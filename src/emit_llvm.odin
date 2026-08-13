// Backend (compiler-plan B16/B17): typed AST straight to textual LLVM IR
// (decision A5), then `clang` to object-and-link in one step.
//
// There is no MIR here on purpose — B13 arrives at M6, and keeping codegen to
// this one file is what makes it replaceable then.
//
// Every local is an alloca plus load/store: LLVM's mem2reg builds the SSA form,
// so this file constructs a phi node only where a value genuinely joins two
// paths it created itself.
package lokec

import "core:fmt"
import "core:os"
import "core:path/filepath"
import os2 "core:os/os2"
import "core:strconv"
import "core:strings"

@(private = "file")
Deferred :: struct {
	flag: string,
	stmt: Stmt,
}

@(private = "file")
Cleanup_Scope :: struct {
	entries: [dynamic]Deferred,
}

@(private = "file")
Emitter :: struct {
	c:    ^Compiler,
	b:    strings.Builder,
	next: int, // temporary and unique-name counter
	// Backend names are an emitter concern. Semantic symbols remain reusable by
	// MIR, interpreters, and multiple backend invocations.
	names:        map[Symbol_Id]string,
	struct_names: map[Type_Id]string,

	// Whether the block being appended to already ends in a terminator. LLVM
	// rejects both a block without one and an instruction after one.
	terminated: bool,

	// Current procedure.
	result_types: []Type_Id,
	result_slots: []string,
	defer_flags:  []string,
	cleanups:     [dynamic]Cleanup_Scope,
	break_label:    string,
	continue_label: string,
	break_depth:    int,
	continue_depth: int,
	// Parameter values already bound at the call site being emitted, so a
	// default expression that names a parameter to its left reads that value.
	param_values: map[Symbol_Id]string,
}

emit_package :: proc(c: ^Compiler, package_id: Package_Id, opts: Options) -> int {
	pkg := package_of(c, package_id)
	if pkg == nil {
		errorf(c, no_span(), "L0404", "cannot emit an unknown package")
		return 2
	}
	e := Emitter {
		c            = c,
		names        = make(map[Symbol_Id]string),
		struct_names = make(map[Type_Id]string),
		cleanups     = make([dynamic]Cleanup_Scope),
		param_values = make(map[Symbol_Id]string),
	}
	strings.builder_init(&e.b)

	emit_preamble(&e)
	emit_struct_definitions(&e)

	// One module, in deterministic dependency order. Every procedure in every
	// package is named before any body is emitted: a cross-package call, a
	// procedure value, and a hoisted literal all need final names first.
	order := package_order(c)
	for id in order {
		name_package_symbols(&e, package_of(c, id))
	}
	for id in order {
		emit_package_items(&e, package_of(c, id))
	}
	emit_entry(&e)

	ll_path := replace_ext(opts.output, ".ll")
	if !os.write_entire_file(ll_path, transmute([]u8)strings.to_string(e.b)) {
		errorf(c, no_span(), "L0401", "cannot write `%s`", ll_path)
		return 2
	}
	if opts.emit_ll {
		fmt.printfln("wrote %s", ll_path)
		return 0
	}
	defer if !opts.keep_temps {
		os.remove(ll_path)
	}

	return link(c, ll_path, opts.output)
}

@(private = "file")
name_package_symbols :: proc(e: ^Emitter, pkg: ^Package) {
	if pkg == nil {
		return
	}
	for file in pkg.files {
		for item in file.active_items {
			if d, ok := item.(^Decl); ok && decl_proc(d) != nil && len(d.symbols) > 0 {
				e.names[d.symbols[0]] = llvm_proc_name(pkg, d.names[0].text)
			}
		}
	}
	for literal, index in pkg.hoisted_procs {
		e.names[literal.symbol] = llvm_proc_name(pkg, fmt.aprintf("lambda.%d", index))
	}
}

@(private = "file")
emit_package_items :: proc(e: ^Emitter, pkg: ^Package) {
	if pkg == nil {
		return
	}
	for file in pkg.files {
		for item in file.active_items {
			if d, ok := item.(^Decl); ok && decl_proc(d) == nil {
				emit_global(e, pkg, d)
			}
		}
	}
	for file in pkg.files {
		for item in file.active_items {
			if d, ok := item.(^Decl); ok && decl_proc(d) != nil {
				emit_proc(e, d.symbols[0], decl_proc(d))
			}
		}
	}
	for literal in pkg.hoisted_procs {
		emit_proc(e, literal.symbol, literal)
	}
}

@(private = "file")
emit_preamble :: proc(e: ^Emitter) {
	fmt.sbprintfln(&e.b, `target triple = "%s"`, e.c.target.triple)
	fmt.sbprintln(&e.b, "")
	// ponytail: printf stands in for core:fmt until the seed runtime lands (M6).
	fmt.sbprintln(&e.b, `@.fmt_int = private unnamed_addr constant [6 x i8] c"%lld\0A\00"`)
	fmt.sbprintln(&e.b, "declare i32 @printf(ptr, ...)")
	// M2 has no runtime yet. Every defined runtime failure — division by zero,
	// an index out of range, a nil dereference or nil indirect call — takes this
	// one explicit seam instead of inheriting LLVM poison or a target-specific
	// hardware exception.
	fmt.sbprintln(&e.b, "declare void @llvm.trap()")
	fmt.sbprintln(&e.b, "")
}

// ------------------------------------------------------- layout agreement --

// One number the checker claims and LLVM can be made to compute.
@(private = "file")
Layout_Probe :: struct {
	description: string,
	llvm:        string, // a constant expression that evaluates to the number
	expected:    u64,
}

// `-check-layout`: builds a module that prints LLVM's own size, alignment, and
// field offsets for every type in the compilation, runs it, and compares the
// results with the checker's cached layout.
//
// Executing LLVM-derived values tests the actual target backend rather than a
// second copy of the checker's formula (m3-plan decision "Layout agreement").
check_layout_agreement :: proc(c: ^Compiler, opts: Options) -> int {
	e := Emitter {
		c            = c,
		names        = make(map[Symbol_Id]string),
		struct_names = make(map[Type_Id]string),
		cleanups     = make([dynamic]Cleanup_Scope),
		param_values = make(map[Symbol_Id]string),
	}
	strings.builder_init(&e.b)
	fmt.sbprintfln(&e.b, `target triple = "%s"`, c.target.triple)
	fmt.sbprintln(&e.b, `@.fmt_int = private unnamed_addr constant [6 x i8] c"%lld\0A\00"`)
	fmt.sbprintln(&e.b, "declare i32 @printf(ptr, ...)")
	emit_struct_definitions(&e)

	probes := make([dynamic]Layout_Probe)
	for index in 0 ..< len(c.types) {
		type := Type_Id(index)
		if !layout_probeable(c, type) {
			continue
		}
		llvm := llvm_type(&e, type)
		name := type_name(c, type)
		append(&probes, Layout_Probe {
			description = fmt.aprintf("size_of(%s)", name),
			llvm        = fmt.aprintf("ptrtoint (ptr getelementptr (%s, ptr null, i64 1) to i64)", llvm),
			expected    = type_size(c, type),
		})
		// The offset of the second member of `{ i8, T }` is T's alignment: LLVM
		// has no `alignof`, but it does have to place that member.
		append(&probes, Layout_Probe {
			description = fmt.aprintf("align_of(%s)", name),
			// `{` is a format directive to core:fmt, so this one is concatenated.
			llvm        = strings.concatenate(
				{"ptrtoint (ptr getelementptr ({ i8, ", llvm, " }, ptr null, i64 0, i32 1) to i64)"},
			),
			expected    = type_align(c, type),
		})
		info := type_of(c, type)
		if info.kind != .Struct {
			continue
		}
		for field, position in info.fields {
			symbol := symbol_of(c, field)
			if symbol == nil {
				continue
			}
			append(&probes, Layout_Probe {
				description = fmt.aprintf("offset_of(%s, %s)", name, identifier_text(c, symbol.name)),
				llvm        = fmt.aprintf("ptrtoint (ptr getelementptr (%s, ptr null, i64 0, i32 %d) to i64)", llvm, position),
				expected    = type_field_offset(c, type, position),
			})
		}
	}

	fmt.sbprintln(&e.b, "define i32 @main() {")
	fmt.sbprintln(&e.b, "entry:")
	for probe in probes {
		fmt.sbprintfln(&e.b, "  call i32 (ptr, ...) @printf(ptr @.fmt_int, i64 %s)", probe.llvm)
	}
	fmt.sbprintln(&e.b, "  ret i32 0")
	fmt.sbprintln(&e.b, "}")

	ll_path := replace_ext(opts.output, ".layout.ll")
	if !os.write_entire_file(ll_path, transmute([]u8)strings.to_string(e.b)) {
		errorf(c, no_span(), "L0401", "cannot write `%s`", ll_path)
		return 2
	}
	defer if !opts.keep_temps {
		os.remove(ll_path)
	}
	if code := link(c, ll_path, opts.output); code != 0 {
		return code
	}
	defer if !opts.keep_temps {
		os.remove(opts.output)
	}

	state, stdout, _, err := os2.process_exec(
		os2.Process_Desc{command = []string{opts.output}},
		context.allocator,
	)
	if err != nil || state.exit_code != 0 {
		errorf(c, no_span(), "L0405", "cannot run the layout probe")
		return 2
	}
	lines := strings.split_lines(strings.trim_space(strings.replace_all(string(stdout), "\r\n", "\n") or_else ""))
	if len(lines) != len(probes) {
		errorf(c, no_span(), "L0405", "the layout probe produced %d values, expected %d", len(lines), len(probes))
		return 2
	}
	disagreements := 0
	for probe, index in probes {
		actual, parsed := strconv.parse_u64(strings.trim_space(lines[index]))
		if !parsed || actual != probe.expected {
			errorf(
				c,
				no_span(),
				"L0405",
				"%s: the checker says %d, LLVM says %s",
				probe.description,
				probe.expected,
				lines[index],
			)
			disagreements += 1
		}
	}
	if disagreements > 0 {
		return 1
	}
	fmt.printfln("%d layout facts agree with LLVM", len(probes))
	return 0
}

// A type whose layout LLVM can be asked about at all: it must lower to a real
// LLVM type and hold a runtime value.
@(private = "file")
layout_probeable :: proc(c: ^Compiler, type: Type_Id) -> bool {
	info := type_of(c, type)
	if info == nil || !type_is_supported(c, type) {
		return false
	}
	#partial switch info.kind {
	case .Bool, .Int, .Float, .Rune, .Raw_Pointer, .Pointer, .Proc, .Enum, .Array, .Struct, .Distinct:
		return true
	}
	return false
}

// ------------------------------------------------------------ LLVM types --

// Named struct definitions, in containment order. The checker has already
// rejected a by-value cycle, so a value edge cannot come back here.
@(private = "file")
emit_struct_definitions :: proc(e: ^Emitter) {
	emitted := make(map[Type_Id]bool)
	defer delete(emitted)
	for index in 0 ..< len(e.c.types) {
		define_struct(e, Type_Id(index), &emitted)
	}
	fmt.sbprintln(&e.b, "")
}

@(private = "file")
define_struct :: proc(e: ^Emitter, type: Type_Id, emitted: ^map[Type_Id]bool) {
	info := type_of(e.c, type)
	if info == nil || info.kind != .Struct || emitted[type] {
		return
	}
	emitted[type] = true
	for field in info.fields {
		symbol := symbol_of(e.c, field)
		if symbol == nil {
			continue
		}
		// A pointer edge stops here: `ptr` needs no definition of its pointee.
		define_struct(e, struct_dependency(e.c, symbol.type), emitted)
	}
	name := struct_name(e, type)
	// `{` is a format directive to core:fmt, so the brace is printed separately.
	fmt.sbprintf(&e.b, "%s = type", name)
	fmt.sbprint(&e.b, " {")
	for field, index in info.fields {
		symbol := symbol_of(e.c, field)
		if index > 0 {
			fmt.sbprint(&e.b, ",")
		}
		fmt.sbprintf(&e.b, " %s", llvm_type(e, symbol.type))
	}
	fmt.sbprintln(&e.b, " }")
}

// The struct a value-typed field depends on, looking through arrays and
// distinct wrappers but never through a pointer.
@(private = "file")
struct_dependency :: proc(c: ^Compiler, type: Type_Id) -> Type_Id {
	current := type_underlying(c, type)
	for i := 0; i < 32; i += 1 {
		info := type_of(c, current)
		if info == nil || info.kind != .Array {
			return current
		}
		current = type_underlying(c, info.element)
	}
	return current
}

@(private = "file")
struct_name :: proc(e: ^Emitter, type: Type_Id) -> string {
	if name, ok := e.struct_names[type]; ok {
		return name
	}
	info := type_of(e.c, type)
	name := ""
	if info != nil && info.name != INVALID_IDENTIFIER {
		name = fmt.aprintf("%%struct.%s.%d", identifier_text(e.c, info.name), int(type))
	} else {
		name = fmt.aprintf("%%struct.anon.%d", int(type))
	}
	e.struct_names[type] = name
	return name
}

llvm_type :: proc(e: ^Emitter, type: Type_Id) -> string {
	// Nothing untyped should reach the backend, but taking its default type here
	// keeps a leak from silently becoming a zero of the wrong width.
	under := type_underlying(e.c, default_type(e.c, type))
	info := type_of(e.c, under)
	if info == nil {
		return "i64"
	}
	#partial switch info.kind {
	case .Void:
		return "void"
	case .Bool:
		// ponytail: `i1` everywhere, so a `bool` alloca is not one byte. Nothing
		// in M2 observes a bool's storage size; switch to i8-in-memory when the
		// foreign ABI lands in M7.
		return "i1"
	case .Int, .Enum:
		return fmt.aprintf("i%d", type_bits(e.c, under))
	case .Rune:
		return "i32"
	case .Float:
		switch info.bits {
		case 16:
			return "half"
		case 32:
			return "float"
		}
		return "double"
	case .Pointer, .Raw_Pointer, .Proc:
		return "ptr"
	case .Array:
		return fmt.aprintf("[%d x %s]", info.count, llvm_type(e, info.element))
	case .Struct:
		return struct_name(e, under)
	}
	return "i64"
}

// The internal convention for several results: one anonymous literal struct,
// used consistently by caller and callee. This is not the frozen Loke or C ABI
// (m2-plan shortcut table); M7 replaces it.
@(private = "file")
llvm_result_type :: proc(e: ^Emitter, results: []Type_Id) -> string {
	switch len(results) {
	case 0:
		return "void"
	case 1:
		return llvm_type(e, results[0])
	}
	b := strings.builder_make()
	strings.write_string(&b, "{ ")
	for result, index in results {
		if index > 0 {
			strings.write_string(&b, ", ")
		}
		strings.write_string(&b, llvm_type(e, result))
	}
	strings.write_string(&b, " }")
	return strings.to_string(b)
}

// ---------------------------------------------------------------- globals --

// File-scope variables need constant initialisers (design.md "Values that
// outlive every scope"), so folding has already produced the value.
@(private = "file")
emit_global :: proc(e: ^Emitter, pkg: ^Package, d: ^Decl) {
	for symbol_id, i in d.symbols {
		sym := symbol_of(e.c, symbol_id)
		if sym == nil || sym.kind != .Var {
			continue
		}
		name := llvm_global_name(pkg, identifier_text(e.c, sym.name))
		e.names[symbol_id] = name
		value := ""
		if i < len(d.values) && d.values[i] != nil && is_const_expr(d.values[i]) {
			value = llvm_const(e, const_value_of(d.values[i]), sym.type)
		} else {
			zero, ok := zero_const(e.c, sym.type)
			if !ok {
				panic("a global type the checker did not gate reached the backend")
			}
			value = llvm_const(e, zero, sym.type)
		}
		fmt.sbprintfln(&e.b, "%s = global %s %s", name, llvm_type(e, sym.type), value)
	}
	fmt.sbprintln(&e.b, "")
}

// -------------------------------------------------------------- constants --

llvm_const :: proc(e: ^Emitter, value: Const_Value, type: Type_Id) -> string {
	under := type_underlying(e.c, default_type(e.c, type))
	info := type_of(e.c, under)
	if info == nil {
		return "0"
	}
	#partial switch info.kind {
	case .Bool:
		return value.boolean ? "true" : "false"
	case .Int, .Enum, .Rune:
		bits := type_bits(e.c, under)
		signed := type_signed(e.c, under)
		if info.kind == .Rune {
			bits, signed = 32, true
		}
		return bi_text(e.c, bi_wrap(e.c, value.integer, bits, signed))
	case .Float:
		return llvm_float(value.float, info.bits)
	case .Pointer, .Raw_Pointer, .Proc:
		return "null"
	case .Array:
		b := strings.builder_make()
		strings.write_string(&b, "[")
		for index in 0 ..< int(info.count) {
			if index > 0 {
				strings.write_string(&b, ",")
			}
			element := Const_Value{}
			if value.aggregate != nil && index < len(value.aggregate.elements) {
				element = value.aggregate.elements[index]
			}
			fmt.sbprintf(&b, " %s %s", llvm_type(e, info.element), llvm_const(e, element, info.element))
		}
		strings.write_string(&b, " ]")
		return strings.to_string(b)
	case .Struct:
		b := strings.builder_make()
		strings.write_string(&b, "{")
		for field, index in info.fields {
			symbol := symbol_of(e.c, field)
			if index > 0 {
				strings.write_string(&b, ",")
			}
			element := Const_Value{}
			if value.aggregate != nil && index < len(value.aggregate.elements) {
				element = value.aggregate.elements[index]
			}
			fmt.sbprintf(&b, " %s %s", llvm_type(e, symbol.type), llvm_const(e, element, symbol.type))
		}
		strings.write_string(&b, " }")
		return strings.to_string(b)
	}
	return "0"
}

// LLVM's decimal float syntax is only exact for values it can round-trip, so
// every float constant is spelled as its bit pattern. `half` uses the 16-bit
// form; `float` uses the double pattern, which is exact because the value was
// already rounded to single precision.
@(private = "file")
llvm_float :: proc(value: f64, bits: u16) -> string {
	if bits == 16 {
		return fmt.aprintf("0xH%04X", f64_to_f16_bits(value))
	}
	pattern := transmute(u64)value
	if bits == 32 {
		pattern = transmute(u64)f64(f32(value))
	}
	return fmt.aprintf("0x%016X", pattern)
}

// ------------------------------------------------------------ procedures --

@(private = "file")
emit_proc :: proc(e: ^Emitter, symbol_id: Symbol_Id, literal: ^Expr_Proc) {
	symbol := symbol_of(e.c, symbol_id)
	if symbol == nil || literal == nil || literal.body == nil {
		return
	}
	llvm_name, named := e.names[symbol_id]
	if !named {
		// Every declared and hoisted procedure is named before any body is
		// emitted, so arriving here would mean emitting one nothing can call.
		panic("a procedure reached emission without a mangled name")
	}

	e.result_types = symbol.results
	e.result_slots = make([]string, len(symbol.results))
	e.terminated = false
	clear(&e.cleanups)

	fmt.sbprintf(&e.b, "define %s %s(", llvm_result_type(e, symbol.results), llvm_name)
	for parameter, index in symbol.params {
		if index > 0 {
			fmt.sbprint(&e.b, ", ")
		}
		mode := symbol_param_mode(e.c, symbol, index)
		type := mode == .Inout ? "ptr" : llvm_type(e, parameter)
		fmt.sbprintf(&e.b, "%s %%arg%d", type, index)
	}
	fmt.sbprintln(&e.b, ") {")
	fmt.sbprintln(&e.b, "entry:")

	// A value parameter is immutable but addressable, so it gets storage of its
	// own; an `inout` parameter is already the alias.
	for parameter, index in symbol.params {
		binding := symbol.param_symbols[index]
		if binding == INVALID_SYMBOL {
			continue
		}
		if symbol_param_mode(e.c, symbol, index) == .Inout {
			e.names[binding] = fmt.aprintf("%%arg%d", index)
			continue
		}
		slot := fmt.aprintf("%%p%d.%d", index, next_id(e))
		fmt.sbprintfln(&e.b, "  %s = alloca %s", slot, llvm_type(e, parameter))
		fmt.sbprintfln(&e.b, "  store %s %%arg%d, ptr %s", llvm_type(e, parameter), index, slot)
		e.names[binding] = slot
	}

	// Named results start at their zero value (design.md "Named results").
	for result, index in symbol.results {
		slot := fmt.aprintf("%%r%d.%d", index, next_id(e))
		fmt.sbprintfln(&e.b, "  %s = alloca %s", slot, llvm_type(e, result))
		zero, ok := zero_const(e.c, result)
		if ok {
			fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", llvm_type(e, result), llvm_const(e, zero, result), slot)
		}
		e.result_slots[index] = slot
		if index < len(symbol.result_symbols) && symbol.result_symbols[index] != INVALID_SYMBOL {
			e.names[symbol.result_symbols[index]] = slot
		}
	}

	// One `i1` flag per syntactic defer, reset when its scope activates and set
	// when registration is reached, so a loop iteration cannot inherit the
	// previous one's registration.
	e.defer_flags = make([]string, literal.defer_count)
	for index in 0 ..< literal.defer_count {
		flag := fmt.aprintf("%%defer%d.%d", index, next_id(e))
		fmt.sbprintfln(&e.b, "  %s = alloca i1", flag)
		e.defer_flags[index] = flag
	}

	emit_scoped_block(e, literal.body)
	if !e.terminated {
		emit_return_values(e, nil)
	}
	fmt.sbprintln(&e.b, "}")
	fmt.sbprintln(&e.b, "")
}

@(private = "file")
symbol_param_mode :: proc(c: ^Compiler, symbol: ^Symbol, index: int) -> Param_Mode {
	info := type_of(c, symbol.proc_type)
	if info == nil || index >= len(info.param_modes) {
		return .Value
	}
	return info.param_modes[index]
}

// The C entry point. Internal runtime startup belongs here, which is why
// Loke's `main` is not the C `main`.
@(private = "file")
emit_entry :: proc(e: ^Emitter) {
	fmt.sbprintln(&e.b, "define i32 @main() {")
	fmt.sbprintln(&e.b, "entry:")
	fmt.sbprintfln(&e.b, "  call void %s()", e.names[entry_symbol(e.c)] or_else "@loke.p.main")
	fmt.sbprintln(&e.b, "  ret i32 0")
	fmt.sbprintln(&e.b, "}")
}

// ------------------------------------------------------------ block plumbing --

@(private = "file")
next_id :: proc(e: ^Emitter) -> int {
	e.next += 1
	return e.next
}

@(private = "file")
temp :: proc(e: ^Emitter) -> string {
	return fmt.aprintf("%%t%d", next_id(e))
}

@(private = "file")
new_label :: proc(e: ^Emitter, prefix: string) -> string {
	return fmt.aprintf("%s.%d", prefix, next_id(e))
}

@(private = "file")
place_label :: proc(e: ^Emitter, label: string) {
	if !e.terminated {
		fmt.sbprintfln(&e.b, "  br label %%%s", label)
	}
	fmt.sbprintfln(&e.b, "%s:", label)
	e.terminated = false
}

@(private = "file")
branch :: proc(e: ^Emitter, label: string) {
	if e.terminated {
		return
	}
	fmt.sbprintfln(&e.b, "  br label %%%s", label)
	e.terminated = true
}

@(private = "file")
branch_if :: proc(e: ^Emitter, cond: string, then_label, else_label: string) {
	if e.terminated {
		return
	}
	fmt.sbprintfln(&e.b, "  br i1 %s, label %%%s, label %%%s", cond, then_label, else_label)
	e.terminated = true
}

@(private = "file")
emit_trap :: proc(e: ^Emitter) {
	fmt.sbprintln(&e.b, "  call void @llvm.trap()")
	fmt.sbprintln(&e.b, "  unreachable")
	e.terminated = true
}

// Traps when `cond` holds, and continues in a fresh block otherwise.
@(private = "file")
trap_if :: proc(e: ^Emitter, cond: string, prefix: string) {
	fail := new_label(e, prefix)
	ok := new_label(e, "ok")
	branch_if(e, cond, fail, ok)
	fmt.sbprintfln(&e.b, "%s:", fail)
	e.terminated = false
	emit_trap(e)
	fmt.sbprintfln(&e.b, "%s:", ok)
	e.terminated = false
}

// -------------------------------------------------------------- cleanups --

@(private = "file")
push_scope :: proc(e: ^Emitter, b: ^Block) {
	push_scope_stmts(e, b == nil ? nil : b.stmts)
}

@(private = "file")
push_scope_stmts :: proc(e: ^Emitter, stmts: []Stmt) {
	append(&e.cleanups, Cleanup_Scope{entries = make([dynamic]Deferred)})
	// Reset the flag of every defer written directly in this scope: the storage
	// is reused across loop iterations, so a stale `true` would run a
	// registration that never happened this time round.
	reset_defer_flags(e, stmts)
}

// A `defer` written inside a selected `when` belongs to the surrounding scope,
// so its flag is reset with that scope's own.
@(private = "file")
reset_defer_flags :: proc(e: ^Emitter, stmts: []Stmt) {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^Stmt_Defer:
			if s.slot < len(e.defer_flags) {
				fmt.sbprintfln(&e.b, "  store i1 false, ptr %s", e.defer_flags[s.slot])
			}
		case ^Stmt_When:
			if selected := when_selected_block(s); selected != nil {
				reset_defer_flags(e, selected.stmts)
			}
		}
	}
}

@(private = "file")
pop_scope :: proc(e: ^Emitter) {
	if len(e.cleanups) == 0 {
		return
	}
	if !e.terminated {
		run_cleanups(e, len(e.cleanups) - 1)
	}
	pop(&e.cleanups)
}

// Runs the deferred statements of every scope above `down_to`, innermost first
// and in reverse registration order within each.
@(private = "file")
run_cleanups :: proc(e: ^Emitter, down_to: int) {
	for depth := len(e.cleanups) - 1; depth >= down_to; depth -= 1 {
		entries := e.cleanups[depth].entries
		for index := len(entries) - 1; index >= 0; index -= 1 {
			entry := entries[index]
			flag := temp(e)
			fmt.sbprintfln(&e.b, "  %s = load i1, ptr %s", flag, entry.flag)
			run := new_label(e, "defer.run")
			skip := new_label(e, "defer.skip")
			branch_if(e, flag, run, skip)
			fmt.sbprintfln(&e.b, "%s:", run)
			e.terminated = false
			emit_stmt(e, entry.stmt)
			branch(e, skip)
			fmt.sbprintfln(&e.b, "%s:", skip)
			e.terminated = false
		}
	}
}

// -------------------------------------------------------------- statements --

@(private = "file")
emit_scoped_block :: proc(e: ^Emitter, b: ^Block) {
	push_scope(e, b)
	emit_block_statements(e, b)
	pop_scope(e)
}

@(private = "file")
emit_block_statements :: proc(e: ^Emitter, b: ^Block) {
	if b == nil {
		return
	}
	for stmt in b.stmts {
		if e.terminated {
			// Unreachable code still needs a block to live in, or LLVM rejects
			// the instructions that follow a terminator.
			fmt.sbprintfln(&e.b, "unreachable.%d:", next_id(e))
			e.terminated = false
		}
		emit_stmt(e, stmt)
	}
}

@(private = "file")
emit_stmt :: proc(e: ^Emitter, stmt: Stmt) {
	switch s in stmt {
	case ^Stmt_Error:

	case ^Decl:
		emit_local_decl(e, s)

	case ^Stmt_Expr:
		for expr in s.exprs {
			// `#assert` is checked and answered at compile time and has no runtime
			// cost, so there is nothing here to emit.
			if call, is_call := expr.(^Expr_Call); is_call {
				if _, is_hash := call.callee.(^Expr_Hash); is_hash {
					continue
				}
			}
			emit_expr(e, expr)
		}

	case ^Stmt_Assign:
		emit_assign(e, s)

	case ^Stmt_If:
		emit_if(e, s)

	case ^Stmt_For:
		emit_for(e, s)

	case ^Stmt_Switch:
		emit_switch(e, s)

	case ^Stmt_Defer:
		if s.slot < len(e.defer_flags) && len(e.cleanups) > 0 {
			fmt.sbprintfln(&e.b, "  store i1 true, ptr %s", e.defer_flags[s.slot])
			append(&e.cleanups[len(e.cleanups) - 1].entries, Deferred{flag = e.defer_flags[s.slot], stmt = s.stmt})
		}

	case ^Stmt_Return:
		emit_return_values(e, s)

	case ^Stmt_Branch:
		if s.kind == .Break {
			run_cleanups(e, e.break_depth)
			branch(e, e.break_label)
		} else {
			run_cleanups(e, e.continue_depth)
			branch(e, e.continue_label)
		}

	case ^Block:
		emit_scoped_block(e, s)

	case ^Stmt_When:
		// Structural selection: the branch the checker chose is emitted in place,
		// with no scope of its own, so its declarations and `defer`s belong to
		// the surrounding block exactly as written.
		emit_block_statements(e, when_selected_block(s))

	case ^Stmt_Foreach:
		// The checker's L0350 arm gates every statement missing here, so this is
		// a hole in that gate — and skipping it would emit a program that
		// silently does less than the source says.
		panic("a statement the checker did not gate reached the backend")
	}
}

@(private = "file")
emit_local_decl :: proc(e: ^Emitter, d: ^Decl) {
	// A call filling several names evaluates once.
	if len(d.values) == 1 && len(d.symbols) > 1 {
		if call, ok := d.values[0].(^Expr_Call); ok && len(call.result_types) == len(d.symbols) {
			results := emit_multi_call(e, call)
			for symbol_id, index in d.symbols {
				slot := declare_local(e, symbol_id)
				if slot != "" {
					store(e, call.result_types[index], results[index], slot)
				}
			}
			return
		}
	}
	for symbol_id, i in d.symbols {
		sym := symbol_of(e.c, symbol_id)
		// Constants are folded at every use, so they need no storage.
		if sym == nil || sym.kind != .Var {
			continue
		}
		slot := declare_local(e, symbol_id)
		if i < len(d.values) && d.values[i] == nil {
			continue // `---`: storage without an initial value
		}
		if i < len(d.values) && d.values[i] != nil {
			store(e, sym.type, emit_expr(e, d.values[i]), slot)
			continue
		}
		zero, ok := zero_const(e.c, sym.type)
		if ok {
			store(e, sym.type, llvm_const(e, zero, sym.type), slot)
		}
	}
}

@(private = "file")
declare_local :: proc(e: ^Emitter, symbol_id: Symbol_Id) -> string {
	sym := symbol_of(e.c, symbol_id)
	if sym == nil || sym.kind != .Var {
		return ""
	}
	name := fmt.aprintf("%%%s.%d", identifier_text(e.c, sym.name), next_id(e))
	e.names[symbol_id] = name
	fmt.sbprintfln(&e.b, "  %s = alloca %s", name, llvm_type(e, sym.type))
	return name
}

// design.md "Assignment statements": every right side is evaluated, then every
// destination address, then the writes happen. Nothing is written before all of
// both are prepared.
@(private = "file")
emit_assign :: proc(e: ^Emitter, s: ^Stmt_Assign) {
	if s.op != .Assign {
		emit_compound_assign(e, s)
		return
	}

	values: []string
	types: []Type_Id
	if len(s.rhs) == 1 && len(s.lhs) > 1 {
		call := s.rhs[0].(^Expr_Call)
		values = emit_multi_call(e, call)
		types = call.result_types
	} else {
		values = make([]string, len(s.rhs))
		types = make([]Type_Id, len(s.rhs))
		for value, index in s.rhs {
			values[index] = emit_expr(e, value)
			types[index] = expr_base(value).type
		}
	}

	addresses := make([]string, len(s.lhs))
	for target, index in s.lhs {
		if is_discard(target) {
			continue
		}
		addresses[index] = emit_address(e, target)
	}
	for target, index in s.lhs {
		if addresses[index] == "" || index >= len(values) {
			continue
		}
		store(e, expr_base(target).type, values[index], addresses[index])
	}
}

// The destination is evaluated once, before the right operand.
@(private = "file")
emit_compound_assign :: proc(e: ^Emitter, s: ^Stmt_Assign) {
	target := s.lhs[0]
	type := expr_base(target).type
	address := emit_address(e, target)
	current := temp(e)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", current, llvm_type(e, type), address)
	rhs := emit_expr(e, s.rhs[0])
	op := compound_op(s.op)
	result := emit_binary_op(e, op, type, expr_base(s.rhs[0]).type, current, rhs)
	store(e, type, result, address)
}

@(private = "file")
compound_op :: proc(op: Token_Kind) -> Token_Kind {
	#partial switch op {
	case .Plus_Eq:
		return .Plus
	case .Minus_Eq:
		return .Minus
	case .Star_Eq:
		return .Star
	case .Slash_Eq:
		return .Slash
	case .Percent_Eq:
		return .Percent
	case .Pipe_Eq:
		return .Pipe
	case .Tilde_Eq:
		return .Tilde
	case .Amp_Eq:
		return .Amp
	case .Amp_Tilde_Eq:
		return .Amp_Tilde
	case .Shl_Eq:
		return .Shl
	case .Shr_Eq:
		return .Shr
	}
	return .Plus
}

@(private = "file")
is_discard :: proc(target: Expr) -> bool {
	ident, ok := target.(^Expr_Ident)
	return ok && ident.name == "_"
}

@(private = "file")
emit_if :: proc(e: ^Emitter, s: ^Stmt_If) {
	push_scope(e, nil)
	if s.init != nil {
		emit_stmt(e, s.init)
	}
	cond := emit_expr(e, s.cond)
	then_label := new_label(e, "if.then")
	else_label := new_label(e, "if.else")
	done_label := new_label(e, "if.done")
	branch_if(e, cond, then_label, s.otherwise == nil ? done_label : else_label)

	fmt.sbprintfln(&e.b, "%s:", then_label)
	e.terminated = false
	emit_scoped_block(e, s.then)
	branch(e, done_label)

	if s.otherwise != nil {
		fmt.sbprintfln(&e.b, "%s:", else_label)
		e.terminated = false
		emit_stmt(e, s.otherwise)
		branch(e, done_label)
	}
	fmt.sbprintfln(&e.b, "%s:", done_label)
	e.terminated = false
	pop_scope(e)
}

@(private = "file")
emit_for :: proc(e: ^Emitter, s: ^Stmt_For) {
	outer_break, outer_continue := e.break_label, e.continue_label
	outer_break_depth, outer_continue_depth := e.break_depth, e.continue_depth
	defer {
		e.break_label, e.continue_label = outer_break, outer_continue
		e.break_depth, e.continue_depth = outer_break_depth, outer_continue_depth
	}

	// The loop's own scope holds the init declaration; `break` leaves it too.
	e.break_depth = len(e.cleanups)
	push_scope(e, nil)
	if s.init != nil {
		emit_stmt(e, s.init)
	}

	head := new_label(e, "for.head")
	body := new_label(e, "for.body")
	post := new_label(e, "for.post")
	done := new_label(e, "for.done")
	e.break_label = done
	e.continue_label = post
	e.continue_depth = len(e.cleanups)

	place_label(e, head)
	if s.cond != nil {
		branch_if(e, emit_expr(e, s.cond), body, done)
	} else {
		branch(e, body)
	}

	fmt.sbprintfln(&e.b, "%s:", body)
	e.terminated = false
	emit_scoped_block(e, s.body)
	branch(e, post)

	fmt.sbprintfln(&e.b, "%s:", post)
	e.terminated = false
	if s.post != nil {
		emit_stmt(e, s.post)
	}
	branch(e, head)

	fmt.sbprintfln(&e.b, "%s:", done)
	e.terminated = false
	pop_scope(e)
}

// ponytail: one ordered comparison chain rather than an LLVM `switch` for the
// all-constant case. Ranges and non-constant cases need the chain anyway, and a
// second lowering would have to agree with this one about source order. Add the
// jump table when a measured switch is hot.
@(private = "file")
emit_switch :: proc(e: ^Emitter, s: ^Stmt_Switch) {
	outer_break, outer_break_depth := e.break_label, e.break_depth
	defer {
		e.break_label = outer_break
		e.break_depth = outer_break_depth
	}

	e.break_depth = len(e.cleanups)
	push_scope(e, nil)
	if s.init != nil {
		emit_stmt(e, s.init)
	}
	subject_type := expr_base(s.subject).type
	subject := emit_expr(e, s.subject)

	done := new_label(e, "switch.done")
	e.break_label = done

	bodies := make([]string, len(s.cases))
	tests := make([]string, len(s.cases))
	for index in 0 ..< len(s.cases) {
		bodies[index] = new_label(e, "case.body")
		tests[index] = new_label(e, "case.test")
	}
	default_index := -1
	for entry, index in s.cases {
		if len(entry.values) == 0 {
			default_index = index
		}
	}

	// Value cases are tested in source order; the default is the fallthrough of
	// the last of them, wherever it was written.
	order := make([dynamic]int)
	defer delete(order)
	for entry, index in s.cases {
		if len(entry.values) > 0 {
			append(&order, index)
		}
	}
	fallback := default_index >= 0 ? bodies[default_index] : done

	branch(e, len(order) > 0 ? tests[order[0]] : fallback)
	for case_index, position in order {
		fmt.sbprintfln(&e.b, "%s:", tests[case_index])
		e.terminated = false
		next := position + 1 < len(order) ? tests[order[position + 1]] : fallback
		matched := ""
		for value in s.cases[case_index].values {
			test := emit_case_test(e, subject, subject_type, value)
			if matched == "" {
				matched = test
			} else {
				combined := temp(e)
				fmt.sbprintfln(&e.b, "  %s = or i1 %s, %s", combined, matched, test)
				matched = combined
			}
		}
		branch_if(e, matched, bodies[case_index], next)
	}

	for entry, index in s.cases {
		fmt.sbprintfln(&e.b, "%s:", bodies[index])
		e.terminated = false
		push_scope_stmts(e, entry.stmts)
		for stmt in entry.stmts {
			if e.terminated {
				fmt.sbprintfln(&e.b, "unreachable.%d:", next_id(e))
				e.terminated = false
			}
			emit_stmt(e, stmt)
		}
		pop_scope(e)
		branch(e, done)
	}

	fmt.sbprintfln(&e.b, "%s:", done)
	e.terminated = false
	pop_scope(e)
}

@(private = "file")
emit_case_test :: proc(e: ^Emitter, subject: string, subject_type: Type_Id, value: Expr) -> string {
	if range, is_range := value.(^Expr_Range); is_range {
		lo := emit_expr(e, range.lo)
		hi := emit_expr(e, range.hi)
		low_ok := emit_compare(e, .Gt_Eq, subject_type, subject, lo)
		high_op := range.op == .Range_Excl ? Token_Kind.Lt : Token_Kind.Lt_Eq
		high_ok := emit_compare(e, high_op, subject_type, subject, hi)
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = and i1 %s, %s", out, low_ok, high_ok)
		return out
	}
	return emit_equal(e, subject_type, subject, emit_expr(e, value))
}

// ----------------------------------------------------------------- returns --

// Return values move into the result slots before any cleanup runs, so a
// deferred statement cannot change what is returned.
@(private = "file")
emit_return_values :: proc(e: ^Emitter, s: ^Stmt_Return) {
	if s != nil && len(s.values) > 0 {
		if len(s.values) == 1 && len(e.result_types) > 1 {
			if call, ok := s.values[0].expr.(^Expr_Call); ok && len(call.result_types) == len(e.result_types) {
				results := emit_multi_call(e, call)
				for value, index in results {
					store(e, e.result_types[index], value, e.result_slots[index])
				}
				emit_epilogue(e)
				return
			}
		}
		values := make([]string, len(s.values))
		for value, index in s.values {
			values[index] = emit_expr(e, value.expr)
		}
		for value, index in values {
			if index < len(e.result_slots) {
				store(e, e.result_types[index], value, e.result_slots[index])
			}
		}
	}
	emit_epilogue(e)
}

@(private = "file")
emit_epilogue :: proc(e: ^Emitter) {
	run_cleanups(e, 0)
	switch len(e.result_types) {
	case 0:
		fmt.sbprintln(&e.b, "  ret void")
	case 1:
		value := temp(e)
		fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", value, llvm_type(e, e.result_types[0]), e.result_slots[0])
		fmt.sbprintfln(&e.b, "  ret %s %s", llvm_type(e, e.result_types[0]), value)
	case:
		aggregate := "undef"
		result_type := llvm_result_type(e, e.result_types)
		for type, index in e.result_types {
			value := temp(e)
			fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", value, llvm_type(e, type), e.result_slots[index])
			next := temp(e)
			fmt.sbprintfln(
				&e.b,
				"  %s = insertvalue %s %s, %s %s, %d",
				next, result_type, aggregate, llvm_type(e, type), value, index,
			)
			aggregate = next
		}
		fmt.sbprintfln(&e.b, "  ret %s %s", result_type, aggregate)
	}
	e.terminated = true
}

// ------------------------------------------------------------------ places --

@(private = "file")
store :: proc(e: ^Emitter, type: Type_Id, value, address: string) {
	if address == "" || value == "" {
		return
	}
	fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", llvm_type(e, type), value, address)
}

// The address of a place. Composite literals get temporary storage here, which
// is what makes `&Point{1, 2}` work.
@(private = "file")
emit_address :: proc(e: ^Emitter, expr: Expr) -> string {
	#partial switch v in expr {
	case ^Expr_Ident:
		if name, ok := e.names[v.symbol]; ok {
			return name
		}
		panic("a resolved place has no backend storage")

	case ^Expr_Postfix:
		pointer := emit_expr(e, v.operand)
		emit_nil_check(e, pointer)
		return pointer

	case ^Expr_Selector:
		symbol := symbol_of(e.c, v.resolution.symbol)
		base_type, base_address := emit_base_address(e, v.operand)
		out := temp(e)
		fmt.sbprintfln(
			&e.b,
			"  %s = getelementptr inbounds %s, ptr %s, i32 0, i32 %d",
			out, llvm_type(e, base_type), base_address, symbol.index,
		)
		return out

	case ^Expr_Index:
		base_type, base_address := emit_base_address(e, v.operand)
		info := type_of(e.c, type_underlying(e.c, base_type))
		index := emit_expr(e, v.indices[0])
		index = emit_bounds_check(e, index, expr_base(v.indices[0]).type, info.count)
		out := temp(e)
		fmt.sbprintfln(
			&e.b,
			"  %s = getelementptr inbounds %s, ptr %s, i64 0, i64 %s",
			out, llvm_type(e, base_type), base_address, index,
		)
		return out

	case ^Expr_Composite:
		slot := temp(e)
		fmt.sbprintfln(&e.b, "  %s = alloca %s", slot, llvm_type(e, v.type))
		emit_composite_into(e, v, slot)
		return slot
	}
	// Any other addressable expression is materialised into a temporary.
	type := expr_base(expr).type
	slot := temp(e)
	fmt.sbprintfln(&e.b, "  %s = alloca %s", slot, llvm_type(e, type))
	store(e, type, emit_expr(e, expr), slot)
	return slot
}

// `p.x` and `p[i]` accept one pointer hop, in which case the pointer value
// itself is the base address.
@(private = "file")
emit_base_address :: proc(e: ^Emitter, operand: Expr) -> (Type_Id, string) {
	type := expr_base(operand).type
	info := type_of(e.c, type_underlying(e.c, type))
	if info != nil && info.kind == .Pointer {
		pointer := emit_expr(e, operand)
		emit_nil_check(e, pointer)
		return info.element, pointer
	}
	return type, emit_address(e, operand)
}

@(private = "file")
emit_nil_check :: proc(e: ^Emitter, pointer: string) {
	is_nil := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", is_nil, pointer)
	trap_if(e, is_nil, "nil.deref")
}

@(private = "file")
emit_bounds_check :: proc(e: ^Emitter, index: string, index_type: Type_Id, count: u64) -> string {
	// An unsigned comparison catches a negative index and an oversized one at
	// once: a negative value becomes a very large unsigned one. Compare before
	// truncating a 128-bit index, then use the checked i64 value for the GEP.
	out_of_range := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp uge %s %s, %d", out_of_range, llvm_type(e, index_type), index, count)
	trap_if(e, out_of_range, "bounds")
	return widen_to_i64(e, index, index_type)
}

@(private = "file")
widen_to_i64 :: proc(e: ^Emitter, value: string, type: Type_Id) -> string {
	bits := type_bits(e.c, type)
	if bits == 64 {
		return value
	}
	out := temp(e)
	op := type_signed(e.c, type) ? "sext" : "zext"
	if bits > 64 {
		op = "trunc"
	}
	fmt.sbprintfln(&e.b, "  %s = %s i%d %s to i64", out, op, bits, value)
	return out
}

// ------------------------------------------------------------ expressions --

// Returns an operand: a literal, or a `%name`.
@(private = "file")
emit_expr :: proc(e: ^Emitter, expr: Expr) -> string {
	if expr == nil {
		return "0"
	}
	base := expr_base(expr)
	if base.is_const && base.const_value.kind != .Invalid {
		return llvm_const(e, base.const_value, base.type)
	}

	switch v in expr {
	case ^Expr_Error:
		return "0"

	case ^Expr_Literal:
		return llvm_const(e, v.const_value, v.type)

	case ^Expr_Ident:
		if name, ok := e.param_values[v.symbol]; ok {
			return name // a default argument reading a parameter to its left
		}
		symbol := symbol_of(e.c, v.symbol)
		if symbol != nil && symbol.kind == .Proc {
			return e.names[v.symbol] or_else "null"
		}
		out := temp(e)
		address, ok := e.names[v.symbol]
		if !ok {
			panic("a resolved value has no backend storage")
		}
		fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", out, llvm_type(e, v.type), address)
		return out

	case ^Expr_Selector, ^Expr_Index, ^Expr_Postfix:
		// `pkg.f` as a value is the procedure itself, not storage holding one.
		if symbol := symbol_of(e.c, base.resolution.symbol); symbol != nil && symbol.kind == .Proc {
			return e.names[base.resolution.symbol] or_else "null"
		}
		address := emit_address(e, expr)
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", out, llvm_type(e, base.type), address)
		return out

	case ^Expr_Unary:
		return emit_unary(e, v)

	case ^Expr_Binary:
		return emit_binary(e, v)

	case ^Expr_Cond:
		return emit_cond(e, v)

	case ^Expr_Call:
		return emit_call(e, v)

	case ^Expr_Composite:
		slot := emit_address(e, expr)
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", out, llvm_type(e, v.type), slot)
		return out

	case ^Expr_Proc:
		if name, ok := e.names[v.symbol]; ok {
			return name
		}
		return "null"

	case ^Expr_Type_Assert, ^Expr_Slice, ^Expr_Range, ^Expr_Or_Else, ^Expr_Move,
	     ^Expr_Hash, ^Expr_Proc_Group, ^Expr_Operator,
	     ^Type_Pointer, ^Type_Multi_Pointer, ^Type_Slice, ^Type_Dynamic_Array,
	     ^Type_Array, ^Type_Map, ^Type_Distinct, ^Type_Dyn, ^Type_Type,
	     ^Type_Poly, ^Type_Proc, ^Type_Record, ^Type_Enum, ^Type_Interface:
	}
	// Same gate as `emit_stmt`: returning `0` here would compile silently and
	// produce the wrong answer.
	panic("an expression the checker did not gate reached the backend")
}

@(private = "file")
emit_composite_into :: proc(e: ^Emitter, v: ^Expr_Composite, address: string) {
	// Start from the zero value so an omitted field is not left undefined.
	zero, ok := zero_const(e.c, v.type)
	if ok {
		store(e, v.type, llvm_const(e, zero, v.type), address)
	}
	info := type_of(e.c, type_underlying(e.c, v.type))
	if info == nil {
		return
	}
	for element, index in v.elements {
		slot := index
		element_type := info.element
		if info.kind == .Struct {
			if element.key != nil {
				key := element.key.(^Expr_Ident)
				field := struct_field(e.c, v.type, intern_identifier(e.c, key.name))
				slot = int(symbol_of(e.c, field).index)
			}
			element_type = symbol_of(e.c, info.fields[slot]).type
		}
		value := emit_expr(e, element.value)
		field_address := temp(e)
		fmt.sbprintfln(
			&e.b,
			"  %s = getelementptr inbounds %s, ptr %s, i32 0, i32 %d",
			field_address, llvm_type(e, v.type), address, slot,
		)
		store(e, element_type, value, field_address)
	}
}

@(private = "file")
emit_unary :: proc(e: ^Emitter, v: ^Expr_Unary) -> string {
	if v.op == .Amp {
		return emit_address(e, v.operand)
	}
	operand := emit_expr(e, v.operand)
	type := v.type
	llvm := llvm_type(e, type)
	out := temp(e)
	#partial switch v.op {
	case .Plus:
		return operand
	case .Minus:
		if type_is_float(e.c, type) {
			fmt.sbprintfln(&e.b, "  %s = fneg %s %s", out, llvm, operand)
		} else {
			fmt.sbprintfln(&e.b, "  %s = sub %s 0, %s", out, llvm, operand)
		}
	case .Tilde:
		fmt.sbprintfln(&e.b, "  %s = xor %s %s, -1", out, llvm, operand)
	case .Not:
		fmt.sbprintfln(&e.b, "  %s = xor i1 %s, true", out, operand)
	}
	return out
}

@(private = "file")
emit_binary :: proc(e: ^Emitter, v: ^Expr_Binary) -> string {
	#partial switch v.op {
	case .And_And, .Or_Or:
		return emit_short_circuit(e, v)
	case .Eq_Eq, .Not_Eq, .Lt, .Lt_Eq, .Gt, .Gt_Eq:
		operand_type := expr_base(v.lhs).type
		lhs := emit_expr(e, v.lhs)
		rhs := emit_expr(e, v.rhs)
		return emit_compare(e, v.op, operand_type, lhs, rhs)
	}
	lhs := emit_expr(e, v.lhs)
	rhs := emit_expr(e, v.rhs)
	return emit_binary_op(e, v.op, v.type, expr_base(v.rhs).type, lhs, rhs)
}

@(private = "file")
emit_binary_op :: proc(e: ^Emitter, op: Token_Kind, type: Type_Id, rhs_type: Type_Id, lhs, rhs: string) -> string {
	llvm := llvm_type(e, type)
	if type_is_float(e.c, type) {
		out := temp(e)
		name := ""
		#partial switch op {
		case .Plus:
			name = "fadd"
		case .Minus:
			name = "fsub"
		case .Star:
			name = "fmul"
		case .Slash:
			name = "fdiv"
		}
		fmt.sbprintfln(&e.b, "  %s = %s %s %s, %s", out, name, llvm, lhs, rhs)
		return out
	}

	signed := type_signed(e.c, type) || type_is_rune(e.c, type)
	#partial switch op {
	case .Slash, .Percent:
		return emit_divrem(e, op, type, signed, lhs, rhs)
	case .Shl, .Shr:
		return emit_shift(e, op, type, signed, rhs_type, lhs, rhs)
	case .Amp_Tilde:
		complement := temp(e)
		fmt.sbprintfln(&e.b, "  %s = xor %s %s, -1", complement, llvm, rhs)
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = and %s %s, %s", out, llvm, lhs, complement)
		return out
	}
	name := ""
	#partial switch op {
	case .Plus:
		name = "add"
	case .Minus:
		name = "sub"
	case .Star:
		name = "mul"
	case .Amp:
		name = "and"
	case .Pipe:
		name = "or"
	case .Tilde:
		name = "xor"
	}
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = %s %s %s, %s", out, name, llvm, lhs, rhs)
	return out
}

// Division and remainder need two guards. Zero takes the explicit trap seam;
// `MIN / -1` has the wrapping result design.md requires and must not reach LLVM
// `sdiv`/`srem`, where it would be poison.
@(private = "file")
emit_divrem :: proc(e: ^Emitter, op: Token_Kind, type: Type_Id, signed: bool, lhs, rhs: string) -> string {
	llvm := llvm_type(e, type)
	bits := type_bits(e.c, type)

	is_zero := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, 0", is_zero, llvm, rhs)
	trap_if(e, is_zero, "div.zero")

	if !signed {
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = %s %s %s, %s", out, op == .Slash ? "udiv" : "urem", llvm, lhs, rhs)
		return out
	}

	minimum := bi_text(e.c, bi_neg(e.c, bi_pow2(e.c, bits - 1)))
	special_label := new_label(e, "div.special")
	normal_label := new_label(e, "div.normal")
	done_label := new_label(e, "div.done")

	is_min := temp(e)
	is_neg_one := temp(e)
	is_overflow := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, %s", is_min, llvm, lhs, minimum)
	fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, -1", is_neg_one, llvm, rhs)
	fmt.sbprintfln(&e.b, "  %s = and i1 %s, %s", is_overflow, is_min, is_neg_one)
	branch_if(e, is_overflow, special_label, normal_label)

	fmt.sbprintfln(&e.b, "%s:", special_label)
	e.terminated = false
	branch(e, done_label)

	fmt.sbprintfln(&e.b, "%s:", normal_label)
	e.terminated = false
	normal_value := temp(e)
	fmt.sbprintfln(&e.b, "  %s = %s %s %s, %s", normal_value, op == .Slash ? "sdiv" : "srem", llvm, lhs, rhs)
	branch(e, done_label)

	fmt.sbprintfln(&e.b, "%s:", done_label)
	e.terminated = false
	out := temp(e)
	special_value := op == .Slash ? minimum : "0"
	fmt.sbprintfln(
		&e.b,
		"  %s = phi %s [ %s, %%%s ], [ %s, %%%s ]",
		out, llvm, special_value, special_label, normal_value, normal_label,
	)
	return out
}

// design.md: a shift count at or beyond the operand's width is defined — zero,
// or the replicated sign bit for an arithmetic right shift. No out-of-range
// count reaches an LLVM shift instruction, where it would be poison.
@(private = "file")
emit_shift :: proc(e: ^Emitter, op: Token_Kind, type: Type_Id, signed: bool, count_type: Type_Id, lhs, rhs: string) -> string {
	llvm := llvm_type(e, type)
	bits := type_bits(e.c, type)
	count_llvm := llvm_type(e, count_type)
	count_bits := type_bits(e.c, count_type)

	// The comparison happens in the count's own width, before any truncation
	// could hide how large it was.
	oversized := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp uge %s %s, %d", oversized, count_llvm, rhs, bits)

	count := rhs
	if count_bits != bits {
		converted := temp(e)
		operation := count_bits > bits ? "trunc" : "zext"
		fmt.sbprintfln(&e.b, "  %s = %s %s %s to %s", converted, operation, count_llvm, rhs, llvm)
		count = converted
	}

	if op == .Shr && signed {
		// Clamping to width-1 is the limit of the repeated one-bit shift.
		clamped := temp(e)
		fmt.sbprintfln(&e.b, "  %s = select i1 %s, %s %d, %s %s", clamped, oversized, llvm, bits - 1, llvm, count)
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = ashr %s %s, %s", out, llvm, lhs, clamped)
		return out
	}

	safe := temp(e)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, %s 0, %s %s", safe, oversized, llvm, llvm, count)
	raw := temp(e)
	fmt.sbprintfln(&e.b, "  %s = %s %s %s, %s", raw, op == .Shl ? "shl" : "lshr", llvm, lhs, safe)
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, %s 0, %s %s", out, oversized, llvm, llvm, raw)
	return out
}

@(private = "file")
emit_compare :: proc(e: ^Emitter, op: Token_Kind, type: Type_Id, lhs, rhs: string) -> string {
	if type_is_aggregate(e.c, type) {
		equal := emit_equal(e, type, lhs, rhs)
		if op == .Eq_Eq {
			return equal
		}
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = xor i1 %s, true", out, equal)
		return out
	}
	llvm := llvm_type(e, type)
	out := temp(e)
	if type_is_float(e.c, type) {
		// Ordered comparisons, so a NaN operand compares false — except `!=`,
		// which is true whenever the operands are unordered.
		name := ""
		#partial switch op {
		case .Eq_Eq:
			name = "oeq"
		case .Not_Eq:
			name = "une"
		case .Lt:
			name = "olt"
		case .Lt_Eq:
			name = "ole"
		case .Gt:
			name = "ogt"
		case .Gt_Eq:
			name = "oge"
		}
		fmt.sbprintfln(&e.b, "  %s = fcmp %s %s %s, %s", out, name, llvm, lhs, rhs)
		return out
	}
	signed := type_signed(e.c, type) || type_is_rune(e.c, type)
	name := ""
	#partial switch op {
	case .Eq_Eq:
		name = "eq"
	case .Not_Eq:
		name = "ne"
	case .Lt:
		name = signed ? "slt" : "ult"
	case .Lt_Eq:
		name = signed ? "sle" : "ule"
	case .Gt:
		name = signed ? "sgt" : "ugt"
	case .Gt_Eq:
		name = signed ? "sge" : "uge"
	}
	fmt.sbprintfln(&e.b, "  %s = icmp %s %s %s, %s", out, name, llvm, lhs, rhs)
	return out
}

// LLVM has no aggregate `icmp`, so structural equality is generated: each
// operand is evaluated once, and the leaf comparisons are combined.
//
// ponytail: one flat `and` chain rather than short-circuiting blocks. Every leaf
// is a pure `extractvalue` plus `icmp`/`fcmp`, so skipping them is unobservable,
// and a chain of N blocks would be worse IR than N ands. Revisit if a measured
// comparison of a very large array shows up.
@(private = "file")
emit_equal :: proc(e: ^Emitter, type: Type_Id, lhs, rhs: string) -> string {
	under := type_underlying(e.c, type)
	info := type_of(e.c, under)
	if info == nil {
		return "true"
	}
	#partial switch info.kind {
	case .Array:
		result := "true"
		for index in 0 ..< int(info.count) {
			left := extract(e, under, lhs, index)
			right := extract(e, under, rhs, index)
			leaf := emit_equal(e, info.element, left, right)
			result = combine_and(e, result, leaf)
		}
		return result
	case .Struct:
		result := "true"
		for field, index in info.fields {
			symbol := symbol_of(e.c, field)
			left := extract(e, under, lhs, index)
			right := extract(e, under, rhs, index)
			leaf := emit_equal(e, symbol.type, left, right)
			result = combine_and(e, result, leaf)
		}
		return result
	}
	return emit_compare(e, .Eq_Eq, type, lhs, rhs)
}

@(private = "file")
extract :: proc(e: ^Emitter, aggregate_type: Type_Id, value: string, index: int) -> string {
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", out, llvm_type(e, aggregate_type), value, index)
	return out
}

@(private = "file")
combine_and :: proc(e: ^Emitter, a, b: string) -> string {
	if a == "true" {
		return b
	}
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = and i1 %s, %s", out, a, b)
	return out
}

@(private = "file")
emit_short_circuit :: proc(e: ^Emitter, v: ^Expr_Binary) -> string {
	lhs := emit_expr(e, v.lhs)
	rhs_label := new_label(e, "sc.rhs")
	done_label := new_label(e, "sc.done")
	entry_label := new_label(e, "sc.entry")

	// The incoming edge needs a name of its own for the phi, and the left
	// operand may itself have created blocks.
	branch(e, entry_label)
	fmt.sbprintfln(&e.b, "%s:", entry_label)
	e.terminated = false
	if v.op == .And_And {
		branch_if(e, lhs, rhs_label, done_label)
	} else {
		branch_if(e, lhs, done_label, rhs_label)
	}

	fmt.sbprintfln(&e.b, "%s:", rhs_label)
	e.terminated = false
	rhs := emit_expr(e, v.rhs)
	rhs_exit := new_label(e, "sc.rhs.exit")
	branch(e, rhs_exit)
	fmt.sbprintfln(&e.b, "%s:", rhs_exit)
	e.terminated = false
	branch(e, done_label)

	fmt.sbprintfln(&e.b, "%s:", done_label)
	e.terminated = false
	out := temp(e)
	short := v.op == .And_And ? "false" : "true"
	fmt.sbprintfln(
		&e.b,
		"  %s = phi i1 [ %s, %%%s ], [ %s, %%%s ]",
		out, short, entry_label, rhs, rhs_exit,
	)
	return out
}

@(private = "file")
emit_cond :: proc(e: ^Emitter, v: ^Expr_Cond) -> string {
	cond := emit_expr(e, v.cond)
	then_label := new_label(e, "cond.then")
	else_label := new_label(e, "cond.else")
	done_label := new_label(e, "cond.done")
	branch_if(e, cond, then_label, else_label)

	fmt.sbprintfln(&e.b, "%s:", then_label)
	e.terminated = false
	then_value := emit_expr(e, v.then)
	then_exit := new_label(e, "cond.then.exit")
	branch(e, then_exit)
	fmt.sbprintfln(&e.b, "%s:", then_exit)
	e.terminated = false
	branch(e, done_label)

	fmt.sbprintfln(&e.b, "%s:", else_label)
	e.terminated = false
	else_value := emit_expr(e, v.otherwise)
	else_exit := new_label(e, "cond.else.exit")
	branch(e, else_exit)
	fmt.sbprintfln(&e.b, "%s:", else_exit)
	e.terminated = false
	branch(e, done_label)

	fmt.sbprintfln(&e.b, "%s:", done_label)
	e.terminated = false
	out := temp(e)
	fmt.sbprintfln(
		&e.b,
		"  %s = phi %s [ %s, %%%s ], [ %s, %%%s ]",
		out, llvm_type(e, v.type), then_value, then_exit, else_value, else_exit,
	)
	return out
}

// ------------------------------------------------------------------- calls --

@(private = "file")
emit_call :: proc(e: ^Emitter, v: ^Expr_Call) -> string {
	if v.resolution.kind == .Conversion {
		return emit_conversion(e, v)
	}
	symbol := symbol_of(e.c, v.resolution.symbol)
	if symbol != nil && symbol.kind == .Builtin {
		switch symbol.builtin {
		case .Print_Int:
			arg := emit_expr(e, v.bound[0])
			out := temp(e)
			fmt.sbprintfln(&e.b, "  %s = call i32 (ptr, ...) @printf(ptr @.fmt_int, i64 %s)", out, arg)
			return "0"
		case .Assert:
			// The runtime half of a phase-neutral built-in: the message is
			// compile-time-only until the seed runtime lands (M6), so a failed
			// assertion takes the same trap seam as every other defined runtime
			// failure.
			cond := emit_expr(e, v.bound[0])
			failed := temp(e)
			fmt.sbprintfln(&e.b, "  %s = xor i1 %s, true", failed, cond)
			trap_if(e, failed, "assert.failed")
			return "0"
		case .Panic:
			emit_trap(e)
			return "0"
		case .None, .Size_Of, .Align_Of, .Offset_Of, .Len:
			// These fold to a constant in every reachable case; arriving here
			// would mean emitting `print_int` for a layout query.
			panic("a built-in the checker did not fold reached the backend")
		}
	}
	results := emit_multi_call(e, v)
	return len(results) == 0 ? "0" : results[0]
}

// Emits the call and returns one operand per result.
@(private = "file")
emit_multi_call :: proc(e: ^Emitter, v: ^Expr_Call) -> []string {
	callee_type := type_of(e.c, type_underlying(e.c, expr_base(v.callee).type))
	symbol := symbol_of(e.c, v.resolution.symbol)

	callee := ""
	if symbol != nil && symbol.kind == .Proc {
		callee = e.names[v.resolution.symbol] or_else "null"
	} else {
		callee = emit_expr(e, v.callee)
		// A procedure value may be nil; the call takes the same trap seam every
		// other defined runtime failure does.
		is_nil := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", is_nil, callee)
		trap_if(e, is_nil, "nil.call")
	}

	// Arguments are bound left to right. A default that names a parameter to its
	// left reads the value bound a moment ago, which is why this map exists.
	outer_params := e.param_values
	e.param_values = make(map[Symbol_Id]string)
	defer {
		delete(e.param_values)
		e.param_values = outer_params
	}

	operands := make([]string, len(v.bound))
	for argument, index in v.bound {
		mode := index < len(callee_type.param_modes) ? callee_type.param_modes[index] : Param_Mode.Value
		if mode == .Inout {
			operands[index] = emit_address(e, argument)
		} else {
			operands[index] = emit_expr(e, argument)
		}
		if symbol != nil && index < len(symbol.param_symbols) && symbol.param_symbols[index] != INVALID_SYMBOL {
			e.param_values[symbol.param_symbols[index]] = operands[index]
		}
	}

	result_type := llvm_result_type(e, callee_type.results)
	call := ""
	if len(callee_type.results) > 0 {
		call = temp(e)
		fmt.sbprintf(&e.b, "  %s = call %s %s(", call, result_type, callee)
	} else {
		fmt.sbprintf(&e.b, "  call void %s(", callee)
	}
	for operand, index in operands {
		if index > 0 {
			fmt.sbprint(&e.b, ", ")
		}
		mode := index < len(callee_type.param_modes) ? callee_type.param_modes[index] : Param_Mode.Value
		type := mode == .Inout ? "ptr" : llvm_type(e, callee_type.parameters[index])
		fmt.sbprintf(&e.b, "%s %s", type, operand)
	}
	fmt.sbprintln(&e.b, ")")

	switch len(callee_type.results) {
	case 0:
		return nil
	case 1:
		single := make([]string, 1)
		single[0] = call
		return single
	}
	results := make([]string, len(callee_type.results))
	for index in 0 ..< len(callee_type.results) {
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", out, result_type, call, index)
		results[index] = out
	}
	return results
}

@(private = "file")
emit_conversion :: proc(e: ^Emitter, v: ^Expr_Call) -> string {
	source_expr := v.bound[0]
	source := expr_base(source_expr).type
	target := v.type
	value := emit_expr(e, source_expr)

	from := type_underlying(e.c, source)
	to := type_underlying(e.c, target)
	if llvm_type(e, from) == llvm_type(e, to) {
		return value
	}

	from_float := type_is_float(e.c, from)
	to_float := type_is_float(e.c, to)
	from_bits, to_bits := type_bits(e.c, from), type_bits(e.c, to)
	from_signed := type_signed(e.c, from) || type_is_rune(e.c, from)
	to_signed := type_signed(e.c, to) || type_is_rune(e.c, to)

	operation := ""
	switch {
	case from_float && to_float:
		operation = from_bits > to_bits ? "fptrunc" : "fpext"
	case from_float:
		operation = to_signed ? "fptosi" : "fptoui"
	case to_float:
		operation = from_signed ? "sitofp" : "uitofp"
	case from_bits > to_bits:
		operation = "trunc"
	case from_bits < to_bits:
		operation = from_signed ? "sext" : "zext"
	case:
		return value
	}
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = %s %s %s to %s", out, operation, llvm_type(e, from), value, llvm_type(e, to))
	return out
}

// ------------------------------------------------------------------ naming --

// Every user symbol carries its package's logical key, so two packages with the
// same declared name and the same source-level symbols still emit distinct
// working symbols (m3-plan decision "Symbol mangling"). The root package's key
// is empty, which is what keeps its entry procedure at a fixed name.
@(private = "file")
llvm_global_name :: proc(pkg: ^Package, name: string) -> string {
	return fmt.aprintf("@loke.g.%s%s", mangled_key(pkg), name)
}

@(private = "file")
llvm_proc_name :: proc(pkg: ^Package, name: string) -> string {
	return fmt.aprintf("@loke.p.%s%s", mangled_key(pkg), name)
}

// Encode every UTF-8 byte as two hex digits. A substitution such as `/` -> `.`
// is not injective (`a-b`, `a.b`, and `a/b` would collide), while fixed-width
// hex keeps distinct logical package identities distinct and LLVM-safe.
@(private = "file")
mangled_key :: proc(pkg: ^Package) -> string {
	if pkg == nil || pkg.key == "" {
		return ""
	}
	hex := "0123456789abcdef"
	out := make([]u8, len(pkg.key) * 2 + 1)
	for i in 0 ..< len(pkg.key) {
		ch := pkg.key[i]
		out[i * 2] = hex[ch >> 4]
		out[i * 2 + 1] = hex[ch & 0x0f]
	}
	out[len(out) - 1] = '.'
	return string(out)
}

@(private = "file")
entry_symbol :: proc(c: ^Compiler) -> Symbol_Id {
	pkg := package_of(c, c.root_package)
	if pkg == nil || pkg.scope == nil {
		return INVALID_SYMBOL
	}
	return lookup_symbol(pkg.scope, intern_identifier(c, "main"))
}

@(private = "file")
replace_ext :: proc(path: string, ext: string) -> string {
	if i := strings.last_index_byte(path, '.'); i >= 0 {
		return strings.concatenate({path[:i], ext})
	}
	return strings.concatenate({path, ext})
}

// clang does llc + link + CRT startup in one process (decision A5, A7). It
// finds the Windows SDK itself, but computes a relative, unusable
// VCToolsInstallDir unless it is run from a developer prompt — so the CRT
// import libraries are located here.
@(private = "file")
link :: proc(c: ^Compiler, ll_path: string, exe_path: string) -> int {
	clang := find_clang()

	command := make([dynamic]string)
	append(&command, clang, ll_path, "-o", exe_path)
	// The module states its triple; clang's default carries an MSVC version
	// suffix, and the mismatch is not interesting.
	append(&command, "-Wno-override-module")
	// `f16` arithmetic lowers to the compiler-rt conversion helpers
	// (`__extendhfsf2`, `__truncsfhf2`) on x86-64 without F16C, and the MSVC CRT
	// does not provide them.
	append(&command, "-rtlib=compiler-rt")
	if lib := msvc_lib_dir(); lib != "" {
		append(&command, "-L", lib)
	}

	state, _, stderr, err := os2.process_exec(
		os2.Process_Desc{command = command[:]},
		context.allocator,
	)
	if err != nil {
		errorf(
			c,
			no_span(),
			"L0402",
			"cannot run `%s`: install LLVM (`winget install LLVM.LLVM`) or set LOKE_CLANG",
			clang,
		)
		return 2
	}
	if state.exit_code != 0 {
		errorf(c, no_span(), "L0403", "`%s` failed:\n%s", clang, string(stderr))
		return 2
	}
	return 0
}

@(private = "file")
find_clang :: proc() -> string {
	if configured := os2.get_env("LOKE_CLANG", context.allocator); configured != "" {
		return configured
	}
	candidates := []string {
		`C:\Program Files\LLVM\bin\clang.exe`,
		`C:\Program Files (x86)\LLVM\bin\clang.exe`,
	}
	for candidate in candidates {
		if os.is_file(candidate) {
			return candidate
		}
	}
	return "clang"
}

// The MSVC toolset's `lib\x64`, or "" when there is nothing to add: a developer
// prompt has already put it in LIB, which lld-link honours.
//
// ponytail: a glob and a string compare instead of vswhere.exe. Picks the
// lexically greatest toolset, which orders real MSVC version numbers correctly
// today. Switch to vswhere if that ever stops holding, or if a build needs a
// specific toolset.
@(private = "file")
msvc_lib_dir :: proc() -> string {
	if os2.get_env("LIB", context.allocator) != "" {
		return ""
	}

	best := ""
	patterns := []string {
		`C:\Program Files\Microsoft Visual Studio\*\*\VC\Tools\MSVC\*\lib\x64`,
		`C:\Program Files (x86)\Microsoft Visual Studio\*\*\VC\Tools\MSVC\*\lib\x64`,
	}
	for pattern in patterns {
		matches, err := filepath.glob(pattern)
		if err != nil {
			continue
		}
		for match in matches {
			if match > best {
				best = match
			}
		}
	}
	return best
}

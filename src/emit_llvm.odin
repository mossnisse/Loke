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
// One registered cleanup action. design.md gives explicit `defer` and the
// implicit drop of a managed local one reverse registration order, so they share
// one entry and one stack rather than the second mechanism a parallel list would
// be (m5a-plan decision "Drop/defer ordering").
//
// `flag` is empty when the CFG proved the slot reached unconditionally: no
// source or ABI rule requires a flag, so a definite state does not get one.
Deferred :: struct {
	flag: string,
	// A written `defer`, or nil for an implicit drop of `place`.
	stmt:  Stmt,
	place: string,
	type:  Type_Id,
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
	// Which results were declared `inout`. Such a result is returned as the
	// address of a place, which is what makes `grid[i] = v` an ordinary store.
	result_inout: []bool,
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
	// Registered during checking, so every use already knows its name.
	emit_materialized_constants(&e)

	// One module, in deterministic dependency order. Every procedure in every
	// package is named before any body is emitted: a cross-package call, a
	// procedure value, and a hoisted literal all need final names first.
	order := package_order(c)
	for id in order {
		name_package_symbols(&e, package_of(c, id))
	}
	name_synth_procs(&e)
	for id in order {
		emit_package_items(&e, package_of(c, id))
	}
	emit_synth_procs(&e)
	emit_crt_reset_thunk(&e)
	emit_witnesses(&e)
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
			#partial switch v in item {
			case ^Decl:
				// A template has no signature and no body of its own; only its
				// instances are named and emitted.
				if decl_proc_literal(v) != nil && len(v.symbols) > 0 && !symbol_is_template(e.c, v.symbols[0]) {
					e.names[v.symbols[0]] = llvm_proc_name(pkg, v.names[0].text)
				}
			case ^Item_Impl:
				// A method is an ordinary procedure under a type-qualified name.
				for member in v.members {
					d, is_decl := member.(^Decl)
					if !is_decl || decl_proc_literal(d) == nil || len(d.symbols) == 0 {
						continue
					}
					sym := symbol_of(e.c, d.symbols[0])
					if sym == nil {
						continue
					}
					e.names[d.symbols[0]] = llvm_proc_name(pkg, llvm_safe(qualified_member_name(e.c, sym)))
				}
			}
		}
	}
	for literal, index in pkg.hoisted_procs {
		e.names[literal.symbol] = llvm_proc_name(pkg, fmt.aprintf("lambda.%d", index))
	}
	// Instantiations are named with their own package's symbols, in deterministic
	// instantiation order, so a cross-package generic call has a final name
	// before any body is written (m4b-plan decision "Emission order").
	for instance in pkg.instances {
		e.names[instance.symbol] = llvm_proc_name(pkg, llvm_safe(instance.name))
	}
}

// The compiler-contributed `iter` and `next` are compilation-global rather than
// package-owned, so they are named with the ordinary symbols and emitted after
// every package's items.
@(private = "file")
name_synth_procs :: proc(e: ^Emitter) {
	for symbol_id in e.c.synth_procs {
		symbol := symbol_of(e.c, symbol_id)
		if symbol == nil {
			continue
		}
		e.names[symbol_id] = fmt.aprintf("@loke.i.%s", llvm_safe(qualified_member_name(e.c, symbol)))
	}
}

@(private = "file")
symbol_is_template :: proc(c: ^Compiler, symbol_id: Symbol_Id) -> bool {
	sym := symbol_of(c, symbol_id)
	return sym != nil && sym.generic
}

@(private = "file")
emit_package_items :: proc(e: ^Emitter, pkg: ^Package) {
	if pkg == nil {
		return
	}
	for file in pkg.files {
		for item in file.active_items {
			if d, ok := item.(^Decl); ok && decl_proc_literal(d) == nil {
				emit_global(e, pkg, d)
			}
		}
	}
	for file in pkg.files {
		for item in file.active_items {
			#partial switch v in item {
			case ^Decl:
				if len(v.symbols) == 0 || symbol_is_template(e.c, v.symbols[0]) {
					continue
				}
				if literal := decl_proc_literal(v); literal != nil {
					emit_proc(e, v.symbols[0], literal)
				}
			case ^Item_Impl:
				for member in v.members {
					d, is_decl := member.(^Decl)
					if !is_decl || len(d.symbols) == 0 {
						continue
					}
					if literal := decl_proc_literal(d); literal != nil {
						emit_proc(e, d.symbols[0], literal)
					}
				}
			}
		}
	}
	for literal in pkg.hoisted_procs {
		emit_proc(e, literal.symbol, literal)
	}
	for instance in pkg.instances {
		if literal := decl_proc_literal(instance.decl); literal != nil {
			emit_proc(e, instance.symbol, literal)
		}
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
	// design.md "Allocators": M5a has one provider, the C runtime. `calloc` is
	// what makes `new` zero-initialised without a second memset. M6 replaces this
	// with a real provider table behind `mem.default_allocator()`.
	fmt.sbprintln(&e.b, "declare ptr @calloc(i64, i64)")
	fmt.sbprintln(&e.b, "declare ptr @malloc(i64)")
	fmt.sbprintln(&e.b, "declare void @free(ptr)")
	// The one provider handle an M5a `Allocator` value denotes. Its single slot is
	// the region-reset entry, which traps: this provider has no reset support, a
	// different thing from M5b's "unsafe while the region has live dependants".
	fmt.sbprintfln(&e.b, "%s = private unnamed_addr constant [1 x ptr] [ ptr %s ]", CRT_ALLOCATOR_GLOBAL, CRT_RESET_THUNK)
	fmt.sbprintln(&e.b, "")
}

// The default CRT provider handle, and its trapping reset entry.
CRT_ALLOCATOR_GLOBAL :: "@.crt_allocator"
CRT_RESET_THUNK :: "@.crt_allocator.reset"

@(private = "file")
emit_crt_reset_thunk :: proc(e: ^Emitter) {
	// `{` is a format directive to core:fmt, so the brace is printed separately.
	fmt.sbprintf(&e.b, "define private void %s()", CRT_RESET_THUNK)
	fmt.sbprintln(&e.b, " {")
	fmt.sbprintln(&e.b, "entry:")
	emit_trap(e)
	fmt.sbprintln(&e.b, "  ret void")
	fmt.sbprintln(&e.b, "}")
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
	case .Bool, .Int, .Float, .Rune, .Raw_Pointer, .Pointer, .Proc, .Enum, .Array, .Struct,
	     .Distinct, .Union, .Slice, .Allocator, .Allocator_Error:
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
	if info == nil || emitted[type] {
		return
	}
	// A generic record's own shell is a placeholder for its instances and has no
	// layout of its own.
	if sym := symbol_of(e.c, info.symbol); sym != nil && sym.generic {
		emitted[type] = true
		return
	}
	if info.kind == .Union {
		if !type_is_supported(e.c, type) {
			return
		}
		emitted[type] = true
		fmt.sbprintfln(&e.b, "%s = type %s", struct_name(e, type), union_storage_definition(e, type))
		return
	}
	if info.kind == .Slice {
		// Only the read-only variant is defined; `[]mut T` shares its name.
		if !type_is_supported(e.c, type) || slice_abi_type(e.c, type) != type {
			return
		}
		ensure_slice_fields(e.c, type)
		info = type_of(e.c, type)
	} else if info.kind != .Struct && info.kind != .Any_View && info.kind != .Dyn {
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
struct_name :: proc(e: ^Emitter, raw: Type_Id) -> string {
	// Both slice capabilities share one backend type, so `[]mut T` weakening to
	// `[]T` is the no-op the design says it is.
	type := slice_abi_type(e.c, raw)
	if name, ok := e.struct_names[type]; ok {
		return name
	}
	info := type_of(e.c, type)
	prefix := info != nil && info.kind == .Union ? "union" : "struct"
	name := ""
	if info != nil && (info.mangled != "" || info.name != INVALID_IDENTIFIER) {
		// An instantiation carries its own backend spelling; a written name may
		// still mention punctuation LLVM would need quoting for.
		text := info.mangled
		if text == "" {
			text = identifier_text(e.c, info.name)
			if !llvm_plain_name(text) {
				text = llvm_safe(text)
			}
		}
		name = fmt.aprintf("%%%s.%s.%d", prefix, text, int(type))
	} else {
		name = fmt.aprintf("%%%s.anon.%d", prefix, int(type))
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
	case .Int, .Enum, .Allocator_Error:
		return fmt.aprintf("i%d", type_bits(e.c, under))
	case .Typeid:
		// design.md: an ordinary runtime scalar holding one concrete type's unique
		// identifier. Zero is nil.
		return "i64"
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
	case .Pointer, .Raw_Pointer, .Proc, .Allocator:
		// An `Allocator` is a one-word handle on the single default provider.
		return "ptr"
	case .Array:
		return fmt.aprintf("[%d x %s]", info.count, llvm_type(e, info.element))
	case .Struct, .Union, .Any_View, .Dyn, .Slice:
		// A two-word erased view or slice is an ordinary aggregate to the backend.
		return struct_name(e, under)
	}
	return "i64"
}

// The union storage type, built so LLVM's own layout matches the checker's
// cached facts: an alignment-carrying payload head, explicit payload padding,
// the tag, and tail padding. A bare `[N x i8]` payload would be byte-aligned,
// which is wrong wherever a union is allocated directly, nested in a struct, or
// used as an array element.
@(private = "file")
union_storage_definition :: proc(e: ^Emitter, type: Type_Id) -> string {
	shape := union_layout(e.c, type)
	b := strings.builder_make()
	strings.write_string(&b, "{ ")
	fmt.sbprintf(&b, "i%d", shape.align * 8)
	if pad := shape.payload_size - shape.align; pad > 0 {
		fmt.sbprintf(&b, ", [%d x i8]", pad)
	}
	if gap := shape.tag_offset - shape.payload_size; gap > 0 {
		fmt.sbprintf(&b, ", [%d x i8]", gap)
	}
	fmt.sbprintf(&b, ", i%d", shape.tag_bytes * 8)
	if tail := shape.size - shape.tag_offset - shape.tag_bytes; tail > 0 {
		fmt.sbprintf(&b, ", [%d x i8]", tail)
	}
	strings.write_string(&b, " }")
	return strings.to_string(b)
}

// A variant value becoming a union value: zero the storage, write the payload
// through a typed pointer, then write the tag.
@(private = "file")
emit_union_value :: proc(e: ^Emitter, union_type, variant: Type_Id, value: string) -> string {
	slot := emit_union_slot(e, union_type, variant, value)
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", out, llvm_type(e, union_type), slot)
	return out
}

@(private = "file")
emit_union_slot :: proc(e: ^Emitter, union_type, variant: Type_Id, value: string) -> string {
	llvm := llvm_type(e, union_type)
	slot := temp(e)
	fmt.sbprintfln(&e.b, "  %s = alloca %s", slot, llvm)
	fmt.sbprintfln(&e.b, "  store %s zeroinitializer, ptr %s", llvm, slot)
	payload := temp(e)
	fmt.sbprintfln(&e.b, "  %s = getelementptr inbounds %s, ptr %s, i32 0, i32 0", payload, llvm, slot)
	fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", llvm_type(e, variant), value, payload)
	emit_union_store_tag(e, union_type, slot, union_variant_tag(e.c, union_type, variant))
	return slot
}

@(private = "file")
emit_union_store_tag :: proc(e: ^Emitter, union_type: Type_Id, slot: string, tag: int) {
	llvm := llvm_type(e, union_type)
	shape := union_layout(e.c, union_type)
	address := temp(e)
	fmt.sbprintfln(
		&e.b,
		"  %s = getelementptr inbounds %s, ptr %s, i32 0, i32 %d",
		address, llvm, slot, union_tag_member(e, union_type),
	)
	fmt.sbprintfln(&e.b, "  store i%d %d, ptr %s", shape.tag_bytes * 8, tag, address)
}

// The tag of a union *value*, which is what every assertion and type switch
// tests.
@(private = "file")
emit_union_tag :: proc(e: ^Emitter, union_type: Type_Id, value: string) -> string {
	out := temp(e)
	fmt.sbprintfln(
		&e.b,
		"  %s = extractvalue %s %s, %d",
		out, llvm_type(e, union_type), value, union_tag_member(e, union_type),
	)
	return out
}

// Spills a union value so its payload can be read at a variant's own type.
@(private = "file")
emit_union_spill :: proc(e: ^Emitter, union_type: Type_Id, value: string) -> string {
	llvm := llvm_type(e, union_type)
	slot := temp(e)
	fmt.sbprintfln(&e.b, "  %s = alloca %s", slot, llvm)
	fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", llvm, value, slot)
	return slot
}

@(private = "file")
emit_union_payload :: proc(e: ^Emitter, union_type, variant: Type_Id, slot: string) -> string {
	payload := temp(e)
	fmt.sbprintfln(
		&e.b,
		"  %s = getelementptr inbounds %s, ptr %s, i32 0, i32 0",
		payload, llvm_type(e, union_type), slot,
	)
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", out, llvm_type(e, variant), payload)
	return out
}

// Which member of that storage type holds the tag.
@(private = "file")
union_tag_member :: proc(e: ^Emitter, type: Type_Id) -> int {
	shape := union_layout(e.c, type)
	index := 1
	if shape.payload_size > shape.align {
		index += 1
	}
	if shape.tag_offset > shape.payload_size {
		index += 1
	}
	return index
}

// The internal convention for several results: one anonymous literal struct,
// used consistently by caller and callee. This is not the frozen Loke or C ABI
// (m2-plan shortcut table); M7 replaces it.
@(private = "file")
llvm_result_type :: proc(e: ^Emitter, results: []Type_Id, inout: []bool = nil) -> string {
	// An `inout` result is a place, so it travels as its address.
	slot :: proc(e: ^Emitter, results: []Type_Id, inout: []bool, index: int) -> string {
		if index < len(inout) && inout[index] {
			return "ptr"
		}
		return llvm_type(e, results[index])
	}
	switch len(results) {
	case 0:
		return "void"
	case 1:
		return slot(e, results, inout, 0)
	}
	b := strings.builder_make()
	strings.write_string(&b, "{ ")
	for _, index in results {
		if index > 0 {
			strings.write_string(&b, ", ")
		}
		strings.write_string(&b, slot(e, results, inout, index))
	}
	strings.write_string(&b, " }")
	return strings.to_string(b)
}

@(private = "file")
result_inout_of :: proc(e: ^Emitter, proc_type: Type_Id) -> []bool {
	info := type_of(e.c, proc_type)
	return info == nil ? nil : info.result_inout
}

@(private = "file")
emit_result_is_inout :: proc(e: ^Emitter, index: int) -> bool {
	return index < len(e.result_inout) && e.result_inout[index]
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
	case .Typeid:
		// Symbolic during checking, numeric here: `freeze_typeids` has assigned a
		// deterministic value to every requested type before any body is emitted.
		return fmt.aprintf("%d", typeid_value(e.c, value.type_value))
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
	case .Pointer, .Raw_Pointer, .Proc, .Allocator:
		return "null"
	case .Allocator_Error:
		// Nil is success, and success is zero.
		return value.kind == .Nil ? "0" : bi_text(e.c, value.integer)
	case .Union:
		// The only constant of a union or an erased view is its zero value; every
		// other one is built at run time.
		return "zeroinitializer"
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
	case .Struct, .Any_View, .Dyn, .Slice:
		if value.kind == .Nil {
			return "zeroinitializer"
		}
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
	e.result_inout = result_inout_of(e, symbol.proc_type)
	e.result_slots = make([]string, len(symbol.results))
	e.terminated = false
	clear(&e.cleanups)

	fmt.sbprintf(&e.b, "define %s %s(", llvm_result_type(e, symbol.results, e.result_inout), llvm_name)
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
		if emit_result_is_inout(e, index) {
			// The slot holds the address of the place being handed back.
			fmt.sbprintfln(&e.b, "  %s = alloca ptr", slot)
			fmt.sbprintfln(&e.b, "  store ptr null, ptr %s", slot)
			e.result_slots[index] = slot
			if index < len(symbol.result_symbols) && symbol.result_symbols[index] != INVALID_SYMBOL {
				e.names[symbol.result_symbols[index]] = slot
			}
			continue
		}
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

	// design.md "Parameter semantics": a `move` parameter transfers ownership to
	// the callee, so the callee drops it. Its scope sits outside the body's,
	// which makes its cleanup the outermost one every exit replays.
	push_scope_stmts(e, nil)
	for parameter, index in symbol.params {
		_ = parameter
		if index < len(symbol.param_symbols) {
			register_implicit_drop(e, symbol.param_symbols[index])
		}
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
		case ^Decl:
			// A managed local's hidden flag reuses the same storage across loop
			// iterations, so it needs the same reset a written `defer` gets.
			for symbol_id in s.symbols {
				if flag := drop_flag_of(e, symbol_id); flag != "" {
					fmt.sbprintfln(&e.b, "  store i1 false, ptr %s", flag)
				}
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
			if entry.flag == "" {
				run_one_cleanup(e, entry)
				continue
			}
			flag := temp(e)
			fmt.sbprintfln(&e.b, "  %s = load i1, ptr %s", flag, entry.flag)
			run := new_label(e, "defer.run")
			skip := new_label(e, "defer.skip")
			branch_if(e, flag, run, skip)
			fmt.sbprintfln(&e.b, "%s:", run)
			e.terminated = false
			run_one_cleanup(e, entry)
			branch(e, skip)
			fmt.sbprintfln(&e.b, "%s:", skip)
			e.terminated = false
		}
	}
}

@(private = "file")
run_one_cleanup :: proc(e: ^Emitter, entry: Deferred) {
	if entry.stmt != nil {
		emit_stmt(e, entry.stmt)
		return
	}
	emit_drop_place(e, entry.type, entry.place)
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
			value := emit_expr(e, expr)
			emit_discarded_temporary(e, expr, value)
		}

	case ^Stmt_Assign:
		emit_assign(e, s)

	case ^Stmt_If:
		emit_if(e, s)

	case ^Stmt_For:
		emit_for(e, s)

	case ^Stmt_Switch:
		if s.kind == .Type {
			emit_type_switch(e, s)
		} else {
			emit_switch(e, s)
		}

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
		if s.kind == .Unresolved {
			// The checker's L0350 arm gates every statement missing here, so this
			// is a hole in that gate — and skipping it would emit a program that
			// silently does less than the source says.
			panic("a statement the checker did not gate reached the backend")
		}
		emit_foreach(e, s)
	}
}

@(private = "file")
emit_local_decl :: proc(e: ^Emitter, d: ^Decl) {
	// A call filling several names evaluates once.
	if len(d.values) == 1 && len(d.symbols) > 1 {
		if base := expr_base(d.values[0]); base != nil && len(base.result_types) == len(d.symbols) {
			results := emit_multi_value(e, d.values[0])
			for symbol_id, index in d.symbols {
				slot := declare_local(e, symbol_id)
				if slot != "" {
					store(e, base.result_types[index], results[index], slot)
					register_implicit_drop(e, symbol_id)
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
			value := emit_expr(e, d.values[i])
			if i < len(d.value_clones) && d.value_clones[i] {
				value = emit_clone_value(e, sym.type, value)
			}
			store(e, sym.type, value, slot)
			register_implicit_drop(e, symbol_id)
			continue
		}
		zero, ok := zero_const(e.c, sym.type)
		if ok {
			store(e, sym.type, llvm_const(e, zero, sym.type), slot)
		}
		register_implicit_drop(e, symbol_id)
	}
}

// design.md: "A managed local declaration places an implicit conditional
// `defer drop(value)` at the declaration point." Registration is what fixes its
// position in the one reverse order every exit replays.
@(private = "file")
register_implicit_drop :: proc(e: ^Emitter, symbol_id: Symbol_Id) {
	sym := symbol_of(e.c, symbol_id)
	if sym == nil {
		return
	}
	// The flag says "this place holds a value", which an assignment's drop reads
	// as well as cleanup, so it is set whenever one exists.
	flag := drop_flag_of(e, symbol_id)
	if flag != "" {
		fmt.sbprintfln(&e.b, "  store i1 true, ptr %s", flag)
	}
	if !sym.drop_at_exit || len(e.cleanups) == 0 {
		return
	}
	append(
		&e.cleanups[len(e.cleanups) - 1].entries,
		Deferred{flag = flag, place = e.names[symbol_id], type = sym.type},
	)
}

// The hidden `i1` of a conditionally live local, or "" when the CFG left its
// state definite at every cleanup point.
@(private = "file")
drop_flag_of :: proc(e: ^Emitter, symbol_id: Symbol_Id) -> string {
	sym := symbol_of(e.c, symbol_id)
	if sym == nil || !sym.drop_conditional || sym.cleanup_slot >= len(e.defer_flags) {
		return ""
	}
	return e.defer_flags[sym.cleanup_slot]
}

// `move(x)` and `drop(x)` both leave the source dead: the inert zero
// representation is written, and a conditional slot records that its cleanup
// must not run again.
@(private = "file")
kill_place :: proc(e: ^Emitter, symbol_id: Symbol_Id) {
	sym := symbol_of(e.c, symbol_id)
	if sym == nil {
		return
	}
	if zero, ok := zero_const(e.c, sym.type); ok {
		store(e, sym.type, llvm_const(e, zero, sym.type), e.names[symbol_id])
	}
	if flag := drop_flag_of(e, symbol_id); flag != "" {
		fmt.sbprintfln(&e.b, "  store i1 false, ptr %s", flag)
	}
}

// design.md "Storage modifiers": `drop(value)` "runs the cleanup operation,
// writes the inert zero representation, and marks the variable dead".
@(private = "file")
emit_explicit_drop :: proc(e: ^Emitter, v: ^Expr_Call) {
	ident, is_ident := v.bound[0].(^Expr_Ident)
	if !is_ident {
		panic("`drop` reached the backend without a named operand")
	}
	sym := symbol_of(e.c, ident.symbol)
	if sym == nil {
		return
	}
	emit_drop_place(e, sym.type, e.names[ident.symbol])
	kill_place(e, ident.symbol)
}

// design.md: an owning temporary nothing binds is still a completed
// initialization, so it is cleaned up exactly once.
//
// ponytail: dropped at its full-expression boundary rather than registered in
// the surrounding scope's reverse order. Nothing can name it, so the only
// observable difference is ordering against other cleanups — and registering it
// would drop one value per emitted statement rather than one per loop iteration.
@(private = "file")
emit_discarded_temporary :: proc(e: ^Emitter, expr: Expr, value: string) {
	base := expr_base(expr)
	if base == nil || !type_is_managed(e.c, base.type) {
		return
	}
	// A place names storage someone else owns; only an owned temporary is ours
	// to clean up.
	if expression_is_borrowed_place(e.c, expr) {
		return
	}
	slot := temp(e)
	fmt.sbprintfln(&e.b, "  %s = alloca %s", slot, llvm_type(e, base.type))
	store(e, base.type, value, slot)
	emit_drop_place(e, base.type, slot)
}

// design.md "Exchange": "The compiler evaluates the destination place once and
// then evaluates `replacement` completely before modifying the destination. If
// evaluation or construction of the replacement fails or panics, the destination
// remains unchanged. Once the replacement is ready, the compiler moves the old
// value into result storage and moves the replacement into the destination as one
// lifecycle operation."
//
// So the order below is the specification: address, replacement, load, store. No
// hook runs between the two moves — the old value is handed back rather than
// dropped, and the destination is never observably dead.
@(private = "file")
emit_exchange :: proc(e: ^Emitter, v: ^Expr_Call) -> string {
	address := emit_address(e, v.bound[0])
	replacement := emit_expr(e, v.bound[1])
	previous := temp(e)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", previous, llvm_type(e, v.type), address)
	store(e, v.type, replacement, address)
	return previous
}

// design.md "Assignment statements": `move` "transfers the representation,
// writes the inert zero representation to a lexical source, and marks that
// source dead".
@(private = "file")
emit_move :: proc(e: ^Emitter, v: ^Expr_Move) -> string {
	value := emit_expr(e, v.value)
	if ident, is_ident := v.value.(^Expr_Ident); is_ident {
		kill_place(e, ident.symbol)
	}
	return value
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
	// `operator([]=)`: a container with no location to hand out.
	if s.place_setter != INVALID_SYMBOL {
		emit_operator_call(e, s.place_setter, s.setter_bound)
		return
	}

	values: []string
	types: []Type_Id
	if len(s.rhs) == 1 && len(s.lhs) > 1 {
		values = emit_multi_value(e, s.rhs[0])
		types = expr_base(s.rhs[0]).result_types
	} else {
		values = make([]string, len(s.rhs))
		types = make([]Type_Id, len(s.rhs))
		for value, index in s.rhs {
			values[index] = emit_expr(e, value)
			// design.md: the clone happens before the destination is touched, so a
			// failure leaves a previously live destination unchanged.
			if index < len(s.rhs_clones) && s.rhs_clones[index] {
				values[index] = emit_clone_value(e, expr_base(s.lhs[index]).type, values[index])
			}
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
		emit_replace_place(e, s, index, addresses[index])
		store(e, expr_base(target).type, values[index], addresses[index])
	}
}

// design.md "Assignment statements": the assignment `drop(destination)` between
// a successful clone and the write. The destination's state decides whether it
// happens at all — a definitely dead one holds nothing, and a conditional one
// asks its hidden flag.
@(private = "file")
emit_replace_place :: proc(e: ^Emitter, s: ^Stmt_Assign, index: int, address: string) {
	target := s.lhs[index]
	type := expr_base(target).type
	if !type_is_managed(e.c, type) {
		return
	}
	state := index < len(s.destination_live) ? s.destination_live[index] : Liveness.Live
	if state == .Dead {
		return
	}
	flag := ""
	if ident, is_ident := target.(^Expr_Ident); is_ident {
		flag = drop_flag_of(e, ident.symbol)
	}
	if state == .Live || flag == "" {
		emit_drop_place(e, type, address)
	} else {
		live := temp(e)
		fmt.sbprintfln(&e.b, "  %s = load i1, ptr %s", live, flag)
		run, skip := new_label(e, "replace.drop"), new_label(e, "replace.done")
		branch_if(e, live, run, skip)
		place_label(e, run)
		emit_drop_place(e, type, address)
		branch(e, skip)
		place_label(e, skip)
	}
	// The place holds a value again from here.
	if ident, is_ident := target.(^Expr_Ident); is_ident && flag != "" {
		fmt.sbprintfln(&e.b, "  store i1 true, ptr %s", flag)
	}
}

// The destination is evaluated once, before the right operand.
@(private = "file")
emit_compound_assign :: proc(e: ^Emitter, s: ^Stmt_Assign) {
	target := s.lhs[0]
	if s.operator != INVALID_SYMBOL {
		operands := [2]Expr{target, s.rhs[0]}
		if s.operator_direct {
			// A direct `+=` overload writes through its `inout` destination.
			emit_operator_call(e, s.operator, operands[:])
			return
		}
		// The fallback: the binary operator, then an ordinary assignment.
		address := emit_address(e, target)
		value := emit_operator_call(e, s.operator, operands[:])
		store(e, expr_base(target).type, value, address)
		return
	}
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

// A type switch dispatches on the tag. Each case binds its own name: at the
// variant's type where one is known, and at the union's type where a case names
// several types or is the default.
@(private = "file")
emit_type_switch :: proc(e: ^Emitter, s: ^Stmt_Switch) {
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
	union_type := expr_base(s.subject).type
	// An `any_view` switch compares the stored `typeid` and reads through the
	// data pointer; a union switch compares its tag and reads its payload.
	erased := union_type == TYPE_ANY_VIEW
	tag_llvm := "i64"
	value := emit_expr(e, s.subject)
	slot := ""
	tag := ""
	if erased {
		storage := llvm_type(e, TYPE_ANY_VIEW)
		slot = temp(e)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", slot, storage, value, ANY_VIEW_DATA)
		tag = temp(e)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", tag, storage, value, ANY_VIEW_ID)
	} else {
		shape := union_layout(e.c, union_type)
		tag_llvm = fmt.aprintf("i%d", shape.tag_bytes * 8)
		slot = emit_union_spill(e, union_type, value)
		tag = emit_union_tag(e, union_type, value)
	}

	done := new_label(e, "typeswitch.done")
	e.break_label = done

	bodies := make([]string, len(s.cases))
	tests := make([]string, len(s.cases))
	for index in 0 ..< len(s.cases) {
		bodies[index] = new_label(e, "typecase.body")
		tests[index] = new_label(e, "typecase.test")
	}
	default_index := -1
	order := make([dynamic]int)
	defer delete(order)
	for entry, index in s.cases {
		if len(entry.values) == 0 {
			default_index = index
		} else {
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
		for variant_expr in s.cases[case_index].values {
			variant := expr_base(variant_expr).denoted_type
			test := temp(e)
			discriminant := erased ? typeid_value(e.c, variant) : u64(union_variant_tag(e.c, union_type, variant))
			fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, %d", test, tag_llvm, tag, discriminant)
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
		emit_type_case_binding(e, entry, union_type, value, slot, erased)
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
emit_type_case_binding :: proc(e: ^Emitter, entry: Switch_Case, union_type: Type_Id, value, slot: string, erased := false) {
	if entry.binding_symbol == INVALID_SYMBOL {
		return
	}
	binding := fmt.aprintf("%%bind.%d", next_id(e))
	fmt.sbprintfln(&e.b, "  %s = alloca %s", binding, llvm_type(e, entry.binding_type))
	e.names[entry.binding_symbol] = binding
	if erased {
		if entry.binding_type == union_type {
			fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", llvm_type(e, union_type), value, binding)
			return
		}
		// A concrete case reads the erased value through the data pointer.
		loaded := temp(e)
		fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", loaded, llvm_type(e, entry.binding_type), slot)
		store(e, entry.binding_type, loaded, binding)
		return
	}
	if entry.binding_type == union_type {
		fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", llvm_type(e, union_type), value, binding)
		return
	}
	payload := emit_union_payload(e, union_type, entry.binding_type, slot)
	store(e, entry.binding_type, payload, binding)
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
			if base := expr_base(s.values[0].expr); base != nil && len(base.result_types) == len(e.result_types) {
				results := emit_multi_value(e, s.values[0].expr)
				for value, index in results {
					store(e, e.result_types[index], value, e.result_slots[index])
				}
				emit_epilogue(e)
				return
			}
		}
		values := make([]string, len(s.values))
		for value, index in s.values {
			// An `inout` result hands back the place itself, not a copy of it.
			if emit_result_is_inout(e, index) {
				values[index] = emit_address(e, value.expr)
			} else {
				values[index] = emit_expr(e, value.expr)
			}
			if value.clone_on_return && index < len(e.result_types) {
				values[index] = emit_clone_value(e, e.result_types[index], values[index])
			}
		}
		for value, index in values {
			if index >= len(e.result_slots) {
				continue
			}
			if emit_result_is_inout(e, index) {
				fmt.sbprintfln(&e.b, "  store ptr %s, ptr %s", value, e.result_slots[index])
			} else {
				store(e, e.result_types[index], value, e.result_slots[index])
			}
		}
		// The result is in result storage before cleanup runs, so a transferred
		// local can be marked dead here without the epilogue dropping what was
		// just handed back (design.md "Managed values and storage").
		for value in s.values {
			if value.clone_on_return {
				continue
			}
			if ident, is_ident := value.expr.(^Expr_Ident); is_ident {
				if sym := symbol_of(e.c, ident.symbol); sym != nil && type_is_managed(e.c, sym.type) {
					kill_place(e, ident.symbol)
				}
			}
		}
	}
	emit_epilogue(e)
}

// design.md: an implicit copy — a binding, an assignment, or the return of a
// borrowed managed owner — goes through `clone`, the policy-following entry
// point. It calls `try_clone` once and applies the allocator's failure policy,
// which in M5a is the fixed trap, so a failure never reaches a half-written
// destination.
//
// ponytail: one provider, so the allocator is the CRT handle rather than the one
// the destination carries. M6 threads the destination's allocator and its `via`
// policy through here (m5a-plan "Failure fallback").
@(private = "file")
emit_clone_value :: proc(e: ^Emitter, type: Type_Id, value: string) -> string {
	hook := type_hook(e.c, type, "clone")
	if hook == INVALID_SYMBOL {
		panic("an implicit copy reached the backend without a `clone` member")
	}
	out := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call %s %s(%s %s, ptr %s)",
		out, llvm_type(e, type), e.names[hook], llvm_type(e, type), value, CRT_ALLOCATOR_GLOBAL,
	)
	return out
}

@(private = "file")
emit_epilogue :: proc(e: ^Emitter) {
	run_cleanups(e, 0)
	slot_type :: proc(e: ^Emitter, index: int) -> string {
		return emit_result_is_inout(e, index) ? "ptr" : llvm_type(e, e.result_types[index])
	}
	switch len(e.result_types) {
	case 0:
		fmt.sbprintln(&e.b, "  ret void")
	case 1:
		value := temp(e)
		fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", value, slot_type(e, 0), e.result_slots[0])
		fmt.sbprintfln(&e.b, "  ret %s %s", slot_type(e, 0), value)
	case:
		aggregate := "undef"
		result_type := llvm_result_type(e, e.result_types, e.result_inout)
		for _, index in e.result_types {
			value := temp(e)
			fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", value, slot_type(e, index), e.result_slots[index])
			next := temp(e)
			fmt.sbprintfln(
				&e.b,
				"  %s = insertvalue %s %s, %s %s, %d",
				next, result_type, aggregate, slot_type(e, index), value, index,
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
	// design.md "Materialization": every runtime use of one constant shares one
	// read-only object, so the address is the global the checker registered.
	if entry := materialization_of(e.c, expr); entry != nil {
		return entry.name
	}
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
		// An `operator([])` returning `inout T` hands back the address itself.
		if v.resolution.kind == .User_Operator {
			return emit_operator_call(e, v.resolution.symbol, v.bound)
		}
		// A slice element lives in the root, reached through the data word, and its
		// bound is the runtime length rather than a static count.
		if type_is_slice(e.c, expr_base(v.operand).type) {
			return emit_slice_element_address(e, v)
		}
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

// `s[i]`: the element's address inside the slice's root, bounds-checked against
// the runtime length word.
@(private = "file")
emit_slice_element_address :: proc(e: ^Emitter, v: ^Expr_Index) -> string {
	operand_type := expr_base(v.operand).type
	slice := emit_expr(e, v.operand)
	llvm := llvm_type(e, operand_type)
	data, length := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", data, llvm, slice, SLICE_DATA)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", length, llvm, slice, SLICE_LEN)

	index := widen_to_i64(e, emit_expr(e, v.indices[0]), expr_base(v.indices[0]).type)
	// Unsigned, so a negative index is caught by the same comparison as an
	// oversized one.
	out_of_range := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp uge i64 %s, %s", out_of_range, index, length)
	trap_if(e, out_of_range, "bounds")

	out := temp(e)
	fmt.sbprintfln(
		&e.b,
		"  %s = getelementptr inbounds %s, ptr %s, i64 %s",
		out, llvm_type(e, slice_element(e.c, operand_type)), data, index,
	)
	return out
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

// A built-in slice expression: `base[lo:hi]` over a fixed array or another
// slice. The base and both bounds are each evaluated once, in written order,
// then checked as `0 <= lo <= hi <= len` before any address is formed.
@(private = "file")
emit_builtin_slice :: proc(e: ^Emitter, v: ^Expr_Slice) -> string {
	operand_type := expr_base(v.operand).type
	info := type_of(e.c, type_underlying(e.c, operand_type))
	element := info.element

	data, length := "", ""
	if info.kind == .Slice {
		value := emit_expr(e, v.operand)
		llvm := llvm_type(e, operand_type)
		data, length = temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", data, llvm, value, SLICE_DATA)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", length, llvm, value, SLICE_LEN)
	} else {
		data = emit_address(e, v.operand)
		length = fmt.aprintf("%d", info.count)
	}

	low := "0"
	if v.lo != nil {
		low = widen_to_i64(e, emit_expr(e, v.lo), expr_base(v.lo).type)
	}
	high := length
	if v.hi != nil {
		high = widen_to_i64(e, emit_expr(e, v.hi), expr_base(v.hi).type)
	}

	// One trap seam for the whole range, so a reversed or oversized pair cannot
	// produce a slice with a negative or out-of-root length.
	reversed := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp ugt i64 %s, %s", reversed, low, high)
	past_end := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp ugt i64 %s, %s", past_end, high, length)
	bad := temp(e)
	fmt.sbprintfln(&e.b, "  %s = or i1 %s, %s", bad, reversed, past_end)
	trap_if(e, bad, "slice.bounds")

	// The result's data pointer is the low bound's address in the root, so
	// reslicing composes without a second base.
	start := temp(e)
	fmt.sbprintfln(
		&e.b,
		"  %s = getelementptr inbounds %s, ptr %s, i64 %s",
		start, llvm_type(e, element), data, low,
	)
	count := temp(e)
	fmt.sbprintfln(&e.b, "  %s = sub i64 %s, %s", count, high, low)

	result := llvm_type(e, v.type)
	first, out := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, ptr %s, %d", first, result, start, SLICE_DATA)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, i64 %s, %d", out, result, first, count, SLICE_LEN)
	return out
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
	// A variant value becoming a union value. The node is evaluated at the type
	// it actually produces, then payload and tag are written.
	// A concrete value becoming an `any_view`: its address plus the frozen
	// `typeid`. A non-addressable source gets compiler-owned temporary storage.
	if from := base.erased_from; from != INVALID_TYPE {
		target := base.type
		base.erased_from, base.type = INVALID_TYPE, from
		address := spill_iterable(e, expr)
		base.erased_from, base.type = from, target
		return emit_any_view_value(e, address, from)
	}
	if from := base.union_from; from != INVALID_TYPE {
		target := base.type
		base.union_from, base.type = INVALID_TYPE, from
		inner := emit_expr(e, expr)
		base.union_from, base.type = from, target
		return emit_union_value(e, target, from, inner)
	}
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

	case ^Expr_Slice:
		if v.resolution.kind == .User_Operator {
			return emit_operator_call(e, v.resolution.symbol, v.bound)
		}
		return emit_builtin_slice(e, v)

	case ^Expr_Postfix:
		if v.op == .Or_Return {
			results := emit_multi_value(e, expr)
			return len(results) == 0 ? "0" : results[0]
		}
		address := emit_address(e, expr)
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", out, llvm_type(e, base.type), address)
		return out

	case ^Expr_Selector, ^Expr_Index:
		// A user `operator([])`. A value overload produces the element; an `inout`
		// overload produces its address, which is then read through.
		if index, is_index := expr.(^Expr_Index); is_index && base.resolution.kind == .User_Operator {
			result := emit_operator_call(e, index.resolution.symbol, index.bound)
			if base.value_category != .Place {
				return result
			}
			out := temp(e)
			fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", out, llvm_type(e, base.type), result)
			return out
		}
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

	case ^Expr_Type_Assert, ^Expr_Or_Else:
		return emit_multi_value(e, expr)[0]

	case ^Expr_Composite:
		if v.backing != INVALID_TYPE {
			return emit_slice_literal(e, v)
		}
		slot := emit_address(e, expr)
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", out, llvm_type(e, v.type), slot)
		return out

	case ^Expr_Proc:
		if name, ok := e.names[v.symbol]; ok {
			return name
		}
		return "null"

	case ^Expr_Range:
		return emit_range_value(e, v)

	case ^Expr_Move:
		return emit_move(e, v)

	case ^Expr_Hash, ^Expr_Proc_Group, ^Expr_Operator,
	     ^Type_Pointer, ^Type_Multi_Pointer, ^Type_Slice, ^Type_Dynamic_Array,
	     ^Type_Array, ^Type_Map, ^Type_Distinct, ^Type_Dyn, ^Type_Type,
	     ^Type_Poly, ^Type_Proc, ^Type_Record, ^Type_Enum, ^Type_Interface:
	}
	// Same gate as `emit_stmt`: returning `0` here would compile silently and
	// produce the wrong answer.
	panic("an expression the checker did not gate reached the backend")
}

// design.md "Slice literals": "The backing array of a slice literal is a hidden
// fixed-array owner in the surrounding lexical scope, so the slice remains valid
// until that scope exits." The hidden root is filled, then viewed whole.
//
// ponytail: the root is an ordinary `alloca` at its use, exactly like a
// composite literal's temporary storage. A literal inside a loop therefore
// allocates per iteration; hoist to the entry block if a real program shows
// stack growth.
@(private = "file")
emit_slice_literal :: proc(e: ^Emitter, v: ^Expr_Composite) -> string {
	backing := v.backing
	info := type_of(e.c, backing)
	root := temp(e)
	fmt.sbprintfln(&e.b, "  %s = alloca %s", root, llvm_type(e, backing))

	for element, index in v.elements {
		slot := temp(e)
		fmt.sbprintfln(
			&e.b,
			"  %s = getelementptr inbounds %s, ptr %s, i64 0, i64 %d",
			slot, llvm_type(e, backing), root, index,
		)
		store(e, info.element, emit_expr(e, element.value), slot)
	}

	result := llvm_type(e, v.type)
	first, out := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, ptr %s, %d", first, result, root, SLICE_DATA)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, i64 %d, %d", out, result, first, len(v.elements), SLICE_LEN)
	return out
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
	if v.resolution.kind == .User_Operator {
		operands := [1]Expr{v.operand}
		return emit_operator_call(e, v.resolution.symbol, operands[:])
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
	if v.resolution.kind == .User_Operator {
		operands := [2]Expr{v.lhs, v.rhs}
		result := emit_operator_call(e, v.resolution.symbol, operands[:])
		if !v.negated {
			return result
		}
		// The `!=` fallback: `!(a == b)`.
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = xor i1 %s, true", out, result)
		return out
	}
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
	if type_is_aggregate(e.c, type) || type_is_union(e.c, type) || type_is_erased_view(e.c, type) {
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
	case .Union:
		return emit_union_equal(e, under, lhs, rhs)
	case .Dyn, .Any_View:
		// design.md: dynamic interface values are comparable only with `nil`, and
		// nil is the zero view. Comparing the second word — the witness, or the
		// `typeid` — is what distinguishes a live view from the nil one.
		llvm := llvm_type(e, under)
		left, right := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, 1", left, llvm, lhs)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, 1", right, llvm, rhs)
		out := temp(e)
		operand := info.kind == .Dyn ? "ptr" : "i64"
		fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, %s", out, operand, left, right)
		return out
	case .Slice:
		// The checker admits only `slice == nil`, and a nil slice is the one with a
		// null data pointer, so the first word decides it.
		llvm := llvm_type(e, under)
		left, right := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", left, llvm, lhs, SLICE_DATA)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", right, llvm, rhs, SLICE_DATA)
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, %s", out, left, right)
		return out
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

// An erased view is an aggregate the ordinary struct path cannot compare, so it
// takes the same route a union does.
@(private = "file")
type_is_erased_view :: proc(c: ^Compiler, type: Type_Id) -> bool {
	#partial switch type_kind(c, type_underlying(c, type)) {
	case .Dyn, .Any_View, .Slice:
		return true
	}
	return false
}

// Two unions are equal when their tags match and, for a non-nil tag, the active
// variant's payloads match.
//
// ponytail: every variant's comparison is computed and then selected, rather
// than branching per tag. Each payload load is inside the union's own storage,
// so reading one at the wrong variant's type is harmless — only the selected
// comparison is ever used. Switch to a block-per-variant chain if a union ever
// holds a variant whose comparison is expensive.
@(private = "file")
emit_union_equal :: proc(e: ^Emitter, union_type: Type_Id, lhs, rhs: string) -> string {
	info := type_of(e.c, union_type)
	shape := union_layout(e.c, union_type)
	tag_llvm := fmt.aprintf("i%d", shape.tag_bytes * 8)

	left_tag := emit_union_tag(e, union_type, lhs)
	right_tag := emit_union_tag(e, union_type, rhs)
	same_tag := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, %s", same_tag, tag_llvm, left_tag, right_tag)

	left_slot := emit_union_spill(e, union_type, lhs)
	right_slot := emit_union_spill(e, union_type, rhs)

	// Nil equals nil, so the chain starts from `true` and each variant overrides
	// it when its own tag is active.
	payloads := "true"
	for variant, index in info.variants {
		left := emit_union_payload(e, union_type, variant, left_slot)
		right := emit_union_payload(e, union_type, variant, right_slot)
		equal := emit_equal(e, variant, left, right)
		active := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, %d", active, tag_llvm, left_tag, index + 1)
		next := temp(e)
		fmt.sbprintfln(&e.b, "  %s = select i1 %s, i1 %s, i1 %s", next, active, equal, payloads)
		payloads = next
	}
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = and i1 %s, %s", out, same_tag, payloads)
	return out
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
	if v.is_dyn_call {
		results := emit_dyn_slot_call(e, v)
		return len(results) == 0 ? "0" : results[0]
	}
	if v.resolution.kind == .Conversion && type_is_dyn(e.c, v.type) {
		return emit_dyn_value(e, v)
	}
	if v.resolution.kind == .Conversion {
		return emit_conversion(e, v)
	}
	if v.reflect != .None {
		return emit_descriptor_operation(e, v)
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
		case .Hash:
			return emit_hash(e, v.bound[0], v.bound[1])
		case .Iter:
			// The checker rewrote the call to name the chosen `iter` overload, so
			// this arm is only reachable if that failed.
			panic("an `iter` call reached the backend without a chosen overload")
		case .Len:
			// Only a slice reaches here; every other `len` folded. The length is
			// the second word.
			slice := emit_expr(e, v.bound[0])
			out := temp(e)
			fmt.sbprintfln(
				&e.b,
				"  %s = extractvalue %s %s, %d",
				out, llvm_type(e, expr_base(v.bound[0]).type), slice, SLICE_LEN,
			)
			return out
		case .Default_Allocator:
			// One provider in M5a, so the handle is the provider global itself.
			return CRT_ALLOCATOR_GLOBAL
		case .New, .New_Clone:
			return emit_allocation(e, v, symbol.builtin)
		case .Drop:
			emit_explicit_drop(e, v)
			return "0"
		case .Exchange:
			return emit_exchange(e, v)
		case .Free:
			emit_free(e, v)
			return "0"
		case .Free_All:
			// The checker gates every call with its M5b diagnostic.
			panic("`free_all` reached the backend, but M5a gates every call")
		case .None, .Size_Of, .Align_Of, .Offset_Of,
		     .Type_Of, .Typeid_Of, .Fields_Of, .Enum_Values_Of:
			// These fold to a constant in every reachable case; arriving here
			// would mean emitting `print_int` for a layout query.
			panic("a built-in the checker did not fold reached the backend")
		}
	}
	results := emit_multi_call(e, v)
	return len(results) == 0 ? "0" : results[0]
}

// `field.get(value)` and `field.pointer(value)`. The descriptor selected one
// field at check time, so both are an ordinary member address, plus a load for
// `get`.
@(private = "file")
emit_descriptor_operation :: proc(e: ^Emitter, v: ^Expr_Call) -> string {
	base := emit_expr(e, v.bound[0])
	owner := type_of(e.c, type_underlying(e.c, expr_base(v.bound[0]).type))
	field := symbol_of(e.c, v.reflect_field)
	address := temp(e)
	fmt.sbprintfln(
		&e.b,
		"  %s = getelementptr inbounds %s, ptr %s, i32 0, i32 %d",
		address, llvm_type(e, owner.element), base, field.index,
	)
	if v.reflect == .Field_Pointer {
		return address
	}
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", out, llvm_type(e, field.type), address)
	return out
}

// The runtime half of the compiler-contributed `hash`. It spells the same two
// steps `hash_const` folds, so a constant hash and a computed one agree.
@(private = "file")
emit_hash :: proc(e: ^Emitter, value_expr, seed_expr: Expr) -> string {
	value := emit_expr(e, value_expr)
	seed := emit_expr(e, seed_expr)
	return emit_hash_value(e, expr_base(value_expr).type, value, seed)
}

@(private = "file")
emit_hash_value :: proc(e: ^Emitter, type: Type_Id, value, seed: string) -> string {
	under := type_underlying(e.c, type)
	info := type_of(e.c, under)
	if info != nil && info.kind == .Array {
		current := seed
		for index in 0 ..< int(info.count) {
			element := temp(e)
			fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", element, llvm_type(e, under), value, index)
			current = emit_hash_value(e, info.element, element, current)
		}
		return current
	}
	bits := emit_hash_bits(e, under, value)
	mixed := temp(e)
	fmt.sbprintfln(&e.b, "  %s = xor i64 %s, %s", mixed, seed, bits)
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = mul i64 %s, %d", out, mixed, HASH_MULTIPLIER)
	return out
}

// One scalar's 64-bit integer image.
@(private = "file")
emit_hash_bits :: proc(e: ^Emitter, under: Type_Id, value: string) -> string {
	info := type_of(e.c, under)
	out := temp(e)
	#partial switch info.kind {
	case .Bool:
		fmt.sbprintfln(&e.b, "  %s = zext i1 %s to i64", out, value)
	case .Raw_Pointer, .Pointer, .Multi_Pointer, .Proc:
		fmt.sbprintfln(&e.b, "  %s = ptrtoint ptr %s to i64", out, value)
	case .Float:
		// design.md: `+0` and `-0` hash identically because they compare equal.
		llvm := llvm_type(e, under)
		pattern := temp(e)
		width := int(info.bits)
		fmt.sbprintfln(&e.b, "  %s = bitcast %s %s to i%d", pattern, llvm, value, width)
		widened := pattern
		if width < 64 {
			widened = temp(e)
			fmt.sbprintfln(&e.b, "  %s = zext i%d %s to i64", widened, width, pattern)
		}
		zero := temp(e)
		fmt.sbprintfln(&e.b, "  %s = fcmp oeq %s %s, 0.0", zero, llvm, value)
		fmt.sbprintfln(&e.b, "  %s = select i1 %s, i64 0, i64 %s", out, zero, widened)
	case:
		width := type_bits(e.c, under)
		if info.kind == .Rune {
			width = 32
		}
		switch {
		case width == 64:
			return value
		case width > 64:
			fmt.sbprintfln(&e.b, "  %s = trunc i%d %s to i64", out, width, value)
		case type_signed(e.c, under) || info.kind == .Rune:
			fmt.sbprintfln(&e.b, "  %s = sext i%d %s to i64", out, width, value)
		case:
			fmt.sbprintfln(&e.b, "  %s = zext i%d %s to i64", out, width, value)
		}
	}
	return out
}

// An operator, index, or slice call. Operator lookup has already chosen one
// named procedure, so this is an ordinary direct call — except for a `delegate`
// overload, which has no body and applies the underlying type's operation to the
// unwrapped operands instead.
@(private = "file")
emit_operator_call :: proc(e: ^Emitter, symbol_id: Symbol_Id, bound: []Expr) -> string {
	symbol := symbol_of(e.c, symbol_id)
	if symbol == nil {
		return "0"
	}
	if symbol.delegated {
		return emit_delegated(e, symbol, bound)
	}
	info := type_of(e.c, symbol.proc_type)
	results := emit_bound_call(e, symbol_id, e.names[symbol_id] or_else "null", info, bound)
	return len(results) == 0 ? "0" : results[0]
}

// A `distinct` newtype's forwarding overload: unwrap, apply the underlying
// operation, and let the wrap back into the distinct type be the no-op it is —
// the two share a representation.
@(private = "file")
emit_delegated :: proc(e: ^Emitter, symbol: ^Symbol, bound: []Expr) -> string {
	// The underlying type's own overload takes the operands as they stand: a
	// distinct type and what it wraps lower to one LLVM type, so unwrapping is
	// the no-op the representation already makes it.
	if symbol.delegate_target != INVALID_SYMBOL {
		return emit_operator_call(e, symbol.delegate_target, bound)
	}
	op := operator_token(symbol.operator)
	underlying := symbol.delegate_underlying
	if len(bound) == 1 {
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = xor i1 %s, true", out, emit_expr(e, bound[0]))
		return out
	}
	lhs := emit_expr(e, bound[0])
	rhs := emit_expr(e, bound[1])
	#partial switch op {
	case .Eq_Eq, .Not_Eq, .Lt, .Lt_Eq, .Gt, .Gt_Eq:
		return emit_compare(e, op, underlying, lhs, rhs)
	}
	return emit_binary_op(e, op, underlying, underlying, lhs, rhs)
}

// Every result of an expression that produces several: a call, a comma-ok type
// assertion, an `or_else`, or an `or_return`.
@(private = "file")
emit_multi_value :: proc(e: ^Emitter, expr: Expr) -> []string {
	#partial switch v in expr {
	case ^Expr_Call:
		// A conversion and a built-in are calls in syntax only, and each has its
		// own lowering; `emit_call` is what knows the difference.
		if kind := call_builtin_kind(e, v); kind == .New || kind == .New_Clone {
			return emit_allocation_pair(e, v, kind)
		}
		if len(v.result_types) > 1 {
			return emit_multi_call(e, v)
		}
		single := make([]string, 1)
		single[0] = emit_expr(e, expr)
		return single
	case ^Expr_Type_Assert:
		return emit_type_assert(e, v)
	case ^Expr_Or_Else:
		return emit_or_else(e, v)
	case ^Expr_Postfix:
		if v.op == .Or_Return {
			return emit_or_return(e, v)
		}
	}
	single := make([]string, 1)
	single[0] = emit_expr(e, expr)
	return single
}

@(private = "file")
call_builtin_kind :: proc(e: ^Emitter, v: ^Expr_Call) -> Builtin_Kind {
	if v.resolution.kind == .Conversion || v.reflect != .None {
		return .None
	}
	sym := symbol_of(e.c, v.resolution.symbol)
	return sym != nil && sym.kind == .Builtin ? sym.builtin : Builtin_Kind.None
}

// design.md "Allocation failure": `new` and `new_clone` "always return an error
// and do not invoke the allocator failure policy". So there is no branch on
// failure here — the caller receives a null pointer and a non-nil error and
// decides.
//
// ponytail: one CRT provider, so the allocator operand is evaluated for its
// effects and the call goes straight to `calloc`/`malloc`. M6's provider table
// dispatches on the handle instead.
@(private = "file")
emit_allocation_pair :: proc(e: ^Emitter, v: ^Expr_Call, kind: Builtin_Kind) -> []string {
	// design.md: `new_clone` "creates a new allocation root containing a clone of
	// the value", so a record whose clone can fail goes through its hook rather
	// than through a shallow store of the representation.
	if kind == .New_Clone && type_clone_is_fallible(e.c, v.alloc_type) {
		return emit_new_clone_hook(e, v)
	}
	size := type_size(e.c, v.alloc_type)
	pointer := temp(e)
	if kind == .New {
		// design.md: `new` zero-initialises, which is what `calloc` already does.
		fmt.sbprintfln(&e.b, "  %s = call ptr @calloc(i64 1, i64 %d)", pointer, size)
	} else {
		fmt.sbprintfln(&e.b, "  %s = call ptr @malloc(i64 %d)", pointer, size)
	}
	failed := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", failed, pointer)

	if kind == .New_Clone {
		// A failed allocation has nothing to clone into, so the copy is guarded.
		// Nothing is partially built on that path: this arm only runs for a value
		// whose clone is the copy its representation already is.
		store_label, done_label := new_label(e, "newclone.store"), new_label(e, "newclone.done")
		fmt.sbprintfln(&e.b, "  br i1 %s, label %%%s, label %%%s", failed, done_label, store_label)
		place_label(e, store_label)
		store(e, v.alloc_type, emit_expr(e, v.bound[0]), pointer)
		branch(e, done_label)
		place_label(e, done_label)
		e.terminated = false
	}

	error := temp(e)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, i64 1, i64 0", error, failed)
	out := make([]string, 2)
	out[0], out[1] = pointer, error
	return out
}

// The clone-through-a-hook half of `new_clone`, and the only path with a
// partially cloned allocation to destroy: the hook already cleaned its own
// temporary, so what is left is the block it was going to be published into.
// The result travels through storage rather than phi nodes, so the three exits
// do not need their predecessor labels tracked.
@(private = "file")
emit_new_clone_hook :: proc(e: ^Emitter, v: ^Expr_Call) -> []string {
	value_type := llvm_type(e, v.alloc_type)
	value := emit_expr(e, v.bound[0])
	allocator := len(v.bound) > 1 ? emit_expr(e, v.bound[1]) : CRT_ALLOCATOR_GLOBAL

	pointer_slot, error_slot := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = alloca ptr", pointer_slot)
	fmt.sbprintfln(&e.b, "  %s = alloca i64", error_slot)
	fmt.sbprintfln(&e.b, "  store ptr null, ptr %s", pointer_slot)
	fmt.sbprintfln(&e.b, "  store i64 1, ptr %s", error_slot)

	pointer := temp(e)
	fmt.sbprintfln(&e.b, "  %s = call ptr @malloc(i64 %d)", pointer, type_size(e.c, v.alloc_type))
	no_memory := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", no_memory, pointer)
	clone_label := new_label(e, "newclone.clone")
	done_label := new_label(e, "newclone.done")
	branch_if(e, no_memory, done_label, clone_label)

	place_label(e, clone_label)
	hook := type_hook(e.c, v.alloc_type, "try_clone")
	if hook == INVALID_SYMBOL {
		panic("a fallible `new_clone` reached the backend without a `try_clone` member")
	}
	pair := clone_pair_type(value_type)
	returned := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call %s %s(%s %s, ptr %s)",
		returned, pair, e.names[hook], value_type, value, allocator,
	)
	cloned, error, failed := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, 0", cloned, pair, returned)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, 1", error, pair, returned)
	fmt.sbprintfln(&e.b, "  %s = icmp ne i64 %s, 0", failed, error)
	release_label, publish_label := new_label(e, "newclone.release"), new_label(e, "newclone.publish")
	branch_if(e, failed, release_label, publish_label)

	place_label(e, release_label)
	fmt.sbprintfln(&e.b, "  call void @free(ptr %s)", pointer)
	fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", error, error_slot)
	branch(e, done_label)

	place_label(e, publish_label)
	store(e, v.alloc_type, cloned, pointer)
	fmt.sbprintfln(&e.b, "  store ptr %s, ptr %s", pointer, pointer_slot)
	fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", error_slot)
	branch(e, done_label)

	place_label(e, done_label)
	e.terminated = false
	out := make([]string, 2)
	out[0], out[1] = temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = load ptr, ptr %s", out[0], pointer_slot)
	fmt.sbprintfln(&e.b, "  %s = load i64, ptr %s", out[1], error_slot)
	return out
}

@(private = "file")
emit_allocation :: proc(e: ^Emitter, v: ^Expr_Call, kind: Builtin_Kind) -> string {
	return emit_allocation_pair(e, v, kind)[0]
}

// design.md: "Deallocation operations such as `free` and `drop` return no
// status." The checker has already restricted the operand to a binding holding a
// fresh allocation base.
@(private = "file")
emit_free :: proc(e: ^Emitter, v: ^Expr_Call) {
	pointer := emit_expr(e, v.bound[0])
	fmt.sbprintfln(&e.b, "  call void @free(ptr %s)", pointer)
}

// design.md "Type assertions are always checked": a single-value assertion traps
// on a mismatch, and the comma-ok form yields a zeroed payload with `false`.
@(private = "file")
emit_type_assert :: proc(e: ^Emitter, v: ^Expr_Type_Assert) -> []string {
	union_type := expr_base(v.operand).type
	if union_type == TYPE_ANY_VIEW {
		return emit_any_view_assert(e, v)
	}
	shape := union_layout(e.c, union_type)
	tag_llvm := fmt.aprintf("i%d", shape.tag_bytes * 8)
	value := emit_expr(e, v.operand)
	slot := emit_union_spill(e, union_type, value)
	tag := emit_union_tag(e, union_type, value)

	matched := temp(e)
	fmt.sbprintfln(
		&e.b,
		"  %s = icmp eq %s %s, %d",
		matched, tag_llvm, tag, union_variant_tag(e.c, union_type, v.type),
	)
	if !v.optional {
		failed := temp(e)
		fmt.sbprintfln(&e.b, "  %s = xor i1 %s, true", failed, matched)
		trap_if(e, failed, "assert.variant")
		out := make([]string, 1)
		out[0] = emit_union_payload(e, union_type, v.type, slot)
		return out
	}
	// The zeroed payload is selected by address, so no aggregate has to be
	// selected and nothing out of bounds is ever read.
	llvm := llvm_type(e, v.type)
	zero_slot := temp(e)
	fmt.sbprintfln(&e.b, "  %s = alloca %s", zero_slot, llvm)
	fmt.sbprintfln(&e.b, "  store %s zeroinitializer, ptr %s", llvm, zero_slot)
	payload := temp(e)
	fmt.sbprintfln(
		&e.b,
		"  %s = getelementptr inbounds %s, ptr %s, i32 0, i32 0",
		payload, llvm_type(e, union_type), slot,
	)
	chosen := temp(e)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, ptr %s, ptr %s", chosen, matched, payload, zero_slot)
	loaded := temp(e)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", loaded, llvm, chosen)

	out := make([]string, 2)
	out[0], out[1] = loaded, matched
	return out
}

// design.md "or_else expression": the fallback is evaluated only when `ok` is
// false, which is why it lives in its own block.
@(private = "file")
emit_or_else :: proc(e: ^Emitter, v: ^Expr_Or_Else) -> []string {
	values := emit_multi_value(e, v.value)
	ok := values[len(values) - 1]
	payloads := values[:len(values) - 1]

	entry := new_label(e, "orelse.entry")
	fallback_label := new_label(e, "orelse.fallback")
	done := new_label(e, "orelse.done")
	branch(e, entry)
	fmt.sbprintfln(&e.b, "%s:", entry)
	e.terminated = false
	branch_if(e, ok, done, fallback_label)

	fmt.sbprintfln(&e.b, "%s:", fallback_label)
	e.terminated = false
	fallback := emit_multi_value(e, v.fallback)
	fallback_exit := new_label(e, "orelse.fallback.exit")
	branch(e, fallback_exit)
	fmt.sbprintfln(&e.b, "%s:", fallback_exit)
	e.terminated = false
	branch(e, done)

	fmt.sbprintfln(&e.b, "%s:", done)
	e.terminated = false
	out := make([]string, len(payloads))
	types := expr_base(v.value).result_types
	for index in 0 ..< len(payloads) {
		joined := temp(e)
		fmt.sbprintfln(
			&e.b,
			"  %s = phi %s [ %s, %%%s ], [ %s, %%%s ]",
			joined, llvm_type(e, types[index]), payloads[index], entry, fallback[index], fallback_exit,
		)
		out[index] = joined
	}
	return out
}

// design.md "or_return operator": on failure the status is assigned to the final
// result and control leaves through the ordinary epilogue, so `defer` ordering
// stays in one implementation.
@(private = "file")
emit_or_return :: proc(e: ^Emitter, v: ^Expr_Postfix) -> []string {
	values := emit_multi_value(e, v.operand)
	operand := expr_base(v.operand)
	status_type := operand.type
	if len(operand.result_types) > 0 {
		status_type = operand.result_types[len(operand.result_types) - 1]
	}
	status := values[len(values) - 1]
	failed := emit_status_failed(e, status_type, status)

	fail_label := new_label(e, "orreturn.fail")
	ok_label := new_label(e, "orreturn.ok")
	branch_if(e, failed, fail_label, ok_label)

	fmt.sbprintfln(&e.b, "%s:", fail_label)
	e.terminated = false
	last := len(e.result_slots) - 1
	if last >= 0 {
		target := e.result_types[last]
		if target != status_type && type_is_union(e.c, target) && union_holds(e.c, target, status_type) {
			status = emit_union_value(e, target, status_type, status)
		}
		store(e, target, status, e.result_slots[last])
	}
	emit_epilogue(e)

	fmt.sbprintfln(&e.b, "%s:", ok_label)
	e.terminated = false
	return values[:len(values) - 1]
}

// The status is successful when it is `true` for `bool`, or `nil` for a
// nil-comparable type. No other truthiness rules apply.
@(private = "file")
emit_status_failed :: proc(e: ^Emitter, status_type: Type_Id, status: string) -> string {
	out := temp(e)
	if type_is_union(e.c, status_type) {
		shape := union_layout(e.c, status_type)
		tag := emit_union_tag(e, status_type, status)
		result := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp ne i%d %s, 0", result, shape.tag_bytes * 8, tag)
		return result
	}
	if type_is_boolean(e.c, status_type) {
		fmt.sbprintfln(&e.b, "  %s = xor i1 %s, true", out, status)
		return out
	}
	fmt.sbprintfln(&e.b, "  %s = icmp ne ptr %s, null", out, status)
	return out
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

	return emit_bound_call(e, v.resolution.symbol, callee, callee_type, v.bound)
}

// The shared call sequence: bind the operands left to right, emit the call, and
// hand back one operand per result.
@(private = "file")
emit_bound_call :: proc(
	e: ^Emitter,
	symbol_id: Symbol_Id,
	callee: string,
	callee_type: ^Type_Info,
	bound: []Expr,
) -> []string {
	symbol := symbol_of(e.c, symbol_id)
	if callee_type == nil {
		return nil
	}
	// Arguments are bound left to right. A default that names a parameter to its
	// left reads the value bound a moment ago, which is why this map exists.
	outer_params := e.param_values
	e.param_values = make(map[Symbol_Id]string)
	defer {
		delete(e.param_values)
		e.param_values = outer_params
	}

	operands := make([]string, len(bound))
	for argument, index in bound {
		mode := index < len(callee_type.param_modes) ? callee_type.param_modes[index] : Param_Mode.Value
		if mode == .Inout {
			operands[index] = emit_address(e, argument)
		} else {
			operands[index] = emit_expr(e, argument)
		}
		// design.md: method-call syntax supplies the receiver's `move` marker
		// implicitly, so the source is read and then killed here rather than by an
		// `Expr_Move` the caller wrote.
		if index == 0 && symbol != nil && symbol.receiver == .Move {
			if ident, is_ident := argument.(^Expr_Ident); is_ident {
				kill_place(e, ident.symbol)
			}
		}
		if symbol != nil && index < len(symbol.param_symbols) && symbol.param_symbols[index] != INVALID_SYMBOL {
			e.param_values[symbol.param_symbols[index]] = operands[index]
		}
	}

	result_type := llvm_result_type(e, callee_type.results, callee_type.result_inout)
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

// A type-qualified member name may mention punctuation LLVM would need quoting.
// Fixed-width hex keeps every byte sequence distinct and LLVM-safe.
@(private = "file")
llvm_plain_name :: proc(name: string) -> bool {
	for i in 0 ..< len(name) {
		if !llvm_name_byte(name[i]) {
			return false
		}
	}
	return len(name) > 0
}

@(private = "file")
llvm_name_byte :: proc(ch: u8) -> bool {
	return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') ||
		ch == '_' || ch == '.'
}

// A type-qualified member name, and an instantiation's `Table(int, i32)`,
// mention punctuation LLVM would need quoting for. Keeping the bytes LLVM
// already accepts and escaping the rest as `$XX` stays injective — `$` itself is
// escaped — while leaving the emitted symbol readable in a `tests/ll` golden.
llvm_safe :: proc(name: string) -> string {
	hex := "0123456789abcdef"
	out := make([dynamic]u8, 0, len(name) + 8)
	for i in 0 ..< len(name) {
		ch := name[i]
		if llvm_name_byte(ch) {
			append(&out, ch)
			continue
		}
		append(&out, '$', hex[ch >> 4], hex[ch & 0x0f])
	}
	return string(out[:])
}

// A substitution such as `/` -> `.` is not injective (`a-b`, `a.b`, and `a/b`
// would collide), so the escape above is used instead: it keeps distinct logical
// package identities distinct while leaving the readable part readable.
@(private = "file")
mangled_key :: proc(pkg: ^Package) -> string {
	if pkg == nil || pkg.key == "" {
		return ""
	}
	return fmt.aprintf("%s.", llvm_safe(pkg.key))
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

// ============================================================== iteration ==

// `{ T, i1 }`. Built rather than formatted: `{` is a directive to core:fmt.
@(private = "file")
optional_pair_type :: proc(element: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{ ")
	strings.write_string(&b, element)
	strings.write_string(&b, ", i1 }")
	return strings.to_string(b)
}

// `a ..< b` and `a ..= b` as a stored value: the endpoints plus the closed flag,
// so a range keeps its kind after being assigned or passed to a generic
// procedure (m4b-plan decision "Runtime range representation").
@(private = "file")
emit_range_value :: proc(e: ^Emitter, v: ^Expr_Range) -> string {
	info := type_of(e.c, v.type)
	element := info.element
	low := emit_expr(e, v.lo)
	high := emit_expr(e, v.hi)
	closed := v.op == .Range_Incl ? "true" : "false"
	storage := llvm_type(e, v.type)
	step1 := temp(e)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, %s %s, %d", step1, storage, llvm_type(e, element), low, RANGE_LOW)
	step2 := temp(e)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, %s %s, %d", step2, storage, step1, llvm_type(e, element), high, RANGE_HIGH)
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, i1 %s, %d", out, storage, step2, closed, RANGE_CLOSED)
	return out
}

@(private = "file")
emit_foreach :: proc(e: ^Emitter, s: ^Stmt_Foreach) {
	if s.kind == .Static {
		// An expansion is not a loop: its checked copies run in iterable order,
		// and an empty iterable emits nothing.
		for copy_block in s.expansion {
			emit_block_statements(e, copy_block)
		}
		return
	}

	outer_break, outer_continue := e.break_label, e.continue_label
	outer_break_depth, outer_continue_depth := e.break_depth, e.continue_depth
	defer {
		e.break_label, e.continue_label = outer_break, outer_continue
		e.break_depth, e.continue_depth = outer_break_depth, outer_continue_depth
	}
	e.break_depth = len(e.cleanups)
	push_scope(e, nil)
	defer pop_scope(e)

	if s.kind == .Protocol {
		emit_protocol_foreach(e, s)
		return
	}
	emit_indexed_foreach(e, s)
}

// A range or a fixed array: an index loop, with no iterator object at all.
@(private = "file")
emit_indexed_foreach :: proc(e: ^Emitter, s: ^Stmt_Foreach) {
	element := llvm_type(e, s.element_type)
	cursor := temp(e)
	limit := ""
	closed := ""
	array_slot := ""
	counter_type := element

	switch s.kind {
	case .Range:
		written := s.iterable.(^Expr_Range)
		low := emit_expr(e, written.lo)
		high := emit_expr(e, written.hi)
		fmt.sbprintfln(&e.b, "  %s = alloca %s", cursor, element)
		fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", element, low, cursor)
		limit = high
		closed = written.op == .Range_Incl ? "true" : "false"

	case .Stored_Range:
		range_type := llvm_type(e, expr_base(s.iterable).type)
		value := emit_expr(e, s.iterable)
		low := temp(e)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", low, range_type, value, RANGE_LOW)
		high := temp(e)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", high, range_type, value, RANGE_HIGH)
		flag := temp(e)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", flag, range_type, value, RANGE_CLOSED)
		fmt.sbprintfln(&e.b, "  %s = alloca %s", cursor, element)
		fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", element, low, cursor)
		limit = high
		closed = flag

	case .Array:
		// `&value` names the element in place, so the array must be a place
		// rather than a copy.
		array_slot = spill_iterable(e, s.iterable)
		counter_type = "i64"
		fmt.sbprintfln(&e.b, "  %s = alloca i64", cursor)
		fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", cursor)
		limit = fmt.aprintf("%d", s.count)

	case .Slice:
		// The slice is evaluated once; the loop then walks its root through the
		// data word, so `&value` reaches the root rather than a copy.
		slice_type := llvm_type(e, expr_base(s.iterable).type)
		value := emit_expr(e, s.iterable)
		array_slot = temp(e)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", array_slot, slice_type, value, SLICE_DATA)
		length := temp(e)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", length, slice_type, value, SLICE_LEN)
		counter_type = "i64"
		fmt.sbprintfln(&e.b, "  %s = alloca i64", cursor)
		fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", cursor)
		limit = length

	case .Unresolved, .Static, .Protocol:
		panic("a `foreach` the checker did not resolve reached the backend")
	}

	head := new_label(e, "foreach.head")
	body := new_label(e, "foreach.body")
	post := new_label(e, "foreach.post")
	done := new_label(e, "foreach.done")
	e.break_label, e.continue_label = done, post
	e.continue_depth = len(e.cleanups)

	// The index binding is a counter the loop maintains, so it lives across
	// iterations rather than being rebuilt per step.
	index_slot := ""
	if len(s.bindings) == 2 && s.bindings[1].symbol != INVALID_SYMBOL {
		index_slot = temp(e)
		fmt.sbprintfln(&e.b, "  %s = alloca i64", index_slot)
		fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", index_slot)
		e.names[s.bindings[1].symbol] = index_slot
	}

	place_label(e, head)
	current := temp(e)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", current, counter_type, cursor)
	test := temp(e)
	if s.kind == .Array || s.kind == .Slice {
		fmt.sbprintfln(&e.b, "  %s = icmp slt i64 %s, %s", test, current, limit)
	} else {
		// `..<` stops before the high endpoint and `..=` includes it; a stored
		// range carries which at run time.
		signed := type_signed(e.c, s.element_type) || type_is_rune(e.c, s.element_type)
		open_test, closed_test := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp %s %s %s, %s", open_test, signed ? "slt" : "ult", counter_type, current, limit)
		fmt.sbprintfln(&e.b, "  %s = icmp %s %s %s, %s", closed_test, signed ? "sle" : "ule", counter_type, current, limit)
		fmt.sbprintfln(&e.b, "  %s = select i1 %s, i1 %s, i1 %s", test, closed, closed_test, open_test)
	}
	branch_if(e, test, body, done)

	fmt.sbprintfln(&e.b, "%s:", body)
	e.terminated = false
	bind_indexed_value(e, s, current, array_slot, element)
	emit_scoped_block(e, s.body)
	branch(e, post)

	fmt.sbprintfln(&e.b, "%s:", post)
	e.terminated = false
	if s.kind != .Array && s.kind != .Slice {
		// An inclusive range whose high endpoint is the integer maximum cannot
		// represent high+1. Finish directly after yielding high instead.
		at_high, finished := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, %s", at_high, counter_type, current, limit)
		fmt.sbprintfln(&e.b, "  %s = and i1 %s, %s", finished, closed, at_high)
		step := new_label(e, "foreach.step")
		branch_if(e, finished, done, step)
		place_label(e, step)
	}
	step_counter(e, cursor, counter_type)
	if index_slot != "" {
		step_counter(e, index_slot, "i64")
	}
	branch(e, head)

	fmt.sbprintfln(&e.b, "%s:", done)
	e.terminated = false
}

@(private = "file")
step_counter :: proc(e: ^Emitter, slot, type: string) {
	current := temp(e)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", current, type, slot)
	next := temp(e)
	fmt.sbprintfln(&e.b, "  %s = add %s %s, 1", next, type, current)
	fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", type, next, slot)
}

@(private = "file")
bind_indexed_value :: proc(e: ^Emitter, s: ^Stmt_Foreach, current, array_slot, element: string) {
	value := s.bindings[0].symbol
	if value == INVALID_SYMBOL {
		return // the discard binding names nothing
	}
	if s.kind != .Array && s.kind != .Slice {
		slot := temp(e)
		fmt.sbprintfln(&e.b, "  %s = alloca %s", slot, element)
		fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", element, current, slot)
		e.names[value] = slot
		return
	}
	address := temp(e)
	if s.kind == .Slice {
		// `array_slot` is the slice's data pointer, so the element index walks it
		// directly rather than indexing into an inline array.
		fmt.sbprintfln(
			&e.b,
			"  %s = getelementptr inbounds %s, ptr %s, i64 %s",
			address, element, array_slot, current,
		)
	} else {
		fmt.sbprintfln(
			&e.b,
			"  %s = getelementptr inbounds [%d x %s], ptr %s, i64 0, i64 %s",
			address, s.count, element, array_slot, current,
		)
	}
	if s.bindings[0].is_ref {
		// `&value` is the element itself, so the binding is its address and a
		// store through it reaches the array.
		e.names[value] = address
		return
	}
	// By default each iterated value is a copy, and assignment to the copy does
	// not modify the source.
	slot := temp(e)
	fmt.sbprintfln(&e.b, "  %s = alloca %s", slot, element)
	loaded := temp(e)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", loaded, element, address)
	fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", element, loaded, slot)
	e.names[value] = slot
}

// A user iterable: `it := iter(x)`, then `next(&it)` per step, with the loop
// maintaining the two-name index counter itself.
@(private = "file")
emit_protocol_foreach :: proc(e: ^Emitter, s: ^Stmt_Foreach) {
	iter_sym := symbol_of(e.c, s.iter_symbol)
	subject := emit_expr(e, s.iterable)
	iterator_type := llvm_type(e, s.iterator_type)
	iterator := temp(e)
	fmt.sbprintfln(&e.b, "  %s = alloca %s", iterator, iterator_type)
	made := temp(e)
	fmt.sbprintfln(
		&e.b,
		"  %s = call %s %s(%s %s)",
		made, iterator_type, e.names[s.iter_symbol], llvm_type(e, iter_sym.params[0]), subject,
	)
	fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", iterator_type, made, iterator)

	counter := temp(e)
	fmt.sbprintfln(&e.b, "  %s = alloca i64", counter)
	fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", counter)
	if len(s.bindings) == 2 && s.bindings[1].symbol != INVALID_SYMBOL {
		e.names[s.bindings[1].symbol] = counter
	}

	head := new_label(e, "foreach.head")
	body := new_label(e, "foreach.body")
	post := new_label(e, "foreach.post")
	done := new_label(e, "foreach.done")
	e.break_label, e.continue_label = done, post
	e.continue_depth = len(e.cleanups)

	place_label(e, head)
	element := llvm_type(e, s.element_type)
	pair_type := optional_pair_type(element)
	pair := temp(e)
	fmt.sbprintfln(&e.b, "  %s = call %s %s(ptr %s)", pair, pair_type, e.names[s.next_symbol], iterator)
	value := temp(e)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, 0", value, pair_type, pair)
	ok := temp(e)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, 1", ok, pair_type, pair)
	branch_if(e, ok, body, done)

	fmt.sbprintfln(&e.b, "%s:", body)
	e.terminated = false
	if binding := s.bindings[0].symbol; binding != INVALID_SYMBOL {
		slot := temp(e)
		fmt.sbprintfln(&e.b, "  %s = alloca %s", slot, element)
		fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", element, value, slot)
		e.names[binding] = slot
	}
	emit_scoped_block(e, s.body)
	branch(e, post)

	fmt.sbprintfln(&e.b, "%s:", post)
	e.terminated = false
	step_counter(e, counter, "i64")
	branch(e, head)

	fmt.sbprintfln(&e.b, "%s:", done)
	e.terminated = false
}

// An array the loop indexes: its own storage when it has any, and a spill
// otherwise.
@(private = "file")
spill_iterable :: proc(e: ^Emitter, expr: Expr) -> string {
	base := expr_base(expr)
	if base.addressable {
		return emit_address(e, expr)
	}
	value := emit_expr(e, expr)
	slot := temp(e)
	fmt.sbprintfln(&e.b, "  %s = alloca %s", slot, llvm_type(e, base.type))
	fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", llvm_type(e, base.type), value, slot)
	return slot
}

// ------------------------------------------- compiler-contributed procedures --

// design.md: built-ins satisfy the same static interface a user type does, so
// their `iter` and `next` are real procedures rather than a checker fiction.
// Emitted once for the whole compilation, after every package's items.
@(private = "file")
emit_synth_procs :: proc(e: ^Emitter) {
	for symbol_id in e.c.synth_procs {
		symbol := symbol_of(e.c, symbol_id)
		if symbol == nil || symbol.synth == .None {
			continue
		}
		e.terminated = false
		name := e.names[symbol_id]
		switch symbol.synth {
		case .Range_Iter, .Array_Iter:
			emit_synth_iter(e, symbol, name)
		case .Range_Next:
			emit_synth_range_next(e, symbol, name)
		case .Array_Next:
			emit_synth_array_next(e, symbol, name)
		case .Slice_Next:
			emit_synth_slice_next(e, symbol, name)
		case .Try_Clone:
			emit_synth_try_clone(e, symbol, name)
		case .Clone:
			emit_synth_clone(e, symbol, name)
		case .Dyn_Forward:
			emit_dyn_forwarding_slot(e, symbol, name)
		case .None:
		}
		fmt.sbprintln(&e.b, "")
	}
}

@(private = "file")
emit_synth_iter :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	source := llvm_type(e, symbol.params[0])
	iterator := llvm_type(e, symbol.results[0])
	fmt.sbprintf(&e.b, "define %s %s(%s %%arg0)", iterator, name, source)
	fmt.sbprintln(&e.b, " {")
	fmt.sbprintln(&e.b, "entry:")
	if symbol.synth == .Array_Iter {
		// `{ data, 0 }`: iteration is by value, so the iterator owns a copy.
		first := temp(e)
		fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, %s %%arg0, %d", first, iterator, source, ITER_ARRAY_DATA)
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, i64 0, %d", out, iterator, first, ITER_ARRAY_INDEX)
		fmt.sbprintfln(&e.b, "  ret %s %s", iterator, out)
		fmt.sbprintln(&e.b, "}")
		return
	}
	element := llvm_type(e, type_of(e.c, symbol.params[0]).element)
	low, high, closed := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %%arg0, %d", low, source, RANGE_LOW)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %%arg0, %d", high, source, RANGE_HIGH)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %%arg0, %d", closed, source, RANGE_CLOSED)
	step1, step2, out := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, %s %s, %d", step1, iterator, element, low, ITER_RANGE_CURRENT)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, %s %s, %d", step2, iterator, step1, element, high, ITER_RANGE_HIGH)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, i1 %s, %d", out, iterator, step2, closed, ITER_RANGE_CLOSED)
	fmt.sbprintfln(&e.b, "  ret %s %s", iterator, out)
	fmt.sbprintln(&e.b, "}")
}

@(private = "file")
emit_synth_range_next :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	element := llvm_type(e, symbol.results[0])
	iterator := llvm_type(e, symbol.params[0])
	signed := type_signed(e.c, symbol.results[0]) || type_is_rune(e.c, symbol.results[0])

	pair_type := optional_pair_type(element)
	fmt.sbprintf(&e.b, "define %s %s(ptr %%arg0)", pair_type, name)
	fmt.sbprintln(&e.b, " {")
	fmt.sbprintln(&e.b, "entry:")
	current_ptr, current := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = getelementptr inbounds %s, ptr %%arg0, i32 0, i32 %d", current_ptr, iterator, ITER_RANGE_CURRENT)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", current, element, current_ptr)
	high_ptr, high := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = getelementptr inbounds %s, ptr %%arg0, i32 0, i32 %d", high_ptr, iterator, ITER_RANGE_HIGH)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", high, element, high_ptr)
	closed_ptr, closed := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = getelementptr inbounds %s, ptr %%arg0, i32 0, i32 %d", closed_ptr, iterator, ITER_RANGE_CLOSED)
	fmt.sbprintfln(&e.b, "  %s = load i1, ptr %s", closed, closed_ptr)

	open_test, closed_test, live := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp %s %s %s, %s", open_test, signed ? "slt" : "ult", element, current, high)
	fmt.sbprintfln(&e.b, "  %s = icmp %s %s %s, %s", closed_test, signed ? "sle" : "ule", element, current, high)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, i1 %s, i1 %s", live, closed, closed_test, open_test)
	yield_label, stop_label := new_label(e, "next.yield"), new_label(e, "next.stop")
	fmt.sbprintfln(&e.b, "  br i1 %s, label %%%s, label %%%s", live, yield_label, stop_label)

	fmt.sbprintfln(&e.b, "%s:", yield_label)
	stepped, at_high, last := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = add %s %s, 1", stepped, element, current)
	fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, %s", at_high, element, current, high)
	fmt.sbprintfln(&e.b, "  %s = and i1 %s, %s", last, closed, at_high)
	next_current, next_closed := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, %s %s, %s %s", next_current, last, element, current, element, stepped)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, i1 false, i1 %s", next_closed, last, closed)
	fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", element, next_current, current_ptr)
	fmt.sbprintfln(&e.b, "  store i1 %s, ptr %s", next_closed, closed_ptr)
	first, out := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, %s %s, 0", first, pair_type, element, current)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, i1 true, 1", out, pair_type, first)
	fmt.sbprintfln(&e.b, "  ret %s %s", pair_type, out)

	// design.md optional-ok: a false `bool` ends the loop with the first result
	// unobserved, so the payload is the zero value.
	fmt.sbprintfln(&e.b, "%s:", stop_label)
	fmt.sbprintfln(&e.b, "  ret %s zeroinitializer", pair_type)
	fmt.sbprintln(&e.b, "}")
}

@(private = "file")
emit_synth_array_next :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	element := llvm_type(e, symbol.results[0])
	iterator := llvm_type(e, symbol.params[0])
	iterator_info := type_of(e.c, symbol.params[0])
	array_type := symbol_of(e.c, iterator_info.fields[ITER_ARRAY_DATA]).type
	data_type := llvm_type(e, array_type)
	count := type_of(e.c, array_type).count

	pair_type := optional_pair_type(element)
	fmt.sbprintf(&e.b, "define %s %s(ptr %%arg0)", pair_type, name)
	fmt.sbprintln(&e.b, " {")
	fmt.sbprintln(&e.b, "entry:")
	index_ptr, index := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = getelementptr inbounds %s, ptr %%arg0, i32 0, i32 %d", index_ptr, iterator, ITER_ARRAY_INDEX)
	fmt.sbprintfln(&e.b, "  %s = load i64, ptr %s", index, index_ptr)
	live := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp slt i64 %s, %d", live, index, count)
	yield_label, stop_label := new_label(e, "next.yield"), new_label(e, "next.stop")
	fmt.sbprintfln(&e.b, "  br i1 %s, label %%%s, label %%%s", live, yield_label, stop_label)

	fmt.sbprintfln(&e.b, "%s:", yield_label)
	data_ptr, slot, value := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = getelementptr inbounds %s, ptr %%arg0, i32 0, i32 %d", data_ptr, iterator, ITER_ARRAY_DATA)
	fmt.sbprintfln(&e.b, "  %s = getelementptr inbounds %s, ptr %s, i64 0, i64 %s", slot, data_type, data_ptr, index)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", value, element, slot)
	stepped := temp(e)
	fmt.sbprintfln(&e.b, "  %s = add i64 %s, 1", stepped, index)
	fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", stepped, index_ptr)
	first, out := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, %s %s, 0", first, pair_type, element, value)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, i1 true, 1", out, pair_type, first)
	fmt.sbprintfln(&e.b, "  ret %s %s", pair_type, out)

	fmt.sbprintfln(&e.b, "%s:", stop_label)
	fmt.sbprintfln(&e.b, "  ret %s zeroinitializer", pair_type)
	fmt.sbprintln(&e.b, "}")
}

// The slice half of `next`. Same `{ data, index }` iterator as an array's; the
// bound is the slice's own length word and the element address goes through its
// data pointer rather than into an inline array.
@(private = "file")
emit_synth_slice_next :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	element := llvm_type(e, symbol.results[0])
	iterator := llvm_type(e, symbol.params[0])
	iterator_info := type_of(e.c, symbol.params[0])
	slice_type := symbol_of(e.c, iterator_info.fields[ITER_ARRAY_DATA]).type
	slice_llvm := llvm_type(e, slice_type)

	pair_type := optional_pair_type(element)
	fmt.sbprintf(&e.b, "define %s %s(ptr %%arg0)", pair_type, name)
	fmt.sbprintln(&e.b, " {")
	fmt.sbprintln(&e.b, "entry:")
	index_ptr, index := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = getelementptr inbounds %s, ptr %%arg0, i32 0, i32 %d", index_ptr, iterator, ITER_ARRAY_INDEX)
	fmt.sbprintfln(&e.b, "  %s = load i64, ptr %s", index, index_ptr)
	slice_ptr, slice_value, length := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = getelementptr inbounds %s, ptr %%arg0, i32 0, i32 %d", slice_ptr, iterator, ITER_ARRAY_DATA)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", slice_value, slice_llvm, slice_ptr)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", length, slice_llvm, slice_value, SLICE_LEN)
	live := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp slt i64 %s, %s", live, index, length)
	yield_label, stop_label := new_label(e, "next.yield"), new_label(e, "next.stop")
	fmt.sbprintfln(&e.b, "  br i1 %s, label %%%s, label %%%s", live, yield_label, stop_label)

	fmt.sbprintfln(&e.b, "%s:", yield_label)
	data, slot, value := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", data, slice_llvm, slice_value, SLICE_DATA)
	fmt.sbprintfln(&e.b, "  %s = getelementptr inbounds %s, ptr %s, i64 %s", slot, element, data, index)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", value, element, slot)
	stepped := temp(e)
	fmt.sbprintfln(&e.b, "  %s = add i64 %s, 1", stepped, index)
	fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", stepped, index_ptr)
	first, out := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, %s %s, 0", first, pair_type, element, value)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, i1 true, 1", out, pair_type, first)
	fmt.sbprintfln(&e.b, "  ret %s %s", pair_type, out)

	fmt.sbprintfln(&e.b, "%s:", stop_label)
	fmt.sbprintfln(&e.b, "  ret %s zeroinitializer", pair_type)
	fmt.sbprintln(&e.b, "}")
}

// ------------------------------------------------------- lifecycle bodies --

// `{ T, i64 }`, the `(T, Allocator_Error)` result pair. Built rather than
// formatted, because `{` is a directive to core:fmt.
@(private = "file")
clone_pair_type :: proc(value: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{ ")
	strings.write_string(&b, value)
	strings.write_string(&b, ", i64 }")
	return strings.to_string(b)
}

// design.md: "Compiler-generated field-wise cloning calls `try_clone`
// recursively for every owning field, destroys a partially completed temporary
// on failure, and returns zero plus the error."
//
// A type no part of which reaches a custom hook cannot fail, so its generated
// body is the copy the representation already is. The branchy shape below exists
// only where a real hook can return an error.
@(private = "file")
emit_synth_try_clone :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	subject := symbol.params[0]
	value_type := llvm_type(e, subject)
	pair := clone_pair_type(value_type)
	fmt.sbprintf(&e.b, "define %s %s(%s %%arg0, ptr %%arg1)", pair, name, value_type)
	fmt.sbprintln(&e.b, " {")
	fmt.sbprintln(&e.b, "entry:")
	e.terminated = false

	if !type_clone_is_fallible(e.c, subject) {
		first, out := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, %s %%arg0, 0", first, pair, value_type)
		fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, i64 0, 1", out, pair, first)
		fmt.sbprintfln(&e.b, "  ret %s %s", pair, out)
		fmt.sbprintln(&e.b, "}")
		return
	}

	// Both sides are addressed rather than kept in registers: a failure path has
	// to drop what the destination already holds, and a drop hook takes a place.
	self, out := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = alloca %s", self, value_type)
	fmt.sbprintfln(&e.b, "  store %s %%arg0, ptr %s", value_type, self)
	fmt.sbprintfln(&e.b, "  %s = alloca %s", out, value_type)
	// design.md: "every hook must handle the inert zero value", and a cleanup that
	// runs before a part is written must see that zero rather than garbage.
	fmt.sbprintfln(&e.b, "  store %s zeroinitializer, ptr %s", value_type, out)

	for index in 0 ..< clone_part_count(e.c, subject) {
		part := clone_part(e.c, subject, index)
		source := element_address(e, subject, self, index)
		destination := element_address(e, subject, out, index)
		if !type_clone_is_fallible(e.c, part) {
			loaded := temp(e)
			fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", loaded, llvm_type(e, part), source)
			store(e, part, loaded, destination)
			continue
		}
		cloned, error := emit_part_clone(e, part, source)
		failed := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp ne i64 %s, 0", failed, error)
		unwind, ok := new_label(e, "clone.unwind"), new_label(e, "clone.ok")
		branch_if(e, failed, unwind, ok)

		// The partially built temporary, cleaned in reverse part order. Everything
		// past `index` is still the inert zero this block never wrote.
		place_label(e, unwind)
		for done := index - 1; done >= 0; done -= 1 {
			emit_drop_place(e, clone_part(e.c, subject, done), element_address(e, subject, out, done))
		}
		zeroed := temp(e)
		fmt.sbprintfln(&e.b, "  %s = insertvalue %s zeroinitializer, i64 %s, 1", zeroed, pair, error)
		fmt.sbprintfln(&e.b, "  ret %s %s", pair, zeroed)
		e.terminated = true
		// Only a successful part is published, so a hook that breaks its contract
		// and hands back a live value beside an error cannot leave one in the
		// temporary that cleanup would never reach.
		place_label(e, ok)
		store(e, part, cloned, destination)
	}

	built, first, result := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", built, value_type, out)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, %s %s, 0", first, pair, value_type, built)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, i64 0, 1", result, pair, first)
	fmt.sbprintfln(&e.b, "  ret %s %s", pair, result)
	fmt.sbprintln(&e.b, "}")
}

// The address of part `index`, which is a struct field or an array element.
@(private = "file")
element_address :: proc(e: ^Emitter, owner: Type_Id, base: string, index: int) -> string {
	info := type_of(e.c, type_underlying(e.c, owner))
	out := temp(e)
	if info != nil && info.kind == .Array {
		fmt.sbprintfln(
			&e.b, "  %s = getelementptr inbounds %s, ptr %s, i64 0, i64 %d",
			out, llvm_type(e, owner), base, index,
		)
		return out
	}
	fmt.sbprintfln(
		&e.b, "  %s = getelementptr inbounds %s, ptr %s, i32 0, i32 %d",
		out, llvm_type(e, owner), base, index,
	)
	return out
}

// Clones one part through its own `try_clone` — custom or generated, both real
// members. Returns the cloned value and the error word; the caller publishes the
// value only on the success path.
@(private = "file")
emit_part_clone :: proc(e: ^Emitter, part: Type_Id, source: string) -> (string, string) {
	hook := type_hook(e.c, part, "try_clone")
	if hook == INVALID_SYMBOL {
		// `type_clone_is_fallible` said this part reaches a custom hook, so the
		// contribution pass owed it one.
		panic("a fallible clone part reached the backend without a `try_clone` member")
	}
	part_type := llvm_type(e, part)
	pair := clone_pair_type(part_type)
	loaded, returned := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", loaded, part_type, source)
	fmt.sbprintfln(
		&e.b, "  %s = call %s %s(%s %s, ptr %%arg1)",
		returned, pair, e.names[hook], part_type, loaded,
	)
	cloned, error := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, 0", cloned, pair, returned)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, 1", error, pair, returned)
	return cloned, error
}

// design.md: "`clone` ... calls `try_clone` once and, on failure, invokes the
// supplied allocator's failure policy."
//
// ponytail: M5a's fixed fallback is a non-unwinding trap; M6's allocator-selected
// `.Panic`/`.Trap` dispatch replaces the trap block, not the shape.
@(private = "file")
emit_synth_clone :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	subject := symbol.params[0]
	value_type := llvm_type(e, subject)
	pair := clone_pair_type(value_type)
	fmt.sbprintf(&e.b, "define %s %s(%s %%arg0, ptr %%arg1)", value_type, name, value_type)
	fmt.sbprintln(&e.b, " {")
	fmt.sbprintln(&e.b, "entry:")
	e.terminated = false

	hook := type_hook(e.c, subject, "try_clone")
	if hook == INVALID_SYMBOL {
		panic("a generated `clone` reached the backend without a `try_clone` member")
	}
	returned := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call %s %s(%s %%arg0, ptr %%arg1)",
		returned, pair, e.names[hook], value_type,
	)
	cloned, error, failed := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, 0", cloned, pair, returned)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, 1", error, pair, returned)
	fmt.sbprintfln(&e.b, "  %s = icmp ne i64 %s, 0", failed, error)
	trap_if(e, failed, "clone.failed")
	fmt.sbprintfln(&e.b, "  ret %s %s", value_type, cloned)
	fmt.sbprintln(&e.b, "}")
}

// The `try_clone` or `drop` a type answers to: a written one when the `impl`
// block has it, and the contributed one otherwise.
type_hook :: proc(c: ^Compiler, type: Type_Id, name: string) -> Symbol_Id {
	info := type_of(c, type_underlying(c, type))
	if info == nil {
		return INVALID_SYMBOL
	}
	return member_named_in(c, info.members, intern_identifier(c, name))
}

// design.md: "`drop(value)` invokes the user hook when present" and "Fields are
// dropped in reverse declaration order after the containing type's drop hook
// returns." Used by partial-clone cleanup now; step 4's scope-exit cleanup is
// the same walk from a different caller.
emit_drop_place :: proc(e: ^Emitter, type: Type_Id, address: string) {
	if !type_is_managed(e.c, type) {
		return
	}
	if hook := custom_drop_of(e.c, type); hook != INVALID_SYMBOL {
		fmt.sbprintfln(&e.b, "  call void %s(ptr %s)", e.names[hook], address)
	}
	for index := clone_part_count(e.c, type) - 1; index >= 0; index -= 1 {
		part := clone_part(e.c, type, index)
		if !type_is_managed(e.c, part) {
			continue
		}
		emit_drop_place(e, part, element_address(e, type, address, index))
	}
}

@(private = "file")
custom_drop_of :: proc(c: ^Compiler, type: Type_Id) -> Symbol_Id {
	return lifecycle_of(c, type).custom_drop
}

// ============================================================ erased views ==

// `{ ptr data, typeid id }`. The conversion never allocates: it pairs the
// source's address with its frozen `typeid`.
@(private = "file")
emit_any_view_value :: proc(e: ^Emitter, address: string, concrete: Type_Id) -> string {
	storage := llvm_type(e, TYPE_ANY_VIEW)
	first := temp(e)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, ptr %s, %d", first, storage, address, ANY_VIEW_DATA)
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, i64 %d, %d", out, storage, first, typeid_value(e.c, concrete), ANY_VIEW_ID)
	return out
}

// An assertion against an `any_view`: compare the stored `typeid`, then read the
// data pointer as the asserted type. A single-value position traps on a
// mismatch; the comma-ok form yields a zeroed payload and `false`.
@(private = "file")
emit_any_view_assert :: proc(e: ^Emitter, v: ^Expr_Type_Assert) -> []string {
	view := emit_expr(e, v.operand)
	storage := llvm_type(e, TYPE_ANY_VIEW)
	data, id := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", data, storage, view, ANY_VIEW_DATA)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", id, storage, view, ANY_VIEW_ID)
	matched := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i64 %s, %d", matched, id, typeid_value(e.c, v.type))

	target := llvm_type(e, v.type)
	if !v.optional {
		failed := temp(e)
		fmt.sbprintfln(&e.b, "  %s = xor i1 %s, true", failed, matched)
		trap_if(e, failed, "anyview.mismatch")
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", out, target, data)
		single := make([]string, 1)
		single[0] = out
		return single
	}

	slot := temp(e)
	fmt.sbprintfln(&e.b, "  %s = alloca %s", slot, target)
	fmt.sbprintfln(&e.b, "  store %s zeroinitializer, ptr %s", target, slot)
	then_label, done_label := new_label(e, "anyview.match"), new_label(e, "anyview.done")
	fmt.sbprintfln(&e.b, "  br i1 %s, label %%%s, label %%%s", matched, then_label, done_label)
	fmt.sbprintfln(&e.b, "%s:", then_label)
	loaded := temp(e)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", loaded, target, data)
	fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", target, loaded, slot)
	branch(e, done_label)
	fmt.sbprintfln(&e.b, "%s:", done_label)
	e.terminated = false
	payload := temp(e)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", payload, target, slot)
	pair := make([]string, 2)
	pair[0], pair[1] = payload, matched
	return pair
}

// `(dyn I)(&value)`: the data pointer plus the coherent witness for the erased
// type. A nil concrete pointer produces the nil view and retains no witness.
@(private = "file")
emit_dyn_value :: proc(e: ^Emitter, v: ^Expr_Call) -> string {
	storage := llvm_type(e, v.type)
	if v.dyn_witness == nil {
		return "zeroinitializer"
	}
	data := emit_expr(e, v.bound[0])
	first := temp(e)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, ptr %s, %d", first, storage, data, DYN_DATA)
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, ptr %s, %d", out, storage, first, v.dyn_witness.name, DYN_WITNESS)
	return out
}

// A slot call: load the thunk from the witness table and call it indirectly,
// trapping first if the view is nil.
@(private = "file")
emit_dyn_slot_call :: proc(e: ^Emitter, v: ^Expr_Call) -> []string {
	view := emit_expr(e, v.bound[0])
	storage := llvm_type(e, expr_base(v.bound[0]).type)
	data, witness := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", data, storage, view, DYN_DATA)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", witness, storage, view, DYN_WITNESS)

	// design.md: calling a slot on nil panics.
	is_nil := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", is_nil, witness)
	trap_if(e, is_nil, "dyn.nil")

	entry, thunk := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = getelementptr inbounds ptr, ptr %s, i64 %d", entry, witness, v.dyn_slot)
	fmt.sbprintfln(&e.b, "  %s = load ptr, ptr %s", thunk, entry)

	signature := type_of(e.c, expr_base(v.callee).type)
	result_type := llvm_result_type(e, signature.results, nil)
	operands := make([dynamic]string, 0, len(v.bound), context.temp_allocator)
	append(&operands, data)
	for index in 1 ..< len(v.bound) {
		if signature.param_modes[index] == .Inout {
			append(&operands, emit_address(e, v.bound[index]))
		} else {
			append(&operands, emit_expr(e, v.bound[index]))
		}
	}

	call := ""
	if len(signature.results) > 0 {
		call = temp(e)
		fmt.sbprintf(&e.b, "  %s = call %s %s(", call, result_type, thunk)
	} else {
		fmt.sbprintf(&e.b, "  call void %s(", thunk)
	}
	for operand, index in operands {
		if index > 0 {
			fmt.sbprint(&e.b, ", ")
		}
		type := index == 0 || signature.param_modes[index] == .Inout ? "ptr" : llvm_type(e, signature.parameters[index])
		fmt.sbprintf(&e.b, "%s %s", type, operand)
	}
	fmt.sbprintln(&e.b, ")")

	switch len(signature.results) {
	case 0:
		return nil
	case 1:
		single := make([]string, 1)
		single[0] = call
		return single
	}
	out := make([]string, len(signature.results))
	for index in 0 ..< len(signature.results) {
		out[index] = temp(e)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", out[index], result_type, call, index)
	}
	return out
}

// One private immutable global per materialised constant, in registration order
// (design.md "Materialization"). A constant used only at constant indices never
// registered one and so occupies no space in the program.
@(private = "file")
emit_materialized_constants :: proc(e: ^Emitter) {
	if len(e.c.materialized_order) == 0 {
		return
	}
	for entry in e.c.materialized_order {
		fmt.sbprintfln(
			&e.b,
			"%s = private unnamed_addr constant %s %s",
			entry.name, llvm_type(e, entry.type), llvm_const(e, entry.value, entry.type),
		)
	}
	fmt.sbprintln(&e.b, "")
}

// One private immutable global per `(Interface, Concrete, arguments)`, holding a
// compiler-generated thunk per slot. A thunk takes the erased receiver pointer
// and re-types it for the concrete implementation.
@(private = "file")
emit_witnesses :: proc(e: ^Emitter) {
	for witness in e.c.witness_order {
		for slot, index in witness.slots {
			emit_witness_thunk(e, witness, slot, index)
		}
	}
	for witness in e.c.witness_order {
		fmt.sbprintf(&e.b, "%s = private unnamed_addr constant [%d x ptr] [", witness.name, len(witness.slots))
		for _, index in witness.slots {
			if index > 0 {
				fmt.sbprint(&e.b, ",")
			}
			fmt.sbprintf(&e.b, " ptr %s", witness_thunk_name(e, witness, index))
		}
		fmt.sbprintln(&e.b, " ]")
	}
	fmt.sbprintln(&e.b, "")
}

@(private = "file")
witness_thunk_name :: proc(e: ^Emitter, witness: ^Witness, index: int) -> string {
	return fmt.aprintf("%s.thunk.%d", witness.name, index)
}

@(private = "file")
emit_witness_thunk :: proc(e: ^Emitter, witness: ^Witness, slot: Witness_Slot, index: int) {
	target := symbol_of(e.c, slot.target)
	if target == nil {
		return
	}
	e.terminated = false
	name := witness_thunk_name(e, witness, index)
	signature := type_of(e.c, target.proc_type)
	result_type := llvm_result_type(e, target.results, nil)

	fmt.sbprintf(&e.b, "define private %s %s(ptr %%arg0", result_type, name)
	for position in 1 ..< len(target.params) {
		mode := signature.param_modes[position]
		type := mode == .Inout ? "ptr" : llvm_type(e, target.params[position])
		fmt.sbprintf(&e.b, ", %s %%arg%d", type, position)
	}
	fmt.sbprint(&e.b, ")")
	fmt.sbprintln(&e.b, " {")
	fmt.sbprintln(&e.b, "entry:")

	// The receiver arrives erased. An immutable `self` is a value parameter, so
	// it is loaded; an `inout self` is already the alias the callee wants.
	receiver := "%arg0"
	if slot.mode != .Inout {
		loaded := temp(e)
		fmt.sbprintfln(&e.b, "  %s = load %s, ptr %%arg0", loaded, llvm_type(e, target.params[0]))
		receiver = loaded
	}

	call := ""
	if len(target.results) > 0 {
		call = temp(e)
		fmt.sbprintf(&e.b, "  %s = call %s %s(", call, result_type, e.names[slot.target])
	} else {
		fmt.sbprintf(&e.b, "  call void %s(", e.names[slot.target])
	}
	receiver_type := slot.mode == .Inout ? "ptr" : llvm_type(e, target.params[0])
	fmt.sbprintf(&e.b, "%s %s", receiver_type, receiver)
	for position in 1 ..< len(target.params) {
		mode := signature.param_modes[position]
		type := mode == .Inout ? "ptr" : llvm_type(e, target.params[position])
		fmt.sbprintf(&e.b, ", %s %%arg%d", type, position)
	}
	fmt.sbprintln(&e.b, ")")

	if len(target.results) == 0 {
		fmt.sbprintln(&e.b, "  ret void")
	} else {
		fmt.sbprintfln(&e.b, "  ret %s %s", result_type, call)
	}
	fmt.sbprintln(&e.b, "}")
	fmt.sbprintln(&e.b, "")
}

// design.md: `dyn I` satisfies `I` through compiler-provided forwarding slots.
// The forwarder takes the view by value, traps on a nil witness, and calls the
// slot's thunk with the view's own data pointer.
@(private = "file")
emit_dyn_forwarding_slot :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	signature := type_of(e.c, symbol.proc_type)
	result_type := llvm_result_type(e, symbol.results, nil)
	view_type := llvm_type(e, symbol.params[0])

	receiver_inout := len(signature.param_modes) > 0 && signature.param_modes[0] == .Inout
	receiver_type := receiver_inout ? "ptr" : view_type
	fmt.sbprintf(&e.b, "define %s %s(%s %%arg0", result_type, name, receiver_type)
	for position in 1 ..< len(symbol.params) {
		mode := signature.param_modes[position]
		type := mode == .Inout ? "ptr" : llvm_type(e, symbol.params[position])
		fmt.sbprintf(&e.b, ", %s %%arg%d", type, position)
	}
	fmt.sbprint(&e.b, ")")
	fmt.sbprintln(&e.b, " {")
	fmt.sbprintln(&e.b, "entry:")

	view := "%arg0"
	if receiver_inout {
		view = temp(e)
		fmt.sbprintfln(&e.b, "  %s = load %s, ptr %%arg0", view, view_type)
	}
	data, witness := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", data, view_type, view, DYN_DATA)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", witness, view_type, view, DYN_WITNESS)
	is_nil := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", is_nil, witness)
	trap_if(e, is_nil, "dyn.nil")

	entry, thunk := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = getelementptr inbounds ptr, ptr %s, i64 %d", entry, witness, symbol.index)
	fmt.sbprintfln(&e.b, "  %s = load ptr, ptr %s", thunk, entry)

	call := ""
	if len(symbol.results) > 0 {
		call = temp(e)
		fmt.sbprintf(&e.b, "  %s = call %s %s(ptr %s", call, result_type, thunk, data)
	} else {
		fmt.sbprintf(&e.b, "  call void %s(ptr %s", thunk, data)
	}
	for position in 1 ..< len(symbol.params) {
		mode := signature.param_modes[position]
		type := mode == .Inout ? "ptr" : llvm_type(e, symbol.params[position])
		fmt.sbprintf(&e.b, ", %s %%arg%d", type, position)
	}
	fmt.sbprintln(&e.b, ")")

	if len(symbol.results) == 0 {
		fmt.sbprintln(&e.b, "  ret void")
	} else {
		fmt.sbprintfln(&e.b, "  ret %s %s", result_type, call)
	}
	fmt.sbprintln(&e.b, "}")
}

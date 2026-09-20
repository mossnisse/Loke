// LLVM module orchestration, emitter state, naming, and instruction plumbing.
//
// Part of the textual LLVM backend; see compiler-architecture.md.
package lokec

import "core:fmt"
import "core:mem/virtual"
import "core:strings"

@(private)
Emitter :: struct {
	c:    ^Compiler,
	b:    strings.Builder,
	next: int, // temporary and unique-name counter
	failed: bool,
	// Set while emitting synthesized members, whose uncallable copies (L0491)
	// abort instead of failing the build.
	synth_bodies: bool,
	names:        map[Symbol_Id]string,
	struct_names: map[Type_Id]string,
	// design.md "@(packed)": a place's alignment, by pointer temporary, when it is
	// below the pointee's natural one.
	place_align:  map[string]u64,
	// The function being written; saved and cleared around a nested thunk.
	using fn: Function_State,
	// Panic-cleanup replay functions, empty under `-panic=abort`.
	pending: [dynamic]string,
	// Thunks generated mid-body, flushed at the end of the module.
	pending_thunks: [dynamic]string,
	// The spilled `format_any` writer and options, shared by nested dispatch.
	fmt_writer:  string,
	fmt_options: string,
	// Interned per type or per name, so each is emitted once.
	container_ops: map[Type_Id]string,
	container_thunks: map[string]bool,
	messages: map[string]string,
	literals: map[string]string,
	simd_intrinsics: map[string]bool,
	globals:  [dynamic]string,
}

// The only `Emitter` literal, so no map is left uninitialized.
make_emitter :: proc(c: ^Compiler) -> Emitter {
	e := Emitter {
		c            = c,
		names        = make(map[Symbol_Id]string),
		struct_names = make(map[Type_Id]string),
		place_align  = make(map[string]u64),
		cleanups     = make([dynamic]Cleanup_Scope),
		param_values = make(map[Symbol_Id]string),
		pending      = make([dynamic]string),
		pending_thunks = make([dynamic]string),
		container_ops = make(map[Type_Id]string),
		container_thunks = make(map[string]bool),
		messages     = make(map[string]string),
		literals     = make(map[string]string),
		simd_intrinsics = make(map[string]bool),
		globals      = make([dynamic]string),
	}
	strings.builder_init(&e.b)
	return e
}

// The whole checked program as one LLVM module, in memory.
emit_llvm_module :: proc(c: ^Compiler) -> (string, bool) {
	context.allocator = virtual.arena_allocator(&c.emission_arena)
	if !validate_emission_dependencies(c) { return "", false }
	e := make_emitter(c)

	emit_preamble(&e)
	emit_struct_definitions(&e)
	emit_materialized_constants(&e)

	// Every procedure is named before any body refers to it.
	order := package_order(c)
	for id in order {
		name_package_symbols(&e, package_of(c, id))
	}
	name_synth_procs(&e)
	emit_foreign_declarations(&e)
	emit_static_locals(&e)
	for id in order {
		emit_package_items(&e, package_of(c, id))
	}
	emit_synth_procs(&e)
	emit_witnesses(&e)
	// Every module, object builds included: the runtime's `thread_detach` calls it.
	emit_thread_local_teardown(&e)
	// design.md "Build-selected providers": no initializer unless one is selected.
	if any_provider_selected(c) {
		emit_program_init(&e)
	}
	// design.md "Build modes": an object build's host owns the entry.
	if c.build_mode == .Exe {
		emit_entry(&e)
	}
	emit_type_info_tables(&e)
	emit_format_thunks(&e)
	for text in e.pending_thunks {
		strings.write_string(&e.b, text)
	}
	for text in e.globals {
		strings.write_string(&e.b, text)
	}
	if e.failed || c.error_count != 0 {
		return "", false
	}
	return strings.to_string(e.b), true
}

// The enclosing function's buffer and state, restored when a nested one ends.
@(private = "file")
Function_Emission :: struct {
	parent: strings.Builder,
	saved:  Function_State,
}

// The per-function half of `Emitter`. `emit_unwind_thunk` swaps only the fields
// it owns, so a field a replay must not share needs adding there too.
@(private)
Function_State :: struct {
	// Whether the current block already ends in a terminator.
	terminated: bool,
	// INVALID_TYPE, with an empty `result_slot`, when there is no result.
	result_type: Type_Id,
	result_slot: string,
	// An `inout` result is returned as the address of a place.
	result_inout: bool,
	// design.md "Calling conventions": the Windows x64 classification applies.
	abi_foreign: bool,
	// The hidden `sret` pointer, which the result slot aliases, or "".
	abi_sret:    string,
	defer_flags: []string,
	cleanups:    [dynamic]Cleanup_Scope,
	// design.md "Borrows and lifetimes": one frame per full expression, since a
	// value temporary dies at its end.
	temporaries: [dynamic][dynamic]Deferred,
	break_label:    string,
	continue_label: string,
	break_depth:    int,
	continue_depth: int,
	// Arguments already bound at the current call, for default expressions.
	param_values: map[Symbol_Id]string,
	unwind: Unwind_State,
	// Fixed-size allocas, spliced into the entry block so a loop can't grow the stack.
	prologue: [dynamic]string,
}

// `define <signature> {` and the entry label; `{` can't go in a format string.
@(private)
open_function :: proc(e: ^Emitter, format: string, args: ..any) {
	fmt.sbprintf(&e.b, format, ..args)
	fmt.sbprintln(&e.b, " {")
	fmt.sbprintln(&e.b, "entry:")
}

@(private)
begin_function_emission :: proc(e: ^Emitter) -> Function_Emission {
	state := Function_Emission{parent = e.b, saved = e.fn}
	e.b = strings.builder_make()
	e.fn = {}
	e.result_type = INVALID_TYPE
	return state
}

// The finished function's text, for the caller to place.
@(private)
end_function_emission :: proc(e: ^Emitter, state: Function_Emission) -> string {
	text := splice_prologue(e, strings.to_string(e.b), e.prologue[:])
	e.b = state.parent
	e.fn = state.saved
	return text
}

@(private)
finish_function_emission :: proc(e: ^Emitter, state: Function_Emission) {
	strings.write_string(&e.b, end_function_emission(e, state))
}

// A thunk made mid-body waits for the end of the module.
@(private)
finish_pending_thunk :: proc(e: ^Emitter, state: Function_Emission) {
	append(&e.pending_thunks, end_function_emission(e, state))
}

// Places the collected `alloca` lines right after the entry label.
@(private)
splice_prologue :: proc(e: ^Emitter, body: string, prologue: []string) -> string {
	if len(prologue) == 0 {
		return body
	}
	ENTRY :: "\nentry:\n"
	at := strings.index(body, ENTRY)
	if at < 0 {
		backend_fail(e, "a function has no entry block to hold its storage")
		return body
	}
	out := strings.builder_make()
	strings.write_string(&out, body[:at + len(ENTRY)])
	for line in prologue {
		fmt.sbprintln(&out, line)
	}
	strings.write_string(&out, body[at + len(ENTRY):])
	return strings.to_string(out)
}

// design.md "@(export)": only exports need linker-visible names; `internal`
// lets LLVM drop everything else once inlined.
@(private)
llvm_linkage :: proc(name: string) -> string {
	return strings.has_prefix(name, "@loke.") ? "internal " : ""
}

@(private)
backend_fail :: proc(e: ^Emitter, message: string) {
	if e.failed {
		return
	}
	e.failed = true
	errorf(e.c, no_span(), "L0405", "internal backend contract violation: %s", message)
}

// Every symbol is named before any body, so an unnamed one is a contract break;
// "null" only keeps the text well formed.
symbol_name :: proc(e: ^Emitter, id: Symbol_Id) -> string {
	if name, named := e.names[id]; named {
		return name
	}
	backend_fail(e, "a resolved operation has no emitted name")
	return "null"
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
				for symbol_id in v.symbols {
					if sym := symbol_of(e.c, symbol_id); sym != nil && sym.kind == .Var && !sym.is_foreign {
						e.names[symbol_id] = sym.exported \
							? llvm_external_name(sym.link_name) \
							: llvm_global_name(pkg, identifier_text(e.c, sym.name))
					}
				}
				// Only a template's instances are named and emitted.
				if decl_proc_literal(v) != nil && len(v.symbols) > 0 && !symbol_is_template(e.c, v.symbols[0]) {
					if sym := symbol_of(e.c, v.symbols[0]); sym != nil && sym.exported {
						e.names[v.symbols[0]] = llvm_external_name(sym.link_name)
					} else {
						e.names[v.symbols[0]] = llvm_proc_name(pkg, v.names[0].text)
					}
				}
			case ^Item_Impl:
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
			case ^Item_Foreign_Block:
				// design.md "Foreign system": foreign members keep their link names.
				for member in v.members {
					d, is_decl := member.(^Decl)
					if !is_decl {
						continue
					}
					for sid in d.symbols {
						if sym := symbol_of(e.c, sid); sym != nil && sym.is_foreign {
							e.names[sid] = foreign_llvm_name(sym)
						}
					}
				}
			}
		}
	}
	for literal, index in pkg.hoisted_procs {
		// The index keeps two bodies' same-named local procedures apart.
		written := "lambda"
		if sym := symbol_of(e.c, literal.symbol); sym != nil && sym.decl != nil {
			written = llvm_safe(identifier_text(e.c, sym.name))
		}
		e.names[literal.symbol] = llvm_proc_name(pkg, fmt.aprintf("%s.%d", written, index))
	}
	// `f(alpha.Item)` and `f(beta.Item)` share a spelling; the id tells them apart.
	taken := make(map[string]bool, len(pkg.instances), context.temp_allocator)
	for instance in pkg.instances {
		name := llvm_proc_name(pkg, llvm_safe(instance.name))
		if taken[name] {
			name = fmt.aprintf("%s.%d", name, int(instance.symbol))
		}
		taken[name] = true
		e.names[instance.symbol] = name
	}
}

// Compiler-contributed members belong to no package.
@(private = "file")
name_synth_procs :: proc(e: ^Emitter) {
	used := make(map[string]bool, context.temp_allocator)
	for symbol_id in e.c.synth_procs {
		symbol := symbol_of(e.c, symbol_id)
		if symbol == nil {
			continue
		}
		base := fmt.aprintf("@loke.i.%s", llvm_safe(qualified_member_name(e.c, symbol)))
		name := base
		if used[name] {
			name = fmt.aprintf("%s.%d", base, int(symbol_id))
		}
		used[name] = true
		e.names[symbol_id] = name
	}
}

@(private = "file")
symbol_is_template :: proc(c: ^Compiler, symbol_id: Symbol_Id) -> bool {
	sym := symbol_of(c, symbol_id)
	if sym == nil {
		return false
	}
	if sym.generic {
		return true
	}
	// An unused generic's signature may never have been checked, so fall back to
	// its syntax; instances keep that syntax but have `instance_of`.
	return sym.instance_of == INVALID_SYMBOL && declaration_generic_kind(sym.decl) != .None
}

@(private = "file")
emit_package_items :: proc(e: ^Emitter, pkg: ^Package) {
	if pkg == nil {
		return
	}
	for file in pkg.files {
		for item in file.active_items {
			if d, ok := item.(^Decl); ok && decl_proc_literal(d) == nil {
				emit_global(e, d)
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
					if symbol_is_template(e.c, d.symbols[0]) {
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
		// A generic method of an instantiated `impl` is still a template.
		if symbol_is_template(e.c, instance.symbol) {
			continue
		}
		if literal := decl_proc_literal(instance.decl); literal != nil {
			emit_proc(e, instance.symbol, literal)
		}
	}
}

@(private = "file")
emit_proc :: proc(e: ^Emitter, symbol_id: Symbol_Id, literal: ^Expr_Proc) {
	symbol := symbol_of(e.c, symbol_id)
	if symbol == nil || literal == nil || literal.body == nil {
		return
	}
	llvm_name, named := e.names[symbol_id]
	if !named {
		backend_fail(e, "a procedure has no mangled name")
		return
	}
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)

	e.result_type = symbol.result
	e.result_inout = result_inout_of(e, symbol.proc_type)
	e.abi_foreign = convention_is_foreign(proc_convention_of(e, symbol))
	begin_unwind_frame(e, llvm_name)

	if e.abi_foreign {
		emit_foreign_signature(e, symbol, llvm_name)
	} else {
		fmt.sbprintf(
			&e.b, "define %s%s %s(",
			llvm_linkage(llvm_name), llvm_result_type(e, symbol.result, e.result_inout), llvm_name,
		)
		for parameter, index in symbol.params {
			if index > 0 {
				fmt.sbprint(&e.b, ", ")
			}
			mode := symbol_param_mode(e.c, symbol, index)
			type := param_mode_is_pointer(mode) ? "ptr" : llvm_type(e, parameter)
			fmt.sbprintf(&e.b, "%s %%arg%d", type, index)
		}
		fmt.sbprintln(&e.b, ") {")
	}
	fmt.sbprintln(&e.b, "entry:")

	// The unwind prologue depends on the whole body, so the body is written aside.
	module := e.b
	e.b = strings.builder_make()

	// A value parameter gets its own storage; a pointer-mode one is already an
	// alias (design.md "Receiver forms").
	for parameter, index in symbol.params {
		binding := symbol.param_symbols[index]
		if binding == INVALID_SYMBOL {
			continue
		}
		if param_mode_is_pointer(symbol_param_mode(e.c, symbol, index)) {
			bind_local(e, binding, fmt.aprintf("%%arg%d", index))
			continue
		}
		if e.abi_foreign {
			bind_local(e, binding, emit_foreign_param_slot(e, parameter, index))
			continue
		}
		slot := fmt.aprintf("%%p%d.%d", index, next_id(e))
		alloca_named(e, slot, llvm_type(e, parameter))
		fmt.sbprintfln(&e.b, "  store %s %%arg%d, ptr %s", llvm_type(e, parameter), index, slot)
		bind_local(e, binding, slot)
	}

	// The result slot starts at zero, so `or_return` can publish into it. An
	// `sret` result writes straight into the caller's storage.
	if result := symbol.result; result != INVALID_TYPE {
		type := e.result_inout ? "ptr" : llvm_type(e, result)
		e.result_slot = e.abi_sret
		if e.result_slot == "" {
			e.result_slot = fmt.aprintf("%%r0.%d", next_id(e))
			alloca_named(e, e.result_slot, type)
		}
		if e.result_inout {
			fmt.sbprintfln(&e.b, "  store ptr null, ptr %s", e.result_slot)
		} else if zero, ok := zero_const(e.c, result); ok {
			fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", type, llvm_const(e, zero, result), e.result_slot)
		}
	}

	// One flag per syntactic defer, set when its registration is reached.
	e.defer_flags = make([]string, literal.defer_count)
	for index in 0 ..< literal.defer_count {
		flag := fmt.aprintf("%%defer%d.%d", index, next_id(e))
		alloca_named(e, flag, "i1")
		e.defer_flags[index] = flag
	}

	// design.md "Parameter semantics and ABI lowering": the callee drops a `move`
	// parameter, in a scope outside the body's.
	push_scope_stmts(e, nil)
	for binding in symbol.param_symbols {
		register_implicit_drop(e, binding)
	}

	emit_scoped_block(e, literal.body)
	if !e.terminated {
		emit_return_values(e, nil)
	}
	fmt.sbprintln(&e.b, "}")
	fmt.sbprintln(&e.b, "")

	body := strings.to_string(e.b)
	e.b = module
	emit_unwind_prologue(e)
	strings.write_string(&e.b, body)
	emit_unwind_thunk(e)
	for text in e.pending {
		strings.write_string(&e.b, text)
	}
	clear(&e.pending)
}

// design.md "Executable startup ABI": `wmain` initializes the arguments, the
// thread, and the providers, in that order, then calls `main`.
@(private = "file")
emit_entry :: proc(e: ^Emitter) {
	entry, found := e.names[e.c.entry_point]
	if !found || entry == "" {
		backend_fail(e, "the validated entry procedure has no emitted name")
		return
	}
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	open_function(e, "define i32 @wmain(i32 %%argc, ptr %%argv)")
	fmt.sbprintln(&e.b, "  call void @loke_rt_v1_args_init(i32 %argc, ptr %argv)")
	fmt.sbprintln(&e.b, "  call void @loke_rt_v1_thread_attach()")
	if any_provider_selected(e.c) {
		fmt.sbprintln(&e.b, "  call void @loke_rt_v1_program_init()")
	}
	fmt.sbprintfln(&e.b, "  call void %s()", entry)
	fmt.sbprintln(&e.b, "  call void @loke_rt_v1_thread_detach()")
	fmt.sbprintln(&e.b, "  ret i32 0")
	fmt.sbprintln(&e.b, "}")
}

// design.md "Build-selected providers": run once, allocator first so the logger
// factory already allocates through it. The runtime keeps the once-only state.
@(private = "file")
emit_program_init :: proc(e: ^Emitter) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	open_function(e, "define void @loke_rt_v1_program_init()")
	go, run := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = call i32 @loke_rt_v1_provider_init_begin()", go)
	fmt.sbprintfln(&e.b, "  %s = icmp ne i32 %s, 0", run, go)
	body, done := new_label(e, "init.run"), new_label(e, "init.done")
	branch_if(e, run, body, done)
	place_label(e, body)

	if allocator := e.c.providers[.Allocator].factory; allocator != INVALID_SYMBOL {
		handle := temp(e)
		fmt.sbprintfln(&e.b, "  %s = call ptr %s()", handle, symbol_name(e, allocator))
		// The runtime rejects a nil or foreign handle.
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_publish_allocator(ptr %s)", handle)
	}
	if logger := e.c.providers[.Logger].factory; logger != INVALID_SYMBOL {
		factory := symbol_of(e.c, logger)
		global, found := e.names[e.c.providers[.Logger].destination]
		if factory == nil || !found {
			backend_fail(e, "the selected logger has no factory or nowhere to be published")
		} else {
			handle := temp(e)
			fmt.sbprintfln(
				&e.b, "  %s = call %s %s()",
				handle, llvm_type(e, factory.result), symbol_name(e, logger),
			)
			store(e, factory.result, handle, global)
		}
	}
	fmt.sbprintln(&e.b, "  call void @loke_rt_v1_provider_init_end()")
	branch(e, done)
	place_label(e, done)
	fmt.sbprintln(&e.b, "  ret void")
	fmt.sbprintln(&e.b, "}")
}

@(private)
next_id :: proc(e: ^Emitter) -> int {
	e.next += 1
	return e.next
}

@(private)
temp :: proc(e: ^Emitter) -> string {
	return fmt.aprintf("%%t%d", next_id(e))
}

@(private)
new_label :: proc(e: ^Emitter, prefix: string) -> string {
	return fmt.aprintf("%s.%d", prefix, next_id(e))
}

// Common instructions, each naming its own result. Types are LLVM text.

@(private)
extract :: proc(e: ^Emitter, aggregate: string, value: string, index: int) -> string {
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", out, aggregate, value, index)
	return out
}

// `into` is "undef" for the first field of a fresh aggregate.
@(private)
insert :: proc(e: ^Emitter, aggregate, into, field_type, value: string, index: int) -> string {
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, %s %s, %d", out, aggregate, into, field_type, value, index)
	return out
}

// A naturally aligned load; an under-aligned place needs `, align N`.
@(private)
load :: proc(e: ^Emitter, type: string, address: string) -> string {
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", out, type, address)
	return out
}

@(private)
alloca :: proc(e: ^Emitter, type: string) -> string {
	out := temp(e)
	alloca_named(e, out, type)
	return out
}

@(private)
alloca_named :: proc(e: ^Emitter, name, type: string) {
	append(&e.prologue, fmt.aprintf("  %s = alloca %s", name, type))
}

// Runtime-sized, so it stays where its count exists.
@(private)
alloca_count :: proc(e: ^Emitter, name, type, count: string) {
	fmt.sbprintfln(&e.b, "  %s = alloca %s, i64 %s", name, type, count)
}

@(private)
gep_field :: proc(e: ^Emitter, aggregate: string, address: string, index: int) -> string {
	out := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = getelementptr inbounds %s, ptr %s, i32 0, i32 %d",
		out, aggregate, address, index,
	)
	return out
}

// The address of element `index`, an i64 operand.
@(private)
gep_at :: proc(e: ^Emitter, element: string, address: string, index: string) -> string {
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = getelementptr inbounds %s, ptr %s, i64 %s", out, element, address, index)
	return out
}

@(private)
place_label :: proc(e: ^Emitter, label: string) {
	if !e.terminated {
		fmt.sbprintfln(&e.b, "  br label %%%s", label)
	}
	fmt.sbprintfln(&e.b, "%s:", label)
	e.terminated = false
}

@(private)
branch :: proc(e: ^Emitter, label: string) {
	if e.terminated {
		return
	}
	fmt.sbprintfln(&e.b, "  br label %%%s", label)
	e.terminated = true
}

@(private)
branch_if :: proc(e: ^Emitter, cond: string, then_label, else_label: string) {
	if e.terminated {
		return
	}
	fmt.sbprintfln(&e.b, "  br i1 %s, label %%%s, label %%%s", cond, then_label, else_label)
	e.terminated = true
}

// Names carry the package's key; the root package's is empty.
@(private)
llvm_global_name :: proc(pkg: ^Package, name: string) -> string {
	return fmt.aprintf("@loke.g.%s%s", mangled_key(pkg), name)
}

@(private = "file")
llvm_proc_name :: proc(pkg: ^Package, name: string) -> string {
	return fmt.aprintf("@loke.p.%s%s", mangled_key(pkg), name)
}

// Whether `name` needs no escaping.
@(private)
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

// Escapes every byte LLVM would need quoted, `$` included, as `$XX`: injective
// and still readable. `dots = false` also escapes `.`, for a part that a `.`
// joins to others.
llvm_safe :: proc(name: string, dots := true, allocator := context.allocator) -> string {
	hex := "0123456789abcdef"
	out := make([dynamic]u8, 0, len(name) + 8, allocator)
	for i in 0 ..< len(name) {
		ch := name[i]
		if llvm_name_byte(ch) && (dots || ch != '.') {
			append(&out, ch)
			continue
		}
		append(&out, '$', hex[ch >> 4], hex[ch & 0x0f])
	}
	return string(out[:])
}

// The key's own dots are escaped: `util.v2` + `f` must not meet `util` + `v2.f`.
@(private = "file")
mangled_key :: proc(pkg: ^Package) -> string {
	if pkg == nil || pkg.key == "" {
		return ""
	}
	return fmt.aprintf("%s.", llvm_safe(pkg.key, dots = false))
}

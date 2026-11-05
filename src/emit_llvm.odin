// LLVM module orchestration, emitter state, procedures, and instruction plumbing.
//
// Part of the textual LLVM backend; see compiler-architecture.md.
package lokec

import "core:fmt"
import "core:mem/virtual"
import "core:strconv"
import "core:strings"

// An `or_return` mapper's error and the hold that drops it until the mapper
// takes it.
@(private)
Mapper_Error :: struct {
	value: string,
	hold:  Deferred,
}

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
	// Every foreign member the naming pass met, in declaration order.
	foreign_symbols: [dynamic]Symbol_Id,
	// Every internal name handed out, across all packages (`claim_name`).
	taken_names:  map[string]bool,
	// What each name asked for at several uses was claimed as (`generated_name`).
	generated_names: map[string]string,
	struct_names: map[Type_Id]string,
	// Every witness table's global, numbered in commit order (`name_witnesses`).
	witness_names: map[^Witness]string,
	// The error each `or_return` mapper is called with, while its failure path
	// is emitted.
	propagated_errors: map[^Expr_Postfix]Mapper_Error,
	// Under `-g`, the span the last location marker named.
	debug_span:   Span,
	// design.md "@(packed)": a place's alignment, by pointer temporary, when it is
	// below the pointee's natural one.
	place_align:  map[string]u64,
	// The function being written; saved and cleared around a nested thunk.
	using fn: Function_State,
	// Thunks and panic-cleanup replays generated mid-body, flushed at the end of
	// the module.
	pending_thunks: [dynamic]string,
	// Interned per type or per name, so each is emitted once.
	container_ops: map[Type_Id]string,
	// The same tables with no element clone: an owned element relocates in.
	container_move_ops: map[Type_Id]string,
	// Insertion members also called with an owned element, which get a
	// consuming body besides the cloning one.
	consuming_ops: map[Symbol_Id]bool,
	container_thunks: map[string]bool,
	literals: map[string]string,
	// The LLVM intrinsics a call has declared, by name.
	intrinsics: map[string]bool,
	globals:  [dynamic]string,
	// design.md "@(cpu_dispatch=<string>)": every procedure body by symbol, the
	// copies for a higher level by name, those still to write, and each level's
	// processor check (`src/emit_llvm_dispatch.odin`).
	bodies:           map[Symbol_Id]^Expr_Proc,
	cpu_copies:       map[Cpu_Copy]string,
	unwritten_copies: [dynamic]Cpu_Copy,
	dispatch_checks:  [Cpu_Level]string,
}

make_emitter :: proc(c: ^Compiler) -> Emitter {
	return Emitter{c = c, b = strings.builder_make()}
}

// The whole checked program as one LLVM module, in memory.
emit_llvm_module :: proc(c: ^Compiler) -> (module: string, ok: bool) {
	context.allocator = virtual.arena_allocator(&c.emission_arena)
	if !validate_emission_dependencies(c) { return "", false }
	// Emission reads the checked program; only the layout cache may change.
	before := semantic_extent(c)
	defer if ok && semantic_extent(c) != before {
		module, ok = "", emission_contract_error(c, "emission added to the checked program")
	}
	e := make_emitter(c)

	reserve_link_names(&e)
	emit_preamble(&e)
	emit_struct_definitions(&e)
	emit_materialized_constants(&e)

	// Every procedure is named before any body refers to it.
	order := package_order(c)
	for id in order {
		name_package_symbols(&e, package_of(c, id))
	}
	name_synth_procs(&e)
	name_witnesses(&e)
	emit_foreign_declarations(&e)
	emit_static_locals(&e)
	for id in order {
		emit_package_items(&e, package_of(c, id))
	}
	emit_synth_procs(&e)
	emit_witnesses(&e)
	emit_cpu_copies(&e)
	// Every module, object builds included: the runtime's `thread_detach` calls it.
	emit_thread_local_teardown(&e)
	emit_sink_bridge(&e)
	// design.md "Build-selected providers": no initializer unless one is selected.
	if any_provider_selected(c) {
		emit_program_init(&e)
	}
	// design.md "Build modes": an object build's host owns the entry.
	if c.build_mode == .Exe {
		emit_entry(&e)
	} else if c.build_mode == .Test {
		emit_test_entry(&e)
	} else if c.target.cpu != .X86_64 {
		emit_object_cpu_check(&e)
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
	if c.debug_info {
		return attach_debug_info(&e, strings.to_string(e.b)), true
	}
	return strings.to_string(e.b), true
}

// Where `break` and `continue` go, and what they owe on the way. Both unwind
// cleanups to `cleanup_depth`, and only the temporary frames and held values made
// since the loop began.
@(private)
Loop_Targets :: struct {
	break_label, continue_label: string,
	cleanup_depth, frames, held: int,
}

// The enclosing function's buffer and state, restored when a nested one ends.
@(private)
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
	// Set while writing a procedure's copy for `copy_cpu`, whose direct calls
	// name copies too (design.md "@(cpu_dispatch=<string>)").
	copying:    bool,
	copy_cpu:   Cpu_Level,
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
	cleanups:    [dynamic][dynamic]Deferred,
	// design.md "Borrows and lifetimes": one frame per full expression, since a
	// value temporary dies at its end.
	temporaries: [dynamic][dynamic]Deferred,
	// Owned values an operation holds while it evaluates its later operands,
	// such as a call's earlier arguments: an exit from one of those operands,
	// `or_return` or an `or_else` exit, drops them on its own path.
	held: [dynamic]Deferred,
	// How many operands that may not run enclose the code being written: the
	// right of `&&` and `||`, a conditional's arms, an `or_else` fallback.
	conditional: int,
	// The innermost loop.
	loop: Loop_Targets,
	// Arguments already bound at the current call, for default expressions.
	param_values: map[Symbol_Id]Bound_Parameter,
	unwind: Unwind_State,
	// Fixed-size allocas, spliced into the entry block so a loop can't grow the stack.
	prologue: [dynamic]string,
	// Large temporaries, shared by the full expressions that need one: taken ones
	// in order, a mark per open full expression, and the free ones.
	large_taken: [dynamic]Large_Slot,
	// One zeroed global per large type that has a zero constant (`large_zero`).
	large_zeros: map[Type_Id]string,
	large_marks: [dynamic]int,
	large_free:  [dynamic]Large_Slot,
	// Per open full expression, the slot holding the stack pointer saved before
	// its first runtime-sized alloca, or "" while it has none.
	stack_saves: [dynamic]string,
}

@(private)
Large_Slot :: struct {
	type, name: string,
}

// `define <signature> {` and the entry label.
@(private)
open_function :: proc(e: ^Emitter, format: string, args: ..any) {
	fmt.sbprintf(&e.b, format, ..args)
	fmt.sbprintln(&e.b, " {")
	fmt.sbprintln(&e.b, "entry:")
}

// A synthesized member's header: its receiver at `%arg0`, after any `%sret`.
@(private)
open_synth_receiver :: proc(e: ^Emitter, name: string, result: Type_Id) {
	open_function(e, "define %s%s %s(%sptr %%arg0)", llvm_linkage(name), llvm_result_type(e, result), name, sret_param(e, result))
}

// A synthesized member's header: its result, any `%sret`, and each parameter at
// `%argN`, then the already spelled `extra` parameters.
@(private)
open_synth_function :: proc(e: ^Emitter, symbol: ^Symbol, name: string, extra := "") {
	fmt.sbprintf(
		&e.b, "define %s%s %s(%s", llvm_linkage(name), llvm_result_type(e, symbol.result, symbol.result_inout),
		name, sret_param(e, symbol.result, symbol.result_inout),
	)
	for _, index in symbol.params {
		if index > 0 {
			fmt.sbprint(&e.b, ", ")
		}
		fmt.sbprintf(&e.b, "%s %%arg%d", synth_param_llvm(e, symbol, index), index)
	}
	open_function(e, "%s)", extra)
}

@(private)
begin_function_emission :: proc(e: ^Emitter) -> Function_Emission {
	state := Function_Emission{parent = e.b, saved = e.fn}
	e.b = strings.builder_make()
	e.fn = {}
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

@(private)
backend_fail :: proc(e: ^Emitter, message: string) {
	if e.failed {
		return
	}
	e.failed = true
	emission_contract_error(e.c, message)
}

@(private = "file")
emit_package_items :: proc(e: ^Emitter, pkg: ^Package) {
	for file in pkg.files {
		for item in file.active_items {
			#partial switch v in item {
			case ^Decl:
				// design.md "Test procedures": only a test build calls one.
				if len(v.symbols) == 0 || symbol_is_template(e.c, v.symbols[0]) || omitted_with_test(e.c, v.symbols[0]) {
					continue
				}
				if literal := decl_proc_literal(v); literal != nil {
					emit_proc(e, v.symbols[0], literal)
				} else {
					emit_global(e, v)
				}
			case ^Item_Impl:
				for member in v.members {
					d, is_decl := member.(^Decl)
					if !is_decl || len(d.symbols) == 0 || symbol_is_template(e.c, d.symbols[0]) {
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
		if !omitted_with_test(e.c, literal.symbol) {
			emit_proc(e, literal.symbol, literal)
		}
	}
	for instance in pkg.instances {
		// A generic method of an instantiated `impl` is still a template.
		if symbol_is_template(e.c, instance.symbol) || omitted_with_test(e.c, instance.symbol) {
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
	if symbol == nil || literal.body == nil || compile_time_only_procedure(e.c, symbol) {
		return
	}
	llvm_name := symbol_name(e, symbol_id)
	if !convention_is_foreign(proc_convention_of(e, symbol)) {
		e.bodies[symbol_id] = literal
		if dispatched(e, symbol) {
			emit_dispatched_proc(e, symbol_id, literal, llvm_name)
		} else {
			emit_proc_definition(e, symbol_id, literal, llvm_name)
		}
		return
	}
	// design.md "Floating-point operators": foreign code may call it in another
	// environment, so its name is the guard, and the body is apart.
	body := entry_body_name(e, llvm_name)
	emit_proc_definition(e, symbol_id, literal, body)
	emit_foreign_entry_guard(e, symbol, llvm_name, body)
}

// design.md "@(cold)": what follows the signature of each function the
// procedure is emitted as, or "". A generic instance's declaration is a clone of
// the template's, attributes and all.
@(private)
cold_attributes :: proc(symbol: ^Symbol) -> string {
	return symbol.decl != nil && has_attribute(symbol.decl.attributes, "cold") ? " cold noinline" : ""
}

// A Loke procedure's parameters as its definition spells them.
@(private)
loke_param_list :: proc(e: ^Emitter, symbol: ^Symbol, inout: bool) -> string {
	params := make([dynamic]string)
	if returns_sret(e, symbol.result, inout) {
		e.abi_sret = "%sret"
		append(&params, "ptr %sret")
	}
	for parameter, index in symbol.params {
		mode := symbol_param_mode(e.c, symbol, index)
		append(&params, fmt.aprintf("%s%s %%arg%d", param_llvm(e, parameter, mode), param_nonnull(e, parameter, mode), index))
	}
	return strings.join(params[:], ", ")
}

// Calls `callee` and returns what it returned.
@(private)
emit_forward_ret :: proc(e: ^Emitter, call_word, result, callee, arguments: string) {
	if result == "void" {
		fmt.sbprintfln(&e.b, "  %s void %s(%s)", call_word, callee, arguments)
		fmt.sbprintln(&e.b, "  ret void")
		return
	}
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = %s %s %s(%s)", out, call_word, result, callee, arguments)
	fmt.sbprintfln(&e.b, "  ret %s %s", result, out)
}

// The procedure's own function, under `llvm_name`; a foreign-convention one is
// a guard's body, which no caller may inline (`emit_foreign_entry_guard`). With
// `copy_cpu`, the copy compiled for that level.
@(private)
emit_proc_definition :: proc(
	e: ^Emitter, symbol_id: Symbol_Id, literal: ^Expr_Proc, llvm_name: string, copy_cpu := Maybe(Cpu_Level){},
) {
	symbol := symbol_of(e.c, symbol_id)
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	e.copy_cpu, e.copying = copy_cpu.?

	e.result_type = symbol.result
	e.result_inout = result_inout_of(e, symbol.proc_type)
	e.abi_foreign = convention_is_foreign(proc_convention_of(e, symbol))

	if e.abi_foreign {
		emit_foreign_signature(e, symbol, llvm_name)
	} else {
		emit_loke_signature(e, symbol, llvm_name)
	}
	debug_mark_proc(e, symbol_id)
	fmt.sbprintln(&e.b, "entry:")
	header := begin_generated_frame(e, llvm_name)

	bind_parameters(e, symbol)
	open_result_slot(e, symbol)

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
		emit_epilogue(e)
	}
	fmt.sbprintln(&e.b, "}")
	fmt.sbprintln(&e.b, "")
	end_generated_frame(e, header)
}

@(private = "file")
emit_loke_signature :: proc(e: ^Emitter, symbol: ^Symbol, llvm_name: string) {
	fmt.sbprintfln(
		&e.b, "define %s%s %s(%s)%s%s {{",
		llvm_linkage(llvm_name), llvm_result_type(e, symbol.result, e.result_inout), llvm_name,
		loke_param_list(e, symbol, e.result_inout), cold_attributes(symbol), copy_attributes(e),
	)
}

// A value parameter gets its own storage; a pointer-mode one is already an
// alias (design.md "Receiver forms").
@(private = "file")
bind_parameters :: proc(e: ^Emitter, symbol: ^Symbol) {
	for parameter, index in symbol.params {
		binding := symbol.param_symbols[index]
		if binding == INVALID_SYMBOL {
			continue
		}
		if param_mode_is_pointer(symbol_param_mode(e.c, symbol, index)) {
			// `self: ^Self` binds the address itself, which needs a slot.
			if bound := symbol_of(e.c, binding); bound != nil && bound.type != parameter {
				slot := fmt.aprintf("%%p%d.%d", index, next_id(e))
				alloca_named(e, slot, "ptr")
				fmt.sbprintfln(&e.b, "  store ptr %%arg%d, ptr %s", index, slot)
				bind_local(e, binding, slot)
				continue
			}
			bind_local(e, binding, fmt.aprintf("%%arg%d", index))
			continue
		}
		if e.abi_foreign {
			bind_local(e, binding, emit_foreign_param_slot(e, parameter, index))
			continue
		}
		slot := fmt.aprintf("%%p%d.%d", index, next_id(e))
		alloca_named(e, slot, llvm_type(e, parameter))
		store(e, parameter, fmt.aprintf("%%arg%d", index), slot)
		bind_local(e, binding, slot)
	}
}

// The result slot starts at zero, so `or_return` can publish into it. An `sret`
// result writes straight into the caller's storage.
@(private = "file")
open_result_slot :: proc(e: ^Emitter, symbol: ^Symbol) {
	result := symbol.result
	if result == INVALID_TYPE {
		return
	}
	type := e.result_inout ? "ptr" : llvm_type(e, result)
	e.result_slot = e.abi_sret
	if e.result_slot == "" {
		e.result_slot = fmt.aprintf("%%r0.%d", next_id(e))
		alloca_named(e, e.result_slot, type)
	}
	if e.result_inout {
		fmt.sbprintfln(&e.b, "  store ptr null, ptr %s", e.result_slot)
	} else if zero, ok := llvm_zero(e, result); ok {
		store(e, result, zero, e.result_slot)
	}
}

@(private)
next_id :: proc(e: ^Emitter) -> int {
	e.next += 1
	return e.next
}

@(private)
temp :: proc(e: ^Emitter) -> string {
	return numbered_name("%t", "", next_id(e))
}

// The LLVM intrinsic `key`, declared on its first use.
@(private)
declare_intrinsic :: proc(e: ^Emitter, key, result, parameters: string) {
	if key not_in e.intrinsics {
		e.intrinsics[key] = true
		append(&e.globals, fmt.aprintf("declare %s @%s(%s)\n", result, key, parameters))
	}
}

@(private)
new_label :: proc(e: ^Emitter, prefix: string) -> string {
	return numbered_name(prefix, ".", next_id(e))
}

// `prefix`, `separator`, and `id` in decimal. Nearly every instruction names
// a value or label, so this skips `fmt`'s format parsing.
@(private = "file")
numbered_name :: proc(prefix, separator: string, id: int) -> string {
	digits: [24]u8
	return strings.concatenate({prefix, separator, strconv.write_int(digits[:], i64(id), 10)})
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

// The address of part `index`: a struct field or an array element.
// Prefer it to `gep_field` for a Loke record, whose field may be under-aligned.
@(private)
element_address :: proc(e: ^Emitter, owner: Type_Id, base: string, index: int) -> string {
	info := underlying_info(e.c, owner)
	if info != nil && info.kind == .Array {
		out := temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = getelementptr inbounds %s, ptr %s, i64 0, i64 %d",
			out, llvm_type(e, owner), base, index,
		)
		if align, known := e.place_align[base]; known {
			e.place_align[out] = align
		}
		return out
	}
	out := gep_field(e, llvm_type(e, owner), base, index)
	// design.md "@(packed)": a packed field is loaded and stored unaligned.
	if info != nil && info.kind == .Struct && index < len(info.fields) {
		if field := symbol_of(e.c, info.fields[index]); field != nil {
			record_field_align(e, owner, base, out, field.type)
		}
	}
	return out
}

// The address of element `index`, an i64 operand.
@(private)
gep_at :: proc(e: ^Emitter, element: string, address: string, index: string) -> string {
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = getelementptr inbounds %s, ptr %s, i64 %s", out, element, address, index)
	// An element of under-aligned storage, such as an array in a packed struct,
	// is as unaligned as the storage.
	if align, known := e.place_align[address]; known {
		e.place_align[out] = align
	}
	return out
}

@(private)
place_label :: proc(e: ^Emitter, label: string) {
	branch(e, label)
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

// A branch whose `then_label` is a failure path, taken only on the way to a
// panic. The weights state what the cold callee would let LLVM infer; the
// tuple is written inline so that it takes no number from the debug metadata.
@(private)
branch_if_unlikely :: proc(e: ^Emitter, cond: string, then_label, else_label: string) {
	if e.terminated {
		return
	}
	fmt.sbprintfln(
		&e.b, `  br i1 %s, label %%%s, label %%%s, !prof !{{!"branch_weights", i32 1, i32 1048575}`,
		cond, then_label, else_label,
	)
	e.terminated = true
}


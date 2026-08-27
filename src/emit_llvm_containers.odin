// Container operation tables, construction, and synthesized runtime bodies.
//
// Part of the textual LLVM backend; see compiler-architecture.md.
package lokec

import "core:fmt"
import "core:strings"

@(private)
emit_container_declarations :: proc(e: ^Emitter) {
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_dyn_reserve(ptr, ptr, i64)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_dyn_bind(ptr)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_dyn_append(ptr, ptr, ptr, i64)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_dyn_insert(ptr, ptr, i64, ptr, i64)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_dyn_pop(ptr, ptr, ptr)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_dyn_remove(ptr, ptr, i64, ptr, i32)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_dyn_clear(ptr, ptr)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_dyn_resize(ptr, ptr, i64)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_dyn_shrink(ptr, ptr, i64)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_dyn_clone(ptr, ptr, ptr, ptr)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_dyn_drop(ptr, ptr)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_map_reserve(ptr, ptr, i64)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_map_clone(ptr, ptr, ptr, ptr)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_map_drop(ptr, ptr)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_checked_add(i64, i64, ptr)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_checked_bytes(i64, i64, ptr)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_container_fault(ptr)")
	fmt.sbprintln(&e.b, "declare i64 @loke_rt_v1_hash_bytes(ptr, i64, i64)")
	fmt.sbprintln(&e.b, "declare i64 @loke_rt_v1_map_scan(ptr, ptr, i64, ptr, ptr)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_map_bind(ptr)")
	fmt.sbprintln(&e.b, "declare ptr @loke_rt_v1_map_find(ptr, ptr, ptr)")
	fmt.sbprintln(&e.b, "declare ptr @loke_rt_v1_map_entry(ptr, ptr, ptr, ptr)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_map_remove(ptr, ptr, ptr, ptr)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_map_clear(ptr, ptr)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_map_shrink(ptr, ptr, i64)")
}

// The operation table for one concrete container type, made once and reused.
// The element and key thunks it points at are generated alongside it, so asking
// for the table is the only thing a caller has to do.
@(private)
container_ops_global :: proc(e: ^Emitter, type: Type_Id) -> string {
	under := type_underlying(e.c, type)
	if existing, found := e.container_ops[under]; found {
		return existing
	}
	name := fmt.aprintf("@.loke.ops.%d", int(under))
	// Registered before the thunks are generated: a container whose element is
	// itself a container would otherwise recurse forever.
	e.container_ops[under] = name

	element := container_element(e.c, under)
	key := container_key(e.c, under)
	elem_drop := container_drop_thunk(e, element)
	elem_clone := container_clone_thunk(e, element)
	key_drop, key_clone, key_hash, key_equal := "null", "null", "null", "null"
	key_size, key_align := u64(0), u64(0)
	if key != INVALID_TYPE {
		key_drop = container_drop_thunk(e, key)
		key_clone = container_clone_thunk(e, key)
		key_hash = container_hash_thunk(e, key)
		key_equal = container_equal_thunk(e, key)
		key_size, key_align = type_size(e.c, key), type_align(e.c, key)
	}
	// `{` is a directive to core:fmt, so the row is concatenated rather than
	// formatted.
	b := strings.builder_make()
	fmt.sbprintf(&b, "%s = private unnamed_addr constant %s ", name, CONTAINER_OPS_TYPE)
	strings.write_string(&b, "{")
	fmt.sbprintf(
		&b, " i64 %d, i64 %d, ptr %s, ptr %s, i64 %d, i64 %d, ptr %s, ptr %s, ptr %s, ptr %s }\n",
		type_size(e.c, element), type_align(e.c, element), elem_drop, elem_clone,
		key_size, key_align, key_drop, key_clone, key_hash, key_equal,
	)
	append(&e.globals, strings.to_string(b))
	return name
}

// A NULL `drop` means the part is trivially destroyed, which is what keeps the
// C loop out of the way entirely for a `[dynamic]int`.
@(private = "file")
container_drop_thunk :: proc(e: ^Emitter, part: Type_Id) -> string {
	if part == INVALID_TYPE || !emit_lifecycle(e, part).managed {
		return "null"
	}
	name := fmt.aprintf("@loke.cdrop.%d", int(type_underlying(e.c, part)))
	if e.container_thunks[name] {
		return name
	}
	e.container_thunks[name] = true
	saved_body, saved_terminated := e.b, e.terminated
	e.b, e.terminated = strings.builder_make(), false
	// `{` is a directive to core:fmt, so the brace is printed separately.
	fmt.sbprintf(&e.b, "define private void %s(ptr %%p)", name)
	fmt.sbprintln(&e.b, " {")
	fmt.sbprintln(&e.b, "entry:")
	emit_drop_place(e, part, "%p")
	fmt.sbprintln(&e.b, "  ret void")
	fmt.sbprintln(&e.b, "}")
	fmt.sbprintln(&e.b, "")
	text := hoist_fixed_allocas(strings.to_string(e.b))
	e.b, e.terminated = saved_body, saved_terminated
	append(&e.pending_thunks, text)
	return name
}

// A NULL `clone` means the part's clone is the copy its representation already
// is, so the C helper memcpys the whole run instead of calling back per element.
@(private = "file")
container_clone_thunk :: proc(e: ^Emitter, part: Type_Id) -> string {
	if part == INVALID_TYPE || !emit_lifecycle(e, part).managed {
		return "null"
	}
	name := fmt.aprintf("@loke.cclone.%d", int(type_underlying(e.c, part)))
	if e.container_thunks[name] {
		return name
	}
	e.container_thunks[name] = true
	saved_body, saved_terminated := e.b, e.terminated
	e.b, e.terminated = strings.builder_make(), false
	fmt.sbprintf(&e.b, "define private i32 %s(ptr %%out, ptr %%src, ptr %%a)", name)
	fmt.sbprintln(&e.b, " {")
	fmt.sbprintln(&e.b, "entry:")
	ok := emit_try_clone_into(e, part, "%out", "%src", "%a")
	widened := temp(e)
	fmt.sbprintfln(&e.b, "  %s = zext i1 %s to i32", widened, ok)
	fmt.sbprintfln(&e.b, "  ret i32 %s", widened)
	fmt.sbprintln(&e.b, "}")
	fmt.sbprintln(&e.b, "")
	text := hoist_fixed_allocas(strings.to_string(e.b))
	e.b, e.terminated = saved_body, saved_terminated
	append(&e.pending_thunks, text)
	return name
}

// The concrete operation table *freezes* the key's `==`/`hash` selection, so
// a map that travels between
// packages keeps one policy. The checker has already rejected a key with no
// coherent inherent pair, so this only has to emit whichever pair it settled on.
@(private = "file")
container_hash_thunk :: proc(e: ^Emitter, key: Type_Id) -> string {
	name := fmt.aprintf("@loke.chash.%d", int(type_underlying(e.c, key)))
	if e.container_thunks[name] {
		return name
	}
	e.container_thunks[name] = true
	saved_body, saved_terminated := e.b, e.terminated
	e.b, e.terminated = strings.builder_make(), false
	fmt.sbprintf(&e.b, "define private i64 %s(ptr %%p, i64 %%seed)", name)
	fmt.sbprintln(&e.b, " {")
	fmt.sbprintln(&e.b, "entry:")
	value := load(e, llvm_type(e, key), "%p")
	out := ""
	if hook := key_policy_member(e, key, false); hook != INVALID_SYMBOL {
		out = temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i64 %s(%s %s, i64 %%seed)",
			out, e.names[hook], llvm_type(e, key), value,
		)
	} else {
		out = emit_hash_value(e, key, value, "%seed")
	}
	fmt.sbprintfln(&e.b, "  ret i64 %s", out)
	fmt.sbprintln(&e.b, "}")
	fmt.sbprintln(&e.b, "")
	text := hoist_fixed_allocas(strings.to_string(e.b))
	e.b, e.terminated = saved_body, saved_terminated
	append(&e.pending_thunks, text)
	return name
}

@(private = "file")
container_equal_thunk :: proc(e: ^Emitter, key: Type_Id) -> string {
	name := fmt.aprintf("@loke.cequal.%d", int(type_underlying(e.c, key)))
	if e.container_thunks[name] {
		return name
	}
	e.container_thunks[name] = true
	saved_body, saved_terminated := e.b, e.terminated
	e.b, e.terminated = strings.builder_make(), false
	fmt.sbprintf(&e.b, "define private i32 %s(ptr %%a, ptr %%b)", name)
	fmt.sbprintln(&e.b, " {")
	fmt.sbprintln(&e.b, "entry:")
	llvm := llvm_type(e, key)
	left := load(e, llvm, "%a")
	right := load(e, llvm, "%b")
	same := ""
	if hook := key_policy_member(e, key, true); hook != INVALID_SYMBOL {
		same = temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i1 %s(%s %s, %s %s)",
			same, e.names[hook], llvm, left, llvm, right,
		)
	} else {
		same = emit_compare(e, .Eq_Eq, key, left, right)
	}
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = zext i1 %s to i32", out, same)
	fmt.sbprintfln(&e.b, "  ret i32 %s", out)
	fmt.sbprintln(&e.b, "}")
	fmt.sbprintln(&e.b, "")
	text := hoist_fixed_allocas(strings.to_string(e.b))
	e.b, e.terminated = saved_body, saved_terminated
	append(&e.pending_thunks, text)
	return name
}

// The key type's own inherent `hash` or `operator(==)`, or INVALID_SYMBOL when
// the compiler supplies the pair. An extension member is never one of these.
@(private = "file")
key_policy_member :: proc(e: ^Emitter, key: Type_Id, want_equal: bool) -> Symbol_Id {
	policy := resolved_map_key_policy(e.c, key)
	if policy.kind == .Unresolved {
		backend_fail(e, "a map key operation was not resolved during checking")
	}
	return want_equal ? policy.equal : policy.hash
}

// Writes a container declaration's written `via` into its header at the
// declaration point. A declaration with no policy is left allocator-unbound,
// which is what makes the lazy default binding observable.
@(private)
emit_eager_via_binding :: proc(e: ^Emitter, symbol_id: Symbol_Id, address: string) {
	sym := symbol_of(e.c, symbol_id)
	if sym == nil || sym.via == nil || !type_is_container(e.c, sym.type) {
		return
	}
	provider, slot := emit_expr(e, sym.via), temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = getelementptr inbounds %s, ptr %s, i32 0, i32 %d",
		slot, CONTAINER_TYPE, address, CONTAINER_ALLOC,
	)
	fmt.sbprintfln(&e.b, "  store ptr %s, ptr %s", provider, slot)
}

// The provider a construction into one destination selects: the declaration's
// written `via`, or the default when it has no policy. The policy belongs to
// the declaration, so this is the destination's own symbol rather than
// anything the source value carries.
@(private)
emit_destination_allocator :: proc(e: ^Emitter, symbol_id: Symbol_Id) -> string {
	written := symbol_via_allocator(e.c, symbol_id)
	return written == nil ? RT_DEFAULT_ALLOCATOR : emit_expr(e, written)
}

// The allocator a call selected: the one it was given, or the default provider
// when the argument was omitted. The checker already bound whichever it was, so
// this never re-derives the choice.
@(private)
emit_allocator_operand :: proc(e: ^Emitter, v: ^Expr_Call, index: int) -> string {
	if len(v.bound) > index {
		return emit_expr(e, v.bound[index])
	}
	return RT_DEFAULT_ALLOCATOR
}

// `free_all` frees every allocation in the allocator's region, and not every
// allocator supports it (design.md). It is one call through the provider's
// reset callback, never a guessed sequence of `free` calls: only the provider
// knows what its region contains. A provider that answers "no region" fails at
// run time — a different thing from the compile-time rejection when a dependant
// would survive the reset.
@(private)
emit_region_reset :: proc(e: ^Emitter, v: ^Expr_Call) {
	handle := emit_expr(e, v.bound[0])
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_reset(ptr %s)", handle)
}

// `[dynamic]T{a, b, c}` over the header this expression has already zeroed.
//
// Each element is appended as soon as it is evaluated, so the container itself
// owns the initialized prefix. A temporary unwind action covers that prefix
// while later expressions run; destination ownership takes over only after the
// complete literal has been built.
@(private)
emit_dynamic_literal_into :: proc(e: ^Emitter, v: ^Expr_Composite, address: string, element: Type_Id) {
	if len(v.elements) == 0 {
		return
	}
	ops := container_ops_global(e, v.type)
	// The destination's own policy is written before the first reservation, so
	// the literal never allocates through a default-backed provider first.
	if v.via != nil {
		provider, slot := emit_expr(e, v.via), temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = getelementptr inbounds %s, ptr %s, i32 0, i32 %d",
			slot, CONTAINER_TYPE, address, CONTAINER_ALLOC,
		)
		fmt.sbprintfln(&e.b, "  store ptr %s, ptr %s", provider, slot)
	}
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_dyn_bind(ptr %s)", address)
	reserved := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call i32 @loke_rt_v1_dyn_reserve(ptr %s, ptr %s, i64 %d)",
		reserved, address, ops, len(v.elements),
	)
	emit_container_policy_failure(e, address, reserved)
	cleanup := begin_temporary_drop(e, v.type, address)

	slot := alloca(e, llvm_type(e, element))
	for written, index in v.elements {
		value := emit_expr(e, written.value)
		if index < len(v.element_clones) && v.element_clones[index] {
			value = emit_clone_value(e, element, value)
		}
		store(e, element, value, slot)
		status := temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i32 @loke_rt_v1_dyn_append(ptr %s, ptr %s, ptr %s, i64 1)",
			status, address, ops, slot,
		)
		emit_container_policy_failure(e, address, status)
		// The staged copy was cloned into the container, so this frame still owns
		// the temporary it appended from.
		emit_drop_place(e, element, slot)
	}
	finish_temporary_drop(e, cleanup)
}

// `map[K]V{ key = value, ... }` over the header this expression has already
// zeroed. Each entry is inserted as soon as it is evaluated, so a temporary
// unwind action lets the map destroy the prefix if a later key/value panics.
@(private)
emit_map_literal_into :: proc(e: ^Emitter, v: ^Expr_Composite, address: string, key, element: Type_Id) {
	if len(v.elements) == 0 {
		return
	}
	ops := container_ops_global(e, v.type)
	if v.via != nil {
		provider, slot := emit_expr(e, v.via), temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = getelementptr inbounds %s, ptr %s, i32 0, i32 %d",
			slot, CONTAINER_TYPE, address, CONTAINER_ALLOC,
		)
		fmt.sbprintfln(&e.b, "  store ptr %s, ptr %s", provider, slot)
	}
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_map_bind(ptr %s)", address)
	reserved := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call i32 @loke_rt_v1_map_reserve(ptr %s, ptr %s, i64 %d)",
		reserved, address, ops, len(v.elements),
	)
	emit_container_policy_failure(e, address, reserved)
	cleanup := begin_temporary_drop(e, v.type, address)

	for written, index in v.elements {
		key_slot := alloca(e, llvm_type(e, key))
		store(e, key, emit_expr(e, written.key), key_slot)
		value := emit_expr(e, written.value)
		if index < len(v.element_clones) && v.element_clones[index] {
			value = emit_clone_value(e, element, value)
		}
		place := emit_map_entry(e, ops, address, key_slot)
		emit_drop_place(e, key, key_slot)
		missing := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", missing, place)
		fail_label, store_label, done_label :=
			new_label(e, "mlit.fail"), new_label(e, "mlit.store"), new_label(e, "mlit.done")
		branch_if(e, missing, fail_label, store_label)
		place_label(e, fail_label)
		provider, slot := temp(e), temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = getelementptr inbounds %s, ptr %s, i32 0, i32 %d",
			slot, CONTAINER_TYPE, address, CONTAINER_ALLOC,
		)
		fmt.sbprintfln(&e.b, "  %s = load ptr, ptr %s", provider, slot)
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_alloc_failed(ptr %s)", provider)
		branch(e, done_label)
		place_label(e, store_label)
		// A duplicate key replaces its value, so whatever the slot held goes first.
		emit_drop_place(e, element, place)
		store(e, element, value, place)
		branch(e, done_label)
		place_label(e, done_label)
		e.terminated = false
	}
	finish_temporary_drop(e, cleanup)
}

// A container operation with no result to report through applies the provider's
// own failure policy, exactly as an implicit allocation does.
@(private = "file")
emit_container_policy_failure :: proc(e: ^Emitter, header, status: string) {
	failed := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i32 %s, 0", failed, status)
	fail_label, done_label := new_label(e, "clit.fail"), new_label(e, "clit.done")
	branch_if(e, failed, fail_label, done_label)
	place_label(e, fail_label)
	slot := gep_field(e, CONTAINER_TYPE, header, CONTAINER_ALLOC)
	provider := load(e, "ptr", slot)
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_alloc_failed(ptr %s)", provider)
	branch(e, done_label)
	place_label(e, done_label)
	e.terminated = false
}

// ------------------------------------------------------- provider bodies --

// One contributed `mem.Arena`/`mem.Scratch` operation. The Loke value is one
// pointer to an address-stable control block, so each of these is a single
// runtime call and an `insertvalue`.
@(private)
emit_synth_provider_op :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	provider := llvm_type(e, symbol.results[0] == TYPE_ALLOCATOR ? symbol.params[0] : symbol.results[0])
	result := llvm_result_type(e, symbol.results, nil)
	fmt.sbprintf(&e.b, "define %s %s(", result, name)
	for parameter, index in symbol.params {
		if index > 0 {
			fmt.sbprint(&e.b, ", ")
		}
		fmt.sbprintf(&e.b, "%s %%arg%d", llvm_type(e, parameter), index)
	}
	fmt.sbprintln(&e.b, ") {")
	fmt.sbprintln(&e.b, "entry:")
	e.terminated = false

	switch symbol.provider_op {
	case .None:
	case .Open:
		opened, out := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = call ptr @loke_rt_v1_arena_open(ptr %%arg0)", opened)
		emit_provider_open_check(e, opened, "%arg0")
		fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, ptr %s, %d", out, provider, opened, PROVIDER_CONTROL)
		fmt.sbprintfln(&e.b, "  ret %s %s", provider, out)

	case .Open_Fixed:
		// Fixed storage cannot fail for want of memory. A buffer too small for the
		// control block is a program fault raised by the runtime.
		buffer := llvm_type(e, symbol.params[0])
		data := extract(e, buffer, "%arg0", SLICE_DATA)
		length := extract(e, buffer, "%arg0", SLICE_LEN)
		opened, out := temp(e), temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call ptr @loke_rt_v1_arena_open_fixed(ptr %s, i64 %s)", opened, data, length,
		)
		fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, ptr %s, %d", out, provider, opened, PROVIDER_CONTROL)
		fmt.sbprintfln(&e.b, "  ret %s %s", provider, out)

	case .Try_Open:
		opened, value, first, failed, error, out := temp(e), temp(e), temp(e), temp(e), temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = call ptr @loke_rt_v1_arena_open(ptr %%arg0)", opened)
		fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, ptr %s, %d", value, provider, opened, PROVIDER_CONTROL)
		fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, %s %s, 0", first, result, provider, value)
		fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", failed, opened)
		fmt.sbprintfln(
			&e.b, "  %s = zext i1 %s to %s", error, failed, llvm_type(e, TYPE_ALLOCATOR_ERROR),
		)
		fmt.sbprintfln(
			&e.b, "  %s = insertvalue %s %s, %s %s, 1",
			out, result, first, llvm_type(e, TYPE_ALLOCATOR_ERROR), error,
		)
		fmt.sbprintfln(&e.b, "  ret %s %s", result, out)

	case .Handle:
		control := extract(e, provider, "%arg0", PROVIDER_CONTROL)
		handle := temp(e)
		fmt.sbprintfln(&e.b, "  %s = call ptr @loke_rt_v1_arena_allocator(ptr %s)", handle, control)
		fmt.sbprintfln(&e.b, "  ret ptr %s", handle)
	}
	fmt.sbprintln(&e.b, "}")
	e.terminated = true
}

@(private = "file")
emit_provider_open_check :: proc(e: ^Emitter, control, allocator: string) {
	failed := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", failed, control)
	fail, done := new_label(e, "arena.failed"), new_label(e, "ok")
	branch_if(e, failed, fail, done)
	place_label(e, fail)
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_alloc_failed(ptr %s)", allocator)
	fmt.sbprintln(&e.b, "  unreachable")
	e.terminated = true
	place_label(e, done)
}

// ------------------------------------------------------ container bodies --

// One contributed container operation. Every one of them is a call into the
// versioned C helper with this type's operation table; what differs is how the
// arguments arrive and what comes back.
//
// A fallible operation has two forms. The `try_` one returns the error and the
// caller decides; the ordinary one has nowhere to report it, so it applies the
// *allocator's* failure policy, which is what design.md's "Allocation failure"
// requires of an implicit allocation.
@(private)
emit_synth_container_op :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	container := symbol.params[0]
	element := container_element(e.c, container)
	element_llvm := llvm_type(e, element)
	ops := container_ops_global(e, container)
	fallible := len(symbol.results) == 1 && symbol.results[0] == TYPE_ALLOCATOR_ERROR

	result := llvm_result_type(e, symbol.results, nil)
	fmt.sbprintf(&e.b, "define %s %s(", result, name)
	for parameter, index in symbol.params {
		if index > 0 {
			fmt.sbprint(&e.b, ", ")
		}
		type := index == 0 ? "ptr" : llvm_type(e, parameter)
		fmt.sbprintf(&e.b, "%s %%arg%d", type, index)
	}
	fmt.sbprintln(&e.b, ") {")
	fmt.sbprintln(&e.b, "entry:")
	e.terminated = false

	// A single value entering the container is spilled so the helper can read it
	// through a pointer, exactly as it reads a `..T` pack's storage.
	value_storage :: proc(e: ^Emitter, element: Type_Id, argument: string) -> string {
		slot := alloca(e, llvm_type(e, element))
		fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", llvm_type(e, element), argument, slot)
		return slot
	}

	status := ""
	switch symbol.container_op {
	case .Append, .Try_Append:
		data, count := temp(e), temp(e)
		pack := llvm_type(e, symbol.params[1])
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %%arg1, %d", data, pack, SLICE_DATA)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %%arg1, %d", count, pack, SLICE_LEN)
		status = temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i32 @loke_rt_v1_dyn_append(ptr %%arg0, ptr %s, ptr %s, i64 %s)",
			status, ops, data, count,
		)

	case .Insert, .Try_Insert:
		slot := value_storage(e, element, "%arg2")
		status = temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i32 @loke_rt_v1_dyn_insert(ptr %%arg0, ptr %s, i64 %%arg1, ptr %s, i64 1)",
			status, ops, slot,
		)
		// The argument was a borrowed copy of the caller's value and the helper
		// cloned from it, so this frame still owns it.
		emit_drop_place(e, element, slot)

	case .Pop:
		out := alloca(e, element_llvm)
		found := temp(e)
		fmt.sbprintfln(&e.b, "  %s = call i32 @loke_rt_v1_dyn_pop(ptr %%arg0, ptr %s, ptr %s)", found, ops, out)
		value, ok, first, pair := temp(e), temp(e), temp(e), optional_pair_type(element_llvm)
		fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", value, element_llvm, out)
		fmt.sbprintfln(&e.b, "  %s = icmp ne i32 %s, 0", ok, found)
		fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, %s %s, 0", first, pair, element_llvm, value)
		built := temp(e)
		fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, i1 %s, 1", built, pair, first, ok)
		fmt.sbprintfln(&e.b, "  ret %s %s", pair, built)
		fmt.sbprintln(&e.b, "}")
		return

	case .Remove, .Remove_Unordered:
		out := alloca(e, element_llvm)
		fmt.sbprintfln(
			&e.b, "  call void @loke_rt_v1_dyn_remove(ptr %%arg0, ptr %s, i64 %%arg1, ptr %s, i32 %d)",
			ops, out, symbol.container_op == .Remove_Unordered ? 1 : 0,
		)
		value := load(e, element_llvm, out)
		fmt.sbprintfln(&e.b, "  ret %s %s", element_llvm, value)
		fmt.sbprintln(&e.b, "}")
		return

	case .Clear:
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_dyn_clear(ptr %%arg0, ptr %s)", ops)
		fmt.sbprintln(&e.b, "  ret void")
		fmt.sbprintln(&e.b, "}")
		return

	case .Resize, .Try_Resize:
		status = temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i32 @loke_rt_v1_dyn_resize(ptr %%arg0, ptr %s, i64 %%arg1)", status, ops,
		)

	case .Reserve, .Try_Reserve:
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_dyn_bind(ptr %%arg0)")
		status = temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i32 @loke_rt_v1_dyn_reserve(ptr %%arg0, ptr %s, i64 %%arg1)", status, ops,
		)

	case .Shrink, .Try_Shrink:
		status = temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i32 @loke_rt_v1_dyn_shrink(ptr %%arg0, ptr %s, i64 %%arg1)", status, ops,
		)

	case .Map_Find:
		// Returns a pointer to the existing value and `true`, or `nil` and `false`;
		// never inserts (design.md).
		slot := value_storage(e, container_key(e.c, container), "%arg1")
		found, ok := temp(e), temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call ptr @loke_rt_v1_map_find(ptr %%arg0, ptr %s, ptr %s)", found, ops, slot,
		)
		emit_drop_place(e, container_key(e.c, container), slot)
		fmt.sbprintfln(&e.b, "  %s = icmp ne ptr %s, null", ok, found)
		pair, first, built := optional_pair_type("ptr"), temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, ptr %s, 0", first, pair, found)
		fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, i1 %s, 1", built, pair, first, ok)
		fmt.sbprintfln(&e.b, "  ret %s %s", pair, built)
		fmt.sbprintln(&e.b, "}")
		return

	case .Map_Try_Insert:
		key_type := container_key(e.c, container)
		// Stage the value clone before asking the runtime for an inserting place.
		// A fallible clone must leave an existing entry untouched, and must not
		// publish a new key whose value could not be constructed.
		allocator_slot := gep_field(e, CONTAINER_TYPE, "%arg0", CONTAINER_ALLOC)
		bound_allocator := load(e, "ptr", allocator_slot)
		unbound, allocator := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", unbound, bound_allocator)
		fmt.sbprintfln(
			&e.b, "  %s = select i1 %s, ptr %s, ptr %s",
			allocator, unbound, RT_DEFAULT_ALLOCATOR, bound_allocator,
		)
		staged := alloca(e, element_llvm)
		cloned := "true"
		if emit_lifecycle(e, element).managed {
			source := value_storage(e, element, "%arg2")
			cloned = emit_try_clone_into(e, element, staged, source, allocator)
		} else {
			store(e, element, "%arg2", staged)
		}
		clone_ready, clone_failed := new_label(e, "mins.cloned"), new_label(e, "mins.clone_failed")
		branch_if(e, cloned, clone_ready, clone_failed)
		place_label(e, clone_failed)
		fmt.sbprintfln(&e.b, "  ret %s 1", result)
		e.terminated = true

		place_label(e, clone_ready)
		key_slot := value_storage(e, key_type, "%arg1")
		place := emit_map_entry(e, ops, "%arg0", key_slot)
		emit_drop_place(e, key_type, key_slot)
		missing, ok_label, failed_label := temp(e), new_label(e, "mins.ok"), new_label(e, "mins.failed")
		fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", missing, place)
		branch_if(e, missing, failed_label, ok_label)
		place_label(e, failed_label)
		emit_drop_place(e, element, staged)
		fmt.sbprintfln(&e.b, "  ret %s 1", result)
		e.terminated = true

		place_label(e, ok_label)
		// The clone is complete, so replacement can now commit without a failure
		// point between destroying the old value and publishing the new one.
		emit_drop_place(e, element, place)
		stored := load(e, element_llvm, staged)
		store(e, element, stored, place)
		fmt.sbprintfln(&e.b, "  ret %s 0", result)
		fmt.sbprintln(&e.b, "}")
		e.terminated = true
		return

	case .Map_Remove:
		key_type := container_key(e.c, container)
		key_slot := value_storage(e, key_type, "%arg1")
		out := alloca(e, element_llvm)
		found := temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i32 @loke_rt_v1_map_remove(ptr %%arg0, ptr %s, ptr %s, ptr %s)",
			found, ops, key_slot, out,
		)
		emit_drop_place(e, key_type, key_slot)
		value := load(e, element_llvm, out)
		ok := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp ne i32 %s, 0", ok, found)
		pair, first, built := optional_pair_type(element_llvm), temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, %s %s, 0", first, pair, element_llvm, value)
		fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, i1 %s, 1", built, pair, first, ok)
		fmt.sbprintfln(&e.b, "  ret %s %s", pair, built)
		fmt.sbprintln(&e.b, "}")
		return

	case .Map_Clear:
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_map_clear(ptr %%arg0, ptr %s)", ops)
		fmt.sbprintln(&e.b, "  ret void")
		fmt.sbprintln(&e.b, "}")
		return

	case .Map_Reserve, .Map_Try_Reserve:
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_map_bind(ptr %%arg0)")
		status = temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i32 @loke_rt_v1_map_reserve(ptr %%arg0, ptr %s, i64 %%arg1)", status, ops,
		)

	case .Map_Shrink, .Map_Try_Shrink:
		status = temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i32 @loke_rt_v1_map_shrink(ptr %%arg0, ptr %s, i64 %%arg1)", status, ops,
		)

	case .None:
		backend_fail(e, "a contributed container member has no operation")
		fmt.sbprintln(&e.b, "  ret void")
		fmt.sbprintln(&e.b, "}")
		return
	}

	failed := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i32 %s, 0", failed, status)
	if fallible {
		error := temp(e)
		fmt.sbprintfln(&e.b, "  %s = zext i1 %s to %s", error, failed, llvm_type(e, TYPE_ALLOCATOR_ERROR))
		fmt.sbprintfln(&e.b, "  ret %s %s", result, error)
		fmt.sbprintln(&e.b, "}")
		return
	}
	// The ordinary form has no result to report through, so the provider's own
	// policy decides: `.Panic` follows the program strategy, `.Trap` terminates.
	provider, fail_label, done_label := temp(e), new_label(e, "cop.fail"), new_label(e, "cop.done")
	branch_if(e, failed, fail_label, done_label)
	place_label(e, fail_label)
	slot := gep_field(e, CONTAINER_TYPE, "%arg0", CONTAINER_ALLOC)
	fmt.sbprintfln(&e.b, "  %s = load ptr, ptr %s", provider, slot)
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_alloc_failed(ptr %s)", provider)
	branch(e, done_label)
	place_label(e, done_label)
	e.terminated = false
	fmt.sbprintln(&e.b, "  ret void")
	fmt.sbprintln(&e.b, "}")
}

// `key in m`: one probe, no insertion and no value.
@(private)
emit_map_membership :: proc(e: ^Emitter, v: ^Expr_Binary) -> string {
	container := expr_base(v.rhs).type
	key := container_key(e.c, container)
	ops := container_ops_global(e, container)
	header := emit_address(e, v.rhs)
	value := emit_expr(e, v.lhs)
	key_slot := alloca(e, llvm_type(e, key))
	store(e, key, value, key_slot)
	found, out := temp(e), temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call ptr @loke_rt_v1_map_find(ptr %s, ptr %s, ptr %s)", found, header, ops, key_slot,
	)
	emit_drop_place(e, key, key_slot)
	fmt.sbprintfln(&e.b, "  %s = icmp ne ptr %s, null", out, found)
	return out
}

// `m[key]` in a place position. If the key is absent, the zero value of the
// element type is inserted first and the resulting slot is the location
// (design.md). The insertion allocates, and a place has nowhere to report a failure, so the
// provider's own policy decides.
@(private)
emit_map_place :: proc(e: ^Emitter, v: ^Expr_Index) -> string {
	container := expr_base(v.operand).type
	ops := container_ops_global(e, container)
	header := emit_address(e, v.operand)
	key_slot := emit_map_key_slot(e, v, container)
	place := emit_map_entry(e, ops, header, key_slot)
	emit_drop_place(e, container_key(e.c, container), key_slot)
	failed := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", failed, place)
	fail_label, done_label := new_label(e, "mplace.fail"), new_label(e, "mplace.done")
	branch_if(e, failed, fail_label, done_label)
	place_label(e, fail_label)
	provider, slot := temp(e), temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = getelementptr inbounds %s, ptr %s, i32 0, i32 %d",
		slot, CONTAINER_TYPE, header, CONTAINER_ALLOC,
	)
	fmt.sbprintfln(&e.b, "  %s = load ptr, ptr %s", provider, slot)
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_alloc_failed(ptr %s)", provider)
	branch(e, done_label)
	place_label(e, done_label)
	e.terminated = false
	return place
}

// The address a non-inserting read of `m[key]` produces: the existing slot, or a
// zeroed temporary of this frame. A lookup of a missing key returns the zero
// value (design.md), and reading one must not create an entry.
@(private)
emit_map_read_address :: proc(e: ^Emitter, v: ^Expr_Index) -> (string, string) {
	container := expr_base(v.operand).type
	element := container_element(e.c, container)
	element_llvm := llvm_type(e, element)
	ops := container_ops_global(e, container)
	header := emit_address(e, v.operand)
	key_slot := emit_map_key_slot(e, v, container)

	found := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call ptr @loke_rt_v1_map_find(ptr %s, ptr %s, ptr %s)", found, header, ops, key_slot,
	)
	emit_drop_place(e, container_key(e.c, container), key_slot)
	zero_slot := alloca(e, element_llvm)
	if zero, ok := zero_const(e.c, element); ok {
		fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", element_llvm, llvm_const(e, zero, element), zero_slot)
	}
	present, source := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp ne ptr %s, null", present, found)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, ptr %s, ptr %s", source, present, found, zero_slot)
	return source, present
}

// `m[key]` as a read, in both its single-value and comma-ok shapes.
@(private)
emit_map_lookup :: proc(e: ^Emitter, v: ^Expr_Index) -> []string {
	element_llvm := llvm_type(e, container_element(e.c, expr_base(v.operand).type))
	source, present := emit_map_read_address(e, v)
	value := load(e, element_llvm, source)
	out := make([]string, 2)
	out[0], out[1] = value, present
	return out
}

// The key, spilled so the C helper can read it through a pointer. The value is
// this frame's, so a managed key is dropped by the caller once the probe is
// done.
@(private = "file")
emit_map_key_slot :: proc(e: ^Emitter, v: ^Expr_Index, container: Type_Id) -> string {
	key := container_key(e.c, container)
	value := emit_expr(e, v.indices[0])
	slot := alloca(e, llvm_type(e, key))
	store(e, key, value, slot)
	return slot
}

// design.md "Maps": an inserting place. The slot is found or created with the
// zero value, and the answer is NULL only when the insertion could not allocate.
@(private = "file")
emit_map_entry :: proc(e: ^Emitter, ops, header, key_slot: string) -> string {
	inserted := alloca(e, "i32")
	place := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call ptr @loke_rt_v1_map_entry(ptr %s, ptr %s, ptr %s, ptr %s)",
		place, header, ops, key_slot, inserted,
	)
	return place
}

// Container operation tables, construction, and synthesized runtime bodies.
//
// Part of the textual LLVM backend; see compiler-architecture.md.
package lokec

import "core:fmt"
import "core:strings"

// One header serves both containers; `runtime/container.c` owns the storage.
CONTAINER_TYPE :: "%loke.container"
CONTAINER_OPS_TYPE :: "%loke.container_ops"

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
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_sort(ptr, i64, i64, ptr, i32)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_sort_by(ptr, i64, i64, ptr, ptr)")
}

// Declared only by a module that calls it, so other modules' IR is unchanged.
@(private = "file")
declare_dyn_append_owned :: proc(e: ^Emitter) {
	if e.container_thunks["dyn_append_owned"] {
		return
	}
	e.container_thunks["dyn_append_owned"] = true
	append(&e.globals, "declare i32 @loke_rt_v1_dyn_append_owned(ptr, ptr, ptr, ptr, i64)\n")
}

// The operation table for one concrete container type, made once along with
// its element and key thunks.
@(private)
container_ops_global :: proc(e: ^Emitter, type: Type_Id, relocating := false) -> string {
	relocating := relocating
	under := type_underlying(e.c, type)
	element := container_element(e.c, under)
	// A move-only element has no clone; every insertion hands it over, which is
	// the memcpy a NULL clone asks for (design.md "Container insertion"). A
	// relocating table asks the same for an owned element of any type.
	clones := element == INVALID_TYPE || !emit_lifecycle(e, element).clone_disabled
	if !clones {
		relocating = false
	}
	interned := relocating ? &e.container_move_ops : &e.container_ops
	if existing, found := interned[under]; found {
		return existing
	}
	name := fmt.aprintf(relocating ? "@.loke.ops.%d.move" : "@.loke.ops.%d", int(under))
	// Registered first, so a container of containers does not recurse forever.
	interned[under] = name

	key := container_key(e.c, under)
	elem_drop := container_drop_thunk(e, element)
	elem_clone := "null"
	if clones && !relocating {
		elem_clone = container_clone_thunk(e, element)
	}
	key_drop, key_clone, key_hash, key_equal := "null", "null", "null", "null"
	key_size, key_align := u64(0), u64(0)
	if key != INVALID_TYPE {
		key_drop = container_drop_thunk(e, key)
		key_clone = container_clone_thunk(e, key)
		key_hash = container_hash_thunk(e, key)
		key_equal = container_equal_thunk(e, key)
		key_size, key_align = type_size(e.c, key), type_align(e.c, key)
	}
	// `{` is a directive to core:fmt, so it is written separately.
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

// The element storage and live count of a sequence member's receiver: loaded
// through a container header's address, or read out of a slice value.
@(private = "file")
synth_sequence_storage :: proc(
	e: ^Emitter, symbol: ^Symbol, through_header: bool,
) -> (data: string, count: string) {
	if through_header {
		storage, length := temp(e), temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = getelementptr inbounds %s, ptr %%arg0, i32 0, i32 %d",
			storage, CONTAINER_TYPE, CONTAINER_STORAGE,
		)
		fmt.sbprintfln(
			&e.b, "  %s = getelementptr inbounds %s, ptr %%arg0, i32 0, i32 %d",
			length, CONTAINER_TYPE, CONTAINER_LEN,
		)
		data, count = temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = load ptr, ptr %s", data, storage)
		fmt.sbprintfln(&e.b, "  %s = load i64, ptr %s", count, length)
		return
	}
	header := llvm_type(e, symbol.params[0])
	self := synth_receiver_value(e, symbol)
	data, count = temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", data, header, self, SLICE_DATA)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", count, header, self, SLICE_LEN)
	return
}

// `xs.sort()` and `s.sort()`: one call into `runtime/container.c`'s introsort.
@(private = "file")
emit_synth_sort :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	receiver := symbol.params[0]
	element := container_element(e.c, receiver)
	through_header := element != INVALID_TYPE
	if !through_header {
		element = slice_element(e.c, receiver)
	}

	open_function(e, "define %svoid %s(%s %%arg0)", llvm_linkage(name), name, synth_param_llvm(e, symbol, 0))
	e.terminated = false

	// Only a call settles an element's `<`, so an unsettled comparison means
	// this contributed member is never called and its body can be empty.
	#partial switch resolved_element_order_policy(e.c, element).kind {
	case .Builtin, .Inherent:
	case:
		fmt.sbprintln(&e.b, "  ret void")
		fmt.sbprintln(&e.b, "}")
		return
	}

	data, count := synth_sequence_storage(e, symbol, through_header)

	fmt.sbprintfln(
		&e.b, "  call void @loke_rt_v1_sort(ptr %s, i64 %s, i64 %d, ptr %s, i32 %d)",
		data, count, type_size(e.c, element), container_less_thunk(e, element),
		symbol.container_op == .Reverse_Sort ? 1 : 0,
	)
	fmt.sbprintln(&e.b, "  ret void")
	fmt.sbprintln(&e.b, "}")
}

// design.md "Swapping elements": two elements change place, so no copy or drop
// hook runs. Both loads precede either store, so equal indices are a no-op.
@(private = "file")
emit_synth_swap :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	receiver := symbol.params[0]
	element := container_element(e.c, receiver)
	through_header := element != INVALID_TYPE
	if !through_header {
		element = slice_element(e.c, receiver)
	}
	element_llvm := llvm_type(e, element)

	open_function(
		e, "define %svoid %s(%s %%arg0, %s %%arg1, %s %%arg2)",
		llvm_linkage(name), name, synth_param_llvm(e, symbol, 0),
		synth_param_llvm(e, symbol, 1), synth_param_llvm(e, symbol, 2),
	)
	e.terminated = false

	data, count := synth_sequence_storage(e, symbol, through_header)

	// Unsigned, so a negative index fails the same comparison.
	for argument in 1 ..= 2 {
		out_of_range := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp uge i64 %%arg%d, %s", out_of_range, argument, count)
		panic_if(e, out_of_range, "bounds", "index out of range")
	}

	left := gep_at(e, element_llvm, data, "%arg1")
	right := gep_at(e, element_llvm, data, "%arg2")
	held_left := load_place(e, element, left)
	held_right := load_place(e, element, right)
	store(e, element, held_right, left)
	store(e, element, held_left, right)
	fmt.sbprintln(&e.b, "  ret void")
	fmt.sbprintln(&e.b, "}")
}

// `core:slice.sort_by`: the checked comparator and its concrete `call` method
// are erased only at this C ABI seam.
@(private)
emit_slice_sort_by :: proc(e: ^Emitter, v: ^Expr_Call) {
	if len(v.bound) != 2 || v.operation.(Call_Sort_By).comparator == INVALID_SYMBOL {
		backend_fail(e, "a checked slice sort_by has no comparator")
		return
	}

	slice_type := expr_base(v.bound[0]).type
	element := slice_element(e.c, slice_type)
	value := emit_expr(e, v.bound[0])
	storage := llvm_type(e, slice_type)
	data := extract(e, storage, value, SLICE_DATA)
	count := extract(e, storage, value, SLICE_LEN)
	ctx := emit_expr(e, v.bound[1])
	less := sort_by_thunk(e, element, v.operation.(Call_Sort_By).comparator)
	fmt.sbprintfln(
		&e.b, "  call void @loke_rt_v1_sort_by(ptr %s, i64 %s, i64 %d, ptr %s, ptr %s)",
		data, count, type_size(e.c, element), ctx, less,
	)
}

// One adapter per concrete comparator method, keyed by the element too so a
// future generic `call` would collide loudly rather than load the wrong type.
@(private = "file")
sort_by_thunk :: proc(e: ^Emitter, element: Type_Id, method: Symbol_Id) -> string {
	name := fmt.aprintf("@loke.csortby.%d.%d", int(method), int(element))
	if e.container_thunks[name] {
		return name
	}
	e.container_thunks[name] = true
	// Shared with user code, so it never inherits a dead body's licence to abort.
	saved := e.synth_bodies
	e.synth_bodies = false
	defer e.synth_bodies = saved

	frame := begin_function_emission(e)
	open_function(e, "define private i32 %s(ptr %%state, ptr %%a, ptr %%b)", name)
	llvm := llvm_type(e, element)
	left := load(e, llvm, "%a")
	right := load(e, llvm, "%b")
	// A value `self` takes the comparator itself.
	state_type, state := "ptr", "%state"
	if sym := symbol_of(e.c, method); !param_mode_is_pointer(symbol_param_mode(e.c, sym, 0)) {
		state_type = llvm_type(e, sym.params[0])
		state = load(e, state_type, "%state")
	}
	before := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call i1 %s(%s %s, %s %s, %s %s)",
		before, symbol_name(e, method), state_type, state, llvm, left, llvm, right,
	)
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = zext i1 %s to i32", out, before)
	fmt.sbprintfln(&e.b, "  ret i32 %s", out)
	fmt.sbprintln(&e.b, "}")
	fmt.sbprintln(&e.b, "")
	finish_pending_thunk(e, frame)
	return name
}

// One comparison per element type, using the `<` policy settled during checking.
@(private = "file")
container_less_thunk :: proc(e: ^Emitter, element: Type_Id) -> string {
	return container_thunk(
		e, fmt.aprintf("@loke.cless.%d", int(element)), element,
		"i32", "ptr %a, ptr %b",
		proc(e: ^Emitter, element: Type_Id) {
			llvm := llvm_type(e, element)
			left := load(e, llvm, "%a")
			right := load(e, llvm, "%b")
			before := ""
			if policy := resolved_element_order_policy(e.c, element); policy.kind == .Inherent {
				before = temp(e)
				fmt.sbprintfln(
					&e.b, "  %s = call i1 %s(%s %s, %s %s)",
					before, symbol_name(e, policy.less), llvm, left, llvm, right,
				)
			} else {
				before = emit_compare(e, .Lt, element, left, right)
			}
			out := temp(e)
			fmt.sbprintfln(&e.b, "  %s = zext i1 %s to i32", out, before)
			fmt.sbprintfln(&e.b, "  ret i32 %s", out)
		},
	)
}

// A memoised private function with one entry block, parked in `e.pending`.
// Each body writes its own `ret`.
@(private = "file")
container_thunk :: proc(
	e: ^Emitter,
	name: string,
	part: Type_Id,
	result, params: string,
	body: proc(e: ^Emitter, part: Type_Id),
) -> string {
	if e.container_thunks[name] {
		return name
	}
	e.container_thunks[name] = true
	// Shared with user code, so it never inherits a dead body's licence to abort.
	saved := e.synth_bodies
	e.synth_bodies = false
	defer e.synth_bodies = saved
	frame := begin_function_emission(e)
	open_function(e, "define private %s %s(%s)", result, name, params)
	body(e, part)
	fmt.sbprintln(&e.b, "}")
	fmt.sbprintln(&e.b, "")
	finish_pending_thunk(e, frame)
	return name
}

// NULL means the part is trivially destroyed, so the C loop is skipped.
@(private = "file")
container_drop_thunk :: proc(e: ^Emitter, part: Type_Id) -> string {
	if part == INVALID_TYPE || !emit_lifecycle(e, part).managed {
		return "null"
	}
	return container_thunk(
		e, fmt.aprintf("@loke.cdrop.%d", int(type_underlying(e.c, part))), part,
		"void", "ptr %p",
		proc(e: ^Emitter, part: Type_Id) {
			emit_drop_place(e, part, "%p")
			fmt.sbprintln(&e.b, "  ret void")
		},
	)
}

// NULL means the part's clone is its bytes, so the C helper memcpys the run.
@(private = "file")
container_clone_thunk :: proc(e: ^Emitter, part: Type_Id) -> string {
	if part == INVALID_TYPE || !emit_lifecycle(e, part).managed {
		return "null"
	}
	return container_thunk(
		e, fmt.aprintf("@loke.cclone.%d", int(type_underlying(e.c, part))), part,
		"i32", "ptr %out, ptr %src, ptr %a",
		proc(e: ^Emitter, part: Type_Id) {
			ok := emit_try_clone_into(e, part, "%out", "%src", "%a")
			widened := temp(e)
			fmt.sbprintfln(&e.b, "  %s = zext i1 %s to i32", widened, ok)
			fmt.sbprintfln(&e.b, "  ret i32 %s", widened)
		},
	)
}

// The table freezes the key's `==`/`hash` pair settled during checking. Keyed
// by the key type itself, not its underlying one: a `distinct` key may carry
// its own pair.
@(private = "file")
container_hash_thunk :: proc(e: ^Emitter, key: Type_Id) -> string {
	return container_thunk(
		e, fmt.aprintf("@loke.chash.%d", int(key)), key,
		"i64", "ptr %p, i64 %seed",
		proc(e: ^Emitter, key: Type_Id) {
			value := load_place(e, key, "%p")
			out := ""
			if hook := key_policy_member(e, key, false); hook != INVALID_SYMBOL {
				// An immutable receiver takes the key's address, which is `%p`.
				receiver_type, receiver := llvm_type(e, key), value
				if sym := symbol_of(e.c, hook);
				   sym != nil && param_mode_is_pointer(symbol_param_mode(e.c, sym, 0)) {
					receiver_type, receiver = "ptr", "%p"
				}
				out = temp(e)
				fmt.sbprintfln(
					&e.b, "  %s = call i64 %s(%s %s, i64 %%seed)",
					out, symbol_name(e, hook), receiver_type, receiver,
				)
			} else {
				out = emit_hash_value(e, key, value, "%seed")
			}
			fmt.sbprintfln(&e.b, "  ret i64 %s", out)
		},
	)
}

@(private = "file")
container_equal_thunk :: proc(e: ^Emitter, key: Type_Id) -> string {
	return container_thunk(
		e, fmt.aprintf("@loke.cequal.%d", int(key)), key,
		"i32", "ptr %a, ptr %b",
		proc(e: ^Emitter, key: Type_Id) {
			llvm := llvm_type(e, key)
			left := load(e, llvm, "%a")
			right := load(e, llvm, "%b")
			same := ""
			if hook := key_policy_member(e, key, true); hook != INVALID_SYMBOL {
				same = temp(e)
				fmt.sbprintfln(
					&e.b, "  %s = call i1 %s(%s %s, %s %s)",
					same, symbol_name(e, hook), llvm, left, llvm, right,
				)
			} else {
				same = emit_compare(e, .Eq_Eq, key, left, right)
			}
			out := temp(e)
			fmt.sbprintfln(&e.b, "  %s = zext i1 %s to i32", out, same)
			fmt.sbprintfln(&e.b, "  ret i32 %s", out)
		},
	)
}

// The key type's inherent `hash` or `operator(==)`, or INVALID_SYMBOL when the
// compiler supplies the pair.
@(private = "file")
key_policy_member :: proc(e: ^Emitter, key: Type_Id, want_equal: bool) -> Symbol_Id {
	policy := e.c.map_key_policies[key]
	if policy.kind == .Unresolved {
		backend_fail(e, "a map key operation was not resolved during checking")
	}
	return want_equal ? policy.equal : policy.hash
}

// Writes a written `via` into a container header.
@(private = "file")
emit_store_via :: proc(e: ^Emitter, address: string, via: Expr) {
	provider := emit_expr(e, via)
	slot := gep_field(e, CONTAINER_TYPE, address, CONTAINER_ALLOC)
	fmt.sbprintfln(&e.b, "  store ptr %s, ptr %s", provider, slot)
}

// A container declaration's written `via` binds at the declaration point. One
// with no policy stays unbound, which makes the lazy default observable.
@(private)
emit_eager_via_binding :: proc(e: ^Emitter, symbol_id: Symbol_Id, address: string) {
	sym := symbol_of(e.c, symbol_id)
	if sym == nil || sym.via == nil || !type_is_container(e.c, sym.type) {
		return
	}
	emit_store_via(e, address, sym.via)
}

// The allocator a call was given, or the default when it was omitted.
@(private)
emit_allocator_operand :: proc(e: ^Emitter, v: ^Expr_Call, index: int) -> string {
	if len(v.bound) > index {
		return emit_expr(e, v.bound[index])
	}
	return emit_default_allocator(e)
}

// `free_all`: one call through the provider's reset callback, which fails at
// run time for a provider with no region (design.md).
@(private)
emit_region_reset :: proc(e: ^Emitter, v: ^Expr_Call) {
	handle := emit_expr(e, v.bound[0])
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_reset(ptr %s)", handle)
}

// `[dynamic]T{a, b, c}` over an already zeroed header. Each element is appended
// as soon as it is evaluated, and a temporary unwind action covers the built
// prefix until the literal is complete.
@(private)
emit_dynamic_literal_into :: proc(e: ^Emitter, v: ^Expr_Composite, address: string, element: Type_Id, as_type: Type_Id) {
	if len(v.elements) == 0 {
		return
	}
	ops := container_ops_global(e, as_type)
	// The policy is written before the first reservation.
	if v.via != nil {
		emit_store_via(e, address, v.via)
	}
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_dyn_bind(ptr %s)", address)
	reserved := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call i32 @loke_rt_v1_dyn_reserve(ptr %s, ptr %s, i64 %d)",
		reserved, address, ops, len(v.elements),
	)
	emit_container_policy_failure(e, address, reserved)
	cleanup := begin_temporary_drop(e, as_type, address)

	// A borrowed element is cloned in; an owned one relocates.
	relocating := container_ops_global(e, as_type, relocating = true)
	slot := alloca(e, llvm_type(e, element))
	for written, index in v.elements {
		store(e, element, emit_expr(e, written.value), slot)
		borrowed := index < len(v.element_clones) && v.element_clones[index]
		status := temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i32 @loke_rt_v1_dyn_append(ptr %s, ptr %s, ptr %s, i64 1)",
			status, address, borrowed ? ops : relocating, slot,
		)
		emit_container_policy_failure(e, address, status)
	}
	finish_temporary_drop(e, cleanup)
}

// `map[K]V{ key = value, ... }` over an already zeroed header. Each entry is
// inserted as soon as it is evaluated, under a temporary unwind action.
@(private)
emit_map_literal_into :: proc(e: ^Emitter, v: ^Expr_Composite, address: string, key, element: Type_Id, as_type: Type_Id) {
	if len(v.elements) == 0 {
		return
	}
	ops := container_ops_global(e, as_type)
	if v.via != nil {
		emit_store_via(e, address, v.via)
	}
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_map_bind(ptr %s)", address)
	reserved := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call i32 @loke_rt_v1_map_reserve(ptr %s, ptr %s, i64 %d)",
		reserved, address, ops, len(v.elements),
	)
	emit_container_policy_failure(e, address, reserved)
	cleanup := begin_temporary_drop(e, as_type, address)

	for written, index in v.elements {
		// The map clones the key, so the probe only borrows it.
		key_slot, key_cleanup := emit_map_key_slot(e, written.key, as_type)
		value := emit_expr(e, written.value)
		if index < len(v.element_clones) && v.element_clones[index] {
			value = emit_clone_value(e, element, value)
		}
		place, inserted := emit_map_entry(e, ops, address, key_slot)
		missing := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", missing, place)
		fail_label, store_label := new_label(e, "mlit.fail"), new_label(e, "mlit.store")
		branch_if(e, missing, fail_label, store_label)
		place_label(e, fail_label)
		emit_alloc_failure(e, address)
		place_label(e, store_label)
		emit_replace_entry(e, element, place, inserted, "mlit")
		store(e, element, value, place)
		drop_temporary_value(e, key_cleanup)
	}
	finish_temporary_drop(e, cleanup)
}

// A new map entry holds inert bytes; only an existing one holds a live value
// that must be dropped before it is overwritten.
@(private = "file")
emit_replace_entry :: proc(e: ^Emitter, element: Type_Id, place, inserted, prefix: string) {
	is_new := temp(e)
	replace_label := new_label(e, fmt.tprintf("%s.replace", prefix))
	write_label := new_label(e, fmt.tprintf("%s.write", prefix))
	fmt.sbprintfln(&e.b, "  %s = icmp ne i32 %s, 0", is_new, inserted)
	branch_if(e, is_new, write_label, replace_label)
	place_label(e, replace_label)
	emit_drop_place(e, element, place)
	branch(e, write_label)
	place_label(e, write_label)
}

// The header's provider applies its own failure policy; it does not return.
@(private = "file")
emit_alloc_failure :: proc(e: ^Emitter, header: string) {
	provider := load(e, "ptr", gep_field(e, CONTAINER_TYPE, header, CONTAINER_ALLOC))
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_alloc_failed(ptr %s)", provider)
	fmt.sbprintln(&e.b, "  unreachable")
	e.terminated = true
}

// A zero `status` from an operation that has no result to report through.
@(private = "file")
emit_container_policy_failure :: proc(e: ^Emitter, header, status: string) {
	failed := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i32 %s, 0", failed, status)
	fail_label, done_label := new_label(e, "clit.fail"), new_label(e, "clit.done")
	branch_if(e, failed, fail_label, done_label)
	place_label(e, fail_label)
	emit_alloc_failure(e, header)
	place_label(e, done_label)
}

// ------------------------------------------------------- provider bodies --

// One contributed `mem.Arena`/`mem.Scratch` operation. The value is one pointer
// to an address-stable control block.
@(private)
emit_synth_provider_op :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	// `try_arena` returns `Result(Arena, Allocator_Error)`; the provider is `.ok`.
	produced := symbol.result
	if symbol.provider_op == .Try_Open {
		produced = union_variant_payload(e.c, produced, union_index_of(e.c, produced, "ok"))
	}
	provider := llvm_type(e, produced == TYPE_ALLOCATOR ? symbol.params[0] : produced)
	result := llvm_result_type(e, symbol.result, symbol.result_inout)
	fmt.sbprintf(&e.b, "define %s%s %s(", llvm_linkage(name), result, name)
	for parameter, index in symbol.params {
		if index > 0 {
			fmt.sbprint(&e.b, ", ")
		}
		fmt.sbprintf(&e.b, "%s %%arg%d", llvm_type(e, parameter), index)
	}
	open_function(e, ")")
	e.terminated = false

	switch symbol.provider_op {
	case .None:
	case .Open:
		// Both names are reserved before the open check allocates its own.
		opened, out := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = call ptr @loke_rt_v1_arena_open(ptr %%arg0)", opened)
		emit_provider_open_check(e, opened, "%arg0")
		fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, ptr %s, %d", out, provider, opened, PROVIDER_CONTROL)
		fmt.sbprintfln(&e.b, "  ret %s %s", provider, out)

	case .Open_Fixed:
		// Fixed storage cannot run out; a too-small buffer is a runtime fault.
		buffer := llvm_type(e, symbol.params[0])
		data := extract(e, buffer, "%arg0", SLICE_DATA)
		length := extract(e, buffer, "%arg0", SLICE_LEN)
		opened := temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call ptr @loke_rt_v1_arena_open_fixed(ptr %s, i64 %s)", opened, data, length,
		)
		out := insert(e, provider, "undef", "ptr", opened, PROVIDER_CONTROL)
		fmt.sbprintfln(&e.b, "  ret %s %s", provider, out)

	case .Try_Open:
		opened := temp(e)
		fmt.sbprintfln(&e.b, "  %s = call ptr @loke_rt_v1_arena_open(ptr %%arg0)", opened)
		value := insert(e, provider, "undef", "ptr", opened, PROVIDER_CONTROL)
		failed := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", failed, opened)
		fmt.sbprintfln(
			&e.b, "  ret %s %s", result, emit_alloc_result(e, symbol.result, failed, value),
		)

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

// One contributed container operation: a call into the versioned C helper with
// this type's operation table. A `try_` form returns the error; the ordinary
// form applies the allocator's failure policy (design.md "Allocation failure").
@(private)
emit_synth_container_op :: proc(e: ^Emitter, symbol: ^Symbol, name: string, consuming := false) {
	// Sort and swap also serve `[]mut T`, which has no operation table.
	#partial switch symbol.container_op {
	case .Sort, .Reverse_Sort:
		emit_synth_sort(e, symbol, name)
		return
	case .Swap:
		emit_synth_swap(e, symbol, name)
		return
	}
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	container := symbol.params[0]
	element := container_element(e.c, container)
	element_llvm := llvm_type(e, element)
	// A consuming `append` of a copyable element takes a pack it partly owns, with
	// a flag per element, and clones the rest through the ordinary table.
	masked := consuming && symbol.container_op == .Append && !emit_lifecycle(e, element).clone_disabled
	ops := container_ops_global(e, container, relocating = consuming && !masked)
	fallible := symbol.result != INVALID_TYPE && type_is_union(e.c, symbol.result)
	// A move-only element, or any element of a consuming body, is handed over,
	// so this body owns it until it is stored.
	moves := consuming || emit_lifecycle(e, element).clone_disabled

	result := llvm_result_type(e, symbol.result, symbol.result_inout)
	fmt.sbprintf(&e.b, "define %s%s %s(", llvm_linkage(name), result, name)
	fmt.sbprint(&e.b, sret_param(e, symbol.result, symbol.result_inout))
	for _, index in symbol.params {
		if index > 0 {
			fmt.sbprint(&e.b, ", ")
		}
		fmt.sbprintf(&e.b, "%s %%arg%d", synth_param_llvm(e, symbol, index), index)
	}
	if masked {
		fmt.sbprint(&e.b, ", ptr %owned")
	}
	open_function(e, ")")
	e.terminated = false

	// A single value entering the container is spilled for the helper to read.
	value_storage :: proc(e: ^Emitter, element: Type_Id, argument: string) -> string {
		slot := alloca(e, llvm_type(e, element))
		store(e, element, argument, slot)
		return slot
	}

	// A lookup borrows its key; a `string_view` is spilled as an unowned header.
	key_probe_slot :: proc(e: ^Emitter, symbol: ^Symbol, container: Type_Id) -> string {
		key := container_key(e.c, container)
		if symbol.params[1] != key {
			return emit_borrowed_key_slot(e, "%arg1")
		}
		return value_storage(e, key, "%arg1")
	}

	// The header address the C probe reads. An immutable receiver arrives as the
	// header value itself.
	receiver_header :: proc(e: ^Emitter, symbol: ^Symbol) -> string {
		if param_mode_is_pointer(symbol_param_mode(e.c, symbol, 0)) {
			return "%arg0"
		}
		header := alloca(e, CONTAINER_TYPE)
		fmt.sbprintfln(&e.b, "  store %s %%arg0, ptr %s", CONTAINER_TYPE, header)
		return header
	}

	status := ""
	switch symbol.container_op {
	case .Append:
		data, count := temp(e), temp(e)
		pack := llvm_type(e, symbol.params[1])
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %%arg1, %d", data, pack, SLICE_DATA)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %%arg1, %d", count, pack, SLICE_LEN)
		status = temp(e)
		if masked {
			declare_dyn_append_owned(e)
			fmt.sbprintfln(
				&e.b, "  %s = call i32 @loke_rt_v1_dyn_append_owned(ptr %%arg0, ptr %s, ptr %s, ptr %%owned, i64 %s)",
				status, ops, data, count,
			)
			// A failed append leaves every owned element with this body. A `try_`
			// form passes no flags: it owns nothing, and its caller drops the pack.
			kept := branch_on_failure(e, status)
			flagged := temp(e)
			fmt.sbprintfln(&e.b, "  %s = icmp ne ptr %%owned, null", flagged)
			drop_owned, dropped := new_label(e, "append.owned"), new_label(e, "append.dropped")
			branch_if(e, flagged, drop_owned, dropped)
			place_label(e, drop_owned)
			count_slot := alloca(e, "i64")
			fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", count, count_slot)
			emit_drop_flagged_array(e, element, data, "%owned", count_slot)
			branch(e, dropped)
			place_label(e, dropped)
			rejoin(e, kept)
		} else {
			fmt.sbprintfln(
				&e.b, "  %s = call i32 @loke_rt_v1_dyn_append(ptr %%arg0, ptr %s, ptr %s, i64 %s)",
				status, ops, data, count,
			)
		}
		if moves && !masked {
			kept := branch_on_failure(e, status)
			emit_drop_run(e, element, data, count)
			rejoin(e, kept)
		}

	case .Insert:
		slot := value_storage(e, element, "%arg2")
		status = temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i32 @loke_rt_v1_dyn_insert(ptr %%arg0, ptr %s, i64 %%arg1, ptr %s, i64 1)",
			status, ops, slot,
		)
		if moves {
			kept := branch_on_failure(e, status)
			emit_drop_place(e, element, slot)
			rejoin(e, kept)
		}

	case .Pop:
		out := alloca(e, element_llvm)
		found := temp(e)
		fmt.sbprintfln(&e.b, "  %s = call i32 @loke_rt_v1_dyn_pop(ptr %%arg0, ptr %s, ptr %s)", found, ops, out)
		value, ok := load_temporary(e, element, out), temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp ne i32 %s, 0", ok, found)
		emit_ret(e, symbol.result, emit_option_value(e, symbol.result, ok, value))
		fmt.sbprintln(&e.b, "}")
		return

	case .Remove, .Remove_Unordered:
		out := alloca(e, element_llvm)
		fmt.sbprintfln(
			&e.b, "  call void @loke_rt_v1_dyn_remove(ptr %%arg0, ptr %s, i64 %%arg1, ptr %s, i32 %d)",
			ops, out, symbol.container_op == .Remove_Unordered ? 1 : 0,
		)
		value := load_place(e, element, out)
		emit_ret(e, element, value)
		fmt.sbprintln(&e.b, "}")
		return

	case .Clear:
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_dyn_clear(ptr %%arg0, ptr %s)", ops)
		fmt.sbprintln(&e.b, "  ret void")
		fmt.sbprintln(&e.b, "}")
		return

	case .Resize:
		status = temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i32 @loke_rt_v1_dyn_resize(ptr %%arg0, ptr %s, i64 %%arg1)", status, ops,
		)

	case .Reserve:
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_dyn_bind(ptr %%arg0)")
		status = temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i32 @loke_rt_v1_dyn_reserve(ptr %%arg0, ptr %s, i64 %%arg1)", status, ops,
		)

	case .Shrink:
		status = temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i32 @loke_rt_v1_dyn_shrink(ptr %%arg0, ptr %s, i64 %%arg1)", status, ops,
		)

	case .Map_Find:
		// A pointer to the existing value, or `nil`; never inserts.
		header := receiver_header(e, symbol)
		slot := key_probe_slot(e, symbol, container)
		found, ok := temp(e), temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call ptr @loke_rt_v1_map_find(ptr %s, ptr %s, ptr %s)", found, header, ops, slot,
		)
		fmt.sbprintfln(&e.b, "  %s = icmp ne ptr %s, null", ok, found)
		emit_ret(e, symbol.result, emit_option_value(e, symbol.result, ok, found))
		fmt.sbprintln(&e.b, "}")
		return

	case .Map_Lookup_Value:
		// One probe, no insertion, and an independently owned clone on a hit, made
		// here so the destination must not copy again.
		header := receiver_header(e, symbol)
		key_slot := key_probe_slot(e, symbol, container)
		found := temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call ptr @loke_rt_v1_map_find(ptr %s, ptr %s, ptr %s)", found, header, ops, key_slot,
		)
		present := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp ne ptr %s, null", present, found)

		out := alloca(e, element_llvm)
		zero := "zeroinitializer"
		if constant, zeroed := zero_const(e.c, element); zeroed {
			zero = llvm_const(e, constant, element)
		}
		store(e, element, zero, out)
		hit_label, done_label := new_label(e, "mlookup.hit"), new_label(e, "mlookup.done")
		branch_if(e, present, hit_label, done_label)
		place_label(e, hit_label)
		stored := load_place(e, element, found)
		if emit_lifecycle(e, element).managed {
			stored = emit_clone_value(e, element, stored)
		}
		store(e, element, stored, out)
		branch(e, done_label)
		place_label(e, done_label)

		value := load_place(e, element, out)
		emit_ret(e, symbol.result, emit_option_value(e, symbol.result, present, value))
		fmt.sbprintln(&e.b, "}")
		return

	case .Map_Find_Or_Insert:
		// The slot either way. A miss inserts the element, cloned as `try_insert`
		// clones it or moved in; a move-only element is dropped on a hit.
		key_slot := value_storage(e, container_key(e.c, container), "%arg1")
		found, present := temp(e), temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call ptr @loke_rt_v1_map_find(ptr %%arg0, ptr %s, ptr %s)", found, ops, key_slot,
		)
		fmt.sbprintfln(&e.b, "  %s = icmp ne ptr %s, null", present, found)
		hit_label, miss_label := new_label(e, "mfoi.hit"), new_label(e, "mfoi.miss")
		branch_if(e, present, hit_label, miss_label)
		place_label(e, hit_label)
		if moves {
			emit_drop_place(e, element, value_storage(e, element, "%arg2"))
		}
		emit_map_slot_result(e, symbol.result, result, found, fallible)

		place_label(e, miss_label)
		staged := alloca(e, element_llvm)
		cloned := "true"
		if moves {
			store(e, element, "%arg2", staged)
		} else if emit_lifecycle(e, element).managed {
			cloned = emit_try_clone_into(
				e, element, staged, value_storage(e, element, "%arg2"), emit_map_allocator(e, "%arg0"),
			)
		} else {
			store(e, element, "%arg2", staged)
		}
		clone_ready, clone_failed := new_label(e, "mfoi.cloned"), new_label(e, "mfoi.clone_failed")
		branch_if(e, cloned, clone_ready, clone_failed)
		place_label(e, clone_failed)
		emit_map_slot_failure(e, symbol.result, result, "%arg0", fallible)

		place_label(e, clone_ready)
		place, _ := emit_map_entry(e, ops, "%arg0", key_slot)
		missing := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", missing, place)
		entry_failed, entry_ok := new_label(e, "mfoi.failed"), new_label(e, "mfoi.ok")
		branch_if(e, missing, entry_failed, entry_ok)
		place_label(e, entry_failed)
		emit_drop_place(e, element, staged)
		emit_map_slot_failure(e, symbol.result, result, "%arg0", fallible)

		place_label(e, entry_ok)
		// The key was absent a moment ago, so the slot is new and inert.
		store(e, element, load_place(e, element, staged), place)
		emit_map_slot_result(e, symbol.result, result, place, fallible)
		fmt.sbprintln(&e.b, "}")
		return

	case .Map_Try_Insert:
		key_type := container_key(e.c, container)
		// The value is staged before insertion, so a failed clone neither touches
		// an existing entry nor publishes a key without a value.
		allocator := emit_map_allocator(e, "%arg0")
		staged := alloca(e, element_llvm)
		cloned := "true"
		if moves {
			store(e, element, "%arg2", staged)
		} else if emit_lifecycle(e, element).managed {
			source := value_storage(e, element, "%arg2")
			cloned = emit_try_clone_into(e, element, staged, source, allocator)
		} else {
			store(e, element, "%arg2", staged)
		}
		clone_ready, clone_failed := new_label(e, "mins.cloned"), new_label(e, "mins.clone_failed")
		branch_if(e, cloned, clone_ready, clone_failed)
		place_label(e, clone_failed)
		emit_ret(e, symbol.result, emit_alloc_result(e, symbol.result, "true"))
		e.terminated = true

		place_label(e, clone_ready)
		key_slot := value_storage(e, key_type, "%arg1")
		place, inserted := emit_map_entry(e, ops, "%arg0", key_slot)
		missing, ok_label, failed_label := temp(e), new_label(e, "mins.ok"), new_label(e, "mins.failed")
		fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", missing, place)
		branch_if(e, missing, failed_label, ok_label)
		place_label(e, failed_label)
		emit_drop_place(e, element, staged)
		emit_ret(e, symbol.result, emit_alloc_result(e, symbol.result, "true"))
		e.terminated = true

		place_label(e, ok_label)
		// No failure point remains between dropping the old value and storing.
		emit_replace_entry(e, element, place, inserted, "mins")
		stored := load_place(e, element, staged)
		store(e, element, stored, place)
		emit_ret(e, symbol.result, emit_alloc_result(e, symbol.result, "false"))
		fmt.sbprintln(&e.b, "}")
		e.terminated = true
		return

	case .Map_Entries, .Map_Keys, .Map_Values:
		// design.md "Iteration adapters": a view is just the table pointer.
		table := extract(e, llvm_type(e, container), synth_receiver_value(e, symbol), CONTAINER_STORAGE)
		view := insert(e, result, "undef", "ptr", table, VIEW_SOURCE)
		fmt.sbprintfln(&e.b, "  ret %s %s", result, view)
		fmt.sbprintln(&e.b, "}")
		return

	case .Map_Remove:
		key_slot := key_probe_slot(e, symbol, container)
		out := alloca(e, element_llvm)
		found := temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i32 @loke_rt_v1_map_remove(ptr %%arg0, ptr %s, ptr %s, ptr %s)",
			found, ops, key_slot, out,
		)
		value := load_place(e, element, out)
		ok := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp ne i32 %s, 0", ok, found)
		emit_ret(e, symbol.result, emit_option_value(e, symbol.result, ok, value))
		fmt.sbprintln(&e.b, "}")
		return

	case .Map_Clear:
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_map_clear(ptr %%arg0, ptr %s)", ops)
		fmt.sbprintln(&e.b, "  ret void")
		fmt.sbprintln(&e.b, "}")
		return

	case .Map_Reserve:
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_map_bind(ptr %%arg0)")
		status = temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i32 @loke_rt_v1_map_reserve(ptr %%arg0, ptr %s, i64 %%arg1)", status, ops,
		)

	case .Map_Shrink:
		status = temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i32 @loke_rt_v1_map_shrink(ptr %%arg0, ptr %s, i64 %%arg1)", status, ops,
		)

	case .None, .Sort, .Reverse_Sort, .Swap:
		backend_fail(e, "a contributed container member has no operation")
		fmt.sbprintln(&e.b, "  ret void")
		fmt.sbprintln(&e.b, "}")
		return
	}

	if fallible {
		failed := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp eq i32 %s, 0", failed, status)
		emit_ret(e, symbol.result, emit_alloc_result(e, symbol.result, failed))
		fmt.sbprintln(&e.b, "}")
		return
	}
	emit_container_policy_failure(e, "%arg0", status)
	fmt.sbprintln(&e.b, "  ret void")
	fmt.sbprintln(&e.b, "}")
}

// A move-only element that failed to enter the container is still this body's
// to drop. `branch_on_failure` opens that block; `rejoin` closes it.
@(private = "file")
branch_on_failure :: proc(e: ^Emitter, status: string) -> string {
	failed := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i32 %s, 0", failed, status)
	drop_label, kept_label := new_label(e, "cop.unconsumed"), new_label(e, "cop.kept")
	branch_if(e, failed, drop_label, kept_label)
	place_label(e, drop_label)
	return kept_label
}

@(private = "file")
rejoin :: proc(e: ^Emitter, kept_label: string) {
	branch(e, kept_label)
	place_label(e, kept_label)
}

// Every element of a `..T` pack, in order.
@(private = "file")
emit_drop_run :: proc(e: ^Emitter, element: Type_Id, data, count: string) {
	index_slot := alloca(e, "i64")
	fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", index_slot)
	head, body, done := new_label(e, "unconsumed.head"), new_label(e, "unconsumed.body"), new_label(e, "unconsumed.done")
	branch(e, head)
	place_label(e, head)
	index := load(e, "i64", index_slot)
	more := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp ult i64 %s, %s", more, index, count)
	branch_if(e, more, body, done)
	place_label(e, body)
	at := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = getelementptr inbounds %s, ptr %s, i64 %s", at, llvm_type(e, element), data, index,
	)
	emit_drop_place(e, element, at)
	next := temp(e)
	fmt.sbprintfln(&e.b, "  %s = add i64 %s, 1", next, index)
	fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", next, index_slot)
	branch(e, head)
	place_label(e, done)
}

// `key in m`: one probe, no insertion and no value.
@(private)
emit_map_membership :: proc(e: ^Emitter, v: ^Expr_Binary) -> string {
	container := expr_base(v.rhs).type
	ops := container_ops_global(e, container)
	header := emit_address(e, v.rhs)
	key_slot, cleanup := emit_map_key_slot(e, v.lhs, container)
	found, out := temp(e), temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call ptr @loke_rt_v1_map_find(ptr %s, ptr %s, ptr %s)", found, header, ops, key_slot,
	)
	drop_temporary_value(e, cleanup)
	fmt.sbprintfln(&e.b, "  %s = icmp ne ptr %s, null", out, found)
	return out
}

// The map's own provider, or the build-selected default when it is unbound.
@(private = "file")
emit_map_allocator :: proc(e: ^Emitter, header: string) -> string {
	bound := load(e, "ptr", gep_field(e, CONTAINER_TYPE, header, CONTAINER_ALLOC))
	unbound, allocator := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", unbound, bound)
	fmt.sbprintfln(
		&e.b, "  %s = select i1 %s, ptr %s, ptr %s", allocator, unbound, emit_default_allocator(e), bound,
	)
	return allocator
}

// `find_or_insert` answers the slot; `try_find_or_insert` answers it as `.ok`.
@(private = "file")
emit_map_slot_result :: proc(e: ^Emitter, result_type: Type_Id, result, slot: string, fallible: bool) {
	if fallible {
		fmt.sbprintfln(&e.b, "  ret %s %s", result, emit_alloc_result(e, result_type, "false", slot))
	} else {
		fmt.sbprintfln(&e.b, "  ret %s %s", result, slot)
	}
	e.terminated = true
}

// The error for the `try_` spelling, and the provider's policy otherwise.
@(private = "file")
emit_map_slot_failure :: proc(e: ^Emitter, result_type: Type_Id, result, header: string, fallible: bool) {
	if fallible {
		fmt.sbprintfln(&e.b, "  ret %s %s", result, emit_alloc_result(e, result_type, "true", "null"))
		e.terminated = true
		return
	}
	emit_alloc_failure(e, header)
}

// `m[key] = elem` (design.md "Maps"): the one index form that creates an entry.
// The receiver and key are captured with the other assignment destinations and
// inserted in the write phase, without being evaluated again.
@(private)
Map_Assignment_Destination :: struct {
	container: Type_Id,
	header, key_slot: string,
	key_cleanup: Deferred,
}

@(private)
prepare_map_assignment :: proc(e: ^Emitter, v: ^Expr_Index, snapshot_key: bool) -> Map_Assignment_Destination {
	container := expr_base(v.operand).type
	header := emit_address(e, v.operand)
	key_slot, cleanup := emit_map_key_slot(e, v.indices[0], container)
	key := container_key(e.c, container)
	// An earlier destination of a multiple assignment may overwrite the variable
	// supplying this key, so it is snapshotted.
	if snapshot_key && emit_lifecycle(e, key).managed && expression_is_borrowed_place(v.indices[0]) {
		value := emit_clone_value(e, key, load_place(e, key, key_slot))
		store(e, key, value, key_slot)
		cleanup = begin_temporary_drop(e, key, key_slot)
	}
	return Map_Assignment_Destination{container, header, key_slot, cleanup}
}

// The insertion allocates and an assignment cannot report failure, so the
// provider's policy decides.
@(private)
emit_map_insert_store :: proc(e: ^Emitter, destination: Map_Assignment_Destination, value: string, guard: Deferred) {
	container, header, key_slot := destination.container, destination.header, destination.key_slot
	element := container_element(e.c, container)
	ops := container_ops_global(e, container)
	place, inserted := emit_map_entry(e, ops, header, key_slot)
	missing := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", missing, place)
	fail_label, store_label := new_label(e, "mset.fail"), new_label(e, "mset.store")
	branch_if(e, missing, fail_label, store_label)
	place_label(e, fail_label)
	emit_alloc_failure(e, header)
	place_label(e, store_label)
	emit_replace_entry(e, element, place, inserted, "mset")
	store(e, element, value, place)
	// The map owns the value before a user key destructor can panic.
	finish_temporary_drop(e, guard)
	drop_temporary_value(e, destination.key_cleanup)
}

// The address of an existing `m[key]`, for every position but assignment. A
// missing key panics, as a dynamic array's index does (design.md "Maps").
@(private)
emit_map_element_address :: proc(e: ^Emitter, v: ^Expr_Index) -> string {
	container := expr_base(v.operand).type
	ops := container_ops_global(e, container)
	header := emit_address(e, v.operand)
	key_slot, cleanup := emit_map_key_slot(e, v.indices[0], container)

	found := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call ptr @loke_rt_v1_map_find(ptr %s, ptr %s, ptr %s)", found, header, ops, key_slot,
	)
	drop_temporary_value(e, cleanup)
	absent := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", absent, found)
	panic_if(e, absent, "mkey", "map key not found")
	return found
}

// `m[key]` as a read; `m.lookup_value(key)` is the `Option(V)` form.
@(private)
emit_map_lookup :: proc(e: ^Emitter, v: ^Expr_Index) -> string {
	return load_place(e, container_element(e.c, expr_base(v.operand).type), emit_map_element_address(e, v))
}

// Spills a key for the C helper, which only borrows it. Only an owned
// temporary gets a cleanup; a borrowed place stays its owner's.
@(private = "file")
emit_map_key_slot :: proc(e: ^Emitter, index: Expr, container: Type_Id) -> (string, Deferred) {
	key := container_key(e.c, container)
	given := expr_base(index).type
	value := emit_expr(e, index)
	if given != key {
		return emit_borrowed_key_slot(e, value), Deferred{slot = -1}
	}
	slot := alloca(e, llvm_type(e, key))
	store(e, key, value, slot)
	cleanup := Deferred{slot = -1}
	if emit_lifecycle(e, key).managed && !expression_is_borrowed_place(index) {
		cleanup = begin_temporary_drop(e, key, slot)
	}
	return slot, cleanup
}

// design.md "Maps": a `map[string]V` is queried with a `string_view`, spilled
// as an unowned static header that nothing clones or drops.
@(private)
emit_borrowed_key_slot :: proc(e: ^Emitter, view: string) -> string {
	data, length := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", data, STRING_VIEW_TYPE, view, VIEW_DATA)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", length, STRING_VIEW_TYPE, view, VIEW_LEN)
	slot := alloca(e, STRING_TYPE)
	fmt.sbprintfln(&e.b, "  store ptr %s, ptr %s", data, gep_field(e, STRING_TYPE, slot, STRING_DATA))
	fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", length, gep_field(e, STRING_TYPE, slot, STRING_LEN))
	fmt.sbprintfln(
		&e.b, "  store i64 %d, ptr %s", STRING_STATIC, gep_field(e, STRING_TYPE, slot, STRING_OWNER),
	)
	return slot
}

// Finds or creates a map slot, and whether it was newly inserted (inert) or
// already held a live value.
@(private = "file")
emit_map_entry :: proc(e: ^Emitter, ops, header, key_slot: string) -> (string, string) {
	inserted := alloca(e, "i32")
	place := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call ptr @loke_rt_v1_map_entry(ptr %s, ptr %s, ptr %s, ptr %s)",
		place, header, ops, key_slot, inserted,
	)
	was_inserted := load(e, "i32", inserted)
	return place, was_inserted
}

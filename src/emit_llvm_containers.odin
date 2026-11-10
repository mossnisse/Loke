// Container operation tables, construction, synthesized runtime bodies, and the
// `[]mut T` members.
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
	declare_runtime(e, CONTAINER_DECLARATIONS[:])
}

@(private = "file", rodata)
CONTAINER_DECLARATIONS := [?]Runtime_Declaration {
	{"i32", "loke_rt_v1_dyn_reserve", "ptr, ptr, i64", ""},
	{"void", "loke_rt_v1_dyn_bind", "ptr", ""},
	{"i32", "loke_rt_v1_dyn_append", "ptr, ptr, ptr, i64", ""},
	{"i32", "loke_rt_v1_dyn_append_owned", "ptr, ptr, ptr, ptr, i64", ""},
	{"i32", "loke_rt_v1_dyn_insert", "ptr, ptr, i64, ptr, i64", ""},
	{"i32", "loke_rt_v1_dyn_pop", "ptr, ptr, ptr", ""},
	{"void", "loke_rt_v1_dyn_remove", "ptr, ptr, i64, ptr, i32", ""},
	{"void", "loke_rt_v1_dyn_clear", "ptr, ptr", ""},
	{"i32", "loke_rt_v1_dyn_resize", "ptr, ptr, i64", ""},
	{"i32", "loke_rt_v1_dyn_shrink", "ptr, ptr, i64", ""},
	{"i32", "loke_rt_v1_dyn_clone", "ptr, ptr, ptr, ptr", ""},
	{"void", "loke_rt_v1_dyn_drop", "ptr, ptr", ""},
	{"i32", "loke_rt_v1_map_reserve", "ptr, ptr, i64", ""},
	{"i32", "loke_rt_v1_map_clone", "ptr, ptr, ptr, ptr", ""},
	{"void", "loke_rt_v1_map_drop", "ptr, ptr", ""},
	{"i64", "loke_rt_v1_hash_bytes", "ptr, i64, i64", ""},
	{"i64", "loke_rt_v1_map_scan", "ptr, ptr, i64, ptr, ptr", ""},
	{"void", "loke_rt_v1_map_bind", "ptr", ""},
	{"ptr", "loke_rt_v1_map_find", "ptr, ptr, ptr", ""},
	{"ptr", "loke_rt_v1_map_entry", "ptr, ptr, ptr, ptr", ""},
	{"i32", "loke_rt_v1_map_remove", "ptr, ptr, ptr, ptr", ""},
	{"void", "loke_rt_v1_map_clear", "ptr, ptr", ""},
	{"i32", "loke_rt_v1_map_shrink", "ptr, ptr, i64", ""},
	{"void", "loke_rt_v1_sort", "ptr, i64, i64, ptr, i32", ""},
	{"void", "loke_rt_v1_sort_by", "ptr, i64, i64, ptr, ptr", ""},
}

// The operation table for one concrete container type, made once along with
// its element and key thunks.
@(private)
container_ops_global :: proc(e: ^Emitter, type: Type_Id, relocating := false) -> string {
	under := type_underlying(e.c, type)
	element := container_element(e.c, under)
	lifecycle := emit_lifecycle(e, element)
	// A move-only element has no clone; every insertion hands it over, which is
	// the memcpy a NULL clone asks for (design.md "Container insertion"). A
	// relocating table asks the same for an owned element of any type, and only a
	// managed element's clone is more than that memcpy.
	clones := !lifecycle.clone_disabled
	relocates := relocating && clones && lifecycle.managed
	interned := relocates ? &e.container_move_ops : &e.container_ops
	if existing, found := interned[under]; found {
		return existing
	}
	name := generated_name(e, fmt.aprintf(relocates ? "@.loke.ops.%d.move" : "@.loke.ops.%d", int(under)))
	// Registered first, so a container of containers does not recurse forever.
	interned[under] = name

	key := container_key(e.c, under)
	elem_drop := container_drop_thunk(e, element)
	elem_clone := "null"
	if clones && !relocates {
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
	table := fmt.aprintf(
		"%s = private unnamed_addr constant %s {{ i64 %d, i64 %d, ptr %s, ptr %s, i64 %d, i64 %d, ptr %s, ptr %s, ptr %s, ptr %s }\n",
		name, CONTAINER_OPS_TYPE, type_size(e.c, element), type_align(e.c, element), elem_drop, elem_clone,
		key_size, key_align, key_drop, key_clone, key_hash, key_equal,
	)
	append(&e.globals, table)
	return name
}

// The element storage and live count of a sequence member's receiver: loaded
// through a container header's address, or read out of a slice value.
@(private = "file")
synth_sequence_storage :: proc(e: ^Emitter, symbol: ^Symbol) -> (data: string, count: string) {
	receiver := symbol.params[0]
	if type_is_container(e.c, receiver) {
		data = load(e, "ptr", gep_field(e, CONTAINER_TYPE, "%arg0", CONTAINER_STORAGE))
		count = load(e, "i64", gep_field(e, CONTAINER_TYPE, "%arg0", CONTAINER_LEN))
		return
	}
	header := llvm_type(e, receiver)
	self := synth_receiver_value(e, symbol)
	data, count = ptr_len_parts(e, header, self)
	return
}

// `xs.sort()` and `s.sort()`: one call into `runtime/container.c`'s introsort.
@(private = "file")
emit_synth_sort :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	element := sequence_element(e.c, symbol.params[0])

	open_synth_function(e, symbol, name)

	// Only a call settles an element's `<`, so an unsettled comparison means
	// this contributed member is never called and its body can be empty.
	#partial switch resolved_element_order_policy(e.c, element).kind {
	case .Builtin, .Inherent:
	case:
		fmt.sbprintln(&e.b, "  ret void")
		fmt.sbprintln(&e.b, "}")
		return
	}

	data, count := synth_sequence_storage(e, symbol)

	fmt.sbprintfln(
		&e.b, "  call void @loke_rt_v1_sort(ptr %s, i64 %s, i64 %d, ptr %s, i32 %d)",
		data, count, type_size(e.c, element), container_less_thunk(e, element),
		symbol.container_op == .Reverse_Sort ? 1 : 0,
	)
	fmt.sbprintln(&e.b, "  ret void")
	fmt.sbprintln(&e.b, "}")
}

// standard-library.md "Swapping elements": two elements change place, so no copy or drop
// hook runs. Both loads precede either store, so equal indices are a no-op.
@(private = "file")
emit_synth_swap :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	element := sequence_element(e.c, symbol.params[0])
	element_llvm := llvm_type(e, element)

	open_synth_function(e, symbol, name)

	data, count := synth_sequence_storage(e, symbol)

	emit_bounds_check(e, "%arg1", count, "index out of range")
	emit_bounds_check(e, "%arg2", count, "index out of range")

	left := gep_at(e, element_llvm, data, "%arg1")
	right := gep_at(e, element_llvm, data, "%arg2")
	held_left := load_place(e, element, left)
	held_right := load_place(e, element, right)
	store(e, element, held_right, left)
	store(e, element, held_left, right)
	fmt.sbprintln(&e.b, "  ret void")
	fmt.sbprintln(&e.b, "}")
}

// standard-library.md "Splitting a mutable slice": one bounds check and two headers over
// the receiver's elements.
@(private = "file")
emit_synth_split :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	header := llvm_type(e, symbol.params[0])
	element_llvm := llvm_type(e, slice_element(e.c, symbol.params[0]))
	halves := llvm_type(e, symbol.result)

	open_synth_function(e, symbol, name)

	data, count := synth_sequence_storage(e, symbol)
	// `mid == len` leaves `right` empty.
	emit_bounds_check(e, "%arg1", count, "split index out of range", inclusive = true)

	rest := gep_at(e, element_llvm, data, "%arg1")
	rest_count := emit_value(e, "sub i64 %s, %%arg1", count)
	left := emit_ptr_len(e, header, data, "%arg1")
	right := emit_ptr_len(e, header, rest, rest_count)
	value := insert(e, halves, "undef", header, left, 0)
	value = insert(e, halves, value, header, right, 1)
	emit_ret(e, symbol.result, value)
	fmt.sbprintln(&e.b, "}")
}

// standard-library.md "Chunks of a mutable slice": the view over the receiver, after the
// chunk length is checked.
@(private = "file")
emit_synth_chunks :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	header := llvm_type(e, symbol.params[0])
	chunks := llvm_type(e, symbol.result)

	open_synth_function(e, symbol, name)

	not_positive := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp slt i64 %%arg1, 1", not_positive)
	panic_if(e, not_positive, "bounds", "chunk length must be positive")
	value := insert(e, chunks, "undef", header, synth_receiver_value(e, symbol), CHUNKS_REST)
	value = insert(e, chunks, value, "i64", "%arg1", CHUNKS_SIZE)
	emit_ret(e, symbol.result, value)
	fmt.sbprintln(&e.b, "}")
}

// `next` for `chunks_mut`: the next `size` elements of what is left, or all of
// it when fewer remain, and what is left past them.
@(private)
emit_synth_chunks_next :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	option := symbol.result
	slice := option_payload(e.c, option)
	header := llvm_type(e, slice)
	element := llvm_type(e, slice_element(e.c, slice))
	iterator := llvm_type(e, symbol.params[0])

	open_synth_receiver(e, name, option)
	rest_ptr := gep_field(e, iterator, "%arg0", CHUNKS_REST)
	rest := load(e, header, rest_ptr)
	data, count := ptr_len_parts(e, header, rest)
	size := load(e, "i64", gep_field(e, iterator, "%arg0", CHUNKS_SIZE))
	empty := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp sle i64 %s, 0", empty, count)
	stop_label, yield_label := new_label(e, "chunks.stop"), new_label(e, "chunks.yield")
	branch_if(e, empty, stop_label, yield_label)

	place_label(e, yield_label)
	short, taken, left := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp slt i64 %s, %s", short, count, size)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, i64 %s, i64 %s", taken, short, count, size)
	fmt.sbprintfln(&e.b, "  %s = sub i64 %s, %s", left, count, taken)
	chunk := emit_ptr_len(e, header, data, taken)
	store(e, slice, emit_ptr_len(e, header, gep_at(e, element, data, taken), left), rest_ptr)
	emit_ret(e, option, emit_option_some(e, option, chunk))

	close_synth_next(e, option, stop_label)
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
	data, count := ptr_len_parts(e, storage, value)
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
	name := generated_name(e, fmt.aprintf("@loke.csortby.%d.%d", int(method), int(element)))
	thunk, fresh := begin_thunk(e, name)
	if !fresh {
		return name
	}
	open_function(e, "define private i32 %s(ptr %%state, ptr %%a, ptr %%b)", name)
	// A value `self` takes the comparator itself.
	state := hook_argument(e, method, 0, symbol_of(e.c, method).params[0], "%state")
	left := hook_argument(e, method, 1, element, "%a")
	right := hook_argument(e, method, 2, element, "%b")
	before := temp(e)
	fmt.sbprintfln(&e.b, "  %s = call i1 %s(%s, %s, %s)", before, symbol_name(e, method), state, left, right)
	emit_ret_flag(e, before)
	fmt.sbprintln(&e.b, "}")
	end_thunk(e, thunk)
	return name
}

// An `i1` answer, widened to the `int` the C runtime reads.
@(private = "file")
emit_ret_flag :: proc(e: ^Emitter, flag: string) {
	widened := temp(e)
	fmt.sbprintfln(&e.b, "  %s = zext i1 %s to i32", widened, flag)
	fmt.sbprintfln(&e.b, "  ret i32 %s", widened)
}

// One comparison per element type, using the `<` policy settled during checking.
@(private = "file")
container_less_thunk :: proc(e: ^Emitter, element: Type_Id) -> string {
	return memo_thunk(
		e, generated_name(e, fmt.aprintf("@loke.cless.%d", int(element))), element,
		"i32", "ptr %a, ptr %b",
		proc(e: ^Emitter, element: Type_Id) {
			before := ""
			if policy := resolved_element_order_policy(e.c, element); policy.kind == .Inherent {
				before = temp(e)
				fmt.sbprintfln(
					&e.b, "  %s = call i1 %s(%s, %s)", before, symbol_name(e, policy.less),
					hook_argument(e, policy.less, 0, element, "%a"), hook_argument(e, policy.less, 1, element, "%b"),
				)
			} else {
				left := load_temporary(e, element, "%a")
				right := load_temporary(e, element, "%b")
				before = emit_compare(e, .Lt, element, left, right)
			}
			emit_ret_flag(e, before)
		},
	)
}

// One typed operand of a direct call from a thunk to `hook`, given the address
// the C runtime handed over: that address for a pointer-mode parameter, and
// otherwise the value in the parameter ABI, where a large one stays an address.
@(private)
hook_argument :: proc(e: ^Emitter, hook: Symbol_Id, index: int, type: Type_Id, address: string) -> string {
	mode := symbol_param_mode(e.c, symbol_of(e.c, hook), index)
	if param_mode_is_pointer(mode) {
		return fmt.aprintf("ptr %s", address)
	}
	return fmt.aprintf("%s %s", param_llvm(e, type, mode), load_temporary(e, type, address))
}

// NULL means the part is trivially destroyed, so the C loop is skipped.
@(private = "file")
container_drop_thunk :: proc(e: ^Emitter, part: Type_Id) -> string {
	if !emit_lifecycle(e, part).managed {
		return "null"
	}
	// design.md "What the unwind runs, and what it does not": the element's own
	// drop registers what it has not dropped yet, as a procedure's would.
	return memo_thunk(
		e, generated_name(e, fmt.aprintf("@loke.cdrop.%d", int(type_underlying(e.c, part)))), part,
		"void", "ptr %p",
		proc(e: ^Emitter, part: Type_Id) {
			emit_drop_place(e, part, "%p")
			emit_unwind_pop(e)
			fmt.sbprintln(&e.b, "  ret void")
		},
		framed = true,
	)
}

// NULL means the part's clone is its bytes, so the C helper memcpys the run.
@(private = "file")
container_clone_thunk :: proc(e: ^Emitter, part: Type_Id) -> string {
	if !emit_lifecycle(e, part).managed {
		return "null"
	}
	return memo_thunk(
		e, generated_name(e, fmt.aprintf("@loke.cclone.%d", int(type_underlying(e.c, part)))), part,
		"i32", "ptr %out, ptr %src, ptr %a",
		proc(e: ^Emitter, part: Type_Id) {
			emit_ret_flag(e, emit_try_clone_into(e, part, "%out", "%src", "%a"))
		},
	)
}

// The table freezes the key's `==`/`hash` pair settled during checking. Keyed
// by the key type itself, not its underlying one: a `distinct` key may carry
// its own pair.
@(private = "file")
container_hash_thunk :: proc(e: ^Emitter, key: Type_Id) -> string {
	return memo_thunk(
		e, generated_name(e, fmt.aprintf("@loke.chash.%d", int(key))), key,
		"i64", "ptr %p, i64 %seed",
		proc(e: ^Emitter, key: Type_Id) {
			out := ""
			if hook := settled_key_policy(e, key).hash; hook != INVALID_SYMBOL {
				out = temp(e)
				fmt.sbprintfln(
					&e.b, "  %s = call i64 %s(%s, i64 %%seed)",
					out, symbol_name(e, hook), hook_argument(e, hook, 0, key, "%p"),
				)
			} else {
				out = emit_hash_value(e, key, load_temporary(e, key, "%p"), "%seed")
			}
			fmt.sbprintfln(&e.b, "  ret i64 %s", out)
		},
	)
}

@(private = "file")
container_equal_thunk :: proc(e: ^Emitter, key: Type_Id) -> string {
	return memo_thunk(
		e, generated_name(e, fmt.aprintf("@loke.cequal.%d", int(key))), key,
		"i32", "ptr %a, ptr %b",
		proc(e: ^Emitter, key: Type_Id) {
			same := ""
			if hook := settled_key_policy(e, key).equal; hook != INVALID_SYMBOL {
				same = temp(e)
				fmt.sbprintfln(
					&e.b, "  %s = call i1 %s(%s, %s)", same, symbol_name(e, hook),
					hook_argument(e, hook, 0, key, "%a"), hook_argument(e, hook, 1, key, "%b"),
				)
			} else {
				same = emit_compare(e, .Eq_Eq, key, load_temporary(e, key, "%a"), load_temporary(e, key, "%b"))
			}
			emit_ret_flag(e, same)
		},
	)
}

// The key type's inherent `hash` and `operator(==)`, each INVALID_SYMBOL when
// the compiler supplies it.
@(private = "file")
settled_key_policy :: proc(e: ^Emitter, key: Type_Id) -> Key_Policy {
	policy := e.c.map_key_policies[key]
	if !key_policy_settled(policy) {
		backend_fail(e, "a map key operation was not resolved during checking")
	}
	return policy
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

// The provider an implicit clone into a destination uses: its declaration's
// `via`, or the default (design.md "Value semantics and the ownership rule").
@(private)
emit_destination_allocator :: proc(e: ^Emitter, symbol_id: Symbol_Id) -> string {
	written := symbol_via_allocator(e.c, symbol_id)
	return written == nil ? emit_default_allocator(e) : emit_expr(e, written)
}

// Stores a written `via`, binds the header, and reserves room for every written
// element; a temporary unwind action then covers the built prefix until the
// literal is complete.
@(private = "file")
begin_container_literal :: proc(
	e: ^Emitter, v: ^Expr_Composite, address: string, as_type: Type_Id,
) -> (ops: string, cleanup: Deferred) {
	ops = container_ops_global(e, as_type)
	// The policy is written before the first reservation.
	if v.via != nil {
		emit_store_via(e, address, v.via)
	}
	family := type_is_map(e.c, as_type) ? "map" : "dyn"
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_%s_bind(ptr %s)", family, address)
	reserved := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call i32 @loke_rt_v1_%s_reserve(ptr %s, ptr %s, i64 %d)",
		reserved, family, address, ops, len(v.elements),
	)
	emit_container_policy_failure(e, address, reserved)
	return ops, begin_temporary_drop(e, as_type, address)
}

// `[dynamic]T{a, b, c}` over an already zeroed header. Each element is appended
// as soon as it is evaluated.
@(private)
emit_dynamic_literal_into :: proc(e: ^Emitter, v: ^Expr_Composite, address: string, element: Type_Id, as_type: Type_Id) {
	if len(v.elements) == 0 {
		return
	}
	ops, cleanup := begin_container_literal(e, v, address, as_type)

	// A borrowed element is cloned in; an owned one relocates.
	relocating := container_ops_global(e, as_type, relocating = true)
	slot := alloca(e, llvm_type(e, element))
	for written, index in v.elements {
		operand := begin_operand_temporaries(e)
		borrowed := index < len(v.element_clones) && v.element_clones[index]
		// design.md "Widening by label": a widened element is copied at its own
		// type through the array's provider, and the copy relocates.
		if borrowed && expr_base(written.value).widened_from != INVALID_TYPE {
			provider := load(e, "ptr", gep_field(e, CONTAINER_TYPE, address, CONTAINER_ALLOC))
			store(e, element, emit_copied_expr(e, written.value, element, true, provider), slot)
			borrowed = false
		} else {
			store(e, element, emit_expr(e, written.value), slot)
		}
		status := temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i32 @loke_rt_v1_dyn_append(ptr %s, ptr %s, ptr %s, i64 1)",
			status, address, borrowed ? ops : relocating, slot,
		)
		emit_container_policy_failure(e, address, status)
		end_operand_temporaries(e, operand, element)
	}
	unwind_stop_reusing(e)
	finish_temporary_drop(e, cleanup)
}

// `map[K]V{ key = value, ... }` over an already zeroed header. Each entry is
// inserted as soon as it is evaluated, and one set of slots serves them all, so
// their storage does not grow with the literal.
@(private)
emit_map_literal_into :: proc(e: ^Emitter, v: ^Expr_Composite, address: string, element: Type_Id, as_type: Type_Id) {
	if len(v.elements) == 0 {
		return
	}
	_, cleanup := begin_container_literal(e, v, address, as_type)
	// design.md "Maps": a borrowed element clones through the map's own provider.
	provider := load(e, "ptr", gep_field(e, CONTAINER_TYPE, address, CONTAINER_ALLOC))

	key_storage := alloca(e, llvm_type(e, container_key(e.c, as_type)))
	held := emit_lifecycle(e, element).managed ? alloca(e, llvm_type(e, element)) : ""
	slots := make_map_entry_slots(e, element)
	for written, index in v.elements {
		operand := begin_operand_temporaries(e)
		// The map clones the key, so the probe only borrows it.
		key_slot, key_cleanup := emit_map_key_slot(e, written.key, as_type, key_storage)
		value := emit_copied_expr(e, written.value, element, index < len(v.element_clones) && v.element_clones[index], provider)
		// design.md "What the unwind runs, and what it does not": the value is
		// owned here until the map holds it, across the key's hash and clone and
		// the drop of an entry it replaces.
		guard := hold_temporary_value(e, element, value, held)
		emit_map_insert_store(e, {as_type, address, key_slot, key_cleanup, slots}, value, guard)
		end_operand_temporaries(e, operand, element, container_key(e.c, as_type))
	}
	unwind_stop_reusing(e)
	finish_temporary_drop(e, cleanup)
}

// Where a map insertion reports whether the entry is new, where the entry is,
// where the value waits to be stored, and where a replaced value waits for its
// drop. A literal's entries share them.
@(private)
Map_Entry_Slots :: struct {
	inserted, place, value, old: string,
}

@(private = "file")
make_map_entry_slots :: proc(e: ^Emitter, element: Type_Id) -> Map_Entry_Slots {
	return {alloca(e, "i32"), alloca(e, "ptr"), alloca(e, llvm_type(e, element)), alloca(e, llvm_type(e, element))}
}

// The entry `emit_map_entry` found, and the value to store there, kept in `slots`
// across the check for a failed insertion: a value that crossed the branch would take
// a stack slot of its own at `-opt=none`, one per entry of a long literal. What a
// guard holds is not always the value, as a destructured union widens after it.
@(private = "file")
park_map_entry :: proc(e: ^Emitter, element: Type_Id, slots: Map_Entry_Slots, place, value: string) -> string {
	fmt.sbprintfln(&e.b, "  store ptr %s, ptr %s", place, slots.place)
	store(e, element, value, slots.value)
	return slots.value
}

// Stores the value at `value_place` into the map entry `park_map_entry` kept,
// which then owns it in place of `guard`. A new entry holds inert bytes; an
// existing one's old value is moved out and dropped only once the entry holds the
// new one, so a panicking drop hook leaves the map no value to drop again
// (design.md "Lifecycle hooks and resource types"). Moving out a new entry's inert
// bytes harms nothing, so only the drop branches, and nothing this block computes
// is used after it.
@(private = "file")
emit_store_entry :: proc(e: ^Emitter, element: Type_Id, slots: Map_Entry_Slots, value_place: string, guard: Deferred) {
	place := load(e, "ptr", slots.place)
	managed := emit_lifecycle(e, element).managed
	if managed {
		store(e, element, load_temporary(e, element, place), slots.old)
	}
	store(e, element, load_temporary(e, element, value_place), place)
	finish_temporary_drop(e, guard)
	if !managed {
		return
	}
	is_new := icmp_zero(e, "i32", load(e, "i32", slots.inserted), equal = false)
	replaced_label, done_label := new_label(e, "mentry.replaced"), new_label(e, "mentry.stored")
	branch_if(e, is_new, done_label, replaced_label)
	place_label(e, replaced_label)
	emit_drop_place(e, element, slots.old)
	place_label(e, done_label)
}

// The header's provider applies its own failure policy; it does not return.
@(private = "file")
emit_alloc_failure :: proc(e: ^Emitter, header: string) {
	emit_alloc_failed(e, load(e, "ptr", gep_field(e, CONTAINER_TYPE, header, CONTAINER_ALLOC)))
}

// A zero `status` from an operation that has no result to report through.
@(private = "file")
emit_container_policy_failure :: proc(e: ^Emitter, header, status: string) {
	kept := branch_on_failure(e, status)
	emit_alloc_failure(e, header)
	rejoin(e, kept)
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
	case .Split_At_Mut:
		emit_synth_split(e, symbol, name)
		return
	case .Chunks_Mut:
		emit_synth_chunks(e, symbol, name)
		return
	}
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	op := symbol.container_op
	container := symbol.params[0]
	element := container_element(e.c, container)
	lifecycle := emit_lifecycle(e, element)
	element_llvm := llvm_type(e, element)
	// A consuming `append` of a copyable element takes a pack it partly owns, with
	// a flag per element, and clones the rest through the ordinary table.
	masked := consuming && op == .Append && !lifecycle.clone_disabled
	ops := container_ops_global(e, container, relocating = consuming && !masked)
	// A move-only element, or any element of a consuming body, is handed over,
	// so this body owns it until it is stored.
	moves := consuming || lifecycle.clone_disabled
	body := Container_Body {
		symbol       = symbol,
		container    = container,
		element      = element,
		lifecycle    = lifecycle,
		element_llvm = element_llvm,
		ops          = ops,
		result       = llvm_result_type(e, symbol.result, symbol.result_inout),
		moves        = moves,
		masked       = masked,
		fallible     = symbol.result != INVALID_TYPE && type_is_union(e.c, symbol.result),
	}

	open_synth_function(e, symbol, name, masked ? ", ptr %owned" : "")
	// design.md "Container insertion": a value this body owns stays registered
	// until the container holds it, since a helper or a key hook can panic first.
	framed := op == .Map_Find_Or_Insert || op == .Map_Try_Insert || op == .Insert && moves
	frame_header: strings.Builder
	if framed {
		frame_header = begin_generated_frame(e, name)
	}
	defer if framed {
		end_generated_frame(e, frame_header)
	}

	status := ""
	switch op {
	case .Append:
		status = emit_synth_append(e, body)

	case .Insert:
		slot := spill(e, element, "%arg2")
		guard := moves ? guard_built_element(e, element, slot) : Deferred{}
		status = temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i32 @loke_rt_v1_dyn_insert(ptr %%arg0, ptr %s, i64 %%arg1, ptr %s, i64 1)",
			status, ops, slot,
		)
		// The helper takes the value only once nothing can panic.
		finish_temporary_drop(e, guard)
		if moves {
			kept := branch_on_failure(e, status)
			emit_drop_place(e, element, slot)
			rejoin(e, kept)
		}

	case .Pop:
		out := alloca(e, element_llvm)
		found := temp(e)
		fmt.sbprintfln(&e.b, "  %s = call i32 @loke_rt_v1_dyn_pop(ptr %%arg0, ptr %s, ptr %s)", found, ops, out)
		value := load_temporary(e, element, out)
		ok := icmp_zero(e, "i32", found, equal = false)
		emit_ret(e, symbol.result, emit_option_value(e, symbol.result, ok, value))

	case .Remove, .Remove_Unordered:
		out := alloca(e, element_llvm)
		fmt.sbprintfln(
			&e.b, "  call void @loke_rt_v1_dyn_remove(ptr %%arg0, ptr %s, i64 %%arg1, ptr %s, i32 %d)",
			ops, out, op == .Remove_Unordered ? 1 : 0,
		)
		emit_ret(e, element, load_temporary(e, element, out))

	case .Clear, .Map_Clear:
		helper := op == .Clear ? "dyn_clear" : "map_clear"
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_%s(ptr %%arg0, ptr %s)", helper, ops)
		fmt.sbprintln(&e.b, "  ret void")

	case .Resize:
		status = status_call(e, "dyn_resize", ops)

	case .Reserve:
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_dyn_bind(ptr %%arg0)")
		status = status_call(e, "dyn_reserve", ops)

	case .Shrink:
		status = status_call(e, "dyn_shrink", ops)

	case .Map_Find:
		found := emit_map_find(e, receiver_header(e, symbol), ops, key_probe_slot(e, symbol, container))
		emit_ret(e, symbol.result, emit_option_value(e, symbol.result, not_null(e, found), found))

	case .Map_Lookup_Value:
		emit_synth_map_lookup_value(e, body)

	case .Map_Find_Or_Insert:
		emit_synth_map_find_or_insert(e, body)

	case .Map_Try_Insert:
		emit_synth_map_try_insert(e, body)

	case .Map_Entries, .Map_Keys, .Map_Values:
		// design.md "Iteration adapters": a view is just the table pointer.
		table := extract(e, llvm_type(e, container), synth_receiver_value(e, symbol), CONTAINER_STORAGE)
		view := insert(e, body.result, "undef", "ptr", table, VIEW_SOURCE)
		fmt.sbprintfln(&e.b, "  ret %s %s", body.result, view)

	case .Map_Remove:
		key_slot := key_probe_slot(e, symbol, container)
		out := alloca(e, element_llvm)
		found := temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i32 @loke_rt_v1_map_remove(ptr %%arg0, ptr %s, ptr %s, ptr %s)",
			found, ops, key_slot, out,
		)
		value := load_temporary(e, element, out)
		ok := icmp_zero(e, "i32", found, equal = false)
		emit_ret(e, symbol.result, emit_option_value(e, symbol.result, ok, value))

	case .Map_Reserve:
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_map_bind(ptr %%arg0)")
		status = status_call(e, "map_reserve", ops)

	case .Map_Shrink:
		status = status_call(e, "map_shrink", ops)

	case .None, .Sort, .Reverse_Sort, .Swap, .Split_At_Mut, .Chunks_Mut:
		backend_fail(e, "a contributed container member has no operation")
		fmt.sbprintln(&e.b, "  ret void")
	}

	// A case that set no status has already returned.
	if status != "" {
		if body.fallible {
			emit_ret(e, symbol.result, emit_alloc_result(e, symbol.result, icmp_zero(e, "i32", status)))
		} else {
			emit_container_policy_failure(e, "%arg0", status)
			emit_unwind_pop(e)
			fmt.sbprintln(&e.b, "  ret void")
		}
	}
	fmt.sbprintln(&e.b, "}")
}

// What the parts of one contributed container body share.
@(private = "file")
Container_Body :: struct {
	symbol: ^Symbol,
	container, element: Type_Id,
	lifecycle: Lifecycle_Operations,
	element_llvm, ops, result: string,
	moves, masked, fallible: bool,
}

// A lookup borrows its key; a `string_view` is spilled as an unowned header.
@(private = "file")
key_probe_slot :: proc(e: ^Emitter, symbol: ^Symbol, container: Type_Id) -> string {
	key := container_key(e.c, container)
	if key_is_borrowed_view(key, symbol.params[1]) {
		return emit_borrowed_key_slot(e, "%arg1")
	}
	return spill(e, key, "%arg1")
}

// The header address the C probe reads. An immutable receiver arrives as the
// header value itself.
@(private = "file")
receiver_header :: proc(e: ^Emitter, symbol: ^Symbol) -> string {
	if param_mode_is_pointer(symbol_param_mode(e.c, symbol, 0)) {
		return "%arg0"
	}
	header := alloca(e, CONTAINER_TYPE)
	fmt.sbprintfln(&e.b, "  store %s %%arg0, ptr %s", CONTAINER_TYPE, header)
	return header
}

// A helper's status for the receiver at `%arg0` and the count at `%arg1`.
@(private = "file")
status_call :: proc(e: ^Emitter, helper, ops: string) -> string {
	status := temp(e)
	fmt.sbprintfln(&e.b, "  %s = call i32 @loke_rt_v1_%s(ptr %%arg0, ptr %s, i64 %%arg1)", status, helper, ops)
	return status
}

@(private = "file")
emit_synth_append :: proc(e: ^Emitter, body: Container_Body) -> string {
	pack := llvm_type(e, body.symbol.params[1])
	data, count := ptr_len_parts(e, pack, "%arg1")
	status := temp(e)
	if body.masked {
		fmt.sbprintfln(
			&e.b, "  %s = call i32 @loke_rt_v1_dyn_append_owned(ptr %%arg0, ptr %s, ptr %s, ptr %%owned, i64 %s)",
			status, body.ops, data, count,
		)
		// A failed append leaves every owned element with this body. A `try_`
		// form passes no flags: it owns nothing, and its caller drops the pack.
		kept := branch_on_failure(e, status)
		flagged := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp ne ptr %%owned, null", flagged)
		drop_owned, dropped := new_label(e, "append.owned"), new_label(e, "append.dropped")
		branch_if(e, flagged, drop_owned, dropped)
		place_label(e, drop_owned)
		emit_drop_elements_reversed(e, body.element, data, count, "%owned")
		place_label(e, dropped)
		rejoin(e, kept)
		return status
	}
	fmt.sbprintfln(
		&e.b, "  %s = call i32 @loke_rt_v1_dyn_append(ptr %%arg0, ptr %s, ptr %s, i64 %s)",
		status, body.ops, data, count,
	)
	if body.moves {
		kept := branch_on_failure(e, status)
		emit_drop_run(e, body.element, data, count)
		rejoin(e, kept)
	}
	return status
}

// One probe, no insertion, and an independently owned clone on a hit, made here
// so the destination must not copy again.
@(private = "file")
emit_synth_map_lookup_value :: proc(e: ^Emitter, body: Container_Body) {
	symbol, element := body.symbol, body.element
	header := receiver_header(e, symbol)
	found := emit_map_find(e, header, body.ops, key_probe_slot(e, symbol, body.container))
	present := not_null(e, found)

	out := alloca(e, body.element_llvm)
	hit_label, done_label := new_label(e, "mlookup.hit"), new_label(e, "mlookup.done")
	branch_if(e, present, hit_label, done_label)
	place_label(e, hit_label)
	stored := load_temporary(e, element, found)
	if body.lifecycle.managed {
		stored = emit_clone_value(e, element, stored)
	}
	store(e, element, stored, out)
	place_label(e, done_label)

	value := load_temporary(e, element, out)
	emit_ret(e, symbol.result, emit_option_value(e, symbol.result, present, value))
}

// The slot either way. A miss inserts the element, cloned as `try_insert`
// clones it or moved in; a move-only element is dropped on a hit.
@(private = "file")
emit_synth_map_find_or_insert :: proc(e: ^Emitter, body: Container_Body) {
	symbol, element, ops := body.symbol, body.element, body.ops
	moves, fallible := body.moves, body.fallible
	key_slot := spill(e, container_key(e.c, body.container), "%arg1")
	staged := alloca(e, body.element_llvm)
	guard := Deferred{}
	if moves {
		store(e, element, "%arg2", staged)
		guard = guard_built_element(e, element, staged)
	}
	found := emit_map_find(e, "%arg0", ops, key_slot)
	present := not_null(e, found)
	hit_label, miss_label := new_label(e, "mfoi.hit"), new_label(e, "mfoi.miss")
	branch_if(e, present, hit_label, miss_label)
	place_label(e, hit_label)
	if moves {
		finish_temporary_drop(e, guard)
		emit_drop_place(e, element, staged)
	}
	emit_map_slot_result(e, symbol.result, found, fallible)

	place_label(e, miss_label)
	cloned := "true"
	if !moves && body.lifecycle.managed {
		cloned = emit_try_clone_into(
			e, element, staged, spill(e, element, "%arg2"), emit_map_allocator(e, "%arg0"),
		)
	} else if !moves {
		store(e, element, "%arg2", staged)
	}
	clone_ready, clone_failed := new_label(e, "mfoi.cloned"), new_label(e, "mfoi.clone_failed")
	branch_if(e, cloned, clone_ready, clone_failed)
	place_label(e, clone_failed)
	emit_map_slot_failure(e, symbol.result, "%arg0", fallible)

	place_label(e, clone_ready)
	if !moves {
		guard = guard_built_element(e, element, staged)
	}
	place := emit_map_entry(e, ops, "%arg0", key_slot, alloca(e, "i32"))
	missing := is_null(e, place)
	finish_temporary_drop(e, guard)
	entry_failed, entry_ok := new_label(e, "mfoi.failed"), new_label(e, "mfoi.ok")
	branch_if(e, missing, entry_failed, entry_ok)
	place_label(e, entry_failed)
	emit_drop_place(e, element, staged)
	emit_map_slot_failure(e, symbol.result, "%arg0", fallible)

	place_label(e, entry_ok)
	// The key was absent a moment ago, so the slot is new and inert.
	store(e, element, load_temporary(e, element, staged), place)
	emit_map_slot_result(e, symbol.result, place, fallible)
}

// The value is staged before insertion, so a failed clone neither touches an
// existing entry nor publishes a key without a value.
@(private = "file")
emit_synth_map_try_insert :: proc(e: ^Emitter, body: Container_Body) {
	symbol, element := body.symbol, body.element
	staged := alloca(e, body.element_llvm)
	cloned := "true"
	if body.moves || !body.lifecycle.managed {
		store(e, element, "%arg2", staged)
	} else {
		allocator := emit_map_allocator(e, "%arg0")
		cloned = emit_try_clone_into(e, element, staged, spill(e, element, "%arg2"), allocator)
	}
	clone_ready, clone_failed := new_label(e, "mins.cloned"), new_label(e, "mins.clone_failed")
	branch_if(e, cloned, clone_ready, clone_failed)
	place_label(e, clone_failed)
	emit_ret(e, symbol.result, emit_alloc_result(e, symbol.result, "true"))

	place_label(e, clone_ready)
	// The staged value is this body's until it is stored, across the key's
	// hooks and the old value's drop.
	guard := guard_built_element(e, element, staged)
	key_slot := spill(e, container_key(e.c, body.container), "%arg1")
	slots := make_map_entry_slots(e, element)
	place := emit_map_entry(e, body.ops, "%arg0", key_slot, slots.inserted)
	fmt.sbprintfln(&e.b, "  store ptr %s, ptr %s", place, slots.place)
	missing, ok_label, failed_label := is_null(e, place), new_label(e, "mins.ok"), new_label(e, "mins.failed")
	branch_if(e, missing, failed_label, ok_label)
	place_label(e, failed_label)
	finish_temporary_drop(e, guard)
	emit_drop_place(e, element, staged)
	emit_ret(e, symbol.result, emit_alloc_result(e, symbol.result, "true"))

	place_label(e, ok_label)
	emit_store_entry(e, element, slots, staged, guard)
	emit_ret(e, symbol.result, emit_alloc_result(e, symbol.result, "false"))
}

// `branch_on_failure` opens the block a zero `status` runs, such as the drop of
// a move-only element that failed to enter the container; `rejoin` closes it.
@(private = "file")
branch_on_failure :: proc(e: ^Emitter, status: string) -> string {
	failed := icmp_zero(e, "i32", status)
	drop_label, kept_label := new_label(e, "cop.failed"), new_label(e, "cop.kept")
	branch_if(e, failed, drop_label, kept_label)
	place_label(e, drop_label)
	return kept_label
}

@(private = "file")
rejoin :: proc(e: ^Emitter, kept_label: string) {
	place_label(e, kept_label)
}

// Every element of a `..T` pack, in order.
@(private = "file")
emit_drop_run :: proc(e: ^Emitter, element: Type_Id, data, count: string) {
	loop := open_counted_loop(e, new_counter(e), "unconsumed", count, "ult")
	emit_drop_place(e, element, gep_at(e, llvm_type(e, element), data, loop.index))
	close_counted_loop(e, loop)
}

// `key in m`: one probe, no insertion and no value. The key is evaluated, and
// its temporary protected, before the map (design.md "Evaluation order").
@(private)
emit_map_membership :: proc(e: ^Emitter, v: ^Expr_Binary) -> string {
	container := expr_base(v.rhs).type
	ops := container_ops_global(e, container)
	key_slot, cleanup := emit_map_key_slot(e, v.lhs, container)
	header := emit_borrowed_map(e, v.rhs)
	found := emit_map_find(e, header, ops, key_slot)
	drop_temporary_value(e, cleanup)
	return not_null(e, found)
}

// One probe, no insertion: the entry's value slot, or null.
@(private = "file")
emit_map_find :: proc(e: ^Emitter, header, ops, key_slot: string) -> string {
	found := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call ptr @loke_rt_v1_map_find(ptr %s, ptr %s, ptr %s)", found, header, ops, key_slot,
	)
	return found
}

// The address of a map a read only borrows. A literal is an owned temporary
// that lives until its full expression ends (design.md "Evaluation order").
@(private = "file")
emit_borrowed_map :: proc(e: ^Emitter, operand: Expr) -> string {
	header := emit_address(e, operand)
	if _, composite := operand.(^Expr_Composite); composite {
		hold_addressed_temporary(e, operand, expr_base(operand).type, header)
	}
	return header
}

// The map's own provider, or the build-selected default when it is unbound.
@(private = "file")
emit_map_allocator :: proc(e: ^Emitter, header: string) -> string {
	bound := load(e, "ptr", gep_field(e, CONTAINER_TYPE, header, CONTAINER_ALLOC))
	unbound, allocator := is_null(e, bound), temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = select i1 %s, ptr %s, ptr %s", allocator, unbound, emit_default_allocator(e), bound,
	)
	return allocator
}

// `find_or_insert` answers the slot; `try_find_or_insert` answers it as `.ok`.
@(private = "file")
emit_map_slot_result :: proc(e: ^Emitter, result_type: Type_Id, slot: string, fallible: bool) {
	value := slot
	if fallible {
		value = emit_alloc_result(e, result_type, "false", slot)
	}
	emit_ret(e, result_type, value)
}

// The error for the `try_` spelling, and the provider's policy otherwise.
@(private = "file")
emit_map_slot_failure :: proc(e: ^Emitter, result_type: Type_Id, header: string, fallible: bool) {
	if fallible {
		emit_ret(e, result_type, emit_alloc_result(e, result_type, "true", "null"))
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
	slots: Map_Entry_Slots,
}

@(private)
prepare_map_assignment :: proc(e: ^Emitter, v: ^Expr_Index, snapshot_key: bool) -> Map_Assignment_Destination {
	container := expr_base(v.operand).type
	header := emit_borrowed_map(e, v.operand)
	key_slot, cleanup := emit_map_key_slot(e, v.indices[0], container)
	key := container_key(e.c, container)
	// An earlier destination of a multiple assignment may overwrite the variable
	// supplying this key, so it is snapshotted.
	if snapshot_key && emit_lifecycle(e, key).managed && expression_is_borrowed_place(v.indices[0]) {
		value := emit_clone_value(e, key, load_place(e, key, key_slot))
		store(e, key, value, key_slot)
		cleanup = begin_temporary_drop(e, key, key_slot)
	}
	slots := make_map_entry_slots(e, container_element(e.c, container))
	return Map_Assignment_Destination{container, header, key_slot, cleanup, slots}
}

// The insertion allocates and an assignment cannot report failure, so the
// provider's policy decides.
@(private)
emit_map_insert_store :: proc(e: ^Emitter, destination: Map_Assignment_Destination, value: string, guard: Deferred) {
	container, header, key_slot := destination.container, destination.header, destination.key_slot
	element := container_element(e.c, container)
	ops := container_ops_global(e, container)
	place := emit_map_entry(e, ops, header, key_slot, destination.slots.inserted)
	value_place := park_map_entry(e, element, destination.slots, place, value)
	missing := is_null(e, place)
	fail_label, store_label := new_label(e, "mset.fail"), new_label(e, "mset.store")
	branch_if(e, missing, fail_label, store_label)
	place_label(e, fail_label)
	emit_alloc_failure(e, header)
	place_label(e, store_label)
	// The map owns the value before a user key destructor can panic.
	emit_store_entry(e, element, destination.slots, value_place, guard)
	drop_temporary_value(e, destination.key_cleanup)
}

// The address of an existing `m[key]`, for every position but assignment. A
// missing key panics, as a dynamic array's index does (design.md "Maps").
@(private)
emit_map_element_address :: proc(e: ^Emitter, v: ^Expr_Index) -> string {
	container := expr_base(v.operand).type
	ops := container_ops_global(e, container)
	header := emit_borrowed_map(e, v.operand)
	key_slot, cleanup := emit_map_key_slot(e, v.indices[0], container)

	found := emit_map_find(e, header, ops, key_slot)
	drop_temporary_value(e, cleanup)
	panic_if(e, is_null(e, found), "mkey", "map key not found")
	return found
}

// `m[key]` as a read; `m.lookup_value(key)` is the `Option(V)` form.
@(private)
emit_map_lookup :: proc(e: ^Emitter, v: ^Expr_Index) -> string {
	return load_place(e, container_element(e.c, expr_base(v.operand).type), emit_map_element_address(e, v))
}

// design.md "Maps": the one key form that is not the key type itself.
@(private = "file")
key_is_borrowed_view :: proc(key, given: Type_Id) -> bool {
	return key == TYPE_STRING && given == TYPE_STRING_VIEW
}

// Spills a key for the C helper, which only borrows it, into `storage` when the
// caller has one to reuse. Only an owned temporary gets a cleanup; a borrowed
// place stays its owner's.
@(private = "file")
emit_map_key_slot :: proc(e: ^Emitter, index: Expr, container: Type_Id, storage := "") -> (string, Deferred) {
	key := container_key(e.c, container)
	value := emit_expr(e, index)
	if key_is_borrowed_view(key, expr_base(index).type) {
		return emit_borrowed_key_slot(e, value), Deferred{}
	}
	slot := storage != "" ? storage : alloca(e, llvm_type(e, key))
	store(e, key, value, slot)
	cleanup := Deferred{}
	if emit_lifecycle(e, key).managed && !expression_is_borrowed_place(index) {
		cleanup = begin_temporary_drop(e, key, slot)
	}
	return slot, cleanup
}

// design.md "Maps": a `map[string]V` is queried with a `string_view`, spilled
// as an unowned static header that nothing clones or drops.
@(private = "file")
emit_borrowed_key_slot :: proc(e: ^Emitter, view: string) -> string {
	data, length := ptr_len_parts(e, STRING_VIEW_TYPE, view)
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
emit_map_entry :: proc(e: ^Emitter, ops, header, key_slot, inserted: string) -> string {
	place := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call ptr @loke_rt_v1_map_entry(ptr %s, ptr %s, ptr %s, ptr %s)",
		place, header, ops, key_slot, inserted,
	)
	return place
}

emit_hash_value :: proc(e: ^Emitter, type: Type_Id, value, seed: string) -> string {
	// design.md "Maps": a part with its own `==` hashes by its own `hash`, which
	// is the coherent partner of the `==` structural equality calls for it.
	if own := part_own_hash(e.c, type); own != INVALID_SYMBOL {
		address := value_address(e, type, value)
		out := temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i64 %s(%s, i64 %s)",
			out, callee_name(e, own), hook_argument(e, own, 0, type, address), seed,
		)
		return out
	}
	under := type_underlying(e.c, type)
	info := type_of(e.c, under)
	// A record mixes its fields in declaration order, as an array mixes its
	// elements; a large one is an address, read in place.
	if info != nil && info.kind == .Struct {
		current := seed
		for field, index in info.fields {
			symbol := symbol_of(e.c, field)
			current = emit_hash_value(e, symbol.type, record_part(e, under, value, index), current)
		}
		return current
	}
	// A union mixes its tag, then the active payload, so two variants with one
	// payload type hash apart.
	if info != nil && info.kind == .Union {
		tag := emit_union_tag(e, under, value)
		widened := temp(e)
		fmt.sbprintfln(&e.b, "  %s = zext %s %s to i64", widened, union_tag_llvm(union_layout(e.c, under)), tag)
		tagged := emit_hash_mix(e, seed, widened)
		slot := emit_union_spill(e, under, value)
		state := alloca(e, "i64")
		fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", tagged, state)
		done := new_label(e, "unionhash.done")
		hits := variant_labels(e, info, "unionhash.hit", .Payload)
		emit_union_switch(e, under, tag, hits, done)
		for variant, index in info.variants {
			if hits[index] == "" {
				continue
			}
			place_label(e, hits[index])
			payload := emit_union_payload(e, under, variant, slot)
			payload_hash := emit_hash_value(e, variant, payload, tagged)
			fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", payload_hash, state)
			branch(e, done)
		}
		place_label(e, done)
		return load(e, "i64", state)
	}
	if info != nil && info.kind == .Array {
		// Hashed in a loop where equality compares in one, element by element in
		// memory.
		if array_walks_in_loop(e, under, info) {
			address := value_address(e, under, value)
			element_llvm := llvm_type(e, info.element)
			state := alloca(e, "i64")
			fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", seed, state)
			loop := open_counted_loop(e, new_counter(e), "hash.array", fmt.aprintf("%d", info.count))
			element := load_temporary(e, info.element, gep_at(e, element_llvm, address, loop.index))
			next := emit_hash_value(e, info.element, element, load(e, "i64", state))
			fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", next, state)
			close_counted_loop(e, loop)
			return load(e, "i64", state)
		}
		current := seed
		for index in 0 ..< int(info.count) {
			element := extract(e, llvm_type(e, under), value, index)
			current = emit_hash_value(e, info.element, element, current)
		}
		return current
	}
	// design.md: `string` and `string_view` hash byte-wise, which is the coherent
	// partner of the byte-wise `==` they already have.
	if type_is_utf8_text(e.c, under) {
		storage := llvm_type(e, under)
		data, length := string_parts(e, storage, value)
		out := temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i64 @loke_rt_v1_hash_bytes(ptr %s, i64 %s, i64 %s)",
			out, data, length, seed,
		)
		return out
	}
	return emit_hash_mix(e, seed, emit_hash_bits(e, under, value))
}

// One hash step: `bits` folded into `seed`.
@(private = "file")
emit_hash_mix :: proc(e: ^Emitter, seed, bits: string) -> string {
	mixed, out := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = xor i64 %s, %s", mixed, seed, bits)
	fmt.sbprintfln(&e.b, "  %s = mul i64 %s, %d", out, mixed, HASH_MULTIPLIER)
	return out
}

// One scalar's 64-bit integer image.
@(private = "file")
emit_hash_bits :: proc(e: ^Emitter, under: Type_Id, value: string) -> string {
	#partial switch type_of(e.c, under).kind {
	case .Bool:
		return resize_int(e, value, 1, 64, signed = false)
	case .Raw_Pointer, .Pointer, .C_Pointer:
		return emit_value(e, "ptrtoint ptr %s to i64", value)
	}
	return widen_to_i64(e, value, under)
}

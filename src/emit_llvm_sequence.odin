// The members every sequence shares, over a dynamic array's storage or a
// `[]mut T` view: `sort`, `swap`, `split_at_mut`, `chunks_mut`, and `core:slice`'s
// typed-comparator sort.
//
// Part of the textual LLVM backend; see compiler-architecture.md.
package lokec

import "core:fmt"

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
@(private)
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
@(private)
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
@(private)
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
@(private)
emit_synth_chunks :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	header := llvm_type(e, symbol.params[0])
	chunks := llvm_type(e, symbol.result)

	open_synth_function(e, symbol, name)

	not_positive := emit_value(e, "icmp slt i64 %%arg1, 1")
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
	empty := emit_value(e, "icmp sle i64 %s, 0", count)
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
	before := emit_value(e, "call i1 %s(%s, %s, %s)", symbol_name(e, method), state, left, right)
	emit_ret_flag(e, before)
	fmt.sbprintln(&e.b, "}")
	end_thunk(e, thunk)
	return name
}

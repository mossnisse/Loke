// Resolved calls, argument packing, conversions, and allocation builtins.
package lokec

import "core:fmt"

// ------------------------------------------------------------------- calls --

// design.md "Exchange": the replacement is fully evaluated before the
// destination is touched, and the old value is handed back, not dropped.
@(private = "file")
emit_exchange :: proc(e: ^Emitter, v: ^Expr_Call, as_type: Type_Id) -> string {
	address := emit_address(e, v.bound[0])
	replacement := emit_expr(e, v.bound[1])
	previous := load_place(e, as_type, address)
	store(e, as_type, replacement, address)
	return previous
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
// run time for a provider with no region
// (design.md "Allocator regions and region provenance").
@(private = "file")
emit_region_reset :: proc(e: ^Emitter, v: ^Expr_Call) {
	handle := emit_expr(e, v.bound[0])
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_reset(ptr %s)", handle)
}

@(private)
emit_call :: proc(e: ^Emitter, v: ^Expr_Call, as_type: Type_Id) -> string {
	if v.dispatch != nil {
		return emit_type_switch(e, v.dispatch, as_type)
	}
	if call_diverges(e.c, v) {
		return emit_diverging_call(e, v, as_type)
	}
	switch operation in v.operation {
	case Call_Enum_From_Int:
		return emit_enum_from_int(e, v, operation.type, as_type)
	case Call_Union_As:
		return emit_union_as(e, v, operation.index, as_type)
	case Call_Box_Unbox:
		return emit_box_unbox(e, v)
	case Call_Dyn_Slot:
		return emit_dyn_slot_call(e, v)
	case Call_Dyn_Conversion:
		return emit_dyn_value(e, v, as_type)
	case Call_Text_Conversion:
		return emit_text_conversion(e, v, as_type)
	case Call_Conversion:
		return emit_conversion(e, v, as_type)
	case Call_Reflect:
		return emit_descriptor_operation(e, v)
	case Call_Union_Construct:
		return emit_union_construct(e, v, operation, as_type)
	case Call_Text:
		return emit_text_operation(e, v, as_type)
	case Call_Procedure:
		return emit_direct_call(e, v)
	case Call_Builtin, Call_Atomic, Call_Allocation, Call_Sort_By, Call_Simd_Reduce:
	case nil, Call_Compile_Time:
		backend_fail(e, "an unchecked or compile-time call reached emission")
		return "0"
	}
	switch kind := call_builtin_kind(e, v); kind {
	case .Assert:
		cond := emit_expr(e, v.bound[0])
		fail, ok := new_label(e, "assert.failed"), new_label(e, "ok")
		branch_if(e, cond, ok, fail)
		place_label(e, fail)
		emit_formatted_panic(e, v, 1, "assertion failed")
		place_label(e, ok)
		return "0"
	case .Panic, .Allocation_Failed:
		backend_fail(e, "a diverging built-in bypassed emit_diverging_call")
		return "0"
	case .Default_Allocator:
		return emit_default_allocator(e)
	case .Box_New, .Try_Box, .Unsafe_New, .Unsafe_Try_New:
		return emit_box_new(e, v, as_type)
	case .Make, .Try_Make:
		return emit_make_container(e, v, as_type)
	case .Drop:
		emit_explicit_drop(e, v)
		return "0"
	case .Exchange:
		return emit_exchange(e, v, as_type)
	case .Unsafe_Raw_Data, .Unsafe_String_View, .Unsafe_C_String_View:
		return emit_unsafe_builtin(e, v, kind, as_type)
	case .Unsafe_Transmute:
		return emit_transmute(e, v, as_type)
	case .Math_Wrap:
		source := expr_base(v.bound[0]).type
		return emit_value_conversion(e, emit_expr(e, v.bound[0]), source, as_type, checked = false)
	case .Math_Fma_Available:
		return emitted_has_fma(e) ? "true" : "false"
	case .Math_Fma_Instruction:
		return emit_fma_instruction(e, v)
	case .Math_Sqrt_Instruction:
		return emit_float_instruction(e, v, "sqrt")
	case .Math_Floor_Instruction:
		return emit_float_instruction(e, v, "floor")
	case .Math_Ceil_Instruction:
		return emit_float_instruction(e, v, "ceil")
	case .Math_Trunc_Instruction:
		return emit_float_instruction(e, v, "trunc")
	case .Math_Round_Instruction:
		return emit_float_instruction(e, v, "round")
	case .Math_Mod_Instruction:
		llvm := llvm_type(e, expr_base(v.bound[0]).type)
		x, y := emit_expr(e, v.bound[0]), emit_expr(e, v.bound[1])
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = frem %s %s, %s", out, llvm, x, y)
		return out
	case .Math_Count_Ones:
		return emit_bit_count(e, v, "ctpop")
	case .Math_Leading_Zeros:
		return emit_bit_count(e, v, "ctlz")
	case .Math_Trailing_Zeros:
		return emit_bit_count(e, v, "cttz")
	case .Math_Rotate_Left:
		return emit_rotate(e, v, "fshl")
	case .Math_Rotate_Right:
		return emit_rotate(e, v, "fshr")
	case .Math_Bit_Width:
		return emit_bit_width(e, v)
	case .Math_Reverse_Bits:
		return emit_reverse_bits(e, v)
	case .Math_Is_Power_Of_Two:
		return emit_is_power_of_two(e, v)
	case .Math_Next_Power_Of_Two:
		return emit_next_power_of_two(e, v, as_type, checked = false)
	case .Math_Checked_Next_Power_Of_Two:
		return emit_next_power_of_two(e, v, as_type, checked = true)
	case .Unsafe_Take:
		return load_place(e, as_type, emit_address(e, v.bound[0]))
	case .Unsafe_Write:
		written := expr_base(v.bound[0]).type
		address := emit_address(e, v.bound[0])
		copies := emit_lifecycle(e, copied_type(v.bound[1], written)).managed && expression_is_borrowed_place(v.bound[1])
		value := emit_copied_expr(e, v.bound[1], written, copies)
		store(e, written, value, address)
		return "0"
	case .Unsafe_Forget:
		// Skips the drop an owned temporary would get; `emit_move` still kills a
		// `move(place)` source.
		emit_expr(e, v.bound[0])
		return "0"
	case .Type_Info_Of:
		return emit_type_info_of(e, v)
	case .Fmt_Stdout_Writer, .Fmt_Stderr_Writer, .Fmt_Write_Bytes:
		return emit_fmt_builtin(e, v, kind)
	case .Strings_Allocate:
		return emit_strings_allocate(e, v, as_type)
	case .Slice_Sort_By:
		emit_slice_sort_by(e, v)
		return "0"
	case .Atomic_Load, .Atomic_Store, .Atomic_Exchange, .Atomic_Compare_Exchange,
	     .Atomic_Add, .Atomic_Sub, .Atomic_And, .Atomic_Or, .Atomic_Xor, .Atomic_Fence:
		return emit_atomic_builtin(e, v, kind, as_type)
	case .Simd_Cast, .Simd_Select, .Simd_Reduce:
		return emit_simd_builtin(e, v, kind, as_type)
	case .Unsafe_Free:
		emit_free(e, v)
		return "0"
	case .Free_All:
		emit_region_reset(e, v)
		return "0"
	case .None, .Size_Of, .Align_Of, .Offset_Of, .Is_Copyable, .Is_Union,
	     .Static_Assert, .Build_Config, .Source_Location, .Caller_Location,
	     .Type_Of, .Typeid_Of, .Fields_Of, .Enum_Values_Of, .Variants_Of:
	}
	backend_fail(e, "a call with no run-time built-in reached emission")
	return "0"
}

// Compare at the argument's width; a member it cannot hold never matches.
@(private = "file")
emit_enum_from_int :: proc(e: ^Emitter, v: ^Expr_Call, enum_type, as_type: Type_Id) -> string {
	source := expr_base(v.bound[0]).type
	bits, signed := type_bits(e.c, source), type_signed(e.c, source)
	value := emit_expr(e, v.bound[0])
	present := "false"
	for member in underlying_info(e.c, enum_type).fields {
		sym := symbol_of(e.c, member)
		if !bi_fits(e.c, sym.const_value.integer, bits, signed) {
			continue
		}
		matches := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp eq i%d %s, %s", matches,
			bits, value, bi_text(e.c, sym.const_value.integer))
		if present == "false" {
			present = matches
		} else {
			joined := temp(e)
			fmt.sbprintfln(&e.b, "  %s = or i1 %s, %s", joined, present, matches)
			present = joined
		}
	}
	// A matching value fits both widths, so the resize is exact when it counts.
	if backing_bits := type_bits(e.c, enum_type); backing_bits != bits {
		resized := temp(e)
		op := backing_bits < bits ? "trunc" : (signed ? "sext" : "zext")
		fmt.sbprintfln(&e.b, "  %s = %s i%d %s to i%d", resized, op, bits, value, backing_bits)
		value = resized
	}
	return emit_option_value(e, as_type, present, value)
}

// `field.pointer(value)` is the field's address, and so is the place
// `field.get(value)`, which its reader loads.
@(private = "file")
emit_descriptor_operation :: proc(e: ^Emitter, v: ^Expr_Call) -> string {
	checked := v.operation.(Call_Reflect)
	base := emit_expr(e, v.bound[0])
	owner := underlying_info(e.c, expr_base(v.bound[0]).type)
	field := symbol_of(e.c, checked.field)
	return element_address(e, owner.element, base, int(field.index))
}

// An operator, index, or slice call. A non-empty `left_place` is the address
// of an already-evaluated left operand.
@(private)
emit_operator_call :: proc(e: ^Emitter, symbol_id: Symbol_Id, bound: []Expr, left_place := "") -> string {
	symbol := symbol_of(e.c, symbol_id)
	if symbol == nil {
		return "0"
	}
	if symbol.delegated {
		return emit_delegated(e, symbol, bound, left_place)
	}
	info := type_of(e.c, symbol.proc_type)
	receiver := left_place
	if left_place != "" && !param_mode_is_pointer(info.param_modes[0]) {
		receiver = load_place(e, info.parameters[0], left_place)
	}
	return emit_bound_call(e, symbol_id, callee_name(e, symbol_id), info, bound, receiver = receiver)
}

// A `distinct` newtype's forwarding overload.
@(private = "file")
emit_delegated :: proc(e: ^Emitter, symbol: ^Symbol, bound: []Expr, left_place: string) -> string {
	if symbol.delegate_target != INVALID_SYMBOL {
		return emit_operator_call(e, symbol.delegate_target, bound, left_place)
	}
	op := operator_token(symbol.operator)
	underlying := symbol.delegate_underlying
	simd := type_is_simd(e.c, underlying)
	if len(bound) == 1 {
		operand := emit_expr(e, bound[0])
		return simd ? emit_simd_unary_value(e, op, underlying, operand) : emit_unary_op(e, op, underlying, operand)
	}
	lhs := left_place != "" ? load_place(e, underlying, left_place) : emit_borrowed_operand(e, bound[0])
	rhs := emit_borrowed_operand(e, bound[1])
	if simd {
		return emit_simd_binary_values(e, op, underlying, lhs, underlying, rhs, underlying)
	}
	if op == .Plus && type_is_utf8_text(e.c, underlying) {
		return emit_text_concat_values(e, underlying, lhs, rhs)
	}
	#partial switch op {
	case .Eq_Eq, .Not_Eq, .Lt, .Lt_Eq, .Gt, .Gt_Eq:
		return emit_compare(e, op, underlying, lhs, rhs)
	}
	return emit_binary_op(e, op, underlying, underlying, lhs, rhs)
}

@(private)
call_builtin_kind :: proc(e: ^Emitter, v: ^Expr_Call) -> Builtin_Kind {
	#partial switch _ in v.operation {
	case Call_Builtin, Call_Atomic, Call_Allocation, Call_Sort_By, Call_Simd_Reduce:
		sym := symbol_of(e.c, v.resolution.symbol)
		return sym != nil && sym.kind == .Builtin ? sym.builtin : Builtin_Kind.None
	case:
		return .None
	}
}

// design.md "Allocation failure": the `try_` form returns the failure as a
// `Result`; the plain form applies the allocator's policy, which does not
// return, and produces the value.
@(private)
emit_alloc_outcome :: proc(e: ^Emitter, v: ^Expr_Call, as_type: Type_Id, failed, value, allocator: string) -> string {
	if v.operation.(Call_Allocation).fallible {
		return emit_alloc_result(e, as_type, failed, value)
	}
	fail, ok := new_label(e, "alloc.failed"), new_label(e, "alloc.ok")
	branch_if(e, failed, fail, ok)
	place_label(e, fail)
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_alloc_failed(ptr %s)", allocator)
	fmt.sbprintln(&e.b, "  unreachable")
	e.terminated = true
	place_label(e, ok)
	return value
}

// `make(T, counts..., allocator)` receives checker-bound operands in order.
@(private = "file")
emit_make_container :: proc(e: ^Emitter, v: ^Expr_Call, as_type: Type_Id) -> string {
	checked := v.operation.(Call_Allocation)
	is_map := type_is_map(e.c, checked.type)
	counts := is_map ? 1 : 2
	values := make([]string, counts)
	for index in 0 ..< counts {
		values[index] = v.bound[index] == nil ? "" : emit_expr(e, v.bound[index])
	}
	allocator := v.bound[counts] == nil ? emit_default_allocator(e) : emit_expr(e, v.bound[counts])

	header := alloca(e, CONTAINER_TYPE)
	fmt.sbprintfln(&e.b, "  store %s zeroinitializer, ptr %s", CONTAINER_TYPE, header)
	provider := gep_field(e, CONTAINER_TYPE, header, CONTAINER_ALLOC)
	fmt.sbprintfln(&e.b, "  store ptr %s, ptr %s", allocator, provider)

	// design.md: `cap` defaults to `len`, and a `len > cap` relationship is an
	// ordinary program fault rather than an allocation failure.
	length := values[0] == "" ? "0" : values[0]
	capacity := length
	if !is_map && values[1] != "" {
		capacity = values[1]
		bad := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp sgt i64 %s, %s", bad, length, capacity)
		panic_if(e, bad, "make.len_gt_cap", "a container's length cannot exceed its capacity")
	}
	negative := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp slt i64 %s, 0", negative, length)
	panic_if(e, negative, "make.negative", "a container's length cannot be negative")

	helper := is_map ? "loke_rt_v1_map_reserve" : "loke_rt_v1_dyn_reserve"
	status := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call i32 @%s(ptr %s, ptr %s, i64 %s)",
		status, helper, header, container_ops_global(e, checked.type), capacity,
	)
	failed := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i32 %s, 0", failed, status)
	fill_label, done_label := new_label(e, "make.fill"), new_label(e, "make.done")
	branch_if(e, failed, done_label, fill_label)

	// Dynamic-array zero values are all-zero bits.
	place_label(e, fill_label)
	if !is_map {
		element := container_element(e.c, checked.type)
		data := load(e, "ptr", header)
		bytes := temp(e)
		fmt.sbprintfln(&e.b, "  %s = mul i64 %s, %d", bytes, length, type_size(e.c, element))
		fmt.sbprintfln(&e.b, "  call void @llvm.memset.p0.i64(ptr %s, i8 0, i64 %s, i1 false)", data, bytes)
		count_slot := gep_field(e, CONTAINER_TYPE, header, CONTAINER_LEN)
		fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", length, count_slot)
	}
	branch(e, done_label)
	place_label(e, done_label)

	built := temp(e)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", built, CONTAINER_TYPE, header)
	return emit_alloc_outcome(e, v, as_type, failed, built, allocator)
}

// `unsafe.free`: releases an allocation sized by the pointer's element type.
@(private = "file")
emit_free :: proc(e: ^Emitter, v: ^Expr_Call) {
	pointer := emit_expr(e, v.bound[0])
	allocator := emit_allocator_operand(e, v, 1)
	info := underlying_info(e.c, expr_base(v.bound[0]).type)
	if info == nil || (info.kind != .Pointer && info.kind != .C_Pointer) {
		backend_fail(e, "`unsafe.free` did not receive an allocation pointer")
		return
	}
	emit_rt_free(e, allocator, pointer, type_size(e.c, info.element), type_align(e.c, info.element))
}

// design.md "Diverging procedures": the call never returns. In a value position
// the code after it still needs a block and an operand, neither ever reached.
@(private = "file")
emit_diverging_call :: proc(e: ^Emitter, v: ^Expr_Call, as_type: Type_Id) -> string {
	if is_builtin_call(e.c, v, .Panic) {
		emit_formatted_panic(e, v, 0, "explicit panic")
	} else if is_builtin_call(e.c, v, .Allocation_Failed) {
		// The error's size goes back into the runtime's note, so the report names
		// the refused request, and the allocator's policy decides.
		error := emit_expr(e, v.bound[0])
		allocator := emit_expr(e, v.bound[1])
		emit_restore_refusal(e, allocator, error)
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_alloc_failed(ptr %s)", allocator)
		fmt.sbprintln(&e.b, "  unreachable")
		e.terminated = true
	} else {
		emit_direct_call(e, v)
		fmt.sbprintln(&e.b, "  unreachable")
		e.terminated = true
	}
	if as_type == INVALID_TYPE || as_type == TYPE_VOID {
		return "0"
	}
	fmt.sbprintfln(&e.b, "unreachable.%d:", next_id(e))
	e.terminated = false
	return "undef"
}

@(private = "file")
emit_direct_call :: proc(e: ^Emitter, v: ^Expr_Call) -> string {
	callee_type := underlying_info(e.c, expr_base(v.callee).type)
	symbol := symbol_of(e.c, v.resolution.symbol)

	callee := ""
	if symbol != nil && symbol.kind == .Proc {
		callee = callee_name(e, v.resolution.symbol)
	} else {
		callee = emit_expr(e, v.callee)
	}

	return emit_bound_call(e, v.resolution.symbol, callee, callee_type, v.bound, v)
}

// A variadic pack is a read-only slice over compiler-owned stack storage.
@(private = "file")
Variadic_Pack :: struct {
	value:   string,
	cleanup: Deferred,
	// Set when a `try_` form's copy may be refused: an `i1` slot holding
	// whether one was, and the `Allocator_Error` slot holding why.
	refused: string,
	error:   string,
}

// design.md "Variadic parameters": the most a pack sized at run time may hold.
PACK_STACK_BYTES :: 256 * 1024

@(private = "file")
checked_variadic_total :: proc(e: ^Emitter, total, added: string) -> string {
	negative := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp slt i64 %s, 0", negative, added)
	panic_if(e, negative, "variadic.length", "invalid variadic spread length")
	sum := temp(e)
	fmt.sbprintfln(&e.b, "  %s = add i64 %s, %s", sum, total, added)
	overflow := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp ult i64 %s, %s", overflow, sum, total)
	panic_if(e, overflow, "variadic.size", "variadic argument pack is too large")
	return sum
}

// A lending pack holds a borrowed place or a spread's elements without cloning
// them, and its flags mark only the elements it owns; the callee clones the rest.
// A pack a container consumes copies through that container's `provider`, and
// for a `try_` form (`fallible`) a refused copy leaves its element unowned and
// is reported in the pack instead of applying the allocator's policy.
@(private = "file")
emit_variadic_pack :: proc(
	e: ^Emitter, v: ^Expr_Call, pack_type: Type_Id, lend := false, provider := "", fallible := false,
) -> Variadic_Pack {
	if v.variadic_forwards {
		return Variadic_Pack{value = emit_expr(e, v.bound[v.variadic_slot])}
	}
	if len(v.variadic_spreads) == 0 && len(v.variadic_elements) == 0 {
		return Variadic_Pack{value = "zeroinitializer"}
	}
	element := slice_element(e.c, pack_type)
	operands := emit_pack_operands(e, v, element, lend, provider, fallible)
	buffer, cleanup := operands.staging, operands.cleanup
	if len(v.variadic_spreads) == 0 {
		// Staging already has the pack's shape, so it is the pack.
		release_held(e, cleanup)
	} else {
		buffer, cleanup = emit_spread_pack(e, v, element, operands, lend)
		unwind_clear(e, operands.cleanup.slot)
		release_held(e, operands.cleanup)
	}
	return Variadic_Pack{
		value = emit_slice_value(e, pack_type, buffer, operands.total), cleanup = cleanup,
		refused = operands.refused, error = operands.error,
	}
}

// A pack's operands, evaluated in their written order.
@(private = "file")
Pack_Operands :: struct {
	// The static elements. A managed pack's `cleanup` flags those it owns, and
	// protects them while later operands are evaluated.
	staging: string,
	cleanup: Deferred,
	// Whether the pack owns each static element: a constant, or a refusable
	// copy's outcome.
	owns:    []string,
	spread_data, spread_len: []string,
	total:   string,
	refused: string,
	error:   string,
}

@(private = "file")
emit_pack_operands :: proc(
	e: ^Emitter, v: ^Expr_Call, element: Type_Id, lend: bool, provider: string, fallible: bool,
) -> Pack_Operands {
	element_llvm := llvm_type(e, element)
	managed := emit_lifecycle(e, element).managed
	static_count := len(v.variadic_elements)
	out := Pack_Operands {
		owns        = make([]string, static_count),
		spread_data = make([]string, len(v.variadic_spreads)),
		spread_len  = make([]string, len(v.variadic_spreads)),
		total       = fmt.aprintf("%d", static_count),
	}
	if static_count > 0 {
		out.staging = alloca(e, fmt.aprintf("[%d x %s]", static_count, element_llvm))
	}
	if managed && static_count > 0 {
		flags, count := alloca(e, fmt.aprintf("[%d x i1]", static_count)), alloca(e, "i64")
		fmt.sbprintfln(&e.b, "  call void @llvm.memset.p0.i64(ptr %s, i8 0, i64 %d, i1 false)", flags, static_count)
		fmt.sbprintfln(&e.b, "  store i64 %d, ptr %s", static_count, count)
		out.cleanup = register_array_cleanup(e, element, out.staging, flags, count)
		// An exit from a later operand drops the elements staged so far.
		append(&e.held, out.cleanup)
	}
	next_element, next_spread := 0, 0
	for is_spread in v.variadic_order {
		if is_spread {
			expr := v.variadic_spreads[next_spread]
			spread := emit_expr(e, expr)
			storage := llvm_type(e, expr_base(expr).type)
			out.spread_data[next_spread] = extract(e, storage, spread, SLICE_DATA)
			out.spread_len[next_spread] = extract(e, storage, spread, SLICE_LEN)
			out.total = checked_variadic_total(e, out.total, out.spread_len[next_spread])
			next_spread += 1
			continue
		}
		expr := v.variadic_elements[next_element]
		// Temporaries transfer into staging; borrowed owners are cloned, or lent.
		borrowed := managed && expression_is_borrowed_place(expr)
		out.owns[next_element] = borrowed && lend ? "false" : "true"
		copies := borrowed && !lend
		value := ""
		if from := copied_type(expr, element); copies && fallible && from != element && emit_lifecycle(e, from).clone_fallible {
			if out.refused == "" {
				out.refused, out.error = alloca(e, "i1"), alloca(e, llvm_type(e, TYPE_ALLOCATOR_ERROR))
				fmt.sbprintfln(&e.b, "  store i1 false, ptr %s", out.refused)
			}
			value, out.owns[next_element] = emit_refusable_pack_copy(e, expr, from, element, provider, out.refused, out.error)
		} else {
			value = emit_copied_expr(e, expr, element, copies, provider)
		}
		position := fmt.aprintf("%d", next_element)
		store(e, element, value, gep_at(e, element_llvm, out.staging, position))
		if managed {
			fmt.sbprintfln(&e.b, "  store i1 %s, ptr %s", out.owns[next_element], gep_at(e, "i1", out.cleanup.array_flags, position))
		}
		next_element += 1
	}
	return out
}

// The pack of a call with a spread, which only now knows its length: every
// operand in written order, in storage for exactly that many elements.
@(private = "file")
emit_spread_pack :: proc(
	e: ^Emitter, v: ^Expr_Call, element: Type_Id, operands: Pack_Operands, lend: bool,
) -> (buffer: string, cleanup: Deferred) {
	element_llvm := llvm_type(e, element)
	managed := emit_lifecycle(e, element).managed
	size := type_size(e.c, element)
	limit := size == 0 ? u64(max(i64)) : PACK_STACK_BYTES / size
	too_large := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp ugt i64 %s, %d", too_large, operands.total, limit)
	panic_if(e, too_large, "variadic.size", "variadic argument pack is too large")
	save_stack_for_expression(e)
	buffer = temp(e)
	alloca_count(e, buffer, element_llvm, operands.total)
	flags := ""
	if managed {
		flags = temp(e)
		alloca_count(e, flags, "i1", operands.total)
		fmt.sbprintfln(&e.b, "  call void @llvm.memset.p0.i64(ptr %s, i8 0, i64 %s, i1 false)", flags, operands.total)
		count := alloca(e, "i64")
		fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", operands.total, count)
		cleanup = register_array_cleanup(e, element, buffer, flags, count)
	}

	cursor := alloca(e, "i64")
	fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", cursor)
	next_element, next_spread := 0, 0
	for is_spread in v.variadic_order {
		position := load(e, "i64", cursor)
		advance := "1"
		if is_spread {
			data := operands.spread_data[next_spread]
			advance = operands.spread_len[next_spread]
			next_spread += 1
			if lend || !managed {
				// Bitwise, with any flags left clear.
				bytes := temp(e)
				fmt.sbprintfln(&e.b, "  %s = mul i64 %s, %d", bytes, advance, size)
				fmt.sbprintfln(
					&e.b, "  call void @llvm.memcpy.p0.p0.i64(ptr %s, ptr %s, i64 %s, i1 false)",
					gep_at(e, element_llvm, buffer, position), data, bytes,
				)
			} else {
				emit_pack_clone_spread(e, element, data, advance, buffer, flags, position)
			}
		} else {
			staged := fmt.aprintf("%d", next_element)
			loaded := load_place(e, element, gep_at(e, element_llvm, operands.staging, staged))
			store(e, element, loaded, gep_at(e, element_llvm, buffer, position))
			if managed {
				fmt.sbprintfln(&e.b, "  store i1 %s, ptr %s", operands.owns[next_element], gep_at(e, "i1", flags, position))
				fmt.sbprintfln(&e.b, "  store i1 false, ptr %s", gep_at(e, "i1", operands.cleanup.array_flags, staged))
			}
			next_element += 1
		}
		advanced := temp(e)
		fmt.sbprintfln(&e.b, "  %s = add i64 %s, %s", advanced, position, advance)
		fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", advanced, cursor)
	}
	return buffer, cleanup
}

// Clones a spread's elements into the pack from `start`, flagging each as it is
// made, so a clone that panics drops only those already there.
@(private = "file")
emit_pack_clone_spread :: proc(e: ^Emitter, element: Type_Id, data, length, buffer, flags, start: string) {
	element_llvm := llvm_type(e, element)
	index_slot := alloca(e, "i64")
	fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", index_slot)
	head, body, done := new_label(e, "vararg.copy.head"), new_label(e, "vararg.copy.body"), new_label(e, "vararg.copy.done")
	branch(e, head)
	place_label(e, head)
	index := load(e, "i64", index_slot)
	more := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp ult i64 %s, %s", more, index, length)
	branch_if(e, more, body, done)
	place_label(e, body)
	cloned := emit_clone_value(e, element, load_place(e, element, gep_at(e, element_llvm, data, index)))
	position, next_index := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = add i64 %s, %s", position, start, index)
	store(e, element, cloned, gep_at(e, element_llvm, buffer, position))
	fmt.sbprintfln(&e.b, "  store i1 true, ptr %s", gep_at(e, "i1", flags, position))
	fmt.sbprintfln(&e.b, "  %s = add i64 %s, 1", next_index, index)
	fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", next_index, index_slot)
	branch(e, head)
	place_label(e, done)
}

// design.md "Widening by label" and "Container insertion": a `try_append` copies
// a widened place at its own type, and a refused copy leaves an unowned zero in
// the pack and records the error, so the call can drop the pack and return it.
// Returns the element and whether the pack owns it.
@(private = "file")
emit_refusable_pack_copy :: proc(
	e: ^Emitter, expr: Expr, from, element: Type_Id, provider, refused, error_slot: string,
) -> (value: string, owned: string) {
	source := emit_expr_at(e, expr, from)
	cloned, failed, error := emit_clone_call(e, emit_lifecycle(e, from).try_clone, from, source, provider)
	slot := temporary_slot(e, element)
	refused_label, copied_label := new_label(e, "vararg.refused"), new_label(e, "vararg.copied")
	done := new_label(e, "vararg.done")
	branch_if(e, failed, refused_label, copied_label)
	place_label(e, refused_label)
	fmt.sbprintfln(&e.b, "  store i1 true, ptr %s", refused)
	store(e, TYPE_ALLOCATOR_ERROR, error, error_slot)
	store(e, element, "zeroinitializer", slot)
	branch(e, done)
	place_label(e, copied_label)
	store(e, element, emit_union_widen(e, cloned, from, element), slot)
	branch(e, done)
	place_label(e, done)
	owned = temp(e)
	fmt.sbprintfln(&e.b, "  %s = xor i1 %s, true", owned, failed)
	return load_temporary(e, element, slot), owned
}

// The container insertion slot whose element the callee consumes, or -1.
// design.md "Container insertion": a move-only element is always handed over,
// and so is an owned one of any type, through the member's consuming body.
@(private = "file")
consumed_element_slot :: proc(e: ^Emitter, symbol: ^Symbol, call_node: ^Expr_Call) -> (slot: int, consuming_body: bool) {
	if symbol == nil || len(symbol.params) == 0 {
		return -1, false
	}
	#partial switch symbol.container_op {
	case .Append:
		slot = 1
	case .Insert, .Map_Find_Or_Insert, .Map_Try_Insert:
		slot = 2
	case:
		return -1, false
	}
	lifecycle := emit_lifecycle(e, container_element(e.c, symbol.params[0]))
	// A move-only element is handed over by every form; a failed `try_` form
	// drops it.
	if lifecycle.clone_disabled {
		return slot, false
	}
	// A copyable element goes to a `try_` form by copy, so a failure leaves the
	// argument with the caller. A built pack still goes to the lending body,
	// which copies each element itself and so reports a failed copy; the caller
	// keeps and drops the pack.
	if container_member_is_try(e.c, symbol) {
		if symbol.container_op != .Append || !lifecycle.managed || call_node == nil ||
		   !call_node.is_variadic || call_node.variadic_forwards {
			return -1, false
		}
		return -1, true
	}
	if !lifecycle.managed || call_node == nil || slot >= len(call_node.bound) {
		return -1, false
	}
	// A built pack owns every element, since a borrowed place or a spread is
	// cloned into it; a lone forwarded spread only lends the caller's slice.
	owned := symbol.container_op == .Append \
		? call_node.is_variadic && !call_node.variadic_forwards \
		: !expression_is_borrowed_place(call_node.bound[slot])
	if !owned {
		return -1, false
	}
	return slot, true
}

consuming_op_name :: proc(e: ^Emitter, symbol_id: Symbol_Id) -> string {
	return fmt.aprintf("%s.consume", symbol_name(e, symbol_id))
}

// A call's parameter bindings, which its default arguments read. A default reads
// the parameters already bound to its left; a written argument sees only the
// bindings of the default it is written in, if any.
@(private)
Default_Scope :: struct {
	callee:       ^Symbol,
	has_defaults: bool,
	outer, own:   map[Symbol_Id]Bound_Parameter,
}

// A parameter's operand, which is its address if it passes by pointer.
@(private)
Bound_Parameter :: struct {
	operand:    string,
	by_address: bool,
}

@(private)
begin_default_scope :: proc(e: ^Emitter, callee: ^Symbol) -> Default_Scope {
	scope := Default_Scope{callee = callee, outer = e.param_values}
	if callee != nil {
		for value in callee.param_defaults {
			scope.has_defaults ||= value != nil
		}
	}
	return scope
}

// Selects the bindings that parameter `index`'s `argument` is evaluated under.
@(private)
enter_default_scope :: proc(e: ^Emitter, scope: ^Default_Scope, index: int, argument: Expr) {
	is_default := scope.has_defaults && argument != nil && index < len(scope.callee.param_defaults) &&
		argument == scope.callee.param_defaults[index]
	e.param_values = is_default ? scope.own : scope.outer
}

@(private)
bind_default_scope :: proc(e: ^Emitter, scope: ^Default_Scope, index: int, operand: string) {
	if !scope.has_defaults || index >= len(scope.callee.param_symbols) {
		return
	}
	if parameter := scope.callee.param_symbols[index]; parameter != INVALID_SYMBOL {
		by_address := param_mode_is_pointer(symbol_param_mode(e.c, scope.callee, index))
		scope.own[parameter] = Bound_Parameter{operand, by_address}
	}
}

@(private)
end_default_scope :: proc(e: ^Emitter, scope: ^Default_Scope) {
	delete(scope.own)
	e.param_values = scope.outer
}

// A call's bound operands, and what the caller still owes once it is made.
@(private = "file")
Bound_Operands :: struct {
	operands:          []string,
	owned_flags:       string,
	pack_cleanup:      Deferred,
	argument_cleanups: [dynamic]Deferred,
	inserted:          Insertion_Copy,
	refused_pack:      Variadic_Pack,
}

// Binds operands left to right. `consumed` and `consuming_body` are
// `consumed_element_slot`'s answer.
@(private = "file")
emit_call_operands :: proc(
	e: ^Emitter, symbol: ^Symbol, callee_type: ^Type_Info, bound: []Expr, call_node: ^Expr_Call,
	receiver: string, consumed: int, consuming_body: bool,
) -> Bound_Operands {
	scope := begin_default_scope(e, symbol)
	defer end_default_scope(e, &scope)

	out := Bound_Operands{operands = make([]string, len(bound)), }
	operands := out.operands
	pack := -1
	if call_node != nil && call_node.is_variadic {
		pack = call_node.variadic_slot
	}
	handoff_cleanups := make([dynamic]Deferred)
	defer delete(handoff_cleanups)
	result_borrows := callee_type.result != INVALID_TYPE && type_carries_borrow(e.c, callee_type.result).any
	for step in 0 ..< len(bound) {
		index := call_node != nil ? call_slot_at(call_node, step) : step
		argument := bound[index]
		enter_default_scope(e, &scope, index, argument)
		if index == 0 && receiver != "" {
			operands[0] = receiver
			bind_default_scope(e, &scope, 0, receiver)
			continue
		}
		if index == pack {
			// A consuming `append` clones what the pack lends, so a failed clone is its
			// to report.
			lends := consuming_body && symbol.container_op == .Append
			provider, fallible := "", false
			if consumed == pack && symbol.container_op == .Append && operands[0] != "" {
				provider = load(e, "ptr", gep_field(e, CONTAINER_TYPE, operands[0], CONTAINER_ALLOC))
				fallible = container_member_is_try(e.c, symbol)
			}
			packed := emit_variadic_pack(
				e, call_node, callee_type.parameters[index], lend = lends, provider = provider, fallible = fallible,
			)
			if packed.refused != "" {
				out.refused_pack = packed
			}
			if lends {
				// Nothing owned crosses into a `try_` form: it copies every element.
				out.owned_flags = consumed == pack && packed.cleanup.kind == .Array ? packed.cleanup.array_flags : "null"
			}
			operands[index] = packed.value
			out.pack_cleanup = packed.cleanup
			continue
		}
		mode := index < len(callee_type.param_modes) ? callee_type.param_modes[index] : Param_Mode.Value
		if index == 0 && param_mode_is_pointer(mode) && symbol != nil && .Lends_Receiver in CONTAINER_OP_EFFECTS[symbol.container_op] {
			// standard-library.md "Splitting a mutable slice": the receiver is evaluated
			// before the index, which may rebind it, and the reborrow is taken of
			// that value, so the callee reads a snapshot rather than the place.
			operands[0] = temporary_slot(e, callee_type.parameters[0])
			store(e, callee_type.parameters[0], emit_expr(e, argument), operands[0])
		} else if param_mode_is_pointer(mode) {
			operands[index] = emit_address(e, argument)
			if _, composite := argument.(^Expr_Composite); mode == .Borrow && composite {
				// A directly borrowed composite belongs to the complete expression.
				hold_addressed_temporary(e, argument, callee_type.parameters[index], operands[index])
			}
		} else if index == consumed && expression_is_borrowed_place(argument) && index < len(callee_type.parameters) {
			out.inserted = emit_insertion_copy(e, argument, callee_type.parameters[index], operands[0], container_member_is_try(e.c, symbol))
			operands[index] = out.inserted.value
		} else {
			operands[index] = emit_expr(e, argument)
		}
		// The caller cleans temporaries passed through non-owning value parameters.
		if mode == .Move && index < len(callee_type.parameters) {
			// Keep a move handoff live until the call begins.
			entry := hold_temporary_value(e, callee_type.parameters[index], operands[index])
			if entry.place != "" { append(&handoff_cleanups, entry) }
		} else if mode == .Value && index < len(callee_type.parameters) && index != consumed &&
		   !expression_is_borrowed_place(argument) {
			parameter := callee_type.parameters[index]
			if !result_borrows {
				entry := hold_temporary_value(e, parameter, operands[index])
				if entry.place != "" { append(&out.argument_cleanups, entry) }
			} else if emit_lifecycle(e, parameter).managed {
				// The result may borrow the argument, as `arena.allocator()` borrows
				// its provider, so the temporary lives through the complete
				// expression (design.md "Temporaries and procedure boundaries").
				held := alloca(e, llvm_type(e, parameter))
				store(e, parameter, operands[index], held)
				register_temporary_place(e, parameter, held)
			}
		}
		bind_default_scope(e, &scope, index, operands[index])
	}

	// A consumed pack transfers to the callee.
	if consumed >= 0 && consumed == pack && out.pack_cleanup.kind == .Array {
		unwind_clear(e, out.pack_cleanup.slot)
		out.pack_cleanup = Deferred{}
	}
	// Ownership now crosses the call boundary.
	for entry in handoff_cleanups {
		finish_temporary_drop(e, entry)
	}
	return out
}

// A `try_` form whose copy was refused returns that failure, and the call is not
// made; a refused pack first drops what it owns. With a copy that may be refused,
// returns the label both paths join at and the slot that holds the result there.
@(private = "file")
emit_refusal_branch :: proc(
	e: ^Emitter, call: ^Bound_Operands, callee_type: ^Type_Info, sret_slot: string,
) -> (joined, joined_slot: string) {
	failed, error := call.inserted.failed, call.inserted.error
	if call.refused_pack.refused != "" {
		failed = load(e, "i1", call.refused_pack.refused)
		error = load(e, llvm_type(e, TYPE_ALLOCATOR_ERROR), call.refused_pack.error)
	}
	if failed == "" {
		return "", ""
	}
	refused, attempted := new_label(e, "insert.refused"), new_label(e, "insert.copied")
	joined = new_label(e, "insert.joined")
	joined_slot = sret_slot != "" ? sret_slot : temporary_slot(e, callee_type.result)
	branch_if(e, failed, refused, attempted)
	place_label(e, refused)
	if cleanup := call.refused_pack.cleanup; cleanup.kind == .Array {
		emit_drop_staged_array(e, cleanup)
	}
	store(e, callee_type.result, emit_alloc_result(e, callee_type.result, "true", error = error), joined_slot)
	branch(e, joined)
	place_label(e, attempted)
	return joined, joined_slot
}

// The call instruction, which returns its result operand, `sret_slot` if it has
// one, or nothing.
@(private = "file")
emit_call_instruction :: proc(
	e: ^Emitter, callee: string, callee_type: ^Type_Info, call: ^Bound_Operands, consumed: int, sret_slot, receiver_type: string,
) -> string {
	operands := call.operands
	if call.inserted.from != INVALID_TYPE {
		operands[consumed] = emit_union_widen(e, operands[consumed], call.inserted.from, callee_type.parameters[consumed])
	}
	// A large argument is passed as the address of a copy only the callee reads,
	// and a large constant has no address yet.
	for &operand, index in operands {
		mode := index < len(callee_type.param_modes) ? callee_type.param_modes[index] : Param_Mode.Value
		if !param_mode_is_pointer(mode) && is_large_value(e, callee_type.parameters[index]) && operand[0] != '%' {
			spill := temporary_slot(e, callee_type.parameters[index])
			store(e, callee_type.parameters[index], operand, spill)
			operand = spill
		}
	}
	out := sret_slot
	if sret_slot != "" {
		fmt.sbprintf(&e.b, "  call void %s(ptr %s%s", callee, sret_slot, len(operands) > 0 ? ", " : "")
	} else if callee_type.result != INVALID_TYPE {
		out = temp(e)
		fmt.sbprintf(&e.b, "  %s = call %s %s(", out, llvm_result_type(e, callee_type.result, callee_type.result_inout), callee)
	} else {
		fmt.sbprintf(&e.b, "  call void %s(", callee)
	}
	for operand, index in operands {
		if index > 0 {
			fmt.sbprint(&e.b, ", ")
		}
		mode := index < len(callee_type.param_modes) ? callee_type.param_modes[index] : Param_Mode.Value
		type := param_llvm(e, callee_type.parameters[index], mode)
		if index == 0 && receiver_type != "" {
			type = receiver_type
		}
		fmt.sbprintf(&e.b, "%s %s", type, operand)
	}
	if call.owned_flags != "" {
		fmt.sbprintf(&e.b, ", ptr %s", call.owned_flags)
	}
	fmt.sbprintln(&e.b, ")")
	return out
}

// Drops the pack and the temporary arguments, the result held meanwhile.
@(private = "file")
emit_after_call :: proc(e: ^Emitter, call: ^Bound_Operands, callee_type: ^Type_Info, result: string) {
	pack := call.pack_cleanup
	guard := Deferred{}
	if callee_type.result != INVALID_TYPE && !callee_type.result_inout &&
	   (pack.kind == .Array || len(call.argument_cleanups) > 0) {
		guard = hold_temporary_value(e, callee_type.result, result)
	}
	if pack.kind == .Array {
		emit_drop_staged_array(e, pack)
		unwind_clear(e, pack.slot)
	}
	#reverse for entry in call.argument_cleanups {
		drop_temporary_value(e, entry)
	}
	if guard.place != "" { finish_temporary_drop(e, guard) }
}

// Binds operands left to right and emits one call. A non-empty `receiver` is
// slot 0's already-evaluated operand, typed `receiver_type` when that is set.
// Returns the result operand, or "0" for none.
@(private)
emit_bound_call :: proc(
	e: ^Emitter,
	symbol_id: Symbol_Id,
	callee: string,
	callee_type: ^Type_Info,
	bound: []Expr,
	call_node: ^Expr_Call = nil,
	receiver := "",
	receiver_type := "",
) -> string {
	if callee_type == nil {
		return "0"
	}
	symbol := symbol_of(e.c, symbol_id)
	callee := callee
	consumed, consuming_body := consumed_element_slot(e, symbol, call_node)
	if consuming_body {
		e.consuming_ops[symbol_id] = true
		callee = consuming_op_name(e, symbol_id)
	}
	call := emit_call_operands(e, symbol, callee_type, bound, call_node, receiver, consumed, consuming_body)
	defer delete(call.argument_cleanups)

	if convention_is_foreign(callee_type.convention) {
		return emit_foreign_call(e, callee, callee_type, call.operands, symbol, bound)
	}

	sret := returns_sret(e, callee_type.result, callee_type.result_inout)
	sret_slot := sret ? temporary_slot(e, callee_type.result) : ""
	joined, joined_slot := emit_refusal_branch(e, &call, callee_type, sret_slot)
	result := emit_call_instruction(e, callee, callee_type, &call, consumed, sret_slot, receiver_type)
	if joined != "" {
		if !sret {
			store(e, callee_type.result, result, joined_slot)
		}
		branch(e, joined)
		place_label(e, joined)
		if !sret {
			result = load_temporary(e, callee_type.result, joined_slot)
		}
	}
	emit_after_call(e, &call, callee_type, result)
	return callee_type.result != INVALID_TYPE ? result : "0"
}

// design.md "Widening by label" and "Container insertion": a borrowed smaller
// union inserted as a move-only element is copied at its own type through the
// container's provider, and the copy is handed over; the caller remaps it once
// the copy is known to have succeeded. A `try_` form reports a refused copy as
// its own failure, so the borrowed place is left as it was.
@(private = "file")
Insertion_Copy :: struct {
	value:  string,
	from:   Type_Id, // the smaller union `value` still has, or INVALID_TYPE
	failed: string,  // set when a `try_` copy may be refused
	error:  string,
}

@(private = "file")
emit_insertion_copy :: proc(e: ^Emitter, argument: Expr, element: Type_Id, container: string, fallible: bool) -> Insertion_Copy {
	from := copied_type(argument, element)
	value := emit_expr_at(e, argument, from)
	operations := emit_lifecycle(e, from)
	if from == element || !operations.managed {
		return Insertion_Copy{value = from == element ? value : emit_union_widen(e, value, from, element)}
	}
	provider := load(e, "ptr", gep_field(e, CONTAINER_TYPE, container, CONTAINER_ALLOC))
	if fallible && operations.clone_fallible {
		cloned, failed, error := emit_clone_call(e, operations.try_clone, from, value, provider)
		return Insertion_Copy{value = cloned, from = from, failed = failed, error = error}
	}
	return Insertion_Copy{value = emit_clone_value(e, from, value, provider), from = from}
}

@(private = "file")
emit_conversion :: proc(e: ^Emitter, v: ^Expr_Call, as_type: Type_Id) -> string {
	source := expr_base(v.bound[0]).type
	value := emit_expr(e, v.bound[0])
	if v.operation.(Call_Conversion).clones {
		value = emit_clone_value(e, source, value)
	}
	return emit_value_conversion(e, value, source, as_type, checked = true)
}

// The types a conversion's instruction reads: a vector pair's lane types, or the
// operands themselves.
@(private = "file")
conversion_lanes :: proc(c: ^Compiler, from, to: Type_Id) -> (from_lane, to_lane: Type_Id, lanes: bool) {
	if type_is_simd(c, from) && type_is_simd(c, to) {
		return type_underlying(c, type_of(c, from).element), type_underlying(c, type_of(c, to).element), true
	}
	return from, to, false
}

// A built-in conversion of an evaluated value. `checked` is `T(v)`'s promise
// that an integer keeps its value; `math.wrap` keeps the low bits instead.
@(private = "file")
emit_value_conversion :: proc(e: ^Emitter, value: string, source, target: Type_Id, checked: bool) -> string {
	// design.md "Widening by label": the tag is remapped even where two unions
	// share one storage type.
	if union_widens_to(e.c, source, target) {
		return emit_union_widen(e, value, source, target)
	}
	from := type_underlying(e.c, source)
	to := type_underlying(e.c, target)
	if checked {
		guard_integer_conversion(e, value, from, to)
		guard_null_reference(e, value, from, to)
	}
	if llvm_type(e, from) == llvm_type(e, to) {
		return value
	}

	// SIMD conversions use the same instruction over lane types.
	from_lane, to_lane, _ := conversion_lanes(e.c, from, to)
	from_float := type_is_float(e.c, from_lane)
	to_float := type_is_float(e.c, to_lane)
	from_bits, to_bits := type_bits(e.c, from_lane), type_bits(e.c, to_lane)
	from_signed := type_signed(e.c, from_lane)
	to_signed := type_signed(e.c, to_lane)

	operation := ""
	switch {
	case from_float && to_float:
		operation = from_bits > to_bits ? "fptrunc" : "fpext"
	case from_float:
		operation = to_signed ? "fptosi" : "fptoui"
		guard_float_to_int(e, value, from, from_lane, to_lane)
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

// design.md "Type conversion": an integer converts only to a type that holds its
// value, checked in the source type against the destination's bounds. A vector
// is checked lane-wise and, as a panic is not lane-wise, fails as a whole.
@(private = "file")
guard_integer_conversion :: proc(e: ^Emitter, value: string, from, to: Type_Id) {
	from_lane, to_lane, lanes := conversion_lanes(e.c, from, to)
	info := type_of(e.c, from)
	integral :: proc(c: ^Compiler, type: Type_Id) -> bool {
		return type_is_integer(c, type) || type_is_rune(c, type) || underlying_kind(c, type) == .Enum
	}
	if !integral(e.c, from_lane) || !integral(e.c, to_lane) {
		return
	}
	from_bits, to_bits := type_bits(e.c, from_lane), type_bits(e.c, to_lane)
	from_signed := type_signed(e.c, from_lane)
	to_signed := type_signed(e.c, to_lane)
	// Only a bound the source can pass needs a test.
	to_value_bits := to_bits - (to_signed ? 1 : 0)
	test_high := to_value_bits < from_bits - (from_signed ? 1 : 0)
	test_low := from_signed && (!to_signed || to_bits < from_bits)
	if !test_high && !test_low {
		return
	}
	llvm := llvm_type(e, from)
	predicate := lanes ? fmt.aprintf("<%d x i1>", info.count) : "i1"
	bound :: proc(e: ^Emitter, info: ^Type_Info, lanes: bool, value: Big_Int) -> string {
		text := bi_text(e.c, value)
		return lanes ? simd_repeated(e, info, text) : text
	}
	bad := ""
	if test_high {
		to_max := bi_sub(e.c, bi_pow2(e.c, to_value_bits), bi_from_i64(e.c, 1))
		bad = temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = icmp %s %s %s, %s", bad, from_signed ? "sgt" : "ugt", llvm, value, bound(e, info, lanes, to_max),
		)
	}
	if test_low {
		to_min := to_signed ? bi_neg(e.c, bi_pow2(e.c, to_bits - 1)) : bi_zero(e.c)
		under := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp slt %s %s, %s", under, llvm, value, bound(e, info, lanes, to_min))
		if bad == "" {
			bad = under
		} else {
			joined := temp(e)
			fmt.sbprintfln(&e.b, "  %s = or %s %s, %s", joined, predicate, bad, under)
			bad = joined
		}
	}
	if lanes {
		bad = simd_any_lane(e, info, bad)
	}
	panic_if(e, bad, "cast.int", "an integer outside the destination type's range; `math.wrap` keeps the low bits")
}

// design.md "The `unsafe` package": an unchecked address becomes a reference
// only if it is not null, so no reference is ever null once checked code holds
// it and nothing that uses one tests it again.
@(private)
guard_null_reference :: proc(e: ^Emitter, value: string, from, to: Type_Id) {
	#partial switch underlying_kind(e.c, from) {
	case .Raw_Pointer, .C_Pointer:
	case:
		return
	}
	#partial switch underlying_kind(e.c, to) {
	case .Pointer, .CString_View:
	case:
		return
	}
	is_null := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", is_null, value)
	panic_if(e, is_null, "cast.null", "a null address converted to a reference")
}

// Guard LLVM float-to-integer casts from poison on invalid inputs.
@(private = "file")
guard_float_to_int :: proc(e: ^Emitter, value: string, from, from_lane, to_lane: Type_Id) {
	width := u16(type_bits(e.c, from_lane))
	signed := type_signed(e.c, to_lane)
	magnitude := int(type_bits(e.c, to_lane)) - (signed ? 1 : 0)
	low_value := signed ? -power_of_two(magnitude) : 0
	high_value := power_of_two(magnitude)

	// A destination wider than the source's exponent range rounds its bound to an
	// infinity. Every finite value is then in range and only the infinity itself
	// is not, so an equal operand has to fail rather than pass.
	below := float_from_pattern(float_pattern(low_value, width), width) == low_value ? "ult" : "ule"
	low := llvm_float(float_pattern(low_value, width), width)
	high := llvm_float(float_pattern(high_value, width), width)

	info := underlying_info(e.c, from)
	lanes := type_is_simd(e.c, from)
	if lanes {
		low, high = simd_repeated(e, info, low), simd_repeated(e, info, high)
	}
	llvm := llvm_type(e, from)
	under, over, bad := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = fcmp %s %s %s, %s", under, below, llvm, value, low)
	fmt.sbprintfln(&e.b, "  %s = fcmp uge %s %s, %s", over, llvm, value, high)
	predicate := lanes ? fmt.aprintf("<%d x i1>", info.count) : "i1"
	fmt.sbprintfln(&e.b, "  %s = or %s %s, %s", bad, predicate, under, over)
	// A panic is not lane-wise, so one invalid lane faults the whole conversion.
	if lanes {
		bad = simd_any_lane(e, info, bad)
	}
	panic_if(e, bad, "cast.range", "a float outside the destination integer type's range")
}

// `U.name(payload)`.
@(private = "file")
emit_union_construct :: proc(e: ^Emitter, v: ^Expr_Call, operation: Call_Union_Construct, as_type: Type_Id) -> string {
	payload := emit_copied_expr(e, v.bound[0], expr_base(v.bound[0]).type, operation.clone)
	return emit_union_value(e, as_type, operation.index, payload)
}

// `u.as(.name)` borrows `u`: the payload is cloned only once the tag matched,
// and the option is written only on that path.
@(private = "file")
emit_union_as :: proc(e: ^Emitter, v: ^Expr_Call, index: int, as_type: Type_Id) -> string {
	subject := type_underlying(e.c, expr_base(v.bound[0]).type)
	value := emit_borrowed_operand(e, v.bound[0])
	matched := emit_union_tag_is(e, subject, value, index)

	slot := alloca(e, llvm_type(e, as_type))
	store(e, as_type, emit_union_value(e, as_type, union_index_of(e.c, as_type, "none"), ""), slot)
	then_label, done_label := new_label(e, "unionas.match"), new_label(e, "unionas.done")
	branch_if(e, matched, then_label, done_label)
	place_label(e, then_label)
	payload_type := option_payload(e.c, as_type)
	payload := "zeroinitializer"
	if union_variant_payload(e.c, subject, index) != TYPE_VOID {
		payload = emit_union_payload(e, subject, payload_type, emit_union_spill(e, subject, value))
		if emit_lifecycle(e, payload_type).managed {
			payload = emit_clone_value(e, payload_type, payload)
		}
	}
	store(e, as_type, emit_option_some(e, as_type, payload), slot)
	branch(e, done_label)
	place_label(e, done_label)
	return load_place(e, as_type, slot)
}

// ------------------------------------------- the Loke calling convention --

// design.md: a procedure returns at most one value. An `inout` result is a
// place, so it travels as its address. A large result is written through a
// leading `ptr %sret` into the caller's storage.
@(private)
llvm_result_type :: proc(e: ^Emitter, result: Type_Id, inout := false) -> string {
	if result == INVALID_TYPE || !inout && is_large_value(e, result) {
		return "void"
	}
	return inout ? "ptr" : llvm_type(e, result)
}

@(private)
returns_sret :: proc(e: ^Emitter, result: Type_Id, inout: bool) -> bool {
	return !inout && is_large_value(e, result)
}

// `ptr %sret, ` ahead of a procedure's own parameters when its result is
// large; the procedure then returns with `emit_ret`.
@(private)
sret_param :: proc(e: ^Emitter, result: Type_Id, inout := false) -> string {
	if !returns_sret(e, result, inout) {
		return ""
	}
	e.abi_sret = "%sret"
	return "ptr %sret, "
}

@(private)
emit_ret :: proc(e: ^Emitter, result: Type_Id, value: string) {
	emit_unwind_pop(e)
	e.terminated = true
	if returns_sret(e, result, false) {
		store(e, result, value, "%sret")
		fmt.sbprintln(&e.b, "  ret void")
		return
	}
	fmt.sbprintfln(&e.b, "  ret %s %s", llvm_type(e, result), value)
}

// Calls `callee` with the written `arguments` and returns its result, which a
// large result receives through storage passed ahead of them.
@(private)
emit_call_result :: proc(e: ^Emitter, result: Type_Id, callee, arguments: string) -> string {
	if returns_sret(e, result, false) {
		out := temporary_slot(e, result)
		fmt.sbprintfln(&e.b, "  call void %s(ptr %s%s%s)", callee, out, arguments == "" ? "" : ", ", arguments)
		return out
	}
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = call %s %s(%s)", out, llvm_type(e, result), callee, arguments)
	return out
}

// A pointer-mode parameter, or a large value, travels as an address.
@(private)
param_llvm :: proc(e: ^Emitter, type: Type_Id, mode: Param_Mode) -> string {
	return param_mode_is_pointer(mode) || is_large_value(e, type) ? "ptr" : llvm_type(e, type)
}

// design.md "Types with no zero value": a non-null type held as one address,
// and the address a pointer-mode or large parameter arrives at, is never null.
@(private)
param_nonnull :: proc(e: ^Emitter, type: Type_Id, mode: Param_Mode) -> string {
	if param_mode_is_pointer(mode) || is_large_value(e, type) {
		return " nonnull"
	}
	#partial switch underlying_kind(e.c, type) {
	case .Pointer, .Box, .Proc, .CString_View:
		return " nonnull"
	}
	return ""
}

@(private)
result_inout_of :: proc(e: ^Emitter, proc_type: Type_Id) -> bool {
	info := type_of(e.c, proc_type)
	return info != nil && info.result_inout
}

// The LLVM type of one parameter of a compiler-synthesized member. design.md
// "Receiver forms": a `self: ^` receiver arrives as a pointer to the caller's
// storage, exactly as an `inout` one does.
@(private)
synth_param_llvm :: proc(e: ^Emitter, symbol: ^Symbol, index: int) -> string {
	return param_llvm(e, symbol.params[index], symbol_param_mode(e.c, symbol, index))
}

// The receiver of a synthesized member as a *value*. The bodies below read
// their receiver's words with `extractvalue`, so one that arrived as a pointer
// is loaded once here rather than every body learning both spellings.
@(private)
synth_receiver_value :: proc(e: ^Emitter, symbol: ^Symbol) -> string {
	if !param_mode_is_pointer(symbol_param_mode(e.c, symbol, 0)) {
		return "%arg0"
	}
	return load_place(e, symbol.params[0], "%arg0")
}

// The receiver operand for a direct call to `hook` when the caller holds the
// receiver as a value. design.md "Receiver forms": a `self: ^` receiver wants
// the address of the value, so a held one is spilled here — once, and LLVM folds
// the round trip away. A caller that already has the address passes it straight.
@(private)
call_receiver_operand :: proc(
	e: ^Emitter, hook: Symbol_Id, type: Type_Id, value: string,
) -> (receiver_type: string, receiver: string) {
	sym := symbol_of(e.c, hook)
	if sym == nil || !param_mode_is_pointer(symbol_param_mode(e.c, sym, 0)) {
		return param_llvm(e, type, .Value), value
	}
	slot := temporary_slot(e, type)
	store(e, type, value, slot)
	return "ptr", slot
}

@(private)
proc_convention_of :: proc(e: ^Emitter, symbol: ^Symbol) -> string {
	info := type_of(e.c, symbol.proc_type)
	return info == nil ? "" : info.convention
}

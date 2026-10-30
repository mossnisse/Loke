// Resolved calls, argument packing, conversions, and allocation builtins.
package lokec

import "core:fmt"

// ------------------------------------------------------------------- calls --

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
		// Compare at the argument's width; a member it cannot hold never matches.
		source := expr_base(v.bound[0]).type
		bits, signed := type_bits(e.c, source), type_signed(e.c, source)
		value := emit_expr(e, v.bound[0])
		present := "false"
		for member in underlying_info(e.c, operation.type).fields {
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
		if backing_bits := type_bits(e.c, operation.type); backing_bits != bits {
			resized := temp(e)
			op := backing_bits < bits ? "trunc" : (signed ? "sext" : "zext")
			fmt.sbprintfln(&e.b, "  %s = %s i%d %s to i%d", resized, op, bits, value, backing_bits)
			value = resized
		}
		return emit_option_value(e, as_type, present, value)
	case Call_Union_As:
		return emit_union_as(e, v, operation.index, as_type)
	case Call_Box_Unbox:
		return emit_box_unbox(e, v)
	case Call_Extract:
		return emit_any_view_extract(e, operation.node, operation.node.type)[0]
	case Call_Dyn_Slot:
		results := emit_dyn_slot_call(e, v)
		return len(results) == 0 ? "0" : results[0]
	case Call_Dyn_Conversion:
		return emit_dyn_value(e, v, as_type)
	case Call_Text_Conversion:
		return emit_text_conversion(e, v, as_type)[0]
	case Call_Conversion:
		return emit_conversion(e, v, as_type)
	case Call_Reflect:
		return emit_descriptor_operation(e, v)
	case Call_Union_Construct:
		return emit_union_operation(e, v, as_type)
	case Call_Text:
		return emit_text_operation(e, v, as_type)[0]
	case Call_Procedure:
		results := emit_direct_call(e, v)
		return len(results) == 0 ? "0" : results[0]
	case Call_Builtin, Call_Atomic, Call_Allocation, Call_Sort_By, Call_Simd_Reduce:
	case nil, Call_Compile_Time:
		backend_fail(e, "an unchecked or compile-time call reached emission")
		return "0"
	}
	symbol := symbol_of(e.c, v.resolution.symbol)
	if symbol != nil && symbol.kind == .Builtin {
		switch symbol.builtin {
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
			return emit_make_container(e, v, as_type)[0]
		case .Drop:
			emit_explicit_drop(e, v)
			return "0"
		case .Exchange:
			return emit_exchange(e, v, as_type)
		case .Unsafe_Raw_Data, .Unsafe_String_View, .Unsafe_C_String_View:
			return emit_unsafe_builtin(e, v, symbol.builtin, as_type)[0]
		case .Unsafe_Transmute:
			return emit_transmute(e, v, as_type)
		case .Math_Wrap:
			source := expr_base(v.bound[0]).type
			return emit_value_conversion(e, emit_expr(e, v.bound[0]), source, as_type, checked = false)
		case .Math_Fma_Available:
			return .FMA in emitted_features(e) ? "true" : "false"
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
			// The feature's whole meaning is the call that is *not* made: the operand
			// is evaluated for its side effects, but skips the `emit_discarded_temporary`
			// an owned temporary would otherwise get. A `move(place)` operand still
			// zeroes and kills its source through `emit_move`, like any other transfer.
			emit_expr(e, v.bound[0])
			return "0"
		case .Type_Info_Of:
			return emit_type_info_of(e, v)
		case .Fmt_Stdout_Writer, .Fmt_Stderr_Writer, .Fmt_Write_Bytes, .Fmt_Format_View:
			return emit_fmt_builtin(e, v, symbol.builtin)
		case .Strings_Allocate:
			return emit_strings_allocate(e, v, as_type)[0]
		case .Slice_Sort_By:
			emit_slice_sort_by(e, v)
			return "0"
		case .Atomic_Load, .Atomic_Store, .Atomic_Exchange, .Atomic_Compare_Exchange,
		     .Atomic_Add, .Atomic_Sub, .Atomic_And, .Atomic_Or, .Atomic_Xor, .Atomic_Fence:
			return emit_atomic_builtin(e, v, symbol.builtin, as_type)
		case .Simd_Cast, .Simd_Select, .Simd_Reduce:
			return emit_simd_builtin(e, v, symbol.builtin, as_type)
		case .Unsafe_Free:
			emit_free(e, v)
			return "0"
		case .Free_All:
			emit_region_reset(e, v)
			return "0"
		case .None, .Size_Of, .Align_Of, .Offset_Of, .Is_Copyable, .Is_Union,
		     .Static_Assert, .Build_Config, .Source_Location, .Caller_Location,
		     .Type_Of, .Typeid_Of, .Fields_Of, .Enum_Values_Of, .Variants_Of:
			backend_fail(e, "an unfrozen compile-time built-in reached emission")
			return "0"
		}
	}
	backend_fail(e, "an intrinsic call has no builtin symbol")
	return "0"
}

// The checker admits the call only on a target with the instruction, where
// `llvm.fma` lowers to it rather than to the C library's `fma`.
@(private = "file")
emit_fma_instruction :: proc(e: ^Emitter, v: ^Expr_Call) -> string {
	llvm := llvm_type(e, expr_base(v.bound[0]).type)
	if .FMA not_in emitted_features(e) {
		if "llvm.trap" not_in e.simd_intrinsics {
			e.simd_intrinsics["llvm.trap"] = true
			append(&e.globals, "declare void @llvm.trap()\n")
		}
		fmt.sbprintln(&e.b, "  call void @llvm.trap()")
		fmt.sbprintln(&e.b, "  unreachable")
		fmt.sbprintfln(&e.b, "unreachable.%d:", next_id(e))
		return "poison"
	}
	key := fmt.aprintf("llvm.fma.%s", llvm == "float" ? "f32" : "f64")
	if key not_in e.simd_intrinsics {
		e.simd_intrinsics[key] = true
		append(&e.globals, fmt.aprintf("declare %s @%s(%s, %s, %s)\n", llvm, key, llvm, llvm, llvm))
	}
	a, b, c := emit_expr(e, v.bound[0]), emit_expr(e, v.bound[1]), emit_expr(e, v.bound[2])
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = call %s @%s(%s %s, %s %s, %s %s)", out, llvm, key, llvm, a, llvm, b, llvm, c)
	return out
}

// `llvm.sqrt` is the instruction on every x86-64 level, correctly rounded as
// IEEE 754 requires. `llvm.floor`, `ceil`, `trunc`, and `round` are SSE4.1's
// `roundsd` and `roundss` from `x86-64-v2`, and below it the C library's
// functions of those names; the result is exact either way.
@(private = "file")
emit_float_instruction :: proc(e: ^Emitter, v: ^Expr_Call, name: string) -> string {
	llvm := llvm_type(e, expr_base(v.bound[0]).type)
	key := fmt.aprintf("llvm.%s.%s", name, llvm == "float" ? "f32" : "f64")
	if key not_in e.simd_intrinsics {
		e.simd_intrinsics[key] = true
		append(&e.globals, fmt.aprintf("declare %s @%s(%s)\n", llvm, key, llvm))
	}
	x := emit_expr(e, v.bound[0])
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = call %s @%s(%s %s)", out, llvm, key, llvm, x)
	return out
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

emit_hash_value :: proc(e: ^Emitter, type: Type_Id, value, seed: string) -> string {
	// design.md "Maps": a part with its own `==` hashes by its own `hash`, which
	// is the coherent partner of the `==` structural equality calls for it.
	if own := part_own_hash(e.c, type); own != INVALID_SYMBOL {
		address := value
		if !is_large_value(e, type) {
			address = alloca(e, llvm_type(e, type))
			store(e, type, value, address)
		}
		out := temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i64 %s(%s, i64 %s)",
			out, symbol_name(e, own), hook_argument(e, own, 0, type, address), seed,
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
			part := ""
			if is_large_value(e, under) {
				address := element_address(e, under, value, index)
				part = is_large_value(e, symbol.type) ? address : load_place(e, symbol.type, address)
			} else {
				part = extract(e, llvm_type(e, under), value, index)
			}
			current = emit_hash_value(e, symbol.type, part, current)
		}
		return current
	}
	// A union mixes its tag, then the active payload, so two variants with one
	// payload type hash apart.
	if info != nil && info.kind == .Union {
		shape := union_layout(e.c, under)
		tag_llvm := fmt.aprintf("i%d", shape.tag_bytes * 8)
		tag := emit_union_tag(e, under, value)
		widened, mixed, tagged := temp(e), temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = zext %s %s to i64", widened, tag_llvm, tag)
		fmt.sbprintfln(&e.b, "  %s = xor i64 %s, %s", mixed, seed, widened)
		fmt.sbprintfln(&e.b, "  %s = mul i64 %s, %d", tagged, mixed, HASH_MULTIPLIER)
		slot := emit_union_spill(e, under, value)
		state := alloca(e, "i64")
		fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", tagged, state)
		done := new_label(e, "unionhash.done")
		for variant, index in info.variants {
			if variant == TYPE_VOID {
				continue
			}
			active := temp(e)
			fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, %d", active, tag_llvm, tag, index)
			hit, next := new_label(e, "unionhash.hit"), new_label(e, "unionhash.next")
			branch_if(e, active, hit, next)
			place_label(e, hit)
			payload := emit_union_payload(e, under, variant, slot)
			payload_hash := emit_hash_value(e, variant, payload, tagged)
			fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", payload_hash, state)
			branch(e, done)
			place_label(e, next)
		}
		place_label(e, done)
		return load(e, "i64", state)
	}
	if info != nil && info.kind == .Array && is_large_value(e, under) {
		// A large array is an address, so its elements are hashed in place, in a
		// loop rather than unrolled.
		element_llvm := llvm_type(e, info.element)
		state, cursor := alloca(e, "i64"), alloca(e, "i64")
		fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", seed, state)
		fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", cursor)
		head := new_label(e, "hash.large.head")
		body, done := new_label(e, "hash.large.body"), new_label(e, "hash.large.done")
		branch(e, head)
		place_label(e, head)
		at := load(e, "i64", cursor)
		more := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp slt i64 %s, %d", more, at, info.count)
		branch_if(e, more, body, done)
		place_label(e, body)
		element := load_temporary(e, info.element, gep_at(e, element_llvm, value, at))
		next := emit_hash_value(e, info.element, element, load(e, "i64", state))
		fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", next, state)
		step := temp(e)
		fmt.sbprintfln(&e.b, "  %s = add i64 %s, 1", step, at)
		fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", step, cursor)
		branch(e, head)
		place_label(e, done)
		return load(e, "i64", state)
	}
	if info != nil && info.kind == .Array {
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
		data := extract(e, storage, value, STRING_DATA)
		length := extract(e, storage, value, STRING_LEN)
		out := temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i64 @loke_rt_v1_hash_bytes(ptr %s, i64 %s, i64 %s)",
			out, data, length, seed,
		)
		return out
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
	case .Raw_Pointer, .Pointer, .C_Pointer:
		fmt.sbprintfln(&e.b, "  %s = ptrtoint ptr %s to i64", out, value)
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
	results := emit_bound_call(e, symbol_id, callee_name(e, symbol_id), info, bound, receiver = receiver)
	return len(results) == 0 ? "0" : results[0]
}

// A `distinct` newtype's forwarding overload.
@(private = "file")
emit_delegated :: proc(e: ^Emitter, symbol: ^Symbol, bound: []Expr, left_place: string) -> string {
	if symbol.delegate_target != INVALID_SYMBOL {
		return emit_operator_call(e, symbol.delegate_target, bound, left_place)
	}
	op := operator_token(symbol.operator)
	underlying := symbol.delegate_underlying
	if len(bound) == 1 {
		return emit_unary_op(e, op, underlying, emit_expr(e, bound[0]))
	}
	lhs := left_place != "" ? load_place(e, underlying, left_place) : emit_expr(e, bound[0])
	rhs := emit_expr(e, bound[1])
	#partial switch op {
	case .Eq_Eq, .Not_Eq, .Lt, .Lt_Eq, .Gt, .Gt_Eq:
		return emit_compare(e, op, underlying, lhs, rhs)
	}
	return emit_binary_op(e, op, underlying, underlying, lhs, rhs)
}

// Lowers calls that produce values outside the ordinary expression path.
@(private)
emit_producer_value :: proc(e: ^Emitter, expr: Expr, as_type: Type_Id) -> []string {
	#partial switch v in expr {
	case ^Expr_Call:
		#partial switch operation in v.operation {
		case Call_Extract:
			return emit_any_view_extract(e, operation.node, operation.node.type)
		case Call_Dyn_Slot:
			return emit_dyn_slot_call(e, v)
		case Call_Allocation:
			kind, _ := allocation_builtin(call_builtin_kind(e, v))
			if kind == .Make { return emit_make_container(e, v, as_type) }
			single := make([]string, 1)
			single[0] = emit_box_new(e, v, as_type)
			return single
		case Call_Text:
			return emit_text_operation(e, v, as_type)
		case Call_Text_Conversion:
			return emit_text_conversion(e, v, as_type)
		}
		if kind := call_builtin_kind(e, v); kind == .Unsafe_String_View {
			return emit_unsafe_builtin(e, v, kind, as_type)
		}
		if call_builtin_kind(e, v) == .Strings_Allocate {
			return emit_strings_allocate(e, v, as_type)
		}
		single := make([]string, 1)
		single[0] = emit_expr_at(e, expr, as_type)
		return single
	case ^Expr_Checked_Extract:
		return emit_any_view_extract(e, v, as_type)
	case ^Expr_Or_Else:
		return emit_or_else(e, v)
	case ^Expr_Postfix:
		if v.op == .Or_Return {
			return emit_or_return(e, v)
		}
	}
	single := make([]string, 1)
	single[0] = emit_expr_at(e, expr, as_type)
	return single
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
@(private = "file")
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
emit_make_container :: proc(e: ^Emitter, v: ^Expr_Call, as_type: Type_Id) -> []string {
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
	if !is_map && len(values) > 1 && values[1] != "" {
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
	e.terminated = false

	built := temp(e)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", built, CONTAINER_TYPE, header)
	out := make([]string, 1)
	out[0] = emit_alloc_outcome(e, v, as_type, failed, built, allocator)
	return out
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
	fmt.sbprintfln(
		&e.b, "  call void @loke_rt_v1_free(ptr %s, ptr %s, i64 %d, i64 %d)",
		allocator, pointer, type_size(e.c, info.element), type_align(e.c, info.element),
	)
}

// Whether this union value holds its designated failure variant.
@(private)
emit_union_failed :: proc(e: ^Emitter, union_type: Type_Id, value: string) -> string {
	info := type_of(e.c, type_underlying(e.c, union_type))
	shape := union_layout(e.c, union_type)
	tag := emit_union_tag(e, union_type, value)
	out := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = icmp eq i%d %s, %d",
		out, shape.tag_bytes * 8, tag, info.failure_variant,
	)
	return out
}

// Applies the explicit representations needed by propagated failures.
@(private = "file")
emit_failure_conversion :: proc(e: ^Emitter, value: string, from, into: Type_Id, source_address := "") -> string {
	if from == into || value == "" {
		return value
	}
	if underlying_kind(e.c, from) == .String && underlying_kind(e.c, into) == .String_View {
		data := extract(e, STRING_TYPE, value, STRING_DATA)
		length := extract(e, STRING_TYPE, value, STRING_LEN)
		return emit_ptr_len(e, STRING_VIEW_TYPE, data, length)
	}
	if into == TYPE_ANY_VIEW {
		concrete := any_view_source_type(e.c, from)
		slot := source_address
		if slot == "" {
			slot = alloca(e, llvm_type(e, concrete))
			store(e, concrete, value, slot)
		}
		return emit_any_view_value(e, slot, concrete)
	}
	// design.md "Widening by label": a smaller error set propagates into a
	// larger one.
	if union_widens_to(e.c, from, into) {
		return emit_union_widen(e, value, from, into)
	}
	// Carrier weakening, procedure escape weakening, checked/C-pointer
	// interchange, and pointer-to-rawptr all share one backend representation.
	return value
}

// The fallback is evaluated only for the failure variant.
@(private = "file")
emit_or_else :: proc(e: ^Emitter, v: ^Expr_Or_Else) -> []string {
	operand_type := type_underlying(e.c, expr_base(v.value).type)
	info := type_of(e.c, operand_type)
	success := 1 - info.failure_variant
	payload_type := info.variants[success]
	// A success that carries nothing yields `Unit`.
	unit := payload_type == TYPE_VOID
	if unit {
		payload_type = e.c.unit_type
	}

	value := emit_expr(e, v.value)
	slot := emit_union_spill(e, operand_type, value)

	entry := new_label(e, "orelse.entry")
	success_label := new_label(e, "orelse.success")
	fallback_label := new_label(e, "orelse.fallback")
	done := new_label(e, "orelse.done")
	branch(e, entry)
	place_label(e, entry)
	failed := emit_union_failed(e, operand_type, value)
	// A large value cannot be a phi operand, so each arm writes one slot.
	joined_slot := is_large_value(e, payload_type) ? temporary_slot(e, payload_type) : ""
	branch_if(e, failed, fallback_label, success_label)

	place_label(e, success_label)
	taken := "zeroinitializer"
	if !unit {
		taken = emit_union_payload(e, operand_type, payload_type, slot)
	}
	if v.borrows && emit_lifecycle(e, payload_type).managed {
		taken = emit_clone_value(e, payload_type, taken)
	}
	if joined_slot != "" {
		store(e, payload_type, taken, joined_slot)
	}
	success_exit := new_label(e, "orelse.success.exit")
	branch(e, success_exit)
	place_label(e, success_exit)
	branch(e, done)

	place_label(e, fallback_label)
	// design.md: `or_else` never copies the error, so a managed failure payload of
	// a *temporary* is dropped here, before the fallback runs, since the operand's
	// value is discarded on this path. A place still owns its own.
	if failure_type := info.variants[info.failure_variant];
	   !v.borrows && emit_lifecycle(e, failure_type).managed {
		emit_drop_place(e, failure_type, gep_field(e, llvm_type(e, operand_type), slot, 0))
	}
	// design.md "or_else expression": an exit leaves here, and only the success
	// arm reaches the rest of the expression. A temporary of a `return` value is
	// made only on this path, so the success path must not drop it.
	if v.exit != nil {
		begin_conditional(e)
		emit_stmt(e, v.exit)
		end_conditional(e)
		if !e.terminated {
			fmt.sbprintln(&e.b, "  unreachable")
			e.terminated = true
		}
		place_label(e, done)
		out := make([]string, 1)
		out[0] = joined_slot
		if joined_slot == "" {
			out[0] = temp(e)
			fmt.sbprintfln(
				&e.b, "  %s = phi %s [ %s, %%%s ]", out[0], llvm_type(e, payload_type), taken, success_exit,
			)
		}
		return out
	}
	begin_conditional(e)
	fallback := emit_copied_expr(e, v.fallback, payload_type, v.fallback_clone)
	end_conditional(e)
	if joined_slot != "" {
		store(e, payload_type, fallback, joined_slot)
	}
	fallback_exit := new_label(e, "orelse.fallback.exit")
	branch(e, fallback_exit)
	place_label(e, fallback_exit)
	branch(e, done)

	place_label(e, done)
	out := make([]string, 1)
	out[0] = joined_slot
	if joined_slot == "" {
		out[0] = temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = phi %s [ %s, %%%s ], [ %s, %%%s ]",
			out[0], llvm_type(e, payload_type), taken, success_exit, fallback, fallback_exit,
		)
	}
	return out
}

// Rewraps a failure and exits through the ordinary epilogue.
@(private = "file")
emit_or_return :: proc(e: ^Emitter, v: ^Expr_Postfix) -> []string {
	operand_type := type_underlying(e.c, expr_base(v.operand).type)
	info := type_of(e.c, operand_type)
	success := 1 - info.failure_variant
	operand_address := ""
	value := ""
	if v.borrows {
		// A place is evaluated once and retained as an address. Borrowing failure
		// conversions such as `T -> any_view` must point into that proven-live
		// source rather than into the temporary union spill below.
		operand_address = emit_address(e, v.operand)
		value = load_place(e, operand_type, operand_address)
	} else {
		value = emit_expr(e, v.operand)
	}
	slot := emit_union_spill(e, operand_type, value)
	failed := emit_union_failed(e, operand_type, value)

	fail_label := new_label(e, "orreturn.fail")
	ok_label := new_label(e, "orreturn.ok")
	branch_if(e, failed, fail_label, ok_label)

	place_label(e, fail_label)
	if v.failure_exit != nil {
		// design.md "or_return operator": the failure operand runs only here. A
		// mapper takes the error, copied out of a place; a replacement leaves a
		// place's error where it is and drops a temporary's first, as `or_else`
		// does.
		failure_type := info.variants[info.failure_variant]
		if v.failure_maps {
			error := emit_union_payload(e, operand_type, failure_type, slot)
			if v.borrows && emit_lifecycle(e, failure_type).managed {
				error = emit_clone_value(e, failure_type, error)
			}
			// Held until the mapper takes it, so an exit or a panic while the
			// mapper is selected still drops it.
			e.propagated_errors[v] = {error, hold_temporary_value(e, failure_type, error)}
		} else if !v.borrows && failure_type != TYPE_VOID && emit_lifecycle(e, failure_type).managed {
			emit_drop_place(e, failure_type, gep_field(e, llvm_type(e, operand_type), slot, 0))
		}
		// A temporary of the `return` value is made only on this path.
		begin_conditional(e)
		emit_stmt(e, v.failure_exit)
		end_conditional(e)
		if !e.terminated {
			fmt.sbprintln(&e.b, "  unreachable")
			e.terminated = true
		}
	} else if e.result_slot != "" {
		target := type_underlying(e.c, e.result_type)
		target_info := type_of(e.c, target)
		error := ""
		if failure_type := info.variants[info.failure_variant]; failure_type != TYPE_VOID {
			error = emit_union_payload(e, operand_type, failure_type, slot)
			failure_into := target_info.variants[target_info.failure_variant]
			if v.borrows && emit_lifecycle(e, failure_type).managed &&
			   !failure_assignment_borrows(e.c, failure_type, failure_into) {
				error = emit_clone_value(e, failure_type, error)
			}
			source_address := ""
			if v.borrows && failure_assignment_borrows(e.c, failure_type, failure_into) {
				source_address = gep_field(e, llvm_type(e, operand_type), operand_address, 0)
			}
			error = emit_failure_conversion(e, error, failure_type, failure_into, source_address)
		}
		wrapped := emit_union_value(e, e.result_type, target_info.failure_variant, error)
		store(e, e.result_type, wrapped, e.result_slot)
		emit_epilogue(e)
	} else {
		emit_epilogue(e)
	}

	place_label(e, ok_label)
	out := make([]string, 1)
	if info.variants[success] == TYPE_VOID {
		out[0] = "zeroinitializer"
		return out
	}
	out[0] = emit_union_payload(e, operand_type, info.variants[success], slot)
	if v.borrows && emit_lifecycle(e, info.variants[success]).managed {
		out[0] = emit_clone_value(e, info.variants[success], out[0])
	}
	return out
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

// Emits the call and returns its one result operand, or nothing.
@(private = "file")
emit_direct_call :: proc(e: ^Emitter, v: ^Expr_Call) -> []string {
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

@(private = "file")
// A lending pack holds a borrowed place or a spread's elements without cloning
// them, and its flags mark only the elements it owns; the callee clones the rest.
// A pack a container consumes copies through that container's `provider`, and
// for a `try_` form (`fallible`) a refused copy leaves its element unowned and
// is reported in the pack instead of applying the allocator's policy.
emit_variadic_pack :: proc(
	e: ^Emitter, v: ^Expr_Call, pack_type: Type_Id, lend := false, provider := "", fallible := false,
) -> Variadic_Pack {
	if v.variadic_forwards {
		return Variadic_Pack{value = emit_expr(e, v.bound[v.variadic_slot])}
	}
	element := slice_element(e.c, pack_type)
	element_llvm := llvm_type(e, element)
	static_count := len(v.variadic_elements)
	if len(v.variadic_spreads) == 0 && static_count == 0 {
		return Variadic_Pack{value = "zeroinitializer"}
	}
	managed := emit_lifecycle(e, element).managed

	// Staging protects managed operands while later operands are evaluated.
	staging, staging_flags, staging_count := "", "", ""
	staging_cleanup := Deferred{slot = -1}
	if managed && static_count > 0 {
		staging, staging_flags, staging_count = temp(e), temp(e), temp(e)
		alloca_named(e, staging, fmt.aprintf("[%d x %s]", static_count, element_llvm))
		alloca_named(e, staging_flags, fmt.aprintf("[%d x i1]", static_count))
		fmt.sbprintfln(
			&e.b, "  call void @llvm.memset.p0.i64(ptr %s, i8 0, i64 %d, i1 false)",
			staging_flags, static_count,
		)
		alloca_named(e, staging_count, "i64")
		fmt.sbprintfln(&e.b, "  store i64 %d, ptr %s", static_count, staging_count)
		staging_cleanup = register_array_cleanup(e, element, staging, staging_flags, staging_count)
		// An exit from a later operand drops the elements staged so far.
		append(&e.held, staging_cleanup)
	}

	// Spread lengths are collected while evaluating operands in written order.
	elements := make([]string, static_count)
	lent := make([]bool, static_count)
	// Whether the pack owns each element: a constant, or a refusable copy's
	// outcome.
	owns := make([]string, static_count)
	refused, refusal_error := "", ""
	spreads := make([]string, len(v.variadic_spreads))
	spread_data := make([]string, len(v.variadic_spreads))
	spread_len := make([]string, len(v.variadic_spreads))
	next_element, next_spread := 0, 0
	total := fmt.aprintf("%d", static_count)
	for is_spread in v.variadic_order {
		if is_spread {
			expr := v.variadic_spreads[next_spread]
			spreads[next_spread] = emit_expr(e, expr)
			storage := llvm_type(e, expr_base(expr).type)
			data := extract(e, storage, spreads[next_spread], SLICE_DATA)
			length := extract(e, storage, spreads[next_spread], SLICE_LEN)
			spread_data[next_spread], spread_len[next_spread] = data, length
			total = checked_variadic_total(e, total, length)
			next_spread += 1
			continue
		}
		expr := v.variadic_elements[next_element]
		// Temporaries transfer into staging; borrowed owners are cloned, or lent.
		lent[next_element] = managed && lend && expression_is_borrowed_place(expr)
		owns[next_element] = lent[next_element] ? "false" : "true"
		copies := managed && !lend && expression_is_borrowed_place(expr)
		value := ""
		if from := copied_type(expr, element); copies && fallible && from != element && emit_lifecycle(e, from).clone_fallible {
			if refused == "" {
				refused, refusal_error = alloca(e, "i1"), alloca(e, llvm_type(e, TYPE_ALLOCATOR_ERROR))
				fmt.sbprintfln(&e.b, "  store i1 false, ptr %s", refused)
			}
			value, owns[next_element] = emit_refusable_pack_copy(e, expr, from, element, provider, refused, refusal_error)
		} else {
			value = emit_copied_expr(e, expr, element, copies, provider)
		}
		elements[next_element] = value
		if managed {
			slot, flag := temp(e), temp(e)
			fmt.sbprintfln(
				&e.b, "  %s = getelementptr inbounds [%d x %s], ptr %s, i64 0, i64 %d",
				slot, static_count, element_llvm, staging, next_element,
			)
			store(e, element, value, slot)
			fmt.sbprintfln(&e.b, "  %s = getelementptr i1, ptr %s, i64 %d", flag, staging_flags, next_element)
			fmt.sbprintfln(&e.b, "  store i1 %s, ptr %s", owns[next_element], flag)
		}
		next_element += 1
	}

	buffer := temp(e)
	if len(v.variadic_spreads) == 0 {
		alloca_named(e, buffer, fmt.aprintf("[%d x %s]", static_count, element_llvm))
	} else {
		limit := u64(max(i64)) / max(type_size(e.c, element), 1)
		too_large := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp ugt i64 %s, %d", too_large, total, limit)
		panic_if(e, too_large, "variadic.size", "variadic argument pack is too large")
		save_stack_for_expression(e)
		alloca_count(e, buffer, element_llvm, total)
	}
	final_flags, final_count := "", ""
	cleanup := Deferred{slot = -1}
	if managed {
		final_flags, final_count = temp(e), temp(e)
		if len(v.variadic_spreads) == 0 {
			alloca_named(e, final_flags, fmt.aprintf("[%d x i1]", static_count))
		} else {
			alloca_count(e, final_flags, "i1", total)
		}
		fmt.sbprintfln(&e.b, "  call void @llvm.memset.p0.i64(ptr %s, i8 0, i64 %s, i1 false)", final_flags, total)
		alloca_named(e, final_count, "i64")
		fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", total, final_count)
		cleanup = register_array_cleanup(e, element, buffer, final_flags, final_count)
	}

	cursor := "0"
	cursor_slot := ""
	if managed {
		cursor_slot = temp(e)
		alloca_named(e, cursor_slot, "i64")
		fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", cursor_slot)
	}
	next_element, next_spread = 0, 0
	for is_spread in v.variadic_order {
		if managed {
			if is_spread && lend {
				// Lent bitwise, with its flags left clear.
				position := load(e, "i64", cursor_slot)
				bytes := temp(e)
				fmt.sbprintfln(
					&e.b, "  %s = mul i64 %s, %d", bytes, spread_len[next_spread], type_size(e.c, element),
				)
				fmt.sbprintfln(
					&e.b, "  call void @llvm.memcpy.p0.p0.i64(ptr %s, ptr %s, i64 %s, i1 false)",
					gep_at(e, element_llvm, buffer, position), spread_data[next_spread], bytes,
				)
				next_position := temp(e)
				fmt.sbprintfln(&e.b, "  %s = add i64 %s, %s", next_position, position, spread_len[next_spread])
				fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", next_position, cursor_slot)
				next_spread += 1
				continue
			}
			if is_spread {
				index_slot := alloca(e, "i64")
				fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", index_slot)
				head, body, done := new_label(e, "vararg.copy.head"), new_label(e, "vararg.copy.body"), new_label(e, "vararg.copy.done")
				branch(e, head)
				place_label(e, head)
				index := load(e, "i64", index_slot)
				more := temp(e)
				fmt.sbprintfln(&e.b, "  %s = icmp ult i64 %s, %s", more, index, spread_len[next_spread])
				branch_if(e, more, body, done)
				place_label(e, body)
				source := gep_at(e, element_llvm, spread_data[next_spread], index)
				loaded := load_place(e, element, source)
				cloned := emit_clone_value(e, element, loaded)
				position := load(e, "i64", cursor_slot)
				destination := gep_at(e, element_llvm, buffer, position)
				store(e, element, cloned, destination)
				flag := temp(e)
				fmt.sbprintfln(&e.b, "  %s = getelementptr i1, ptr %s, i64 %s", flag, final_flags, position)
				fmt.sbprintfln(&e.b, "  store i1 true, ptr %s", flag)
				next_index, next_position := temp(e), temp(e)
				fmt.sbprintfln(&e.b, "  %s = add i64 %s, 1", next_index, index)
				fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", next_index, index_slot)
				fmt.sbprintfln(&e.b, "  %s = add i64 %s, 1", next_position, position)
				fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", next_position, cursor_slot)
				branch(e, head)
				place_label(e, done)
				next_spread += 1
				continue
			}
			position := load(e, "i64", cursor_slot)
			destination := gep_at(e, element_llvm, buffer, position)
			source := temp(e)
			fmt.sbprintfln(
				&e.b, "  %s = getelementptr inbounds [%d x %s], ptr %s, i64 0, i64 %d",
				source, static_count, element_llvm, staging, next_element,
			)
			loaded := load_place(e, element, source)
			store(e, element, loaded, destination)
			final_flag, staging_flag := temp(e), temp(e)
			fmt.sbprintfln(&e.b, "  %s = getelementptr i1, ptr %s, i64 %s", final_flag, final_flags, position)
			fmt.sbprintfln(&e.b, "  store i1 %s, ptr %s", owns[next_element], final_flag)
			fmt.sbprintfln(&e.b, "  %s = getelementptr i1, ptr %s, i64 %d", staging_flag, staging_flags, next_element)
			fmt.sbprintfln(&e.b, "  store i1 false, ptr %s", staging_flag)
			next_position := temp(e)
			fmt.sbprintfln(&e.b, "  %s = add i64 %s, 1", next_position, position)
			fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", next_position, cursor_slot)
			next_element += 1
			continue
		}
		slot := gep_at(e, element_llvm, buffer, cursor)
		if is_spread {
			bytes := temp(e)
			fmt.sbprintfln(
				&e.b, "  %s = mul i64 %s, %d",
				bytes, spread_len[next_spread], type_size(e.c, element),
			)
			fmt.sbprintfln(
				&e.b, "  call void @llvm.memcpy.p0.p0.i64(ptr %s, ptr %s, i64 %s, i1 false)",
				slot, spread_data[next_spread], bytes,
			)
			advanced := temp(e)
			fmt.sbprintfln(&e.b, "  %s = add i64 %s, %s", advanced, cursor, spread_len[next_spread])
			cursor = advanced
			next_spread += 1
			continue
		}
		store(e, element, elements[next_element], slot)
		advanced := temp(e)
		fmt.sbprintfln(&e.b, "  %s = add i64 %s, 1", advanced, cursor)
		cursor = advanced
		next_element += 1
	}
	if staging_cleanup.array_cleanup {
		unwind_clear(e, staging_cleanup.slot)
		release_held(e, staging_cleanup)
	}
	return Variadic_Pack{
		value = emit_slice_value(e, pack_type, buffer, total), cleanup = cleanup,
		refused = refused, error = refusal_error,
	}
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
	e.terminated = false
	owned = temp(e)
	fmt.sbprintfln(&e.b, "  %s = xor i1 %s, true", owned, failed)
	return load_temporary(e, element, slot), owned
}

// Materializes the Windows x64 call-side ABI.
@(private)
param_is_by_ptr :: proc(info: ^Type_Info, index: int) -> bool {
	return info != nil && index < len(info.param_by_ptr) && info.param_by_ptr[index]
}

@(private)
proc_result_is_inout :: proc(info: ^Type_Info) -> bool {
	return info != nil && info.result_inout
}

// The container insertion slot whose element the callee consumes, or -1.
// design.md "Container insertion": a move-only element is always handed over,
// and so is an owned one of any type, through the member's consuming body.
@(private = "file")
consumed_element_slot :: proc(
	e: ^Emitter, symbol_id: Symbol_Id, symbol: ^Symbol, call_node: ^Expr_Call,
) -> (slot: int, consuming_body: bool) {
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
		e.consuming_ops[symbol_id] = true
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
	e.consuming_ops[symbol_id] = true
	return slot, true
}

// The name of a container member's consuming body.
consuming_op_name :: proc(e: ^Emitter, symbol_id: Symbol_Id) -> string {
	return fmt.aprintf("%s.consume", symbol_name(e, symbol_id))
}

// Binds operands left to right and emits one call. A non-empty `receiver` is
// slot 0's already-evaluated operand, typed `receiver_type` when that is set.
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
) -> []string {
	symbol := symbol_of(e.c, symbol_id)
	if callee_type == nil {
		return nil
	}
	// A default reads the parameters already bound to its left; a written
	// argument sees only the bindings of the default it is written in, if any.
	outer_params := e.param_values
	own_params := make(map[Symbol_Id]string)
	defer {
		delete(own_params)
		e.param_values = outer_params
	}

	operands := make([]string, len(bound))
	pack := -1
	if call_node != nil && call_node.is_variadic {
		pack = call_node.variadic_slot
	}
	pack_cleanup := Deferred{slot = -1}
	callee := callee
	owned_flags := ""
	consumed, consuming_body := consumed_element_slot(e, symbol_id, symbol, call_node)
	if consuming_body {
		callee = consuming_op_name(e, symbol_id)
	}
	argument_cleanups := make([dynamic]Deferred)
	defer delete(argument_cleanups)
	handoff_cleanups := make([dynamic]Deferred)
	defer delete(handoff_cleanups)
	result_borrows := callee_type.result != INVALID_TYPE && type_carries_borrow(e.c, callee_type.result).any
	inserted: Insertion_Copy
	refused_pack: Variadic_Pack
	for step in 0 ..< len(bound) {
		index := call_node != nil ? call_slot_at(call_node, step) : step
		argument := bound[index]
		is_default := symbol != nil && argument != nil && index < len(symbol.param_defaults) &&
			argument == symbol.param_defaults[index]
		e.param_values = is_default ? own_params : outer_params
		if index == 0 && receiver != "" {
			operands[0] = receiver
			if symbol != nil && len(symbol.param_symbols) > 0 && symbol.param_symbols[0] != INVALID_SYMBOL {
				own_params[symbol.param_symbols[0]] = receiver
			}
			continue
		}
		if index == pack {
			// A consuming `append` clones what the pack lends, so a failed clone is its
			// to report.
			lends := consuming_body && symbol.container_op == .Append
			// A pack the container consumes copies through its provider.
			provider, fallible := "", false
			if consumed == pack && symbol.container_op == .Append && operands[0] != "" {
				provider = load(e, "ptr", gep_field(e, CONTAINER_TYPE, operands[0], CONTAINER_ALLOC))
				fallible = container_member_is_try(e.c, symbol)
			}
			packed := emit_variadic_pack(
				e, call_node, callee_type.parameters[index], lend = lends, provider = provider, fallible = fallible,
			)
			if packed.refused != "" {
				refused_pack = packed
			}
			if lends {
				// Nothing owned crosses into a `try_` form: it copies every element.
				owned_flags = consumed == pack && packed.cleanup.array_cleanup ? packed.cleanup.array_flags : "null"
			}
			operands[index] = packed.value
			pack_cleanup = packed.cleanup
			continue
		}
		mode := index < len(callee_type.param_modes) ? callee_type.param_modes[index] : Param_Mode.Value
		if index == 0 && param_mode_is_pointer(mode) && symbol != nil && prov_op_lends_receiver(symbol.container_op) {
			// design.md "Splitting a mutable slice": the receiver is evaluated
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
			inserted = emit_insertion_copy(e, argument, callee_type.parameters[index], operands[0], container_member_is_try(e.c, symbol))
			operands[index] = inserted.value
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
			if result_borrows {
				// The result may borrow the argument, as `arena.allocator()` borrows
				// its provider, so the temporary lives through the complete
				// expression (design.md "Temporaries and procedure boundaries").
				held := alloca(e, llvm_type(e, callee_type.parameters[index]))
				store(e, callee_type.parameters[index], operands[index], held)
				register_temporary_place(e, callee_type.parameters[index], held)
			} else {
				entry := hold_temporary_value(e, callee_type.parameters[index], operands[index])
				if entry.place != "" { append(&argument_cleanups, entry) }
			}
		}
		// Method syntax supplies a move receiver's marker implicitly.
		if index == 0 && symbol != nil && symbol.receiver == .Move {
			if ident, is_ident := argument.(^Expr_Ident); is_ident {
				kill_place(e, ident.symbol)
			}
		}
		if symbol != nil && index < len(symbol.param_symbols) && symbol.param_symbols[index] != INVALID_SYMBOL {
			own_params[symbol.param_symbols[index]] = operands[index]
		}
	}
	e.param_values = outer_params

	// A consumed pack transfers to the callee.
	if consumed >= 0 && consumed == pack && pack_cleanup.array_cleanup {
		unwind_clear(e, pack_cleanup.slot)
		pack_cleanup = Deferred{slot = -1}
	}
	// Ownership now crosses the call boundary.
	for entry in handoff_cleanups {
		finish_temporary_drop(e, entry)
	}

	if convention_is_foreign(callee_type.convention) {
		return emit_foreign_call(e, callee, callee_type, operands, symbol, bound)
	}

	result_type := llvm_result_type(e, callee_type.result, callee_type.result_inout)
	sret := returns_sret(e, callee_type.result, callee_type.result_inout)
	call := sret ? temporary_slot(e, callee_type.result) : ""
	// A `try_` form whose copy was refused returns that failure, and the call
	// is not made; a refused pack first drops what it owns.
	joined, joined_slot := "", ""
	failed, error := inserted.failed, inserted.error
	if refused_pack.refused != "" {
		failed = load(e, "i1", refused_pack.refused)
		error = load(e, llvm_type(e, TYPE_ALLOCATOR_ERROR), refused_pack.error)
	}
	if failed != "" {
		refused, attempted := new_label(e, "insert.refused"), new_label(e, "insert.copied")
		joined = new_label(e, "insert.joined")
		joined_slot = sret ? call : temporary_slot(e, callee_type.result)
		branch_if(e, failed, refused, attempted)
		place_label(e, refused)
		if cleanup := refused_pack.cleanup; cleanup.array_cleanup {
			emit_drop_flagged_array(e, cleanup.type, cleanup.array_buffer, cleanup.array_flags, cleanup.array_count)
		}
		store(e, callee_type.result, emit_alloc_result(e, callee_type.result, "true", error = error), joined_slot)
		branch(e, joined)
		place_label(e, attempted)
	}
	if inserted.from != INVALID_TYPE {
		operands[consumed] = emit_union_widen(e, operands[consumed], inserted.from, callee_type.parameters[consumed])
	}
	// A large argument is passed as the address of a copy only the callee reads.
	for &operand, index in operands {
		if index < len(callee_type.parameters) && is_large_value(e, callee_type.parameters[index]) &&
		   operand[0] != '%' {
			spill := temporary_slot(e, callee_type.parameters[index])
			store(e, callee_type.parameters[index], operand, spill)
			operand = spill
		}
	}
	if sret {
		fmt.sbprintf(&e.b, "  call void %s(ptr %s%s", callee, call, len(operands) > 0 ? ", " : "")
	} else if callee_type.result != INVALID_TYPE {
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
		type := param_llvm(e, callee_type.parameters[index], mode)
		if index == 0 && receiver_type != "" {
			type = receiver_type
		}
		fmt.sbprintf(&e.b, "%s %s", type, operand)
	}
	if owned_flags != "" {
		fmt.sbprintf(&e.b, ", ptr %s", owned_flags)
	}
	fmt.sbprintln(&e.b, ")")
	if joined != "" {
		if !sret {
			store(e, callee_type.result, call, joined_slot)
		}
		branch(e, joined)
		place_label(e, joined)
		e.terminated = false
		call = sret ? call : load_temporary(e, callee_type.result, joined_slot)
	}
	results: []string
	if callee_type.result != INVALID_TYPE {
		results = make([]string, 1)
		results[0] = call
	}
	guard := Deferred{slot = -1}
	if len(results) == 1 && !callee_type.result_inout &&
	   (pack_cleanup.array_cleanup || len(argument_cleanups) > 0) {
		guard = hold_temporary_value(e, callee_type.result, results[0])
	}
	if pack_cleanup.array_cleanup {
		emit_drop_flagged_array(
			e, pack_cleanup.type, pack_cleanup.array_buffer,
			pack_cleanup.array_flags, pack_cleanup.array_count,
		)
		unwind_clear(e, pack_cleanup.slot)
	}

	if len(argument_cleanups) > 0 {
		for index := len(argument_cleanups) - 1; index >= 0; index -= 1 {
			drop_temporary_value(e, argument_cleanups[index])
		}
	}
	if guard.place != "" { finish_temporary_drop(e, guard) }
	return results
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
	source_expr := v.bound[0]
	source := expr_base(source_expr).type
	target := as_type
	value := emit_expr(e, source_expr)
	if v.operation.(Call_Conversion).clones {
		value = emit_clone_value(e, source, value)
	}
	return emit_value_conversion(e, value, source, target, checked = true)
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
	from_lane, to_lane := from, to
	if type_is_simd(e.c, from) && type_is_simd(e.c, to) {
		from_lane = type_underlying(e.c, type_of(e.c, from).element)
		to_lane = type_underlying(e.c, type_of(e.c, to).element)
	}
	from_float := type_is_float(e.c, from_lane)
	to_float := type_is_float(e.c, to_lane)
	from_bits, to_bits := type_bits(e.c, from_lane), type_bits(e.c, to_lane)
	from_signed := type_signed(e.c, from_lane) || type_is_rune(e.c, from_lane)
	to_signed := type_signed(e.c, to_lane) || type_is_rune(e.c, to_lane)

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
	from_lane, to_lane := from, to
	lanes := type_is_simd(e.c, from) && type_is_simd(e.c, to)
	info := type_of(e.c, from)
	if lanes {
		from_lane = type_underlying(e.c, info.element)
		to_lane = type_underlying(e.c, type_of(e.c, to).element)
	}
	integral :: proc(c: ^Compiler, type: Type_Id) -> bool {
		return type_is_integer(c, type) || type_is_rune(c, type) || underlying_kind(c, type) == .Enum
	}
	if !integral(e.c, from_lane) || !integral(e.c, to_lane) {
		return
	}
	from_bits, to_bits := type_bits(e.c, from_lane), type_bits(e.c, to_lane)
	from_signed := type_signed(e.c, from_lane) || type_is_rune(e.c, from_lane)
	to_signed := type_signed(e.c, to_lane) || type_is_rune(e.c, to_lane)
	from_max := bi_sub(e.c, bi_pow2(e.c, from_bits - (from_signed ? 1 : 0)), bi_from_i64(e.c, 1))
	to_max := bi_sub(e.c, bi_pow2(e.c, to_bits - (to_signed ? 1 : 0)), bi_from_i64(e.c, 1))
	to_min := to_signed ? bi_neg(e.c, bi_pow2(e.c, to_bits - 1)) : bi_zero(e.c)
	// Only a bound the source can pass needs a test.
	test_high := bi_cmp(e.c, to_max, from_max) < 0
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
		bad = temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = icmp %s %s %s, %s", bad, from_signed ? "sgt" : "ugt", llvm, value, bound(e, info, lanes, to_max),
		)
	}
	if test_low {
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
	signed := type_signed(e.c, to_lane) || type_is_rune(e.c, to_lane)
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

// `U.name(payload)`: evaluate the payload and write it plus the variant's tag.
@(private = "file")
emit_union_operation :: proc(e: ^Emitter, v: ^Expr_Call, as_type: Type_Id) -> string {
	operation, construction := v.operation.(Call_Union_Construct)
	if !construction || len(v.bound) != 1 {
		backend_fail(e, "a union call has no construction operand")
		return "0"
	}
	payload := emit_copied_expr(e, v.bound[0], expr_base(v.bound[0]).type, operation.clone)
	return emit_union_value(e, as_type, operation.index, payload)
}

// `u.as(.name)` borrows `u`: the payload is cloned only once the tag matched,
// and the option is written only on that path.
@(private = "file")
emit_union_as :: proc(e: ^Emitter, v: ^Expr_Call, index: int, as_type: Type_Id) -> string {
	subject := type_underlying(e.c, expr_base(v.bound[0]).type)
	value := emit_borrowed_operand(e, v.bound[0])
	tag := emit_union_tag(e, subject, value)
	matched := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i%d %s, %d", matched, union_layout(e.c, subject).tag_bytes * 8, tag, index)

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
	store(e, as_type, emit_union_value(e, as_type, union_index_of(e.c, as_type, "some"), payload), slot)
	branch(e, done_label)
	place_label(e, done_label)
	return load_place(e, as_type, slot)
}

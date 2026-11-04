// Emitting `Simd(T, N)` (design.md "SIMD vectors") as LLVM's `<N x T>`. Lane
// access is the ordinary array path; a mask lane is `i8` where `icmp` gives `i1`.
package lokec

import "core:fmt"
import "core:strings"

emit_simd_splat :: proc(e: ^Emitter, value: string, vector: Type_Id) -> string {
	info := underlying_info(e.c, vector)
	llvm := llvm_type(e, vector)
	scalar := value
	if simd_is_mask(e, info) {
		scalar = temp(e)
		fmt.sbprintfln(&e.b, "  %s = zext i1 %s to i8", scalar, value)
	}
	one, out := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = insertelement %s poison, %s %s, i32 0", one, llvm, simd_lane_llvm_type(e, info), scalar)
	fmt.sbprintfln(
		&e.b, "  %s = shufflevector %s %s, %s poison, <%d x i32> zeroinitializer",
		out, llvm, one, llvm, info.count,
	)
	return out
}

simd_is_mask :: proc(e: ^Emitter, info: ^Type_Info) -> bool {
	return type_is_boolean(e.c, info.element)
}

emit_simd_binary :: proc(e: ^Emitter, v: ^Expr_Binary) -> string {
	left := emit_expr(e, v.lhs)
	right := emit_expr(e, v.rhs)
	return emit_simd_binary_values(e, v.op, expr_base(v.lhs).type, left, right)
}

// The operator over already-evaluated operands, as a compound assignment has.
emit_simd_binary_values :: proc(e: ^Emitter, op: Token_Kind, vector: Type_Id, left, right_value: string) -> string {
	right := right_value
	info := underlying_info(e.c, vector)
	llvm := llvm_type(e, vector)
	float := type_is_float(e.c, info.element)

	#partial switch op {
	case .Eq_Eq, .Not_Eq, .Lt, .Lt_Eq, .Gt, .Gt_Eq:
		return emit_simd_compare(e, op, info, llvm, left, right)
	case .Plus, .Minus, .Star:
		if !float {
			return emit_simd_checked(e, op, info, llvm, left, right)
		}
	case .Slash, .Percent:
		if !float {
			return emit_simd_divrem(e, op, info, llvm, left, right)
		}
	case .Shl, .Shr:
		return emit_simd_shift(e, op, info, llvm, left, right)
	case .Amp_Tilde:
		complement := temp(e)
		fmt.sbprintfln(&e.b, "  %s = xor %s %s, %s", complement, llvm, right, simd_all_ones(e, info))
		right = complement
	}
	mnemonics := arith_mnemonic(op == .Amp_Tilde ? .Amp : op)
	mnemonic := float ? mnemonics.float : mnemonics.integer
	if mnemonic == "" {
		backend_fail(e, "an unhandled SIMD operator reached emission")
		return "zeroinitializer"
	}
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = %s %s %s, %s", out, mnemonic, llvm, left, right)
	return out
}

// design.md "Lane-wise operators": a lane that overflows panics the whole
// operation, as the scalar operator would.
emit_simd_checked :: proc(e: ^Emitter, op: Token_Kind, info: ^Type_Info, llvm, left, right: string) -> string {
	signed := type_signed(e.c, info.element)
	key := checked_intrinsic(op, signed, fmt.aprintf("v%d%s", info.count, simd_lane_llvm_type(e, info)))
	flag := fmt.aprintf("<%d x i1>", info.count)
	if key not_in e.simd_intrinsics {
		e.simd_intrinsics[key] = true
		append(&e.globals, fmt.aprintf("declare {{ %s, %s }} @%s(%s, %s)\n", llvm, flag, key, llvm, llvm))
	}
	wrapped, overflowed := emit_overflow_call(e, key, llvm, flag, left, right)
	panic_if(e, simd_any_lane(e, info, overflowed), "int.overflow", overflow_message(signed))
	return wrapped
}

@(private = "file")
emit_simd_compare :: proc(e: ^Emitter, op: Token_Kind, info: ^Type_Info, llvm, left, right: string) -> string {
	bits := temp(e)
	fmt.sbprintfln(&e.b, "  %s = %s %s %s, %s", bits, compare_instruction(e, op, info.element), llvm, left, right)
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = zext <%d x i1> %s to <%d x i8>", out, info.count, bits, info.count)
	return out
}

// Any zero lane faults the whole operation; otherwise lane by lane as
// `emit_divrem`.
@(private = "file")
emit_simd_divrem :: proc(e: ^Emitter, op: Token_Kind, info: ^Type_Info, llvm, left, right: string) -> string {
	zeroes := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, zeroinitializer", zeroes, llvm, right)
	panic_if(e, simd_any_lane(e, info, zeroes), "div.zero", "integer division by zero")

	if !type_signed(e.c, info.element) {
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = %s %s %s, %s", out, op == .Slash ? "udiv" : "urem", llvm, left, right)
		return out
	}

	bits := type_bits(e.c, info.element)
	minimum := simd_repeated(e, info, bi_text(e.c, bi_neg(e.c, bi_pow2(e.c, bits - 1))))
	is_min, is_neg_one, overflow := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, %s", is_min, llvm, left, minimum)
	fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, %s", is_neg_one, llvm, right, simd_all_ones(e, info))
	fmt.sbprintfln(&e.b, "  %s = and <%d x i1> %s, %s", overflow, info.count, is_min, is_neg_one)
	if op == .Slash {
		panic_if(e, simd_any_lane(e, info, overflow), "int.overflow", "signed integer overflow")
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = sdiv %s %s, %s", out, llvm, left, right)
		return out
	}
	safe := simd_select(e, info, llvm, overflow, simd_repeated(e, info, "1"), right)
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = srem %s %s, %s", out, llvm, left, safe)
	return out
}

// A negative count lane panics the whole operation; otherwise lane by lane as
// `emit_shift`.
@(private = "file")
emit_simd_shift :: proc(e: ^Emitter, op: Token_Kind, info: ^Type_Info, llvm, left, right: string) -> string {
	bits := type_bits(e.c, info.element)
	if type_signed(e.c, info.element) {
		negative := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp slt %s %s, zeroinitializer", negative, llvm, right)
		panic_if(e, simd_any_lane(e, info, negative), "shift.negative", "negative shift count")
	}
	oversized := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = icmp uge %s %s, %s", oversized, llvm, right, simd_repeated(e, info, fmt.aprintf("%d", bits)),
	)
	if op == .Shr && type_signed(e.c, info.element) {
		clamped := simd_select(e, info, llvm, oversized, simd_repeated(e, info, fmt.aprintf("%d", bits - 1)), right)
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = ashr %s %s, %s", out, llvm, left, clamped)
		return out
	}
	safe := simd_select(e, info, llvm, oversized, "zeroinitializer", right)
	raw := temp(e)
	fmt.sbprintfln(&e.b, "  %s = %s %s %s, %s", raw, op == .Shl ? "shl" : "lshr", llvm, left, safe)
	return simd_select(e, info, llvm, oversized, "zeroinitializer", raw)
}

@(private = "file")
simd_select :: proc(e: ^Emitter, info: ^Type_Info, llvm, condition, if_true, if_false: string) -> string {
	out := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = select <%d x i1> %s, %s %s, %s %s", out, info.count, condition, llvm, if_true, llvm, if_false,
	)
	return out
}

simd_repeated :: proc(e: ^Emitter, info: ^Type_Info, lane: string) -> string {
	llvm := simd_lane_llvm_type(e, info)
	b := strings.builder_make()
	strings.write_string(&b, "<")
	for index in 0 ..< int(info.count) {
		fmt.sbprintf(&b, "%s %s %s", index == 0 ? "" : ",", llvm, lane)
	}
	strings.write_string(&b, ">")
	return strings.to_string(b)
}

// A mask lane must stay 0 or 1, so its complement flips only the low bit.
simd_all_ones :: proc(e: ^Emitter, info: ^Type_Info) -> string {
	return simd_repeated(e, info, simd_is_mask(e, info) ? "1" : "-1")
}

// True when any lane of an `<N x i1>` is.
simd_any_lane :: proc(e: ^Emitter, info: ^Type_Info, mask: string) -> string {
	return simd_call_reduce(e, "or", "i1", int(info.count), mask, "")
}

// `start` is the `type value, ` prefix of an ordered float fold, or empty.
@(private = "file")
simd_call_reduce :: proc(e: ^Emitter, name, lane: string, count: int, value, start: string) -> string {
	key := fmt.aprintf("llvm.vector.reduce.%s.v%d%s", name, count, intrinsic_type_suffix(lane))
	if key not_in e.simd_intrinsics {
		e.simd_intrinsics[key] = true
		leading := start != "" ? fmt.aprintf("%s, ", lane) : ""
		append(&e.globals, fmt.aprintf("declare %s @%s(%s<%d x %s>)\n", lane, key, leading, count, lane))
	}
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = call %s @%s(%s<%d x %s> %s)", out, lane, key, start, count, lane, value)
	return out
}

// ------------------------------------------------------- `core:simd` --

// `from_array`/`to_array`: the same bytes, stored and reloaded through the
// vector's over-aligned storage.
emit_simd_cast :: proc(e: ^Emitter, v: ^Expr_Call, as_type: Type_Id) -> string {
	source := expr_base(v.bound[0]).type
	vector := type_is_simd(e.c, source) ? source : as_type
	value := emit_expr(e, v.bound[0])
	slot := alloca(e, llvm_type(e, vector))
	store(e, source, value, slot)
	return load_place(e, as_type, slot)
}

emit_simd_select :: proc(e: ^Emitter, v: ^Expr_Call, as_type: Type_Id) -> string {
	info := underlying_info(e.c, as_type)
	mask := emit_expr(e, v.bound[0])
	left := emit_expr(e, v.bound[1])
	right := emit_expr(e, v.bound[2])
	bits := temp(e)
	fmt.sbprintfln(&e.b, "  %s = trunc <%d x i8> %s to <%d x i1>", bits, info.count, mask, info.count)
	return simd_select(e, info, llvm_type(e, as_type), bits, left, right)
}

// Float sums and products use the ordered form, seeded with `-0.0` or `1.0`
// so an all-`-0.0` sum keeps its sign.
emit_simd_reduce :: proc(e: ^Emitter, v: ^Expr_Call) -> string {
	info := underlying_info(e.c, expr_base(v.bound[0]).type)
	value := emit_expr(e, v.bound[0])
	lane := simd_lane_llvm_type(e, info)
	count := int(info.count)
	float := type_is_float(e.c, info.element)
	signed := type_signed(e.c, info.element)

	name := ""
	switch fold := v.operation.(Call_Simd_Reduce).fold; fold {
	case .Any, .All:
		folded := simd_call_reduce(e, fold == .Any ? "or" : "and", lane, count, value, "")
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = trunc i8 %s to i1", out, folded)
		return out
	case .Add, .Mul:
		if !float {
			return emit_simd_checked_fold(e, fold == .Add ? .Plus : .Star, signed, lane, count, value)
		}
		bits := u16(type_bits(e.c, info.element))
		start := fmt.aprintf("%s %s, ", lane, llvm_float(float_pattern(fold == .Add ? -0.0 : 1.0, bits), bits))
		return simd_call_reduce(e, fold == .Add ? "fadd" : "fmul", lane, count, value, start)
	case .Min:
		name = float ? "fmin" : (signed ? "smin" : "umin")
	case .Max:
		name = float ? "fmax" : (signed ? "smax" : "umax")
	}
	return simd_call_reduce(e, name, lane, count, value, "")
}

// An integer sum or product folds from lane 0, left to right, through the
// scalar checked operator, so a partial result that does not fit panics as the
// same loop over the lanes would.
@(private = "file")
emit_simd_checked_fold :: proc(e: ^Emitter, op: Token_Kind, signed: bool, lane: string, count: int, vector: string) -> string {
	result := ""
	for index in 0 ..< count {
		element := temp(e)
		fmt.sbprintfln(&e.b, "  %s = extractelement <%d x %s> %s, i32 %d", element, count, lane, vector, index)
		result = index == 0 ? element : emit_checked_integer(e, op, signed, lane, result, element)
	}
	return result
}

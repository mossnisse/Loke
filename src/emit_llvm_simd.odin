// Emitting `Simd(T, N)` (design.md "SIMD vectors") as LLVM's `<N x T>`. Lane
// access is the ordinary array path; a mask lane is `i8` where `icmp` gives `i1`.
package lokec

import "core:fmt"
import "core:strings"

// An operand the checker left at the element type is a splat.
@(private = "file")
simd_operand :: proc(e: ^Emitter, value: string, written: Type_Id, vector: Type_Id) -> string {
	if type_underlying(e.c, written) == type_underlying(e.c, vector) {
		return value
	}
	return emit_simd_splat(e, value, vector)
}

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

@(private = "file")
simd_is_mask :: proc(e: ^Emitter, info: ^Type_Info) -> bool {
	return type_kind(e.c, type_underlying(e.c, info.element)) == .Bool
}

emit_simd_binary :: proc(e: ^Emitter, v: ^Expr_Binary) -> string {
	left_type := expr_base(v.lhs).type
	vector := type_is_simd(e.c, left_type) ? left_type : expr_base(v.rhs).type
	left := emit_expr(e, v.lhs)
	right := emit_expr(e, v.rhs)
	return emit_simd_binary_values(e, v.op, vector, left, left_type, right, expr_base(v.rhs).type)
}

// The operator over already-evaluated operands, as a compound assignment has.
emit_simd_binary_values :: proc(
	e: ^Emitter,
	op: Token_Kind,
	vector: Type_Id,
	left_value: string,
	left_type: Type_Id,
	right_value: string,
	right_type: Type_Id,
) -> string {
	info := underlying_info(e.c, vector)
	llvm := llvm_type(e, vector)
	left := simd_operand(e, left_value, left_type, vector)
	right := simd_operand(e, right_value, right_type, vector)
	float := type_is_float(e.c, info.element)

	mnemonic := ""
	#partial switch op {
	case .Eq_Eq, .Not_Eq, .Lt, .Lt_Eq, .Gt, .Gt_Eq:
		return emit_simd_compare(e, op, vector, info, left, right)
	case .Slash, .Percent:
		if !float {
			return emit_simd_divrem(e, op, vector, info, left, right)
		}
		if op == .Slash { mnemonic = "fdiv" }
	case .Shl, .Shr:
		return emit_simd_shift(e, op, vector, info, left, right)
	case .Amp_Tilde:
		complement := temp(e)
		fmt.sbprintfln(&e.b, "  %s = xor %s %s, %s", complement, llvm, right, simd_all_ones(e, info))
		right = complement
		mnemonic = "and"
	case .Plus:  mnemonic = float ? "fadd" : "add"
	case .Minus: mnemonic = float ? "fsub" : "sub"
	case .Star:  mnemonic = float ? "fmul" : "mul"
	case .Amp:   mnemonic = "and"
	case .Pipe:  mnemonic = "or"
	case .Tilde: mnemonic = "xor"
	}
	if mnemonic == "" {
		backend_fail(e, "an unhandled SIMD operator reached emission")
		return "zeroinitializer"
	}
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = %s %s %s, %s", out, mnemonic, llvm, left, right)
	return out
}

// A comparison yields a mask: one byte per lane, widened from `icmp`'s `i1`.
@(private = "file")
emit_simd_compare :: proc(
	e: ^Emitter, op: Token_Kind, vector: Type_Id, info: ^Type_Info, left, right: string,
) -> string {
	predicate := compare_predicate(op)
	name := predicate.float
	instruction := "fcmp"
	if !type_is_float(e.c, info.element) {
		instruction = "icmp"
		name = type_signed(e.c, info.element) ? predicate.signed : predicate.unsigned
	}
	bits := temp(e)
	fmt.sbprintfln(&e.b, "  %s = %s %s %s %s, %s", bits, instruction, name, llvm_type(e, vector), left, right)
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = zext <%d x i1> %s to <%d x i8>", out, info.count, bits, info.count)
	return out
}

// Any zero divisor lane faults the whole operation; signed `MIN / -1` and
// `MIN % -1` wrap as scalars do, via a safe divisor and a select.
@(private = "file")
emit_simd_divrem :: proc(
	e: ^Emitter, op: Token_Kind, vector: Type_Id, info: ^Type_Info, left, right: string,
) -> string {
	llvm := llvm_type(e, vector)
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
	safe := simd_select(e, info, llvm, overflow, simd_repeated(e, info, "1"), right)
	raw := temp(e)
	fmt.sbprintfln(&e.b, "  %s = %s %s %s, %s", raw, op == .Slash ? "sdiv" : "srem", llvm, left, safe)
	return simd_select(e, info, llvm, overflow, op == .Slash ? minimum : "zeroinitializer", raw)
}

// A count at or beyond the width gives the scalar result: zero, or the sign
// bit for an arithmetic right shift.
@(private = "file")
emit_simd_shift :: proc(
	e: ^Emitter, op: Token_Kind, vector: Type_Id, info: ^Type_Info, left, right: string,
) -> string {
	llvm := llvm_type(e, vector)
	bits := type_bits(e.c, info.element)
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

emit_simd_unary :: proc(e: ^Emitter, v: ^Expr_Unary, as_type: Type_Id) -> string {
	info := underlying_info(e.c, as_type)
	llvm := llvm_type(e, as_type)
	operand := emit_expr(e, v.operand)
	if v.op == .Plus {
		return operand
	}
	out := temp(e)
	if v.op != .Minus {
		fmt.sbprintfln(&e.b, "  %s = xor %s %s, %s", out, llvm, operand, simd_all_ones(e, info))
	} else if type_is_float(e.c, info.element) {
		fmt.sbprintfln(&e.b, "  %s = fneg %s %s", out, llvm, operand)
	} else {
		fmt.sbprintfln(&e.b, "  %s = sub %s zeroinitializer, %s", out, llvm, operand)
	}
	return out
}

// A vector constant with `lane` in every lane.
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
@(private = "file")
simd_all_ones :: proc(e: ^Emitter, info: ^Type_Info) -> string {
	return simd_repeated(e, info, simd_is_mask(e, info) ? "1" : "-1")
}

// True when any lane of an `<N x i1>` is.
simd_any_lane :: proc(e: ^Emitter, info: ^Type_Info, mask: string) -> string {
	return simd_call_reduce(e, "or", "i1", int(info.count), mask, "")
}

// Overloaded intrinsics are mangled by bit width, so `double` is `f64`.
@(private = "file")
simd_mangled_lane :: proc(lane: string) -> string {
	switch lane {
	case "half":   return "f16"
	case "float":  return "f32"
	case "double": return "f64"
	}
	return lane
}

// Calls `llvm.vector.reduce.<name>`, declaring it once. `start` is the
// `type value, ` prefix of an ordered float fold, or empty.
@(private = "file")
simd_call_reduce :: proc(e: ^Emitter, name, lane: string, count: int, value, start: string) -> string {
	key := fmt.aprintf("llvm.vector.reduce.%s.v%d%s", name, count, simd_mangled_lane(lane))
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

emit_simd_builtin :: proc(e: ^Emitter, v: ^Expr_Call, kind: Builtin_Kind, as_type: Type_Id) -> string {
	#partial switch kind {
	case .Simd_Cast:
		return emit_simd_cast(e, v, as_type)
	case .Simd_Select:
		return emit_simd_select(e, v, as_type)
	case .Simd_Reduce:
		return emit_simd_reduce(e, v)
	}
	backend_fail(e, "an unhandled SIMD built-in reached emission")
	return "0"
}

// `from_array`/`to_array`: the same bytes, stored and reloaded through the
// vector's over-aligned storage.
@(private = "file")
emit_simd_cast :: proc(e: ^Emitter, v: ^Expr_Call, as_type: Type_Id) -> string {
	source := expr_base(v.bound[0]).type
	vector := type_is_simd(e.c, source) ? source : as_type
	value := emit_expr(e, v.bound[0])
	slot := alloca(e, llvm_type(e, vector))
	store(e, source, value, slot)
	return load_place(e, as_type, slot)
}

@(private = "file")
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
@(private = "file")
emit_simd_reduce :: proc(e: ^Emitter, v: ^Expr_Call) -> string {
	info := underlying_info(e.c, expr_base(v.bound[0]).type)
	value := emit_expr(e, v.bound[0])
	lane := simd_lane_llvm_type(e, info)
	count := int(info.count)
	float := type_is_float(e.c, info.element)
	signed := type_signed(e.c, info.element)
	fold := v.operation.(Call_Simd_Reduce).fold

	name := ""
	switch fold {
	case .Add: name = float ? "fadd" : "add"
	case .Mul: name = float ? "fmul" : "mul"
	case .Min: name = float ? "fmin" : (signed ? "smin" : "umin")
	case .Max: name = float ? "fmax" : (signed ? "smax" : "umax")
	case .Any: name = "or"
	case .All: name = "and"
	}
	if fold == .Any || fold == .All {
		folded := simd_call_reduce(e, name, lane, count, value, "")
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = trunc i8 %s to i1", out, folded)
		return out
	}
	start := ""
	if float && (fold == .Add || fold == .Mul) {
		bits := u16(type_bits(e.c, info.element))
		start = fmt.aprintf("%s %s, ", lane, llvm_float(float_pattern(fold == .Add ? -0.0 : 1.0, bits), bits))
	}
	return simd_call_reduce(e, name, lane, count, value, start)
}

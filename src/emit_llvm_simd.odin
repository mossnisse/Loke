// Emitting `Simd(T, N)` (design.md "SIMD vectors").
//
// A vector lowers to LLVM's `<N x T>`, so every lane-wise operator is the
// scalar instruction applied to a vector operand — the whole point of the type.
// What needs writing here is the three places a vector is not simply the scalar
// path with a wider operand: the splat, the reduction of a lane-wise fault
// condition to one branch, and the `<N x i1>` an `icmp` hands back where
// design.md's lane mask is one byte per lane.
package lokec

import "core:fmt"

// The lane a splat repeats. An operand the checker left at the element type is
// a scalar being widened; one already at the vector type is not.
@(private = "file")
simd_operand :: proc(e: ^Emitter, value: string, written: Type_Id, vector: Type_Id) -> string {
	if type_underlying(e.c, written) == type_underlying(e.c, vector) {
		return value
	}
	return emit_simd_splat(e, value, vector)
}

// design.md: "A scalar converts to a vector implicitly wherever a vector is
// expected, producing the **splat** — every lane equal to that scalar."
emit_simd_splat :: proc(e: ^Emitter, value: string, vector: Type_Id) -> string {
	info := underlying_info(e.c, vector)
	llvm := llvm_type(e, vector)
	lane := simd_lane_llvm_type(e, info)
	scalar := simd_lane_value(e, value, info)
	one := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = insertelement %s poison, %s %s, i32 0", one, llvm, lane, scalar,
	)
	out := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = shufflevector %s %s, %s poison, <%d x i32> zeroinitializer",
		out, llvm, one, llvm, info.count,
	)
	return out
}

// A scalar `bool` is `i1` and a mask lane is `i8`, so a `bool` entering or
// leaving a lane changes width. Every other lane type is already its own.
@(private = "file")
simd_lane_value :: proc(e: ^Emitter, value: string, info: ^Type_Info) -> string {
	if type_kind(e.c, type_underlying(e.c, info.element)) != .Bool {
		return value
	}
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = zext i1 %s to i8", out, value)
	return out
}

// Lane access needs nothing here: a vector is an ordinary memory place, so
// `v[i]` and `v[i] = x` are the same address-of-element the array path emits,
// which LLVM defines for a vector in memory.

// The lane-wise arithmetic and bitwise operators.
emit_simd_binary :: proc(e: ^Emitter, v: ^Expr_Binary) -> string {
	vector := simd_binary_vector(e, v)
	info := underlying_info(e.c, vector)
	llvm := llvm_type(e, vector)
	left := simd_operand(e, emit_expr(e, v.lhs), expr_base(v.lhs).type, vector)
	right := simd_operand(e, emit_expr(e, v.rhs), expr_base(v.rhs).type, vector)

	#partial switch v.op {
	case .Eq_Eq, .Not_Eq, .Lt, .Lt_Eq, .Gt, .Gt_Eq:
		return emit_simd_compare(e, v.op, vector, info, left, right)
	case .Slash, .Percent:
		if !type_is_float(e.c, info.element) {
			return emit_simd_divrem(e, v.op, vector, info, left, right)
		}
	case .Shl, .Shr:
		return emit_simd_shift(e, v.op, vector, info, left, right)
	case .Amp_Tilde:
		complement := temp(e)
		fmt.sbprintfln(&e.b, "  %s = xor %s %s, %s", complement, llvm, right, simd_all_ones(e, info))
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = and %s %s, %s", out, llvm, left, complement)
		return out
	}
	mnemonic := simd_mnemonic(v.op, type_is_float(e.c, info.element))
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = %s %s %s, %s", out, mnemonic, llvm, left, right)
	return out
}

// The vector type both operands take. One side may have been left at the lane
// type by the checker, which is how it records a splat.
@(private = "file")
simd_binary_vector :: proc(e: ^Emitter, v: ^Expr_Binary) -> Type_Id {
	left := expr_base(v.lhs).type
	return type_is_simd(e.c, left) ? left : expr_base(v.rhs).type
}

@(private = "file")
simd_mnemonic :: proc(op: Token_Kind, float: bool) -> string {
	#partial switch op {
	case .Plus:  return float ? "fadd" : "add"
	case .Minus: return float ? "fsub" : "sub"
	case .Star:  return float ? "fmul" : "mul"
	case .Slash: return "fdiv"
	case .Amp:   return "and"
	case .Pipe:  return "or"
	case .Tilde: return "xor"
	}
	return "add"
}

// design.md: "a comparison yields a lane mask", which is `Simd(bool, N)` —
// one byte per lane, so the `<N x i1>` an `icmp` produces is widened.
@(private = "file")
emit_simd_compare :: proc(
	e: ^Emitter, op: Token_Kind, vector: Type_Id, info: ^Type_Info, left, right: string,
) -> string {
	predicate := compare_predicate(op)
	name := predicate.float
	instruction := "fcmp"
	if !type_is_float(e.c, info.element) {
		instruction = "icmp"
		// A `bool` lane is unsigned by construction, and only equality reaches it.
		name = type_signed(e.c, info.element) ? predicate.signed : predicate.unsigned
	}
	bits := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = %s %s %s %s, %s", bits, instruction, name, llvm_type(e, vector), left, right,
	)
	out := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = zext <%d x i1> %s to <%d x i8>", out, info.count, bits, info.count,
	)
	return out
}

// design.md: "Integer division or remainder by a zero lane is the same program
// fault it is for a scalar, and any zero divisor lane faults the whole
// operation. Signed `MIN / -1` and `MIN % -1` have the same wrapping results
// scalars give."
//
// Both are lane-wise conditions: the fault reduces to one branch because a
// panic is not lane-wise, and the wrap selects a safe divisor and then selects
// the answer back, which keeps the operation itself branchless.
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
		fmt.sbprintfln(
			&e.b, "  %s = %s %s %s, %s", out, op == .Slash ? "udiv" : "urem", llvm, left, right,
		)
		return out
	}

	bits := type_bits(e.c, info.element)
	minimum := simd_repeated(e, info, bi_text(e.c, bi_neg(e.c, bi_pow2(e.c, bits - 1))))
	is_min, is_neg_one, overflow := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, %s", is_min, llvm, left, minimum)
	fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, %s", is_neg_one, llvm, right, simd_all_ones(e, info))
	fmt.sbprintfln(&e.b, "  %s = and <%d x i1> %s, %s", overflow, info.count, is_min, is_neg_one)

	// A divisor of 1 leaves the lane's own value where the overflow select then
	// replaces it, so no lane reaches `sdiv` with the poison pair.
	safe := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = select <%d x i1> %s, %s %s, %s %s",
		safe, info.count, overflow, llvm, simd_repeated(e, info, "1"), llvm, right,
	)
	raw := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = %s %s %s, %s", raw, op == .Slash ? "sdiv" : "srem", llvm, left, safe,
	)
	// `MIN / -1` wraps to `MIN`; `MIN % -1` is 0.
	wrapped := op == .Slash ? minimum : "zeroinitializer"
	out := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = select <%d x i1> %s, %s %s, %s %s",
		out, info.count, overflow, llvm, wrapped, llvm, raw,
	)
	return out
}

// design.md: "A shift count at or beyond the element's width is defined exactly
// as it is for a scalar — the limit of the repeated one-bit shift". The scalar
// emitter says the same thing with selects; here they are lane-wise.
@(private = "file")
emit_simd_shift :: proc(
	e: ^Emitter, op: Token_Kind, vector: Type_Id, info: ^Type_Info, left, right: string,
) -> string {
	llvm := llvm_type(e, vector)
	bits := type_bits(e.c, info.element)

	oversized := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = icmp uge %s %s, %s",
		oversized, llvm, right, simd_repeated(e, info, fmt.aprintf("%d", bits)),
	)
	if op == .Shr && type_signed(e.c, info.element) {
		// Clamping to width-1 is the limit of the repeated one-bit shift, and the
		// sign bit is what it replicates.
		clamped := temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = select <%d x i1> %s, %s %s, %s %s",
			clamped, info.count, oversized, llvm,
			simd_repeated(e, info, fmt.aprintf("%d", bits - 1)), llvm, right,
		)
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = ashr %s %s, %s", out, llvm, left, clamped)
		return out
	}
	safe := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = select <%d x i1> %s, %s zeroinitializer, %s %s",
		safe, info.count, oversized, llvm, llvm, right,
	)
	raw := temp(e)
	fmt.sbprintfln(&e.b, "  %s = %s %s %s, %s", raw, op == .Shl ? "shl" : "lshr", llvm, left, safe)
	out := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = select <%d x i1> %s, %s zeroinitializer, %s %s",
		out, info.count, oversized, llvm, llvm, raw,
	)
	return out
}

// `-v` and `~v`. LLVM has no vector complement, so it is the exclusive-or the
// scalar emitter would also produce.
emit_simd_unary :: proc(e: ^Emitter, v: ^Expr_Unary, as_type: Type_Id) -> string {
	info := underlying_info(e.c, as_type)
	llvm := llvm_type(e, as_type)
	operand := emit_expr(e, v.operand)
	if v.op == .Plus {
		return operand
	}
	out := temp(e)
	if v.op == .Minus {
		if type_is_float(e.c, info.element) {
			fmt.sbprintfln(&e.b, "  %s = fneg %s %s", out, llvm, operand)
		} else {
			fmt.sbprintfln(&e.b, "  %s = sub %s zeroinitializer, %s", out, llvm, operand)
		}
		return out
	}
	fmt.sbprintfln(&e.b, "  %s = xor %s %s, %s", out, llvm, operand, simd_all_ones(e, info))
	return out
}

// A vector constant with the same value in every lane, written inline.
@(private = "file")
simd_repeated :: proc(e: ^Emitter, info: ^Type_Info, lane: string) -> string {
	llvm := simd_lane_llvm_type(e, info)
	out := "<"
	for index in 0 ..< int(info.count) {
		out = fmt.aprintf("%s%s %s %s", out, index == 0 ? "" : ",", llvm, lane)
	}
	return fmt.aprintf("%s>", out)
}

// The complement's mask. A lane mask holds 0 or 1 in each byte and must keep
// doing so — `~` over all-ones would leave 254 in a false lane, which reads
// back as false at one optimization level and as true at another once the
// optimizer canonicalises the byte to an `i1`.
@(private = "file")
simd_all_ones :: proc(e: ^Emitter, info: ^Type_Info) -> string {
	if type_kind(e.c, type_underlying(e.c, info.element)) == .Bool {
		return simd_repeated(e, info, "1")
	}
	return simd_repeated(e, info, "-1")
}

// One `i1` from a lane-wise predicate: true when any lane is. A panic is not
// lane-wise, so a lane-wise fault condition has to reduce before it can branch.
@(private = "file")
simd_any_lane :: proc(e: ^Emitter, info: ^Type_Info, mask: string) -> string {
	simd_declare_reduce(e, "or", "i1", int(info.count), "i1")
	out := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call i1 @llvm.vector.reduce.or.v%di1(<%d x i1> %s)",
		out, info.count, info.count, mask,
	)
	return out
}

// One `declare` per reduction intrinsic the module actually uses. `result` is
// the scalar it folds to, which is the lane type for every reduction except a
// float `add`/`mul`, whose LLVM form takes a starting value.
simd_declare_reduce :: proc(e: ^Emitter, name: string, lane: string, count: int, result: string) {
	simd_declare_reduce_with_start(e, name, lane, count, result, false)
}

simd_declare_reduce_with_start :: proc(
	e: ^Emitter, name, lane: string, count: int, result: string, start: bool,
) {
	key := fmt.aprintf("llvm.vector.reduce.%s.v%d%s", name, count, lane)
	if key in e.simd_intrinsics {
		return
	}
	e.simd_intrinsics[key] = true
	leading := start ? fmt.aprintf("%s, ", result) : ""
	append(&e.globals, fmt.aprintf("declare %s @%s(%s<%d x %s>)\n", result, key, leading, count, lane))
}

// ------------------------------------------------------- `core:simd` --

// The three `core:simd` intrinsics. Each is one LLVM instruction or intrinsic
// call — which is the reason they are built in rather than library code.
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

// A vector and an array of the same lanes have the same bytes in memory, so
// the conversion is a store and a reload at the other type. A vector is
// over-aligned relative to the array, so the vector's storage is what both use.
@(private = "file")
emit_simd_cast :: proc(e: ^Emitter, v: ^Expr_Call, as_type: Type_Id) -> string {
	source := expr_base(v.bound[0]).type
	vector := type_is_simd(e.c, source) ? source : as_type
	value := emit_expr(e, v.bound[0])
	slot := alloca(e, llvm_type(e, vector))
	fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", llvm_type(e, source), value, slot)
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", out, llvm_type(e, as_type), slot)
	return out
}

// `select(mask, a, b)`: LLVM's own vector select, whose condition is `<N x i1>`
// where a lane mask is `<N x i8>`.
@(private = "file")
emit_simd_select :: proc(e: ^Emitter, v: ^Expr_Call, as_type: Type_Id) -> string {
	info := underlying_info(e.c, as_type)
	mask := emit_expr(e, v.bound[0])
	left := emit_expr(e, v.bound[1])
	right := emit_expr(e, v.bound[2])
	bits := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = trunc <%d x i8> %s to <%d x i1>", bits, info.count, mask, info.count,
	)
	llvm := llvm_type(e, as_type)
	out := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = select <%d x i1> %s, %s %s, %s %s",
		out, info.count, bits, llvm, left, llvm, right,
	)
	return out
}

// The folds, each an `llvm.vector.reduce.*`. The float `add` and `mul` forms
// take a starting value, which is what makes them ordered rather than
// tree-shaped — design.md requires the ordered form so a result does not depend
// on the target's vector width.
@(private = "file")
emit_simd_reduce :: proc(e: ^Emitter, v: ^Expr_Call) -> string {
	vector := expr_base(v.bound[0]).type
	info := underlying_info(e.c, vector)
	value := emit_expr(e, v.bound[0])
	lane := simd_lane_llvm_type(e, info)
	count := int(info.count)
	float := type_is_float(e.c, info.element)
	signed := type_signed(e.c, info.element)

	name := ""
	switch v.simd_fold {
	case .Add: name = float ? "fadd" : "add"
	case .Mul: name = float ? "fmul" : "mul"
	case .Min: name = float ? "fmin" : (signed ? "smin" : "umin")
	case .Max: name = float ? "fmax" : (signed ? "smax" : "umax")
	case .Any: name = "or"
	case .All: name = "and"
	}

	// The `i8` lane a mask stores is reduced as itself, then narrowed: `or`
	// answers "any lane set" and `and` answers "every lane set".
	if v.simd_fold == .Any || v.simd_fold == .All {
		folded := simd_call_reduce(e, name, lane, count, lane, value, "")
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = trunc i8 %s to i1", out, folded)
		return out
	}
	// design.md: the floating-point reductions are ordered, left to right. LLVM
	// spells that as the starting-value form, whose identity is the neutral
	// element of the fold.
	start := ""
	if float && (v.simd_fold == .Add || v.simd_fold == .Mul) {
		start = fmt.aprintf(
			"%s %s, ", lane, llvm_float(float_pattern(v.simd_fold == .Add ? 0 : 1, u16(type_bits(e.c, info.element))), u16(type_bits(e.c, info.element))),
		)
	}
	return simd_call_reduce(e, name, lane, count, lane, value, start)
}

@(private = "file")
simd_call_reduce :: proc(
	e: ^Emitter, name, lane: string, count: int, result: string, value: string, start: string,
) -> string {
	simd_declare_reduce_with_start(e, name, lane, count, result, start != "")
	out := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call %s @llvm.vector.reduce.%s.v%d%s(%s<%d x %s> %s)",
		out, result, name, count, lane, start, count, lane, value,
	)
	return out
}

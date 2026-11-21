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
		scalar = emit_value(e, "zext i1 %s to i8", value)
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
			return emit_divrem(e, op, lane_int_form(e, info, llvm), left, right)
		}
	case .Shl, .Shr:
		form := lane_int_form(e, info, llvm)
		return emit_shift(e, op, form, form, left, right)
	case .Amp_Tilde:
		complement := emit_value(e, "xor %s %s, %s", llvm, right, simd_all_ones(e, info))
		right = complement
	}
	mnemonics := arith_mnemonic(op == .Amp_Tilde ? .Amp : op)
	mnemonic := float ? mnemonics.float : mnemonics.integer
	if mnemonic == "" {
		backend_fail(e, "an unhandled SIMD operator reached emission")
		return "zeroinitializer"
	}
	return emit_value(e, "%s %s %s, %s", mnemonic, llvm, left, right)
}

// design.md "Lane-wise operators": a lane that overflows panics the whole
// operation, as the scalar operator would.
emit_simd_checked :: proc(e: ^Emitter, op: Token_Kind, info: ^Type_Info, llvm, left, right: string) -> string {
	signed := type_signed(e.c, info.element)
	key := checked_intrinsic(op, signed, fmt.aprintf("v%d%s", info.count, simd_lane_llvm_type(e, info)))
	flag := fmt.aprintf("<%d x i1>", info.count)
	wrapped, overflowed := emit_overflow_call(e, key, llvm, flag, left, right)
	panic_if(e, simd_any_lane(e, info, overflowed), "int.overflow", overflow_message(signed))
	return wrapped
}

@(private = "file")
emit_simd_compare :: proc(e: ^Emitter, op: Token_Kind, info: ^Type_Info, llvm, left, right: string) -> string {
	bits := emit_value(e, "%s %s %s, %s", compare_instruction(e, op, info.element), llvm, left, right)
	return emit_value(e, "zext <%d x i1> %s to <%d x i8>", info.count, bits, info.count)
}

@(private)
lane_int_form :: proc(e: ^Emitter, info: ^Type_Info, llvm: string) -> Int_Form {
	return Int_Form {
		llvm = llvm,
		mask = fmt.aprintf("<%d x i1>", info.count),
		bits = type_bits(e.c, info.element),
		signed = type_signed(e.c, info.element),
		lanes = info,
	}
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
	leading := start != "" ? fmt.aprintf("%s, ", lane) : ""
	declare_intrinsic(e, key, lane, fmt.aprintf("%s<%d x %s>", leading, count, lane))
	return emit_value(e, "call %s @%s(%s<%d x %s> %s)", lane, key, start, count, lane, value)
}

// ------------------------------------------------------- `core:simd` --

emit_simd_select :: proc(e: ^Emitter, v: ^Expr_Call, as_type: Type_Id) -> string {
	info := underlying_info(e.c, as_type)
	mask := emit_expr(e, v.bound[0])
	left := emit_expr(e, v.bound[1])
	right := emit_expr(e, v.bound[2])
	bits := simd_mask_bits(e, int(info.count), mask)
	llvm := llvm_type(e, as_type)
	return emit_value(e, "select <%d x i1> %s, %s %s, %s %s", info.count, bits, llvm, left, llvm, right)
}

// A mask's `i8` lanes as the `i1` lanes `select` and the reductions take.
@(private = "file")
simd_mask_bits :: proc(e: ^Emitter, count: int, mask: string) -> string {
	return emit_value(e, "trunc <%d x i8> %s to <%d x i1>", count, mask, count)
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
		return simd_call_reduce(e, fold == .Any ? "or" : "and", "i1", count, simd_mask_bits(e, count, value), "")
	case .Add, .Mul:
		bits := type_bits(e.c, info.element)
		if fold == .Add && !float && !signed && bits <= 16 {
			return emit_simd_widened_sum(e, lane, bits, count, value)
		}
		if !float {
			return emit_simd_checked_fold(e, fold == .Add ? .Plus : .Star, signed, lane, count, value)
		}
		start := fmt.aprintf("%s %s, ", lane, llvm_float(float_pattern(fold == .Add ? -0.0 : 1.0, u16(bits)), u16(bits)))
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
		element := emit_value(e, "extractelement <%d x %s> %s, i32 %d", count, lane, vector, index)
		result = index == 0 ? element : emit_checked_integer(e, op, signed, lane, result, element)
	}
	return result
}

// Every prefix of an unsigned sum is at most its total, so checking the total
// once panics exactly where the left-to-right fold would. At twice the lane
// width the sum is exact: at most 64 lanes (design.md "Element types and lane
// counts") cannot carry past it. Measured for 8- and 16-bit lanes only.
@(private = "file")
emit_simd_widened_sum :: proc(e: ^Emitter, lane: string, bits, count: int, vector: string) -> string {
	wide := fmt.aprintf("i%d", bits * 2)
	widened := emit_value(e, "zext <%d x %s> %s to <%d x %s>", count, lane, vector, count, wide)
	total := simd_call_reduce(e, "add", wide, count, widened, "")
	overflowed := emit_value(e, "icmp ugt %s %s, %d", wide, total, (1 << uint(bits)) - 1)
	panic_if(e, overflowed, "int.overflow", overflow_message(false))
	return emit_value(e, "trunc %s %s to %s", wide, total, lane)
}

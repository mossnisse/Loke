// The `core:math` bit and floating-point instruction built-ins.
package lokec

import "core:fmt"

// A one-operand intrinsic `key`, declared over the operand's own LLVM type.
@(private = "file")
emit_unary_intrinsic :: proc(e: ^Emitter, v: ^Expr_Call, key: string) -> string {
	llvm := llvm_type(e, expr_base(v.bound[0]).type)
	declare_intrinsic(e, key, llvm, llvm)
	operand := emit_expr(e, v.bound[0])
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = call %s @%s(%s %s)", out, llvm, key, llvm, operand)
	return out
}

// `llvm.ctlz` or `llvm.cttz` (`name`) of the operand, in the operand's own type.
// The zero-operand flag is false, so a zero operand counts as its width rather
// than as poison.
@(private = "file")
emit_zero_count :: proc(e: ^Emitter, name, llvm, operand: string) -> string {
	key := fmt.aprintf("llvm.%s.%s", name, llvm)
	declare_intrinsic(e, key, llvm, fmt.aprintf("%s, i1", llvm))
	count := temp(e)
	fmt.sbprintfln(&e.b, "  %s = call %s @%s(%s %s, i1 false)", count, llvm, key, llvm, operand)
	return count
}

// `llvm.ctpop`, `llvm.ctlz`, or `llvm.cttz` (`name`) of an integer operand,
// widened or narrowed to the `int` result.
@(private)
emit_bit_count :: proc(e: ^Emitter, v: ^Expr_Call, name: string) -> string {
	source := expr_base(v.bound[0]).type
	llvm := llvm_type(e, source)
	count := name == "ctpop" \
		? emit_unary_intrinsic(e, v, fmt.aprintf("llvm.ctpop.%s", llvm)) \
		: emit_zero_count(e, name, llvm, emit_expr(e, v.bound[0]))
	return resize_int(e, count, type_bits(e.c, source), type_bits(e.c, TYPE_INT), signed = false)
}

// The width less the leading zeros, which a zero operand makes the width, so
// the bit width of zero is zero. The count is at most 128, so subtracting it
// as an `int` keeps every result.
@(private)
emit_bit_width :: proc(e: ^Emitter, v: ^Expr_Call) -> string {
	leading := emit_bit_count(e, v, "ctlz")
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = sub %s %d, %s", out, llvm_type(e, TYPE_INT), type_bits(e.c, expr_base(v.bound[0]).type), leading)
	return out
}

// `llvm.bitreverse`. No x86-64 CPU level has an instruction for it, so LLVM
// expands it to a byte swap and shift-and-mask steps, never a loop.
@(private)
emit_reverse_bits :: proc(e: ^Emitter, v: ^Expr_Call) -> string {
	return emit_unary_intrinsic(e, v, fmt.aprintf("llvm.bitreverse.%s", llvm_type(e, expr_base(v.bound[0]).type)))
}

// A positive value with no bit below its highest: `x > 0` and `x & (x - 1)`
// zero, which reads the value, so a signed minimum, one set bit but negative,
// is not a power of two. `x - 1` may wrap, but only where `x > 0` is false.
@(private)
emit_is_power_of_two :: proc(e: ^Emitter, v: ^Expr_Call) -> string {
	source := expr_base(v.bound[0]).type
	llvm := llvm_type(e, source)
	x := emit_expr(e, v.bound[0])
	positive := emit_value(e, "icmp %s %s %s, 0", type_signed(e.c, source) ? "sgt" : "ugt", llvm, x)
	below := emit_value(e, "sub %s %s, 1", llvm, x)
	rest := emit_value(e, "and %s %s, %s", llvm, x, below)
	return combine_and(e, positive, icmp_zero(e, llvm, rest))
}

// design.md "Integer overflow": `1 << (W - ctlz(x - 1))` for `x > 1`, and 1
// for every smaller value, whose exponent is selected to 0 before the check.
// An exponent of `W` (unsigned) or `W - 1` (signed) does not fit and panics as
// checked arithmetic does, so the shift that remains is always in range. The
// checked form makes that test the option's presence instead, and shifts by a
// zero exponent where it fails, so that no shift is poison.
@(private)
emit_next_power_of_two :: proc(e: ^Emitter, v: ^Expr_Call, as_type: Type_Id, checked: bool) -> string {
	source := expr_base(v.bound[0]).type
	llvm := llvm_type(e, source)
	bits := type_bits(e.c, source)
	signed := type_signed(e.c, source)
	x := emit_expr(e, v.bound[0])
	small, below := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp %s %s %s, 1", small, signed ? "sle" : "ule", llvm, x)
	fmt.sbprintfln(&e.b, "  %s = sub %s %s, 1", below, llvm, x)
	leading := emit_zero_count(e, "ctlz", llvm, below)
	needed, exponent, overflowed := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = sub %s %d, %s", needed, llvm, bits, leading)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, %s 0, %s %s", exponent, small, llvm, llvm, needed)
	fmt.sbprintfln(&e.b, "  %s = icmp uge %s %s, %d", overflowed, llvm, exponent, signed ? bits - 1 : bits)
	if !checked {
		panic_if(e, overflowed, "int.overflow", overflow_message(signed))
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = shl %s 1, %s", out, llvm, exponent)
		return out
	}
	shift := emit_value(e, "select i1 %s, %s 0, %s %s", overflowed, llvm, llvm, exponent)
	power := emit_value(e, "shl %s 1, %s", llvm, shift)
	return emit_option_value(e, as_type, not_i1(e, overflowed), power)
}

// `llvm.fshl` or `llvm.fshr` (`name`) with the operand as both halves, which
// rotates it. The funnel shift takes its amount modulo the width, a power of
// two, so the `int` count's low bits are all it needs, and `trunc` or `zext`
// keeps them: the floored remainder the specification gives a negative count.
@(private)
emit_rotate :: proc(e: ^Emitter, v: ^Expr_Call, name: string) -> string {
	source := expr_base(v.bound[0]).type
	llvm := llvm_type(e, source)
	key := fmt.aprintf("llvm.%s.%s", name, llvm)
	declare_intrinsic(e, key, llvm, fmt.aprintf("%s, %s, %s", llvm, llvm, llvm))
	value := emit_expr(e, v.bound[0])
	count := emit_expr(e, v.bound[1])
	count = resize_int(e, count, type_bits(e.c, TYPE_INT), type_bits(e.c, source), signed = false)
	return emit_value(e, "call %s @%s(%s %s, %s %s, %s %s)", llvm, key, llvm, value, llvm, value, llvm, count)
}

// `core:math` calls this only behind `fma_is_instruction()`; on a target without
// FMA the call is unreachable, so it traps.
@(private)
emit_fma_instruction :: proc(e: ^Emitter, v: ^Expr_Call) -> string {
	llvm := llvm_type(e, expr_base(v.bound[0]).type)
	if !emitted_has_fma(e) {
		declare_intrinsic(e, "llvm.trap", "void", "")
		fmt.sbprintln(&e.b, "  call void @llvm.trap()")
		emit_unreachable(e)
		place_label(e, new_label(e, "unreachable"))
		return "poison"
	}
	key := fmt.aprintf("llvm.fma.%s", intrinsic_type_suffix(llvm))
	declare_intrinsic(e, key, llvm, fmt.aprintf("%s, %s, %s", llvm, llvm, llvm))
	a, b, c := emit_expr(e, v.bound[0]), emit_expr(e, v.bound[1]), emit_expr(e, v.bound[2])
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = call %s @%s(%s %s, %s %s, %s %s)", out, llvm, key, llvm, a, llvm, b, llvm, c)
	return out
}

// `llvm.sqrt` is the instruction on every x86-64 level, correctly rounded as
// IEEE 754 requires. `llvm.floor`, `ceil`, `trunc`, and `round` are SSE4.1's
// `roundsd` and `roundss` from `x86-64-v2`, and below it the C library's
// functions of those names; the result is exact either way.
@(private)
emit_float_instruction :: proc(e: ^Emitter, v: ^Expr_Call, name: string) -> string {
	suffix := intrinsic_type_suffix(llvm_type(e, expr_base(v.bound[0]).type))
	return emit_unary_intrinsic(e, v, fmt.aprintf("llvm.%s.%s", name, suffix))
}

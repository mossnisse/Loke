// Exact float operations on constants: rounding to a width, the compile-time
// values of the `core:math` instructions, and the IEEE-754 encodings.
package lokec

import "base:intrinsics"
import "core:math"

// design.md "Type conversion": the bounds of a float-to-integer conversion are
// powers of two, so one interval serves every float width — the value is exact
// in any format that can hold it and an infinity in one that cannot.
power_of_two :: proc(exponent: int) -> f64 {
	return math.ldexp(f64(1), exponent)
}

// A typed float operation rounds to its own width after every step: folding an
// `f32` expression in `f64` and rounding once at the end can disagree with what
// the same expression computes at runtime.
round_float :: proc(value: f64, bits: u16) -> f64 {
	switch bits {
	case 16:
		return f16_bits_to_f64(f64_to_f16_bits(value))
	case 32:
		return f64(f32(value))
	}
	return value
}

// `a*b + c` rounded once to `bits` (32 or 64), the compile-time value of the
// FMA instruction `core:math` uses. Computed exactly in integers, so it owes
// nothing to the compiling machine's arithmetic beyond the special cases.
exact_fma :: proc(storage: Value_Storage, a, b, c: f64, bits: u16) -> f64 {
	finite :: proc(x: f64) -> bool { return !math.is_nan(x) && !math.is_inf(x, 0) }
	if !finite(a) || !finite(b) || a == 0 || b == 0 {
		// The product is exact: an infinity, a NaN, or a signed zero.
		return round_float(a*b + c, bits)
	}
	if !finite(c) {
		// A finite product never overflows on its way to the sum.
		return c
	}
	x, y, z := dyadic_of(storage, a), dyadic_of(storage, b), dyadic_of(storage, c)
	product := Dyadic{bi_mul(storage, x.significand, y.significand), x.exponent + y.exponent}
	exponent := min(product.exponent, z.exponent)
	sum := bi_add(
		storage,
		bi_shl(storage, product.significand, product.exponent - exponent),
		bi_shl(storage, z.significand, z.exponent - exponent),
	)
	return dyadic_to_float(storage, sum, exponent, bits)
}

// The square root of `x`, an `f32` or `f64` constant, rounded once to its
// width: the compile-time value of the instruction `core:math.sqrt` is, which
// IEEE 754 makes correctly rounded. Computed exactly in integers. A NaN result
// is the x86-64 instruction's, the operand quieted or, below zero, the default
// NaN, which is negative; nothing promises it.
exact_sqrt :: proc(x: Const_Value) -> Const_Value {
	bits := x.float_bits
	if math.is_nan(x.float) {
		return quieted(x)
	}
	if x.float == 0 || math.is_inf(x.float, 1) {
		return x
	}
	if x.float < 0 {
		return default_nan(bits)
	}
	// An `f32` operand is exact as an `f64`, and narrowing its `f64` root rounds
	// correctly: rounding twice is innocuous for a square root when the wider
	// format has at least 2p + 2 bits for the narrower's p, here 53 >= 50
	// (Figueroa, "When is double rounding innocuous?", 1995).
	return float_const(sqrt_rounded(x.float), bits)
}

// `x` rounded to an integral value as `builtin` does: the compile-time
// `core:math.floor`, `ceil`, `trunc`, `round`. Exact, and an `f32`'s integral
// value is an `f32`, so the `f64` procedures serve both. A NaN gives the operand
// quieted; nothing promises it.
exact_integral :: proc(x: Const_Value, builtin: Builtin_Kind) -> Const_Value {
	bits := x.float_bits
	if math.is_nan(x.float) {
		return quieted(x)
	}
	#partial switch builtin {
	case .Math_Floor_Instruction:
		return float_const(math.floor(x.float), bits)
	case .Math_Ceil_Instruction:
		return float_const(math.ceil(x.float), bits)
	case .Math_Round_Instruction:
		return float_const(math.round(x.float), bits)
	}
	return float_const(math.trunc(x.float), bits)
}

// `x mod y` with `x`'s sign: the compile-time `core:math.mod`. C's `fmod` is
// exact too, so they differ only in which NaN, which nothing promises. An `f32`
// remainder is exact as an `f64`, so the `f64` one serves both.
exact_mod :: proc(x, y: Const_Value) -> Const_Value {
	if math.is_nan(x.float) {
		return quieted(x)
	}
	if math.is_nan(y.float) {
		return quieted(y)
	}
	if math.is_inf(x.float) || y.float == 0 {
		return default_nan(x.float_bits)
	}
	if math.is_inf(y.float) {
		return x
	}
	return float_const(remainder_exact(x.float, y.float), x.float_bits)
}

// An `f32` or `f64` NaN constant with its quiet bit set.
@(private = "file")
quieted :: proc(x: Const_Value) -> Const_Value {
	return float_bits_const(x.float_raw | (x.float_bits == 32 ? 1 << 22 : 1 << 51), x.float_bits)
}

// The NaN an x86-64 instruction answers for an invalid operand.
@(private = "file")
default_nan :: proc(bits: u16) -> Const_Value {
	return float_bits_const(bits == 32 ? 0xffc00000 : 0xfff8000000000000, bits)
}

// With x = m_x 2^e_x and y = m_y 2^e_y, both significands normalized to 53
// bits, the remainder of m_x 2^(e_x - e_y) by m_y, reduced 64 bits of the gap
// at a time in `u128`, is r < m_y, and r 2^e_y is the result: a multiple of
// the smallest subnormal, as x and y are, and under |y|, so representable.
@(private = "file")
remainder_exact :: proc(x, y: f64) -> f64 {
	SIGN :: u64(1) << 63
	a, b := transmute(u64)x, transmute(u64)y
	sign := a & SIGN
	ax, ay := a &~ SIGN, b &~ SIGN
	if ax < ay {
		return x
	}
	if ax == ay {
		return transmute(f64)sign
	}
	mx, ex := normalized_significand(ax)
	my, ey := normalized_significand(ay)
	r := u128(mx % my)
	for ex > ey {
		shift := min(ex - ey, 64)
		r = (r << uint(shift)) % u128(my)
		ex -= shift
	}
	if r == 0 {
		return transmute(f64)sign
	}
	// r 2^ey with r normalized to 53 bits, and its biased exponent.
	top := 128 - int(intrinsics.count_leading_zeros(r))
	significand := u64(r) << uint(53 - top)
	biased := ey - (53 - top) + 1023 + 52
	if biased >= 1 {
		return transmute(f64)(sign | (u64(biased - 1) << 52 + significand))
	}
	// A subnormal result: the shift drops only zero bits.
	return transmute(f64)(sign | significand >> uint(1 - biased))
}

// A positive finite magnitude's significand with its top bit at bit 52, and
// the exponent that keeps its value.
@(private = "file")
normalized_significand :: proc(magnitude: u64) -> (significand: u64, exponent: int) {
	field := int(magnitude >> 52)
	if field != 0 {
		return magnitude & (1 << 52 - 1) | 1 << 52, field - 1075
	}
	shift := int(intrinsics.count_leading_zeros(magnitude)) - 11
	return magnitude << uint(shift), -1074 - shift
}

// For a positive finite x = M 2^E, M an integer shifted into [2^52, 2^54) with
// E even, sqrt x is sqrt(N) 2^((E - 52)/2) for the integer N = M 2^52, so the
// result's significand is sqrt N rounded to an integer. With q = floor(sqrt N),
// found a bit at a time, that is q + 1 exactly when N - q^2 > q, and never a
// tie, since (q + 1/2)^2 is not an integer. It carries to 2^53 at most.
@(private = "file")
sqrt_rounded :: proc(x: f64) -> f64 {
	m, e := normalized_significand(transmute(u64)x)
	if e & 1 != 0 {
		m <<= 1
		e -= 1
	}
	n := u128(m) << 52
	q: u128 = 0
	for bit := u128(1) << 52; bit != 0; bit >>= 1 {
		if (q | bit) * (q | bit) <= n {
			q |= bit
		}
	}
	if n - q * q > q {
		q += 1
	}
	biased := (e - 52) / 2 + 52 + 1023
	if q == 1 << 53 {
		q >>= 1
		biased += 1
	}
	return transmute(f64)(u64(biased) << 52 | (u64(q) - 1 << 52))
}

// `significand * 2^exponent`, exactly.
@(private = "file")
Dyadic :: struct {
	significand: Big_Int,
	exponent:    int,
}

// A finite `f64`, which also holds every narrower float exactly.
@(private = "file")
dyadic_of :: proc(storage: Value_Storage, value: f64) -> Dyadic {
	pattern := transmute(u64)value
	biased := int(pattern >> 52) & 0x7ff
	fraction := pattern & (1 << 52 - 1)
	result := Dyadic{exponent = -1074}
	if biased != 0 {
		fraction |= 1 << 52
		result.exponent = biased - 1075
	}
	result.significand = bi_from_u64(storage, fraction)
	if value < 0 {
		result.significand = bi_neg(storage, result.significand)
	}
	return result
}

// The nearest float of `bits` width to `n * 2^exponent`, ties to even, with
// gradual underflow; an exact zero is `+0`. The rounding happens once, at the
// result's own last place, so a subnormal is not rounded twice.
@(private = "file")
dyadic_to_float :: proc(storage: Value_Storage, n: Big_Int, exponent: int, bits: u16) -> f64 {
	if bi_is_zero(n) {
		return 0
	}
	precision, min_exponent := 53, -1022
	switch bits {
	case 16: precision, min_exponent = 11, -14
	case 32: precision, min_exponent = 24, -126
	}
	negative := bi_sign(n) < 0
	magnitude := negative ? bi_neg(storage, n) : n
	leading := bi_magnitude_bits(storage, magnitude) - 1 + exponent
	// The exponent of the result's last place: `precision` bits below its
	// leading one, and never below the smallest subnormal's.
	unit := max(leading, min_exponent) - (precision - 1)
	shift := unit - exponent
	kept: u64
	if shift <= 0 {
		kept, _ = bi_to_u64(storage, bi_shl(storage, magnitude, -shift))
	} else {
		top := bi_shr(storage, magnitude, shift)
		kept, _ = bi_to_u64(storage, top)
		order := bi_cmp(storage, bi_sub(storage, magnitude, bi_shl(storage, top, shift)), bi_pow2(storage, shift - 1))
		if order > 0 || (order == 0 && kept & 1 == 1) {
			kept += 1
		}
	}
	// Exact in `f64`, which holds every narrower format's values and range, so
	// only an overflow changes it: to the infinity rounding to nearest gives.
	result := round_float(math.ldexp(f64(kept), unit), bits)
	return negative ? -result : result
}

// The IEEE-754 encoding of a value already rounded to `bits`, and its inverse.
float_pattern :: proc(value: f64, bits: u16) -> u64 {
	switch bits {
	case 16:
		return u64(f64_to_f16_bits(value))
	case 32:
		return u64(transmute(u32)f32(value))
	}
	return transmute(u64)value
}

float_from_pattern :: proc(raw: u64, bits: u16) -> f64 {
	switch bits {
	case 16:
		return f16_bits_to_f64(u16(raw))
	case 32:
		return f64(transmute(f32)u32(raw))
	}
	return transmute(f64)raw
}

// A Float carries the exact pattern of the width it was rounded to; any other
// width re-encodes from the numeric field.
const_float_pattern :: proc(value: Const_Value, bits: u16) -> u64 {
	if value.float_bits == bits {
		return value.float_raw
	}
	return float_pattern(value.float, bits)
}

// IEEE-754 binary16, rounding to nearest with ties to even. Odin's own `f16(x)`
// rounds halfway cases away from zero — it turns 2049 into 2050 where the
// hardware `fadd half` LLVM emits produces 2048, which would make a folded
// `f16` constant disagree with the runtime expression.
f64_to_f16_bits :: proc(value: f64) -> u16 {
	pattern := transmute(u64)value
	sign := u16((pattern >> 48) & 0x8000)
	exponent := int((pattern >> 52) & 0x7ff)
	mantissa := pattern & 0x000f_ffff_ffff_ffff

	if exponent == 0x7ff {
		return mantissa != 0 ? sign | 0x7e00 : sign | 0x7c00 // NaN, or infinity
	}
	if exponent == 0 {
		return sign // zero, or an f64 subnormal, far below f16's range
	}

	unbiased := exponent - 1023
	if unbiased > 15 {
		return sign | 0x7c00 // beyond f16's largest finite value
	}
	significand := mantissa | (u64(1) << 52) // 53 bits, implicit bit included
	target_exponent := unbiased + 15
	shift := 42 // 52 explicit bits down to f16's 10
	if target_exponent <= 0 {
		// An f16 subnormal: the implicit bit moves into the stored mantissa.
		shift = 43 - target_exponent
		if shift > 63 {
			return sign
		}
		target_exponent = 0
	}

	dropped := significand & ((u64(1) << u64(shift)) - 1)
	result := significand >> u64(shift)
	halfway := u64(1) << u64(shift - 1)
	if dropped > halfway || (dropped == halfway && (result & 1) != 0) {
		result += 1
	}
	if target_exponent == 0 {
		// Rounding may have carried a subnormal up to the smallest normal, whose
		// encoding is the next value in sequence; no special case is needed.
		return sign | u16(result)
	}
	if result >= (u64(1) << 11) {
		result >>= 1
		target_exponent += 1
		if target_exponent >= 31 {
			return sign | 0x7c00
		}
	}
	return sign | u16(u64(target_exponent) << 10) | u16(result & 0x3ff)
}

f16_bits_to_f64 :: proc(bits: u16) -> f64 {
	sign := u64(bits & 0x8000) << 48
	exponent := int((bits >> 10) & 0x1f)
	mantissa := u64(bits & 0x3ff)

	switch {
	case exponent == 0x1f:
		pattern := sign | 0x7ff0_0000_0000_0000 | (mantissa != 0 ? u64(0x0008_0000_0000_0000) : 0)
		return transmute(f64)pattern
	case exponent == 0 && mantissa == 0:
		return transmute(f64)sign
	case exponent == 0:
		// Subnormal: `mantissa * 2^-24`, exact in f64 both times.
		magnitude := f64(mantissa) / 16777216.0
		return sign != 0 ? -magnitude : magnitude
	}
	pattern := sign | (u64(exponent - 15 + 1023) << 52) | (mantissa << 42)
	return transmute(f64)pattern
}

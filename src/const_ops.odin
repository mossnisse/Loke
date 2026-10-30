// Constant values and their arithmetic, shared by the checker and the
// compile-time evaluator so both fold identically. `src/bigint.odin` is the
// arbitrary-precision integer half.
package lokec

import "base:intrinsics"
import "core:math"
import "core:mem"
import "core:strings"

Const_Kind :: enum {
	Invalid,
	Integer,
	Boolean,
	Float,
	String,
	Rune,
	Nil,
	Type,
	Aggregate,
}

// Struct, array, and union constants. Behind a pointer so `Const_Value` stays a
// fixed-size value an AST node can embed.
Const_Aggregate :: struct {
	type:     Type_Id,
	elements: []Const_Value,
	// For a union constant: the variant held, with `elements[0]` its payload (an
	// `Invalid` value when the variant is payloadless).
	variant:  int,
}

// Text is source/compilation backed; `integer` is arena-owned and immutable
// after publication (see `src/bigint.odin`).
Const_Value :: struct {
	kind:       Const_Kind,
	integer:    Big_Int, // Integer and Rune
	float:      f64,
	float_bits: u16,     // the semantic width a Float was last rounded to
	// The exact encoding at `float_bits`. `float` alone cannot carry it: an f32
	// signalling NaN round-tripped through the f64 field comes back quiet, so
	// `unsafe.transmute(u32, x)` would not answer the bits it was handed.
	float_raw:  u64,
	boolean:    bool,
	// A String's text, or an unfixed Float literal's decimal spelling, kept so
	// a narrower destination rounds the exact value once (design.md "Number
	// literals").
	text:       string,
	type_value: Type_Id,
	aggregate:  ^Const_Aggregate,
}

integer_const :: proc(value: Big_Int) -> Const_Value {
	return Const_Value{kind = .Integer, integer = value}
}

int_const :: proc(c: ^Compiler, value: i64) -> Const_Value {
	return Const_Value{kind = .Integer, integer = bi_from_i64(c, value)}
}

rune_const :: proc(value: Big_Int) -> Const_Value {
	return Const_Value{kind = .Rune, integer = value}
}

bool_const :: proc(value: bool) -> Const_Value {
	return Const_Value{kind = .Boolean, boolean = value}
}

nil_const :: proc() -> Const_Value {
	return Const_Value{kind = .Nil}
}

type_const :: proc(type: Type_Id) -> Const_Value {
	return Const_Value{kind = .Type, type_value = type}
}

float_const :: proc(value: f64, bits: u16) -> Const_Value {
	rounded := round_float(value, bits)
	return Const_Value{kind = .Float, float = rounded, float_bits = bits, float_raw = float_pattern(rounded, bits)}
}

// The `unsafe.transmute` direction: exact bits in, the nearest `f64` view of
// them alongside for every ordinary constant operation.
float_bits_const :: proc(raw: u64, bits: u16) -> Const_Value {
	return Const_Value{kind = .Float, float = float_from_pattern(raw, bits), float_bits = bits, float_raw = raw}
}

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
		return float_bits_const(x.float_raw | (bits == 32 ? 1 << 22 : 1 << 51), bits)
	}
	if x.float == 0 || math.is_inf(x.float, 1) {
		return x
	}
	if x.float < 0 {
		return float_bits_const(bits == 32 ? 0xffc00000 : 0xfff8000000000000, bits)
	}
	// An `f32` operand is exact as an `f64`, and narrowing its `f64` root rounds
	// correctly: rounding twice is innocuous for a square root when the wider
	// format has at least 2p + 2 bits for the narrower's p, here 53 >= 50
	// (Figueroa, "When is double rounding innocuous?", 1995).
	return float_const(sqrt_rounded(x.float), bits)
}

// `x`, an `f32` or `f64` constant, rounded to an integral value as `builtin`
// (one of the rounding instructions) rounds it: the compile-time value of
// `core:math.floor`, `ceil`, `trunc`, and `round`, which is exact and so the
// same on every machine. A NaN gives the operand quieted, as the instruction
// does; nothing promises it. Odin's procedures are exact too, `round` taking
// halves away from zero by its bits rather than by adding a half, and an
// `f32` operand's integral value is an `f32`, so the `f64` ones serve both.
exact_integral :: proc(x: Const_Value, builtin: Builtin_Kind) -> Const_Value {
	bits := x.float_bits
	if math.is_nan(x.float) {
		return float_bits_const(x.float_raw | (bits == 32 ? 1 << 22 : 1 << 51), bits)
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

// The compile-time value of `core:math.count_ones`, `leading_zeros`, or
// `trailing_zeros` (`builtin`) of `value` as a `bits`-wide integer: its
// two's-complement pattern, which no integer type wider than 128 bits has.
// Zero has `bits` leading and trailing zeros, as LLVM's `ctlz` and `cttz`
// with a defined zero result give.
bit_count :: proc(storage: Value_Storage, value: Big_Int, bits: int, builtin: Builtin_Kind) -> int {
	pattern := bi_wrap(storage, value, bits, false)
	low, _ := bi_to_u64(storage, bi_and(storage, pattern, bi_from_u64(storage, max(u64))))
	high, _ := bi_to_u64(storage, bi_shr(storage, pattern, 64))
	x := u128(high) << 64 | u128(low)
	#partial switch builtin {
	case .Math_Count_Ones:
		return int(intrinsics.count_ones(x))
	case .Math_Leading_Zeros:
		return int(intrinsics.count_leading_zeros(x)) - (128 - bits)
	}
	return x == 0 ? bits : int(intrinsics.count_trailing_zeros(x))
}

// The compile-time value of `core:math.rotate_left` or `rotate_right`
// (`builtin`): `value` of integer type `type` rotated by `count` modulo its
// width, which the floored remainder makes a left rotation for a negative
// right count and the reverse. The result is built in `storage`.
rotate_const :: proc(c: ^Compiler, storage: Value_Storage, value, count: Big_Int, type: Type_Id, builtin: Builtin_Kind) -> Big_Int {
	bits := type_bits(c, type)
	amount, _ := bi_to_i64(storage, count)
	left := int(amount) & (bits - 1)
	if builtin == .Math_Rotate_Right {
		left = (bits - left) % bits
	}
	pattern := bi_wrap(storage, value, bits, false)
	rotated := bi_or(storage, bi_shl(storage, pattern, left), bi_shr(storage, pattern, bits - left))
	return bi_wrap(storage, rotated, bits, type_signed(c, type))
}

// `x mod y` for two `f32` or two `f64` constants, the remainder of `x` by `y`
// with `x`'s sign: the compile-time value of `core:math.mod`, whose run-time
// `frem` calls the C library's `fmod`. Both are exact, so they agree on every
// result but which NaN a NaN or an invalid operand gives, which nothing
// promises. An `f32` remainder is exact as an `f64`, so the `f64` one serves
// both widths.
exact_mod :: proc(x, y: Const_Value) -> Const_Value {
	bits := x.float_bits
	quiet := u64(bits == 32 ? 1 << 22 : 1 << 51)
	if math.is_nan(x.float) {
		return float_bits_const(x.float_raw | quiet, bits)
	}
	if math.is_nan(y.float) {
		return float_bits_const(y.float_raw | quiet, bits)
	}
	if math.is_inf(x.float) || y.float == 0 {
		return float_bits_const(bits == 32 ? 0xffc00000 : 0xfff8000000000000, bits)
	}
	if math.is_inf(y.float) {
		return x
	}
	return float_const(remainder_exact(x.float, y.float), bits)
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
	mx, ex := remainder_operand(ax)
	my, ey := remainder_operand(ay)
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
remainder_operand :: proc(magnitude: u64) -> (significand: u64, exponent: int) {
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
	pattern := transmute(u64)x
	m := pattern & (1 << 52 - 1)
	e := -1074
	if pattern >> 52 != 0 {
		m |= 1 << 52
		e = int(pattern >> 52) - 1075
	}
	for m < 1 << 52 {
		m <<= 1
		e -= 1
	}
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

value_allocator :: proc(c: ^Compiler, requested: mem.Allocator) -> mem.Allocator {
	return requested.procedure == nil ? c.semantic_allocator : requested
}

fold_arithmetic :: proc(
	c: ^Compiler,
	op: Token_Kind,
	op_span: Span,
	a, b: Const_Value,
	type: Type_Id,
	allocator: mem.Allocator = {},
) -> (Const_Value, bool) {
	storage := value_allocator(c, allocator)
	// design.md "SIMD vectors": operators apply lane-wise.
	if info := underlying_info(c, type); info != nil && info.kind == .Simd {
		return fold_simd_lanes(c, op, op_span, a, b, type, info, allocator)
	}
	if a.kind == .String || b.kind == .String {
		// Only `+` applies to compile-time strings.
		if op != .Plus || a.kind != .String || b.kind != .String {
			errorf(c, op_span, "L0355", "`%s` does not apply to `%s`", operator_text(op), type_name(c, type))
			return Const_Value{}, false
		}
		joined, err := strings.concatenate({a.text, b.text}, storage)
		return Const_Value{kind = .String, text = joined}, err == nil
	}

	if a.kind == .Float || b.kind == .Float {
		bits := u16(type_bits(c, type))
		if type_is_untyped(c, type) {
			bits = 64
		}
		x, y := a.float, b.float
		result: f64
		#partial switch op {
		case .Plus:
			result = x + y
		case .Minus:
			result = x - y
		case .Star:
			result = x * y
		case .Slash:
			// design.md "Floating-point operators": IEEE-754, and no panic.
			result = x / y
		case:
			errorf(c, op_span, "L0355", "`%s` does not apply to `%s`", operator_text(op), type_name(c, type))
			return Const_Value{}, false
		}
		return float_const(result, bits), true
	}

	// design.md "SIMD vectors": bitwise operators apply to `bool` lanes too.
	if a.kind == .Boolean || b.kind == .Boolean {
		if a.kind != .Boolean || b.kind != .Boolean {
			errorf(c, op_span, "L0355", "`%s` does not apply to `%s`", operator_text(op), type_name(c, type))
			return Const_Value{}, false
		}
		#partial switch op {
		case .Amp:
			return bool_const(a.boolean && b.boolean), true
		case .Pipe:
			return bool_const(a.boolean || b.boolean), true
		case .Tilde:
			return bool_const(a.boolean != b.boolean), true
		case .Amp_Tilde:
			return bool_const(a.boolean && !b.boolean), true
		}
		errorf(c, op_span, "L0355", "`%s` does not apply to `%s`", operator_text(op), type_name(c, type))
		return Const_Value{}, false
	}

	if (op == .Slash || op == .Percent) && bi_is_zero(b.integer) {
		errorf(c, op_span, "L0319", "division by zero")
		return Const_Value{}, false
	}

	x, y := a.integer, b.integer
	result: Big_Int
	#partial switch op {
	case .Plus, .Plus_Wrap:
		result = bi_add(storage, x, y)
	case .Minus, .Minus_Wrap:
		result = bi_sub(storage, x, y)
	case .Star, .Star_Wrap:
		result = bi_mul(storage, x, y)
	case .Slash:
		result = bi_quo(storage, x, y)
	case .Percent:
		result = bi_rem(storage, x, y)
	case .Amp:
		result = bi_and(storage, x, y)
	case .Pipe:
		result = bi_or(storage, x, y)
	case .Tilde:
		result = bi_xor(storage, x, y)
	case .Amp_Tilde:
		result = bi_and_not(storage, x, y)
	case .Shl, .Shr:
		// design.md "Integer operators": a shift saturates, so a larger count folds
		// as the limit. Only an untyped `<<` grows, up to a storage cap. A negative
		// count, which only a signed type holds, panics at run time.
		if bi_sign(y) < 0 {
			errorf(c, op_span, "L0356", "a shift count cannot be negative, found %s", bi_text(storage, y))
			return Const_Value{}, false
		}
		untyped := type_is_untyped(c, type)
		limit := u64(bi_magnitude_bits(storage, x))
		if op == .Shl {
			limit = untyped ? 1 << 20 : u64(type_bits(c, type))
		}
		count, fits := bi_to_u64(storage, y)
		if !fits || count > limit {
			if op == .Shl && untyped {
				errorf(c, op_span, "L0356", "shift count %s is too large to fold", bi_text(storage, y))
				return Const_Value{}, false
			}
			count = limit
		}
		result = op == .Shl ? bi_shl(storage, x, int(count)) : bi_shr(storage, x, int(count))
	case:
		errorf(c, op_span, "L0355", "`%s` does not apply to `%s`", operator_text(op), type_name(c, type))
		return Const_Value{}, false
	}
	#partial switch op {
	case .Plus, .Minus, .Star, .Slash:
		if !integer_fits(c, result, type, storage) {
			report_integer_overflow(c, op_span, result, type, storage)
			return Const_Value{}, false
		}
	}
	return Const_Value{kind = a.kind, integer = wrap_to_type(c, result, type, storage)}, true
}

// design.md "Integer overflow": a result that does not fit its integer type is
// a compile-time error where a runtime one would panic. An untyped constant is
// exact, and only `+%`, `-%`, and `*%` wrap.
integer_fits :: proc(c: ^Compiler, value: Big_Int, type: Type_Id, allocator: mem.Allocator = {}) -> bool {
	if type_is_untyped(c, type) {
		return true
	}
	bits := type_bits(c, type)
	return bits <= 0 || bi_fits(value_allocator(c, allocator), value, bits, integer_computes_signed(c, type))
}

report_integer_overflow :: proc(c: ^Compiler, span: Span, value: Big_Int, type: Type_Id, allocator: mem.Allocator = {}) {
	errorf(
		c, span, "L0397", "%s overflow: the result %s does not fit `%s`",
		integer_computes_signed(c, type) ? "signed" : "unsigned",
		bi_text(value_allocator(c, allocator), value), type_name(c, type),
	)
}

// design.md "Integer overflow": a typed result keeps the low bits of its
// width, as `+%`, `<<`, and `math.wrap` do; an untyped one stays exact.
wrap_to_type :: proc(c: ^Compiler, value: Big_Int, type: Type_Id, allocator: mem.Allocator = {}) -> Big_Int {
	if type_is_untyped(c, type) {
		return value
	}
	bits := type_bits(c, type)
	if bits <= 0 {
		return value
	}
	return bi_wrap(value_allocator(c, allocator), value, bits, type_signed(c, type))
}

fold_comparison :: proc(c: ^Compiler, op: Token_Kind, a, b: Const_Value, allocator: mem.Allocator = {}) -> (bool, bool) {
	storage := value_allocator(c, allocator)
	order := 0
	switch {
	case a.kind == .String || b.kind == .String:
		if a.kind != .String || b.kind != .String {
			return false, false
		}
		// Byte order.
		order = strings.compare(a.text, b.text)
	case a.kind == .Float && b.kind == .Float:
		// NaN compares false against everything, including itself.
		if a.float != a.float || b.float != b.float {
			return op == .Not_Eq, true
		}
		order = a.float < b.float ? -1 : (a.float > b.float ? 1 : 0)
	case a.kind == .Float || b.kind == .Float:
		// Integer against float, compared exactly.
		float, integer := a, b
		if b.kind == .Float {
			float, integer = b, a
		}
		if integer.kind != .Integer && integer.kind != .Rune {
			return false, false
		}
		if float.float != float.float {
			return op == .Not_Eq, true
		}
		order = bi_cmp_float(storage, integer.integer, float.float)
		if a.kind == .Float {
			order = -order
		}
	case a.kind == .Integer || a.kind == .Rune:
		if b.kind != .Integer && b.kind != .Rune {
			return false, false
		}
		order = bi_cmp(storage, a.integer, b.integer)
	case a.kind == .Boolean:
		if b.kind != .Boolean {
			return false, false
		}
		if op != .Eq_Eq && op != .Not_Eq {
			return false, false
		}
		return (a.boolean == b.boolean) == (op == .Eq_Eq), true
	case a.kind == .Nil && b.kind == .Nil:
		return op == .Eq_Eq, true
	// Type identity after aliases are resolved.
	case a.kind == .Type && b.kind == .Type:
		if op != .Eq_Eq && op != .Not_Eq {
			return false, false
		}
		equal, known := type_consts_equal(storage, a, b)
		return equal == (op == .Eq_Eq), known
	case a.kind == .Aggregate && b.kind == .Aggregate:
		if op != .Eq_Eq && op != .Not_Eq {
			return aggregate_order(c, op, a.aggregate, b.aggregate, storage)
		}
		equal, known := aggregate_equal(c, a.aggregate, b.aggregate, storage)
		return equal == (op == .Eq_Eq), known
	case:
		return false, false
	}

	#partial switch op {
	case .Eq_Eq:
		return order == 0, true
	case .Not_Eq:
		return order != 0, true
	case .Lt:
		return order < 0, true
	case .Lt_Eq:
		return order <= 0, true
	case .Gt:
		return order > 0, true
	case .Gt_Eq:
		return order >= 0, true
	}
	return false, false
}

// Unknown only while a `typeid` part awaits its number (`type_consts_equal`),
// and then only if no other part already differs.
@(private = "file")
aggregate_equal :: proc(c: ^Compiler, a, b: ^Const_Aggregate, allocator: mem.Allocator = {}) -> (equal: bool, known: bool) {
	if a == nil || b == nil || len(a.elements) != len(b.elements) {
		return false, true
	}
	// design.md "Unions": equal values hold the same variant.
	if type_is_union(c, a.type) {
		if a.variant != b.variant {
			return false, true
		}
		if union_variant_payload(c, a.type, a.variant) == TYPE_VOID {
			return true, true
		}
	}
	deferred := false
	info := underlying_info(c, a.type)
	for element, index in a.elements {
		other := b.elements[index]
		field := info != nil && info.kind == .Struct ? symbol_of(c, info.fields[index]) : nil
		// design.md "Uninitialized capacity": only the live prefix has values.
		if counter := field != nil ? symbol_of(c, field.initialized_by) : nil; counter != nil {
			live, live_ok := bi_to_i64(allocator, a.elements[counter.index].integer)
			if !live_ok || live < 0 || element.aggregate == nil || other.aggregate == nil ||
			   live > i64(min(len(element.aggregate.elements), len(other.aggregate.elements))) {
				return false, true
			}
			for at in 0 ..< int(live) {
				if !part_equal(c, element.aggregate.elements[at], other.aggregate.elements[at], allocator, &deferred) {
					return false, true
				}
			}
			continue
		}
		if !part_equal(c, element, other, allocator, &deferred) {
			return false, true
		}
	}
	if deferred {
		return false, false
	}
	return true, true
}

// Whether a pair of parts may be equal; a pair awaiting a `typeid` number sets
// `deferred`. Any other pair a constant cannot compare counts as a difference.
@(private = "file")
part_equal :: proc(c: ^Compiler, a, b: Const_Value, allocator: mem.Allocator, deferred: ^bool) -> bool {
	equal, ok := fold_comparison(c, .Eq_Eq, a, b, allocator)
	// Between two `type` or two aggregate constants, `==` is unknown only then.
	if !ok && (a.kind == .Type || a.kind == .Aggregate) && a.kind == b.kind {
		deferred^ = true
		return true
	}
	return ok && equal
}

// design.md "Comparison operators": an anonymous record orders by its first
// unequal field, and equal records answer `<=` and `>=`.
@(private = "file")
aggregate_order :: proc(c: ^Compiler, op: Token_Kind, a, b: ^Const_Aggregate, allocator: mem.Allocator) -> (bool, bool) {
	if a == nil || b == nil || len(a.elements) != len(b.elements) || !type_is_ordered(c, a.type) {
		return false, false
	}
	for element, index in a.elements {
		other := b.elements[index]
		equal, ok := fold_comparison(c, .Eq_Eq, element, other, allocator)
		if !ok {
			return false, false
		}
		if equal {
			continue
		}
		if op == .Gt || op == .Gt_Eq {
			return fold_comparison(c, .Lt, other, element, allocator)
		}
		return fold_comparison(c, .Lt, element, other, allocator)
	}
	return op == .Lt_Eq || op == .Gt_Eq, true
}

// One lane at a time at the element type. A non-aggregate operand is a
// splatted scalar.
@(private = "file")
fold_simd_lanes :: proc(
	c: ^Compiler,
	op: Token_Kind,
	op_span: Span,
	a, b: Const_Value,
	type: Type_Id,
	info: ^Type_Info,
	allocator: mem.Allocator,
) -> (Const_Value, bool) {
	lane :: proc(value: Const_Value, index: int) -> Const_Value {
		if value.kind != .Aggregate || value.aggregate == nil {
			return value
		}
		return index < len(value.aggregate.elements) ? value.aggregate.elements[index] : Const_Value{}
	}
	elements := make([]Const_Value, info.count, value_allocator(c, allocator))
	for index in 0 ..< int(info.count) {
		folded, ok := fold_arithmetic(
			c, op, op_span, lane(a, index), lane(b, index), info.element, allocator,
		)
		if !ok {
			return Const_Value{}, false
		}
		elements[index] = folded
	}
	aggregate := new(Const_Aggregate, value_allocator(c, allocator))
	aggregate.type = type
	aggregate.elements = elements
	return Const_Value{kind = .Aggregate, aggregate = aggregate}, true
}

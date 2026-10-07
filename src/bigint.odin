// Arbitrary-precision integer constants over core:math/big. Untyped folding is
// exact; `bi_fits` and `bi_wrap` are where a value meets a width. Every
// operation builds a new value in the given storage.
package lokec

import "core:math"
import big "core:math/big"
import "core:mem"
import "core:strings"

Big_Int :: big.Int

// The checker's semantic arena, or the evaluator's bounded scratch.
Value_Storage :: union { ^Compiler, mem.Allocator }
@(private = "file")
arena :: proc(c: Value_Storage) -> mem.Allocator {
	switch storage in c {
	case ^Compiler:
		init_semantic_stores(storage)
		return storage.semantic_allocator
	case mem.Allocator:
		return storage
	}
	return context.allocator
}

bi_zero :: proc(c: Value_Storage) -> Big_Int {
	return bi_from_i64(c, 0)
}

// Copies a value out of evaluator scratch.
bi_clone :: proc(storage: Value_Storage, value: Big_Int) -> Big_Int {
	context.allocator = arena(storage)
	value := value
	result: Big_Int
	big.int_copy(&result, &value)
	return result
}

bi_from_i64 :: proc(c: Value_Storage, v: i64) -> Big_Int {
	context.allocator = arena(c)
	r: Big_Int
	big.int_set_from_integer(&r, v)
	return r
}

bi_from_u64 :: proc(c: Value_Storage, v: u64) -> Big_Int {
	context.allocator = arena(c)
	r: Big_Int
	big.int_set_from_integer(&r, v)
	return r
}

bi_pow2 :: proc(c: Value_Storage, power: int) -> Big_Int {
	context.allocator = arena(c)
	r: Big_Int
	big.power_of_two(&r, power)
	return r
}

// An integer literal as the lexer spells it: decimal or a lower-case `0b`/`0o`/
// `0x` prefix, `_` separators after the first character. `-define` also passes
// a leading `-`, and reads `ok == false` as "this value is a string".
bi_parse_int_literal :: proc(c: Value_Storage, text: string) -> (value: Big_Int, ok: bool) {
	context.allocator = arena(c)
	negative := strings.has_prefix(text, "-")
	literal := negative ? text[1:] : text
	if literal == "" || literal[0] == '_' {
		return bi_zero(c), false
	}
	radix := 10
	digits := literal
	if len(literal) > 2 && literal[0] == '0' {
		switch literal[1] {
		case 'b': radix, digits = 2, literal[2:]
		case 'o': radix, digits = 8, literal[2:]
		case 'x': radix, digits = 16, literal[2:]
		}
	}
	digits, _ = strings.remove_all(digits, "_")
	if digits == "" {
		return bi_zero(c), false
	}
	for ch in digits {
		digit := 99
		switch ch {
		case '0' ..= '9': digit = int(ch - '0')
		case 'a' ..= 'f': digit = int(ch - 'a') + 10
		case 'A' ..= 'F': digit = int(ch - 'A') + 10
		}
		if digit >= radix {
			return bi_zero(c), false
		}
	}
	r: Big_Int
	if err := big.int_atoi(&r, digits, i8(radix)); err != nil {
		return bi_zero(c), false
	}
	return negative ? bi_neg(c, r) : r, true
}

bi_text :: proc(c: Value_Storage, v: Big_Int) -> string {
	v := v
	text, err := big.int_itoa_string(&v, 10, false, arena(c))
	if err != nil {
		return "<big>"
	}
	return text
}

// -1, 0, or 1.
bi_sign :: proc(v: Big_Int) -> int {
	if v.used == 0 {
		return 0
	}
	return v.sign == .Negative ? -1 : 1
}

bi_is_zero :: proc(v: Big_Int) -> bool {
	return v.used == 0
}

bi_cmp :: proc(c: Value_Storage, a, b: Big_Int) -> int {
	context.allocator = arena(c)
	a, b := a, b
	result, _ := big.int_compare(&a, &b)
	return result
}

bi_eq_i64 :: proc(c: Value_Storage, a: Big_Int, b: i64) -> bool {
	return bi_cmp(c, a, bi_from_i64(c, b)) == 0
}

@(private = "file")
bi_binary :: proc(
	c: Value_Storage,
	a, b: Big_Int,
	op: proc(dest, x, y: ^Big_Int, allocator := context.allocator) -> big.Error,
) -> Big_Int {
	context.allocator = arena(c)
	a, b := a, b
	r: Big_Int
	op(&r, &a, &b)
	return r
}

bi_add :: proc(c: Value_Storage, a, b: Big_Int) -> Big_Int { return bi_binary(c, a, b, big.int_add) }
bi_sub :: proc(c: Value_Storage, a, b: Big_Int) -> Big_Int { return bi_binary(c, a, b, big.int_sub) }
bi_mul :: proc(c: Value_Storage, a, b: Big_Int) -> Big_Int { return bi_binary(c, a, b, big.int_mul) }
bi_and :: proc(c: Value_Storage, a, b: Big_Int) -> Big_Int { return bi_binary(c, a, b, big.int_bit_and) }
bi_or :: proc(c: Value_Storage, a, b: Big_Int) -> Big_Int { return bi_binary(c, a, b, big.int_bit_or) }
bi_xor :: proc(c: Value_Storage, a, b: Big_Int) -> Big_Int { return bi_binary(c, a, b, big.int_bit_xor) }

bi_neg :: proc(c: Value_Storage, a: Big_Int) -> Big_Int {
	context.allocator = arena(c)
	a := a
	r: Big_Int
	big.int_neg(&r, &a)
	return r
}

// `~x`, which on a two's-complement integer of any width is `-x - 1`.
bi_not :: proc(c: Value_Storage, a: Big_Int) -> Big_Int {
	context.allocator = arena(c)
	a := a
	r: Big_Int
	big.int_bit_complement(&r, &a)
	return r
}

bi_and_not :: proc(c: Value_Storage, a, b: Big_Int) -> Big_Int {
	return bi_and(c, a, bi_not(c, b))
}

// Truncated quotient and remainder (design.md "Integer operators"). The caller
// has already rejected a zero divisor.
bi_quo :: proc(c: Value_Storage, a, b: Big_Int) -> Big_Int {
	context.allocator = arena(c)
	a, b := a, b
	q, r: Big_Int
	big.int_divmod(&q, &r, &a, &b)
	return q
}

bi_rem :: proc(c: Value_Storage, a, b: Big_Int) -> Big_Int {
	context.allocator = arena(c)
	a, b := a, b
	q, r: Big_Int
	big.int_divmod(&q, &r, &a, &b)
	return r
}

bi_shl :: proc(c: Value_Storage, a: Big_Int, count: int) -> Big_Int {
	context.allocator = arena(c)
	a := a
	r: Big_Int
	big.int_shl(&r, &a, count)
	return r
}

// Arithmetic right shift, so a huge count settles on 0 or -1.
//
// core:math/big's `int_shr_signed` returns `src - 1` for any negative input
// (it writes `sub(dest, src, 1)` for `sub(dest, dest, 1)`), so the negative case
// uses `x >> n == ~(~x >> n)`, where `~x` is non-negative.
bi_shr :: proc(c: Value_Storage, a: Big_Int, count: int) -> Big_Int {
	if bi_sign(a) < 0 {
		return bi_not(c, bi_shr_logical(c, bi_not(c, a), count))
	}
	return bi_shr_logical(c, a, count)
}

@(private = "file")
bi_shr_logical :: proc(c: Value_Storage, a: Big_Int, count: int) -> Big_Int {
	context.allocator = arena(c)
	a := a
	r: Big_Int
	big.int_shr(&r, &a, count)
	// core:math/big clamps the source rather than the result, which leaves a
	// shift below one 60-bit digit with a stale leading zero digit.
	big.internal_clamp(&r)
	return r
}

// Number of bits in the magnitude; 0 for zero.
bi_magnitude_bits :: proc(c: Value_Storage, v: Big_Int) -> int {
	context.allocator = arena(c)
	v := v
	count, _ := big.count_bits(&v)
	return count
}

// Does the value fit a two's-complement integer of this width?
bi_fits :: proc(c: Value_Storage, v: Big_Int, bits: int, signed: bool) -> bool {
	if bits <= 0 {
		return false
	}
	if !signed {
		if bi_sign(v) < 0 {
			return false
		}
		return bi_magnitude_bits(c, v) <= bits
	}
	magnitude := bi_magnitude_bits(c, v)
	if magnitude < bits {
		return true
	}
	if magnitude > bits {
		return false
	}
	// Exactly `bits` magnitude bits fits only as the most negative value.
	return bi_cmp(c, v, bi_neg(c, bi_pow2(c, bits - 1))) == 0
}

// The modulo-2^n projection every typed integer operation ends with
// (design.md "Integer overflow").
bi_wrap :: proc(c: Value_Storage, v: Big_Int, bits: int, signed: bool) -> Big_Int {
	if bits <= 0 {
		return bi_zero(c)
	}
	mask := bi_sub(c, bi_pow2(c, bits), bi_from_i64(c, 1))
	low := bi_and(c, v, mask)
	if signed && bi_cmp(c, low, bi_pow2(c, bits - 1)) >= 0 {
		return bi_sub(c, low, bi_pow2(c, bits))
	}
	return low
}

// A machine integer, or `ok == false` when out of range.
bi_to_i64 :: proc(c: Value_Storage, v: Big_Int) -> (value: i64, ok: bool) {
	if !bi_fits(c, v, 64, true) {
		return 0, false
	}
	context.allocator = arena(c)
	v := v
	result, err := big.int_get_i64(&v)
	return result, err == nil
}

bi_to_u64 :: proc(c: Value_Storage, v: Big_Int) -> (value: u64, ok: bool) {
	if !bi_fits(c, v, 64, false) {
		return 0, false
	}
	context.allocator = arena(c)
	v := v
	result, err := big.int_get_u64(&v)
	return result, err == nil
}

// The nearest float of `bits` width (16, 32, or 64), ties to even, or
// `ok == false` when it overflows that width. core:math/big's `int_get_float`
// is not used: it rounds inexactly and returns 0 past the f64 range.
bi_to_float :: proc(c: Value_Storage, v: Big_Int, bits: u16) -> (result: f64, ok: bool) {
	// Enough leading bits for one correct rounding, plus a sticky bit below them.
	keep := 64
	switch bits {
	case 16: keep = 11 + 2
	case 32: keep = 24 + 2
	}
	negative := bi_sign(v) < 0
	magnitude := negative ? bi_neg(c, v) : v
	shift := max(bi_magnitude_bits(c, magnitude) - keep, 0)
	top := bi_shr(c, magnitude, shift)
	high, _ := bi_to_u64(c, top)
	if bi_cmp(c, bi_shl(c, top, shift), magnitude) != 0 {
		high |= 1
	}
	result = round_float(math.ldexp(f64(high), shift), bits)
	if negative {
		result = -result
	}
	return result, !math.is_inf(result, 0)
}

// A decimal literal's spelling, `digits[.digits][e[+-]digits]`, rounded once to
// a 16- or 32-bit float. `ok` is false for any other width or spelling, where
// the caller's binary64 value already is the single rounding.
decimal_to_float :: proc(c: Value_Storage, text: string, bits: u16) -> (result: f64, ok: bool) {
	// Far past both bounds below, and small enough that adding the fraction's
	// digit count cannot overflow.
	DECIMAL_EXPONENT_LIMIT :: 1 << 40
	if (bits != 16 && bits != 32) || text == "" {
		return 0, false
	}
	negative := text[0] == '-'
	digits := make([dynamic]u8, 0, len(text), arena(c))
	exponent := 0
	index := negative ? 1 : 0
	point := false
	for ; index < len(text); index += 1 {
		ch := text[index]
		switch {
		case ch >= '0' && ch <= '9':
			append(&digits, ch)
			if point {
				exponent -= 1
			}
		case ch == '.':
			point = true
		case ch == 'e' || ch == 'E':
			// Saturated: any exponent this large already decides the result below.
			written := 0
			sign := 1
			rest := text[index + 1:]
			if rest != "" && (rest[0] == '+' || rest[0] == '-') {
				sign = rest[0] == '-' ? -1 : 1
				rest = rest[1:]
			}
			if rest == "" {
				return 0, false
			}
			for digit in transmute([]u8)rest {
				if digit < '0' || digit > '9' {
					return 0, false
				}
				written = min(written * 10 + int(digit - '0'), DECIMAL_EXPONENT_LIMIT)
			}
			exponent += sign * written
			index = len(text)
		case:
			return 0, false
		}
	}
	significand, parsed := bi_parse_int_literal(c, string(digits[:]))
	if !parsed {
		return 0, false
	}
	if bi_is_zero(significand) {
		return negative ? math.copy_sign(f64(0), -1) : 0, true
	}
	// The value lies in [10^(top - 1), 10^top). Past 10^40 every 16- and 32-bit
	// float overflows, and below 10^-50 every one rounds to zero, so no power
	// of ten is built for an exponent outside that range.
	first := 0
	for digits[first] == '0' {
		first += 1
	}
	top := len(digits) - first + exponent
	if top > 40 {
		return 0, false
	}
	if top < -50 {
		return negative ? math.copy_sign(f64(0), -1) : 0, true
	}
	ten := bi_from_i64(c, 10)
	power := bi_from_i64(c, 1)
	for _ in 0 ..< abs(exponent) {
		power = bi_mul(c, power, ten)
	}
	magnitude: f64
	if exponent >= 0 {
		magnitude, ok = bi_to_float(c, bi_mul(c, significand, power), bits)
		if !ok {
			return 0, false
		}
	} else {
		// `significand / power`, scaled so the quotient keeps one correct rounding
		// and a sticky bit for the remainder, as `bi_to_float` keeps for its own.
		keep := bits == 16 ? 11 + 2 : 24 + 2
		scale := max(keep + 2 + bi_magnitude_bits(c, power) - bi_magnitude_bits(c, significand), 0)
		scaled := bi_shl(c, significand, scale)
		quotient := bi_quo(c, scaled, power)
		shift := max(bi_magnitude_bits(c, quotient) - keep, 0)
		top := bi_shr(c, quotient, shift)
		high, _ := bi_to_u64(c, top)
		if !bi_is_zero(bi_rem(c, scaled, power)) || bi_cmp(c, bi_shl(c, top, shift), quotient) != 0 {
			high |= 1
		}
		magnitude = round_float(math.ldexp(f64(high), shift - scale), bits)
	}
	return negative ? -magnitude : magnitude, true
}

// Orders an integer against a float that is not NaN, exactly.
bi_cmp_float :: proc(c: Value_Storage, a: Big_Int, y: f64) -> int {
	if math.is_inf(y, 0) {
		return y > 0 ? -1 : 1
	}
	truncated, exact, _ := bi_from_f64_trunc(c, y)
	if order := bi_cmp(c, a, truncated); order != 0 || exact {
		return order
	}
	return y > 0 ? -1 : 1
}

// Truncates a finite binary64 value towards zero. `exact` is false when a
// fraction was dropped: `1.0` is exactly an integer, `1.5` is not.
bi_from_f64_trunc :: proc(c: Value_Storage, value: f64) -> (result: Big_Int, exact, ok: bool) {
	pattern := transmute(u64)value
	exponent_bits := int((pattern >> 52) & 0x7ff)
	fraction := pattern & 0x000f_ffff_ffff_ffff
	negative := (pattern >> 63) != 0

	if exponent_bits == 0x7ff {
		return bi_zero(c), false, false // infinity or NaN
	}
	if exponent_bits == 0 {
		// Zero is exact; every binary64 subnormal has magnitude below one.
		return bi_zero(c), fraction == 0, true
	}

	unbiased := exponent_bits - 1023
	if unbiased < 0 {
		return bi_zero(c), false, true
	}

	significand := fraction | (u64(1) << 52)
	magnitude := bi_from_u64(c, significand)
	exact = true
	if unbiased >= 52 {
		magnitude = bi_shl(c, magnitude, unbiased - 52)
	} else {
		shift := 52 - unbiased
		mask := (u64(1) << u64(shift)) - 1
		exact = (significand & mask) == 0
		magnitude = bi_shr(c, magnitude, shift)
	}
	if negative && !bi_is_zero(magnitude) {
		magnitude = bi_neg(c, magnitude)
	}
	return magnitude, exact, true
}

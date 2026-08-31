// Arbitrary-precision integer constants.
//
// Untyped folding is exact: an intermediate is never rejected merely because no
// runtime integer type could hold it. `bi_fits` and `bi_wrap` are where a value
// meets a width — range check on materializing a constant, modulo-2^n
// projection when folding a typed operation.
//
// Arithmetic is core:math/big; values are immutable, operations always build
// new digit buffers. Checking uses the compilation's semantic arena; evaluation
// uses bounded scratch storage, cloning escaping constants into the semantic
// arena before releasing that scratch.
package lokec

import big "core:math/big"
import "core:mem"
import "core:strings"

Big_Int :: big.Int

// Checking uses compilation storage; execution supplies its bounded scratch
// allocator explicitly. Neither mode changes the other's allocation lifetime.
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

// Publish an evaluator result without retaining its scratch digit buffer (or
// the allocator pointer stored in that buffer).
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

// `2^power`, the building block of every width boundary below.
bi_pow2 :: proc(c: Value_Storage, power: int) -> Big_Int {
	context.allocator = arena(c)
	r: Big_Int
	big.power_of_two(&r, power)
	return r
}

// Decodes an integer literal per grammar.md: decimal, or a `0b`/`0o`/`0x`
// prefix, with `_` allowed as a separator anywhere but the first character.
// Unlike M0's `parse_int_text` this cannot overflow, so `ok` is false only for
// a spelling the lexer would not have produced.
bi_parse_int_literal :: proc(c: Value_Storage, text: string) -> (value: Big_Int, ok: bool) {
	context.allocator = arena(c)
	radix := i8(10)
	digits := text
	if len(text) > 2 && text[0] == '0' {
		switch text[1] {
		case 'b', 'B':
			radix, digits = 2, text[2:]
		case 'o', 'O':
			radix, digits = 8, text[2:]
		case 'x', 'X':
			radix, digits = 16, text[2:]
		}
	}
	if strings.contains(digits, "_") {
		digits, _ = strings.replace_all(digits, "_", "", arena(c))
	}
	if digits == "" {
		return bi_zero(c), false
	}
	r: Big_Int
	if err := big.int_atoi(&r, digits, radix); err != nil {
		return bi_zero(c), false
	}
	return r, true
}

bi_text :: proc(c: Value_Storage, v: Big_Int) -> string {
	context.allocator = arena(c)
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

// Truncated quotient and remainder (design.md "Integer operators": `x = q*y + r`
// with `|r| < |y|`, `q` truncated towards zero). The caller has already rejected
// a zero divisor.
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

// Arithmetic right shift: on an untyped value the sign bit is replicated
// forever, so a huge count settles on 0 or -1 exactly as design.md requires of
// the typed operators.
//
// core:math/big's own `int_shr_signed` is not used: its negative branch means
// `sub(dest, dest, 1)` but writes `sub(dest, src, 1)`, so it returns `src - 1`
// regardless of count. The negative case is derived here instead from the
// logical shift, via `x >> n == ~(~x >> n)` — `~x` is non-negative exactly when
// `x` is negative, so the inner shift never sees a sign.
bi_shr :: proc(c: Value_Storage, a: Big_Int, count: int) -> Big_Int {
	context.allocator = arena(c)
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

// Extraction for places that need a machine integer: an array length, a shift
// count, an enum discriminant. `ok` is false when out of range; the caller has
// a diagnostic for that.
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

bi_to_f64 :: proc(c: Value_Storage, v: Big_Int) -> f64 {
	context.allocator = arena(c)
	v := v
	result, err := big.int_get_float(&v)
	if err != nil {
		return 0
	}
	return result
}

// Truncates a finite binary64 value towards zero without squeezing the result
// through a machine integer first (needed for conversions to i128 and u128).
// `exact` implements the implicit-constant rule: `1.0` is exactly an integer,
// `1.5` is not.
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

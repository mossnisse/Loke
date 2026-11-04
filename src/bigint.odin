// Arbitrary-precision integer constants over core:math/big. Untyped folding is
// exact; `bi_fits` and `bi_wrap` are where a value meets a width. Every
// operation builds a new value in the given storage, except that `bi_wrap`
// returns a value already in range.
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

// Evaluator storage charges every digit an integer holds (eval_memory.odin),
// and core:math/big gives each result room for 32 whatever it needs. A result
// built there keeps only the digits it uses; the rest goes back for reuse.
@(private = "file")
bi_settle :: proc(c: Value_Storage, r: ^Big_Int) {
	if is_eval_storage(c) {
		big.internal_int_grow(r, r.used, allow_shrink = true)
	}
}

// Releases integers built in evaluator storage that no value holds; anywhere
// else they stay until their storage goes.
bi_release :: proc(values: ..Big_Int) {
	for &value in values {
		if is_eval_storage(value.digit.allocator) {
			context.allocator = value.digit.allocator
			big.internal_int_destroy(&value)
		}
	}
}

bi_zero :: proc(c: Value_Storage) -> Big_Int {
	return bi_from_i64(c, 0)
}

// Copies a value out of evaluator scratch, keeping only the digits it uses.
bi_clone :: proc(storage: Value_Storage, value: Big_Int) -> Big_Int {
	context.allocator = arena(storage)
	value := value
	result: Big_Int
	big.int_copy(&result, &value, minimize = true)
	return result
}

bi_from_i64 :: proc(c: Value_Storage, v: i64) -> Big_Int {
	context.allocator = arena(c)
	r: Big_Int
	big.int_set_from_integer(&r, v)
	bi_settle(c, &r)
	return r
}

bi_from_u64 :: proc(c: Value_Storage, v: u64) -> Big_Int {
	context.allocator = arena(c)
	r: Big_Int
	big.int_set_from_integer(&r, v)
	bi_settle(c, &r)
	return r
}

bi_pow2 :: proc(c: Value_Storage, power: int) -> Big_Int {
	context.allocator = arena(c)
	r: Big_Int
	big.power_of_two(&r, power)
	bi_settle(c, &r)
	return r
}

bi_pow10 :: proc(c: Value_Storage, power: int) -> Big_Int {
	context.allocator = arena(c)
	r: Big_Int
	big.int_pow_int(&r, 10, power)
	bi_settle(c, &r)
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
	for i in 0 ..< len(digits) {
		if digit_value(digits[i]) >= radix {
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

bi_cmp :: proc(a, b: Big_Int) -> int {
	a, b := a, b
	return big.internal_cmp(&a, &b)
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
	bi_settle(c, &r)
	return r
}

bi_add :: proc(c: Value_Storage, a, b: Big_Int) -> Big_Int { return bi_binary(c, a, b, big.int_add) }
bi_sub :: proc(c: Value_Storage, a, b: Big_Int) -> Big_Int { return bi_binary(c, a, b, big.int_sub) }
bi_mul :: proc(c: Value_Storage, a, b: Big_Int) -> Big_Int { return bi_binary(c, a, b, big.int_mul) }
bi_and :: proc(c: Value_Storage, a, b: Big_Int) -> Big_Int { return bi_binary(c, a, b, big.int_bit_and) }
bi_or :: proc(c: Value_Storage, a, b: Big_Int) -> Big_Int { return bi_binary(c, a, b, big.int_bit_or) }
bi_xor :: proc(c: Value_Storage, a, b: Big_Int) -> Big_Int { return bi_binary(c, a, b, big.int_bit_xor) }

@(private = "file")
bi_unary :: proc(
	c: Value_Storage,
	a: Big_Int,
	op: proc(dest, src: ^Big_Int, allocator := context.allocator) -> big.Error,
) -> Big_Int {
	context.allocator = arena(c)
	a := a
	r: Big_Int
	op(&r, &a)
	bi_settle(c, &r)
	return r
}

bi_neg :: proc(c: Value_Storage, a: Big_Int) -> Big_Int { return bi_unary(c, a, big.int_neg) }

// `~x`, which on a two's-complement integer of any width is `-x - 1`.
bi_not :: proc(c: Value_Storage, a: Big_Int) -> Big_Int { return bi_unary(c, a, big.int_bit_complement) }

bi_and_not :: proc(c: Value_Storage, a, b: Big_Int) -> Big_Int {
	inverse := bi_not(c, b)
	defer bi_release(inverse)
	return bi_and(c, a, inverse)
}

// Truncated quotient and remainder (design.md "Integer operators"). The caller
// has already rejected a zero divisor.
//
// core:math/big's `int_divmod` turns to a recursive division past 160 divisor
// digits, and `_private_div_recursion` leaves out a term (it never subtracts
// `Q1 * B0 * beta^k`), so these use its schoolbook division at any size.
bi_quo :: proc(c: Value_Storage, a, b: Big_Int) -> Big_Int { return bi_binary(c, a, b, bi_school_quo) }
bi_rem :: proc(c: Value_Storage, a, b: Big_Int) -> Big_Int { return bi_binary(c, a, b, bi_school_rem) }

@(private = "file")
bi_school_quo :: proc(dest, a, b: ^Big_Int, allocator := context.allocator) -> big.Error {
	context.allocator = allocator
	if big.internal_lt_abs(a, b) {
		return big.internal_zero(dest)
	}
	return big._private_int_div_school(dest, nil, a, b)
}

@(private = "file")
bi_school_rem :: proc(dest, a, b: ^Big_Int, allocator := context.allocator) -> big.Error {
	context.allocator = allocator
	if big.internal_lt_abs(a, b) {
		return big.internal_copy(dest, a)
	}
	return big._private_int_div_school(nil, dest, a, b)
}

bi_shl :: proc(c: Value_Storage, a: Big_Int, count: int) -> Big_Int {
	context.allocator = arena(c)
	a := a
	r: Big_Int
	big.int_shl(&r, &a, count)
	bi_settle(c, &r)
	return r
}

// Arithmetic right shift, so a huge count settles on 0 or -1.
//
// core:math/big's `int_shr_signed` returns `src - 1` for any negative input
// (it writes `sub(dest, src, 1)` for `sub(dest, dest, 1)`), so the negative case
// uses `x >> n == ~(~x >> n)`, where `~x` is non-negative.
bi_shr :: proc(c: Value_Storage, a: Big_Int, count: int) -> Big_Int {
	if bi_sign(a) < 0 {
		inverse := bi_not(c, a)
		shifted := bi_shr_logical(c, inverse, count)
		defer bi_release(inverse, shifted)
		return bi_not(c, shifted)
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
	bi_settle(c, &r)
	return r
}

bi_magnitude_bits :: proc(v: Big_Int) -> int {
	v := v
	return big.internal_count_bits(&v)
}

bi_fits :: proc(v: Big_Int, bits: int, signed: bool) -> bool {
	if bits <= 0 {
		return false
	}
	magnitude := bi_magnitude_bits(v)
	if !signed {
		return bi_sign(v) >= 0 && magnitude <= bits
	}
	if magnitude != bits {
		return magnitude < bits
	}
	// Exactly `bits` magnitude bits fits only as the most negative value, whose
	// one bit is the top one.
	v := v
	trailing, _ := big.internal_int_count_lsb(&v)
	return bi_sign(v) < 0 && trailing == bits - 1
}

// The modulo-2^n projection every typed integer operation ends with
// (design.md "Integer overflow").
bi_wrap :: proc(c: Value_Storage, v: Big_Int, bits: int, signed: bool) -> Big_Int {
	if bits <= 0 {
		return bi_zero(c)
	}
	if bi_fits(v, bits, signed) {
		return v
	}
	modulus := bi_pow2(c, bits)
	one := bi_from_i64(c, 1)
	mask := bi_sub(c, modulus, one)
	low := bi_and(c, v, mask)
	bi_release(one, mask)
	defer bi_release(modulus)
	if signed {
		half := bi_pow2(c, bits - 1)
		defer bi_release(half)
		if bi_cmp(low, half) >= 0 {
			defer bi_release(low)
			return bi_sub(c, low, modulus)
		}
	}
	return low
}

// `v`'s two's-complement pattern as a `bits`-wide integer, which no integer type
// wider than 128 bits has. Builds nothing.
bi_pattern :: proc(v: Big_Int, bits: int) -> u128 {
	magnitude: u128
	for index := v.used - 1; index >= 0; index -= 1 {
		magnitude = magnitude << big._DIGIT_BITS | u128(v.digit[index])
	}
	pattern := v.sign == .Negative ? -magnitude : magnitude
	return bits >= 128 ? pattern : pattern & (u128(1) << uint(bits) - 1)
}

// The value a `bits`-wide two's-complement pattern holds.
bi_from_pattern :: proc(c: Value_Storage, pattern: u128, bits: int, signed: bool) -> Big_Int {
	context.allocator = arena(c)
	r: Big_Int
	if signed {
		shift := uint(128 - bits)
		big.int_set_from_integer(&r, i128(pattern << shift) >> shift)
	} else {
		big.int_set_from_integer(&r, pattern)
	}
	bi_settle(c, &r)
	return r
}

bi_to_i64 :: proc(c: Value_Storage, v: Big_Int) -> (value: i64, ok: bool) {
	if !bi_fits(v, 64, true) {
		return 0, false
	}
	context.allocator = arena(c)
	v := v
	result, err := big.int_get_i64(&v)
	return result, err == nil
}

bi_to_u64 :: proc(c: Value_Storage, v: Big_Int) -> (value: u64, ok: bool) {
	if !bi_fits(v, 64, false) {
		return 0, false
	}
	context.allocator = arena(c)
	v := v
	result, err := big.int_get_u64(&v)
	return result, err == nil
}

// Orders an integer against a float that is not NaN, exactly.
bi_cmp_float :: proc(c: Value_Storage, a: Big_Int, y: f64) -> int {
	if math.is_inf(y, 0) {
		return y > 0 ? -1 : 1
	}
	truncated, exact := bi_from_f64_trunc(c, y)
	defer bi_release(truncated)
	if order := bi_cmp(a, truncated); order != 0 || exact {
		return order
	}
	return y > 0 ? -1 : 1
}

// Truncates a finite binary64 value towards zero. `exact` is false when a
// fraction was dropped.
bi_from_f64_trunc :: proc(c: Value_Storage, value: f64) -> (result: Big_Int, exact: bool) {
	if abs(value) < 1 {
		return bi_zero(c), value == 0
	}
	exact = math.trunc(value) == value
	split := dyadic_of(c, abs(value))
	defer bi_release(split.significand)
	magnitude := split.exponent >= 0 ? bi_shl(c, split.significand, split.exponent) : bi_shr(c, split.significand, -split.exponent)
	if value < 0 {
		defer bi_release(magnitude)
		return bi_neg(c, magnitude), exact
	}
	return magnitude, exact
}

// A set of integers for code that can see thousands. Only the few past `i64` are
// compared one by one.
Integer_Set :: struct {
	small: map[i64]bool,
	large: [dynamic]Big_Int,
}

new_integer_set :: proc(capacity: int, allocator: mem.Allocator) -> Integer_Set {
	return Integer_Set{small = make(map[i64]bool, capacity, allocator), large = make([dynamic]Big_Int, allocator)}
}

// Whether `value` is new to the set, adding it if so.
integer_set_add :: proc(c: Value_Storage, set: ^Integer_Set, value: Big_Int) -> bool {
	if small, fits := bi_to_i64(c, value); fits {
		if small in set.small {
			return false
		}
		set.small[small] = true
		return true
	}
	for other in set.large {
		if bi_cmp(other, value) == 0 {
			return false
		}
	}
	append(&set.large, value)
	return true
}

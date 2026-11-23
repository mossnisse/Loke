// Arbitrary-precision integer constants over core:math/big. Untyped folding is
// exact; `bi_fits` and `bi_wrap` are where a value meets a width. Every
// operation builds a new value in the given storage, except that `bi_wrap`
// returns a value already in range.
package lokec

import "base:intrinsics"
import "core:math"
import big "core:math/big"
import "core:mem"
import "core:strings"

Big_Int :: big.Int

// The checker's semantic arena, or the evaluator's bounded scratch.
Value_Storage :: union { ^Compiler, mem.Allocator }
storage_allocator :: proc(c: Value_Storage) -> mem.Allocator {
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
	context.allocator = storage_allocator(storage)
	value := value
	result: Big_Int
	big.int_copy(&result, &value, minimize = true)
	return result
}

bi_from_i64 :: proc(c: Value_Storage, v: i64) -> Big_Int { return bi_from_int(c, v) }
bi_from_u64 :: proc(c: Value_Storage, v: u64) -> Big_Int { return bi_from_int(c, v) }

@(private = "file")
bi_from_int :: proc(c: Value_Storage, v: $T) -> Big_Int where intrinsics.type_is_integer(T) {
	context.allocator = storage_allocator(c)
	r: Big_Int
	big.int_set_from_integer(&r, v)
	bi_settle(c, &r)
	return r
}

bi_pow2 :: proc(c: Value_Storage, power: int) -> Big_Int {
	context.allocator = storage_allocator(c)
	r: Big_Int
	big.power_of_two(&r, power)
	bi_settle(c, &r)
	return r
}

bi_pow :: proc(c: Value_Storage, base, power: int) -> Big_Int {
	context.allocator = storage_allocator(c)
	r: Big_Int
	big.int_pow_int(&r, base, power)
	bi_settle(c, &r)
	return r
}

// The number of zero bits below the lowest one; 0 for zero.
bi_trailing_zeros :: proc(v: Big_Int) -> int {
	v := v
	count, _ := big.internal_int_count_lsb(&v)
	return count
}

// `v` with up to `most` factors of the small `factor` divided out, and how many
// were. Each pass divides by one digit, by as high a power of `factor` as fits,
// so it costs a pass over `v` per digit's worth of factors rather than per factor.
bi_divide_out :: proc(c: Value_Storage, v: Big_Int, factor: int, most: int) -> (result: Big_Int, count: int) {
	context.allocator = storage_allocator(c)
	chunk, width := big.DIGIT(factor), 1
	for chunk < (1 << big._DIGIT_BITS) / big.DIGIT(factor) {
		chunk *= big.DIGIT(factor)
		width += 1
	}
	result = bi_clone(c, v)
	for step in ([2]struct{divisor: big.DIGIT, width: int}{{chunk, width}, {big.DIGIT(factor), 1}}) {
		for count + step.width <= most && !bi_is_zero(result) {
			quotient: Big_Int
			remainder, _ := big.int_divmod_digit(&quotient, &result, step.divisor)
			if remainder != 0 {
				bi_release(quotient)
				break
			}
			bi_settle(c, &quotient)
			bi_release(result)
			result = quotient
			count += step.width
		}
	}
	return
}

// An integer literal as the lexer spells it: decimal or a lower-case `0b`/`0o`/
// `0x` prefix, `_` separators after the first character. `-define` also passes
// a leading `-`, and reads `ok == false` as "this value is a string".
bi_parse_int_literal :: proc(c: Value_Storage, text: string) -> (value: Big_Int, ok: bool) {
	context.allocator = storage_allocator(c)
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
	digits, _ = strings.remove_all(digits, "_", context.temp_allocator)
	if digits == "" {
		return bi_zero(c), false
	}
	for i in 0 ..< len(digits) {
		if digit_value(digits[i]) >= radix {
			return bi_zero(c), false
		}
	}
	r, parsed := bi_atoi(c, digits, radix)
	if !parsed {
		bi_release(r)
		return bi_zero(c), false
	}
	if negative {
		context.allocator = storage_allocator(c)
		big.int_neg(&r, &r)
	}
	return r, true
}

// `digits` in `radix`, split in halves past a few hundred digits:
// core:math/big's `int_atoi` takes in one digit at a time, quadratic in the
// length, which a long decimal literal makes seconds.
@(private = "file")
bi_atoi :: proc(c: Value_Storage, digits: string, radix: int) -> (Big_Int, bool) {
	if len(digits) <= 512 {
		context.allocator = storage_allocator(c)
		r: Big_Int
		err := big.int_atoi(&r, digits, i8(radix))
		bi_settle(c, &r)
		return r, err == nil
	}
	half := len(digits) / 2
	high, high_ok := bi_atoi(c, digits[:half], radix)
	low, low_ok := bi_atoi(c, digits[half:], radix)
	scale := bi_pow(c, radix, len(digits) - half)
	shifted := bi_mul(c, high, scale)
	defer bi_release(high, low, scale, shifted)
	return bi_add(c, shifted, low), high_ok && low_ok
}

bi_text :: proc(c: Value_Storage, v: Big_Int) -> string {
	v := v
	text, err := big.int_itoa_string(&v, 10, false, storage_allocator(c))
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
	context.allocator = storage_allocator(c)
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
	context.allocator = storage_allocator(c)
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

// Both, from one division.
bi_quo_rem :: proc(c: Value_Storage, a, b: Big_Int) -> (quotient, remainder: Big_Int) {
	context.allocator = storage_allocator(c)
	a, b := a, b
	bi_school_div(&quotient, &remainder, &a, &b)
	bi_settle(c, &quotient)
	bi_settle(c, &remainder)
	return
}

// The greatest common divisor of the magnitudes; 0 only when both are. Euclid's:
// core:math/big's binary `int_gcd` takes a step per bit, too slow for the
// denominator of a long decimal. A one-digit divisor, the usual one, takes a
// single pass where the schoolbook remainder's grows with the square of the
// dividend.
bi_gcd :: proc(c: Value_Storage, a, b: Big_Int) -> Big_Int {
	x, y := bi_abs(c, a), bi_abs(c, b)
	for !bi_is_zero(y) {
		r: Big_Int
		if y.used == 1 {
			context.allocator = storage_allocator(c)
			digit, _ := big.int_mod_digit(&x, y.digit[0])
			r = bi_from_u64(c, u64(digit))
		} else {
			r = bi_rem(c, x, y)
		}
		bi_release(x)
		x, y = y, r
	}
	bi_release(y)
	return x
}

bi_abs :: proc(c: Value_Storage, a: Big_Int) -> Big_Int { return bi_unary(c, a, big.int_abs) }

// Whichever of `quotient` and `remainder` is not nil.
@(private = "file")
bi_school_div :: proc(quotient, remainder, a, b: ^Big_Int) -> big.Error {
	if !big.internal_lt_abs(a, b) {
		return big._private_int_div_school(quotient, remainder, a, b)
	}
	if quotient != nil {
		big.internal_zero(quotient) or_return
	}
	return remainder == nil ? nil : big.internal_copy(remainder, a)
}

@(private = "file")
bi_school_quo :: proc(dest, a, b: ^Big_Int, allocator := context.allocator) -> big.Error {
	context.allocator = allocator
	return bi_school_div(dest, nil, a, b)
}

@(private = "file")
bi_school_rem :: proc(dest, a, b: ^Big_Int, allocator := context.allocator) -> big.Error {
	context.allocator = allocator
	return bi_school_div(nil, dest, a, b)
}

bi_shl :: proc(c: Value_Storage, a: Big_Int, count: int) -> Big_Int {
	context.allocator = storage_allocator(c)
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
	context.allocator = storage_allocator(c)
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
	return bi_sign(v) < 0 && bi_trailing_zeros(v) == bits - 1
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
	context.allocator = storage_allocator(c)
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
	context.allocator = storage_allocator(c)
	v := v
	result, err := big.int_get_i64(&v)
	return result, err == nil
}

bi_to_u64 :: proc(c: Value_Storage, v: Big_Int) -> (value: u64, ok: bool) {
	if !bi_fits(v, 64, false) {
		return 0, false
	}
	context.allocator = storage_allocator(c)
	v := v
	result, err := big.int_get_u64(&v)
	return result, err == nil
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

// A map from integers for code that can see thousands, such as a generated
// switch over 64-bit hashes, half of which are past `i64`. A key in `i64` is
// looked up by value. One past it is in `wide`, found by a hash of its digits:
// `first` names the newest entry with that hash, and `next` chains the earlier
// ones, each compared exactly. The zero value is an empty map that finds
// nothing.
Integer_Map :: struct($V: typeid) {
	small: map[i64]V,
	wide:  [dynamic]Wide_Entry(V),
	first: map[u64]int,
}

@(private = "file")
Wide_Entry :: struct($V: typeid) {
	key:   Big_Int,
	value: V,
	next:  int, // an earlier entry with the same hash, or -1
}

Integer_Set :: Integer_Map(struct {})

new_integer_map :: proc($V: typeid, capacity: int, allocator: mem.Allocator) -> Integer_Map(V) {
	return {
		small = make(map[i64]V, capacity, allocator),
		wide  = make([dynamic]Wide_Entry(V), allocator),
		first = make(map[u64]int, allocator),
	}
}

integer_map_find :: proc(c: Value_Storage, m: ^Integer_Map($V), key: Big_Int) -> (value: V, found: bool) {
	if small, fits := bi_to_i64(c, key); fits {
		return m.small[small]
	}
	at, hashed := m.first[bi_hash(key)]
	for hashed && at >= 0 {
		entry := m.wide[at]
		if bi_cmp(entry.key, key) == 0 {
			return entry.value, true
		}
		at = entry.next
	}
	return
}

// Maps `key` to `value` unless it already maps to one; whether it was new.
integer_map_add :: proc(c: Value_Storage, m: ^Integer_Map($V), key: Big_Int, value: V) -> bool {
	if _, found := integer_map_find(c, m, key); found {
		return false
	}
	if small, fits := bi_to_i64(c, key); fits {
		m.small[small] = value
		return true
	}
	hash := bi_hash(key)
	earlier, hashed := m.first[hash]
	append(&m.wide, Wide_Entry(V){key, value, hashed ? earlier : -1})
	m.first[hash] = len(m.wide) - 1
	return true
}

// Whether `value` is new to the set, adding it if so.
integer_set_add :: proc(c: Value_Storage, set: ^Integer_Set, value: Big_Int) -> bool {
	return integer_map_add(c, set, value, struct {}{})
}

// FNV-1a over the sign and the digits in use, which are canonical: equal
// integers hash alike.
@(private = "file")
bi_hash :: proc(v: Big_Int) -> u64 {
	hash := u64(0xcbf29ce484222325) ~ u64(v.sign)
	for digit in v.digit[:v.used] {
		hash = (hash ~ u64(digit)) * 0x100000001b3
	}
	return hash
}

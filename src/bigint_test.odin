// Boundary checks for `src/bigint.odin`, where a wrong fold would go unnoticed.
package lokec

import "core:c/libc"
import "core:math"
import "core:mem"
import "core:strings"
import "core:testing"

bi_eq_i64 :: proc(c: Value_Storage, a: Big_Int, b: i64) -> bool {
	return bi_cmp(a, bi_from_i64(c, b)) == 0
}

@(test)
bigint_truncated_division :: proc(t: ^testing.T) {
	c: Compiler
	defer destroy_compilation(&c)

	// Truncated towards zero: the remainder takes the dividend's sign.
	cases := [][4]i64{
		{7, 2, 3, 1},
		{-7, 2, -3, -1},
		{7, -2, -3, 1},
		{-7, -2, 3, -1},
	}
	for k in cases {
		a, b := bi_from_i64(&c, k[0]), bi_from_i64(&c, k[1])
		q, r := bi_quo(&c, a, b), bi_rem(&c, a, b)
		testing.expectf(t, bi_eq_i64(&c, q, k[2]), "%d / %d: expected %d, got %s", k[0], k[1], k[2], bi_text(&c, q))
		testing.expectf(t, bi_eq_i64(&c, r, k[3]), "%d %% %d: expected %d, got %s", k[0], k[1], k[3], bi_text(&c, r))
	}

	a := bi_neg(&c, bi_add(&c, bi_pow2(&c, 130), bi_from_i64(&c, 1)))
	three := bi_from_i64(&c, 3)
	q, r := bi_quo(&c, a, three), bi_rem(&c, a, three)
	testing.expectf(t, bi_eq_i64(&c, r, -2), "-(2^130 + 1) %% 3: got %s", bi_text(&c, r))
	testing.expect(t, bi_cmp(bi_add(&c, bi_mul(&c, q, three), r), a) == 0, "-(2^130 + 1) / 3 does not round-trip")
}

@(test)
bigint_width_boundaries :: proc(t: ^testing.T) {
	c: Compiler
	defer destroy_compilation(&c)

	u128_max, ok := bi_parse_int_literal(&c, "340282366920938463463374607431768211455")
	testing.expect(t, ok, "u128 max does not parse")
	testing.expect(t, bi_fits(u128_max, 128, false), "u128 max should fit u128")
	testing.expect(t, !bi_fits(u128_max, 128, true), "u128 max should not fit i128")
	testing.expectf(
		t,
		bi_text(&c, u128_max) == "340282366920938463463374607431768211455",
		"u128 max round-trip: %s",
		bi_text(&c, u128_max),
	)

	magnitude, magnitude_ok := bi_parse_int_literal(&c, "170141183460469231731687303715884105728")
	testing.expect(t, magnitude_ok, "i128 min's magnitude does not parse")
	i128_min := bi_neg(&c, magnitude)
	testing.expect(t, bi_fits(i128_min, 128, true), "i128 min should fit i128")
	testing.expect(t, !bi_fits(magnitude, 128, true), "i128 min's magnitude should not fit i128")

	testing.expect(t, bi_fits(bi_from_i64(&c, 127), 8, true), "127 fits i8")
	testing.expect(t, !bi_fits(bi_from_i64(&c, 128), 8, true), "128 does not fit i8")
	testing.expect(t, bi_fits(bi_from_i64(&c, -128), 8, true), "-128 fits i8")
	testing.expect(t, !bi_fits(bi_from_i64(&c, -129), 8, true), "-129 does not fit i8")
	testing.expect(t, bi_fits(bi_from_i64(&c, 255), 8, false), "255 fits u8")
	testing.expect(t, !bi_fits(bi_from_i64(&c, -1), 8, false), "-1 does not fit u8")
}

@(test)
bigint_machine_integers :: proc(t: ^testing.T) {
	c: Compiler
	defer destroy_compilation(&c)

	min64 := bi_neg(&c, bi_pow2(&c, 63))
	value, ok := bi_to_i64(&c, min64)
	testing.expectf(t, ok && value == min(i64), "i64 min: %v %v", value, ok)
	value, ok = bi_to_i64(&c, bi_sub(&c, bi_pow2(&c, 63), bi_from_i64(&c, 1)))
	testing.expectf(t, ok && value == max(i64), "i64 max: %v %v", value, ok)
	_, ok = bi_to_i64(&c, bi_pow2(&c, 63))
	testing.expect(t, !ok, "i64 max + 1 should not fit")
	_, ok = bi_to_i64(&c, bi_sub(&c, min64, bi_from_i64(&c, 1)))
	testing.expect(t, !ok, "i64 min - 1 should not fit")

	unsigned, unsigned_ok := bi_to_u64(&c, bi_sub(&c, bi_pow2(&c, 64), bi_from_i64(&c, 1)))
	testing.expectf(t, unsigned_ok && unsigned == max(u64), "u64 max: %v %v", unsigned, unsigned_ok)
	_, unsigned_ok = bi_to_u64(&c, bi_pow2(&c, 64))
	testing.expect(t, !unsigned_ok, "u64 max + 1 should not fit")
	_, unsigned_ok = bi_to_u64(&c, bi_from_i64(&c, -1))
	testing.expect(t, !unsigned_ok, "-1 should not fit u64")
}

@(test)
bigint_wrapping :: proc(t: ^testing.T) {
	c: Compiler
	defer destroy_compilation(&c)

	testing.expect(t, bi_eq_i64(&c, bi_wrap(&c, bi_from_i64(&c, 128), 8, true), -128), "128 wraps to -128 in i8")
	testing.expect(t, bi_eq_i64(&c, bi_wrap(&c, bi_from_i64(&c, 256), 8, false), 0), "256 wraps to 0 in u8")
	testing.expect(t, bi_eq_i64(&c, bi_wrap(&c, bi_from_i64(&c, -1), 8, false), 255), "-1 wraps to 255 in u8")
	testing.expect(t, bi_eq_i64(&c, bi_wrap(&c, bi_from_i64(&c, -1), 64, true), -1), "-1 stays -1 in i64")

	// Matches the backend's guarded runtime division.
	min64 := bi_neg(&c, bi_pow2(&c, 63))
	wrapped := bi_wrap(&c, bi_mul(&c, min64, bi_from_i64(&c, -1)), 64, true)
	testing.expectf(t, bi_cmp(wrapped, min64) == 0, "i64 min * -1 wrapped to %s", bi_text(&c, wrapped))

	wide := bi_sub(&c, bi_neg(&c, bi_pow2(&c, 100)), bi_from_i64(&c, 1))
	u64_max := bi_sub(&c, bi_pow2(&c, 64), bi_from_i64(&c, 1))
	wrapped = bi_wrap(&c, wide, 64, false)
	testing.expectf(t, bi_cmp(wrapped, u64_max) == 0, "-(2^100) - 1 in u64: %s", bi_text(&c, wrapped))
	testing.expect(t, bi_eq_i64(&c, bi_wrap(&c, wide, 64, true), -1), "-(2^100) - 1 wraps to -1 in i64")
}

@(test)
bigint_bitwise_and_shifts :: proc(t: ^testing.T) {
	c: Compiler
	defer destroy_compilation(&c)

	testing.expect(t, bi_eq_i64(&c, bi_not(&c, bi_from_i64(&c, 0)), -1), "~0 == -1")
	testing.expect(t, bi_eq_i64(&c, bi_not(&c, bi_from_i64(&c, 5)), -6), "~5 == -6")
	testing.expect(t, bi_eq_i64(&c, bi_and(&c, bi_from_i64(&c, -1), bi_from_i64(&c, 0xff)), 0xff), "-1 & 0xff")
	testing.expect(t, bi_eq_i64(&c, bi_or(&c, bi_from_i64(&c, -6), bi_from_i64(&c, 3)), -5), "-6 | 3 == -5")
	testing.expect(t, bi_eq_i64(&c, bi_xor(&c, bi_from_i64(&c, -6), bi_from_i64(&c, 3)), -7), "-6 ~ 3 == -7")
	testing.expect(t, bi_eq_i64(&c, bi_and_not(&c, bi_from_i64(&c, 0b1111), bi_from_i64(&c, 0b0101)), 0b1010), "15 &~ 5 == 10")
	testing.expect(t, bi_eq_i64(&c, bi_shr(&c, bi_from_i64(&c, -1), 200), -1), "-1 >> 200 == -1")
	testing.expect(t, bi_eq_i64(&c, bi_shr(&c, bi_from_i64(&c, 8), 200), 0), "8 >> 200 == 0")
	testing.expect(t, bi_eq_i64(&c, bi_shr(&c, bi_from_i64(&c, -7), 1), -4), "-7 >> 1 floors")

	wide := bi_shl(&c, bi_from_i64(&c, 1), 200)
	testing.expect(t, bi_magnitude_bits(wide) == 201, "1 << 200 has 201 magnitude bits")
	testing.expect(t, bi_eq_i64(&c, bi_shr(&c, wide, 200), 1), "(1 << 200) >> 200 == 1")

	// A shift under one 60-bit digit must drop the emptied top digit.
	shifted := bi_shr(&c, bi_pow2(&c, 120), 10)
	testing.expectf(t, bi_cmp(shifted, bi_pow2(&c, 110)) == 0, "(1 << 120) >> 10 == %s", bi_text(&c, shifted))
	testing.expect(t, bi_magnitude_bits(shifted) == 111, "(1 << 120) >> 10 has 111 magnitude bits")
}

@(test)
bigint_allocator_storage :: proc(t: ^testing.T) {
	buffer := make([]byte, 1 << 16)
	defer delete(buffer)
	arena: mem.Arena
	mem.arena_init(&arena, buffer)
	storage := mem.arena_allocator(&arena)

	value := bi_add(storage, bi_pow2(storage, 100), bi_from_i64(storage, 7))
	testing.expect(t, bi_cmp(bi_clone(storage, value), value) == 0, "clone differs from its source")
	testing.expectf(
		t,
		bi_text(storage, value) == "1267650600228229401496703205383",
		"2^100 + 7 in allocator storage: %s",
		bi_text(storage, value),
	)
}

@(test)
bigint_patterns :: proc(t: ^testing.T) {
	c: Compiler
	defer destroy_compilation(&c)

	two_to_127 := bi_pow2(&c, 127)
	i128_min := bi_neg(&c, two_to_127)
	testing.expect(t, bi_pattern(i128_min, 128) == u128(1) << 127, "i128 min's pattern")
	testing.expect(t, bi_cmp(bi_from_pattern(&c, u128(1) << 127, 128, true), i128_min) == 0, "i128 min from its pattern")
	testing.expect(t, bi_cmp(bi_from_pattern(&c, u128(1) << 127, 128, false), two_to_127) == 0, "2^127 from its pattern")
	testing.expect(t, bi_pattern(bi_from_i64(&c, -1), 128) == max(u128), "-1's 128-bit pattern")
	testing.expect(t, bi_eq_i64(&c, bi_from_pattern(&c, max(u128), 128, true), -1), "-1 from its 128-bit pattern")

	testing.expect(t, bi_pattern(bi_from_i64(&c, -1), 8) == 0xff, "-1's 8-bit pattern")
	testing.expect(t, bi_pattern(bi_from_i64(&c, -128), 8) == 0x80, "-128's 8-bit pattern")
	testing.expect(t, bi_pattern(bi_from_i64(&c, 0), 8) == 0, "0's pattern")
	testing.expect(t, bi_eq_i64(&c, bi_from_pattern(&c, 0x80, 8, true), -128), "-128 from its pattern")
	testing.expect(t, bi_eq_i64(&c, bi_from_pattern(&c, 0x7f, 8, true), 127), "127 from its pattern")
	testing.expect(t, bi_eq_i64(&c, bi_from_pattern(&c, 0xff, 8, false), 255), "255 from its pattern")

	// A digit boundary and a wider value: only the low bits survive.
	above := bi_add(&c, bi_pow2(&c, 60), bi_from_i64(&c, 3))
	testing.expect(t, bi_pattern(above, 64) == (u128(1) << 60) + 3, "2^60 + 3's pattern")
	testing.expect(t, bi_pattern(bi_add(&c, bi_pow2(&c, 200), bi_from_i64(&c, 5)), 16) == 5, "a wider value's low bits")
}

// design.md "Compile-time procedure evaluation": what a bit cast builds during
// an evaluation counts against that evaluation's limit.
@(test)
a_constant_bit_cast_builds_in_the_storage_it_is_given :: proc(t: ^testing.T) {
	c: Compiler
	defer destroy_compilation(&c)
	build_universe(&c)
	bytes := array_of(&c, TYPE_U8, 4)
	type_size(&c, bytes)

	buffer := make([]byte, 1 << 16)
	defer delete(buffer)
	arena: mem.Arena
	mem.arena_init(&arena, buffer)

	value := integer_const(bi_from_u64(&c, 0x8040_2010))
	semantic_before := c.semantic_arena.total_used
	folded, status := transmute_const(&c, value, TYPE_U32, bytes, mem.arena_allocator(&arena))
	testing.expect(t, status == .Folded, "the bit cast did not fold")
	testing.expect(t, arena.offset > 0, "nothing was built in the given storage")
	testing.expect(t, c.semantic_arena.total_used == semantic_before, "the bit cast grew the semantic arena")
	if status == .Folded {
		testing.expect(t, bi_eq_i64(&c, folded.aggregate.elements[3].integer, 0x80), "the last byte of the result")
	}
}

@(test)
bigint_to_float_rounds_once :: proc(t: ^testing.T) {
	c: Compiler
	defer destroy_compilation(&c)

	two := proc(c: ^Compiler, power: int, plus: i64) -> Big_Int {
		return bi_add(c, bi_pow2(c, power), bi_from_i64(c, plus))
	}
	cases := []struct{value: Big_Int, bits: u16, want: f64, ok: bool} {
		{two(&c, 53, 1), 64, 9007199254740992.0, true},
		{two(&c, 53, 3), 64, 9007199254740996.0, true},
		{bi_neg(&c, two(&c, 53, 3)), 64, -9007199254740996.0, true},
		// Sticky bits past the first 64 still round up.
		{bi_add(&c, two(&c, 120, 1), bi_pow2(&c, 67)), 64, 0h47700000_00000001, true},
		{bi_sub(&c, bi_pow2(&c, 1024), bi_pow2(&c, 971)), 64, 0h7FEF_FFFF_FFFF_FFFF, true},
		{bi_sub(&c, bi_pow2(&c, 1024), bi_pow2(&c, 970)), 64, 0, false},
		{bi_pow2(&c, 1100), 64, 0, false},
		{bi_from_i64(&c, 16777217), 32, 16777216.0, true},
		{bi_from_i64(&c, 16777219), 32, 16777220.0, true},
		{bi_pow2(&c, 128), 32, 0, false},
		{bi_from_i64(&c, 2049), 16, 2048.0, true},
		{bi_from_i64(&c, 65519), 16, 65504.0, true},
		{bi_from_i64(&c, 65520), 16, 0, false},
	}
	for k, index in cases {
		value, ok := bi_to_float(&c, k.value, k.bits)
		testing.expectf(t, ok == k.ok, "case %d: fits %v, expected %v", index, ok, k.ok)
		if k.ok {
			testing.expectf(t, value == k.want, "case %d: %v, expected %v", index, value, k.want)
		}
	}

	testing.expect(t, bi_cmp_float(&c, two(&c, 53, 1), 9007199254740992.0) == 1, "2^53 + 1 > 2^53 exactly")
	testing.expect(t, bi_cmp_float(&c, bi_from_i64(&c, -3), -2.5) == -1, "-3 < -2.5")
	testing.expect(t, bi_cmp_float(&c, bi_from_i64(&c, -2), -2.5) == 1, "-2 > -2.5")
	testing.expect(t, bi_cmp_float(&c, bi_from_i64(&c, 2), 2.5) == -1, "2 < 2.5")
	testing.expect(t, bi_cmp_float(&c, bi_from_i64(&c, 5), 5.0) == 0, "5 == 5.0")
	testing.expect(t, bi_cmp_float(&c, bi_pow2(&c, 1100), 0h7FEF_FFFF_FFFF_FFFF) == 1, "2^1100 > max f64")
	testing.expect(t, bi_cmp_float(&c, bi_pow2(&c, 1100), 0h7FF0_0000_0000_0000) == -1, "2^1100 < +inf")
	testing.expect(t, bi_cmp_float(&c, bi_neg(&c, bi_pow2(&c, 1100)), 0hFFF0_0000_0000_0000) == 1, "-2^1100 > -inf")
}

// Odin's f16 conversion rounds ties away from zero; LLVM's `half` rounds to even.
@(test)
bigint_f16_rounds_ties_to_even :: proc(t: ^testing.T) {
	cases := []struct{value: f64, bits: u16, rounded: f64} {
		{0.0, 0x0000, 0.0},
		{-0.0, 0x8000, -0.0},
		{1.0, 0x3C00, 1.0},
		{-2.0, 0xC000, -2.0},
		{2049.0, 0x6800, 2048.0},
		{-2049.0, 0xE800, -2048.0},
		{2051.0, 0x6802, 2052.0},
		{2047.0, 0x67FF, 2047.0},
		{65504.0, 0x7BFF, 65504.0},
		{65520.0, 0x7C00, 0h7ff0000000000000},
		{0.00006103515625, 0x0400, 0.00006103515625},
		{0.000000059604645, 0x0001, 0.000000059604644775390625},
		// 1.5 * 2^-24, a subnormal tie.
		{0.0000000894069671630859375, 0x0002, 0.00000011920928955078125},
		{0.00000001, 0x0000, 0.0},
	}
	for k in cases {
		bits := f64_to_f16_bits(k.value)
		testing.expectf(t, bits == k.bits, "f16(%v): expected 0x%04X, got 0x%04X", k.value, k.bits, bits)
		rounded := round_float(k.value, 16)
		testing.expectf(t, rounded == k.rounded, "round_float(%v, 16): expected %v, got %v", k.value, k.rounded, rounded)
	}
	testing.expect(t, round_float(16777217.0, 32) == 16777216.0, "f32 drops the 25th bit")
	testing.expect(t, round_float(16777217.0, 64) == 16777217.0, "f64 keeps it")
}

@(test)
bigint_literal_spellings :: proc(t: ^testing.T) {
	c: Compiler
	defer destroy_compilation(&c)

	spellings := []struct{text: string, value: i64}{
		{"0", 0},
		{"1_000_000", 1000000},
		{"0xff", 255},
		{"0xFF_FF", 65535},
		{"0b1010", 10},
		{"0o777", 511},
		{"1_", 1},
		{"-5", -5},
		{"-0x10", -16},
	}
	for s in spellings {
		value, ok := bi_parse_int_literal(&c, s.text)
		if !ok {
			testing.expectf(t, false, "%s does not parse", s.text)
			continue
		}
		testing.expectf(t, bi_eq_i64(&c, value, s.value), "%s folded to %s", s.text, bi_text(&c, value))
	}

	// `-define:NAME=VALUE` passes arbitrary text and reads a rejection as a string.
	rejected := []string{"0X10", "0B10", "0O10", "12abc", "", "0x", "0x-5", "_7", "-", "--5", "0b102", "0x_", "+5"}
	for bad in rejected {
		_, ok := bi_parse_int_literal(&c, bad)
		testing.expectf(t, !ok, "`%s` parsed as an integer", bad)
	}
}

@(test)
bigint_from_float_truncation :: proc(t: ^testing.T) {
	c: Compiler
	defer destroy_compilation(&c)

	integer, exact := bi_from_f64_trunc(&c, 1.0)
	testing.expect(t, exact && bi_eq_i64(&c, integer, 1), "1.0 should be the exact integer 1")

	integer, exact = bi_from_f64_trunc(&c, -2.75)
	testing.expect(t, !exact && bi_eq_i64(&c, integer, -2), "-2.75 should truncate towards zero")

	// 2^100 must not pass through i64.
	integer, exact = bi_from_f64_trunc(&c, 0h4630000000000000)
	testing.expect(t, exact, "2^100 should be an exact integer")
	testing.expect(t, bi_cmp(integer, bi_pow2(&c, 100)) == 0, "2^100 was truncated through a machine integer")

	cases := []struct{value: f64, want: i64, exact: bool} {
		{0, 0, true},
		{0h8000_0000_0000_0000, 0, true},
		{0h0000_0000_0000_0001, 0, false},
		{0h3FEF_FFFF_FFFF_FFFF, 0, false},
		{-0.5, 0, false},
		{-1, -1, true},
		{2251799813685248.5, 2251799813685248, false},
		{9007199254740992, 9007199254740992, true},
		{-4503599627370497, -4503599627370497, true},
	}
	for k in cases {
		truncated, is_exact := bi_from_f64_trunc(&c, k.value)
		testing.expectf(t, bi_eq_i64(&c, truncated, k.want) && is_exact == k.exact, "%v truncated to %s, exact %v", k.value, bi_text(&c, truncated), is_exact)
	}
}

// A negative value with as many magnitude bits as the width fits only as the
// lowest value: its top bit alone, whichever digit a further bit would be in.
@(test)
bigint_fits_only_the_lowest_at_the_full_width :: proc(t: ^testing.T) {
	c: Compiler
	defer destroy_compilation(&c)

	lowest := bi_neg(&c, bi_pow2(&c, 127))
	testing.expect(t, bi_fits(lowest, 128, true), "i128 min fits i128")
	for bit in ([]int{0, 62, 63, 64, 119, 125, 126}) {
		testing.expectf(t, !bi_fits(bi_sub(&c, lowest, bi_pow2(&c, bit)), 128, true), "i128 min - 2^%d fits i128", bit)
	}
	testing.expect(t, bi_fits(bi_from_i64(&c, -1), 1, true), "-1 fits i1")
	testing.expect(t, bi_fits(bi_zero(&c), 1, true), "0 fits i1")
	testing.expect(t, !bi_fits(bi_from_i64(&c, 1), 1, true), "1 does not fit i1")
	testing.expect(t, !bi_fits(bi_zero(&c), 0, false), "nothing fits no bits")
}

@(test)
bigint_results_keep_no_more_than_they_need :: proc(t: ^testing.T) {
	c: Compiler
	defer destroy_compilation(&c)

	value := bi_from_i64(&c, -5)
	wrapped := bi_wrap(&c, value, 8, true)
	testing.expect(t, raw_data(wrapped.digit) == raw_data(value.digit), "a value in range wraps to itself")

	clone := bi_clone(&c, value)
	testing.expect(t, cap(clone.digit) < cap(value.digit), "a clone keeps only the digits it uses")
	testing.expect(t, bi_eq_i64(&c, clone, -5), "the clone holds the value")
}

// Above and below the 160-digit divisor where `int_divmod` would go wrong.
@(test)
bigint_long_division_round_trips :: proc(t: ^testing.T) {
	c: Compiler
	defer destroy_compilation(&c)

	a := bi_neg(&c, bi_add(&c, bi_pow2(&c, 60 * 600), bi_from_i64(&c, 12345)))
	for b in ([]Big_Int{bi_add(&c, bi_pow2(&c, 60 * 200), bi_from_i64(&c, 7)), bi_from_i64(&c, 1000), bi_pow2(&c, 60 * 700)}) {
		q, r := bi_quo(&c, a, b), bi_rem(&c, a, b)
		testing.expect(t, bi_cmp(bi_add(&c, bi_mul(&c, q, b), r), a) == 0, "a / b does not round-trip")
		testing.expect(t, bi_sign(r) == -1, "the remainder takes the dividend's sign")
		testing.expect(t, bi_magnitude_bits(r) <= bi_magnitude_bits(b), "the remainder is below the divisor")
	}
}

@(test)
bigint_powers_of_ten :: proc(t: ^testing.T) {
	c: Compiler
	defer destroy_compilation(&c)

	for power in ([]int{0, 1, 2, 3, 18, 19, 100, 5000}) {
		testing.expectf(t, bi_text(&c, bi_pow10(&c, power)) == strings.concatenate({"1", strings.repeat("0", power, context.temp_allocator)}, context.temp_allocator), "10^%d", power)
	}
}

// One rounding of the exact value, at the ties that a second rounding or a lost
// sticky bit gets wrong, and below the normal range.
@(test)
decimal_to_float_rounds_once :: proc(t: ^testing.T) {
	c: Compiler
	defer destroy_compilation(&c)

	cases := []struct{text: string, bits: u16, want: u64} {
		// A tie to even, and just past it.
		{"1.00048828125", 16, 0x3FF0_0000_0000_0000},
		{"1.000488281250000001", 16, 0x3FF0_0400_0000_0000},
		{"1.000000059604644775390625", 32, 0x3FF0_0000_0000_0000},
		{"1.000000059604644775390625000001", 32, 0x3FF0_0000_2000_0000},
		// Half the smallest subnormal, the tie, and just past it.
		{"2.98023223876953125e-08", 16, 0},
		{"2.98023223876953126e-08", 16, 0x3E70_0000_0000_0000},
		{"7.006492321624085e-46", 32, 0},
		{"7.0064923216240854e-46", 32, 0x36A0_0000_0000_0000},
		// An exponent that decides the result before any power is built.
		{"1e-99999999999", 32, 0},
		{"-1e-99999999999", 32, 0x8000_0000_0000_0000},
		{"-0.0", 16, 0x8000_0000_0000_0000},
		{"-1.5", 32, 0xBFF8_0000_0000_0000},
		{"125e-3", 32, 0x3FC0_0000_0000_0000},
		{"12e3", 16, 0x40C7_7000_0000_0000},
		// A fraction past the width's largest value is an infinity for the caller to see.
		{"400000000000000000000000000000000000000.5", 32, 0x7FF0_0000_0000_0000},
	}
	for k in cases {
		value, ok := decimal_to_float(&c, k.text, k.bits)
		testing.expectf(t, ok && transmute(u64)value == k.want, "%s as f%d: %v, ok %v", k.text, k.bits, value, ok)
	}

	for text in ([]string{"", "-", "1e", "1e+", "1e5x", "0x10", "1_000.0", "1e39", "99e39"}) {
		_, ok := decimal_to_float(&c, text, 32)
		testing.expectf(t, !ok, "%q as f32 should fall to the caller", text)
	}
	_, ok := decimal_to_float(&c, "1.5", 64)
	testing.expect(t, !ok, "a 64-bit width is the caller's binary64 value")

	zeros := strings.repeat("0", 20000, context.temp_allocator)
	long := strings.concatenate({"1", zeros, "e-20000"}, context.temp_allocator)
	value: f64
	value, ok = decimal_to_float(&c, long, 32)
	testing.expect(t, ok && value == 1, "1 spelled with 20,000 zeros and their exponent")
}

// What these build in evaluator storage goes back to it: only a result the
// caller holds stays charged (eval_memory.odin).
@(test)
bigint_evaluator_storage_keeps_only_results :: proc(t: ^testing.T) {
	storage: Eval_Storage
	defer eval_storage_destroy(&storage)
	alloc := mem.Allocator{eval_allocator_proc, &storage}

	wide := bi_neg(alloc, bi_pow2(alloc, 300))
	small := bi_from_i64(alloc, 100)
	before := storage.bytes

	bi_to_float(alloc, wide, 64)
	bi_to_float(alloc, small, 32)
	testing.expect(t, storage.bytes == before, "bi_to_float keeps a temporary")
	bi_cmp_float(alloc, wide, -2.5)
	testing.expect(t, storage.bytes == before, "bi_cmp_float keeps a temporary")
	for text in ([]string{"1.000000059604644775390625000001", "123456789e20", "1e39", "1e-60", "-0.0", "1e-40"}) {
		decimal_to_float(alloc, text, 32)
		testing.expectf(t, storage.bytes == before, "decimal_to_float keeps a temporary for %s", text)
	}
	bi_fits(wide, 300, true)
	testing.expect(t, bi_wrap(alloc, small, 8, false).used != 0 && storage.bytes == before, "a value in range builds nothing")

	for value in ([]f64{-2.75, 1.5, 0h4630000000000000, 0.25}) {
		truncated, _ := bi_from_f64_trunc(alloc, value)
		bi_release(truncated)
		testing.expectf(t, storage.bytes == before, "bi_from_f64_trunc keeps a temporary for %v", value)
	}
	results := []Big_Int{bi_quo(alloc, wide, small), bi_rem(alloc, wide, small), bi_wrap(alloc, wide, 64, true), bi_wrap(alloc, wide, 8, false)}
	for result in results {
		bi_release(result)
	}
	testing.expect(t, storage.bytes == before, "an integer operation keeps more than its result")
}

// An empty request is a small block like any other: it is served from the
// arena and its release puts it on a free list, at every alignment.
@(test)
evaluator_storage_serves_empty_requests :: proc(t: ^testing.T) {
	storage: Eval_Storage
	defer eval_storage_destroy(&storage)
	alloc := mem.Allocator{eval_allocator_proc, &storage}
	for alignment in ([]int{1, 16, 32, 64}) {
		for _ in 0 ..< 2 {
			// Directly: `mem.alloc_bytes` answers an empty request itself.
			block, err := alloc.procedure(alloc.data, .Alloc, 0, alignment, nil, 0)
			testing.expectf(t, err == nil && raw_data(block) != nil, "an empty request at alignment %d failed", alignment)
			testing.expectf(t, storage.large == nil, "an empty request at alignment %d went to the heap", alignment)
			mem.free(raw_data(block), alloc)
			testing.expectf(t, storage.bytes == 0, "an empty block at alignment %d stayed charged", alignment)
		}
	}
}

// `exact_fma`, the compile-time value of `core:math`'s FMA instruction, at the
// boundaries where rounding once differs from rounding twice or from the
// host's arithmetic: a product that is itself a tie, results below the normal
// range, overflow, and cancellation. Each expectation is an encoding.
@(test)
exact_fma_rounds_once :: proc(t: ^testing.T) {
	c: Compiler
	defer destroy_compilation(&c)

	p2 :: proc(exponent: int) -> f64 { return math.ldexp(1.0, exponent) }
	a := 1.0 + p2(-27)
	b := 1.0 + p2(-26)
	min_subnormal := transmute(f64)u64(1)
	min_normal := transmute(f64)u64(1 << 52)
	Case :: struct {
		a, b, c:  f64,
		bits:     u16,
		expected: u64,
	}
	cases := []Case {
		// `a*a` is `1 + 2^-26 + 2^-54`; the fused remainder keeps the last term.
		{a, a, -(a*a), 64, transmute(u64)p2(-54)},
		// A tie at the product's last place goes to even, unless an addend far
		// below it says which way.
		{a, b, 0, 64, transmute(u64)(1.0 + p2(-26) + p2(-27))},
		{a, b, min_subnormal, 64, transmute(u64)(1.0 + p2(-26) + p2(-27) + p2(-52))},
		// Gradual underflow, rounded at the subnormal's own last place.
		{min_normal, 0.5, 0, 64, 1 << 51},
		{min_subnormal, 0.75, 0, 64, 1},
		{min_subnormal, 0.5, 0, 64, 0},
		{min_subnormal, 0.5, min_subnormal, 64, 2},
		{-min_subnormal, 0.5, 0, 64, 1 << 63},
		// The product never overflows on its own, and the sum may.
		{1.0e308, 2.0, -1.0e308, 64, transmute(u64)f64(1.0e308)},
		{1.0e308, 2.0, 0, 64, transmute(u64)math.INF_F64},
		{1.0e308, 2.0, math.NEG_INF_F64, 64, transmute(u64)math.NEG_INF_F64},
		// Exact cancellation is +0 under rounding to nearest.
		{1.5, 2.0, -3.0, 64, 0},
		// `f32` rounds once at its own width, not at `f64`'s first.
		{f64(f32(1.0 + p2(-12))), f64(f32(1.0 - p2(-13))), -1.0, 32, u64(transmute(u32)f32(p2(-13) - p2(-25)))},
		// Half the smallest `f32` subnormal ties to even, and more rounds up.
		{p2(-75), p2(-75), 0, 32, 0},
		{p2(-75), 1.5*p2(-75), 0, 32, 1},
		{p2(100), p2(28), 0, 32, u64(transmute(u32)math.INF_F32)},
	}
	for k in cases {
		got := exact_fma(&c, k.a, k.b, k.c, k.bits)
		pattern := k.bits == 32 ? u64(transmute(u32)f32(got)) : transmute(u64)got
		testing.expectf(t, pattern == k.expected, "fma(%v, %v, %v) at %d bits: expected %x, got %x", k.a, k.b, k.c, k.bits, k.expected, pattern)
	}
}

// `exact_sqrt`, the compile-time value of `core:math`'s square root
// instruction, against the compiling machine's, which IEEE 754 makes
// correctly rounded too: the arguments whose roots come nearest a midpoint,
// 1 - 2^-53 and 1 + 2^-52 and their `f32` counterparts, where narrowing the
// `f64` root comes closest to rounding twice; the smallest subnormals; the
// largest values; and seeded patterns of every magnitude. The special cases
// are the x86-64 instruction's.
@(test)
exact_sqrt_matches_the_instruction :: proc(t: ^testing.T) {
	check64 :: proc(t: ^testing.T, x: f64) {
		got := exact_sqrt(float_const(x, 64))
		want := transmute(u64)math.sqrt(x)
		testing.expectf(t, got.float_raw == want, "sqrt(%x): expected %x, got %x", transmute(u64)x, want, got.float_raw)
	}
	check32 :: proc(t: ^testing.T, x: f32) {
		got := exact_sqrt(float_const(f64(x), 32))
		want := u64(transmute(u32)math.sqrt(x))
		testing.expectf(t, got.float_raw == want, "sqrt_f32(%x): expected %x, got %x", transmute(u32)x, want, got.float_raw)
	}
	for pattern in ([]u64{1, 2, 3, 4, 0x000fffffffffffff, 0x0010000000000000, 0x3fefffffffffffff, 0x3ff0000000000001, 0x4002000000000000, 0x7fefffffffffffff}) {
		check64(t, transmute(f64)pattern)
	}
	for pattern in ([]u32{1, 2, 4, 0x007fffff, 0x3f7fffff, 0x3f800001, 0x40100000, 0x7f7fffff}) {
		check32(t, transmute(f32)pattern)
	}
	state: u64 = 0x6a09e667f3bcc908
	for i in 0 ..< 20000 {
		state = state*6364136223846793005 + 1442695040888963407
		pattern := (state >> 1) & 0x7fefffffffffffff
		if i % 4 == 0 {
			pattern &= 0x000fffffffffffff
		}
		if pattern != 0 {
			check64(t, transmute(f64)pattern)
		}
		pattern32 := u32(state >> 33) & 0x7f7fffff
		if pattern32 != 0 {
			check32(t, transmute(f32)pattern32)
		}
	}

	negative_zero := exact_sqrt(float_const(math.copy_sign(f64(0), -1), 64))
	testing.expectf(t, negative_zero.float_raw == 0x8000000000000000, "sqrt(-0) is %x", negative_zero.float_raw)
	infinity := exact_sqrt(float_const(math.INF_F64, 64))
	testing.expectf(t, infinity.float_raw == 0x7ff0000000000000, "sqrt(+Inf) is %x", infinity.float_raw)
	negative := exact_sqrt(float_const(-1, 32))
	testing.expectf(t, negative.float_raw == 0xffc00000, "sqrt_f32(-1) is %x", negative.float_raw)
	signaling := exact_sqrt(float_bits_const(0x7ff0000000000001, 64))
	testing.expectf(t, signaling.float_raw == 0x7ff8000000000001, "sqrt(sNaN) is %x", signaling.float_raw)
}

// The C library's `floor`, `ceil`, `trunc`, and `round` are exact, as the
// instructions are, so they are the reference: at the boundaries where the
// fraction is a half or just below one, near 2^52 and 2^23, at zeros of both
// signs, and at seeded patterns of every sign and of exponents around the
// integral range.
@(test)
exact_integral_matches_the_c_library :: proc(t: ^testing.T) {
	check64 :: proc(t: ^testing.T, x: f64) {
		for builtin, i in ([]Builtin_Kind{.Math_Floor_Instruction, .Math_Ceil_Instruction, .Math_Trunc_Instruction, .Math_Round_Instruction}) {
			got := exact_integral(float_const(x, 64), builtin)
			want := transmute(u64)([]f64{libc.floor(x), libc.ceil(x), libc.trunc(x), libc.round(x)}[i])
			testing.expectf(t, got.float_raw == want, "%v(%x): expected %x, got %x", builtin, transmute(u64)x, want, got.float_raw)
		}
	}
	check32 :: proc(t: ^testing.T, x: f32) {
		for builtin, i in ([]Builtin_Kind{.Math_Floor_Instruction, .Math_Ceil_Instruction, .Math_Trunc_Instruction, .Math_Round_Instruction}) {
			got := exact_integral(float_const(f64(x), 32), builtin)
			want := u64(transmute(u32)([]f32{libc.floor(x), libc.ceil(x), libc.trunc(x), libc.round(x)}[i]))
			testing.expectf(t, got.float_raw == want, "%v_f32(%x): expected %x, got %x", builtin, transmute(u32)x, want, got.float_raw)
		}
	}
	for x in ([]f64{0.5, 0.49999999999999994, 1.5, 2.5, 0.25, 1, 4503599627370495.5, 4503599627370496, 4503599627370497, 2251799813685247.5, 1e300, math.INF_F64}) {
		check64(t, x)
		check64(t, -x)
	}
	check64(t, 0)
	check64(t, math.copy_sign(f64(0), -1))
	for x in ([]f32{0.5, 0.49999997, 1.5, 2.5, 8388607.5, 8388608, 8388609, 4194303.5, 3e38}) {
		check32(t, x)
		check32(t, -x)
	}
	check32(t, 0)
	check32(t, math.copy_sign(f32(0), -1))
	state: u64 = 0xbb67ae8584caa73b
	for _ in 0 ..< 20000 {
		state = state*6364136223846793005 + 1442695040888963407
		// Exponents from 2^-4 to 2^59, either sign.
		pattern := (state & 0x800fffffffffffff) | (1019 + (state >> 52) % 64) << 52
		check64(t, transmute(f64)pattern)
		pattern32 := u32(state >> 32) & 0x807fffff | (123 + u32(state >> 24) % 32) << 23
		check32(t, transmute(f32)pattern32)
	}

	signaling := exact_integral(float_bits_const(0x7ff0000000000001, 64), .Math_Floor_Instruction)
	testing.expectf(t, signaling.float_raw == 0x7ff8000000000001, "floor(sNaN) is %x", signaling.float_raw)
}

// The C library's `fmod` is exact, as `exact_mod` is, so it is the reference:
// at the cases where the divisor is infinite, larger than the dividend, or
// equal to it, at subnormals and near multiples, and at seeded patterns of
// every exponent, either sign, and in both widths.
@(test)
exact_mod_matches_the_c_library :: proc(t: ^testing.T) {
	check64 :: proc(t: ^testing.T, x, y: f64) {
		got := exact_mod(float_const(x, 64), float_const(y, 64))
		want := libc.fmod(x, y)
		if math.is_nan(want) {
			testing.expectf(t, math.is_nan(got.float), "mod(%x, %x): expected a NaN, got %x", transmute(u64)x, transmute(u64)y, got.float_raw)
			return
		}
		testing.expectf(t, got.float_raw == transmute(u64)want, "mod(%x, %x): expected %x, got %x", transmute(u64)x, transmute(u64)y, transmute(u64)want, got.float_raw)
	}
	check32 :: proc(t: ^testing.T, x, y: f32) {
		got := exact_mod(float_const(f64(x), 32), float_const(f64(y), 32))
		want := libc.fmod(x, y)
		if math.is_nan(want) {
			testing.expectf(t, math.is_nan(got.float), "mod_f32(%x, %x): expected a NaN, got %x", transmute(u32)x, transmute(u32)y, got.float_raw)
			return
		}
		testing.expectf(t, got.float_raw == u64(transmute(u32)want), "mod_f32(%x, %x): expected %x, got %x", transmute(u32)x, transmute(u32)y, transmute(u32)want, got.float_raw)
	}
	values := []f64{0, 1, 1.5, 3, 7, 0.1, 1e300, 1.7976931348623157e308, 5e-324, 2.2250738585072014e-308, math.INF_F64, math.nan_f64()}
	for x in values {
		for y in values {
			check64(t, x, y)
			check64(t, -x, y)
			check64(t, x, -y)
			check64(t, f64(f32(x)), f64(f32(y)))
			check32(t, f32(x), f32(y))
			check32(t, -f32(x), f32(y))
		}
	}
	state: u64 = 0x3c6ef372fe94f82b
	for _ in 0 ..< 20000 {
		state = state*6364136223846793005 + 1442695040888963407
		x := state
		state = state*6364136223846793005 + 1442695040888963407
		y := state
		// Finite patterns of every exponent, and dividends near multiples.
		x &~= 0x4000000000000000 * u64((x >> 52) & 0x7ff == 0x7ff)
		y &~= 0x4000000000000000 * u64((y >> 52) & 0x7ff == 0x7ff)
		a, b := transmute(f64)x, transmute(f64)y
		check64(t, a, b)
		check64(t, b*f64(x % 1000) + b*0.001*f64(y % 7), b)
		check32(t, transmute(f32)u32(x >> 32), transmute(f32)u32(y >> 32))
	}
}

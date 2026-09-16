// The runnable check behind `src/bigint.odin`: the exact behaviours the
// constant folder depends on, at the boundaries where a wrong answer would be
// invisible in ordinary programs.
package lokec

import "core:testing"

@(private = "file")
text :: proc(c: ^Compiler, v: Big_Int) -> string {
	return bi_text(c, v)
}

@(test)
bigint_truncated_division :: proc(t: ^testing.T) {
	c: Compiler
	defer destroy_compilation(&c)

	// design.md "Integer operators": q truncates towards zero and |r| < |y|,
	// which fixes the sign of the remainder to the sign of the dividend.
	cases := [][4]i64{
		{7, 2, 3, 1},
		{-7, 2, -3, -1},
		{7, -2, -3, 1},
		{-7, -2, 3, -1},
	}
	for k in cases {
		a, b := bi_from_i64(&c, k[0]), bi_from_i64(&c, k[1])
		testing.expectf(
			t,
			bi_eq_i64(&c, bi_quo(&c, a, b), k[2]),
			"%d / %d: expected %d, got %s",
			k[0], k[1], k[2], text(&c, bi_quo(&c, a, b)),
		)
		testing.expectf(
			t,
			bi_eq_i64(&c, bi_rem(&c, a, b), k[3]),
			"%d %% %d: expected %d, got %s",
			k[0], k[1], k[3], text(&c, bi_rem(&c, a, b)),
		)
	}
}

@(test)
bigint_width_boundaries :: proc(t: ^testing.T) {
	c: Compiler
	defer destroy_compilation(&c)

	u128_max, ok := bi_parse_int_literal(&c, "340282366920938463463374607431768211455")
	testing.expect(t, ok, "u128 max does not parse")
	testing.expect(t, bi_fits(&c, u128_max, 128, false), "u128 max should fit u128")
	testing.expect(t, !bi_fits(&c, u128_max, 128, true), "u128 max should not fit i128")
	testing.expectf(
		t,
		text(&c, u128_max) == "340282366920938463463374607431768211455",
		"u128 max round-trip: %s",
		text(&c, u128_max),
	)

	// `i128::min` is spelled `-170141183460469231731687303715884105728`; the
	// magnitude alone is not representable by any signed type, which is the whole
	// reason folding does not use i128.
	magnitude, _ := bi_parse_int_literal(&c, "170141183460469231731687303715884105728")
	i128_min := bi_neg(&c, magnitude)
	testing.expect(t, bi_fits(&c, i128_min, 128, true), "i128 min should fit i128")
	testing.expect(t, !bi_fits(&c, magnitude, 128, true), "i128 min's magnitude should not fit i128")

	testing.expect(t, bi_fits(&c, bi_from_i64(&c, 127), 8, true), "127 fits i8")
	testing.expect(t, !bi_fits(&c, bi_from_i64(&c, 128), 8, true), "128 does not fit i8")
	testing.expect(t, bi_fits(&c, bi_from_i64(&c, -128), 8, true), "-128 fits i8")
	testing.expect(t, !bi_fits(&c, bi_from_i64(&c, -129), 8, true), "-129 does not fit i8")
	testing.expect(t, bi_fits(&c, bi_from_i64(&c, 255), 8, false), "255 fits u8")
	testing.expect(t, !bi_fits(&c, bi_from_i64(&c, -1), 8, false), "-1 does not fit u8")
}

@(test)
bigint_wrapping :: proc(t: ^testing.T) {
	c: Compiler
	defer destroy_compilation(&c)

	testing.expect(t, bi_eq_i64(&c, bi_wrap(&c, bi_from_i64(&c, 128), 8, true), -128), "128 wraps to -128 in i8")
	testing.expect(t, bi_eq_i64(&c, bi_wrap(&c, bi_from_i64(&c, 256), 8, false), 0), "256 wraps to 0 in u8")
	testing.expect(t, bi_eq_i64(&c, bi_wrap(&c, bi_from_i64(&c, -1), 8, false), 255), "-1 wraps to 255 in u8")
	testing.expect(t, bi_eq_i64(&c, bi_wrap(&c, bi_from_i64(&c, -1), 64, true), -1), "-1 stays -1 in i64")

	// i64::min * -1 wraps back to i64::min, the same value the backend's guarded
	// division produces at runtime.
	min64 := bi_neg(&c, bi_pow2(&c, 63))
	wrapped := bi_wrap(&c, bi_mul(&c, min64, bi_from_i64(&c, -1)), 64, true)
	testing.expectf(t, bi_cmp(&c, wrapped, min64) == 0, "i64 min * -1 wrapped to %s", text(&c, wrapped))
}

@(test)
bigint_bitwise_and_shifts :: proc(t: ^testing.T) {
	c: Compiler
	defer destroy_compilation(&c)

	testing.expect(t, bi_eq_i64(&c, bi_not(&c, bi_from_i64(&c, 0)), -1), "~0 == -1")
	testing.expect(t, bi_eq_i64(&c, bi_not(&c, bi_from_i64(&c, 5)), -6), "~5 == -6")
	testing.expect(t, bi_eq_i64(&c, bi_and(&c, bi_from_i64(&c, -1), bi_from_i64(&c, 0xff)), 0xff), "-1 & 0xff")
	testing.expect(t, bi_eq_i64(&c, bi_and_not(&c, bi_from_i64(&c, 0b1111), bi_from_i64(&c, 0b0101)), 0b1010), "&~")
	testing.expect(t, bi_eq_i64(&c, bi_shr(&c, bi_from_i64(&c, -1), 200), -1), "-1 >> 200 == -1")
	testing.expect(t, bi_eq_i64(&c, bi_shr(&c, bi_from_i64(&c, 8), 200), 0), "8 >> 200 == 0")
	testing.expect(t, bi_eq_i64(&c, bi_shr(&c, bi_from_i64(&c, -7), 1), -4), "-7 >> 1 floors")

	// An untyped shift is exact, however far past any runtime width it goes.
	wide := bi_shl(&c, bi_from_i64(&c, 1), 200)
	testing.expect(t, bi_magnitude_bits(&c, wide) == 201, "1 << 200 has 201 magnitude bits")
	testing.expect(t, bi_eq_i64(&c, bi_shr(&c, wide, 200), 1), "(1 << 200) >> 200 == 1")

	// A shift under one 60-bit digit still drops the emptied top digit.
	shifted := bi_shr(&c, bi_pow2(&c, 120), 10)
	testing.expectf(t, bi_cmp(&c, shifted, bi_pow2(&c, 110)) == 0, "(1 << 120) >> 10 == %s", text(&c, shifted))
	testing.expect(t, bi_magnitude_bits(&c, shifted) == 111, "(1 << 120) >> 10 has 111 magnitude bits")
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
		// Bits past the first 64 still round up.
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
	testing.expect(t, bi_cmp_float(&c, bi_from_i64(&c, 5), 5.0) == 0, "5 == 5.0")
	testing.expect(t, bi_cmp_float(&c, bi_pow2(&c, 1100), 0h7FEF_FFFF_FFFF_FFFF) == 1, "2^1100 > max f64")
	testing.expect(t, bi_cmp_float(&c, bi_pow2(&c, 1100), 0h7FF0_0000_0000_0000) == -1, "2^1100 < +inf")
}

// The f16 conversion is the compiler's own because Odin's rounds halfway cases
// away from zero, where the `half` instructions LLVM emits round to even. A
// folded `f16` constant that disagreed with runtime would be invisible in
// ordinary programs and wrong in exactly the cases a width test looks at.
@(test)
f16_rounds_ties_to_even :: proc(t: ^testing.T) {
	cases := []struct{value: f64, bits: u16, rounded: f64} {
		{0.0, 0x0000, 0.0},
		{1.0, 0x3C00, 1.0},
		{-2.0, 0xC000, -2.0},
		// 2049 sits exactly between 2048 and 2050; even wins.
		{2049.0, 0x6800, 2048.0},
		{2051.0, 0x6802, 2052.0},
		{2047.0, 0x67FF, 2047.0},
		// The largest finite f16, and the first value that overflows past it.
		{65504.0, 0x7BFF, 65504.0},
		{65520.0, 0x7C00, 0h7ff0000000000000},
		// Subnormals, down to the smallest and then under it.
		{0.00006103515625, 0x0400, 0.00006103515625},
		{0.000000059604645, 0x0001, 0.000000059604644775390625},
		{0.00000001, 0x0000, 0.0},
	}
	for k in cases {
		bits := f64_to_f16_bits(k.value)
		testing.expectf(t, bits == k.bits, "f16(%v): expected 0x%04X, got 0x%04X", k.value, k.bits, bits)
		testing.expectf(
			t,
			round_float(k.value, 16) == k.rounded,
			"round_float(%v, 16): expected %v, got %v",
			k.value, k.rounded, round_float(k.value, 16),
		)
	}
	// f32 rounding stays on the hardware path, and f64 is the identity.
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
		testing.expectf(t, ok, "%s does not parse", s.text)
		testing.expectf(t, bi_eq_i64(&c, value, s.value), "%s folded to %s", s.text, text(&c, value))
	}

	// Only what the lexer spells. `-define:NAME=VALUE` reaches here with any
	// text at all and reads a rejection as "this value is a string".
	rejected := []string{"0X10", "0B10", "0O10", "12abc", "", "0x", "0x-5", "_7", "-", "--5", "0b102", "0x_", "+5"}
	for bad in rejected {
		_, ok := bi_parse_int_literal(&c, bad)
		testing.expectf(t, !ok, "`%s` parsed as an integer", bad)
	}
}

@(test)
float_to_bigint_truncation :: proc(t: ^testing.T) {
	c: Compiler
	defer destroy_compilation(&c)

	integer, exact, ok := bi_from_f64_trunc(&c, 1.0)
	testing.expect(t, ok && exact && bi_eq_i64(&c, integer, 1), "1.0 should be the exact integer 1")

	integer, exact, ok = bi_from_f64_trunc(&c, -2.75)
	testing.expect(t, ok && !exact && bi_eq_i64(&c, integer, -2), "-2.75 should truncate towards zero")

	// 2^100 is exact in binary64 and proves conversion does not pass through
	// i64 before reaching an i128/u128 destination.
	integer, exact, ok = bi_from_f64_trunc(&c, 0h4630000000000000)
	testing.expect(t, ok && exact, "2^100 should be an exact integer")
	testing.expect(t, bi_cmp(&c, integer, bi_pow2(&c, 100)) == 0, "2^100 was truncated through a machine integer")

	_, _, ok = bi_from_f64_trunc(&c, 0h7ff0000000000000)
	testing.expect(t, !ok, "infinity is not an integer constant")
}

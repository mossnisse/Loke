// Boundary checks for `src/bigint.odin`, where a wrong fold would go unnoticed.
package lokec

import "core:mem"
import "core:testing"

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
	testing.expect(t, bi_cmp(&c, bi_add(&c, bi_mul(&c, q, three), r), a) == 0, "-(2^130 + 1) / 3 does not round-trip")
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
		bi_text(&c, u128_max) == "340282366920938463463374607431768211455",
		"u128 max round-trip: %s",
		bi_text(&c, u128_max),
	)

	magnitude, magnitude_ok := bi_parse_int_literal(&c, "170141183460469231731687303715884105728")
	testing.expect(t, magnitude_ok, "i128 min's magnitude does not parse")
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
	testing.expectf(t, bi_cmp(&c, wrapped, min64) == 0, "i64 min * -1 wrapped to %s", bi_text(&c, wrapped))

	wide := bi_sub(&c, bi_neg(&c, bi_pow2(&c, 100)), bi_from_i64(&c, 1))
	u64_max := bi_sub(&c, bi_pow2(&c, 64), bi_from_i64(&c, 1))
	wrapped = bi_wrap(&c, wide, 64, false)
	testing.expectf(t, bi_cmp(&c, wrapped, u64_max) == 0, "-(2^100) - 1 in u64: %s", bi_text(&c, wrapped))
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
	testing.expect(t, bi_magnitude_bits(&c, wide) == 201, "1 << 200 has 201 magnitude bits")
	testing.expect(t, bi_eq_i64(&c, bi_shr(&c, wide, 200), 1), "(1 << 200) >> 200 == 1")

	// A shift under one 60-bit digit must drop the emptied top digit.
	shifted := bi_shr(&c, bi_pow2(&c, 120), 10)
	testing.expectf(t, bi_cmp(&c, shifted, bi_pow2(&c, 110)) == 0, "(1 << 120) >> 10 == %s", bi_text(&c, shifted))
	testing.expect(t, bi_magnitude_bits(&c, shifted) == 111, "(1 << 120) >> 10 has 111 magnitude bits")
}

@(test)
bigint_allocator_storage :: proc(t: ^testing.T) {
	buffer := make([]byte, 1 << 16)
	defer delete(buffer)
	arena: mem.Arena
	mem.arena_init(&arena, buffer)
	storage := mem.arena_allocator(&arena)

	value := bi_add(storage, bi_pow2(storage, 100), bi_from_i64(storage, 7))
	testing.expect(t, bi_cmp(storage, bi_clone(storage, value), value) == 0, "clone differs from its source")
	testing.expectf(
		t,
		bi_text(storage, value) == "1267650600228229401496703205383",
		"2^100 + 7 in allocator storage: %s",
		bi_text(storage, value),
	)
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

	integer, exact, ok := bi_from_f64_trunc(&c, 1.0)
	testing.expect(t, ok && exact && bi_eq_i64(&c, integer, 1), "1.0 should be the exact integer 1")

	integer, exact, ok = bi_from_f64_trunc(&c, -2.75)
	testing.expect(t, ok && !exact && bi_eq_i64(&c, integer, -2), "-2.75 should truncate towards zero")

	// 2^100 must not pass through i64.
	integer, exact, ok = bi_from_f64_trunc(&c, 0h4630000000000000)
	testing.expect(t, ok && exact, "2^100 should be an exact integer")
	testing.expect(t, bi_cmp(&c, integer, bi_pow2(&c, 100)) == 0, "2^100 was truncated through a machine integer")

	_, _, ok = bi_from_f64_trunc(&c, 0h7ff0000000000000)
	testing.expect(t, !ok, "infinity is not an integer constant")
}

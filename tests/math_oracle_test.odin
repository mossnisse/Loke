package tests

import "core:math"
import "core:testing"

// Results fixed by other means: each constant's nearest float, which every
// library that rounds these well gets, and sin(10^22), whose argument
// reduction needs pi to well over a thousand bits (K. C. Ng, "Argument
// reduction for huge arguments", 1992).
@(test)
oracle_matches_known_results :: proc(t: ^testing.T) {
	o: Oracle
	oracle_init(&o)
	defer oracle_destroy(&o)
	Known :: struct {
		function: Oracle_Function,
		x:        f64,
		format:   Float_Format,
		pattern:  u64,
	}
	known := []Known {
		{.Exp, 1, F64_FORMAT, 0x4005bf0a8b145769},
		{.Log, 2, F64_FORMAT, 0x3fe62e42fefa39ef},
		{.Log, 10, F64_FORMAT, 0x40026bb1bbb55516},
		{.Sin, 3.141592653589793, F64_FORMAT, 0x3ca1a62633145c07},
		{.Cos, 3.141592653589793, F64_FORMAT, 0xbff0000000000000},
		{.Sin, 1e22, F64_FORMAT, 0xbfeb453ab76bf397},
		{.Exp, 1, F32_FORMAT, 0x402df854},
		{.Log, 2, F32_FORMAT, 0x3f317218},
		{.Sin, 1, F32_FORMAT, 0x3f576aa4},
		// The contract's special cases.
		{.Exp, math.inf_f64(-1), F64_FORMAT, 0},
		{.Exp, -2000, F64_FORMAT, 0},
		{.Exp, 2000, F32_FORMAT, 0x7f800000},
		{.Log, 0, F64_FORMAT, 0xfff0000000000000},
		{.Log, -1, F64_FORMAT, 0x7ff8000000000000},
		{.Log, -1, F32_FORMAT, 0x7fc00000},
		{.Sin, math.copy_sign(f64(0), -1), F64_FORMAT, 0x8000000000000000},
		{.Cos, math.inf_f64(1), F64_FORMAT, 0x7ff8000000000000},
		// The smallest subnormal is its own sine, and exp of the most negative
		// argument whose result is not zero rounds up to it.
		{.Sin, 4.9406564584124654e-324, F64_FORMAT, 1},
		{.Exp, -745.1332191019411, F64_FORMAT, 1},
		{.Exp, -745.1332191019412, F64_FORMAT, 0},
	}
	for k in known {
		got := oracle_eval(&o, k.function, k.x, k.format)
		testing.expectf(t, got == k.pattern, "%v(%v) at %v: expected %x, got %x", k.function, k.x, k.format, k.pattern, got)
	}
}

// Odin's own library is not correctly rounded, but it is within an ulp, and
// it agrees with correct rounding almost always: a gross error in the oracle
// breaks one of these.
@(test)
oracle_agrees_with_a_library_almost_always :: proc(t: ^testing.T) {
	o: Oracle
	oracle_init(&o)
	defer oracle_destroy(&o)
	state: u64 = 0x9e3779b97f4a7c15
	for format in ([]Float_Format{F64_FORMAT, F32_FORMAT}) {
		for function in Oracle_Function {
			differ := 0
			CASES :: 400
			for _ in 0 ..< CASES {
				state = state*6364136223846793005 + 1442695040888963407
				x: f64
				switch function {
				case .Exp: x = f64(i64(state >> 11) % 1400000) / 1000 - 700
				case .Log: x = transmute(f64)(u64(0x0010000000000000) + (state >> 2) % u64(0x7fd0000000000000))
				case .Sin, .Cos: x = f64(i64(state >> 11) % 2000000) / 1000 - 1000
				}
				library, got: u64
				if format == F32_FORMAT {
					x32 := f32(x)
					if function == .Exp {x32 = f32(x / 8)}
					if function == .Log {x32 = transmute(f32)(0x00800000 + u32(state >> 40) % 0x7f000000)}
					x = f64(x32)
					switch function {
					case .Exp: library = u64(transmute(u32)math.exp(x32))
					case .Log: library = u64(transmute(u32)math.ln(x32))
					case .Sin: library = u64(transmute(u32)math.sin(x32))
					case .Cos: library = u64(transmute(u32)math.cos(x32))
					}
				} else {
					switch function {
					case .Exp: library = transmute(u64)math.exp(x)
					case .Log: library = transmute(u64)math.ln(x)
					case .Sin: library = transmute(u64)math.sin(x)
					case .Cos: library = transmute(u64)math.cos(x)
					}
				}
				got = oracle_eval(&o, function, x, format)
				// Patterns of opposite signs are never an ulp apart; subtracting
				// them as integers would wrap to a small distance.
				sign := format == F32_FORMAT ? u64(1) << 31 : u64(1) << 63
				distance := got > library ? got - library : library - got
				if got & sign != library & sign {
					distance = max(u64)
				}
				if distance != 0 {
					differ += 1
				}
				testing.expectf(t, distance <= 1, "%v(%v) at %v: oracle %x, library %x", function, x, format, got, library)
			}
			testing.expectf(t, differ*20 <= CASES, "%v at %v: %d of %d differ from the library", function, format, differ, CASES)
		}
	}
}

// pow's results fixed by other means: the contract's table, results that are
// exact, among them midpoints rounded to even, and ones the oracle's `exp`
// and `log` give.
@(test)
oracle_pow_matches_known_results :: proc(t: ^testing.T) {
	o: Oracle
	oracle_init(&o)
	defer oracle_destroy(&o)
	Known :: struct {
		x, y:    f64,
		format:  Float_Format,
		pattern: u64,
	}
	nan := math.nan_f64()
	inf := math.inf_f64(1)
	negative_zero := math.copy_sign(f64(0), -1)
	known := []Known {
		{2, 0.5, F64_FORMAT, 0x3ff6a09e667f3bcd},
		{10, 2, F64_FORMAT, 0x4059000000000000},
		{4, 0.5, F64_FORMAT, 0x4000000000000000},
		{-2, 3, F64_FORMAT, 0xc020000000000000},
		{-2, -2, F64_FORMAT, 0x3fd0000000000000},
		{math.E, 1, F64_FORMAT, 0x4005bf0a8b145769},
		{2, 0.5, F32_FORMAT, 0x3fb504f3},
		// 2^-1075 is half the smallest subnormal, and ties go to even.
		{2, -1075, F64_FORMAT, 0},
		{2, -1074, F64_FORMAT, 1},
		{2, -150, F32_FORMAT, 0},
		{2, 1024, F64_FORMAT, 0x7ff0000000000000},
		// Midpoints: (2 - 2^-26)^2 has 54 bits, (2 - 2^-17)^3 too, as does
		// (w^2 2^-34)^1.5 with w = 2^18 - 1; (1 + 2^-12)^2 and 66049^1.5 have
		// 25.
		{2 - 1.0 / (1 << 26), 2, F64_FORMAT, 0x400ffffff8000000},
		{2 - 1.0 / (1 << 17), 3, F64_FORMAT, 0x401fffe800060000},
		{f64(262143 * 262143) / (1 << 34), 1.5, F64_FORMAT, 0x401fffe800060000},
		{1 + 1.0 / (1 << 12), 2, F32_FORMAT, 0x3f801000},
		{66049, 1.5, F32_FORMAT, 0x4b818180},
		// The contract's table.
		{nan, 0, F64_FORMAT, 0x3ff0000000000000},
		{1, nan, F64_FORMAT, 0x3ff0000000000000},
		{nan, 1, F64_FORMAT, 0x7ff8000000000000},
		{negative_zero, -1, F64_FORMAT, 0xfff0000000000000},
		{negative_zero, -2, F64_FORMAT, 0x7ff0000000000000},
		{negative_zero, 3, F64_FORMAT, 0x8000000000000000},
		{negative_zero, 0.5, F64_FORMAT, 0},
		{-1, inf, F64_FORMAT, 0x3ff0000000000000},
		{0.5, -inf, F64_FORMAT, 0x7ff0000000000000},
		{2, -inf, F64_FORMAT, 0},
		{-inf, -3, F64_FORMAT, 0x8000000000000000},
		{-inf, 3, F64_FORMAT, 0xfff0000000000000},
		{-inf, 2, F64_FORMAT, 0x7ff0000000000000},
		{inf, -0.5, F64_FORMAT, 0},
		{-8, 1.0 / 3.0, F64_FORMAT, 0x7ff8000000000000},
		{-1, -3, F32_FORMAT, 0xbf800000},
	}
	for k in known {
		got := oracle_pow(&o, k.x, k.y, k.format)
		testing.expectf(t, got == k.pattern, "pow(%v, %v) at %v: expected %x, got %x", k.x, k.y, k.format, k.pattern, got)
	}
}

// pow against Odin's library, as for the other functions.
@(test)
oracle_pow_agrees_with_a_library_almost_always :: proc(t: ^testing.T) {
	o: Oracle
	oracle_init(&o)
	defer oracle_destroy(&o)
	state: u64 = 0x2545f4914f6cdd1d
	for format in ([]Float_Format{F64_FORMAT, F32_FORMAT}) {
		differ := 0
		CASES :: 400
		for _ in 0 ..< CASES {
			state = state*6364136223846793005 + 1442695040888963407
			x := f64(state >> 11) / (1 << 53) * 20
			state = state*6364136223846793005 + 1442695040888963407
			y := f64(i64(state >> 11) % 60000) / 1000 - 30
			library, got: u64
			if format == F32_FORMAT {
				x32, y32 := f32(x), f32(y / 2)
				x, y = f64(x32), f64(y32)
				library = u64(transmute(u32)math.pow(x32, y32))
			} else {
				library = transmute(u64)math.pow(x, y)
			}
			got = oracle_pow(&o, x, y, format)
			distance := got > library ? got - library : library - got
			if distance != 0 {
				differ += 1
			}
			testing.expectf(t, distance <= 1, "pow(%v, %v) at %v: oracle %x, library %x", x, y, format, got, library)
		}
		testing.expectf(t, differ*20 <= CASES, "pow at %v: %d of %d differ from the library", format, differ, CASES)
	}
}

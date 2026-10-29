package tests

import "core:c/libc"
import "core:math"
import "core:testing"

// Results fixed by other means: each constant's nearest float, which every
// library that rounds these well gets, sin(10^22), whose argument reduction
// needs pi to well over a thousand bits (K. C. Ng, "Argument reduction for
// huge arguments", 1992), asin 1/2 = pi/6, acos 1/2 = pi/3, and
// acos -1/2 = 2 pi/3, rounded from pi by exact rational arithmetic, and tan
// at 1/2, 1, pi's and pi/2's `f64` values, and 10, from sin and cos summed
// separately in 120-digit decimal, and log2 and log10 at 3, 10, 1.25, and
// 0.1's `f64` value, from 100-digit decimal logarithms; log10 of that is
// within 2^-55 of -1, so it rounds to -1. The exact results at powers of 2
// and of 10 are integers.
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
		{.Log2, 10, F64_FORMAT, 0x400a934f0979a371},
		{.Log2, 3, F64_FORMAT, 0x3ff95c01a39fbd68},
		{.Log2, 0.1, F64_FORMAT, 0xc00a934f0979a371},
		{.Log2, 1.25, F64_FORMAT, 0x3fd49a784bcd1b8b},
		{.Log10, 3, F64_FORMAT, 0x3fde8927964fd5fd},
		{.Log10, 0.1, F64_FORMAT, 0xbff0000000000000},
		{.Log10, 1.25, F64_FORMAT, 0x3fb8cf183886480d},
		{.Log2, 10, F32_FORMAT, 0x40549a78},
		{.Log2, 3, F32_FORMAT, 0x3fcae00d},
		{.Log10, 3, F32_FORMAT, 0x3ef4493d},
		{.Log10, f64(f32(1.25)), F32_FORMAT, 0x3dc678c2},
		{.Log2, 8, F64_FORMAT, 0x4008000000000000},
		{.Log2, 4.9406564584124654e-324, F64_FORMAT, 0xc090c80000000000},
		{.Log2, 0.5, F32_FORMAT, 0xbf800000},
		{.Log10, 1000, F64_FORMAT, 0x4008000000000000},
		{.Log10, 1e22, F64_FORMAT, 0x4036000000000000},
		{.Log10, 1e10, F32_FORMAT, 0x41200000},
		{.Tan, 1, F64_FORMAT, 0x3ff8eb245cbee3a6},
		{.Tan, -0.5, F64_FORMAT, 0xbfe17b4f5bf3474a},
		{.Tan, 3.141592653589793, F64_FORMAT, 0xbca1a62633145c07},
		{.Tan, 1.5707963267948966, F64_FORMAT, 0x434d02967c31cdb5},
		{.Tan, 0.7853981633974483, F64_FORMAT, 0x3fefffffffffffff},
		{.Tan, 10, F64_FORMAT, 0x3fe4bf5f34be3782},
		{.Tan, 1, F32_FORMAT, 0x3fc75923},
		{.Tan, f64(f32(1.5707963267948966)), F32_FORMAT, 0xcbae8a4a},
		{.Tan, 10, F32_FORMAT, 0x3f25fafa},
		{.Asin, 0.5, F64_FORMAT, 0x3fe0c152382d7366},
		{.Asin, -0.5, F64_FORMAT, 0xbfe0c152382d7366},
		{.Acos, 0.5, F64_FORMAT, 0x3ff0c152382d7366},
		{.Acos, -0.5, F64_FORMAT, 0x4000c152382d7366},
		{.Asin, 0.5, F32_FORMAT, 0x3f060a92},
		{.Acos, 0.5, F32_FORMAT, 0x3f860a92},
		{.Acos, -0.5, F32_FORMAT, 0x40060a92},
		{.Asin, 1, F64_FORMAT, 0x3ff921fb54442d18},
		{.Asin, -1, F32_FORMAT, 0xbfc90fdb},
		{.Acos, -1, F64_FORMAT, 0x400921fb54442d18},
		{.Acos, 0, F64_FORMAT, 0x3ff921fb54442d18},
		{.Acos, math.copy_sign(f64(0), -1), F32_FORMAT, 0x3fc90fdb},
		// The contract's special cases.
		{.Exp, math.inf_f64(-1), F64_FORMAT, 0},
		{.Exp, -2000, F64_FORMAT, 0},
		{.Exp, 2000, F32_FORMAT, 0x7f800000},
		{.Log, 0, F64_FORMAT, 0xfff0000000000000},
		{.Log, -1, F64_FORMAT, 0x7ff8000000000000},
		{.Log, -1, F32_FORMAT, 0x7fc00000},
		{.Log2, 1, F64_FORMAT, 0},
		{.Log2, math.copy_sign(f64(0), -1), F64_FORMAT, 0xfff0000000000000},
		{.Log10, -2, F64_FORMAT, 0x7ff8000000000000},
		{.Log10, math.inf_f64(1), F32_FORMAT, 0x7f800000},
		{.Sin, math.copy_sign(f64(0), -1), F64_FORMAT, 0x8000000000000000},
		{.Cos, math.inf_f64(1), F64_FORMAT, 0x7ff8000000000000},
		{.Tan, math.copy_sign(f64(0), -1), F64_FORMAT, 0x8000000000000000},
		{.Tan, math.inf_f64(-1), F32_FORMAT, 0x7fc00000},
		{.Asin, math.copy_sign(f64(0), -1), F64_FORMAT, 0x8000000000000000},
		{.Asin, 1.0000000000000002, F64_FORMAT, 0x7ff8000000000000},
		{.Acos, 1, F64_FORMAT, 0},
		{.Acos, math.inf_f64(-1), F32_FORMAT, 0x7fc00000},
		// The smallest subnormal is its own sine and arcsine, and exp of the
		// most negative argument whose result is not zero rounds up to it.
		{.Sin, 4.9406564584124654e-324, F64_FORMAT, 1},
		{.Asin, -4.9406564584124654e-324, F64_FORMAT, 0x8000000000000001},
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
// breaks one of these. Its tan is sin/cos, rounded twice, so tan, log2,
// and log10 are compared with the C library's instead.
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
				case .Log, .Log2, .Log10: x = transmute(f64)(u64(0x0010000000000000) + (state >> 2) % u64(0x7fd0000000000000))
				case .Sin, .Cos, .Tan: x = f64(i64(state >> 11) % 2000000) / 1000 - 1000
				case .Asin, .Acos: x = f64(i64(state >> 11) % 2000000) / 1000000 - 1
				}
				library, got: u64
				if format == F32_FORMAT {
					x32 := f32(x)
					if function == .Exp {x32 = f32(x / 8)}
					if function == .Log || function == .Log2 || function == .Log10 {x32 = transmute(f32)(0x00800000 + u32(state >> 40) % 0x7f000000)}
					x = f64(x32)
					switch function {
					case .Exp: library = u64(transmute(u32)math.exp(x32))
					case .Log: library = u64(transmute(u32)math.ln(x32))
					case .Log2: library = u64(transmute(u32)libc.log2f(x32))
					case .Log10: library = u64(transmute(u32)libc.log10f(x32))
					case .Sin: library = u64(transmute(u32)math.sin(x32))
					case .Cos: library = u64(transmute(u32)math.cos(x32))
					case .Tan: library = u64(transmute(u32)libc.tanf(x32))
					case .Asin: library = u64(transmute(u32)math.asin(x32))
					case .Acos: library = u64(transmute(u32)math.acos(x32))
					}
				} else {
					switch function {
					case .Exp: library = transmute(u64)math.exp(x)
					case .Log: library = transmute(u64)math.ln(x)
					case .Log2: library = transmute(u64)libc.log2(x)
					case .Log10: library = transmute(u64)libc.log10(x)
					case .Sin: library = transmute(u64)math.sin(x)
					case .Cos: library = transmute(u64)math.cos(x)
					case .Tan: library = transmute(u64)libc.tan(x)
					case .Asin: library = transmute(u64)math.asin(x)
					case .Acos: library = transmute(u64)math.acos(x)
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
			// Odin's `f64` asin and acos, FreeBSD's, are an ulp off in 5 to 7%
			// of these, where a separate computation by Newton's method on sin
			// or cos agrees with the oracle, so a tenth may differ there.
			allowed := CASES/20
			if (function == .Asin || function == .Acos) && format == F64_FORMAT {allowed = CASES/10}
			testing.expectf(t, differ <= allowed, "%v at %v: %d of %d differ from the library", function, format, differ, CASES)
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

// atan2's results fixed by other means: the contract's table, constants from
// fdlibm's atan tables, which hold atan(1/2) and atan(3/2) correctly rounded,
// and tiny quotients: atan t is just below t, so a t exactly halfway between
// two floats rounds toward zero, not to even.
@(test)
oracle_atan2_matches_known_results :: proc(t: ^testing.T) {
	o: Oracle
	oracle_init(&o)
	defer oracle_destroy(&o)
	Known :: struct {
		y, x:    f64,
		format:  Float_Format,
		pattern: u64,
	}
	nan := math.nan_f64()
	inf := math.inf_f64(1)
	negative_zero := math.copy_sign(f64(0), -1)
	smallest := 4.9406564584124654e-324
	known := []Known {
		{1, 2, F64_FORMAT, 0x3fddac670561bb4f},
		{3, 2, F64_FORMAT, 0x3fef730bd281f69b},
		{-3, 2, F64_FORMAT, 0xbfef730bd281f69b},
		{1, 1, F64_FORMAT, 0x3fe921fb54442d18},
		{1, -1, F64_FORMAT, 0x4002d97c7f3321d2},
		{-1, -1, F64_FORMAT, 0xc002d97c7f3321d2},
		{1, 1, F32_FORMAT, 0x3f490fdb},
		{1, -1, F32_FORMAT, 0x4016cbe4},
		{1e-300, 1, F64_FORMAT, transmute(u64)f64(1e-300)},
		{smallest, 2, F64_FORMAT, 0},
		{3*smallest, 2, F64_FORMAT, 1},
		{-3*smallest, 2, F64_FORMAT, 0x8000000000000001},
		{3*smallest, 2*smallest, F64_FORMAT, 0x3fef730bd281f69b},
		{smallest, 1e300, F64_FORMAT, 0},
		{f64(3*transmute(f32)u32(1)), 2, F32_FORMAT, 1},
		// The contract's table.
		{nan, 0, F64_FORMAT, 0x7ff8000000000000},
		{0, nan, F32_FORMAT, 0x7fc00000},
		{0, negative_zero, F64_FORMAT, 0x400921fb54442d18},
		{negative_zero, -1, F64_FORMAT, 0xc00921fb54442d18},
		{negative_zero, 0, F64_FORMAT, 0x8000000000000000},
		{0, 1, F64_FORMAT, 0},
		{-1, 0, F64_FORMAT, 0xbff921fb54442d18},
		{1, negative_zero, F32_FORMAT, 0x3fc90fdb},
		{3, -inf, F64_FORMAT, 0x400921fb54442d18},
		{-3, inf, F64_FORMAT, 0x8000000000000000},
		{inf, 3, F64_FORMAT, 0x3ff921fb54442d18},
		{-inf, -3, F32_FORMAT, 0xbfc90fdb},
		{inf, -inf, F64_FORMAT, 0x4002d97c7f3321d2},
		{-inf, inf, F64_FORMAT, 0xbfe921fb54442d18},
		{inf, -inf, F32_FORMAT, 0x4016cbe4},
	}
	for k in known {
		got := oracle_atan2(&o, k.y, k.x, k.format)
		testing.expectf(t, got == k.pattern, "atan2(%v, %v) at %v: expected %x, got %x", k.y, k.x, k.format, k.pattern, got)
	}
}

// atan2 against Odin's library, as for the other functions, over all four
// quadrants and quotients of every size down to 2^-60. Its `f64` atan2 is an
// ulp low in about a quarter of these, near ±pi/2 most often, where a
// separate computation by angle halving agrees with the oracle, so a third
// may differ.
@(test)
oracle_atan2_agrees_with_a_library_almost_always :: proc(t: ^testing.T) {
	o: Oracle
	oracle_init(&o)
	defer oracle_destroy(&o)
	state: u64 = 0x6a09e667f3bcc909
	for format in ([]Float_Format{F64_FORMAT, F32_FORMAT}) {
		differ := 0
		CASES :: 400
		for _ in 0 ..< CASES {
			state = state*6364136223846793005 + 1442695040888963407
			y := f64(i64(state >> 11) % 2000000) / 1000 - 1000
			state = state*6364136223846793005 + 1442695040888963407
			x := math.ldexp(f64(i64(state >> 11) % 2000000) / 1000 - 1000, -int(state % 61))
			library, got: u64
			if format == F32_FORMAT {
				y32, x32 := f32(y), f32(x)
				y, x = f64(y32), f64(x32)
				library = u64(transmute(u32)math.atan2(y32, x32))
			} else {
				library = transmute(u64)math.atan2(y, x)
			}
			got = oracle_atan2(&o, y, x, format)
			sign := format == F32_FORMAT ? u64(1) << 31 : u64(1) << 63
			distance := got > library ? got - library : library - got
			if got & sign != library & sign {
				distance = max(u64)
			}
			if distance != 0 {
				differ += 1
			}
			testing.expectf(t, distance <= 1, "atan2(%v, %v) at %v: oracle %x, library %x", y, x, format, got, library)
		}
		allowed := format == F64_FORMAT ? CASES/3 : CASES/20
		testing.expectf(t, differ <= allowed, "atan2 at %v: %d of %d differ from the library", format, differ, CASES)
	}
}

// hypot's results fixed by other means: exact ones, among them Pythagorean
// triples whose hypotenuse, 54 or 25 bits and odd, is a midpoint that
// rounds to even; one far below the larger argument, which it rounds to;
// subnormal ones; overflow; and the special cases.
@(test)
oracle_hypot_matches_known_results :: proc(t: ^testing.T) {
	Known :: struct {
		x, y:    f64,
		format:  Float_Format,
		pattern: u64,
	}
	nan := math.nan_f64()
	inf := math.inf_f64(1)
	smallest := 4.9406564584124654e-324
	known := []Known {
		{3, 4, F64_FORMAT, transmute(u64)f64(5)},
		{-3, 4, F32_FORMAT, u64(transmute(u32)f32(5))},
		{7006394575843381, 7006394850613860, F64_FORMAT, transmute(u64)f64(9908538426787068)},
		{7006395311559277, -7006395155357364, F64_FORMAT, transmute(u64)f64(9908539162502964)},
		{13013847, 13025704, F32_FORMAT, u64(transmute(u32)f32(18412744))},
		{1e300, 1, F64_FORMAT, transmute(u64)f64(1e300)},
		{3*smallest, 4*smallest, F64_FORMAT, 5},
		{smallest, smallest, F64_FORMAT, 1},
		{1.7976931348623157e308, 1.7976931348623157e308, F64_FORMAT, 0x7ff0000000000000},
		{2, 0, F64_FORMAT, transmute(u64)f64(2)},
		{0, math.copy_sign(f64(0), -1), F64_FORMAT, 0},
		{inf, nan, F64_FORMAT, 0x7ff0000000000000},
		{nan, math.inf_f64(-1), F32_FORMAT, 0x7f800000},
		{nan, 1, F64_FORMAT, 0x7ff8000000000000},
		{0, nan, F32_FORMAT, 0x7fc00000},
	}
	for k in known {
		got := oracle_hypot(k.x, k.y, k.format)
		testing.expectf(t, got == k.pattern, "hypot(%v, %v) at %v: expected %x, got %x", k.x, k.y, k.format, k.pattern, got)
	}
}

// hypot against the C library's, which is within an ulp, over arguments of
// every relative scale. The UCRT's `f64` hypot is an ulp off in about an
// eighth of these, where an exact integer square root in Python and Python's
// own `math.hypot` agree with the oracle, so a fifth may differ there.
@(test)
oracle_hypot_agrees_with_a_library_almost_always :: proc(t: ^testing.T) {
	state: u64 = 0x3c6ef372fe94f82b
	for format in ([]Float_Format{F64_FORMAT, F32_FORMAT}) {
		differ := 0
		CASES :: 400
		for _ in 0 ..< CASES {
			state = state*6364136223846793005 + 1442695040888963407
			x := math.ldexp(f64(i64(state >> 11) % 2000000) / 1000 - 1000, int(state % 61) - 30)
			state = state*6364136223846793005 + 1442695040888963407
			y := math.ldexp(f64(i64(state >> 11) % 2000000) / 1000 - 1000, int(state % 61) - 30)
			library, got: u64
			if format == F32_FORMAT {
				x32, y32 := f32(x), f32(y)
				x, y = f64(x32), f64(y32)
				library = u64(transmute(u32)libc.hypotf(x32, y32))
			} else {
				library = transmute(u64)libc.hypot(x, y)
			}
			got = oracle_hypot(x, y, format)
			distance := got > library ? got - library : library - got
			if distance != 0 {
				differ += 1
			}
			testing.expectf(t, distance <= 1, "hypot(%v, %v) at %v: oracle %x, library %x", x, y, format, got, library)
		}
		allowed := format == F64_FORMAT ? CASES/5 : CASES/20
		testing.expectf(t, differ <= allowed, "hypot at %v: %d of %d differ from the library", format, differ, CASES)
	}
}

// sqrt's results fixed by other means: exact squares, among them the
// smallest subnormal's, 2^-1074 having an even exponent; sqrt 2 and the
// largest `f64`'s; and the special cases, -0 keeping its sign.
@(test)
oracle_sqrt_matches_known_results :: proc(t: ^testing.T) {
	Known :: struct {
		x:       f64,
		format:  Float_Format,
		pattern: u64,
	}
	smallest := 4.9406564584124654e-324
	known := []Known {
		{4, F64_FORMAT, transmute(u64)f64(2)},
		{0.25, F32_FORMAT, u64(transmute(u32)f32(0.5))},
		{smallest, F64_FORMAT, transmute(u64)f64(2.2227587494850775e-162)},
		{4*smallest, F64_FORMAT, transmute(u64)f64(4.445517498970155e-162)},
		{2, F64_FORMAT, transmute(u64)f64(1.4142135623730951)},
		{2, F32_FORMAT, u64(transmute(u32)f32(1.4142135))},
		{1.7976931348623157e308, F64_FORMAT, transmute(u64)f64(1.3407807929942596e154)},
		{0, F64_FORMAT, 0},
		{math.copy_sign(f64(0), -1), F64_FORMAT, 0x8000000000000000},
		{math.copy_sign(f64(0), -1), F32_FORMAT, 0x80000000},
		{math.inf_f64(1), F32_FORMAT, 0x7f800000},
		{math.inf_f64(-1), F64_FORMAT, 0x7ff8000000000000},
		{-1, F32_FORMAT, 0x7fc00000},
		{math.nan_f64(), F64_FORMAT, 0x7ff8000000000000},
	}
	for k in known {
		got := oracle_sqrt(k.x, k.format)
		testing.expectf(t, got == k.pattern, "sqrt(%v) at %v: expected %x, got %x", k.x, k.format, k.pattern, got)
	}
}

// sqrt against the processor's, which IEEE 754 requires to be correctly
// rounded, so every result must agree, over arguments of every magnitude,
// subnormal ones included.
@(test)
oracle_sqrt_agrees_with_the_processor :: proc(t: ^testing.T) {
	state: u64 = 0x510e527fade682d1
	for format in ([]Float_Format{F64_FORMAT, F32_FORMAT}) {
		CASES :: 2000
		for _ in 0 ..< CASES {
			state = state*6364136223846793005 + 1442695040888963407
			x := transmute(f64)(state >> 1)
			if math.is_nan(x) || math.is_inf(x, 0) {
				continue
			}
			want: u64
			if format == F32_FORMAT {
				x32 := transmute(f32)u32(state >> 33)
				if math.is_nan(x32) || math.is_inf(x32, 0) {
					continue
				}
				x = f64(x32)
				want = u64(transmute(u32)math.sqrt(x32))
			} else {
				want = transmute(u64)math.sqrt(x)
			}
			got := oracle_sqrt(x, format)
			testing.expectf(t, got == want, "sqrt(%v) at %v: oracle %x, processor %x", x, format, got, want)
		}
	}
}

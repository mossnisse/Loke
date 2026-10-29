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
				distance := abs(i64(got) - i64(library))
				if distance != 0 {
					differ += 1
				}
				testing.expectf(t, distance <= 1, "%v(%v) at %v: oracle %x, library %x", function, x, format, got, library)
			}
			testing.expectf(t, differ*20 <= CASES, "%v at %v: %d of %d differ from the library", function, format, differ, CASES)
		}
	}
}

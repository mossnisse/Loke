// deterministic-math-and-targets-plan.md "Validation and performance gates": an
// oracle for the correctly rounded `exp`, `log`, `sin`, and `cos` of `f64` and
// `f32`, with the special cases of the reproducible contract.
//
// Each result is an interval of integers at a scale of `2^-precision`, every
// step rounded outward, so the true value is always inside it. When both ends
// round to the same float, so does the true value, since rounding to nearest
// is monotone; otherwise the precision doubles (Ziv's strategy). The search
// ends because none of these functions has a dyadic value at a dyadic
// argument other than the special cases handled first, so no result is a
// midpoint. Host `libm` is never consulted.
package tests

import "core:math"
import "core:math/big"
import "core:mem/virtual"

Oracle_Function :: enum {
	Exp,
	Log,
	Sin,
	Cos,
}

// An IEEE-754 binary format, by its significand and exponent widths.
Float_Format :: struct {
	precision:     int, // significand bits, the leading one included
	exponent_bits: int,
}

F64_FORMAT :: Float_Format{53, 11}
F32_FORMAT :: Float_Format{24, 8}

// The contract's NaN result: positive, quiet, and with no other payload.
canonical_nan :: proc(format: Float_Format) -> u64 {
	return (u64(1) << uint(format.exponent_bits + 1) - 1) << uint(format.precision - 2)
}

@(private = "file")
infinity_bits :: proc(format: Float_Format) -> u64 {
	return (u64(1) << uint(format.exponent_bits) - 1) << uint(format.precision - 1)
}

@(private = "file")
sign_bit :: proc(format: Float_Format) -> u64 {
	return u64(1) << uint(format.precision + format.exponent_bits - 1)
}

@(private = "file")
pattern_value :: proc(pattern: u64, format: Float_Format) -> f64 {
	if format == F32_FORMAT {
		return f64(transmute(f32)u32(pattern))
	}
	return transmute(f64)pattern
}

// The precision the search starts at and the one it gives up at. No `f64`
// argument of these functions is known to need more than about 120 bits.
@(private = "file")
START_PRECISION :: 160
@(private = "file")
MAX_PRECISION :: 2560

// The constants are held at this precision and narrowed when used: enough for
// `sin` at the largest `f64`, 2^1024, at `MAX_PRECISION` and below.
@(private = "file")
CONSTANT_PRECISION :: MAX_PRECISION + 1024 + 1200

// One oracle's constants, and the arena every integer of it lives in.
Oracle :: struct {
	arena: virtual.Arena,
	ln2:   Interval,
	pi:    Interval,
}

// `[lo, hi] * 2^-scale`, which holds the value; the scale is the caller's.
@(private = "file")
Interval :: struct {
	lo, hi: ^big.Int,
}

oracle_init :: proc(o: ^Oracle) {
	_ = virtual.arena_init_growing(&o.arena)
	context.allocator = virtual.arena_allocator(&o.arena)
	o.ln2 = ln2_interval(CONSTANT_PRECISION)
	o.pi = pi_interval(CONSTANT_PRECISION)
}

oracle_destroy :: proc(o: ^Oracle) {
	virtual.arena_destroy(&o.arena)
}

// The correctly rounded result's bit pattern for an argument of `format`,
// which `x` holds exactly. A scratch arena, reset after each call, holds the
// search's integers.
oracle_eval :: proc(o: ^Oracle, function: Oracle_Function, x: f64, format: Float_Format) -> u64 {
	if special, ok := special_case(function, x, format); ok {
		return special
	}
	scratch: virtual.Arena
	_ = virtual.arena_init_growing(&scratch)
	context.allocator = virtual.arena_allocator(&scratch)
	for precision := START_PRECISION; precision <= MAX_PRECISION; precision *= 2 {
		if pattern, decided := attempt(o, function, x, format, precision); decided {
			virtual.arena_destroy(&scratch)
			return pattern
		}
		free_all(context.allocator)
	}
	panic("the oracle could not decide a rounding")
}

// The contract's table, which mathematics alone does not settle: the NaN
// result, infinities, zeros, poles, and the arguments with an exact result.
@(private = "file")
special_case :: proc(function: Oracle_Function, x: f64, format: Float_Format) -> (u64, bool) {
	one := transmute(u64)f64(1)
	if format == F32_FORMAT {
		one = u64(transmute(u32)f32(1))
	}
	nan := canonical_nan(format)
	infinity := infinity_bits(format)
	negative_zero := sign_bit(format)
	if math.is_nan(x) {
		return nan, true
	}
	switch function {
	case .Exp:
		if math.is_inf(x, 1) {return infinity, true}
		if math.is_inf(x, -1) {return 0, true}
		if x == 0 {return one, true}
	case .Log:
		if x == 0 {return infinity | negative_zero, true}
		if x < 0 {return nan, true}
		if math.is_inf(x, 1) {return infinity, true}
		if x == 1 {return 0, true}
	case .Sin:
		if math.is_inf(x, 0) {return nan, true}
		if x == 0 {return math.sign_bit(x) ? negative_zero : 0, true}
	case .Cos:
		if math.is_inf(x, 0) {return nan, true}
		if x == 0 {return one, true}
	}
	return 0, false
}

@(private = "file")
attempt :: proc(o: ^Oracle, function: Oracle_Function, x: f64, format: Float_Format, precision: int) -> (u64, bool) {
	switch function {
	case .Exp:
		return exp_attempt(o, x, format, precision)
	case .Log:
		return log_attempt(o, x, format, precision)
	case .Sin, .Cos:
		return trig_attempt(o, function, x, format, precision)
	}
	return 0, false
}

// exp(x) = 2^k exp(r), r = x - k ln 2. `k` is chosen one low, so `r` lies in
// [ln 2, 2 ln 2) whatever the rounding of the estimate, and every Taylor term
// is positive.
@(private = "file")
exp_attempt :: proc(o: ^Oracle, x: f64, format: Float_Format, w: int) -> (u64, bool) {
	// Far past both ends of either format: the result rounds to infinity or 0.
	if x > 1000 {return infinity_bits(format), true}
	if x < -1100 {return 0, true}
	k := int(math.floor(x / math.LN2)) - 1
	ln2 := narrow(o.ln2, CONSTANT_PRECISION, w + 16)
	scaled := scaled_argument(x, w + 16)
	kl := k >= 0 ? Interval{times(ln2.lo, int_of(k)), times(ln2.hi, int_of(k))} : Interval{times(ln2.hi, int_of(k)), times(ln2.lo, int_of(k))}
	r := narrow(Interval{minus(scaled.lo, kl.hi), minus(scaled.hi, kl.lo)}, w + 16, w)
	if sign_of(r.lo) <= 0 {
		return 0, false
	}
	// Terms r^n/n!, while r/(n+1) <= 1/2 bounds the rest by the last.
	one := power_of_two(w)
	sum := Interval{one, one}
	term := Interval{one, one}
	for n := 1;; n += 1 {
		term = Interval {
			divide_down(shift_down(times(term.lo, r.lo), w), int_of(n)),
			divide_up(shift_up(times(term.hi, r.hi), w), int_of(n)),
		}
		sum = Interval{plus(sum.lo, term.lo), plus(sum.hi, term.hi)}
		if n >= 3 && compare(term.hi, int_of(1)) <= 0 {
			sum.hi = plus(sum.hi, times(term.hi, int_of(2)))
			break
		}
	}
	return round_interval(sum, k - w, false, format)
}

// log(x) = e ln 2 + 2 atanh(t), t = (m - 1)/(m + 1), with x = m 2^e and m in
// [3/4, 3/2), so |t| <= 1/5.
@(private = "file")
log_attempt :: proc(o: ^Oracle, x: f64, format: Float_Format, w: int) -> (u64, bool) {
	significand, exponent := dyadic(x)
	e := bit_count(significand) - 1 + exponent
	// m = significand / 2^(e - exponent); move it below 3/2.
	if compare(times(significand, int_of(2)), times(power_of_two(e - exponent), int_of(3))) >= 0 {
		e += 1
	}
	denominator := power_of_two(e - exponent)
	difference := minus(significand, denominator)
	negative := sign_of(difference) < 0
	magnitude := negative ? negated(difference) : difference
	total := plus(significand, denominator)
	t := Interval{divide_down(shift_left(magnitude, w), total), divide_up(shift_left(magnitude, w), total)}
	t2 := Interval{shift_down(times(t.lo, t.lo), w), shift_up(times(t.hi, t.hi), w)}
	atanh := t
	power := t
	for j := 1;; j += 1 {
		power = Interval{shift_down(times(power.lo, t2.lo), w), shift_up(times(power.hi, t2.hi), w)}
		atanh = Interval {
			plus(atanh.lo, divide_down(power.lo, int_of(2*j + 1))),
			plus(atanh.hi, divide_up(power.hi, int_of(2*j + 1))),
		}
		// The rest is below power * (t^2 + t^4 + ...) / 3 < power.
		if compare(power.hi, int_of(1)) <= 0 {
			atanh.hi = plus(atanh.hi, int_of(2))
			break
		}
	}
	part := Interval{times(atanh.lo, int_of(2)), times(atanh.hi, int_of(2))}
	if negative {
		part = Interval{negated(part.hi), negated(part.lo)}
	}
	ln2 := narrow(o.ln2, CONSTANT_PRECISION, w)
	el := e >= 0 ? Interval{times(ln2.lo, int_of(e)), times(ln2.hi, int_of(e))} : Interval{times(ln2.hi, int_of(e)), times(ln2.lo, int_of(e))}
	return round_signed(Interval{plus(el.lo, part.lo), plus(el.hi, part.hi)}, -w, format)
}

// sin and cos of |x| = q pi/2 + r, |r| a little over pi/4 at most, from the
// Taylor series of sin |r| and cos |r|, both positive there. A tiny argument
// gets as many more bits as it is below one, since sin x is about x.
@(private = "file")
trig_attempt :: proc(o: ^Oracle, function: Oracle_Function, x: f64, format: Float_Format, base: int) -> (u64, bool) {
	significand, exponent := dyadic(abs(x))
	leading := bit_count(significand) - 1 + exponent
	w := base + max(0, -leading)
	r: Interval
	quadrant := 0
	if leading < 0 {
		// Below one, which is below pi/4: r is the argument itself, exactly.
		exact := shift_left(significand, exponent + w)
		r = Interval{exact, exact}
	} else {
		// pi/2 to as many bits as the quotient has, beyond the working ones.
		p := w + leading + 64
		half_pi := narrow(o.pi, CONSTANT_PRECISION + 1, p)
		scaled := shift_left(significand, exponent + p)
		q := divide_down(plus(times(scaled, int_of(2)), half_pi.lo), times(half_pi.lo, int_of(2)))
		quadrant = int(low_bits(q, 2))
		r = narrow(Interval{minus(scaled, times(q, half_pi.hi)), minus(scaled, times(q, half_pi.lo))}, p, w)
	}
	r_negative := false
	if sign_of(r.hi) < 0 {
		r_negative = true
		r = Interval{negated(r.hi), negated(r.lo)}
	} else if sign_of(r.lo) <= 0 {
		// It straddles zero: more bits will place it.
		return 0, false
	}
	r2 := Interval{shift_down(times(r.lo, r.lo), w), shift_up(times(r.hi, r.hi), w)}
	// sin or cos of |r|, chosen by quadrant: the four rotations of the pair.
	use_sin := (quadrant % 2 == 0) == (function == .Sin)
	value := use_sin ? alternating_series(r, r2, 2, w) : alternating_series(Interval{power_of_two(w), power_of_two(w)}, r2, 1, w)
	negative: bool
	if function == .Sin {
		negative = quadrant >= 2
		if use_sin && r_negative {negative = !negative}
		if math.sign_bit(x) {negative = !negative}
	} else {
		negative = quadrant == 1 || quadrant == 2
		if !use_sin {
			// cos r is even in r; the sign of sin r follows r's.
		} else if r_negative {
			negative = !negative
		}
	}
	if sign_of(value.lo) <= 0 {
		return 0, false
	}
	return round_interval(value, -w, negative, format)
}

// first - first r^2/((a)(a+1)) + ..., the sine's series from `r` with `a` 2,
// the cosine's from 1 with `a` 1: each term is the last times r^2/(a(a+1)),
// `a` going up by two.
@(private = "file")
alternating_series :: proc(first, r2: Interval, start: int, w: int) -> Interval {
	sum := first
	term := first
	for a, n := start, 1;; a, n = a + 2, n + 1 {
		divisor := int_of(a*(a + 1))
		term = Interval {
			divide_down(shift_down(times(term.lo, r2.lo), w), divisor),
			divide_up(shift_up(times(term.hi, r2.hi), w), divisor),
		}
		if n % 2 == 1 {
			sum = Interval{minus(sum.lo, term.hi), minus(sum.hi, term.lo)}
		} else {
			sum = Interval{plus(sum.lo, term.lo), plus(sum.hi, term.hi)}
		}
		// The terms fall in magnitude from here, so the rest is within the next.
		if compare(term.hi, int_of(1)) <= 0 {
			return Interval{minus(sum.lo, int_of(2)), plus(sum.hi, int_of(2))}
		}
	}
}

// ln 2 = sum of 1/(k 2^k): each of the `scale` floored terms loses under one,
// and the rest of the series is under one.
@(private = "file")
ln2_interval :: proc(scale: int) -> Interval {
	sum := int_of(0)
	for k in 1 ..= scale {
		sum = plus(sum, divide_down(power_of_two(scale - k), int_of(k)))
	}
	return Interval{sum, plus(sum, int_of(scale + 1))}
}

// pi = 16 atan(1/5) - 4 atan(1/239), Machin's formula.
@(private = "file")
pi_interval :: proc(scale: int) -> Interval {
	a := atan_inverse(5, scale)
	b := atan_inverse(239, scale)
	return Interval {
		minus(times(a.lo, int_of(16)), times(b.hi, int_of(4))),
		minus(times(a.hi, int_of(16)), times(b.lo, int_of(4))),
	}
}

// atan(1/m) = sum of (-1)^j / ((2j+1) m^(2j+1)): each floored term loses under
// one, and the alternating rest is under the first omitted term, under one.
@(private = "file")
atan_inverse :: proc(m: int, scale: int) -> Interval {
	sum := int_of(0)
	power := int_of(i64(m))
	m2 := int_of(i64(m*m))
	one := power_of_two(scale)
	count := 0
	for j := 0;; j += 1 {
		term := divide_down(one, times(power, int_of(2*j + 1)))
		if sign_of(term) == 0 {
			break
		}
		sum = j % 2 == 0 ? plus(sum, term) : minus(sum, term)
		power = times(power, m2)
		count += 1
	}
	return Interval{minus(sum, int_of(count + 1)), plus(sum, int_of(count + 1))}
}

// The interval at scale `from`, outward at the coarser scale `to`.
@(private = "file")
narrow :: proc(v: Interval, from, to: int) -> Interval {
	return Interval{floor_shift(v.lo, from - to), ceil_shift(v.hi, from - to)}
}

// x times 2^scale, as an interval of integers: exact unless x has bits below.
@(private = "file")
scaled_argument :: proc(x: f64, scale: int) -> Interval {
	significand, exponent := dyadic(abs(x))
	v := Interval{floor_shift(significand, -(exponent + scale)), ceil_shift(significand, -(exponent + scale))}
	if x < 0 {
		v = Interval{negated(v.hi), negated(v.lo)}
	}
	return v
}

// A positive finite x as significand * 2^exponent, the significand an integer.
@(private = "file")
dyadic :: proc(x: f64) -> (^big.Int, int) {
	pattern := transmute(u64)x
	biased := int(pattern >> 52) & 0x7ff
	fraction := pattern & (1 << 52 - 1)
	exponent := -1074
	if biased != 0 {
		fraction |= 1 << 52
		exponent = biased - 1075
	}
	return int_of(fraction), exponent
}

// Rounds an interval of a signed value, deciding only if it excludes zero.
@(private = "file")
round_signed :: proc(v: Interval, exponent: int, format: Float_Format) -> (u64, bool) {
	if sign_of(v.lo) > 0 {
		return round_interval(v, exponent, false, format)
	}
	if sign_of(v.hi) < 0 {
		return round_interval(Interval{negated(v.hi), negated(v.lo)}, exponent, true, format)
	}
	return 0, false
}

// A positive interval of magnitudes times 2^exponent: decided when both ends
// round to the same float.
@(private = "file")
round_interval :: proc(v: Interval, exponent: int, negative: bool, format: Float_Format) -> (u64, bool) {
	lo := round_magnitude(v.lo, exponent, format)
	hi := round_magnitude(v.hi, exponent, format)
	if lo != hi {
		return 0, false
	}
	return negative ? lo | sign_bit(format) : lo, true
}

// The pattern of the float nearest `n * 2^exponent`, n >= 0, ties to even,
// rounded once at its own last place, subnormal or not; past the largest
// finite value, infinity.
@(private = "file")
round_magnitude :: proc(n: ^big.Int, exponent: int, format: Float_Format) -> u64 {
	if sign_of(n) == 0 {
		return 0
	}
	precision := format.precision
	bias := (1 << uint(format.exponent_bits - 1)) - 1
	min_exponent := 1 - bias
	leading := bit_count(n) - 1 + exponent
	unit := max(leading, min_exponent) - (precision - 1)
	shift := unit - exponent
	kept: u64
	if shift <= 0 {
		kept = low_bits(shift_left(n, -shift), 64)
	} else {
		top := shift_down(n, shift)
		kept = low_bits(top, 64)
		order := compare(minus(n, shift_left(top, shift)), power_of_two(shift - 1))
		if order > 0 || (order == 0 && kept & 1 == 1) {
			kept += 1
		}
	}
	if kept == u64(1) << uint(precision) {
		kept >>= 1
		unit += 1
	}
	if kept < u64(1) << uint(precision - 1) {
		return kept // subnormal, or zero
	}
	biased := unit + precision - 1 + bias
	if biased >= (1 << uint(format.exponent_bits)) - 1 {
		return infinity_bits(format)
	}
	return u64(biased) << uint(precision - 1) | (kept - u64(1) << uint(precision - 1))
}

// Values in the current allocator; never aliased, so never freed one by one.
@(private = "file")
int_of :: proc(v: $T) -> ^big.Int {
	r := new(big.Int)
	_ = big.int_set_from_integer(r, v)
	return r
}

@(private = "file")
power_of_two :: proc(n: int) -> ^big.Int {
	r := new(big.Int)
	_ = big.power_of_two(r, n)
	return r
}

@(private = "file")
plus :: proc(a, b: ^big.Int) -> ^big.Int {
	r := new(big.Int)
	_ = big.int_add(r, a, b)
	return r
}

@(private = "file")
minus :: proc(a, b: ^big.Int) -> ^big.Int {
	r := new(big.Int)
	_ = big.int_sub(r, a, b)
	return r
}

@(private = "file")
times :: proc(a, b: ^big.Int) -> ^big.Int {
	r := new(big.Int)
	_ = big.int_mul(r, a, b)
	return r
}

@(private = "file")
negated :: proc(a: ^big.Int) -> ^big.Int {
	r := new(big.Int)
	_ = big.int_neg(r, a)
	return r
}

@(private = "file")
shift_left :: proc(a: ^big.Int, n: int) -> ^big.Int {
	r := new(big.Int)
	_ = big.int_shl(r, a, n)
	return r
}

// floor(a / 2^n) and ceil(a / 2^n) for a >= 0.
@(private = "file")
shift_down :: proc(a: ^big.Int, n: int) -> ^big.Int {
	r := new(big.Int)
	_ = big.int_shr(r, a, n)
	return r
}

@(private = "file")
shift_up :: proc(a: ^big.Int, n: int) -> ^big.Int {
	return shift_down(plus(a, minus(power_of_two(n), int_of(1))), n)
}

// floor(a / 2^n) and ceil(a / 2^n) for any sign of a; a negative n shifts
// left, exactly.
@(private = "file")
floor_shift :: proc(a: ^big.Int, n: int) -> ^big.Int {
	if n <= 0 {
		return shift_left(a, -n)
	}
	return sign_of(a) < 0 ? negated(shift_up(negated(a), n)) : shift_down(a, n)
}

@(private = "file")
ceil_shift :: proc(a: ^big.Int, n: int) -> ^big.Int {
	if n <= 0 {
		return shift_left(a, -n)
	}
	return sign_of(a) < 0 ? negated(shift_down(negated(a), n)) : shift_up(a, n)
}

// floor(a / b) and ceil(a / b) for a >= 0, b > 0.
@(private = "file")
divide_down :: proc(a, b: ^big.Int) -> ^big.Int {
	r := new(big.Int)
	_ = big.int_div(r, a, b)
	return r
}

@(private = "file")
divide_up :: proc(a, b: ^big.Int) -> ^big.Int {
	return divide_down(plus(a, minus(b, int_of(1))), b)
}

@(private = "file")
compare :: proc(a, b: ^big.Int) -> int {
	c, _ := big.int_compare(a, b)
	return c
}

@(private = "file")
sign_of :: proc(a: ^big.Int) -> int {
	if zero, _ := big.int_is_zero(a); zero {
		return 0
	}
	negative, _ := big.int_is_negative(a)
	return negative ? -1 : 1
}

// The bits of a magnitude, from its leading one.
@(private = "file")
bit_count :: proc(a: ^big.Int) -> int {
	m := new(big.Int)
	_ = big.int_abs(m, a)
	count, _ := big.count_bits(m)
	return count
}

// The low `count` bits of a non-negative integer, count <= 64.
@(private = "file")
low_bits :: proc(a: ^big.Int, count: int) -> u64 {
	result, _ := big.int_get_u64(minus(a, shift_left(shift_down(a, count), count)))
	return result
}

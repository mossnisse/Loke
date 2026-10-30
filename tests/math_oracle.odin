// deterministic-math-and-targets-plan.md "Validation and performance gates": an
// oracle for the correctly rounded `exp`, `log`, `log2`, `log10`, `sin`, `cos`,
// `tan`, `asin`, `acos`, `pow`, `atan2`, and `hypot` of `f64` and `f32`, with
// the special cases of the reproducible contract.
//
// Each result is an interval of integers at a scale of `2^-precision`, every
// step rounded outward, so the true value is always inside it. When both ends
// round to the same float, so does the true value, since rounding to nearest
// is monotone; otherwise the precision doubles (Ziv's strategy). The search
// ends because none of these functions has a dyadic value at a dyadic
// argument other than the special cases handled first, so no result is a
// midpoint; pow, which has, rounds its dyadic results exactly first. Host
// `libm` is never consulted.
package tests

import "core:fmt"
import "core:math"
import "core:math/big"
import "core:mem/virtual"
import "core:strings"

Oracle_Function :: enum {
	Exp,
	Log,
	Log2,
	Log10,
	Sin,
	Cos,
	Tan,
	Asin,
	Acos,
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
	case .Log, .Log2, .Log10:
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
	case .Tan:
		if math.is_inf(x, 0) {return nan, true}
		if x == 0 {return math.sign_bit(x) ? negative_zero : 0, true}
	case .Asin:
		if abs(x) > 1 {return nan, true}
		if x == 0 {return math.sign_bit(x) ? negative_zero : 0, true}
	case .Acos:
		if abs(x) > 1 {return nan, true}
		if x == 1 {return 0, true}
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
	case .Log2, .Log10:
		return log_base_attempt(o, x, function == .Log10, format, precision)
	case .Sin, .Cos, .Tan:
		return trig_attempt(o, function, x, format, precision)
	case .Asin, .Acos:
		return arc_attempt(o, function, x, format, precision)
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
	return exp_of_interval(o, scaled_argument(x, w + 16), x, format, w)
}

// exp of a value in `scaled`, an interval at a scale of 2^-(w + 16), whose
// nearest `f64` is about `x`, which is within the range of `exp_attempt`.
@(private = "file")
exp_of_interval :: proc(o: ^Oracle, scaled: Interval, x: f64, format: Float_Format, w: int) -> (u64, bool) {
	k := int(math.floor(x / math.LN2)) - 1
	ln2 := narrow(o.ln2, CONSTANT_PRECISION, w + 16)
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

@(private = "file")
log_attempt :: proc(o: ^Oracle, x: f64, format: Float_Format, w: int) -> (u64, bool) {
	return round_signed(log_interval(o, x, w), -w, format)
}

// log2 x and log10 x as log x over ln 2 or ln 10, the divisor's interval
// positive, so the quotient's ends come from the matching ends. They are
// rational only at x = 2^k and 10^k, where they are the integer k, a float
// and not a midpoint, so the search ends.
@(private = "file")
log_base_attempt :: proc(o: ^Oracle, x: f64, ten: bool, format: Float_Format, w: int) -> (u64, bool) {
	v := log_interval(o, x, w)
	divisor := ten ? log_interval(o, 10, w) : narrow(o.ln2, CONSTANT_PRECISION, w)
	negative := sign_of(v.hi) < 0
	if !negative && sign_of(v.lo) <= 0 {
		return 0, false
	}
	m := negative ? Interval{negated(v.hi), negated(v.lo)} : v
	quotient := Interval{divide_down(shift_left(m.lo, w), divisor.hi), divide_up(shift_left(m.hi, w), divisor.lo)}
	return round_interval(quotient, -w, negative, format)
}

// log x for a positive finite x other than 1, at a scale of 2^-w: e ln 2 +
// 2 atanh(t), t = (m - 1)/(m + 1), with x = m 2^e and m in [3/4, 3/2), so
// |t| <= 1/5.
@(private = "file")
log_interval :: proc(o: ^Oracle, x: f64, w: int) -> Interval {
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
	return Interval{plus(el.lo, part.lo), plus(el.hi, part.hi)}
}

// The correctly rounded x^y's bit pattern, for arguments of `format`, which
// `x` and `y` hold exactly, with the contract's table first. Unlike the
// other functions, pow has dyadic results at finite arguments, among them
// midpoints, at which the search would never end; `pow_exact` finds every
// dyadic result small enough to be one and rounds it exactly.
oracle_pow :: proc(o: ^Oracle, x, y: f64, format: Float_Format) -> u64 {
	if special, ok := pow_special_case(x, y, format); ok {
		return special
	}
	// x is finite, nonzero, and not ±1, y finite and nonzero, and x < 0 only
	// with an integer y.
	sign := x < 0 && is_odd_integer(y) ? sign_bit(format) : 0
	scratch: virtual.Arena
	_ = virtual.arena_init_growing(&scratch)
	context.allocator = virtual.arena_allocator(&scratch)
	if pattern, exact := pow_exact(abs(x), y, format); exact {
		virtual.arena_destroy(&scratch)
		return pattern | sign
	}
	for precision := START_PRECISION; precision <= MAX_PRECISION; precision *= 2 {
		if pattern, decided := pow_attempt(o, abs(x), y, format, precision); decided {
			virtual.arena_destroy(&scratch)
			return pattern | sign
		}
		free_all(context.allocator)
	}
	panic("the oracle could not decide a rounding of pow")
}

// deterministic-math-and-targets-plan.md "Special cases": pow's table, in
// its order, and x = -1 with an integer y, whose result is ±1.
@(private = "file")
pow_special_case :: proc(x, y: f64, format: Float_Format) -> (u64, bool) {
	one := transmute(u64)f64(1)
	if format == F32_FORMAT {
		one = u64(transmute(u32)f32(1))
	}
	infinity := infinity_bits(format)
	negative := sign_bit(format)
	if y == 0 || x == 1 {return one, true}
	if math.is_nan(x) || math.is_nan(y) {return canonical_nan(format), true}
	odd := is_odd_integer(y)
	if x == 0 {
		x_sign := math.sign_bit(x) && odd ? negative : 0
		return (y < 0 ? infinity : 0) | x_sign, true
	}
	if math.is_inf(y, 0) {
		if x == -1 {return one, true}
		return (abs(x) < 1) == (y < 0) ? infinity : 0, true
	}
	if math.is_inf(x, 0) {
		x_sign := x < 0 && odd ? negative : 0
		return (y < 0 ? 0 : infinity) | x_sign, true
	}
	if x < 0 && !is_integer(y) {return canonical_nan(format), true}
	if x == -1 {return one | (odd ? negative : 0), true}
	return 0, false
}

@(private = "file")
is_integer :: proc(y: f64) -> bool {
	return !math.is_inf(y, 0) && math.floor(y) == y
}

@(private = "file")
is_odd_integer :: proc(y: f64) -> bool {
	return is_integer(y) && abs(y) < 9007199254740992 && math.mod(y, 2) != 0
}

// An odd integer and a power of two whose product is a positive finite x.
@(private = "file")
odd_part :: proc(x: f64) -> (^big.Int, int) {
	significand, exponent := dyadic(x)
	for sign_of(significand) != 0 && low_bits(significand, 1) == 0 {
		significand = shift_down(significand, 1)
		exponent += 1
	}
	return significand, exponent
}

// x^y rounded exactly when it is a dyadic value with an odd part of at most
// 200 bits, which every midpoint is, for x > 0 other than 1 and finite
// nonzero y. With x = a 2^b and |y| = c 2^d, a and c odd, x^y is dyadic only
// when b y is an integer and a^y is an integer: a = 1, or y > 0 and a is a
// perfect 2^-d-th power.
@(private = "file")
pow_exact :: proc(x, y: f64, format: Float_Format) -> (u64, bool) {
	a, b := odd_part(x)
	c, d := odd_part(abs(y))
	// t = b y, which must be an integer.
	t_magnitude := times(int_of(abs(b)), c)
	t_negative := (b < 0) != (y < 0)
	if d >= 0 {
		t_magnitude = shift_left(t_magnitude, d)
	} else {
		if compare(shift_left(shift_down(t_magnitude, -d), -d), t_magnitude) != 0 {return 0, false}
		t_magnitude = shift_down(t_magnitude, -d)
	}
	value := int_of(1)
	if compare(a, int_of(1)) != 0 {
		if y < 0 {return 0, false}
		root := a
		for _ in 0 ..< max(0, -d) {
			s := square_root(root)
			if compare(times(s, s), root) != 0 {return 0, false}
			root = s
		}
		power := shift_left(c, max(0, d))
		if compare(times(power, int_of(bit_count(root))), int_of(200)) > 0 {return 0, false}
		for _ in 0 ..< int(low_bits(power, 64)) {
			value = times(value, root)
		}
	}
	// value < 2^200, so past 2^4000 either way the result is infinite or 0.
	if compare(t_magnitude, int_of(4000)) > 0 {
		return t_negative ? 0 : infinity_bits(format), true
	}
	t := int(low_bits(t_magnitude, 64))
	return round_magnitude(value, t_negative ? -t : t, format), true
}

// e^(y log x), for x > 0 other than 1 and finite nonzero y: log x at a scale
// fine enough that y times it is within 2^-(w + 8), then `exp_of_interval`.
@(private = "file")
pow_attempt :: proc(o: ^Oracle, x, y: f64, format: Float_Format, w: int) -> (u64, bool) {
	estimate := y*math.ln(x)
	if estimate > 1000 {return infinity_bits(format), true}
	if estimate < -1100 {return 0, true}
	significand, exponent := dyadic(abs(y))
	// |y| < 2^(exponent + 53).
	scale := w + 8 + max(0, exponent + 53)
	l := log_interval(o, x, scale)
	z := Interval{times(l.lo, significand), times(l.hi, significand)}
	if y < 0 {
		z = Interval{negated(z.hi), negated(z.lo)}
	}
	// z is at a scale of 2^-(scale - exponent); bring it to 2^-(w + 16).
	shift := scale - exponent - (w + 16)
	if shift >= 0 {
		z = Interval{floor_shift(z.lo, shift), ceil_shift(z.hi, shift)}
	} else {
		z = Interval{shift_left(z.lo, -shift), shift_left(z.hi, -shift)}
	}
	return exp_of_interval(o, z, estimate, format, w)
}

// The correctly rounded atan2(y, x)'s bit pattern, for arguments of `format`,
// which `y` and `x` hold exactly. With t the smaller of |y| and |x| over the
// larger, the result is atan t when |y| <= |x| and x is positive, pi/2 - atan t
// or pi/2 + atan t when |y| > |x|, by x's sign, and pi - atan t otherwise,
// with y's sign; x's sign bit decides, so -0 counts as negative. t is 0 when
// the smaller is 0 or the larger alone is infinite, and 1 when both are
// infinite, which gives the contract's table without listing it. No result
// but 0 is dyadic, since atan of a nonzero rational is not even algebraic
// (Lindemann-Weierstrass), so the search ends; a tiny atan t, though, is
// within about t^3 of t, which can be a midpoint, so it takes about twice as
// many bits as t is below one, and below 2^-1100 rounds to 0 at once.
oracle_atan2 :: proc(o: ^Oracle, y, x: f64, format: Float_Format) -> u64 {
	if math.is_nan(y) || math.is_nan(x) {
		return canonical_nan(format)
	}
	negative := math.sign_bit(y)
	sign := negative ? sign_bit(format) : 0
	ay, ax := abs(y), abs(x)
	swap := ay > ax
	n, d := swap ? ax : ay, swap ? ay : ax
	// The base in quarters of pi, and the sign atan t takes.
	quarter, s := 0, 1
	if swap {
		quarter = 2
		s = math.sign_bit(x) ? 1 : -1
	} else if math.sign_bit(x) {
		quarter = 4
		s = -1
	}
	scratch: virtual.Arena
	_ = virtual.arena_init_growing(&scratch)
	context.allocator = virtual.arena_allocator(&scratch)
	if p, q := atan2_ratio(n, d); quarter == 0 && (p == nil || bit_count(q) - bit_count(p) > 1100) {
		virtual.arena_destroy(&scratch)
		return sign
	}
	for precision := START_PRECISION; precision <= MAX_PRECISION; precision *= 2 {
		if pattern, decided := atan2_attempt(o, n, d, quarter, s, negative, format, precision); decided {
			virtual.arena_destroy(&scratch)
			return pattern
		}
		free_all(context.allocator)
	}
	panic("the oracle could not decide a rounding of atan2")
}

// The correctly rounded hypot(x, y)'s bit pattern, sqrt(x^2 + y^2), for
// arguments of `format`, which `x` and `y` hold exactly. An infinite argument
// gives +Inf, even with a NaN, and otherwise a NaN gives NaN (C17 F.10.4.3).
// x^2 + y^2 is an exact integer S times 2^(2 low), and its root at w more
// bits is floor(sqrt(S 2^(2w))) or exactly that; an exact root is rounded
// as it is, a midpoint to even. Otherwise the root is irrational, so the
// search ends.
oracle_hypot :: proc(x, y: f64, format: Float_Format) -> u64 {
	if math.is_inf(x, 0) || math.is_inf(y, 0) {
		return infinity_bits(format)
	}
	if math.is_nan(x) || math.is_nan(y) {
		return canonical_nan(format)
	}
	if x == 0 && y == 0 {
		return 0
	}
	scratch: virtual.Arena
	_ = virtual.arena_init_growing(&scratch)
	context.allocator = virtual.arena_allocator(&scratch)
	// A zero argument contributes nothing at the other's exponent.
	sx, ex := int_of(0), 0
	sy, ey := int_of(0), 0
	if x != 0 {sx, ex = dyadic(abs(x))}
	if y != 0 {sy, ey = dyadic(abs(y))}
	if x == 0 {ex = ey}
	if y == 0 {ey = ex}
	low := min(ex, ey)
	sum := plus(shift_left(times(sx, sx), 2*(ex - low)), shift_left(times(sy, sy), 2*(ey - low)))
	for w := START_PRECISION; w <= MAX_PRECISION; w *= 2 {
		n := shift_left(sum, 2*w)
		root := square_root(n)
		value := Interval{root, root}
		if compare(times(root, root), n) != 0 {
			value.hi = plus(root, int_of(1))
		}
		if pattern, decided := round_interval(value, low - w, false, format); decided {
			virtual.arena_destroy(&scratch)
			return pattern
		}
	}
	panic("the oracle could not decide a rounding of hypot")
}

// t = n/d as integers p/q, for 0 <= n <= d, or nil for t = 0: 1/1 when both
// are infinite, and nil when n is 0 or d alone is infinite.
@(private = "file")
atan2_ratio :: proc(n, d: f64) -> (p, q: ^big.Int) {
	if math.is_inf(n, 0) {
		return int_of(1), int_of(1)
	}
	if n == 0 || math.is_inf(d, 0) {
		return nil, nil
	}
	sn, en := dyadic(n)
	sd, ed := dyadic(d)
	low := min(en, ed)
	return shift_left(sn, en - low), shift_left(sd, ed - low)
}

// quarter pi/4 + s atan(n/d), as `oracle_atan2` defines them. With no base,
// the result is near n/d, so it gets as many more bits as that is below one.
@(private = "file")
atan2_attempt :: proc(o: ^Oracle, n, d: f64, quarter, s: int, negative: bool, format: Float_Format, w: int) -> (u64, bool) {
	p, q := atan2_ratio(n, d)
	scale := w + 2
	if quarter == 0 {
		scale = w + max(0, bit_count(q) - bit_count(p) + 1)
	}
	quarter_pi := narrow(o.pi, CONSTANT_PRECISION + 2, scale)
	value := Interval{times(quarter_pi.lo, int_of(quarter)), times(quarter_pi.hi, int_of(quarter))}
	if p != nil {
		a := atan_interval(p, q, scale)
		if s > 0 {
			value = Interval{plus(value.lo, a.lo), plus(value.hi, a.hi)}
		} else {
			value = Interval{minus(value.lo, a.hi), minus(value.hi, a.lo)}
		}
	}
	if sign_of(value.lo) <= 0 {
		return 0, false
	}
	return round_interval(value, -scale, negative, format)
}

// atan(p/q) at a scale of 2^-scale, for integers 0 < p <= q, by Euler's
// series: the sum over k >= 0 of (2k)!!/(2k + 1)!! z^k t/(1 + t^2), with
// t = p/q, so that t/(1 + t^2) = p q/(p^2 + q^2) and z = t^2/(1 + t^2) =
// p^2/(p^2 + q^2) <= 1/2. Each term is the one before times 2k z/(2k + 1),
// under half of it, so the rest after a term is under that term; each term
// is floored and ceiled from the ends of the last.
@(private = "file")
atan_interval :: proc(p, q: ^big.Int, scale: int) -> Interval {
	p2 := times(p, p)
	denominator := plus(p2, times(q, q))
	first := shift_left(times(p, q), scale)
	term := Interval{divide_down(first, denominator), divide_up(first, denominator)}
	sum := term
	for k := 1;; k += 1 {
		factor := times(p2, int_of(2*k))
		divisor := times(denominator, int_of(2*k + 1))
		term = Interval{divide_down(times(term.lo, factor), divisor), divide_up(times(term.hi, factor), divisor)}
		sum = Interval{plus(sum.lo, term.lo), plus(sum.hi, term.hi)}
		if compare(term.hi, int_of(1)) <= 0 {
			return Interval{sum.lo, plus(sum.hi, int_of(1))}
		}
	}
}

// asin x and acos x for |x| <= 1 other than the special cases, as atan2(x, w)
// and atan2(w, x) with w = sqrt(1 - x^2), the base and sign of atan t chosen
// as `oracle_atan2` chooses them. With a = |x| = s 2^e, 1 - a^2 = m 2^(2e)
// for the integer m = 2^(-2e) - s^2, so at a scale of 2^(e - E), a is s 2^E
// exactly and w lies between W = floor(sqrt(m 2^(2E))) and W + 1, with E
// chosen so that W has a few more bits than the result's scale. atan is
// monotone, so atan t lies between its values at the two quotients; a < w
// exactly when 2 a^2 < 1, and then s 2^E <= W, else W + 1 <= s 2^E, so
// each quotient is at most one. t is 0 at x = 0 for acos and |x| = 1, and
// otherwise not a dyadic: w is irrational, or a and w are both rational and
// t with them, and atan of a nonzero rational is not one.
@(private = "file")
arc_attempt :: proc(o: ^Oracle, function: Oracle_Function, x: f64, format: Float_Format, w: int) -> (u64, bool) {
	s, e := dyadic(abs(x))
	if x == 0 {
		s, e = int_of(0), -1
	}
	m := minus(power_of_two(-2*e), times(s, s))
	small := compare(times(times(s, s), int_of(2)), power_of_two(-2*e)) < 0
	quarter, sign, negative := 0, 1, false
	if function == .Asin {
		negative = x < 0
		if !small {
			quarter, sign = 2, -1
		}
	} else if small {
		quarter, sign = 2, x < 0 ? 1 : -1
	} else if x < 0 {
		quarter, sign = 4, -1
	}
	// With no base, the result is near t, at least s 2^e or 2^((bits(m) - 1)/2 + e),
	// so it gets as many more bits as that is below one.
	scale := w + 2
	if quarter == 0 {
		leading := small ? bit_count(s) - 1 + e : (bit_count(m) - 1)/2 + e
		scale = w + max(0, 1 - leading)
	}
	quarter_pi := narrow(o.pi, CONSTANT_PRECISION + 2, scale)
	value := Interval{times(quarter_pi.lo, int_of(quarter)), times(quarter_pi.hi, int_of(quarter))}
	if sign_of(s) != 0 && sign_of(m) != 0 {
		extra := max(0, scale + 6 - bit_count(m)/2)
		a := shift_left(s, extra)
		root := square_root(shift_left(m, 2*extra))
		root_up := plus(root, int_of(1))
		low, high: Interval
		if small {
			low, high = atan_interval(a, root_up, scale), atan_interval(a, root, scale)
		} else {
			low, high = atan_interval(root, a, scale), atan_interval(root_up, a, scale)
		}
		if sign > 0 {
			value = Interval{plus(value.lo, low.lo), plus(value.hi, high.hi)}
		} else {
			value = Interval{minus(value.lo, high.hi), minus(value.hi, low.lo)}
		}
	}
	if sign_of(value.lo) <= 0 {
		return 0, false
	}
	return round_interval(value, -scale, negative, format)
}

// sin, cos, and tan of |x| = q pi/2 + r, |r| a little over pi/4 at most, from
// the Taylor series of sin |r| and cos |r|, both positive there; tan is
// their quotient, or for an odd q minus its reciprocal. A tiny argument gets
// as many more bits as it is below one, since sin x and tan x are about x.
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
	if function == .Tan {
		odd := quadrant % 2 == 1
		s := alternating_series(r, r2, 2, w)
		c := alternating_series(Interval{power_of_two(w), power_of_two(w)}, r2, 1, w)
		top, bottom := odd ? c : s, odd ? s : c
		if sign_of(top.lo) <= 0 || sign_of(bottom.lo) <= 0 {
			return 0, false
		}
		quotient := Interval{divide_down(shift_left(top.lo, w), bottom.hi), divide_up(shift_left(top.hi, w), bottom.lo)}
		return round_interval(quotient, -w, (odd != r_negative) != math.sign_bit(x), format)
	}
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
	count, _ := big.count_bits(a)
	return count
}

// The low `count` bits of a non-negative integer, count <= 64.
@(private = "file")
low_bits :: proc(a: ^big.Int, count: int) -> u64 {
	result, _ := big.int_get_u64(minus(a, shift_left(shift_down(a, count), count)))
	return result
}

// The constants `core:math/repro`'s `exp` is built from, as the Loke source
// between its generated-block markers: 2^(i/128) as a pair of `f64`, the high
// one correctly rounded and the low one the correctly rounded rest; ln 2/128
// in three parts, the first two of 35 significant bits so a multiple by an
// integer below 2^18 is exact; and ln 2 * 2^320, floored, as six limbs.
exp_constants_source :: proc(o: ^Oracle) -> string {
	context.allocator = virtual.arena_allocator(&o.arena)
	P :: 400
	b: strings.Builder
	strings.builder_init(&b)
	strings.write_string(&b, "EXP_TABLE :: [256]u64{\n")
	// 2^(2^-j) for j in 1 ..= 7, each the square root of the one before, and
	// 2^(i/128) the product of those its bits select, all as intervals.
	roots: [8]Interval
	roots[0] = Interval{power_of_two(P + 1), power_of_two(P + 1)}
	for j in 1 ..= 7 {
		roots[j] = Interval {
			square_root(shift_left(roots[j - 1].lo, P)),
			plus(square_root(shift_left(roots[j - 1].hi, P)), int_of(1)),
		}
	}
	for i in 0 ..< 128 {
		v := Interval{power_of_two(P), power_of_two(P)}
		for j in 1 ..= 7 {
			if i & (1 << uint(7 - j)) != 0 {
				v = Interval{shift_down(times(v.lo, roots[j].lo), P), shift_up(times(v.hi, roots[j].hi), P)}
			}
		}
		low_end, high_end := split_pair(v.lo, P), split_pair(v.hi, P)
		if low_end != high_end {
			panic("2^(i/128) needs more bits to round")
		}
		fmt.sbprintf(&b, "\t0x%016x, 0x%016x,\n", transmute(u64)low_end[0], transmute(u64)low_end[1])
	}
	strings.write_string(&b, "};\n")
	ln2 := narrow(o.ln2, CONSTANT_PRECISION, P)
	part := divide_down(ln2.lo, int_of(128))
	parts: [3]f64
	for index in 0 ..< 3 {
		parts[index] = index < 2 ? split_round(part, P, 35) : split_round(part, P, 53)
		part = minus(part, scaled_value(parts[index], P))
	}
	fmt.sbprintf(&b, "LN2_128_HI :: 0x%016x;\n", transmute(u64)parts[0])
	fmt.sbprintf(&b, "LN2_128_MID :: 0x%016x;\n", transmute(u64)parts[1])
	fmt.sbprintf(&b, "LN2_128_LO :: 0x%016x;\n", transmute(u64)parts[2])
	fixed := floor_shift(ln2.lo, P - 320)
	strings.write_string(&b, "LN2_FIXED :: [6]u64{")
	for limb in 0 ..< 6 {
		fmt.sbprintf(&b, "%s0x%016x", limb == 0 ? "" : ", ", low_bits(shift_down(fixed, 64*limb), 64))
	}
	strings.write_string(&b, "};\n")
	return strings.to_string(b)
}

// floor(sqrt(n)) for n >= 0.
@(private = "file")
square_root :: proc(n: ^big.Int) -> ^big.Int {
	r := new(big.Int)
	_ = big.int_sqrt(r, n)
	return r
}

// `n * 2^-scale` as its nearest `f64` and the nearest `f64` to the rest.
@(private = "file")
split_pair :: proc(n: ^big.Int, scale: int) -> [2]f64 {
	hi := split_round(n, scale, 53)
	return {hi, rest_round(minus(n, scaled_value(hi, scale)), scale)}
}

// A positive `n * 2^-scale` rounded to `bits` significant bits, as an `f64`;
// `n` is a floor of the value with more than enough bits below the rounding
// that the floor cannot move it.
@(private = "file")
split_round :: proc(n: ^big.Int, scale: int, bits: int) -> f64 {
	negative := sign_of(n) < 0
	m := negative ? negated(n) : n
	drop := bit_count(m) - bits
	kept := shift_down(m, drop)
	order := compare(minus(m, shift_left(kept, drop)), power_of_two(drop - 1))
	k := low_bits(kept, 64)
	if order > 0 || (order == 0 && k & 1 == 1) {
		k += 1
	}
	value := math.ldexp(f64(k), drop - scale)
	return negative ? -value : value
}

// The nearest `f64` to a signed `n * 2^-scale`.
@(private = "file")
rest_round :: proc(n: ^big.Int, scale: int) -> f64 {
	if sign_of(n) == 0 {
		return 0
	}
	return split_round(n, scale, 53)
}

// An `f64` as an integer at `2^-scale`, exactly.
@(private = "file")
scaled_value :: proc(x: f64, scale: int) -> ^big.Int {
	significand, exponent := dyadic(abs(x))
	v := shift_left(significand, scale + exponent)
	return x < 0 ? negated(v) : v
}

// The constants `core:math/repro`'s `sin` and `cos` are built from, as the
// Loke source between trig.loke's generated-block markers: sin and cos of
// j/256 for j in 0 ..= 201 as `f64` pairs, each the correctly rounded value
// and the correctly rounded rest; pi/2 in four parts for Cody and Waite's
// reduction, the first three of 33 bits so a multiple by an integer below
// 2^20 is exact, and as an `f64` pair; the first 1,536 bits of 2/pi, the
// most significant first; and pi/2 * 2^320, floored, as six limbs.
trig_constants_source :: proc(o: ^Oracle) -> string {
	context.allocator = virtual.arena_allocator(&o.arena)
	P :: 2000
	b: strings.Builder
	strings.builder_init(&b)

	strings.write_string(&b, "SIN_COS_TABLE :: [808]u64{\n")
	for j in 0 ..< 202 {
		pairs: [2][2]f64 = {{0, 0}, {1, 0}}
		if j > 0 {
			a := shift_left(int_of(j), P - 8)
			square := times(a, a)
			r2 := Interval{shift_down(square, P), shift_up(square, P)}
			sine := alternating_series(Interval{a, a}, r2, 2, P)
			cosine := alternating_series(Interval{power_of_two(P), power_of_two(P)}, r2, 1, P)
			pairs = {exact_pair(sine, P), exact_pair(cosine, P)}
		}
		fmt.sbprintf(
			&b, "\t0x%016x, 0x%016x, 0x%016x, 0x%016x,\n",
			transmute(u64)pairs[0][0], transmute(u64)pairs[0][1],
			transmute(u64)pairs[1][0], transmute(u64)pairs[1][1],
		)
	}
	strings.write_string(&b, "};\n")

	half_pi := narrow(o.pi, CONSTANT_PRECISION + 1, P)
	part := half_pi.lo
	for index in 0 ..< 4 {
		value := index < 3 ? split_round(part, P, 33) : split_round(part, P, 53)
		fmt.sbprintf(&b, "PIO2_%d :: 0x%016x;\n", index + 1, transmute(u64)value)
		part = minus(part, scaled_value(value, P))
	}
	pair := exact_pair(half_pi, P)
	fmt.sbprintf(&b, "PIO2_HI :: 0x%016x;\n", transmute(u64)pair[0])
	fmt.sbprintf(&b, "PIO2_LO :: 0x%016x;\n", transmute(u64)pair[1])

	// floor(2/pi * 2^1536) from both ends of pi's interval, which agree.
	pi := narrow(o.pi, CONSTANT_PRECISION, P)
	numerator := power_of_two(1537 + P)
	two_over_pi := divide_down(numerator, pi.hi)
	if compare(two_over_pi, divide_down(numerator, pi.lo)) != 0 {
		panic("2/pi needs more bits of pi")
	}
	strings.write_string(&b, "TWO_OVER_PI :: [24]u64{\n")
	for word in 0 ..< 24 {
		fmt.sbprintf(&b, "%s0x%016x,%s", word % 4 == 0 ? "\t" : " ", low_bits(shift_down(two_over_pi, 1536 - 64*(word + 1)), 64), word % 4 == 3 ? "\n" : "")
	}
	strings.write_string(&b, "};\n")

	wide := narrow(half_pi, P, 320)
	if compare(wide.lo, wide.hi) != 0 && compare(plus(wide.lo, int_of(1)), wide.hi) != 0 {
		panic("pi/2 needs more bits")
	}
	strings.write_string(&b, "PIO2_WIDE :: [6]u64{")
	for limb in 0 ..< 6 {
		fmt.sbprintf(&b, "%s0x%016x", limb == 0 ? "" : ", ", low_bits(shift_down(wide.lo, 64*limb), 64))
	}
	strings.write_string(&b, "};\n")
	return strings.to_string(b)
}

// The constants `core:math/repro`'s `log` is built from, as the Loke source
// between log.loke's generated-block markers. For i in 0 ..= 128, d near
// 1/(1 + i/128), of 29 bits so its product with an `f32` significand is
// exact, and exactly 1 and 1/2 at the ends; then L = -log d, or -log 2d from
// i = 53 on, as an `f64` pair, which is 0 at both ends. Then ln 2 as a part
// of 42 bits, so a multiple by an exponent is exact, and the nearest `f64`
// to the rest. Then `pow`'s second table: for k in -128 ..= 128, the
// nearest `f64` to 1/(1 + k 2^-15), exactly 1 at k = 0, and -log of it as
// an `f64` pair.
log_constants_source :: proc(o: ^Oracle) -> string {
	context.allocator = virtual.arena_allocator(&o.arena)
	P :: 400
	b: strings.Builder
	strings.builder_init(&b)
	strings.write_string(&b, "LOG_TABLE :: [387]u64{\n")
	for i in 0 ..= 128 {
		d := 1.0
		pair := [2]f64{0, 0}
		if i == 128 {
			d = 0.5
		} else if i > 0 {
			d = split_round(divide_down(power_of_two(P + 7), int_of(128 + i)), P, 29)
			v := log_interval(o, i >= 53 ? 2*d : d, P)
			pair = exact_pair(Interval{negated(v.hi), negated(v.lo)}, P)
		}
		fmt.sbprintf(&b, "\t0x%016x, 0x%016x, 0x%016x,\n", transmute(u64)d, transmute(u64)pair[0], transmute(u64)pair[1])
	}
	strings.write_string(&b, "};\n")
	ln2 := narrow(o.ln2, CONSTANT_PRECISION, P)
	parts: [2][2]f64
	for end, index in ([2]^big.Int{ln2.lo, ln2.hi}) {
		parts[index][0] = split_round(end, P, 42)
		parts[index][1] = rest_round(minus(end, scaled_value(parts[index][0], P)), P)
	}
	if parts[0] != parts[1] {
		panic("ln 2 needs more bits to split")
	}
	fmt.sbprintf(&b, "LN2_HI :: 0x%016x;\n", transmute(u64)parts[0][0])
	fmt.sbprintf(&b, "LN2_LO :: 0x%016x;\n", transmute(u64)parts[0][1])
	strings.write_string(&b, "LOG_FINE_TABLE :: [771]u64{\n")
	for k in -128 ..= 128 {
		d := 1.0
		pair := [2]f64{0, 0}
		if k != 0 {
			d = split_round(divide_down(power_of_two(P + 15), int_of(32768 + k)), P, 53)
			v := log_interval(o, d, P)
			pair = exact_pair(Interval{negated(v.hi), negated(v.lo)}, P)
		}
		fmt.sbprintf(&b, "\t0x%016x, 0x%016x, 0x%016x,\n", transmute(u64)d, transmute(u64)pair[0], transmute(u64)pair[1])
	}
	strings.write_string(&b, "};\n")
	return strings.to_string(b)
}

// The constants `core:math/repro`'s `log2` and `log10` are built from, as the
// Loke source between log_base.loke's generated-block markers: 1/ln 2 and
// 1/ln 10 as `f64` pairs, the nearest `f64` and the nearest to the rest, and
// times 2^320, floored, as six limbs.
log_base_constants_source :: proc(o: ^Oracle) -> string {
	context.allocator = virtual.arena_allocator(&o.arena)
	P :: 400
	b: strings.Builder
	strings.builder_init(&b)
	ln2 := narrow(o.ln2, CONSTANT_PRECISION, P)
	divisors := [2]Interval{ln2, log_interval(o, 10, P)}
	inverses: [2]Interval
	for d, i in divisors {
		inverses[i] = Interval{divide_down(power_of_two(2*P), d.hi), divide_up(power_of_two(2*P), d.lo)}
	}
	strings.write_string(&b, "LOG_BASE_PAIRS :: [4]u64{")
	for v, i in inverses {
		pair := exact_pair(v, P)
		fmt.sbprintf(&b, "%s0x%016x, 0x%016x", i == 0 ? "" : ", ", transmute(u64)pair[0], transmute(u64)pair[1])
	}
	strings.write_string(&b, "};\n")
	strings.write_string(&b, "LOG_BASE_FIXED :: [2][6]u64{\n")
	for v in inverses {
		wide := narrow(v, P, 320)
		if compare(wide.lo, wide.hi) != 0 && compare(plus(wide.lo, int_of(1)), wide.hi) != 0 {
			panic("a logarithm's base needs more bits")
		}
		strings.write_string(&b, "\t{")
		for limb in 0 ..< 6 {
			fmt.sbprintf(&b, "%s0x%016x", limb == 0 ? "" : ", ", low_bits(shift_down(wide.lo, 64*limb), 64))
		}
		strings.write_string(&b, "},\n")
	}
	strings.write_string(&b, "};\n")
	return strings.to_string(b)
}

// The constants `core:math/repro`'s `atan2` is built from, as the Loke source
// between atan.loke's generated-block markers: atan(j/128) for j in 0 ..= 128
// as `f64` pairs, each the correctly rounded value and the correctly rounded
// rest, and atan(j/8) * 2^320 for j in 0 ..= 8, floored, as six limbs.
atan_constants_source :: proc(o: ^Oracle) -> string {
	context.allocator = virtual.arena_allocator(&o.arena)
	P :: 400
	b: strings.Builder
	strings.builder_init(&b)
	strings.write_string(&b, "ATAN_TABLE :: [258]u64{\n")
	for j in 0 ..= 128 {
		pair := [2]f64{0, 0}
		if j > 0 {
			pair = exact_pair(atan_interval(int_of(j), int_of(128), P), P)
		}
		fmt.sbprintf(&b, "\t0x%016x, 0x%016x,\n", transmute(u64)pair[0], transmute(u64)pair[1])
	}
	strings.write_string(&b, "};\n")
	strings.write_string(&b, "ATAN_WIDE :: [9][6]u64{\n")
	for j in 0 ..= 8 {
		wide := Interval{int_of(0), int_of(0)}
		if j > 0 {
			wide = narrow(atan_interval(int_of(j), int_of(8), P), P, 320)
			if compare(wide.lo, wide.hi) != 0 && compare(plus(wide.lo, int_of(1)), wide.hi) != 0 {
				panic("atan(j/8) needs more bits")
			}
		}
		strings.write_string(&b, "\t{")
		for limb in 0 ..< 6 {
			fmt.sbprintf(&b, "%s0x%016x", limb == 0 ? "" : ", ", low_bits(shift_down(wide.lo, 64*limb), 64))
		}
		strings.write_string(&b, "},\n")
	}
	strings.write_string(&b, "};\n")
	return strings.to_string(b)
}

// An interval's value as an `f64` pair, which both ends must give.
@(private = "file")
exact_pair :: proc(v: Interval, scale: int) -> [2]f64 {
	low_end, high_end := split_pair(v.lo, scale), split_pair(v.hi, scale)
	if low_end != high_end {
		panic("a constant needs more bits to round")
	}
	return low_end
}

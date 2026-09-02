# `core:math` plan

Status: proposed. `core:math` today holds one file, `complex.loke`, with
`Complex(T)` and `Quaternion(T)`. Neither can answer `abs`, because the package
has no square root. This plan adds the elementary functions and the constants,
and then closes the two holes those types document in their own comments.

## What is missing, concretely

`core/math/complex.loke` names both gaps itself:

- `norm_squared` exists and `abs` does not, "because it needs a square root and
  `core:math` has no elementary functions yet";
- `Complex.divide` is the textbook form and "overflows for operands whose
  squares do not fit, which is the price of not having a scaled `hypot`".

Everything else follows from those two: a program doing any floating-point work
currently has no `sqrt`, no `sin`, no `floor`, no `pi`, and no way to ask
whether a value is NaN.

## Where the functions come from

Four tiers, in the order this plan reaches for them.

**Compiler prerequisite: implement `unsafe.transmute`.** `design.md` currently
specifies a predeclared `transmute(T, value)`, but the universe does not define
it and `lokec` reports `L0315: unknown name`. The design is changed before the
implementation: general bit reinterpretation is not a safe, universally valid
conversion, so its public spelling is `unsafe.transmute(T, value)` from
`core:unsafe`. It is never injected into the universe or made implicitly
available to ordinary source. `core:math` imports `core:unsafe` privately and
uses the operation only in its bit-level implementation.

The compiler recognizes the procedure contributed to `core:unsafe`, just as it
does that package's other compiler-backed operations. The checker requires
equal-sized source and destination types with trivial lifecycles and rejects
managed values, references, borrows, and aggregates containing them. It emits
an LLVM bitcast or an equal-size storage copy as appropriate and evaluates
scalar integer/float bitcasts at compile time. The compiler rejects a provably
invalid constant `bool` or enum result; for a runtime result, producing only a
valid destination representation is the caller's obligation. Pointer
destinations are limited to `rawptr` and C pointers, and the result is unchecked:
dereferencing it is valid only when the input bits already describe suitably
aligned, live storage of the destination pointee type. These rules belong in
`core:unsafe`'s public doc comment and in `design.md`, not only in compiler code.

The prerequisite gets direct positive and negative compiler tests, including
the exact conversions needed here: `f32` to/from `u32`, and `f64` to/from `u64`
in both runtime and constant contexts. Constant evaluation must retain the
source-width raw bits rather than round-trip an `f32` NaN payload through the
current numeric `f64` field; extend the constant representation if necessary.
Signed zero and NaN payload tests make that requirement observable. The math
work does not begin until those tests pass.

**Ordinary Loke, over private `unsafe.transmute` calls.** Classification and
sign manipulation are bit tests: `is_nan`, `is_infinite`, `is_finite`,
`sign_bit`, `copy_sign`, and `abs`. The `f32` forms use `u32`; the `f64` forms
use `u64`. Clearing the sign bit is the spelling that maps `-0.0` to `+0.0`
while preserving a NaN's payload and quiet/signalling bit. No `f16` form is part
of this plan.

**The versioned seed runtime, through one private foreign block.** Directly
binding public CRT/libm names would make `core:math` depend on the host linker's
implicit libraries. Instead, `runtime/math.c` and `runtime/loke_rt.h` expose
versioned wrappers such as `loke_rt_v1_math_sqrt_f64` and
`loke_rt_v1_math_sqrt_f32`. A private `foreign loke_runtime` block binds only
those versioned names, as other core packages already do for seed-runtime APIs.

The C file includes `<math.h>` and delegates to the target C math implementation.
The target toolchain supplies its math link input explicitly where required:
the current Windows CRT needs no new flag, Linux adds `-lm`, and macOS uses
libSystem. Platform work must settle this in the target record rather than in
`core:math` source.

This layer promises the documented classifications, signs, poles, and domain
results below; it does not promise correctly rounded transcendental functions,
identical last bits across platforms, a particular NaN payload, or portable
`errno` contents. Calls may raise the floating-point exceptions the target C
implementation specifies. They never translate `errno` or an exception flag
into a Loke panic. Target bring-up runs the special-case conformance table; a
wrapper normalizes a host-library difference where practical, and a target that
cannot meet the contract is not declared supported.

**Compiler intrinsics — deferred behind a semantic gate.** LLVM has intrinsics
for some of this surface, but they are not automatically equivalent to CRT calls
and do not universally lower to one instruction. A wrapper may become an
intrinsic only after tests show the same signed-zero, NaN, rounding-mode, and
floating-exception behavior promised by this plan on every supported target.
Measured call overhead is necessary but not sufficient.

## The overload trap, and the naming that avoids it

design.md, "Operator lookup and overload resolution": "`i8` vs `int` overloads
(or `f32` vs `f64` for `7.0`) remain ambiguous". A procedure group
`sqrt :: proc{sqrt_f32, sqrt_f64}` therefore makes `math.sqrt(2.0)` a compile
error — the most obvious call in the package fails.

So there are no groups. The unsuffixed name is the `f64` one, and the `f32` twin
carries the suffix, matching `strconv.parse_int` / `parse_uint`:

```odin
sqrt     :: proc(x: f64) -> f64
sqrt_f32 :: proc(x: f32) -> f32
```

Both ship together rather than `f64` first. Loke has no implicit `f32` → `f64`
widening, so an `f32`-only caller with no twin would write
`f32(math.sqrt(f64(x)))`, which rounds twice and is wrong. The twin is one line
over the versioned f32 runtime wrapper; the wrong idiom it prevents is not.

`f16` gets nothing. The CRT has no `f16` variants and no caller has asked.

## The surface

`core/math/math.loke`, one file, `@(public) package math` alongside the existing
`complex.loke`.

Every float-specific procedure has exactly two concrete spellings: the
unsuffixed name takes and returns `f64`, and the `_f32` name takes and returns
`f32`. This applies to classification and sign procedures as well as to the
CRT-backed ones; there is no generic float-only procedure and no `f16` form.
The scalar comparison procedures below are deliberately generic instead.

**Constants.** Unfixed floating constants, so each converts at the point of use
to whichever floating type the context wants:

```odin
PI, TAU, E, LN2, LN10, SQRT_TWO
```

Typed limits need a type in the name, because a limit is a property of one
format:

```odin
F32_EPSILON, F64_EPSILON
F32_MAX, F64_MAX
F32_MIN_NORMAL, F64_MIN_NORMAL
F32_MIN_SUBNORMAL, F64_MIN_SUBNORMAL
F32_INFINITY, F64_INFINITY, F32_NAN, F64_NAN
```

`EPSILON` is the gap from `1` to the next representable value. `MIN_NORMAL` is
the smallest positive normal value and `MIN_SUBNORMAL` is the smallest positive
subnormal value. Infinity and the canonical quiet NaN have no literal spelling,
so all typed limits are constructed from their exact integer bit patterns in
private, constant-evaluated `unsafe.transmute` calls. The unsafe dependency is
an implementation detail and does not leak through the public math API. The NaN
payload is canonical only for the constant; procedures may propagate or return
another quiet payload.

**Classification and sign** (Loke, private `unsafe.transmute`):

```odin
is_nan, is_infinite, is_finite, sign_bit, copy_sign, abs
```

**Rounding and remainder** (CRT): `floor`, `ceil`, `round`, `trunc`, `mod`.
`mod` rather than `fmod`: floating types have no `%` operator, and this is that
operator's name in Loke terms. `round` rounds halfway cases away from zero.
`mod` has the mathematical result of `x - trunc(x/y)*y` without requiring that
overflow-prone expression as its implementation; the sign of a non-zero result
matches `x`, and an exact-zero result preserves the sign of `x`. A zero divisor
or infinite `x` produces NaN, while finite `x` modulo an infinite `y` returns
`x`.

**Roots, powers, logarithms** (CRT): `sqrt`, `hypot`, `pow`, `exp`, `log`,
`log2`, `log10`. They do not panic on a floating domain or pole: `sqrt` of a
negative finite value other than `-0.0` is NaN; logarithms of a negative value
are NaN and logarithms of either zero are negative infinity. `sqrt` preserves
the sign of zero. `hypot` is non-negative and an infinite operand wins over a
NaN operand.

**Trigonometry** (CRT): `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`,
plus `to_radians` and `to_degrees`, which are one multiply each and are the two
conversions every caller otherwise open-codes with a wrong constant. An infinite
argument to `sin`, `cos`, or `tan` produces NaN; `asin` and `acos` produce NaN
outside `[-1, 1]`; `atan2` preserves the quadrant and signed-zero cases defined
by IEC 60559.

For the CRT-backed arithmetic functions, NaN input propagates to a quiet NaN
except for an operation with a stronger specified result, such as
`hypot(infinity, NaN)`. The bit-based classification and sign functions do not
quiet a NaN. `pow` follows the IEC 60559 special-case table for zero, infinity,
negative bases, and integral exponents. That table is copied into the public
doc comment and the runtime tests before the wrapper is accepted; the plan does
not leave those cases to an undocumented host-CRT accident. Exact NaN payloads
and the last bit of finite transcendental results remain unspecified.

**Comparison** (Loke, generic):

```odin
min :: proc(a, b: $T) -> T
    where interfaces.Numeric(T), interfaces.Ordered(T)
max :: proc(a, b: $T) -> T
    where interfaces.Numeric(T), interfaces.Ordered(T)
clamp :: proc(value, low, high: $T) -> T
    where interfaces.Numeric(T), interfaces.Ordered(T)
```

These cover numeric scalars rather than every type that happens to be ordered;
strings, enums, and pointers therefore do not acquire arithmetic-looking
operations from `core:math`. They do not go through the CRT. `min` returns `a`
when `a < b` and `b` otherwise; `max` returns `a` when `b < a` and `b`
otherwise. Equal or unordered operands therefore select the second argument,
including signed zeros and a NaN in either position.

`clamp` panics when `high < low`, then returns `low` when `value < low`, `high`
when `high < value`, and `value` otherwise. A NaN value is returned unchanged;
a NaN bound is unordered and does not clamp on that side. These rules are in
the doc comments and tests. `core:slice` already has `min`/`max` over a slice;
these are the scalar forms and the packages do not overlap.

## What `Complex` and `Quaternion` gain

The existing types are constrained by `interfaces.Numeric(T)`, which includes
integers and does not imply ordering. Calling an `f32`/`f64` `hypot` from that
generic implementation would not type-check, and silently narrowing the types
would break existing source. The generic implementation therefore remains as
it is. New operations live in exact specialization blocks, a lookup form the
language already supports:

```odin
impl Complex(f64)    { /* abs, inverse, specialised divide */ }
impl Complex(f32)    { /* same surface through `_f32` scalar functions */ }
impl Quaternion(f64) { /* abs, inverse */ }
impl Quaternion(f32) { /* same surface through `_f32` scalar functions */ }
```

The exact `Complex` blocks replace the generic `/` member for those two
instantiations; other numeric instantiations retain the existing textbook
operator and gain neither `abs` nor `inverse`.

- `Complex.abs` is `hypot(real, imaginary)`.
- `Quaternion.abs` is
  `hypot(hypot(real, i), hypot(j, k))`. The nested form avoids overflow and
  underflow in the sum of four squares; its extra rounding is within the normal
  target-libm accuracy contract.
- Floating `Complex.divide` uses Smith's branch on the larger denominator
  component and never forms `c*c + d*d`. Its stated guarantee is narrow and
  testable: finite non-zero denominator components do not overflow merely
  because their squares would overflow. It does not claim bit-for-bit C complex
  semantics for every NaN/infinity combination; those outcomes are documented
  and tested explicitly.
- `Complex.inverse` uses the specialised division path rather than spelling
  `conjugate/norm_squared` again.
- `Quaternion.inverse` scales all four components by their maximum absolute
  value, forms the normalized sum of squares, and divides in stages so it does
  not create an avoidable overflowing `norm_squared`. A zero quaternion returns
  NaN components under the scalar floating rules.

`Quaternion` still gets no `/` operator. Quaternion division is left- or
right-multiplication by the inverse and the two differ; an operator would have
to pick one silently. `inverse` makes the caller write which.

## Deliberately not in v1

Named here so a later step is an addition and not a redesign: hyperbolic
functions; `cbrt`, `exp2`, `expm1`, `log1p`, `fma`; `ldexp`, `frexp`, `modf`;
integer helpers (`gcd`, `is_power_of_two`, `next_power_of_two`, `count_ones`) —
those are bit operations and want a `core:bits`, not this package; `erf` and
`gamma`; lane-wise math over `Simd(T, N)`; `core:random`; fixed-point; and any
vector or matrix type. `Quaternion.normalize` and a rotation API wait for
something that rotates.

## Implementation order

Each step is one reviewable commit with proportionate tests in the existing
compiler and integration corpora.

1. **Implement `unsafe.transmute`.** First move the documented operation from
   the predeclared universe into `core:unsafe`, then add the compiler-contributed
   symbol, checker, constant evaluator, and LLVM emission. Do not retain a global
   compatibility alias. Unit tests cover visibility, type/size and lifecycle
   rejection, checked-reference rejection, invalid constant destinations, and
   unchecked pointer results; `tests/run/unsafe_transmute.loke` and matching
   error cases cover scalar constant and runtime bitcasts. This prerequisite
   stands on its own and is not hidden inside the library commit.
2. **`math.loke`: constants, classification, sign, and scalar comparison.**
   Test both widths in `tests/run/lib_math_bits.loke`: exact constant bit
   patterns, quiet NaN/infinity/subnormal classification, both signed zeros,
   payload-preserving `abs`/`copy_sign`, second-argument `min`/`max`, NaN
   behavior, and every `clamp` branch. A `tests/trap` case covers reversed clamp
   bounds.
3. **Versioned runtime bridge and elementary functions.** Add `runtime/math.c`,
   declarations in `runtime/loke_rt.h`, the target-owned math link input, one
   private foreign block, and the public wrappers. `tests/run/lib_math.loke`
   exercises every f64 and f32 symbol plus the special-case table specified
   above. An LLVM
   test asserts that the Loke declarations call the width-matched versioned
   symbols rather than host CRT names.
4. **Floating `Complex`/`Quaternion` specializations.** Extend
   `tests/run/lib_numeric.loke` with ordinary values, huge and subnormal
   magnitudes, zero, infinity, and NaN. Include a denominator whose component
   squares overflow but whose complex quotient is finite; that is the regression
   the Smith rewrite claims to fix.
5. **Intrinsics remain outside v1.** A later measured change gets its own plan,
   target matrix, and semantic-equivalence tests. There is no speculative
   `STD_MATH` step in this implementation series.

## Testing notes

Three rules keep the corpus portable without weakening what it checks.

**The differential-optimization corpus runs every `tests/run` case at each
`-opt` level** (`LOKE_TEST_FLAGS`), and one `.expected` has to match all of
them. A transcendental result printed at `%.17g` is exactly the kind of value
that can move in its last digit if a constant gets folded at compile time
instead of computed at run time. So: assert on values that are exact in binary
floating point — `sqrt(4)`, `floor(2.5)`, `pow(2, 10)`, `hypot(3, 4)` — and for
anything else print a comparison rather than the number. Use a combined bound,
`abs(got-want) <= absolute_tolerance + relative_tolerance*abs(want)`, with
separate f32 and f64 tolerances. A fixed `1e-12` absolute threshold is neither a
meaningful f32 test nor sufficient over a wide dynamic range.

**Test classifications and special values, not their text.** For every public
wrapper, the table includes ordinary finite inputs, both zeros where signs
matter, positive and negative infinity, quiet NaN, and each documented domain
or pole. Exact operations test exact bits. Transcendental accuracy checks never
stand in for the special-case contract, and the f32 cases call the `_f32`
surface directly.

**Do not print a NaN.** `loke_rt_v1_fmt_f64` is `snprintf("%.17g")`, and the
MSVC runtime spells a NaN `nan`, `-nan(ind)` or `nan(snan)` depending on the
payload. Print `is_nan(x)` instead. That the runtime's NaN and infinity
spellings are the platform C library's, rather than anything Loke chose, is a
separate question worth settling in `core:fmt` — but not by this plan.

# `src/const_float.odin` review

Reviewed [`src/const_float.odin`](../../src/const_float.odin) at `ea622efe`.

## Findings

- **P3 · Use Odin's direct binary32 parser, lines 283–386.** The pinned Odin
  toolchain's `strconv.parse_f32` rounds decimal input directly to binary32.
  The compiler already uses its binary64 counterpart at literal checking.
  Send the original decimal spelling to the binary32 parser at conversion and
  keep the binary16 path for exact half-precision midpoints. An overflowing
  finite literal must still produce a conversion diagnostic. The existing
  helper's `ok` mixes unsupported input and overflow, and currently reports
  overflow differently for positive and negative decimal exponents. Let the
  conversion caller distinguish a missing spelling from a parsed decimal that
  is out of range. [Literal checking](../../src/check_expr.odin) ·
  [Constant conversion](../../src/const_ops.odin) ·
  [Pinned Odin](../../readme.md#building-from-source) ·
  [Number literals](../design.md#number-literals)
- **P3 · Bound the work before allocating big integers, lines 235–264 and
  341–364.** `dyadic_to_float` rebuilds the discarded digits and a halfway
  integer even when `leading` is above the target's maximum normal exponent
  and infinity is already determined. Return a signed infinity there and keep
  the rounding logic at the highest normal exponent, where the rounding can
  carry into overflow. When `shift <= 0`, the unshifted magnitude already fits
  in `u64`; extract it before shifting to remove that bignum temporary. On
  the decimal path, trim leading and trailing digit zeroes, adjusting the
  decimal exponent for the trailing zeroes, and apply the zero and range
  checks before parsing a big integer. The existing 20,000-zero test is the
  value 1 and can reduce to `1e0` before creating a significand or power.
  Checker-side `bi_release` leaves these temporaries in the semantic arena
  until teardown. [Big integer storage](../../src/bigint.odin) ·
  [Rounding tests](../../src/bigint_test.odin)
- **Simplification · Encode each constant once, lines 18–26 and 389–408.**
  `float_const` first rounds and then encodes the rounded value. For `f16`,
  this runs `f64_to_f16_bits` twice. Build through
  `float_bits_const(float_pattern(value, bits), bits)` so the numeric view
  comes from the same authoritative encoding. Keep the same-width
  `const_float_pattern` path, which preserves the exact bits of values
  created by `unsafe.transmute`. [Constant constructors](../../src/const_ops.odin) ·
  [Floating-point operators](../design.md#floating-point-operators)
- **Simplification · Skip exponent alignment for a zero FMA addend, lines
  41–48 and 216–224.** Decoding zero gives it exponent `-1074`, so
  `fma(1.0, 1.0, 0.0)` shifts the product left by 970 bits and then rounds it
  back down. In the finite nonzero-product branch, send the exact product
  directly to `dyadic_to_float` when `c == 0`. The existing zero-product
  branch still determines the sign when both the product and addend are zero.
  [FMA rounding tests](../../src/bigint_test.odin) ·
  [`core:math`](../standard-library.md#coremath)

## Scope and verification

The IEEE representations and width-rounding primitives serve the checker,
constant evaluator, and emitter. Keep shared encoding beside the numeric
conversion and keep LLVM spelling in emission. `sqrt_rounded` and
`remainder_exact` fit fixed-width operands in `u128`. The FMA sum can require
far more bits when its product and addend have distant exponents, so the
multi-limb representation serves a real case. The custom binary16 rounding
handles ties to even. No standalone dead path or new user-visible spec gap
was confirmed. Exact decimal values lost before the conversion boundary are
already covered in the [expression checker review](check_expr.md#unfixed-decimals-lose-precision-before-folding-p2).

Used Odin `84bc3fc` to probe `strconv.parse_f32` at the ties near 1 and the
smallest subnormal, just above those ties, at negative zero, immediately
below and at the overflow midpoint, and with a 20,000-zero significand. It
returned the expected encodings and reported overflow through `ok == false`.
The compiler built from the reviewed source passed static assertions for
binary16 midpoint and overflow-edge literals, the largest finite binary32
encoding, FMA with a zero addend and signed underflow, a remainder with a
subnormal divisor, and square root of the smallest binary64 subnormal.
All seven focused Odin tests for integer-to-float and decimal rounding,
binary16 ties, FMA, square root, integral rounding, and remainder passed.

# Deterministic math and CPU targeting plan

Status: proposal, 2026-10-28; partly implemented, 2026-10-29. This document
proposes implementation work; it does not change the language contract. The
current authorities remain [Floating-point operators](design.md#floating-point-operators),
[`core:math`](standard-library.md#coremath), the
[compiler options](compiler-guide.md#common-options), and
[CPU levels](compiler-guide.md#cpu-levels).

## Progress

Implemented, from phases 2 and 3:

- `-cpu=x86-64|x86-64-v2|x86-64-v3`, resolved into `Target_Info`'s CPU level
  and feature set, and passed as `-march` to the module, object, and runtime
  compiles. The runtime's prebuilt objects are kept per level.
- `-ffp-contract=off` on every Clang command. `tests/cpu_test.odin` rebuilds
  the floating-point run cases at v2 and v3 against their baseline output, at
  every `-opt` level under `test-all.ps1 -Full`.
- The startup check. `wmain` above baseline carries an explicit baseline
  `"target-features"` list and first calls `loke_rt_v1_require_cpu`, which
  lives in `runtime/cpu.c`, compiled as baseline code under a Clang
  `target("arch=x86-64")` pragma. A `"target-cpu"` attribute alone was not
  enough: the command line's features still applied, and a v3 callee was
  inlined into it.
- Object builds enforce their level rather than describe it: above baseline
  the object carries a baseline static constructor (`.CRT$XCU`) that calls the
  same check before the host's `main`. Metadata alone would leave every host
  to read and act on it; the constructor needs nothing from the host, which
  can still check first through `loke_rt_v1_cpu_supports`, as one that
  chooses between builds must.
- `math.fma` as the FMA instruction at v3, through two `core:math`-private
  built-ins, and a compile-time evaluator for it that rounds the exact
  integer result once, independent of both the host and the software path.

From phase 1:

- The environment is specified ([Floating-point operators](design.md#floating-point-operators)):
  nearest-even rounding, subnormals kept, and non-stop exceptions on every
  thread, with no Loke operation that changes them and a restore obligation on
  foreign code. `tests/run/float_environment.loke` checks Windows gives it to
  the main thread and to a started one. Phase 4 adds the entry from C hosts;
  see below.
- [Special cases](#special-cases) for `exp`, `log`, `sin`, `cos`, `pow`, and
  `atan2`.
- An oracle, `tests/math_oracle.odin`: outward-rounded interval arithmetic on
  `core:math/big` integers, with Ziv's doubling of the precision, for `exp`,
  `log`, `sin`, and `cos` in both widths, special cases included. It takes
  about half a millisecond per argument, a large `sin` argument the most, and its constants (ln 2, and pi by Machin's
  formula to 4,800 bits for `sin` of the largest `f64`) are built once per
  oracle. Its tests pin known results and its agreement with Odin's library.
  It replaces MPFR, which the Windows toolchain does not provide.
- The UCRT's distance from correct rounding, measured with the oracle and
  recorded in [Deterministic math functions](open-questions.md#deterministic-math-functions).

Phase 3, `exp`, `sin`, and `cos` in both widths in a new
[`core:math/repro`](standard-library.md#coremathrepro):

- Each has a double-`f64` fast path with a relative bound of 2^-67, derived
  in its source, and a decision margin of twice that, and a slow path in
  320-bit fixed point for the rest.
- `exp` reads a 128-entry table of 2^(i/128); every result that could be
  subnormal takes the slow path. `exp_f32` puts a single-`f64` path first,
  whose window of four ulps leaves roughly one argument in 10^7 to the rest.
- `sin` and `cos` reduce by pi/2 three ways: not at all below pi/4, Cody
  and Waite's with pi/2 in four parts below 2^20 pi/2, and Payne and
  Hanek's above, in integers against 1,536 bits of 2/pi, which takes the
  largest `f64` exactly. A 202-entry table of both at j/256 and short series
  give the result; a table at j/128 would not have met the bound for small
  results.
- No `fma`: the one exact product is Dekker's, whose bits are the
  instruction's, so the CPU levels need no dispatch. Using the instruction
  at `x86-64-v3` is a measured speed question, not a correctness one.
- `tests/repro_test.odin` checks the tables and constants against the
  oracle's derivation, compares the fast and slow paths over 180,000 seeded
  arguments, sin and cos ones near multiples of pi/2 and of every magnitude
  among them, and the oracle over 7,500, the slow paths' own results
  included through a copy of the package that exports them, and compares
  compile-time and run-time results. Four `f32` arguments found by search
  pin the retries seeded arguments almost never reach: `exp_f32`'s
  double-`f64` step and slow path, and those of `sin_f32` and `cos_f32`.
  Fixed `f64` arguments at and beside 2^-9, the table's first half step,
  pin its index, which once rounded up there. The probe's output is the
  same at every optimization and CPU level tried.
- Measured cost: about four to five times the UCRT's in throughput; see
  [Deterministic math functions](open-questions.md#deterministic-math-functions).

Phase 3's gate is met: exact agreement with the oracle, and the cost
measured, with and without FMA in the UCRT's paths (`core:math/repro` uses
none). The cost is phase 6's question.

Phase 4, begun with `log` in both widths:

- The fast path takes x = 2^e y and, from a 129-entry table indexed by y's
  top seven fraction bits, d near 1/y and -log d as an `f64` pair, so that
  r = y d - 1 is exact and under 2^-8, and log(1 + r) is a short series. The
  buckets either side of x = 1 have d exactly 1 and 1/2, so near 1 nothing
  cancels; from about sqrt 2 on, y is halved, so E ln 2 and the table's part
  never nearly cancel either. d has 29 bits, which makes r exact in one
  `f64` for an `f32` argument, so `log_f32`'s first approximation needs no
  pair arithmetic.
- The slow path is E ln 2 + 2 atanh((y - 1)/(y + 1)) in 320-bit fixed
  point, the quotient from Newton's iteration for the reciprocal. A
  bit-by-bit division was simpler, but folding it at compile time took more
  than the evaluator's 64 MB; see
  [Deterministic math functions](open-questions.md#deterministic-math-functions).
- An exhaustive pass over every positive `f32` found 138 arguments that
  leave `log_f32`'s first approximation and 16 of them that reach its slow
  path; one of each is pinned, with 1 + 6 2^-52, whose `f64` log is about
  2^-100 from a midpoint. About one seeded `f64` argument in 4,000 takes the
  slow path, as the margin predicts. With `log`, the probe compares the fast
  and slow paths over 220,000 arguments and the oracle over 10,000.

Then `pow` in both widths:

- e^(y log x), with log x as a pair within 2^-83 relative, so that y log x
  is within 2^-73.5 wherever the result is finite and not 0 or 1, and
  `exp`'s kernel, which now takes y log x's low part. The log adds a second
  table at steps of 2^-15 to `log`'s, so that its series is under 2^-16,
  its first entry exactly 1 so that nothing cancels near 1 either.
- The slow path multiplies `log`'s fixed-point value by y and takes `exp`'s
  fixed-point value of that, within 2^-240. x^y can be exactly a midpoint,
  so a value within 2^-230 of one is tested in integers for being exactly
  it, and rounded to even if it is: (2 - 2^-26)^2, (1 + 2^-12)^2 in `f32`,
  and 2^-1075 among them. Nothing proves no other x^y comes that close to
  a midpoint; see
  [Deterministic math functions](open-questions.md#deterministic-math-functions).
- The oracle gains `oracle_pow`, with the table and an exact test of its
  own in big integers for dyadic results, so that Ziv's search never meets
  a midpoint. The probe checks the table over a grid of 143 pairs in each
  width, pinned midpoints, 2,000 seeded pairs against the oracle, a
  thousand of them midpoints, and 40,000 against the slow path.

Then `atan2` and `atan` in both widths, atan x being atan2(x, 1):

- With t the smaller magnitude over the larger, the result is atan t, or
  pi/2 or pi plus or minus it, at least pi/4 then. The fast path takes c =
  j/128 nearest t from a table of `f64` pairs and atan t = atan c + atan u,
  u = (n - c d)/(d + c n) from the two magnitudes, |u| <= 2^-8, so the
  series is short and nothing near zero has an absolute error; `atan2_f32`
  puts a single-`f64` path first, in which u's numerator and denominator
  are exact. The slow path does the same in fixed point at c = J/8, and for
  t < 1/16 scales t near 1 first.
- Below 2^-101, t is closer to atan t than any quotient of two floats comes
  to a midpoint without being one, so it is rounded in integers, but for a
  t exactly halfway, which rounds toward zero: `atan2(3*2^-1074, 2)` is
  2^-1074, not the even 2^-1073. As for `pow`, no search covers two
  arguments, so nothing proves the slow path's 2^-305 enough.
- The oracle gains `oracle_atan2`, which follows the table without listing
  it and sums Euler's series for atan of a rational, independent of the
  implementation's reduction. Odin's `atan2` is an ulp low in about a
  quarter of its sample, where a separate computation by angle halving
  agrees with the oracle.

Then `asin` and `acos` in both widths, as atan2(x, w) and atan2(w, x) with
w = sqrt(1 - x^2):

- No square root instruction is used, since compile-time evaluation did
  not then share one: w is a pair from Newton's steps for 1/sqrt from an
  estimate in the bit pattern, and the `atan2` kernel takes it with one of
  t's operands a pair. `asin_f32` and `acos_f32` put a single-`f64` path
  first, with three steps and a bound of 2^18.5 ulps; an exhaustive pass
  over (0, 1) found its error at most 2^18 and 5 arguments in 1.1 billion
  that reach the slow path. The slow path forms 1 - x^2 exactly in fixed
  point and its root by Newton's iteration there.
- The oracle gains both, bracketing w between integer square roots and
  summing Euler's series at both ends; asin 1/2 = pi/6, acos 1/2 = pi/3,
  and acos -1/2 = 2 pi/3 pin it. Odin's `acos` is an ulp off in about 7% of
  its sample, where Newton's method on cos agrees with the oracle.
- No binary64 worst-case search is relied on, so as for `atan2` nothing
  proves the slow path's 2^-305 enough.

Then `tan` in both widths:

- It takes `sin` and `cos`'s reduction and both kernels, and divides the
  pairs, sin r/cos r or -cos r/sin r by the quadrant. The two kernels'
  errors add, so its bound is 2^-66 and its margin 2^-65, twice the
  others', and about one `f64` argument in 2,800 takes the slow path. That
  takes both series in fixed point and their quotient, the denominator
  scaled near 1.
- An exhaustive pass over every finite `f32` from 2^-12 up found 2 that
  reach the slow path. The oracle divides its sine and cosine intervals.
  Odin's `tan` is sin/cos, rounded twice, so the library test compares it
  with the C library's instead.

Then `log2` and `log10` in both widths:

- Each is `log`'s double-`f64` result times 1/ln 2 or 1/ln 10 as a pair,
  within 2^-68, and `log`'s slow path times the constant in fixed point;
  the `f32` procedures scale `log_f32`'s single-`f64` approximation first.
- log2 x and log10 x are rational only at powers of 2 and 10, where they
  are an integer, a float and not a midpoint, so no exact-case test is
  needed: every close enough approximation rounds to it.
- An exhaustive pass over every positive finite `f32` found 281 and 111
  arguments that reach the double-`f64` step and 0 and 15 that reach the
  slow path, and none where the first approximation disagreed. The oracle
  divides its log by ln 2 or ln 10 and also generates the constants; the
  library test compares with the C library's.

Then `hypot` in both widths, which completes the transcendental functions
of [`core:math`](standard-library.md#coremath):

- x^2 + y^2 is formed with both squares exact, after scaling the larger
  argument into [1, 2), and its root comes from the same software square
  root as `asin`'s. The fast path is within 2^-100, so it decides at 2^-99
  and leaves the slow path to exact midpoints, results that could be
  subnormal, and about one random `f32` pair in 10^7.
- Unlike the others, `hypot` has midpoint results, Pythagorean triples whose
  hypotenuse has one bit too many and is odd. The slow path forms x^2 + y^2
  exactly in fixed point and tests a root near a midpoint by squaring the
  midpoint. A root that is not a midpoint is at least 2^-229 from one, so
  `hypot` is proved correctly rounded, needing no search.
- The oracle takes exact integer square roots. The UCRT's `hypot` is an ulp
  off in an eighth of its sample, where an exact computation in Python
  agrees with the oracle.

Every NaN result of `core:math/repro` is the canonical quiet NaN, signaling
arguments included, as [Reproducible result contract](#reproducible-result-contract)
asks; a whole-program canonicalization mode is separate work, as
[Special cases](#special-cases) says.

Then the entry from foreign code, which
[Execution environment and future platforms](#execution-environment-and-future-platforms)
asks for:

- Instead of a scoped call each host makes, every procedure Loke defines with
  a foreign calling convention guards its own entry. Under its own name it
  reads MXCSR, and only when the control bits differ from Loke's sets them,
  calls the body, and restores the caller's; the body is a function no caller
  may inline, so none of its arithmetic runs before the switch. That covers
  exports, callbacks reached from a C library, and threads the host created,
  and a host cannot forget it. The generated entries a host calls,
  `loke_rt_v1_program_init` and the thread-local cleanup behind
  `loke_rt_v1_thread_detach`, are guarded the same way. See
  [The floating-point environment is fixed](comments.md#the-floating-point-environment-is-fixed).
- With `-debug`, each call to a foreign procedure, or through a foreign
  procedure value, reads MXCSR when it returns and panics, naming the
  procedure, when Loke's environment changed. A release build does not check.
- `tests/obj/environment_host.c` calls into Loke rounding upward, with
  flush-to-zero, denormals-are-zero, and the invalid-operation exception
  unmasked, from its main thread, through a callback, and from a thread of
  its own; built without the guard, its second call stops on that exception.
  `tests/trap/foreign_float_environment.loke` is the `-debug` check's.

Phase 4's gate is met: the supported functions are listed in
[`core:math/repro`](standard-library.md#coremathrepro), each is checked
against the oracle, and `test-all.ps1 -Full` passes locally and in CI,
the probe at every optimization level and the floating-point cases at every
CPU level.

Phase 5, begun with `sqrt` in both widths, which reproducible distributions
need and `core:math/repro` lacked:

- IEEE 754 requires the square root instruction to be correctly rounded, so
  it already gives the result `core:math/repro` promises, on every x86-64
  level and on the architectures after it. It was kept out only because a C
  library call has no compile-time value. `core:math.sqrt` is now the
  instruction, through a package-private built-in, and the compile-time
  evaluator rounds it exactly in integers: for x = M 2^E, M shifted into
  [2^52, 2^54) with E even, the significand is sqrt(M 2^52) rounded to an
  integer, q = floor of the root rounding up exactly when M 2^52 - q^2 > q,
  never a tie. An `f32` root is the `f64` one narrowed, which rounds
  correctly because 53 is at least twice 24 plus 2 (Figueroa, "When is
  double rounding innocuous?", 1995). `repro.sqrt` adds the canonical NaN.
- It takes 1.5 ns, as the instruction does. A software version from
  `asin`'s root and that integer rounding was correct, agreeing with the
  instruction on every positive `f32` and 200 million seeded `f64`
  patterns, but took 42 ns.
- The evaluator's result is checked against the compiling machine's
  instruction at the arguments whose roots come nearest a midpoint, 1 - 2^-53
  and 1 + 2^-52 and their `f32` counterparts, at subnormals, and at 20,000
  seeded patterns in each width; the probe checks those arguments folded and
  at run time, and 2,000 more against the oracle, which takes an exact
  integer square root.
- `pair_root`, behind `hypot`, `asin`, and `acos`, and their `f32` first
  approximations still started from the bit-pattern estimate and Newton's
  steps; they start from the instruction now, as the last part of this
  section describes.

Then `core:random`'s distributions, switched in place rather than given a
second, reproducible set beside them, as
[Lockstep integration and versioning](#lockstep-integration-and-versioning)
proposed:

- Every `exp`, `log`, `pow`, and `sqrt` they call is `core:math/repro`'s, so a
  seeded generator's values are the same on every machine and CPU level, and
  the distributions run at compile time, which needed `math.floor`, `ceil`,
  `trunc`, and `round` to become instructions with compile-time values, as
  `sqrt` had. The algorithms and draw orders are unchanged. Two of the 1,028
  ziggurat table entries, `NORMAL_F[94]` and `EXPONENTIAL_F[87]`, were the
  UCRT's recomputation and an ulp from the correctly rounded one; they are
  now `core:math/repro`'s, and the other entries already were.
- Few values change. The UCRT's `exp` differs from the correctly rounded one
  on about one `log_normal` value in 200 and its `log` on about one `unit`
  argument in 700, and 2 million seeded draws of each distribution kept
  their bits but for `log_normal` and `gamma` below shape 1. Keeping the old
  sequences would have kept them only on machines whose C library takes the
  same path, at the price of listing every distribution twice.
- The cost lands where a value calls those functions. Measured on
  2026-10-29 at `-opt=speed` over 2 million draws, against the UCRT's
  functions: `normal` and `exponential` stay at about 7 and 4 ns, `gamma` of
  shape 3 goes from 17 to 23 ns and of shape 0.5 from 40 to 112, `student_t`
  from 29 to 34, `poisson` from 24 to 53 at a mean of 4 and from 29 to 66 at
  100, `binomial` from 56 to 119 by inversion and from 59 to 70 by BTPE,
  `geometric` from 13 to 69, and `beta` from 35 to 46 by gammas and from 13
  to 205 by Jöhnk's method, which calls `pow` twice per attempt. Faster
  `core:math/repro` kernels, phase 6's work, would recover it for every
  caller.

Then the composite operations: the audit found the magnitudes of
`math.Complex` and `math.Quaternion` the only callers of a nondeterministic
function outside `core:math`'s own procedures; nothing else in the bundled
packages calls one. `core:math` cannot call `core:math/repro`, which imports
it, and `repro.hypot` takes 30 ns to the UCRT's 4.4, so `abs` keeps the C
library, and `core:math/repro` adds the entry points the plan asks for:

- `complex_abs` is `hypot` of the two parts. `quaternion_abs` is sqrt(real^2
  + i^2 + j^2 + k^2) rounded once, where `q.abs()` nests `hypot` and rounds
  three times. Its fast path sums the four exact squares as a pair within
  2^-98.4 and takes `pair_root`, deciding at 2^-97; its slow path is
  `hypot`'s fixed-point root.
- `hypot`'s proof does not carry over. With two components, one far below
  the other leaves the root a float's distance from any midpoint; with four,
  the near one's square can be finer than any fixed point holds and still
  decide a near tie. So a root within 2^-300 of a midpoint is settled by
  comparing the sum of squares with the midpoint's square exactly, in
  integers over the whole span, about 4,200 bits. `quaternion_abs_f32` of
  13013847, 13025704, 0, and the smallest subnormal rounds up to 18412746,
  where without the fourth component the midpoint rounds to even.
- The oracle's `hypot` became `oracle_norm`, of any number of components,
  and the probe checks 2,707 more results against it, Euler's four-square
  identity giving exact midpoints, and fast and slow paths agree over 20,000
  seeded arguments in each width. Measured at `-opt=speed`, `quaternion_abs`
  takes 48 ns and `quaternion_abs_f32` 37 ns, against 11 ns for `q.abs()`'s
  three UCRT `hypot` calls.

Then the replay example and version metadata, which complete phase 5:

- `repro.RESULTS_VERSION` and `random.SEQUENCE_VERSION`, both 1, change with
  any result of their package, a distribution's through `core:math/repro`
  included, as [Version policy](releasing.md#version-policy) now requires. A
  recording carries them with `LOKE_VERSION` and the simulation's own
  version. A build-configuration field is not needed: no CPU or optimization
  level changes a value, which is what this plan's earlier phases made true.
- [examples/lockstep.loke](examples/lockstep.loke) steps twelve bodies at
  60 Hz from a seed and an input log, with `core:math/repro`'s `sin`, `cos`,
  `atan2`, `hypot`, and a folded `exp`, and `core:random`'s `uniform`,
  `normal`, `exponential`, and `in_range`, and prints a hash of a canonical
  serialization, the generator's state included, each simulated second. A
  second run from the seed and a run resumed from a snapshot at tick 300
  reach the same final hash, and a recording with another random sequence
  version is refused.
- Phase 5's gate is met: the examples test pins its output, the CPU level
  test requires the same at `x86-64-v2` and `x86-64-v3`, and
  `test-all.ps1 -Full` reruns both at every optimization level.

Then phase 6's first kernel change, one of two that a performance review's
experiments on 2026-10-29 found would pay:

- `pair_root` starts from the square root instruction, correctly rounded,
  instead of a bit-pattern estimate and four Newton steps, and keeps its
  residual correction, which then leaves the pair within 2^-103.3 of the
  root rather than 2^-101; every bound derived from the old figure still
  holds. The `f32` first approximations of `asin`, `acos`, `hypot`, and
  `quaternion_abs` take the instruction's root too, within 1 or 2 ulps where
  5 or 6 were, and 2 of `asin_f32`'s 2^18.5, under the margins they keep.
  The bit-pattern estimate is gone.
- No result changed: the probe's 37,956 oracle-checked results and its
  fast-against-slow comparisons are bit for bit the same, and so is every
  `f32` argument of `asin_f32` and `acos_f32` in (-1, 1), compared
  exhaustively with the previous version.
- Measured at `-opt=speed` with
  [`bench/math_compare`](bench/math_compare/README.md), medians per call:
  `asin` from 67.2 to 53.1 ns, `acos` from 69.6 to 56.5, `hypot` from 29.3 to
  20.0, and `asin_f32` from 42.3 to 31.9; `quaternion_abs` from 48 to 36 ns
  and `quaternion_abs_f32` from 37 to 24. The others did not move.

Then the other, `two_product` by the FMA instruction:

- `math.fma_is_instruction()`, public and then constant, tells `core:math/repro`,
  and any other algorithm, whether `math.fma` is the instruction; a
  `core:math/repro`-private built-in would not have reached the probe's copy
  of the package. Where it is, `two_product`'s error is `fma(a, b, -p)`, and
  elsewhere still Dekker's, never `math.fma`'s slower integer arithmetic.
- The two agree bit for bit wherever both are exact, which for Dekker's needs
  operands under 2^995 and a product of 0 or at least 2^-916, and the fused
  one needs less; an exact zero error is +0 both ways. The audit of every
  call, recorded in `arith.loke`'s head, finds each fast path's values 0 or
  above about 2^-300 and its operands under 2^64, `norm`'s smallest square at
  2^-916 included. So every intermediate value is the same at every CPU
  level, not only the results, which are correctly rounded either way.
- `tests/repro_test.odin` builds the probe at `x86-64-v3` too and requires its
  output to be baseline's, folded constants included. A copy of the package
  whose `two_product` computed both errors and panicked on any difference
  passed the probe, every 61st `f32` pattern through the ten unary functions
  (70 million arguments each), and 4 million seeded `f64` and `f32` bit
  patterns of every exponent through all of them, `pow`, `atan2`, `hypot`,
  and `quaternion_abs` included; the same check with the fused error halved
  panicked at once.
- Measured at `-opt=speed` and `-cpu=x86-64-v3` with
  `bench/math_compare`, medians per call, Dekker's then fused: `exp` 19.4
  and 18.0 ns, `log` 22.0 and 17.3, `log2` 32.6 and 23.4, `sin` 41.2 and 36.9,
  `tan` 56.4 and 48.3, `asin` 56.4 and 40.2, `acos` 58.5 and 41.9, `atan2`
  38.7 and 32.9, `pow` 72.4 and 57.5, `hypot` 19.5 and 13.4, and `pow_f32`
  87.8 and 75.7; `sin_f32` and `asin_f32`, decided by their single-`f64`
  paths, did not move. Baseline builds are unchanged.

Then the `f32` functions' rounding decision and first approximations:

- `f32_decided`, which every `f32` result passes through, joined two
  comparisons with `||`; the second's overflow check made it a branch,
  taken for about half of random arguments and mispredicted as often. One
  wrapping comparison decides the same, as 200 million seeded values at
  every window the package uses confirmed, and took 6 to 8 ns off each
  `f32` function.
- `sin_f32`, `cos_f32`, and `tan_f32` had no first approximation, and went
  straight to the double-`f64` kernel, so `sin_f32` took longer than `sin`.
  Below 2^20 pi/2 they now take a single-`f64` one: Cody and Waite's
  reduction with three parts and the table's high parts with short series,
  sin and cos chosen by coefficients and the sign set by a mask rather than
  by branches the quadrant would mispredict. An exhaustive pass over all
  281,612,248 such arguments, both signs, found it within 3, 1.7, and 4.5
  ulps of the double-`f64` result, and every result equal to the previous
  path's at the window of 16 ulps.
- Measured at `-opt=speed` with `bench/math_compare` at baseline,
  medians per call before and after: `sin_f32` 61.3 and 26.6 ns, `exp_f32`
  20.1 and 13.6, `asin_f32` 33.8 and 24.5, and `pow_f32` 92.2 and 81.7; a
  separate loop measured `cos_f32` from 56 to 25 ns and `tan_f32` from 88
  to 30. The `f64` functions did not change.
- Found on the way: an array literal whose element type is spelled as a
  procedure type reported a compiler defect, `L0350`, besides its parse
  error; it now reports the parse error alone
  (`tests/err/proc_literal_array_type.loke`).

Then `pow_f32`, the last `f32` function without a first approximation:

- z = y log x from `log_f32`'s single-`f64` logarithm, and e^z from
  `exp_f32`'s single-`f64` exponential, for |z| under 88, so that the result
  is normal; its error is under 2^10.2 `f64` ulps, and it decides at 2^11.
  An exact midpoint never decides there, so `pow_slow`'s exact test still
  settles every one.
- Every positive finite `f32` x against y = 2, 1/2, 1/3, and -3/2, 2.1
  billion pairs each, and 341 million seeded pairs, random patterns, bases
  near 1 with large exponents, and small integer exponents among them, gave
  the previous path's result every time; the largest error found was 208
  ulps.
- Measured at `-opt=speed` with `bench/math_compare` at baseline:
  `pow_f32` from 83.3 to 35.4 ns per call.

Two `f64` experiments on 2026-10-30 did not pay, and changed nothing:

- `log2` and `log10` take about 13 ns more than `log`: 9 in the kernel,
  Dekker's product of `log`'s result with the constant, and the rest in the
  decision. Specializing to the constant, so that its split folds, saved 1.3
  ns; a table of -log2 d would only move the product onto the series. At
  `x86-64-v3` the fused product already takes most of it.
- `sin`, `cos`, and `tan` choose `sin_kernel` or `cos_kernel` by the
  quadrant, a branch random arguments mispredict, but one kernel with its
  coefficients chosen, as the `f32` first approximation does, took 43.2 ns
  against 42.8: the double-`f64` kernels' cost is their arithmetic.

The remaining `f64` gap needs other algorithms, each with a new bound.

The plan's exhaustive `f32` gate: `F32_FIRST_APPROXIMATION`, true in the
package, lets `tests/repro_test.odin` build a copy without the first
approximations, and `tests/repro/exhaustive.loke` runs every `f32` bit
pattern through both: the ten unary functions, `pow_f32` at y = 2, 1/2, 1/3,
and -3/2, `hypot_f32` against 0.75, and `quaternion_abs_f32` against three
fixed components, a hash per 2^24 results naming any block that differs.
`test-all.ps1 -Exhaustive` runs it, in about 25 minutes on six cores; CI does not, and
the release checklist does.

`math.mod`, the last exact `core:math` procedure without a compile-time
value, is now LLVM's `frem` through a package-private built-in, which still
calls the C library's `fmod` at run time, and the evaluator computes the
remainder exactly in integers; it agreed with `fmod` on 3 million seeded
pairs of every exponent. A remainder written in Loke was exact too, agreeing
on 400 million pairs, but took 22 ns to `fmod`'s 4 when wrapping an angle.

Phase 6's dispatch, on 2026-10-30: a baseline executable runs
`core:math/repro`'s `f64` functions with the FMA instruction on a processor
with `x86-64-v3`.

- [`@(cpu_dispatch="x86-64-v3")`](design.md#cpu_dispatchstring) marks a
  procedure that a build for a lower level also emits for the named one, with
  every procedure its copy calls directly, so the copy needs no inlining from
  the build's level and nothing of the level's runs outside it. Its own name
  becomes a dispatcher at the build's level that asks the runtime's
  `loke_rt_v1_cpu_dispatch`, once per process, through a cached byte. This is
  the plan's "isolated from cross-target inlining": LLVM never inlines a
  function into one lacking its features. No fat binary, and no general
  per-procedure target attribute: the copy's features are a CPU level's.
- `math.fma_is_instruction()` is no longer a constant, since the copies
  answer differently; `math.fma` and `two_product` test it in an `if`. At
  compile time it answers for the build's level.
- `LOKE_DISPATCH_CPU` caps the copies that run, which is how
  `tests/repro_test.odin` and `tests/cpu_test.odin` run the fallback on a
  processor with the level and require the same output.
- The validation gates' assembly check: `tests/cpu_test.odin` disassembles
  an object build of `tests/obj/dispatch_kernels.loke` with the
  `llvm-objdump` beside Clang. At baseline no function but a `.v3` copy holds
  a VEX instruction or any SSE3-and-later, POPCNT, LZCNT, BMI, or MOVBE
  instruction, and the copies hold FMA; at both levels a written `a*b + c` is
  not fused. Adding `contract` to that IR by hand makes it `vfmadd213sd`,
  which the check reports. Real non-FMA hardware, or an emulator such as
  Intel SDE, remains untested.
- Measured at `-opt=speed` with calls the optimizer cannot inline, in ns per
  call for the plain copies, the dispatched ones, and a `x86-64-v3` build:
  `log` 26.2, 20.5, 18.0; `tan` 55.6, 43.6, 42.2; `hypot` 21.7, 17.8, 14.5;
  `atan2` 38.6, 35.1, 32.6. Over a direct loop, `pow` 74.3, 58.7, 57.6,
  `asin` 50.3, 39.0, 37.0, and `log2` 34.7, 20.7, 19.8. The rest of the gap to
  the `x86-64-v3` build is the dispatcher's call and the inlining a whole
  build allows. The `_f32` functions measured no faster in their copies and
  are not marked.

Phase 1's benchmark is [`bench/math_compare`](bench/math_compare/README.md),
which times every `core:math/repro` function against the UCRT's with seeded,
ordered, and dependent arguments, on either UCRT path and with dispatch
capped. Measured again on 2026-10-30 after the changes above, the dispatched
`f64` functions but `sqrt` take 1.9 to 4.7 times the UCRT's time, where they
took 2.1 to 8.7, and the measured `f32` ones 2.3 to 3.7, where they took 4.6
to 9.4; every checksum is the earlier run's.

Not started: phase 6's faster `f64` kernels, which need other algorithms,
the worst-case latency and simulation frame-time measurements its gate
asks for, and other platforms.

## Recommended direction

Separate three choices: the machine instructions a program may use, the
numerical contract of a math function, and optimization effort. A faster CPU
target must not silently relax the numerical contract. A multiplayer game
should be able to use deterministic math in its simulation and platform math
in its renderer within the same executable.

1. Preserve separate rounding of ordinary arithmetic at every optimization
   level. Keep fused multiply-add explicit through `math.fma`.
2. Keep baseline x86-64 as the distribution default. Add explicit CPU levels,
   starting with baseline, v2, and v3. An FMA-capable target accelerates an
   explicit FMA; it does not turn `a*b + c` into one.
3. Add a portable, correctly rounded math package. This serves both users who
   need reproducibility and users who need the most accurate result in the
   chosen floating-point format.
4. Keep platform math available. Add a separately named deterministic
   approximation package only where measurements justify its maintenance.
5. Share portable math implementations across Windows, Linux, macOS, ARM64,
   and WebAssembly. Certify each target before promising reproducibility on it.

Determinism and accuracy are independent properties. A fixed approximation
can be deterministic without being correctly rounded; a good platform library
can be accurate without producing identical bits everywhere. Correct rounding
provides both for ordinary numerical results, but exceptional values and the
execution environment still need explicit rules.

## Starting point

Loke already forbids implicit contraction and reassociation. Its
[`core:math` interface](core/math/api.loki) provides a correctly rounded software
`fma`, but the listed transcendental functions and `hypot` use the C library.
The [existing investigation](open-questions.md#deterministic-math-functions)
records differences between UCRT CPU paths and between runtime calls and
optimizer-folded calls. Microsoft also documents that its FMA3 math paths use
different algorithms and can return different results. Disabling UCRT FMA3
would address only one Windows-specific source of differences, not portability
or compiler folding. See [Microsoft's FMA3 control documentation](https://learn.microsoft.com/en-us/cpp/c-runtime-library/reference/get-fma3-enable-set-fma3-enable?view=msvc-170).

The driver currently passes no CPU level to Clang. Target metadata exists in
`src/semantic.odin`, while build constants in `src/build_config.odin` are fixed
to Windows x64. Object emission, runtime compilation, and linking have separate
command construction in `src/emit_llvm_toolchain.odin`; all must agree on the
selected target. This work should extend the planned
[target boundary](future-plans.md#more-platforms), rather than add an unrelated
x64-only configuration mechanism.

The [random distributions](standard-library.md#distributions)
also depended on these functions. Changing a result can change rejection sampling
and every subsequent draw. Fixing scalar math is therefore necessary but not
sufficient to promise stable distribution sequences or lockstep simulation.

## Numerical APIs and compatibility

Use explicit package imports, with the following proposed contracts. Package
names below are proposals; existing `f64` names and `_f32` suffixes should stay
consistent with the current interface.

| API | Result contract | Intended use |
| --- | --- | --- |
| `core:math` initially | Existing platform-dependent transcendental results | Compatibility and general applications that accept platform variation |
| `core:math/repro` | Correctly rounded `f32`/`f64` results, fixed special cases, identical bits across certified implementations | Lockstep simulation, reproducible generation, and accuracy-sensitive computation |
| `core:math/fast`, if justified | Versioned, bit-identical approximations with a documented domain and error bound per function | Simulation hot paths where reduced accuracy buys measured performance |

Do not add a global switch that silently redirects every dependency's math
calls. A library should state its numerical dependency in source, and both
contracts should coexist in one program. Optimization level controls effort,
not which package contract applies.

Initially retain the current default to avoid changing existing numerical
results while the portable implementation is incomplete. Once full coverage
and measurements exist, make an explicit release decision about promoting
reproducible implementations into `core:math`. The preferred long-term default
is correctly rounded math if its cost is acceptable for representative general
purpose workloads. If promoted, retain `core:math/repro` as a compatible entry
point and expose old platform behavior through `core:math/system`; do not
maintain two independent correctly rounded implementations.

Correct rounding means the best representable result at that width, not more
precision than `f32` or `f64`, nor an accurate solution to an ill-conditioned
problem. Arbitrary precision and directed-rounding/interval APIs are separate
future work. Do not make users change the process rounding mode to obtain
accuracy from the reproducible package.

### Reproducible result contract

Specify this before implementing or porting functions:

- Inputs and outputs are IEEE binary32 or binary64. For finite mathematical
  results, round once to the output format using nearest, ties to even.
  Underflow uses gradual underflow; overflow and signed zero follow explicit
  per-function rules. An `f64` implementation narrowed to `f32` is not generally
  a correctly rounded `f32` implementation because of double rounding.
- Define all domain, pole, infinity, zero, and NaN cases. In particular, give
  `pow` and `atan2` complete special-case tables. Mathematical correct rounding
  alone does not settle them. Exceptions such as a NaN argument paired with an
  identity case must follow those tables, not a blanket early NaN return.
- When a reproducible function's result is NaN, return a positive canonical
  quiet NaN: `0x7fc00000` for `f32`, `0x7ff8000000000000` for `f64`.
  Specify signaling NaN inputs and canonicalize the result consistently.
- Do not promise portable `errno`, exception flags, or traps. The portable
  contract uses non-trapping arithmetic. Loke has no facility for changing the
  rounding mode, flush-to-zero, or exception masks, and this contract adds none.
- Publish an explicit list of certified functions and target combinations.
  An unimplemented function must not silently fall back to system `libm`.
- For the same inputs and contract version, CPU level, compiler host,
  optimization level, and compile-time versus runtime evaluation must not
  change the output bits on certified targets.

### Special cases

These tables complete the contract for the first functions and for the two
whose special cases are the hardest. Every entry not listed is the correctly
rounded mathematical result, including overflow to infinity and gradual
underflow to a subnormal or a zero of the result's sign. They follow the IEC
60559 annex of C17 (F.10), except that every NaN result is the canonical one,
whatever NaN produced it and whether or not it was signaling. `π`, `π/2`,
`π/4`, and `3π/4` mean the correctly rounded constants of the result's width.
`tests/math_oracle.odin` implements all of them.

| Function | Argument | Result |
| --- | --- | --- |
| `exp` | NaN | NaN |
| | +∞ | +∞ |
| | −∞ | +0 |
| | ±0 | 1, exactly |
| `log` | NaN, or any x < 0 including −∞ | NaN |
| | ±0 | −∞ |
| | 1 | +0 |
| | +∞ | +∞ |
| `sin` | NaN, ±∞ | NaN |
| | ±0 | ±0 |
| `cos` | NaN, ±∞ | NaN |
| | ±0 | 1, exactly |

For finite nonzero arguments these functions have no exact or midpoint results
(Lindemann–Weierstrass), so correct rounding needs no further rules, and
`sin(-x)` is `-sin(x)` bit for bit.

`pow(x, y)`, in the order the rules apply:

| Arguments | Result |
| --- | --- |
| y is ±0, any x, NaN included | 1 |
| x is +1, any y, NaN included | 1 |
| x or y is NaN | NaN |
| x is ±0, y an odd integer < 0 | ±∞, the sign of x |
| x is ±0, y < 0 otherwise, −∞ included | +∞ |
| x is ±0, y an odd integer > 0 | ±0, the sign of x |
| x is ±0, y > 0 otherwise, +∞ included | +0 |
| x is −1, y is ±∞ | 1 |
| \|x\| < 1, y is −∞; \|x\| > 1, y is +∞ | +∞ |
| \|x\| < 1, y is +∞; \|x\| > 1, y is −∞ | +0 |
| x is −∞, y an odd integer < 0 | −0 |
| x is −∞, y < 0 otherwise | +0 |
| x is −∞, y an odd integer > 0 | −∞ |
| x is −∞, y > 0 otherwise | +∞ |
| x is +∞ | +0 for y < 0, +∞ for y > 0 |
| x finite < 0, y finite and not an integer | NaN |
| x finite < 0, y an integer | ±\|x\|^y, negative when y is odd |

Unlike the others, `pow` has exact and midpoint results at finite arguments,
such as `pow(4, 0.5)` and `pow(2, -1075)`. Correct rounding still decides
them, ties to even, so `pow(2, -1075)` is +0; an implementation must detect
them rather than rely on the search for a rounding to end.

`atan2(y, x)`:

| Arguments | Result |
| --- | --- |
| y or x is NaN | NaN |
| y is ±0, x is −0 or x < 0 | ±π |
| y is ±0, x is +0 or x > 0 | ±0 |
| y < 0 finite, x is ±0 | −π/2 |
| y > 0 finite, x is ±0 | π/2 |
| y finite, ±, x is −∞ | ±π |
| y finite, ±, x is +∞ | ±0 |
| y is ±∞, x finite | ±π/2 |
| y is ±∞, x is −∞ | ±3π/4 |
| y is ±∞, x is +∞ | ±π/4 |

Canonicalizing library outputs does not canonicalize every arithmetic NaN in
a program. Initially define the lockstep recipe around finite simulation
state, checking for non-finite results at suitable simulation boundaries.
Programs that intentionally use NaNs must canonicalize before any payload/sign
inspection or other representation-dependent decision, as well as before
serialization. A whole-program NaN canonicalization mode would be separate
compiler work, not an implied property of importing this package. Preserve the
documented bit behavior of `abs`, `copy_sign`, and bit reinterpretation.

### Faster deterministic approximations

First benchmark correctly rounded functions in a real simulation. If that
cost is material, prototype a small `core:math/fast` surface, beginning with
`sin`/`cos` and `exp`/`log` as workloads require. Do not copy the entire math
package speculatively.

Freeze coefficients, range reduction, evaluation order, exceptional cases,
and use of fused versus unfused operations. State the supported input domain
and a verified ULP or absolute/relative error bound, using absolute error
where relative error is meaningless near zero. A range-limited API must have
explicit behavior outside its range. There is no universal accuracy bound
to choose before evaluating an algorithm.

For each frozen approximation, either use explicit FMA on every target,
including software emulation, or use unfused arithmetic on every target.
Do not dispatch to different polynomial evaluations merely because each is
within the error bound: both must produce the same bits. Different evaluation
schemes can share a contract only after their equivalence is established.
Avoid slow-path iteration where predictable frame-time cost matters; measure
worst observed latency as well as throughput.

Approximation revisions can change replay results. Give their numerical
contract a version and treat changed output bits as a compatibility change.
Platform math is an additional performance choice, but must not be presented
as guaranteed faster or suitable for lockstep without evidence.

## CPU targets and FMA

### User-facing selection

Propose a `-cpu=<level>` option, independent of the existing `-opt=<mode>`.
Do not add a public `-target` option while Windows x64 is the only target: an
option that accepts one value would commit to triple spelling and
normalization before a second target forces those decisions. Add it with the
first additional target, as part of the
[target boundary](future-plans.md#more-platforms); recognizing a triple must
not imply support for its ABI or runtime. The internal target description
below is needed now.

| Proposed CPU value | Instruction-set policy | Rollout |
| --- | --- | --- |
| `x86-64` | Baseline x64, including SSE2; no FMA requirement | Default |
| `x86-64-v2` | Complete standard v2 feature set; no FMA requirement | First release |
| `x86-64-v3` | Complete standard v3 feature set, including AVX2 and FMA | First release |
| `x86-64-v4` | Complete standard v4 feature set, including its AVX-512 subset | Later, with hardware coverage and benchmarks |
| `native` | Resolve this build host's usable features explicitly | Later convenience option; unsuitable as a portable release default |

Use established level definitions, not a hand-picked approximation such as
"v3 means AVX2." These levels describe cumulative instruction sets rather than
CPU vendors or operating systems. Toolchains can apply the same level feature
sets outside the System V ABI; see [GCC's x86 target documentation](https://gcc.gnu.org/onlinedocs/gcc/x86-Options.html).

Keep baseline support unless a separate compatibility decision changes it.
FMA is a capability, not a synonym for x64 or a numerical mode. Internally use
an architecture-neutral target description containing architecture, OS/ABI,
layout, required features, and tuning. Reject invalid CPU/target combinations.
Defer public arbitrary feature overrides and per-procedure target attributes
until there is a concrete need. Keep tuning separate from required features.

### Code generation and startup

Thread the resolved target through IR generation, Clang invocations, runtime
objects, assembly handling, linking, toolchain reporting, session identity,
and cache keys. Include compiler/toolchain identity, optimization policy,
numerical contract version, and the resolved `native` features where relevant.
Never reuse a v3 runtime object for a baseline build. Emit object metadata
describing requirements so external hosts can enforce the same contract.

For an executable requiring more than baseline, compile the startup feature
check as a separate baseline unit. It must run before specialized Loke code,
global initialization, or library constructors that require those features.
Check the entire required feature set; AVX-family support also requires the
OS to enable the relevant extended register state. Keep the check outside
cross-target inlining/LTO. If toolchain startup runs specialized code first,
use a baseline launcher instead of claiming the later check is sufficient.
Report an unsupported CPU clearly. Object/library builds document the host's
obligation to check before calling them.

Keep ordinary LLVM operations free of contraction, reassociation, approximate
function, and other value-changing fast-math permissions. The emitted IR
carries no fast-math flags, but IR flags are not the only control: Clang's
`-ffp-contract` also sets the backend's fusion mode for `.ll` input, and under
`fast` the backend can fuse a plain `fmul` and `fadd`. Neither Clang command
passes the option today. Object emission compiles the module with only an
`-O` flag, and the runtime compile gets Clang's C default, `-ffp-contract=on`,
which fuses `a*b + c` within an expression. That is harmless at baseline,
which has no FMA instruction, but not once a CPU level with FMA reaches the
runtime compile. Pass `-ffp-contract=off` on every Clang command rather than
assume the default, "precise", or `-fno-fast-math` disables contraction, and
inspect the generated IR and machine code at each CPU level.
[Clang documents these distinct controls](https://clang.llvm.org/docs/UsersManual.html#controlling-floating-point-behavior).

Lower explicit `math.fma` to hardware only when the selected target supports
the required semantics. Keep the existing software implementation available
on baseline x64 and other targets. Hardware and software must agree after the
reproducible API's special-value normalization. LLVM's `llvm.fma` specifies
single-rounding fused arithmetic, but its transcendental intrinsics are not a
portable correctly rounded math library. Do not use them as replacements for
the reproducible implementation. See [LLVM's intrinsic contracts](https://llvm.org/docs/LangRef.html#llvm-fma-intrinsic).

A software FMA is not `a*b + c`, nor generally a widened operation rounded
back down. Preserve exact-product information through cancellation, overflow,
and subnormal cases. Similarly, replacing an algorithm's FMA with a two-part
product requires a correctness argument for that algorithm and its full range.

Later, a baseline executable may dispatch selected math kernels to FMA-capable
implementations after a single feature check. Start with whole-program CPU
selection because it is simpler to validate. Add dispatch only where measured
benefit exceeds call/branch overhead, and require identical outputs on every
path. Compile the resolver and fallback for baseline and isolate specialized
kernels from cross-target inlining. Test forced fallback and accelerated paths.

## Portable implementation and compile-time evaluation

Prototype from [CORE-MATH](https://core-math.gitlabpages.inria.fr/), pinning an
upstream revision and recording each function's license, dependencies, and
validation evidence. It is a source of algorithms, not a drop-in assurance for
every port: its project notes distinguish regular-number rounding from special
cases and describe different validation coverage by format/function. Preserve
notices and independently verify Loke's wrappers and port.

Use the upstream C implementation as a prototype/reference when useful, then
prefer Loke implementations that can share code with compile-time evaluation.
Audit assumptions about FMA, wider integers, byte order, compiler extensions,
and floating-point environment. Loke's integer `+`, `-`, and `*` panic on
overflow at every optimization level ([Integer overflow](design.md#integer-overflow)),
and built-in indexing is always bounds-checked. Upstream kernels rely on
modular 64- and 128-bit arithmetic and table lookups: write each intentional
wrap with `+%`, `-%`, or `*%`, since a missed one panics only on rare inputs
that hard-case and exhaustive tests reach. The slowdown estimates in open
questions do not include the remaining checks; measure them.

Do not make compiler bootstrap depend on running target binaries. Start with `exp` in both widths to measure FMA versus
software cost; include `sin` early because large-argument range reduction tests
a different risk. Add `log`, `cos`, and `pow`, then the remaining currently
nonreproducible functions, including `hypot` and inverse trigonometric functions.

Control constant evaluation explicitly:

1. Give reproducible runtime functions Loke-owned symbols; avoid recognizable
   `sin`/`pow` libc names and builtin substitutions that can use host `libm`.
   Test after optimization and LTO, including vector-library substitutions.
2. Where a foreign wrapper is used during prototyping, apply and test the
   appropriate LLVM `nobuiltin` protection. A compiler flag for C source alone
   does not prove that calls in emitted LLVM IR are protected.
3. Execute typed compile-time arithmetic with target-format rounding after
   each operation and explicit FMA semantics. Audit `src/const_ops.odin` and
   the evaluator; do not inherit the compiler host's rounding or subnormal
   state. Keep unfixed literal arithmetic distinct from typed runtime values,
   as required by [Number literals](design.md#number-literals).
4. Evaluate reproducible functions through the same implementation or a
   separately verified evaluator with identical special cases. Until this is
   supported, reject such a compile-time call rather than use host math.
5. Compare compile-time results, optimizer-folded results, and calls fed from
   runtime inputs across every supported optimization level.

## Execution environment and future platforms

Define the reproducible execution environment as nearest-even rounding,
gradual underflow for inputs and outputs, and masked floating exceptions.
Loke code cannot change this state: no library procedure sets the rounding
mode, flush-to-zero, or exception masks, so a Loke program runs in whatever
state the OS and C runtime establish. Only foreign code can change it: a C
library Loke calls, a C host calling into a Loke library, or a module loaded
into the process. Scope the work to those boundaries:

- Record, by test, the state each supported OS gives a new process and a new
  thread, rather than assume either. Add setup at executable entry or thread
  start only where that state differs from the contract.
- Provide a scoped entry mechanism for C hosts that establishes and restores
  the state around calls into Loke, including from foreign-created threads.
  A Loke library cannot otherwise rely on its caller's state.
- A foreign call that changes the state must restore it before Loke arithmetic
  resumes; validate that boundary in debug builds.

For x64, account for MXCSR rounding, FTZ, and DAZ. For ARM64, account for FPCR
and the chosen instruction semantics. LLVM environment attributes describe
assumptions; they do not initialize hardware state. The first implementation
milestone must turn these assumptions into a documented contract and tests.
A library that later adds environment control must define how it interacts
with this contract.

| Future target | Required adaptation before certification |
| --- | --- |
| Linux x64 | System V ABI, ELF/toolchain/runtime support, environment setup, and the same portable kernels rather than a dependency on glibc math results |
| macOS x64/ARM64 | Darwin ABI/toolchain/runtime support; test each architecture separately and avoid Apple libm dependence for reproducible calls |
| ARM64 Windows/Linux | AArch64 ABI and FP environment; explicit hardware FMA and scalar/SIMD conformance against the reference |
| WebAssembly | Separate architecture/runtime target (for example WASI versus browser host), explicit wasm32 layout, bundled math kernels, and software FMA where the target lacks an exact operation |

Use ordinary deterministic Wasm operations for the portable path. Do not
replace explicit FMA with relaxed SIMD multiply-add, or assume arithmetic NaN
bits are universally fixed by the engine. Baseline Wasm behavior permits NaN
variation and relaxed SIMD adds numerical choices; validate any newer
deterministic profile separately before relying on it. See the
[WebAssembly nondeterminism documentation](https://github.com/WebAssembly/design/blob/main/Nondeterminism.md).

Initially scope ARM support to ARM64. Treat 32-bit ARM as a separate target with
its own ABI and floating-point capability requirements. Neither an LLVM target
backend nor successful cross-linking proves Loke runtime support. Cross-target
tests compare numerical results, not raw object layout, pointer sizes, or
native `int` serialization.

## Lockstep integration and versioning

Publish a simulation recipe alongside the math API:

- Fix the timestep and input order. Keep clocks, entropy, address ordering,
  unspecified map traversal, and scheduling-dependent reductions out of state
  updates. Deterministic math does not make data races reproducible. The
  [existing audit](nondeterminism-audit.md#intentionally-unspecified-or-nonreproducible-results)
  identifies these other sources.
- Use fixed-width state and canonical serialization with explicit byte order.
  Hash fields rather than struct padding or pointers. Preserve or normalize
  signed zeros by an explicit protocol rule; do not assume they are equivalent
  for later arithmetic just because `==` treats them as equal.
- Keep SIMD accumulation order fixed. Existing extrema reductions can choose
  between equal signed-zero lanes: use a specified tie rule or a deterministic
  alternative in simulation code. Wider vectors cannot silently change these
  choices or reduction grouping.
- Add explicit reproducible distribution APIs using the portable math path.
  Pin generator, seed mapping, distribution algorithm, draw order, and
  rejection rules. Preserve existing distribution sequences during migration;
  a math import change alone does not version the whole distribution algorithm.
- Audit complex/quaternion magnitudes and any other transitive math users.
  Provide explicit reproducible entry points rather than leave a hidden system
  `hypot` call under an apparently deterministic top-level operation.
- Include simulation version, numerical contract version, random algorithm
  version, and relevant build configuration in replays and peer handshakes.
  Pin compiler/library releases for shipped matches. Permit different certified
  CPU levels within one session; CPU equality is not the compatibility rule.

Correct rounding gives a mathematical compatibility target, but a bug fix can
still change previously shipped results. Record such changes, provide upgrade
notes, and require a replay/network version transition. Do not advertise
unlimited replay compatibility across compiler updates merely because the
intended contract was unchanged.

## Validation and performance gates

Build a shared numerical corpus and an independent oracle. Use
[MPFR](https://www.mpfr.org/mpfr-current/mpfr.html) in the test tooling with
correct target-format exponent/subnormal handling, or rigorously bounded
high-precision intervals that prove the final rounding. A fixed arbitrary
precision followed by a cast can itself double-round; ordinary host `libm`
is not a correctness oracle.

| Check | Required evidence |
| --- | --- |
| Special cases | Signed zeros, infinities, both NaN classes, poles, domains, subnormals, and overflow/underflow boundaries match the specified bit patterns |
| Hard rounding | Known difficult inputs, range-reduction boundaries, cancellation, and FMA edge cases agree with the oracle |
| Width coverage | Exhaustive unary `f32` sweeps where practical as a dedicated long-running gate; targeted and randomized `f64`/multi-input cases plus algorithmic correctness evidence |
| Compiler behavior | All five optimization modes, constant/runtime inputs, and available LTO configurations agree; assembly confirms no implicit FMA and no forbidden instructions on fallback paths |
| CPU paths | Baseline/v2/v3 and software/hardware FMA agree bitwise; test actual non-FMA hardware or faithful emulation in addition to forced software paths |
| Runtime state | New threads, foreign entry/reentry, altered rounding, and FTZ/DAZ state are handled according to the entry contract |
| Future platforms | Execute the same corpus on each supported OS/architecture; for Wasm use multiple independent engines |
| Application | Multi-tick simulation state hashes and reproducible distribution outputs agree across builds and machines |

A finite corpus is regression evidence, not a proof of correct rounding for
all `f64` inputs. Retain upstream proofs or error analyses where available and
review changes to coefficients, range reduction, fallback logic, and compiler
assumptions. Test-only feature forcing must never execute unsupported hardware
instructions.

Measure before and after using the repository's
[performance workflow](compiler-architecture.md#testing-and-verification),
extended with numerical workloads. Report dependent-call latency, independent
throughput, batches/SIMD, worst observed hard-case latency, software-FMA cost,
overflow- and bounds-check cost in ported kernels, binary size, compile time, and simulation frame time. Cover ordinary and
adversarial input distributions on at least baseline-capable and v3 hardware.
Record CPU, OS, toolchain, source revision, and options. Existing estimates in
open questions are hypotheses, not release criteria or universal slowdowns.

Agree workload-specific frame-time and error budgets before selecting a fast
approximation or changing the default package. Keep short regression vectors
in the quick gate; put exhaustive sweeps and broad platform/performance runs
in dedicated scheduled or release jobs. Wait for each suite to finish.

## Implementation order

| Phase | Deliverable | Completion gate |
| --- | --- | --- |
| 1. Contract and baseline | Specify special cases/environment; capture existing CPU/folding differences; add oracle vectors and benchmarks | Reproducible measurements and reviewed contracts; no unsupported whole-program determinism claim |
| 2. Target plumbing | Central target descriptor, baseline/v2/v3 `-cpu` selection, object/cache metadata, startup compatibility check | CPU requirements propagate to every build path; every Clang command passes `-ffp-contract=off`; baseline safety and unfused arithmetic verified at each CPU level |
| 3. FMA and first kernels | Verify software/hardware FMA equivalence; prototype correctly rounded `exp` and `sin` in both widths | Exact corpus agreement and measured cost on FMA/non-FMA paths |
| 4. Reproducible package | Port remaining kernels; special-value wrappers; deterministic folding/CTFE; thread/foreign entry support | Published supported-function list, oracle tests, and optimization/CPU matrix pass |
| 5. Simulation support | Reproducible distributions and composite operations, version metadata, replay example | Same state hashes across Windows CPU levels and repeated runs |
| 6. Performance decisions | Evaluate small deterministic approximation API and kernel dispatch independently | Add each only for a measured workload benefit with a maintained bit/error contract |
| 7. Platform certification | Reuse target boundary for Linux, macOS, ARM64, then Wasm as their runtimes mature | Execute numerical and simulation suites on each target before advertising support |
| 8. Default review | Decide whether `core:math` adopts the reproducible kernels | Complete function coverage, measured budgets, migration notes, and explicit release decision |

Phases 1 and 2 can be developed independently after agreeing the target and
numerical contracts. A limited reproducible package can ship before every
function is ported if its coverage is explicit. Future platform work need not
wait for optional approximations or runtime dispatch. Do not build a general
math-provider framework, fat-binary system, or new effect system for this first
implementation.

For each implemented behavior change, update the affected language/library
specification, implementation, citing comments, regression tests, and
`CHANGELOG.md` together. Regenerate changed package interfaces as described in
[Interface files](compiler-guide.md#interface-files), and document changed bits
under [Upgrade notes](releasing.md#upgrade-notes). Resolve the linked
[math questions](open-questions.md#deterministic-math-functions) and
[CPU questions](open-questions.md#targeting-x86-64-levels) as their decisions ship.
This proposal itself changes no compiler or library behavior.

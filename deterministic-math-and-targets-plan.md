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
  the main thread and to a started one. The entry mechanism for C hosts is not
  done; the obligation covers them for now.
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

`pow` is next.

Not started: phase 1's benchmarks (the UCRT timings in open questions stand
until there is a kernel to compare), the rest of phase 4's kernels, NaN
canonicalization, the environment entry
contract, simulation support, dispatch, and other platforms.

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

The [random distributions](open-questions.md#random-distributions-across-platforms)
also depend on these functions. Changing a result can change rejection sampling
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
`tests/math_oracle.odin` implements the first four tables.

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

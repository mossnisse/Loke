# Deterministic math and CPU targeting plan

Status: proposal, 2026-10-28. This document proposes implementation work; it
does not change the language contract or describe options already available.
The current authorities remain [Floating-point operators](design.md#floating-point-operators),
[`core:math`](standard-library.md#coremath), and the
[compiler options](compiler-guide.md#common-options).

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
  contract uses non-trapping arithmetic. Preserve the existing general-purpose
  environment facilities outside that contract.
- Publish an explicit list of certified functions and target combinations.
  An unimplemented function must not silently fall back to system `libm`.
- For the same inputs and contract version, CPU level, compiler host,
  optimization level, and compile-time versus runtime evaluation must not
  change the output bits on certified targets.

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

Propose independent `-target=<triple>` and `-cpu=<level>` options, integrated
with existing `-opt=<mode>`. Initially accept only the implemented Windows x64
target; recognizing a triple must not imply support for its ABI or runtime.
Use the existing Windows x64 triple as the default.

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
function, and other value-changing fast-math permissions. For C math/runtime
sources, set contraction explicitly off rather than assuming "precise" or
`-fno-fast-math` disables it. Inspect the generated IR and machine code:
frontend C flags alone do not define the semantics of Loke's emitted IR.
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
and floating-point environment. Do not make compiler bootstrap depend on
running target binaries. Start with `exp` in both widths to measure FMA versus
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
Document and implement setup for executable entry, every Loke-created thread,
worker threads, and foreign-thread attachment. Provide a scoped entry mechanism
for C hosts that establishes and restores this state. Foreign calls that change
it must restore it before Loke arithmetic resumes; validate that boundary in
debug builds. Setting it once in `main` is insufficient.

For x64, account for MXCSR rounding, FTZ, and DAZ. For ARM64, account for FPCR
and the chosen instruction semantics. LLVM environment attributes describe
assumptions; they do not initialize hardware state. The first implementation
milestone must turn these assumptions into a documented contract and tests,
without silently redefining the existing general-purpose environment behavior.

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
binary size, compile time, and simulation frame time. Cover ordinary and
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
| 2. Target plumbing | Central target descriptor, baseline/v2/v3 selection, object/cache metadata, startup compatibility check | CPU requirements propagate to every build path; baseline safety and unfused arithmetic verified |
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

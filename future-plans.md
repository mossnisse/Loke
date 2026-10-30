# Future plans

This is the implementation roadmap beyond the current compiler. The
language contract remains in [design.md](design.md) and [grammar.md](grammar.md).
Existing divergences belong in [known-gaps.md](known-gaps.md) and remain
correctness fixes to address while the work below proceeds.

Each phase states its starting point, implementation order, and completion
checks. The order is a priority order, with prerequisites called out separately;
it is not a promise that all work in one phase must stop before the next starts.
Before implementing a milestone, settle its remaining contract questions and
identify the regression cases that will demonstrate it. Update this document
as milestones ship, and keep implementation details in
[compiler-architecture.md](compiler-architecture.md).

## Suggested order

| Phase | Deliverable | Prerequisite | Status |
| --- | --- | --- | --- |
| 0 | [Correctness and performance baseline](#ongoing-quality-engineering), maintained throughout | Existing compiler and test suites | Ongoing |
| 1 | [Library support demonstrated by a parser and test harness in Loke](#standard-library-maturity) | Current lexer and corpus-runner examples | Lexer and corpus runner done; parser not started |
| 2 | [Reproducible dependency resolution and locked builds](#packages-and-dependencies) | Existing local `loke.project` workflow | Not started |
| 3 | [Reusable compiler sessions, then incremental checking](#compiler-services) | Current phase contracts and baseline comparisons | Milestones 1–4 shipped; equivalence and cost open |
| 4 | [Language server](#language-server) and [editor integration](#debugging-and-developer-tools) | Phase 3 sessions, overlays, and semantic queries | Language server shipped; debugger workflow open |
| 5 | [Linux, then macOS support](#more-platforms) | Target interfaces isolated while preserving Windows behavior | Not started |
| 6 | [Self-hosted compiler and reproducible bootstrap](#self-hosting) | Stable compiler contracts, required libraries, locked inputs, and release checks | Not started |

Start with the highest-risk known correctness gaps and the parser example.
Dependency work can proceed alongside library work. The first language-server
milestone can use whole-program checking while incremental checking is built.
Platform work can overlap editor work; it does not depend on the LSP or its
caches. Small formatter, documentation, and debugger improvements can ship
whenever a concrete use requires them.

The full compiler rewrite stays last to avoid maintaining two implementations
while their shared contracts are changing. The lexer and parser examples are
earlier library trials and can later become parts of that rewrite.

## Ongoing quality engineering

**Phase 0, then continuous.** Correctness, diagnostic quality, and performance
remain release requirements throughout the roadmap.

Implementation order:

1. Triage [known-gaps.md](known-gaps.md), fixing acceptance of unsafe programs
   before false rejections. Keep a minimal reproduction for each open gap and
   move each fixed reproduction into the appropriate regression corpus.
2. Preserve a baseline of diagnostics, emitted IR, and runtime output for any
   compiler refactor. Follow
   [Testing and verification](compiler-architecture.md#testing-and-verification):
   use the affected suite or `test-all.ps1` while iterating and let CI run the
   full gate. Run `-Full` locally when changing what only it covers or chasing
   a CI failure.
3. Measure with `perf.ps1` before and after representation or algorithm changes
   intended to improve speed. Add a `bench/` workload when the relevant case is
   missing; retain comparable measurements from the same machine.
4. Extend the syntax, semantic, IR, run, trap, package, object-host, foreign-ABI,
   example, and tutorial coverage as new boundaries appear. Malformed source
   must not crash, hang, or cause unbounded diagnostic cascades. Use practical
   runtime and compiler sanitizers and platform diagnostics as support permits.
5. Apply the existing [release checklist](releasing.md#release-checklist),
   including its requirement for no open specification divergences. Explain
   material performance regressions before a release.

**Completion check:** every shipped milestone has its regression evidence and
updated documentation; every release has comparable conformance, robustness,
and performance evidence. This work continues throughout the roadmap.

## Standard-library maturity

**Phase 1.** Establish library contracts through real command-line programs and
compiler workloads. The API inventory is in
[standard-library.md](standard-library.md); required coverage is in
[Standard-library verification](compiler-architecture.md#standard-library-verification).

Already available: [examples/lexer.loke](examples/lexer.loke) is checked against
`lokec -dump-tokens`. [examples/corpus_runner.loke](examples/corpus_runner.loke)
exercises run, trap, diagnostic, syntax-error, IR, and package corpora, using
`process.output`, `thread.processor_count`, and the toolchain reported by
`lokec -print-toolchain`.

Implementation order:

1. Build the parser as the next Loke example, reusing the lexer. Compare its
   accepted syntax, AST structure, source spans, and recovery on malformed
   input with the Odin parser and existing syntax corpus. Resolve library and
   language gaps exposed by this program before growing another subsystem.
2. Use that parser and the corpus runner to exercise source ownership,
   collections, paths, filesystem access, diagnostics, formatting, and
   allocation at repository scale. Record missing foundational operations
   before adding APIs; keep the program that demonstrates each need.
3. Add the testing and binary/text facilities those programs actually require.
   Introduce `core:bytes`, buffered I/O, or further encodings only when a
   caller establishes their contracts, as `core:time`, `core:random`, and
   `core:encoding/json` were.
4. For every public API, add an example and the applicable allocator-failure,
   cleanup, Unicode, short-I/O, and platform-conformance cases from
   [Standard-library verification](compiler-architecture.md#standard-library-verification).

Current optional gaps, to add only when a caller establishes their contract:
`core:bytes`, `core:unicode`,
`core:encoding/base64`, and `core:testing`; in
`core:time`, the local and named time zones (see
[Open questions in `core:time`](open-questions.md#open-questions-in-coretime));
in `core:random`, `f32` distributions,
sampling indices from a range without materializing it, and distributions such
as the negative binomial, Cauchy, and Weibull; buffered streams,
`fs.absolute`, `fs.canonicalize`, symlinks, and file
locking; fallible twins of
allocating string transformations other than `copy`, Unicode case mapping,
normalization, and grapheme segmentation; terminal colors, cursor movement,
mouse and resize events; `thread.try_spawn`, `try_lock`, and thread identity
(a bare condition variable is left out on purpose: `Monitor` replaces it, see
[Waiting on a condition, not a signal](comments.md#waiting-on-a-condition-not-a-signal)).
Math gaps include hyperbolics,
`cbrt`/`ldexp`/`frexp`/`modf`, `erf`, `gamma`, lane-wise SIMD math, and
integer bit helpers. `core:simd`'s remaining gaps are specified in
[What SIMD does not do](design.md#what-simd-does-not-do).
[`core:math/linalg`](standard-library.md#coremathlinalg) has every milestone
of the [linear algebra library plan](linear-algebra-plan.md#milestones), the
last its measured `Simd` paths, and
[`core:math/dense`](standard-library.md#coremathdense) all five milestones
of the [dense matrix plan](dense-matrix-plan.md#milestones): storage, views,
products, LU, Cholesky, QR, least squares, the symmetric and Hermitian
eigensolver, the SVD, measured `Simd`, blocked, and pooled kernels, and
complex elements through `linalg.Scalar`. Shapes, exact predicates, and the
queries between them are proposed for `core:math/geometry` in the
[geometry library plan](geometry-plan.md#milestones).

[`core:encoding/json`](standard-library.md#coreencodingjson) still needs this
evidence, in this order; its open design questions are in
[JSON follow-ups](open-questions.md#json-follow-ups):

1. Run the [JSONTestSuite](https://github.com/nst/JSONTestSuite), pinned to a
   revision: accept its required-valid cases within the documented limits,
   reject its required-invalid cases, and record the result of every
   implementation-defined case.
2. Fuzz scanner and document agreement and writer call sequences, and check
   writer output with an independent parser. The locale fault host in
   `tests/obj` checks the runtime's fallible numeric entry points; carry an
   injected locale failure through `strconv`, `fmt`, and the JSON errors too.
3. Keep a benchmark corpus: state files of 2–64 KiB, large numeric arrays, many
   small objects, long ASCII strings, non-ASCII text, and dense escapes of
   1–64 MiB, plus tiny tokens and large-then-small document reuse. Report time,
   throughput, allocation count and bytes, peak memory including growth, and
   retained capacity, separating cold and reused parses, a complete walk with
   conversions, field extraction, repeated lookup against one traversal,
   output to memory, and durable file I/O. Compare the 16-byte node layout
   with the 24-byte one, and compare like-for-like full validation against
   pinned reference parsers, disclosing flags, hardware, allocator, input
   copies, and raised limits ([simdjson's guidance](https://github.com/simdjson/simdjson/blob/master/doc/performance.md)
   lists the usual pitfalls).
4. Optimize from that baseline: byte runs, bulk copies into the writer's buffer
   (it copies byte by byte today), escaping, and number conversion first; SIMD
   string scanning or UTF-8 validation on full blocks after, with short tails
   kept in bounds. No throughput claim is made until then.

**Completion check:** the lexer, parser, and test harness run on the shared
library without private substitutes for foundational services. Further library
needs are handled with the compiler phase that exposes them; this is not a
requirement to finish every optional package before phase 2 or phase 3.

## Packages and dependencies

**Phase 2.** Extend the existing [Projects](compiler-guide.md#projects)
workflow while keeping imports independent of a registry. Today
`loke.project` registers local dependency directories as collections, follows
their manifests, and permits explicit `-collection` overrides.

Implementation order:

1. Define dependency identity and version syntax before extending the manifest:
   how a collection name identifies its source, which Git tags are versions,
   how versions are ordered, and how incompatible major versions and conflicting
   sources are diagnosed. Use the minimal-version-selection direction recorded
   in [Package and import versioning](open-questions.md#package-and-import-versioning).
   Retain local directories and explicit overrides. Record the required Loke
   release without splitting the compiler, runtime, and library bundle that
   [Version policy](releasing.md#version-policy) already defines.
2. Implement resolution and fetching as an explicit tool step outside front-end
   compilation. Resolve direct and transitive requirements to one graph, then
   write a lock containing every selected dependency's collection name, source
   URL, version, immutable Git commit ID, and content checksum. Define exactly
   which files the checksum covers. A version tag is an input to resolution;
   locked fetching uses the commit ID and verifies content.
3. Define locked-build and update behavior separately. A locked build must use
   the recorded graph and reject inconsistent manifests or missing lock entries.
   Only an explicit resolve/update operation may select new revisions or rewrite
   the lock. Define how local dependencies and overrides are represented: an
   unrecorded local replacement must not silently claim to reproduce a locked
   build, and reproducibility checks must cover any recorded local inputs.
4. Specify cache keys, content verification, interrupted fetch cleanup, and
   offline behavior. Compilation consumes already prepared dependencies and
   performs no implicit network access. A preparation step may fetch missing
   locked commits; an offline preparation uses only verified cached or vendored
   content. Unavailable locked content is an error, never a reason to select a
   different revision.
5. Add fixtures for transitive version selection, source/name conflicts, local
   overrides, incompatible compiler requirements, lock/manifest mismatches,
   cache corruption, unavailable commits, and offline cache misses. Resolve a
   project, move a dependency tag while retaining its original commit on the
   remote, clear the local cache, and verify that locked fetching still builds
   the original graph.

**Completion check:** two clean machines given the same project, lock, available
source revisions, and matched Loke release prepare the same dependency graph
and build without collection flags. The prepared project builds offline, and
neither a moved tag nor a normal build changes its locked inputs. This guarantees
dependency reproducibility; binary reproducibility is checked separately during
self-hosting.

## Compiler services

**Phase 3.** Expose the existing compiler to tools in small steps. Preserve the
[checking and consumption boundary](compiler-architecture.md#pipeline-at-a-glance)
and the current command-line behavior. A reusable batch session is the first
deliverable; incremental checking is a later milestone with its own evidence.

Implementation order:

1. **Reusable sessions — shipped.** `Compilation_Session` separates driver
   concerns from owned configuration, sources, packages, semantic stores, and
   diagnostics. `lokec` uses its creation, checking, emission, and destruction
   path; every check reloads inputs and runs the existing whole-program pipeline.
   Regression coverage compares reused and fresh sessions after source and
   manifest edits, checks diagnostics and IR, and tracks repeated creation and
   destruction for leaks. The API and lifetime contract are in
   [Reusable batch sessions](compiler-architecture.md#reusable-batch-sessions).
2. **Snapshots and queries — shipped.** Session-owned overlays supply unsaved
   sources and new packages through the ordinary loader. Read-only queries
   expose symbols, types, definitions, references, signatures, and diagnostics
   from checked results, with partial results on erroneous programs. Snapshot
   IDs reject stale/foreign handles after edits, checks, or destruction; old
   query storage is reclaimed rather than retained. Regression coverage checks
   overlay/disk equivalence, recorded binding identity, errors, lifetimes, and
   repeated queries without semantic mutation. The API and error/lifetime
   contracts are in [Snapshots and queries](compiler-architecture.md#snapshots-and-queries).
   This milestone is enough to begin the language server.
3. **Invalidation rules — shipped.** `invalidate_session` expires the entire
   checked result on external input changes, sharing the conservative boundary
   used by overlays and new checks. The next check reloads and rebuilds the whole
   program. [Invalidation rules](compiler-architecture.md#invalidation-rules)
   identify source/discovery, imports, manifests, collections, providers, build
   configuration, compiler identity, and target inputs, plus the CTFE, generic,
   inferred-effect, and final-registry dependencies that signatures alone miss.
   Regression coverage compares edits, failures, and fixes with fresh batches.
   These rules also govern the narrower reuse in the following milestone.
4. **Incremental checking — shipped.** `check_session_incremental` restores
   bounded package checkpoints for stable static import graphs, reuses the
   dependency prefix before an edit, and rechecks the suffix containing the
   changed packages and their dependents. Whole-program analyses and finalization
   still run; emission remains whole-program. `session_check_stats` exposes reuse
   and retained memory. Edit sequences compare fresh diagnostics/IR and verify
   repeated overlays do not accumulate obsolete state. Discovery, conditional
   selection, providers, and unknown changes retain the full-check fallback.
   The scope and memory ceiling are in
   [Incremental checking](compiler-architecture.md#incremental-checking).
5. **Equivalence and cost.** Compare each incremental result with a fresh batch
   compilation after edits, including import additions/removals, conditional
   imports, generic changes, provider/configuration changes, and fixes to invalid
   source. Measure cold startup, warm edit latency, and memory on a representative
   multi-package workspace before calling the cache an improvement.
   `bench/workspace` is that workspace, and `perf.ps1` measures the language
   server on it. There, provenance analysis is most of an incremental check,
   and checkpoint images, each a copy of the whole semantic arena so far, cost
   more memory than the program's own state. Reusing provenance results for
   unchanged packages, and sharing unchanged image bytes, come next.

**Completion checks:** milestones 1 and 2 retain batch diagnostics and IR and
support repeated tool queries. The incremental milestone gives the same results
as fresh compilation, avoids rechecking unrelated packages for an ordinary local
edit, and does not retain obsolete snapshots indefinitely. Document cases that
still require whole-program invalidation.

## Language server

**Phase 4.** Build on [Compiler services](#compiler-services), using the real
lexer, parser, package loader, and checker. Begin after sessions, overlays, and
queries exist; incremental checking can arrive during this phase.

Implementation order:

1. **Documents and diagnostics — shipped.** `loke-lsp.exe` handles document
   open, change, save, and close. It checks each open document through its
   package directory with a batch session, honoring `loke.project`,
   `initializationOptions` collections/defines, and watched-file changes.
   Diagnostics carry the document version they were computed from; results
   superseded by a later edit are discarded. Requests queued with their
   `$/cancelRequest` are answered as cancelled. `shutdown` and `exit` follow
   the protocol's exit codes. Protocol regressions run in-process and over
   pipes. The design is in
   [Language server](compiler-architecture.md#language-server).
2. **Hover, go-to-definition, and document symbols — shipped.** Requests wait
   for their document's root to be checked and are answered from its snapshot;
   one whose document changed first is answered `ContentModified`. Symbols
   carry their declaration extent, owning declaration, and doc comment from the
   query API. Unresolved names answer `null`. Regressions cover unsaved
   buffers, multiple packages, syntax errors, missing imports, recovery after a
   broken edit, and stale and cancelled requests.
3. **Completion, signature help, references, and rename — shipped.** A
   statement the parser cannot finish is still checked, so `value.` and
   `call(first, ` keep their meaning. `query_visible` and `query_members` list
   names in scope and after a `.`. References and rename follow binding
   identity across every checked program. Rename refuses scope and member
   collisions, unchecked code using the old name, programs with errors, and the
   bundled library. Regressions cover unfinished code, shadowing, named
   arguments, fields, two programs sharing a library, and each refusal.
4. **Incremental checking — shipped.** Roots check with
   `check_session_incremental`, in documentation mode too. A file-scope `when`
   without imports, an edit with syntax errors, and unchanged file attributes
   keep the reusable prefix. `perf.ps1` times the server on `bench/workspace`:
   an edit is answered about 45 ms sooner, but whole-program provenance
   analysis still runs on every check, and checkpoints add about 57 MiB per
   program. Regressions cover rapid edits compared with a fresh check,
   cancelled and stale requests during incremental checks, completion in
   unfinished code, and files created, changed, and deleted on disk.
5. **Formatting and documentation — shipped.** `textDocument/formatting`
   answers the layout `lokec -fmt` writes for the unsaved text, as one edit
   over the changed lines, without waiting for a check. The
   `loke.documentation` command first answered the page `lokec -doc` prints for
   the document's root; since the interface file was added, it answers what
   `lokec -api` writes for the document's package. Regressions compare both
   with the command-line tools in process and over pipes, and cover repeated
   formatting, CRLF text, refusals,
   unsaved imports, a library rechecked after edits, and a program `lokec`
   would reject for its missing `main`. See
   [Debugging and developer tools](#debugging-and-developer-tools).

**Completion check:** the server handles a multi-package workspace and unsaved,
temporarily invalid code; diagnostics and name resolution agree with a fresh
`lokec` run on the same inputs. Ordinary edits reuse unaffected package state,
and each advertised editing operation has a protocol regression test.

## Debugging and developer tools

**Alongside phases 1-5, with editor integration in phase 4.** The command-line
foundation already exists: `-fmt` formats source, `-doc` emits public API and
declaration comments, `-api` writes each package's checked-in
[interface file](compiler-guide.md#interface-files), and Windows `-g` emits
CodeView/PDB information for
procedures, scoped locals, and statement locations. Debug executables include
Loke panic frames; natvis covers strings, maps, `any_view`, and `dyn` values.
See [Common options](compiler-guide.md#common-options) and
[Formatting](comments.md#formatting).

Implementation order:

1. Keep the existing formatter, documentation, and debugger regression coverage
   green through compiler-service changes.
2. Add automatic column alignment when hand-maintained alignment becomes a
   demonstrated burden, settling the remaining
   [formatting questions](open-questions.md#formatting) with examples first.
3. **Formatting and documentation in the editor — shipped.** `loke-lsp`
   calls the procedures behind `-fmt` and `-api` on unsaved text, and hover
   shows doc comments as `-doc` does; formatting the result again leaves it
   unchanged. See
   [Language server](compiler-guide.md#language-server).
4. Document and test an editor/debugger workflow for each supported target:
   breakpoint, stepping, ordinary local inspection, and panic stack trace.
   Windows coverage uses the existing PDB path; platform ports must choose and
   verify their own debug formats and debugger integration. Introduce a durable
   intermediate representation only if a concrete consumer requires it.

**Completion check:** the supported editor workflow can format a document,
browse its public API, set a source breakpoint, inspect ordinary locals, and
show Loke frames. Optimized-build limitations are documented and covered by
target-specific tests where practical.

## More platforms

**Phase 5.** Preserve Windows x64 behavior while isolating target decisions,
then add Linux and macOS. Target support is explicit and distinct from the
host running the compiler. This work can overlap phases 3 and 4.

Implementation order:

1. **Target boundary on Windows.** Centralize target triples, scalar layout,
   calling conventions, object formats, debug formats, and linker arguments.
   Add an explicit target-selection interface, keeping the current Windows x64
   target as the compatibility baseline. Distinguish host paths/processes from
   target ABI and runtime choices throughout the driver. CPU levels belong to
   this boundary too: baseline x86-64 stays the default, and a level such as
   `x86-64-v3` is chosen separately from `-opt` and never relaxes a math
   function's numerical contract. Do not add a public `-target` option while
   Windows x64 is the only target, since an option that accepts one value
   would fix triple spelling and normalization before a second target forces
   those decisions. Add it with the first additional target; recognizing a
   triple must not imply support for its ABI or runtime.
2. **Supported configurations.** Name the initial Linux and macOS architectures
   and supported host/target pairs. Decide toolchain discovery, SDK/sysroot
   selection, foreign-library resolution, and artifact naming before promising
   cross-compilation. Reject unsupported combinations explicitly.
3. **Native Linux.** Port the compiler's host operations, runtime startup,
   arguments, panic/unwind and stack traces, TLS teardown, atomics, and platform
   services. Implement filesystem, terminal, process, and OS bindings behind
   existing library contracts. Add Linux build, test, and release jobs.
4. **Native macOS.** Reuse the target boundary and shared implementations, then
   add the macOS ABI, toolchain, runtime, library, debugger, and CI coverage.
   Keep platform differences in their implementations and documented contracts.
5. **Declared cross-compilation pairs.** Validate each supported combination
   using its documented SDK/sysroot and foreign libraries. Run produced programs
   on the target; successful cross-linking alone is not conformance evidence.

**Completion check for each target:** the shared semantic, layout, IR, run,
trap, package, library, and C-interop suites pass in CI, with explicit expected
ABI/platform differences instead of blanket skips. Debugging and installed
release-bundle smoke tests pass on that target. Windows remains green throughout.
Portable programs have the same specified behavior across supported targets.

## Self-hosting

**Phase 6.** Start the full rewrite when the required libraries, compiler phase
and session contracts, dependency workflow, and release checks are stable.
Incremental performance tuning and optional editor features need not be finished.
Reuse the earlier lexer and parser trials. The Odin implementation remains the
bootstrap and behavioral reference until the replacement passes the gates below.

Implementation order:

1. **Pin the inputs.** Record the Odin-based `lokec` used as stage 0, the Loke
   compiler source revision, locked dependencies, matched runtime/library bundle,
   LLVM/linker versions, target, and build flags. Define reproducible source paths
   and handling of timestamps and debug metadata before comparing artifacts.
2. **Migrate by phase.** Port source/package loading and parsing, then semantic
   stores and checking, compile-time evaluation and specialization, ownership
   and provenance analysis, LLVM emission, and the driver/toolchain integration.
   Preserve [phase contracts](compiler-architecture.md#driver-and-phase-order).
   Compare each available phase with the Odin implementation before porting the
   next; keep library additions tied to the compiler code that requires them.
3. **Behavioral parity.** Run the complete compiler and integration suites
   against both implementations, including diagnostics, invalid input, tutorials,
   object-host/foreign ABI, and optimization-sensitive cases. Port Odin-only
   unit checks or provide equivalent checks for the Loke implementation. Resolve
   unexplained acceptance, diagnostic, layout, and runtime differences before
   treating bootstrap success as sufficient.
4. **Three-stage bootstrap.** Compile the same Loke compiler sources with stage 0
   to produce stage 1; use stage 1 to produce stage 2; use stage 2 to produce
   stage 3. Stages 1 and 2 may differ because their producers are different
   implementations. Compare stage 2 and stage 3 emitted IR and compiler binaries
   using identical inputs and options. Run the conformance suites with the
   resulting compilers as well.
5. **Reproducibility gate.** Repeat the bootstrap from clean build directories
   in CI on each supported native target. Require byte-identical stage-2/stage-3
   comparison artifacts, including distributed debug artifacts when present.
   Eliminate incidental path/time variation through build settings; any necessary
   normalization must be narrowly documented and must not mask generated code or
   data differences. Also compare repeated clean builds to catch nondeterminism
   that one consecutive stage comparison could miss.
6. **Release and retirement.** Build and install a candidate self-hosted release
   bundle, use it to rebuild the compiler and compile external sample projects,
   and apply the existing [release checklist](releasing.md#release-checklist).
   Retire the Odin implementation only after behavioral parity, reproducible
   bootstrap, and installed-release checks pass. Preserve a documented bootstrap
   path and the exact inputs needed to rebuild it.

**Completion check:** a released Loke compiler builds an equivalent compiler
from source; stage 2 and stage 3 match under the reproducibility contract; both
implementations pass the required compatibility suites during migration; and
the installed release works without the Odin implementation present.

## Open language questions

[open-questions.md](open-questions.md) remains the canonical backlog for possible
language changes. A roadmap workload may establish a need, but implementation
starts only after the proposal's semantics and migration are decided. Keep the
specification, grammar, implementation, tests, rationale, and release notes
consistent when such a change is accepted. This roadmap does not silently
promote every open question into a compiler task.

# Future plans

This is the implementation roadmap beyond the current v1 compiler. The
language contract remains in [design.md](design.md) and [grammar.md](grammar.md).
Existing divergences belong in [known-gaps.md](known-gaps.md) and are v1 fixes,
including while the work below proceeds.

Each phase states its starting point, implementation order, and completion
checks. The order is a priority order, with prerequisites called out separately;
it is not a promise that all work in one phase must stop before the next starts.
Before implementing a milestone, settle its remaining contract questions and
identify the regression cases that will demonstrate it. Update this document
as milestones ship, and keep implementation details in
[compiler-architecture.md](compiler-architecture.md).

## Suggested order

| Phase | Deliverable | Prerequisite |
| --- | --- | --- |
| 0 | [Correctness and performance baseline](#ongoing-quality-engineering), maintained throughout | Existing compiler and test suites |
| 1 | [Library support demonstrated by a parser and test harness in Loke](#standard-library-maturity) | Current lexer and corpus-runner examples |
| 2 | [Reproducible dependency resolution and locked builds](#packages-and-dependencies) | Existing local `loke.project` workflow |
| 3 | [Reusable compiler sessions, then incremental checking](#compiler-services) | Current phase contracts and baseline comparisons |
| 4 | [Language server](#language-server) and [editor integration](#debugging-and-developer-tools) | Phase 3 sessions, overlays, and semantic queries |
| 5 | [Linux, then macOS support](#more-platforms) | Target interfaces isolated while preserving Windows behavior |
| 6 | [Self-hosted compiler and reproducible bootstrap](#self-hosting) | Stable compiler contracts, required libraries, locked inputs, and release checks |

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
and performance evidence. This phase does not end after v1.

## Standard-library maturity

**Phase 1.** Establish library contracts through real command-line programs and
compiler workloads. The API inventory and test requirements remain in
[standard-library.md](standard-library.md).

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
   Introduce `core:bytes`, time, random, buffered I/O, or higher-level encodings
   only when a caller establishes their contracts. Settle
   [width and precision in `fmt`](open-questions.md#width-and-precision-in-fmt)
   together when a program needs both.
4. For every public API, add an example and the applicable allocator-failure,
   cleanup, Unicode, short-I/O, and platform-conformance cases from
   [Test requirements](standard-library.md#test-requirements).

**Completion check:** the lexer, parser, and test harness run on the shared
library without private substitutes for foundational services. Further library
needs are handled with the compiler phase that exposes them; this is not a
requirement to finish every optional package before phase 2 or phase 3.

## Packages and dependencies

**Phase 2.** Extend the existing [Projects](readme.md#projects) workflow while
keeping imports independent of a registry. Today `loke.project` registers local
dependency directories as collections, follows their manifests, and permits
explicit `-collection` overrides.

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
   Narrower reuse remains deferred until its complete dependencies can be
   established safely.
4. **Incremental checking.** Cache and reclaim per-package state, invalidate
   changed packages and affected dependents, and rerun required whole-program
   analyses and finalization. Do not introduce separate object compilation as
   part of this milestone. Track rechecked packages and memory use across edit
   sequences so reuse and reclamation are both observable.
5. **Equivalence and cost.** Compare each incremental result with a fresh batch
   compilation after edits, including import additions/removals, conditional
   imports, generic changes, provider/configuration changes, and fixes to invalid
   source. Measure cold startup, warm edit latency, and memory on a representative
   multi-package workspace before calling the cache an improvement.

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

1. Support workspace/project loading and document open, change, save, and close.
   Publish diagnostics for the current document version, discard results for
   superseded versions, and handle cancellation and shutdown. Start with batch
   checking through the session API.
2. Add hover, go-to-definition, and document symbols from checked semantic data.
   Exercise unsaved buffers, multiple packages, syntax errors, missing imports,
   and recovery after a broken edit. A missing semantic result must not crash
   the server or be presented as a successful resolution.
3. Add completion and signature help for incomplete programs, then references
   and rename. Check that rename respects binding identity, scope, and name
   collisions across packages rather than replacing matching text.
4. Adopt the incremental session path and measure editor latency on the same
   workspace used for compiler-service checks. Add protocol-level regressions
   for rapid edits, cancellation, stale results, and workspace changes.
5. Connect the formatter and generated documentation through the existing tools
   as described in [Debugging and developer tools](#debugging-and-developer-tools).

**Completion check:** the server handles a multi-package workspace and unsaved,
temporarily invalid code; diagnostics and name resolution agree with a fresh
`lokec` run on the same inputs. Ordinary edits reuse unaffected package state,
and each advertised editing operation has a protocol regression test.

## Debugging and developer tools

**Alongside phases 1-5, with editor integration in phase 4.** The command-line
foundation already exists: `-fmt` formats source, `-doc` emits public API and
declaration comments, and Windows `-g` emits CodeView/PDB information for
procedures, scoped locals, and statement locations. Debug executables include
Loke panic frames; natvis covers strings, maps, `any_view`, and `dyn` values.
See [Common options](readme.md#common-options) and
[Formatting](comments.md#formatting).

Implementation order:

1. Keep the existing formatter, documentation, and debugger regression coverage
   green through compiler-service changes. Use the lexer's retained comment
   spans for documentation and hover.
2. Add automatic column alignment when hand-maintained alignment becomes a
   demonstrated burden, settling the remaining
   [formatting questions](open-questions.md#formatting) with examples first.
3. Expose formatting and documentation from the editor without creating another
   front end. Preserve unsaved-buffer behavior and make formatting edits
   repeatable: applying the formatter twice must leave the same text.
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
   target ABI and runtime choices throughout the driver.
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

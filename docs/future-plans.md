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

The compile-time evaluator's values are one candidate for that measurement:
every scalar is a `core:math/big` integer inside a whole constant
(`Eval_Value` in [src/eval.odin](../src/eval.odin)), so loops and arithmetic set
both its time and what it charges against its memory limit. A small-integer
fast path (`i64`, promoted to a big integer on overflow) with a tagged scalar
representation would cut both; it needs a `bench/` workload of compile-time
loops first.

**Completion check:** every shipped milestone has its regression evidence and
updated documentation; every release has comparable conformance, robustness,
and performance evidence. This work continues throughout the roadmap.

## Standard-library maturity

**Phase 1.** Establish library contracts through real command-line programs and
compiler workloads. The API inventory is in
[standard-library.md](standard-library.md); required coverage is in
[Standard-library verification](compiler-architecture.md#standard-library-verification).

Already available: [examples/lexer.loke](../examples/lexer.loke) is checked against
`lokec -dump-tokens`. [examples/corpus_runner.loke](../examples/corpus_runner.loke)
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

The containers that could follow [`Priority_Queue` and `Deque`](standard-library.md#priority-queues),
in the suggested order. Each is worth having in a general-purpose library on its own
merits. Concurrent containers stay in [`core:thread`](standard-library.md#corethread).

| Type | What it adds | Shape |
| --- | --- | --- |
| `Set(T)` | Hash set with `in` and set algebra. | A wrapper over `map[T]Unit` with `T` `Hashable`. A map with a zero-sized value already works. |
| `Ordered_Map(K, V)`, `Ordered_Set(T)` | Sorted iteration, nearest-key and range queries, which `map` cannot offer. | A B-tree, ordered by `Ordered(K)` or a stored comparator exactly as `Priority_Queue` stores one. |
| `Slot_Map(T)` | Stable handles with generation checks, O(1) insert and remove. For graphs and entity tables that would otherwise fight the borrow checker. | Dense or sparse slots, with a `Handle` value type. |
| `Indexed_Priority_Queue` | True decrease-key, for a caller who has measured that duplicates cost too much. | Keys are `0 ..< cap`, with a position table beside the heap, so `set_priority(key, value)` is O(log n). |
| `Small_Deque(T, N)` | A ring with inline storage and no allocation. | As `Deque`, over `[N]T`. |
| `Inline_Array(T, N)` | A small array that spills to the heap. | `Small_Array` plus a `[dynamic]T`. |

Linked lists are deliberately left out. Lists lose to arrays on cache behaviour for
nearly all uses, and an owning doubly-linked list has no good expression under the
borrow rules. `Slot_Map` with indices gives the same O(1) unlinking with checked
handles.

Current optional gaps, to add only when a caller establishes their contract:
`core:bytes`, `core:unicode`,
`core:encoding/base64`, and `core:testing`; in
`core:time`, [named time zones](#named-time-zones);
in `core:random`, `f32` distributions,
sampling indices from a range without materializing it, and distributions such
as the negative binomial, Cauchy, and Weibull; buffered streams,
`fs.absolute`, `fs.canonicalize`, and symlinks; fallible twins of
allocating string transformations other than `copy`, Unicode case mapping,
normalization, and grapheme segmentation; terminal colors, cursor movement,
mouse and resize events; `thread.try_spawn`, `try_lock`, and thread identity
(a bare condition variable is left out on purpose: `Monitor` replaces it, see
[Waiting on a condition, not a signal](comments.md#waiting-on-a-condition-not-a-signal)).
Math gaps include hyperbolics,
`cbrt`/`ldexp`/`frexp`/`modf`, `erf`, `gamma`, lane-wise SIMD math, and
the lane-wise integer bit operations (see
[Integer bit operations not yet provided](open-questions.md#integer-bit-operations-not-yet-provided))
and [bit field extract and deposit](#bit-field-extract-and-deposit).
`core:simd`'s remaining gaps are specified in
[What SIMD does not do](design.md#what-simd-does-not-do).
[`core:math/linalg`](standard-library.md#coremathlinalg) has vectors,
matrices of any fixed shape, transforms, rotations, cameras, and measured
`Simd` paths, and
[`core:math/dense`](standard-library.md#coremathdense) has storage, views,
products, LU, Cholesky, QR, least squares, the symmetric and Hermitian
eigensolver, the SVD, measured `Simd`, blocked, and pooled kernels, and
complex elements through `linalg.Scalar`.
[`core:math/geometry`](standard-library.md#coremathgeometry) has the exact
predicates, the shapes with their point queries, rays, culling, and
transforms, polygons, and the measured `Simd` path of the `f32` box cast.

[`core:encoding/binary`](standard-library.md#coreencodingbinary) and
[`core:checksum`](standard-library.md#corechecksum) leave these for a caller, each of
which fits on top without changing their API: buffered streams, which need their own
contract for a `drop` that cannot report a failed flush and which `Writer(W)` will
accept unchanged; bulk typed arrays, `get_all(destination: []mut T)` and its inverse,
as a measured optimization with a host-order fast path; variable-length integers and
bit fields, which are separate encodings with their own failure modes; a tee adapter;
`combine` for CRCs, which matters for parallel checksums; and carry-less
multiplication and the SSE4.2 CRC-32C instruction.

`core:math/linalg` adds, with a caller: structure-of-arrays batch transforms,
a vector a lane rather than a component a lane, measured against
`bench/linalg.loke`; proper Euler sequences such as `ZXZ`; dual quaternions; a
condition estimate beside `inverse` and `solve`; and `quaternion_between` as
one procedure with an `Option(Vector3(T))` fallback, which
[Arguments typed after inference](design.md#arguments-typed-after-inference)
now allows.

[`core:math/repro`](standard-library.md#coremathrepro) has every
transcendental function of `core:math`, `sqrt`, and the two magnitudes,
correctly rounded and dispatched to FMA at `x86-64-v3`. Still to do, in this
order:

1. Faster `f64` kernels. `exp`'s and `log`'s dependency chains were shortened
   by counting their latencies; the other functions' chains have not been
   counted. Measure worst observed latency, the slow paths' included, and a
   simulation's frame time, not only throughput, and compare at baseline and
   `x86-64-v3` under ordinary and adversarial arguments.
2. A `core:math/fast` package only if a measured workload needs it, beginning
   with `sin`, `cos`, `exp`, and `log`, never a copy of the whole of
   `core:math`. Each approximation freezes its coefficients, reduction,
   evaluation order, special cases, and use of FMA, which is either explicit
   on every target, emulated where needed, or absent on every target, never
   two evaluations dispatched because each is within the bound. It states its
   domain, its behavior outside it, and a verified error bound, absolute
   where relative error means nothing, avoids slow-path iteration where frame
   time matters, and versions its results as `RESULTS_VERSION` does.
3. The default. Once coverage and measurements justify it, a release decides
   whether `core:math` takes the correctly rounded kernels. If it does,
   `core:math/repro` stays as a compatible name, the C library's functions
   move to `core:math/system`, and no second correctly rounded implementation
   is kept.

Arbitrary precision and directed-rounding or interval arithmetic are separate
libraries that name their rounding, and a whole-program NaN canonicalization
mode would be compiler work of its own; neither follows from
`core:math/repro`.

`core:math/dense` adds each of these with a caller who needs it: `try_` forms
that return allocation failure; reversed views; a one-sided Jacobi SVD, slower
and more accurate for tiny singular values; values-only forms of
`symmetric_eigen` and `svd`, which would give the same values bit for bit;
the full `U`; a QR in the blocked WY form under its own name, since its bits
differ ([Standard-library API choices](comments.md#standard-library-api-choices));
a pool for `qr`, `symmetric_eigen`, `svd`, and the one-call `solve`,
`inverse`, and `least_squares`; a faster symmetric product in the
tridiagonalization, now the eigensolver's largest cost; a fast path for
products with a strided `a`; a complex `Simd` kernel, which would have to keep
`math.Complex`'s `ac - bd` and `ad + bc` in each lane; and a conjugating
`dot`.

`core:math/geometry` leaves these for a caller, each built on what it has:
oriented boxes, capsules, and cylinders, with the separating-axis tests
between them (Gottschalk et al., 1996) and the closest points of capsules;
an exact frustum test by separating axes beside the conservative one;
bounding volume hierarchies over `Aabb3` with deterministic construction,
and a uniform grid for a 2D broad phase; Welzl's minimal enclosing circle and
sphere, with a seeded `core:random` generator so the result is reproducible;
Delaunay and constrained triangulation over the exact predicates, and polygon
Boolean operations; Bézier evaluation, subdivision, bounds, and flattening to
a polyline with a stated tolerance; and lane-wise batch queries over
structure-of-arrays boxes, measured against `bench/geometry.loke`. Meshes,
NURBS, geodesy on the ellipsoid, and contact generation for a physics solver
can likewise be built on it.

[`core:encoding/json`](standard-library.md#coreencodingjson) still needs this
evidence, in this order; the designs that wait for a caller are in
[JSON designs](#json-designs):

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
Loke panic frames; natvis covers strings, maps, and `dyn` values.
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

## Package documentation

**Alongside phases 1-5.** Hand-written documentation goes stale, because
nothing checks it. What a package tells its users is therefore generated from
its source, checked by the compiler, or run by the test runner, and prose is
kept for intent, which goes stale slowest. [`///` doc comments](design.md#comments),
the checked-in [interface file](compiler-guide.md#interface-files), and
[`@(intrinsic)`](design.md#intrinsic) declarations are built, and so is the
first step. The steps below were accepted on 2026-11-22; each one's language rules move to
[design.md](design.md) with its implementation, and what the plan does not
decide is in [Package documentation](open-questions.md#package-documentation).

### Steps

**1. Inferred facts are shown, one line each — shipped.** The interface
file and hover put an `// inferred:` line above a public procedure for what
its result borrows, which allocator backs it, and whose package state a call
writes, and say nothing when there is nothing to report
([Inferred lines](compiler-guide.md#inferred-lines),
[reasons](comments.md#inferred-facts-are-shown-not-promised)). A
[written contract](design-review-2026-10-31.md#public-borrow-contracts-should-stand-on-their-own), once
it exists, would be shown in its place, without "inferred".

**2. Examples are tests.** `@(example=split)` marks a
[test procedure](design.md#test-procedures) that illustrates `split`, or
`Type.member` for an `impl` member, of its own package. It follows every test
rule, and in addition it may name only public declarations, because it shows
what an importer can write. The interface file lists each example by name
under its declaration (``// example: `split_on_commas` ``), and the HTML page
shows its body. The gate builds each bundled package with `-test`, so an
example that stops compiling or fails is caught.

**3. Names in doc comments are checked.** A backticked span in a doc
comment that is a name or dotted path, such as `split`, `Builder.len`, or
`mem.Allocator`, must resolve, as rustdoc's intra-doc links must. It resolves
in the documented declaration's package and imports, and also among its
parameters and, for a type or `impl` member, the type's members. A span with
any other character, such as `builder.len()` or `[dynamic]u8`, is prose and is
not checked. An unresolved name is a warning in every check, so the editor
shows it. This catches renames and removals, not wrong claims.

**4. `-doc` writes HTML for people.** A browser is on every computer, and a
Markdown page needs a renderer and has no links. `lokec <dir> -doc` writes
`index.html` and one page per package of the project into `doc/`, or the
directory `-o` names. Each page is self-contained, with inline CSS for light
and dark themes and no scripts. Signatures are colored from the compiler's own
tokens, which is exact where a TextMate grammar approximates, and every name in
a signature or checked reference links to its declaration's anchor (`#split`,
`#String_Builder.append`). Doc comments are rendered from a stated subset:
paragraphs, inline code, `*emphasis*`, `**strong**`, `- ` lists, and indented
code blocks. The HTML is generated, not checked in. Hover stays Markdown,
which the protocol requires, and the editor's documentation command shows the
interface file as a Loke document instead of a Markdown preview.

### Not planned

- **A "may panic" mark.** Once checked arithmetic and indexing count, nearly
  every procedure may panic, so the mark carries no information. A
  precondition a caller must meet is written in the doc comment.
- **Preconditions as code.** Checked clauses are a language feature, and
  types already carry many preconditions. They wait for what remains in doc
  comments after the steps.
- **Index and single-entry forms of `-doc`.** The interface file and grep
  cover what an agent needs.
- **A checked list of a package's main entry points.** The overview's checked
  references cover it.

The steps are in priority order, and each is usable without the next.

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
   triple must not imply support for its ABI or runtime. The C runtime is one
   of these choices: an executable links the static one
   ([C runtime](compiler-guide.md#c-runtime)), and a static library that ships
   only for the dynamic one draws `L0755`. A dynamic-runtime option would
   build the runtime's cached objects for that runtime, keep the static one as
   the default, and turn the warning around; it can ship before the target
   boundary once such a library is a real need.
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

**Numerical certification for each target.** `core:math/repro` promises the
same bits only where its corpus, the oracle, and `examples/lockstep.loke`'s
hashes have run, so each target is listed as certified only after they pass
there. Record by test the floating-point environment each OS gives a new
process and thread, and add setup only where it differs from
[Floating-point operators](design.md#floating-point-operators): MXCSR's
rounding, FTZ, and DAZ on x64, FPCR on ARM64. Linux and macOS use the same
Loke kernels, never glibc's or Apple's `libm` results; ARM64 has hardware FMA
and its own SIMD conformance to check; 32-bit ARM is a separate target.
WebAssembly needs its own architecture and host target (WASI or a browser),
software FMA where the target lacks an exact one, never relaxed SIMD's
multiply-add, and runs on several independent engines, since baseline Wasm
leaves NaN bits to the engine
([WebAssembly nondeterminism](https://github.com/WebAssembly/design/blob/main/Nondeterminism.md)).
Cross-target tests compare numerical results, not object layout or native
`int` serialization.

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

## Retiring the earlier spellings

`lokec -migrate` and the parser's recognition of a record's in-type attributes,
`move_only struct`, and `&mut a[lo:hi]` exist so that code written for 0.9 can be
rewritten. Delete them, with `L0750`, `L0751`, and `L0752` left unused, after a
later minor release.

## Decided, waiting for a caller

These were open questions whose answer is "not yet". Each says what would be
built and which caller or measurement would start it; none is scheduled, and
[Standard-library maturity](#standard-library-maturity) lists the smaller gaps
of the same kind.

### JSON designs

[`core:encoding/json`](standard-library.md#coreencodingjson) implements the
fully validating document parser and streaming writer; the evidence it still
needs is in [Standard-library maturity](#standard-library-maturity). These
designs wait for a caller or a measurement:

- **An event decoder.** When a caller needs one, it would share the scanner's
  token recognition and grammar transitions over contiguous input, with
  `next -> Result(Option(Event), Parse_Error)` and a `skip_value` that
  validates what it skips, consumed through a
  [fallible-source loop](standard-library.md#streaming-a-fallible-source). Borrowed
  decoded text would last until the next step, and a successful decode would
  require consuming the end or calling a `finish` that validates the rest: a
  valid prefix alone is not a validated document.
- **An on-demand cursor or a SIMD structural index.** Either may beat the scalar
  scanner on large input, but their navigation and validation guarantees differ
  ([simdjson's paper](https://arxiv.org/abs/1902.08318), [on-demand design
  constraints](https://simdjson.org/api/3.0.0/md_doc_ondemand_design.html)).
  Neither is established as better for 2 to 64 KiB state files, and either would
  stay separate from fully validating document parsing.
- **Avoiding repeated validation and copies.** `parse` validates UTF-8 and then
  scans; a fused scanner would need a trusted validated-view operation and a
  decision about keeping invalid UTF-8 ahead of every other error. `stringify`
  validates and copies its finished bytes; a consuming bytes-to-string
  conversion could avoid that, as retained owned bytes could avoid the copy in
  an owning file load. Any such operation must preserve [borrow
  provenance](design.md#procedure-result-contracts), allocator ownership, and
  [string invariants](design.md#string-type); `unsafe.string_view` still
  validates. Evaluate one only if profiling makes the cost material.
- **Typed record codecs.** Reflection-based encoding and decoding need explicit
  contracts for field names, missing versus null members, duplicates, numeric
  ranges, and union mappings before an API is chosen. A mutable document,
  automatic object indexes, and chunked input likewise wait for callers.
- **Faster repeated access.** A direct child index or an explicit object index
  pays only if repeated random access outweighs its build time and memory, and
  `validate_unique_keys` waits for a protocol that requires globally unique
  keys.

### Named time zones

Converting in a zone chosen by name, such as `Europe/Stockholm` in 1950, needs
the IANA time-zone database. Good C libraries exist for it. The hard part is
the data, which changes several times a year, and a stale copy gives wrong
local times without any error.

| Route | Data and its updates | Cost |
| --- | --- | --- |
| ICU in Windows (`icu.dll`) | IANA data in the OS, kept current by Windows Update | A handful of `ucal_` calls, UTF-16 zone names. Windows 10 1903 and Server 2022 or later. Windows only. MSVC's `std::chrono` zones use it. |
| IANA `tzcode`, public domain | TZif files: `/usr/share/zoneinfo` on Linux and macOS, none on Windows | Vendored C. Thread-safe through `tzalloc`, `localtime_rz`, and `mktime_z`. On Windows we would ship tzdata and follow its releases. |
| A TZif reader in Loke (RFC 9636) | The same files as `tzcode` | A few hundred lines of Loke, and the same data problem on Windows |
| Windows' own zones | The registry, kept current by Windows Update | Windows names (`W. Europe Standard Time`), not IANA's, and history only where Microsoft recorded it |

The recommendation is to leave named zones out until a caller needs them. When
one does, use the data each system already keeps current: ICU on Windows, the
system's TZif files elsewhere. Never ship a copy of tzdata with the compiler.
`Zone` then gains a named variant holding shared, immutable rules, so it stays
copyable, and nothing already in the package changes.

### Smaller points in `core:time`

- **Calendar durations.** `P1Y2M3D` has no type; `add_months` and its siblings
  do the arithmetic. A `Period` type waits for a caller that stores or parses
  one.
- **The system zone's name.** Windows names its zones its own way, and the
  IANA name needs CLDR's mapping, which ICU has, so a `Zone` has no name. A
  caller that shows one, or records the zone beside a time, would need it.

### More random generators and distributions

ChaCha would give a seedable cryptographic generator, and belongs with a
`core:crypto`. A counter-based generator such as Philox would give random
access into a stream. Floyd's sampling of indices from a range without
materializing it needs a set. `f32` distributions would need their own
ziggurat tables. The remaining candidates are listed in
[Standard-library maturity](#standard-library-maturity).
None is added until a caller needs it.

### Longer seeds

`from_seed` takes 64 bits, which is enough to name a run but not to reach
every state; `from_state` takes all 256. A seed sequence in the style of numpy's
`SeedSequence`, hashing seed material of any length into a state, would sit
between them, for a caller that needs one.

### Bit field extract and deposit

`pext` and `pdep` exist only from `x86-64-v3`, so
[`core:math`'s integer bit operations](standard-library.md#integer-bit-operations)
would need a portable fallback with the same result. They wait for a caller
that settles that contract.

### Thread-affine strings

`string` is an owning value whose copies share immutable backing storage, and
a string may be dropped on any thread that received it, so the shared handle
count is atomic: [`runtime/text.c`](../runtime/text.c) retains with a relaxed
atomic add and
releases with an acquire-release atomic subtract, each behind an out-of-line
runtime call. Nothing turns a `string` copy into a move, since copying it
cannot allocate, so this is the most frequent hidden cost in ordinary code.
Measured on 2026-10-28 at `-opt=speed` on an Intel i5-9600K, one uncontended
copy and drop of a heap-backed string costs about 12.5 ns regardless of
length, of which about 4 ns is the two calls and the owner check (a literal or
empty string pays only that) and about 8.5 ns is the two atomic operations; a
24-byte struct copy costs under 0.3 ns, and an allocating copy of 16 bytes
about 65-70 ns. Contended counts, where cache-line traffic dominates, have not
been measured. Atomic accounting does not make an arbitrary allocator
thread-safe; a string that crosses threads still asserts that its bound
allocator may deallocate on the receiving thread.

A thread-affine string with a non-atomic count would be a distinct type rather
than a silent weakening of the guarantee, and would save at most the atomic
part of the cost above. It is not needed now: Windows x64 is the only target,
so copy-always for a target without atomics is not a live constraint, and no
workload in the repository is bound by string copies. Revisit when a profile
shows `string` retain and release on a hot path, when contended counts are
measured, or when a freestanding target is added, since that decides whether
`string` is usable unchanged there.

## Open language questions

[open-questions.md](open-questions.md) remains the canonical backlog for possible
language changes. A roadmap workload may establish a need, but implementation
starts only after the proposal's semantics and migration are decided. Keep the
specification, grammar, implementation, tests, rationale, and release notes
consistent when such a change is accepted. This roadmap does not silently
promote every open question into a compiler task.

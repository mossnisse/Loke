# Future plans

The v1 language design is complete, and the compiler implements it. Any
divergence found later is recorded in [known-gaps.md](known-gaps.md) and fixed
as v1 work, not treated as a future language extension.

Later work should extend the existing architecture without weakening
diagnostics, semantic consistency, and reproducibility. Each
initiative below should receive a detailed implementation plan when work begins.

## Continuous integration and releases

Make the existing Windows build and test process reproducible before multiplying
it across more hosts. A release is the compiler together with the `base/`,
`core/`, and `runtime/` trees it discovers beside itself, not a standalone
`lokec.exe`.

Main work:

- define the v1 release gate as an empty known-gaps list, or document any
  intentionally accepted exception as a specification change;
- run citation checks, compiler tests, integration tests, layout checks, and the
  optimization matrix in CI on Windows x64;
- publish versioned release bundles containing the compiler and every required
  installation-relative component;
- verify a release from a clean machine or image rather than from a developer
  checkout;
- add a changelog, supported-version policy, upgrade notes, and a documented
  release checklist;
- record compile time, peak compiler memory, output size, and representative
  program performance so regressions are visible;
- extend the parser mutation fuzzer (`mutation_fuzzing` in
  `src/syntax_corpus_test.odin`) to the checker and diagnostic paths, and retain
  every discovered failure as a minimized test.

Done means a tagged revision produces a repeatable, installable bundle whose
tests pass in CI and whose version and compatibility expectations are clear.

## Tutorials

Create practical, beginner-friendly tutorials that teach Loke from the first
program through packages, foreign-function interfaces, and common application
patterns. Testing joins them once Loke has a test facility (see
[Standard-library maturity](#standard-library-maturity)). Keep every tutorial
executable and verified against the current compiler so examples cannot
silently become outdated.

Done means a new user can install the toolchain, learn the core language, and
build a small multi-package program by following the tutorials alone.

## Standard-library maturity

Complete the library capabilities required by real applications and by a
self-hosted compiler. Continue to add packages from concrete use cases rather
than creating a broad utility namespace. The open inventory and its design
constraints remain in [standard-library.md](standard-library.md).

Main work:

- implement process creation with explicit argument, environment, pipe, handle,
  and lifetime rules;
- provide the testing and binary/text facilities needed to express the compiler
  and its test harness in Loke;
- validate that the shipped collections, paths, filesystem, formatting, and
  allocation APIs scale to a compiler-sized program;
- prioritize `core:bytes`, time, random, buffered I/O, and higher-level encodings
  only when a concrete program establishes their contracts;
- add examples and allocator-failure, cleanup, Unicode, and platform-conformance
  tests with every new public API.

Done means ordinary command-line applications and the planned self-hosted
compiler need no private substitute for a missing foundational library service.

## Packages and dependencies

Turn the current explicit `-collection name=path` mechanism into a reproducible
project workflow without coupling source imports to one registry. Settle the
package and import versioning questions tracked in [comments.md](comments.md)
before freezing a manifest format.

Main work:

- define a project manifest, dependency identity, version-selection rules, and a
  lock format;
- preserve local path dependencies and explicit collection overrides for
  development and vendoring;
- specify cache layout, offline builds, checksums, and conflict diagnostics;
- decide how compiler, language, runtime, and standard-library versions declare
  compatibility;
- keep fetching and registry policy outside the compiler front end unless a
  concrete semantic requirement proves otherwise.

Done means two clean machines can resolve the same project to the same dependency
graph and build it without hand-written collection flags.

## Compiler services

Make the compiler usable as a long-lived service, not only as one command-line
run. Compilation is whole-program and single-process today
([compiler-architecture.md](compiler-architecture.md) "Deliberate v1
boundaries"); the language server, developer tools, and a self-hosted compiler
all need the same checked program without re-running everything.

Main work:

- separate the command-line driver from a reusable compilation session that owns
  source, package, and semantic state;
- add in-memory source overlays for unsaved editor buffers;
- cache per-package results and invalidate only the packages an edit affects;
- expose read-only semantic queries for symbols, types, definitions, references,
  signatures, and diagnostics, keyed by the existing semantic IDs;
- keep command-line compilation behavior unchanged.

Done means a long-lived process re-checks an edited package without rebuilding
unrelated packages, and `lokec` built on the same session produces the same
diagnostics and IR as before.

## Language server

Build an LSP server on the [compiler services](#compiler-services). It reuses the
real lexer, parser, package loader, and checker, and must not grow a second,
approximate Loke front end.

Main work:

- support diagnostics, hover, go-to-definition, completion, references, rename,
  document symbols, and signature help;
- keep partial and temporarily invalid programs responsive through the parser's
  existing recovery nodes and accumulated diagnostics.

Done means the server handles a multi-package workspace, updates after an edit
without rebuilding unrelated packages, and agrees with `lokec` on diagnostics
and name resolution.

## Debugging and developer tools

Add source-level observability once the compiler services exist. Debug
information is a separate backend consumer and should drive any durable
intermediate representation it actually needs.

Main work:

- emit source locations, procedure and local-variable information, and readable
  stack traces for debug builds;
- define a debug build mode separately from optimization and the compile-time
  `LOKE_DEBUG` value;
- preserve useful source locations through generated cleanup, specialization,
  and compile-time expansion;
- build a deterministic formatter over the real syntax tree;
- generate package API documentation from checked public declarations and their
  source comments;
- integrate formatting, documentation, and debugging metadata with editor tools
  without teaching them a second language front end.

Done means a developer can format a project, browse its public API, set a
source-level breakpoint, inspect ordinary locals, and obtain a Loke-oriented
stack trace from a debug build.

## Ongoing quality engineering

Treat correctness, diagnostic quality, and performance as continuing work rather
than a milestone that ends after v1.

Main work:

- record every compiler/specification divergence in
  [known-gaps.md](known-gaps.md) with its reproduction, fix those that can accept
  an unsafe program first, and move each fixed reproduction into the regression
  corpus;
- expand syntax, semantic, IR, run, trap, package, object-host, and foreign-ABI
  corpora whenever a bug or new feature exposes a missing boundary;
- test malformed and adversarial source without crashes, hangs, or unbounded
  diagnostic cascades;
- benchmark compilation before changing compiler representations for speed;
- keep generated IR and binaries inspectable enough to explain material size or
  performance regressions;
- test runtime and compiler code with the strongest practical sanitizers and
  platform diagnostics.

Done is continuous: every release has conformance, robustness, and performance
evidence comparable with the previous release.

## More platforms

Separate the currently Windows-specific target, ABI, runtime, standard-library,
and toolchain decisions, then add Linux and macOS targets. Target support should
be explicit rather than hidden behind host checks.

Main work:

- make target triples, scalar layout, calling conventions, object formats, and
  linker arguments target records;
- add an explicit target-selection interface and distinguish the build host from
  the program target throughout the driver;
- decide which target pairs support cross-compilation, how SDKs and sysroots are
  selected, and how target-specific foreign libraries are resolved;
- port runtime startup, arguments, panic/unwind, TLS teardown, atomics, and
  platform services;
- provide target-specific `core:os`, filesystem, terminal, and foreign bindings
  behind the existing public contracts, and run the same library conformance
  tests on every target;
- add cross-platform toolchain discovery, diagnostics, and target-aware artifact
  naming;
- run the same semantic, layout, IR, run, trap, package, and C-interop corpora on
  every supported target.

Done means one source program has the same specified behavior on Windows,
Linux, and macOS, with intentional ABI differences isolated behind target
interfaces and continuously tested in CI.

## Self-hosting

Reimplement `lokec` in Loke only after the compiler services and standard
library are sufficient for a compiler-sized program. The Odin compiler remains
the trusted bootstrap until the replacement is reproducible.

Main work:

- provide the library support needed for source management, diagnostics,
  collections, processes, paths, and binary/text output;
- preserve the current phase contracts and reuse the architecture described in
  [compiler-architecture.md](compiler-architecture.md);
- bootstrap stage 1 with the Odin compiler, build stage 2 with stage 1, and
  compare stage 1 and stage 2 behavior and artifacts;
- run the complete compiler and integration suites against both implementations
  during migration;
- retire the Odin implementation only after reproducible bootstrap, diagnostic
  compatibility, and release builds are proven.

Done means a released Loke compiler can build an equivalent compiler from
source, the second-stage build is reproducible, and no supported program depends
on the bootstrap implementation used.

## Open language questions

[comments.md](comments.md) is the canonical backlog for possible language
changes. Keep proposals there until a concrete use case and implementation plan
make them roadmap candidates; do not silently turn an open question into a
compiler task.

## Suggested order

1. Establish Windows CI, the v1 release gate, reproducible release bundles,
   compatibility records, fuzzing, and performance baselines.
2. Publish introductory tutorials while filling the concrete standard-library
   gaps those tutorials and real programs expose.
3. Define the reproducible package and dependency workflow, and finish the
   standard-library services required by a compiler-sized program.
4. Build the compiler services without changing command-line compilation
   behavior.
5. Build the language server, formatter, documentation generator, and debug
   information support on those compiler services.
6. Isolate target interfaces and add Linux, then macOS, with an explicit native
   and cross-compilation policy and one shared conformance corpus.
7. Begin self-hosting after the compiler services, package workflow, release
   process, and required libraries have stabilized.

Tutorial and standard-library work may overlap. The language server, developer
tools, and platform ports may overlap once the compiler services exist. Quality
engineering continues through every step. Self-hosting remains last because it
multiplies the cost of any compiler, runtime, library, or package interface that
is still moving.

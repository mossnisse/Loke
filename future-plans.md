# Future plans

The v1 language design is complete, and the compiler implements its intended
feature set except for the divergences recorded in [known-gaps.md](known-gaps.md).
Closing those gaps is part of completing v1, not a future language extension.

Later work should extend the existing architecture without weakening
diagnostics, semantic consistency, reproducibility. Each
initiative below should receive a detailed implementation plan when work begins.

## Correctness and conformance

Resolve every compiler/specification divergence in
[known-gaps.md](known-gaps.md), starting with problems that can accept an unsafe
program. Keep each entry's reproduction while the issue is open; once fixed,
move it into the permanent regression corpus so the divergence cannot return.

Main work:

- fix each new divergence as it is found, and add negative diagnostics and
  runtime coverage for the corrected case;
- keep `design.md`, diagnostics, implementation comments, and tests in agreement;
- define the v1 release gate as an empty known-gaps list, or document any
  intentionally accepted exception as a specification change.

Done means the shipped compiler agrees with the normative v1 specification for
the complete conformance corpus and no known unsafe divergence remains.

## Continuous integration and releases

Make the existing Windows build and test process reproducible before multiplying
it across more hosts. A release is the compiler together with the `base/`,
`core/`, and `runtime/` trees it discovers beside itself, not a standalone
`lokec.exe`.

Main work:

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
- add deterministic fuzzing for the lexer, parser, and diagnostic paths, and
  retain every discovered failure as a minimized test.

Done means a tagged revision produces a repeatable, installable bundle whose
tests pass in CI and whose version and compatibility expectations are clear.

## Tutorials

Create practical, beginner-friendly tutorials that teach Loke from the first
program through packages, testing, foreign-function interfaces, and common
application patterns. Keep every tutorial executable and verified against the
current compiler so examples cannot silently become outdated.

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

## Language server

Build an LSP server that reuses the real lexer, parser, package loader, checker,
and semantic IDs. It must not grow a second, approximate Loke front end.

Main work:

- add in-memory source overlays for unsaved editor buffers;
- expose read-only semantic queries for symbols, types, definitions, references,
  signatures, and diagnostics;
- cache package state and invalidate affected packages after edits;
- support diagnostics, hover, go-to-definition, completion, references, rename,
  document symbols, and signature help;
- keep partial and temporarily invalid programs responsive through the parser's
  existing recovery nodes and accumulated diagnostics.

Done means the server handles a multi-package workspace, updates after an edit
without rebuilding unrelated packages, and agrees with `lokec` on diagnostics
and name resolution.

## Debugging and developer tools

Add source-level observability after the compiler-service boundary exists. Debug
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

- expand syntax, semantic, IR, run, trap, package, object-host, and foreign-ABI
  corpora whenever a bug or new feature exposes a missing boundary;
- test malformed and adversarial source without crashes, hangs, or unbounded
  diagnostic cascades;
- benchmark incremental and whole-program compilation before changing compiler
  representations for speed;
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

Reimplement `lokec` in Loke only after the compiler-service boundaries and
standard library are sufficient for a compiler-sized program. The Odin compiler
remains the trusted bootstrap until the replacement is reproducible.

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
compiler task. The question below is recorded here because its implementation
consequences have already been investigated in detail.

Nominal conformance was considered while file-scope `static_assert` was added
and deliberately left out. It is not an unfinished part of that work: the
structural interface model is complete without it, and it needs its own proposal
before any compiler change.

### Nominal conformance

An `implements Drawable(Circle);` declaration was proposed and rejected. With no
semantic force it is only a second spelling of `static_assert(Drawable(Circle));`
while suggesting a nominal relationship the language does not create.

It should be reconsidered only as a proposal in which it *has* force. That
proposal must define ownership and orphan rules, coherence, generic and
conditional conformances, conformances for built-in types, compatibility with
existing structural code, and whether a claim gates static satisfaction or only
`dyn` witness construction. Until then satisfaction stays structural, and a
file-scope assertion stays a check rather than a registry.

## Suggested order

1. Close the known v1 correctness and conformance gaps, converting every fixed
   reproduction into a regression test.
2. Establish Windows CI, reproducible release bundles, compatibility records,
   fuzzing, and performance baselines.
3. Publish introductory tutorials while filling the concrete standard-library
   gaps those tutorials and real programs expose.
4. Define the reproducible package and dependency workflow, and finish the
   standard-library services required by a compiler-sized program.
5. Extract a reusable, incremental compiler-service boundary without changing
   command-line compilation behavior.
6. Build the language server, formatter, documentation generator, and debug
   information support on those shared compiler services.
7. Isolate target interfaces and add Linux, then macOS, with an explicit native
   and cross-compilation policy and one shared conformance corpus.
8. Begin self-hosting after the compiler APIs, package workflow, release process,
   and required libraries have stabilized.

Tutorial and standard-library work may overlap once the v1 behavior is reliable.
The language server, developer tools, and platform ports may overlap once the
compiler-service boundary exists. Quality engineering continues through every
step. Self-hosting remains last because it multiplies the cost of any compiler,
runtime, library, or package interface that is still moving.

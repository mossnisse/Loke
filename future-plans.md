# Future plans

The v1 compiler and language are complete. Future work should extend the
existing architecture without weakening diagnostics, semantic consistency, or
the test corpus. Each initiative below should receive a detailed implementation
plan when work begins.

## Tutorials

Create practical, beginner-friendly tutorials that teach Loke from the first
program through packages, testing, foreign-function interfaces, and common
application patterns. Keep every tutorial executable and verified against the
current compiler so examples cannot silently become outdated.

Done means a new user can install the toolchain, learn the core language, and
build a small multi-package program by following the tutorials alone.

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

## More platforms

Separate the currently Windows-specific target, ABI, runtime, standard-library,
and toolchain decisions, then add Linux and macOS targets. Target support should
be explicit rather than hidden behind host checks.

Main work:

- make target triples, scalar layout, calling conventions, object formats, and
  linker arguments target records;
- port runtime startup, arguments, panic/unwind, TLS teardown, atomics, and
  platform services;
- provide target-specific `core:os`, filesystem, terminal, and foreign bindings;
- add cross-platform toolchain discovery and target-aware artifact naming;
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

Two extensions were considered while file-scope `static_assert` was added and
were deliberately left out. Neither is an unfinished part of that work: the
structural interface model is complete without them, and each needs its own
proposal before any compiler change.

### Interface value predicates

Interface parameters take types today. Admitting constant *values*, and an
interface-local `where` clause over them, would allow a bound such as
`size_of(Self) <= 8` to live in the interface rather than in every consumer.

The blocking problem is runtime polymorphism. `dyn I` satisfies `I` through its
forwarding slots, but a concrete type can satisfy a bound over its own size
while the two-word `dyn I` view does not, so a structural re-check of
`I(dyn I)` may contradict the witness the value carries. A proposal must decide
whether such a bound may mention the erased subject at all, whether a `dyn`
value is judged by re-evaluation or by its witness, when the bound is evaluated
during `dyn` formation and conversion, how the failure is reported, and how
value arguments are normalized, compared, displayed, mangled, and substituted
through composed interfaces and slots. It must also name the library or
language use case that an ordinary consuming `where` clause does not already
serve.

Implementation would have to audit every consumer of `Generic_Arg`, not only
witness keys: dynamic type keys, equality, display, composed-slot resolution,
and slot-call substitution all assume type arguments today.

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

1. Publish introductory tutorials for the existing language and toolchain.
2. Extract a reusable, incremental compiler-service boundary without changing
   command-line compilation behavior.
3. Build the language server on that boundary.
4. Isolate target interfaces and add Linux, then macOS, while retaining one
   shared conformance corpus.
5. Begin self-hosting after those APIs and libraries have stabilized.

The language server and platform ports may overlap once the compiler-service
boundary exists. Self-hosting should remain last: it multiplies the cost of any
compiler or library interface that is still moving.

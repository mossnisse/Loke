# Compiler architecture

This is the durable implementation guide for `lokec`. The normative language
definition is [design.md](design.md), the accepted syntax is
[grammar.md](grammar.md), and user-facing build instructions are in
[readme.md](readme.md). This document explains how the compiler is assembled and
where to make changes.

Loke v1 is a whole-program Windows x64 compiler written in Odin. It parses into
one AST, annotates that AST with semantic decisions, runs ownership and
provenance analyses over a disposable control-flow view, emits textual LLVM IR,
and invokes clang with a versioned C runtime. There is no durable MIR and no
second backend.

## Pipeline at a glance

```text
CLI and build configuration
        |
        v
source loading -> lexing -> parsing
        |
        v
package/import/when fixed point
        |
        v
declaration collection and signature preparation
        |
        v
body checking, overload resolution, CTFE, and monomorphization
        |
        v
ownership/lifecycle analysis -> whole-program borrow and region analysis
        |
        v
typeid freeze -> formatter discovery -> lifecycle snapshot
        |
        v
emission contract -> textual LLVM module
        |
        v
clang/NASM + versioned C runtime -> .exe or .obj
```

The important architectural seam is between checking and consumption. The
checker chooses symbols, overloads, conversions, map policies, lifecycle
operations, witnesses, and other runtime dependencies once. Compile-time
evaluation and LLVM lowering consume those recorded choices; they do not repeat
source lookup or repair incomplete semantic state.

## Driver and phase order

`main` in `src/main.odin` calls the file-private `run`, which seeds immutable
build configuration, collection roots, panic strategy, optimization mode, and
build mode before source discovery begins.

The normal compilation path is:

1. `compile_program` in `src/packages.odin` initializes semantic stores, loads
   `base:runtime`, loads the root package, reads the provider selections from
   its package-clause attributes, and adds the selected provider packages.
2. Package discovery runs to a fixed point. Each round rebuilds the selected
   `File.active_items`, discovers newly active imports, rejects import cycles,
   prepares package declarations, and evaluates file-scope `when` conditions.
   An unselected branch is parsed but has no semantic effect.
3. Once the graph is stable, package bodies are checked in dependency order.
   Generic instances and pending generic `impl` bodies are checked as concrete
   uses commit them.
4. Ownership analysis runs per concrete procedure while it is checked.
   `analyze_program_provenance` then settles each body's global write effects,
   computes cross-procedure result summaries, checks inferred callback
   contracts, and checks borrows, escapes, allocator regions, and reset effects
   over the completed program. `resolve_provider_factories` then resolves the
   selected providers' factory signatures, once every package has been checked.
   Last, diagnostics held aside during checking rejoin the list.
5. The driver validates the executable entry point and exported names. Then
   `finalize_semantics` freezes runtime `typeid` values, discovers the coherent
   formatter for each concrete type, and finalizes immutable
   lifecycle-operation records. Each step is idempotent.
6. `emit_package` calls `emit_llvm_module`, which first runs
   `validate_emission_dependencies` to reject an incomplete checked state before
   an emitter is allocated, then produces one textual LLVM module containing
   every package in deterministic dependency order.
7. `emit_package` writes the module and either stops at `.ll`, compiles a
   relocatable `.obj`, or links an executable with the C runtime and foreign
   inputs.

`-parse-only` and `-dump-ast` deliberately take a shorter path through source
loading, lexing, and parsing for one file. `-check-layout` stops after the
semantic closure passes and compares the compiler's layout facts with LLVM.

## Core representations and ownership

### Source and syntax

`Span` is a byte range into a loaded `Source`. Line and column numbers are
derived only when diagnostics are rendered. Every AST node has a span, including
recovery nodes, so later phases never need to reconstruct source locations.

Each parsed `File` owns a syntax arena. The parser keeps errors in the tree as
explicit error nodes and continues after synchronization points. Types and
expressions share the `Expr` node domain because constructs such as generic
applications and calls cannot always be classified from syntax alone.

### Stable semantic state

`Compiler` is the compilation-wide state owner. Identifiers, symbols, types, and
packages are referenced by `Identifier_Id`, `Symbol_Id`, `Type_Id`, and
`Package_Id`; AST annotations contain these stable IDs rather than pointers into
growable arrays. Semantic declarations, interned data, specialization records,
and frozen constants live in the compilation-lifetime semantic arena.

The symbol and type stores hold one allocation per entry, so a `^Symbol` or
`^Type_Info` from `symbol_of` or `type_of` stays valid while checking appends
more. `c.packages` is still a plain dynamic array: retain a `Package_Id` across
anything that may load a package.

### One annotated AST

There is no separate typed tree. `check.odin` and `check_expr.odin` annotate the
parsed AST in place with types, constants, value categories, place capabilities,
resolved symbols, chosen overloads, bound arguments, conversions, and lowering
tags. Backend code should consume these annotations instead of inferring
semantics from syntax.

`Expr_Call.operation` is a tagged `Call_Operation`: procedure calls, intrinsic
families, conversions, reflection, text operations, union construction,
extraction, and dynamic dispatch carry only their operation-specific metadata.
Symbol identity stays in `Expr_Base.resolution`; written arguments, bound
arguments, variadic packing, and evaluation order remain shared on the call.
Nil means unchecked, and syntax cloning clears the operation along with the
other checked annotations. LLVM call dispatch switches on the operation and
rejects an unchecked call instead of inferring its meaning from a symbol.

Struct literals retain resolved field indices in source order for both CTFE and
LLVM. Executable validation retains the entry procedure's `Symbol_Id`; emission
requires its registered name. Optional extraction reads the checked union's
failure-variant metadata to identify its success variant.

A generic specialization cannot reuse an already annotated template. It clones
the declaration through `ast_clone.odin`, installs concrete generic bindings in
the clone's definition-site scope, and checks the clone. Static `foreach` uses
the same cloning rule for each expansion.

### Disposable control-flow graphs

`cfg.odin` builds a per-procedure `Flow_Graph` whose blocks reference typed AST
nodes. It owns traversal, control-flow topology, and lifecycle events;
`cfg_provenance.odin` owns the provenance event vocabulary and construction,
including carrier projections, allocator regions, and call effects;
`global_effects.odin` records which globals a body writes.
The graph is an analysis view, not a lowering IR, built in one of three modes:

- `Lifecycle` records initialization, move, drop, cleanup, and control-flow
  events used by `lifecycle.odin`, and is the only mode that reports;
- `Prov_Summary` and `Prov_Diagnose` rebuild the same topology without mutating
  settled lifecycle annotations and record the event stream consumed by
  `borrow.odin`: the first while result summaries settle, the second to check
  each body.

Every concrete body gets a fresh graph per mode, and one per summary round, in
the analysis arena; each is discarded after its analysis. A provenance build
with allocator-region facts is repeated, seeded with the previous pass's
facts, until they stop growing: the facts are flow-insensitive, but each pass
reads them as it walks, so a later write reaches an earlier read only on the
next pass. Building a provenance graph reports nothing and writes no compiler
state, so a repeat is safe; what a build finds, such as `thread.spawn` calls,
stays on the graph for its caller to take. LLVM lowering still
walks the annotated AST directly.

### Allocation domains

- Source buffers and diagnostics use ordinary process-owned storage. A
  diagnostic's strings come from the allocator its list was first grown with,
  so one raised during emission is still freed correctly.
- Each parsed file owns its AST arena.
- Compilation-wide semantic stores use the semantic arena, and so does cloned
  syntax: generic instances and static `foreach` copies.
- Ownership and provenance analysis use the analysis arena, reset after each
  body, so no flow graph outlives its analysis.
- Each CTFE invocation has bounded scratch storage for frames, mutable values,
  strings, big integers, and containers. Values that escape evaluation are
  frozen into semantic storage.
- LLVM strings and temporary maps belong to the emitter invocation and never
  become semantic annotations. Emission, `-check-layout`, and the toolchain run
  on the compilation's emission arena, freed by `destroy_compilation`.

## Semantic architecture

### Package preparation and source selection

Packages are directory identities. Imports form a dependency DAG, and package
order is a deterministic post-order traversal of that graph. `when` selection
is structural: only `File.active_items` may be collected, checked, or emitted.
Conditional imports are why package discovery, declaration preparation, and
compile-time evaluation cooperate in a fixed point rather than running once in
a simple sequence.

`base:runtime` is loaded before user code because `Unit`, `Option`, `Result`,
`Shared`, `Weak`, and `try_shared` are ordinary Loke declarations whose
identities the compiler uses. `bootstrap.odin` binds those declarations into the predeclared
universe instead of synthesizing lookalikes; `Shared` and `Weak` are bound as
`shared` and `weak`, and a call `shared(value)` resolves to `shared_construct`.

### Checking and overload resolution

`check.odin` owns declarations, signatures, statements, scopes, and type syntax.
`check_expr.odin` owns expressions, contextual typing, conversions, place
capabilities, and leaf folding. It dispatches calls to `check_calls.odin`, which
owns call checking, argument binding, and explicit call-form conversions. An
expected type flows down into untyped constants, implicit enum members, `nil`,
and typeless composite literals.

All named groups, methods, user operators, `init` conversions, and indexing
share the candidate engine in `overload.odin`. Feature modules form candidates
and validate their special rules; overload viability, conversion vectors,
tie-breakers, and ambiguity reporting remain centralized.

Hypothetical interface and overload checks increment `Compiler.speculation_depth`.
They may inspect or annotate cloned syntax, but they must not enroll generic
bodies, witnesses, materialized globals, type IDs, or backend helpers in the
final program.

Rolling back a check removes only its diagnostics, so **any check whose
diagnostics may be truncated runs with `speculation_depth` raised**. Report-once
caches (map-key and sort-order policies, validated attributes) and hoisted
procedures are gated on it; a rollback outside speculation lets a cache record a
report that no longer exists. The one sanctioned commit from inside speculation
is `ensure_proc_typed_for_eval`, which checks a body for compile-time execution
at depth zero and holds that body's diagnostics aside (`hold_diagnostics`), so a
later rollback cannot take them. Held errors are left out of `error_count` until
`release_held_diagnostics` returns them at the end of `compile_program`.

A call usually probes a generic instance's `where` bounds speculatively first.
Committing that instance's body checks the bounds again at depth zero, so what a
holding bound reports, such as a deprecated call, is not lost with the probe.

### Compile-time execution and generics

Simple constant semantics live in `const_ops.odin` and are shared by the checker
and evaluator. `eval.odin` is a tree-walking interpreter over already typed AST;
it adds frames, mutation, calls, loops, containers, and `defer`, but it is not a
second type checker.

Generic procedures and records are monomorphized. `generic.odin` owns template
recognition, inference, specialization, `where` evaluation, instance caching,
and body commitment. Lookup inside an instance is definition-site lookup, so a
caller's local extension cannot change the meaning of a specialization.

### Ownership, lifecycle, and provenance

Managed values have language-defined clone, move, and drop behavior.
`hooks.odin` classifies types and records canonical lifecycle operations;
`lifecycle.odin` assigns copy obligations, tracks liveness, diagnoses invalid
uses, and determines cleanup slots. Liveness follows every local, because a
local starts dead and definite initialization is checked for all of them; only
a managed one also carries a scope-exit cleanup obligation. Normal exits and
panic unwind consume the same settled cleanup facts.

`borrow.odin` runs two related dataflow analyses over provenance events:

- root provenance follows which storage a slice, text view, `any_view`, `dyn`,
  pointer-like result, or aggregate carrier borrows and checks exclusivity,
  invalidation, retention, and escape;
- region provenance follows allocator identity through owners and borrows and
  proves that values do not escape or survive an allocator reset.

Procedure result summaries, the regions each body may leave in the arguments
it writes, and escape levels carry these facts through direct, generic, and
indirect calls. A call also counts as a write to every global its
callee may write, settled over the whole program first. What these analyses
trust rather than check is listed under "Deliberate v1 boundaries".

### Closed semantic registries

Several semantic choices are compilation-wide records rather than facts to
rediscover during lowering:

- map key and ordering policies store exact operation `Symbol_Id`s;
- generic bodies are checked and enrolled in their defining package;
- materialized constants store their definition and immutable value;
- erased interface witnesses store concrete slot targets;
- runtime type identities are requested symbolically and numbered by
  `freeze_typeids`;
- formatter discovery selects one coherent formatter per concrete type;
- lifecycle finalization snapshots clone/drop classification and hook IDs.

`emission_contract.odin` verifies that these registries are closed and mutually
consistent. It never invokes the checker or fills missing state. Local emitter
assertions remain a second line of defense, and failed emission returns no
partial module.

## Runtime and library boundary

The repository has three implementation layers outside `src/`:

| Location | Role |
| --- | --- |
| `base/` | Foundational Loke declarations needed by the compiler itself: runtime result/option/shared types, reflection metadata, and structural interfaces. |
| `core/` | The standard library written in ordinary Loke: formatting, memory, containers, strings and string conversion, I/O, logging, filesystem and paths, OS, terminal, synchronization, SIMD helpers, math, encoding, and related packages. |
| `runtime/` | The versioned C ABI for allocation, arenas, process arguments, atomics, managed containers, failure, panic, formatting, and text storage. `loke_rt.h` is the ABI contract. |

The rule is to keep a feature in Loke source whenever the language can express
it. `stdlib.odin` contributes only identities or primitives the compiler already
owns or that Loke cannot express, such as atomic instructions, erased formatting
dispatch, allocator-aware string allocation, and selected provider access.

An executable build links the generated module with the compiled C runtime.
`prebuilt_runtime_objects` keeps one object set per optimization mode under
`runtime/prebuilt/<mode>/` and recompiles it only when a `runtime/*.c` or
`*.h` is newer than a cached object, so the first build after editing
`runtime/` is slow by design and the rest are not. An object build emits one
relocatable compiler module and leaves its runtime and foreign references for
the host to supply.

## Source-code map

All Odin files under `src/` belong to the same `lokec` package. The file split is
for ownership and navigation, not separate package APIs. Helpers shared by
subsystems are package-private; a helper used only within one component should
be file-private.

### Driver, source, and syntax

| Files | Responsibility |
| --- | --- |
| `main.odin`, `build_config.odin`, `providers.odin` | CLI options, build constants, provider selection, top-level phase order, and exit codes. |
| `stack.odin` | The 64 MB compiler stack reservation that bounds nesting (`MAX_NEST`) and compile-time recursion. |
| `install.odin`, `packages.odin`, `select.odin` | Installation-relative roots, package loading/import graph, dependency order, and `when` selection. |
| `source.odin` | `Compiler`, source buffers, spans, and the diagnostics engine. Start here when locating global state; `destroy_compilation` is `semantic.odin`'s. |
| `lexer.odin` | Tokens and lexical scanning. |
| `parser.odin`, `ast.odin`, `ast_dump.odin` | Recursive-descent parsing, syntax node definitions, error recovery, and deterministic syntax dumps. |
| `semantic.odin`, `universe.odin` | Stable IDs, symbols, types, scopes, packages, type interning, and predeclared names. |

### Checking and language features

| Files | Responsibility |
| --- | --- |
| `check.odin`, `check_expr.odin`, `check_calls.odin`, `check_builtin.odin` | Main checker: declarations/statements/type syntax, expression dispatch/conversions/folding, call checking/argument binding, and compiler-owned primitive call contracts. |
| `bigint.odin`, `const_ops.odin`, `zero.odin` | Exact integer constants, shared constant operations, zero-value rules, and required-result classification. |
| `overload.odin`, `impl.odin`, `operators.odin`, `customization.odin` | Candidate ranking, methods/extensions, operators/delegates, and the built-in `len`/`cap`/`hash` receiver members. |
| `attributes.odin`, `abi.odin`, `foreign.odin`, `layout.odin` | Attribute validation, foreign ABI safety and Win64 classification, foreign declarations/imports, and canonical layout. |
| `enums.odin`, `union.odin`, `optional.odin`, `erased.odin` | Closed enum validation, tagged unions, checked extraction/failure protocol, `any_view`, `dyn`, and witnesses. |
| `slice.odin`, `container.odin`, `text.odin`, `simd.odin`, `atomics.odin` | The slice type, its shared ABI type and queries; managed-container, text, SIMD, and atomic semantics, and the member tables of the built-in carriers. |
| `hash.odin`, `format.odin`, `iterate.odin` | Contributed hashing, coherent formatting, ranges, `foreach`, and iteration protocol support. |
| `iteration_adapters.odin`, `iteration_mutable.odin`, `iteration_yield.odin` | Fallback `indexed`/`reversed`/`copied` adapters, peeled so `foreach` lowers directly; mutable lending over arrays, dynamic arrays, mutable slices, and maps, and the `iter_mut` protocol check; and the yield modes, derived from `next`, that decide whether a loop binding owns, borrows, or mutably borrows each part. |

### Generics, compile-time features, and bootstrap

| Files | Responsibility |
| --- | --- |
| `ast_clone.odin`, `generic.odin` | Clean syntax cloning, generic inference, specialization, monomorphization, and instance caches. |
| `interface.odin` | Typed interface arguments, interface-local predicates, structural requirements, and slot lookup contexts. |
| `eval.odin` | Bounded typed-AST interpreter for compile-time execution. |
| `expand.odin`, `reflect.odin` | Static `foreach`, reflection descriptors, `type_of`, `typeid_of`, and type-ID freezing. |
| `materialize.odin` | Read-only storage for address-requiring constants. |
| `bootstrap.odin`, `stdlib.odin` | Binding ordinary bootstrap declarations and contributing compiler-owned standard members without duplicating type identity. |

### Ownership and memory safety

| Files | Responsibility |
| --- | --- |
| `hooks.odin`, `lifecycle.odin` | Managed-type classification, lifecycle hooks, copy/move/drop checking, liveness, and cleanup slots. |
| `cfg.odin`, `cfg_provenance.odin` | Disposable control-flow topology and lifecycle events; provenance event construction, carrier projections, allocator regions, and call effects. |
| `proc_contracts.odin` | Inferred callback result contracts, checked substitution bounds, and immutable borrow arguments. |
| `precision.odin` | Diagnostic metadata explaining bounded provenance merges without changing acceptance. |
| `borrow.odin` | Root loans, carrier paths, result summaries, escape contracts, allocator-region analysis, and diagnostics. |
| `global_effects.odin` | Whole-program global write effects: which globals each body, and each call through it, may write; and the L0707 warning for a `thread.spawn` entry that writes a shared global. |
| `nil_uses.odin` | Locals a body only ever writes `nil` to, reported at the use rather than left to the trap. |
| `region.odin` | `Arena`/`Scratch` semantic types. |

### LLVM and toolchain

| File | Responsibility |
| --- | --- |
| `emission_contract.odin` | Read-only validation of the checked-program boundary. |
| `emit_llvm.odin` | Module orchestration, emitter state, symbol names, procedures, globals, and instruction plumbing. |
| `emit_llvm_abi.odin` | LLVM type spelling and foreign signatures, arguments, and returns. |
| `emit_llvm_stmt.odin` | Statements, control flow, local bindings, assignment, and returns. |
| `emit_llvm_expr.odin` | Constants, places, scalar expressions, comparisons, and text operations. |
| `emit_llvm_calls.odin` | Resolved calls, argument packing, conversions, allocation built-ins, and erased dispatch. |
| `emit_llvm_cleanup.odin` | Lifecycle clone/drop, cleanup registration, and panic replay. |
| `emit_llvm_containers.odin` | Container operation tables, construction, synthesized element/key bodies, and typed-comparator sort adapters. |
| `emit_llvm_iteration.odin`, `emit_llvm_adapters.odin` | Built-in iteration, iterable adapters, and synthesized iterator bodies. |
| `emit_llvm_atomics.odin`, `emit_llvm_simd.odin` | Atomic instruction/fallback lowering and LLVM vector lowering. |
| `emit_llvm_runtime.odin` | Runtime declarations, reflection metadata, formatting tables, globals, and witnesses. |
| `emit_llvm_toolchain.odin` | `.ll`/`.obj`/`.exe` artifact policy, clang/NASM discovery and invocation, foreign inputs, and layout probes. |

`emit_llvm_module` is an artifact boundary: it consumes a checked compilation
and returns module text in memory. It creates no types or symbols; the only
semantic state it writes is the layout cache `layout.odin` shares with the
checker. Filesystem and process policy
belongs in `emit_llvm_toolchain.odin`. Backend names and temporary values belong
to `Emitter`, never to semantic symbols. No non-test backend file
(`emit_llvm*.odin`, `emission_contract.odin`) names `Checker`; `test-all.ps1`
enforces this.

Implicit conversions use `emit_expr_at` with an explicit effective type; address
and value helpers carry that type without changing the checker's AST annotations.
Child expressions continue to use their own checked types.

A value larger than `LARGE_VALUE_BYTES` never becomes an LLVM first-class value,
because clang crashes on one with 65536 or more scalars in it. Such a value is
instead the address of storage that nothing else writes. It travels by pointer,
and it is returned through a leading `ptr %sret`. Its temporaries are shared
between full expressions, so a function's frame holds what one statement needs.
Every load, store, call, and return of a Loke-typed value therefore goes
through the typed helpers: `load_place`, `store`, `temporary_slot`,
`emit_call_result`, `emit_ret`, and `sret_param`. A raw `store %s` or `ret %s`
of such a value is a bug.

## How to make a compiler change

Use the narrowest path that preserves the phase contracts:

1. If syntax changes, update `grammar.md`, tokens/lexer, AST nodes, parser, AST
   dump, `ast_clone.odin`, and syntax recovery fixtures together. A new node
   kind fails to compile until it has a clone case, but a new field on an
   existing node is silently dropped from every generic instance unless the
   clone copies it.
2. Settle the language decision in `design.md` first, then put it in the
   checker or the relevant semantic feature module. Record the chosen symbol,
   type, operation, conversion, or policy on the AST or in a semantic registry.
   Source comments cite design.md sections by heading (`design.md "Maps"`);
   `check-citations.ps1` fails on a heading that no longer exists.
3. If the feature works at compile time, implement its value semantics in
   `const_ops.odin` or its evaluator path in `eval.odin`; do not create a second
   checker inside CTFE.
4. If it affects ownership, borrowing, retention, or allocator identity, add a
   CFG/provenance event and update the corresponding solver. Do not infer these
   facts during LLVM emission.
5. If it adds a runtime dependency, register that dependency during committed
   checking and extend `validate_emission_dependencies` when an incomplete
   registry could otherwise reach lowering.
6. Lower the already resolved operation in the matching `emit_llvm_*` component.
   Keep layout in `layout.odin` and foreign ABI classification in `abi.odin`.
7. Prefer an ordinary implementation in `base/` or `core/` when the language can
   express the feature. Add a compiler contribution or C runtime primitive only
   for an actual language/runtime seam.
8. Add the smallest unit or corpus regression that would have caught the bug,
   then run the broader suite appropriate to its risk.

Useful navigation commands:

```powershell
rg "^[A-Za-z_][A-Za-z0-9_]* :: proc" src
rg "L[0-9]{4}" src tests
rg "resolution\.kind|chosen_overload|container_op" src
rg "Builtin_Kind|Synth_Kind" src
rg "@\(test\)" src tests
```

When debugging a backend failure, trace backward from the emitter assertion to
the AST annotation or semantic registry that should have been settled. The usual
fix belongs at that earlier boundary, not in a fresh backend lookup.

## Testing and verification

Compiler unit tests live beside the implementation:

- `front_end_test.odin` covers the lexer, parser recovery, package loading,
  semantic helpers, and hand-built packages;
- `bigint_test.odin` covers exact integer arithmetic;
- `carrier_test.odin` covers aggregate carrier shapes and provenance;
- `syntax_corpus_test.odin` runs the valid syntax corpus, the AST goldens and the parser mutation fuzzer in process;
- `emit_llvm_test.odin` checks emission contracts and structural backend rules.

The integration harness is `tests/corpus_test.odin`:

| Directory | Contract |
| --- | --- |
| `tests/run/` | Compile, execute, and compare stdout with `.expected`. |
| `tests/trap/` | Compile, require a failing process result, and match the panic report with `.expected-err`. |
| `tests/err/` | Match diagnostic count, codes, message fragments, and optional `@line:column` spans. Warnings the case's own sources raise are counted too, written as `warning[L0507]: ...`. |
| `tests/syntax_err/` | Parser recovery: diagnostics, and the file's trailing sentinel survives. (`tests/syntax/` is run in process by `syntax_corpus_test.odin`.) |
| `tests/ll/` | Require stable shapes in emitted LLVM IR, and require LLVM to accept the module. |
| `tests/layout/` | Compare compiler and LLVM layout. |
| `tests/pkg/`, `tests/pkg_err/` | Multi-package success and import/package diagnostics. |
| `tests/obj/`, `tests/os/` | C-host object linking, and real process arguments and environment values. |
| `tests/examples/` | Every program in `examples/` is built from its real source and must carry a classification; an output example's stdout is compared with `tests/examples/<name>.expected`. |

Every diagnostic code the compiler can write is pinned by a case in one of those
directories, or by a harness or unit test for the ones no corpus shape reaches
— a missing input, an unwritable module, an absent clang or assembler, a
malformed literal the lexer rejects. The
exceptions are the `UNPINNED` list in `tests/corpus_test.odin`: invariant guards
that no source can reach, and `require_const`'s fallback message, each with the
reasoning recorded at its site. `every_diagnostic_code_is_pinned` fails when a
new code arrives without either.

Common commands from the repository root:

```powershell
odin test src -vet-unused -vet-shadowing -vet-packages:lokec
odin build src -out:lokec.exe -vet-unused -vet-shadowing
odin test tests -define:ODIN_TEST_TRACK_MEMORY=false -vet-unused -vet-shadowing -vet-packages:tests
.\test-all.ps1
```

`odin test src` tracks every unit test's memory and reports leaks and bad
frees. For a whole compilation, build with `-define:LOKE_TRACK_MEMORY=true`,
which makes `lokec` print every allocation still live at exit, and every bad
free, on stderr. Test code is vetted with `-vet-packages`, because plain vet
also reaches Odin's own `core:testing` and fails there.

`test-all.ps1` checks design-document citations and backend layering, runs the
unit tests, rebuilds the compiler, runs the baseline corpus, and reruns every
test that honours `LOKE_TEST_FLAGS` (the run/trap corpus, multi-package
programs, and the examples) at every supported optimization level. Use
`-SkipOptimizationMatrix` for a quicker baseline check while iterating.

Three tests need a tool this repository does not ship — nasm, and a clang or MSVC
toolset to link a C host — and record what they skipped when it is absent. Pass
`-RequireTools` (or set `LOKE_TEST_REQUIRE_TOOLS=1`) on a machine that is
supposed to have them: the skips become failures, so the assembly link, the
object-build host link and the IR validation cannot go missing on a green run.

For a structural backend refactor, compare emitted `.ll` with the same source
path and options before and after the change. Reproducible IR catches naming and
ordering drift that successful execution may hide.

## Deliberate v1 boundaries

- Windows x64 is the only target and the foreign ABI follows its classification.
- The backend is annotated AST to textual LLVM; a durable MIR and direct native
  debug backend should be introduced only with a real second consumer.
- The compiler shells out to clang and NASM and links a versioned C runtime.
- Compilation is whole-program and single-process; there is no incremental or
  parallel package compilation.
- The compiler remains in Odin; v1 has no self-hosting path (future-plans.md
  sketches one).
- Debug information, non-Windows targets, recoverable panic, macros, owning type
  erasure, and a GC allocator are not part of v1.
- Raw-pointer provenance, `core:unsafe`, foreign retention/aliasing, and
  cross-thread transfer remain explicit trust boundaries.

These are boundaries, not hidden unfinished phases. Where the shipped compiler
does diverge from design.md, the divergence is recorded in
[known-gaps.md](known-gaps.md) with its own repro, not here. New
work should extend this architecture only when its consumer and semantic
contract are concrete. The next intended initiatives are summarized in
[future-plans.md](future-plans.md).

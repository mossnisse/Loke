# Compiler architecture

Loke keeps the existing pipeline: parsing, an annotated AST, ownership and
provenance CFG analyses, textual LLVM, then clang and the versioned C runtime.
Stable semantic IDs, common layout calculations, overload resolution, and
procedure provenance summaries remain shared infrastructure. There is no MIR.

## Phase contracts

The checker owns language decisions. Consumers use resolved symbols, bound
arguments, operation tags, and ownership annotations rather than resolving
source syntax again.

Map keys are an explicit example. `require_map_key_policy` selects a `Key_Policy`
once and records it in `Compiler.map_key_policies`. Its kind distinguishes a
builtin pair from an inherent hash/equality pair; the latter stores exact
`Symbol_Id`s. CTFE and the container LLVM thunks read that record. An absent
record is an internal contract error, not a request to repeat member lookup.
Failed lookups are not cached while discovery is still installing declarations.

Speculative interface and overload checks may annotate cloned syntax and cache
signatures, but do not commit generic bodies or register runtime artifacts.
Actually executing a CTFE helper is a real use: its persistent body is checked
with dependency registration enabled. A later real call can promote a previously
probed signature without inheriting a partially committed body.

`freeze_typeids` closes runtime type identity. Reusing an existing ID is allowed;
requesting a new one after freezing produces `L0405` without changing the set.
Before allocating an emitter, `validate_emission_dependencies` checks:

- Checking is outside speculation and typeids are frozen, complete, and unique.
- Committed generic bodies are checked and enrolled in their packages.
- Synthesized map bodies have resolved key policies and operation targets.
- Witness targets and materialized constant definitions are present.

This validates the registries, not every AST annotation. Local lowering checks
remain necessary, and a failed emission returns no module. The verifier does not
repair missing state or invoke the checker.

## Allocation ownership

Parsed files own syntax. The compiler's semantic arena owns IDs, declarations,
resolved operation records, and published constants. Each CTFE invocation owns
a separate bounded scratch arena for values, big integer arithmetic, strings,
frames, and container temporaries. `freeze` copies escaping constants into
semantic storage before scratch storage is released.

The evaluator's 64 MiB budget accounts for allocations, including conservative
resize charges; arena frees do not refund it. Step and call-depth limits are
separate. Exceeding a limit produces a diagnostic rather than runtime fallback.

## LLVM components

All backend components remain in the `lokec` Odin package. Shared implementation
helpers are package-private; helpers used by one component stay file-private.
This is a source-level separation, not a claim of isolated package APIs.

| File | Responsibility |
| --- | --- |
| `src/emit_llvm.odin` | Module orchestration, emitter state, symbol names, procedures, instruction plumbing |
| `src/emit_llvm_toolchain.odin` | Artifact paths and writing, clang/NASM, host discovery, executable layout probes |
| `src/emit_llvm_abi.odin` | LLVM type representation and foreign signatures, arguments, returns |
| `src/emit_llvm_cleanup.odin` | Cleanup registration, panic replay, lifecycle clone/drop |
| `src/emit_llvm_stmt.odin` | Statements, control flow, bindings, assignment, returns |
| `src/emit_llvm_expr.odin` | Constants, places, arithmetic, comparisons, text operations |
| `src/emit_llvm_calls.odin` | Resolved calls, argument packing, conversions, allocation builtins |
| `src/emit_llvm_containers.odin` | Operation tables, construction, synthesized container/provider bodies |
| `src/emit_llvm_iteration.odin` | Iteration lowering and synthesized iterator bodies |
| `src/emit_llvm_runtime.odin` | Runtime declarations, globals, formatting, reflection metadata, erased witnesses |

`emit_llvm_module` produces bytes in memory. `emit_package` in the toolchain
component writes those bytes and invokes external tools. Emission keeps names,
temporary counters, and cleanup state in `Emitter`, not semantic symbols.

## Extending this architecture

For a new operation, first record its semantic choice on the typed AST, symbol,
or a dedicated semantic record. Teach CTFE and LLVM to consume that choice, and
add a boundary check when it introduces a new runtime dependency. Keep ABI
classification in `abi.odin` and layout in `layout.odin`; backend files translate
those decisions into LLVM spelling.

This refactor establishes the pattern for map policies. Other paths, including
lifecycle hook lookup and some builtin dispatch, still deserve the same audit.
The backend components also still share one mutable emitter. Further separation
can proceed one operation or state owner at a time without replacing the AST.

## Verification

Use `odin test src -define:ODIN_TEST_TRACK_MEMORY=false` for compiler tests and
`test-all.ps1` for the compiler build, integration corpus, and optimization
matrix. Boundary tests deliberately remove registry entries and member-lookup
inputs; they check failures and consumers of resolved IDs.

For structural backend refactors, also compare emitted `.ll` bytes before and
after using the same source paths, build options, and fixture `.flags`. Identical
IR is a stronger check of a file split than successful compilation alone; the
integration suite separately exercises clang, the ABI, and runtime behavior.

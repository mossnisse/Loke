# M3 implementation plan — compile-time engine and packages

## Context

`compiler-plan.md` defines M3 as the compile-time engine milestone (B10). M3
replaces M2's compile-time shortcut with one typed-AST interpreter, then uses it
for compile-time procedure calls, `when`, conditional import discovery, array
lengths, enum values, `static_assert`, and `build_config`.

M2 deliberately left three seams for this milestone:

- one input file and one package (`m2-plan.md:454`);
- checker-local constant folding instead of the B10 interpreter
  (`m2-plan.md:456`); and
- no size/alignment/offset table (`m2-plan.md:451`).

The repository already has the pieces M3 should preserve: package/file storage,
stable symbol and type IDs, order-independent declaration collection, typed AST
annotations, `Big_Int`, `Const_Value`, immutable `Const_Aggregate`, and the
folding/conversion primitives in `check_expr.odin`. The LLVM backend still walks
the annotated AST directly; MIR remains deferred to M6.

This plan covers compiler implementation. It does not add a core library.
Collection prefixes, including `core:`, resolve only when the driver receives a
matching `-collection name=path` option.

## Scope

### In M3

| Area | Contents |
|---|---|
| Evaluator (B10) | Tree-walking interpreter over the typed AST: explicit frames, locals, mutation, `if`, `for`, `switch`, `defer`, `return`, recursion, direct and indirect calls, phase-neutral `assert`/`panic`, limits, sandboxing, and compile-time call-stack diagnostics |
| Compile-time contexts | Constant initializers, file-scope variable initializers, fixed-array lengths, enum values, `when` conditions, and `static_assert` operands, all routed through `require_const` |
| Built-ins | `size_of`, `align_of`, `offset_of`, and `len` for fixed arrays and compile-time strings |
| `#name` forms | `static_assert(condition[, message])` and `build_config(NAME, default)`, with `-define:NAME=VALUE` |
| Strings | Untyped compile-time string constants: concatenation, comparisons, `len`, configuration values, assertion/panic messages, and `when` conditions |
| `when` | Procedure and file scope, `else when`/`else`, no initializer, no introduced scope, and semantic checking/emission of only the selected branch |
| Packages (B5) | Directory packages, multi-file packages, relative imports, collection prefixes, import DAG and cycle paths, deterministic order, public/package visibility, and qualified selection |
| Conditional discovery | A staged fixed point that alternates import discovery, header checking, condition evaluation, and item activation until the package DAG is stable |
| Backend | Selection-aware AST emission, package-owned hoisted procedure literals, stable package-qualified symbol names, multi-package emission, and runtime trap lowering for `assert`/`panic` |

### Deferred after M3

| Deferred | Goes to |
|---|---|
| `source_location()`, `caller_location()`, and `runtime.Source_Code_Location` | M6, when runtime `string` and the seed runtime exist |
| Runtime string bindings, fields, parameters, and results | M6 |
| Temporary managed evaluator values such as dynamic arrays and maps | M5/M6 |
| `static foreach`, reflection, `where`, `$` parameters, `type_of`, and `typeid_of` | M4 |
| Foreign imports/blocks, `@(packed)`, foreign ABI layout, and `transmute` | M7 |
| Memoized evaluation and parallel/incremental package processing | Post-v1 |

## Decisions

| Area | Choice | Why |
|---|---|---|
| Fold ownership | Move checker-independent value operations into a shared constant-value module. Keep leaf/operator folding in the checker and let the interpreter call the same `fold_arithmetic`, `fold_comparison`, `convert_const`, `wrap_to_type`, and `zero_const` operations. | Untyped constant typing is contextual and already correct. M3 replaces the hand-written *procedure-evaluation shortcut*, not the checker's ability to annotate simple typed expressions while checking them. There is one operator table and one value semantics. |
| Constant entry point | `require_const(k, expression, context)` first checks/types the expression, accepts an already folded value, otherwise evaluates a typed call/expression, then publishes an immutable `Const_Value`. Failure names the runtime binding or forbidden operation that blocked evaluation. | Every required context gets the same diagnostics and never silently falls back to runtime. |
| Evaluation readiness | Add explicit declaration/procedure readiness states separate from the existing constant-cycle state. Before interpreting a call, `ensure_proc_typed_for_eval` checks its body on demand. Re-entering a declaration, signature, procedure body, or evaluation already in progress reports the corresponding dependency path. | Array lengths and enum values are resolved while signatures are built, before phase-3 body checking today. A typed interpreter cannot evaluate an unchecked body. Lazy readiness preserves forward references without pretending the current pass order already supplies a typed body. |
| Evaluator values | Use evaluator-owned mutable `Eval_Value` aggregates in a per-evaluation scratch arena. Freeze results into compilation-arena-owned immutable `Const_Value`/`Const_Aggregate` only when crossing back into semantic state. | Procedure locals may mutate, but published constants must not. |
| Frames | Use an explicit frame stack. Each frame initially maps `Symbol_Id` to an evaluator slot/value; switch to checker-assigned dense slots only if measurement justifies it. | Explicit frames make recursion limits and call-stack notes deterministic and avoid using the Odin call stack as a language limit. |
| Flow and defer | Evaluation returns `Normal`, `Break`, `Continue`, `Return`, or `Panic`. Each frame tracks active defers, runs them in reverse order on every exit, and preserves a pending return value before running them. | It mirrors checked control flow and the language's current runtime defer order. |
| Phase-neutral `assert`/`panic` | Add distinct builtin identities rather than treating every `Symbol_Kind.Builtin` as `print_int`. During evaluation, failed `assert` and every `panic` diagnose with the compile-time stack. At runtime, `assert` branches to the existing trap seam when false and `panic` always traps; messages must be compile-time strings in M3 and become runtime panic messages in M6. `panic` is non-fallthrough in checker flow and emission. | These are ordinary calls whose phase is chosen by execution. Supporting them only in the evaluator would make a normal procedure impossible to emit correctly; the current backend also treats every builtin as `print_int`. Trap lowering preserves M2's documented runtime-failure shortcut without requiring runtime strings. |
| Sandbox | On executed paths reject mutable file-scope reads/writes, `print_int` and builtins without compile-time meaning, runtime/foreign operations that become reachable, pointer-to-integer observation, and pointers escaping evaluator storage. Use one `L0341` diagnostic naming the operation. | The checks grow when later milestones make additional forbidden operations reachable. |
| Limits | Enforce documented step, explicit-frame depth, and scratch-memory ceilings. Exceeding one is `L0342` with the compile-time call stack. | Resource exhaustion is a diagnostic, never a request to generate runtime code instead. |
| Failure origin | The primary diagnostic points at the compile-time-required context; notes identify the failing `assert`/`panic` or limit and each evaluator frame. | The user first needs to know which required constant forced evaluation. |
| Strings | Keep `TYPE_STRING` runtime-gated. Untyped string constants and evaluator string values may be concatenated, compared, measured, and used as configuration or diagnostic messages, but may not be stored in runtime-representable bindings. | This enables M3 configuration and diagnostics without pre-implementing M6 ownership/runtime representation. |
| Layout ownership | Add `layout.odin` and cache natural size, alignment, and field offsets on `Type_Info`. Target-specific scalar/pointer layout comes from `Target_Info`; aggregate layout is computed from those cached facts. | Checker and backend must not develop independent language-layout models. Packed and foreign ABI layout remain M7. |
| Unevaluated layout operands | `size_of(type-or-expression)` and `align_of(type-or-expression)` use a dedicated checker path: an expression operand resolves and type-checks but is not evaluated, does not read storage, and does not require liveness. `offset_of(T, field)` resolves `field` as a member name, not a lexical value expression. | These operands inspect static type/declaration information. Passing them through ordinary argument evaluation or `require_const` would add side effects and reject valid dead-local uses. |
| Layout agreement | Add an executed test that compares every interesting M2 type's folded size/alignment/field offsets with LLVM GEP-derived values. Include empty/nested structs, arrays, pointers, enums, `f16`, and 128-bit integers. | Executing the LLVM-derived values tests the actual target backend rather than a second copy of the checker formula. |
| Selected source representation | Preserve parser-owned `file.items` and block statements for `-dump-ast`. Track top-level activation monotonically, then rebuild compilation-owned `file.active_items` in source order by flattening each selected branch at its surrounding position. Add a semantic `selected` result on each checked `Stmt_When`. All semantic top-level consumers—including declaration phases and LLVM emission—iterate `active_items`. Procedure checking calls `check_block` on the selected block without creating a scope; emission calls `emit_block_statements` on that same block without creating a scope. | Checking annotates the existing AST; it does not produce MIR or a second checked AST. A persistent selected view is therefore required to keep checking, flow/defer analysis, direct AST emission, and source-order determinism in agreement. |
| Unselected source | Unselected branches are parsed only. They are never declared, name-resolved, type-checked, gated, evaluated, assigned defer slots, or emitted. | This is structural source selection, not a constant `if`. |
| Package phase model | Give each package persistent phase/readiness state and scope. A discovery round: (1) loads unconditional imports, (2) marks unconditional/previously selected items active and rebuilds ordered `active_items`, (3) detects cycles in the current active import graph and processes its DAG dependency-first, (4) incrementally collects new declarations and nominal shells, (5) resolves only headers and lazily checks dependencies needed by ready `when` conditions, (6) activates the first true branch, and (7) adds newly selected imports. Repeat whenever an item or edge is added. Once stable, freeze the dependency order and perform final declaration/body checking once. | Re-running today's `check_package` would replace the package scope while declarations refuse to redeclare existing symbols. Final body checking before selection would also issue false unknown-name errors for declarations supplied by selected branches. Persistent monotonic phases avoid both failures, while per-round cycle detection prevents semantic checking from recursing through an already active package cycle. |
| Stalled conditions | A condition is pending only while it has an unresolved dependency that a future selected import could supply. If a round adds no item/import and pending conditions remain, emit one diagnostic per dependency component, including the condition path; a condition depending on an import inside its own branch is a self-bootstrap error. Ordinary type/evaluation errors are reported immediately, not treated as pending. | This makes the fixed point terminating and distinguishes an invalid condition from one waiting on package discovery. |
| Package input | A directory argument compiles all `.loke` files directly in that directory as the root package. A `.loke` argument retains the one-file-package behavior used by the existing corpus, though its relative imports still resolve from its directory. Imported directories always load all direct `.loke` files. | Existing one-file tests share directories and must remain independent programs. |
| Import resolution | An unprefixed path is relative to the importing file. `name:path` resolves under `-collection name=path`; there is no implicit `core:` root. Canonicalize paths before package identity comparison and reject a directory whose files disagree on package name. | Import aliases must not create duplicate package instances, and source-relative imports must work from every file. |
| Import symbols | Reuse `Symbol_Kind.Package_Alias` and `Resolution_Kind.Package`; store the target `Package_Id` on the alias symbol. `check_selector` handles package resolution before enum/type/value field selection and enforces visibility there. | The semantic model already distinguishes a package alias symbol from package resolution; adding a competing `Symbol_Kind.Package` would duplicate it. |
| Import cycles | Detect cycles over active import edges and report the ordered path of import statement spans. | The design requires a path, not a package-name set. |
| Visibility | Declarations are package-private by default. `@(public)` exports one declaration; `@(public)` on a package clause makes declarations in that file public by default; `@(private)` on a declaration opts out of that file default. Reject conflicting/duplicate visibility attributes and enforce access on qualified lookup. | Loke has package and public visibility, and the design explicitly permits the private opt-out. |
| Package-owned backend state | Move hoisted procedure literals from compiler-global reset-on-check storage to `Package.hoisted_procs`. Emit and name them with their owning package. Keep other package-specific selected/emission state on `Package` or `File`, not in a singleton overwritten by the next package. | `check_package` currently recreates `c.hoisted_procs`; checking a second package would otherwise discard literals from the first. |
| Symbol mangling | Derive a stable package key from the logical canonical import identity (root-relative or collection-relative), never an import alias or absolute host path. Mangle every user symbol and hoisted literal with that key. Only the selected root package entry receives the fixed executable entry name. Escape or hash characters that LLVM identifiers cannot safely carry. | Declared package names need not match paths and may collide. Absolute paths would make builds non-reproducible. |
| Multi-package emission | Emit one LLVM module in deterministic dependency order. Name all procedures before emitting any body, then emit types, constants/globals, procedures, and package-owned hoisted literals from `active_items`; emit the root entry wrapper last. | Cross-package direct calls and procedure values need final names before bodies are written. |
| Configuration | Parse `-define:NAME=VALUE` as boolean, integer, or string and reject duplicate definitions. `build_config` requires an identifier token plus a constant default of one of those kinds; an override must be representable as the default's type/kind. Seed the project-wide immutable table before package discovery. | Configuration must be available to the first file-scope `when` round and mean the same thing in every package. |
| Diagnostics | Reserve `L0327`–`L0339` for packages/imports/visibility, `L0340`–`L0349` for evaluation, and `L0386` onward for M3 builtins/`when`, after auditing current use. | Exact ranges keep fixtures stable and separate discovery from evaluator failures. |
| Package corpora | Add `tests/pkg/<case>/` and `tests/pkg_err/<case>/`; each case directory is passed as one root and may contain imported subdirectories. Extend `tests/corpus_test.odin` to enumerate case directories deterministically. | Multi-file/import behavior cannot be represented by the one-file corpus. |

## Steps

Each step ends with a built compiler and a green existing corpus. New behavior
gets an exact success or diagnostic fixture in the same step that enables it.

### 1. Evaluator core, readiness states, and phase-neutral failures

- Extract checker-independent constant operations from `check_expr.odin` without
  duplicating the operator table.
- Add declaration/signature/procedure/evaluation readiness states and dependency
  stacks. Implement `ensure_proc_typed_for_eval` so a call required by an array
  length, enum value, or earlier constant can type-check its body lazily.
- Add `eval.odin`: `Eval_Value`, scratch arena accounting, explicit frames,
  places/assignment, expression and statement dispatch, call binding, control
  flow, recursion, defer unwinding, and result freezing.
- Add `require_const` and route constant/file-scope initializers, array lengths,
  and enum values through it.
- Give builtins explicit identities. Add evaluator and runtime trap semantics for
  `assert`/`panic`; make runtime `panic` non-fallthrough. Keep `print_int`
  forbidden during evaluation.
- Add step/depth/memory limits, sandbox violations, origin diagnostics, and
  compile-time frame notes.

**Exit:** a recursive procedure with locals, mutation, loops, and defer computes
an array length even though its body would previously be checked after the type;
the same procedure can also be emitted for runtime use. Runtime `assert` and
`panic` take the trap seam. Runtime-binding, dependency-cycle, limit, sandbox,
and compile-time failure fixtures have exact non-cascading diagnostics.

### 2. Natural layout and layout builtins

- Extend `Target_Info` and `Type_Info` with the data needed for cached natural
  size/alignment/offset calculation; add `layout.odin`.
- Predeclare and check `size_of`, `align_of`, `offset_of`, and fixed-array `len`
  with distinct builtin identities.
- Implement unevaluated expression/type operands and member-name resolution for
  `offset_of`.
- Fold every result to `int` and ensure no layout builtin reaches generic
  `print_int` emission.
- Add the executed LLVM agreement corpus.

**Exit:** folded layout agrees with LLVM for the complete M2 type set. A
side-effecting expression passed to `size_of` is not evaluated, a dead local is
accepted as an unevaluated operand, and `offset_of` does not resolve its field as
a lexical variable.

### 3. Compile-time strings, `static_assert`, and `build_config`

- Fold untyped string concatenation, comparisons, and `len`; add evaluator
  string values without enabling runtime string storage.
- Check and evaluate `static_assert(condition[, message])` in every surrounding phase.
- Parse project-wide `-define:NAME=VALUE`, validate names/types/duplicates, and
  implement `build_config(NAME, default)`.
- Give `source_location()` and `caller_location()` a specific deferred diagnostic that
  points to M6 rather than the generic M2 gate.

**Exit:** defaults and overrides select different constants; false `static_assert`
reports its message; compile-time strings work in expressions and diagnostics;
attempted runtime string storage remains one `L0350`.

### 4. Selection views and `when`

- Add `File.active_items` and the persistent selected result for `Stmt_When`.
- Implement monotonic item activation for unconditional items, `Item_Block`, and
  file-scope `Item_When`. Rebuild the flattened view in original source order
  after activation; do not mutate parser-owned item lists.
- Implement procedure-scope `when` checking with no new scope and return the
  selected branch's `Flow_Info`.
- Make every current checker phase and every top-level emitter pass consume
  `active_items`. Add LLVM emission of the selected procedure block with no new
  scope.
- Verify selected-only defer slots, flow, diagnostics, and backend output.

**Exit:** unselected invalid code is ignored, a selected declaration is visible
and emitted, procedure `when` preserves surrounding scope and flow, and neither
file- nor procedure-scope `when` can reach the backend's old panic arm.

### 5. Unconditional packages and imports

- Extend the driver for directory inputs and repeatable `-collection name=path`.
- Load/canonicalize packages and files deterministically; retain one-file root
  behavior when the input is a file.
- Bind imports with `Package_Alias`, qualified selection, visibility checks,
  `@(public)` defaults, and `@(private)` opt-outs.
- Build the unconditional import DAG, report missing packages and cycle paths,
  and establish dependency order.
- Move hoisted literals to packages; implement stable logical-path mangling and
  multi-package selected-item emission.
- Add directory package success/error corpora.

**Exit:** a three-package diamond builds and runs; two same-named package
declarations from different logical paths do not collide; a package containing a
procedure literal emits it; private/public/default-private behavior, missing
collections/packages, and cycles have exact fixtures.

### 6. Conditional import fixed point and milestone audit

- Join selection and package discovery with the persistent package phase model:
  discover unconditional edges, reject cycles in the current active graph,
  process its DAG dependency-first, incrementally collect/resolve active headers,
  lazily check dependencies needed by conditions, activate ready branches, add
  their imports, and repeat.
- Delay final ordinary body checking until selection and the import DAG are
  stable. Ensure an unconditional body may refer to a declaration introduced by
  a selected file-scope branch.
- Implement stalled-condition dependency diagnostics and self-bootstrap
  detection separately from ordinary condition type/evaluation errors.
- Audit all package-global mutable state, all top-level `file.items` consumers,
  builtin dispatches, gates, diagnostic codes, and exact fixtures.
- Update `USAGE`, `readme.md` (including evaluator limits and collection/config
  syntax), and the M3 milestone record.

**Exit:** conditional imports extend the graph to a stable DAG; an active cycle
is reported as statement spans; self-bootstrap conditions terminate with a
specific error; selected declarations are usable from ordinary bodies; the full
verification below passes from a clean build.

## Verification

```powershell
odin test src -define:ODIN_TEST_TRACK_MEMORY=false
odin build src -out:lokec.exe
odin test tests -define:ODIN_TEST_TRACK_MEMORY=false
./lokec.exe examples/hello.loke -o hello.exe
./hello.exe
```

Milestone spot checks:

- A compile-time procedure checked on demand uses loops, locals, recursion, and
  defer to supply an array length and enum value.
- The same procedure is callable at runtime; runtime and compile-time
  `assert`/`panic` take their correct paths.
- `size_of`/`align_of`/`offset_of` agree with executed LLVM-derived values, and
  expression operands remain unevaluated.
- `build_config` overridden by `-define` selects a different `when` branch.
- An unselected branch containing type errors is not diagnosed or emitted.
- A selected procedure `when` affects flow/defer exactly as its in-place
  statements would.
- An ordinary body can reference a declaration activated by file-scope `when`.
- A conditional import extends the graph, and an active cycle is reported as an
  ordered path of import statements.
- `@(public)` on a package clause and a declaration-level `@(private)` opt-out
  are enforced across packages.
- Two packages with hoisted procedure literals and colliding source-level names
  emit distinct working symbols.
- Sandbox, limit, dependency-cycle, stalled-condition, and compile-time panic
  diagnostics carry the required origin and call/dependency stacks.

## Deliberate shortcuts

### M2 shortcuts M3 repays

| M2 shortcut | M3 replacement |
|---|---|
| No offset/alignment table | Natural target layout cache plus LLVM agreement tests |
| Single file and one package | Directory packages, imports, visibility, DAG processing, and multi-package emission |
| Hand-written constant evaluator | Shared constant operations plus the typed-AST interpreter and one `require_const` funnel |

### Shortcuts retained after M3

| Shortcut | Replaced when |
|---|---|
| Annotated AST lowers directly to LLVM; no MIR | M6 (B13) |
| Runtime `assert`/`panic` use the trap seam and do not print their compile-time-only messages | M6 seed runtime |
| Private aggregate call/result convention | M7 (B15), before foreign calls |
| Natural Loke layout only; no packed or foreign ABI layout | M7 (B15) |
| `print_int` remains the output stand-in | M6 `core:fmt` |
| Evaluator supports no temporary managed owners | M5/M6 |
| No built-in `core:` collection root or core library | M6 seed runtime/core library and build-system integration |

## Assumptions

- `design.md` and `grammar.md` are normative. Where this plan narrows a feature
  for milestone sequencing, the gate is explicit and non-cascading.
- Windows x64 remains the only code-generation target in M3, but layout data is
  target-owned rather than hard-coded independently in the checker and emitter.
- Parser AST node kinds are stable; M3 may add semantic annotations and
  compilation-owned selected views without changing syntax dumps.
- Package identity is a canonical logical import identity, distinct from the
  declared package name, import alias, and host absolute path.
- Package discovery is deterministic and single-threaded. Parallel and
  incremental compilation remain out of scope.
- No source edit in an unselected `when` branch is allowed to influence semantic
  state, diagnostics, symbol names, evaluator limits, or emitted code.

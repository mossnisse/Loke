# Third consolidation implementation plan: typed fallibility and one union model

Status: planned; no implementation or verification results are claimed here.

## Context

Steps 2 and 3 of
[`language-design-consolidation-proposal.md`](language-design-consolidation-proposal.md#13-proposed-migration-order)
have shipped. [`consolidation-phase-1a-plan.md`](consolidation-phase-1a-plan.md)
gave every destination-sensitive producer a fixed arity, and
[`consolidation-provenance-plan.md`](consolidation-provenance-plan.md) closed the
aggregate-provenance and call-contract gates needed before borrows move into
ordinary aggregates.

This plan evaluates and, only after a positive gate, implements proposal steps
4–6: named variants, typed fallibility, defaults, and migration of the complete
absence/failure corpus. Anonymous records and the general one-result-procedure
migration remain proposal step 7 and are out of scope.

The problem under evaluation is composability. Phase 1a made `(T, bool)` and
nil-status results predictable, but they are still result-list shapes rather
than values. They cannot be stored in a field, passed through an unconstrained
generic, or returned through a procedure value without recreating the trailing
status convention. Adoption reverses the current decision at
[`design.md:6418`](design.md#L6418), so the gate must record why that reversal is
worth its lifecycle, language, compile-time, and ABI cost.

## Gate discipline and settled prototype choices

The following choices define the typed-fallibility candidate. They are settled
for the prototype; the package as a whole is adopted or rejected at the gate.

1. **One named-variant union model after adoption.** Anonymous type-list unions,
   their nil state, type-based extraction, and implicit payload conversion are
   deleted only if typed fallibility wins. They do not persist beside named
   variants in a landed compiler.
2. **Structural operator recognition.** `or_else` and `or_return` accept any
   two-variant union whose declaration explicitly designates one failure
   variant. No declaration is privileged by name.
3. **`Result(T, E)` has no zero value.** Lack of a zero is a general type
   property. `Option(T)` has `.none` as its zero; `Result` must be constructed.
4. **The prototype is disposable until the gate passes.** Build steps 1–4 in a
   dedicated branch or worktree. If typed fallibility loses, discard those
   implementation changes without touching unrelated user work and land only
   the decision record. The existing anonymous-union/status model then remains
   the sole model. If it wins, steps 1–7 and the corpus migration land together;
   no released revision exposes two propagation protocols.

Consequences recorded up front:

- **`active_typeid()` is deleted on adoption.** A payload `typeid` cannot
  identify a variant when two variants have the same payload type. Switches and
  reflection use variant identity instead. Only
  [`tests/run/m6a_union_active_typeid.loke`](tests/run/m6a_union_active_typeid.loke)
  currently exercises the operation.
- **`.(T)` and `.as(T)` remain runtime type inspection for `any_view` only.**
  `.as(T)` changes result type to `Option(T)`.
- **No `()` spelling is added here.** `base:runtime` declares
  `Unit :: struct {}`. No-payload fallible operations return
  `Result(Unit, E)`; proposal step 7 may later make `()` sugar for the same type.
- **`Allocator_Error` keeps its representation and zero.** It loses only its
  status role. Migrated APIs return `Result(T, Allocator_Error)` and never use
  the nil error member as a returned status.

## Fixed language contracts

### Variants and identity

| Construct | Contract |
|---|---|
| `union {a: T, b: U}` | Every variant has a name unique within the union and an optional payload type. Every declaration contains a colon, including payloadless `a:`. |
| Variant identity | Each resolved variant has a stable declaration index/identity independent of its payload `Type_Id`. Two variants may carry the same payload type. Constructors, cases, reflection, equality, formatting, lifecycle lowering, and evaluation carry this identity rather than re-deriving it from the payload. |
| Construction | `.name(payload)` for a payload variant and `.name` for a payloadless variant. The explicit form is `U.name(payload)`. Payload variants take exactly one argument; payloadless variants take none and have no parentheses. |
| Payload ownership | Record-field initialization rules apply: a place argument clones and must be copyable; a temporary or `move(x)` transfers. |
| Inspection | `switch (p in u) { case .name: ... }`. Cases resolve to variant identities. The switch is exhaustive with no nil case. A grouped/default case leaves the binding at the union type; a payloadless single case binds `Unit`. |
| Switch ownership | A place subject borrows: its binding is immutable and non-owning, and cannot be moved or dropped. A temporary or `move(subject)` consumes; the active payload transfers into an owning binding or drops exactly once on every exit. `_` acquires no binding. |
| Layout | Variant index 0 has tag 0. There is no nil tag. The tag is the narrowest supported unsigned width representing `0 ..< variant_count`; 256 variants still fit in one byte, while 257 require two. An empty union retains the minimum one-byte tag representation. |
| Reflection | `Member_Kind.Union_Variant` entries carry variant name, payload type (or `Unit` for payloadless reflection), and declaration order. |

The semantic store must represent a variant as a record such as
`Union_Variant {name, payload, index}` (or an equivalent stable ID), not as a
bare `Type_Id`. Resolved constructor and switch-case nodes retain the variant
index so the emitter and evaluator never perform a payload-type lookup.

### Zero values and inert storage

Loke currently relies on every semantic zero value having an all-zero runtime
representation. Container growth, zero-initialized allocation, map insertion,
globals, and generated cleanup all depend on this. This phase preserves that
invariant rather than adding a per-type default constructor:

- `@(zero=name)` is valid only when `name` is the **first declared variant** and
  its payload is absent or itself has an all-zero semantic zero. Thus tag 0 plus
  a zero payload remains the all-zero representation. Designating a later
  variant is rejected.
- A named union without `@(zero=)` has no semantic zero. A named union whose
  designated payload lacks a zero also has no zero. The property propagates
  through structs, non-empty fixed arrays, and distinct types. A zero-length
  fixed array still has a zero because it contains no element.
- Dynamic arrays and maps retain their empty all-zero header regardless of
  element type. Capacity is raw storage, not a sequence of initialized values.
- `move` and `drop` may still clear a dead lexical source to an inert all-zero
  representation. For a no-zero type those bytes are not a live value and may
  never be observed or dropped. A custom drop hook for a no-zero type is called
  only on completed live initialization and need not accept `{}`.

Diagnose every operation that semantically manufactures a zero of a no-zero
type:

- `{}` and omitted aggregate field initializers;
- file-scope, `static`, and `thread_local` declarations without an explicit
  constant initializer;
- generic `T{}` after instantiation;
- `new(T)`, which promises a zero-initialized allocation;
- `make([dynamic]T, len=...)` when a written length is not compile-time zero,
  and any `resize` operation that can grow a `[dynamic]T`;
- a missing-key `map[K]V` read; and
- inserting place syntax rooted in `m[key]`, because the unchanged map policy
  first inserts a zero `V`, including `m[key] = value`.

`make([dynamic]T)` with its default zero length and `reserve` remain valid for a
no-zero `T`. A direct value-insertion operation such as `try_insert` must
construct the supplied value in unpublished raw storage and remains the way to
populate `map[K]V` when `V` has no zero; zeroed scratch bytes are not treated as
a live `V`. `lookup_value`, `find`, and `remove` return `Option` and therefore no
longer need to manufacture an absent payload.

Locals without initializers remain dead until full assignment. Explicit
constant variant construction is permitted at static duration when its payload
is constant, including an explicitly constructed `Result`.

### Failure protocol and required results

| Construct | Contract |
|---|---|
| Failure marker | `@(failure=name)` designates one variant as failure. Such a union has exactly two variants; the other is success. |
| `or_else` | The success variant must carry a payload. The result type is that payload. The fallback is evaluated only on failure. |
| `or_return` | The enclosing procedure has a single union result with a designated failure variant. The operand failure payload is assignable to the enclosing failure payload, or both are payloadless. The success payload may be absent, in which case the expression yields `Unit`. |
| Operator ownership | A place operand copies the selected payload and leaves the source live; a temporary or `move(x)` transfers it. `or_else` never copies the error. `or_return` copies a place error and therefore requires it to be copyable. A place operand also requires a copyable success payload. |

`require_results` is a **declaration/type attribute**, not a union-layout
attribute. The ordinary declarations are:

```odin
Unit   :: struct {}
Option :: union($T: type) @(zero=none, failure=none) {none:, some: T}

@(require_results)
Result :: union($T, $E: type) @(failure=err) {ok: T, err: E}
```

The attribute records a `requires_results` property on the declared nominal
type and every generic instance. A type requires handling when it is that type,
an alias/distinct form of it, or a value aggregate (struct, fixed array, or
named union) containing it recursively. Pointers, views, and procedure values
do not inherit the property merely because the pointee or signature mentions
it. Recursion is cycle-safe.

A bare call statement is rejected when any result type requires handling,
regardless of whether the call is direct, overloaded, generic, or through a
procedure value. The existing procedure/group `@(require_results)` rule remains
an independent source of the same diagnostic. Assignment to `_` is an explicit
discard and remains legal. This rule checks discarded returned values; it does
not prove that a stored error is eventually inspected.

## Implementation sequence

### 1. Baseline and exact inventory

- Run and preserve `test-all.ps1`, `odin test src`, and `odin test tests` before
  changes. Record revision, Odin/Clang versions, optimization/panic axes, and
  unrelated working-tree changes.
- Generate the inventory from syntax/semantic nodes, not broad word counts.
  Record separately:
  - anonymous union declarations and variant counts;
  - union `.(T)`/`.as(T)` sites versus `any_view` sites;
  - union and `any_view` type switches;
  - actual `or_else` and `or_return` expressions;
  - every compiler-generated, library, example, test, and embedded-test
    producer whose final result is a status;
  - implicit payload-to-union conversions; and
  - every zero-manufacturing operation listed above.
- At the revision used to write this corrected plan, textual declaration
  inventory finds 39 anonymous unions: five in `base`/`core`/`examples`, 33 in
  `tests`, and one embedded in `src/*_test.odin`. Recompute at implementation
  start. The five library/example declarations are single-variant nil-status
  wrappers; the tests include empty, multi-variant, generic, layout, managed,
  and deliberately invalid unions and must not be described as error wrappers.
- Characterize the current multi-payload `or_else`, named-result requirement,
  managed-union L0494 gate, tag-width boundaries, and all-zero assumptions in
  `runtime/container.c` and allocation lowering. These are intentional
  deletions or required implementation work, not unexplained regressions.
- Add and run a fixture instantiating a generic anonymous union before changing
  the grammar. Generic records work, and union syntax accepts parameters, but
  the corpus currently lacks an instantiated generic-union runtime proof.

### 2. Named variants and stable semantic identity

Anonymous unions remain available only inside the disposable prototype so the
gate has a control.

- Replace `Union_Variants = Type ("," Type)*` with disjoint anonymous and named
  productions. Mandatory colons distinguish the named form without lookup.
- Replace `Type_Record.variants: []Expr` with an AST variant record carrying
  optional name, payload syntax, and span; clone it during generic
  instantiation.
- Replace `Type_Info.variants: []Type_Id` and Type_Id-keyed case coverage/tag
  APIs with stable semantic variants. Update every consumer: assignability,
  type switching, equality, formatting, reflection, type traversal, layout,
  emitter, evaluator, provenance shape, and diagnostics.
- Reject mixed lists and duplicate names. Permit duplicate payload types.
  `Result(int, int)` is the mandatory proof that no later phase reverts to
  payload identity.
- Resolve `.name`/`.name(payload)` through the implicit-selector parser path,
  but store the chosen union and variant index on the expression. Delete
  implicit payload-to-union conversion for named unions.
- Branch type switches by subject: `any_view` retains type cases; named unions
  resolve variant cases. Coverage is by variant identity, not payload type.
- Implement tag numbering and width by variant count, including explicit tests
  at 0, 1, 255, 256, and 257 variants.

### 3. Runtime declarations, zero properties, and bootstrap

- Add `Unit`, `Option`, and `Result` to `base/runtime/runtime.loke` with the
  attribute placement shown above.
- Load `base:runtime` as an explicit compiler bootstrap dependency before any
  package whose checked or synthesized signatures may instantiate these types.
  Bind the three declaration symbols into the universe only after their
  signatures are resolved. Detect and diagnose bootstrap failure rather than
  synthesizing a second compiler-owned type.
- Provide one checker helper for instantiating the source-declared `Option` and
  `Result`; built-ins, container members, generated hooks, and iteration all use
  it. Cache instances through the ordinary generic-instance cache.
- Implement `type_has_zero` and `zero_const` under the all-zero rules above.
  Audit materialization, constants, globals/TLS, composites, allocation,
  containers, evaluator storage, move/drop clearing, and map operations.
- Split direct map insertion into reserve/construct/commit phases (or an
  equivalent atomic helper). The key/value must not become an occupied entry
  until the supplied value is completely initialized. Failure releases staged
  storage and leaves the old table unchanged; replacement drops only an
  actually live old value. Do not reuse the current zero-inserting
  `map_entry` path for a no-zero value.
- Implement type-based `require_results` propagation and call diagnostics,
  including indirect calls and recursive generic wrappers.
- Measure unconditional runtime loading: front-end time, type/symbol counts,
  and empty-program output. Record this at the gate.

### 4. Full union lifecycle, structural operators, and the decision gate

- Remove the managed-union L0494 gate only after tag-aware lifecycle support is
  complete. A union inherits managed and move-only properties from every
  payload. Clone/copy/drop dispatches only on the active tag; partial failed
  clones clean up; moves transfer the active payload and leave dead inert
  storage; generated unwind paths drop exactly once.
- Equality, formatting, and reflection/evaluator inspection also dispatch on
  the active tag. They must not speculatively load or operate on inactive
  payload storage.
- Support ordinary initialization, assignment, return, parameter passing,
  field/array/container storage, explicit discard, procedure-value calls, and
  static explicit construction for unions carrying managed or move-only
  payloads. Constructor/switch/operator tests alone are insufficient.
- Rewrite `check_or_else` and `check_or_return` against the designated-failure
  protocol. Delete `type_is_status`, `status_payloads`, multi-payload fallback,
  and named-result initialization coupling in the prototype.
- Implement every row of the operator ownership matrix and consuming/borrowing
  switch rules in semantic analysis, lifecycle annotations, evaluator, and LLVM
  lowering. `or_return` constructs the enclosing error directly without a
  second clone.
- Verify provenance parity for bare versus wrapped borrows. Reuse aggregate
  content paths and call contracts; do not add an `Option` exception.

**Gate.** Compare the complete prototype with the unchanged Phase 1a status
protocol using at least:

- a generic producer/consumer passed through a procedure value;
- a managed and a move-only payload stored in a field and container;
- a borrow-carrying payload across direct, generic, package, and indirect calls;
- a failure path and an explicitly discarded `Result`; and
- compile-time construction and matching.

Record source complexity, semantic rules added/deleted, diagnostics, layout and
call lowering versus the current `loke`-CC aggregate, clone/drop behavior,
generated IR, binary size, front-end cost, and type-count delta in `comments.md`
and this plan.

If typed fallibility loses, discard the dedicated prototype changes and land
only the no-go decision record. Do not proceed to step 5 and do not expose named
variants, bootstrap types, or structural operators in the released compiler.

### 5. Adopt one named union model

Only after a positive gate; this and step 6 are one adoption change.

- Migrate the five library/example nil-status wrappers to their underlying
  error payloads inside `Result`.
- Migrate test unions according to purpose:
  - multi-variant/layout/generic tests become named-variant tests;
  - extraction and switch tests use constructors and variant cases;
  - managed-union rejection fixtures become positive tag-aware lifecycle tests
    or retain only genuinely invalid ownership cases; and
  - invalid-union fixtures test mixed forms, duplicate names, bad attributes,
    and zero/failure constraints.
- Delete anonymous union parsing and AST/semantic branches, nil union state,
  tag-0-is-nil behavior, `union_holds` assignability, `active_typeid`, the union
  half of checked type extraction, and `const_holds_live_union`.
- Remove `nil` assignability/comparison for unions. `Option.none` is a variant,
  not a renamed nil union state.
- Keep `.(T)`, `.as(T)`, and type cases only for `any_view`; `.as(T)` produces
  `Option(T)`.

### 6. Migrate every absence and failure producer

The inventory, not this illustrative list, is authoritative. No standard
library or compiler-generated API retains a trailing status convention.

- Migrate absence to `Option(T)`:
  - `any_view.as(T)`;
  - `map.lookup_value`;
  - `map.find`, preserving its name, `inout` receiver, non-inserting behavior,
    mutable borrowed pointer, and provenance;
  - `map.remove`;
  - dynamic-array `pop`;
  - validating conversions;
  - the iteration protocol's `next`; and
  - every additional corpus producer identified in step 1.
- Migrate allocation failure to `Result(T, Allocator_Error)`: `new`,
  `new_clone`, `make`, every `try_*` member, generated `try_clone`, and
  `hook(copy)`. No-payload cases use `Result(Unit, Allocator_Error)`.
- Change `Small_Array.try_append -> bool` to
  `Result(Unit, Capacity_Error)`. Inventory any other bare-bool failure rather
  than assuming this is the last.
- Preserve map insertion policy: index-place insertion still creates a zero and
  is unavailable for no-zero values; direct value insertion constructs the
  supplied value without publishing a zero. `find` changes only its result
  representation.
- Re-evaluate `try_` naming once, while every member is touched, and record
  whether the prefix remains. Do not rename in a later pass.
- Delete status checking and lowering end to end. Search source, generated
  member tables, evaluator, emitter, tests, examples, docs, and diagnostics for
  residue. Ordinary procedures may still return multiple results containing a
  `bool`; they simply receive no status semantics.

### 7. Specification and decision records

Land specification changes with the adoption change:

- `design.md`: named variants and identity, constructors, switches, lifecycle,
  all-zero/default rules, no-zero types, `Option`/`Result`, structural failure,
  required-result propagation, map restrictions, and operator ownership.
- `grammar.md`: anonymous/named prototype grammar followed by the adopted named
  production, variant constructors/cases, and attribute positions.
- `language-design-consolidation-proposal.md` and
  `language-refinement-strategy.md`: gate result, measured costs, chosen model,
  migration completion, and any rejected alternative.
- `comments.md`: A/B evidence and the explicit reversal (or no-go retention) of
  the current `Option` decision.

## Verification and acceptance

### Required semantic evidence

- **Variant identity:** `Result(int, int)` constructs, switches, compares,
  formats, reflects, clones, and drops the correct variant. Coverage and
  diagnostics name variants, not payload types.
- **Grammar/construction:** reject anonymous/named mixtures, duplicate names,
  `.ok()`, `.none()`, and wrong payload counts; accept contextual and explicit
  construction in generic, constant, and runtime code.
- **Zero values:** reject a later `@(zero=...)` variant and a first variant with
  a no-zero payload. Cover `{}`, omitted fields, globals/statics/TLS, `new(T)`,
  `make` length, resize growth, missing map reads, and inserting map indices.
  Prove default-length arrays, reserve, raw capacity, direct map insertion, and
  explicit constant `Result` construction remain valid.
- **Required results:** cover direct, overloaded, generic, package, and
  procedure-value calls; containing struct/array/union wrappers; recursion; and
  explicit `_` discard.
- **Lifecycle:** ordinary copy/assignment/return/discard and nested
  field/array/container storage for managed and move-only payloads. Count
  clones, partial cleanup, drops, and unwinding for both tags.
- **Switch/operator ownership:** every branch and every ownership-matrix row,
  including grouped/default/`_`, `break`, `return`, and panic unwinding.
- **Provenance:** reproduce the bare acceptance/rejection set from
  `m5b_aggregate_baseline.loke` and `m5b_aggregate_wrapping.loke` with payloads
  inside `Option`/`Result`; keep `wrap`/`unwrap` legal.
- **Producer completeness:** audit `map.find`, `map.remove`, lookup, pop,
  conversion, iteration, allocation, generated hooks, `try_*`, library APIs,
  examples, and embedded programs. No standard API exposes `(T, bool)` as an
  absence convention or `Allocator_Error` as a final status.

### Backend and cost evidence

- Measure 0/1/255/256/257-variant tag layout, padding/alignment, reflection
  order, and constant emission.
- Compare `Option`/`Result` `loke`-CC returns with current `(T, bool)` and
  `(T, Allocator_Error)` aggregates for scalar, managed, move-only, unit, and
  borrow-carrying payloads. No boxing or wrapper allocation is permitted.
- Inspect IR for tag-aware comparison/format/clone/drop and ensure inactive
  payloads are never loaded, compared, formatted, cloned, or dropped.
- Record compile-time/runtime changes caused by bootstrap loading and generic
  instances rather than treating them as noise.

### Test matrix

Run before the gate and after the complete adoption migration:

- `odin test src`
- `odin test tests`
- `test-all.ps1` at `minimal`, `size`, `speed`, and `aggressive`
- every supported panic strategy for lifecycle/unwind fixtures
- an A/B of old and new compilers over the complete corpus, reporting only
  intended acceptance, diagnostic, ABI, and output differences

## Boundaries

- Deferred: anonymous records, general destructuring, the general one-result
  procedure migration, removal of named-result locals, and `()` spelling.
- Unchanged except where stated: `manual`, `inout` and place results, container
  representation, map index insertion policy, interface work, and the
  `.Allocator_Error` type kind.
- `find` retains its borrowing and invalidation behavior but migrates its result
  to `Option(^mut V)`; “unchanged” never means retaining `(T, bool)` absence.
- Preserve unrelated working-tree edits. The disposable prototype must live in
  isolated git state so a no-go never requires a destructive reset.

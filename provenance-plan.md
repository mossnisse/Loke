# Transitive provenance implementation plan

Status: historical; superseded by
[`consolidation-provenance-plan.md`](consolidation-provenance-plan.md), the second
consolidation implementation plan for aggregate provenance and call contracts.
The decisions and checklist below are retained as historical input, not current
implementation instructions. In particular, its recursive-cache shortcut,
`Unknown` lifetime allowance, and `unsafe.forget_provenance` proposal are not
adopted by the replacement plan.

## Context

M5b built the two lifetime analyses design.md specifies, and
`src/borrow.odin` implements them over `src/cfg.odin`'s provenance event stream.
Both follow *carriers*: `type_is_carrier` answers yes for `^T`, `[]T`,
`string_view`, `cstring_view`, `any_view`, `dyn`, and region providers, and no
for everything else. A carrier stored inside a struct, a fixed array, a union,
a dynamic array, or a map is therefore invisible to the analysis, and so is a
carrier written into file-scope, `static`, or `thread_local` storage.

design.md records that as a deliberate v1 decision under
[what is not checked](design.md#what-is-not-checked), and
`tests/run/m5b_trust_boundary.loke` keeps the list executable: every case in it
is a program that must keep compiling.

This plan closes the record-and-container half of that list. It is a
**source-breaking** change with no compatibility mode, and it is separated from
the small corrections shipped alongside it — the consuming-receiver spelling,
the map `Element` documentation, `&m[key]`, and the lifecycle-contract wording —
because those are local fixes and this is a change to what the borrow checker
*is*.

The normative sections are
[Borrows and lifetimes](design.md#borrows-and-lifetimes),
[Storage roots and borrow carriers](design.md#storage-roots-and-borrow-carriers),
[Temporaries and procedure boundaries](design.md#temporaries-and-procedure-boundaries),
and [what is not checked](design.md#what-is-not-checked).

## The breakage budget

This is the part to agree on before any code moves, because it is larger than
"records now propagate borrows" sounds.

Making structs carriers means a struct that holds a `^T` participates in the
one rule. `tests/run/m5b_trust_boundary.loke`'s `hidden_alias` becomes an
`L0511`:

```odin
Handle :: struct { target: ^int }

hidden_alias :: proc() -> int {
	value := 1;
	h := Handle{&value};
	value = 2;      // ERROR: write of `value` conflicts with the mutable
	return h.target^;  //        pointer inside `h`, which is still in use
}
```

That is the intended rule, and it is also every parent pointer, intrusive list
link, and observer back-reference in the language. Loke gains a Rust-grade
aliasing check over user records, and `unsafe.forget_provenance` is the only
relief.

The second cost is the global rule. A borrow reaching file-scope, `static`, or
`thread_local` storage is rejected unless its root outlives that storage —
which **includes borrows arrived through a parameter**, since a caller's stack
frame does not outlive a global:

```odin
global_view: []int;

store_in_a_global :: proc(values: []int) {
	global_view = values;   // ERROR: `values` names caller storage
}
```

Installing a caller-provided buffer into a registry is a real pattern, and after
this change it is written `global_view = unsafe.forget_provenance(values);`.
Both of these are the point of the change, not side effects of it; they are
written down here so that agreeing to the plan is agreeing to them.

## Scope

### In this plan

| Area | Contents |
|---|---|
| Carrier predicate | `type_is_carrier` becomes recursive over structs, fixed arrays, unions, dynamic arrays, and maps, memoized against recursive types |
| Aggregate loans | Construction, copy, move, assignment, selection, extraction, calls, returns, and branch joins carry loan sets through aggregate values |
| Container contents | Insert, append, replace, clear, drop, pop, and remove relate a container's loan set to the loans of what goes in and comes out |
| Retention summaries | `Proc_Summary` gains a retained-provenance component for carrier-valued `inout` parameters and mutable receivers |
| Global stores | Storing a locally checked loan into file-scope, `static`, `thread_local`, or unrelated parameter-reachable storage is a diagnostic |
| `unsafe.forget_provenance` | The compiler-contributed escape hatch that makes the two rules above opt-out-able |

### Not in this plan

- No user-written provenance or lifetime annotation, and no effect system.
- No cross-package serialization of the extended summary. Summaries live in
  `Compiler.result_summaries` for one whole-program compile and are not emitted;
  the retention component inherits that.
- Raw pointers, `[^]T`, foreign retention, `core:unsafe`, and cross-thread
  transfer stay unchecked. They remain on design.md's list, which shrinks by
  exactly two bullets.

## Decisions

| Area | Choice | Why |
|---|---|---|
| Carrier recursion | A struct, fixed array, union, dynamic array, or map is a carrier exactly when one of its contained types is. Built-in carriers stay leaves. The predicate memoizes per `Type_Id` and treats a type already on the stack as a non-carrier for the recursive edge only. | The lattice is per-type and the answer is monotone, so one memo table over the whole compile is enough. A recursive record reaches a fixed point on its first query rather than needing a separate pass. |
| Field and index reads | A value read of a carrier-typed field or element inherits the aggregate's loan set **and nothing else**. It does *not* additionally borrow the containing root. | The loaded value points where it already pointed. When it points into the aggregate — a slice of an inline array field — the inherited loan already names that root with that path, so the correct case is covered. Adding a synthetic borrow of the container would reject `h := Holder{values}; return h.view;`, which is legal code that borrows only the caller's argument. |
| Address and reference projections | `&h.field`, an `inout` projection, and a by-reference `foreach` binding *do* borrow the containing root, in addition to inheriting its loans. | Here the result is an address into the aggregate's own storage, so the aggregate is genuinely the root. This is the case the previous row is deliberately not. |
| Copy, move, assignment | A copy duplicates loan associations; a move transfers them; a full assignment replaces them. Branches and union variants join. | This is what the existing per-slot reaching solver already does for built-in carriers. Aggregates need the same operations, not new ones. |
| Container contents | One loan set per container slot, holding everything ever inserted. Full replacement, `clear`, and drop end it; `pop`/`remove` results inherit it and the container conservatively keeps it. Element selection inherits both container-root and stored-content loans. | Per-element tracking would need a dependent index domain the solver does not have. A single set is coarse in the rejecting direction and costs one slot per container. |
| Retention effects | `Proc_Summary` gains, per carrier-valued `inout` parameter and mutable receiver, the set of other parameters whose loans may be retained into it. A direct call substitutes actual loans into the mutated destination. An indirect Loke call assumes every borrowed actual may be retained by every carrier-valued mutable actual. | This is the same possibility-union lattice as `Result_Provenance`, so it joins the existing worklist fixed point in `analyze_program_provenance` without a second solver. |
| Global stores | The root half of the rule is emitted at the site that already computes the region half — `prov_region_escape` in `src/cfg.odin`, which resolves `` `static` storage `` / `file-scope storage` and emits `.Region_Escape`. Its `type_is_managed` early return gates the region question only and must be lifted for the root one: a bare `[]int` written to a global is exactly the case being added. Permitted roots are `Static`, `Materialized`, and `Unknown`. | That site already answers "is this destination longer-lived than the source", and `src/borrow.odin` already reports it. Prov slots are deliberately not created for static or top-level symbols (`prov_slot_for_symbol` refuses them), so a slot-based approach would fight the existing design rather than reuse it. |
| Reads from globals | A read of mutable global carrier storage yields unknown provenance and stays a trust boundary. | Nothing tracks writes to a global across procedures, so any other answer would be a guess. Unknown is not evidence of a failure — only an operation needing a proof, such as checked `free`, rejects it. |
| `unsafe.forget_provenance` | `contribute_builtin(c, pkg, "forget_provenance", .Unsafe_Forget_Provenance)` in `src/stdlib.odin`, alongside the `raw_data`, `string_view`, and `cstring_view` entries already there. It evaluates its operand once under normal copy/move semantics, replaces root provenance with unknown, preserves region provenance, ownership, lifecycle, type, and representation, and lowers to nothing. | The mechanism exists and `core/unsafe` is otherwise an empty package. Keeping *region* provenance is the load-bearing half: forgetting a root must not also launder an arena-backed owner past a region reset. |
| `forget_provenance` domain | Accepts any type and is the identity on one that carries no root provenance. | Once the carrier predicate is recursive, "can carry provenance" is most of the type system, so a restriction would reject little and would make generic code ask a question it cannot answer. |
| Diagnostics | Reserve L0649–L0660. | Stale as written: L0639 is in use and [`consolidation-provenance-plan.md`](consolidation-provenance-plan.md) allocated L0644 and L0646–L0648 from the old reservation. L0645 is unused. |

## Steps

Each step ends with a built compiler and a green existing corpus, except where a
step's own entry says which fixtures it converts from success to diagnostic.

### 1. The recursive carrier predicate

- Make `type_is_carrier` recursive over `.Struct`, `.Array`, `.Union`,
  `.Dynamic_Array`, and `.Map`, memoized on a `map[Type_Id]bool` held by the
  compiler, with an on-stack set so a recursive record terminates.
- Change nothing else. Slots are now created for aggregate locals and
  parameters, and they simply hold no loans yet.

**Exit:** the whole corpus is unchanged in behaviour, and a body full of structs
allocates slots without reporting anything new. Record the lattice size on the
largest corpus body: `prepare_state` allocates `slots × loans` bools twice per
block, and this step is where that product grows. If it grows more than tenfold
on a real body, stop and make the slot set demand-driven before continuing.

### 2. Aggregate loan flow

- Join operand loans at composite construction; duplicate on copy, transfer on
  move, replace on full assignment.
- Return the aggregate's loans from a value read of a carrier-typed field,
  element, or checked extraction — inheritance only, per the decision above.
- Borrow the containing root for `&h.field`, `inout` projections, and
  by-reference bindings, in addition to inheriting.
- Join at branch merges and union variants.

**Exit:** `tests/run/m5b_trust_boundary.loke`'s `hidden_alias` and
`store_in_a_record_field` become diagnostics and move to `tests/err`. A borrowing
iterator returned from a record cannot outlive its source, and still compiles
when the source, a caller parameter, or static storage stays live.

### 3. Container contents

- One loan set per container slot; insert and append union into it; replacement,
  `clear`, and drop end it; `pop`/`remove` inherit it; element selection inherits
  container-root and content loans.

**Exit:** a borrow appended into a dynamic array or map cannot outlive its root;
clearing the container releases the obligation; removal is conservative.

### 4. Retention summaries

- Extend `Proc_Summary` with the retention component, seed and join it in
  `summarize_body`, and substitute at direct calls. Indirect calls take the
  conservative assumption.

**Exit:** a helper that stores its borrowed argument into an `inout` container
is diagnosed at its *caller*, at the point where the container outlives the
borrow.

### 5. The global rule and `unsafe.forget_provenance`

- Add `unsafe.forget_provenance` first: the builtin, its checking, its
  constant-evaluator identity behaviour, the provenance rewrite, and its no-op
  lowering.
- Then add the root half of the escape rule at `prov_region_escape`, lifting its
  managed-only early return so a bare view reaches it.

**Exit:** `store_in_a_global`, `retain_an_argument`, and `store_a_view` become
diagnostics; each compiles again with `unsafe.forget_provenance` around the
stored value. A forgotten allocation root no longer reaches checked `free`, and
a forgotten arena-backed owner is still refused at a region reset.

### 6. Audit and documentation

- Rewrite design.md's carrier list and its
  [what is not checked](design.md#what-is-not-checked) bullets: the record and
  global entries leave, the raw-pointer, foreign, `core:unsafe`, and
  cross-thread entries stay.
- Document `unsafe.forget_provenance` in the `unsafe` package section.
- Rewrite `tests/run/m5b_trust_boundary.loke` as the smaller list it has become,
  with the removed cases living in the new `tests/err` fixtures.

## Verification

```powershell
./test-all.ps1
```

Milestone spot checks:

- Nested and recursive records, fixed arrays, unions, and branch joins each
  propagate a borrow to the same conclusion the equivalent bare carrier reaches.
- A returned iterator, a shared-style handle, and a helper that retains into an
  `inout` container are each diagnosed with the root named.
- `unsafe.forget_provenance` enables the intentional store, produces unknown
  provenance, preserves the region-reset restriction, and blocks checked `free`.
- The optimization matrix is unaffected: this plan adds no lowering.

## Deliberate shortcuts

| Shortcut | Ceiling | Upgrade path |
|---|---|---|
| One loan set per container, not per element | A borrow removed from a container is still assumed present | A dependent index domain, if a real program is rejected by it |
| Indirect calls assume every mutable actual retains every borrowed actual | Procedure values through a carrier-valued `inout` are effectively unusable with checked borrows | A move-only wrapper type, as design.md already prescribes for allocation transfer |
| Retention summaries are in-memory only | Cross-package checking is whole-program-compile only | Serialization, when separate compilation exists |

## Assumptions

- Loke remains pre-release, so the two breakages under
  [The breakage budget](#the-breakage-budget) ship without a migration flag.
- No map `keys()`, `values()`, or `entries()` adapters are added here.
- The existing uncommitted working tree is the base.

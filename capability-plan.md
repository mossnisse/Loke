# Capability-typed borrows — `^mut T`, `&mut`, `dyn mut I`

## Status

**Both phases complete.** Bare `^`, `&`, and `dyn` are read-only; `^mut`, `&mut`,
and `dyn mut` are the mutable spellings. `test-all.ps1` is green end to end: 44
compiler unit tests, the 14-case integration corpus, and the run/trap corpus at
`-opt=minimal|size|speed|aggressive`.

Phase A landed as written. Two details differed from the outline:

- **`&&mut x` does not parse.** `&&` is one token, so a borrow of a borrow is
  written `& &mut x`. Noted in the ambiguity corpus rather than special-cased in
  the lexer.
- **Malformed `mut` needed no new code.** `[^]mut T`, `^mut;`, `dyn mut;`,
  `a & mut b`, and `-mut a` all reach an existing L0210/L0220 with an accurate
  span, pinned by `tests/syntax_err/capability-modifiers.loke`.

Phase B found three things the outline did not predict:

- **A pre-existing bug in slice weakening.** `prov_weaken` downgraded the loan but
  not the `.Access` the borrow had already registered on its root, so two
  read-only slices of one root wrongly conflicted — `xs[0:2]` can only spell the
  mutable capability, and the destination is what settles it. Fixed in step 5 by
  recording where the access was emitted so weakening can revise it. This is the
  slice half of **D5**, and it had to be fixed before two `&` borrows could work.
- **The dyn slot call does not go through the forwarding members.**
  `check_dyn_slot_call` resolves against the interface's own slot list, so the
  member filter in `install_dyn_forwarding_slots` governs only whether `dyn I`
  satisfies `I`. Both mechanisms are needed and they are not the same one.
- **Two of the six planned diagnostics were better left to existing codes** — see
  step 8.

Everything else landed as planned, including the reborrow suspension, which was
the item flagged as most likely to be wrong first try and needed no adjudication
of existing tests: nothing in the corpus weakened an existing carrier.

## Context

Loke has one capability axis today and applies it to exactly one carrier.
`[]mut T` and `[]T` are distinct types with a real weakening rule
([slice.odin:24](src/slice.odin:24), [generic.odin:545](src/generic.odin:545)),
while `^T` is unconditionally mutable and `&` unconditionally produces an
exclusive loan ([cfg.odin:899](src/cfg.odin:899)). design.md:370 states that as a
decision: *"Pointers carry no read-only capability: there is no `^const T`."*
`dyn` infers its capability from the interface's receiver modes and explicitly
refuses a second spelling (design.md:2542).

The consequence is that every read-only single-value borrow has to be spelled as
something else — a value parameter, a one-element slice, or an `inout` that
overstates what it does — and a mixed interface's `dyn` view is mutable even for
callers that only read. This plan makes the capability explicit and orthogonal
across all three checked carriers:

|                | read-only | mutable      |
|----------------|-----------|--------------|
| single value   | `^T`      | `^mut T`     |
| sequence       | `[]T`     | `[]mut T`    |
| erased view    | `dyn I`   | `dyn mut I`  |
| address-of     | `&place`  | `&mut place` |

`inout T` stays a distinct non-null, call-bound place mode with whole-owner
invalidation rights. `[^]T` stays unchecked, mutable, and capability-erasing.

Pre-1.0 breaking change, no compatibility spelling. Migration surface is small:
~101 pointer-type mentions and ~134 address-of sites across `core`, `base`,
`examples`, and `tests`; 22 test files mention `dyn`; two library interfaces are
mutable views (`interfaces.Iterator`, `io.Writer`).

## Language changes

### Formation

- `&place` needs **readable** addressable storage and yields `^T`. New
  acceptances over today's `&`: a value parameter, an element of `[]T`, and a
  named constant or a place inside one.
- `&mut place` needs **writable** addressable storage and yields `^mut T`. It is
  today's `&` exactly.
- Unchanged rejections for both: a packed field, an `any_view`, a non-addressable
  value.

### Places

- `p^` where `p: ^T` is addressable but **not assignable**.
- `p^` where `p: ^mut T` is assignable.
- The same rule carries through implicit pointer field selection, indexing,
  method receivers, and nested projections. Calling an `inout self` method
  through a `^T` is a capability error, not a missing member.

### Weakening

- `^mut T` → `^T`, `[]mut T` → `[]T`, `dyn mut I` → `dyn I` are implicit. The
  reverse never happens, including when the ultimate owner is mutable.
- Weakening a **fresh** borrow (`p: ^int = &mut x`) just creates the loan
  read-only. This is what [cfg.odin:1361](src/cfg.odin:1361) already does for
  slices.
- Weakening an **existing** mutable carrier creates a read-only reborrow: the
  source loan and every other mutable alias of the same place are suspended until
  the reborrow's last use, then usable again. This is new (see step 5).

### Compiler-produced pointers

The complete audit — every synthesized pointer result in the compiler:

| Site | Result | Capability |
|---|---|---|
| [check.odin:1085](src/check.odin:1085) | a written `^T` type | from the syntax |
| [check_expr.odin:1385](src/check_expr.odin:1385) | `&` / `&mut` | from the operator |
| [check_expr.odin:2904](src/check_expr.odin:2904) | `new` | `^mut T` |
| [check_expr.odin:2931](src/check_expr.odin:2931) | `new_clone` | `^mut T` |
| [container.odin:276](src/container.odin:276) | `map.find` | `^mut V`, `inout` receiver |
| [reflect.odin:558](src/reflect.odin:558) | `field.pointer` | preserves the input pointer's |
| [text.odin:753](src/text.odin:753) | `type_info_of` | `^runtime.Type_Info`, read-only |
| [check_expr.odin:1270](src/check_expr.odin:1270) | multi-pointer slicing | `[]mut T`, unchanged |
| [text.odin:360](src/text.odin:360) | `raw_data` | `[^]T`, unchanged |

`free` requires an allocation-root `^mut T`.

### Dyn

- `dyn I` and `dyn mut I` are separately interned types with distinct names, type
  ids, and cache keys. One canonical LLVM aggregate serves both; the header stays
  data pointer + witness pointer.
- `(dyn I)(&value)` and `(dyn I)(&mut value)` (weakening) both construct.
  `(dyn mut I)(...)` requires `^mut Concrete`.
- For a mixed interface, `dyn I` exposes only immutable-`self` slots; `dyn mut I`
  exposes every slot. Both keep the full witness table; only capability-legal
  forwarding members are installed.
- A mutable slot call through any `dyn mut I` value is allowed: the capability
  belongs to the view type and the call mutates the erased referent, not the view
  header.
- `dyn I` satisfies `I` only when every required receiver is immutable;
  `dyn mut I` satisfies mixed and mutable interfaces. Composed-base conversion
  keeps the capability.
- **Slot receiver spelling is unchanged.** A dyn-compatible slot's receiver is
  `self` or `self: inout Self`. `self: ^mut Self` is not a receiver form and does
  not become one.

### Unchanged

Multi-pointer conversions, `unsafe.raw_data`, `@(by_ptr)`, LLVM layouts, runtime
calls, the reflection schema, and pointer ABI. `^T` and `^mut T` lower to the
same LLVM pointer and receive no new attributes; at a foreign boundary the
capability is documentation.

## Decisions

**D1. Materialized constant identity.** `&CONST` materializes one shared
read-only static object per constant *symbol*, so every `&CONST` in the program
compares equal. A generic instantiation's constant belongs to the instantiated
symbol, so it is one object per instance. A constant used only by value is not
materialized. `&mut` of materialized storage is rejected. This replaces
design.md:2812, whose ban existed only because no read-only pointer existed.

**D2. Generic matching weakens, like slices.** `^$T` accepts `^mut int`;
`^mut $T` rejects `^int`. Same for `dyn`. This mirrors
[generic.odin:545](src/generic.odin:545) verbatim, and without it every generic
helper would need two versions.

**D3. Dyn checked extraction stays out of version 1 — for a new reason.**
design.md justifies the ban with *"Loke has no read-only pointer type to
represent a safe downcast"*, which this plan makes false. The ban stands on the
representation instead: the view header carries a data pointer and a witness
pointer and no typeid, so a checked downcast would need a third word and a dyn
ABI change. Rewrite that sentence; do not lift the restriction.

**D4. Two phases, each green.** Flipping `&` and `^` in the same commit as the
source migration breaks every package at once with no way to bisect. Phase A is
purely additive (new spellings mean what the old ones mean) and ends with every
source migrated and the corpus green. Phase B flips the bare spellings to
read-only. The red window is Phase B only, and by then no source still spells a
mutable pointer as `^T`.

**D6. `^T` still converts to `[^]T`.** This strengthens a capability, but it
strengthens it *across the unchecked boundary*, which is what `[^]T` is for:
design.md already says a multi-pointer carries neither a length nor a capability
and that its lifetime stops being checked. Requiring `^mut T` here would suggest
the boundary preserves something it does not. `unsafe.raw_data` of a `[]T`
behaves the same way and always has. Decided rather than inherited —
`tests/run/m6a_unsafe_text.loke` round-trips `[^]int → ^int → [^]int`.

**D5. `&` becomes a shared loan.** Two live `&x` borrows of the same place become
legal for the first time. That is the point of the feature and needs a positive
test, not only conflict negatives.

## Implementation

### Phase A — additive

Nothing gets stricter. The corpus stays green after every step.

#### 1. Grammar, AST, and the new spellings

- Grammar: `Type = "^" "mut"? Type` and `"dyn" "mut"? Type_Name …`;
  `Unary_Expression = … | "&" "mut"? Unary_Expression`. `mut` is already a
  keyword ([grammar.md:55](grammar.md:55)).
- AST: a `mutable` bit on the pointer type node, the dyn type node, and the
  address-of expression, mirroring `Type_Slice.mutable`
  ([ast.odin:353](src/ast.odin:353)). Update `ast_clone.odin` and `ast_dump.odin`.
- **Both spellings intern to today's mutable type in this phase.** `^mut T` ==
  `^T`, `&mut x` == `&x`, `dyn mut I` == `dyn I`.
- Reject `mut` where it is meaningless: `[]mut` already errors correctly;
  `[^]mut T`, `^mut` with no type, `&mut` on a non-place.

Tests: parser corpus for nested `^mut ^mut T`, `^mut []mut T`, `dyn mut I(args)`,
`&mut` in call arguments and initializers, and each malformed placement. These
are the only Phase A tests, and they are the ones that keep working unchanged
into Phase B. They live in `tests/syntax/types.loke`,
`tests/syntax/expressions.loke`,
`tests/syntax/ambiguity/16-capability-modifiers.loke` (the dump golden that pins
`(ptr mut`, `(dyn mut`, and `(unary Amp mut`), and
`tests/syntax_err/capability-modifiers.loke`.

#### 2. Migrate every source by intent

Mechanical pass over `core`, `base`, `examples`, and `tests`. Still compiling at
every point because the spellings are synonyms.

`design.md`, `grammar.md` prose, and `readme.md` are **not** touched here beyond
the grammar productions themselves. Migrating spec examples while the spec still
says pointers have no read-only capability would leave the document contradicting
itself for the length of a phase; prose and examples change together in step 9.

| Rewrite | To |
|---|---|
| `^T` that is written through, or is an output/allocation result | `^mut T` |
| `^T` only read through | leave as `^T` |
| `&x` passed where mutation happens | `&mut x` |
| `&x` observational | leave as `&` |
| `dyn Iterator(T)`, `dyn Writer`, `dyn Reader`, `dyn Bumpable` | `dyn mut …` |
| `dyn Shape` and other read-only views | leave bare |

Mutable dyn sites to fix: `interfaces.Iterator` (`slot next: proc(self: inout
Self)`, so every `dyn Iterator` becomes `dyn mut`), `io.Writer` including the
stored `Latch.writer` field ([io.loke:368](core/io/io.loke:368)), and
`tests/run/m4b_erased.loke`'s `Bumpable`. `examples/shapes.loke` stays bare.

Judgement calls are recorded in the diff, not deferred: a `^T` left bare here is
an assertion that nothing writes through it, and Phase B is what checks the
assertion.

Verification: full `test-all.ps1` including the optimization matrix. A green run
here means the migration changed no behavior at all.

What the migration actually touched, and two things it surfaced for Phase B:

- The stdlib barely uses pointers: 10 sites across `core:fmt`, `core:fs`,
  `core:io`, and `core:term`, almost all Win32 out-parameters. `base` has none.
  `io.Writer` was the only library `dyn` needing `dyn mut`; `Bumpable` in
  `tests/run/m4b_erased.loke` was the only other one.
- **Invalidation tests were left on bare `&` deliberately.** Moving, dropping,
  freeing, exchanging, or fully assigning a root invalidates a read-only loan as
  well as a mutable one, so those cases keep testing what they tested. Only the
  tests whose error would *disappear* under a shared `&` were moved to `&mut`:
  overlap conflicts, `free` of a non-allocation root, assignment into a `^mut`
  variable, and `&` of materialized constant storage.
- `tests/run/m6a_unsafe_text.loke` round-trips `[^]int` → `^int` → `[^]int`.
  Step 3 must decide whether `^T` → `[^]T` stays legal (it strengthens a
  capability across the unchecked boundary) or requires `^mut T`. The plan says
  multi-pointer conversions are unchanged, so the default is "stays legal";
  make it a written decision rather than an accident.

### Phase B — the flip

#### 3. Capability in type identity

- Add an explicit `mutable` participant to pointer and dyn interning keys.
  `Type_Info.mutable` already exists ([semantic.odin:150](src/semantic.odin:150));
  do not overload `count` or element metadata.
- Bare `^`/`dyn`/`&` now produce the read-only capability. This is the flip: the
  default argument at the parse-to-type site changes, and everything below is the
  consequence.
- `type_name` prints `^mut T` / `dyn mut I`; distinct type ids and distinct
  runtime names, no representation change.
- Structural specialization matching per **D2**.

#### 4. Places and formation rules

- `&`: require readable addressable storage. Relax
  [check_expr.odin:1369](src/check_expr.odin:1369) accordingly, and make a `[]T`
  element addressable — [check_expr.odin:938](src/check_expr.odin:938) currently
  sets `addressable = info.mutable`, which becomes `addressable = true,
  assignable = info.mutable`.
- `&mut`: today's rule unchanged.
- Dereference: `^T` addressable, not assignable; `^mut T` both. Propagate through
  field selection, indexing, method receiver binding, and nested projections.
- Constant materialization per **D1**: extend `materialize.odin` so `&` of a
  constant or a subplace registers the shared static object and produces a
  `.Materialized` root, which `Root_Kind` already has
  ([borrow.odin:70](src/borrow.odin:70)). Delete the comment at
  [materialize.odin:10](src/materialize.odin:10) that explains why this was
  impossible.

#### 5. Weakening and the read-only reborrow

The only genuinely new checker semantics in this plan, and the one most likely to
be wrong first try. It gets its own step and its own test file.

- Generalize [`prov_weaken`](src/cfg.odin:1361) from slices to every carrier via
  `carrier_is_mutable` ([borrow.odin:246](src/borrow.odin:246)).
- Today it only downgrades `fresh_loan`, so weakening an *existing* carrier
  (passing a `[]mut T` variable to a `[]T` parameter) currently downgrades
  nothing. Fix that: when the source is an existing loan rather than a fresh one,
  create a derived read-only loan and mark the source loan suspended for the
  derived loan's live range.
- A suspended mutable loan cannot be used; using it is a diagnostic naming the
  reborrow that suspended it and the reborrow's last use. After that last use the
  source loan is usable again.
- **This changes existing slice behavior**, not just new pointer behavior. Run the
  existing slice/borrow corpus expecting some previously-accepted programs to be
  rejected, and adjudicate each one before adjusting a fixture.

#### 6. Dyn split

- Separate `dyn I` / `dyn mut I` interning in
  [erased.odin:143](src/erased.odin:143), capability in `dyn_key`,
  `dyn_display_name`, and the type id.
- `install_dyn_forwarding_slots` ([erased.odin:181](src/erased.odin:181)) installs
  only capability-legal slots; the witness table keeps every slot.
- Construction, satisfaction, and composed-base rules as under "Language changes".
- Canonical dyn ABI normalization analogous to the existing slice normalization,
  so weakening emits no cast and no copy.
- Rewrite the design.md dyn-capability paragraph and the downcast rationale per
  **D3**.

#### 7. Builtins, reflection, and provenance

- The capability column of the audit table: `new`/`new_clone` → `^mut T`, `free`
  requires `^mut T`, `type_info_of` → read-only, `field.pointer` preserves,
  `map.find` → `^mut V`.
- Provenance: `&` creates an immutable loan, `&mut` an exclusive one; carrier
  capability comes from the semantic type; returned and read-only pointers keep
  their existing root and region provenance. Update the `&place` row of the
  table at the top of [borrow.odin:23](src/borrow.odin:23) — it currently reads
  "mutable loan of the place".

#### 8. Diagnostics

L0638 was the maximum, so the new codes are L0639+. Five behaviors needed a new
code; two are better served by diagnostics that already exist.

| Code | Message |
|---|---|
| L0639 | `free` needs a mutable allocation pointer, found `^T` |
| L0640 | this place is reached through a read-only `^T` and cannot be written; borrow it with `&mut` |
| L0641 | use of a carrier suspended by a read-only reborrow; names the reborrow's creation and its last use |
| L0642 | `dyn mut I` needs `^mut Concrete`, found `^Concrete` |
| L0643 | slot mutates its subject, so it needs `dyn mut I` |

L0643 must not surface as "no such member" — the slot exists on the witness. It
is raised in `check_dyn_slot_call`, the direct path; the forwarding-member filter
in `install_dyn_forwarding_slots` is the separate mechanism that decides whether
`dyn I` satisfies `I`.

**Reusing two existing diagnostics rather than adding codes.** `&mut` on
unwritable storage goes through `report_not_assignable`, which already
distinguishes a constant (L0358), a value parameter (L0358), and read-only
storage (L0478) and names which one — a new code would say less. Strengthening
`^T` to `^mut T` lands on the ordinary assignment and conversion errors (L0310,
L0373), which already print both types. L0640 needed a new `Immutable_Reason`
variant, `Through_Pointer`, precisely because the generic "read-only storage"
wording could not name the fix.

#### 9. Documentation

- design.md:370 — replace the "no read-only capability" decision with the
  capability table and the formation rules.
- design.md:2812 — replace the materialized-constant ban per **D1**.
- design.md:2542 and the following dyn paragraphs — explicit capability, slot
  projection, and the **D3** rewrite.
- design.md "Capabilities and the one rule" (:4536) — `^T` moves from the mutable
  list to the immutable list, and the reborrow rule joins it.
- design.md:4886 builtin table, grammar.md types and unary expression, the
  borrow-carrier catalogue, and foreign guidance.
- Milestone plan files (`m0`–`m7`, `provenance-plan.md`) are history and are left
  alone.

#### 10. Tests

New files: `tests/run/capability.loke`, `tests/err/capability.loke`,
`tests/run/capability_reborrow.loke`, `tests/err/capability_reborrow.loke`,
`tests/run/capability_dyn.loke`, `tests/err/capability_dyn.loke`,
`tests/ll/capability.loke`.

- **Positive.** Reads through `^T`; mutation and projection through `^mut T`;
  fresh weakening; existing-carrier weakening with recovery after last use;
  **two simultaneous `&x` loans of the same place** (D5); `&` of a `[]T` element;
  `&CONST` and `&CONST.field`, including that two `&CONST` compare equal (D1);
  `new`/`free`; nil and equality; pointer layout unchanged.
- **Negative.** Write through `^T`; `inout self` method through `^T`; `&mut` on a
  value parameter, a constant, a `[]T` element, a packed field; `^T` assigned to
  `^mut T`; `free` of a `^T`; use of a mutable alias while a read-only reborrow
  is live.
- **Dyn.** Construction from `&` and from `&mut`; immutable and mutable slot
  calls; mixed-interface projection; `dyn mut` → `dyn` weakening; composed
  interfaces; nested erasure; generic satisfaction both directions (D2); nil
  views; L0643.
- **Codegen.** `^T` and `^mut T` emit the same LLVM type; `@(by_ptr)` unchanged;
  multi-pointers unchanged; exactly one LLVM struct shape per dyn interface
  application.
- Full `test-all.ps1` including `-opt=minimal|size|speed|aggressive`.

## Acceptance criteria

1. Phase A ends with a fully green `test-all.ps1` and every source migrated.
2. No bare `^T` is written through anywhere in `core`, `base`, `examples`, or
   `tests`; no bare `dyn` carries a mutable slot call.
3. `&` and `&mut` are distinct operators with distinct result types, and `&` is a
   shared loan that permits a second overlapping `&`.
4. A read-only reborrow of an existing mutable carrier suspends and then restores
   its source, with a diagnostic that names both ends of the range.
5. `dyn I` and `dyn mut I` are distinct types over one LLVM shape, and a mutable
   slot call through `dyn I` is a capability error, not a missing member.
6. No "pointers carry no read-only capability" text survives in design.md or in
   compiler comments except where it describes `[^]T`.
7. Full corpus green at every optimization level.

## Deliberate shortcuts

- Multi-pointers stay outside checked capability typing. Converting to `[^]T`
  visibly crosses the unchecked boundary; bounded multi-pointer slicing still
  yields `[]mut T`.
- No capability polymorphism: a procedure cannot be generic *over* the capability
  the way it can be over the element type. **D2** means read-only-parameter
  helpers accept both, which covers the corpus; add it if a real case needs a
  helper that returns the caller's capability.
- Foreign boundaries get documentation only — no LLVM `readonly`/`noalias`
  attributes. Add them when someone measures a reason.
- Each capability of a dyn application gets its own forwarding procedures, so an
  interface used both ways emits two identical thunks per immutable slot. They
  are separate types with separate members, and one struct and one witness are
  already shared. Deduplicate if a program ever emits enough of them to notice.

## Assumptions

- Syntax is exactly `^mut T`, `[]mut T`, `dyn mut I`, `&mut place`.
- `inout` keeps its syntax, call-site markers, whole-owner invalidation rights,
  and non-first-class status; it is not re-spelled in terms of `^mut`.
- Runtime reflection schema, dyn representation, and all ABI shapes are
  unchanged; capability-distinct types still get distinct identities and names.
- Pre-1.0 break with no compatibility spelling and no transitional diagnostic.

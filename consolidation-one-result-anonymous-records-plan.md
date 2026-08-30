# Fourth consolidation implementation plan: one result, anonymous records, destructuring

Status: **shipped**

## What shipped

Every part of steps 1–4, 6, and 7 landed as written. Two deliberate deviations,
both recorded in `language-design-consolidation-proposal.md`'s open decisions:

- **Step 5's matcher extraction was not done.** `bind_arguments` and
  `check_struct_literal` remain two matchers. A matching-only core over exactly
  two callers with disjoint diagnostic codes and one visibility rule that only
  one of them has is more indirection than it removes; the plan's own fallback
  ("preserve both existing matchers and say so") applies. The *required*
  correctness half did land: supplied call arguments now evaluate in source
  order and omitted defaults afterwards in parameter order, at run time and at
  compile time, recorded as `Expr_Call.bound_order` and driven from the slot the
  checker already chose. Literal element evaluation was already source-ordered
  and is now pinned by `tests/run/m7_argument_order.loke`; `design.md`'s stale
  "all fields or no fields" paragraph was corrected as a specification fix.
- **`()` was not added** (open decision 5, deferred), and there is no inline
  shape-prefixed record literal.

Two pre-existing defects surfaced during the migration and were fixed with it,
because every migrated record literal is written with named fields:

- A composite literal's *named* elements were joined into every borrow-
  provenance path instead of resolving to the field each names
  (`prov_composite_content`). This turned exact per-field result provenance into
  a join for every migrated signature.
- Named call arguments evaluated in *parameter* order rather than source order.

Both were the same missing information: the slot the checker had already chosen
for each written element was not carried past checking.

### Measured cost

`hello`, `robot_arena`, and `game_of_life` produce **byte-identical**
executables before and after (188416, 194048, 370176 bytes), and front-end time
is unchanged within noise (medians 771/717/976 ms before, 712/736/947 ms after).
A record result lowers to the same by-value aggregate the old internal
multi-result convention used, now as a named LLVM struct rather than an unnamed
literal one, so register classification and the `sret` threshold are unchanged —
those paths were already written under `len(results) == 1`.

`src/` is +1397/-1295 lines: roughly 350 lines of new feature (anonymous record
interning, destructuring, the evaluation schedule) against roughly 450 lines of
deleted machinery.

## Context

Three consolidation plans have shipped. `consolidation-phase-1a-plan.md` gave
every destination-sensitive producer a fixed arity;
`consolidation-provenance-plan.md` closed the aggregate-provenance and
call-contract gates; `consolidation-typed-fallibility-plan.md` replaced the
status protocol with `Option(T)`/`Result(T, E)` and one named-variant union
model.

This plan implements **step 7** of
`language-design-consolidation-proposal.md` — its sections 1, 2, and 3, and
strategy Phase 2a. It is one vertical change with three parts that land
together, because each removes the reason the others' old spellings existed:

1. **Procedures return at most one value.** Multiple results and named result
   locals go, and with them bare `return;` in a procedure that has a result.
2. **Anonymous structural records** `(key: string_view, value: int)` become the
   lightweight product type, taking over the `-> (a: T, b: U)` spelling whose
   old meaning part 1 removes.
3. **General record destructuring** `a, b := record;` replaces result-only
   multi-binding, with one rule in declarations, assignments, and `foreach`.

Why now: typed fallibility already collapsed the library to single results, so
the migration cost is at its minimum and only grows from here. `core:` has
exactly **one** multi-result procedure, `base:` and `examples:` have none, and
five naked returns in the whole live corpus return named results.

Out of scope by decision: the `()` unit spelling (open decision 5 — the shipped
`Unit :: struct {}` already covers `Result(Unit, E)`; a second spelling for one
type buys nothing yet), and step 8's removal of `manual`.

## What the corpus costs

Live corpus (`tests/tmp/**` is scratch compiler output and excluded — it holds
a stale pre-Phase-1a snapshot that should be deleted separately):

| Construct | base | core | examples | tests |
| --- | --- | --- | --- | --- |
| procedures with >1 result | 0 | 1 | 0 | 20 (14 files) |
| single named result `-> (n: T)` | 0 | 0 | 0 | 1 |
| naked `return;` returning results | 0 | 0 | 0 | 5 |
| `a, b := f()` from a call | 0 | 2 | 0 | ~9 |
| `or_return` in a multi-result proc | 0 | 0 | 0 | 1 |

The one library site is `core/strings/builder.loke:124`,
`encode_rune :: proc(value: rune) -> ([4]u8, int)`, called twice in the same
file. It becomes the plan's first worked example:
`-> (bytes: [4]u8, length: int)`.

`a, b := 20, 30` (parallel initialisation from an expression list) is a
different construct and survives unchanged. `foreach (k, v in map)` already
destructures a record and keeps working — it becomes the same rule rather than
its own.

## Fixed language contracts

### Results

| Construct | Contract |
| --- | --- |
| `Results` | `Result_Type` only. `-> T` or `-> inout T`; never a list. |
| Result names | Gone. A result is anonymous; `Type_Info.results: []Type_Id` and `result_inout: []bool` become `result: Type_Id` and `result_inout: bool`. `INVALID_TYPE` means that the procedure has no result and requires `result_inout == false`; `TYPE_VOID` remains the checked expression type of a no-result call and is not stored as a procedure result. `result_inout` **is** part of procedure-type identity today and stays so as a scalar. |
| `return` | `return expression;` when there is a result, `return;` when there is not. A bare `return;` in a procedure with a result is an error naming the deleted mechanism. |
| `inout` results | Unchanged, including `return inout place;`. This is the one place a result is still a place rather than a value. |
| `or_return` | Keeps its contract against the single result. Its multi-result half — "every result must be named and every earlier one definitely initialised" — is deleted with the definite-initialisation tracking that serves it. |

### Anonymous records

| Construct | Contract |
| --- | --- |
| Spelling | `(name: Type, ...)`, at any arity ≥ 1, in any type position. A parenthesised type is a record **iff** it is labelled; `(T)` stays expression-position grouping and is still not a type. |
| Identity | Structural: the ordered sequence of `(field name, field Type_Id)`. Field order matters; two records with the same fields in a different order are different types. Interning compares that semantic vector, never a printed type name. Equal shapes are one `Type_Id`; two nominal field types with the same unqualified spelling remain different. |
| Restrictions | Every field named and public. No `using`, no private fields, no layout attributes, no declaration site and therefore no inherent `impl`. Copy/move/drop/equality/format/reflection derive structurally, as they already do for a struct with no user hooks. |
| Alias | `Entry :: (key: string_view, value: int);` names the structural type; it does not create a nominal one. |
| Construction | The anonymous *shape* has contextual composite construction: `entry: Entry = {key="port", value=8080}`, `return .ok({key=k, value=v})`. A type alias may be used as an ordinary literal prefix (`Entry{key="port", value=8080}`), but there is no inline `(key: T, value: U){...}` prefix form; adding a `Composite_Type` alternative for it buys one redundant spelling. |
| Unit | No `()` type. `Unit` remains the no-payload spelling. |

### Destructuring

| Construct | Contract |
| --- | --- |
| Form | Two or more bindings on the left of `:=` or `=`, with one record on the right. One binding takes the whole value. Also the existing `foreach` binding list. |
| Eligibility | Exactly as many directly declared fields as bindings, every one visible at the use site. Private fields are not filtered out and `_` does not bypass visibility. Promoted (`using`) fields are not flattened. Flat only. |
| Place operand | **Clones.** `x, y := point` copy-initialises each binding; `point` stays live and drops normally. Each retained field must be copyable; the copy-cost diagnostic applies. It projects fields — it does not call the containing record's copy hook. |
| Temporary or `move(...)` | **Consumes.** Retained fields transfer without cloning. The containing record must have neither a custom `hook(copy)` nor a custom `hook(drop)`; its *fields* may. |
| `_` | Discards. Clones nothing from a place; in a consuming form the discarded field drops exactly once, in reverse declaration order. |
| Failure | Prepare retained fields in declaration order before publishing any binding; assignment keeps the existing prepare-then-write rule. On the place path, a failed clone cleans partial field temporaries and leaves the source untouched. The consuming path performs no clones; if preparation or a discarded-field drop unwinds, clean staged retained fields and every not-yet-transferred field exactly once. |

`foreach` keeps its own borrowed-key/copied-value policy and its existing
`L0504` restriction on by-value managed elements; that limitation is per-iteration
loop cleanup, not a destructuring rule, and is not lifted here.

### Slot matching

Calls and record literals share one **slot matcher**: positional fills the next
unfilled slot, a name selects one slot, positional precedes named, duplicate
fills are errors, evaluation is left to right. One policy split sits on top:
omitted call parameters evaluate their defaults in parameter order after the
supplied arguments bind; omitted record fields zero-fill.

This does **not** change literal acceptance. The checker already accepts
`Point{1, y=2}` and zero-fills omitted positional fields; only `design.md` still
says that an unnamed list must supply all fields or no fields. Preserve the
shipped behavior with a regression test before factoring the matcher, then fix
the stale specification in the same change.

### Compatibility note for reinterpreted result syntax

The source spelling `-> (a: int, b: int)` is necessarily ambiguous with the
deleted named-result syntax. It is reinterpreted as one anonymous-record result.
That is an intentional compatibility break: result names used to be excluded
from procedure-type identity, while anonymous-record field names are included.
Consequently `proc() -> (a: int, b: int)` and
`proc() -> (x: int, y: int)` were compatible before this phase and are not
compatible after it. Likewise `-> (n: T)` changes from one named `T` result to
one `(n: T)` record result. Record this break in the migration notes and test it
for procedure values, overloads, interfaces, reflection, and ABI lowering.

## Implementation sequence

### 1. Baseline

- Run and preserve `odin test src`, `odin test tests`, and `test-all.ps1` at
  `minimal`, `size`, `speed`, and `aggressive`. Record revision and toolchain
  versions.
- Record the `loke`-CC lowering of the current multi-result forms before
  deleting them: `-> (int, int)` today builds an anonymous literal struct in
  `llvm_result_type` (`src/emit_llvm_abi.odin:525`). Capture the IR for
  `divmod`, `minmax`, and `encode_rune` so the verification section's ABI
  comparison is checked against a real baseline rather than asserted.
- Delete the stale `tests/tmp/phase1a-review/` snapshot, or confirm it is
  ignored; it is a pre-migration copy of the whole tree and distorts every
  inventory run.

### 2. One result

Roughly 700–1000 lines across ~25 files are keyed to result arity, and almost
all of it is deletion rather than rewrite. The spine is
`Expr_Base.result_types: []Type_Id` (`src/ast.odin:31`) — 72 references across
12 files, and after Phase 1a **procedure signatures are its only remaining
source**: `Expr_Checked_Extract`, `or_else`, and `or_return` each already
produce exactly one value.

Land it in two independently testable halves, keeping `result_types` as a
one-element slice through the middle if that helps bisect a regression. It is
deleted at the end of the second half rather than replaced by another field:
`Expr_Base.type` already holds the one result type or `TYPE_VOID` for a
no-result call.

**Front end and checker.**

- **Parser** (`src/parser.odin:2595` `parse_results`, `:2627`
  `parse_result_item`): `parse_result_item` disappears; `Result.names` and
  `Result.symbols` (`src/ast.odin:471`) go with it, and `Stmt_Return.values`
  (`ast.odin:931`) becomes one optional `Return_Value`. The parenthesised result
  list is not so much deleted as **reinterpreted** — after step 3 it parses as
  an anonymous record type, so `-> (a: int, b: int)` keeps compiling and changes
  meaning. `-> (int, int)` and the mixed `-> (ok: bool, int)`
  (`tests/syntax/types.loke:59`) become errors naming the record spelling.
- **Semantic** (`src/semantic.odin:209-210`, `:612-618`, `:977-1034`): the two
  result slices collapse to scalars on `Type_Info` and on `Symbol`. Both use
  `INVALID_TYPE` for no result; `result_inout` must be false in that state.
  A checked no-result call still has expression type `TYPE_VOID`, preserving
  `check_single_expr`'s `L0309` distinction between a value and no value.
  `intern_proc_type`'s vector compare (`:993`), `proc_types_equal` (`:1089`),
  `type_name`'s multi-result branch (`:1696-1708`), and the `:r<inout>{…}`
  repetition in `typeid_sort_key_walk` (`src/reflect.odin:370-373`) all
  simplify with it.
- **Named result locals**: delete symbol kind `.Result` (`semantic.odin:498`)
  and everything keyed to it — `Symbol.result_symbols`, the declaration
  expansion at `src/check.odin:884-913`, scope install at `:1869-1874`, and the
  `Checker` state at `check.odin:48-57` (`result_symbols`, `named_results`,
  `assigned_results`) with its save/restore in `check.odin:1826-1853`,
  `eval.odin:190-203`, and `interface.odin:334-345`.
- **The definite-initialisation dataflow exists only for `or_return`** and dies
  whole: `note_result_assigned`, `clone_result_assignments`,
  `intersect_result_assignments` (`src/optional.odin:315-345`) and all five
  join points — if/else (`check.odin:2377`), for (`:2436`), switch (`:2486`),
  variant switch (`optional.odin:399-531`), foreach
  (`src/iterate.odin:1000`). `check_or_return_target`'s multi-result clause
  (`optional.odin:289-309`) goes with them, and `last` becomes `0` everywhere.
- **Bare `return;`** (`check.odin:2697-2702`) rejects a procedure with a result,
  with a diagnostic naming the removed mechanism. The `lifecycle.odin:239` /
  `cfg.odin:593` "named result transfers ownership" path goes.
- Only `check_single_expr`'s `L0382` multi-value gate
  (`src/check_expr.odin:123-133`) is deleted. The helper and its `TYPE_VOID` /
  `L0309` no-value gate remain: every *value-producing* expression now produces
  one value, while a no-result call still produces none.

**Back end, evaluator, and provenance.**

- `llvm_result_type` (`src/emit_llvm_abi.odin:525`) loses its `n → {T0, T1, …}`
  arm; `emit_epilogue`'s `insertvalue` chain (`emit_llvm_stmt.odin:727-741`)
  and the `extractvalue` loop at call sites
  (`emit_llvm_calls.odin:1070-1087`) go with it. `emit_multi_value`
  (`emit_llvm_calls.odin:260`) and `emit_multi_call` (`:728`) collapse to
  `emit_expr` — every arm but one already returns a single element.
  `Emitter.result_slots` (`emit_llvm.odin:31-42`) becomes one slot.
- `sret` and register classification (`src/abi.odin:103-110`,
  `emit_llvm_abi.odin:581-920`) need **no change** — every one of those paths is
  already written under `len(results) == 1`. The foreign one-result check
  (`abi.odin:71-73`, `L0620`) becomes unreachable and is deleted.
- `Eval_Frame.results` / `result_slots` (`src/eval.odin:63-64`) become optional
  scalars (`result.type == INVALID_TYPE` and a nil slot mean no result);
  `eval_return`'s bare-return arm (`:2535-2541`) and `eval_or_return`'s
  earlier-result copy loop (`:1578-1588`) go. A no-result frame returns ordinary
  control flow without manufacturing a `TYPE_VOID` procedure result.
- **Provenance simplifies rather than merely following**:
  `Proc_Summary.results: []Result_Provenance` (`src/borrow.odin:890`) becomes
  one `Result_Provenance`, and `Prov_Event.result: int` plus
  `Flow_Graph.call_results: map[^Expr_Call][]Prov_Call_Result`
  (`src/cfg.odin:162-165`, `:270`) collapse to scalars. `cfg.odin:1062-1100`
  already only models the last result, so the special case disappears with the
  index.
- `interface.odin:652-665` `slot_signature` is the **other** place result names
  expand into arity (`for _ in 0 ..< max(len(result.names), 1)`); it and
  `slot_matches` (`:673-703`) become scalar comparisons. Same for the witness
  and dyn paths (`src/erased.odin:224-247`, `:767-790`, `:1139-1148`) and the
  synthetic iterator `next` (`src/iterate.odin:379-427`).

Retiring diagnostics: **L0382**, **L0620**, and the named-result halves of
**L0429**/**L0430**. **L0326** stays with scalar wording for both remaining
contract errors: a result procedure uses bare `return;`, or a no-result
procedure returns an expression. **L0308** and **L0360** stay but lose their
one-call-fills-many escape hatch.

### 3. Anonymous records

Reuse, in order of what already exists:

- **Type construction**: `src/iterate.odin:159` `element_record` already builds
  a `Type_Info{kind = .Struct}` with `new_field(..., public = true)` and no
  declaration site. Generalise only the shape-compatible element records
  (`Map_Entry`, `indexed()`, and `rune_offsets()`) to N fields through
  `anon_record_type(c, fields)`. `Range(T)` and iterator state remain distinct
  compiler-owned types because they carry behavior/metadata beyond their field
  vectors.
- **Separate identity from display**: add `anonymous_record: bool` to
  `Type_Info`. `name` may hold the readable spelling
  `(key: string_view, value: int)` for diagnostics and runtime metadata, but it
  is never an identity key. `typeid_sort_key_walk` handles
  `anonymous_record` *before* its existing `info.name` branch and emits the
  ordered field names plus the recursive stable sort key of every field type.
  That same structural key supplies an injectively escaped backend `mangled`
  spelling for `qualified_member_name`; two packages' unrelated `Token` types
  therefore cannot collide merely because `type_name` prints both as `Token`.
- **Interning**: `Type_Key` (`semantic.odin:257`) has no field-vector slot.
  Introduce `Anon_Record_Field {name: Identifier_Id, type: Type_Id}` and add an
  `anon_record_types: map[u64][]Type_Id` bucket table on `Compiler`.
  `anon_record_type` accepts those specs rather than pre-created field symbols,
  so a cache hit does not leak orphan `Symbol`s. Hash the ordered pairs only to
  choose a bucket; compare every pair against each candidate's `info.fields`
  before reusing its `Type_Id`, so a hash or display-name collision is harmless.
  On a miss, create the public field symbols in semantic storage and publish the
  completed type. Do not key this table by `type_name` or any canonical display
  string.
- **Parsing**: add a `.Lparen` case to `parse_type` (`src/parser.odin:2210`) and
  a parser-aware `starts_anon_record_type(p)` predicate. It performs the same
  bounded identifier-list scan as `starts_declaration`: `Ident (',' Ident)* ':'`
  starts an anonymous record, which correctly recognises `(a, b: int)` as well
  as `(a: int)`. In `parse_primary`'s `.Lparen` branch, test the predicate before
  consuming the opener and dispatch directly to `parse_type`; that also covers
  the constant/type-value path used by `Entry :: (...)`. Do not add `.Lparen`
  to the token-only `starts_type(kind)` predicate and thereby misclassify
  ordinary grouping. In `parse_type_name` (`parser.odin:2410`), detect a
  labelled-field start after the trailing `(` and reject `Foo(x: int)` with a
  focused diagnostic instead of sending it through generic-argument recovery.
- **Field grammar and checking**: add `Type_Anon_Record` plus a dedicated
  `parse_anon_record_fields`, reusing the `Field` AST representation but not
  `parse_parameter_list`. It accepts only one or more identifier names, `:`, a
  type, and comma-separated groups until `)`. Parameter-only attributes, `$`
  names, `inout`, `move`, variadics, defaults, and missing types are syntax
  errors; promotion, privacy, and layout attributes are unavailable by
  grammar. Add `resolve_type_syntax`, `ast_clone.odin`, and `ast_dump.odin`
  cases. A diagnostic points to a declared struct when any excluded feature is
  attempted.
- **Lifecycle**: nothing new. `contribute_lifecycle_members`
  (`src/hooks.odin:287`) keys on the underlying type id and walks `info.fields`;
  `generated_hook` → `synth_proc` (`src/iterate.odin:369`) already builds
  symbols with `span = no_span()`. One ordering constraint applies: an anonymous
  record type must be created before `c.lifecycle_operations_ready`
  (`hooks.odin:298`), so it must be interned during checking, never first
  materialised in the emitter.
- **Layout, zero, comparability, formatting** (`src/layout.odin:48`,
  `src/zero.odin:33`, `semantic.odin:1406`, `src/format.odin:25`) read
  `info.fields` only and need no change.

### 4. Destructuring

- **Checker**: the seam is already cut. `src/check.odin:1618-1628` handles
  `len(d.values) == 1 && len(d.names) > 1` by matching `result_types`; replace
  that body with "the single value's type is a record with `len(d.names)`
  visible fields". Same for assignment at `src/check.odin:2078-2087`. The
  eligibility and per-field binding code is `check_foreach_body`'s N-binding
  branch (`src/iterate.odin:892-915`) — `require_visible_field`, positional
  field walk, `report_arity_mismatch` — lifted into a shared helper both call.
  Store the resolved field symbols/types and the per-field clone/discard policy
  on the checked declaration or assignment; later phases consume that decision
  instead of reclassifying the operand syntactically.
- **Ownership**: the clone-vs-consume rule is the new work. Classify by operand
  category with a new `classify_destructure`; the existing
  `classify_declaration_copies` / `classify_assignment_copies`
  (`src/lifecycle.odin:333`, `:357`) deliberately return when value and target
  counts differ, so they cannot directly classify this form. Reuse their
  `classify_copy` and copy-cost helpers for each retained field on the cloning
  path. Reject a consuming destructure of a record with a custom `hook(copy)`
  or `hook(drop)`, suggesting a whole-value binding or an explicit
  type-provided decomposition procedure.
- **Emitter**: replace `emit_local_decl`'s multi-value branch
  (`src/emit_llvm_stmt.odin:127-145`) and its assignment twin (`:240`) with a
  single-evaluation record projection: evaluate the operand once, then bind or
  transfer each field, dropping discarded fields exactly once in reverse
  declaration order on the consuming path.
- **Compile-time evaluator**: replace the call-only multi-result branches in
  `eval_local_decl` (`src/eval.odin:2199-2212`) and `eval_assign`
  (`:2282-2301`) with the same checked record projection. Evaluate the operand
  once; clone retained fields from a place, transfer them from a temporary or
  `move`, skip `_`, clean partial clones on failure, and prepare every assignment
  value before resolving destinations or writing. Compile-time evaluation must
  not fall through to the ordinary one-value-per-symbol loops.
- **CFG/borrow**: `src/cfg.odin:703`, `:3214`, `:3318` currently reason about
  multi-result bindings; they reason about one record value and its projected
  fields instead. Field-level provenance already exists from Phase 4a — a
  destructure must give each binding that field's own root, not a joined set.

### 5. Shared slot matcher

`bind_arguments` (`src/check_expr.odin:3459`) and `check_struct_literal`
(`src/check_expr.odin:3899`) are today two matchers with the same structure and
no shared code: named lookup, `filled`/`seen` duplicate detection,
positional-after-named rejection, arity. Factor one **matching-only** core over
"a slot list with names and types". It returns the slot chosen for each written
source element plus the filled vector; it never evaluates or reorders an
expression. Calls layer defaults from `declared.param_defaults` on top, while
literals apply `require_type_has_zero` to omitted fields. Variadics
(`bind_variadic_arguments`, `bind_c_vararg_arguments`) stay on the call side; a
call still does not materialise an argument record, so parameter modes,
`inout`, and ABI classification are untouched.

Preserve a separate evaluation schedule. Supplied call arguments evaluate once
in `v.args` source order and are staged into their matched parameter slots;
omitted defaults then evaluate once in parameter order; only the final ABI
operand list is parameter-ordered. `v.bound` by itself is insufficient because
it is parameter-ordered today. Struct literal elements likewise evaluate in
source order before their values are placed into field-order storage. Apply the
same schedule in the evaluator and emitter, and test named arguments written in
reverse parameter order with observable side effects.

Before factoring, add a regression that the current checker accepts
`Point{1, y=2}` and zero-fills the omitted fields of `Point{1}`. Preserve that
behavior. `check_expr.odin:3945` is only the too-many-fields check; there is no
"all fields or none" checker restriction to lift. Rewrite the stale paragraph
in `design.md` as a specification correction, not a compatibility change.

This remains a net simplification in validation (two matchers → one core plus
two omission policies), but the source-order schedule is required correctness,
not optional factoring. If the matcher extraction slips, the rest of the plan
still lands — but then preserve both existing matchers and say so rather than
shipping a partial abstraction or reordering side effects.

### 6. Corpus migration

- `core/strings/builder.loke`: `encode_rune -> (bytes: [4]u8, length: int)`,
  and its two call sites become `encoded, count := encode_rune(value);` —
  the same source line, now a destructure of a record temporary.
- The 20 multi-result test procedures: `divmod`, `minmax`, `forward`,
  `result_many`, `multi_result`, and the syntax-corpus entries become anonymous
  record results. Keep `tests/run/m2_procs.loke` and `m2_integrated.loke` as the
  canonical destructuring tests they already are.
- Migrate named-result locals explicitly rather than relying on the identical
  surface syntax: `minmax`/`divmod` return contextual record literals on every
  path, and `tests/run/m5b_aggregate_baseline.loke`'s one-field
  `result_named -> (out: Pair)` becomes `-> Pair` with an ordinary local and
  `return out;`. All five bare returns that currently publish named result slots
  become expression returns.
- `tests/err/multi_value.{loke,expected}` deletes with `L0382`;
  `tests/err/m7_conventions.expected` and `tests/err/m4a_unions.expected` need
  edits. `tests/err/optional_arity.loke` and the `m5b_*` negative fixtures
  retarget to the new diagnostics — a bare `return;` with a result, an
  unlabelled `(T, U)` result, an arity mismatch against a record's field count,
  a destructure hiding a private field, and a consuming destructure of a record
  with a custom hook.
- Two embedded programs in `src/*_test.odin` also use multi-result signatures
  and migrate with the rest.
- `tests/syntax/types.loke:55-60` and `tests/syntax/ambiguity/`: add the
  labelled-versus-grouping cases — `(T)` in expression position still converts,
  `(x: int)` in type position is a record, `Foo(x: int)` is not a generic
  application. Add `(a, b: int)` as a positive grouped-field case and reject
  parameter-only spellings: `$a`, `a: inout T`, `a: move T`, `a: ..T`,
  `a: = value`, an attribute, and a missing field type.
- One new negative case with no existing home: `-> (ok: bool, int)`, mixed
  labelled and unlabelled, must be rejected rather than silently read as a
  one-field record.
- Add procedure-value and interface fixtures showing the intentional break:
  `(a: int, b: int)` and `(x: int, y: int)` are distinct result types, while
  identical record shapes written at separate sites are compatible. Include the
  one-field `-> (n: T)` reinterpretation explicitly.
- Replace the evaluator's existing compile-time multi-result fixtures with
  anonymous-record destructuring fixtures for declaration and assignment. Cover
  place cloning, temporary/move consumption, `_`, and prepare-before-write.

### 7. Specification

Land with the implementation:

- `design.md`: delete `#### Multiple results` (4225) and `#### Named results`
  (4282); keep `#### inout results` (4237) unchanged. Rewrite the `or_return`
  multi-result paragraph (5421-5423). Replace the tuple-deferral sentence at
  2991 with the destructuring rules. Add anonymous records next to `### Structs`
  (1220) and `#### Struct literals` (1245). Correct the stale all-or-none
  positional-literal paragraph to describe the already-shipped mixed and
  zero-fill behavior; do not label it as a language change.
- `grammar.md`: `Results = Result_Type` (411-415); a parenthesised labelled
  `Type` production (257-271); `Return_Statement` loses its value **list**
  (490-492); the destructuring hooks on `Variable_Decl` (197-205) and
  `Assignment` (453-462); a note at 630 that an anonymous record literal is
  contextually typed only.
- `language-design-consolidation-proposal.md`: mark sections 1, 2, 3 adopted
  with the deviations (no `()`, no inline shape-prefixed literal), and
  answer open decisions 5 (deferred), 6 (flat destructuring, with evidence), and
  7 (identity includes names).
- `language-refinement-strategy.md`: record the Phase 2a outcome.
- `comments.md`: the measured cost and any rejected alternative.
  Include the named-result-to-record procedure-compatibility break and the
  reason semantic vector interning was chosen over display-string interning.

## Verification

### Semantic evidence

- **Results**: reject `-> (int, int)`, `-> (ok: bool, int)`, and a bare
  `return;` in a procedure with a result. Accept `-> inout T` with
  `return inout place;` unchanged. Check direct, generic, overloaded,
  procedure-value, interface-slot, and compile-time calls. Confirm a no-result
  procedure stores `INVALID_TYPE`/`false`, while its checked call expression is
  still `TYPE_VOID` and still triggers `L0309` in a value context.
- **Reinterpreted compatibility**: reject assignment between procedure values
  returning `(a: int, b: int)` and `(x: int, y: int)`; accept identical shapes
  from different sites. Repeat through an interface slot and an overload so the
  break is explicit rather than an accidental checker detail.
- **Record identity**: two identical anonymous records in different files are
  the same type and interoperate; reordered fields are not; an alias is not
  nominal. Two packages that each export a distinct nominal `Token` must make
  `(value: a.Token)` and `(value: b.Token)` different anonymous records despite
  their equal display spelling. `typeid` and reflection distinguish them, and
  generated hook symbols do not collide.
- **Parser boundary**: accept `(a: int)` and `(a, b: int)` as record types;
  preserve `(T)` as expression grouping; reject mixed labelled/unlabelled fields
  and every parameter-only field feature listed in the migration section.
- **Literals**: pin the pre-change acceptance of positional, named, mixed, and
  partial positional forms; reject duplicate fill; zero-fill omitted fields;
  reject a no-zero field type in a partial literal. Use side-effecting named
  elements written out of field order to prove source-order evaluation. Accept
  both contextual `{...}` and alias-prefixed `Entry{...}` construction, while
  rejecting an inline `(field: T){...}` prefix.
- **Slot evaluation order**: call a procedure with named arguments written in
  reverse parameter order and side-effecting operands; supplied operands must
  run in source order, followed by omitted defaults in parameter order, at both
  runtime and compile time. The final callee still receives parameter-order
  operands.
- **Destructuring**: place clones and the source stays live; temporary and
  `move` consume; `_` drops a discarded owning field exactly once in reverse
  order; a private field is rejected; a promoted field is not flattened; a
  consuming destructure of a record with a custom hook is rejected; a failed
  clone mid-sequence cleans up without writing destinations, under every panic
  strategy. Run the declaration and assignment matrix both at runtime and in
  the compile-time evaluator.
- **Ownership through `or_return`**: `name, bytes := read_document(path)
  or_return;` consumes the temporary with no clone, while binding first and
  destructuring the place clones — and the copy-cost diagnostic reports the
  second. This is proposal §8.3 and is the pair that proves the rule is visible.
- **Provenance**: a borrow inside an anonymous record is caught exactly where
  its bare twin is — reproduce the `m5b_aggregate_baseline` /
  `m5b_aggregate_wrapping` acceptance set with anonymous record payloads, and
  keep `wrap`/`unwrap` legal. Each destructured binding takes its own field's
  root, not a join.
- **`foreach` parity**: existing map and `indexed()` loops are unchanged, and
  the same arity/visibility diagnostics now come from the shared helper.

### Backend and cost evidence

- Compare `-> (a: int, b: int)` as an anonymous record against the baseline
  `-> (int, int)` literal-struct lowering from step 1: register classification,
  `sret` threshold, and generated IR. Any difference is intentional and
  recorded, not discovered later.
- Confirm no anonymous record type is first materialised in the emitter
  (`hooks.odin:298`'s contract error is the detector).
- Front-end time and binary size on `hello`, `robot_arena`, and
  `game_of_life`, against the same baseline the typed-fallibility plan used, so
  the three consolidation changes have one comparable series.

### Test matrix

- `odin test src`
- `odin test tests`
- `test-all.ps1` at `minimal`, `size`, `speed`, `aggressive`
- every supported panic strategy for the destructuring cleanup fixtures

## Boundaries

- Unchanged: `inout` parameters, receivers, and results; `manual`; container
  representation and map insertion policy; `Option`/`Result` and the failure
  protocol; interface mechanics; `foreach`'s borrowed-key and `L0504` policies.
- Deferred: `()` as a type spelling (open decision 5); nested/pattern
  destructuring (open decision 6 — flat only, with the evidence recorded);
  `find` and place results (open decision 8, step 9); `manual` (step 8).
- Do not give anonymous records privileged provenance or lifecycle treatment to
  make the migration work. If a rule needs an exception for them, that is
  evidence against the structural type, not a licence.

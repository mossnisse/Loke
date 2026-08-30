# Fifth consolidation implementation plan: cleanup policy, storage, and removal of `manual`

Status: **implemented.** See [Outcome](#outcome).

## Context

Steps 2–7 of
[`language-design-consolidation-proposal.md`](language-design-consolidation-proposal.md#13-proposed-migration-order)
have shipped:
[`consolidation-phase-1a-plan.md`](consolidation-phase-1a-plan.md) gave each
producer behaviour its own spelling,
[`consolidation-provenance-plan.md`](consolidation-provenance-plan.md) closed the
aggregate-provenance and call-contract gates,
[`consolidation-typed-fallibility-plan.md`](consolidation-typed-fallibility-plan.md)
made failure a value, and
[`consolidation-one-result-anonymous-records-plan.md`](consolidation-one-result-anonymous-records-plan.md)
reduced every procedure to one result.

This plan covers **step 8** — validate the real manual-storage cases, add
`unsafe.forget`, migrate those cases, then remove `manual` — and the **step 9**
reviews, which are decision records rather than code.

Section [6](language-design-consolidation-proposal.md#6-cleanup-stack-storage-and-removal-of-manual)
is the normative source; strategy
[Phase 5d](language-refinement-strategy.md#phase-5d--keep-storage-policy-distinct-from-value-ownership)
sets the exit condition.

This is a small phase. The compiler's `manual` surface is about 30 lines across
15 files. The corpus has 13 actual modifier uses across six files, plus two
existing fixtures where `manual` is already an ordinary type name. The
replacement is one built-in. It is worth doing as its own vertical change
because it *deletes* a grammar axis, a `Symbol` field, and a CFG field, and
because the terminology it fixes ("manual" naming both cleanup policy and
allocation roots) is currently wrong in `design.md` in about twenty places.

## Baseline: every `manual` that exists

| Site | What it does | Replacement |
| --- | --- | --- |
| [`tests/run/m5a_ownership.loke:195`](tests/run/m5a_ownership.loke:195) `held: manual Res` | live at scope exit, never dropped — a deliberate leak | `unsafe.forget(move(held))` |
| [`tests/run/m5a_ownership.loke:196`](tests/run/m5a_ownership.loke:196) `released: manual Res` | explicit `drop` | ordinary owner, same `drop` |
| [`tests/run/m6b_regions.loke:85`](tests/run/m6b_regions.loke:85) `raw: manual [dynamic]u8 via arena.allocator()` | explicit `drop` before `free_all` | ordinary owner, same `drop` |
| [`tests/err/deferred_families.loke:18`](tests/err/deferred_families.loke:18) `pooled: manual int via allocator_of()` | rejects `via` at file scope | drop the modifier; the diagnostic is about `via` |
| [`tests/syntax/declarations.loke`](tests/syntax/declarations.loke) ×6 modifier uses | parse-shape fixtures; the file also has one existing ordinary-type use | rewrite the six modifier forms; retain and extend the ordinary-identifier/type coverage |
| [`tests/syntax/ambiguity/03-storage-modifiers.loke`](tests/syntax/ambiguity/03-storage-modifiers.loke) ×2 modifier uses plus one existing ordinary-type use, [`19-declaration-forms.loke:27`](tests/syntax/ambiguity/19-declaration-forms.loke:27) ×1 modifier use | contextual-keyword fixtures | rewrite the three modifier forms; keep `manual` as an ordinary identifier and type name |
| [`base:`](base), [`core:`](core), [`examples/`](examples) | **no uses at all** | — |

Exactly **one** site in the entire corpus needs cleanup suppression. Everything
else is an ordinary owner that already writes its own `drop`. Record this in the
Phase 5d decision: `manual` is not paying for itself.

Two `manual` behaviours have no corpus user and must still get a spelling before
removal, or the plan is a silent capability loss:

- **Foreign handoff.** `held`'s pattern — the resource escaped to something else
  that now owns it. Answered by `unsafe.forget`.
- **Undropped `thread_local` owner.**
  [`src/emit_llvm_runtime.odin:212`](src/emit_llvm_runtime.odin:212) skips a
  `manual` TLS owner in the detach teardown. No corpus program uses it. Answered
  by `unsafe.forget(exchange(inout value, {}))`, which is already legal on
  static-duration storage where direct `drop`/`move` are not
  ([`design.md:5832`](design.md#L5832)). No new static-duration rule is needed;
  the built-in-specific temporary rule above is what accepts the `exchange`
  result.

Process-duration `static` owners are never dropped automatically today, so
`manual` was already inert there.

## Fixed language contracts

### `unsafe.forget`

`unsafe.forget(value)` consumes an owning operand, marks it dead, and runs no
`drop` hook. It is contributed by `core:unsafe` exactly as `unsafe.raw_data` is
([`src/stdlib.odin:64`](src/stdlib.odin:64)) — a `Builtin_Kind`, not an ordinary
procedure, because no signature can express "consume without cleanup".

- **The operand follows a narrow, built-in-specific consuming rule.** A lexical
  place must be written `move(place)` and is then subject to `move`'s existing
  lexical-owner and static-duration checks. A value temporary is accepted
  directly, which is what permits
  `unsafe.forget(exchange(inout tls_value, {}))`. This temporary exception does
  **not** change ordinary `move` parameters or consuming receivers, which still
  require a written `move(...)`. `unsafe.forget(local)` is rejected with the
  consuming-argument diagnostic.
- **The operand must own something or be provenance-free.** A managed value is
  accepted even when it contains checked borrows; forgetting it leaks the owned
  resource and ends the contained loans. An unmanaged value is accepted only
  when `type_carries_borrow(type).any` is false. This keeps generic scalar and
  plain-record instantiations valid while rejecting bare checked pointers,
  slices, views, `dyn` values, borrow-only records, and temporaries such as
  `&local`. Raw pointers and multi-pointers carry no checked provenance and are
  accepted like other unmanaged scalars; `forget` does not release any
  allocation they designate.
- **No cleanup runs**, for the operand or for anything it owns transitively.
- **The source binding becomes dead.** `move` already emits the `Kill` event
  ([`src/cfg.odin:1004`](src/cfg.odin:1004)); use-after-forget and
  forget-after-move are the existing use-after-move diagnostics.
- **Nothing is extended.** No heap promotion, no address stabilization, no frame
  preservation. A borrow of a forgotten owner is invalidated at the `forget`,
  the same as at a `drop` — conservative, and it is what keeps `forget` from
  reading as a lifetime extension.
- **A provenance-free unmanaged operand is accepted silently.** `forget` exists
  for the generic case, where `T` may or may not be managed; a diagnostic for an
  `int` or plain record would make that generic use impossible. A generic
  instantiation whose unmanaged `T` carries a checked borrow is rejected by the
  preceding rule.
- **Result is `Unit`**, matching `drop`.
- **Nothing is emitted** beyond evaluating the operand for its side effects.
  Concretely: the emitter takes the value and skips
  [`emit_discarded_temporary`](src/emit_llvm_cleanup.odin:658). That one skipped
  call is the entire runtime meaning of the feature.

### Terminology

`design.md` must use three distinct terms and stop using "manual" for two of
them:

- **automatic owner** — a lexical value cleaned up at scope exit;
- **allocation root** — `new`/`new_clone` storage, released by `free` or a region
  reset;
- **forgotten owner** — a value whose cleanup was explicitly suppressed.

### What does not change

Stack placement, allocator selection via `via`, backing-storage location, region
provenance, failure atomicity, `inout`, and every `drop`/`move`/`exchange` rule.
Removing `manual` removes a *cleanup-policy* modifier and nothing else; the
modifier grammar drops to one axis (duration).

## Open decisions this phase answers

- **9 — which case still needs an undropped inline owner?** One, and it is a
  deliberate leak. `unsafe.forget` covers it; `unsafe.Maybe_Uninit(T)` has no
  demonstrated user and is **not built** (section 6.6 conditions it on a real
  implementation need).
- **10 — can foreign handoff use a consuming `into_raw` instead?** `fs.File`
  already has the inert-making half (`close`,
  [`core/fs/fs.loke:83`](core/fs/fs.loke:83)), so `into_raw`/`from_raw` is ~5
  lines whenever a handoff appears. None does today. Record the pattern in
  `design.md` as the preferred alternative; add the members when a caller
  exists, not before.
- **8 — does `table.find(key)` return `Option(^mut V)`?** Already answered by
  typed fallibility ([`design.md:1154`](design.md#L1154)). This phase closes the
  decision and fixes the one stale example that still destructures it as two
  values ([`design.md:2026`](design.md#L2026)).
- **11 — do `inout` results justify their place semantics?** Reviewed, **not
  changed.** The evidence to record is the list of current `inout`-result users
  (place-returning indexing, user-defined mutable projections) and what each
  would become as `^mut T`: a nullable first-class value with different
  assignment and address-taking rules. Proposal section 7 already states the
  provisional keep; this phase turns it into a recorded decision with the user
  list attached, and ships no change.

## Implementation sequence

### 1. Baseline

Capture IR and behaviour for the corpus at the current commit, per
[`differential-opt-corpus`](tests): `test-all.ps1` clean at every `-opt` level,
and saved `.ll` for `run-m5a_ownership`, `run-m5a_lifecycle`, `run-m6b_regions`,
and `greeting` (the no-`manual` control). Steps 3 and 4 are checked against these.

### 2. Add `unsafe.forget`

- [`src/semantic.odin:584`](src/semantic.odin:584): add `Unsafe_Forget` to
  `Builtin_Kind`, beside the other `Unsafe_*` kinds.
- [`src/stdlib.odin:64`](src/stdlib.odin:64): `contribute_builtin(c, pkg,
  "forget", .Unsafe_Forget)` under `STD_UNSAFE`.
- [`src/check_expr.odin:2616`](src/check_expr.odin:2616): add a dedicated
  `check_forget_builtin` — arity 1, positional value syntax only, result `Unit`.
  Check the operand once. Any place requires `move(place)`; an
  `Expr_Move` reuses `check_move`; a non-place is the built-in's owned-temporary
  path. Reject `!type_is_managed(type) && type_carries_borrow(type).any`. Add
  the kind to the two exhaustive lists at
  [3017](src/check_expr.odin:3017) and [3181](src/check_expr.odin:3181).
- [`src/cfg.odin`](src/cfg.odin): nothing new in the lifecycle walk for the
  `move(place)` form — `Expr_Move` already kills the slot. In the provenance
  built-in switch at [3690](src/cfg.odin:3690), give `Unsafe_Forget` its own arm
  and call `prov_consume(graph, v.bound[0], v.span, "forgotten")`, discarding
  the returned carriers. `prov_consume` unwraps `Expr_Move`, preserves the
  `"forgotten"` verb for conflicts, invalidates the source root, and walks a
  temporary operand so any loans it contains end with the discarded value.
- [`src/emit_llvm_calls.odin:80`](src/emit_llvm_calls.odin:80): emit the operand,
  return `"0"`, and do **not** call `emit_discarded_temporary`.
- [`src/eval.odin:1970`](src/eval.odin:1970): compile-time case with two explicit
  paths. For `Expr_Move`, evaluate the inner lexical place (not the unsupported
  move node), discard its value, and replace the slot with its zero when one
  exists; the CFG already makes the binding dead. For a temporary, call
  `eval_expr` once and discard the result. Neither path invokes a hook.
- Exhaustive switches: [`src/format.odin:133`](src/format.odin:133),
  [`src/text.odin:321`](src/text.odin:321),
  [`src/reflect.odin:493`](src/reflect.odin:493).

Land this step with its tests (see Verification) *before* touching `manual`, so
the replacement is proven working while the thing it replaces still exists.

### 3. Migrate the corpus

Migrate all 13 modifier uses from the baseline table. The two existing
ordinary-type uses remain. `tests/run/m5a_ownership.loke`'s `manual_owner`
becomes `forgotten_owner` and keeps its printed drop counts — that expected
output is the evidence that suppression works. The syntax fixtures in
`tests/syntax/` invert: they now assert `manual` parses as an ordinary identifier
and type name.

### 4. Remove `manual`

Grammar and AST:

- [`src/parser.odin:834`](src/parser.odin:834) `parse_storage_modifiers`: delete
  `is_manual`, its `case`, and the duplicate-`manual` arm of `L0232`. The loop
  keeps only duration.
- [`src/parser.odin:887`](src/parser.odin:887) `finish_constant` and
  [`src/impl.odin:86`](src/impl.odin:86): drop `d.manual` from the guards.
- [`src/ast.odin:1051`](src/ast.odin:1051),
  [`src/ast_clone.odin:593`](src/ast_clone.odin:593),
  [`src/ast_dump.odin:168`](src/ast_dump.odin:168): remove the field and its dump.

Semantics:

- [`src/semantic.odin:708`](src/semantic.odin:708) and
  [`src/check.odin:1644`](src/check.odin:1644): remove `Symbol.manual`.
- [`src/cfg.odin:669`](src/cfg.odin:669): `owns_cleanup` becomes `true` at all
  three creation sites ([439](src/cfg.odin:439), [669](src/cfg.odin:669),
  [962](src/cfg.odin:962)) — **delete the field** and simplify
  [`src/lifecycle.odin:794`](src/lifecycle.odin:794) to
  `local.seen_cleanup && local.live_exit`.
- [`src/emit_llvm_runtime.odin:212`](src/emit_llvm_runtime.odin:212): drop the
  `|| sym.manual` term; TLS teardown now drops every live managed TLS owner.

Comments referring to `manual`:
[`src/borrow.odin:2097`](src/borrow.odin:2097),
[`src/cfg.odin`](src/cfg.odin) (44, 222, 659, 2716, 3446),
[`src/check_expr.odin:3171`](src/check_expr.odin:3171),
[`src/lexer.odin:297`](src/lexer.odin:297),
[`src/lifecycle.odin:735`](src/lifecycle.odin:735),
[`src/slice.odin:14`](src/slice.odin:14),
[`src/source.odin:231`](src/source.odin:231).

Keep `manual` in the lexer golden input at
[`src/front_end_test.odin:283`](src/front_end_test.odin:283): it is test data,
not a comment, and continues to prove that the word lexes as an ordinary
identifier. Its expected `.Ident` entry therefore does not change.

No migration diagnostic is added. An old explicit-type form such as
`raw: manual [dynamic]int;` parses `manual` as the type and reports the adjacent
`[dynamic]int` as unexpected syntax. An old inferred form such as
`raw: manual = [dynamic]int{};` parses `manual` as the type and reports it as
undefined. A dedicated hint is not worth a permanent special case for a
modifier no shipped program uses.

### 5. Specification

`grammar.md`:

- [64](grammar.md#L64) and [685](grammar.md#L685): remove `manual` from the
  contextual-keyword list.
- [213](grammar.md#L213): `Storage_Modifiers = Duration_Modifier?`.
- [236](grammar.md#L236), [241](grammar.md#L241): drop the two-independent-groups
  wording and the `raw: manual = ...` example.

`design.md` — about twenty sites (697, 801, 830, 939–949, 1111, 2968, 2990–3048,
3595, 4724, 4819, 5002, 5686, 5708, 5725, 5778, 5787, 5798–5836, 6333, 6428).
The substantive edits:

- "Storage modifiers" (2990): delete the **Ownership** axis; the section
  describes duration only. Add `unsafe.forget` where the removed axis was, with
  the "does not extend a lifetime" statement stated in the normative text, not
  only in an example comment.
- Replace "manual" with **automatic owner** / **allocation root** / **forgotten
  owner** everywhere, including the `new`/`make` descriptions at 5778–5805 that
  currently say "the allocation is manual".
- 2968 (TLS teardown): every live managed TLS owner is dropped; the escape is
  `unsafe.forget(exchange(inout value, {}))`.
- 6333: `static` and `thread_local` remain modifiers, one axis. Cross-reference
  proposal section 6.1 for why they do not become attributes.
- 2026: fix the stale `value, ok := table.find("a")` to the `Option` form.
- Add the preferred foreign-handoff pattern (consuming `into_raw`, unsafe
  `from_raw` inverse) as guidance, marked as a library pattern with no compiler
  support required.

Then update the proposal's open decisions 8–11 and the strategy's Phase 5d exit
condition with the recorded results.

## Verification

### Semantic evidence

New `tests/run` cases (drop counts printed, so suppression is observable):

| Case | Evidence |
| --- | --- |
| Forget suppresses cleanup | a `move_only` resource with a printing `drop` hook, forgotten at scope exit; no hook line printed |
| Forget suppresses transitively | forget a record owning a `[dynamic]T` and a `File`; neither hook runs |
| Forget of a temporary | `unsafe.forget(make_res(1))` — the temporary is not dropped |
| Conditional forget | forget on one branch only; the other branch still drops exactly once (drop-flag path) |
| Forget an unmanaged generic `T` | instantiate over `int` and over a managed type; the `int` instance emits nothing |
| Compile-time forget | an evaluated procedure forgets both `move(local_int)` and an integer temporary; evaluation succeeds and returns its remaining result |
| TLS escape | `unsafe.forget(exchange(inout tls_value, {}))`; detach teardown prints nothing |
| Ordinary owners unchanged | migrated `m5a_ownership` / `m6b_regions` produce byte-identical output to baseline |

New `tests/err` cases:

| Case | Diagnostic |
| --- | --- |
| `unsafe.forget(local)` without `move` | existing consuming-argument error |
| Use after forget | existing use-after-move error |
| Forget twice | existing use-after-move error |
| Forget a temporary checked borrow (`&local`) | rejected by the unmanaged-carrier rule |
| Forget a moved checked-pointer/slice binding | rejected by the unmanaged-carrier rule |
| Forget an unmanaged plain scalar or record | accepted silently, including through a generic `T` |
| Forget then return a borrow of the forgotten owner | rejected — `forget` is not a lifetime extension (acceptance criterion) |
| Direct forget of static-duration storage | rejected, same rule as direct `drop` |
| `x: manual int;` | syntax error at the adjacent `int`; `manual` parsed as the type |
| `x: manual = 0;` | undefined type `manual` |
| `manual` as an ordinary identifier and type name | accepted (syntax fixtures) |

### Cost evidence

- **IR diff on programs that never used `manual`** (`greeting`, `config_parser`,
  the `core:fmt` fixtures): **byte-identical** to baseline. This is the direct
  check of the acceptance criterion that removing `manual` changes no stack
  placement, allocator selection, or backing-storage location.
- **IR diff on migrated programs**: differs only by the drop calls that the
  migration intentionally adds or the `forget` removes. Inspect each hunk.
- **`unsafe.forget` emits no instructions** beyond operand evaluation — confirm
  on the generic-`int` instantiation, which should lower to nothing.
- Record the net line delta in `src/` (expected: negative — one built-in added,
  a parser branch, an AST field, a `Symbol` field, and a `Tracked_Local` field
  removed).

### Test matrix

`test-all.ps1` at every optimization level, after step 2 and again after step 4.
Compare `-opt=minimal` against `aggressive` for the forget cases specifically:
suppression must not be an optimizer artifact.


## Outcome

Every step landed as written, in the planned order: `unsafe.forget` shipped with
its tests while `manual` still existed, the corpus migrated, and only then was
the modifier removed.

**The one substantive deviation is the cost evidence.** The plan expected a
*negative* net line delta in `src/`. The measured delta is **about +80 lines**.
The prediction counted `manual`'s surface — a parser branch, an AST field, a
`Symbol` field, a `Tracked_Local` field, and their comments, roughly 30 lines
removed — but not what a built-in costs, which is a check procedure, a CFG
provenance arm, an emitter arm, a compile-time arm, and five exhaustive-switch
entries, roughly 110 lines added. The *language* got smaller by a grammar axis
and four pieces of per-declaration state; the *compiler* got slightly bigger.
That is the honest trade, and it does not change the case for the phase: what it
bought is that cleanup suppression is now a property of a value, reachable from
generic code, rather than a declaration modifier that thirteen sites used and
one of them needed.

Everything else matched the plan:

- **IR on programs that never used `manual`** — `greeting`, `config_parser`, and
  `m5a_lifecycle` are **byte-identical** to baseline. So is `m6b_regions`, whose
  migrated `raw` was already dead at scope exit through its explicit `drop`.
- **IR on `m5a_ownership`**, the one program whose behaviour the migration
  touched, differs by exactly two instructions once the `manual_owner` →
  `forgotten_owner` rename is normalised away: the load and the zeroing store of
  `move(held)`. No drop call is added or removed.
- **`unsafe.forget` emits nothing** beyond evaluating its operand. The generic
  `int` instantiation lowers to a dead load and the move's zeroing store, and no
  call at all.
- **Suppression is not an optimizer artifact.** `tests/run/unsafe_forget` gives
  identical output at `-opt=minimal` and `-opt=aggressive`, and `test-all.ps1`
  is clean at every level.
- **Both `manual` fixtures kept their ordinary-identifier coverage**, and
  `tests/syntax/ambiguity/03-storage-modifiers.loke` now also declares a
  variable named `manual`, of a type named `manual`, initialised from an
  identifier named `manual`.

New evidence lives in [`tests/run/unsafe_forget.loke`](tests/run/unsafe_forget.loke)
(eight behaviours, drop counts printed),
[`tests/err/unsafe_forget.loke`](tests/err/unsafe_forget.loke) (eight
diagnostics, including the acceptance criterion that a borrow cannot outlive a
forgotten owner), and
[`tests/err/removed_manual.loke`](tests/err/removed_manual.loke) (the two old
modifier forms, reported against `manual`-as-a-type exactly as predicted, with
no dedicated migration hint).

Two diagnostic codes were added: **L0649** for `unsafe.forget`'s call shape, and
**L0650** for an unmanaged operand that carries a checked borrow. The
consuming-operand error reuses **L0501**, the existing consuming-argument code.

### Noticed while implementing, and deliberately not fixed

- `require_lexical_owner` ([`src/lifecycle.odin`](src/lifecycle.odin)) rejects a
  `move` parameter, so `drop(p)` and `unsafe.forget(move(p))` are both refused
  inside a body that owns `p` — while `classify_return_value` in the same file
  treats a `move` parameter as owned. One of the two is wrong. Changing it is a
  `move`/`drop` operand rule, which section "What does not change" puts outside
  this phase.
- `design.md`'s `new`, `new_clone`, and `free` examples still use the pre-typed-
  fallibility two-value form (`ptr, err := new(int);`). The `make` examples in
  the same region were rewritten here because their `manual` declarations had to
  go; the `new` family was left alone. That is leftover debt from the typed-
  fallibility phase, not this one.

## Boundaries

Not in this phase, and each with its trigger for reconsideration:

- **`unsafe.Maybe_Uninit(T)`** — open decision 9 found no user. Add it when a
  real container needs raw element storage, not to preserve a removed modifier.
- **`into_raw`/`from_raw` on `fs.File`** — add with the first actual foreign
  handoff.
- **`inout` results and `find`** — reviewed and kept (decisions 8 and 11); a
  change needs its own plan.
- **`@(require_results)` on a type**, and the **`try_` family** review — proposal
  section 9 items, unrelated to cleanup policy.
- **Surface-syntax simplification** — strategy Phase 6, still last.

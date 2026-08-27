# First consolidation implementation plan: baseline and Phase 1a

## Summary

Remove destination-dependent result arity from checked extraction and map lookup.
Establish a recorded baseline, introduce explicit optional operations, migrate the
complete corpus, and delete the superseded behavior.

This milestone retains multiple results, named results, the existing status
protocol, and current map insertion policy. It does not adopt `Option`/`Result` or
implement aggregate provenance.

The corpus this touches is small — roughly ten comma-ok or `or_else` extraction
sites and four comma-ok map reads across `base`, `core`, `examples`, and `tests`,
plus the embedded programs in the compiler's own tests. The risk is not the
migration; it is the ownership and provenance semantics of the two new operations,
which is where the verification weight belongs.

## Fixed language contracts

| Operation | Results | Mismatch or missing key |
|---|---|---|
| `value.(T)` | `T` | Panics on type mismatch |
| `value.as(T)` | `(T, bool)` | Returns the zero value of `T` and `false` |
| `table[key]` in a read | `V` | Returns the zero value without inserting |
| `table.lookup_value(key)` | `(V, bool)` | Returns the zero value of `V` and `false`, without inserting |

- `as` applies to unions and `any_view`, using their existing extraction
  eligibility rules. It takes exactly one positional type argument. It is not a
  conversion and adds no keyword; ordinary members named `as` on other types remain
  unaffected.
- `lookup_value` is a compiler-contributed ordinary map member with an immutable
  receiver and one `key: K` parameter. It works on immutable parameters and
  temporary maps without requiring `inout`.
- Both optional operations evaluate their receiver and arguments once. Managed
  payloads follow existing value-copy rules; the source remains live. A returned
  owned copy must not alias exclusive backing storage or acquire a second cleanup
  responsibility for the source.
- `lookup_value` performs **exactly one** clone of a managed payload, inside the
  operation. Its result is a call value, not a borrowed place
  ([lifecycle.odin:283](src/lifecycle.odin:283)), so the destination must not clone
  it again. One clone, not zero and not two, is the contract the ownership tests
  below check in both directions.
- Copying uses the existing allocator and failure policies. A clone or user hook
  failure must not become `false`: the boolean reports only mismatch or absence.
- Map assignment, compound assignment, and field/index assignment chains retain
  their insertion behavior. `find` remains `(^mut V, bool)`; membership and
  address-taking rules stay unchanged.
- `or_else` and `or_return` consume the existing fixed status shape. Preserve named
  result initialization requirements and status-only propagation. In particular, a
  single `bool` or union result may still be an `or_return` operand; it never gains
  an optional second result.
- Validating conversions retain their names, `(value, bool)` results, zero-on-invalid
  behavior, and single-value arity diagnostics.

`find` and `lookup_value` do not read as a pair for two members that differ only in
borrowing versus copying. Settle the pairing now if it is going to change; Phase 5a
revisits the borrowed lookup API and would churn the name a second time.

## Implementation sequence

### 1. Record the baseline

- Run the complete `test-all.ps1` matrix before semantic changes. Preserve its
  output, compiler/toolchain versions, and starting revision; distinguish existing
  working-tree edits.
- Inventory destination-dependent branches for extraction and map lookup across
  checking, AST annotations, lowering, and tests. Include declaration and assignment
  destinations, fallback operands, and embedded Loke programs in compiler tests.
- Extend existing fixtures to characterize success, mismatch, absence, evaluation
  order, status propagation, managed copies, and validating conversions.
- Characterize one borrowed value through a record and through a procedure value,
  as the strategy's Phase 0 asks. Do not widen this into a survey of union, helper,
  and package-boundary cases: this milestone hands provenance to
  [`provenance-plan.md`](provenance-plan.md), and a speculative inventory ages out
  before that work reaches it.
- Keep this inventory limited to affected mechanisms. Baseline failures must be
  understood before comparison results are treated as evidence.

#### The comma-ok map read is already broken

This is known before the baseline runs, and the recorded baseline will contain it.
It is a defect to fix, not a contract to preserve.

```odin
one := m["a"];        // clones the element
two, ok := m["a"];    // does not clone, and is still registered for drop
```

The emitted IR for the second form calls `loke_rt_v1_map_find` and loads the
element directly ([emit_llvm_containers.odin:809](src/emit_llvm_containers.odin:809)),
so `two` aliases the map's stored value while carrying its own implicit drop. At
scope end both `dyn_drop` on `two` and `map_drop` on `m` free the same allocation.

The cause is in the checker, not the emitter:
[lifecycle.odin:330](src/lifecycle.odin:330) skips copy classification entirely for
a declaration where one expression fills several names, on the grounds that "one
call filling several names hands over results it already owns". That is true of a
call and false of the comma-ok map read.

Record it explicitly in the baseline, with a fixture, so the step 4 diff is not
read as a regression. Step 3 fixes it as a consequence of the migration: a
`lookup_value` that clones internally makes the two-name form own its payload for
the same reason the one-name form already does.

### 2. Split extraction by operation

- Parse `.as(T)` through existing selector/call syntax. Resolve it during checking,
  preserving ordinary member lookup for other receiver types.
- Give both extraction spellings one shared semantic description containing source,
  resolved target type, and fixed trapping/optional mode. Downstream phases consume
  that description rather than recognizing names again.
- Concretely: `.as(T)` resolves to the existing `Expr_Checked_Extract` node, not to
  a call node. [cfg.odin:994](src/cfg.odin:994) preserves the source root through an
  extraction; routing `.as(T)` through the generic call path would lose that and
  require new cases in the flow graph, the evaluator, and the emitter. Reusing the
  node is what makes this step cheap.
- Specify how the name `as` resolves, and do not copy the existing precedent.
  [union.odin:22](src/union.odin:22) suppresses the built-in only when the receiver
  is an `Expr_Ident` bound to a non-union symbol, so `f().as(T)`, `a.b.as(T)`, and
  `xs[0].as(T)` would take the built-in path regardless of receiver type.
  `active_typeid` survives that because nobody names a member `active_typeid`; `as`
  is a name users choose. The rule is: resolve the receiver type first, take the
  built-in path only for a union or `any_view` receiver, and prefer a declared
  member on every other type.
- Make `.(T)` permanently single-result. Remove destination-driven extraction flags,
  including their propagation through generic AST cloning.
- Reuse tag checks, type registration, payload access, and mismatch lowering. Route
  `.as(T)` through extraction provenance handling, not the scalar-only
  `active_typeid()` path.
- Preserve existing managed-union restrictions. Do not add named variants, consuming
  switches, or broader union lifecycle support.

### 3. Add copying map lookup

- Contribute `lookup_value` through the existing map-member machinery. Generalize
  receiver handling where it currently assumes every container member is mutating:
  `container_member` in [container.odin:342](src/container.odin:342) hardcodes
  `sym.receiver = .Inout`.
- Reuse the resolved key policy and existing runtime map probe. Evaluate the
  receiver before the key, perform one lookup, and never insert or alter map
  contents.
- Produce an independently owned payload on success using existing copy machinery;
  produce the ordinary zero value on absence. Construct the result independently of
  whether the caller retains or discards it.
- Ensure temporary receiver cleanup, managed key handling, copy failure, and
  discarded results cannot leak or double-drop values. Fix ownership defects in
  these touched paths where required by existing value semantics — including the
  comma-ok double drop recorded in step 1.
- Give the contributed member an explicit result provenance summary. This is work,
  not an acceptance criterion. A map index is a provenance place rooted in the map
  ([cfg.odin:1969](src/cfg.odin:1969)); a call is not. A synthesized member has no
  body and no `Result_Provenance`, so a carrier result falls through to
  `prov_synthetic_borrow(..., .Unknown, ...)`
  ([cfg.odin:2717](src/cfg.odin:2717)) and an unknown region
  ([cfg.odin:1758](src/cfg.odin:1758)). Migrating `v, ok := m[k]` to
  `m.lookup_value(k)` would therefore trade precise place provenance for `Unknown`
  wherever the value type is a carrier — `map[K]string_view`, `map[K]^T`,
  `map[K][]T` — which either rejects code that compiles today or stops checking code
  that is checked today. Register `params[0] = true` for the payload result, or
  resolve the call into the existing map-index semantic description so the place
  path still applies. Whichever is chosen, the result's provenance follows the value
  type: an owned managed payload depends on nothing, a carrier payload still borrows
  through the map.
- Implement compile-time lookup using the evaluator's existing map representation
  and copy operations. Keep existing restrictions on unsupported compile-time types
  and operations.
- Remove `map_optional` and the map-index branch that emits an optional result pair.
  Keep ordinary read and inserting-place lowering.

### 4. Migrate and remove the old mechanism

- Migrate optional `.(T)` uses to `.as(T)` and optional map-index uses to
  `.lookup_value(key)` throughout libraries, examples, fixtures, and embedded test
  sources.
- Leave intentional trapping extractions and ordinary map reads unchanged. Preserve
  negative tests' intended failure reasons; add dedicated rejection tests for
  obsolete optional uses.
- Remove `mark_optional_ok` and every destination-side attempt to change producer
  arity. Retain ordinary multiple-result expansion.
- Update `design.md`, `grammar.md`, examples, and implementation together. Delete
  the per-producer optional-result exception and update extraction, maps, fallback,
  and absence documentation.
- Record Phase 1a's selected names and contracts in the consolidation documents
  without marking the wider proposal adopted.
- Land the semantic migration with its complete corpus update. Do not retain
  compatibility aliases, flags, or two supported meanings for the old syntax.

## Verification and acceptance

Extend existing test suites, adding fixtures only where coverage has no natural home.

- **Arity and diagnostics:** both new operations always produce two results;
  single-value destinations reject them. Old extraction/index syntax rejects
  two-binding destinations and payload fallback use. Diagnostics point to the
  replacement operation.
- **Extraction:** union match, mismatch, nil state, `any_view`, generic targets,
  wrong type arguments, invalid arity, and ordinary user members named `as` —
  including a non-ident receiver (`f().as(T)`, `a.b.as(T)`, `xs[0].as(T)`), which is
  where the existing name-collision guard does not reach.
- **Maps:** present, missing, empty, immutable and temporary receivers, custom keys,
  named arguments, and unchanged insertion/address behavior.
- **Status handling:** lazy fallback, boolean propagation, named-result
  initialization, cleanup on early return, and unchanged single-status `or_return`.
- **Ownership:** copied dynamic-array/custom-hook payloads remain independent;
  strings retain correctly; move-only copying is rejected; source maps survive result
  cleanup; clone failure leaves existing destinations and map contents intact.
  Specifically: a managed value read through `lookup_value` is cloned exactly once —
  the migrated comma-ok form no longer double-drops the map's storage, and the
  destination does not add a second clone.
- **Provenance:** existing checked borrow and region cases do not weaken. A
  `map[K]string_view` payload obtained through `lookup_value` is still tied to the
  map, so the cases that are rejected today through `m[k]` are still rejected, and
  the cases that compile today still compile. Recorded aggregate and indirect-call
  gaps remain visible and are handed to the separate provenance plan.
- **Evaluation:** receiver/key side effects occur once in order; compile-time map
  lookup agrees with runtime for supported types. Existing unsupported
  extraction/status-expression compile-time paths remain explicit diagnostics.
- **Backend:** compare representative generated IR for result shape, lookup count,
  mismatch checks, clones, and cleanup. No runtime ABI or container representation
  change is intended.

Run the full test matrix again, including baseline, minimal, size, speed, and
aggressive optimization modes. Completion requires passing tests and an audited
deletion checklist showing no remaining destination-dependent extraction or map
result arity.

## Boundaries and defaults

- Preserve current working-tree edits; do not revert or overwrite unrelated work.
- Do not rewrite or implement the historical provenance plan here. This milestone
  supplies its baseline cases and a focused handoff.
- Defer typed fallibility, anonymous records, default-value changes,
  `require_results` changes, removal of `manual`, borrowed lookup redesign,
  interface work, and container representation changes.
- One unrelated defect was found while probing and is **not** in scope here: the
  L0507 copy-cost warning on `one := m["a"]` reports "this binding clones `m`" and
  advises `move(m)`. It names the place root rather than the element being cloned,
  and the suggested fix would move the map. Fix it separately.
- The baseline has not yet been rerun; executing and recording it is the first
  implementation step.

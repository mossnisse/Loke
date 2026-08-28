# Second consolidation implementation plan: aggregate provenance and call contracts

Status: planned; no implementation or verification results are claimed here.

## Summary

Close the provenance gaps that must be repaired before ordinary records or unions
can replace the current multiple-result and status protocols. This is step 3 of
[`language-design-consolidation-proposal.md`](language-design-consolidation-proposal.md#13-proposed-migration-order),
covering Phases 4a and 4b of
[`language-refinement-strategy.md`](language-refinement-strategy.md#phase-4--make-provenance-compose-through-values-and-calls).
The phase numbers identify workstreams, not the order of implementation plans.

The two phases are two separately shippable deliveries, not one indivisible
milestone. Phase 4a — aggregate and container content flow — completes at its own
gate and authorizes borrowed aggregate migration on its own. Phase 4b — result
and retention contracts at call boundaries, and the storage-duration checks built
on them — is a gated follow-on that may ship later. The strategy and the proposal
already gate the two separately; this plan owns both without requiring them to
land together.

The [first implementation plan](consolidation-phase-1a-plan.md) has shipped fixed
producer arities. This milestone retains those contracts, special multiple
results, named results, the status operators, existing unions, `manual`, `inout`,
and the current allocation and container APIs. It does not adopt typed
fallibility, anonymous records, or new reference types.

This plan supersedes the checklist and decisions in the historical
[`provenance-plan.md`](provenance-plan.md). In particular, it does not adopt that
plan's recursive-cache shortcut, wrapper-root loans on value reads, blanket
parameter-store rejection, permissive `Unknown` lifetime proof, or
`unsafe.forget_provenance` builtin.

## Fixed contracts

The contract is about a value's dependencies, not merely whether its type can
contain a pointer. An owner can have backing-storage region dependencies and
also contain borrows of unrelated roots. Track these independently.

| Operation | Required behavior |
|---|---|
| Wrap a value | Preserve its root, region, capability, and known allocation-base facts through ordinary records, arrays, unions, and containers |
| Read a stored carrier by value | Copy its original dependencies; do not create a lasting borrow of the wrapper or container merely because it held the carrier |
| Address or project a place | Borrow the storage addressed, preserving inherited dependencies and existing invalidation rules |
| Copy an owner | Apply the actual copy operation: independently cloned backing storage uses its selected allocator, while copied contained borrows retain their original dependencies |
| Move an owner | Transfer its content and region facts before consuming the source; do not make the destination borrow the dead source binding |
| Replace a known field | Replace that field's facts after successful preparation; leave unrelated fields and surviving copies alone |
| Remove, clear, or drop contents | End only dependencies no surviving value holds; an extracted value keeps its own dependencies |
| Return or retain through a call | Apply a checked result/retention contract to actual argument paths, roots, and regions, including at generic, package, and procedure-value boundaries |
| Store into longer-lived storage | Prove that every dependency outlives the destination; unknown provenance is not that proof |

`^T` is immutable and `^mut T` is mutable. Preserve capability and reborrow
suspension per contained carrier; a record containing both has no single
aggregate-wide borrow capability. Owning copies and moves must not weaken either
carrier accidentally. Existing restrictions on copying mutable or move-only
values continue to apply.

A known empty container or nil anonymous union has no content loans. Its owner
may still depend on an allocator region. A pointer's allocation-base identity is
separate from its lifetime: returning it in a wrapper must neither lose a known
base nor turn an interior or unknown pointer into something checked `free` accepts.

The following use of current syntax must remain legal:

```odin
Holder :: struct { view: []int }

wrap :: proc(values: []int) -> Holder {
    return Holder{values};
}

unwrap :: proc(holder: Holder) -> []int {
    return holder.view;
}
```

The caller must keep the original root alive. Returning a wrapped borrow of a
callee-local array, or taking and returning `&holder.view`, has a different
storage dependency and must fail. These are acceptance cases, not claims about
the current checker.

## Current implementation and required changes

Source inspected at `e2f32e21faaebffef28460b45d31edd6b7a2f24d` on 2026-08-27.
Recheck these entry points before implementation; the first plan's verification
record is historical evidence, not a fresh baseline for this milestone.

| Area | Current entry points and gap |
|---|---|
| Carrier classification | [borrow.odin](src/borrow.odin), `type_is_carrier`, `carrier_is_mutable`: built-in leaves and region providers, not recursive aggregate content |
| Value flow | [cfg.odin](src/cfg.odin), `walk_flow_expr`, `prov_declare`, `prov_assign`: composite children are visited without returning aggregate loans; field reads/writes do not load/update content slots; the provenance `Expr_Move` arm invalidates and returns no loans |
| Places and slots | [borrow.odin](src/borrow.odin), `Proj_Step`, `Prov_Slot`; [cfg.odin](src/cfg.odin), `prov_place_of`, `prov_slot_for_symbol`, `prov_bind_parameters`: place projections already exist, but content state is not tracked per aggregate path |
| Region flow | [cfg.odin](src/cfg.odin), `prov_region_of`, `prov_call_region`, `prov_region_escape`: some aggregate regions already join, but field precision is absent and the storage-escape path accepts only a simple identifier of managed type |
| Summaries | [borrow.odin](src/borrow.odin), `Result_Provenance`, `Proc_Summary`, `summarize_body`, `analyze_program_provenance`: positional result summaries and a worklist already exist; zero-result bodies are skipped and retention is not summarized |
| Calls and map reads | [cfg.odin](src/cfg.odin), `prov_call`, `prov_call_result`; [container.odin](src/container.odin), `set_synth_result_summary` use: `lookup_value` currently borrows the map root for carrier payloads, and indirect calls have no precise result contract |
| Procedure types | [semantic.odin](src/semantic.odin), `intern_proc_type`: allocator-reset effects already participate in type identity, but result/retention contracts do not |
| Static duration | [cfg.odin](src/cfg.odin), `prov_root_for_symbol` maps every `duration != .None` symbol to `Root_Kind.Static`, so thread and process storage are one root kind |
| Lattice cost | [borrow.odin](src/borrow.odin), `prepare_state` allocates two `[]bool` of `slots * loans` per block plus four more per-block arrays |

Reuse the existing read-only provenance graph modes and summary worklist. Do not
rerun lifecycle checking while constructing provenance graphs or duplicate its
copy, move, cleanup, and emission annotations.

## Staging: every step lands green

No step in this sequence may land as part of one unreviewable change. Content
state arrives behind a new `Flow_Mode` member beside `.Prov_Summary` and
`.Prov_Diagnose`. Nearly every branch in [cfg.odin](src/cfg.odin) tests
`mode != .Lifecycle`, so a fourth member inherits the read-only provenance walk
without touching those sites; only the few that name a provenance mode directly,
such as `prov_note_summary_dependency`, need updating. The
existing modes stay authoritative for reported diagnostics until the new mode
passes the acceptance cases for the slice being adopted; each slice then flips
its own diagnostics over and leaves the corpus green. A slice that cannot be
landed this way is not ready to land.

"Internal staging is permitted" below means this mechanism, not an intention to
stage. An incomplete path stays gated behind the mode and is never described as
checked provenance.

## Implementation sequence

Steps 4–6 are coordinated parts of Phase 4a and steps 7–8 of Phase 4b; within
each phase they are separate landings, not independent promises of soundness.
Migrate affected specification text and fixtures with each adopted slice; step 9
is the final audit, not permission to leave the specification behind the
implementation.

### 0. Split thread duration from static duration in roots

Done; see the verification record. A small refactor with no dependency on the
rest of this plan, landed first so the later steps do not carry it.

- Give `Root_Kind` a thread-duration kind distinct from `.Static`, set it in
  `prov_root_for_symbol` from `sym.duration`, and stop `root_outlives_body` from
  answering one question for both. Carry the distinction into `Result_Provenance`
  so a summary records which one a result may name.
- Keep the current acceptance behavior. `design.md` already records that a
  procedure may return a borrow of either, and that sending a `thread_local`
  borrow to another thread is an unchecked error; this step does not change that.
  The user-visible check that consumes the distinction is step 8.

**Exit:** summaries and diagnostics distinguish the two durations, no corpus
program changes acceptance, and step 8 has the root information it needs.

### 1. Record the baseline and contract decision cases

- Run the complete `./test-all.ps1` matrix, recording revision, working-tree edits,
  toolchain versions, output, and elapsed time. Keep failures separate from new
  behavior. Do not use `-SkipOptimizationMatrix` for the milestone baseline.
- Extend existing provenance fixtures to characterize bare versus wrapped borrows,
  independent fields, a moved owning record with borrowed content, map value reads
  versus entry pointers, allocation-base round trips, and retention into an
  `inout` destination. Add the `wrap`/`unwrap` pair above as a fixture; it does
  not exist in the corpus today. Include the currently unchecked cases without
  making their acceptance a permanent regression requirement.
- Build the strategy's integrated example using current named records and unions:
  obtain a borrow from a map, wrap it, return it through a helper and a procedure
  value across a package, and retain a view through a second helper. Pair every
  valid lifetime with an escaping or invalidated-root case.
- Add a callback example whose result borrows `input` while `scratch` is used
  only during the call. Add a setter receiving a caller-owned destination and a
  process/TLS storage example. These are the decision cases for step 2; accepting
  only a locally known function pointer does not establish an indirect contract.
- Instrument two counters and one timing, not a measurement project: total
  reaching-state bytes per body and summary worklist iterations, both behind an
  environment check in `prepare_state` and `analyze_program_provenance`, plus the
  wall time the existing test run already reports. Add blocks, slots, loans, or
  peak memory only for a body that trips a threshold below. Measure representative
  existing bodies and generated nested/recursive aggregate cases, including an
  all-scalar case.

Use provisional stop-and-review budgets of 2x baseline provenance time on
unchanged representative programs, and investigate any body whose reaching-state
size grows by 10x after step 3's widening. Use repeated measurements and record
absolute sizes as well as ratios. These are engineering review thresholds, not
measured results or permission to discard dependencies. If they are exceeded,
reduce unnecessary slots before widening the analysis further. Record every false
rejection in the representative programs; the required positive cases below are
not negotiable to meet a resource budget.

**Exit:** a reproducible baseline, an operation inventory, and concrete tests
against which both provenance precision and call-contract alternatives can be
judged. No language change ships in this step.

### 2. Settle the result and retention contract representation

This is a decision gate on paper, taken against step 1's examples and before any
solver work, because the summary representation the later steps produce *is* the
contract. Deciding it after building those summaries means rebuilding them.

Compare portable inferred summaries with a small explicit
declaration/procedure-type contract. Inference can remain the default for bodies;
it wins alone only if an abstract callback signature can express the needed
contract without knowing the eventual callee or consulting its body at each
caller. Otherwise prototype the smallest explicit form using the existing
attribute/signature machinery.

Record the selected syntax or metadata representation, default for an omitted
contract, compatibility rules, diagnostics, and conservative rejections before
changing `design.md` or `grammar.md`. This is a bounded decision within this
milestone, not permission to silently choose a lifetime language. Shipping Phase
4b is blocked until it has a concrete usable answer.

The selected contract must describe:

- result-path dependencies on input paths, distinguishing borrowed content from
  addresses of input storage, plus regions and known allocation-base relationships;
- which input paths may be retained in which mutable destination paths, including
  `inout` parameters and receivers;
- input lifetime requirements for retention into process/TLS storage; and
- any proven replacement/clear effect used to remove old facts. A may-retain
  effect alone only adds possibilities and cannot justify killing a dependency.

Identity is whole-program for now. Use the indices the whole-program checker
already has rather than designing a portable encoding with no reader; record that
a private `Symbol_Id` or transient graph index cannot survive serialization, so a
future separate-compilation system must republish the contract through package
metadata. Do not build that system here.

**Exit:** a recorded representation, default, compatibility rule, and diagnostic
shape that steps 4–8 implement without renegotiation. No compiler change ships in
this step.

### 3. Widen the reaching lattice before adding slots

`prepare_state` allocates two `[]bool` of `slots * loans` per block. Step 4
multiplies `slots` by the content paths of every aggregate value, so the 10x
threshold in step 1 is arithmetic rather than a risk to watch: a four-field record
holding two loans per field already exceeds it.

- Convert the reaching component to packed words in `prepare_state`,
  `solve_reaching`, `reach_row`, and their consumers, keeping the same lattice and
  the same results. This is a representation change with no semantic content, so
  it lands with the corpus unchanged and byte-identical diagnostics.
- Re-measure step 1's counters afterwards; that measurement is the baseline the
  later steps are judged against.

**Exit:** identical diagnostics and identical emitted IR across the full matrix,
with recorded before/after reaching-state bytes.

### 4. Introduce finite carrier shapes and per-value content state

- Compute recursive carrier shapes over `.Struct`, `.Array`, `.Union`,
  `.Dynamic_Array`, and both map keys and values. Keep existing leaf semantics,
  distinct-type unwrapping, allocator handles, region providers, and compiler
  iterators. Do not recursively expand a pointer's pointee as inline storage.
- Use a monotone fixed point over the type graph, strongly connected components,
  or an equivalent cycle-safe algorithm. An unfinished recursive edge is not a
  cached negative result. Recompute dependent shapes when generic instantiation
  or a synthesized type completes previously unavailable structure.
- Represent recursive shapes finitely: container-element edges can refer back to
  a shape rather than expanding every possible `Node.children` path. A
  `Node` containing `[dynamic]Node` and `[]int` must give the same answer in both
  field orders and whichever type is queried first. Scalar-only cycles must
  terminate without acquiring fictitious loans.
- Bound a *value's* content paths as well as the type graph. Fix one depth limit;
  a path deeper than the limit collapses into the wildcard join for its prefix,
  which is sound because a wildcard already overlaps every sibling. Record the
  chosen limit and the cases it approximates. A finite type shape does not by
  itself keep the per-value path set small.
- Give aggregate values content paths. Preserve known record fields and constant
  array projections; use explicit wildcard joins for unknown indices and union
  alternatives. Keep a value's storage root separate from the roots carried in
  its fields. Share existing projection overlap rules where applicable.
- Store root dependencies, region dependencies, and allocation identity at the
  relevant content paths. Carry the leaf capability into weakening and reborrow
  checks. Do not call `carrier_is_mutable` once on an entire record and apply its
  answer to every field.
- Allocate slots only for relevant content, including live returned or retained
  values, and measure the effect against step 3's re-measured baseline. An empty
  value initializes no payload facts even when its type is a possible carrier.

**Exit:** structural tests cover recursive/query-order independence, the depth
limit, field distinctions, mixed capabilities, and empty values. Behind the new
graph mode, aggregate slots carry facts; a change that merely makes
`type_is_carrier` recursive while those slots stay empty is not this step.

### 5. Propagate aggregate values and direct results together

- Extend construction, declarations, assignment, selection, indexing, union
  injection/extraction, existing type-switch bindings, and iteration to consume
  and produce the content state. Preserve current union ownership restrictions;
  this does not add the proposal's new consuming-switch semantics.
- A value read loads content facts, including a value read through a dereference;
  checking that storage access must not add a lasting borrow to the loaded value.
  `&field`, slice creation over owned storage, `inout` results, and by-reference
  iteration also borrow the addressed root and its projection. Reads of a stored
  view must not inherit unrelated sibling-field loans or a synthetic wrapper loan.
- Prepare source facts before invalidating moved values. Cover explicit `move`,
  consuming receivers, existing implicit return transfers, `exchange`, and
  temporary cleanup. A borrow of the old owner's storage still forbids its move;
  contained borrows of other roots transfer without borrowing the old binding.
- Use resolved copy/lifecycle operations to distinguish preserved contained
  borrows from new backing allocations. A clone into another allocator can shed
  the source backing region but cannot shed an external view stored in the clone.
  Custom copy hooks must use their checked call contracts, not an assumption that
  every hook is a field-wise identity.
- Prepare all right-hand sides and destinations before publishing assignment
  facts. Update only the written path after successful preparation. Preserve the
  old state on failed preparation, without rolling back earlier side effects or
  explicit moves. Cleanup/drop hooks count as uses of content they may observe.
- Seed aggregate parameter contents independently of the callee-local parameter
  slot. Extend result summaries with the source and result paths, capabilities,
  regions, and allocation-base relationships step 2 selected; substitute the
  caller's matching content, not all loans of the parameter. Fresh allocation
  facts must preserve alias relationships between returned fields, not invent a
  new allocation for each alias.
- Keep all current result positions, named-result assignments and bare returns,
  status-only `or_return`, and `or_else` success/failure paths working. Reuse
  `Prov_Call_Result` and the existing worklist rather than relying on source order.
  No path may lose dependencies because a value passed through a temporary,
  generic instance, wrapper helper, or second result.
- Keep `any_view`'s borrow of erased storage distinct from dependencies inside an
  extracted value. Erasure still borrows its subject; extraction does not grant
  ownership of that subject or make an unknown foreign value checked.

**Exit:** local aggregate and direct/generic/package wrapper tests match their
bare counterparts. `wrap`/`unwrap` and independent-field positives pass; local
escapes, hidden aliases, conflicting reborrows, invalidation, and region reset
fail for the underlying general rule. Wrapped known allocation bases can be
released exactly as their bare equivalents can; aliases and interior pointers
do not gain new release rights.

### 6. Track container contents and synthesized operations

Use the resolved `Container_Op` and iteration descriptors in
[container.odin](src/container.odin) and [iterate.odin](src/iterate.odin), not
member-name recognition in the solver. Ordinary user types obtain equivalent
behavior through their checked bodies and call contracts.

| Operation family | Content and storage effect |
|---|---|
| Literals, append, insert, inserting map assignment | Associate dependencies of stored elements, keys, and values with the destination on successful mutation |
| Known field/element replacement | Replace the known content path after preparation; unknown keys/indices conservatively join without erasing other elements |
| Index reads and `lookup_value` | Return the selected value's content facts; managed copies follow the existing clone and allocator policy |
| `find`, element addresses, mutable slices, entry places | Borrow container storage and retain its invalidation obligations; subsequent writes through these aliases update the addressed content |
| `pop`, `remove`, `remove_unordered` | Return the removed value's dependencies independently; an imprecise remaining-content set may conservatively retain them |
| `clear`, whole replacement, drop | Clear only facts held by the removed contents; surviving copies/results stay live and backing-region facts are handled separately |
| Resize, reserve, shrink, reallocation | Apply existing storage invalidation and failure rules; preserve surviving content dependencies, and give new zero elements no invented loans |
| `iter`/`next`, `entries`, `keys`, `values`, `indexed`, reverse adapters | Track iterator storage borrows separately from the dependencies of copied or borrowed elements |

- Replace the current `map_value_borrow` special case in `prov_call` and the
  map-index synthetic-root shortcut once content facts exist. Update the
  synthesized `lookup_value` summary to describe copied content. Do not remove
  those conservative checks first and leave a gap between implementations.
- Distinguish map key and value content so a value read does not inherit unrelated
  key borrows. Include nested containers, temporary receivers, and aliases through
  `find`, slice elements, pointer dereferences, and `inout` destination fields.
- Model fallible operations' commit points and status edges. On a proven failure
  edge, insertion adds no stored-value loan; on success it does. A join where
  success is unknown may conservatively retain the new dependencies. Preserve
  this relationship through the existing status operators without changing
  expression arity or failure policy. Include partial clone failures and unwind
  cleanup; do not pretend an unsuccessful insertion stored its argument.
- Prototype one joined set for indistinguishable elements, with separate nested
  field paths where known. Unknown-index removal cannot erase the other elements'
  loans. Clearing or replacing the entire content set can end them, but cannot
  invalidate a surviving result's facts or waive a live entry-place borrow.
- Measure false rejections from the joined-set approximation. If the integrated
  example or ordinary container use needs more precision, refine it before
  acceptance; "everything ever inserted" is not a permanent language rule.

**Exit:** a copied view can outlive a local wrapper/container when its original
root remains valid; an entry pointer cannot. Container-held borrows prevent
invalid source mutation/reset, and clear/replacement releases only the correct
dependencies. Phase 1a's one-clone `lookup_value`, no-insertion reads, and cleanup
tests remain unchanged in runtime behavior.

**Phase 4a gate:** steps 4–6 are complete and their diagnostics are authoritative.
This gate authorizes borrowed aggregate migration on its own; the remaining steps
may ship later.

### 7. Implement result and retention contracts at every call boundary

Implements the representation step 2 selected. Renegotiating it here means step 2
was not finished.

- Extend `Proc_Summary`, merging, dependency discovery, and diagnostics to cover
  retention. Remove `summarize_body`'s zero-results early exit: a setter returning
  nothing is a principal case. Forward, mutually recursive, generic, receiver,
  and generated-hook calls must converge with the same worklist.
- Derive effects from writes through mutable destination paths, including nested
  fields, container operations, and tracked pointer/slice aliases. A local borrow
  retained in caller storage must be rejected; retaining another caller argument
  creates an obligation checked with actual lifetimes at the caller.
- Keep monotone may-effects separate from proven must-replace/clear effects; do
  not erase caller dependencies because one branch or one recursive iteration
  happened to clear them. Include normal exits and cleanup paths that can observe
  retained content.
- Verify bodies against their declared contracts. At calls, substitute source
  paths and destination paths using the already resolved arguments and modes.
  Evaluate arguments once; use the same contracts for method and ordinary syntax.
- Preserve contracts in procedure types/values and generic substitution. Check
  assignments, arguments, returns, conditional choices of callees, and wrapper
  procedures: a callee cannot retain more, return broader borrowed dependencies,
  or require a longer-lived input than the receiving contract permits. Preserve
  required freshness guarantees as well as possible-borrow sets. Parameter names
  remain declaration metadata, not part of procedure type identity.
- Reuse the `@(allocator_reset)` compatibility path without conflating resetting
  a region with retaining a value backed by it. Contracts remain compile-time
  metadata; procedure values keep their current runtime representation and ABI.
- An absent contract must not mean "retains nothing." Specify conservative
  behavior for unknown callees and foreign boundaries, and test it. Blanket
  all-inputs-to-all-mutable-outputs retention is a fallback to measure, not the
  accepted semantics for every procedure value. Account for possible retention
  into global state too: the absence of a mutable argument is not proof of
  non-retention. Audited foreign contracts remain programmer promises; the
  compiler cannot verify foreign retention.

**Exit:** the input/scratch callback and retaining helper work with the same
documented contract directly, generically, across a package, and through an
abstract procedure parameter. Violating bodies and incompatible procedure-value
assignments fail. Unknown contracts neither erase a region nor manufacture a
lifetime/allocation-base proof. A successful direct-call prototype alone does
not complete this step.

### 8. Enforce retention into static and caller-owned storage

- Generalize `prov_region_escape` and assignment destination resolution beyond
  simple identifiers and managed types. Check bare carriers, aggregate fields,
  nested containers, `exchange`, and writes through tracked aliases to
  file-scope, `static`, TLS, or caller-owned storage.
- Consume step 0's duration split in the destination checks. Do not reuse
  `root_outlives_body` as an outlives-every-destination proof, and do not treat a
  thread-duration root as proof of process lifetime.
- Accept stored parameters when step 7's caller-visible contract proves the
  required lifetime. Reject unconstrained local/caller borrows retained beyond
  their valid interval. A heap allocation is still explicitly releasable; its
  existence is not proof of process lifetime. A checked shorter retention interval
  needs an actual contract and enforcement, not an informal promise to clear later.
- A mutable global pointer slot and its pointee have different lifetimes. A read
  without a usable content contract stays unknown; a later checked store or
  `free` cannot treat it as static. Preserve any known region obligations even
  when root information is unavailable.
- Keep explicit raw conversions and audited resource APIs as trust boundaries.
  Do not add `unsafe.forget_provenance`, reinterpret `manual` as an escape hatch,
  or claim that suppressing cleanup extends storage lifetime.

**Exit:** valid process and same-thread storage cases pass; local-to-global,
TLS-to-process, unknown-proof, and retained-local escapes fail with the source
root and destination named. Raw/foreign/cross-thread boundaries remain explicit.

**Phase 4b gate:** steps 7–8 are complete, with body and compatibility checks at
public, generic, and indirect boundaries.

### 9. Migrate specifications and fixtures; remove superseded paths

- Update `design.md`'s carrier model, procedure boundaries, static/TLS retention,
  allocator regions, and unchecked-boundary list with the implementation. Update
  `grammar.md` and syntax fixtures only for a contract form actually selected in
  step 2; no speculative annotation syntax belongs in the normative grammar.
- Split [m5b_trust_boundary.loke](tests/run/m5b_trust_boundary.loke) by semantics.
  Keep `store_in_a_record_field` and step 1's added `wrap`/`unwrap` as positive
  checked cases. Move the conflicting `hidden_alias` write to a negative fixture.
  Convert unconstrained `store_in_a_global`, `retain_an_argument`, and
  `store_a_view` to rejection tests, adding positive counterparts with proved
  storage contracts. Reassess `run_with` under the chosen callback contract rather
  than grandfathering a callback that silently retains its argument.
- Audit `base`, `core`, `examples`, `tests`, and embedded compiler-test programs.
  Classify each new rejection as an intended boundary change, an analysis defect,
  or a measured conservative limitation. Do not make the corpus green by adding
  blanket unsafe conversions or downgrading unknown lifetimes to success.
- Remove obsolete whole-wrapper loans, map value-root shortcuts, result-only
  summary assumptions, the staging graph mode's now-dead alternative path, and
  documentation promising unchecked aggregate retention. Reuse existing
  diagnostics where the same rule applies; allocate new codes from L0644 onward.
  The old L0639 reservation is stale: L0639 is in use and the source currently
  reaches L0643.
- Update the proposal's step 3 and the strategy's Phase 4 progress only for gates
  actually completed. Leave typed fallibility and all unrelated adoption decisions
  open. Record remaining trust boundaries and measured precision limits.

## Verification and acceptance

Extend existing test homes before adding new suites:

| Area | Evidence and natural test home |
|---|---|
| Lattice representation | Identical diagnostics and IR before/after the packed-word widening, with recorded reaching-state bytes; existing provenance suites unchanged |
| Carrier shape and solver | Recursive field/query order, scalar-only cycles, finite nested-container shapes, content-path depth limit, branch/loop convergence; focused compiler tests in `src` |
| Bare versus wrapped values | Local escape, temporary escape, valid caller borrow, independent fields, known-field overwrite, union injection/extraction; `tests/run/m5b_results.loke`, `tests/err/m5b_escape.loke`, and existing provenance regressions |
| Capabilities and ownership | Mixed immutable/mutable fields, reborrow suspension, move/drop/exchange, custom-hook copies, clone into a different allocator, cleanup uses; existing M5a/M5b ownership and borrow fixtures |
| Containers | Borrowed keys and values, copied lookup versus entry pointer, nested/temporary maps, alias writes, failed insertion, returned elements after clear, unknown-index conservative joins; existing M6b map/dynamic-array/region fixtures |
| Regions and allocation bases | Bare and wrapped arena dependencies, copied allocator handles, moves, reset while a retained value is live, base/alias/interior-pointer `free` cases; existing M5b/M6b region and result fixtures |
| Calls and retention | Zero-result setters, recursive summaries, direct/generic/abstract procedure calls, callback input versus scratch, body/contract mismatch and procedure compatibility; existing result tests and `tests/pkg_err/m5b_summary`, with a positive package fixture where needed |
| Storage duration | Nested global/TLS fields and aliases, parameter contracts, unknown mutable-global reads, TLS-to-process rejection; migrated trust-boundary and new focused storage fixtures |
| Compile time and lowering | Existing evaluator restrictions, constant/materialized aggregate views, unchanged representation and cleanup; `src/emit_llvm_test.odin`, `tests/ll/m5b_provenance_regressions.loke`, and existing compile-time/runtime/trap suites |

For every adopted slice, run `./test-all.ps1` without skipping the optimization
matrix: compiler unit tests, baseline integration suites, and run/trap suites at
`minimal`, `size`, `speed`, and `aggressive`.

`test-all.ps1` has no panic-strategy axis, so exercise affected cleanup fixtures
under the second strategy explicitly:

```powershell
$env:LOKE_TEST_FLAGS = '-panic=abort'; odin test tests -define:ODIN_TEST_TRACK_MEMORY=false -define:ODIN_TEST_NAMES=programs_run,programs_trap
```

Compare emitted IR and ABI for unchanged valid programs: no hidden boxing,
runtime provenance fields, extra copies, or changed cleanup order is authorized
by this plan.

Preserve the first milestone's extraction, map-copy, temporary receiver, failure,
and discard regressions. Changed diagnostic snapshots must identify an intended
contract change, not merely a new error number. Run `git diff --check`, audit the
removed shortcuts, and retain test logs and performance/false-rejection results.

## Completion gates and boundaries

- **Phase 4a** (steps 4–6): aggregate and container content flow, direct
  summaries, root and region preservation, and field precision pass their positive
  and negative cases. Safe `wrap`/`unwrap` is not sacrificed to reject an unsafe
  local escape. This gate stands alone and authorizes aggregate producer
  migration without waiting for Phase 4b.
- **Phase 4b** (steps 2, 7, 8): the recorded call contract covers results and
  retention at public, generic, and indirect boundaries, with body and
  compatibility checks. Longer-lived storage checks use that contract and
  distinguish process from thread duration.
- **Both phases and step 9 recorded:** corpus/specification migration, full
  verification, cost measurements, and the deletion audit are complete, and the
  staging graph mode is gone. Until then, incomplete paths remain behind that
  mode and are not described as fully checked provenance.

After the Phase 4a gate, the next value-design plan can evaluate Phase 1b and
Phase 2 together. This milestone makes that comparison safe to pursue; it does not
preselect `Option`/`Result`, a zero/default rule, named variants, anonymous
records, a new map API, container representation, `Owned(T)`, removal of
`manual`, or first-class reference types. Interface lookup remains owned by
`interface-plan.md`; any borrowing interface boundary uses the same selected
call contract, not a separate lifetime mechanism.

## Verification record

Written as planning only: current compiler entry points, the first milestone's
completion record, and existing fixtures were inspected when writing this plan.
Append measured baseline, decision, migration, and final verification results
during implementation.

### Step 0 — thread duration split

Implemented on 2026-08-28 at `e2f32e21faaebffef28460b45d31edd6b7a2f24d` plus this
change. `Root_Kind.Thread_Local` is set from `sym.duration` in
`prov_root_for_symbol`, named "thread-duration storage" by `root_kind_text`,
carried by `Result_Provenance.thread` through `merge_provenance`,
`merge_loan_provenance`, and the synthetic borrow in `prov_call_result`.
`root_outlives_body` still answers true for both durations, which is the frame
question and the current acceptance rule; its comment now says so, so step 8 does
not reuse it as an outlives-the-destination proof.

Coverage: `free_thread_local` and `free_static` in
[m5b_provenance_regressions.loke](tests/err/m5b_provenance_regressions.loke) pin
the two L0514 texts against each other, which is where the split is observable
today.

Ran: `odin test src` (47 tests), `odin test tests` (14 tests), and the run/trap
corpus at `-opt=minimal`, `size`, `speed`, and `aggressive` — all successful, no
other fixture's acceptance or expected text changed. The panic axis was not run:
`Root_Kind` and `Result_Provenance` appear only in
[borrow.odin](src/borrow.odin) and [cfg.odin](src/cfg.odin), so this change
reaches no emission or cleanup path.

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

Done; see the verification record.

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

Decided; the rest of this section is the record. This was a decision gate on
paper, taken against step 1's examples and before any solver work, because the
summary representation the later steps produce *is* the contract. Deciding it
after building those summaries means rebuilding them. No compiler change ships in
this step.

#### Why inference alone loses

Step 1's callback fixture settles it. `run_pick` passes `input` and a local
`scratch` to a `proc(input: []int, scratch: []int) -> []int` parameter and
returns the result. The result borrows `input` and never `scratch`, but at an
indirect call there is no body to infer from, so the fallback assumes every
borrowed argument is a possible source and rejects the program for returning
`scratch`. No amount of summary precision fixes this: the callee is not known at
the call. An explicit form is required at procedure-type boundaries.

Inference still wins everywhere a body is visible, and it keeps the path,
region, and allocation-base precision an annotation cannot carry. So the answer
is a hybrid, and the sentence that makes it coherent is:

> **A declared level is an upper bound; inference computes the precise effect
> below it.** Direct calls to a visible body use the inferred detail. Indirect,
> foreign, and interface calls use the declared level.

#### The selected form: one ordered parameter attribute

`@(escape=<level>)` on a parameter or receiver, in a procedure declaration, a
written procedure type, a `foreign` declaration, or an interface requirement.
Four levels, totally ordered by what may outlive the call:

| Level | The call may leave behind |
|---|---|
| `@(escape=none)` | nothing that depends on this parameter — not even a result |
| *absent*, or `@(escape=result)` | a result that borrows it; nothing else | 
| `@(escape=stored)` | also a borrow held in one of this call's own mutable destinations (`inout` parameters, receiver) |
| `@(escape=static)` | also a borrow held in process-duration storage |

The default is `result` because that is the overwhelmingly common case and is
already today's behavior at both direct and indirect calls, so unannotated code
keeps compiling. Retention defaults to *none* because it is rare, and today
entirely unchecked; making it visible at the boundary is the point of Phase 4b.
The two defaults sit at opposite ends deliberately: each is set to its own common
case, which is what keeps annotations off almost every signature.

`thread_local` is the reserved fifth level, between `stored` and `static`. It is
not defined now because no case in the corpus needs it — step 0 already split the
root kinds, so adding it later is a level, not a redesign.

#### Caller obligations, by level

- `none` — no obligation, and the caller may treat the argument as untouched
  after the call. This is what lets `scratch` stay local.
- `result` — the result's dependencies include the argument, exactly as an
  inferred summary would say at a direct call.
- `stored` — every mutable destination of the call must be outlived by this
  argument. The contract does not name *which* destination, so the caller proves
  it against all of them.
- `static` — the argument must outlive the process.

#### Compatibility

One comparison, in one direction: a procedure is assignable to a procedure type,
passable as an argument of it, and returnable as it, iff for every parameter
`level(procedure) <= level(type)`. A callee may promise more than the type asks;
it may never promise less. The same rule covers conditional choices of callee,
wrapper procedures, and generic substitution, and it is the reason a single
ordered level was chosen over separate result and retention marks.

Levels participate in procedure type identity the way `param_resets` already
does in `intern_proc_type`, so an indirect call cannot launder an effect by
passing through a type that hides it.

#### Machinery this reuses

Nothing here is new mechanism. `@(allocator_reset)` is the precedent in every
respect: a parameter attribute, validated in `attributes.odin`'s one table,
resolved for both declarations and written procedure types in `check.odin`,
carried in `Type_Info.param_resets`, and part of interning. `escape` adds
`specs["escape"] = {{.Parameter}, .Value_Required}`, a `[]Escape_Level` beside
`param_resets`, and a level accessor next to `attribute_string_value` —
`Attribute.value` is a general `Expr`, so the bare identifier in
`@(escape=none)` needs no parser change.

Identity is whole-program for now: use the indices the checker already has rather
than designing a portable encoding with no reader. A private `Symbol_Id` or
transient graph index cannot survive serialization, so a future
separate-compilation system must republish levels through package metadata. The
attribute form is already the portable half; do not build the rest here.

#### Diagnostics

Reserve L0644–L0655 for steps 4–8. Allocated now:

| Code | Reported when |
|---|---|
| L0644 | a body's inferred effect exceeds the level its declaration states |
| L0645 | a procedure value, argument, return, or generic substitution supplies a callee whose level exceeds the receiving type's |
| L0646 | an argument to `@(escape=stored)` does not outlive a mutable destination of the call |
| L0647 | an argument to `@(escape=static)` is not process-duration storage |
| L0648 | `@(escape=...)` names an unknown level or marks a parameter that carries no borrow |

Each names the parameter, the level required, and the level found; L0646 and
L0647 additionally name the source root and the destination, as step 8 requires.

#### Conservative rejections and boundaries

- A parameter whose type is not a carrier cannot escape, so `@(escape)` on one is
  a mistake rather than a no-op — L0648, following `@(allocator_reset)`'s L0539.
- A procedure value whose type states no level carries `result`. That is a real
  contract, not an absence: an unannotated procedure type promises that the call
  retains nothing, and every Loke body assigned to it is checked against that
  promise. This is what makes `run_with` in
  [m5b_trust_boundary.loke](tests/run/m5b_trust_boundary.loke) fail in step 9
  rather than being grandfathered: the callback it is given does retain.
- A `foreign` declaration has no body to check, so its level is an audited
  programmer promise, exactly like every other foreign claim. The compiler cannot
  verify foreign retention and does not pretend to.
- Generic instantiation substitutes levels unchanged; the level belongs to the
  parameter, not to the type argument.
- Interface requirements carry levels like any other procedure type.
  `interface-plan.md` still owns lookup; this adds no second mechanism.

#### What this deliberately cannot express

The level is coarse at the boundary, and each coarsening has the same escape
valve — inference is precise wherever a body is visible:

- It does not distinguish a borrow of the parameter's *content* from a borrow of
  the parameter's *storage*, nor name paths or regions. Any finer boundary
  language is the lifetime language this milestone is forbidden to choose
  silently.
- `stored` does not name which destination, so the caller proves the argument
  outlives all of them.
- It cannot express a proven replacement or clear effect, and must not: a level
  is a may-effect that only adds possibilities. Killing a caller's dependency
  needs a proven must-effect, which only inference over a visible body can
  supply. The representation being unable to state it is the safeguard, not a
  gap.

If step 7's measurement shows ordinary code failing on the `stored` coarsening or
on the missing content/storage distinction, refine then, against a measured case.
Do not widen the language on speculation.

#### What steps 4–8 must implement

Step 5 extends `Result_Provenance`/`Proc_Summary` with the inferred detail below
the level. Step 7 adds `[]Escape_Level` to procedure types and interning, checks
bodies against their declared level (L0644), checks assignability (L0645), and
substitutes obligations at calls (L0646). Step 8 consumes `static` (L0647) using
step 0's duration split. Step 9 documents `@(escape=...)` in `design.md` and
`grammar.md` — now that a form is selected, that update is required, not
speculative.

**Exit met:** representation, defaults, compatibility rule, diagnostics, and
conservative rejections are recorded above, and steps 4–8 implement them without
renegotiation.

### 3. Widen the reaching lattice before adding slots

Done; see the verification record. `prepare_state` allocated two `[]bool` of
`slots * loans` per block. Step 4
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

Shapes done; see the verification record. Content slots move to step 5 with the
walk that reads them — the split is argued at the exit below.

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
limit, field distinctions, mixed capabilities, and empty values, and the cost of
the slots those shapes ask for is measured before it is paid.

The shape machinery and the slot allocation that consumes it were originally one
step. They are split: shapes and their tests land here, and content slots land
with step 5's propagation, which is the first thing that reads them. Allocating
slots nothing consumes would be scaffolding, and the new `Flow_Mode` member has
no meaning until there is a walk that fills it. The guard the original wording
existed to give — that a recursive `type_is_carrier` must not ship alone as if it
were the feature — is kept by this step's measurement obligation and by step 5
owning both halves.

### 5. Propagate aggregate values and direct results together

Partly done; see the verification record for what landed and what is still open.

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

Done; see the verification record.

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

Result contracts done; retention (`stored`, `static`) still open. See the
verification record.

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
- An absent level means `result` — "retains nothing beyond the result" — which
  step 2 chose over the conservative default this plan originally required. That
  reversal is only sound because the promise is *enforced*: every Loke body
  assigned to such a type is checked against it (L0644, L0645), so the absence is
  a real contract rather than missing information. Two residues of the original
  concern survive and must be tested. A `foreign` declaration has no body, so its
  level is an audited programmer promise and the compiler must not present it as
  verified. And the `stored` level's blanket all-arguments-outlive-all-mutable-
  destinations obligation is a coarsening to measure, not a proof of precision:
  record what it falsely rejects.

**Exit:** the input/scratch callback and retaining helper work with the same
documented contract directly, generically, across a package, and through an
abstract procedure parameter. Violating bodies and incompatible procedure-value
assignments fail. Unknown contracts neither erase a region nor manufacture a
lifetime/allocation-base proof. A successful direct-call prototype alone does
not complete this step.

### 8. Enforce retention into static and caller-owned storage

Done, together with step 7's retention half; see the verification record.

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

Coverage (step 0): `free_thread_local` and `free_static` in
[m5b_provenance_regressions.loke](tests/err/m5b_provenance_regressions.loke) pin
the two L0514 texts against each other, which is where the split is observable
today.

Ran: `odin test src` (47 tests), `odin test tests` (14 tests), and the run/trap
corpus at `-opt=minimal`, `size`, `speed`, and `aggressive` — all successful, no
other fixture's acceptance or expected text changed. The panic axis was not run:
`Root_Kind` and `Result_Provenance` appear only in
[borrow.odin](src/borrow.odin) and [cfg.odin](src/cfg.odin), so this change
reaches no emission or cleanup path.

### Step 1 — baseline, decision cases, and instrumentation

Baseline taken on 2026-08-28 at `e3cd8aa71eef7a367e81c3d7764027605963b0c0` with
the three in-flight specification edits uncommitted in the working tree and no
compiler change beyond the counters below. Odin `dev-2025-09-nightly:42c2cb8`,
clang 22.1.8, `x86_64-pc-windows-msvc`. `odin test src` 47 tests / 0.8s,
`odin test tests` 14 tests / 2m54s, and the run/trap corpus at `-opt=minimal`
(3m05s), `size` (2m59s), `speed` (2m54s), and `aggressive` (3m00s) — all
successful. `test-all.ps1` itself was not used as the driver: it trips Windows
PowerShell 5.1's `NativeCommandError` on the test runner's stderr, so its four
commands were run directly.

**Instrumentation.** `LOKE_PROV_STATS=1` makes `analyze_program_provenance`
print `bodies`, `worklist-rounds`, total `reaching-bytes`, and the worst single
body. Unset, it costs one boolean test per body. `bodies` counts only bodies that
reach lattice allocation, which is the right denominator: a body that borrows
nothing never sizes a lattice.

| Program | bodies | rounds | reaching bytes | worst body |
|---|---|---|---|---|
| `tests/run/m6b_maps.loke` | 13 | 26 | 268248 | 265650 (`main`) |
| `tests/run/m6b_regions.loke` | 26 | 29 | 1472 | 300 (`grows`) |
| `tests/run/m5a_ownership.loke` | 25 | 34 | 512 | 240 (`to_string`) |
| `tests/run/m5b_aggregate_baseline.loke` | 24 | 29 | 1024 | 648 (`main`) |
| all-scalar program | 9 | 15 | 296 | 240 (`to_string`) |
| nested/recursive aggregate program | 13 | 16 | 466 | 240 (`to_string`) |

The all-scalar and nested figures are the linked runtime library's bodies; both
user programs contribute nothing measurable, so ~300 bytes is the floor rather
than a property of those programs. The number that matters is `m6b_maps.loke`'s
`main` at 265650 bytes — 99% of that program's total, in one body, before any
content path exists. `slots * loans * 2 * blocks` at one byte per bool is already
the dominant cost in the existing corpus, which settles step 3: the packed-word
conversion is not a contingency.

**Fixtures.** Three added, all labelled per body as POSITIVE (must still compile
after steps 4–7) or GAP (unsound, must stop compiling), so the later flip is a
legible diff rather than a mystery regression:

- [tests/run/m5b_aggregate_baseline.loke](tests/run/m5b_aggregate_baseline.loke) —
  everything accepted today: `wrap`/`unwrap` and the round trip, independent
  fields, union injection/extraction, map value read versus entry pointer, a
  moved owner carrying a borrow, a bare allocation base, and retention into an
  `inout` destination (POSITIVE); a wrapped local escape, a union-wrapped local
  escape, a view read back out of a local map, a write conflicting with a view
  held in a field, a callee-local view retained into a caller's destination, a
  global store, and a `thread_local` store (GAP).
- [tests/pkg/m5b_aggregate/](tests/pkg/m5b_aggregate/main.loke) — the strategy's
  integrated example with today's constructs: a borrow taken from a map with
  `find`, wrapped, carried across a package boundary and through a procedure
  value, and retained through a second helper, each valid case paired with its
  escaping or invalidated-root counterpart.
- [tests/err/m5b_aggregate_false_rejections.loke](tests/err/m5b_aggregate_false_rejections.loke) —
  the two measured false rejections, whose expectations are the thing to be
  removed rather than preserved.

**What the baseline establishes.** The gap is real and it is the wrapper, not the
borrow: `local[:]` returned bare is L0526, and the identical borrow inside
`Holder{local[:]}` compiles. A union alternative and a map value hide it the same
way. Two false rejections are equally concrete: a fresh allocation base put in a
record field reaches `free` as L0514 "unknown provenance" where its bare
equivalent is accepted, and an indirect call's result is assumed to borrow every
borrowed argument, so a callback that returns `input` and only reads `scratch` is
rejected for borrowing `scratch`. That second one is step 2's decision case in
executable form: no inferred summary can fix it, because at the call site there
is no body to infer from.

Unrelated defect found while writing the fixtures, not fixed here: the checker
accepts an explicit union conversion `Choice(Holder{...})` that LLVM emission
then rejects with a type mismatch. Implicit injection is unaffected, which is
what the fixture uses.

### Step 2 — contract representation decided

Decided on 2026-08-28; the record is step 2 itself, and this entry notes only
what the decision changed elsewhere and what it cost.

Selected: `@(escape=<level>)`, one ordered parameter attribute with four levels
(`none` < `result` (default) < `stored` < `static`), a declared upper bound that
inference refines below wherever a body is visible. It was chosen over separate
result-flow and retention marks because a total order collapses assignability to
one comparison in one direction, and over a path- or region-level boundary
language because that is the lifetime language this milestone may not choose
silently.

Implementation cost was checked against the source, not assumed.
`@(allocator_reset)` is the precedent at every layer — `attributes.odin`'s spec
table, `check.odin`'s separate declaration and `^Type_Proc` paths,
`Type_Info.param_resets`, and `intern_proc_type` — so the mechanism exists and
`escape` extends it. `Attribute.value` is a general `Expr`, so the bare
identifier in `@(escape=none)` parses today; only a level accessor beside
`attribute_string_value` is new. No parser change.

One earlier constraint in this plan was reversed by the decision and rewritten
rather than quietly dropped: step 7's "an absent contract must not mean 'retains
nothing'". An absent level now means `result`, which is sound only because the
promise is enforced on every Loke body. The two parts of that constraint that
survive — foreign declarations are audited promises, and `stored`'s blanket
obligation is a coarsening to measure — are recorded in step 7 as testable
requirements.

No compiler change, so no test run beyond re-checking the fixture whose comment
now names the selected form.

### Step 3 — packed reaching lattice

Implemented on 2026-08-28. The reaching component is now one bit per
(slot, loan): `Flow_Block.reach_entry`/`reach_exit`, `Prov_State.reach`, and the
`merged` accumulator became `[]u8`, with `bit_get`, `bit_mark`, `words_or`, and
`words_equal` beside `reach_row`. `invalid` stays `[]bool` — it is indexed by
loan alone and does not multiply. Rows are byte-padded so a row is still an
ordinary subslice; padding bits above `loans` are never set, so whole-byte `or`
and equality remain exact.

**Byte, not a wider word.** A 64-bit version was built and measured first. It
helped the worst body (265650 → 56672) but made every small body *larger*, since
a row costs a whole 8-byte word even with three loans — and that is precisely the
shape step 4 creates when it multiplies `slots` without adding loans. Bytes beat
both 64-bit words and the unpacked form at every size measured, with no
measurable time difference (832ms versus 842ms on three compiles of the heaviest
program, both dominated by clang).

| Program | before | after | worst body after |
|---|---|---|---|
| `tests/run/m6b_maps.loke` | 268248 | 36148 | 35420 (`main`, blocks=23 slots=77 loans=75) |
| `tests/run/m6b_regions.loke` | 1472 | 364 | 80 |
| `tests/run/m5a_ownership.loke` | 512 | 244 | 80 |
| `tests/run/m5b_aggregate_baseline.loke` | 1024 | 312 | 108 (blocks=1 slots=18 loans=18) |
| all-scalar program | 296 | 136 | 80 |
| nested/recursive aggregate program | 466 | 198 | 80 |

7.4x on the body that matters, 2–4x everywhere else. That is the headroom step 4
spends. `LOKE_PROV_STATS` now also prints the worst body's blocks, slots, and
loans, which is what makes the next regression legible.

**Equivalence.** The old and new compilers were run side by side over the whole
corpus: identical diagnostic output on every `tests/err/*.loke`, and byte-identical
`-emit-ll` output on all 123 programs in `tests/run` and `tests/trap`. Then the
full matrix on the new compiler: `odin test src` 47 tests, `odin test tests` 14
tests, and the run/trap corpus at `-opt=minimal` (3m11s), `size` (2m58s), `speed`
(3m00s), and `aggressive` (3m11s) — all successful.

### Step 4 — carrier shapes

Implemented on 2026-08-28. `carrier_shape(c, type)` returns every place inside a
value that can hold a borrow, as ordinary `Proj_Step` paths, so `paths_overlap`
already relates them and a shorter path already covers everything beneath it.
`type_carries_borrow(c, type)` answers whether a carrier is reachable at all and
whether any reachable one is mutable. Both cache on the compiler.

**Finiteness comes from four separate cuts, not from an occurs check.** A
container contributes one wildcard element edge rather than one path per element,
so `[dynamic]Node` is a single edge back into `Node`. Enumeration stops at
`CARRIER_DEPTH` (4) and what is cut becomes one truncated path standing for
everything below it, carrying the strongest capability found there. A type whose
enumeration would exceed `CARRIER_WIDTH` (64) collapses to one truncated path
over the whole value. And a subtree that cannot reach a carrier contributes
nothing, which is what makes a cycle of scalars terminate without inventing a
path.

**Cycle safety without a fixed point.** Reachability here is existential, so a
visiting set gives the *exact* answer for the type asked about: whatever an
already-visiting ancestor reaches, that ancestor reports, and it propagates back
through it. The subtlety is that an intermediate visited during a truncated
exploration may hold an answer that is right for this walk and wrong on its own,
so only the queried type is cached. That is why no worklist is needed and why the
answer does not depend on query order. Both queries run during provenance
analysis, after every body is checked, so no cached shape can describe a type
whose structure was still incomplete — recording that invariant replaced building
an invalidation mechanism for a case that cannot occur.

Nine focused tests in [carrier_test.odin](src/carrier_test.odin) cover a bare
carrier, a scalar record, distinct fields with mixed capabilities, a scalar
cycle, a recursive type in both field orders and both query orders, the depth
limit, a truncated path's capability, map keys versus values, and union
alternatives. The two "no paths" tests assert the type was found, so they cannot
pass vacuously.

**Measured cost of the slots step 5 will allocate**, via a new
`carrying-aggregates`/`content-paths` pair in `LOKE_PROV_STATS`, counted once per
local:

| Program | carrying aggregates | content paths |
|---|---|---|
| `tests/run/m6b_maps.loke` | 1 | 1 |
| `tests/run/m5b_aggregate_baseline.loke` | 12 | 14 |
| `tests/run/m5a_ownership.loke` | 0 | 0 |
| nested/recursive aggregate program | 4 | 14 |

The finding that matters: the body with the largest lattice by far
(`m6b_maps.loke`, 35420 bytes) has one carrying aggregate. Content paths cluster
in code that wraps borrows, which is small and shallow; the recursive case costs
3.5 paths per local. Against step 3's 7.4x reduction there is comfortable
headroom, so step 5 can allocate content slots without a precision trade.

Ran: the full matrix. `odin test src` 56 tests (47 plus the nine new),
`odin test tests` 14 tests, and the run/trap corpus at all four optimization
levels — all successful. Diagnostics were compared against the step 3 compiler
over the whole `tests/err` corpus and are identical: nothing outside the
measurement path changed behavior.

One harness bug found and fixed while writing the tests, worth recording because
it wastes an hour if met again: a helper returned `Compiler` by value after
passing `&c` to the parser and checker, so the returned copy's internals pointed
at the dead local and the test hung rather than crashing. Compilers are filled in
place through a `^Compiler` parameter.

### Step 5 — content flow through values (first slice)

Implemented on 2026-08-28. This is the slice that closes the milestone's
headline gap; the rest of step 5's list is still open and named below.

**What flows now.** A local, parameter, or temporary whose type is not itself a
carrier gets one `Prov_Slot` per `carrier_shape` path, ordered by the shape so
two values of one type pair by index. Reading a whole aggregate yields all of
them; reading a field yields only the slots whose path overlaps it, using
`paths_overlap` rather than a second rule. Construction puts each positional
element's borrows at that element's own field, and a keyed literal joins
conservatively rather than guessing a field index. Declaration and whole-value
assignment publish pairwise; a write through a field replaces only that path.
A parameter is seeded with one loan per path, each borrowing the caller's root at
that path, independently of the parameter binding. Each path weakens to its own
leaf capability, so a mutable slice stored in a read-only field becomes read-only
there — without that, a plain read of the source array was falsely rejected.

Returns needed no work: escapes take their sources from the walked expression,
which now returns content slots.

**Behavior changes, all intended.** Four cases moved from
[m5b_aggregate_baseline.loke](tests/run/m5b_aggregate_baseline.loke) and
[m5b_trust_boundary.loke](tests/run/m5b_trust_boundary.loke) into the new
[m5b_aggregate_wrapping.loke](tests/err/m5b_aggregate_wrapping.loke): a local
wrapped in a record, the same through a union alternative, a write conflicting
with a view held in a field, and `hidden_alias` — the alias inside a
pointer-containing record that `design.md` listed as unchecked. One of step 1's
two measured false rejections is gone: a fresh allocation base put in a record
field now reaches checked `free`, and it is a positive case. The remaining false
rejection is the callback, which needs step 7's contract.

**One conservative rejection turned into an acceptance, deliberately.**
`user_slice_result_outlives_its_receiver` in
[m5b_views.loke](tests/err/m5b_views.loke) reassigned a receiver whose
`operator([:])` result was still live. When the receiver's field is itself a
view, the result borrows what that view borrows — not the receiver's storage — so
replacing the receiver does not invalidate it, and the program is valid. The
fixture keeps its meaning with a receiver that owns its rows, which is still
rejected; the view-holding form became a positive case. This was found by the
corpus, not predicted, and it is the kind of precision gain the milestone is for.

**Cost.** The heaviest body went from 36148 to 36608 reaching bytes and 77 to 78
slots — 1.3%, matching step 4's measurement that content paths cluster in small
shallow code rather than in the bodies with large lattices.

**Still open after the first slice**, closed by the second below.

**The staging `Flow_Mode` was not used, and should be dropped.** It exists so
incomplete plumbing can land without changing acceptance. Content flow's whole
purpose is to change acceptance, and the fixture migration is what makes that
legible to a reviewer; landing dark and flipping later would be two commits for
one change and would hide the corpus evidence. The safety it was meant to provide
came instead from running both compilers over the whole corpus and accounting for
every difference.

Ran: `odin test src` 56 tests, `odin test tests` 14 tests, and the run/trap
corpus at all four optimization levels — all successful. Every difference against
the step 4 compiler across `tests/err`, `tests/run`, `tests/pkg`, `tests/pkg_err`,
and `examples` was enumerated and is accounted for above.

### Step 5 — the rest: consumption, bindings, and path-level summaries

Implemented on 2026-08-28. Each item was probed before it was written, and four
of the five were real holes rather than theoretical ones.

**Consumption.** `move(x)`, and a consuming `self` receiver, both discarded what
the value held. `prov_consume` now reads the content of the place — seeing
through an explicit `move` around it — and only then invalidates, so the borrows
inside travel to wherever the value went while the source binding's own storage
still ends. `move(held)` returning a wrapped view of a local, and
`move(held).take()` returning the same through a consuming method, are both
rejected now. The receiver case needed the move expression's own span rather than
the whole call's, or an existing diagnostic widened its underline.

**Bindings.** A `foreach` element and a type switch's per-case binding were never
defined at all, so a borrow stored inside an element or a union alternative
vanished at the binding. `prov_bind_value` publishes the iterated value into each
element binding at the top of the loop body, and the subject into each case's
binding, using the value's own slot when it is a bare carrier and its content
slots otherwise.

**Path-level result summaries.** This was the one with a measured false
rejection, not just a hole: a helper returning `p.left` made its caller believe
the result borrowed everything the argument held, so writing the array behind
`p.right` was refused. `Result_Provenance.param_paths` now records *which*
content paths of a parameter reach each result, indexed by `carrier_shape` — the
same order the caller's content slots are in, so substitution is an index. The
narrowing is derived from the loan's own projection through `paths_overlap`, so a
loan derived from a field (a reslice, an element) narrows the same way a direct
read does, and anything that cannot be narrowed leaves the entry nil meaning "all
of it". Two escapes through two different fields of one argument now name the two
different arrays they actually borrow.

**`any_view` needed nothing.** Erasure already borrows its subject ahead of every
other arm of the walk, and invalidating the subject while the view is live is
rejected. The escaping form is not expressible: `any_view` may not be a result
type (L0462).

**`exchange` is not a step 5 case.** Its content half already works — the old
value carries what it held. What the probe exposed is the *replacement* being
retained in a caller-owned destination, which is `retain_local_into_inout`,
already recorded as a gap for step 7.

Six cases added to
[m5b_aggregate_wrapping.loke](tests/err/m5b_aggregate_wrapping.loke) and one
precision positive to
[m5b_aggregate_baseline.loke](tests/run/m5b_aggregate_baseline.loke). The whole
corpus was compared against the first slice's compiler: after restoring the
receiver span, `tests/err` output is byte-identical and no other program changed.
Cost is unchanged at 36608 reaching bytes. `odin test src` 56 tests,
`odin test tests` 14 tests, and all four optimization levels pass.

Step 5 is complete. Containers are step 6, and the copy/clone-hook bullet turned
out to need no work of its own: a copy of an aggregate already publishes the
source's content pairwise, and the region half of a clone is existing machinery.

### Step 6 — container contents

Implemented on 2026-08-28. Four changes, each small because steps 4 and 5 had
already built what containers needed.

**A map index names the value half of an entry.** `carrier_shape` gives a map
`[wild, key|value, …]`, but `prov_place_of` gave a map index just `[wild]`, so a
read of `table[k].view` matched nothing in the shape. The place path now ends
`[wild, PROJ_MAP_VALUE]`, which lines the two up exactly. A key is never a place,
so it is reachable only through the shape — which is what keeps a value read from
inheriting what a key borrows.

**An indistinct destination joins instead of replacing.** One content path stands
for every element of a container and every alternative of a union, and a write
reaches only one of them, so replacing the path would erase what the others hold.
`prov_define_content` now joins when the destination path contains a wildcard and
replaces when it does not — an unknown index cannot erase the other elements'
loans, and a known field still replaces exactly.

**Insertion publishes.** `prov_container_content` asks the resolved
`Container_Op` — not a member name — and for `Append`, `Try_Append`, `Insert`,
`Try_Insert`, and `Map_Try_Insert` publishes the stored arguments into the
receiver's element content. Keys and values share the join rather than getting a
second rule, since an unknown index already merges them.

**Reads carry the element out.** Two bails were removing container provenance:
`prov_call_result` returned nothing for a result type that was not itself a
carrier, and `set_synth_result_summary` marked a synthesized result as depending
on its receiver only when the result was a bare carrier. Both now ask
`type_carries_borrow`, which is what makes `lookup_value`, `pop`, and `remove`
carry what the stored value holds. An index read returns the element's content
the same way a field read returns a field's.

**The exit's two halves, both demonstrated.** A copied view outlives a local
container when its original root is the caller's; an entry pointer from `find`
does not, and is rejected naming the table. Container-held borrows now conflict
with writing their source.

Three GAP cases closed and migrated: `map_from_a_local` from the baseline
fixture, and the cross-package `escaping_root` from
[tests/pkg/m5b_aggregate/](tests/pkg/m5b_aggregate/main.loke) into the new
[tests/pkg_err/m5b_aggregate/](tests/pkg_err/m5b_aggregate/main.loke), which also
covers a container element wrapped by an imported helper. That second one is the
integrated example working end to end: an imported wrapper's summary now carries
the caller's root through a record, across a package boundary, and back out.

**Measured precision limits**, recorded rather than fixed: `pop` on a local
container is rejected naming the *container* rather than what the removed element
borrows, because the synthesized summary attributes the result to the receiver.
The rejection is correct and the attribution is conservative. Element content is
one joined set per container, as the plan prototyped; no corpus program was
falsely rejected by that approximation.

Cost is unchanged at 36608 reaching bytes and 78 slots — containers reuse the
element paths step 4 already counted. Against the previous compiler, `tests/err`
output is byte-identical and the only differences anywhere in the corpus are the
two intended GAP flips. `odin test src` 56 tests, `odin test tests` 14 tests, and
all four optimization levels pass.

**Phase 4a gate reached.** Aggregate and container content flow, direct
summaries, root and region preservation, and field precision all pass their
positive and negative cases, and safe `wrap`/`unwrap` was not sacrificed to
reject an unsafe local escape.

### Step 7 — `@(escape=...)` and the result half of the contract

Implemented on 2026-08-28. Step 2's form exists end to end for the levels that
govern results; the retention levels are still open and named below.

**The attribute.** `specs["escape"]` with the `Deferred` value shape, since the
level is a bare identifier rather than a string — `Attribute.value` is a general
expression, so no parser change was needed, as step 2 predicted. Levels are read
at both parameter positions `@(allocator_reset)` already had (a declaration's
signature and a written `^Type_Proc`), stored on the bound symbol and in
`Type_Info.param_escapes`, and interned into procedure type identity.
`type_name` prints them, without which the type-mismatch diagnostic below showed
two identical-looking types.

**Compatibility came free, and stricter than designed.** Because the level
participates in type identity exactly as the reset effect does, a procedure that
promises less than its destination type requires is rejected as an ordinary type
mismatch — no separate rule, no L0645. That is *equality*, not step 2's
`level(callee) <= level(type)` ordering, so a callee that promises **more** than
the type asks is also refused. Sound, conservative, and visible: the fix is to
write the same level. The ordering stays available as a later relaxation, to be
taken against a measured case rather than on principle.

**`none` narrows the indirect call.** `prov_escaping_actuals` drops arguments
whose parameter is at `none` from the conservative result of a call with no
summary. This removes step 1's second and last measured false rejection:
`run_pick` now compiles, and
[m5b_aggregate_false_rejections.loke](tests/err/m5b_aggregate_wrapping.loke) is
deleted, as its own comment said it would be when the last one went.

**Bodies are checked against what they declare** (L0644): a result summary naming
a parameter written `none` is the body contradicting its signature, caught after
the whole-program worklist settles, so it finds the contradiction through a
wrapper as well as directly. `@(escape=...)` on a parameter that carries no
borrow, and an unknown level, are both L0648 — the rule `@(allocator_reset)`
already has for a non-`Allocator` parameter.

The exit case works at every boundary it named:
[m5b_escape_levels.loke](tests/run/m5b_escape_levels.loke) covers the
input/scratch callback directly, through an abstract procedure parameter, through
a procedure value in a local, generically, and with a record-typed `none`
parameter; [tests/pkg/m5b_aggregate/](tests/pkg/m5b_aggregate/main.loke) covers it
across a package boundary. The violating body, the incompatible assignment, and
both malformed forms fail in
[tests/err/m5b_escape_levels.loke](tests/err/m5b_escape_levels.loke).

**Still open, and what it costs.** `stored` and `static` parse, intern, and print
but are not yet enforced: nothing infers retention from writes through mutable
destination paths, so `retain_local_into_inout` and `set_global` remain gaps, and
there is no L0646 or L0647. The step's monotone-may-effect versus proven-clear
distinction and the caller-side outlives obligation belong with that work.
`static` in particular is step 8's input, so the two are best done together.

Adding the attribute changed nothing in the corpus: every `tests/err`,
`tests/run`, `tests/trap`, `tests/pkg`, and `tests/pkg_err` case produced
identical output before and after. `odin test src` 56 tests, `odin test tests` 14
tests, and all four optimization levels pass.

### Step 8 — retention into static, thread, and caller-owned storage

Implemented on 2026-08-28, and with it step 7's retention half. This is the step
that turns design.md's longest "what is not checked" bullet into a checked rule.

**One event, three destinations.** `prov_retain_escape` fires on an assignment
whose destination resolves to a root with process duration, thread duration, or a
caller's storage, and carries the source loans to a `.Retain` check.  The
destination is resolved as a *place*, so a field of a global, a nested container
element, and a write through a tracked alias are all seen — not only the bare
identifier `prov_region_escape` was limited to. Nothing is reported unless the
destination actually receives a borrow, so ordinary global data costs nothing.

**Who satisfies what.** `root_satisfies_retention` answers from the root's kind:
a local, temporary, or hidden literal array satisfies nothing; static and
materialized storage satisfies everything; **thread storage satisfies a thread
destination and not the process**, which is step 0's duration split finally doing
work; an allocation is ordinary rather than proof of anything, since the release
rules already police it; and unknown provenance proves nothing, which is the
whole point of tracking it. A `Param` root is not answered by kind at all — only
its written `@(escape=...)` level can answer, because only the caller knows how
long its storage lives.

**Reading a static or thread carrier yields a borrow of that storage**, which is
what makes `global_view = tls_view` diagnosable at all. Without it a `thread_local`
view was simply invisible.

**The caller's half.** A body check alone would leave `@(escape=static)` as a
promise nobody is held to, so `prov_call_retention` emits the same check at the
call: an argument passed to a `static` parameter must itself outlive the process.
That is what makes `store_in_a_global(numbers[:], &target)` in
[m5b_trust_boundary.loke](tests/run/m5b_trust_boundary.loke) fail where `numbers`
is a local of `main`, and the fixture now passes storage that really does
outlive the process. `run_with` was reassessed as the plan required rather than
grandfathered: its own parameter must carry the contract its callback demands.

**A false rejection found by the corpus and fixed.** Modelling retention lit up
eight standard-library programs with `this string view borrows 'self' … cannot be
stored in 'self'` — an iterator advancing `self.rest = self.rest[n:]`. A root
trivially outlives itself, so storing a value into its own storage is not
retention. The comparison is by *symbol*, not by root identity: a parameter has
one root for its entry loan and another for its places, so identity alone missed
it.

**Still open, deliberately.** `@(escape=stored)`'s caller-side obligation is not
checked: its destinations are other arguments of the same call, and proving one
caller value outlives another needs scope reasoning this step does not have. So
`stored` is enforced in the body — a local cannot be retained into a caller's
storage, and an unconstrained parameter cannot either — but the caller is not yet
held to the ordering. That is the remaining half of L0646 and the honest limit of
this milestone's Phase 4b.

Corpus migration: the retention gaps left in
[m5b_aggregate_baseline.loke](tests/run/m5b_aggregate_baseline.loke) and the three
in `m5b_trust_boundary.loke` became
[m5b_retention.loke](tests/err/m5b_retention.loke), nine rejections covering
local-to-global, local-to-global through a field, unconstrained parameters,
TLS-to-process, local-to-TLS, and both caller-owned cases. Their positive
counterparts — the same procedures with the contract written — stayed in the run
corpus, along with the imported `wrapping.retain`, which now says
`@(escape=stored)`.

`odin test src` 56 tests, `odin test tests` 14 tests, and all four optimization
levels pass.

### Step 9 — specification, grammar, and the deletion audit

Implemented on 2026-08-28. The corpus and fixture bullets of this step were done
with the slices that caused them, in steps 5 through 8; what remained was the
specification, the grammar note, the audit, and the progress records.

**design.md.** The paragraph that said a user record containing pointer or
length fields "is not a new compiler-known borrow carrier" and that storing a
borrow in one escapes the analysis became
[Values that contain borrows](design.md#values-that-contain-borrows): carrier
paths, one per field, one per alternative, one wildcard per container, separate
key and value paths for a map, each with its own capability, bounded in depth and
width, with a cut path standing for everything beneath it so a limit costs
precision and never a check. A record is still not a new *carrier* — it is a
value that contains carriers, and one built from `rawptr` or `[^]T` carries
nothing.

Two new subsections state Phase 4b: [Escape levels](design.md#escape-levels)
gives the four levels, the default, the body check, and the type-identity rule;
[Retaining a borrow](design.md#retaining-a-borrow) gives the three destinations,
what each root kind proves, the parameter's contract as the only answer for a
`Param` root, and the self-retention exemption. The result-summary text gained
thread duration beside static and the per-parameter carrier paths. The pointer
chapter, the `dyn` storing sentence, the `thread_local` storage-duration bullet,
and the procedure-type compatibility paragraph were corrected to match. The
attribute chapter gained `@(escape=<level>)` in the parameter category and a
reference entry beside `@(allocator_reset)`.

[What is not checked](design.md#what-is-not-checked) lost its record/global and
retained-argument entries and gained an honest one: the caller's half of
`@(escape=stored)`. Foreign retention stayed, narrowed to foreign procedures.

**grammar.md.** `@(escape=none)` needs no grammar: `Attribute_Value` is already
an `Expression` and `Parameter` already takes `Attributes?`. The note naming
`@(allocator_reset)` as part of procedure-type compatibility now names both. That
`Parameter = Attributes? ...` production had no fixture, so
[tests/syntax/types.loke](tests/syntax/types.loke) gained an attributed parameter
in the signature that covers every other parameter form.

**The audit found one real hole, in the region half.** `prov_retain_escape`
resolves its destination as a place; `prov_region_escape` still required a bare
identifier, and its call site sat inside `prov_assign`'s identifier branch. So
`global_buffer = make_buffer(n, allocator)` was L0536 and
`global_holder.buffer = make_buffer(n, allocator)` compiled — the milestone's own
headline gap, on the region axis instead of the root one. Both are fixed by
resolving the place, and the case is now in
[m5b_regions.loke](tests/err/m5b_regions.loke). Nothing else in the corpus
changed: an A/B of both compilers over `tests/err`, `tests/run`, `tests/trap`,
`tests/pkg`, `tests/pkg_err`, and `examples` reported no other difference, which
is also why the hole needed a fixture written for it. The same audit records a
result about the library: no declaration in `base` or `core` needs a written
level. Nothing there retains a borrowed argument past a result, so `result` — the
default — is the truthful contract for all of it, and the 25 written levels in
the tree are all in fixtures.

**Deletion audit.** The staging `Flow_Mode` member was never introduced: every
slice landed green on the existing modes, so there is no dead alternative path to
remove and `Flow_Mode` still has its three members. Whole-wrapper loans went with
step 5's content slots and the map value-root shortcut with step 6's
`PROJ_MAP_VALUE`; a map value read now names the value half of the entry and does
not inherit what a key borrows. Summaries are no longer result-only: they carry
per-parameter paths, and retention is answered by the declared level at both
ends. `unsafe.forget_provenance` was never adopted, as the proposal directed.

**Records.** The proposal's migration step 3 is marked done with the one
deliberate omission named. Both Phase 4 exit conditions in the strategy record
their answers: 4a that field distinctions survive a call and that the two
measured false rejections were fixed rather than accepted, with the container
join and `pop` as the recorded conservative limits; 4b that summaries alone do
*not* suffice, which is why `@(escape=...)` exists, with level equality and the
`stored` caller obligation as the recorded limits. The stale L0639 reservation in
[provenance-plan.md](provenance-plan.md) now records what was actually allocated:
L0644 and L0646 through L0648, with L0645 unused. readme.md's claim that the
whole "what is not checked" list "stays that way" is corrected.

`odin test src` 56 tests, `odin test tests` 14 tests, and all four optimization
levels pass.

The plan also asks for a `-panic=abort` pass over the run and trap corpora. It
reports thirteen trap failures, and they are not a regression: the compiler at
`HEAD` produces byte-identical output for each of them. Those fixtures assert
what cleanup *prints while unwinding*, which is exactly what `abort` is defined
not to do, so the suite as written is unwind-specific rather than
strategy-neutral. Making it strategy-aware is its own change and is not claimed
here.

### Follow-up — the caller's half of `@(escape=stored)`

Implemented on 2026-08-28, closing the one item steps 8 and 9 recorded as open.

**The framing was wrong, and that is why it looked hard.** Step 8 described the
missing check as proving that one caller value outlives another, which needs
scope reasoning the solver does not have. It does not need that. A call to a
`stored` parameter *is* the assignment the callee is permitted to make, so the
call gets exactly what an assignment gets: `prov_retain_escape` for the duration
question, and a join into the destination's slots for the flow. Modelling the
flow is what removes the ordering question — the argument's borrows travel into
the destination, and using a borrow after its root has ended is already an error
the analysis reports.

The three destinations fall out of the one model rather than needing three rules:

- a destination in static or thread storage is L0647, the same diagnostic the
  bare assignment gets;
- a destination the caller only passes on is rooted in a parameter, so it is
  L0646: the caller's own parameter must carry the contract instead of stopping
  it;
- a destination that is one of the caller's locals needs no contract at all. It
  gets the loan, and the scope rules answer:
  `keep(inout held, numbers[:])` in an inner block followed by `held.view[0]`
  outside it is **L0513**, the ordinary use-after-scope diagnostic, with no new
  machinery and no new code.

**The destination set is the one the body check already recognises** — an `inout`
parameter or receiver — so caller and callee agree on where a `stored` argument
can go, rather than the caller assuming more than the callee is checked for.

**An indirect call was silently exempt.** `prov_argument_is_inout` asked
`chosen_overload`, which is nil when the callee is a value, so a call through a
procedure value found no destinations and skipped the obligation. It now asks
`prov_call_proc_type`, the same fallback `@(escape=...)` itself uses: a parameter
mode is part of procedure-type compatibility, so an indirect call can answer it.

**A span bug the corpus caught and a manual check did not.** Giving
`prov_retain_escape` an optional span defaulted to `Span{}`, whose `file` is 0 —
a valid file id, not `NO_FILE`. Every body-side retention diagnostic silently
moved to line 1. Grepping the tail of the output missed it; `tests/err`'s exact
spans did not. The parameter is now required at all three call sites.

Corpus: one fixture changed meaning. `escaping_retention` in
[tests/pkg/m5b_aggregate/main.loke](tests/pkg/m5b_aggregate/main.loke) was
labelled `GAP` for exactly this hole and is now rejected, so it moved to
[tests/pkg_err/m5b_aggregate/](tests/pkg_err/m5b_aggregate/main.loke) and a
positive that carries the contract on took its place. Four cases were added to
[m5b_retention.loke](tests/err/m5b_retention.loke) — a global destination, a
forwarded parameter, the scope case, and the same through a procedure value —
and a forwarding positive to
[m5b_aggregate_baseline.loke](tests/run/m5b_aggregate_baseline.loke). An A/B of
both compilers over every corpus reports no other difference.

**What is left, and it is a different hole from the one that closed.** A callee
can retain through a `^mut T` or `[]mut T` parameter — `destination^.view =
values` — and neither the body check nor the call site sees it, because resolving
that destination's root means following the carrier's loans rather than a static
place. `design.md`'s unchecked list now names that instead of the caller's half
of `stored`.

`odin test src` 56 tests, `odin test tests` 14 tests, and all four optimization
levels pass.

### Follow-up — retention through a `^mut` destination

Implemented on 2026-08-28. The previous entry's closing paragraph named this as
the hole left behind; it is closed, and closing it also removed a false rejection
the caller-side check had just introduced.

**Why it was missing at both ends.** `prov_place_of` deliberately stops where a
chain leaves lexical storage: reaching a pointee is a *use of the carrier*, not a
competing access to a root. That is right for the access question and wrong for
the retention one, where what matters is which storage the write lands in — and
for `p^.view` that is whatever `p` borrows, a solved fact rather than a syntactic
one. So `.Retain` gained a second destination form: `into`, the slots holding the
carrier. The solver reads the destination roots off that carrier's reaching
loans, asks `retain_kind_for_root` for each, and runs the same check. One
diagnostic, two ways of naming where the borrow was going.

That covers `p^.view = values`, the auto-deref spelling `p.view = values`, and
`d[0].view = values` through a `[]mut` parameter — all of which compiled before
with no contract written anywhere.

**The caller's side matches.** `prov_writable_arguments` now also returns
arguments whose parameter is a mutable carrier, and the contract check for those
uses the argument's own loans as the destination. The flow half follows `&mut
place` when the argument is written that way.

**A false rejection this exposed.** The previous commit made every `inout`
argument a destination, including one that cannot hold a borrow: passing a view
to `bump :: proc(counter: inout int, @(escape=stored) values: []int)` demanded
`stored` on the caller's own parameter, for a destination where nothing retained
could possibly land. A destination now has to be able to hold a borrow —
`type_carries_borrow` of the `inout` parameter's type, or of a mutable carrier's
element — which is the same question the attribute itself is validated against.
The corpus did not contain the case; the fix has a positive fixture now.

**Corpus.** No existing case changed meaning, so both halves needed fixtures
written for them: three body-side rejections and one caller-side in
[m5b_retention.loke](tests/err/m5b_retention.loke), and three positives in
[m5b_aggregate_baseline.loke](tests/run/m5b_aggregate_baseline.loke) — the
pointer destination with its contract, a caller-local destination through a
pointer, and the `inout int` destination that asks nothing. An A/B of both
compilers over every corpus reports no other difference.

**The remaining limit is precision, not a missing contract.** A destination
reached through a pointer held in a variable — `p := &mut held; keep(p, view)` —
records the borrow against `p` rather than against `held`, so the contract on the
destination's storage is checked while the flow into `held` is not. Written
directly, `keep(&mut held, view)`, both halves hold. `design.md`'s unchecked list
names that.

`odin test src` 56 tests, `odin test tests` 14 tests, and all four optimization
levels pass.

### Follow-up — publishing through a pointer

Implemented on 2026-08-28, closing the precision limit the previous entry
recorded. With it, every part of the retention contract holds through a pointer,
not only the half that could be answered syntactically.

**A destination the solver resolves needs a definition the solver applies.**
`Def` writes into a slot chosen when the graph is built, which is why a write
through a pointer had nowhere to go: the destination is whatever the pointer
borrows. `Publish` is the same operation with the destination read off the
carrier's reaching loans while solving — join, not replace, because one carrier
may name several roots and the write reaches one of them. Joining bits into a row
is monotone, so the fixed point still settles, and it resolves only slots that
already exist: a destination nothing ever reads has no slot, and nothing is lost
by not recording it.

Both spellings now behave the same way. `p^.view = numbers[:]` publishes into
what `p` points at, and so does `keep(p, numbers[:])` where the parameter is
`^mut Holder`. Leaving the source's scope and reading the destination afterwards
is **L0513** in both, exactly as the direct `held.view = numbers[:]` already was.

**The call-site dispatch was wrong and the fixture found it.** A `^mut Holder`
argument is a place — the variable `p` — so the place branch published into `p`'s
own slot rather than into what `p` points at, recording the borrow in the pointer.
Which destination an argument names is decided by how it was passed, not by
whether a place resolves: `prov_argument_is_place` now separates the `inout`
argument, which *is* the destination, from the carrier argument, which points at
it.

**A false rejection the new flow introduced, and its fix.** Publishing skipped
the weakening every assignment does, so a fresh `[]mut int` written into a `[]int`
field through a pointer stayed mutable and conflicted with the read-only borrow
already published there. `prov_weaken` at the publish site restores design.md's
rule that a fresh borrow settles at its destination's capability. The case is in
the run corpus: `HEAD` rejects it with L0511, and the fixture is the positive that
says it must not.

Corpus: two rejections added to
[m5b_retention.loke](tests/err/m5b_retention.loke) — the write and the call, both
through a pointer variable — and one positive to
[m5b_aggregate_baseline.loke](tests/run/m5b_aggregate_baseline.loke). An A/B of
both compilers over every corpus reports no other difference, which also says the
standard library writes through pointers exactly as before.

`odin test src` 56 tests, `odin test tests` 14 tests, and all four optimization
levels pass.

### Follow-up — per-element paths for small fixed arrays

Implemented on 2026-08-28. Phase 4a's exit condition told this step how to
proceed: *measure false rejections before adding per-element tracking*. Three
were measured, all in the same construct, and all now compile:

```odin
holders := [2]Holder{Holder{values}, Holder{local[:]}};
return holders[0].view;          // was blamed for `local`, which element 1 holds
```

plus a write to one element's root while the *other* element's borrow was live,
and the same pair of cases for a bare `[2][]int`.

**The fix is a shape that matches the places.** `prov_place_of` already turns a
constant index into `proj_range(i, i + 1)`, and `paths_overlap` already proves two
constant ranges disjoint — design.md has said "distinct constant fixed-array
indices" are provably disjoint since M5b. Only `carrier_shape` disagreed, giving
every array one wildcard element edge. A fixed array of known length up to
`CARRIER_ARRAY_ELEMENTS` now contributes one path per element. A dynamic array
keeps its wildcard, because one path per element is not finite there, and so does
a longer fixed array: spending the width budget on 64 elements would collapse the
whole type at `CARRIER_WIDTH`, trading every field's precision for one array's.

**Two matchers had to learn the new step kind**, and both would have silently
un-done the change rather than failing:

- `prov_composite_content` matched an element against `proj_field(index)`.
  `steps_overlap` treats a *kind* mismatch as "nothing proven", so a `Field`
  probe against a `Range` path joined every element into every path. An array
  literal now probes with `proj_range`.
- `prov_define_content` decided replace-versus-join from the destination slot's
  path alone. That was sound while every element path held a wildcard; with
  per-index paths, `holders[which] = ...` at an unknown index selects both
  elements through overlap and would have *replaced* each, erasing the loan the
  other element held. The write's own path decides now: indistinct writes join,
  and a constant index replaces — which is what makes `holders[1] = Holder{values}`
  followed by returning `holders[1].view` legal.

Corpus: three positives added to
[m5b_aggregate_baseline.loke](tests/run/m5b_aggregate_baseline.loke) and the two
unknown-index rejections to
[m5b_aggregate_wrapping.loke](tests/err/m5b_aggregate_wrapping.loke). An A/B of
both compilers over every corpus reports no other difference, so no existing
program changed meaning — the gain is entirely in programs that were rejected
before.

`odin test src` 56 tests, `odin test tests` 14 tests, and all four optimization
levels pass.

### Follow-up — a removal names the element's root

Implemented on 2026-08-28, closing the last of Phase 4a's recorded limits.
`holders.pop()` handed back a *borrow of the container*, so returning what the
popped element held was refused as "`holders` ends when this procedure returns"
even when the element borrowed the caller's own argument.

**Why only removals were wrong.** A container's element content already flows
correctly everywhere else: `holders[0].view` reads the content slots through
`prov_content_at`, and `table.lookup_value(key)` works because its receiver is
taken by *value*, so the actual is the receiver's content. A removal's receiver is
`inout`, and that branch substitutes a borrow of the receiver's storage — right
for `append`, which really does hand the callee the container, and wrong for
`pop`, whose result is the element rather than the container.

So the receiver actual for `Pop`, `Remove`, `Remove_Unordered`, and a map's
`Remove` is now the content at the element path, and each carries a written
result summary for the same reason `lookup_value` does: a synthesised member has
no body for the fixed point to walk. A map removal reads the *value* half of the
entry, so what a key borrows does not travel out with it — the same distinction
step 6 made for the map index place.

**The invalidation is a separate question and stayed.** Popping still ends
borrows of the container's own storage: `view := numbers[:]` followed by
`numbers.pop()` is still L0512. What changed is only what the *removed value*
refers to. A borrow the element held — into the caller's array — is correctly not
invalidated by the pop, because popping the container does not move that storage.

The diagnostic improves in the same motion: a popped element that borrowed a
local is now refused naming **`local`**, the root it actually borrows, instead of
the container it came out of.

Corpus: two positives added to
[m5b_aggregate_baseline.loke](tests/run/m5b_aggregate_baseline.loke) — a `pop` and
a map `remove` whose element holds the caller's argument — and the local-holding
`pop` to [m5b_aggregate_wrapping.loke](tests/err/m5b_aggregate_wrapping.loke). An
A/B of both compilers over every corpus reports no other difference.

`odin test src` 56 tests, `odin test tests` 14 tests, and all four optimization
levels pass.

### Follow-up — the escape level's ordering at a procedure value

Implemented on 2026-08-28. Step 2 specified a total order in which "a callee may
promise more than its type asks and never less"; step 7 implemented *equality*,
so a callee promising more was refused along with one promising less. The
ordering holds now.

**Identity and assignability are different questions**, and separating them is
the whole fix. The levels stay part of procedure type identity — that is what
stops an indirect call from laundering a promise, and step 7's reason for putting
them there is unchanged. What was missing is that two distinct types can still be
*assignable*: `proc_escape_weakens_to` accepts a source whose every parameter
level is at most the destination's, with everything else about the two types
matching exactly. It sits in `assignable`, so assignment, argument passing,
return, and generic substitution all get it from one place, and no new diagnostic
is needed: the reverse direction is still the ordinary L0310 mismatch, printed
with the levels. L0645 stays unallocated.

The levels carry no ABI, so the assignment remains a plain pointer copy — nothing
is adapted, boxed, or wrapped.

**The ordering is not a loophole, which the fixture shows.** What governs a call
is the type of the value called, not the identity of what was stored in it. A
`strict` callee assigned into an unannotated `Chooser` is called under
`Chooser`'s promise, so passing it a local scratch buffer and returning the
result is still L0526 — the caller gets no benefit from a promise the type does
not carry. That is the conservative and correct outcome: the gain is that storing
a stricter callee is *allowed*, not that callers may assume more.

Corpus: three positives added to
[m5b_escape_levels.loke](tests/run/m5b_escape_levels.loke) — assignment, argument,
and return — while `assign_a_weaker_callee` in the matching `tests/err` fixture
keeps the refusal in the other direction. An A/B of both compilers over every
corpus reports no other difference.

`odin test src` 56 tests, `odin test tests` 14 tests, and all four optimization
levels pass.

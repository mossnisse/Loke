# Provenance normalization: contracts and implementation

Stage 1 of the [migration plan](provenance-normalization-proposal.md#migration-plan)
established the semantic boundary and baseline. Stage 2 introduces shared
storage IDs and canonical typed places in production. Stage 3 shares typed
transfers between target and region construction. Evaluation and effect
construction still walk the checked AST until stage 4 introduces operation replay.

The [language specification](design.md#borrows-and-lifetimes) remains
authoritative. The baseline records current behavior, with an explicit
[dependency-discovery finding](open-questions.md#normalization-baseline-follow-up),
resolved in stage 3.

## Initial operation contracts

These are the obligations of the first normalized operations, not final Odin
type names. IDs and paths must remain independent of discovered target and
region facts. Each row has an existing behavior to preserve and a test that
observes its semantic input or result.

| Operation | Invariant | Motivating behavior and inspection |
| --- | --- | --- |
| Storage creation | Distinguish a descriptor, its backing object, and carriers stored inside that object. Storage keys survive graph rebuilds. | A copied slice and a borrowed switch payload share one hidden array; `normalization_storage_and_cleanup_contract`. |
| Initialization and store | Attach initial and later stored owner dependencies to the destination's actual cleanup root. Keep handle facts separate. | Owners in slice literal backing and independent sibling fields; `normalization_storage_and_cleanup_contract` and `normalization_summary_and_custom_copy_contract`. |
| Projection | Retain the checked field, index precision, and variant selection. Conservative paths retain their precision limits. | A payload path crosses an array element and the selected union variant; `normalization_storage_and_cleanup_contract`, plus the existing [carrier tests](src/carrier_test.odin). |
| Address | Borrow the selected place, without replacing its identity with targets of its contents. | An address of a pointer descriptor names the descriptor; `normalization_address_and_unknown_target_contract`. |
| Load | Resolve an indirect place through its carrier; keep known and unresolved alternatives together. | A global carrier can replace a known destination without proving that destination impossible; `normalization_address_and_unknown_target_contract`. |
| Borrow and owner view | Preserve access capability, original owner type, and actual materialized-owner lifetime. | An anonymous dynamic array lent as a read-only slice stays owned until block cleanup; `normalization_payload_and_owner_view_contract`. |
| Reborrow | Distinguish a captured carrier value from the source binding, and preserve the point where suspension begins. | `split_at_mut` captures before reading its index and lends afterward; `normalization_delayed_receiver_contract`. |
| Copy and clone | Consume the settled clone flag and selected lifecycle operation. Generated copies replace backing allocations where specified; custom hooks use their result summaries. | A still-used owner clones; a nested custom hook preserves its view and allocator inputs; `normalization_checked_transfer_contract` and `normalization_summary_and_custom_copy_contract`. |
| Move | Consume the checked explicit or last-use move, preserving transferred dependencies. | A final allocating copy becomes a move before normalization; `normalization_checked_transfer_contract` and `normalization_summary_and_custom_copy_contract`. |
| Aggregate and payload transfer | Preserve component paths, variant mappings, and consumption of the containing owner. Checked `as` retains a success/failure distinction. | An unbox consumes its box; checked extraction records its selected variant and fallback; `normalization_payload_and_owner_view_contract` and the [storage-transfer controls](tests/run/provenance_storage_transfers.loke). |
| Call | Preserve checked dispatch, argument evaluation order, parameter binding, and parameter modes. Read current summaries during replay. | Forward calls and recursion settle to a borrowed-input dependency; `normalization_summary_and_custom_copy_contract`. Named arguments and writable calls remain covered by the [evaluation-order cases](tests/err/named_argument_evaluation_order.loke) and storage-transfer controls. |
| Cleanup and invalidation | Preserve normal/unwind order and conditional liveness; distinguish owner cleanup, allocator reset, and provider destruction. | A hidden array has a root-end event; each deferred reset expansion corresponds to lifecycle's `Reset_Key`; `normalization_storage_and_cleanup_contract` and `normalization_defer_reset_correspondence_contract`. |
| Region effect | Preserve owner backing, payload, allocator-handle, and destination-region facts separately. | Moving retains the source region; cloning a dynamic array of scalars replaces its backing; `normalization_summary_and_custom_copy_contract`. |
| Task effect | Evaluate prepared operands on the parent and apply task reach, transfer, and join effects at their existing boundaries. | The existing [thread-summary tests](src/thread_summaries_test.odin) and [parallel task controls](tests/run/parallel_tasks.loke) cover reach, allocator use, thread-exit drops, and joins. |
| Diagnostic origin | Keep the original source operation and owner names through synthetic storage and values. Report after facts settle. | A returned local slice reports `L0526` on `local[:]`; `normalization_diagnostic_origin_contract`. |

The inspection tests are in
[provenance_normalization_test.odin](src/provenance_normalization_test.odin).
They assert properties rather than root numbers, slot counts, map order, or
complete textual graph dumps. The same properties should migrate to normalized
input inspection as operations become available. The delayed-reborrow test uses
a single straight-line body so comparing event positions does not infer runtime
order from unrelated CFG blocks.

## Stage 2: storage and places

[provenance_input.odin](src/provenance_input.odin) owns the normalized
descriptions. `Storage_Id` and `Value_Id` are small body-local IDs, with zero
reserved for unresolved storage or an absent value. `Prov_Storage` records its
checked type, source span, storage kind, and lifetime category. A
`Written_Storage` key provides correspondence: named storage keeps its symbol;
anonymous storage keeps its source identity, storage type, and defer expansion.
Named locals keep one abstract identity across exits, while evaluations inside
different defer expansions have separate keys. Generic bodies have separate
input tables.

`Prov_Place` has a checked result type and projection path, starting either at
a storage ID or at a carrier value ID. `prov_place_of`, `prov_place_carrier`,
and `prov_path_below_carrier` now query this shared description; their separate
recursive syntax walks are removed. A carrier value's source place identifies
its descriptor, and a dereference starts at the carrier value, preserving the
distinction between a pointer and what it points at. Borrowed payload bindings
retain their alias relation to the subject's storage and payload path through
the existing fact construction.

Roots, written targets, and region contents use the same storage IDs, including
hidden arrays and materialized owners. Initialization and later stores meet at
the actual cleanup root. Reset correspondence continues to use `Reset_Key`.
Captured receiver values have their own value IDs and retain the source value
and binding; their copied carrier slots remain separate analysis state. The
existing split-receiver reborrow consumes those captured slots after later
arguments have run.

Input descriptions are cached by source identity, checked representation, and
defer expansion. The representation key includes the effective type and
view/erasure annotations because existing evaluation helpers temporarily expose
an owner's original checked representation. This cache stores no alias sets,
region sets, loans, or call summaries. Identifiers resolve directly through
their symbols: reset analysis creates scratch identifier nodes, whose reusable
addresses cannot serve as cached place identities.

During this stage, the existing region fixed point still rebuilds graphs.
Normalized descriptions are copied with the carried facts, keeping assigned IDs
and independently owning projection slices and map-key strings before the old
graph or carry arena is reclaimed. New syntax queries may add descriptions;
correspondence across separate builds uses keys rather than numeric IDs. Full
construction of immutable operations before replay remains stage 4 work.

Three additional inspection tests check direct/indirect place boundaries,
defer expansion identity, and receiver capture across reassignment. The
[runtime control](tests/run/provenance_normalized_places.loke) checks slice
splitting and cleanup on normal and early exits. A new reassignment control
also exposed a baseline
[emission divergence](known-gaps.md#mutable-slice-splitting-reloads-a-rebound-receiver-during-emission),
recorded separately with a minimal reproduction. The capture inspection checks
analysis metadata, not the emitter's current handling of that example.

## Stage 3: transfers

[provenance_transfer.odin](src/provenance_transfer.odin) interprets the migrated
source forms once into `Prov_Transfer`: forwarding, alternatives, aggregates,
owner borrows, and addresses. Components name a source `Value_Id`, checked type,
source/destination projection paths, transfer mode, lifecycle operation, and
allocator input. Normalized values retain the checked representation used to
describe them, including original owner types and union widening annotations.
Paths are owned by the input arena and copied along with storage descriptions
between graph passes.

Builtin allocation/union constructors, explicit and implicit owner views, `unbox`, checked `as`,
`or_else`/`or_return`, union widening, and settled copies/moves use these
descriptions. A box allocation and its transferred payload have separate paths;
unboxing selects the payload and preserves its move mode. Variant transfers
retain checked tag indices and widening remaps. A stored copy also names its
copy root, so destructuring clones the selected field and widening clones
before remapping variants.

[provenance_transfer_facts.odin](src/provenance_transfer_facts.odin) applies the
same component projections to current carrier targets and allocator regions.
Target projection adapts union tag steps to the existing solver's bounded
carrier paths. Region queries retain the typed paths and distinguish backing,
payload owners, and allocator handles. Neither consumer matches the migrated
constructor or extraction syntax again. Direct arguments and stored values use
the same target recipe; invalidation applies the effective parameter capability
to its result. The former constructor-payload helper, unwrap-depth adjustments,
and duplicate transfer cases in target/region visitors are removed.

Checked copy operations retain hook identity and consult the checked-body
registry, including inherent member bodies. Generated copies recurse by type
until they reach a custom hook, register its summary dependency, and substitute
its current successful result regions. Operations cache no summary or region
facts. Inspection tests check nested dependencies and replay one unchanged
transfer before and after a hook summary grows. Existing copy and extraction
runtime/rejection cases cover cleanup, copied borrows, and allocator selection;
new inspection assertions pin move/clone modes and payload remapping.

This remains an incremental bridge: normalized descriptions are populated during
the existing graph walk. Leaf calls and place reads temporarily expose a value's
captured checked representation to the remaining adapters, then restore it.
Ordinary library calls, including the shared-handle adapters, call effects,
error propagation, evaluation points, and lifecycle events still use the existing
traversal. Stage 4 must complete that vocabulary before moving
the region fixed point to immutable operation replay.

Two behavior corrections have independent compile-only reproductions in
[provenance_normalized_transfers.loke](tests/err/provenance_normalized_transfers.loke).
The stage 2 compiler accepted both premature resets: a call writing owners through
a mutable array view lost the array storage identity, and a call through a stored
read-only pointer failed to follow a writable carrier in its contents. Both now
report `L0537` at the reset, as required by
[allocator region provenance](design.md#allocator-regions-and-region-provenance).
Three additional reset diagnostics in existing rejection cases follow from these
corrections; their expected results are updated. The
[valid control](tests/run/provenance_normalized_transfers.loke) ends dependent
owners before resetting and checks runtime output. The
[changelog](CHANGELOG.md#breaking-changes) gives upgrade guidance.

Validation covers 159 compiler unit tests, 43 LSP unit tests, and all 60 quick-gate
integration checks. The final gate's only failure was binary freshness after a
comment-only source edit; both binaries were rebuilt and that check passed on
rerun. The valid-copy corpus exposed an omitted-count `make` normalization case
during development; it is fixed, and the extraction summary test now asserts
the default allocator without an unknown dependency. Citation and local-link
checks also pass. Performance observations are recorded with the
[baselines](bench/baselines/README.md#transfer-normalization-stage-3).

## AST-sensitive construction inventory

This stage 1 inventory identifies the boundaries that stages 2–4 migrate.
Stage 2 replaces the three independent place walks and migrates storage keys
in fact state to IDs. Stage 3 replaces the constructor, view, extraction, and
copy/move transfer cases with the shared descriptions above.
Type-based shape and overlap helpers, the existing solvers, and summary
scheduling remain reusable.

| Construction responsibility | Current AST-sensitive helpers | Replacement input and migration stage |
| --- | --- | --- |
| Evaluation and control-flow traversal | `walk_flow_expr`, `walk_flow_call`, `walk_flow_stmt`, `walk_flow_switch` in [cfg.odin](src/cfg.odin) | Checked evaluation points and topology; retain the lifecycle walk, migrate provenance interpretation through stages 2–4. |
| Storage and place discovery | `prov_place_of`, `prov_place_carrier`, `prov_path_below_carrier`, `prov_borrowed_storage`, `prov_owner_view_storage`, `prov_slice_literal_storage` in [cfg_provenance.odin](src/cfg_provenance.odin) | Direct or indirect typed places and storage roles; stage 2. |
| Borrowed bindings and materialization | `prov_bind_case_region`, `prov_owner_view`, `prov_slice_literal`, `prov_temp_root_of` | Shared storage identities, original owner types, payload paths, and settled lifetime registrations; stage 2. |
| Carrier target reads and writes | `prov_written_targets`, `prov_written_aliases_at`, `prov_note_alias_source`, `prov_constructor_alias_payload`, `prov_forget_argument_aliases` | Address/load/store/transfer operations and checked capabilities, with explicit unresolved alternatives; stages 2–3. |
| Region queries and field stores | `prov_region_of`, `prov_result_region_at`, `prov_read_storage_regions`, `prov_define_value_regions`, `prov_error_region_at`, `prov_error_region_fields` | Value and place paths, destination shape, and transfer modes; stage 3. |
| Generated and custom copies | `prov_copied_region_at`, `prov_copy_source_region_at`, `prov_clone_region_at`, `prov_copy_hook_region` | Source projections, checked lifecycle operation, allocator input, and current hook summary; stage 3. |
| Call substitution and invalidation | `prov_call`, `prov_call_argument`, `prov_call_written_aliases`, `prov_call_written_regions`, `prov_call_result`, `prov_callback_result`, `prov_callback_returned` | Evaluated operands, parameter slots/modes, checked dispatch, and current summaries; stage 4. |
| Held operands and delayed reborrows | `prov_hold_owner`, with the fact-only `prov_snapshot`, `prov_lend_split_receiver`, and `prov_lend_carrier` helpers | Captured values, source bindings, and explicit hold/reborrow boundaries; stage 2 identities and stage 4 call effects. Reuse the fact-only helpers where their contracts fit. |
| Resets, returns, and cleanup | `prov_call_resets`, `prov_reset_temporary`, `emit_return_cleanups`, `emit_cleanups`, `emit_unwind_branch` | Ordered cleanup and invalidation events, returned/held dependencies, and existing `Reset_Key` correspondence; stages 2 and 4. |
| Implicit calls and task effects | `prov_implicit_call_effects`, `prov_drop_effects` in [global_effects.odin](src/global_effects.odin); `prov_spawn`, `prov_spawn_transfers`, `prov_call_cross_thread` | Checked hook/operator dispatch and explicit task boundaries; stage 4, keeping existing effect worklists. |

Helpers whose only AST use is a diagnostic origin may keep that origin. A
migrated helper must not recover storage meaning, a transfer mode, or a payload
path by matching source syntax again.

## Behavioral and summary baseline

The baseline commit is `81d478b0823daf46499e597fdac8a018c0c3ca3c`, before any
normalization implementation. Existing compile-only and runtime cases remain the
acceptance baseline, including:

- [Storage-transfer rejections](tests/err/provenance_storage_transfers.loke):
  [expected diagnostics](tests/err/provenance_storage_transfers.expected) pin
  eight `L0536` owner escapes and five `L0537` resets, including source positions.
- [Storage-transfer runtime controls](tests/run/provenance_storage_transfers.loke):
  [expected output](tests/run/provenance_storage_transfers.expected) pins valid
  borrowed bindings, payload extraction, cleanup, and independent handles.
- [Copy-region controls](tests/run/copy_region_provenance.loke),
  [clone-result borrows](tests/run/clone_result_borrow.loke),
  [slice splitting](tests/run/split_at_mut.loke), and
  [mutable chunks](tests/run/chunks_mut.loke) cover the reviewed copy and
  receiver contracts alongside their rejection cases.

The inspection suite records result summaries by semantic properties: a returned
view depends on its input after recursive calls settle; a moved owner's region
is retained; a cloned scalar container uses the destination allocator; a custom
hook retains its borrowed input and destination allocator; and a handle field
does not contaminate an independently allocated owner field. Summary identities
are parameter/result paths and symbols, never body-local graph IDs.

The [new benchmark](bench/provenance.loke) adds a forward-call cycle and repeated
anonymous payload, box, and checked-variant transfers to the performance corpus.
Its [expected checksum](bench/provenance.expected) is validated by `perf.ps1`.
The [measurement record](bench/baselines/provenance-normalization-before.json)
and [measurement conditions](bench/baselines/README.md#provenance-normalization)
make the baseline reproducible. The existing script records process wall time
and peak working set, not isolated analysis time or arena high-water usage.
Normalization time and replay counts are not yet available; collect them when
the replay boundary exists rather than treating whole-process figures as
analysis-only measurements.

## Verification and stage boundary

Run the compiler unit suite and the affected integration suites using
[Testing and verification](compiler-architecture.md#testing-and-verification).
The new benchmark is also exercised by `perf.ps1`, which validates its output at
`-opt=speed`. Stage 1 changes tests, workload inputs, and documentation; stage 2
adds the shared descriptions and storage IDs in production. Both the compiler
and LSP must be rebuilt before direct integration runs after that migration.

The operation contracts, helper inventory, behavioral expectations, summary
assertions, and measured baseline are the stage 1 deliverables. A baseline
result that conflicts with the specification must be investigated separately;
it must not become a required property of normalized input.

Stage 1 validation on 2026-10-25: the compiler unit suite passed all 154 tests,
including the eight new inspection tests, with memory tracking enabled. The
performance workflow completed all 24 records and checked every benchmark run's
output. Local documentation links, heading citations, and whitespace checks
passed.

Stage 2 validation on 2026-10-25: all 157 compiler and 43 LSP unit tests passed,
both binaries rebuilt, and the baseline integration suites passed after
rerunning the rejection and debugger suites. The debugger required execution
outside the sandbox. The rejection rerun confirmed that scratch-symbol lookup
preserves the existing reset diagnostics. The performance workflow completed
24 records and checked all benchmark output; the
[stage 2 measurements](bench/baselines/README.md#storage-and-place-normalization-stage-2)
record the observed front-end time increase and essentially unchanged process
peak memory.

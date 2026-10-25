# Provenance normalization: contracts and implementation

Stage 1 of the [migration plan](provenance-normalization-proposal.md#migration-plan)
established the semantic boundary and baseline. Stage 2 introduces shared
storage IDs and canonical typed places in production. Stage 3 shares typed
transfers between target and region construction. Evaluation and effect
construction now record ordered fact operations for replay. Stage 5a makes leaf
region and target queries read normalized values, and stage 5b materializes
fact-dependent events from recorded operations instead of a final walk. Stage 5c
removes the migration's comparison code and lists the queries that still read
source forms.

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
checked type, source span, and storage kind; anonymous storage receives its kind
when it is created. Cleanup timing still comes from the settled lifecycle
annotations, such as temporary extension, not from a copied category. A
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
view/erasure annotations because an owner beneath a conversion is a distinct
value ([stage 5a](#stage-5a-value-based-leaf-queries) replaced the original
temporary exposure of that representation). This cache stores no alias sets,
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

Checked copy operations retain hook identity. A hook member's declaration is
not a procedure declaration, so `prov_has_direct_body` consults the checked-body
registry for it; copy operations and call summaries share that one answer.
Generated copies recurse by type
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

## Stage 4: fact replay and call inputs

[provenance_call.odin](src/provenance_call.odin) owns checked call descriptions:
the selected contract, signature, parameter types/modes, result type, argument
slots in source evaluation order, and receiver mode. A lending slice operation
also references its captured receiver value. Capturing the receiver still occurs
at its argument point; the reborrow begins after later operands have run.
Parameter-order substitution and source-order evaluation remain distinct.

[provenance_effect.odin](src/provenance_effect.odin) records a per-body sequence
of fact-changing operations. These cover declarations, field stores, spread and
map-key stores, borrowed case/element bindings, provider transfers/parents, call
result regions and writes, and carrier-target invalidation. Each operation owns
its checked value IDs, paths, block, and defer expansion. A high-level operation
owns its nested writes, so the recording does not also capture resolved target
sets or intermediate region facts. Rebinding a borrowed name is explicit for
each case and defer expansion. A view of a materialized owner records its own
operation the first time any query reaches it, moving the owner's carrier
targets into the hidden storage it borrows; a view of a named place adds none,
because that place already holds them at their own paths. A store records the
symbol whose destination allocator a copy uses instead of deriving it from the
destination storage, which differs for a map key inserted through indexing.
Every insertion into the input tables, including constant map-key entries, goes
through the frozen-input check and is owned by the input's allocator.

The construction graph supplies the first round's facts and owns shared input
metadata in the body's analysis arena. A zero-weight construction graph is
already final, as in the former fixed point, so it needs neither replay nor
another event walk. Otherwise replay starts from the construction facts instead
of recomputing that first round. Synthetic operator calls are keyed by checked
callee, result type, span, defer expansion, and evaluation mode, so the final
event bridge can reuse their identities.
Captured values retain their own defer expansion as well as their checked
representation; preparing deferred reads in the wrong expansion would construct
a different call or storage identity during replay.

Input tables are frozen before replay. Each round starts fresh fact maps,
stable storage metadata, and the previous round's carried facts, then applies
the ordered operations. The same frozen input is shared by all rounds and the
final event bridge; its paths and descriptions are no longer copied with every carry.
Aliases and hook/callee result summaries are read anew. No replay invokes
`walk_flow_expr`, and assertions reject discovery of new storage, values, call
contracts, copy operations, transfer descriptions, or leaf alias reads. A
replay round uses the ordinary graph constructor but leaves its lifecycle,
loan, and event buffers empty. Recording
also omits scalar operands and operations that cannot change provenance facts,
while retaining their source evaluation slots and effects.

Once the monotone fact weight stops growing, a final graph walk materialized
loan, reset, cleanup, global, and task events with those settled facts, until
[stage 5b](#stage-5b-recorded-events) recorded those events instead. This
preserves precise publication through borrowed payloads, ordered held operands,
normal/unwind cleanup, and the existing reset and task worklists. It is an
explicit stage 5 bridge: at this stage checked leaf queries still read source
metadata and temporarily exposed captured representations, until
[stage 5a](#stage-5a-value-based-leaf-queries). This stage removes repeated
control-flow/source evaluation from the inner fixed point; it does not yet make
all event construction independent of the checked AST. Whole-program summary
visits continue to build one body at a time.
The final bridge can create additional implicit hook temporaries; on its first
such addition it takes a private copy of the input tables, preserving the frozen
program. Fact replay cannot take that escape path or walk source operands.
The [publication rationale](comments.md#provenance-replay-and-precise-publication)
explains why the final event expansion follows settled destinations.

Four inspection tests cover a forwarding chain requiring several fact rounds,
named-argument order and delayed receiver capture, and replay after a nested
hook summary grows without extending input tables, plus retention of global
write events when a zero-weight graph skips replay. The forwarding test compared
an independent checked program with the former AST fixed point until
[stage 5c](#stage-5c-migration-scaffolding) removed that comparison. Existing runtime
and rejection suites remain the behavioral controls; no language behavior
change is intended by this stage.

The [profiling probe](bench/provenance_profile/main.odin) measures full checking,
including repeated whole-program body visits. It reports body builds, fact
replay passes, time in normalization/replay/final materialization, and the
largest sampled arena usage during provenance graph construction. This is
arena bytes used, including construction/carry/replay scratch, rather than
process working set, committed virtual memory, or the borrow solver's later
peak. Run from the repository root:

```powershell
odin run bench/provenance_profile -- bench/provenance.loke bench/workspace examples/corpus_runner.loke
```

Each workload is checked three times in fresh sessions; the probe keeps all
phase figures from the fastest complete check. The process-level comparison
continues to use `perf.ps1`; the
[baseline notes](bench/baselines/README.md#fact-replay-stage-4) record both views.

Stage 4 validation on 2026-10-25: the quick gate passed all 163 compiler unit
tests, 43 LSP unit tests, and 60 integration checks after rebuilding both
binaries. All 2205 spec citations resolve. The performance workflow completed
all 24 records and checked benchmark output; the baseline notes record the
remaining time and memory overhead alongside the initial stage 4 capture.

A review of stage 4 on 2026-10-25 added
`normalization_named_owner_view_contract`, which failed before its fix: viewing
a record's field re-recorded that field's carrier targets at the record's root.
`normalization_define_allocator_contract` pins the recorded copy allocator for a
declaration and for a map key inserted into a map with its own allocator. The
quick gate then passed all 165 compiler unit tests, 43 LSP unit tests, and 60
integration checks with both binaries rebuilt; all 2208 spec citations resolve.

## Stage 5a: value-based leaf queries

Leaf region and target queries take a `Value_Id` and read the value's recorded
representation: its type, view, erasure, widening, and composite backing
(`Prov_Repr`). An operand is the value of its own node at its checked
representation. A value beneath one implicit conversion comes from
`prov_value_beneath`, which interns a distinct value rather than rewriting the
node. Replay therefore passes recorded values directly; `prov_open_value`,
`prov_close_value`, and the in-place type swaps in the view, erasure, widening,
and backing paths are gone: provenance construction no longer rewrites a node's
representation.

The construction walk still evaluates source syntax. A conversion walker records
the conversion it is beneath in `Flow_Graph.converting`, and walk code reads
representation through `prov_repr` and `prov_type`, which fall back to the
checked representation. Values are interned under the same keys as before, so
replay looks up the values construction recorded.

A query can follow a fact-dependent branch to an operand, as the region read of
an unknown carrier falls back to its operand. Freezing the program therefore
interns a value for every operand a recorded value's query can reach, including
the call a user operator stands for. A later round that takes a different
branch finds those values without writing to frozen input. Identifiers also get
values now; their places still come from symbol storage.

Call inputs and split-receiver captures are keyed by the call node and defer
expansion only: a call is never itself beneath a conversion, so its
representation adds no identity. Reset queries read a symbol's region through
`prov_reset_symbol_region` instead of a scratch identifier node. No language
behavior change is intended; the existing normalization inspection, runtime, and
rejection suites are the controls.

Stage 5a validation on 2026-10-25: the quick gate passed all 165 compiler unit
tests, 43 LSP unit tests, and 60 integration checks after rebuilding both
binaries. All 2209 spec citations resolve.

A review of stage 5a on 2026-10-25 found that a user operator's synthetic call
took its node's converted type, so an erased `[dynamic]int` operator result
lost its allocator dependency and a later argument's reset was accepted. The
synthetic call now takes the type beneath every implicit conversion
(`prov_unconverted_type`), which no walk state changes. The
`erased_operator_reset` case in
[provenance_normalized_transfers.loke](tests/err/provenance_normalized_transfers.loke)
failed before the fix. The quick gate then passed all 165 compiler unit tests,
43 LSP unit tests, and 60 integration checks with both binaries rebuilt; all
2210 spec citations resolve.

## Stage 5b: recorded events

The final event walk is gone. Compared field by field over the test, example,
and package corpus, the construction graph and the final walk's had the same
blocks, Flow events, loans, roots, slots, and reborrows; they differed only in
some event payloads and in events present only with settled facts. A trace of
every carried-fact read outside a recorded fact operation, over the same
corpus, found the construction sites below, whose results reach only events,
diagnostics, and summary outputs. Construction therefore produces the returned
graph. Each such site records a `Prov_Event_Operation`
([provenance_event.odin](src/provenance_event.odin)): its fact-independent
inputs, such as values, symbols, spans, and carrier slots, and the walk state it
reads, captured as values. Its materializer runs at once with the facts
construction has, and again once they settle.

| Operation | Construction sites | Fact-dependent output |
| --- | --- | --- |
| `Prov_Event_Reset` | `free_all`, resetting parameters, provider drops, moves, and scope ends, temporary providers, ends through a pointer | The region, which live owner, held operand, temporary, or returned value blocks it, whether it is covered; an end through a pointer only for providers something was lent (`lent_locals`) |
| `Prov_Event_Escape` | `return`, `or_return` | The escaping region, its field regions, and the frame-region name |
| `Prov_Event_Region_Escape`, `Prov_Event_Key_Escape`, `Prov_Event_Static_Escape` | Assigned owners, inserted map keys, owners a call keeps in static storage | Whether a region escape is reported, and its region |
| `Prov_Event_Allocator_Use`, `Prov_Event_Call_Allocator_Use` | `free_all`, clones, drops, fresh container literals, calls no summary follows | `Region_Use` window events, task reservations, the allocator-use summary |
| `Prov_Event_Effect_Use` | Call and drop effects | The regions an effect call's parameters are given, and its window allocator use |
| `Prov_Event_Received_Region` | `@(cross_thread)` arguments | `L0726` |
| `Prov_Event_View_Publish` | Carrier writes through a borrowed payload binding | The storage the binding's region aliases name, and whether the write replaces its old content or keeps it |

The resetting walk state (held operands, temporary roots, the value a `return`
hands back) becomes values: `Prov_Returning` now names the returned value or
the propagated error, and its region is read where a deferred reset needs it.
An allocator control block's root also takes its named provider's settled
region; a provider inside a record keeps its position's token, which comes from
the walk.

Fact operations record the construction events they emitted, and every
recorded operation carries a sequence number, block, defer expansion, and the
`parallel` depth and task site it ran under. Once the facts settle, one more
round replays the fact operations into a fact graph seeded with them and
materializes the event operations interleaved in recorded order, so each sees
the flow-sensitive replay state of its site, such as a borrowed binding's
region aliases. An event operation's construction events are replaced by its
materialization. A fact operation's replay may emit only `Region_Escape` and
`Region_Use` checks, whose position within their block the solver does not
read; they replace its construction ones. Allocator use, task reservations,
and effect-call regions are rebuilt into the returned graph, which also
receives the settled facts.

Construction diagnostics stand, apart from those an event operation reported,
which its settled materialization reports again; replayed fact operations report
nothing. The frozen-input check now has no escape path: replay and
materialization may read only recorded input. A zero-weight graph is still
returned directly.

Before the switch, a development build checked both graphs side by side on 889
inputs, comparing events, loans, roots, slots, root regions, settled facts,
diagnostics, region and window flags, and summary outputs, with no difference.
That comparison is not kept. Few existing programs reach a fact-dependent site
before its facts settle, so
[provenance_settled_events.loke](tests/err/provenance_settled_events.loke)
widens an allocator handle later in a loop than a task reservation, an
allocator-use summary, and a crossing owner that read it; the construction
graph alone accepts all three.

A review of the stage 5b commit found a site that comparison missed. A carrier
written through a borrowed payload binding is published into the storage the
binding's region aliases name, and a later loop iteration can give its subject
another target. Those `Def` events name construction slots but depend on the
facts, so `Prov_Event_View_Publish` materializes the write in the construction
graph with the aliases the replay has at its site; with several targets, each
keeps its old content. The same test drops a source after such a write and
writes to another; the construction graph alone accepted both.

Materialization allocates only in the body's analysis arena, which
`normalization_materialization_allocator_contract` checks, since a language
server checks the same bodies on every edit. Its per-block replacement lists
first came from the process heap, which no check reclaims; over the
measurement's 31 rechecks the server's peak working set rose from 108 to
144 MB, and the test failed until they were allocated in the arena.

Stage 5b validation on 2026-10-25: the quick gate passed all 166 compiler unit
tests, 43 LSP unit tests, and 60 integration checks after rebuilding both
binaries. All 2213 spec citations resolve. Against the stage 5a commit on the
same machine, `perf.ps1` measured front-end time 3–19% lower on every program
(18% on `bench/workspace`), compiler peak working set up to 12% lower, and the
workspace language server 5–11% faster per operation with a peak working set
of 103.4 MB instead of 108.2 MB. Executable sizes were unchanged and every
benchmark output matched.

## Stage 5c: migration scaffolding

The comparison code kept during the migration is gone. The forwarding test
compared the replay with the former AST fixed point, rebuilt in
`provenance_replay_test.odin` by walking the body again with the previous
pass's facts; it now asserts the settled region of its owner directly. That
rebuild was the only user of a graph seeded from another pass, and of a carry
holding its own copy of the input tables, so `build_flow_pass` and
`new_flow_graph` lose their seed and `prov_carry_regions` always shares the
frozen input. An unused helper, `prov_carrier_is_read_only`, is also removed.
A finished graph's query still takes a private copy of the input before adding
to it (`prov_writable_input`).

Stage 5's exit criterion is not met yet. The construction walk is the
normalizer: it reads source syntax to intern values, places, transfers, and
call inputs, and to record fact and event operations. Below it, a query should
read only recorded input, keeping the checked AST as a key, a diagnostic span
or name, or checked metadata such as a call's resolution. A static call graph
from fact replay and event materialization finds these queries still choosing
their rule by the form of a value's origin node, or walking a call's
arguments:

| Query | What it still reads from the AST |
| --- | --- |
| `prov_region_of`, `prov_result_region_at` | The origin's form: an identifier's symbol, a selector's field, a dereference, a propagated error, a call |
| `prov_written_aliases_at` | The operand of a selector, index, dereference, or address |
| `prov_escape_region` | A provider's identifier or moved operand |
| `prov_moved_bits`, `prov_expr_is_temporary` | Moved, exchanged, boxed, and composite operands; which forms are temporaries |
| `prov_call_node`, `prov_operator_call` | Which operator forms stand for a user operator's call, and their operands |
| `prov_error_region_at` | The operand of a propagated error |
| `prov_argument_regions`, `prov_call_allocator_use`, `prov_handle_region` | A call's arguments and their types; a provider's receiver form |

The operands they reach are interned while the program freezes, so the
frozen-input check holds; the remaining step is to record each value's form,
its operand values, and its call's argument values when the value is interned,
and have these queries read that record instead.

Stage 5c validation on 2026-10-25: the quick gate passed all 166 compiler unit
tests, 43 LSP unit tests, and 60 integration checks after rebuilding both
binaries. All 2214 spec citations resolve; the removed comparison held one.

## AST-sensitive construction inventory

This stage 1 inventory identifies the boundaries that stages 2–4 migrate;
[stage 5c](#stage-5c-migration-scaffolding) lists what remains.
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
The initial record has no normalization timings or replay counts. Stage 4 adds
those figures through the separate profiling probe above; whole-process figures
remain distinct from analysis-only measurements.

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

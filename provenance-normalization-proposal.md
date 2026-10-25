# Proposal: normalized input for provenance and borrow analysis

**Status:** stages 1–3 and stage 4's fact replay implemented, 2026-10-25. This proposes an internal compiler
refactor; it does not change the language contract. The rules in
[design.md](design.md#borrows-and-lifetimes) remain authoritative. The
[stage 1 contract and baseline](provenance-normalization-contract.md#initial-operation-contracts)
are recorded; [stage 2](provenance-normalization-contract.md#stage-2-storage-and-places)
provides shared storage IDs and typed places. [Stage 3](provenance-normalization-contract.md#stage-3-transfers)
shares typed transfer operations between target and region construction.
[Stage 4](provenance-normalization-contract.md#stage-4-fact-replay-and-call-inputs)
replays fact-changing effects over frozen input.
[Stage 5a](provenance-normalization-contract.md#stage-5a-value-based-leaf-queries)
makes leaf queries value-based, and
[stage 5b](provenance-normalization-contract.md#stage-5b-recorded-events)
replaces the final loan/event walk with recorded events.
[Stage 5c](provenance-normalization-contract.md#stage-5c-migration-scaffolding)
removes the comparison code and lists the queries that still read source forms;
[stage 5d](provenance-normalization-contract.md#stage-5d-value-forms) has them
read each value's recorded form, and
[stage 5e](provenance-normalization-contract.md#stage-5e-call-arguments) has the
call-substitution helpers read the recorded call arguments. Pending architectural decisions are tracked in
[Open questions](open-questions.md#normalized-input-for-provenance-analysis).

## Recommendation

Introduce a small, typed operation representation between the checked AST and
provenance fact construction. Build it alongside the existing control-flow
topology. Make storage identity, projections, borrowing, copying, moving, calls,
and cleanup explicit before computing carrier targets and allocator regions.

The first consumer is provenance analysis. Keep the current ownership pass,
whole-program summary scheduling, and LLVM emission while migrating. Reuse the
existing graph, projection vocabulary, type information, and solvers wherever
their contracts fit. A durable general-purpose MIR, SSA conversion, and an LLVM
backend rewrite are outside this proposal.

The desired boundary is:

```text
checked AST + settled lifecycle annotations
    -> normalized operations and control-flow edges
    -> target and region facts, call-summary substitution
    -> existing borrow/region solvers and diagnostics
```

Moving the existing AST visitors later in the pipeline would leave their
syntax-specific logic intact. The change is to what the analysis consumes.

## Problem and current architecture

The [current pipeline](compiler-architecture.md#driver-and-phase-order) checks
concrete procedure bodies and runs lifecycle analysis before whole-program
provenance analysis. The compiler already resolves types, calls, conversions,
and many lowering choices on its
[annotated AST](compiler-architecture.md#one-annotated-ast).

However, analysis construction still repeatedly interprets that AST:

- `walk_flow_expr` in [src/cfg.odin](src/cfg.odin) constructs control flow and
  invokes provenance helpers while visiting source expressions.
- `prov_note_alias_source`, region queries, and temporary handling in
  [src/cfg_provenance.odin](src/cfg_provenance.odin) separately recognize source
  forms and reconstruct storage and payload paths.
- `build_flow_graph` rebuilds the AST-derived graph while region facts grow.
  Whole-program summary rounds rebuild it again as callees' summaries change.
- The solvers in [src/borrow.odin](src/borrow.odin) already consume abstract
  events. The largest opportunity is the boundary that produces those events.

Recent fixes illustrate the cost: borrowed switch payloads in anonymous
storage, `unbox`, checked `as`, and owner-to-view conversions each needed
explicit handling to preserve facts that another spelling already retained.
Anonymous owners also needed their initial and later stored region dependencies
connected to the same cleanup identity. The
[storage-transfer regressions](tests/err/provenance_storage_transfers.loke) and
[valid runtime controls](tests/run/provenance_storage_transfers.loke) capture
these cases.

These fixes remain necessary. The proposal makes their storage and transfer
rules reusable instead of adding another interpretation for each syntax form.

## Scope and invariants

The refactor should preserve acceptance, rejection, diagnostic locations,
evaluation order, cleanup, and the specified
[minimum provenance precision](design.md#minimum-provenance-precision).
Any discovered behavior bug gets its own reproduction and correction against
the specification; an existing compiler result is not automatically correct.

The normalized representation must preserve these distinctions:

1. **A place and its contents.** The address of a record is different from the
   targets of carriers stored in the record. A view's backing storage is
   different from the view descriptor's local storage.
2. **A borrow, a value copy, an owner clone, and a move.** An owner clone can
   allocate new backing while retaining dependencies inside its contents.
   Carrier copies preserve the relevant aliasing and capability rules.
3. **A handle and an owner dependency.** An allocator handle in one field must
   not make an independently allocated sibling owner depend on that region.
4. **Known and unknown alternatives.** Joining a known destination with an
   unresolved destination must retain both. Empty and unknown target sets must
   not be interchangeable.
5. **Storage lifetime and last use.** An unused view does not end the lifetime
   of its hidden owner. Cleanup and allocator-provider destruction remain
   explicit, separate events.

The existing bounded paths, conservative aliasing, region joins, callback
contracts, and thread effects still apply. Normalization does not make these
semantic problems disappear or introduce new strong-update rules.

## Proposed representation

### Values, storage, and places

Use small typed IDs local to a concrete body and checked revision. Names below
describe the contract, not a required final Odin API:

| Entity | Meaning |
| --- | --- |
| `Value_Id` | An evaluated value with a known type; it need not own addressable storage. |
| `Storage_Id` | An abstract storage object: a local, parameter place, global, hidden backing array, or materialized temporary. |
| Place | Direct storage plus a projection path, or an indirect place reached through a carrier value plus a path. |
| Operation ID | A semantic operation occurrence, with an origin used for diagnostics and cross-pass correspondence. |

Storage entries record type, source origin, storage category, and applicable
lifetime information. Global references retain `Symbol_Id`; a body-local ID
must never become a cross-body summary identity. Summaries continue to describe
parameter/result paths, global symbols, and region dependencies.

Reuse `Proj_Step` and its overlap/precision rules. Field selection, indexed
storage, and payload selection need explicit checked paths. A dereference
resolves a carrier's targets; it must not silently treat the carrier's own
storage as its pointee. Owner backing and descriptor storage must remain
distinguishable, including when the existing implementation represents backing
through a typed projection rather than a separate root.

Stable storage lookup may initially wrap `Written_Storage`. The builder may use
AST identity, symbols, and a semantic role to assign IDs, but transfer functions
must not inspect AST pointers to determine storage meaning. A single expression
can contribute several roles, such as a result value and a hidden backing array.

### Operation vocabulary

Start with operations needed by current provenance consumers:

| Operation family | Required information |
| --- | --- |
| Storage and lifetime | Storage creation, initialization point, scope/statement lifetime, cleanup or invalidation point. |
| Projection and load | Typed source place, selected field/index/payload path, destination value, access capability. |
| Borrow and reborrow | Source place or captured carrier value, resulting carrier, capability, relation to the source binding or original borrow, and the point where the reborrow begins. |
| Transfer and store | Source value or place, destination, checked copy/clone/move mode and lifecycle operation, allocator when relevant. |
| Aggregate construction | Destination shape and explicit component-to-path transfers, including variant remapping. |
| Call | Resolved operation/callee or indirect contract, evaluated arguments in source evaluation order mapped to parameter slots, parameter modes, result and exit edges. |
| Region and task effects | Reset/provider end, spawn/join, and the existing retention, global, and cross-task effects. |

Control-flow edges represent branches, loops, early returns, and unwind paths.
The representation can omit computations with no relevant effects, but must
preserve their evaluation points when they can call, panic, move, or affect
cleanup. Compile-time indices and other precision metadata come from checked
annotations rather than re-evaluation by the analysis.

Build ordinary control-flow temporaries and assignments as needed; SSA and phi
nodes are unnecessary for the existing dataflow solvers. Use tagged operations
with operation-specific data, avoiding a second large record of unrelated
optional fields.

### Custom copy hooks

A normalized copy or clone references the checked lifecycle operation, including
its selected custom copy hook where applicable. The initial representation keeps
that reference rather than expanding every generated copy into a second lifecycle
implementation. A mode and destination allocator alone are insufficient: a
custom hook may retain source regions or return fresh contents. Generated copies
apply their recursive rules only until they reach a custom hook, including hooks
on nested fields or elements.

During replay, a custom hook registers a summary dependency and substitutes its
current result summary using the source and allocator inputs. Project the
successful payload of the hook's fallible result into the destination paths;
preserve the enclosing operation's failure and cleanup behavior. Do not assume
that every owner clone replaces its backing allocation. Logical copies of shared
storage retain dependencies, and custom copies follow their result summaries,
as required by
[Allocator regions and region provenance](design.md#allocator-regions-and-region-provenance).

This preserves the role of `prov_copy_hook_region` without retaining its
AST-based source queries. Hook identity and checked lifecycle metadata belong
to the operation; substituted targets and regions belong to replay state.
Changes to hook summaries must revisit dependent bodies through the existing
worklist without changing the normalized operations.

### Facts remain separate from operations

An operation describes what the program does. It must not contain a prematurely
settled alias set or call result summary. Target facts, owner-region facts,
allocator-handle facts, and root loans remain analysis state attached to stable
IDs and paths.

A transfer consumes those facts according to its explicit mode. Both target
tracking and region propagation use that same mode and projection mapping.
They can retain separate lattices and solvers; sharing the semantic input does
not require merging every analysis into one state machine.

For calls, normalize arguments and the checked contract once, then consult the
current callee summary during each analysis round. Keep callback dependency
discovery and global/thread effect propagation in the existing worklists.
Summary changes must update facts without changing normalized storage IDs.

## How source forms normalize

The following sketches describe analysis operations, not executable Loke code
or a proposed textual IR format.

### Slice literal and borrowed payload

For a slice literal holding optional wrappers, followed by a switch that borrows
one wrapper:

```text
create hidden array storage H, ending at the enclosing block cleanup
initialize H[index].variant_payload from the checked element value
borrow H as the slice value
branch on the selected element's variant
on the matching edge, bind a borrow of H[index].variant_payload
```

The payload binding is a place alias. It is not a copied wrapper and does not
create an unrelated owner. A call through that binding reaches the same storage
and nested carrier targets as a call through the original array element.
Both initial element regions and subsequent stores belong to H. Reset checks
consult H while its cleanup remains pending.

### Unboxing and checked variant extraction

`unbox` selects the box payload and transfers ownership out. Its normalized
operation also records consumption of the box and the end of the box allocation
as required by the checked operation; the extracted payload retains its own
dependencies and carrier targets.

Checked `as` branches on the selected variant. The matching edge transfers the
payload into the result's success payload using the checked copy/clone behavior;
the other edge constructs the failure result. A subsequent `or_else` or
`or_return` selects that success payload or follows its failure edge. These
forms share projection and transfer operations while retaining their different
control flow and ownership effects.

This replaces syntax-specific depth adjustments with explicit source and
destination paths. Variant indices and widening mappings must remain available;
normalization must not collapse distinct variants merely to simplify the IR.

### Read-only view of an anonymous owner

Materialize the owner, register its real cleanup boundary, and create a borrow
of the appropriate backing/payload place. Loading an owner through that view
and returning a copy uses an explicit clone operation. Newly allocated backing
and retained dependencies follow the checked lifecycle operation, including
[custom copy hooks](#custom-copy-hooks).

Read-only capability limits mutation; it does not remove storage identity or
region dependencies. Ending the view's last use does not authorize resetting a
region while the materialized owner or a dependent copied result remains live.

### Delayed reborrow of a captured receiver

[Splitting a mutable slice](design.md#splitting-a-mutable-slice) evaluates the
receiver before the index, but takes its mutable reborrow after the index.
For `xs.split_at_mut(xs.len() / 2)`, normalize that ordering explicitly:

```text
load the receiver value into V, retaining its source binding S
evaluate the index expression into M while S is still usable
begin a mutable reborrow of captured V, related to source binding S
produce the two disjoint halves from V and M under that reborrow
```

The captured `Value_Id` and source binding have distinct roles. The value fixes
which storage the result views; the source relation lets the existing reborrow
solver suspend the binding while it still views that storage. If evaluating the
index reassigns `xs`, the halves still view the original captured value. Do not
reload `xs` when beginning the reborrow, or begin the reborrow at the initial
load. Preserve the result's disjointness and the ordinary lifetime checks on
the captured storage.

The current `prov_snapshot` / `prov_lend_split_receiver` pair implements this
distinction. Normalized loads and reborrows must retain both identities and the
separate evaluation points. Apply the same receiver handling to `chunks_mut`;
it must remain explicit when call processing moves to replay.

## Pipeline and lifetime integration

### First implementation boundary

Keep body checking and `analyze_ownership` in their current order. Normalize
provenance input only after that body's lifecycle annotations are settled.
Consume checked copy/move decisions, cleanup slots, and temporary-extension
annotations. Do not ask provenance to decide them again.

Initially, build the normalized body once per `build_flow_graph` invocation,
outside its inner region fixed-point loop. Replay immutable operations into
fresh analysis state as facts grow. Whole-program summary scheduling may still
rebuild the normalized body on its next visit. This preserves the existing
bounded-memory strategy without requiring a persistent cache or session
invalidation changes in the first implementation.

Keep normalized operations in an arena whose lifetime encloses the disposable
fact graphs and carried facts. No retained fact may reference a reclaimed
operation buffer. Whole-program summaries copy only the data they retain.

### Identity across passes and control-flow expansions

During replay, IDs are fixed because the normalized body is immutable. Across
rebuilds, derive correspondence from the concrete body, source identity,
semantic role, and expansion identity where needed; never from the number or
order of discovered facts. Generic instances have separate identity spaces.

Lifecycle/provenance reset correspondence must keep using `Reset_Key` until
both consumers use a proven common replacement. Preserve `Defer_Expansion`:
the same deferred source can run on several exits. A local that each exit
cleans up remains the same abstract storage, while temporary evaluations inside
different defer expansions need their own operation correspondence. A loop
site remains an abstract site with repeated lifetime events; this proposal does
not promise a distinct analysis object for every runtime iteration.

Preserve normal and unwind cleanup order, conditional initialization, held
operands, and branch-specific temporary lifetimes. Retain the distinction
between a reset, provider destruction, and owner cleanup. These are central to
[allocator-region rules](design.md#allocator-regions-and-region-provenance),
not optional details of the lowering.

### Diagnostics and emission

Every operation keeps an origin span and, where necessary, related declaration,
owner, or exit origins. Synthetic values should not replace source names in
diagnostics. Keep diagnostic generation after the appropriate facts settle,
and preserve the current suppression of diagnostics from superseded rounds.

LLVM continues to consume the checked AST. The normalizer must consume the same
checked call operations, transfer decisions, evaluation order, and cleanup
annotations as emission. Add semantic comparison tests where these consumers
could diverge. If a needed decision is currently implicit in an emitter helper,
record or share that decision at the semantic boundary rather than independently
guessing it in the normalizer.

## Migration plan

Each stage should leave a usable compiler and remove the replaced logic before
the next stage expands the representation.

Stage 1 is complete: the [contract and baseline](provenance-normalization-contract.md#initial-operation-contracts)
record operation invariants, the AST-sensitive helper inventory, semantic
inspection tests, and measured performance. The existing
[hook dependency-discovery follow-up](open-questions.md#normalization-baseline-follow-up)
is resolved in stage 3 against the checked-body registry, with nested dependency
and summary-growth tests.

Stage 2 uses one canonical place description for direct storage and indirect
carrier access. Storage IDs are shared by roots, targets, and region contents;
captured receiver values retain their source bindings and separate fact slots.
The [implementation notes](provenance-normalization-contract.md#stage-2-storage-and-places)
describe the current bridge across reconstructed graph passes and the separate
receiver-emission finding.

Stage 3 normalizes constructors, owner views, extraction, widening, and checked
copies/moves into shared component paths. Target recording and region propagation
consume those descriptions for stored values and direct arguments. The
[implementation notes](provenance-normalization-contract.md#stage-3-transfers)
record the remaining call/evaluation bridge and two separately reproduced reset
checking fixes.

Stage 4 records checked call inputs and ordered fact-changing operations once,
then replays them as targets and regions grow. The input tables are frozen;
replay cannot evaluate source operands or construct new values, storage, calls,
or transfer descriptions. Reset, cleanup, task, and loan events are materialized
once with settled facts through the remaining event bridge. The
[stage 4 notes](provenance-normalization-contract.md#stage-4-fact-replay-and-call-inputs)
state that boundary explicitly. Stage 5a replaced the checked leaf adapters with
value-based queries, and stage 5b the final walk with recorded events. Stage 5c
removed the temporary comparison code, stage 5d made the queries it lists
read each value's recorded form, and stage 5e made the call-substitution
helpers read the recorded call arguments.

| Stage | Change | Exit criterion |
| --- | --- | --- |
| 1. Establish the contract | Record baseline diagnostics, summaries, and performance; enumerate AST-sensitive target/region helpers; add focused normalization inspection in tests. | Every initial operation has an invariant and at least one motivating existing behavior. |
| 2. Normalize storage and places | Add shared IDs and canonical places for locals, anonymous owners, literal backing arrays, and borrowed bindings; distinguish captured carrier values from their source bindings. Adapt current fact construction to consume them. | Direct and borrowed access to the same storage share identity; a captured receiver keeps its original value across later argument evaluation; cleanup and reset correspondence remain correct. |
| 3. Normalize transfers | Express constructors, owner views, payload extraction, and copy/clone/move behavior as explicit operations referencing checked lifecycle operations. Migrate target recording and field-region propagation together. | The migrated helpers no longer dispatch on these AST forms; stored and direct-argument forms behave alike; direct and nested custom copy hooks use current result summaries and register dependencies. |
| 4. Replay effects | Finish call, reset, cleanup, and task effects, including delayed receiver reborrows; move the inner region fixed point to operation replay. | Replaying with different summary facts does not rebuild syntax interpretation or mutate operations; receiver capture and reborrow timing remain distinct. |
| 5. Remove the bridge | Delete obsolete AST transfer paths and temporary comparison code; document the actual representation and phase contracts. | Production provenance consumes normalized operations, and every remaining AST access has an explicit origin/metadata purpose. |

Use temporary comparison code in tests or development builds during migration,
not a permanent user-facing checker selection flag. Compare independent runs;
do not let two builders mutate the same lifecycle annotations or emit duplicate
diagnostics. For a case with a known old bug, compare against the regression
expectation and specification instead of demanding agreement with the old path.

Potential later work is to let lifecycle analysis consume the same normalized
body. That requires a separate design for unresolved cleanup and last-use
decisions: the first version deliberately consumes already settled lifecycle
annotations. Moving lifecycle at the same time would obscure the source of
behavior changes. Retaining normalized bodies across summary rounds is also a
later, measured choice.

## Validation and completion criteria

Follow [Testing and verification](compiler-architecture.md#testing-and-verification).
Rebuild both compiler and LSP before direct integration runs. Run affected
suites during each stage and the quick gate at the completed migration. The
full optimization/fuzzer gate remains governed by the repository's existing
rules.

Cover behavior, not just the new representation's structure:

| Area | Required comparisons |
| --- | --- |
| Storage identity | Named owner versus anonymous owner; two views of one backing object; direct and nested borrowed switch bindings. |
| Transfer semantics | Stored and inline `unbox`, checked `as`, `or_else`, and `or_return`; borrowed place versus moved value; carrier copy versus owner clone. |
| Custom copies | Direct hooks and hooks nested in generated copies; source-region retention versus fresh allocation; successful payload projection and failure cleanup; replay after hook summaries change. |
| Receiver reborrows | `split_at_mut` and `chunks_mut` with later arguments reading the receiver; index evaluation reassigning the source binding; results still tied to the captured storage, with correct suspension, disjointness, and lifetime checks. |
| Region precision | Initial and later stored owners; copied-out dependencies; allocator handles beside independent owners; read-only and mutable views. |
| Unknown targets | Branches and calls combining known and unresolved storage; writable nested carriers under read-only outer access. |
| Lifetime and control flow | Last use versus owner cleanup; loops, early return, defer expansion, unwind, partial initialization, and held operands. |
| Interprocedural effects | Recursive summaries, callbacks, global writes, provider reset/destruction, and task spawn/join effects. |
| Tooling | Stable diagnostic codes and source spans; unchanged checked AST behavior for emission, semantic queries, and LSP. |

Unsafe examples are compile-only rejection tests. Valid controls run and check
output; ownership-sensitive cases also verify the relevant cleanup behavior.
Normalization tests should establish properties such as one shared storage
identity and correct transfer mode, without freezing every incidental temporary
number in large golden dumps.

Use `tests/run/copy_region_provenance.loke` and
`tests/run/clone_result_borrow.loke` as existing custom-copy controls, and
`tests/run/split_at_mut.loke` and `tests/run/chunks_mut.loke` as receiver-reborrow
controls, alongside their relevant rejection cases. Add focused coverage for
nested hook summaries and receiver reassignment where the existing corpus does
not exercise these contracts.

Measure total check time, normalization time, graph replay count, and peak
analysis memory on representative existing workloads using
[the performance workflow](compiler-architecture.md#testing-and-verification).
Include a body with many payload transfers and repeated summary rounds if the
existing workloads miss that cost. Record measurements before promising a
speedup or deciding to retain more bodies in memory.

The work is complete when:

- Target and region transfer functions consume explicit operations and paths;
  adding a new spelling of an existing transfer requires changing normalization
  and its tests, rather than several fact visitors.
- Anonymous and named storage follow the same identity and lifetime contract.
- Call summaries can grow without changing normalized topology or identities.
- Existing acceptance, diagnostics, and runtime behavior are preserved except
  for separately documented fixes, with no unexplained precision loss.
- Replaced AST-specific code and temporary migration machinery are removed.
- Measured compile-time and memory effects are documented and acceptable.

## Tradeoffs and decision boundary

A new operation layer adds code and another representation to inspect. It earns
that cost only if it replaces repeated semantic interpretation. If a stage adds
operations while leaving equivalent production AST branches behind, stop and
complete that migration before adding more operation families.

The main correctness risk is disagreement with emission about copies, evaluation
order, or cleanup. The main resource risk is retaining normalized bodies alongside
all existing graphs. Shared checked decisions, source-level regression tests,
and one-body-at-a-time construction address these risks in the initial design.

Continuing to consolidate AST helpers is a useful smaller change, but it leaves
every analysis consumer responsible for using those helpers consistently.
A fully lowered backend IR could eventually unify more consumers, but would
require a much larger migration and preserve high-level ownership metadata
through lowering. The proposed operation boundary targets the demonstrated
provenance maintenance problem first.

Adopt stages 1–3 as the first deliverable. Proceed to replaying the entire effect
vocabulary once the transfer migration demonstrably removes duplicate handling
and preserves the regression corpus. No language changes are required to begin.

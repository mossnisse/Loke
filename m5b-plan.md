# M5b implementation plan — borrows, provenance, and allocator regions

## Context

[M5a](m5a-plan.md) establishes concrete lifecycle and liveness: slices and
allocation roots exist, moves and drops are explicit in annotations, every
procedure instance has a disposable CFG, and scope cleanup has one observable
order. **M5b** adds the two provenance analyses that consume those facts. Root
provenance enforces borrow lifetime and capability; region provenance prevents
owners from escaping the allocator region that backs them and prevents locally
tracked owners or carriers from surviving reset of that region.

The analyses share one expanded provenance event stream and diagnostic CFG walk
but remain distinct. A slice of an owner depends on the owner's storage root and
transitively on its allocator region. Passing the root rule does not prove the
region live, and passing the region rule does not grant compatible access to the
root.

M5b also closes the explicit M4/M5a compatibility gaps for `any_view`, `dyn`,
`inout` results, user `operator([:])` results, copied allocation-base pointers,
and slices. Runtime `string_view`/`cstring_view`, dynamic containers, allocator
providers, and the exact `mem.Arena` examples remain unavailable until M6; the
analysis has carrier/provider hooks for them, but M5b's executable fixtures use
M5 types rather than pretending those M6 types already exist.

The normative sections for this half are
[Storage roots and borrow carriers](design.md#storage-roots-and-borrow-carriers),
[Capabilities and the one rule](design.md#capabilities-and-the-one-rule),
[Temporaries and procedure boundaries](design.md#temporaries-and-procedure-boundaries),
[What is not checked](design.md#what-is-not-checked), and
[Allocator regions and region provenance](design.md#allocator-regions-and-region-provenance),
together with the M5a lifecycle sections that define move, drop, copy, and
cleanup state.

## Scope

### In M5b

| Area | Contents |
|---|---|
| Root provenance (B12) | Root/capability identities for `^T`, slices, `any_view`, `dyn`, compiler iterators, default parameters, `inout`, `new` allocation roots, and user `[:]` results |
| Borrow dataflow | Creation-to-last-use loans, copy propagation, compatible access, mutable exclusivity, invalidation, derived places, diagnostics with the complete conflict chain |
| Boundaries | Temporary extension, local escape rejection, direct-call result summaries, generic instances, procedure-value conservatism, static roots, and cross-package metadata |
| Region provenance (B12) | Allocator identity, allocation-root/owner dependencies, copies/moves/clones, escape ordering, conservative aliasing, `free_all`, and verified `@(allocator_reset)` effects |
| M4/M5a handoffs | `any_view`, `dyn`, `inout` and `operator([:])` results, slice escape, move-receiver overlap, and copied/derived allocation-base `free` |
| Backend/metadata | Provenance annotations needed by later MIR, declaration summaries, effect-compatible procedure types, and no runtime ABI changes |

### Deferred after M5

| Deferred | Goes to |
|---|---|
| Runtime `string_view`/`cstring_view` carrier creation and checking | M6; M5b supplies the carrier registration path used when those types become runtime-supported |
| Dynamic-array/map/string invalidating operations and their owner regions | M6, when the types and operations exist |
| Concrete `mem.Arena`/`mem.Scratch` construction and the exact `bad_view`/`bad_owner` examples that use them | M6; equivalent M5 fixtures use fixed arrays, slices, allocator parameters, and `new` roots |
| Debug generation counters (`LOKE_DEBUG`) | Optional implementation aid, not a language guarantee |
| Stored-borrow, foreign-retention, unsafe, and cross-thread checking | Explicit v1 trust boundaries |
| MIR lowering and runtime type/provider tables | M6 |

## Decisions

| Area | Choice | Why |
|---|---|---|
| One provenance event stream | Factor `cfg.odin`'s source-order/control-flow walk from its lifecycle actions, then extend the shared block topology with ordered provenance events for root/carrier definition, borrow creation, copy, overwrite, projected access, call/result substitution, invalidation, and region reset. Build a provenance graph for every relevant concrete body, including bodies with no managed local or M5a allocation-root marker. Add `borrow.odin` with separate root and region lattices over that event stream; each transfer function states which component it updates. | M5a's current graph can be absent for an all-trivial body and records only lifecycle events for tracked owners. Root and region checking need the same control-flow edges but a broader event vocabulary. Keeping one event stream preserves source evaluation order while keeping the two failure classes distinct. |
| CFG purity | Give the shared walker explicit lifecycle and provenance modes. The existing M5a body-checking mode alone may classify copies, emit copy-cost or lifecycle diagnostics, contribute lifecycle members, allocate cleanup slots, or write clone/liveness annotations to the typed AST. Both post-checking provenance modes are read-only apart from their temporary graph and retained summary result. | `build_flow_graph` currently performs semantic work while walking declarations, assignments, returns, and calls. Replaying those actions during two provenance rebuilds would duplicate diagnostics and mutate already-settled annotations. |
| Analysis scheduling | Leave M5a lifecycle analysis at the end of body checking. After every package body and promoted generic instance is checked, rebuild a read-only disposable provenance CFG once to collect symbolic result-summary equations, solve those equations to a fixed point, then rebuild one body at a time in the same read-only mode for root and region diagnostics. | The current M5a CFG is deliberately freed after each body, and source-order checking means a forward or recursive callee may not yet have a summary. Two cheap, side-effect-free post-checking walks avoid retaining all CFGs while ensuring diagnostics see settled summaries. |
| Root identity and overlap | A root is a lexical variable/temporary, static object, materialized constant, hidden slice-literal array, or fresh allocation. A place retains the containing root plus a normalized projection path. Different roots do not overlap. Within one root, a path overlaps itself and its prefixes; distinct struct fields and provably distinct constant fixed-array indices/ranges do not overlap; union fields, dynamic indices/ranges, opaque dereferences, and user-defined projections are conservative wildcards. Whole-root/header invalidation overlaps every descendant. Reslicing composes ranges before comparison, and a known pointer carries its candidate root/path set. | The one rule is about overlapping storage, not merely variable names. An explicit relation permits useful disjoint borrows without guessing through dynamic or user-defined addressing. |
| Capabilities | Immutable carriers permit compatible reads; mutable carriers permit access through that loan and exclude competing access. `inout self` invalidates prior element/view borrows of the receiver, while an interior mutable borrow does not grant header invalidation. | This is the one rule applied to the concrete operations already checked by M5a. |
| Last use | Compute loan liveness backwards from every use of a reaching carrier value. Copies share the source loan; overwriting a carrier kills that reaching value; joins retain every loan that can reach a later use. A never-used borrow ends immediately. | Lexical scope would reject valid code after a view's last use, while variable-only liveness would falsely keep an overwritten loan alive or miss a live copy. |
| Invalidation | Move, drop, `free`, full assignment, `exchange`, and a user operation with `inout self` invalidate the affected root/value. M6 container operations register with the same invalidation hook. | Logical element/header change is sufficient; the rule must not depend only on physical reallocation. |
| Allocation-base `free` | Replace M5a's direct-result restriction with propagated fresh-allocation identity. Pointer copies and projections retain root provenance, but `free` accepts only the base pointer, consumes its operand binding, ends that allocation root, and invalidates every locally tracked alias. Unknown or `&`-created pointers remain ineligible. | This repays M5a's safe narrowing without treating `^T` as an owning type. |
| Temporaries | An ordinary temporary root lasts through its complete expression; `foreach` iterable, `switch` subject, and `if`/`for`/`switch` initial-statement temporaries extend through the complete statement. Hidden slice-literal arrays follow their surrounding lexical scope. | These are the source-visible lifetime boundaries, independent of backend stack slots. |
| Result summaries | Store two independent components per result: possible borrowed parameters/static/fresh/unknown root and possible allocator parameters/moved owner/static/unknown region. First collect finite symbolic equations, including direct-callee result edges, then solve declaration and concrete-instance SCCs to a fixed point. Attach the settled summaries to package semantic metadata, never runtime data. | Direct callers need substitution without lifetime syntax or ABI changes. A fixed point makes forward and mutually recursive calls independent of source order, and generic instances can have different summaries. |
| Procedure values | A returned carrier derives conservatively from every borrowed actual argument; with none it is unknown. Owning results retain every moved-owner and allocator-argument region candidate. Fresh-allocation provenance is erased, so an indirect result cannot be passed to checked `free`. | Ordinary procedure values carry only code pointers and type-level effects, not declaration provenance metadata. |
| Conservatism | Unknown root provenance cannot escape into a context requiring a proven lifetime; regions not proven distinct are possibly identical and block reset. Diagnostics explain the unknown edge or possible alias. | False positives remain local and actionable; accepting an unknown escape/reset would be an undiagnosed lifetime error. |
| Region sources in M5b | Exercise regions through allocator parameters, `new`/`new_clone` allocation roots, destination allocator policy, and result summaries. Reject storing a parameter-backed owner in longer-lived static storage and resetting that parameter while dependants would survive the reset. Storing a bare pointer or other carrier remains the explicit stored-borrow trust boundary. Exact local-arena examples wait for the provider that creates a local region in M6. | This makes region checking testable with M5 types while preserving both the settled M6 provider boundary and v1's deliberately local borrow analysis. |
| `@(allocator_reset)` | Verify transitively that every reset of a pre-existing region is covered by a reset-marked parameter. Include the effect in procedure-type compatibility and retain it through indirect calls; locally created provider regions will be exempt when M6 adds them. | Reset is the one invalidation effect intentionally propagated through arbitrary wrappers. |
| `free_all` activation | Remove M5a's gate only after region analysis runs. Treat reset as the operation that ends every allocation root in the selected region and invalidates all locally tracked aliases. Reject it when a possibly same-region owner remains live for later use or cleanup, or when a pointer/view has a later use; do not reject merely because an allocation still exists or its last carrier use precedes the reset. Lower it as a provider reset operation, not a sequence of guessed CRT `free` calls. The M5 default CRT provider has no reset support and its reset entry traps; M6's arena providers replace that entry with real reset behavior. | `free_all` must be able to perform the release promised by its name. The proof is that no dependant survives the reset, not that every allocation was already freed. “Not supported by this allocator” remains distinct from “unsafe while this region has surviving dependants.” |
| `any_view` and `dyn` | Preserve the source root through conversions, copies, assertions, switches, composed-interface conversions, and witness dispatch. Their existing position restrictions remain; M5b adds last-use and invalidation behavior. | Runtime representations already exist from M4b, but representation stability alone is not lifetime safety. |
| User slicing | A selected `operator([:])` result is a borrow of the receiver unless its result type is owning. `[]mut T` requires an `inout` receiver and carries exclusive capability; an immutable receiver may produce only `[]T`. | M4a deliberately postponed this result relationship because it required provenance. |
| Explicit non-goals | Stored built-in borrows, foreign retention, `rawptr`/`[^]T`, unknown `^T`, `core:unsafe`, hidden aliases in user pointer records, and cross-thread transfer remain unchecked. Each boundary keeps a positive fixture. | Version 1 deliberately limits analysis to locally visible provenance. Tests must keep the trust boundary stable in both directions. |
| Diagnostics | Reserve `L0511`–`L0550`: root/compatibility `L0511`–`L0525`, escape/results `L0526`–`L0535`, regions/reset `L0536`–`L0545`, and erased/user views `L0546`–`L0550`. | The range follows M5a and keeps failure families separable. |
| Corpora | Reuse all M5a corpora. Cross-package summary/effect cases use `tests/pkg` and `tests/pkg_err`; accepted trust boundaries use ordinary run or semantic-success fixtures. | No new harness is needed, and cross-package fixtures make summary attachment and consumption observable. |

## Steps

Each step ends with a built compiler and a green existing corpus. New behavior
gets an exact success or diagnostic fixture in the same step that enables it.

### 1. Root provenance and the one rule

- Refactor `cfg.odin`'s structural walk from its mode-specific actions without
  changing block topology. Preserve one lifecycle mode with M5a's current events,
  copy classification/reporting, annotation writes, and solver behavior. Add
  read-only summary and diagnostic provenance modes that never report copy or
  lifecycle diagnostics, contribute lifecycle members, allocate cleanup slots,
  or mutate typed-AST annotations.
- In provenance modes, build a graph for every body containing a relevant
  expression even when M5a tracks no managed local, and emit ordered references
  to the typed AST for carrier definitions, copies, overwrites, projected
  reads/writes, calls, invalidations, and resets.
- Add root IDs, projection paths, immutable/mutable capabilities, and loan IDs
  for `^T`, `[]T`, `[]mut T`, `any_view`, `dyn`, compiler-known iterators,
  default parameter access, and `inout` paths.
- Build backwards last-use sets and forward access/invalidation transfer
  functions over the expanded CFG. Track reaching carrier values rather than
  variable names alone: a copy shares its source loan, a full overwrite kills
  the old reaching value, and a join retains every candidate loan with a
  reachable later use.
- Enforce compatible root access and mutable exclusivity for reads, writes,
  borrows, calls, and projected places. Treat every `inout self` user operation
  as invalidating prior element/view loans of its receiver.
- Normalize and compare projections explicitly. A whole-root access overlaps
  every path below it; resolved fields and constant fixed-array indices/ranges
  may prove disjoint; union fields, dynamic indices/ranges, opaque dereferences,
  and user-defined addressing overlap conservatively. Compose nested field,
  index, dereference, slice, and reslice paths before applying the relation.
- Handle move, drop, full assignment, `exchange`, and `free` as invalidations
  tied to the old value, preserving M5a's lifecycle result for the replacement.
- Replace M5a's allocation-base narrowing with copied-root propagation: require
  a base pointer at `free`, consume it, and reject every later local alias use.
- Emit one primary conflict diagnostic plus notes for the root, borrow creation,
  invalidating/conflicting operation, and later use keeping the loan live.

**Exit:** access after a mutable or immutable borrow follows the one rule; a
borrow ends at its true last use across branches; copies extend the same loan;
overwriting a carrier ends only the value that was overwritten; an all-trivial
procedure still receives provenance diagnostics; disjoint known fields or
indices can be borrowed independently while unknown/overlapping projections
conflict; rebuilding provenance graphs neither duplicates existing diagnostics
nor changes M5a's settled annotations;
moving, dropping, assigning, exchanging, or freeing a root with a later-used
borrow is rejected; and `free` accepts a copied base pointer while invalidating
all of its locally known aliases.

### 2. Temporaries and procedure boundaries

- Give ordinary and statement-extended temporaries their specified root
  lifetime, including hidden slice-literal arrays and compiler-created
  `any_view` storage.
- Reject returning a borrow of a local variable, ordinary temporary, default
  parameter binding, or hidden local array. Permit static/materialized roots and
  allocation roots with their proper summary category.
- After all package bodies and promoted generic instances are checked, rebuild
  each disposable CFG in read-only summary mode to collect per-result root and
  region equations for every named declaration and concrete instance. A direct
  result call contributes a symbolic edge to the selected callee result rather
  than becoming unknown.
- Solve the finite summary lattice by call-graph SCC to a fixed point, attach
  the settled summaries to declaration/instance package metadata, and only then
  run caller provenance diagnostics with actual roots/regions substituted at
  direct calls. Rebuild and dispose one read-only diagnostic CFG at a time.
- Conservatively derive an indirect returned carrier from every borrowed
  argument and erase fresh-allocation status; apply the independent conservative
  rule to owning results and allocator/move arguments.
- Diagnose unknown provenance only when an operation requires a proof, naming
  the call/result edge where knowledge was lost.

**Exit:** a fixed-array or slice-literal view cannot escape its procedure; a
materialized-constant slice can; a direct `first_half`-style result borrows the
actual argument through another package and generic instance; a procedure-value
result is conservative; forward and mutually recursive declarations produce the
same summaries regardless of source order; and a fresh pointer returned
indirectly cannot be passed to checked `free`.

### 3. Allocator-region provenance and reset effects

- Track allocator identity through copies and joins, treating identities as
  possibly equal unless proven distinct. Attach region dependencies to fresh
  allocation roots, allocating clones, moved owners, and results constructed
  with allocator parameters.
- Preserve a dependency through moves; select the destination allocator for an
  allocating clone; preserve a shared allocation's dependency for logical
  clones; and keep declaration `via` policy separate while a destination is
  dead.
- Reject a parameter-region-backed owner stored in file, `static`, or
  `thread_local` storage or another demonstrably longer-lived owning context.
  Record safe returned dependencies in the result summary rather than rejecting
  a result whose caller can keep the region alive. Do not add an escape check for
  a bare `^T`, slice, iterator, or erased view stored in global/aggregate storage;
  that remains the documented v1 trust boundary.
- Validate `@(allocator_reset)` on parameters and propagate it transitively
  through direct wrappers. Include it in procedure-type compatibility and
  enforce it at indirect calls.
- Activate `free_all` as a region invalidation. Reject it and any reset-capable
  call while a possibly same-region owner remains live for a later use or scope
  cleanup, or while a locally tracked pointer/view has a later use. On an
  accepted reset, end every allocation root in that region and invalidate all
  locally tracked aliases. An unfreed allocation whose carriers have no later
  use is released by the reset and is not itself a blocker.
- Lower the accepted operation through the allocator reset entry. Test the M5
  default provider's unsupported-operation trap separately from the compile-time
  live-dependant diagnostic; M6 providers supply a successful reset path.
- Use M5-available compile fixtures with allocator parameters and explicit
  allocation roots. Include both `new` followed by last carrier use and an
  accepted reset without prior `free`, and the corresponding rejection when an
  alias is used after reset. Leave the exact `mem.Arena` plus dynamic-array
  examples as an M6 activation fixture, not an M5b exit dependency.

**Exit:** a parameter-backed owner cannot escape into static storage while a
bare stored carrier remains an explicit trust boundary; direct and indirect
allocator resets preserve their effect; `free_all` releases an unfreed `new`
root after its carriers' last use and rejects any alias used afterward; a live
owner requiring later cleanup and possibly identical allocators block reset;
and root and region failures receive distinct codes and explanations.

### 4. Erased views, user slicing, and M4 handoffs

- Propagate root/capability through `any_view` conversions, copies, assertions,
  type switches, and local temporaries; within the procedure-local analysis,
  reject invalidation or a checked return escape of the subject while the erased
  view has a later use.
- Propagate through `dyn` formation, copies, composed-interface conversion, and
  slot receiver paths; keep nil behavior and witness coherence unchanged.
- Attach caller roots to `inout` results and enforce exclusivity for every later
  use. Make a move receiver participate in the same invalidation check before
  M5a kills its source.
- Classify `operator([:])` results as owning or borrowed, validate mutable result
  capability against receiver mode, and attach the receiver root to borrowed
  results.
- Register dormant carrier/invalidation hooks for runtime
  `string_view`/`cstring_view` and M6 containers without making their currently
  gated runtime types usable.

**Exit:** within locally tracked uses and checked procedure returns, `any_view`,
`dyn`, `inout` results, and borrowed `[:]` results cannot outlive or conflict
with their subject. Storing a permitted carrier in global, aggregate, callback,
or container state deliberately leaves that guarantee at the documented v1
trust boundary. A mutable user slice requires an exclusive receiver; an owning
`[:]` result has no false borrow edge; and M4b's representations and witness
dispatch remain unchanged.

### 5. Gate, diagnostic, backend, and documentation audit

- Audit every carrier, root-creating operation, invalidation, owner-creating
  operation, and reset-capable call against both lattices. A transfer function
  must state explicitly when only one lattice applies.
- Audit each diagnostic for an exact expected code, substring, line, and column,
  including distinct root-escape and region-escape codes.
- Run existing copy-cost and lifecycle-error fixtures through the completed
  compiler and assert that provenance rebuilds neither duplicate their
  diagnostics nor change their AST-driven lowering. Add projection fixtures for
  disjoint struct fields and constant fixed-array indices/ranges, plus conflicts
  for the same field, union fields, dynamic indices/ranges, opaque dereferences,
  and user-defined projections.
- Add cross-package fixtures proving that result summaries and reset effects are
  attached and consumed; add forward-declaration and mutually recursive
  fixtures proving summary fixed-point behavior; add LLVM goldens only where
  provenance changes emitted cleanup/control flow rather than ABI.
- Add one positive fixture per bullet under design.md's “What is not checked”
  section, including stored views, foreign retention, raw/unknown pointers,
  unsafe provenance loss, cross-thread transfer, and aliases hidden in user
  records.
- Retire the M4b and M5a borrow/provenance gates. Keep exactly one M6 fixture for
  runtime string views/containers and one provider-activation fixture for the
  exact arena-backed `bad_view`/`bad_owner` examples.
- Update `USAGE`, `readme.md`, and the M5b implementation record in
  `compiler-plan.md` only when implementation lands.

**Exit:** the full verification below passes from a clean build, all M4/M5a
handoffs are closed, and every deliberate unchecked boundary still compiles.

## Verification

```powershell
odin test src -define:ODIN_TEST_TRACK_MEMORY=false
odin build src -out:lokec.exe
odin test tests -define:ODIN_TEST_TRACK_MEMORY=false
./lokec.exe examples/hello.loke -o hello.exe
./hello.exe
```

Milestone spot checks:

- A diagnostic names the root, creation, conflict/invalidation, and later use
  that keeps a borrow live.
- Immutable and mutable loans permit only compatible access and end at the last
  use of every copy across control-flow joins.
- A procedure containing only trivial roots and borrow carriers still receives
  borrow diagnostics, and overwriting a carrier ends its old reaching loan.
- Provenance CFG rebuilds are semantically read-only: existing copy-cost and
  lifecycle diagnostics still appear once, and M5a cleanup lowering is stable.
- Known-disjoint fields and constant indices/ranges can carry independent loans;
  equal, prefix-related, union, dynamic, opaque, and user-defined projections
  overlap conservatively.
- A local fixed-array or slice-literal view cannot be returned; a materialized
  constant view can.
- Direct and generic result summaries preserve actual argument roots across a
  package; forward and mutually recursive summaries are source-order
  independent; procedure-value calls use the conservative rule.
- A copied allocation-base pointer can be freed once, and every tracked alias is
  invalid afterward; `&` and indirect fresh results cannot be passed to `free`.
- A parameter-backed owner cannot escape into static storage, while storing a
  bare carrier remains an explicit trust boundary.
- `free_all` may release an unfreed allocation after its carriers' last use,
  invalidates all aliases, and is rejected when an alias survives the reset or
  an owner still needs later use or cleanup.
- Root escape and region escape fail with distinct diagnostics.
- `any_view`, `dyn`, `inout`, and borrowed `[:]` results preserve their subject
  provenance for local uses and checked returns without changing runtime
  representation; a stored carrier still crosses the explicit trust boundary.
- Each explicit “not checked” case compiles, keeping the v1 trust boundary
  executable and documented.

## Deliberate shortcuts

### Earlier shortcuts M5b repays

| Earlier shortcut | M5b replacement |
|---|---|
| No borrow, escape, or exclusivity checks for `any_view`, `dyn`, `inout` results, or `[:]` results | Root/capability provenance through each existing carrier and result path |
| M5a slices have value/capability behavior but no enforced provenance | Last-use, overlap, invalidation, and local-escape checks |
| M5a `free` accepts only a direct allocation result or explicit-move chain | Full allocation-root propagation, base validation, consumption, and alias invalidation |
| M5a gates `free_all` and `@(allocator_reset)` | Region provenance, liveness checks, transitive verified effects, and procedure-type compatibility |

### Shortcuts retained after M5b

| Shortcut | Replaced when |
|---|---|
| Runtime `string_view`/`cstring_view` and managed-container carriers are unavailable, though analysis hooks exist | M6, when their runtime types and operations land |
| No source-level local allocator provider; region tests use allocator parameters and explicit allocation roots | M6 `mem.Arena`/`mem.Scratch`; the exact arena examples activate then |
| Stored borrows, foreign retention, raw/unknown pointers, unsafe provenance loss, hidden user-record aliases, and cross-thread transfer are unchecked | Deliberate v1 boundary |
| No `LOKE_DEBUG` generation counters | Optional post-M6 debugging aid |
| Annotated AST lowers directly to LLVM; no MIR | M6 (B13) |
| Allocator-selected failure policy, panic unwinding, full TLS runtime, dynamic containers, and type-info runtime are absent | M6 (B14) |
| Private aggregate/receiver ABI and natural layout only | M7 (B15) |

## Assumptions

- M5a is complete: its control-flow topology, lifecycle states, copy/drop
  annotations, slice-producing syntax, allocation-root marker, and cleanup
  registration order are stable inputs to M5b. M5b deliberately broadens the
  graph's event vocabulary and builds provenance graphs for bodies M5a does not
  need to track.
- Provenance analysis begins only after package body checking and generic
  promotion settle. Its summary-equation and diagnostic walks rebuild disposable
  CFGs in read-only provenance modes, so no M5a analysis allocation must survive
  `analyze_ownership` and no M5a diagnostic or annotation is replayed.
- Root and region provenance are compile-time declaration/body metadata and do
  not alter source types, value layout, calling ABI, witness keys, or `typeid`.
- Unknown provenance is a checked limitation, not evidence that a value is safe;
  operations at the explicit trust boundaries remain the way to leave the
  analysis.
- M6 providers register their local/static region roots and container
  invalidations through the hooks fixed here rather than reopening the analysis
  contract.
- Windows x64 remains the only code-generation target.

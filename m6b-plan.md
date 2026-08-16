# M6b implementation plan — managed containers and allocator regions

## Context

[M6a](m6a-plan.md) is implemented. It fixes the versioned C runtime, the
pointer-sized allocator handle, failure and panic strategies, standard package
roots, text/runtime metadata, formatting, variadic ABI, and the M5b registration
hooks. **M6b** is the managed-container half: dynamic arrays and maps, allocator
binding with `via`, iteration and invalidation, real local arena/scratch regions,
and the remaining conversion and compile-time-evaluation debts that require
those types.

This is the detailed implementation plan. It replaces the earlier bounded
outline now that the implemented M6a ABI is available. One forward-looking M6a
assumption is corrected here: an allocator record cannot be embedded directly in
a movable `Arena` or `Scratch` value, because every `Allocator` is a pointer to
that record. Region owners instead own address-stable control storage containing
the unchanged M6a record.

The normative sections are [Managed values and storage](design.md#managed-values-and-storage),
[Dynamic arrays](design.md#dynamic-arrays), [Maps](design.md#maps),
[Iteration protocol](design.md#iteration-protocol),
[Allocators](design.md#allocators), and
[Allocator regions and region provenance](design.md#allocator-regions-and-region-provenance).

## Scope

### In M6b

| Area | Contents |
|---|---|
| Dynamic arrays | `[dynamic]T` representation, literals and zero value, length/capacity, all mutating/fallible operations, lifecycle, `make`, `manual`, slicing, iteration, and formatting |
| Maps | `map[K]V` representation and coherence, lookup/comma-ok/`in`, insertion places, `find`, operations, lifecycle, `make`, iteration, and formatting |
| Allocator policy | Eager lexical `via`, lazy default binding, copy/move/clone destination rules, failure policy, static-duration restrictions, constant zero values, and stored provider handles |
| Borrows and invalidation | Value/by-reference iteration, opaque iterators, element/slot loans, and registration of every relocating or slot-invalidating operation in the same step that enables it |
| Regions | Address-stable `mem.Arena` and `mem.Scratch` controls, fixed-buffer and provider-backed roots, owner transfer, successful reset, lifecycle invalidation, nested regions, and the exact M5b escape fixtures |
| Remaining handoffs | `string.to_runes`, `unsafe.raw_data([dynamic]E)`, dynamic/map formatting, and bounded compile-time managed owners |

### Deferred after M6

MIR/no-LLVM code generation; `String_Builder`, `C_String`, `Small_Array`,
`shared(T)`/`weak(T)`, sorting; foreign ABI completion; optional debug generation
counters; and the standing v1 trust boundaries.

## Decisions

| Area | Choice | Why |
|---|---|---|
| Dynamic-array value ABI | `[dynamic]T` is four words: `{data, len, cap, allocator}`. The all-zero value is empty, allocator-unbound, constant, and immediately usable. A bound empty value has nil data and a non-nil allocator. `len` and `cap` are signed `int` in source but are validated before conversion to allocation sizes. | The header gives O(1) length/capacity, retains the provider needed by drop, and preserves the required constant zero representation. |
| Map value ABI | `map[K]V` is four words: `{table, len, cap, allocator}`. The allocation behind `table` contains the slot/control metadata, tombstone count, and seed. The all-zero value is empty and allocator-unbound. `cap` is the number of entries that can be inserted before growth, not the raw slot count. | Keeping the seed and implementation metadata out of the public value leaves a compact constant-zero header and permits the table algorithm to evolve without changing type layout. |
| Container runtime boundary | The compiler emits one private operation table per concrete element or key/value combination. It contains size/alignment plus lifecycle, hash, equality, and formatter thunks as applicable. Versioned C helpers own raw storage/table mechanics; generated thunks call the already-settled Loke lifecycle and coherence selections. No existing allocator record or public runtime layout is reinterpreted. | Textual LLVM should not duplicate a hash-table implementation, while C cannot know concrete Loke lifecycle operations without compiler-generated callbacks. |
| Checked sizes | Every `len + count`, growth calculation, alignment round-up, slot-count calculation, and `count * size_of(T)` uses checked unsigned arithmetic after rejecting negative source counts. `len > cap`, an invalid insert/removal index, and a negative requested count are ordinary program faults. A representable request that cannot be allocated follows the allocator policy; its `try_` form returns `Allocator_Error`. No wrapped size reaches a provider. | Source integer overflow is defined to wrap, but container bookkeeping must not turn that rule into an undersized allocation and memory corruption. |
| Growth/table policy | Dynamic arrays grow geometrically with a small minimum allocation; the exact sequence is fixed in runtime unit tests but is not a language guarantee. Maps use open addressing with explicit empty/occupied/tombstone controls, power-of-two slot counts, and a maximum load threshold fixed in runtime tests. `reserve(n)` promises only `cap >= n`; `shrink` may keep implementation-required slack. | Observable guarantees stay at length/capacity and operation semantics while deterministic tests still pin the implementation against accidental regressions. |
| Atomic mutation | Arguments and source spreads are evaluated first. Potentially failing element/key/value clones and replacement storage are completed in temporary state, with an initialized-prefix cleanup record, before the destination header, length, or occupied control byte is published. In-place spare-capacity paths publish length/slot state last. On failure, temporaries are dropped in reverse order and the original container is bit-for-bit unchanged. | This extends M5a's failure-safe assignment rule to every container operation and makes panic cleanup replay only fully registered work. |
| Dynamic-array operations | Implement `append` (including multiple values and `..slice`), `insert`, `pop`, `remove`, `remove_unordered`, `clear`, `resize`, `reserve`, `shrink`, indexing, indexed assignment, slicing, `len`, `cap`, and the allocating `try_` counterparts. `pop` retains optional-ok behavior; removal/index faults remain bounds panics even in an allocation-fallible form. Self-aliasing inputs are copied to temporaries before a structural mutation. | The operation set matches design.md while making aliasing and fallible behavior executable rather than relying on evaluation accident. |
| Map algorithm and coherence | The concrete map operation table freezes the built-in or inherent owning-type `==` and `hash(value, seed)` selections. User extensions never enter it. Runtime maps use an opaque per-table seed; iteration order remains unspecified. The evaluator may use a fixed internal seed, but every executed operation that exposes map order, including iteration and map formatting, is rejected at compile time. | Coherence survives package boundaries, and compile-time execution cannot leak a table-order choice into reproducible build output. |
| Map places and operations | Implement literals, single/comma-ok lookup, `in`, inserting assignment places through field/index chains and `inout`, non-inserting `find -> (^V, bool)`, `remove`, `clear`, `reserve`, `shrink`, `len`, `cap`, `make`, and allocating `try_` forms. A missing rvalue lookup produces a completed zero value. An inserting place creates a zero `V` only after table growth succeeds. `find` never inserts. | This preserves the intentional difference between lookup and a place while preventing a failed insertion from leaking a partial slot. |
| Allocator binding | A container header records its allocator as soon as a written lexical `via` declaration is evaluated, or when an unbound value first needs an allocator. A container literal initializing or replacing a known destination constructs directly with that destination's selected allocator rather than allocating a default-backed temporary first. `make(..., allocator)` and explicit `clone`/`try_clone` results are bound to the selected allocator even when empty. A live destination keeps its bound allocator; a dead or unbound destination resolves its declaration policy; move transfers the source header and allocator unchanged. Drop writes the inert all-zero representation, while the declaration policy remains compiler metadata for later revival. | The policy belongs to the destination declaration, while the handle belongs to the current live value. Keeping those facts separate is necessary after drop and move. |
| `via` applicability | `via` is allowed only on lexical allocator-binding owners whose canonical clone accepts a destination allocator, including dynamic arrays, maps, and qualifying user-defined managed aggregates. It is rejected on trivial/borrowed values, move-only values without cloning, immutable `string`, `shared`, and every file-scope, `static`, or `thread_local` declaration. Static-duration managed containers begin in the constant allocator-unbound zero state and may later receive a moved value from explicit runtime initialization. | A runtime allocator expression is not a constant initializer, and types that retain shared storage or cannot clone have no destination allocation policy for `via` to select. |
| Element lifecycle | Container insertion and cloning use the container's selected allocator for required independent element/key/value clones. Relocation within the same allocation is a compiler-known move of initialized representations and does not call user clone/drop hooks. Removal drops or transfers exactly the removed values, and container drop destroys live contents exactly once before releasing raw storage. | Deep value semantics must not turn reallocation into user-visible extra copies or double destruction. |
| Iteration | Compiler-contributed `Element`/`Iterator`, `iter`, and opaque iterator types make dynamic arrays and maps satisfy the existing runtime protocol. Arrays yield value/index; maps retain the key/value two-name exception. Built-in by-reference iteration yields array elements or map values only; map keys remain immutable. | This reuses M4b's public iteration abstraction while keeping v1 reference iteration a checked built-in place facility. |
| Container invalidation | The same step that enables an operation emits its M5b event. Array structural operations conservatively invalidate element/view/iterator loans when they may relocate, shift, remove, truncate, clear, shrink, drop, move, or replace storage. Map insertion, removal, clear, shrink, drop, move, and replacement invalidate slot pointers and iterators; `find` produces a slot loan. A value loop owns an immutable whole-container loan and a reference loop an exclusive one for the complete loop. | No intermediate milestone exposes a usable container operation without the borrow rule that makes it safe. Runtime no-op outcomes do not weaken a statically invalidating operation. |
| Stable region control | `Arena` and `Scratch` are move-only owners of a pointer to an address-stable control block containing one unchanged `loke_rt_allocator_v1`, provider state, and canonical region token. Provider-backed construction allocates the control block from its parent allocator. Fixed-buffer `Arena([]mut u8)` places the aligned control block at the front of the supplied buffer and allocates from the remainder. The owner value never contains a record whose address copied handles observe. | Moving a region owner can transfer one stable control pointer without invalidating allocator handles or leaving self-pointers aimed at a dead stack slot. Fixed-buffer construction still performs no heap allocation. |
| Region-owner provenance | `allocator()` returns a handle carrying the local provider-region identity and a lifetime dependency on the region owner. Copies preserve both. Moving or returning the owner transfers the same local-region root to the destination; direct-call result summaries distinguish that fresh transferred root from a returned handle. Returning only the allocator handle is rejected. A fixed-buffer owner additionally borrows its buffer root, and a provider-backed child region depends on its parent provider. Neither owner nor handle may escape those roots. | Region identity alone prevents unsafe reset, but the record and fixed buffer also need an owner lifetime. Nested providers require the parent to outlive the child, while a provider-backed owner must still be constructible through an ordinary wrapper procedure. |
| Region lifecycle effects | `free_all(owner.allocator())` resets allocations but keeps the control and handles live for reuse. Explicit `drop`, live full replacement, and eventual scope cleanup of a region owner end the region and are checked as region invalidations. `exchange` and move transfer an owner and do not reset it; the returned/transferred owner carries the same root. Any ending operation is rejected while a container, allocation root, view, iterator, slot pointer, child provider, or later-used allocator handle survives. | Reset safety must apply to every operation that destroys a provider, not only to the spelling `free_all`. |
| Arena/Scratch behavior | `Arena(buffer)` is fixed-buffer; `Arena(parent := mem.default_allocator())` is growable and provider-backed. `Scratch(parent := mem.default_allocator())` is a provider-backed temporary region with the same reset/lifetime contract and a reuse-oriented page policy. Construction through an ordinary form follows the parent failure policy; explicitly fallible constructors return zero plus `Allocator_Error`. Reset drops no Loke values itself—the compile-time dependant check ensures owners have already been dropped or transferred away. | The language-visible safety contract is shared; allocation/page policy remains a `core:mem` implementation detail. |
| Compile-time managed owners | The evaluator represents dynamic arrays and maps in compiler-owned storage but executes the same zero/bind/copy/move/drop and operation contracts. It charges live and peak bytes, element initialization, recursion, and operation steps to the existing sandbox limits; cleanup releases live accounting on every executed exit. Allocation-limit failure reports the compile-time stack deterministically. Runtime allocator expressions and local runtime providers are not executed as compile-time handles. | Managed temporary evaluation must be reproducible and bounded without pretending a host allocator pointer is a Loke constant. |
| Remaining conversions/formatting | `string.to_runes` builds a managed rune array with failure-safe prefix cleanup. `unsafe.raw_data([dynamic]E)` exposes its current data pointer and intentionally crosses the existing unsafe provenance boundary. Array/map formatters recursively use M6a's coherent formatter table; runtime map order is unspecified and compile-time map formatting is rejected. | These are the exact M6a handoffs whose operand/result types now exist. |
| Diagnostics | Reserve L0576–L0600: type/layout/`via` L0576–L0580, arrays L0581–L0585, maps/coherence L0586–L0590, iteration/container provenance L0591–L0595, and regions/evaluator/gates L0596–L0600. Existing M5a/M5b lifecycle, root, and region codes remain in use when the failure is one those analyses already define. | The range stays bounded while preserving stable diagnostic families across old and new carriers. |

### Operation signatures

The following are conceptual signatures for the compiler-contributed built-ins;
method syntax remains the source spelling for container operations. `try_` forms
recover only allocation/cloning failure. Invalid indices, negative sizes, and
invalid length/capacity relationships remain ordinary program faults.

```odin
// Dynamic arrays.
len(value: [dynamic]T) -> int
cap(value: [dynamic]T) -> int
append(self: inout [dynamic]T, values: ..T)
try_append(self: inout [dynamic]T, values: ..T) -> Allocator_Error
insert(self: inout [dynamic]T, index: int, value: T)
try_insert(self: inout [dynamic]T, index: int, value: T) -> Allocator_Error
pop(self: inout [dynamic]T) -> (T, bool)
remove(self: inout [dynamic]T, index: int) -> T
remove_unordered(self: inout [dynamic]T, index: int) -> T
clear(self: inout [dynamic]T)
resize(self: inout [dynamic]T, new_len: int)
try_resize(self: inout [dynamic]T, new_len: int) -> Allocator_Error
reserve(self: inout [dynamic]T, min_capacity: int)
try_reserve(self: inout [dynamic]T, min_capacity: int) -> Allocator_Error
shrink(self: inout [dynamic]T)
shrink(self: inout [dynamic]T, min_capacity: int)
try_shrink(self: inout [dynamic]T) -> Allocator_Error
try_shrink(self: inout [dynamic]T, min_capacity: int) -> Allocator_Error
make([dynamic]T, len: int = 0, cap: int = len,
     allocator: Allocator = mem.default_allocator())
    -> ([dynamic]T, Allocator_Error)

// Maps. Index lookup and inserting assignment places remain syntax rather than
// calls in this table.
len(value: map[K]V) -> int
cap(value: map[K]V) -> int
find(self: inout map[K]V, key: K) -> (^V, bool)
try_insert(self: inout map[K]V, key: K, value: V) -> Allocator_Error
remove(self: inout map[K]V, key: K) -> (V, bool)
clear(self: inout map[K]V)
reserve(self: inout map[K]V, min_capacity: int)
try_reserve(self: inout map[K]V, min_capacity: int) -> Allocator_Error
shrink(self: inout map[K]V)
try_shrink(self: inout map[K]V) -> Allocator_Error
make(map[K]V, reservation: int = 0,
     allocator: Allocator = mem.default_allocator())
    -> (map[K]V, Allocator_Error)

// `core:mem` region owners. The ordinary provider-backed constructors apply
// the parent allocator's failure policy; their `try_` counterparts do not.
mem.Arena(buffer: []mut u8) -> mem.Arena
mem.Arena(parent: Allocator = mem.default_allocator()) -> mem.Arena
mem.try_arena(parent: Allocator = mem.default_allocator())
    -> (mem.Arena, Allocator_Error)
mem.Scratch(parent: Allocator = mem.default_allocator()) -> mem.Scratch
mem.try_scratch(parent: Allocator = mem.default_allocator())
    -> (mem.Scratch, Allocator_Error)
allocator(self: mem.Arena) -> Allocator
allocator(self: mem.Scratch) -> Allocator
```

`m[key] = value` and every inserting subplace use the allocator policy and have
no result in which to report failure; `try_insert` is their recoverable
counterpart. Map `remove` moves the stored value to its result, drops the key,
and returns zero/false when absent. Dynamic-array removals require an in-range
index and move the removed element to the result. `find` borrows a mutable map
because its pointer grants mutation of the stored value even though it never
inserts. A fixed buffer too small to hold an aligned arena control is an ordinary
program fault and is diagnosed before the control is published. Both region
owners disable `try_clone`; `move` transfers their stable control pointer, and
their canonical `drop` ends the region.

## Steps

Each step ends with a built compiler and a green existing corpus. A type or
operation is ungated only in the step that also installs its lifecycle, failure,
root, region, and panic behavior.

### 1. Shared container ABI, lifecycle, and allocator policy

- Add the two frozen four-word layouts to semantic layout, `typeid`, runtime
  metadata, zero materialization, constant/static emission, and the versioned C
  declarations. Add checked size/alignment helpers and failure-injection runtime
  providers used only by tests.
- Generate per-concrete-type container operation tables and lifecycle thunks.
  Connect container `try_clone`, policy-following `clone`, move, drop, cleanup
  registration, panic cleanup, copy-cost diagnostics, and recursive aggregate
  lifecycle.
- Implement declaration-policy metadata for eager lexical `via`, lazy default
  binding, live/dead/conditionally-live assignment, move transfer, exchange, and
  revival. Reject `via` on every inapplicable type and all three static-duration
  forms before evaluating its expression.
- Implement `make` argument validation and bound-empty results. Keep both
  container expression gates in place until their operation steps.

**Exit:** layouts agree in C/Loke/LLVM; zero file/static/TLS containers are
constant and usable; forbidden static-duration `via` has an exact diagnostic;
copy/move/drop and failure cleanup work through synthetic internal containers;
and no public container operation is usable without invalidation.

### 2. Dynamic arrays with invalidation

- Enable literals, `make`, indexing, assignment, slicing, length/capacity, and
  every operation listed in the decision table. Implement checked growth,
  initialized-prefix cleanup, self-aliasing append/insert/spread, managed-element
  relocation, and allocator-failure atomicity.
- Contribute the sequence/index members needed by generic code. Register slice,
  element, reallocation, shift, truncation, clear, shrink, move, drop, and full
  replacement events in M5b before removing the dynamic-array gate.
- Add ordinary/policy and `try_` state-machine fixtures for trivial and managed
  elements, including a failing provider and a failing nested `try_clone`.

**Exit:** dynamic arrays run and format no partial public state; every completed
element is dropped exactly once; overflow cannot reach an allocation callback;
and a later-used slice or element blocks every operation that may invalidate it.

### 3. Maps with coherence and slot invalidation

- Implement the table/control block, checked reservation/growth/shrink,
  tombstones, seed handling, lookup, optional-ok, `in`, literals, insertion,
  removal, clear, and `make` for trivial keys/values first, then lifecycle-bearing
  keys and values.
- Freeze hash/equality in each concrete operation table using the existing
  inherent-only `Hashable` lookup. Add cross-package positive cases and reject a
  caller-local extension even when it satisfies an ordinary local interface
  query.
- Implement inserting places for direct assignment, compound assignment,
  field/index chains, and `inout`; implement non-inserting `find` and its slot
  root. Register insertion/removal/clear/shrink/move/drop/replacement events
  before removing the map gate.

**Exit:** missing lookup and insertion-place behavior differ exactly as
specified; failed growth or cloning leaves all entries unchanged; key/value
lifecycles are exact; and no live `find` pointer or iterator can survive a
slot-invalidating operation.

### 4. Iteration, formatting, and dynamic-array handoffs

- Add opaque iterators and compiler-contributed protocol members for arrays and
  maps, including array index values, the map two-name exception, array
  by-reference values, and map value-only by-reference iteration.
- Attach immutable or exclusive whole-container loans for the complete loop and
  prove last-use acceptance around, but never inside, the loop back-edge.
- Add recursive array/map formatters through M6a's formatter table. Enable
  `string.to_runes` and `unsafe.raw_data([dynamic]E)` with their respective
  managed-result and unsafe-boundary behavior.

**Exit:** generic and direct iteration agree; mutations in a live loop loan are
rejected; nested containers format; `to_runes` cleans partial output on failure;
and the dynamic unsafe overload does not accidentally claim checked provenance.

### 5. Stable arena and scratch regions

- Add address-stable fixed-buffer and provider-backed control blocks and publish
  the `core:mem` constructors, fallible constructors, `allocator`, reset, and
  drop behavior. Verify record version/size before dispatch just as for the
  default provider.
- Extend the existing region lattice with distinct local provider tokens and
  owner roots. Transfer a token on owner move; propagate it through copied
  allocator handles, direct-call result summaries, and container construction;
  attach fixed-buffer roots and parent-provider dependencies; retain
  conservative joins only where identities genuinely merge. A wrapper may
  return a provider owner and transfer its fresh root, but may not return only a
  handle to that root.
- Treat `free_all` as reusable reset and every destructive provider lifecycle as
  region end. Use M5a liveness instead of in-scope presence so an explicitly
  dropped manual container permits reset. A later-used allocator handle alone
  does not block reusable reset, because it remains valid for the reset control;
  it does block drop/replacement of the provider. A child provider, backed owner,
  allocation carrier, view, iterator, or slot pointer blocks reset while it
  survives.
- Activate the exact `bad_view` and `bad_owner` examples, fixed-buffer arena
  escape cases, allocator-handle escape cases, nested regions, region-owner move,
  and explicitly-dropped-manual-owner success case.

**Exit:** moving a provider never changes its record address or region identity;
fixed buffers and parents outlive their regions; all provider-ending operations
reject surviving dependants; a successful reset permits later reuse; and the
default system provider's unsupported reset traps at runtime.

### 6. Compile-time evaluator, audit, and documentation

- Enable managed array/map owners only on executed compile-time paths. Add
  deterministic live/peak memory and step accounting, prefix cleanup, allocation
  limit diagnostics, and complete-expression/branch/procedure cleanup.
- Reject compile-time map iteration and every indirect order observation such as
  map formatting. Keep unexecuted branches free of allocation and diagnostics.
- Audit every operation against lifecycle, panic, formatter, root, region,
  checked-size, and static-initialization hooks. Retire the remaining M6b gates
  and prove one diagnostic per previously gated construct.
- Update `design.md`, `readme.md`, and the M6b implementation record in
  `compiler-plan.md` only as implementation lands; document any deviation beside
  the implemented mechanism.

**Exit:** the complete verification below passes from a clean build, no M6b
gate remains, evaluator limits are deterministic, and every earlier handoff has
an executable positive or negative fixture.

## Verification

```powershell
odin test src -define:ODIN_TEST_TRACK_MEMORY=false
odin build src -out:lokec.exe
odin test tests -define:ODIN_TEST_TRACK_MEMORY=false
./lokec.exe examples/hello.loke -o hello.exe
./hello.exe
```

Milestone spot checks:

- Both four-word headers and all-zero values agree across semantic layout,
  emitted LLVM, runtime C, `size_of`, and runtime type information.
- File-scope, `static`, and TLS containers bind the default lazily on first
  allocation; all three reject written `via` and accept a value moved in by an
  explicit runtime initialization procedure.
- Negative counts, `len > cap`, index faults, `len + count`, capacity growth,
  slot-count, alignment, and byte-size overflow cannot make an undersized
  allocation. Ordinary allocation failure follows `.Panic`/`.Trap`; `try_`
  returns an error and preserves the original header and contents.
- Array append/insert/spread, including self-aliasing inputs, and map insert or
  replacement clean every partially cloned managed element exactly once.
- Live destination assignment preserves its allocator; dead/unbound revival
  uses the declaration policy; move and exchange transfer the source allocator;
  explicit clone/make use the selected allocator even for an empty result.
- Map hash/equality is inherent and package-coherent; lookup, comma-ok, `in`,
  insertion chains, `inout`, and `find` preserve their distinct missing-key and
  borrowing behavior.
- Array views/elements and map slots/iterators reject structural invalidation
  until their true last use. Value loops hold immutable loans and reference loops
  exclusive loans across every back-edge.
- Provider-backed and fixed-buffer controls keep one record address across owner
  moves and provider-owner returns. An allocator handle alone cannot escape its
  owner; a fixed-buffer region cannot outlive or conflict with its buffer; and a
  child region cannot outlive or survive reset/drop of its parent.
- `free_all` succeeds for Arena/Scratch, permits later reuse, and accepts an
  explicitly dropped manual owner. Drop, replacement, and scope cleanup of a
  provider reject every surviving dependant, including a later-used allocator
  handle. `free_all(mem.default_allocator())` reaches the unsupported-reset
  runtime trap.
- Runtime map order is unspecified. Compile-time map iteration and formatting
  are rejected, while other compile-time managed operations are deterministic
  and hit stable memory/step-limit diagnostics.
- `string.to_runes`, dynamic `unsafe.raw_data`, and formatting of nested arrays
  and maps cover success, allocation failure, cleanup, and empty values.

## Deliberate shortcuts

### Earlier shortcuts M6b repays

| Earlier shortcut | M6b replacement |
|---|---|
| Dynamic arrays/maps and their invalidations are gated | Complete managed containers wired into M5b in the same step as each operation |
| Default allocator is the only successful provider | Arena and Scratch controls with distinct local regions and successful reset |
| M5b region identity is flow-insensitive and over-blocks dropped manual owners | A local-provider lattice plus lifecycle-aware reset proof |
| One string/unsafe conversion row waits for dynamic arrays | `to_runes` and dynamic `raw_data` |
| Evaluator rejects temporary managed owners | Bounded compiler-owned managed temporaries |
| M6a could not source-test failed resize or unsupported reset | Failure-injection resize preservation and the default-provider reset trap |

### Shortcuts retained after M6b

The post-M6 and v1 trust-boundary list in [m6a-plan.md](m6a-plan.md) remains in
force. In particular, the annotated typed AST still lowers directly to textual
LLVM; MIR waits for a second consumer. Stored borrows, unsafe provenance loss,
foreign retention, hidden user-record aliases, and cross-thread transfer remain
the documented v1 trust boundaries.

## Assumptions

- M6a's runtime allocator ABI and public Loke layouts are frozen inputs. M6b adds
  versioned container helpers and per-type operation tables, not fields to or a
  reinterpretation of `loke_rt_allocator_v1`.
- M5b's CFG event stream, result summaries, and root/region solvers remain the
  one provenance analysis. M6b extends their value domain with local provider
  tokens and registers new carriers, owner transfers, and invalidations.
- Region-owner control storage is address-stable for its entire owned lifetime;
  owner move transfers that lifetime but never copies the control block.
- Windows x64 remains the only code-generation target for v1.

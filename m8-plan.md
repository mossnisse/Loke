# M8 implementation plan — the rest of design.md

## Context

M7 is implemented. Every *language* construct design.md defines compiles, runs,
optimizes, and links in both directions with C. What is left is not a phase of
the pipeline: it is the set of entries in design.md's
[Library types assumed by this specification](design.md#library-types-assumed-by-this-specification)
table that require an implementation, plus the two places where design.md names
a facility without specifying it. The catalogue's illustrative `Trace_Span`
and `Time` handles are recorded below but are not implementation requirements
for this milestone.

That distinction is what shapes this plan. M0–M7 each widened the compiler. M8
is mostly *library* work over facilities that already exist, with compiler and
runtime integration that the library cannot write for itself:

- **atomic intrinsics**, which `Atomic(T)`, `shared(T)`, and `weak(T)` all need;
- **provider selection and startup**, including one selected allocator handle
  reached by both generated code and the C runtime;
- **shared-handle integration**, for nil, allocator policy, and provenance;
- **a contributed `sort` member**, because an `impl` on a foreign subject is an
  extension confined to its own package, so `core:slice` cannot make
  `xs.sort()` resolve in *user* code;
- **`Simd(T, N)`**, which needs a type kind, an operator table, and an ABI —
  and needs a design.md section written first, because design.md currently says
  its contract does not exist.

Two entries also need a *specification* before code: the mechanism by which a
build selects its providers, and the SIMD contract. Both are marked below.

The normative sections are
[Concurrency and the memory model](design.md#concurrency-and-the-memory-model),
[Shared ownership](design.md#shared-ownership),
[Build-selected providers](design.md#build-selected-providers),
[SIMD vectors](design.md#simd-vectors),
[Fixed-capacity arrays](design.md#fixed-capacity-arrays),
[Sorting slices](design.md#sorting-slices),
[Library numeric types](design.md#library-numeric-types),
[Iterating an enumeration](design.md#iterating-an-enumeration), and the
catalogue table itself.

## Inventory

Every catalogue row is accounted for below, together with sorting and SIMD from
the linked sections. Absent entries are in scope unless explicitly excluded.

| Entry | State | Compiler work it needs |
|---|---|---|
| `os.Args`, `fs.File`, `String_Builder`, `C_String`, `meta.*`, `Allocator`, `mem.Arena`/`Scratch`, `Source_Code_Location`, `base:interfaces` | shipped | — |
| **slice sorting** — `slice.sort`, `slice.reverse_sort`, `xs.sort()` | absent | a contributed `Sort` container member; the free form is ordinary Loke |
| **`Small_Array(T, N)`** | absent | none — value generics, operators, and the sequence interfaces all exist |
| **`Bit_Set(Enum)`, `Enum_Array(Enum, T)`** | absent | none — `Enum.values()` and `meta.Enum_Value` exist |
| **`Complex(T)`, `Quaternion(T)`** | absent | none — design.md already writes them as ordinary source |
| **`Little_Endian(T)`, `Big_Endian(T)`** | absent | none — `distinct` plus conversion hooks |
| **`Logger` / `core:log`** | absent | a build-provider selection mechanism, which design.md names but does not specify |
| **`Atomic(T)` / `core:sync`** | absent | atomic intrinsics with constant ordering operands, plus a runtime fallback for widths without native lowering |
| **`shared(T)`, `weak(T)`** | absent | nil-ability, the `via` prohibition, `get()` root provenance, and a construction spelling that is not generic type application |
| **`Simd(T, N)` / `core:simd`** | reserved name, `L0636` | a type kind, lane operators, constant lane indexing, splat conversion, and an ABI — after a design.md section exists |
| `Trace_Span`, `Time` | illustrative catalogue entries; excluded from M8 | none — tracing and time libraries remain outside this milestone |

Other work associated with M8's row in
[compiler-plan.md](compiler-plan.md#c-milestones) includes non-Windows targets, which
[standard-library-plan.md](standard-library-plan.md) Stage 4 is gated on, and
`core:bytes`/`time`/`random`/`testing`, which that plan defers until a caller
asks. That work is not in this plan; see *Deferred beyond M8*.

## Scope

### In M8

| Area | Contents |
|---|---|
| Ordinary library types | `core:slice`, `Small_Array(T, N)`, `Bit_Set`, `Enum_Array`, `Complex`, `Quaternion`, `Little_Endian`, `Big_Endian` |
| Contributed member | `sort` on a dynamic array and on a mutable slice, so the method spelling resolves outside the defining package |
| Providers | Build-time selection, process-lifetime handle storage, executable and foreign-host startup, and `core:log` over the selected logger |
| Atomics | Compiler atomic intrinsics, the ordering enum, the supported-type predicate, runtime fallback helpers, and `core:sync` with `Atomic(T)`, `fence`, and `once` |
| Shared ownership | `shared(T)` and `weak(T)` as library records over the atomic control block, with the four compiler-visible facts design.md gives them |
| SIMD | A design.md contract, then `Simd(T, N)`, lane-wise operators, constant lane indexing, splat, and `core:simd` |

### Deferred beyond M8

Unchanged from [compiler-plan.md](compiler-plan.md#d-out-of-scope-for-v1)'s
list, and none of it blocks the entries above: MIR and the no-LLVM debug
backend; debug builds and debug information; non-Windows targets and
standard-library Stage 4; incremental and parallel compilation; a shared-library
build mode; extension attributes; `core:bytes`/`time`/`random`/`testing`;
tracing libraries and the illustrative `Trace_Span`/`Time` handles; and the
standing v1 trust boundaries.

One of these has a standing inaccuracy worth naming rather than leaving
implicit: `LOKE_DEBUG` is predeclared `false` and there is no `-debug` option,
which M7 chose deliberately so the constant stays truthful. A debug milestone
must introduce the option, the debug information, and the constant together.

## Decisions

| Area | Choice | Why |
|---|---|---|
| Order | The pure-library entries land first, before any compiler change. | They need nothing new, they are the largest share of the remaining surface, and each one is an independent test that M4b's generics, M4a's operators, and M6b's containers actually carry real code. Finding a defect there is cheaper than finding it underneath an atomics implementation. |
| `sort` as a member | `sort` and `reverse_sort` become contributed members on `[dynamic]T` and `[]mut T`, beside `append` and `reserve`, lowering to a generated monomorphic comparison sort per element type. The free `slice.sort(s)` form in `core:slice` forwards to the same member. | design.md writes both spellings and says mutators stay method-only so the receiver borrow cannot hide in free-call syntax. An `impl [dynamic]T` in `core:slice` is an *extension*, visible only inside `core:slice` — so a library-only implementation cannot make design.md's own `s.sort()` example compile in user code. Contributing the member reuses M6b's `inout`-receiver place rule and invalidation edges unchanged. |
| Sort algorithm | One introsort in the C runtime over an element size, a stride, and a generated comparison thunk — the same shape `loke_rt_container_ops_v1` already uses for clone and drop. | The container runtime already owns "what C cannot know arrives as a generated thunk". A second copy of that pattern in generated IR would be more code and slower to compile than one call. |
| Atomic surface | Intrinsics are compiler built-ins in `core:sync`'s package-private space, exactly as `allocate_string` is contributed to `core:strings`: `atomic_load`, `atomic_store`, `atomic_exchange`, `atomic_compare_exchange`, `atomic_add`/`sub`/`and`/`or`/`xor`, and `atomic_fence`. `Atomic(T)` and the public `fence` procedure are ordinary library wrappers over them. | design.md calls `Atomic(T)` a "`core:sync` wrapper over compiler atomic intrinsics", so the split is specified. The private `atomic_fence` and public `fence` have different names because contributed and source declarations share one package scope. |
| Ordering operand | The ordering enum is ordinary `base:runtime` source. Public atomic wrappers, including `fence`, take ordering through `$` parameters, so it remains constant when forwarded to an intrinsic; compare-exchange preserves both success and failure orderings. A relaxed fence, a non-constant order, or any unsupported combination is a compile-time error naming the combination. | A constant at the user's call site does not make an ordinary wrapper parameter constant inside its body. Compile-time parameters preserve the order through the library boundary; the intrinsic validates it before either native or fallback lowering. |
| Atomic types and lowering | `bool`, every integer type including `i128`/`u128`, enums with supported integer backing types, and `^T`/`rawptr`. Use native LLVM atomics for supported widths and versioned runtime helpers for the others; Windows x64 requires a 128-bit fallback. Every operand must be naturally aligned, with packed-place rejection checked before entering a wrapper. | The current Windows link setup does not supply `__atomic_load_16`, which LLVM's default 128-bit atomic lowering requires. Emitting valid IR alone cannot implement the promised type set. design.md permits a lock when the target lacks a lock-free operation. |
| Atomic fallback | Add lock-backed 128-bit operations in `runtime/atomic.c`, using operating-system primitives without allocating or depending on `core:sync`. All operations on a fallback width use that path, including loads and stores; the contract covers ordering and fences together with native-width atomics. | Mixing a locked read-modify-write with an unlocked wide load would lose atomicity. The fallback must be reviewed against the memory model and tested through the real linker, not assumed to exist in the toolchain. |
| Data races | Not checked. The compiler lowers the model; it does not verify it. | design.md's own words: a race is undefined behaviour, and there are no implicit `Send`/`Sync` interfaces. |
| `shared(T)` spelling | `shared` and `weak` are **compiler-known generic library types**, bound through `src/stdlib.odin`'s existing identity binding, the way `Allocator` and `meta.Field` are. `shared(x)` where `x` is a value is a construction call; `shared(T)` where `T` is a type is the type. | Four of design.md's statements about `shared(T)` are language facts, not library facts: its zero value is `nil` and it compares to `nil`; `via` on such a declaration is an error; `handle.get()` returns a `^T` whose root provenance derives from the handle; and the compiler never silently moves it. None of those can be written in library source today. The value/type overload of one name is the same disambiguation `Complex_F64(scale)` already needs, applied to a generic subject. |
| `shared(T)` internals | The control block, the strong and weak counts, the release-decrement, and the acquire fence at the final reference are ordinary Loke source over the step-4 intrinsics and M5a's lifecycle hooks. **They live in `base:runtime`, not `core:sync`** — a deviation from this plan's first draft, recorded here and in design.md's catalogue. | design.md's catalogue says "library records with custom lifecycle hooks and an atomic control block", and by step 5 every one of those facilities exists. `shared`, `weak`, and `try_shared` are *universe* names — design.md writes `x: shared(Node)` with no import in sight — so the package that declares them is loaded by every program. `base:runtime` already exists for exactly that, beside `Option` and `Result`; putting them in `core:sync` would have put an atomics package in every hello world (measured: importing `core:sync` adds ~282 lines of IR). The atomic intrinsics are contributed to `base:runtime` too, following the `allocate_string`-in-two-packages precedent. |
| Provider selection | `-provider allocator=<pkg>:<name>` and `-provider logger=<pkg>:<name>` select nullary factories returning the respective handle types. Generated startup code calls them once and retains their results in process-lifetime slots. Keep `loke_rt_v1_default_allocator` as the system-heap fallback record; add an accessor for the selected allocator handle and route generated and runtime default-allocation paths through it. | The existing allocator symbol is data, not a weak factory function. A factory cannot replace that record's definition. Keeping the returned handle itself preserves its identity, state, and region rather than copying a descriptor to another address. |
| Provider startup | In an executable, convert arguments, attach the initial thread, initialize the allocator slot and then the logger slot, and call `main`. A selected object build exports `loke_rt_v1_program_init`; its host calls it after attaching and before using exports or starting worker threads. Factories and their backing state remain valid until process exit. | Startup is explicit build-selected work, not an import side effect. The same initialization contract must work when the C host owns entry; thread attachment alone cannot invoke the factories. Step 3 specifies bootstrap defaults, lifetime, and repeated-call behavior. |
| `core:log` level | `-log-level=<level>` predeclares a `LOKE_LOG_LEVEL` constant. Library-body `when` guards suppress provider dispatch below that level, but ordinary calls still check and evaluate arguments. Complete removal requires a caller-side `when`, for example `when (LOKE_LOG_LEVEL <= .Debug) { log.debug(expensive()); }`. | Discarding a callee's body does not discard the caller's expressions. Caller-side guards use M3's existing semantics to remove the call and its arguments from checking and emission without special logging call rules. |
| SIMD, first | design.md gets a real *SIMD vectors* section before any code: the element types, the permitted lane counts, the operator set, the comparison result type, lane indexing, splat conversion, the ABI classification, and what `core:simd` supplies. | design.md today says "SIMD operations, conversions, and ABI behavior are not part of the current language contract". There is nothing to implement against. Writing the contract is the first deliverable, not documentation after the fact. |
| SIMD ABI | `Simd(T, N)` lowers to LLVM `<N x T>` and is **not** foreign-ABI-safe in v1: it is rejected in a foreign signature, a foreign global, and an `@(export)`. Its `loke`-convention classification stays LLVM's own, as every other aggregate's does. | M7's decision that only foreign conventions get a compiler-written classification holds here for the same reason. A vector's C ABI is target- and extension-dependent in a way the foreign-ABI-safe subset deliberately excludes; permitting it later is additive. |
| Runtime ABI version | Frozen record layouts and the version tag remain unchanged. Keep the existing fallback allocator symbol and add versioned accessors, startup glue, and atomic helpers. M8-generated code that references these additions requires the M8 runtime. M7 objects remain supported in unselected builds; custom-provider builds must regenerate them. | New entry points do not reorder record fields, but an old runtime does not supply new symbols. Regenerating M7 objects removes their direct fallback references so a custom-provider build still has one default allocator. |
| Diagnostics | Reserve L0651–L0700: sorting and library gates L0651–L0655, providers and logging L0656–L0660, atomics L0661–L0670, shared ownership L0671–L0680, SIMD L0681–L0695. | L0650 is the last code in use. |

## Steps

Each step ends with a built compiler and a green existing corpus, including the
differential optimization matrix. No construct is ungated in a step that does
not also install its checking.

### 1. The library types that need no compiler change

Nothing here touches `src/`. If something in this step cannot be written in
Loke, that is a compiler defect to be found and fixed here rather than designed
around — which is the point of doing it first.

- `core:slice`: `sort`, `reverse_sort`, and the ordinary non-allocating queries
  a sort needs beside it, over `[]mut T` constrained by `interfaces.Ordered`.
  The free form is written first; step 2 gives it the member spelling.
- `Small_Array(T, N)` with indexing, slicing, iteration, `len`/`cap`, the
  panicking and `try_` operations, `Capacity_Error` as an ordinary union with
  `@(failure=...)`, and the three sequence interfaces.
- `Bit_Set(Enum)` and `Enum_Array(Enum, T)` over `Enum.values()`, including
  iteration and formatting.
- `Complex(T)` and `Quaternion(T)` — design.md's own `Complex_F64` source,
  generalized — with operators, the `hook(convert)` scalar conversion, and
  formatting.
- `Little_Endian(T)` and `Big_Endian(T)` as `distinct` storage wrappers with
  explicit load and store conversions, over `LOKE_ENDIAN`.

**Exit:** every one of these compiles, runs, formats, and passes the differential
matrix as ordinary Loke source with no `src/` change; design.md's
`Small_Array`, sorting, and `Complex_F64` examples run verbatim; a read-only
`[]T` passed to `slice.sort` is a compile-time error; and each type satisfies
the catalogue interfaces it claims.

### 2. `sort` as a contributed member

- Add `Sort` and `Reverse_Sort` to `Container_Op` and contribute them to
  `[dynamic]T` and `[]mut T` beside `append`, with the same `inout`-receiver
  place rule. Reject a receiver whose element is not `Ordered`, once at the
  type rather than once per call.
- Generate one comparison thunk per element type, memoised the way
  `loke_rt_container_ops_v1`'s element thunks already are, and add the introsort
  to `runtime/container.c` over size, stride, and that thunk.
- Point `core:slice`'s free procedures at the member so there is one
  implementation.
- Confirm the provenance edges: a sort is an invalidating access to the whole
  container, exactly as `append` is, so every outstanding view of it ends.

**Exit:** design.md's `s.sort()` on a dynamic array compiles in a package that
is not `core:slice`; `slice.sort(s)` and `s.sort()` produce identical results;
a non-`Ordered` element reports once at the container; sorting under a live
borrow is rejected with the existing invalidation diagnostic; and the sort is
stable-input-order-independent and correct on empty, one-element, all-equal, and
reversed inputs.

### 3. Build-selected providers and `core:log`

- Specify the selection and startup contract in design.md's *Build-selected
  providers*, *Executable startup ABI*, and *Build modes* before implementation.
  Include the compiled logging level and the caller-side guard needed for
  complete call removal.
- Add `-provider allocator=…` and `-provider logger=…` to the driver. Resolve
  each package as a build dependency even if source does not import it, check
  the factory's signature against the slot, and diagnose a second selection,
  an unresolvable name, and a signature mismatch separately. Imports never
  select a provider.
- Retain the system-heap record and add the selected-handle accessor. Initially
  it returns the fallback; after allocator initialization it returns the exact
  handle returned by the factory. Update every default-binding path in generated
  code and the C runtime, including lifecycle defaults, text creation, container
  lazy binding, and arena parent selection. Already-bound owners keep their
  original handle. An unselected build preserves M7's behavior, not byte-identical
  IR: calls to the new accessor are intentional.
- Generate `loke_rt_v1_program_init` for a selected configuration. On the attached
  startup thread, call the allocator factory first, validate its non-nil handle
  and allocator ABI, publish it, then call and retain the logger factory's
  handle. Omitted slots keep their fallbacks. The allocator factory's own default
  allocations use the system heap; the logger factory uses the published
  allocator. Logging before the logger is published uses the standard fallback.
- Require factories to return handles backed by process-lifetime state, never
  by a factory local, TLS value, or resettable temporary region. Retained state
  receives no automatic shutdown. Initialization runs before workers exist;
  repeated calls after completion are no-ops, recursive initialization fails,
  and concurrent initialization is outside the host contract. A null allocator
  or invalid logger handle terminates startup before application code runs.
  This startup mechanism does not depend on step 4's `once`.
- Call the initializer from generated executable entry after argument conversion
  and thread attachment, before `main`. For an object build, emit no automatic
  call: document the host's explicit call after attachment and before any
  application export or worker thread. The final link permits one selected
  configuration; duplicate initializer definitions fail the link. An unselected
  object keeps the existing host startup contract and fallback providers.
- Add `-log-level` and the `LOKE_LOG_LEVEL` predeclared constant, allocating its
  enum type lazily exactly as M7's `LOKE_*` constants are, for the same
  `Type_Id`-numbering reason.
- Write `core:log`: `Logger` as an ordinary service handle, the package-level
  procedures with body guards on the compiled level, and the standard logger
  over `core:io`. Document caller-side `when` guards for arguments that must not
  be checked or evaluated. An unguarded call below the level still checks and
  evaluates its arguments, even though it does not dispatch to the provider.

**Exit:** an unselected build preserves fallback behavior; the selected allocator
handle is used by `mem.default_allocator()`, generated lifecycle defaults, text,
containers, and arena parents after initialization; bootstrap owners keep the
fallback to which they bound. Factories run once in the specified order before
application code in both executable and C-hosted object fixtures, their state
remains valid through TLS cleanup, and invalid startup results fail before the
application runs. Two selections for one slot are one diagnostic, and imports
cannot change either provider. A discarded caller-side log guard removes checking
and evaluation of its call and arguments; an unguarded disabled call still
checks/evaluates arguments but never invokes the selected logger.

### 4. Atomic intrinsics and `core:sync`

- Contribute the intrinsics to `core:sync` package-privately, naming the fence
  intrinsic `atomic_fence` so it cannot collide with the public source wrapper
  `fence`. Require constant ordering operands and apply the supported-type and
  operation predicates before lowering. Use byte-sized storage for atomic
  booleans, with conversions to and from Loke `bool`.
- Define the target lowering table before ungating any type. On Windows x64,
  native widths use `load atomic`, `store atomic`, `atomicrmw`, and `cmpxchg`
  with the requested LLVM ordering; `atomic_fence` lowers to LLVM `fence`.
  All supported 128-bit operations, including enum-backed operations, call
  versioned helpers in `runtime/atomic.c` instead of depending on unavailable
  `__atomic_*_16` toolchain symbols.
- Implement the lock-backed helpers over operating-system primitives with no
  allocation or `core:sync` dependency. Define success/failure compare-exchange
  behavior, atomicity, release/acquire publication, and sequentially consistent
  ordering across fallback operations, native operations, and fences. All
  operations on a given fallback width must use the same locking protocol.
  Document the barriers needed by that implementation; exact native instruction
  spelling is not the contract for the fallback.
- Reject, each with its own diagnostic: an unsupported operand type, an
  unsupported operation for that type, an ordering the operation does not
  permit, a relaxed `fence`, a non-constant ordering, and an operand whose
  effective place alignment is below its natural alignment.
- Write the ordering enum in `base:runtime`, then `core:sync`'s `Atomic(T)`,
  public `fence` over private `atomic_fence`, and `once` — which
  [design.md's storage rules](design.md#build-selected-providers) already name
  as the sanctioned way to do runtime initialization. Ordering arguments are
  `$` parameters throughout the wrappers, including both compare-exchange
  orderings, so forwarding does not turn them into runtime values.
- Confirm the compile-time boundary: an atomic operation on an executed
  compile-time path is rejected, the way a foreign call already is.

**Exit:** every supported type/operation/ordering triple compiles, links, and runs
at every optimization level. Native paths emit the requested LLVM ordering;
fallback paths call supplied runtime helpers, including all `i128`/`u128` and
128-bit enum cases, with no unresolved `__atomic_*_16` dependency. Every
unsupported combination is one diagnostic naming it; an atomic on a packed
field is rejected; and an external package can call public `sync.fence` while
private `atomic_fence` remains inaccessible. A `once` initializes exactly once
under contention. Native and fallback paths pass atomicity and publication
fixtures, including mixed-width sequentially consistent operations and fences.
The differential matrix is a regression gate, alongside a review of the fallback
against the memory model; passing it alone is not a proof of that model.

### 5. `shared(T)` and `weak(T)`

- Bind `shared` and `weak` as compiler-known generic library types through
  `src/stdlib.odin`, so the universe and `core:sync` name the same identities.
- Add the four compiler-visible facts: `nil` as their zero value and a valid
  comparison operand; `via` on such a declaration rejected with its own
  diagnostic; `handle.get()` deriving its `^T` root provenance from the handle,
  so M5b rejects a borrow outliving it; and no silent move at last use.
  Disambiguate `shared(x)` construction from `shared(T)` instantiation by
  whether the operand resolves to a type.
- Write the library half in `core:sync`: the control block with strong and weak
  counts, `shared(value)` and `shared(move(value))`, `try_shared`, the
  allocator parameter and its storage in the control block, clone as a strong
  increment, drop as a release decrement with an acquire fence and a single
  payload drop at the final reference, and `weak(T).upgrade` returning
  `Option(shared(T))`.

**Exit:** design.md's shared-ownership paragraph runs as written — sharing,
moving, upgrading, and cycle-leaking; a borrow from `get()` cannot outlive its
handle; `via` on a `shared` declaration is one diagnostic; the payload's `drop`
runs exactly once under concurrent handle traffic; and a `weak` handle keeps the
control block but not the payload alive.

### 6. `Simd(T, N)`

- **Write the design.md section first.** Element types, permitted lane counts,
  the lane-wise operator set and its result types, whether a whole-vector
  comparison reduces or yields a lane mask, constant lane indexing, scalar
  splat, the ABI position recorded above, and the `core:simd` surface. This is
  the deliverable that gates the rest of the step.
- Add the type kind — the public `Type_Kind` member is already reserved, so this
  moves no runtime ABI version — with construction, layout, constant folding,
  and zero values.
- Add the operator table, constant lane indexing, splat conversion, and
  reflection and formatting for the new kind. Retire `L0636`.
- Reject `Simd` in a foreign signature, a foreign global, and an `@(export)`
  through M7's existing ABI-safety predicate, so the rejection names the member
  path like every other unsafe type.
- Write `core:simd` over it: shuffles, reductions, and the lane predicates the
  design.md section commits to.

**Exit:** the design.md section exists and every claim in it has a fixture; a
`Simd` program produces the same results at every optimization level; a
`Simd` in a foreign or exported signature is rejected by the existing predicate;
`L0636` is gone and its fixture is repointed; and reflection, formatting, and
`-check-layout` all handle the new kind.

### 7. The audit

The same shape M6b and M7 each ended with, and for the same reason: the
milestone's own gates are the ones most likely to be left behind.

- Prove no diagnostic still names a milestone that has arrived. Every
  "specified but not implemented in version 1" message must be either retired
  or, where something genuinely remains deferred, rewritten to name the real
  limit rather than a milestone number.
- Walk design.md's catalogue table and confirm each row's *Status* column
  matches the tree, amending the column where M8 changed it. Keep `Trace_Span`
  and `Time` explicitly illustrative and excluded from this milestone; do not
  relabel them as implemented.
- Walk [standard-library-plan.md](standard-library-plan.md)'s "still open" list
  and re-file each entry against what M8 landed.
- Confirm the v1 trust-boundary set is unchanged in substance and record any
  entry M8's atomics or shared ownership added to it — cross-thread transfer
  is the one that grows.
- Update [compiler-plan.md](compiler-plan.md)'s M8 record and readme.md's
  current-milestone paragraph.

**Exit:** no diagnostic references an unarrived milestone; every in-scope
catalogue entry is implemented, and every other row has an explicit deferral or
illustrative exclusion. The trust-boundary set is stated once and accurately,
and the whole corpus is green at every optimization level.

## Testing

Per step, extend the existing corpora and C-host object-link test — no separate
harness.

- `tests/run` for every library type, at every optimization level through
  `LOKE_TEST_FLAGS`. Atomic coverage includes executable tests for every
  supported width and operation, especially `i128`, `u128`, and 128-bit enums;
  successfully emitting IR is not a substitute for linking and running them.
- Logging fixtures cover both forms: a discarded caller-side `when` containing
  an otherwise-invalid call, and an unguarded disabled call whose argument side
  effects must run while the provider remains unused. Repeat at all optimization
  levels; add an error fixture proving that an invalid unguarded argument is
  still checked.
- Provider fixtures count factory calls and allocation routes, covering explicit
  defaults, lifecycle defaults, text, container lazy binding, arena parents,
  bootstrap allocation, and state lifetime through TLS cleanup. Extend the
  existing `tests/obj` C-host link test with a selected configuration and the
  explicit initializer call; retain the unselected-host regression case.
- `tests/err` for each new diagnostic, one fixture per way of being wrong: a
  read-only slice sorted, a non-`Ordered` element, a duplicate provider
  selection, each unsupported atomic combination, a relaxed public fence, a
  non-constant ordering, an unaligned atomic, `via` on a `shared` declaration,
  a borrow outliving its handle, and every SIMD rejection.
- `tests/pkg`/`tests/pkg_err` for external access to public `sync.fence` and
  rejection of the package-private `atomic_fence` name; importing `core:sync`
  must not produce a contributed/source redeclaration error.
- `tests/trap` for invalid provider results and recursive provider initialization.
- `tests/ll` for native atomic instructions and orderings, fallback helper calls,
  and `<N x T>` lowering. Pair fallback IR checks with executable tests against
  the bundled runtime and the supported Windows linker configuration.
- `tests/layout` for `Simd` sizes and alignments under `-check-layout`.
- One concurrency fixture per step-4 and step-5 claim, run under contention.
  Include wide fallback atomicity and mixed native/fallback ordering with fences.
  These are the only tests in the plan that are not deterministic by
  construction, so each asserts an invariant (a count, a single drop, a
  once-only initialization) rather than an interleaving.

## What M8 completing means

Every in-scope catalogue entry is implemented, and no diagnostic names a feature
delivered by M8 as absent. Every catalogue row is accounted for; `Trace_Span`
and `Time` remain illustrative handles excluded from this milestone, not
unimplemented completion requirements. What remains is the explicitly deferred
work: a second backend and its MIR, debug builds and debug information,
non-Windows targets and standard-library Stage 4, tracing and the later utility
packages, incremental and parallel compilation, and the standing trust
boundaries — none of which changes the pipeline shape.

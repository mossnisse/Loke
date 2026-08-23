# M5a implementation plan — visibility, slices, and lifecycle

## Context

`compiler-plan.md` splits M5 at the same kind of dependency seam used for M4.
**M5a** establishes the runtime shapes and liveness facts that do not require a
general provenance analysis: uniform field visibility, slices and constant
materialization, lifecycle hooks, ownership transfer, deep copy, drop
insertion, and the allocator semantic types. **M5b** then walks the same CFG to
propagate root and allocator-region provenance and enforce borrow compatibility,
escape, and reset rules.

What M5a builds on:

- M4b records `sym.public`, `sym.pkg`, and the declaration lookup package. Its
  reflection path already filters fields by the package/public rule, while
  ordinary selection and construction retain the documented M4a exception.
- M4a's inherent-member tables can hold fixed lifecycle hooks, and M4b's
  interface checker can expose the real `Cloneable` catalogue entry once
  `Allocator`, `Allocator_Error`, and `try_clone` exist.
- M2's checker numbers every `defer`, and its LLVM emitter owns a cleanup stack
  used by return, `break`, and `continue`. Implicit drops join that registration
  order rather than creating a second cleanup mechanism.
- M4b clones each generic declaration instance before checking it. The
  per-procedure CFG and lifecycle annotations therefore belong to one concrete
  body instance and never share mutable state between specializations.

Slices land here even though their full provenance checking lands in M5b. They
have no allocator or cleanup obligation, materialization needs a read-only slice
result, and they give M5b a real built-in carrier to analyze. Dynamic arrays,
maps, runtime `string`, general runtime `string_view`/`cstring_view`, allocator
providers, and the seed runtime remain M6.

The normative sections for this half are
[Managed values and storage](design.md#managed-values-and-storage),
[Assignment statements](design.md#assignment-statements),
[Exchange](design.md#exchange), [Materialization](design.md#materialization),
[Slices](design.md#slices),
[Lifecycle hooks and resource types](design.md#lifecycle-hooks-and-resource-types),
[Allocators](design.md#allocators),
[Allocation failure](design.md#allocation-failure),
[Copy-cost diagnostics](design.md#copy-cost-diagnostics), and the
[`@(private)`](design.md#private)/[`@(public)`](design.md#public) visibility
rules.

## Scope

### In M5a

| Area | Contents |
|---|---|
| Uniform field visibility (B6) | One package/public predicate for ordinary field reads, writes, `offset_of`, named and positional aggregate construction, and reflection |
| Slices (B7/B8) | `[]T`/`[]mut T`, literals and hidden backing arrays, slicing and reslicing fixed arrays and slices, bounds, indexing, nil, weakening, `len`, `foreach`, and compiler-contributed sequence/iteration members |
| Materialization (B11) | One deterministic read-only global per constant used by runtime indexing or slicing, constant folding for constant indices, and address/capability rejection |
| Lifecycle hooks (B11) | Fixed `try_clone` and `drop`, generated `clone`, `try_clone :: ---`, recursive struct/fixed-array operations, partial-clone cleanup, inert-zero obligations, and lifecycle-dependent interface satisfaction |
| Ownership (B11) | Per-instance CFG, definitely-live/dead/conditional states, `move`, `drop`, `exchange`, initialization/replacement, deep copy, parameter/result ownership, temporaries, drop flags, and cleanup insertion |
| Storage and allocators | `manual`/`static`/`thread_local`, declaration `via` policy, compiler-owned `Allocator`/`Allocator_Error`, a single default CRT provider, and minimally safe `new`/`new_clone`/`free` |
| Diagnostics/backend | Copy-cost warnings, slice/materialization and lifecycle lowering, cleanup flags, default-provider `malloc`/`free`, and auditable LLVM goldens |

### Deferred to M5b

| Deferred | Why it waits |
|---|---|
| General borrow last-use, overlap, invalidation, and local-escape checking for slices, `^T`, `any_view`, `dyn`, iterators, `inout` results, and `operator([:])` | These require root provenance over M5a's completed CFG and liveness states |
| Copied or derived allocation-base pointers passed to `free` | M5a safely accepts only the direct `new`/`new_clone` result binding or a chain of explicit moves; M5b propagates the allocation root across pointer copies and derived views and invalidates all aliases |
| Usable `free_all` and `@(allocator_reset)` | A reset cannot be admitted until region provenance proves that no live allocation root, owner, or borrow depends on the region |
| Owner region escape and result-provenance summaries | These are the region half of B12, not lifecycle liveness |

### Deferred after M5

| Deferred | Goes to |
|---|---|
| `[dynamic]T`, `map`, runtime `string`, `shared(T)`, `make`, and their library operations | M6, with the seed runtime |
| `mem.Arena`, `mem.Scratch`, allocator provider selection, and general `core:mem` | M6 |
| Allocator-selected `.Panic`/`.Trap` dispatch and real panic unwinding | M6; M5a uses the fixed failure fallback recorded below and emits unwind cleanup metadata |
| Deterministic teardown for runtime-created threads and foreign attach/detach | M6; M5a emits normal main-thread TLS teardown only |
| MIR lowering and the nameable implicit `base:`/`core:` roots | M6 |
| Receiver/aggregate ABI completion and foreign layout | M7 |

## Decisions

| Area | Choice | Why |
|---|---|---|
| Visibility predicate | Generalize the existing `member_is_visible` predicate in `impl.odin` and make reflection call it; do not create a second reflection-specific policy. The lookup package, not merely the package currently being compiled, is the observer. | Methods already use the exact `sym.pkg == lookup_package(k) || sym.public` rule. One predicate prevents reflection, generic definition-site lookup, selection, and construction from drifting. |
| Positional construction | A cross-package positional literal is rejected if any position it supplies is not visible; omitted inaccessible fields do not become a back door through inferred zero filling. | Visibility applies to constructing a field, not only spelling its name. Named and positional literals must agree. |
| Slice representation | Both slice capabilities use `{ptr data, int len}`. Mutability is semantic only; `[]mut T` weakens to `[]T`, never the reverse. Slice literals own a compiler-generated fixed-array root in the surrounding scope. | This is the design representation and gives M5b one root for every slice regardless of capability. |
| Slice boundary | M5a implements all value, layout, bounds, and capability behavior, but records borrow provenance only as a local annotation for M5b. Until M5b, invalidating a sliced root or returning a local-root slice remains a deliberate, tested compatibility gap. | Shipping partial, undocumented lifetime checks would make the seam unpredictable. M5b owns the one rule as one analysis. |
| Materialization identity | Key one immutable global by the resolved constant symbol plus concrete generic instance. Runtime indexing and slicing share it; a constant index still folds and requests no storage. | Constants inside different specializations may have different values, while all uses of one concrete constant must share storage. |
| Analysis placement | Add a disposable per-procedure CFG after a concrete body is checked. Blocks reference typed-AST nodes and carry control-flow edges; lifecycle writes obligations back to those nodes. It is rebuilt per body instance and is not MIR. | A1 calls for a lightweight analysis view. Backends still receive annotated AST until M6. |
| Lifecycle classification | A user record is managed when it has a custom `drop`, custom `try_clone`, disabled `try_clone`, or a recursively managed field. Fixed arrays inherit their element lifecycle. An allocation root from `new` is manual and is not an automatically dropped owning pointer. | The pointer returned by `new` has release responsibility but no `drop` hook. Keeping allocation roots distinct from lexical owners avoids accidental automatic `free`. |
| Drop/defer ordering | Give every implicit drop the next `defer` registration slot at the declaration's completed initialization. All exits replay one reverse registration order. Return values are evaluated and transferred before cleanup; ignored owning temporaries are registered at their full-expression boundary. Reusing M2's stack means widening its cleanup entry to hold a drop action as well as a `defer` statement, and driving flag emission from liveness instead of from one flag per syntactic `defer`. | This directly implements the specified observable ordering without parallel cleanup stacks. The entry and flag changes are the price of that reuse and are cheaper than a second stack. |
| Conditional liveness | Track definitely live, definitely dead, and conditionally live. A hidden flag is emitted only when cleanup or replacement must distinguish runtime paths; it is neither source layout nor ABI. | Liveness is semantic, while the best lowering can duplicate cleanups or keep a condition in a register. |
| Parameter and result ownership | A managed ordinary `value: T` parameter is a non-owning immutable borrow; `inout` is exclusive and `move` transfers ownership. Returning a borrowed managed parameter clones, while returning a managed local, named result, temporary, or move parameter transfers it. Move arguments and receivers mark their caller source dead. | Copy-cost diagnostics and exactly-once drop behavior depend on distinguishing a borrowed parameter from an owned local before M5b adds overlap checking. |
| Allocator representation | `Allocator` is a compiler-owned nominal runtime handle whose M5a value denotes the single default CRT provider; per-expression region identity is semantic metadata, not part of the type or ABI. `Allocator_Error` is a compiler-owned nil status, so `p := new(T) or_return` propagates allocation failure into any final result the error is assignable to, and `or_else` supplies a value instead of one; handling failure where it happens is still the explicit `err != nil` test. `via` remains declaration policy separate from the allocator carried by a live owner. | A semantic type cannot itself carry per-value provenance. A minimal real handle permits fixed signatures and calls while M6 can widen the provider implementation without changing source types. |
| Minimal allocation-root fact | `new`/`new_clone` annotate their direct pointer result as a fresh allocation base. M5a permits `free` only on a definitely-live binding carrying that exact fact through explicit moves, consumes it, and rejects `&` pointers, pointer copies, interior pointers, and unknown pointers. The rule lands in two steps: step 3 checks the operand's form, step 4 adds the liveness and move-chain half once the CFG exists. M5b replaces this narrowing with full root propagation and alias invalidation. | This makes M5a's executable `malloc`/`free` path safe without pretending that the general borrow checker already exists. Splitting it by step keeps each step's exit checkable with what that step built. |
| Reset boundary | Register and type-check the `free_all` signature in M5a, but issue one named M5b gate before lowering a call. | CRT `free` cannot implement a region reset, and admitting reset before region liveness is checked would be unsound. |
| Failure fallback | Explicitly fallible `try_clone`, `new`, and `new_clone` return `Allocator_Error`. If an implicit assignment/copy or generated `clone` sees a non-nil error in M5a, it leaves the destination unchanged and takes a fixed non-unwinding trap. M6 replaces that fallback with allocator-selected `.Panic`/`.Trap` dispatch. | A fallible hook needs defined behavior now. A fixed trap is implementable without claiming the seed runtime's panic policy exists. |
| Panic and TLS | Compute and annotate panic-unwind cleanup sets in M5a, but execute them only when M6 supplies unwinding. Emit normal teardown for main-thread `thread_local` owners; runtime-created-thread ordering remains gated. `os.exit` is always modeled as bypassing cleanup. | This repays B11's analysis obligation while leaving runtime mechanics with B14. |
| Diagnostics | Reserve `L0471`–`L0510`: visibility `L0471`–`L0475`, slices/materialization `L0476`–`L0485`, hooks/allocators `L0486`–`L0495`, and ownership/liveness/copy cost `L0496`–`L0510`. | Live diagnostics currently stop at `L0467`; the unused tail of M4b's reservation remains untouched. |
| Corpora | Reuse `tests/run`, `tests/err`, `tests/ll`, `tests/trap`, `tests/pkg`, and `tests/pkg_err`; exercise the catalogue through `-collection base=base`. | Existing corpora cover output ordering, traps, LLVM shapes, and cross-package visibility without a new harness. |

## Steps

Each step ends with a built compiler and a green existing corpus. New behavior
gets an exact success or diagnostic fixture in the same step that enables it.

### 1. Uniform field visibility

- Generalize `member_is_visible` as the one symbol-visibility predicate and make
  `fields_of` use it, removing `reflection_member_is_visible` and its M5 note.
- Apply it in ordinary struct selection before read or place behavior is chosen,
  in `offset_of`, and in named and positional struct-literal construction.
- Preserve same-package and generic definition-site access through
  `lookup_package`; do not key visibility to the package of an instantiation
  request.
- Add `tests/pkg` and `tests/pkg_err` cases covering reads, writes, addressable
  selection, `offset_of`, named literals, positional literals, public-default
  files with `@(private)`, and reflection from the same two packages.
- Remove the M4a compatibility exception from documentation and keep exact
  declaration-site notes on visibility diagnostics.

**Exit:** same-package code can read, write, take `offset_of`, and construct every
field; an importer can do so only for public fields; named and positional
construction agree; and reflection exposes exactly the fields ordinary access
permits at the same lookup package.

### 2. Slices and constant materialization

- Accept and lay out `[]T` and `[]mut T`; implement nil, nil comparison, explicit
  mutable-to-read-only weakening, rejection of the reverse conversion, indexing,
  element places, `len`, and bounds traps.
- Implement full slice syntax over mutable and immutable fixed arrays, existing
  slices, materialized array constants, and slice literals: omitted endpoints,
  chained reslicing, capability selection, and single evaluation of the base and
  bounds.
- Give `[]T{...}` and `[]mut T{...}` a hidden fixed-array storage root in the
  surrounding lexical scope or static storage at file scope. Preserve the
  written capability rather than inferring it from the destination.
- Implement `foreach` value and index bindings over both slice capabilities and
  `&value` only for `[]mut T`. Contribute `Element`, `Iterator`, `iter`, `next`,
  `Sequence`, and `Mutable_Sequence` behavior through the M4b catalogue path.
- Materialize a constant array on the first non-constant index or slice use into
  one private immutable global per constant instance. Keep constant indexing
  folded, reject writes and `&C`/`&C[i]`, and force every slice of that storage
  to `[]T`.
- Add LLVM goldens for the two-word representation, hidden literal storage,
  bounds checks, one shared materialized global, and no global for a constant
  used only at constant indices.

**Exit:** slice literals, fixed-array slices, and reslices run with correct
bounds and capabilities; generic `Sequence` code accepts a slice;
by-reference iteration mutates only through `[]mut T`; one constant table
materializes once; and no checked operation obtains a mutable pointer to its
read-only storage.

### 3. Lifecycle hooks, allocator types, and the catalogue

- Add compiler-owned `Allocator` and `Allocator_Error` semantic types, their
  nil/error behavior, fixed layout, default CRT handle, and generated default
  argument path without requiring a nameable `core:mem` package.
- Validate the canonical `try_clone` and `drop` signatures in inherent `impl`
  tables, reject lifecycle hooks in `extend`, generate `clone`, and implement
  `try_clone :: ---` as disabling both copy entry points.
- Fix the M5a source spelling of a custom hook: a user writes
  `try_clone :: proc(self, allocator: Allocator) -> (T, Allocator_Error)` with no
  default expression, because `mem.default_allocator()` is not nameable until M6.
  The compiler supplies the default argument at every call site that omits it, so
  `value.clone()` and implicit copies already behave as specified. Reject a
  written default on a lifecycle hook with an exact diagnostic naming M6.
- Generate recursive field-wise `try_clone` for records and fixed arrays,
  cleaning a partially built temporary in reverse field order on failure. Run a
  containing custom `drop` before reverse-declaration-order field drops, and
  require every hook to handle the inert zero value.
- Implement the fixed M5a failure fallback for the two entry points that exist
  before liveness: explicit `try_clone` returns its error, and generated `clone`
  traps only after preserving a live destination. Add trap and
  destination-unchanged fixtures for both. Implicit copy at binding and
  assignment is a step 4 site and carries its fixtures there.
- Register `new`, `new_clone`, `free`, and the gated `free_all`; lower the
  M5a-active calls to CRT `malloc`/`free`, zero-initialize `new`, and destroy a
  partially cloned allocation on `new_clone` failure. Give the default CRT
  provider a reset entry that traps, so "this allocator cannot reset" is already
  distinct from M5b's "reset is unsafe while this region has live dependants".
- Check `free`'s operand syntactically here: accept only a binding whose
  initializer is a direct `new`/`new_clone` result, and reject `&` pointers,
  pointer copies, interior pointers, and unknown pointers. The definitely-live
  requirement and the explicit-move chain need liveness and are added in step 4.
- Append `Cloneable` to `base/interfaces/interfaces.loke` with its real slot and
  test generated, custom, and disabled satisfaction.

**Exit:** a resource record can customize `drop`, customize or disable
`try_clone`, and receive the correct generated `clone`; recursive partial clones
clean up once; `new`/`new_clone` report allocation failure explicitly; `free` on
a direct fresh-result binding runs while every other pointer form and `free_all`
receive precise gates; and the ordinary `Cloneable` source compiles against real
types.

### 4. Ownership CFG, liveness, and cleanup insertion

- Add `cfg.odin` with basic blocks referencing typed statements/expressions,
  normal and abrupt edges for branch, loop, `break`, `continue`, return, trap,
  and fallthrough, plus scope-entry and scope-exit events.
- Add `lifecycle.odin` with definite/conditional liveness, completed
  initialization, explicit `move`/`drop`, full assignment to dead/live/
  conditional destinations, self-assignment, and `exchange`'s evaluate-before-
  replace transaction.
- Implement ownership at calls: ordinary managed parameters borrow without a
  clone; `move` arguments and receivers transfer and kill their source; callees
  drop owned move parameters; borrowed-parameter returns clone; owned locals,
  named results, temporaries, and move parameters transfer to result storage.
- Annotate copy initialization and assignment with recursive `try_clone`, using
  the destination's carried allocator or declaration `via` policy. A failed
  copy leaves a live destination unchanged and follows the M5a trap fallback;
  add the implicit-copy trap and destination-unchanged fixtures here, where the
  sites first exist.
- Complete the allocation-root fact begun in step 3: require `free`'s operand to
  be definitely live, accept a chain of explicit moves from the fresh result,
  consume the fact, and kill the binding. Step 3's syntactic gates keep their
  fixtures; add the dead-binding and moved-from cases.
- Register implicit drops with explicit `defer` slots after completed
  initialization. Cover procedure fallthrough, return, `break`, `continue`,
  ignored owning results and temporaries, and partially initialized aggregates;
  emit conditional state only where the CFG requires it.
- Extend the emitter's one cleanup stack rather than adding a second: widen its
  cleanup entry from a `defer` statement to either that statement or a drop
  action naming a place and its hook, and teach the loop-entry flag reset to
  reach implicit slots as well as syntactic `defer` nodes. Allocate a hidden
  `i1` per slot only where the CFG left the slot conditional, replacing today's
  unconditional flag per syntactic `defer`, so the Conditional-liveness decision
  holds for explicit defers and implicit drops alike.
- Enable `manual`, `static`, and `thread_local`; reject `move`/`drop` on any
  static-duration root, permit replacement and `exchange`, omit process-static
  automatic drops, and emit the documented main-thread TLS teardown narrowing.
- Compute panic-unwind cleanup sets and mark `os.exit` as cleanup-bypassing even
  though M6 is the first milestone that executes an unwind strategy.

**Exit:** every completed resource initialization is dropped exactly once on
fallthrough, return, `break`, and `continue`; explicit defers and implicit drops
run in one reverse order; move parameters and receivers kill their sources; a
conditionally live value cleans up only on its live path; assignment preserves
the destination on clone failure; and static-duration storage is never
observably dead.

### 5. Copy-cost diagnostics

- Add a configurable warning at the four specified copy sites: a trivial
  aggregate copied into `value: T`, binding initialization, assignment, and
  return of a borrowed managed owner by value.
- Distinguish an ABI hidden-pointer transport and a managed ordinary parameter
  borrow from a semantic copy. Report approximate inline bytes and whether a
  lifecycle clone may allocate; do not warn merely because a type is large.
- Point at the operation, name the source where available, and suggest `move`, a
  pointer, or `shared(T)` according to whether transfer or sharing is intended.
- Make return of a borrowed managed value with disabled clone a hard error, and
  keep ordinary size thresholds out of type correctness.

**Exit:** all four real copy sites warn under a low test threshold; borrowed
managed parameter passing and hidden-pointer ABI transport do not; and returning
a borrowed move-only resource is rejected.

### 6. Gate, diagnostic, backend, and documentation audit

- Audit every M5a AST/type kind against evaluator and emitter dispatch;
  reaching the backend without lowering remains an assertion.
- Audit `type_is_supported` and every `L0350` site. Each surviving gate names
  M5b, M6, or M7 and keeps exactly one fixture, including the temporary slice
  lifetime gap, copied allocation-root `free`, and `free_all`.
- Audit every new diagnostic for an exact `tests/err/*.expected` entry with
  code, message substring, line, and column; every trap gets a `tests/trap`
  fixture.
- Add compact LLVM goldens for slice values, read-only materialization,
  lifecycle calls, conditional drop flags, cleanup order, and CRT allocation.
- Add an integrated resource program combining a slice, a materialized table,
  custom lifecycle, move parameter, conditional initialization, `defer`, and
  return cleanup; add unrelated failures to confirm accumulation.
- Update `USAGE` in `src/main.odin`, `readme.md`, and the M5a implementation
  record in `compiler-plan.md` only when implementation lands.

**Exit:** the full verification below passes from a clean build, with M4b still
green and every M5b boundary explicit.

## Verification

```powershell
odin test src -define:ODIN_TEST_TRACK_MEMORY=false
odin build src -out:lokec.exe
odin test tests -define:ODIN_TEST_TRACK_MEMORY=false
./lokec.exe examples/hello.loke -o hello.exe
./hello.exe
```

Milestone spot checks:

- Reflection and ordinary selection/construction expose the same fields from
  both sides of a package boundary.
- `[]mut T` weakens to `[]T`; the reverse conversion and mutation through
  `[]T` fail, while a hidden slice-literal array lives for its surrounding
  scope.
- Runtime indexing and slicing share one immutable materialization, constant
  indexing emits none, and `&C[i]` is rejected.
- A custom resource drops once on fallthrough, return, `break`, and `continue`,
  interleaved with explicit `defer` in reverse registration order.
- A move parameter and move receiver kill their caller source; a borrowed
  parameter return clones, and a disabled clone rejects that return.
- A conditional initialization emits state only where cleanup needs it.
- Direct `new`/`free` and `new_clone` failure work; pointer-copy `free` and
  `free_all` remain named M5b gates.
- All four semantic copy sites warn without warning for managed parameter
  borrowing or an ABI-only hidden pointer.
- `Cloneable` compiles as ordinary catalogue source using the real allocator and
  lifecycle types.

## Deliberate shortcuts

### Earlier shortcuts M5a repays

| Earlier shortcut | M5a replacement |
|---|---|
| Reflection alone filters struct fields | One package/public predicate for reflection, ordinary reads/writes, `offset_of`, and aggregate construction |
| `move` receivers transfer by value without liveness | Caller source death, owned callee binding, result transfer, and exactly-once cleanup |
| No lifecycle hooks, deep copy, or copy-cost diagnostics | Fixed hooks, recursive generation, ownership dataflow, and four copy-site warnings |
| Slices and runtime materialization are gated | Complete slice value/capability behavior and one immutable global per materialized constant instance |
| `Cloneable` is absent from the catalogue | The real source declaration over `Allocator`, `Allocator_Error`, and `try_clone` |

### Shortcuts retained after M5a

| Shortcut | Replaced when |
|---|---|
| Slice, pointer, iterator, `any_view`, `dyn`, `inout`-result, and `[:]` provenance/overlap/escape are not checked | M5b (B12); one fixture per carrier records the temporary boundary |
| `free` accepts only a direct fresh-result binding or explicit-move chain; copied/derived allocation bases are gated | M5b root propagation and alias invalidation |
| `free_all` and `@(allocator_reset)` calls are gated | M5b region analysis |
| A custom `try_clone` is written without the design's `= mem.default_allocator()` default; the compiler supplies it at omitting call sites | M6, when `core:mem` is nameable and the hook is spelled exactly as design.md states |
| General runtime `string_view`/`cstring_view` are absent | M6, with runtime strings and the seed runtime; M5b leaves analysis hooks for them |
| Implicit allocation failure uses a fixed non-unwinding trap rather than allocator-selected policy | M6 (B14) |
| Panic cleanup sets are annotated but no runtime unwinding executes them | M6 (B14) |
| `thread_local` teardown is emitted only for the main thread | M6 runtime thread entry/exit |
| Dynamic arrays, maps, runtime strings, providers, and `mem.Arena`/`mem.Scratch` are absent | M6 (B14) |
| Annotated AST lowers directly to LLVM; no MIR | M6 (B13) |
| Private aggregate/receiver ABI and natural layout only | M7 (B15) |

## Assumptions

- `design.md` and `grammar.md` are normative. Every milestone narrowing above is
  gated, diagnosed, and represented by exactly one fixture.
- M4b is complete, including declaration cloning, lookup-package preservation,
  reflection descriptors, iteration contributions, and erased-view lowering.
- A concrete generic body has its own AST nodes. Lifecycle and CFG annotations
  never mutate a template or another specialization.
- The M5a allocation-root annotation is deliberately narrower than M5b root
  provenance and is deleted or subsumed when `borrow.odin` lands.
- Windows x64 remains the only code-generation target; slice and allocator
  runtime layouts are target-owned and tested against emitted LLVM.

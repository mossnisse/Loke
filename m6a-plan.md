# M6a implementation plan — runtime foundations, strings, and formatting

## Context

[M5a](m5a-plan.md) supplies lifecycle classification, one cleanup registration
order, drop flags, and normal-exit cleanup lowering. [M5b](m5b-plan.md) supplies
root and allocator-region provenance, result summaries, reset effects, and
dormant registration hooks for future borrowed carriers and invalidating
container operations. **M6a** turns those semantic facts into the first real
runtime: a C seed linked beside generated LLVM, stable allocator and panic ABIs,
runtime strings and text views, ordinary and erased variadics, runtime type
information, formatting, source locations, and implicit standard-package roots.

The annotated typed AST remains the v1 lowering input. MIR has no second
consumer while the no-LLVM backend is out of v1 scope, so B13 moves with that
backend rather than requiring a rewrite of the working textual-LLVM emitter in
this milestone.

One M5a plan statement needs an explicit correction before M6a starts. M5a
implemented cleanup registration order, normal-exit emission, liveness, and
conditional drop flags; it did not persist a standalone per-panic cleanup-set
annotation or a cross-frame unwind ABI. M6a consumes the facts that do exist and
adds the runtime-visible frame registration needed for panic cleanup. It does
not assume that a C panic function can unwind LLVM-generated frames by itself.

The normative sections for this half are
[Panics and unwinding](design.md#panics-and-unwinding),
[Build-selected providers](design.md#build-selected-providers),
[Allocators](design.md#allocators), [string type](design.md#string-type),
[string type conversions](design.md#string-type-conversions),
[any_view type](design.md#any_view-type),
[Variadic parameters](design.md#variadic-parameters),
[`type` and `typeid`](design.md#type-and-typeid), and the four compile-time
`#name` forms.

## Scope

### In M6a

| Area | Contents |
|---|---|
| Seed runtime (B14) | Versioned C ABI in `runtime/`, deterministic source discovery, `loke_rt_*` symbols, compiler-relative lookup with `-runtime=<dir>`, and C inputs on the existing clang link command |
| Allocator provider | A pointer-sized `Allocator` handle over state, stable region identity, callbacks, and failure policy; system-heap default provider; `mem.default_allocator()`; `.Panic`/`.Trap` dispatch |
| Standard package roots (B5) | Implicit `base:` and `core:` roots beside `lokec.exe`, explicit `-collection` override, and nameable `base:runtime`, `base:meta`, `base:interfaces`, `core:mem`, `core:fmt`, and `core:unsafe` packages |
| Panic and thread runtime | `-panic=unwind\|abort`; compiler-instrumented logical frame unwind; every specified runtime-panic source; double-panic abort; normal runtime thread attach/detach and managed TLS teardown |
| Runtime text (B7/B8/B14) | `string`, `string_view`, and `cstring_view` representation and lifecycle; literals, concatenation, equality/order where specified, byte/rune operations, slicing, rune iteration with byte offsets, conversions that do not require dynamic arrays, and M5b carrier integration |
| Unsafe surface | `[^]T` indexing, slicing, pointer conversions, and the `core:unsafe` overloads whose operands exist by M6a |
| Variadics | Ordinary `..T`, zero or more explicit arguments, one or more `..slice` spreads, forwarding, procedure-type compatibility, overload ranking, managed-element cleanup, and the special call-scoped `..any_view` form |
| Runtime reflection | Frozen public `runtime.Type_Kind`, `runtime.Member_Info`, `runtime.Type_Info`, a dense table keyed by frozen `typeid`, safe invalid-ID behavior, and `type_info_of` |
| Formatting and output | Coherent formatter selection, compiler-generated formatter thunks, `core:fmt` writers/options plus `print`/`println`/`eprint`/`eprintln`, and retirement of `print_int` |
| Locations | `runtime.Source_Code_Location`, `#location`, and `#caller_location` |

### Deferred to M6b

| Deferred | Why it waits |
|---|---|
| `[dynamic]T`, `map[K]V`, `via`, `make`, and their operations | These are the managed-container half and consume the provider, panic, lifecycle, formatting, and borrow seams fixed here |
| `string.to_runes() -> [dynamic]rune` | This is the one string-conversion-table row whose result type does not exist until M6b |
| `unsafe.raw_data([dynamic]E)` and formatting dynamic arrays/maps | Their operand types land in M6b; all other M6a-safe overloads land here |
| `mem.Arena` and `mem.Scratch` | They instantiate the allocator ABI fixed here and provide the first source-level local region roots |
| Exact arena-backed `free_all` activation fixtures | M5b already checks and lowers reset; the successful local providers needed by those examples arrive in M6b |
| Compile-time temporary managed owners | The evaluator revisits that M3 narrowing when dynamic containers make it necessary in M6b |

### Deferred past v1

MIR and the no-LLVM backend; `String_Builder`, `C_String`, `Small_Array(T, N)`,
`shared(T)`/`weak(T)`, sorting; foreign interoperability and ABI completeness
until M7; and the deliberate trust boundaries in design.md “What is not
checked”.

## Decisions

| Area | Choice | Why |
|---|---|---|
| Runtime language and discovery | Compile every sorted `runtime/*.c` input with the `.ll` file in the existing clang invocation. Resolve the default directory relative to the canonical `lokec.exe` path, not the current directory; `-runtime=<dir>` replaces it. Every exported symbol begins `loke_rt_v1_`. | The compiler already has one object-and-link seam. A versioned ABI prevents silent mismatches, sorting makes commands reproducible, and executable-relative lookup works for installed and test compilers. |
| Allocator handle ABI | Keep `Allocator` pointer-sized. It points to a `loke_rt_allocator_v1` record beginning with ABI version and record size, then an opaque state pointer, a canonical region-identity pointer, an ops-table pointer, and `.Panic`/`.Trap`. The exact callbacks are `alloc(state, size, align) -> ptr`, `resize(state, ptr, old_size, new_size, align) -> ptr`, `free(state, ptr, size, align)`, and `reset(state) -> bool`; false reset support traps, and failed resize leaves the old allocation live. Copying a handle copies the pointer and therefore preserves region identity. | M5a already emitted a pointer-sized handle, while design.md requires runtime state, callbacks, failure policy, and stable region identity. The version/size prefix permits later extension. M6b region owners keep each record in address-stable control storage; the record cannot be embedded directly in a movable owner because every copied handle is its address. |
| Provider selection | M6a installs one static system-heap provider record. `mem.default_allocator()` loads that record. Source imports cannot replace it; a future build option may choose another implementation without changing the handle ABI. | This implements the default fixed provider without inventing scoped replacement and leaves the build-selected seam explicit. |
| Logical panic unwind | Under `-panic=unwind`, every Loke procedure instance that can own a cleanup registers an opaque frame `{previous, cleanup_thunk, context}` in runtime TLS. Registration flags become runtime-visible: they are set only after an action is fully registered and cleared when normal control flow runs it. `loke_rt_v1_panic` marks the thread panicking, walks frames newest first, invokes each generated thunk to replay live actions in reverse registration order, then terminates. A panic while that flag is set aborts. `-panic=abort` registers no frames and terminates immediately. | Loke has no recovery, so the runtime need not resume or physically unwind the native stack. All caller frames and their local storage are still live while the panic routine invokes their thunks. This is deterministic, works with textual LLVM and C, and avoids an unstated Windows C++/SEH ABI dependency. |
| Panic classification | Replace the undifferentiated trap seam with `panic_if` and `abort_if`. Explicit `panic`, failed runtime `assert`, nil dereference/call/dyn, integer division or remainder by zero, bounds failure, failed checked assertion, and `.Panic` allocation failure use the program strategy. `.Trap` allocation failure and panic-during-unwind use immediate abort. `os.exit` bypasses both lexical and panic cleanup. | These are exactly the runtime-panic sources enumerated by design.md; leaving one on `llvm.trap` would silently ignore the selected strategy. |
| Thread runtime | Runtime TLS owns the unwind-frame head, the panicking bit, and the managed-TLS registration list. The compiler-generated process entry attaches the initial thread and normal return detaches it, dropping managed TLS in reverse initialization order. Runtime-created or foreign-attached threads use the same exported attach/detach pair; panic termination never drops TLS. | One entry/exit contract generalizes M5a’s main-thread-only teardown without changing the language cleanup rules. |
| Package-root precedence | Seed `base` and `core` first from directories beside the compiler. Apply explicit `-collection` entries afterward as replacements; duplicate explicit entries remain an error. A missing implicit directory is diagnosed only when an import needs it, and a user override need not coexist with the bundled directory. | Existing explicit catalogue fixtures keep working, projects can replace the bundled tree deliberately, and an unused installation component does not break compilation. |
| Compiler-owned names | Keep `string`, `string_view`, `Allocator`, and `Allocator_Error` as predeclared aliases for v1 because fixed lifecycle signatures and the existing catalogue spell them unqualified. Export the same `Type_Id` values through `core:mem`/`base:runtime`; do not create duplicate nominal types. Remove the source-visible `default_allocator()` scaffold and make generated defaults resolve the real `mem.default_allocator()` symbol. `base:meta` binds the existing opaque descriptor identities through compiler-contributed package members. | This makes the packages real without breaking every lifecycle declaration or changing M5 provenance identity. It also states explicitly which universe compatibility names remain and which scaffold is retired. |
| Runtime string representation | A string is `{ptr data, int byte_len, uintptr owner_flags}`. Static literals point at zero-terminated immutable storage and set the static bit. Runtime storage has a header containing an atomic handle count and the creating `Allocator`; `owner_flags` identifies that header. Assignment retains, drop releases and frees on the last handle, and `clone` always allocates an independent buffer. The empty value is all zero. | The representation keeps literals and zero values constant, preserves the creating allocator, and gives shared immutable assignment the atomic accounting design.md requires. |
| Text validation and C views | Runtime-created `string` values are validated UTF-8. `string_view` is `{ptr,len}` and borrows its root. A literal can form a static `cstring_view`; `to_c_view()` reuses an existing terminator or allocates a call-scoped temporary released at the complete expression. Validation conversions use optional-ok and publish zero on failure. | One carrier path through M5b covers ordinary text views, while the special C temporary rule remains narrower than an assignable local view. |
| Ordinary variadics | Lower `..T` in a Loke procedure ABI as one read-only `[]T`. A sole compatible spread forwards its slice directly. Otherwise the caller concatenates explicit arguments and spread slices into compiler-owned contiguous stack storage: fixed-size when the count is static and a checked dynamic `alloca` when a spread makes it runtime-sized. Managed elements obey ordinary copy/move rules, track an initialized prefix for panic, and are destroyed after the complete call. Variadic shape remains part of procedure-type compatibility, and the existing fixed-over-variadic tie-breaker remains. | The general language feature was deferred to M5/M6 and cannot disappear merely because formatting needs the special erased form. Compiler-owned stack storage handles runtime-length spreads without depending on M6b dynamic arrays; the slice ABI and lifecycle rules remain shared. |
| `..any_view` | Use the same callee slice ABI, but permit the compiler-only temporary `[]any_view` that source code cannot declare. Each element borrows its concrete argument for the complete call; forwarding preserves that boundary. Existing M5b slice/element escape checks consume a synthetic call root and reject storing or returning either the slice or an element. | This keeps `any_view` two words and enforces the specified calling-only exception without making it a general container type. |
| Runtime metadata ABI | `base:runtime` is authoritative for `Type_Kind`, `Member_Info`, `Type_Info`, and `Source_Code_Location`. `Type_Info` exposes `id`, `kind`, static `name`, `size`, `align`, scalar bit/signed facts, `element`, `key`, `count`, and a read-only `members` slice. `Member_Info` carries static name/tag views, declared `typeid`, byte offset, and a two-word raw enum value when applicable. `Source_Code_Location` is `{file, procedure: string_view, line, column: int}`. | The emitter and library need one frozen public layout before either side is written. Static views require no runtime ownership, and the fields cover formatting, aggregate tags, and data editors without exposing compiler-only `type` descriptors. |
| Type-info lookup | Emit one dense entry for every requested runtime type after `freeze_typeids`; recursively request types named by public metadata. `type_info_of(0)` and an out-of-range or forged id return nil. The builtin lowers to a checked table address, not a runtime call. | Existing ids are dense and deterministic, but `typeid` is a runtime scalar and can be forged through unsafe bit operations, so unchecked indexing is not sound. Recursive requests make every referenced entry resolvable. |
| Coherent formatting | Runtime formatting has one formatter per concrete typeid. Built-ins and managed containers receive compiler-contributed thunks; a user customization is eligible only when `format(value, writer, options)` is declared in the value type’s owning package. Caller-local extensions remain callable explicitly but cannot change `fmt.print*`. The compiler emits a private thunk table parallel to type info and contributes one package-private `core:fmt` intrinsic that dispatches an `any_view` through it; the public `Type_Info` layout does not expose code pointers. Record this coherence rule in design.md when implementation lands. | `any_view` contains only a pointer and typeid, so a callee cannot recover a call-site-specific visible overload. Coherence makes the erased call well-defined without changing the two-word carrier or creating a `base:runtime` → `core:fmt` import cycle. |
| Diagnostics | Reserve L0551–L0575: runtime/provider L0551–L0555, panic/failure L0556–L0560, strings/conversions L0561–L0568, multi-pointer/unsafe L0569–L0571, and metadata/variadics/locations/format coherence L0572–L0575. | This follows M5b’s reservation; the highest live code is L0547. |
| Corpora | Reuse the existing corpus directories, but extend `tests/trap` to read sibling `.flags` and optional `.expected` output exactly as `tests/run` already does. | A nonzero exit alone cannot prove unwind cleanup, and the current trap runner neither accepts `-panic=abort` nor checks observable cleanup. Extending it is smaller than adding another harness. |

The public metadata declaration is frozen in this field order when step 2 lands:

```odin
Type_Kind :: enum u8 {
	Invalid, Void, Bool, Signed_Int, Unsigned_Int, Float, Rune,
	Raw_Pointer, Pointer, Multi_Pointer, Array, Slice, Dynamic_Array, Map,
	Struct, Enum, Union, Proc, String, String_View, CString_View,
	Typeid, Any_View, Dyn, Distinct, Simd, Allocator, Allocator_Error,
}

Member_Kind :: enum u8 {Field, Enum_Value, Union_Variant, Parameter, Result}

Member_Info :: struct {
	kind:       Member_Kind,
	name:       string_view,
	tag:        string_view,
	type:       typeid,
	offset:     int,
	value_low:  u64,
	value_high: u64,
}

Type_Info :: struct {
	id:      typeid,
	kind:    Type_Kind,
	name:    string_view,
	size:    int,
	align:   int,
	bits:    int,
	signed:  bool,
	element: typeid,
	key:     typeid,
	count:   int,
	members: []Member_Info,
}

Source_Code_Location :: struct {
	file:      string_view,
	procedure: string_view,
	line:      int,
	column:    int,
}
```

Unused scalar/relation/member fields are zero. Enum values use the two raw
words without narrowing signed or unsigned 128-bit values; `bits` and `signed`
interpret them. Aggregate member tables expose public fields only; procedure
entries retain written parameter/result order, union variants retain declaration
order, names/tags use static storage, and locations are one-based. Adding fields
or enum members requires a runtime ABI version bump.

## Steps

Each step ends with a clean compiler build and all previously passing tests.
Public runtime layouts and symbol signatures receive LLVM-shape tests in the
same step that introduces them.

### 1. Freeze the runtime and allocator ABIs

- Add `runtime/` headers and C sources with `loke_rt_v1_*` symbol names, explicit
  integer widths, compile-time layout assertions, and no dependency on Loke
  package discovery.
- Add `-runtime=<dir>`, canonical executable-relative lookup, deterministic C
  source sorting, and C inputs to the existing clang command. Include the
  resolved directory and missing-file detail in linker diagnostics.
- Replace `CRT_ALLOCATOR_GLOBAL` and `CRT_RESET_THUNK` with the pointer-sized
  allocator record and system-heap provider. Route `new`, `new_clone`, `free`,
  generated lifecycle clones, and `free_all` through its ops table without yet
  changing M5’s explicit error behavior.
- Test copied allocator handles, stable region identity, size/alignment passed to
  callbacks, resize failure preserving the old allocation, and unsupported
  system-provider reset trapping.

**Exit:** generated programs link the versioned C runtime from any current
directory, the M5 allocator surface uses one stable record ABI, and explicit
`-runtime` replacement is deterministic.

### 2. Add implicit roots and freeze the public runtime packages

- Seed `base:`/`core:` with explicit-override precedence. Add package fixtures
  for bundled roots, replacement roots, duplicate explicit entries, and a
  missing bundled root that is never imported.
- Create `base/runtime`, `base/meta`, `core/mem`, `core/fmt`, and `core/unsafe`
  beside the existing `base/interfaces`. Bind compiler-owned aliases to their
  existing `Type_Id` values and update `base/interfaces` only where a real
  package-qualified call replaces scaffolding.
- Declare the exact `Type_Kind`, `Member_Info`, `Type_Info`, allocator aliases,
  and `Source_Code_Location` layouts in `base/runtime`; make source declarations
  the ABI authority and assert compiler layout against them.
- Make `mem.default_allocator()` nameable and migrate explicit uses of the old
  `default_allocator()` scaffold. Retain the documented unqualified allocator
  type aliases and add an audit proving no second identity was created.

**Exit:** standard imports work without `-collection`, explicit entries replace
the defaults, and compiler-owned and package-qualified spellings compare as the
same types.

### 3. Implement panic strategy, logical unwind, thread state, and locations

- Add `-panic=unwind|abort`, default `unwind` for the hosted Windows target, and
  carry the selection into runtime symbols and LLVM emission.
- Extend cleanup lowering with a generated per-procedure cleanup thunk, opaque
  context, runtime registration flags for every action that can be live at a
  panic point, and TLS frame push/pop. Preserve the existing normal-exit path;
  after a normal cleanup, clear its registration before executing code that may
  panic.
- Replace every semantic `trap_if` with the classified panic/abort seam. Cover
  explicit panic/assert, nil access/calls/dyn, integer zero division, bounds,
  checked union/any assertions, and implicit allocation/clone failure.
- Implement the panicking guard, newest-first cross-frame walk, partial
  initialization, `os.exit` bypass, and abort on a cleanup panic.
- Add runtime thread attach/detach, use it around the initial thread, and move
  normal managed-TLS teardown behind detach. Do not run TLS teardown during
  panic termination.
- Implement location forms from source-manager spans. `#location(entity)` uses
  the declaration span; `#caller_location` is substituted at each omitted call
  argument before ordinary default checking.
- Extend `tests/trap` with `.flags` and optional expected stdout. Add nested-frame
  unwind/abort pairs, partial initialization, cleanup-order, double-panic, each
  panic-source family, and TLS-normal-versus-panic cases.

**Exit:** unwind runs exactly the registered live actions in every active Loke
frame and then fails; abort runs none; cleanup itself cannot start a second
unwind; locations expose stable file/procedure/line/column values.

### 4. Implement runtime strings, views, multi-pointers, and unsafe text access

- Enable `string`, `string_view`, and `[^]T` in supported runtime positions;
  introduce `cstring_view` with its nil/static/temporary rules.
- Emit static, zero-terminated literal storage and the three-word string value.
  Implement atomic retain/release, allocator-aware destruction, independent
  `clone`, concatenation, equality, byte length, rune count, bytes, slicing,
  valid UTF-8 decoding, and rune iteration with byte offsets.
- Implement every conversion-table row whose source and result exist in M6a:
  strings, literals, byte/rune slices, C views, and multi-pointers. Leave
  `to_runes()` named and gated to M6b rather than claiming the full table.
- Implement multi-pointer conversions, unchecked indexing, the five documented
  slice result shapes and their bounds behavior, plus `unsafe.raw_data`,
  `unsafe.string_view`, and `unsafe.cstring_view` overloads for available types.
  Keep the dynamic-array overload gated to M6b.
- Register text owners, views, subranges, C temporaries, invalidating drops, and
  unsafe provenance loss through M5b’s existing event hooks.

**Exit:** valid text round-trips, invalid UTF-8 returns optional-ok failure,
string assignment shares atomically, clone does not, the last handle frees with
the creating allocator, and every borrowed or temporary text escape receives an
M5b-style creation/conflict diagnostic.

### 5. Implement variadics, runtime type information, and coherent formatting

- Teach signatures, procedure types, overload candidates, direct/indirect
  calls, and LLVM lowering about ordinary `..T`. Materialize and clean up the
  compiler-owned stack buffer, track the initialized managed-element prefix,
  concatenate explicit and spread arguments in source order, and preserve the
  fixed-over-variadic tie-breaker.
- Add the `..any_view` exception with its synthetic call root, temporary element
  addresses, forwarding, and slice/element escape checks. Continue rejecting
  every source-declared array, slice, owner, result, or field containing
  `any_view`.
- Recursively close the requested-type set, emit static string/member/type-info
  tables after typeid freeze, and implement checked `type_info_of` for nil,
  valid, and forged ids.
- Add coherent formatter discovery and one generated thunk per printable
  concrete type. Diagnose two owning-package formatters for one type; do not
  consider caller-local extensions for erased printing.
- Implement the Loke-source `core:fmt` writer/options layer and output
  procedures over the private thunk table. Cover scalars, pointers, strings and
  views, typeids/type names, fixed arrays/slices, structs, enums, unions,
  `Source_Code_Location`, and user-owned coherent formatters.
- Record the coherence rule and public metadata layouts in design.md in the
  implementation commit that makes them observable.

**Exit:** ordinary homogeneous variadics and erased heterogeneous formatting
both work through slice ABI, user formatting is deterministic across packages,
and every valid runtime typeid maps to stable metadata while invalid ids return
nil.

### 6. Retire gates and scaffolding, then audit the milestone

- Remove `print_int` and migrate every fixture to `core:fmt`; keep expected
  output byte-identical. Remove the source-visible `default_allocator()`
  scaffold and migrate its explicit callers.
- Retire only M6a gates. Keep exact diagnostics for `Dynamic_Array`, `Map`,
  `to_runes`, the dynamic `raw_data` overload, arenas, and the other M6b work.
- Audit every existing `llvm.trap`, every cleanup action, every runtime call,
  every `type_is_supported` denial, every borrow carrier registration, every
  predeclared compatibility name, and every `L0350`-family message against the
  M6a scope.
- Update `USAGE`, design cross-references, `readme.md`, and the M6a
  implementation record in `compiler-plan.md` only when code lands.

**Exit:** the full verification below passes from a clean build, no M6a feature
still reaches a compatibility gate, and no M6b feature was enabled accidentally.

## Verification

```powershell
odin test src -define:ODIN_TEST_TRACK_MEMORY=false
odin build src -out:lokec.exe
odin test tests -define:ODIN_TEST_TRACK_MEMORY=false
./lokec.exe examples/hello.loke -o hello.exe
./hello.exe
```

Milestone spot checks:

- Runtime discovery succeeds outside the repository working directory and an
  explicit `-runtime` directory replaces it.
- Copying an allocator preserves its region identity and all callbacks receive
  the original state, size, and alignment.
- A panic in a third nested Loke frame runs that frame’s live drops/defers and
  then both callers’ actions in order under unwind; the paired abort fixture
  prints none of them. Both compile through per-case `.flags`.
- A declaration whose initializer panics is not dropped; earlier fully
  initialized declarations are. A panic raised by a cleanup aborts immediately.
- Each specified runtime-panic family follows the selected strategy, while an
  allocator `.Trap` bypasses unwind under both program strategies.
- Normal thread detach drops managed TLS; panic termination and `os.exit` do not.
- String literals remain constants; concatenation and validation allocate;
  assignment retains atomically; clone owns a separate allocation; the last
  drop calls the recorded allocator once.
- String and C views preserve root provenance, and subrange, `to_c_view`, and
  unsafe conversions each obey their distinct lifetime boundary.
- Ordinary `..int` handles zero, explicit, spread, mixed, forwarded, and
  indirect calls. A managed `..T` temporary clones and drops each element once.
- `..any_view` formats mixed types, forwards once, and cannot escape as a slice
  or element.
- `type_info_of` is stable across source-order changes, recursively resolves
  member types, and returns nil for zero and forged out-of-range ids.
- Two packages cannot give one concrete type different erased formatting;
  explicit extension calls remain possible and do not change `fmt.println`.
- `#location`, `#location(entity)`, and omitted `#caller_location` produce the
  documented declaration or call spans.
- A package imports `core:fmt` and `base:runtime` with no collection flags; the
  existing explicit `-collection base=base` catalogue case still passes.

## Deliberate shortcuts

### Earlier shortcuts M6a repays

| Earlier shortcut | M6a replacement |
|---|---|
| Runtime failures converge on `llvm.trap` | Classified program panic versus immediate abort, with observable cross-frame cleanup |
| One fixed CRT allocator/reset thunk | Stable stateful allocator record and default provider |
| Runtime string and string views are gated | Managed immutable UTF-8 strings plus checked borrowed carriers |
| Only parser-level variadic syntax exists | General `..T`, spreading, forwarding, and call-scoped `..any_view` |
| `typeid` has identity but no metadata lookup | Dense static runtime metadata and checked `type_info_of` |
| `print_int` is the output stand-in | Coherent `core:fmt` over compiler-generated formatter thunks |
| No implicit standard collections | Bundled `base:`/`core:` roots with explicit override |
| `#location`/`#caller_location` are gated | Runtime source-location values with call-site substitution |
| Main-thread-only managed TLS teardown | Runtime thread attach/detach and normal-return teardown |

### Shortcuts retained after M6a

| Shortcut | Replaced when |
|---|---|
| Dynamic arrays, maps, their formatting/invalidation, `to_runes`, and dynamic `raw_data` | M6b |
| No successful source-level local region provider | M6b `mem.Arena`/`mem.Scratch` |
| Annotated typed AST lowers directly to textual LLVM; no MIR | Post-v1 with the second backend or another concrete consumer |
| Formatter coherence is owning-package-only | Deliberate erased-call rule; richer scoped formatting would require a different carrier or call ABI |
| Stored borrows, foreign retention, unsafe provenance loss, hidden aliases, and cross-thread transfer are unchecked | Deliberate v1 boundary |
| Private aggregate/receiver ABI, natural layout only, and foreign interop | M7 |
| `String_Builder`, `C_String`, `Small_Array`, `shared`/`weak`, and sorting | Post-M6 library work |

## Assumptions

- M5a’s cleanup registration order, drop flags, and normal-exit behavior are
  stable, but there is no pre-existing cross-frame unwind artifact to execute.
- M5b’s root/region event stream and result/effect summaries are stable inputs;
  M6a registers new carriers and operations rather than introducing another
  lifetime analysis.
- Windows x64 remains the only v1 code-generation target, and v1 panic has no
  recovery. The logical unwind ABI relies on termination after cleanup and would
  need revision before catch/recover could exist.
- The C runtime is an implementation component, not a Loke package. Public Loke
  ABI declarations live in `base/runtime` and `core/mem`; their layouts and the
  C header are verified against each other.
- M6b writes its detailed plan just in time, using the allocator, panic,
  metadata, formatting, and borrow seams fixed here.

# `src/emit_llvm_const.odin` review

Reviewed [`src/emit_llvm_const.odin`](../../src/emit_llvm_const.odin) at
`e1aab600`. It turns checked constants into LLVM operands and global
initializers. The byte-image path is necessary when a union payload or a
packed, over-aligned record contains a pointer to module storage. Its relocation
list follows layout order, so one pass can interleave byte ranges and pointers.
The existing layout helpers and the cache for reusable private constants fit
those responsibilities.

## Findings

### Mutable slice backing is shared across thread-local instances [P2]

`slice_literal_storage` gives a mutable slice literal a writable process global.
`emit_var_global` applies `thread_local` to the slice header alone. Two workers
that each increment `xs[0]` for `xs: thread_local []mut int = []mut int{0};`
print `1` and `2` when started and joined sequentially. This reproduces with
the declaration at file scope and inside the worker. Both header copies refer
to the same hidden array, so their elements can also be accessed concurrently.
Carry the initializer's storage duration through lowering and give each thread
its own writable backing, including literals nested in aggregates. The view's
pointer needs to be installed for each thread before its code uses the view.
[Slice backing](../../src/emit_llvm_const.odin#L558) ·
[Global qualifier](../../src/emit_llvm_runtime.odin#L358) ·
[Storage modifiers](../design.md#storage-modifiers) ·
[Slice literals](../design.md#slice-literals)

### A small union variant writes the largest variant's padding [P2]

`union_constant` allocates the full payload size, then writes the entire byte
tail one escaped byte at a time. A global `.tiny(7)` in
`Wide :: union { empty, tiny: u8, inactive: [65536]u8 }` creates a 196,674-character
initializer line, including 65,535 escaped zero bytes. Its size and transient
buffer cost grow with an inactive variant. Serialize the active payload and use
a typed `zeroinitializer` for all-zero byte members. Apply the same all-zero byte
range spelling to relocation images, where padding between pointer fields is
also common. Keep the union's storage type, offsets, and tag spelling intact.
[Union constant](../../src/emit_llvm_const.odin#L14) ·
[Byte-array spelling](../../src/emit_llvm_const.odin#L100) ·
[Relocation images](../../src/emit_llvm_const.odin#L418)

### Equal file-scope slice literals have observable shared backing

The immutable backing cache gives separate `a: []int = []int{2};` and
`b: []int = []int{2};` the same pointer. `&a[0] == &b[0]` is `true`, and the same
comparison on two lexically scoped literals is `false`. An explicitly spelled
`[]mut int{2}` weakened to `[]int` also joins that cache. The slice-literal
section describes creation of a hidden array for a literal and gives that array
static lifetime at file scope. Clarify whether that allows merging distinct
immutable arrays with observable addresses. Preserving literal identity would
require distinct backing globals with significant LLVM addresses, while caching
can still serve constant contents whose address is unobservable.
[Slice backing cache](../../src/emit_llvm_const.odin#L579) ·
[Private constant definition](../../src/emit_llvm_const.odin#L491) ·
[Slice literals](../design.md#slice-literals) ·
[Comparison operators](../design.md#comparison-operators)

## Simplification and boundaries

- `shrink:` The integer union head is at most 16 bytes. Accumulate each byte in
  a `u128` with shifts and bitwise OR, and print it with `%d`. The branch then
  needs neither per-byte arbitrary-precision operations nor the emitter
  argument. [Union head](../../src/emit_llvm_const.odin#L60) ·
  [Head width](../../src/emit_llvm_union.odin#L10)
- `delete:` `write_u64_bytes` repeats the existing little-endian
  `write_pattern_bytes` loop. Widen the tag, type ID, count, and flags to `u128`
  at those call sites and use the existing writer.
  [LLVM byte writer](../../src/emit_llvm_const.odin#L365) ·
  [Shared byte writer](../../src/const_ops.odin#L659)
- `yagni:` Inline `slice_constant` into `slice_literal_constant`. The private
  wrapper has one caller and adds only a formatting call.
  [Slice initializer](../../src/emit_llvm_const.odin#L548) ·
  [Wrapper](../../src/emit_llvm_const.odin#L586)
- `shrink:` Derive the pointer, length, and owner flags of a literal from one
  carrier description in the emitter. The typed and byte-image paths currently
  make independent empty checks and choose literal storage separately. Keep
  each renderer and share just those carrier decisions, including the nonnull
  address of an empty `cstring_view` and the writable slice backing rule.
  [Byte images](../../src/emit_llvm_const.odin#L329) ·
  [Typed constants](../../src/emit_llvm_const.odin#L136) ·
  [Text header](../../src/emit_llvm_const.odin#L591)

The two local deletions can remove about 12 lines. Measure the carrier change
against the duplicated code before adding a shared representation.

## Verification

Built and ran the thread-local and slice identity probes with `lokec` at
`v0.10.0-15-ge1aab600`. Inspected the retained TLS and slice LLVM globals and
measured the wide union initializer in `-emit-ll` output. The existing
[pointer constant images example](../../tests/run/pointer_constant_images.loke)
built and ran with its expected output. This was a review of the source and
the focused probes.

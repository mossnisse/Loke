# Source review of `emit_llvm_box.odin`

Reviewed [emit_llvm_box.odin](../../src/emit_llvm_box.odin) at `ea622efe`.
It lowers boxed and raw allocation, box payload projections, and box copy,
drop, and unbox operations.

## Findings

### Box lifecycle thunks assume pointer alignment for packed fields [P1]

`box_drop_thunk` loads and clears its `%p` slot at LLVM's default pointer
alignment (lines 140–146). `box_clone_thunk` does the same for `%src`
(line 178). A `@(packed)` record containing `tag: u8, payload: Box(int)`
places the handle at offset one. Its generated drop and clone call the
thunks with the field address and lose the `align 1` used by direct field
loads and stores. LLVM can assume those accesses are aligned, which makes
the generated IR undefined for a misaligned slot. Use explicit `align 1`
for the pointer load and clear through `%p` and the pointer load through
`%src`. Apply the same alignment to the `%out` store if the thunk contract
accepts arbitrary destination places. Heap header and payload accesses can
keep their allocation alignment.
[Box drop thunk](../../src/emit_llvm_box.odin#L140) ·
[Box clone thunk](../../src/emit_llvm_box.odin#L178) ·
[Record drop](../../src/emit_llvm_lifecycle.odin#L340) ·
[Packed field alignment](../../src/emit_llvm_place.odin#L156) ·
[Packed layout](../design.md#packed)

### An explicit zero allocator loses the original box provider [P2]

`emit_box_new` stores the supplied allocator operand in the header (line 90)
even when it is null. `box_clone_thunk` does the same for `%a` (line 208).
The runtime resolves null against the provider selected at the time of each
call. A box made or cloned with `{}` inside the allocator factory therefore
allocates from the fallback heap. If it survives provider publication, drop
or unbox reads null from the header and sends the heap allocation to the new
provider. A selected arena cannot reclaim that fallback allocation. Resolve
the allocator used for a new box to a concrete provider once, before cloning
or allocating, and write that handle to the header in both paths.
[Box allocation](../../src/emit_llvm_box.odin#L90) ·
[Box clone](../../src/emit_llvm_box.odin#L208) ·
[Runtime provider resolution](../../runtime/alloc.c#L111) ·
[Owned values](../design.md#owned-values) ·
[Provider initialization](../design.md#provider-initialization) ·
[Allocators](../design.md#allocators)

## Simplification and boundaries

- `emit_box_new` always emits `take_refusal` and `restore_refusal` on allocation
  failure (lines 81–86), even when the payload has no cleanup. `drop_temporary_value`
  returns immediately in that case. Emit both runtime calls only when there is a
  held payload to drop, preserving refusal across all managed cleanup.
  [Failure path](../../src/emit_llvm_box.odin#L81) ·
  [Temporary cleanup](../../src/emit_llvm_cleanup.odin#L245) ·
  [Allocation failure](../design.md#allocation-failure)
- `box_clone_thunk` snapshots a privately staged managed payload once more
  before allocating (lines 179–194). For a large payload `load_place` creates
  a second stack slot and emits a full-size `memcpy`. Use `load_temporary`
  for the freshly cloned slot. Preserve `load_place` for the borrowed plain
  origin, which snapshots its value before the allocation call.
  [Clone staging](../../src/emit_llvm_box.odin#L179) ·
  [Large-value loads](../../src/emit_llvm_place.odin#L12) ·
  [Temporary loads](../../src/emit_llvm_place.odin#L54)
- Make `box_payload_at` file-private (line 104). Other lowering code already
  uses `emit_box_payload_address`, which takes a box's type and resolves its
  payload internally.
  [Payload address helpers](../../src/emit_llvm_box.odin#L104)
- Memoized per-type thunks make recursive boxes finite to emit and allow one
  drop or clone body to serve every call site. Construction, cloning, and
  release share the box layout helpers, and the lifecycle emitter supplies
  the finalized payload operations. Preserve those boundaries and the guard
  around payload drop for panic replay.
  [Thunk memoization](../../src/emit_llvm.odin#L787) ·
  [Lifecycle operations](../../src/emit_llvm_lifecycle.odin#L436) ·
  [Box cleanup](../../src/emit_llvm_cleanup.odin#L131)

## Verification

`loke-source-review.exe` reported `v0.10.0-4-gea622efe`. Focused `-emit-ll`
probes confirmed the packed field at offset one reaches both lifecycle thunks
and that an allocator factory can retain boxes across publication. The
factory saved `box(1, {})`, `initial.clone({})`, and `box(3)` in separate
static `Option(Box(int))` values. The first two headers stored null and the
third stored the concrete fallback provider returned by
`loke_rt_v1_selected_allocator`. IR for drop and unbox loaded the header to
call `loke_rt_v1_free`. The runtime's provider dispatch establishes the wrong
release target. A record with `[8192]u8` and `string` fields produced an
additional 8,216-byte copy from the staged payload before the box allocation.

`box_refusal_keeps_its_size`, `box_list`, and `box_expected_payload` built and
ran with their expected output. Manually checked relative links and anchors.
`check-citations.ps1` and `bundle.ps1` passed.

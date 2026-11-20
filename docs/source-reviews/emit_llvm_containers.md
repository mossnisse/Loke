# Review of `src/emit_llvm_containers.odin`

Reviewed at `e1aab600`. This module connects checked container operations to the
versioned runtime. The runtime owns backing storage and probing. The emitter
owns argument evaluation, lifecycle callbacks, and the handoff between a value
being built and its container. Memoizing operation tables by concrete container
shape and callbacks by type fits those responsibilities. In particular, distinct
map keys need their own equality and hash policy. Reusing map literal scratch
slots keeps stack use from growing with the entry count at `-opt=none`.
[Container lowering](../../src/emit_llvm_containers.odin),
[Runtime storage](../../runtime/container.c),
[Maps](../design.md#maps)

## Correctness

- **P1. A panicking copy during dynamic insertion can double-drop a live
  value and skip another.** The `.Insert` arm (lines 473–478) delegates copying
  the borrowed value to `loke_rt_v1_dyn_insert`. The helper shifts existing
  elements before calling the copy thunk and only rolls the shift back if the
  thunk returns failure. A panic unwinds with the old length and shifted
  contents. With spare capacity, inserting a borrowed `Item{99}` at zero into
  `[1, 2, 3]` printed drops `99, 2, 1, 1`. The initialized owners should drop
  `99, 3, 2, 1`. Validate the index and complete the copy before shifting or
  publishing the new storage, and keep the staged value guarded until the
  container takes it. Preserve the `try_insert` failure path.
  [Insert lowering](../../src/emit_llvm_containers.odin),
  [Runtime insertion and drop](../../runtime/container.c),
  [What the unwind runs](../design.md#what-the-unwind-runs-and-what-it-does-not)

- **P2. A panicking append copy leaves previously built clones outside the
  registered length.** `emit_synth_append` (lines 604–634) relies on the C
  helper to clone borrowed operands. `dyn_fill` destroys previous clones when a
  clone reports failure. A panic bypasses that loop and the destination's
  registered cleanup only sees the old length. With spare capacity, a
  `try_append(first, second)` that successfully cloned `first` as `Item{101}`
  and then panicked copying `second` printed drops `99, 1`, omitting `101`.
  Arrange for a cleanup to own the initialized clones before the next hook can
  run. Keep borrowed originals with the caller, and track relocated pack
  elements separately so rollback never drops them twice.
  [Append lowering](../../src/emit_llvm_containers.odin),
  [Runtime append and `dyn_fill`](../../runtime/container.c),
  [Container insertion](../design.md#container-insertion)

- **P2. A drop panic after failed move-only append skips the rest of the
  pack.** `emit_synth_container_op` (line 459) omits an append unwind frame,
  and `emit_drop_run` (lines 772–778) drops refused owned values without
  registering the remaining elements. Appending two move-only values to an
  array backed by a zero arena caused the first value's drop to panic. The
  surrounding `defer` ran during unwinding, and the second value never dropped.
  Keep the still-owned pack registered during disposal, using the existing
  tracked element-drop machinery with a generated frame or retaining the
  caller's ownership until the operation returns its status.
  [Append cleanup](../../src/emit_llvm_containers.odin),
  [Tracked element cleanup](../../src/emit_llvm_lifecycle.odin),
  [What the unwind runs](../design.md#what-the-unwind-runs-and-what-it-does-not)

## Simplification and boundaries

- `L266–271 shrink` Remove the explicit `map_bind` or `dyn_bind` before
  reserving a nonempty literal and the two dedicated LLVM declarations.
  Both C reserve helpers already bind the header before deciding whether to
  allocate. Keep the written `via` store before the reservation and retain
  the C runtime entry points.
  [Literal construction](../../src/emit_llvm_containers.odin),
  [Reserve implementations](../../runtime/container.c)
- `L768 delete` Replace `rejoin(e, kept)` with `place_label(e, kept)` at its
  four callers. The wrapper forwards the arguments unchanged and owns no
  state.
  [Failure branches](../../src/emit_llvm_containers.odin)
- `L346–352 shrink` The common map insertion scratch layout always allocates
  an old-value slot and a parked new-value slot. An unmanaged value never uses
  the old slot, and `try_insert` already has a staging slot for its new value.
  Allocate the old slot only for managed elements and give `try_insert` a
  smaller shared slot layout or use its existing staging slot as the new-value
  slot. Keep the pointer spill across the failure branch and the per-literal
  slot reuse.
  [Insertion scratch storage and callers](../../src/emit_llvm_containers.odin)
- **Duplicate calls across emitter modules.** `container_hash_thunk` and
  `container_equal_thunk` (lines 175–214) emit almost the same direct-hook
  calls as structural hashing and equality. Share the address-based call
  emission alongside the comparison emitter and have map thunks pass the
  checker-settled hook and the desired callee symbol. This also gives
  `hook_argument` (lines 124–134), used by structural comparisons and sequence
  operations, a home with general typed call-operand lowering. Keep policy
  selection at each caller since map keys use a frozen `==` and `hash` pair.
  [Map callbacks](../../src/emit_llvm_containers.odin),
  [Structural comparison and hashing](../../src/emit_llvm_equality.odin),
  [Sequence comparators](../../src/emit_llvm_sequence.odin)
- **Repeated probe on misses.** `find_or_insert` (lines 674 and 703) first
  probes to avoid cloning a value on a hit, then `map_entry` probes again on
  a miss. The first probe is necessary under the current ABI. Any change
  should measure miss-heavy cases with expensive custom hashes and establish
  that the missing-slot information stays valid across the copy hook before
  extending the runtime ABI.
  [Find-or-insert lowering](../../src/emit_llvm_containers.odin),
  [Runtime probing and insertion](../../runtime/container.c)

`net: -8 lines possible.` This estimate covers the explicit bind and `rejoin`
removals.

## Verification

Built and ran three focused Windows executables with `lokec` from
`v0.10.0-15-ge1aab600` and its default unwind strategy. Each executable exited
with the expected panic status `3`. The logged drops distinguish the three
ownership failures.

For the first two reproductions, use this type and one `main` body at a time.

```loke
package main;
import "core:fmt";

Item :: struct { id: int }
impl Item {
    copy_owned :: hook(copy) proc(self, allocator: Allocator) -> Result(Item, Allocator_Error) {
        if (self.id == 99) { panic("copy failed"); }
        return .ok(Item{self.id + 100});
    }
    release :: hook(drop) proc(self: inout Item) {
        fmt.println("drop", self.id);
    }
}

main :: proc() {
    items := [dynamic]Item{Item{1}, Item{2}, Item{3}};
    items.reserve(8);
    borrowed := Item{99};
    items.insert(0, borrowed);
}
```

```loke
main :: proc() {
    items: [dynamic]Item = {};
    items.reserve(8);
    first := Item{1};
    second := Item{99};
    _ = items.try_append(first, second);
}
```

For the third reproduction, use a move-only type and a zero arena.

```loke
package main;
import "core:fmt";
import "core:mem";

@(move_only) Item :: struct { id: int }
impl Item {
    release :: hook(drop) proc(self: inout Item) {
        fmt.println("drop", self.id);
        if (self.id == 1) { panic("drop failed"); }
    }
}

main :: proc() {
    defer fmt.println("unwound");
    arena: mem.Arena = {};
    items := make([dynamic]Item, 0, arena.allocator());
    _ = items.try_append(Item{1}, Item{2});
}
```

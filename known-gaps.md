# Known gaps

Divergences between the specification documents and the shipped compiler, with
a minimal reproduction for each. A gap leaves this file when the compiler
accepts the program the spec describes — not when the spec is reworded to match
the compiler, unless the rewording is the intended fix.

## Gaps

### Reads under a read-only reborrow are allowed only for slice locals

[design.md "Weakening and reborrows"](design.md#weakening-and-reborrows) lets a
carrier suspended by a read-only reborrow still be read. The compiler allows
those reads only for a local `[]mut T` whose elements are plain data: passed to
a `[]T` parameter, indexed, `len`, `cap`, `hash`, resliced read-only, traversed
by value, or printed. Any other read is still `L0641`, among them a slice
stored in a record field, a `^mut T`, and a slice whose elements are carriers.
This program should be accepted:

```odin
package main;
import "core:fmt";
Holder :: struct { items: []mut int }
main :: proc() {
    storage := [2]int{1, 2};
    held := Holder{storage[:]};
    view: []int = held.items;
    fmt.println(held.items[0]);   // L0641; it only reads
    fmt.println(view[0]);
}
```

Each accepted read is tagged where the provenance walk emits it
(`reads_only` on the `Live` event), so an untagged read stays rejected rather
than letting a write through. Covering the rest means tagging the read paths
through fields, pointers, and loaded carriers.

### Temporary and unwinding drops are not write effects

[design.md "Global write effects"](design.md#global-write-effects) counts a
`hook(drop)` as a call wherever a value is dropped. The compiler counts drops
at scope exit, `drop`, assignment, a `move` parameter's return, and `clear` or
a shrinking `resize`, but not a temporary dropped at the end of its statement
(including a discarded `pop` or `remove` result) or a drop during panic
unwinding. This program is accepted and reads freed storage:

```odin
package main;
import "core:fmt";

cache: [dynamic]int;
Guard :: move_only struct { active: bool }
impl Guard {
    release :: hook(drop) proc(self: inout Guard) {
        if (self.active) { cache.clear(); cache.shrink(); }
    }
}
look :: proc(g: Guard) {}
main :: proc() {
    cache = [dynamic]int{42};
    view := cache[:];
    look(Guard{true});    // the temporary drops here; should be L0512
    fmt.println(view[0]);
}
```

The provenance walk has no point where a temporary's drop happens; the emitter
decides that. Unwinding cleanup is modeled only by the lifecycle pass.

### A `shared(T)` payload's borrows are not tracked

[design.md "Values that contain borrows"](design.md#values-that-contain-borrows)
says putting a borrow inside a value does not discard what it owes. A
`shared(T)` is a library record over a `rawptr` control block, so it carries
no carrier path to its payload, and a payload that borrows a local outlives it.
This program is accepted and reads a dead frame:

```odin
package main;
import "core:fmt";
View :: struct { items: []int }
make_handle :: proc() -> shared(View) {
    local := [3]int{1, 2, 3};
    return shared(View{local[:]});  // should be L0526
}
main :: proc() {
    h := make_handle();
    fmt.println(h.get().items[0]);
}
```

`box(T)` is a compiler type for this reason, and its payload is a wildcard
carrier path as a dynamic array's element is. `shared(T)` needs the same:
either the compiler gives `Shared(T)` and `Weak(T)` their payload's carrier
shape, or they become compiler types when the decision under
[Non-null references and explicit allocation owners](open-questions.md#non-null-references-and-explicit-allocation-owners)
gives `shared(T)` the box's `^` and conversion.

### An owner made from a temporary arena outlives it

[design.md "Allocator regions and region provenance"](design.md#allocator-regions-and-region-provenance)
says an owner backed by a local region cannot outlive the region. A named
arena's drop ends its region and is checked (`L0537`), but a temporary arena
ends with its statement and nothing marks that end, so a container or a box
built from one is accepted and then used, and released, through a freed
control block:

```odin
package main;
import "core:mem";
main :: proc() {
    xs := make([dynamic]int, 0, 1, mem.Arena.init().allocator());
    xs.append(1);                             // should be rejected
    b := box(0, mem.Arena.init().allocator());
    b^ = 1;                                   // should be rejected
}
```

`new` used to catch its own case, because its allocation root depended on the
allocator handle's loan; the containers never did. The fix is to end a
temporary provider's region where the temporary ends, as `provider_region_end`
does for a named one.

### A deferred reset can end the region backing a returned owner

[design.md "Allocators"](design.md#allocators) rejects a reset while an owner
backed by the region is live, and a result is transferred to the caller before
the procedure's deferred statements run, so the caller's owner is live across
the reset. A `defer free_all` of a received region is accepted anyway when the
result is an owner, and the caller receives one whose storage is gone:

```odin
package main;
import "core:mem";
reset_later :: proc(@(allocator_reset) allocator: Allocator) -> [dynamic]int {
    defer free_all(allocator);      // should be L0537
    return make([dynamic]int, 0, 1, allocator);
}
main :: proc() {
    arena := mem.Arena.init();
    xs := reset_later(arena.allocator());
    xs.append(1);
}
```

`new` was rejected in this position, because its result was a checked pointer
into an allocation root the reset ended; the same function returning a
`box(int)` is accepted like the container.

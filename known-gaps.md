# Known gaps

Divergences between the specification documents and the shipped compiler, with
a minimal reproduction for each. A gap leaves this file when the compiler
accepts the program the spec describes — not when the spec is reworded to match
the compiler, unless the rewording is the intended fix.

## Gaps

### A moved owned foreach leaf is dropped again at the end of its step

[design.md "Lifecycle hooks and resource types"](design.md#lifecycle-hooks-and-resource-types)
runs a drop hook exactly once per initialization that is not transferred.
`bind_foreach_field` in [src/emit_llvm_iteration.odin](src/emit_llvm_iteration.odin)
registers an owned loop binding's drop with `register_scope_place`, which
`move` cannot cancel, and the lifecycle walk does not follow `foreach`
bindings, so moving one leaves the step's drop in place:

```odin
package main;
import "core:fmt";
Owned :: move_only struct { id: int }
impl Owned {
    release :: hook(drop) proc(self: inout Owned) { fmt.println("drop", self.id); }
}
Row :: struct { owned: Owned, lent: int }
Sequence :: struct { n: int }
Cursor :: struct { at: int, n: int }
impl Sequence {
    Element :: Row;
    iter :: proc(self) -> Cursor { return {0, self.n}; }
}
impl Cursor {
    next :: proc(self: inout Cursor) -> Option(Row) {
        if (self.at >= self.n) { return .none; }
        self.at += 1;
        return .some(Row{Owned{self.at}, 5});
    }
}
take :: proc(value: move Owned) { fmt.println("take", value.id); }
main :: proc() {
    foreach (owned, lent in Sequence{1}) { take(move(owned)); }
}
```

This prints `take 1`, `drop 1`, and then `drop 0`: the step drops the inert
value `move` left behind. Owned loop bindings need the liveness tracking and
cancellable drops a local has. The mixed-yield gap below needs the same.

This iteration-emission gap was reproduced with a compiler built from the
source tree on 2026-10-02.

### Mixed record yields mark owned leaves as borrowed

[design.md "Yield modes"](design.md#yield-modes) and
["Element bindings"](design.md#element-bindings) decide ownership per field
of a record yield. `check_protocol_foreach` and `bind_pattern_leaf` in
[src/iterate.odin](src/iterate.odin) instead apply `s.borrows` to every leaf
when any field is lent, including fields `next` hands over as owned values:

```odin
package main;
import "core:fmt";
Owned :: move_only struct { id: int }
impl Owned {
    release :: hook(drop) proc(self: inout Owned) { fmt.println("drop", self.id); }
}
Row :: struct { owned: Owned, lent: int }
Sequence :: struct { values: []int }
Cursor :: struct { values: []int, at: int }
impl Sequence {
    Element :: Row;
    iter :: proc(self) -> Cursor { return {self.values, 0}; }
}
impl Cursor {
    next :: proc(self: inout Cursor) -> Option((owned: Owned, lent: ^int)) {
        if (self.at >= self.values.len()) { return .none; }
        p := &self.values[self.at];
        self.at += 1;
        return .some({owned = Owned{self.at}, lent = p});
    }
}
take :: proc(value: move Owned) { fmt.println("take", value.id); }
main :: proc() {
    values := [1]int{7};
    foreach (owned, lent in Sequence{values[:]}) {
        take(move(owned));
        fmt.println(lent);
    }
}
```

The `owned` leaf should transfer into `take`, which drops it once. Instead
the compiler rejects `move(owned)` with `L0690`, claiming that the source
still owns it. Replacing the body with `fmt.println(owned.id, lent)`
compiles, prints `1 7`, and drops that owned value at the end of the step.
Preserve the yield descriptor through recursive binding and classify each
leaf separately; owned fields must remain movable and droppable even when
their siblings borrow.

This iteration finding was reproduced with a compiler built from the
source tree on 2026-10-02. The existing `m4b_foreach`, `m6b_iteration`,
`foreach_elements`, `foreach_regressions`, `iteration_ownership`,
`derived_iterator`, `readonly_iteration`, and `mutable_iteration` run cases
all compile and match their expected output without covering it.

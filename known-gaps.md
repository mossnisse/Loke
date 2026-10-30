# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### A multiple assignment's destination goes through its carrier's new value

[Evaluation order](design.md#evaluation-order) evaluates every destination of
a multiple assignment before any is written, and
[Values that contain borrows](design.md#values-that-contain-borrows) puts a
store where the carrier it goes through points. `prov_assign` in
[src/cfg_provenance.odin](src/cfg_provenance.odin) instead handles each
target in turn, so a later destination reached through a carrier an earlier
target redefines is taken to go through the new value (unsound):

```loke
package main;
Node :: struct { value: int }
Pair :: struct { head: ^mut Node, tail: ^mut Node }
main :: proc() {
    a := Node{1}; b := Node{2}; c := Node{3}; d := Node{4};
    x := Pair{&mut a, &mut b};
    y := Pair{&mut c, &mut d};
    p := &mut x;
    p, p^.head = &mut y, p^.tail; // stores into x.head
    h := x.head;                  // points at b
    b.value = 7;                  // accepted, should be L0511
    h^.value = 1;
}
```

Writing `p^.head = p^.tail; p = &mut y;` instead reports `L0511` at
`b.value = 7`. A store into an element of a local view a multiple assignment
also reassigns is not narrowed to one element, so the narrowing adds nothing
to it. Closing it needs each destination's carriers read before the first
write, as the values already are (`prov_capture_slots`). Found while
closing the self-resliced view case on 2026-10-30.

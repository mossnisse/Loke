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

### A generic `impl`'s constant is not read by the type of its value

[Private names in public declarations](design.md#private-names-in-public-declarations)
reads a public constant with no written type by the type of its value. A
member of a generic `impl` is checked per instance, so its template has no
symbol and no type, and only its written syntax is read:

```loke
package shapes;
@(private) Corner :: struct { x: int }
@(public) Box :: struct($T: type) { value: T }
impl Box($T) {
    @(public) ORIGIN :: Corner{}; // should warn L0740, as it does in a non-generic `impl`
}
```

`read_public_decl` in [src/private_names.odin](src/private_names.odin) reads
the type from the constant's symbol. Reading it from the syntax would guess:
`Corner{}` names its type, but `size_of(Corner)` names a type and has another.
Writing the type, `ORIGIN: Corner : Corner{}`, is reported. Found while adding
the warning on 2026-10-30.

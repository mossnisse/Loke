# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### Storing one element of a local view resliced from itself is rejected

[Weakening and reborrows](design.md#weakening-and-reborrows) lets a store
replace what one place held. A local view whose definitions are each a borrow,
or a constant reslice of another such view, now replaces the one element it
names, but a view resliced from itself does not:

```loke
package main;
Node :: struct { value: int }
Counted :: struct { head: ^mut Node, tail: ^mut Node, count: int }
self_resliced :: proc() {
    a := Node{1}; b := Node{2}; c := Node{3}; d := Node{4}; e := Node{5}; f := Node{6};
    arr := [3]Counted{{&mut a, &mut b, 0}, {&mut c, &mut d, 0}, {&mut e, &mut f, 0}};
    s := &mut arr[:];
    s = &mut s[1:];
    for (round := 0; round < 2; round += 1) {
        h := s[0].head;
        h^.value = 1;
        s[0].head = s[0].tail; // L0641, should be allowed
    }
}
main :: proc() {}
```

`publish_view_of` in [src/borrow.odin](src/borrow.odin) relates a view to the
range its borrow lends from each definition of the slot, wherever it stands,
so a definition that reslices the slot itself refers back to itself and the
view's start counts as unknown. Telling the two definitions apart needs the
view's start tracked per program point, like the loans a slot holds. When the
reslice runs inside the loop, the store may name several places and rejecting
it is correct. Found while closing the resliced-view case on 2026-10-30.

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

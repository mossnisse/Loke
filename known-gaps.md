# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### A store through a carrier loaded from a parameter joins into the parameter

[Weakening and reborrows](design.md#weakening-and-reborrows) borrows a place
reached through a pointer for that place only, so storing `head` beside a
borrow of `count` is allowed. Through a parameter, or a pointer loaded out of
one, it is rejected once a loop repeats it, though the same body without the
loop compiles:

```loke
package main;
Node :: struct { value: int }
Counted :: struct { head: ^mut Node, tail: ^mut Node, count: int }
sink :: proc(value: int) {}
loaded :: proc(p: ^mut ^mut Counted) {
    for (round := 0; round < 2; round += 1) {
        count := &p^^.count;
        p^^.head = p^^.tail; // L0641, should be allowed
        sink(count^);
    }
}
main :: proc() {}
```

`publish_into_loan` in [src/borrow.odin](src/borrow.odin) joins a store into
the slots carrying the loan's root symbol, and for a parameter's caller storage
the only such slot is the parameter itself, so `p` comes to hold the stored
node's loans. In the next iteration the copy of `p^^.tail` loaded through it
then holds the loans of the storage `count` is borrowed from, so the copy,
which may write all its pointer names, is taken to write over `count`'s place
loan. Publishing into the caller
slots instead, as `load_through_loan` reads them, is not enough alone: a later
load through a parameter sees a stored carrier only through the parameter's
own loans, so this join is also what rejects
`h^.head = h^.tail; x := h^.head; y := h^.tail; x^.value = 1; y^.value = 2;`.
Loads need to read what the caller slots hold first ("Caller storage contents"
under [Compositional loan construction](open-questions.md#compositional-loan-construction)).
`matrix_known_gap` lists the matrix cases.

### A write through a pointer read out of a borrowed place is not checked against it

[Switch ownership](design.md#switch-ownership) forbids writing a switched
payload through any pointer to its place while a binding is in use, and
[Weakening and reborrows](design.md#weakening-and-reborrows) forbids a write
overlapping a live borrow. A pointer read out of the borrowed place itself may
lead back to it in a cyclic structure, and a write through it is accepted:

```loke
package main;
Node :: struct { value: int, back: ^mut Holder }
Holder :: struct { first: Option(^mut Node), count: int }
through_binding :: proc(h: ^mut Holder) -> int {
    switch (h^.first) {
    case .some(node):
        node^.back^.first = .none; // should be rejected when `node^.back` is `h`
        return node^.value;
    case .none:
    }
    return 0;
}
Cell :: struct { next: ^mut Cell, value: int }
Pair :: struct { left: Cell, right: Cell }
through_borrow :: proc(p: ^mut Pair) -> int {
    left := &mut p^.left;
    right := &p^.right;
    left^.next^.value = 1;     // should be rejected when `left^.next` is `&mut p^.right`
    return right^.value;
}
main :: proc() {}
```

Place loans treat what is read out through a borrow as inside the borrowed
place: `carry_place_bits` in [src/borrow.odin](src/borrow.odin) gives a
loaded value its source's place-loan bits, so an access through it is the
loan's own, and `accessed_beside` takes one through a borrow of a sibling
place to be beside it. That keeps a `&mut left` case binding from conflicting
with what `&mut left^` reaches, where a recursive type makes that content
indistinguishable from the subject, but it also exempts these writes. Telling
them apart needs pointee storage the analysis can distinguish from the place
it was read out of.

### A fifth possible field makes a borrow cover unrelated fields

[Weakening and reborrows](design.md#weakening-and-reborrows) lets a carrier
be used for a place beside the one borrowed through it. In commit `5244cddd`,
a pointer chosen among four sibling fields keeps `z` writable, but adding a
fifth reports `L0641` at the write to `z`:

```loke
package main;
Holder :: struct { a: int, b: int, c: int, d: int, e: int, z: int }
probe :: proc(h: ^mut Holder, x: bool, y: bool, w: bool, v: bool) -> int {
    a := &mut h^.a; b := &mut h^.b; c := &mut h^.c;
    d := &mut h^.d; e := &mut h^.e;
    q := a if x else b if y else c if w else d if v else e;
    value := &q^;
    h^.z = 1; // should be allowed
    return value^;
}
main :: proc() {}
```

`prov_union_offsets` in [src/cfg_provenance.odin](src/cfg_provenance.odin)
replaces all alternatives by their common prefix once there are more than
four (`PROV_OFFSET_LIMIT`). Here the prefix names the whole `Holder`, so the
place loan overlaps `z`. The four-choice version of the same program compiles.

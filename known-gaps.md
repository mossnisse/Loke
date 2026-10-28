# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### A store through a pointer to a local joins what the place held

[Values that contain borrows](design.md#values-that-contain-borrows) says
replacing a borrow through a carrier ends the previous borrow in the storage
actually written, and that taking the address of a known place identifies
that place. A store through `list := &mut l` instead keeps what `l.head` held
beside the new value, so the copy of `tail` stored first is still in use when
`tail` is copied again, and this reports `L0641`:

```loke
package main;
Node :: struct { value: int }
List :: struct { head: ^mut Node, tail: ^mut Node }
through_pointer :: proc() {
    a := Node{1}; b := Node{2};
    l := List{&mut a, &mut b};
    list := &mut l;
    list^.head = list^.tail;
    again := list^.head;
    again^.value = 3;
    list^.head = list^.tail; // should be allowed
    last := list^.head;
    last^.value = 4;
}
main :: proc() {}
```

The same statements through `l` itself compile. A store through a carrier is
a `.Publish` event, which `publish_into_loan` in
[src/borrow.odin](src/borrow.odin) joins into every content slot of the
named root that overlaps the loan's path, never replacing one, so storing
`head` also joins into what `tail` holds, and liveness runs through it. When
the carrier holds one loan naming one place exactly, the store could replace
that slot and end its liveness, as a store to `l.head` does. The cases in
[tests/borrow_matrix_test.odin](tests/borrow_matrix_test.odin) that this
rejects are listed in its `matrix_known_gap`.

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

### A repeated store through a pointer to one of several places keeps the copy it stored

[Values that contain borrows](design.md#values-that-contain-borrows) has a
store through a carrier that may name more than one place keep what each
possible target held, since the write may reach another one. Storing a copy
of `tail` into `head` through such a pointer compiles once, and twice in
straight-line code, but a loop repeating it reports `L0641` at the copy,
though nothing reads `head` again and the same loop through a pointer to one
place compiles:

```loke
package main;
Node :: struct { value: int }
List :: struct { head: ^mut Node, tail: ^mut Node }
cond :: proc() -> bool { return true; }
chosen :: proc() {
    a := Node{1}; b := Node{2}; d := Node{4}; e := Node{5};
    l := List{&mut a, &mut b}; m := List{&mut d, &mut e};
    p := &mut l if cond() else &mut m;
    for (i := 0; i < 2; i += 1) {
        p^.head = p^.tail; // L0641, should be allowed
    }
}
main :: proc() {}
```

`prov_publish_view_content` in [src/cfg_provenance.odin](src/cfg_provenance.odin)
defines `l.head` and `m.head` with `preserve_previous`, so each keeps the copy
of `tail` an earlier iteration stored, where a pointer to one place replaces
it. How that kept copy makes the next copy of `tail` conflict, when the
straight-line repetition does not, is not yet pinned down.
`matrix_known_gap` lists the matrix cases, from its `local_chosen` place
form, where a traversal repeats the store too.

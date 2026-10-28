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

[Weakening and reborrows](design.md#weakening-and-reborrows) reborrows the
carriers a borrow goes through for that place only, so storing `head` beside
a borrow of `count` is allowed. Through a pointer loaded out of a parameter,
it is rejected once a loop repeats it, though the same body without the loop
compiles:

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
node's loans. In the next iteration the load of `p^^.tail` through `p^` then
also reads the slot `p^` was loaded from for `count`, as a use with no place,
which the placed reborrow for `count` suspends. Publishing into the caller
slots instead, as `load_through_loan` reads them, is not enough alone: a later
load through a parameter sees a stored carrier only through the parameter's
own loans, so this join is also what rejects
`h^.head = h^.tail; x := h^.head; y := h^.tail; x^.value = 1; y^.value = 2;`.
Loads need to read what the caller slots hold first ("Caller storage contents"
under [Compositional loan construction](open-questions.md#compositional-loan-construction)).
`matrix_known_gap` lists the matrix cases.

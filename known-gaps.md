# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### A bit cast of a `typeid_of` constant has no compile-time value

[`unsafe.transmute`](design.md#unsafetransmute) promises compile-time
bytewise conversion for admitted scalar shapes, and a constant bit cast now
builds a `typeid` from an integer, but not the reverse for a symbolic type:

```loke
package main;
import "core:unsafe";
X :: unsafe.transmute(u64, typeid_of(int));
main :: proc() {}
```

It reports `L0688`, "`unsafe.transmute` has no compile-time meaning from
`typeid` to `u64`". The same cast where the program runs gives the number.
A `typeid_of(T)` constant has no number until emission freezes the numbering
(`freeze_typeids`), so `const_storage` in
[src/check_builtin.odin](src/check_builtin.odin) treats it as unfoldable.
Found while fixing constant `typeid` bit casts on 2026-10-30. Folding it needs
type numbers fixed before constants that depend on them are evaluated, or the
spec to exclude symbolic `typeid` constants; see
[Comparing a forged `typeid` constant](open-questions.md#comparing-a-forged-typeid-constant).

### Storing one element of a local slice view in a loop is rejected

[Weakening and reborrows](design.md#weakening-and-reborrows) lets a store
replace what one place held, so the copy of `s[0].head` taken in one
iteration no longer holds the storage the next store puts there. Through a
slice parameter this is now accepted, but through a local view of two or
more elements it is not:

```loke
package main;
Node :: struct { value: int }
Counted :: struct { head: ^mut Node, tail: ^mut Node, count: int }
local_view :: proc() {
    a := Node{1}; b := Node{2}; c := Node{3}; d := Node{4};
    arr := [2]Counted{{&mut a, &mut b, 0}, {&mut c, &mut d, 0}};
    s := &mut arr[:];
    for (round := 0; round < 2; round += 1) {
        h := s[0].head;
        h^.value = 1;
        s[0].head = s[0].tail; // L0641, should be allowed
    }
}
main :: proc() {}
```

A local view's loan names a range of `arr`, so `publish_replaces` in
[src/borrow.odin](src/borrow.odin) never finds the one place a store into an
element replaces, and the store only joins. A one-element view compiles.
Found while fixing stores through slice parameters on 2026-10-30; the
parameter fix (`prov_view_element` in
[src/cfg_provenance.odin](src/cfg_provenance.odin)) gives a view parameter's
element at a constant index slots of its own, which a local view's range
loan could do as well.

### A borrow a call stores through a pointer argument is not reborrowed by a later copy

[Retaining a borrow](design.md#retaining-a-borrow) says a callee may write an
`@(escape=stored)` argument's borrows into any compatible mutable destination
it receives, and [Weakening and reborrows](design.md#weakening-and-reborrows)
makes a carrier copied out of storage a reborrow of the carrier stored there.
After such a call, a copy out of the destination is not linked to the
argument, so two mutable paths to `r^` are used together:

```loke
package main;
Node :: struct { value: int }
Counted :: struct { head: ^mut Node, tail: ^mut Node, count: int }
relink :: proc(p: ^mut Counted, @(escape=stored) n: ^mut Node) { p^.head = n; }
caller :: proc(p: ^mut Counted, @(escape=stored) r: ^mut Node) {
    relink(p, r);
    h := p^.head;
    r^.value = 1; // should be L0641: `h` may copy `r`
    h^.value = 2;
}
main :: proc() {}
```

This compiles. Writing `p^.head = r` in `caller` instead is rejected. Found
while fixing stores through slice parameters on 2026-10-30. A call's stored
argument should publish into each compatible destination as a store does,
with the copy linked to the slots it may land in.

### A whole record stored through a parameter joins into the parameter

[Weakening and reborrows](design.md#weakening-and-reborrows) lets a carrier be
used beside one copied from a sibling field. Storing a whole record through a
pointer to a local now links each copied carrier to where it lands, but
through a parameter the store also joins into the parameter itself, so a copy
of one field holds the loans of every field:

```loke
package main;
Node :: struct { value: int }
List :: struct { head: ^mut Node, tail: ^mut Node }
sibling :: proc(@(escape=stored) p: ^mut List, @(escape=stored) q: ^mut List) {
    p^ = q^;
    x := p^.head;
    y := q^.tail; // L0641, should be allowed: `x` copies `q^.head`
    x^.value = 1;
    y^.value = 2;
}
main :: proc() {}
```

`caller_replaces` in [src/borrow.odin](src/borrow.odin) does not replace
caller slots for a record store, so `publish_into_loan` keeps joining such a
store into the parameter. The same body over a pointer to a local compiles.
Found while fixing whole-record stores on 2026-10-30. Replacing the record's
carrier slots, as the one-field store through a parameter now does, would
close it.

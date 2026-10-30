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
Found while fixing constant `typeid` bit casts on 2026-10-30. Dense numbering
cannot be fixed earlier, since which types are numbered depends on constants;
folding it needs numbers derived from each type's own identity, or the spec to
exclude symbolic `typeid` constants. See
[Comparing a forged `typeid` constant](open-questions.md#comparing-a-forged-typeid-constant).

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

# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### A copy out of a dynamic array's view suspends the other elements' carriers

[Weakening and reborrows](design.md#weakening-and-reborrows) makes elements
of a local view at different constant indices different places wherever it
is known where the view starts, as it is for a fresh `&mut d[:]` of a
dynamic array, and a carrier copied out of one element is no use of the
carrier stored in another. Over a dynamic array, the second copy here is
still rejected:

```loke
package main;
Node :: struct { value: int }
List :: struct { head: ^mut Node }
through_dynamic_view :: proc() {
    a := Node{1}; b := Node{2};
    lists := [dynamic]List{List{&mut a}, List{&mut b}};
    s := &mut lists[:];
    node := s[0].head;
    other := s[1].head; // L0641; should be accepted
    other^.value = 3;
    node^.value = 1;
}
main :: proc() {}
```

The same copies compile over a fixed `[2]List`, and a borrow of `s[0]`
beside a write of `s[1]` compiles over the dynamic array too. The carriers
stored in a dynamic array's elements share one set of content slots
(`carrier_shape_walk` in [src/borrow.odin](src/borrow.odin) gives every
element one wildcard step), so a load naming one element of the view still
reads what every element holds, and the diagnostic names no analysis budget
as [Minimum provenance precision](design.md#minimum-provenance-precision)
asks of a merge. Copying `lists[0].head` and `lists[1].head` straight out of
the dynamic array is rejected the same way. Telling the elements apart needs
content slots for constant elements of a dynamic array, as a view
parameter's constant elements get caller slots of their own
(`prov_view_element` in [src/cfg_provenance.odin](src/cfg_provenance.odin)).
Found while making copies out of a local view's element read that element
alone on 2026-10-31.

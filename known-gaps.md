# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### A store through a slice parameter joins into the parameter

[Weakening and reborrows](design.md#weakening-and-reborrows) borrows a place
reached through a view for that place only, so storing `head` beside a borrow
of `count` is allowed. Through a slice parameter it is rejected once a loop
repeats it, though the same body without the loop compiles:

```loke
package main;
Node :: struct { value: int }
Counted :: struct { head: ^mut Node, tail: ^mut Node, count: int }
sink :: proc(value: int) {}
sliced :: proc(s: []mut Counted) {
    for (round := 0; round < 2; round += 1) {
        count := &s[0].count;
        s[0].head = s[0].tail; // L0641, should be allowed
        sink(count^);
    }
}
main :: proc() {}
```

A store through a parameter lands in the slots standing for the caller
storage it names (`prov_caller_slots` in
[src/cfg_provenance.odin](src/cfg_provenance.odin)), but a view's slots stand
for all of its elements, which no store replaces, as a view's element step is
not kept below its loan. Landing there alone, with the copy linked to the
slot, would reject a loop that copies `s[0].head` and stores `s[0].tail` into
it, so such a store still joins into the parameter itself
(`publish_into_loan` in [src/borrow.odin](src/borrow.odin)), and the next
iteration's copy of `s[0].tail` loaded through it then holds the loans of the
storage `count` is borrowed from. Telling one element's slots from the
others' would close it. `matrix_known_gap` lists the matrix cases.

### A whole value stored through a pointer keeps no reborrow of its carriers

[Weakening and reborrows](design.md#weakening-and-reborrows) makes a carrier
copied out of storage a reborrow of the carrier stored there, wherever that
storage is. A record holding carriers stored through a pointer copies each of
them, but the copies are not linked to where they land, so copying the
source's carrier again while a copy of the stored one is in use is accepted:

```loke
package main;
Node :: struct { value: int }
List :: struct { head: ^mut Node, tail: ^mut Node }
whole :: proc(q: ^mut List) {
    a := Node{1}; b := Node{2};
    l := List{&mut a, &mut b};
    p := &mut l;
    p^ = q^;
    x := p^.head;
    y := q^.head; // should be L0641: `x` copies the copy of `q^.head`
    x^.value = 1;
    y^.value = 2;
}
main :: proc() {}
```

`prov_assign` in [src/cfg_provenance.odin](src/cfg_provenance.odin) links the
copy a store of one carrier makes to every slot it may land in
(`prov_reborrow`), but nothing for a record. Storing `p^.head = q^.head`
instead is rejected. Through a parameter, such a store also joins into the
parameter itself, which keeps the same body over parameters rejected.

### A pointer chosen among more than eight places covers their shared prefix

[Weakening and reborrows](design.md#weakening-and-reborrows) lets a carrier be
used for a place beside the one borrowed through it. A pointer chosen among
nine fields of a nested record reports `L0641` at a write to a field of the
record that none of the nine is:

```loke
package main;
Wide :: struct { a: int, b: int, c: int, d: int, e: int, z: int }
Sides :: struct { left: Wide, right: Wide }
probe :: proc(s: ^mut Sides, i: int) -> int {
    q := &mut s^.left.a;
    if (i == 1) { q = &mut s^.left.b; }
    if (i == 2) { q = &mut s^.left.c; }
    if (i == 3) { q = &mut s^.left.d; }
    if (i == 4) { q = &mut s^.left.e; }
    if (i == 5) { q = &mut s^.right.a; }
    if (i == 6) { q = &mut s^.right.b; }
    if (i == 7) { q = &mut s^.right.c; }
    if (i == 8) { q = &mut s^.right.d; }
    value := &q^;
    s^.right.e = 2; // allowed
    s^.left.z = 3;  // L0641, should be allowed
    return value^;
}
main :: proc() {}
```

`prov_union_offsets` in [src/cfg_provenance.odin](src/cfg_provenance.odin)
keeps at most eight places a value may point at (`PROV_OFFSET_LIMIT`), and past
that merges the two sharing the longest prefix into it, here `s^.left`, so the
place loan overlaps `s^.left.z`. Nine sibling fields of one record merge into
the whole record. The bound keeps the place loans and `.Through` events a
borrow makes few. The diagnostic also does not name the limit, which
[Minimum provenance precision](design.md#minimum-provenance-precision)
requires of a rejection an analysis budget causes.

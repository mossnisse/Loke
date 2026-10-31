# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### Reaching-definition limits weaken the per-storage chosen-place guarantee

[Minimum provenance precision](design.md#minimum-provenance-precision)
guarantees eight chosen places of each storage and 64 in all, without a
separate limit on definitions or control-flow blocks. The reaching-offset
analysis added by `68504095` falls back to all earlier definitions after 63
definitions of a carrier, or after walking 256 previously uncached blocks.
That fallback again counts later places against the storage the carrier
named before it was repointed. This program chooses four places of `s` and
five of `t`, but rejects the disjoint write:

```loke
package main;
Wide :: struct { a: int, b: int, c: int, d: int, e: int, z: int }
Sides :: struct { left: Wide, right: Wide, z: int }
chosen :: proc(s: ^mut Sides, t: ^mut Sides, i: int) -> int {
    p := s;
    q := &mut p^.left.a;
    if (i == 1) { q = &mut p^.left.b; }
    if (i == 2) { q = &mut p^.left.c; }
    if (i == 3) { q = &mut p^.left.d; }
    p = t;
    foreach ($repeat in 0 ..< 62) { p = t; }
    if (i == 4) { q = &mut p^.left.e; }
    if (i == 5) { q = &mut p^.right.a; }
    if (i == 6) { q = &mut p^.right.b; }
    if (i == 7) { q = &mut p^.right.c; }
    if (i == 8) { q = &mut p^.right.d; }
    value := &q^;
    s^.left.z = 1; // L0641; should be accepted
    return value^;
}
main :: proc() {}
```

Changing 62 to 61 compiles. Replacing the static loop with
`foreach ($repeat in 0 ..< 129) { if (i < 0) {} }` also rejects the write,
this time by exhausting the block walk. Both cases report the eight-place
and multiple-storage precision limits, without naming the reaching-analysis
limit that caused the loss. Keep the per-storage guarantee across these
fallbacks; storing only the last definition in each block also avoids counting
overwritten definitions against the definition bound. Reproduced on a compiler
built from `68504095` and on the merged tree during review on 2026-10-31.

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
An attempt on 2026-10-31 gave a dynamic array's first elements paths of their
own and joined the carriers of elements a call may rearrange. It made
`duplicate` in
[A call that moves carriers between elements or fields is not seen](#a-call-that-moves-carriers-between-elements-or-fields-is-not-seen)
unsound over a dynamic array as it already is over a fixed one, so this gap
waits on that one.

### A call that moves carriers between elements or fields is not seen

[Values that contain borrows](design.md#values-that-contain-borrows) makes a
container carry every borrow stored in it, and
[Weakening and reborrows](design.md#weakening-and-reborrows) makes a copy of a
mutable carrier a reborrow that suspends the carrier copied. A call that
swaps or copies carriers between the elements of a fixed array, or between
fields, leaves each element or field with the provenance it had before, so
all four of these are accepted:

```loke
package main;
Link :: struct { to: ^mut int }
Pair :: struct { a: ^mut int, b: ^mut int }
duplicate :: proc(links: []mut Link) { links[0] = links[1]; }
exchange :: proc(links: []mut Link) { links.swap(0, 1); }
share :: proc(pair: ^mut Pair) { pair^.a = pair^.b; }
view_swapped :: proc() {
    x := 1; y := 2;
    links := [2]Link{Link{&mut x}, Link{&mut y}};
    view := &mut links[:];
    view.swap(0, 1);
    held := links[0].to;
    y = 5; // should be rejected: `held` points at `y`
    held^ = 4;
}
call_exchanges :: proc() {
    x := 1; y := 2;
    links := [2]Link{Link{&mut x}, Link{&mut y}};
    exchange(&mut links[:]);
    held := links[0].to;
    y = 5; // should be rejected
    held^ = 4;
}
call_copies :: proc() {
    x := 1; y := 2;
    links := [2]Link{Link{&mut x}, Link{&mut y}};
    duplicate(&mut links[:]);
    held := links[0].to;
    y = 5; // should be rejected
    held^ = 4;
}
between_fields :: proc() {
    x := 1; y := 2;
    pair := Pair{&mut x, &mut y};
    share(&mut pair);
    held := pair.a;
    y = 5; // should be rejected
    held^ = 4;
}
main :: proc() {}
```

Each callee body is accepted on its own: it stores into its argument's own
storage, which is no retention, and its reborrows end when it returns. A
dynamic array's elements share one path, so the same calls over one are
rejected. Joining the carriers of every element or field a call may write
catches a move; a copy also leaves two live mutable carriers, which needs a
summary saying which arguments a body copies a mutable carrier within, since
linking every element as a reborrow of every other would make two calls
passing the same array conflict. Found while telling a dynamic array's
constant elements apart on 2026-10-31.

### A borrow stored through a mutable traversal binding is not seen in the container

[Values that contain borrows](design.md#values-that-contain-borrows) makes a
container carry every borrow stored in it, and a `foreach (&mut x in xs)`
binding names an element of `xs`. A carrier stored through such a binding is
not seen in the container afterwards:

```loke
package main;
Node :: struct { value: int }
List :: struct { head: ^mut Node }
stored_through_binding :: proc() {
    a := Node{1}; b := Node{2}; c := Node{3};
    lists := [2]List{List{&mut a}, List{&mut b}};
    foreach (&mut list in lists) { list.head = &mut c; }
    node := lists[1].head;
    c.value = 5; // should be rejected: `node` points at `c`
    node^.value = 1;
}
main :: proc() {}
```

The same holds over a dynamic array. Found while telling a dynamic array's
constant elements apart on 2026-10-31.

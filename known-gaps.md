# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### A public type's private formatter reaches an invalid backend witness

[Interface bodies](design.md#interface-bodies) excludes a public type's private
methods from slots, and [String format printing](design.md#string-format-printing)
requires erased printing to use the same `Formattable` witness as an explicit
interface view. The new exclusion is not handled by formatter discovery:

```loke
// lib/lib.loke
package lib;
import "core:fmt";
@(public) S :: struct {}
impl S {
    format :: proc(self, w: fmt.Writer, o: fmt.Options) {
        fmt.format_to(w, "secret");
    }
}
```

```loke
// main.loke
package main;
import "./lib";
import "core:fmt";
main :: proc() { fmt.println(lib.S{}); }
```

Compiling this package reports `L0405: internal backend contract violation:
a discovered formatter has no checked procedure`. The parent of `c0b30260`
compiles it and prints `secret`; marking `format` public also compiles and
prints `secret` with the reviewed compiler. Losing the private method as a
slot candidate is intentional; constructing an invalid witness is not.

`discover_formatters` in [src/format.odin](src/format.odin) still requests a
witness for every printable type in `typeid_order`. `ensure_format_member`
does not supply a default when a written `format` exists, while
`slot_candidates` in [src/interface.odin](src/interface.odin) now excludes
that private method. `request_witness` in [src/erased.odin](src/erased.odin)
therefore records `INVALID_SYMBOL` as the target, which the backend contract
check rejects. Make formatter discovery handle the new eligibility rule
before constructing the witness, with a package regression test. Confirmed
against fresh parent and reviewed compiler builds while reviewing `c0b30260`
on 2026-10-31.

### Views with a known start lose element precision when their length varies

[Weakening and reborrows](design.md#weakening-and-reborrows) separates constant
elements of a local view when its start is known and its reaching definitions
are fresh range borrows or constant reslices. A branch that only shortens the
view keeps its start at zero, and both indices below remain in bounds, but
the write is rejected:

```loke
package main;
Counter :: struct { count: int }
length_only :: proc(flag: bool) {
    a := [3]Counter{};
    s := &mut a[:];
    if (flag) { s = &mut s[:2]; }
    first := &mut s[0];
    s[1].count += 1; // L0641; should be accepted
    first^.count += 1;
}
main :: proc() {}
```

Making the reslice unconditional compiles. `view_element_in` in
[src/borrow.odin](src/borrow.odin) reuses `publish_view_of`, whose
`publish_view_take` requires every reaching definition to agree on both
offset and length. This loses a known start when only lengths differ.
The same distinction also affects a fresh full view of a dynamic array:
`a := [dynamic]Counter{Counter{}, Counter{}}; s := &mut a[:]` rejects the
same two-element access, while spelling `a[0:2]` compiles. Its runtime upper
bound prevents `view_element_in` from recognizing a bounded range, although
the start is zero. Track knowledge of the start separately from an exact
extent, retaining any bounds required for publication. Confirmed while
reviewing `72431f48` on 2026-10-31.

### A carrier repointed between choices counts its places against both storages

[Minimum provenance precision](design.md#minimum-provenance-precision)
guarantees eight chosen places of each storage. When the carrier the places
are reached through is itself repointed between the choices, the places taken
after it was repointed count against the storage it named before too, so four
places of `s` and five of `t` reached through `p` merge, and the disjoint
write is rejected naming the eight-place limit:

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

Borrowing through `s` and `t` directly is accepted. `Prov_Offset.storage` in
[src/borrow.odin](src/borrow.odin) names the storage a place was reached in
by the carrier slot that named it, and a slot's offsets
(`prov_note_offset` in [src/cfg_provenance.odin](src/cfg_provenance.odin))
gather what every definition of it may point at, so after `p = t` they hold
the whole of `s` as well as of `t`. Counting a place against only the storage
its carrier names where it is taken needs offsets that follow the
definitions reaching each borrow. Found while closing the storage scope of the
chosen-place guarantee on 2026-10-31.

### A copy out of a local view's element suspends the other elements' carriers

[Weakening and reborrows](design.md#weakening-and-reborrows) says a carrier
copied out of storage reborrows the carrier stored there, and another field
beside it is not a use of it. Through a local view, a copy out of one element
suspends the carriers stored in every other element, so the second copy here
is rejected:

```loke
package main;
Node :: struct { value: int }
List :: struct { head: ^mut Node }
through_local_view :: proc() {
    a := Node{1}; b := Node{2};
    lists := [2]List{List{&mut a}, List{&mut b}};
    s := &mut lists[:];
    node := s[0].head;
    other := s[1].head; // L0641; should be accepted
    other^.value = 3;
    node^.value = 1;
}
main :: proc() {}
```

The same copies are accepted out of `lists` itself and out of a view
parameter `s: []mut List`, whose constant elements get caller slots of their
own (`prov_view_element` in [src/cfg_provenance.odin](src/cfg_provenance.odin)).
A load through a local view reads the content slots of the whole range the
view's loan lends, so both copies reborrow the same slots. Reading only the
element's own slots needs where the view starts, as `prov_local_view_element`
already works out for a store into one element. Found while making constant
view elements their own places on 2026-10-31.

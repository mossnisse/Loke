# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### An explicitly typed alias in a generic `impl` is not read for private names

[Private names in public declarations](design.md#private-names-in-public-declarations)
reads a type alias's target. An alias written `Inner: type : Corner` warns in
a plain `impl`, but the same declaration in a generic `impl` does not, even
when an instance is checked:

```loke
package shapes;
@(private) Corner :: struct { x: int }
@(public) Plain :: struct { value: int }
@(public) Box :: struct($T: type) { value: T }
impl Plain {
    @(public) Inner: type : Corner; // L0740
}
impl Box($T) {
    @(public) Inner: type : Corner; // should warn L0740 too
}
@(private) use :: proc() { _ = size_of(Box(int).Inner); }
```

`read_generic_impl_constants` in [src/private_names.odin](src/private_names.odin)
classifies aliases only after `untyped_constant` has excluded declarations
with a written type. Without an entry in `generic_impl_types`,
`read_public_decl` reads `type` instead of the target `Corner`; the instance
pass excludes the declaration too. Classify explicitly typed aliases as well
as inferred ones and read their targets. Found while reviewing `cbac28d9`
on 2026-10-31.

### A generic `impl`'s public alias of a member selection is not read for private names

[Private names in public declarations](design.md#private-names-in-public-declarations)
reports a public declaration that names a private type. A public type alias
in a generic `impl` is now read by its written target in several cases, but a
target that selects a member from an instance is not read fully. A private
sibling reached through either `Box(T).Hidden` or `Box(int).Hidden` goes
unreported:

```loke
package shapes;
@(private) Corner :: struct { x: int }
@(public) Box :: struct($T: type) { value: T }
@(public) Plain :: struct { value: int }
impl Plain {
    @(private) Hidden :: Corner;
    @(public) Sibling :: Plain.Hidden; // L0740
}
impl Box($T) {
    @(private) Hidden :: Corner;
    @(public) Sibling :: Box(T).Hidden; // should warn L0740 too
}
```

`read_generic_impl_constants` in [src/private_names.odin](src/private_names.odin)
records a member as a type alias when its value instantiates a generic record
(`instantiates_generic_record`). `Box(T).Hidden` is a selector on such a call,
so it is neither recorded nor walked. A concrete selection can be recognized
as a type, but the syntax walk does not resolve the selected member when the
operand is a call. Recognize a selection from an instantiated generic record
as a type too, and walk its written names, including the selected member.
Found while closing the general case of this gap on 2026-10-31; the concrete
selection was confirmed while reviewing `cbac28d9` the same day, including
with an instance that uses the alias.

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

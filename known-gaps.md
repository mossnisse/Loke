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

### Typed generic aliases still skip targets when their written type is an alias

[Private names in public declarations](design.md#private-names-in-public-declarations)
reads a type alias's target. The fix in `72da8ff0` recognizes a written
`type`, but not a public alias of it, so this declaration produces no
`L0740` for `Corner`, even after instantiation:

```loke
package shapes;
@(private) Corner :: struct { x: int }
@(public) Meta :: type;
@(public) Box :: struct($T: type) { value: T }
impl Box($T) {
    @(public) Inner: Meta : Corner; // should warn L0740 for Corner
}
@(private) use :: proc() { _ = size_of(Box(int).Inner); }
```

`read_generic_impl_constants` in [src/private_names.odin](src/private_names.odin)
only marks a typed constant as an alias when `declared_type` is a
`Type_Type` syntax node. Here it is an identifier, so `read_public_decl`
walks the public `Meta` instead of the target `Corner`; the instance pass
also excludes explicitly typed constants. Recognize a declared type that
resolves to `type`, including its aliases. Confirmed while reviewing
`72da8ff0` on 2026-10-31.

### Generic member aliases of composite types are not recognized as types

[Private names in public declarations](design.md#private-names-in-public-declarations)
reads a public alias's target. A private member alias whose value is a
composite type containing a generic parameter is not classified as a type,
so selecting it from a public alias produces no `L0740`:

```loke
package shapes;
@(public) Point :: struct { x: int }
@(public) Box :: struct($T: type) { value: T }
impl Box($T) {
    @(private) Hidden :: []T;
    @(public) Leak :: Box(T).Hidden; // should warn L0740 for Box.Hidden
}
@(private) use :: proc() { _ = size_of(Box(Point).Leak); }
```

The equivalent selection from a plain `impl` does warn.
`read_generic_impl_constants` in [src/private_names.odin](src/private_names.odin)
only classifies a value that reaches a stand-in for `$T` when it is a
generic-record call. The syntax fallback in `add_named` recognizes records,
enums, interfaces, distinct types, and procedure types, but omits slice,
pointer, array, and map types, unlike `read_public_decl`. Share recognition
of explicit type syntax so `selected_member` sees these member aliases as
types too. Confirmed with the slice case while reviewing `72da8ff0` on
2026-10-31.

### Long chains of member aliases lose warnings for private names

[Private names in public declarations](design.md#private-names-in-public-declarations)
does not limit how many aliases can be followed to determine that a member
names a type. In a generic `impl`, a sufficiently long chain of selections
is not recognized as a type, so its public alias is not checked:

```loke
package shapes;
@(private) Corner :: struct { x: int }
@(public) Box :: struct($T: type) { value: T }
impl Box($T) {
    @(private) H0 :: Box(T).H1;
    @(private) H1 :: Box(T).H2;
    @(private) H2 :: Box(T).H3;
    @(private) H3 :: Box(T).H4;
    @(private) H4 :: Box(T).H5;
    @(private) H5 :: Box(T).H6;
    @(private) H6 :: Box(T).H7;
    @(private) H7 :: Box(T).H8;
    @(private) H8 :: Box(T).H9;
    @(private) H9 :: Corner;
    @(public) Leak :: Box(T).H0; // should warn L0740 for Box.H0
}
```

`selected_member` in [src/private_names.odin](src/private_names.odin) stops
recursing at `depth == 8` even for an acyclic chain. `read_public_decl`
therefore skips `Leak`'s target. A shorter selection such as `Box(T).H8`
does warn. Detect cycles or propagate alias classification until it settles
instead of imposing a depth cutoff. Confirmed while reviewing `72da8ff0`
on 2026-10-31.

### A procedure's analysis panics after one GiB of scratch allocations

The scratch allocator introduced by `e4d3562b` makes the former one-GiB
reservation per arena block a hard limit for the whole arena.
`scratch_commit` in [src/scratch_arena.odin](src/scratch_arena.odin) panics
instead of adding another block. This rejects valid source that the parent
compiler accepts, even when memory is available and the
[provenance precision budgets](design.md#minimum-provenance-precision) are
satisfied. A 53,568-byte procedure fixture with 900 local read-only borrows
and 900 conditionals reproduces it:

```powershell
New-Item -ItemType Directory -Force tests/tmp | Out-Null
$source = @('package main;', 'probe :: proc(flag: bool) -> int { total := 0;')
foreach ($i in 0..899) {
    $source += "n$i := $i; p$i := &n$i;"
}
foreach ($i in 0..899) {
    $source += "if (flag) { total += p$i^; }"
}
$source += 'return total; }', 'main :: proc() { _ = probe(false); }'
$source | Set-Content -Encoding utf8 tests/tmp/scratch_limit.loke
.\lokec.exe tests/tmp/scratch_limit.loke -emit-ll
```

The new compiler exits 1 with `a procedure body's analysis outgrew its
scratch arena reservation`; a fresh build of parent `402c1508` emits LLVM
successfully for the same input. Preserve growth beyond the initial
reservation, for example with additional blocks on the allocation slow path.
Confirmed while reviewing `e4d3562b` on 2026-10-31.

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

# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

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

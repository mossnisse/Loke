# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### Optimized linalg SIMD and scalar transforms can disagree bit for bit

[`core:math/linalg`](standard-library.md#coremathlinalg) promises the same
result bits for its SIMD and scalar formulas. On this Windows x86-64 host,
the existing deterministic regression fails with speed optimization:

```powershell
.\lokec.exe tests/run/lib_linalg_lanes.loke -opt=speed -o tests/tmp/linalg-lanes.exe
.\tests\tmp\linalg-lanes.exe
```

It prints `FAIL a 3 x 3 times a vector is the scalar form` and omits
`all lane checks passed`. The three printed finite-result bit patterns still
match the expected file. The failing loop covers 4,000 deterministic vectors
and matrices, including NaNs, infinities, and signed zeros. Adding diagnostic
printing inside that loop made the failure disappear, so its exact operands
and cause have not yet been isolated; a NaN-bit difference is a hypothesis,
not an established diagnosis. Found in the linalg merge review on 2026-10-30.
Keep the regression and its bitwise comparison until the discrepancy is
understood; do not replace its expected output with the failing result.

### Linalg perspective can overflow with finite projection coefficients

[`core:math/linalg`](standard-library.md#coremathlinalg) accepts finite positive
near planes and finite far planes beyond them, but its direct product can
overflow before division even when the final coefficient is representable:

```loke
package main;
import "core:fmt";
import "core:math/linalg";
main :: proc() {
    p := linalg.Matrix(f32, 4, 4).perspective(1, 1, 10, 1e38, .Zero_To_One);
    fmt.println(p[2, 3]);
}
```

This prints `-inf` instead of a value near `-10`: `far*near` overflows before
division by `near - far`. The other depth ranges and the left-handed variants
use the same products. Found in the linalg merge review on 2026-10-30.
An overflow-safe evaluation order needs to be specified and tested across
CPU and optimization levels, preserving the package's reproducibility contract.

### Linalg Euler extraction loses finite non-unit quaternions at extreme scales

[`to_euler`](core/math/linalg/api.loki) accepts non-unit quaternions, but
squares their components without rescaling:

```loke
package main;
import "core:fmt";
import "core:math";
import "core:math/linalg";
main :: proc() {
    q := math.Quaternion(f64).from_components(1e200, 0, 1e200, 0);
    first, second, third := linalg.to_euler(q, .ZYX);
    fmt.println(first, second, third);
}
```

This prints `0.0 nan 0.0`; replacing both `1e200` components with `1` gives
`0.0 1.5707963267948966 0.0`, the same rotation. Intermediate squares overflow
and the subsequent products produce NaN. Found in the linalg merge review on
2026-10-30. Rescale finite nonzero inputs before these products, with
regressions for large and small scales and every Euler order.

### Constant bit casts cannot construct valid `typeid` values

[Invalid representations](design.md#invalid-representations) makes every
`typeid` bit pattern a value, and
[`unsafe.transmute`](design.md#unsafetransmute) promises compile-time bytewise
conversion for admitted scalar shapes. A `typeid` is a same-sized, trivial
scalar with no borrow, but this program is rejected:

```loke
package main;
import "core:fmt";
import "core:unsafe";
FORGED :: unsafe.transmute(typeid, u64(999999));
main :: proc() { fmt.println(FORGED); }
```

It reports `L0688`, "`unsafe.transmute` has no compile-time meaning from `u64`
to `typeid`". Making `FORGED` a local variable instead succeeds and prints
`999999`. Found reviewing `c885b92d` on 2026-10-29: the runtime path also
preserves and reflects the high-bit and all-ones patterns correctly, but
`fold_transmute`, `const_storage`, and `const_from_storage` in
[check_builtin.odin](src/check_builtin.odin) do not handle `Typeid`.
Implement constant storage for these values and add a regression comparing
constant and runtime bit casts, while preserving the deferred numbering of
symbolic `typeid_of` constants.

### Native path normalization can remove an intermediate link before traversal

[Filesystem operations](standard-library.md#filesystem-operations) says a
link anywhere before the last path element is followed. Ordinary Windows
paths instead normalize `.` and `..` before resolving links, so a junction
followed by `..` can disappear without being followed. In a fresh directory:

```powershell
New-Item -ItemType Directory -Path local,target\child | Out-Null
Set-Content local\marker.txt local -NoNewline
Set-Content target\marker.txt target-parent -NoNewline
New-Item -ItemType Junction -Path local\junction -Target (Resolve-Path target\child).Path | Out-Null
```

```loke
package main;
import "core:fmt";
import "core:fs";
main :: proc() {
    fmt.println(fs.read_text("local/junction/../marker.txt") or_else "error");
}
```

This prints `local`, whereas following the junction before `..` would read
`target/marker.txt` and print `target-parent`. Found reviewing `9c8a17c7` on
2026-10-29. Qualify the new link rule with the ordering of native path
normalization and traversal, including the separate treatment of
extended-length paths, if retaining Windows path semantics. Microsoft's
[path-normalization description](https://learn.microsoft.com/en-us/dotnet/standard/io/file-path-formats#path-normalization)
describes the preprocessing.

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

### A store through a one-pointer-field parameter keeps the old borrow

[Values that contain borrows](design.md#values-that-contain-borrows) says
replacing a carrier stored in a field ends the old borrow in that field.
With a parameter whose record has one pointer field, the old borrow remains
linked to the field, so copying the new value reports `L0641`:

```loke
package main;
Node :: struct { value: int }
One :: struct { head: ^mut Node, count: int }
probe :: proc(p: ^mut One, @(escape=stored) replacement: ^mut Node) {
    old := p^.head;
    p^.head = replacement;
    fresh := p^.head; // L0641, should be allowed
    old^.value = 1;
    fresh^.value = 2;
}
main :: proc() {}
```

The same sequence through a pointer to a local `One` compiles, as does a
parameter whose record has two pointer fields. For one nonempty carrier
path, `prov_caller_slots` in
[src/cfg_provenance.odin](src/cfg_provenance.odin) creates an untyped slot for
the whole record instead of a typed slot at `head`. `caller_replaces` in
[src/borrow.odin](src/borrow.odin) cannot recognize that slot as the field
replaced by the store, so it keeps the old borrow. Preserve the single
carrier path and its type when constructing the caller slot.

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

# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

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

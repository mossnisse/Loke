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

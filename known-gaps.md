# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### An unknown-target owner read loses its actual allocator dependency

[Allocators](design.md#allocators) requires a reset to reject live owners that still refer to
the allocator's storage; a `string` copy shares its allocation. `e08ad0ff` removes the
whole-pointee unnamed-allocator mark in `prov_unknown_target_read` in
[provenance_regions.odin](src/provenance_regions.odin), but does not replace it with the
region of the owner actually loaded. For a read-only carrier in a record parameter, the
known-target lookup and `prov_viewed_region(..., whole = false)` can both return an empty
set. Since `string` contains no allocator handle, the fallback remains empty, and the
caller's returned string loses its genuine backing dependency:

```loke
package main;
import "core:mem";
import "core:strings";
Holder :: struct { allocator: mem.Allocator, text: string }
Reader :: struct { holder: ^Holder }
read_text :: proc(reader: Reader) -> string { return reader.holder^.text; }
caller :: proc(@(allocator_reset) allocator: mem.Allocator) -> int {
    kept: string = "";
    {
        source := Holder{allocator, strings.copy("arena text", allocator)};
        kept = read_text(Reader{&source});
    }
    free_all(allocator); // wrongly accepted while `kept` still shares the allocation
    return int(kept.bytes()[0]);
}
main :: proc() {}
```

The parent of `e08ad0ff` rejects the reset with `L0537`; the reviewed commit and
`dbebf669` accept it, permitting use and cleanup after reset. The same regression occurs
when the loaded value is a `[dynamic]string`: copying its backing array does not copy the
strings' allocations. Keep the loaded owner's actual region distinct from an unrelated
sibling handle, and add rejection cases for shared owners and retained container elements
alongside the accepted integer-array case. Found on 2026-11-06 while reviewing `e08ad0ff`
(P1).

The gap is wider than the sibling handle. A body's parameter gets a region
(`prov_seed_parameter_region`) only when its type is an allocator, an owner, or a view
carrier, so a record parameter holding a carrier, as `reader: Reader` with
`Reader :: struct { holder: ^Holder }`, has none. A read through its carrier then names
nothing: with `Holder` replaced by `Plain :: struct { items: [dynamic]int }`, whose
`items` came from `make(..., allocator)`, returning `reader.holder^.items` is accepted
with no allocator in the record at all. The same holds for `^mut Holder` and for an
`inout reader`, whose loaded alias finds an empty `region_of` to mark as loaded, while a
`reader: ^Reader` pointer parameter is rejected correctly. Seeding a region for such a
parameter and marking the read as loaded would be sound, but a loaded parameter's region
at a call is everything its argument reaches (`prov_reached_regions`), handles included,
which brings back the sibling over-rejection `tests/run/sibling_handle_regions` pins; a
`holder: ^Holder` parameter already has it, so returning `holder^.items` beside the
handle is `L0537` though `items` uses the default allocator. A precise fix needs a
loaded read to say what it read, an owner or a handle, or better its path, as
`Result_Dependencies.param_loads` does for borrows. Found on 2026-11-07 while
investigating this entry.

### A local copy of a carrier retains a sibling allocator's region

[Region tracking](design.md#region-tracking) keeps sibling allocator handles apart from
owners and preserves a pointer's destinations when it is stored in a local. The
`e08ad0ff` fix accepts a direct `return reader.holder^.items`, but a local pointer still
keeps the whole-pointee unnamed-allocator mark. `prov_unknown_target_read` asks
`prov_viewed_region` for `whole = false`, but its symbol branch returns that previously
cached mark unchanged:

```loke
package main;
import "core:mem";
Holder :: struct { allocator: mem.Allocator, items: [dynamic]int }
Reader :: struct { holder: ^Holder }
read_items :: proc(reader: Reader) -> [dynamic]int {
    pointer := reader.holder;
    return pointer^.items;
}
caller :: proc(@(allocator_reset) allocator: mem.Allocator) -> int {
    source := Holder{allocator, [dynamic]int{1}};
    copied := read_items(Reader{&source});
    free_all(allocator); // L0537 for `copied`; both arrays use the default allocator
    return copied[0];
}
main :: proc() {}
```

The local-pointer rejection predates `e08ad0ff` and remains in it and `dbebf669`;
the direct-read control is accepted by those latter snapshots. Preserve the distinction
when recording and forwarding a carrier's viewed regions, rather than only suppressing
the mark on a selector read. Found on 2026-11-06 while reviewing `e08ad0ff` (P3).


# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### A result read through more than four loads reaches nothing

[Procedure result contracts](design.md#procedure-result-contracts) let a result hold what
is read through a parameter at any depth. A summary keeps a parameter's loads to
`CARRIER_DEPTH` (four) in
[carrier_shape.odin](src/carrier_shape.odin), and a result read through a fifth carries no
dependency at the call, so the reset here is accepted although `target` names `a`:

```loke
package main;
import "core:mem";
Two :: struct { p: ^mut [dynamic]int, q: ^mut [dynamic]int }
A :: struct { b: ^B }
B :: struct { c: ^C }
C :: struct { d: ^Two }
E :: struct { a: ^A }
f :: proc(x: ^E) -> ^mut [dynamic]int { return x^.a^.b^.c^.d^.p; }
run :: proc(@(allocator_reset) allocator: mem.Allocator) -> int {
    buffer := [1024]u8{};
    kept := mem.Arena.from_buffer(&mut buffer[:]);
    a := make([dynamic]int, 1, kept.allocator());
    b := make([dynamic]int, 1, kept.allocator());
    two := Two{&mut a, &mut b};
    cc := C{&two};
    bb := B{&cc};
    aa := A{&bb};
    x := E{&aa};
    target := f(&x);
    target^ = make([dynamic]int, 1, allocator);
    free_all(allocator); // wrongly accepted: `a` now holds the allocator's array
    return a[0];
}
main :: proc() {}
```

The same read in `run` itself, `px^.a^.b^.c^.d^.p` with `px := &x`, is rejected with
`L0537`, and so is a call reading through four loads, `x^.a^.c^.d^.p` with
`E :: struct { a: ^B }`. The parent of `b5279ced`
accepts it too, so it predates last-load paths. A result past the last depth a summary
keeps should depend on what that depth reaches, as a deeper local load does. Found on
2026-11-06 while reviewing `b5279ced` (P1).

### An unrelated carrier store forgets what was loaded below a cursor

[Weakening and reborrows](design.md#weakening-and-reborrows) permits a load through
what was loaded below a cursor's current value. `run_loaded_below_event` in
[borrow_loaded_below.odin](src/borrow_loaded_below.odin) clears every such fact on a
carrier store, including one into a separate record that cannot relink the chain:

```loke
package main;
Node :: struct { value: int, next: ^mut Node }
Holder :: struct { p: ^int }
walk :: proc(head: ^mut Node, other: ^mut Holder, @(escape=stored) spare: ^int) {
    cur := head;
    for (i := 0; i < 3; i += 1) {
        cur = cur^.next;
        t := cur^.next;
        other^.p = spare;
        u := t^.next; // L0641, though this still reads below `cur`
        u^.value = 1;
        cur^.value = 2;
    }
}
main :: proc() {}
```

The parent `18885562` accepts this program; `a6097991` and `dbebf669` reject the
load of `t^.next`. The store changes only a read-only integer pointer in `other`,
so `t` remains below `cur`. Once the loop's deeper loads share an analysis slot,
forgetting that fact makes the load appear to compete with the cursor's copy.
Removing the unrelated store, or moving it before `t := cur^.next`, is accepted.

Invalidate facts only where a store may change an anchor or relink the storage
that establishes its below relation; retain them across provably unrelated
stores. Keep the stale-cursor rejection tests alongside this valid-loop case.
Found on 2026-11-06 while reviewing `a6097991` (P2, new over-rejection).

### Providers moved into sibling fields retain each other's regions

[Allocators](design.md#allocators) preserves a provider's identity across a move, and
[region tracking](design.md#region-tracking) keeps independent record fields apart.
`8d9af257` projects the fixed provider tokens when taking or exchanging a field, but
`provider_moved` still joins every incoming provider token at the whole local. The
`prov_provider_region_at` lookup in [provenance_regions.odin](src/provenance_regions.odin)
includes that entire set regardless of the requested field:

```loke
package main;
import "core:mem";
Pair :: struct { first: mem.Arena, second: mem.Arena }
main :: proc() {
    first := mem.Arena.init();
    second := mem.Arena.init();
    pair := Pair{move(first), move(second)};
    xs := make([dynamic]int, 1, pair.second.allocator());
    taken := exchange(inout pair.first, mem.Arena.init());
    drop(taken); // L0537 for `xs`, though only the second arena backs it
    _ = xs[0];
}
```

Replacing the first three statements with
`pair := Pair{mem.Arena.init(), mem.Arena.init()};` is accepted by the reviewed commit.
The same false rejection occurs with `unsafe.take` followed by reinitializing the first
field, and when the fields receive the providers through later assignments. Preserve
the destination path of moved-in tokens and project them alongside the fixed tokens.
This is a remaining precision gap, not a new regression: the moved-field case rejects
on the parent of `8d9af257`, that commit, and `dbebf669`. Found on 2026-11-06 while
reviewing `8d9af257` (P3).

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

### A local pointer to a slice blames an untouched carrier's target

[Region tracking](design.md#region-tracking) requires a pointer stored in a local to preserve
the destinations of the same pointer passed directly, and
[minimum provenance precision](design.md#minimum-provenance-precision) keeps a record's carrier
leaves apart. A call through a local pointer to a slice instead attributes a store through
`second` to `first` too:

```loke
package main;
import "core:mem";
Pair :: struct { first: ^mut [dynamic]int, second: ^mut [dynamic]int }
store :: proc(pairs: ^mut []Pair, allocator: mem.Allocator) {
    pairs^[0].second^ = make([dynamic]int, 1, allocator);
}
caller :: proc(@(allocator_reset) allocator: mem.Allocator) -> int {
    buffer := [256]u8{};
    kept := mem.Arena.from_buffer(&mut buffer[:]);
    a := make([dynamic]int, 1, kept.allocator());
    b := make([dynamic]int, 1, kept.allocator());
    pairs := []Pair{Pair{&mut a, &mut b}};
    pointer := &mut pairs;
    store(pointer, allocator);
    drop(b);
    free_all(allocator); // L0537 for `a`; should be accepted
    return a.len();
}
main :: proc() {}
```

Replacing the pointer declaration and call with `store(&mut pairs, allocator)` is accepted.
The local-pointer rejection predates `ac656b11` and remains in that commit and `dbebf669`;
it is an existing precision gap, not a regression from the reviewed commit.
Found on 2026-11-06 while reviewing `ac656b11` (P3).


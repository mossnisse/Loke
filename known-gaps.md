# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

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

### A direct copied loop still copies its source

[Iteration adapters](design.md#iteration-adapters) says a `foreach` written directly over an
adapter makes no copy of its source, and the new inline
[copy-cost report](design.md#copy-cost-diagnostics) recommends that form. For `copied()`,
however, `peel_resolved_adapter` in [iteration_adapters.odin](src/iteration_adapters.odin)
stops before peeling the call. This program makes the copy and receives `L0507` together
with the advice that the very form already written makes none:

```loke
package main;
Cursor :: struct { at: int }
impl Cursor { next :: proc(self: inout Cursor) -> Option(^mut int) { return .none; } }
View :: struct { bytes: [1024]u8 }
impl View {
    Element :: int;
    Iterator :: Cursor;
    Mut_Iterator :: Cursor;
    iter :: proc(self: ^) -> Cursor { return {0}; }
    iter_mut :: proc(self) -> Cursor { return {0}; }
}
main :: proc() {
    source: View = {};
    foreach (value in source.copied()) { _ = value; }
}
```

`dbf1b4c5` and `dbebf669` report a 1024-byte iteration-adapter copy and suggest a
`foreach` over the adapter call. The emitted adapter loads and stores the complete
1024-byte `View`, so this is a real copy, not merely a report left behind after peeling.
The source copy predates the reviewed commit; its new inline report introduces this
unusable advice for plain views, and the older allocating-copy advice has the same
limitation. Avoid the source copy for a directly used `copied()` as the specification
requires, and add a direct `copied()` case beside the peeled `indexed()` tests.
Found on 2026-11-06 while reviewing `dbf1b4c5` (P2).

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

### A procedure contract ignores loaded parameter regions

[Procedure result contracts](design.md#procedure-result-contracts) permit a
substitute only when its region dependencies fit the destination contract.
`ecce89f3` distinguishes a parameter's own storage from what its carriers reach
with `Region_Set.loaded`, but `region_contract_within` in
[proc_contracts.odin](src/proc_contracts.odin) compares only `params`. An inferred
contract that returns an owner's direct field therefore accepts a procedure
that returns an owner reached through another carrier. The call then uses the
narrower contract and loses that owner's allocator dependency:

```loke
package main;
import "core:mem";
import "core:strings";
Leaf :: struct { text: string }
Input :: struct { text: string, next: ^mut Leaf }
own :: proc(input: ^Input) -> string { return input^.text; }
deep :: proc(input: ^Input) -> string { return input^.next^.text; }
Own :: type_of(own);
run :: proc(@(allocator_reset) allocator: mem.Allocator) -> int {
    kept: string = "";
    {
        leaf := Leaf{strings.copy("arena text", allocator)};
        input := Input{"default text", &mut leaf};
        callback: Own = deep; // should be L0645
        kept = callback(&input);
    }
    free_all(allocator); // wrongly accepted while `kept` still depends on it
    return int(kept.bytes()[0]);
}
main :: proc() {}
```

The program compiles in `ecce89f3` and in the later committed snapshot
`dbebf669`, allowing a read after the arena reset; the parent `f8737e02` reports
`L0537`. Requiring `a.loaded & ~b.loaded == 0` alongside the existing parameter
subset check rejects the incompatible conversion with `L0645`. A matching
`type_of(deep)` contract retains the dependency and reports `L0537`, and a
matching `Own` substitution remains valid. Apply this check to result and
written-region bounds, which share the helper.

The separate omission of `Region_Set.loaded` from replay weighting, also
introduced by `ecce89f3`, is already fixed by `dbf1b4c5`; that correction alone
still accepts this conversion. Found on 2026-11-06 while reviewing `ecce89f3`
(P1).

### A result read through a pointer to a temporary keeps the temporary

A [result contract](design.md#procedure-result-contracts) that reads a value stored behind a
pointer argument substitutes only that value's borrows, at every nesting depth, so
`name_one(x: ^View) -> string_view { return x^.name; }` gives a result that borrows what the
`View` holds and not the `View`. Where the `View` is a
[temporary](design.md#temporaries-and-procedure-boundaries) the caller keeps the temporary's loan
in the result too, so a later use is rejected as if the result borrowed it:

```loke
package main;
import "core:fmt";
View :: struct { name: string_view }
name_one :: proc(x: ^View) -> string_view { return x^.name; }
main :: proc() {
    text := "kept";
    s := name_one(&View{text});
    fmt.println(s); // L0513: used after this temporary has ended; should print "kept"
}
```

The same holds for a value a `..^View` pack lends from a temporary. The same call on a named
`View` local is accepted. The likely cause is that the temporary's root has no local content for
the result's load to read, so the load stands for the temporary itself. Found on 2026-11-06
with the compiler built from `dbebf669`, while adding the rule that a lending pack is kept only
for the call.

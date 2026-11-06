# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

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

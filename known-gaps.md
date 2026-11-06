# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

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

### Deque's fallible append of several borrowed values panics while copying them

The [growable container contract](standard-library.md#conventions-of-the-growable-containers)
requires `try_append` to return an element-copy allocation failure, as
[container insertion](design.md#container-insertion) copies a borrowed place only on success.
Several borrowed values written one by one select the variadic `try_append_copied` in
[deque.loke](core/container/deque.loke), and a [variadic pack](design.md#variadic-parameters)
receives a copy, made by the caller before the procedure runs. A failure in that copy applies
the default allocator's failure policy and panics instead of returning `.err`:

```loke
package main;
import "core:container";
import "core:fmt";
Item :: struct { id: int }
impl Item {
    duplicate :: hook(copy) proc(self, allocator: Allocator) -> Result(Item, Allocator_Error) {
        return .err({});
    }
}
main :: proc() {
    q: container.Deque(Item) = {};
    a := Item{1};
    b := Item{2};
    result := q.try_append(a, b); // panics; should return .err
    fmt.println(result != .ok, q.len());
}
```

One borrowed value selects `try_append_one_copied`, and a lone spread `q.try_append(..items)`
lends its elements, so both copy inside and return the failure. A built-in dynamic array's
`try_append(a, b)` returns it too. The language now has a pack that lends, `..^T`, but
`try_append_copied` cannot take one yet: it is written `@(escape=stored)` so that what a copy
carries may stay in the deque, and a level bounds every carrier of the parameter, the pack's own
pointers included, so a call would keep `a` and `b` borrowed as long as `q` lives. Using it needs
a rule that a lending pack's pointers are kept only for the call, with the level bounding what the
values carry, as on a `value: T` parameter, and the caller's pack contract to tell a lent
element's borrow from what it carries. Reproduced with the compiler built from `1cefee9c` on
2026-11-05 while reviewing that commit (P2); narrowed on 2026-11-06.

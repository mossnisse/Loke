# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

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

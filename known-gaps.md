# Known gaps

Divergences between the specification documents and the shipped compiler, with
a minimal reproduction for each. A gap leaves this file when the compiler
matches the specified behavior — not when the spec is reworded to match the
compiler, unless the rewording is the intended fix.

## Gaps

### A view of a lent `foreach` element is rejected on return

[Borrowing iteration](design.md#borrowing-iteration) says a lent element names
the source's own storage and carries the source's provenance. A view of it
returned through a borrowed parameter should therefore borrow that parameter.
Instead both procedures below report L0526: the first names the element `item`
as a local, and the second names the slice parameter `items` itself, as if
iterating it borrowed the parameter's frame slot rather than what it views.

```loke
package main;
import "core:fmt";
import "core:strings";
Doc :: struct { items: [dynamic]string }
from_pointer :: proc(d: ^Doc) -> string_view {
    foreach (item in d.items) { return item; }
    return "";
}
from_slice :: proc(items: []string) -> string_view {
    foreach (item in items) { return item; }
    return "";
}
main :: proc() {
    d := Doc{make([dynamic]string, 0, 1)};
    d.items.append(strings.copy("first"));
    fmt.println(from_pointer(&d), from_slice(d.items[:]));
}
```

The expected output is `first first`. Indexing, `return d.items[0];`, works.
The same false rejection for a switch payload bound over a place was fixed by
treating such a binding's root as the subject's storage in the escape and
retention checks (`root_names_source` in `src/borrow.odin`); the `foreach`
binding does not reach that test, and the slice case is rooted elsewhere.

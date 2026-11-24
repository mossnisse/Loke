# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### A result allocated from an `inout` arena outlives it

Under [Allocator regions and region
provenance](design.md#allocator-regions-and-region-provenance), a call's result
allocated through a provider the caller lent is in that provider's region. The
compiler gives the result the region backing the arena instead, so the arena
ends while the list is live with no diagnostic. Allocating in `main` itself
reports L0537.

```loke
package main;
import "core:mem";
make_list :: proc(arena: inout mem.Arena) -> [dynamic]int { return make([dynamic]int, 0, 4, arena.allocator()); }
main :: proc() {
    list: [dynamic]int;
    {
        arena := mem.Arena.init();
        list = make_list(inout arena);
    }
    list.append(1);
}
```

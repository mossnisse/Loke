# Known gaps

Divergences between the specification documents and the shipped compiler, with
a minimal reproduction for each. A gap leaves this file when the compiler
matches the specified behavior — not when the spec is reworded to match the
compiler, unless the rewording is the intended fix.

## Gaps

### Growing a container through a pointer during its own traversal compiles

[Borrowing iteration](design.md#borrowing-iteration) says the source cannot be
mutated or invalidated while the traversal is live. Over a local container,
`items.append(item)` inside the loop is L0512. Through a pointer it compiles,
and the append can reallocate the buffer the loop is still reading:

```loke
package main;
grow :: proc(items: ^mut [dynamic]int) {
    foreach (item in items^) {
        items.append(item); // should be rejected
    }
}
main :: proc() {}
```

In [src/cfg.odin](src/cfg.odin), `walk_flow_foreach` finds no place for
`items^`, so `prov_iterate` takes no iterator loan, and
`prov_reborrow_traversal` reborrows only mutable carriers among the loaded
elements, not the `^mut` the source is reached through. Nothing the loop head
keeps live guards the pointer. A view of an element used after the loop is
already rejected, since the binding borrows what the pointer names.

# Known gaps

Divergences between the specification documents and the shipped compiler, with
a minimal reproduction for each. A gap leaves this file when the compiler
accepts the program the spec describes — not when the spec is reworded to match
the compiler, unless the rewording is the intended fix.

## Gaps

### A `foreach` cannot destructure a record with padding

[design.md "Destructuring"](design.md#destructuring) applies to `foreach`
bindings, and a `_` padding field fills no binding:

```odin
package main;
Padded :: struct { first: u8, _: [7]u8, last: u8 }
main :: proc() {
    items := [1]Padded{};
    foreach (first, last in items) {}
}
```

Actual: L0459 says `Padded` has padding fields. Binding the whole element and
selecting its fields works, as does `first, last := items[0]`. The `foreach`
pattern walkers in `iterate.odin` and `emit_llvm_iteration.odin` pair bindings
with fields by position; they must map each binding to its named field's slot,
as declaration destructuring does.

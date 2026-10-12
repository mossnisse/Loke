# Known gaps

Divergences between the specification documents and the shipped compiler, with
a minimal reproduction for each. A gap leaves this file when the compiler
accepts the program the spec describes — not when the spec is reworded to match
the compiler, unless the rewording is the intended fix.

## Gaps

### A grouped `<` is not used to sort

[Sorting slices](design.md#sorting-slices) sorts by the element type's `<`, but
the sort looks only for a single `operator(<)` procedure and misses one declared
as a group. This program prints `[1, 2, 3]`; it should print `[3, 2, 1]`, the
order `Reverse`'s own `<` gives, as `a < b` on two `Reverse` values already does.

```odin
package main;
import "core:fmt";
Reverse :: distinct int;
impl Reverse {
    reversed :: proc(a, b: Reverse) -> bool { return int(b) < int(a); }
    less :: operator(<) proc { reversed };
}
main :: proc() {
    values: [dynamic]Reverse = {1, 3, 2};
    values.sort();
    fmt.println(values);
}
```

### A grouped `==` is not used for a part

[Comparison operators](design.md#comparison-operators) compares a part whose
type declares its own `==` by that operator. A `==` declared as a group is
missed, so the part is compared structurally instead. This program prints
`true false`; it should print `true true`.

```odin
package main;
import "core:fmt";
Loose :: distinct int;
impl Loose {
    same :: proc(a, b: Loose) -> bool { return true; }
    equal :: operator(==) proc { same };
}
main :: proc() {
    fmt.println(Loose(1) == Loose(2), [1]Loose{1} == [1]Loose{2});
}
```

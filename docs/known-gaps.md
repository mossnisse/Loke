# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### A bounds check waits for a later setter destination's indices

[Evaluation order](design.md#evaluation-order) prepares destinations from left
to right. In a multiple assignment through `operator([]=)`, an ordinary
destination's bounds check runs after every setter destination's receiver and
indices are evaluated, even one to its right.

```loke
package main;
import "core:fmt";

Grid :: struct { cells: [3]int }
impl Grid {
    get :: operator([]) proc(self: Grid, key: int) -> int { return self.cells[key]; }
    set :: operator([]=) proc(self: inout Grid, key: int, value: int) { self.cells[key] = value; }
}
key :: proc() -> int { fmt.println("key"); return 0; }
main :: proc() {
    g := Grid{};
    a := [2]int{};
    i := 2;
    a[i], g[key()] = 7, 8;
}
```

The program prints `key` before the panic. The checker's lowering binds each
setter destination's indices to temporaries, and the final assignment then
prepares the ordinary places. Binding the ordinary place by address would order
the check but hold a mutable borrow across the later destinations.

### A compound assignment cannot view its operator's result

[Operator declarations](design.md#operator-declarations) define `x op= y` as
`x = x op y`. When the operator's result converts to the destination as a view
or a `dyn proc`, the written assignment keeps the temporary result alive, but the
compound form reports `L0417`.

```loke
package main;

Tag :: struct { n: int }
concat :: operator(+) proc(s: string_view, t: Tag) -> string { return "x"; }

main :: proc() {
    s: string_view = "a";
    s += Tag{1};
    _ = s;
}
```

`s = s + Tag{1};` compiles. Compound assignment needs the assignment's temporary
extension. [Regression](../tests/err/compound_fallback_borrow.loke)

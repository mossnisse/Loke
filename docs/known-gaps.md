# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### An `inout` index destination waits for a later setter destination's indices

[Evaluation order](design.md#evaluation-order) prepares destinations from left
to right. In a multiple assignment through `operator([]=)`, a destination
reached through a user `operator([])` returning `inout` calls it after every
setter destination's receiver and indices are evaluated, even one to its right.

```loke
package main;
import "core:fmt";

Grid :: struct { cells: [3]int }
impl Grid {
    get :: operator([]) proc(self: Grid, key: int) -> int { return self.cells[key]; }
    set :: operator([]=) proc(self: inout Grid, key: int, value: int) { self.cells[key] = value; }
}
Cells :: struct { cells: [3]int }
impl Cells {
    at :: operator([]) proc(self: inout Cells, key: int) -> inout int { fmt.println("at", key); return inout self.cells[key]; }
}
key :: proc() -> int { fmt.println("key"); return 0; }
main :: proc() {
    g := Grid{};
    h := Cells{};
    h[1], g[key()] = 7, 8;
}
```

The program prints `key` before `at 1`. The checker's lowering binds each
setter destination's indices before its last statement prepares the other
places. A built-in element is checked in its turn by a `checks_bounds`
statement, but preparing this one twice would call `at` twice. Binding its
address in its turn would hold a mutable borrow of `h` while the later
destinations' receivers and indices are evaluated, so a read of `h` among them
would conflict with it.

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

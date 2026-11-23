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
address in its turn would hold a mutable borrow of `h` across the later
destinations, so that `h, h[1], g[key()] = Cells{}, 7, 8;` would be `L0512`.

### A multiple assignment writes an element of the buffer an earlier write replaced

[Evaluation order](design.md#evaluation-order) prepares every destination
before any write, so `d[1]` below names an element of the buffer `d` holds
before the statement. The first write replaces `d` and drops that buffer, and
the second stores into the dropped buffer. The program prints `[5, 6]`.

```loke
package main;
import "core:fmt";

main :: proc() {
    d := [dynamic]int{1, 2};
    d, d[1] = [dynamic]int{5, 6}, 9;
    fmt.println(d);
}
```

The same steps written apart, `p := &mut d[1]; d = [dynamic]int{5, 6}; p^ = 9;`,
are `L0512`. A fixed array's element keeps its place when the array is
replaced, so `a, a[i] = b, 9;` is sound.

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

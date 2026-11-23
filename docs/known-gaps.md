# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### A field's name in an argument literal can stop a returned transfer

[Returned constructions](design.md#returned-constructions) transfers an
operand the returned value names once. The compiler counts the names before
checking, when a literal passed to a call has no type yet, so its bare key
`s` may name the local `s` as a map key or be a field's name. It counts such a
key as a use, so `s` is copied:

```loke
package main;
import "core:strings";

Pair :: struct { s: string, n: int }
Options :: struct { s: int }
width :: proc(o: Options) -> int { return o.s; }

make_pair :: proc() -> Pair {
    s := strings.repeat("ab", 3);
    return Pair{s, width({s = 2})};   // `s` is copied, though named once
}
main :: proc() { _ = make_pair(); }
```

The program runs, retaining and releasing the string where the specification
moves it; a `hook(copy)` would run. A move-only local is moved, as specified.
Counting after checking needs the transfer decided once the whole returned value
is checked, not as each operand is.

### `caller_location()` in a computed default names the declaration

[`caller_location()`](design.md#caller_location) names the call that omits a
default. A default the compiler folds, such as `caller_location().line + 100`,
does. One it cannot fold names the declaration.

```loke
package main;
import "core:fmt";

offset := 0;
report :: proc(line := offset + caller_location().line) -> int { return line; }
main :: proc() {
    fmt.println(report());
}
```

The program prints `5`, the declaration's line, instead of `7`. The emitter and
evaluator find a default only by its identity with the declaration's syntax, so
a call-site copy would need a per-call marker.

### A multiple assignment through a setter writes before its other destinations are prepared

[Evaluation order](design.md#evaluation-order) prepares every destination before
any write. A destination that calls `operator([]=)` is written while the
destinations after it are still unprepared.

```loke
package main;
import "core:fmt";

Grid :: struct { cells: [3]int }
impl Grid {
    get :: operator([]) proc(self: Grid, key: int) -> int { return self.cells[key]; }
    set :: operator([]=) proc(self: inout Grid, key: int, value: int) { self.cells[key] = value; }
}
main :: proc() {
    g := Grid{};
    first := [2]int{1, 2};
    second := [2]int{3, 4};
    s := first[mut :];
    s, g[0], s[1] = second[mut :], 7, 9;
    fmt.println(first, second);
}
```

The program prints `[1, 2] [3, 9]`: `s[1]` writes into the slice assigned to `s`
by the same statement. Without `g[0]` it prints `[1, 9] [3, 4]`. Likewise, in
`g[0], a[i] = 7, 8;` with `i` out of bounds the setter runs before the bounds
check panics. Fixing both moves the setter call into the ordinary assignment's
destination preparation in the emitter, control-flow graph, and evaluator.

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

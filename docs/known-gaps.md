# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### A compound fallback reads its destination before the right operand

[Evaluation order](design.md#evaluation-order) evaluates a compound
assignment's destination place, then its right operand, and only then performs
the operation, which reads the destination. Through a binary operator
fallback, compiled code reads the destination before the right operand.

```loke
package main;
import "core:fmt";

Tag :: struct { n: int }
V :: struct { n: int }
add :: operator(+) proc(v: V, t: Tag) -> V { return {v.n + t.n}; }
bump :: proc(v: inout V) -> Tag { v.n = 100; return {1}; }
run :: proc() -> int {
    v := V{1};
    v += bump(inout v);
    return v.n;
}
AT_COMPILE :: run();
main :: proc() {
    fmt.println(AT_COMPILE, run());
}
```

The program prints `101 2`: compile-time evaluation reads `v` after `bump`, and
the compiled code before it. `emit_operator_call` loads its `left_place` before
it evaluates the other operands. A fallback whose result its local destination
views is lowered to `x = x op y` with `Expr_Binary.right_first` set, and reads in
the specified order.

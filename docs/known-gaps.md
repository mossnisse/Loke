# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

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

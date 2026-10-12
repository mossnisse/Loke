# Known gaps

Divergences between the specification documents and the shipped compiler, with
a minimal reproduction for each. A gap leaves this file when the compiler
accepts the program the spec describes — not when the spec is reworded to match
the compiler, unless the rewording is the intended fix.

## Gaps

### A `foreach` binding can borrow a packed field

[design.md "@(packed)"](design.md#packed) makes a packed field unaddressable,
and [Borrowing iteration](design.md#borrowing-iteration) says packed fields
cannot supply element pointers. A `foreach` binding names the element in place
without `&`, so the check that rejects `&value.field` never sees it. Each loop
below compiles and hands out a pointer that may be misaligned; each should be
`L0614`, as the same borrow through a switch case binding is.

```odin
H :: struct @(packed) { pad: u8, arr: [2]i32 }
P :: struct @(packed) { pad: u8, n: i32 }
read :: proc(x: ^i32) -> i32 { return x^; }

main :: proc() {
	h := H{1, {2, 3}};
	foreach (x in h.arr) { read(&x); }
	foreach (&mut x in h.arr) { x += 1; }
	ps := [1]P{{1, 2}};
	foreach (pad, n in ps) { read(&n); }
}
```

# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### A reserved loan through an index that calls, or through a map element

[Weakening and reborrows](design.md#weakening-and-reborrows) reserves the
mutable loan an argument takes for its call until the call starts, so the later
arguments may read the place. The compiler takes the loan where the argument is
evaluated, as it did before the rule, in two forms:

```loke
package main;

Row :: struct { flag: bool }
Counter :: struct { n: int }

impl Row { set :: proc(self: inout, flag: bool) { self.flag = flag; } }

poke :: proc(c: ^mut Counter, n: int) { c^.n = n; }
pick :: proc() -> int { return 0; }

// The receiver's place is reached through a view or a pointer, and an index on
// the way calls a procedure.
indexed :: proc(rows: []mut Row) {
	rows[pick()].set(rows[0].flag);   // L0641, should be accepted
}

// The carrier is read through a map element.
mapped :: proc(m: ^mut map[int]^mut Counter) {
	poke(m^[1], m^[1]^.n);            // L0641, should be accepted
}

main :: proc() {}
```

Both are rejected with `L0641`. `rows[0].set(rows[1].flag)` and the same calls
on a local container are accepted. To take the loan when the call starts, the
checker walks the place a second time without evaluating it
(`prov_place_reservable` in `provenance_places.odin`); it does not yet do that
for an index that may run code or for a map lookup. A local for the index, or
for the value read, makes either call compile.

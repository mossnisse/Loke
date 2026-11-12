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

### An `impl` block on a procedure type ahead of a block its subject's bound needs

[when statement](design.md#when-statement) lets file-scope declarations appear
in any order. The compiler declares most `impl` blocks without resolving their
subject, so those may be written anywhere: a block on a generic application or
on an alias of one, and a block whose subject is a type's name, or an alias's,
under pointers, slices, dynamic arrays, maps, and arrays of a literal length.
A subject written any other way is resolved to declare its block: a procedure
type, an anonymous record or union, a `dyn` view, an array whose length is a
named constant, or a generic application inside one of the forms above. Those
that name nothing this package declares go first. The rest are declared in
file-name order and then source order, and one that instantiates a generic
asks the generic's bounds on the spot:

```loke
package main;

Sized :: interface($T: type) {
	slot size: proc(self) -> int;
}

Box :: struct($T: type) where Sized(T) { value: T }

Point :: struct { x, y: int }

impl []Box(proc(p: Point) -> int) {   // L0406, should be accepted
	total :: proc(self) -> int { return self.len(); }
}

impl proc(p: Point) -> int {
	size :: proc(self) -> int { return 1; }
}

main :: proc() {}
```

The first block is reported as not naming a type, because the block on
`proc(p: Point) -> int` is not declared when `Box(proc(p: Point) -> int)` is
instantiated, so `Sized` does not hold. Both subjects have to be of the kind
that is resolved, and the one supplying the method has to name a type of this
package: with `proc(value: int) -> int` in both, or with the second block
written first, the program compiles. Trying again once every block is declared
is not possible as the checker stands, since a rejected instance stays cached
and a declaration checked on the way is settled (`begin_settling` in
`speculation.odin`); the fix is to make a procedure type and the other forms
readable without resolving what they name, as `resolve_type_shell` in
`check_types.odin` reads the rest.

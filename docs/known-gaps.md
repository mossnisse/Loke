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

### An `impl` block whose subject instantiates a generic ahead of a block its bound needs

[when statement](design.md#when-statement) lets file-scope declarations appear
in any order. The compiler declares the `impl` blocks on a type named outright,
or on an alias of one, before it resolves any other subject, so those may be
written anywhere. The remaining blocks are declared in file-name order and then
source order, each by resolving its subject, and a subject that instantiates a
generic asks the generic's bounds on the spot:

```loke
package main;

Sized :: interface($T: type) {
	slot size: proc(self) -> int;
}

Box :: struct($T: type) where Sized(T) { value: T }

Slice_Box :: Box([]int);              // L0444, should be accepted

impl Slice_Box {
	twice :: proc(self) -> int { return self.value.size() * 2; }
}

impl []int {
	size :: proc(self) -> int { return self.len(); }
}

main :: proc() {
	assert(Slice_Box{[]int{1, 2, 3}}.twice() == 6);
}
```

`[]int` is reported as not satisfying `Sized([]int)`, because `impl []int` is
not declared when `impl Slice_Box` resolves `Box([]int)`. The block that
supplies the method has a subject that is not a bare type name (a slice, a
pointer, an array, a procedure type, `pkg.Type`, or an alias of one of those),
and the block that needs it has a subject that instantiates the generic.
Writing `impl []int` first, or in a file that sorts first, compiles. Declaring a
block without resolving its subject is what `impl_subject_shell` in `impl.odin`
does for a type named outright; these subjects have no shell to stand in for
them, so the fix is to keep a bound unasked until every block of the package is
declared.

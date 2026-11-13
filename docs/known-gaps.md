# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### A switch over a place whose index calls suspends the whole view

[Switch ownership](design.md#switch-ownership) has a switch over a place borrow
that place, and [Places and overlap](design.md#places-and-overlap) keeps two
fields of an element apart whichever element it is. When the subject is reached
through an index that calls a procedure, the compiler suspends the whole view
for as long as a payload binding is in use:

```loke
package main;

Node :: struct { value: int }
List :: struct { first: Option(^mut Node), cells: [2]int }

at :: proc() -> int { return 0; }
bump :: proc(n: ^mut int) { n^ += 1; }

called :: proc(s: []mut List) {
	switch (s[at()].first) {
	case .some(node):
		bump(&mut s[at()].cells[1]);   // L0641, should be accepted
		node^.value = 1;
	case .none:
	}
}

main :: proc() {}
```

`s` is reported as mutably reborrowed by the subject. With `s[k]` for a
parameter `k` in both places the procedure compiles, and so do a copy out of
`s[at()].head`, a borrow of `s[at()].count`, and a slice or traversal of
`s[at()].cells` beside the same use. An index that may run a program's code is
evaluated after the view was read, so the view is captured as it was
(`prov_capture` in `cfg_provenance.odin`); the capture of a mutable view is a
mutable reborrow of all of it, which the binding then extends, where a place
loan of the element's `first` would do. `borrow_matrix` in
`tests/borrow_matrix_test.odin` leaves the place form out for this reason
(`RESERVED_PLACES`). A local for the index makes the switch compile.
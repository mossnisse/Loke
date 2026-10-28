# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### A store through a chain of local pointers does not suspend a copy below it

[Weakening and reborrows](design.md#weakening-and-reborrows) says a mutable
reborrow suspends all use of its source until its last use. A pointer copied
out two pointers away from local storage still compiles beside a store through
the place it was copied from, leaving two mutable paths to one value in use:

```loke
package main;
Node :: struct { value: int }
Pair :: struct { a: ^mut Node, b: ^mut Node }
main :: proc() {
    first := Node{1};
    second := Node{2};
    pair := Pair{&mut first, &mut second};
    held := &mut pair;
    p := &mut held;
    node := p^^.a;
    p^^.a^.value = 3; // should be rejected
    node^.value = 4;
}
```

The copy reborrows `pair.a`, the local storage its load resolved to, but the
store reports a use of only `p`, the outermost carrier
(`prov_retain_through_carrier` in
[src/cfg_provenance.odin](src/cfg_provenance.odin)), and does not load
`p^^.a` on the way. Reading the place, as `p^^.a^.value + 1`, is rejected, and
so is the same store through a pointer parameter.

### Walking a list through a `switch` binding is rejected

[Switch ownership](design.md#switch-ownership) lets a binding over a place
view the payload, so `cur = next` should move a cursor along a list. In a loop
it is rejected with `L0641`, naming no variable:

```loke
package main;
Node :: struct { value: int, next: Option(^mut Node) }
walk :: proc(start: ^mut Node) {
    cur := start;
    for (i := 0; i < 3; i += 1) {
        cur^.value += 1;
        switch (cur^.next) {      // L0641: `` cannot be used here
        case .some(next): cur = next;
        case .none: return;
        }
    }
}
main :: proc() {}
```

The subject's payload, a temporary loaded through `cur`, is reborrowed by
`next` and so by `cur`, and the next pass's load of the same temporary meets
that reborrow still in use. `cur = cur^.next` with `next: ^mut Node` compiles.

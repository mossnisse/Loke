# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### A `switch` binding of a pointer payload does not suspend the subject

[Weakening and reborrows](design.md#weakening-and-reborrows) says a copy of a
mutable carrier is a reborrow that suspends its source until its last use.
Binding the `^mut` payload of a subject read through a pointer leaves the
subject usable while the binding is, so two mutable pointers to one node are
in use at once:

```loke
package main;
Node :: struct { value: int, next: Option(^mut Node) }
twice :: proc(cur: ^mut Node) {
    switch (cur^.next) {
    case .some(a):
        b := cur^.next; // should be rejected
        a^.value = 1;
        switch (b) { case .some(c): c^.value = 2; case .none: }
    case .none:
    }
}
main :: proc() {}
```

Copying the subject instead, as `first := cur^.next;` before `b := cur^.next;`,
is rejected with `L0641`. The binding takes its view from
`prov_subject_view` in [src/cfg_provenance.odin](src/cfg_provenance.odin),
which for a subject read through a carrier returns that carrier's slots
without reborrowing them, as `prov_borrow_place` does for `&cur^.next`.

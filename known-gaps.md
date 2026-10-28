# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### A switch over a place reached through a pointer does not borrow the place

[Switch ownership](design.md#switch-ownership) says a switch over a place
borrows it while a payload binding is in use. Over a local the binding keeps
that borrow, so writing the subject meanwhile is rejected with `L0511`; over a
place reached through a pointer, a store into the subject or a call that may
write it compiles, and the binding goes on reading a payload that is no longer
there:

```loke
package main;
Node :: struct { value: int }
Holder :: struct { first: Option(^mut Node) }
clear :: proc(h: ^mut Holder) { h^.first = .none; }
peek :: proc(h: ^mut Holder) -> int {
    switch (h^.first) {
    case .some(node):
        clear(h);  // should be rejected, as is `h^.first = .none;`
        return node^.value;
    case .none:
    }
    return 0;
}
main :: proc() {}
```

The binding views the subject through the carriers it was read through
(`prov_subject_view` in [src/cfg_provenance.odin](src/cfg_provenance.odin)),
which records no loan of the storage they name, and a store or call through a
pointer checks no loan by path either. A read-only reborrow of `h`, as
`&h^.first` takes, rejects both forms here, but also a second switch over
`h^.first` and a store through a sibling pointer, as `h^.other^.value = 2`,
beside the binding, and it reaches nothing through a pointer loaded on the
way, as `p^` in `switch (p^^.first)`. The generated matrix in [tests/borrow_matrix_test.odin](tests/borrow_matrix_test.odin)
pins the call form (`matrix_known_gap`).

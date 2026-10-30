# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### Multiple assignment still rereads carriers stored in fields or whole records

[Evaluation order](design.md#evaluation-order) evaluates every destination
before any write, so the second destination below is `x.head`, reached
through the original `holder.pointer`:

```loke
package main;
Node :: struct { value: int }
Pair :: struct { head: ^mut Node, tail: ^mut Node }
Outer :: struct { pointer: ^mut Pair }
main :: proc() {
    a := Node{1}; b := Node{2}; c := Node{3}; d := Node{4};
    x := Pair{&mut a, &mut b};
    y := Pair{&mut c, &mut d};
    holder := Outer{&mut x};
    holder.pointer, holder.pointer^.head = &mut y, holder.pointer^.tail;
    h := x.head;
    b.value = 7; // accepted, should be L0511: h points at b
    h^.value = 1;
}
```

This compiles with `5322493c`. Writing
`holder.pointer^.head = holder.pointer^.tail; holder.pointer = &mut y;`
instead reports `L0511` at `b.value = 7`. Replacing the multiple assignment
with `holder, holder.pointer^.head = Outer{&mut y}, holder.pointer^.tail;`
also compiles incorrectly.

`prov_assign` in [cfg_provenance.odin](src/cfg_provenance.odin) gathers
`written` only from bare identifiers for which `prov_slot_for_symbol`
returns one carrier slot. A field assignment contributes none, and neither
does a bare identifier holding a whole record. Destination preparation is
conditional on that list being nonempty, so these stores still read their
carriers after the first write. Prepare all multiple-assignment destinations
before writes, and preserve the carrier contents that field or aggregate
stores can replace. Cover both field and whole-record replacement. This is
a remaining unsound case after `d1ee2a57`, whose bare-carrier examples are
fixed. Found reviewing that commit on 2026-10-30.

### A public type alias in a generic `impl` is not read for private names

[Private names in public declarations](design.md#private-names-in-public-declarations)
reports a public declaration that names a private type. A public type alias
inside a non-generic `impl` is reported, but the same alias in a generic
`impl` is not:

```loke
package shapes;
@(private) Corner :: struct { x: int }
@(public) Box :: struct($T: type) { value: T }
@(public) Plain :: struct { value: int }
impl Plain {
    @(public) Inner :: Corner; // L0740
}
impl Box($T) {
    @(public) Inner :: Corner; // should warn L0740 too
}
```

A member of a generic `impl` is checked per instance, so its template has no
symbol, and `read_public_decl` in [src/private_names.odin](src/private_names.odin)
walks an alias's target only through its symbol. Reading the alias's type
instead would miss a private alias of a public type, which the syntax walk
reports. Found while closing the matching gap for constants on 2026-10-30.

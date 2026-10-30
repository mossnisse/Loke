# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

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

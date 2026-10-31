# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### A generic `impl`'s public alias of a dependent selection is not read for private names

[Private names in public declarations](design.md#private-names-in-public-declarations)
reports a public declaration that names a private type. A public type alias
in a generic `impl` is now read by its written target, but only when that
target is type syntax, names none of the block's `$` names, or instantiates a
generic record. A target that selects a member from a dependent instance is
not read, so a private sibling reached that way goes unreported:

```loke
package shapes;
@(private) Corner :: struct { x: int }
@(public) Box :: struct($T: type) { value: T }
@(public) Plain :: struct { value: int }
impl Plain {
    @(private) Hidden :: Corner;
    @(public) Sibling :: Plain.Hidden; // L0740
}
impl Box($T) {
    @(private) Hidden :: Corner;
    @(public) Sibling :: Box(T).Hidden; // should warn L0740 too
}
```

`read_generic_impl_constants` in [src/private_names.odin](src/private_names.odin)
records a member as a type alias when its value instantiates a generic record
(`instantiates_generic_record`). `Box(T).Hidden` is a selector on such a call,
so it is neither recorded nor walked. Recognize a selection from an
instantiated generic record as a type too, and walk its written names. Found
while closing the general case of this gap on 2026-10-31.

# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### Mutable carrier in a read-only parameter can be copied twice

[Values that contain borrows](design.md#values-that-contain-borrows) says
writable carriers inside a read-only wrapper keep their own capabilities, and
[Weakening and reborrows](design.md#weakening-and-reborrows) says copying a
stored mutable carrier reborrows it. This program compiles, leaving two mutable
copies of the same stored pointer live; changing `h` to `^mut Holder` rejects the
second copy with `L0641`:

```loke
package main;
Node :: struct { value: int }
Holder :: struct { head: ^mut Node }
duplicate :: proc(h: ^Holder) {
    a := h^.head;
    b := h^.head; // should be L0641
    a^.value = 1;
    b^.value = 2;
}
main :: proc() {
    n := Node{0};
    holder := Holder{&mut n};
    duplicate(&holder);
}
```

`prov_caller_slot` in [src/cfg_provenance.odin](src/cfg_provenance.odin) marks
the caller slot mutable from the enclosing loan's capability. For `^Holder`
that loan is read-only even though `head` itself is `^mut Node`, so
`prov_reborrow_loaded` records no reborrow from the caller slot when it loads
`head`.

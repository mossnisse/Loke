# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### A view through a copied pointer survives a write through the pointer it came from

[Weakening and reborrows](design.md#weakening-and-reborrows) says a carrier
stored where a read-only one is wanted reborrows its source, which cannot be
changed while the copy is in use. Through one pointer, as
`view: []int = items^[:]; items.append(1);` with `items: ^mut [dynamic]int`,
the append is L0641. Two pointers away it compiles, and the append can
reallocate the buffer the view still reads:

```loke
package main;
import "core:fmt";
grow :: proc(p: ^mut ^mut [dynamic]int) {
    view: []int = p^^[:];
    p^.append(1); // should be rejected
    fmt.println(view[0]);
}
main :: proc() {}
```

The inner `^mut` is loaded out of `p^` into an unnamed slot, so the view's
reborrow suspends nothing a later `p^` names. A traversal of `p^^` already
reborrows `p` itself (`foreach_reborrow_through_carrier` in
[src/cfg.odin](src/cfg.odin)); a stored view needs the same.

### A field read two loads below a parameter keeps its siblings' borrows

[Procedure result contracts](design.md#procedure-result-contracts) says a
helper returning one field of an argument substitutes only that field's root,
at every nesting depth. One load below the parameter, `return p.a;` with
`p: ^Pair` holds. Two loads below, the result also depends on what every field
of the first pointee views:

```loke
package main;
import "core:fmt";
import "core:strings";
Pair :: struct { a: string_view, b: string_view }
Deep :: struct { pair: ^Pair, other: string_view }
inner :: proc(d: ^Deep) -> string_view { return d.pair.a; }
main :: proc() {
    kept: string_view = "";
    {
        source := strings.copy("other");
        pair := Pair{"static", "b"};
        deep := Deep{&pair, source};
        kept = inner(&deep);
    }
    fmt.println(kept); // should compile; currently L0513
}
```

`Result_Dependencies.param_load_paths` in [src/borrow.odin](src/borrow.odin)
narrows only the first load, so `prov_substitute_result` in
[src/cfg_provenance.odin](src/cfg_provenance.odin) loads a deeper dependency
through every path of the first pointee, `other` among them.

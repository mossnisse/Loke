# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### A copy of a pointer read through another does not suspend that other

[Weakening and reborrows](design.md#weakening-and-reborrows) says copying a
mutable carrier reborrows it, and the source cannot be used while the copy is
in use. Through one pointer, `copy := items; items.append(1); copy.append(2);`
with `items: ^mut [dynamic]int` is L0641. A copy of the inner pointer two
pointers away still compiles, leaving two mutable pointers to one container:

```loke
package main;
grow :: proc(p: ^mut ^mut [dynamic]int) {
    copy := p^;
    p^.append(1); // should be rejected
    copy.append(2);
}
main :: proc() {}
```

A view of, or pointer into, the storage, as `p^^[:]` or `&p^^[0]`, already
reborrows `p` (`prov_reborrow_outer_carriers` in
[src/cfg_provenance.odin](src/cfg_provenance.odin)). A copy of `p^` itself is
a loaded slot, which `prov_reborrow_loaded` in [src/borrow.odin](src/borrow.odin)
ties only to local storage the load resolved to, so nothing ties it to a
pointer parameter. Tying every load to the pointer it went through would also
tie `cur = cur^.next` to `cur` itself, since reborrows of loaded carriers are
never severed.

### One call may take a mutable pointer and a pointer to it

[Weakening and reborrows](design.md#weakening-and-reborrows) says a mutable
carrier passed on as one is reborrowed for the call, so no other argument may
use it meanwhile. Passing a `^mut` and a mutable borrow of the variable
holding it compiles, and the callee then holds two mutable paths to one
container:

```loke
package main;
both :: proc(a: ^mut [dynamic]int, b: ^mut ^mut [dynamic]int) {
    a.append(1);
    b^.append(2);
}
main :: proc() {
    items := [dynamic]int{1};
    held := &mut items;
    both(held, &mut held); // should be rejected
}
```

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

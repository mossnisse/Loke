# Known gaps

Divergences between the specification documents and the shipped compiler, with
a minimal reproduction for each. A gap leaves this file when the compiler
matches the specified behavior — not when the spec is reworded to match the
compiler, unless the rewording is the intended fix.

## Gaps

### Growing a container two pointers away during its own traversal compiles

[Borrowing iteration](design.md#borrowing-iteration) says the source cannot be
mutated or invalidated while the traversal is live. Through one pointer, as
`foreach (item in items^)` with `items: ^mut [dynamic]int`, growing the source
in the loop is L0641. Through a second pointer it still compiles, and the
append can reallocate the buffer the loop is still reading:

```loke
package main;
grow :: proc(p: ^mut ^mut [dynamic]int) {
    foreach (item in p^^) {
        p^.append(item); // should be rejected
    }
}
main :: proc() {}
```

`foreach_reborrow_through_carrier` in [src/cfg.odin](src/cfg.odin) reborrows
the carriers `prov_read_through_carrier` reaches, but `prov_reborrow_traversal`
reborrows only named mutable carriers. The inner `^mut` is loaded out of `p^`
into an unnamed slot, so nothing guards it.

### A field returned by a `self: ^` method keeps the receiver's other borrows

[Procedure result contracts](design.md#procedure-result-contracts) says a
helper returning one field of an argument substitutes only that field's root.
Through a pointer parameter that holds: `first(&values[0])` with
`first :: proc(p: ^Pair) -> string_view { return p.a; }` compiles. As a
`self: ^` method it is rejected with L0513, because `b` views a local that
has ended:

```loke
package main;
import "core:fmt";
import "core:strings";
Pair :: struct { a: string_view, b: string_view }
impl Pair { first :: proc(self: ^) -> string_view { return self.a; } }
main :: proc() {
    kept: string_view = "";
    {
        source := strings.copy("other");
        values := [1]Pair{{"static", source}};
        kept = values[0].first();
    }
    fmt.println(kept); // should compile; currently L0513
}
```

The summary narrows the result to the receiver's `a` path, but
`prov_call_argument` in [src/cfg_provenance.odin](src/cfg_provenance.odin)
lends a `.Borrow` receiver as a borrow of the place joined with the carriers
the receiver holds. The call loads the `a` path through both, and through
those carriers it reaches every field's borrow.

### A field of an array literal element keeps its sibling field's borrow

[Minimum provenance precision](design.md#minimum-provenance-precision)
requires distinct paths for each field and for each element of a fixed array
of up to 8 elements. Here `values[0].a` is static, but using it after
`source` ends is rejected with L0513. With `other` replaced by a static
string, or with a one-element array, it compiles.

```loke
package main;
import "core:fmt";
import "core:strings";
Pair :: struct { a: string_view, b: string_view }
main :: proc() {
    kept: string_view = "";
    {
        source := strings.copy("ended");
        other := strings.copy("other");
        values := [2]Pair{{"static", source}, {"x", other}};
        kept = values[0].a;
    }
    fmt.println(kept); // should compile; currently L0513
}
```

The loss is local: no call is involved. When more than one element of the
literal holds a borrow, the read of `values[0].a` also takes `b`'s loan of
`source`. The cause has not been traced yet.

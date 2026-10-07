# Known gaps

Divergences between the specification documents and the shipped compiler, with
a minimal reproduction for each. A gap leaves this file when the compiler
accepts the program the spec describes — not when the spec is reworded to match
the compiler, unless the rewording is the intended fix.

## Gaps

### Every statement is taken to be able to panic

[design.md "Panics and unwinding"](design.md#panics-and-unwinding) runs the
registered cleanups only when a panic happens. The checker models that unwind
from the start of every statement while a `defer` is registered, including
statements that cannot panic, so it rejects a cleanup order that only an
impossible panic would get wrong. This program is valid, since neither the
`if` condition nor dropping a `[dynamic]int` can panic, but `defer drop(arena)`
is `L0537`:

```odin
package main;
import "core:mem";
dropped_first :: proc(flag: bool) -> int {
    arena := mem.Arena.init();
    xs: [dynamic]int via arena.allocator() = {};
    defer drop(arena);      // L0537: a panic could unwind it before `xs`
    if (flag) {
        drop(xs);
        return 1;
    }
    drop(xs);
    return 2;
}
main :: proc() { _ = dropped_first(true); }
```

Registering the `defer` before `xs` is accepted and is the safer order anyway.
Narrowing the unwind points to the operations that can panic (calls, checked
indexing and arithmetic, conversions) would accept the program as written.

### A procedure cannot compute a type

[design.md "`type` and `typeid`"](design.md#type-and-typeid) lets a
compile-time-only procedure return `type`, and gives `Index_Type` as its
example. The checker rejects the procedure's signature as runtime storage
(`L0378`) and its call as a non-constant `type` (`L0453`):

```odin
package main;
Index_Type :: proc($Count: uint) -> type {
    when (Count <= 256) { return u8; } else { return u32; }
}
Index :: Index_Type(1000);  // L0378 at the signature, L0453 here
main :: proc() { x: Index = 3; _ = x; }
```

`core:math`'s vector `wrapping_*` forms choose an unsigned lane type with a
`when` on `size_of(T)` and pass it as a `$U: type` argument instead.

### A slot call on a temporary `dyn` view has no global effects

[design.md "Global write effects"](design.md#global-write-effects) makes a call
write whatever its callee may write, and a `dyn` slot call reaches every method
that fills the slot. The checker applies that when the view is a local, but not
when the receiver is the call that produced the view, so this program is
accepted although `touch` clears `cache` while `view` borrows it:

```odin
package main; import "core:fmt";
cache: [dynamic]int;
Touch :: interface($Self: type) { slot touch: proc(self: ^Self); }
Toucher :: struct {}
impl Toucher { touch :: proc(self: ^Toucher) { cache.clear(); } }
TOUCHER: Toucher = {};
view_of :: proc() -> dyn Touch { return (dyn Touch)(&TOUCHER); }
main :: proc() {
    view := cache[:];
    view_of().touch();      // should be L0512, as with `t := view_of(); t.touch();`
    fmt.println(view[0]);
}
```

`core:fmt`'s `format_any` keeps the recovered view in a local for this reason,
so printing still counts a `format` method's writes.

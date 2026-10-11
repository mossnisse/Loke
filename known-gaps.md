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

### Rune constants convert to integer and floating-point types

[design.md "Implicit type conversions"](design.md#implicit-type-conversions)
converts an unfixed rune constant only to rune types. The compiler converts one
as it does an unfixed integer: to any integer type that holds it, and to a
floating-point type. This program should be rejected at both declarations, but
it compiles and prints `65 97.0`:

```odin
package main;
import "core:fmt";
main :: proc() {
    ch: u8 = 'A';     // no rune-to-`u8` conversion is listed
    x: f64 = 'a';     // accepted as 97.0
    fmt.println(ch, x);
}
```

`core:strconv` writes `u8('0')`, as the spec requires; `examples/lexer.loke`
relies on the implicit form (`ch >= '0'` with `ch: u8`). Either the spec admits
integer destinations that hold the value, or the compiler rejects them and the
lexer converts explicitly. A floating-point destination looks unintended either
way.

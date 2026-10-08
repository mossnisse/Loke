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

### A distinct procedure type does not convert implicitly

[design.md "Implicit type conversions"](design.md#implicit-type-conversions)
lists a distinct procedure type converting to and from its underlying
procedure type without a written conversion. The checker accepts only the
written form, so both declarations here are `L0310`:

```odin
package main; import "core:fmt";
Op :: distinct proc(n: int) -> int;
double :: proc(n: int) -> int { return n * 2; }
main :: proc() {
    op: Op = double;                         // L0310
    plain: proc(n: int) -> int = Op(double); // L0310
    fmt.println(op(1), plain(2));
}
```

Writing `Op(double)` and `(proc(n: int) -> int)(op)` is accepted. A
[`dyn proc` view](design.md#borrowed-callable-views) takes a procedure that
converts to its signature, so it rejects an `Op` for `dyn proc(n: int) -> int`
until this is fixed.

### A procedure type written as a result is read as a literal

[grammar.md "Procedures"](grammar.md#procedures) lets `Results` be any `Type`,
`Proc_Type` included, but the parser reads a written procedure result type
followed by the body as a procedure literal, so this is `L0350`, reported as a
compiler defect, then `L0209`:

```odin
package main; import "core:fmt";
add_one :: proc(n: int) -> int { return n + 1; }
make :: proc() -> proc(n: int) -> int { return add_one; }
main :: proc() { fmt.println(make()(1)); }
```

The same holds for a `dyn proc(...)` result. Naming the type,
`Step :: proc(n: int) -> int;` and `make :: proc() -> Step { ... }`, is
accepted. The grammar does not say which reading wins, so the fix also needs a
rule there.

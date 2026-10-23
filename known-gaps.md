# Known gaps

Divergences between the specification documents and the shipped compiler, with
a minimal reproduction for each. A gap leaves this file when the compiler
accepts the program the spec describes — not when the spec is reworded to match
the compiler, unless the rewording is the intended fix.

## Gaps

### A task's result read back through a callback is judged by its type

[Borrows crossing between tasks](design.md#borrows-crossing-between-tasks)
allows a task to use a borrow of its own `thread_local` storage within its
call. Here the task passes `keep`, which writes nothing, yet its result is
rejected because another procedure of the callback's type, `publish`, is used
as a value elsewhere:

```loke
package main;

counter: thread_local int;
publish :: proc(out: ^mut ^int) { out^ = &counter; }
keep :: proc(out: ^mut ^int) {}
apply :: proc(f: proc(out: ^mut ^int), start: ^int) -> ^int {
    current := start;
    f(&mut current);
    return current;
}

main :: proc() {
    other := 0;
    view := apply(publish, &other);
    result: ^int;
    parallel { spawn result = apply(keep, &other); } // L0730
    _ = result^;
}
```

What a callback parameter leaves in an argument is substituted at each call
for the write-back check (`Callback_Write`), but a result summary has no such
parameter: it takes what any procedure of the callback's type may leave.

### A write-back through a carrier of static storage reports `L0647`

A procedure may leave a borrow of its own thread's `thread_local` storage in
its caller's storage on one thread, as `slot = &counter` does directly. Doing
the same through a call is rejected when the argument points at storage that
outlives the thread, although only `slot` itself is written:

```loke
package main;

counter: thread_local int;
fallback: int;
publish :: proc(out: ^mut ^int) { out^ = &counter; }

main :: proc() {
    slot: ^int = &fallback;
    publish(&mut slot); // L0647
    slot = &counter;    // accepted
    _ = slot^;
}
```

The call stores the borrow through the argument's carriers and everything they
reach (`prov_retain_into_argument`), so `fallback`, which holds no borrow, is
treated as a destination too.

### A spawned call cannot take a variadic pack

[Spawn statements](design.md#spawn-statements) lets a task call any procedure
written in Loke, but a call whose variadic parameter is filled from separate
arguments is rejected:

```loke
package main;

sum :: proc(xs: ..int) -> int {
    total := 0;
    foreach (x in xs) { total += x; }
    return total;
}

main :: proc() {
    answer: int;
    parallel {
        spawn answer = sum(1, 2, 3);   // L0728: "cannot start a call with a variadic pack yet"
    }
}
```

The pack is a temporary slice of the parent's statement, and the frame has no
field that owns its elements for the task. Passing a slice to a procedure the
task runs works today.

### `-doc` omits compiler-contributed declarations

[`-doc`](compiler-guide.md#common-options) prints "each public declaration's
signature", but a public name the compiler contributes to a bundled package has
no source declaration, so the page leaves it out. `lokec core\mem -doc` prints
only the package comment, with none of `Allocator`, `Allocator_Error`,
`default_allocator`, `Arena`, `Scratch`, `Failure_Policy`, `try_arena`, and
`try_scratch`. The same holds for `core:unsafe`'s operations, `math.wrap`,
`log.Level`, `sync.Memory_Order`, and `core:meta`'s descriptors.
[Interface files](compiler-guide.md#interface-files) leave them out the same
way, so `core/mem/api.loki` holds only the package clause. Their signatures
are in comments in the package source, which nothing checks. See
[Using a package without reading its code](open-questions.md#using-a-package-without-reading-its-code-proposal-2026-10-21).

# Known gaps

Divergences between the specification documents and the shipped compiler, with
a minimal reproduction for each. A gap leaves this file when the compiler
accepts the program the spec describes — not when the spec is reworded to match
the compiler, unless the rewording is the intended fix.

## Gaps

### A callback's returned `thread_local` borrow can reach the parent

[Borrows crossing between tasks](design.md#borrows-crossing-between-tasks)
forbids a task's result from holding a borrow of the worker's `thread_local`
storage. A callback that returns one, called through a plain procedure type,
is accepted, and `result` points into the worker's ended storage:

```loke
package main;

counter: thread_local int;
borrow_tls :: proc() -> ^int { return &counter; }
call_it :: proc(h: proc() -> ^int) -> ^int { return h(); }

main :: proc() {
    result: ^int;
    parallel { spawn result = call_it(borrow_tls); }
    _ = result^;
}
```

A call through a plain procedure type has no result summary, so with no
escaping argument its result gets an unknown root (`prov_call_result`), which
the crossing check does not treat as `thread_local` storage. What a callback
leaves in an argument is substituted at each call (`Callback_Write`,
`Callback_Read`); what it returns is not.

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

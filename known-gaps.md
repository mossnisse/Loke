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

### A container's whole drop leaks the elements after a panicking hook

[design.md "What the unwind runs, and what it does not"](design.md#what-the-unwind-runs-and-what-it-does-not).

This prints `drop 1`, `drop 2`, then `outer cleanup`, and never `drop 3`. The array's cleanup is unregistered before `loke_rt_v1_dyn_drop` runs, as every cleanup is, so when element 2's hook panics nothing owes element 3 its drop. `clear` and a shrinking `resize` already shorten before each drop (`dyn_truncate` in `runtime/container.c`); a whole drop could do the same and stay registered until it finishes, and `loke_rt_v1_map_drop` likewise. `loke_rt_v1_map_remove` drops the key after copying the value out, so a panicking key hook leaves the copied value unowned.

```odin
package main;
import "core:fmt";
Tracked :: struct { id: int }
impl Tracked {
    release :: hook(drop) proc(self: inout Tracked) {
        fmt.println("drop", self.id);
        if (self.id == 2) { panic("drop failed"); }
    }
}
main :: proc() {
    defer fmt.println("outer cleanup");
    values := [dynamic]Tracked{Tracked{1}, Tracked{2}, Tracked{3}};
}
```

### Compile-time evaluation rejects records with lifecycle hooks

[design.md "Compile-time procedure evaluation"](design.md#compile-time-procedure-evaluation).

This is rejected with `L0341` ("`T` has a `hook(drop)`, which compile-time evaluation does not run yet"), although a record with a lifecycle hook is an ordinary value the evaluated path may use. `src/eval.odin` runs no lifecycle hook: not at an explicit `drop`, scope exit, a replacing assignment, a discarded temporary, or a container removal, and not for an implicit copy's `hook(copy)`. Until it runs them, `eval_hooks_supported` refuses any record value whose drop or copy would run a hook, wherever evaluation makes one, rather than evaluating it with the hook skipped. Running them needs per-slot liveness, as the emitter's drop flags give the runtime.

```odin
package main; T :: struct { n: int } impl T { release :: hook(drop) proc(self: inout T) { panic("drop ran"); } } compute :: proc() -> int { value := T{1}; drop(value); return 1; } VALUE :: compute(); main :: proc() { _ = VALUE; }
```

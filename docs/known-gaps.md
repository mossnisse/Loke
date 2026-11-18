# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### A lock's guard can retain a borrow beyond its lifetime

[Retaining a borrow](design.md#retaining-a-borrow) requires a borrowed value to
outlive storage that retains it, and a destination reached through a carrier
uses every root that carrier may name. A `thread.Guard(T)` names its mutex, but
a store through `get` is checked against the guard alone, so a process-lifetime
`thread.Mutex(T)` keeps a pointer to a local.

```loke
package main;
import "core:thread";

cell: static thread.Mutex(Option(^int)) = {};
publish :: proc() {
    value := 42;
    guard := cell.lock();
    guard.get() = .some(&value);
}
main :: proc() { publish(); }
```

Run `lokec <file> -emit-ll`. The compiler emits IR. A guard of a local mutex
that outlives the stored value is rejected with `L0513`, and the same store
through `sync.Atomic(Option(^int)).store` is `L0647`. `Guard.get` reaches the
value through a `rawptr`, which hides from its caller that the result is the
mutex's storage; `thread.Monitor_Guard(T).get` does the same.

### A `stored` argument is checked against storage only a read-only carrier reaches

[Retaining a borrow](design.md#retaining-a-borrow) lets a callee write a
`stored` argument's borrows into any compatible mutable destination it
receives. The call site also checks the argument against storage a destination
reaches only through a read-only carrier, where the callee cannot write.

```loke
package main;

Holder :: struct { view: ^int }
kept: static int = 7;
keep :: proc(destination: ^mut Holder, @(escape=stored) value: ^int) { destination.view = value; }
main :: proc() {
    local := 3;
    holder := Holder{view = &kept};
    keep(&mut holder, &local);
}
```

Run `lokec <file> -emit-ll`. The compiler reports `L0647`: `local` does not
outlive `kept`, though `keep` can store only into `holder`. The same call
through an `inout` receiver compiles.

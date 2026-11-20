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

### Unfixed decimal literals round before constant folding

`static_assert(9007199254740993.0 != 9007199254740992.0);` reports
`L0387`. The compiler rounds both literals to `f64` before it compares
them. A declaration `Difference: f64 : 9007199254740993.0 - 9007199254740992.0;`
also gets zero instead of one. [Open questions](open-questions.md#compiler-source-audit-continuation)
says what an exact representation needs.
[Number literals](design.md#number-literals) · [Expression checker review](source-reviews/check_expr.md#findings)

### `caller_location()` in a computed default names the declaration

[`caller_location()`](design.md#caller_location) names the call that omits a
default. A default the compiler folds, such as `caller_location().line + 100`,
does. One it cannot fold names the declaration.

```loke
package main;
import "core:fmt";

offset := 0;
report :: proc(line := offset + caller_location().line) -> int { return line; }
main :: proc() {
    fmt.println(report());
}
```

The program prints `5`, the declaration's line, instead of `7`. The emitter and
evaluator find a default only by its identity with the declaration's syntax, so
a call-site copy would need a per-call marker. [Built-in checker review](source-reviews/check_builtin.md#findings)

### A multiple assignment through a setter writes before its other destinations are prepared

[Evaluation order](design.md#evaluation-order) prepares every destination before
any write. A destination that calls `operator([]=)` is written while the
destinations after it are still unprepared.

```loke
package main;
import "core:fmt";

Grid :: struct { cells: [3]int }
impl Grid {
    get :: operator([]) proc(self: Grid, key: int) -> int { return self.cells[key]; }
    set :: operator([]=) proc(self: inout Grid, key: int, value: int) { self.cells[key] = value; }
}
main :: proc() {
    g := Grid{};
    first := [2]int{1, 2};
    second := [2]int{3, 4};
    s := first[mut :];
    s, g[0], s[1] = second[mut :], 7, 9;
    fmt.println(first, second);
}
```

The program prints `[1, 2] [3, 9]`: `s[1]` writes into the slice assigned to `s`
by the same statement. Without `g[0]` it prints `[1, 9] [3, 4]`. Likewise, in
`g[0], a[i] = 7, 8;` with `i` out of bounds the setter runs before the bounds
check panics. Fixing both moves the setter call into the ordinary assignment's
destination preparation in the emitter, control-flow graph, and evaluator.
[Statement checker review](source-reviews/check_stmt.md#findings)

### A compound assignment cannot view its operator's result

[Operator declarations](design.md#operator-declarations) define `x op= y` as
`x = x op y`. When the operator's result converts to the destination as a view
or a `dyn proc`, the written assignment keeps the temporary result alive, but the
compound form reports `L0417`.

```loke
package main;

Tag :: struct { n: int }
concat :: operator(+) proc(s: string_view, t: Tag) -> string { return "x"; }

main :: proc() {
    s: string_view = "a";
    s += Tag{1};
    _ = s;
}
```

`s = s + Tag{1};` compiles. Compound assignment needs the assignment's temporary
extension. [Regression](../tests/err/compound_fallback_borrow.loke)


### A mutable slice literal in thread-local storage shares its backing array

[Storage modifiers](design.md#storage-modifiers) give each thread its own
`thread_local` instance. This initializer embeds a pointer to one shared,
writable array in every thread's slice header.

```loke
package main;
import "core:fmt";
import "core:thread";

worker :: proc() {
    xs: thread_local []mut int = []mut int{0};
    xs[0] += 1;
    fmt.println(xs[0]);
}
main :: proc() {
    first := thread.spawn(worker);
    first.join();
    second := thread.spawn(worker);
    second.join();
}
```

The two threads print `1` and `2`. Separate backing arrays initialized to zero
would each yield `1`.
[LLVM constant review](source-reviews/emit_llvm_const.md#mutable-slice-backing-is-shared-across-thread-local-instances-p2)

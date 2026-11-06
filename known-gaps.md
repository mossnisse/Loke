# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### Deque's fallible append of several borrowed values panics while copying them

The [growable container contract](standard-library.md#conventions-of-the-growable-containers)
requires `try_append` to return an element-copy allocation failure, as
[container insertion](design.md#container-insertion) copies a borrowed place only on success.
Several borrowed values written one by one select the variadic `try_append_copied` in
[deque.loke](core/container/deque.loke), and a [variadic pack](design.md#variadic-parameters)
receives a copy, made by the caller before the procedure runs. A failure in that copy applies
the default allocator's failure policy and panics instead of returning `.err`:

```loke
package main;
import "core:container";
import "core:fmt";
Item :: struct { id: int }
impl Item {
    duplicate :: hook(copy) proc(self, allocator: Allocator) -> Result(Item, Allocator_Error) {
        return .err({});
    }
}
main :: proc() {
    q: container.Deque(Item) = {};
    a := Item{1};
    b := Item{2};
    result := q.try_append(a, b); // panics; should return .err
    fmt.println(result != .ok, q.len());
}
```

One borrowed value selects `try_append_one_copied`, and a lone spread `q.try_append(..items)`
lends its elements, so both copy inside and return the failure. A built-in dynamic array's
`try_append(a, b)` returns it too. A procedure has no pack that lends borrowed places, as a
`..dyn I` pack lends its views, so fixing this needs one in the language. Reproduced with the
compiler built from `1cefee9c` on 2026-11-05 while reviewing that commit (P2).

### A hook in a `when` on a later constant comes too late for a record already used

[Lifecycle hooks and resource types](design.md#lifecycle-hooks-and-resource-types)
counts a hook wherever its block is written, and a body-local record's hooks are
found where the record is declared, ahead of their block. A `when` whose condition
names a constant declared after the record cannot be selected there, so a record
already used by the time that block is reached is rejected, though the program is
valid:

```loke
package main;
import "core:fmt";
main :: proc() {
    @(move_only) H :: struct { fd: int }
    a := H{1};
    N :: 1;
    when (N == 1) {
        impl H { close :: hook(drop) proc(self: inout H) { fmt.println("close", self.fd); } }
    }
    fmt.println(a.fd);
}
```

This is `L0488`, "comes too late". Moving `a` after the `when`, or `N` before `H`,
compiles and runs the hook. A block inside a static `foreach` is treated the same,
since each expansion checks its own copy. It is an error rather than a late hook
because earlier copies may already have been decided without the hook, which would
release a value twice. `reject_unhoisted_local_hook` in
[src/impl.odin](src/impl.odin) reports it. Found on 2026-11-01 while fixing the lost
hooks of a body-local record.

### A body-local block cannot take a name an earlier use generated

[Lifecycle hooks and resource types](design.md#lifecycle-hooks-and-resource-types) makes a
body-local block's members other than its hooks visible from its statement on, and does not
say what happens when a use before that statement already made the compiler generate a member
of that name:

```loke
package main;
import "core:fmt";
main :: proc() {
    R :: struct { x: int }
    r := R{1};
    fmt.println(r);
    impl R {
        format :: proc(self, writer: fmt.Writer, options: fmt.Options) { fmt.concat_to(writer, "R"); }
    }
    fmt.println(r);
}
```

This is `L0409`, "already has a generated member `format`", and `hash` is the same;
moving the block up compiles. It stays an error because letting the written member
in would not reach what the earlier use settled: `Formattable`'s witness is chosen once
per type, so the second `println` would print the generated form with a written `format`
in scope, and a map's entries could be hashed two ways. Making this valid needs a
decision on which member such a program means. Found on 2026-11-04 in the compiler review.

### A file-scope `when` cannot call a member declared in a package still selecting

[when statement](design.md#when-statement) lets a condition read what its names
declare, but an `impl` block is declared only once its subject's package has no
pending `when`, as a record's fields may come from one. The condition is itself
pending, so the valid member call is rejected with `L0408`:

```loke
package main;
import "core:fmt";
S :: struct { x: int }
impl S { size :: proc() -> int { return 1; } }
when (S.size() == 1) { A :: 1; } else { A :: 2; }
main :: proc() { fmt.println(A); }
```

Calling a free procedure compiles. A fix has to say which blocks a condition may
reach before they are declared, the same question as the gap below. Found on
2026-11-03 while making conditions wait on what they reach.

### A file-scope `when` answers `is_copyable` without a later hook's bound

[where clauses](design.md#where-clauses) leave a `hook(copy)` out of an instance that
fails its bound, which makes the instance move-only. A file-scope `when` is selected
before the package's blocks are declared, so it sees neither the hook nor its bound,
and takes the other branch from the one the finished instance would:

```loke
package main;
import "core:fmt";
G :: struct($T: type) { value: T }
when (is_copyable(G(string))) { X :: 1; } else { X :: 2; }
impl G($T) {
    dup :: hook(copy) proc(self, allocator: Allocator) -> Result(G(T), Allocator_Error) where T == int { return .ok(G(T){self.value}); }
}
main :: proc() { fmt.println(X, is_copyable(G(string))); }
```

This prints `1 false`. The hook itself is no longer lost, since `lifecycle_of` keeps
no answer during selection. The block cannot be declared first, as a `when` may select
what it needs, so a fix has to say which questions a condition may ask. Found on
2026-11-01 while fixing the lost hooks of a body-local record.

### A write on every path does not end a received allocator's region

[The allocator reset promise](design.md#allocator_reset) covers the regions a reset
can reach. A value a parameter received, written on every path before the reset,
holds only what the write put there:

```loke
package main;
Holder :: struct { allocator: Allocator }
reset :: proc(@(allocator_reset) @(escape=stored) allowed: Allocator, h: inout Holder) {
    h.allocator = allowed;
    free_all(h.allocator);
}
main :: proc() {}
```

This reports `L0538`, though the reset can only reach `allowed`'s region. Region facts
in [src/provenance_regions.odin](src/provenance_regions.odin) only grow and do not follow
control flow, so `prov_add_received_allocator` cannot tell this from the same write
under an `if`, and keeps the incoming region. An `Allocator` parameter reassigned from
another is treated the same way, for the same reason. Resetting `allowed` itself says
the same thing. Telling them apart takes region facts by program point. Found while
fixing the conditional write on 2026-11-01 at `46cf2aa8` (P3, over-rejection).

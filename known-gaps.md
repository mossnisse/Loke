# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### A long literal can still overflow the stack at `-opt=none`

A large temporary lives to the end of its full expression, so each element of a `[dynamic]` or map
literal that is a call or a place of more than 4096 bytes keeps a slot of its own in the frame, and
300 elements of a 5 KB `L` overflow the stack. A managed key or value of a map literal also keeps its
own unwind action, 9 bytes in the frame: a 100000-entry `map[string]string` overflows where a
`[dynamic]string` of that length runs. An element's slot can be reused only once its temporaries are
known not to outlive it, and an action only while nothing newer has been reserved, since the thunk
replays newest reservation first.

```loke
package main;
L :: struct { a: [5000]u8 };
make_l :: proc() -> L { return {}; }
main :: proc() {
	xs := [dynamic]L{ make_l(), make_l(), make_l() /* and 297 more */ };
}
```

Found on 2026-11-03 (P3).

### A carrier redefined thousands of times, each value copied, takes cubic time

A generated body of `q0 := p; keep(q0); p = &mut v; q1 := p; keep(q1); p = &mut v; ...` compiled by
an optimized `lokec` takes 1.3 s at 1000 repeats and 45 s at 4000. Each new value in `p` ends what was
taken from the old one (`end_links_of_value` in [src/borrow.odin](src/borrow.odin)), which asks every
slot about every reborrow of `p`, and `p` has one per copy. A chain of copies, where each slot has one
reborrow, is quadratic with a small constant. Telling which slots may hold a reborrow from which it
derives could avoid the asking. Found on 2026-11-05 while fixing the chain (P3).
### A result read through two loads reaches every field of the second

[Procedure result contracts](design.md#procedure-result-contracts) keep which paths of a parameter's
pointee a result's first load goes along, and nothing of the loads below it. So `through_two` here
reaches both `a` and `b` at the call, and the reset reports `L0537` for `a`, as only `b` takes the
new owner. [tests/err/call_result_targets.loke](tests/err/call_result_targets.loke) pins this as
`stored_through_two_loads`, and the rejection errs on the safe side:

```loke
package main;
import "core:mem";
Two :: struct { p: ^mut [dynamic]int, q: ^mut [dynamic]int }
Nest :: struct { two: ^Two }
through_two :: proc(nest: ^Nest) -> ^mut [dynamic]int { return nest^.two^.q; }
run :: proc(@(allocator_reset) allocator: mem.Allocator) -> int {
    buffer := [1024]u8{};
    kept := mem.Arena.from_buffer(&mut buffer[:]);
    a := make([dynamic]int, 1, kept.allocator());
    b := make([dynamic]int, 0, kept.allocator());
    two := Two{&mut a, &mut b};
    nest := Nest{&two};
    target := through_two(&nest);
    target^ = make([dynamic]int, 1, allocator);
    drop(b);
    free_all(allocator); // L0537 for `a`; should be accepted
    return a[0];
}
main :: proc() {}
```

Found on 2026-11-05 while narrowing the first load (P3).

### A store through one field of a record parameter blames the sibling field's target at the call

[Minimum provenance precision](design.md#minimum-provenance-precision) keeps a record's carrier
leaves apart, and one body does: the same store written in the caller, through `pair.second^` or a
local `s := pair.second`, lands only in `b`, so this program is accepted. Across a call it is
rejected with L0537 naming `a`, because `prov_written_aliases_of` in
[src/provenance_aliases.odin](src/provenance_aliases.odin) answers a parameter's written target
without the path of the carrier reached, and the summary row's paths are then applied below every
target of the argument:

```loke
package main;
import "core:mem";
Pair :: struct { first: ^mut [dynamic]int, second: ^mut [dynamic]int }
store_second :: proc(pair: Pair, allocator: mem.Allocator) {
    pair.second^ = make([dynamic]int, 1, allocator);
}
caller :: proc(@(allocator_reset) allocator: mem.Allocator) {
    buffer := [64]u8{};
    kept := mem.Arena.from_buffer(&mut buffer[:]);
    a := make([dynamic]int, 0, kept.allocator());
    b := make([dynamic]int, 0, kept.allocator());
    store_second(Pair{&mut a, &mut b}, allocator);
    drop(b);
    free_all(allocator);
    _ = a[0];
}
main :: proc() {}
```

Found on 2026-11-03 (P3): the rejection errs on the safe side.

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

### A call that swaps with a temporary counts as copying

[Weakening and reborrows](design.md#weakening-and-reborrows) says a reordering is not
a copy, and a call summary (`Carrier_Move.copied`) says which its body does. A swap
with a temporary in the callee compiles but counts as a copy, so using both elements
after the call is `L0641`, as it is not after the same swap in a statement:

```loke
package main;
Link :: struct { to: ^mut int }
swap_by_hand :: proc(links: []mut Link) {
    held := links[0];
    links[0] = links[1];
    links[1] = held;
}
caller :: proc() {
    a := 1; b := 2;
    links := [2]Link{Link{&mut a}, Link{&mut b}};
    swap_by_hand(&mut links[:]);
    links[0].to^ = 1; // L0641; should be accepted
    links[1].to^ = 2;
}
main :: proc() {}
```

`collect_carrier_moves` asks only whether each store permutes in its own statement
(`prov_assign_permutes`). Found on 2026-11-01 while deriving a store's links in the
solve (P3, over-rejection).

### A carrier a call may have left stays after its place is replaced

[Weakening and reborrows](design.md#weakening-and-reborrows) says a store to one place
replaces what it held, and a local's record already does after a call that may have
stored there. Through a parameter's pointer to a record of one carrier, through a
pointer to a carrier, or at one element of a view parameter, it does not. In the
reproduction, the call's carrier is joined into a caller slot of no path or type as well
as the typed one, the store replaces only the typed one, and the load reads both.

```loke
package main;
Link :: struct { to: ^mut int }
keep :: proc(dst: ^mut Link, @(escape=stored) c: ^mut int) { dst^.to = c; }
replaced :: proc(l: ^mut Link, @(escape=stored) other: ^mut int, @(escape=stored) fresh: ^mut int) {
    keep(l, other);
    l^.to = fresh;
    x := l^.to;
    other^ = 1; // L0641; should be accepted
    x^ = 2;
}
main :: proc() {}
```

[carrier_store_matrix_test.odin](tests/carrier_store_matrix_test.odin) lists each place
form this holds for, and a record of two carriers through a pointer is already accepted.
End the use of `x` before using `other`.

### A read of a carrier a call may have weakened conflicts with the copy

A read-only copy does not suspend a read of what it reborrows
([Weakening and reborrows](design.md#weakening-and-reborrows)), and after `m^.b = m^.a;`
by hand the read below is accepted. After a call that does the same, it is `L0641`,
as the links a call's copies get say nothing of which carrier was weakened:

```loke
package main;
Mixed :: struct { a: ^mut int, b: ^int }
weakened :: proc(mixed: ^mut Mixed) { mixed^.b = mixed^.a; }
read_while_copy_live :: proc(m: ^mut Mixed) {
    weakened(m);
    x := m^.b;
    y := m^.a^; // L0641; should be accepted
    z := x^;
}
main :: proc() {}
```

Read through the mutable carrier before making the copy.

### A cursor stepped through itself holds nothing of the field it came from

A carrier copied out of storage reborrows the carrier stored there
([Weakening and reborrows](design.md#weakening-and-reborrows)), so two live copies of
`head^.next` are `L0641`. Once one is stored back into the carrier it was loaded through, it no
longer counts, by name or through a pointer to that carrier, and the two copies are accepted:

```loke
package main;
Node :: struct { value: int, next: ^mut Node }
stepped :: proc(head: ^mut Node) {
    cur := head;
    cur = cur^.next;
    other := head^.next;
    other^.value = 1; // accepted; should be L0641
    cur^.value = 2;
}
through_a_pointer :: proc(head: ^mut Node) {
    cur := head;
    p := &mut cur;
    p^ = p^^.next;
    other := head^.next;
    other^.value = 1; // accepted; should be L0641
    cur^.value = 2;
}
main :: proc() {}
```

One slot stands for the `next` of every node below the first, so keeping these copies as they are
would reject `cur^.next = cur^.next^.next; cur = cur^.next;` in a loop, which is valid. Fixing it
needs a read through the cursor's own value told from a read of what it was copied from.

Finish with one copy before making the other.

### A reordering of fields through a traversal binding is rejected

[Weakening and reborrows](design.md#weakening-and-reborrows) says a reordering leaves
each carrier in one place. Reordering two carrier fields through a
`foreach (&mut x in xs)` binding compiles, but a copy out of one field then conflicts
with a use of the other, though the same statement through a view parameter's element
or a pointer's fields does not:

```loke
package main;
Node :: struct { value: int }
Two :: struct { a: ^mut Node, b: ^mut Node }
fields_reordered :: proc() {
    a := Node{1}; b := Node{2};
    twos := [1]Two{Two{&mut a, &mut b}};
    foreach (&mut two in twos) { two.a, two.b = two.b, two.a; }
    node := twos[0].a; // L0641; should be accepted
    twos[0].b^.value = 1;
    node^.value = 1;
}
main :: proc() {}
```

`twos[0].b` reaches `twos[0].a` through the loop's copy of what the elements held, the
binding's slot, and the store's link: `Prov_Reborrow.moved` only stops a walk at the
first step, and the first step here is the loop's copy, which a reordering in the body
does not make a move. Found on 2026-11-01 while replacing a carrier through its
traversal binding (P3, over-rejection).

### An adapter's clone of its source draws no copy warning

An adapter stored over a mutable view that owns something clones it
([Iteration adapters](design.md#iteration-adapters)), which may allocate, but `L0507` does
not report it as it reports other implicit clones. The adapter call is checked before
`foreach` knows whether it will peel the adapter and make no clone, so warning there would
also report a loop that copies nothing. This compiles with no warning:

```loke
package main;
Cursor :: struct { at: int }
impl Cursor { next :: proc(self: inout Cursor) -> Option(^mut int) { return .none; } }
Owning :: struct { owned: [dynamic]int }
impl Owning {
    Element :: int;
    Iterator :: Cursor;
    Mut_Iterator :: Cursor;
    iter :: proc(self) -> Cursor { return {0}; }
    iter_mut :: proc(self) -> Cursor { return {0}; }
}
main :: proc() {
    source := Owning{};
    view := source.indexed();
    _ = view;
}
```

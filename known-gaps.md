# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### A call's loaded target includes sibling fields

[Procedure result contracts](design.md#procedure-result-contracts) preserves the paths a
result reads through a parameter. The call-target walk added in `f5774e5e` ignores
`param_load_paths`, so `second(&two)` below reaches both `a` and `b`. Only `b` takes
the new owner and it is dropped before the reset, but the reset reports `L0537` for
`a`. The parent commit accepts this program.

```loke
package main;
import "core:mem";
Two :: struct { p: ^mut [dynamic]int, q: ^mut [dynamic]int }
second :: proc(two: ^Two) -> ^mut [dynamic]int { return two^.q; }
run :: proc(@(allocator_reset) allocator: mem.Allocator) -> int {
    buffer := [1024]u8{};
    kept := mem.Arena.from_buffer(&mut buffer[:]);
    a := make([dynamic]int, 1, kept.allocator());
    b := make([dynamic]int, 0, kept.allocator());
    two := Two{&mut a, &mut b};
    target := second(&two);
    target^ = make([dynamic]int, 1, allocator);
    drop(b);
    free_all(allocator); // L0537 for `a`; should be accepted
    return a[0];
}
main :: proc() {}
```

Use the summary's first-load paths before following the remaining loads, as
`prov_substitute_result` already does for loans. Found reviewing `f5774e5e` on
2026-11-05 (P2, over-rejection).

### A returned record's targets lose their result paths

The same [result contract](design.md#procedure-result-contracts) records dependencies
per result carrier. In the [loaded-target reproduction](#a-calls-loaded-target-includes-sibling-fields),
replace `second` with:

```loke
identity :: proc(two: Two) -> Two { return two; }
```

and replace `target := second(&two);` with:

```loke
returned := identity(two);
target := returned.q;
```

This also reports `L0537` for `a`, although only `b` takes the new owner. The new
`prov_call_result_aliases` uses the whole-result summary and clears every alias's
`path`, so both returned fields reach both input targets. It needs the existing
per-content summaries to keep each alias at its result path. The parent accepts
this program. Found reviewing `f5774e5e` on 2026-11-05 (P2, over-rejection).

### An operator signature can settle a delegate before its target is ready

[Delegating operators](design.md#delegating-operators) should not depend on declaration
order. The operator prepass resolves signatures in source order; a signature that
evaluates a constant can run `settle_delegates` before the underlying operator's
signature is resolved. The pending delegate is removed and never retried:

```loke
package main;
D :: distinct V;
impl D { delegate(+); } // L0420: `+` is not defined for `V`
V :: struct { a: int }
N :: V(D(V{1}) + D(V{2})).a;
W :: struct { a: int }
impl W { sub :: operator(-) proc(l: W, r: [N]int) -> W { return l; } }
impl V { add :: operator(+) proc(l, r: V) -> V { return {l.a + r.a}; } }
main :: proc() {}
```

This fails in both `f5774e5e` and its parent: it is a remaining edge of the
delegate-order gap, not a new regression. Found on 2026-11-05 (P2).

### `L0740` reads a generic type's value argument as a type

[Private names in public declarations](design.md#private-names-in-public-declarations) exempts a
generic type's value argument, but the walk is by name and cannot tell a value parameter's argument
from a type parameter's. So `Priv` warns here, where it would not in an array length:

```loke
package shapes;
@(private) Priv :: struct { x: int }
@(public) Vec :: struct($N: int) { x: [N]int }
@(public) a :: proc(v: Vec(size_of(Priv))) {}
```

The fix is to read the callee's generic parameters where a call in type syntax has a template.

### `L0740` misses a group's private member when another block declares its name

Two blocks of one generic type share a member table by written subject, so a group in the first
reads the second's member of that name, and `Box(int).h`'s private `Fill` is not reported:

```loke
package shapes;
@(private) Fill :: enum { Solid }
@(public) Box :: struct($V: type) { v: V }
impl Box(int) { @(private) h :: proc(f: Fill) {} @(public) g :: proc{h}; }
impl Box(string) { @(private) h :: proc(s: string) {} @(public) g :: proc{h}; }
```

A selection such as `Box(int).Inner` resolves this by asking the checker. A group would read the
members its block declares.

### An export can still spell a generated name the compiler fixes

[`@(export)`](design.md#export) reserves only the `loke_rt_` prefix, and the names the naming pass
hands out step aside for a link name, but the rest are written as they stand: `loke.fmt.*`,
`loke.f.<n>`, the container and box thunks, and a replay's `loke.u<n>.*`. This fails in clang with `L0403`, "invalid redefinition", rather than compiling:

```loke
package main;
@(export, link_name = "loke.fmt.std_write")
f :: proc "c" () -> i32 { return 1; }
main :: proc() { _ = f(); }
```

Found on 2026-11-03 (P3).

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

### A long chain of reborrows in one body takes cubic time to solve

A generated body of `p1 := p0; keep(p1); p2 := p1; keep(p2); ...` compiled by an optimized `lokec`
takes 0.6 s at 1000 links, 3.8 s at 2000 and 34 s at 4000. Walking the body is 75 ms of the last;
the rest is `solve_provenance` in [src/borrow.odin](src/borrow.odin). The cause is not established.
Found on 2026-11-03 (P3).

### A type's printed name doubles with each alias naming the previous one twice

`type_name` spells a structural type in full and an alias has no name of its own, so the printed
form of this type is about 2^40 characters. Declaring a value of it never finishes, since checking
a map value prints the map's name; at depth 16 the name is already 1.1 MB:

```loke
package main;
M0 :: map[int]int;
M1 :: map[^M0]M0;
// ... each `Mn :: map[^Mn-1]Mn-1`, up to:
M40 :: map[^M39]M39;
main :: proc() { m: M40 = {}; _ = m; }
```

The same holds of a diagnostic naming a deep procedure alias, such as `x: P40 = 1;` over `Pn ::
proc(a: Pn-1, b: Pn-1) -> Pn-1`, and of whatever else names one, such as `Option(P40)` or `-g`. The
walks over such a type's components are linear in its depth; only the text is not. A fix has to
abbreviate a long printed type, or print the alias a type was written through. Found on 2026-11-04
(P3).

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

### A body of thousands of borrows is slow, then runs out of memory

The language sets no limit on a body's size, but `prepare_state` in
[src/borrow.odin](src/borrow.odin) gives every block a row per slot of a bit per loan, so a body's
tables grow as blocks times slots times loans. A generated body of `if (c) { p := &mut v; p^ = i; }`
takes 16 s at 1000 statements and 3.5 minutes at 2000 on an unoptimized `lokec`, and at 6000 stops
with `error: out of memory`. A `switch` no longer adds to this by its cases alone, as its bindings
share one view of the subject. Fixing it needs sparse rows, or rows only where a slot is live. Found
on 2026-11-03 (P2).

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

### An owned `next` counts a copy of its element that no step makes

[Global write effects](design.md#global-write-effects) count the copies that may
run. A protocol `next` that returns its element hands it over, and no step of the
traversal clones it, yet `Tagged.duplicate`'s read of `counter` is counted:

```loke
package main;
counter: int;
Tagged :: struct { n: int }
impl Tagged {
    duplicate :: hook(copy) proc(self, allocator: Allocator) -> Result(Tagged, Allocator_Error) {
        return .ok(Tagged{self.n + counter});
    }
}
It :: struct { done: bool }
impl It {
    Element :: Tagged;
    Iterator :: It;
    iter :: proc(self) -> It { return self; }
    next :: proc(self: inout It) -> Option(Tagged) {
        if (self.done) { return .none; }
        self.done = true;
        return .some(Tagged{1});
    }
}
main :: proc() {
    p := &mut counter;
    foreach (t in It{false}) { p^ = t.n; }
}
```

This reports `L0511` at `It{false}`, though with `p` removed the emitted loop calls
only `It.next`, and no `Tagged.clone`. `walk_flow_foreach` in
[src/cfg.odin](src/cfg.odin) calls `prov_copy_effects` for any step that does not lend
its element. `in_a_copying_traversal` in
[tests/err/global_read_effects.loke](tests/err/global_read_effects.loke) pins `L0511`
for `items.copied()`, so a fix must keep that read counted, as a clone inside `next`
or otherwise. Found while fixing destructuring's copy effects on 2026-11-01 (P3,
over-rejection).

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

### A pointer to one field of a record stands for the others

A store by hand of `r^.a.to = other` leaves `r^.b.to` free, and so does a pointer into a view
parameter's element ([Places and overlap](design.md#places-and-overlap)). A load through a
pointer to one field of a record reached through a carrier reads what the other fields hold
as well, so a copy out of one conflicts with what was stored in another:

```loke
package main;
Link :: struct { to: ^mut int }
Two :: struct { a: Link, b: Link }
other_field :: proc(r: ^mut Two, @(escape=stored) other: ^mut int) {
    r^.a.to = other;
    h := &mut r^.b;
    x := h^.to;
    other^ = 1; // L0641; should be accepted
    x^ = 2;
}
main :: proc() {}
```

Read `r^.b.to` by name.

### Clearing a dynamic array field through a pointer to it uses the pointer's source

[Weakening and reborrows](design.md#weakening-and-reborrows) has a mutable reborrow suspend
its source until the reborrow's last use, and a use of the reborrow is no use of the source.
A pointer to a dynamic array field whose elements hold a mutable carrier conflicts with
itself when it clears the array, though the same call by name, through a pointer to the whole
array, or on elements of plain data, is accepted:

```loke
package main;
Pair :: struct { a: ^mut int }
Holder :: struct { d: [dynamic]Pair }
by_name :: proc(h: ^mut Holder) { h^.d.clear(); }
through_a_field_pointer :: proc(h: ^mut Holder) {
    y := &mut h^.d;
    y^.clear(); // L0641; should be accepted
}
main :: proc() {}
```

Call it by name through `h`. Found on 2026-11-02 while checking a length beside a borrow of
the field (over-rejection).

### The length of a dynamic array conflicts with a mutable pointer to its element

A call to `len` reads only the array's header, as the same call on a view shows beside a
pointer to one of its elements. A mutable borrow of an element of a dynamic array reached
through a carrier reborrows that carrier, so the read of it conflicts:

```loke
package main;
Pair :: struct { n: int }
in_a_view :: proc(s: []mut Pair) {
    y := &mut s[0];
    n := s.len();
    y^.n = n;
}
in_a_dynamic_array :: proc(d: ^mut [dynamic]Pair) {
    y := &mut d^[0];
    n := d^.len(); // L0641; should be accepted
    y^.n = n;
}
main :: proc() {}
```

Take the length before the borrow.

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

### A misplaced token reports its cascade

[Grammar](grammar.md) has one error here, but the parser recovers into more. `impl proc() { }` reads
`{ }` as the body the type cannot have, and reports `L0406` and `L0252` after `L0210`. `return );`
in a procedure with no result reports `L0326` before the `L0220` that names the token:

```loke
package main;
impl proc() { }
f :: proc() {
    return );
}
main :: proc() {}
```

Found on 2026-11-04 in the compiler review (P3).

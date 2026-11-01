# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### A report's later argument can write through a carrier holding borrows

[Built-in procedures](design.md#built-in-procedures) has a report borrow each argument
until it has printed the last, so a later argument should not change an earlier one.
Where what a mutable pointer names holds a borrow, this compiles, and prints `n = 2`:

```loke
package main;
Node :: struct { value: ^mut int, n: int }
grow :: proc(p: ^mut Node) -> int { p^.n = 2; return 0; }
main :: proc() {
    x := 1;
    node := Node{&mut x, 1};
    p := &mut node;
    assert(false, "stop", p, grow(p));
}
```

`fmt.println(p, grow(p))` reports `L0641`, and a pointer to plain data does in a report
too. `prov_printed_argument` in [src/cfg_provenance.odin](src/cfg_provenance.odin) walks
such a local without reborrowing it, as a borrow of `p` holds nothing of what it names.
Reborrowing it there would also reject `assert(false, "stop", p, p)`, which only reads,
so the fix needs the read told apart from a use that may write. Found on 2026-11-01
while fixing printing of mutable fields (P3).

### A distinct mutable slice is read as plain when printed

`prov_type_is_plain_view` in [src/cfg_provenance.odin](src/cfg_provenance.odin) takes
printing a slice of plain data to only read it, as
[Weakening and reborrows](design.md#weakening-and-reborrows) says of printing, but a
distinct slice type may have a `format` of its own that writes through its value. This
compiles and prints `2 3`:

```loke
package main;
import "core:fmt";
D :: distinct []mut int;
impl D {
    format :: proc(self, writer: fmt.Writer, options: fmt.Options) {
        view := ([]mut int)(self);
        view[0] += 1;
        fmt.format_to(writer, view[0]);
    }
}
main :: proc() {
    storage := [2]int{1, 2};
    d := D(&mut storage[:]);
    fmt.println(d, d);
}
```

A distinct pointer in the same place reports `L0641`. Leaving distinct slices out of the
plain views as well would reject `fmt.println(d, d)` for every such type, including those
with no `format`, so that wants the method's presence checked. Found on 2026-11-01 (P3).

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
    H :: move_only struct { fd: int }
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

### Copying a zero-length array counts its element's copy hook

[Global write effects](design.md#global-write-effects) count the hooks a copy may run.
A `[0]T` has no element, but its copy still counts `T`'s `hook(copy)`:

```loke
package main;
values: [dynamic]int = {};
Tagged :: struct { n: int }
impl Tagged {
    duplicate :: hook(copy) proc(self, allocator: Allocator) -> Result(Tagged, Allocator_Error) {
        _ = values;
        return .ok(Tagged{1});
    }
}
main :: proc() {
    p := &mut values;
    a: [0]Tagged = {};
    b := a;
    p.append(1);
}
```

This reports `L0511` at `a`, though the generated `[0]Tagged` `try_clone` calls no
element clone. `copy_hooks_walk` in [src/hooks.odin](src/hooks.odin) descends into an
array's element whatever its length, as `drop_hooks_walk` beside it does not. Found
while fixing the same for equality and hashing on 2026-11-01 (P3, over-rejection).

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

### A copy's source is not held across its hook's reads

[Global write effects](design.md#global-write-effects) make a mutable borrow still
live across a call an error, and count every place a value is copied. A borrow the
copied value itself holds is not seen as live across the hook, unless the source is
used again:

```loke
package main;
counter: int;
Tagged :: struct { p: ^mut int }
impl Tagged {
    duplicate :: hook(copy) proc(self, allocator: Allocator) -> Result(Tagged, Allocator_Error) {
        _ = counter;
        return .ok(Tagged{self.p});
    }
}
main :: proc() {
    t := Tagged{&mut counter};
    u := t;
    u.p^ = 1;
}
```

This compiles, though `duplicate` reads `counter` while `t` hands it a pointer that
`u.p^ = 1` then writes through. Adding `t.p^ = 2;` afterwards reports the expected
`L0511`. In [src/cfg.odin](src/cfg.odin), `walk_flow_expr` checks `copied_as` as it
leaves the operand, so the read comes before the binding's definition takes `t`'s
content, and that definition is not a use, so nothing holds `t` at the read. A repeated array element holds its
initializer with a `.Live` event after the read (`prov_repeated_element_effects`), and
the same would newly reject `u := t` with no later use. Found while fixing repeated
elements' copy effects on 2026-11-01 (P3).

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
in [src/cfg_provenance.odin](src/cfg_provenance.odin) only grow and do not follow
control flow, so `prov_add_received_allocator` cannot tell this from the same write
under an `if`, and keeps the incoming region. An `Allocator` parameter reassigned from
another is treated the same way, for the same reason. Resetting `allowed` itself says
the same thing. Telling them apart takes region facts by program point. Found while
fixing the conditional write on 2026-11-01 at `46cf2aa8` (P3, over-rejection).

### A call given a carrier and its copy in one use is not rejected

[Weakening and reborrows](design.md#weakening-and-reborrows) suspends all use of
the source of a mutable reborrow until the reborrow's last use, and a call uses
each mutable carrier reachable through it, but a call reached with both a carrier
and its copy behind one argument is accepted when neither is used afterwards,
though the body writes through both:

```loke
package main;
Link :: struct { to: ^mut int }
poke_both :: proc(links: []mut Link) { links[0].to^ = 1; links[1].to^ = 2; }
duplicate :: proc(links: []mut Link) { links[0] = links[1]; }
written_out :: proc() {
    x := 1; y := 2;
    links := [2]Link{Link{&mut x}, Link{&mut y}};
    links[0] = links[1];
    poke_both(&mut links[:]); // should be rejected
}
copied_by_a_call :: proc() {
    x := 1; y := 2;
    links := [2]Link{Link{&mut x}, Link{&mut y}};
    duplicate(&mut links[:]);
    poke_both(&mut links[:]); // should be rejected
}
main :: proc() {}
```

Liveness finds the copy dead once the call has used the source, since a use of
both in one event comes after nothing. Found while making a call that copies
carriers within an argument link them on 2026-11-01.

### A reordering of fields through a view parameter is rejected

[Weakening and reborrows](design.md#weakening-and-reborrows) says a reordering
assignment leaves each carrier in one place, and in a view parameter elements at
different constant indices are different places. Reordering a carrier field of
two elements is still `L0641`:

```loke
package main;
Link :: struct { to: ^mut int }
swap_fields :: proc(links: []mut Link) {
    links[0].to, links[1].to = links[1].to, links[0].to; // L0641; should be accepted
}
main :: proc() {}
```

Reordering whole elements, `links[0], links[1] = links[1], links[0]`, is accepted,
and so is this statement on a named `[2]Link`. It fails before any summary is
reached, so proving the permutation does not help, and the compiler before that
proof rejects it the same way. The cause has not been traced. Found on 2026-11-01
while replacing the textual permutation check (P3, over-rejection).

### A swap written with a temporary is rejected

[Weakening and reborrows](design.md#weakening-and-reborrows) lets a carrier leave
its place, and a body reordering what it holds ends with each carrier in one
place. Written with a temporary, the reordering is `L0641` at the second store,
though `links[0], links[1] = links[1], links[0]` and `links.swap(0, 1)` are
accepted:

```loke
package main;
Link :: struct { to: ^mut int }
swap_by_hand :: proc(links: []mut Link) {
    held := links[0];
    links[0] = links[1]; // L0641; should be accepted
    links[1] = held;
}
main :: proc() {}
```

Found while separating calls that move carriers from calls that copy them on
2026-11-01. The cause has not been traced; it does not depend on those summaries.

### A mutable carrier copied back through its traversal binding is rejected

[Weakening and reborrows](design.md#weakening-and-reborrows) says storing a
carrier into itself suspends nothing, but a copy of a mutable carrier stored
back through a `foreach (&mut x in xs)` binding is `L0641` where the source is
used afterwards, though the same store through an index is accepted:

```loke
package main;
Node :: struct { value: int }
List :: struct { head: ^mut Node }
stored_back :: proc() {
    a := Node{1}; b := Node{2}; c := Node{3};
    lists := [2]List{List{&mut a}, List{&mut b}};
    foreach (&mut list in lists) { list.head = list.head; } // L0641; should be accepted
    node := lists[0].head;
    lists[1].head = &mut c;
    node^.value = 1;
}
main :: proc() {}
```

The store joins into what every element holds (`prov_publish_traversal`), so
each element's carrier is linked as a reborrow of the loop's copy of what the
elements held, which each step reads again to bind the leaf. A read-only
carrier is accepted. `list.next = list.next^.next` is rejected the same way, as
is `xs[i].next = xs[i].next^.next` over a view parameter, where the element
copied from and the one stored to are not known to be the same. Found while
making what is stored through a traversal binding reach the source on
2026-11-01.

### A mutable protocol traversal publishes into the iterable instead of its elements

[By-reference iteration](design.md#by-reference-iteration) stores through a
mutable binding into the element it names. A custom
[iteration protocol](design.md#iteration-protocol) can lend elements reached
through a slice, but the traversal's writes are recorded on the iterable object
itself:

```loke
package main;
Node :: struct { value: int }
Ro :: struct { head: ^Node }
Lender :: struct { values: []mut Ro }
Cursor :: struct { values: []mut Ro, at: int }
impl Lender {
    Element :: Ro;
    Mut_Iterator :: Cursor;
    iter_mut :: proc(self: inout Lender) -> Cursor { return {self.values, 0}; }
}
impl Cursor {
    next :: proc(self: inout Cursor) -> Option(^mut Ro) {
        if (self.at >= self.values.len()) { return .none; }
        value := &mut self.values[self.at];
        self.at += 1;
        return .some(value);
    }
}
main :: proc() {
    a := Node{1}; c := Node{3};
    lists := [1]Ro{Ro{&a}};
    source := Lender{&mut lists[:]};
    foreach (&mut list in source) { list.head = &c; }
    c.value = 5; // L0511; should be accepted when only the slice length is read
    _ = source.values.len();
}
```

This compiles before `cf7c9790` and is rejected after it. Conversely, replacing
the last two statements with `node := lists[0].head; c.value = 5;
_ = node^.value;` compiles on both revisions, although it must reject the write
of `c`: the backing array still never learns about the stored borrow.
`prov_note_traversal` in [src/cfg_provenance.odin](src/cfg_provenance.odin) takes
the named-root branch for a protocol iterable, with no element path, so
`prov_publish_traversal` puts the borrow into `source.values` itself. Publish
through the storage the protocol lends rather than into the iterable's fields.
Found while reviewing the mutable traversal store change on 2026-11-01 (P2 for
the new false rejection; the backing-storage hole predates it).

### A declaration first checked in a probe loses its rejection

A probe rolls back what it reports, but `check_alias_template` in
[src/generic.odin](src/generic.odin) keeps `template.rejected` and the declaration
stays settled, so what was wrong with it is never reported. The
[parametric alias](design.md#parametric-aliases) rule below compiles, and moving
`Bad` above `Record` reports `L0744`:

```loke
package main;
Record :: struct($V: Bad(int)) {}
Bad :: distinct Option($T);
main :: proc() {}
```

`reject_typeid_generic_parameter` resolves `$V`'s type in a probe when `Record` is
declared, which is the first thing to ask about `Bad`. The same loss turns a use into
an internal error, as the only report is gone, so `size_of` reaches emission:

```loke
package main;
Record :: struct($T: type, $V: Alias(int, 0)) { item: T }
Alias :: Record($T, $V);
main :: proc() { _ = size_of(Alias(int, 0)); }
```

This exits 2 with `L0405`, "an unfrozen compile-time built-in reached emission". A
declaration settled in a probe should keep its report, or stay unsettled for the
check that commits. Found on 2026-11-01 while fixing the instantiation limit for a
parameter's type; traced for the alias only.

### An `impl` on a record whose parameter type does not resolve reports L0350

`check_generic_impl_subject` in [src/generic.odin](src/generic.odin) reads an `impl`
subject's constant argument as a type when its parameter's type does not resolve, and
reports it as a compiler defect:

```loke
package main;
Record :: struct($T: type, $V: Unknown) { item: T }
impl Record(int, 0) { }
main :: proc() {}
```

This reports only `L0350`, "this construct parses, but the checker has no rule for
it", at the `0`, and nothing about `Unknown`. So does `$V: Record(T, 0)`, where the
instantiation limit is what stops the parameter's type. The site's comment says the
template reports its own parameter types, and it does not here. Found on 2026-11-01
while fixing the instantiation limit for a parameter's type.

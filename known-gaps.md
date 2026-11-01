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

### A swap with a temporary is rejected in a branch or a loop

[Weakening and reborrows](design.md#weakening-and-reborrows) lets a carrier leave its
place, and a swap ends with each carrier in one place. Written with a temporary in a
branch or a loop, it is `L0641`, in a branch at the reads after it, though the same
swap in straight-line code and one written in a statement are accepted:

```loke
package main;
Link :: struct { to: ^mut int }
flip :: proc() -> bool { return true; }
in_a_branch :: proc(links: ^mut [2]Link) {
    if (flip()) {
        held := links^[0];
        links^[0] = links^[1];
        links^[1] = held;
    }
    first := links^[0].to; // L0641; should be accepted
    second := links^[1].to; // L0641; should be accepted
    first^ = 1;
    second^ = 2;
}
in_a_loop :: proc(links: ^mut [2]Link) {
    for (i := 0; i < 2; i += 1) {
        held := links^[0]; // L0641; should be accepted
        links^[0] = links^[1]; // L0641; should be accepted
        links^[1] = held; // L0641; should be accepted
    }
}
main :: proc() {}
```

What a store links holds from that store on, and a reborrow is severed only where it
is severed on every path (`solve_severing`), so at the join, or round the loop, the
links of the swap are live where the reads before them are made. Telling them apart
needs them keyed by which definition reaches, as
[Compositional loan construction](open-questions.md#compositional-loan-construction)
says of value identity. Found on 2026-11-01 while deriving a store's links in the
solve; `carrier_store_matrix` lists these cases (P3, over-rejection).

### Copies out of elements swapped with a temporary through a view parameter are rejected

[Weakening and reborrows](design.md#weakening-and-reborrows) says each carrier is in
one place after a swap. Through a view parameter, a copy out of each is `L0641` after
a swap with a temporary, though the same copies compile after a swap in a statement,
and through any other place form:

```loke
package main;
Link :: struct { to: ^mut int }
copies_of_each :: proc(links: []mut Link) {
    held := links[0];
    links[0] = links[1];
    links[1] = held;
    first := links[0].to;
    second := links[1].to; // L0641; should be accepted
    first^ = 1;
    second^ = 2;
}
main :: proc() {}
```

All of a view parameter's slots hold one loan, so `prov_slots_overlap` cannot tell what
`first` holds from what `held` left in `links[1]`, and the chain through `held` still
reaches `first`. Found on 2026-11-01 while deriving a store's links in the solve (P3,
over-rejection).

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

### A receiver written `self: ^` behind a carrier conflicts with a read-only copy

A read-only copy of a mutable carrier does not suspend a read of it
([Weakening and reborrows](design.md#weakening-and-reborrows)), and a procedure taking
`^T` is accepted below. The same read as a method is `L0641`, as walking the receiver
through the carrier does not say that it only reads:

```loke
package main;
Pair :: struct { a: ^mut int, n: int }
impl Pair { size :: proc(self: ^) -> int { return self.n; } }
read_pair :: proc(p: ^Pair) -> int { return p^.n; }
by_procedure :: proc(l: ^mut Pair) {
    y: ^int = l^.a;
    n := read_pair(l);
    z := y^;
}
by_method :: proc(l: ^mut Pair) {
    y: ^int = l^.a;
    n := l^.size(); // L0641; should be accepted
    z := y^;
}
main :: proc() {}
```

Use the procedure, or end the use of the copy before the call.

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

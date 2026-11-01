# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### A local record's copy decision is checked only for its first instance

[Lifecycle hooks and resource types](design.md#lifecycle-hooks-and-resource-types)
requires a record with a drop hook to state its copy decision. Since
`bf5cb393`, a record inside a generic procedure is checked only for the first
instance of that procedure, even when a later instance adds the hook:

```loke
package main;
import "core:fmt";
outer :: proc($T: type) {
    Handle :: struct { fd: int }
    when (T == int) {
        impl Handle {
            close :: hook(drop) proc(self: inout Handle) {
                fmt.println("close", self.fd);
            }
        }
    }
    a := Handle{7};
    b := a.clone();
    fmt.println(a.fd, b.fd);
}
main :: proc() { outer(bool); outer(int); }
```

This compiles and prints `close 7` twice for the second call's two values.
Reversing the calls reports `L0747` at `Handle`, as required. A hook releasing
the handle would release the same resource twice. The same cache suppresses
`L0748` when a local `struct @(fieldwise_copy) { value: T }` is instantiated
with `int` before a move-only `T`; reversing those calls reports the conflict.

`report_local_copy_decisions` in [src/check.odin](src/check.odin) keys
`checked_copy_decisions` by source position and records successful checks too.
Check each concrete declaration, and deduplicate only diagnostics that have
actually been reported, so a successful earlier instance cannot hide a later
failure. Confirmed on `46cf2aa8` during review on 2026-11-01 (P2).

### A deferred record declaration bypasses the copy-decision check

[The copy-decision rule](design.md#lifecycle-hooks-and-resource-types) applies
to every record declaration. A declaration directly wrapped by
[`defer`](design.md#defer-statement) is checked and remains visible to the
procedure, but the new validation does not visit it:

```loke
package main;
import "core:fmt";
main :: proc() {
    defer Handle :: struct { fd: int }
    impl Handle {
        close :: hook(drop) proc(self: inout Handle) {
            fmt.println("close", self.fd);
        }
    }
    a := Handle{7};
    b := a.clone();
    fmt.println(a.fd, b.fd);
}
```

This compiles and prints `7 7`, then `close 7` twice. Removing `defer` reports
`L0747`, with no other change. `report_local_copy_decisions` in
[src/check.odin](src/check.odin) visits direct declarations and selected
`when` branches, but skips a declaration wrapped in `Stmt_Defer`.
Include those declarations in the check after the enclosing statement sequence,
once its implementation blocks have been checked. This is a coverage gap in
`bf5cb393`, confirmed on `46cf2aa8` during review on 2026-11-01 (P2).

### An excluded generic drop hook still supplies cleanup

A generic method whose [bound](design.md#where-clauses) does not hold is not
part of that instance. This also applies to a drop hook:

```loke
package main;
import "core:fmt";
G :: move_only struct($T: type) { value: T }
impl G($T) {
    release :: hook(drop) proc(self: inout) where T == int {
        fmt.println("drop", self.value);
    }
}
main :: proc() {
    a := G(string){"a"};
    fmt.println(a.value);
}
```

The program fails with `L0405`, "internal backend contract violation: a
resolved operation has no emitted name". `collect_hooks` in
[src/hooks.odin](src/hooks.odin) excludes a failed bound for a copy hook, but
unconditionally selects a drop hook. Its body is correctly omitted by
`check_pending_impl_instances` in [src/generic.odin](src/generic.odin), so the
record's cleanup refers to a procedure that will not be emitted. Exclude a drop
hook whose bound failed from lifecycle collection too. This predates the
generic-hook validation change: confirmed on both `bf5cb393` and `46cf2aa8`
during review on 2026-11-01 (P2, adjacent existing gap).

### Comparing zero-length arrays contributes nonexistent element effects

[Global write effects](design.md#global-write-effects) count the calls that run. A
structural `==` of a `[0]T` compares no element, but still counts `T`'s `==`:

```loke
package main;
import "core:fmt";
values: [dynamic]int = {};
Clears :: struct { id: int }
impl Clears {
    equal :: operator(==) proc(a, b: Clears) -> bool { values = {}; return true; }
}
main :: proc() {
    values.append(7);
    borrowed := values[:];
    a: [0]Clears = {};
    b: [0]Clears = {};
    fmt.println(a == b);
    fmt.println(borrowed[0]);
}
```

This reports `L0512` at `a == b`. `prov_equality_effects` and `prov_hash_effects` in
[src/global_effects.odin](src/global_effects.odin) take their parts from
`own_equalities_within` in [src/hash.odin](src/hash.odin), which descends into an
array's element whatever its length, as `drop_hooks_walk` used to. The checker also
asks that walk what a type requires, so the fix belongs in the two effect readers or
in a separate query. Found while fixing the empty slice literal's drop effects on
2026-11-01 at `46cf2aa8` (P3, over-rejection).

### A printed value through a mutable call result is not held

[Built-in procedures](design.md#built-in-procedures) and
[Variadic parameters](design.md#variadic-parameters) keep what a printed value
is viewed from in use until printing ends. A value reached through a named carrier
or a read-only result now is, but one reached through a mutable call result is not:

```loke
package main;
import "core:fmt";
clearing :: proc(m: inout map[int]int) -> int { m.clear(); return 0; }
main :: proc() {
    m := map[int]int{};
    m.find_or_insert(3, 1);
    fmt.println(m.find_or_insert(3, 7)^, clearing(inout m));
}
```

This compiles, and the view of the value is read after `clear` emptied the map.
The same goes for a `panic` or `assert` report. `prov_view_through_carrier` in
[src/cfg_provenance.odin](src/cfg_provenance.odin) leaves this form alone because
the result holds the receiver's mutable loan, so holding the loan would also reject
`fmt.println(m.find_or_insert(3, 7)^, m.len())`, which `tests/run/no_zero_containers`
requires and which is sound, as a read does not move the value. Fixing it takes a
way to hold a mutable loan for its invalidating accesses only. Found while fixing
the report's borrows on 2026-11-01 at `46cf2aa8` (P2).

### Printing a mutable slice field suspends it for a later read

`fmt.println` takes a read-only view of what it prints, so a later read of the same
place is allowed, as it is for a local:

```loke
package main;
import "core:fmt";
Holder :: struct { items: []mut int }
len_of :: proc(xs: []int) -> int { return xs.len(); }
main :: proc() {
    storage := [2]int{1, 2};
    held := Holder{&mut storage[:]};
    fmt.println(held.items, len_of(held.items));
}
```

This reports `L0641`, "a mutable reborrow of it is still in use". With `s := &mut
storage[:]` in place of the field, `fmt.println(s, len_of(s))` compiles.
`prov_call_argument` in [src/cfg_provenance.odin](src/cfg_provenance.odin) lends a
pack operand that `type_carries_borrow` calls mutable with a mutable
`prov_lend_carrier`, and `prov_erase` returns the field's own slot when it is not a
plain-slice read. The over-rejection predates the fix to report borrows, which
gives a report its own walk and so does not reach it. Found on 2026-11-01 at
`46cf2aa8` (P3).

### A view of a named array does not hold what its elements borrow

[Values that contain borrows](design.md#values-that-contain-borrows) carry a borrow
through whatever holds it. A slice of a local array in use does not keep in use what
the array's elements borrow, so a call can read a stale one:

```loke
package main;
import "core:fmt";
Plain :: struct { data: []int }
first :: proc(view: []Plain) -> int { return view[0].data[0]; }
main :: proc() {
    values := [dynamic]int{7};
    arr := [1]Plain{Plain{values[:]}};
    view := arr[:];
    drop(values);
    fmt.println(first(view));
}
```

This compiles, and `first` reads the dropped array. `fmt.println(view)` in place of
the call compiles too, and so does `first(arr[:])` with no local view. A load in the
same body, `view[0].data[0]`, is rejected, since `load_through_loan` in
[src/borrow.odin](src/borrow.odin) reads the element's slot at that point; only a use
of the view that hands it on goes unseen. A slice literal's array has the same shape
and is held, by `with_literal_content` extending each use of the slice with the
slots of the array it views. Giving a named root the same treatment closes this, at
the cost of also rejecting `drop(values); view.len()` for a named array, as a slice
literal already does. Found while fixing a slice literal's drop on 2026-11-01 at
`46cf2aa8` (P1).

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

### A nested `distinct` gives a parametric alias's application a new type

A [parametric alias](design.md#parametric-aliases)'s body is not "a `distinct`
type, which would be new", and an application is "the type its body denotes, not
a new one". `L0744` holds that only for the whole body:

```loke
package main;
import "core:fmt";
Alias :: Option(distinct $T);
main :: proc() {
    a: Alias(int) = .none;
    fmt.println(a);
}
```

This compiles, and `Alias(int)` denotes `Option(distinct int)`, whose element no
other spelling names. A pattern `Alias($T)` takes an `Option(Meters)` only as far
as binding `T`, then reports `L0392`, since `Alias(f64)` is another new type. In
[src/generic.odin](src/generic.odin), `check_alias_template` looks for
`Type_Distinct` only at the root. Either reject it at any depth, or settle that a
nested one is meant and say what it denotes. Found on 2026-11-01 beside the
nested computed type check.

### Instance-only private members evade L0740 outside `impl` blocks

[Private names in public declarations](design.md#private-names-in-public-declarations)
reads a private member that is a type only in an instance, and a generic `impl`'s
own declarations are read so as each instance of the block is checked. These
declarations are generic too, and select the same member, but no instance of
theirs is read, so none warns:

```loke
package shapes;
@(public) Twin :: struct($A: type, $B: type) { a: A, b: B }
@(public) Bag :: struct($T: type) { @(public) value: T }
impl Bag($T) {
    @(private) Inferred :: type_of(T{});
}
@(public) Field :: struct($T: type) { @(public) field: Twin(Bag(T).Inferred, int) }
@(public) result :: proc(x: $T) -> Twin(Bag(T).Inferred, int) { return {}; }
@(public) Target :: map[$K]Twin(Bag(K).Inferred, int);
@(private) use :: proc() {
    _ = Bag(int){};
    _ = Field(int){};
    _ = result(1);
    a: Target(string) = {};
    _ = a.len();
}
```

`check_instance_private_names` in
[src/private_names.odin](src/private_names.odin) runs for a block's instance. In
the template pass, `resolves_to_type` cannot read syntax that names a `$` name, so
a generic record's field, a generic procedure's signature, and a parametric
alias's target are passed over. Read each as its record, procedure, or alias
application is instantiated, with the checker in that instance's scope, as the
block's instance does, and report each written name once through
`private_names_warned`. Found while fixing the same omission for `impl` blocks on
2026-11-01.

### Completion lists nothing after a pointer whose method is already called

[Language server](compiler-architecture.md#language-server) completion lists the
members visible at a use. It does so after an unfinished `r.`, and after `r.x`,
but lists no member when the selector already calls a method through the pointer:

```loke
package main;
P :: struct { x: int }
impl P {
    size :: proc(self) -> int { return 0; }
}
main :: proc() {
    p := P{1};
    r := &p;
    _ = r.size(); // completion at `size` offers nothing; at `p.size` it does
}
```

`check_selector` in [src/check_expr.odin](src/check_expr.odin) rewrites the operand
to `r^` through `implicit_pointer_deref` when the method is the pointee's. Both
expressions occupy `r`'s span with different types, so `merge_occurrence` in
[src/queries.odin](src/queries.odin) drops the type as a conflict, and
`query_members` has no subject. Prefer the type the source wrote over the implicit
dereference's. Confirmed through `loke-lsp.exe` on 2026-11-01 while fixing the
generated formatter's completion.

### A swap or reverse of owners in a fixed array is not seen

[Allocator regions and region provenance](design.md#allocator-regions-and-region-provenance)
makes an owner carry its region wherever it is stored. Region facts are kept by
path and flow-insensitively, so one recorded at a fixed array's constant index
stays at that index when a swap or a call moves the owner to another, and a read
of the other index finds no region, so this escape is accepted:

```loke
package main;
import "core:fmt";
import "core:mem";
import "core:slice";
swapped :: proc() -> string {
    arena := mem.Arena.init();
    items := [2]string{"a", "b"};
    items[1] = fmt.to_string(arena.allocator(), 42);
    view := &mut items[:];
    view.swap(0, 1);
    return items[0]; // should be rejected: `arena` is dropped here
}
by_a_call :: proc() -> string {
    arena := mem.Arena.init();
    items := [2]string{"a", "b"};
    items[1] = fmt.to_string(arena.allocator(), 42);
    slice.reverse(&mut items[:]);
    return items[0]; // should be rejected
}
main :: proc() {}
```

A dynamic array's facts are wildcards for this reason (`prov_region_path`). Fields
moved by a call are probably affected the same way. `Carrier_Move` does not say
owners moved, as a summary would need to. Found while telling a dynamic array's
constant elements apart on 2026-11-01.

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

### A borrow taken once and stored at two places in a loop is not linked

[Weakening and reborrows](design.md#weakening-and-reborrows) makes a mutable
borrow's second use conflict with a live first one, but one `&mut c` stored in
two elements by a loop leaves both usable, so `c` has two live mutable carriers:

```loke
package main;
Node :: struct { value: int }
List :: struct { head: ^mut Node }
stored_twice :: proc() {
    a := Node{1}; b := Node{2}; c := Node{3};
    lists := [2]List{List{&mut a}, List{&mut b}};
    for (i := 0; i < 2; i += 1) { lists[i].head = &mut c; }
    node := lists[0].head;
    other := lists[1].head; // should be rejected
    node^.value = 1;
    other^.value = 1;
}
main :: proc() {}
```

Each store is one event taking one loan, so the two iterations are one borrow of
`c` however many places hold it. The same happens through a `foreach (&mut list
in lists)` binding. Found while making what is stored through a traversal binding
reach the source on 2026-11-01.

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

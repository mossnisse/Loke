# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

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

### A copy out of a dynamic array's view suspends the other elements' carriers

[Weakening and reborrows](design.md#weakening-and-reborrows) makes elements
of a local view at different constant indices different places wherever it
is known where the view starts, as it is for a fresh `&mut d[:]` of a
dynamic array, and a carrier copied out of one element is no use of the
carrier stored in another. Over a dynamic array, the second copy here is
still rejected:

```loke
package main;
Node :: struct { value: int }
List :: struct { head: ^mut Node }
through_dynamic_view :: proc() {
    a := Node{1}; b := Node{2};
    lists := [dynamic]List{List{&mut a}, List{&mut b}};
    s := &mut lists[:];
    node := s[0].head;
    other := s[1].head; // L0641; should be accepted
    other^.value = 3;
    node^.value = 1;
}
main :: proc() {}
```

The same copies compile over a fixed `[2]List`, and a borrow of `s[0]`
beside a write of `s[1]` compiles over the dynamic array too. The carriers
stored in a dynamic array's elements share one set of content slots
(`carrier_shape_walk` in [src/borrow.odin](src/borrow.odin) gives every
element one wildcard step), so a load naming one element of the view still
reads what every element holds, and the diagnostic names no analysis budget
as [Minimum provenance precision](design.md#minimum-provenance-precision)
asks of a merge. Copying `lists[0].head` and `lists[1].head` straight out of
the dynamic array is rejected the same way. Telling the elements apart needs
content slots for constant elements of a dynamic array, as a view
parameter's constant elements get caller slots of their own
(`prov_view_element` in [src/cfg_provenance.odin](src/cfg_provenance.odin)).
Found while making copies out of a local view's element read that element
alone on 2026-10-31.
An attempt on 2026-10-31 gave a dynamic array's first elements paths of their
own and joined the carriers of elements a call may rearrange. It made
`duplicate` in
[A call that moves carriers between elements or fields is not seen](#a-call-that-moves-carriers-between-elements-or-fields-is-not-seen)
unsound over a dynamic array as it already is over a fixed one, so this gap
waits on that one.

### A call that moves carriers between elements or fields is not seen

[Values that contain borrows](design.md#values-that-contain-borrows) makes a
container carry every borrow stored in it, and
[Weakening and reborrows](design.md#weakening-and-reborrows) makes a copy of a
mutable carrier a reborrow that suspends the carrier copied. A call that
swaps or copies carriers between the elements of a fixed array, or between
fields, leaves each element or field with the provenance it had before, so
all four of these are accepted:

```loke
package main;
Link :: struct { to: ^mut int }
Pair :: struct { a: ^mut int, b: ^mut int }
duplicate :: proc(links: []mut Link) { links[0] = links[1]; }
exchange :: proc(links: []mut Link) { links.swap(0, 1); }
share :: proc(pair: ^mut Pair) { pair^.a = pair^.b; }
view_swapped :: proc() {
    x := 1; y := 2;
    links := [2]Link{Link{&mut x}, Link{&mut y}};
    view := &mut links[:];
    view.swap(0, 1);
    held := links[0].to;
    y = 5; // should be rejected: `held` points at `y`
    held^ = 4;
}
call_exchanges :: proc() {
    x := 1; y := 2;
    links := [2]Link{Link{&mut x}, Link{&mut y}};
    exchange(&mut links[:]);
    held := links[0].to;
    y = 5; // should be rejected
    held^ = 4;
}
call_copies :: proc() {
    x := 1; y := 2;
    links := [2]Link{Link{&mut x}, Link{&mut y}};
    duplicate(&mut links[:]);
    held := links[0].to;
    y = 5; // should be rejected
    held^ = 4;
}
between_fields :: proc() {
    x := 1; y := 2;
    pair := Pair{&mut x, &mut y};
    share(&mut pair);
    held := pair.a;
    y = 5; // should be rejected
    held^ = 4;
}
main :: proc() {}
```

Each callee body is accepted on its own: it stores into its argument's own
storage, which is no retention, and its reborrows end when it returns. A
dynamic array's elements share one path, so the same calls over one are
rejected. Joining the carriers of every element or field a call may write
catches a move; a copy also leaves two live mutable carriers, which needs a
summary saying which arguments a body copies a mutable carrier within, since
linking every element as a reborrow of every other would make two calls
passing the same array conflict. Found while telling a dynamic array's
constant elements apart on 2026-10-31.

### A borrow stored through a mutable traversal binding is not seen in the container

[Values that contain borrows](design.md#values-that-contain-borrows) makes a
container carry every borrow stored in it, and a `foreach (&mut x in xs)`
binding names an element of `xs`. A carrier stored through such a binding is
not seen in the container afterwards:

```loke
package main;
Node :: struct { value: int }
List :: struct { head: ^mut Node }
stored_through_binding :: proc() {
    a := Node{1}; b := Node{2}; c := Node{3};
    lists := [2]List{List{&mut a}, List{&mut b}};
    foreach (&mut list in lists) { list.head = &mut c; }
    node := lists[1].head;
    c.value = 5; // should be rejected: `node` points at `c`
    node^.value = 1;
}
main :: proc() {}
```

The same holds over a dynamic array. Found while telling a dynamic array's
constant elements apart on 2026-10-31.

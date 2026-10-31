# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### A local alias hides a generic-dependent Unit success

[One result](design.md#one-result) permits a bare success return only when its
payload is `Unit` as written, rather than through a generic argument. The
dependency check added in `e4d9c207` reads the name of a local alias without
following its target:

```loke
package main;
outer :: proc(value: $T) {
    Outcome :: Result(T, int);
    inner :: proc() -> Outcome { return; }
    _ = inner();
}
main :: proc() { outer(Unit{}); }
```

This compiles. Spelling the inner result `Result(T, int)` instead reports
`L0326`, with the note that its success carries `Unit` only through a generic
argument. The alias should preserve that restriction; otherwise the same body
gains a bare success return only in its `Unit` instance. In
[src/check.odin](src/check.odin), `success_names_generic` returns early because
`type_syntax_names_generic` sees `Outcome` as a constant rather than a generic
binding. Follow ordinary type-alias targets in their defining scopes when
determining the success payload's dependency. Confirmed on `3b49d840` during
review on 2026-10-31 (P2).

### An overwritten slice literal's hooked elements stop borrowing

[Temporaries and procedure
boundaries](design.md#temporaries-and-procedure-boundaries) extends a slice
literal's backing array to the end of the block, where its elements are
dropped, and what a drop hook reads stays borrowed until then. Once the local
is overwritten, the elements' borrows end early:

```loke
package main;
import "core:fmt";
Read :: struct { data: []int }
impl Read {
    retire :: hook(drop) proc(self: inout Read) { fmt.println(self.data[0]); }
}
main :: proc() {
    values := [dynamic]int{7};
    view: []Read = []Read{Read{values[:]}};
    view = {};
    drop(values);
    fmt.println(view.len());
}
```

This compiles, and the hook reads `values` after it was dropped. The same code
with `view := &Read{values[:]};` overwritten by another `&Read{...}` reports
`L0512` at `drop(values)`, noting the temporary is still used when it is
dropped at the end of its scope; so did an `any_view` local. The backing
array's drop at the block's end should keep its elements' borrows live as the
extended composite's does. Found on `b73dfa55` while moving
`tests/err/temporary_extension_drops.loke` off `any_view` (P1).

### `or_else` drops the region of its left operand's payload

[Allocator regions and region
provenance](design.md#allocator-regions-and-region-provenance) requires the
`@(allocator_reset)` promise for every region a reset may reach that is not the
body's own. An allocator unwrapped from an unmarked `Option(Allocator)`
parameter by `or_else` escapes that rule when the fallback is marked:

```loke
package main;
reset :: proc(@(allocator_reset) allowed: Allocator, maybe: Option(Allocator)) {
    selected := maybe or_else allowed;
    free_all(selected);
}
main :: proc() {}
```

This compiles. The same reset reached through `switch (maybe) { case
.some(selected): free_all(selected); ... }` reports `L0538`, and so does
`maybe or_else Allocator{}`, where the default is what is uncovered. The result
of `or_else` should carry the region of the payload as well as the fallback's.
Found on `701846e9` while removing `any_view` extraction from
`tests/err/allocator_reset_alternatives.loke` (P2).

### Recursive records through parametric aliases depend on resolution order

A [parametric alias](design.md#parametric-aliases) has its expansion's identity,
and a [generic type](design.md#generic-types) may recurse through a reference.
An alias of that reference can nevertheless be rejected while its record is
being resolved:

```loke
package main;
Link :: ^Node($T);
Node :: struct($T: type) { next: Option(Link(T)) }
main :: proc() { _ = size_of(Link(int)); }
```

This reports `L0436`, claiming to exceed the 64-deep instantiation limit when
only `Link(int)` and `Node(int)` are on the stack. Resolving `Node(int)` first,
by adding `_ = size_of(Node(int));` before the use, makes the program compile.
The alias body has no alias cycle; the record's reference breaks the size
recursion. In [src/generic.odin](src/generic.odin),
`resolve_alias_application` rejects any reentry of the same template through
`template.expanding`, before the existing record instance can finish the
expansion. Permit finite record-mediated reentry while retaining the alias
cycle and actual depth checks. Confirmed on `3b49d840` during review on
2026-10-31 (P2).

### Parametric aliases cannot bind a dependently typed value argument

[Parametric aliases](design.md#parametric-aliases) take a constant generic
argument with that generic parameter's type, including when an earlier type
argument determines it. The direct application below works, but the alias
reaches an internal backend error:

```loke
package main;
import "core:fmt";
Value :: struct($T: type, $V: T) { item: T }
Alias :: Value($T, $V);
main :: proc() { fmt.println(Alias(int, 3){}); }
```

The diagnostic is `L0405`, "internal backend contract violation: `<invalid>`
has no backend representation". Replacing `Alias(int, 3)` with `Value(int, 3)`
compiles and prints `Value(int, 3){item = 0}`.
`generic_parameter_kind` in [src/generic.odin](src/generic.odin) tries to resolve
the parameter type `T` in `Value`'s template scope before it is bound.
`check_alias_template` then marks the alias rejected on `INVALID_TYPE` without
reporting a source error. Retain dependent parameter types until earlier
application arguments are bound, as record applications do, and ensure a
rejected alias has a diagnostic. Confirmed on `3b49d840` during review on
2026-10-31 (P2).

### Nested computed types evade parametric alias binding validation

[Parametric aliases](design.md#parametric-aliases) reject a `$` name where an
argument cannot bind it. The root call is checked for being a type constructor,
but a nested computed call is treated as an ordinary constructor argument:

```loke
package main;
Identity :: proc($T: type) -> type { return T; }
Alias :: Option(Identity($T));
read :: proc(value: Alias($T)) -> T {
    return value or_else panic("none");
}
main :: proc() {
    value: Alias(int) = .some(3);
    _ = read(value);
}
```

The alias is accepted, including when unused, and `Alias(int)` expands to
`Option(int)`, but `read(value)` reports `L0392`: the type does not match its
parameter's shape. The binding pass in
[src/generic.odin](src/generic.odin), `alias_binding_uses`, traverses arbitrary
calls, whereas `match_type_pattern` cannot infer a procedure's arguments from
the type it computes. Reject the unreachable `$T` at the alias declaration;
apply the constructor restriction recursively wherever a pattern must bind.
Confirmed on `3b49d840` during review on 2026-10-31 (P2).

### Parametric aliases are omitted from private type exposure checks

[Private names in public declarations](design.md#private-names-in-public-declarations)
requires `L0740` for a public alias's private target and for a private alias in
a public signature. Neither warning is produced for these parametric aliases
in a package imported by a main program:

```loke
package shapes;
Hidden :: enum { Err }
Hidden_Result :: Result($T, Hidden);
@(public) Public_Result :: Result($T, Hidden);
@(public) consume :: proc(x: Hidden_Result($T)) {}
```

Alias templates are registered as generic constants without a concrete type
value. `symbol_names_type` in [src/private_names.odin](src/private_names.odin)
therefore does not classify them as types: `read_public_decl` skips the public
alias's target, and a signature walk skips the private alias. Include alias
templates in the classification and bind their own parameter names while
reading their targets. Confirmed on `3b49d840` during review on 2026-10-31 (P3).

### Private member aliases whose types are known only in an instance evade L0740

[Private names in public declarations](design.md#private-names-in-public-declarations)
reads an alias's target, including a private alias of a public type. After
`1d4a0c29`, a public alias whose written type is bound to `type` is read in
an instance, but selecting a private member that needs the same classification
still produces no warning:

```loke
package shapes;
@(public) Point :: struct {}
@(public) Box :: struct($T: type) { value: int }
impl Box($T) {
    @(private) Hidden: T : Point;
    @(public) Typed: T : Box(T).Hidden; // should warn L0740 for Box.Hidden
    @(public) Untyped :: Box(T).Hidden; // should warn L0740 for Box.Hidden
}
@(private) use :: proc() {
    _ = Box(type).Typed;
    _ = Box(type).Untyped;
}
```

Spelling `Hidden: type : Point` produces both warnings. The indirect case is
also missed with `Hidden :: type_of(T{})` and `Box(Point).Untyped`, without
any explicitly typed alias.

`read_instance_alias` in [src/private_names.odin](src/private_names.odin)
rebuilds its `Exposure` from template declarations. The private `Hidden`
has no template-wide type classification, so `selected_member` treats it as
a value and `found_name` ignores it in a type position. The instance pass
skips private members and also skips aliases with no written type when their
resolved value is a type, so neither form gets the missing classification.
Use the current instance's resolved member kinds for these lookups and read
untyped aliases whose targets could not be classified in the template too.
Confirmed on a compiler built from `1d4a0c29` and on the merged tree during
review on 2026-10-31.

### Zero-offset reslices in loops lose a local view's known start

[Weakening and reborrows](design.md#weakening-and-reborrows) separates constant
elements of a local view whose reaching definitions are fresh range borrows
or constant reslices with a known start. Every reslice below starts at zero,
so only the view's length changes, but the distinct-element write is rejected:

```loke
package main;
Counter :: struct { count: int }
check :: proc() {
    a := [3]Counter{};
    s := &mut a[:];
    for (i := 0; i < 2; i += 1) { s = &mut s[:2]; }
    first := &mut s[0];
    s[1].count += 1; // L0641; should be accepted
    first^.count += 1;
}
main :: proc() { check(); }
```

Replacing the loop with a single `s = &mut s[:2]` compiles, as does a
conditional zero-offset reslice. `publish_view_take` in
[src/borrow.odin](src/borrow.odin) now joins differing lengths, but
`publish_view_advance` rejects a definition reached while its own answer is
unsettled before that join can retain the start. This remains a gap after
`4e475f11`, rather than a new rejection introduced by it. Preserve starts
around cycles whose reslices all have zero lower bounds, while keeping
start-changing loops conservative. Confirmed on a compiler built from
`4e475f11` and on the merged tree during review on 2026-10-31.

### Editor completion offers a hidden generated formatter

After `d16a9a2d`, a public type with a private `format` also has a generated
default for its `Formattable` slot. Ordinary lookup deliberately hides that
default, but the editor's member query lists it as callable. The query should
list the members visible at the use, as described in
[Snapshots and queries](compiler-architecture.md#snapshots-and-queries) and
[Language server](compiler-architecture.md#language-server).

```loke
// lib/lib.loke
package lib;
import "core:fmt";
@(public) S :: struct {}
impl S {
    format :: proc(self, w: fmt.Writer, o: fmt.Options) {}
}
```

```loke
// main.loke
package main;
import "./lib";
import "core:fmt";
main :: proc() {
    s := lib.S{};
    fmt.println(s);
    s.format(fmt.stdout(), fmt.DEFAULT_OPTIONS); // L0363
}
```

Replacing the final call with an unfinished `s.` and requesting completion
offers `format`, even though completing the call above is rejected.
`query_members` in [src/queries.odin](src/queries.odin) filters by `public`
and package alone, so the public synthetic method escapes the new check in
`member_is_visible` in [src/impl.odin](src/impl.odin). Apply the same hidden
default policy to the read-only query, preserving snapshot immutability,
and add a completion regression. Confirmed through both `query_members` and
the LSP `completion` entry point with a fresh build on 2026-10-31; the
existing `tests/pkg/private_formatter` case also supplies the type.

### Reaching-definition limits weaken the per-storage chosen-place guarantee

[Minimum provenance precision](design.md#minimum-provenance-precision)
guarantees eight chosen places of each storage and 64 in all, without a
separate limit on definitions or control-flow blocks. The reaching-offset
analysis added by `68504095` falls back to all earlier definitions after 63
definitions of a carrier, or after walking 256 previously uncached blocks.
That fallback again counts later places against the storage the carrier
named before it was repointed. This program chooses four places of `s` and
five of `t`, but rejects the disjoint write:

```loke
package main;
Wide :: struct { a: int, b: int, c: int, d: int, e: int, z: int }
Sides :: struct { left: Wide, right: Wide, z: int }
chosen :: proc(s: ^mut Sides, t: ^mut Sides, i: int) -> int {
    p := s;
    q := &mut p^.left.a;
    if (i == 1) { q = &mut p^.left.b; }
    if (i == 2) { q = &mut p^.left.c; }
    if (i == 3) { q = &mut p^.left.d; }
    p = t;
    foreach ($repeat in 0 ..< 62) { p = t; }
    if (i == 4) { q = &mut p^.left.e; }
    if (i == 5) { q = &mut p^.right.a; }
    if (i == 6) { q = &mut p^.right.b; }
    if (i == 7) { q = &mut p^.right.c; }
    if (i == 8) { q = &mut p^.right.d; }
    value := &q^;
    s^.left.z = 1; // L0641; should be accepted
    return value^;
}
main :: proc() {}
```

Changing 62 to 61 compiles. Replacing the static loop with
`foreach ($repeat in 0 ..< 129) { if (i < 0) {} }` also rejects the write,
this time by exhausting the block walk. Both cases report the eight-place
and multiple-storage precision limits, without naming the reaching-analysis
limit that caused the loss. Keep the per-storage guarantee across these
fallbacks; storing only the last definition in each block also avoids counting
overwritten definitions against the definition bound. Reproduced on a compiler
built from `68504095` and on the merged tree during review on 2026-10-31.

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

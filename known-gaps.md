# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### A callee may read a global its mutable parameter borrows

[Capabilities and the one rule](design.md#capabilities-and-the-one-rule) says
that while a mutable borrow is live, its root cannot be accessed through a
competing name. A call that passes a mutable borrow of a global to a callee
that reads that global by name is accepted:

```loke
package main;
import "core:fmt";

counter: int;

bump :: proc(p: ^mut int) {
    p^ = 1;
    fmt.println(counter); // should be rejected at the call: `p` borrows `counter`
    p^ = 2;
}

main :: proc() {
    bump(&mut counter);
}
```

It prints `1`. [Global write effects](design.md#global-write-effects) make a
call conflict with a live borrow of each global the callee may write, and
[src/global_effects.odin](src/global_effects.odin) computes only those writes,
so a read during the call is not seen. Closing it needs a read component in
the effect, checked against mutable borrows live across the call. The same
read effect would answer the thread-affine globals question under
[Later concurrency extensions](open-questions.md#later-concurrency-extensions),
and `noalias` on `^mut T` parameters depends on it
([design review 6.1](design-review-2026-10-31.md#61-alias-attributes-from-facts-the-checker-already-proves)).
Found while checking the alias-attribute proposal on 2026-11-01 with the
compiler at `5580637f`.

### Assert and panic arguments do not borrow the places they print

[Built-in procedures](design.md#built-in-procedures) requires an `assert` or
`panic` report to borrow each printed argument through the report. Since
`701846e9`, checking these arguments preserves their types but records no loan
of the places the backend will address. A later argument may move and destroy
an earlier argument's storage:

```loke
package main;
consume :: proc(values: move [dynamic]int) -> int { return values.len(); }
main :: proc() {
    values := [dynamic]int{7, 8};
    panic("stop", values[0], consume(move(values)));
}
```

This compiles. The emitted code retains the element's address, calls `consume`
(which drops the array before returning), then loads the element through that
freed address to print it. The same problem affects a failing `assert`.
`check_printed_argument` in [src/check_builtin.odin](src/check_builtin.odin)
checks printability and requests a type ID, but its replacement for the old
erasure no longer reaches the loan creation in `prov_erase` in
[src/cfg_provenance.odin](src/cfg_provenance.odin).
Record the report's read-only borrow without erasing the argument's type, and
keep it live across evaluation of later arguments and formatting.

Confirmed during review on 2026-11-01 with the compiler built at `5580637f`;
the relevant code is unchanged from the reviewed `426f1a13`. A compiler built
from `03d04d34`, immediately before the built-in printing change, rejects the
same program with `L0512`; an equivalent `fmt.println` also rejects the move
today. The local-mutation control `panic("stop", p, change(inout p))` likewise
compiles while `fmt.println(p, change(inout p))` reports `L0511` (P1).

### A slice literal's drop keeps only its initial element borrows

[Slice literals](design.md#slice-literals) have a hidden owner whose elements
are dropped at the end of the block. A hook must therefore keep the elements'
current borrows live until that cleanup, including borrows stored later:

```loke
package main;
import "core:fmt";
Read :: move_only struct { data: []int }
impl Read {
    retire :: hook(drop) proc(self: inout Read) {
        if (self.data.len() > 0) { fmt.println(self.data[0]); }
    }
}
main :: proc() {
    values := [dynamic]int{7};
    view := []mut Read{Read{{}}};
    view[0] = Read{values[:]};
    view = {};
    drop(values);
}
```

This compiles, and the element's hook reads freed storage at block exit.
Conversely, initializing the literal with `Read{values[:]}` and replacing the
element with `Read{{}}` reports `L0512` at `drop(values)`, although the hook
that read that borrow already ran during replacement. The latter is a
regression from `426f1a13`; the former remains unfixed by `210f1131`.
In [src/cfg_provenance.odin](src/cfg_provenance.odin), `prov_slice_literal`
defines `root.content` from the original elements only, and
`prov_extended_drop` reads that snapshot. Track the backing array's current
content through element and field writes instead. Confirmed on `5580637f`
during review on 2026-11-01 (P1).

### An empty slice literal contributes nonexistent element drop effects

An empty [slice literal](design.md#slice-literals) has no elements whose
hooks can run. Since `210f1131`, its cleanup nevertheless applies the element
type's global write effects:

```loke
package main;
import "core:fmt";
values: [dynamic]int = {};
Clear :: move_only struct { id: int }
impl Clear {
    retire :: hook(drop) proc(self: inout Clear) { values = {}; }
}
main :: proc() {
    values.append(7);
    borrowed := values[:];
    {
        view := []Clear{};
        fmt.println(view.len());
    }
    fmt.println(borrowed[0]);
}
```

This reports `L0512` at `[]Clear{}`, claiming that `retire` writes `values`
when the slice literal is dropped. At `426f1a13` it compiles and prints `0`
and `7`; the zero-length backing array runs no hook. `prov_slice_literal`
now records its backing type for `prov_extended_drop`, but `type_drop_hooks`
in [src/hooks.odin](src/hooks.odin) descends into the element type of a fixed
array even when its length is zero. Exclude those nonexistent element effects.
Confirmed on `5580637f` during review on 2026-11-01 (P2).

### A conditional write hides a received allocator payload's region

[The allocator reset promise](design.md#allocator_reset) must cover every
pre-existing region that can be reset. A known write into a received `Option`
can suppress the unknown incoming payload that `5580637f` added:

```loke
package main;
reset :: proc(@(allocator_reset) @(escape=stored) allowed: Allocator,
              maybe: inout Option(Allocator), flag: bool) {
    if (flag) { maybe = Option(Allocator).some(allowed); }
    free_all(maybe or_else allowed);
}
main :: proc() {}
```

This compiles. With `flag` false, the reset can reach the incoming payload's
region, which need not be `allowed`'s. Removing the conditional assignment
reports `L0538`. In [src/cfg_provenance.odin](src/cfg_provenance.odin),
`prov_result_region_at` adds the unknown parameter origin only when the whole
queried set is empty. Region writes merge without regard to control flow, so
the possible write of `allowed` makes that set nonempty even on the path where
the incoming payload survives. Preserve the incoming origin alongside possible
writes; seeding allocator leaves at parameter entry would also avoid repeating
this fallback in individual readers. Confirmed on `5580637f` during review on
2026-11-01 (P2); the conditional-write case also compiles at `426f1a13`.

### A temporary record field also carries sibling allocator regions

[Allocator regions and region provenance](design.md#allocator-regions-and-region-provenance)
keeps a record's fields separate when projecting a temporary result:

```loke
package main;
Pair :: struct { a, b: Allocator }
reset :: proc(@(allocator_reset) allowed: Allocator, other: Allocator, flag: bool) {
    free_all((Pair{allowed, other} if flag else Pair{allowed, other}).a);
}
main :: proc() {}
```

This reports `L0538`, although both possible values of `.a` are `allowed`.
The failure predates the reviewed commits and reproduces at `426f1a13`.
The projected query added in `5580637f` now obtains the correct field region,
but `prov_region_of` in [src/cfg_provenance.odin](src/cfg_provenance.odin)
merges it with `prov_read_region`'s whole-record result, retaining `.b`'s
unmarked region. Return the projected query directly for a struct field and
keep `prov_read_region` as the fallback. A scratch compiler with that
one-line reduction accepts this case while still rejecting the received
allocator payload probes. Confirmed on `5580637f` during review on 2026-11-01
(P2, pre-existing; also a simplification opportunity).

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

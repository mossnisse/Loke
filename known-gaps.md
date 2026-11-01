# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### A qualified local alias hides a result's generic dependence

[One result](design.md#one-result) and
[Success returns](design.md#success-returns) read a result through a local alias
as what that alias names. `045dcbce` follows a bare identifier, but not an alias
selected from an implementation block on a type declared in the same generic
body:

```loke
package main;
outer :: proc(value: $T) {
    Local :: struct {}
    impl Local { Outcome :: Result(T, int); }
    inner :: proc() -> Local.Outcome { return; }
    _ = inner();
}
main :: proc() { outer(Unit{}); }
```

This compiles. Moving the same `Outcome :: Result(T, int)` directly into
`outer` and returning `Outcome` reports `L0326`, as does spelling the result
`Result(T, int)`. An associated `Payload :: T` selected in
`Result(Local.Payload, int)` has the same omission. With `T` equal to `int`,
`inner :: proc(x: T) -> Result(Local.Payload, int) { return x; }` also compiles,
implicitly wrapping a value beside an error payload where the direct alias
reports `L0310`.

`type_syntax_any_name` in [src/ast.odin](src/ast.odin) visits only the operand of
a selector. The operand `Local` defines a nominal type, so
`local_alias_target` in [src/check.odin](src/check.odin) correctly does not
follow it, but the selected constant's initializer is never inspected.
Follow the selected alias in its declaration scope for both dependence and
success-payload analysis, preserving bare returns for
`Local.Outcome :: Result(Unit, T)`, whose success is explicitly `Unit`.
Confirmed at `045dcbce` and on the merged `1b7845aa` during review on
2026-11-01 (P2, remaining coverage gap).

### Provisional short lengths hide a zero-offset view cycle's known start

[Weakening and reborrows](design.md#weakening-and-reborrows) preserves a local
view's known start when every repeated reslice starts at zero. The fixed point
in `51bceeb4` can still lose it when mutually dependent views contribute
different lengths:

```loke
package main;
import "core:fmt";
Holder :: struct { p: ^mut int }
run :: proc(flag: bool) {
    a, b, c := 1, 2, 3;
    arr := [3]Holder{{&mut a}, {&mut b}, {&mut c}};
    base := arr[:];
    s := base[:1];
    t := base[:];
    for (i := 0; i < 2; i += 1) {
        if (flag) { s = t[:]; }
        t = s[:2];
    }
    first := s[0].p;
    s[1].p^ += 1;
    first^ += 1;
    fmt.println(a, b, c);
}
main :: proc() { run(true); }
```

This reports `L0641` at `s[1].p^`. Replacing the loop with a single block, or
initializing `s` with `base[:2]` or `base[:]`, compiles; the block and full-length
controls both print `2 3 3`. Every reslice starts at zero. The false branch can
panic because the source is too short, but cannot make the two surviving
element accesses overlap.

`publish_view_def` in [src/borrow.odin](src/borrow.odin) produces an unknown
start when its current source length is less than the requested constant end.
During the new fixed point that length can still grow as other definitions
contribute. Joining this provisional answer with the previous state through
`publish_view_agree` makes unknown permanent, even after the longer source
arrives. Settle the length information before concluding that the start is
unknown, or distinguish provisional bounds from a genuinely unknown offset.
Confirmed at `51bceeb4` and on the merged `1b7845aa` during review on
2026-11-01 (P2, remaining precision gap).

### Destructuring records counts the containing copy hook instead of the fields

[Destructuring](design.md#destructuring) copies each retained field of a place,
without calling the containing record's copy hook. [Global write
effects](design.md#global-write-effects) must therefore include those fields'
copy-hook reads:

```loke
package main;
counter: int;
Tagged :: struct { n: int }
impl Tagged {
    duplicate :: hook(copy) proc(self, allocator: Allocator) -> Result(Tagged, Allocator_Error) {
        return .ok(Tagged{self.n + counter});
    }
}
Pair :: struct { tag: Tagged, text: string }
impl Pair {
    duplicate :: hook(copy) proc(self, allocator: Allocator) -> Result(Pair, Allocator_Error) {
        return .ok(Pair{Tagged{self.tag.n}, self.text});
    }
}
use :: proc(pair: Pair) {
    p := &mut counter;
    tag, _ := pair;
    p^ = tag.n;
}
main :: proc() { use(Pair{Tagged{1}, "hello"}); }
```

This compiles, though `Tagged.duplicate` reads `counter` while `p` borrows it
mutably. The emitted IR calls `Tagged.clone` at the destructure. In
[src/lifecycle.odin](src/lifecycle.odin), `classify_destructure` sets the operand's
`copied_as` to the whole record. `type_copy_hooks` in [src/hooks.odin](src/hooks.odin)
then stops at `Pair.duplicate`, missing the hook that actually runs. The same
annotation over-rejects a discarded field: remove `Pair`'s hook and change the
body to `_, text := pair; p^ = text.len();`, and it reports `L0511` even though
the discarded `tag` is never cloned. Record effects per retained cloned field.
Introduced in `edb4eb2e`; confirmed on `1b7845aa` during review on 2026-11-01 (P2).


### Repeated array elements count copy reads before creating their loans

[Fixed arrays](design.md#fixed-arrays) evaluate a repeated initializer before
copying it into the remaining slots. A copy hook's [global read
effect](design.md#global-write-effects) must be checked with the loans that
initializer created still in use:

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
    copies := [2]Tagged{0..=1 = Tagged{&mut counter}};
    copies[0].p^ = 10;
}
```

This compiles; the emitted IR takes the pointer and then calls `Tagged.clone`,
whose hook reads `counter`. Naming `p := &mut counter` before the literal and
using `Tagged{p}` instead reports the expected `L0511`. The `Expr_Composite`
case of `walk_flow_expr` in [src/cfg.odin](src/cfg.odin) emits every repeated
element's `prov_copy_effects` before walking the allocator or any element, so
the fresh loan does not yet exist at the read event. Emit the effects after
evaluating the repeated initializer, in the order its copies run. Introduced
in `edb4eb2e`; confirmed on `1b7845aa` during review on 2026-11-01 (P2).


### Reports count a public type's private formatter that printing never calls

[Interface bodies](design.md#interface-bodies) excludes a public type's private
`format` from its coherent printed representation. [Built-in
procedures](design.md#built-in-procedures) print report arguments through that
representation:

```loke
package sample;
import "core:fmt";
data: [dynamic]int = {};
@(public) Hidden :: struct { n: int }
impl Hidden {
    format :: proc(self, writer: fmt.Writer, options: fmt.Options) { data = {}; }
}
report :: proc() { data.append(7); panic("stop", data[0], Hidden{1}); }
```

Compile with `lokec sample.loke -build-mode=obj -emit-ll`. This reports `L0512`
at `Hidden{1}`, claiming printing may modify `data`, although its generated
formatter prints only its integer field. Removing `data[0]` permits emission,
and the witness calls the generated `Hidden.format`, not the written private
method. `prints_through_method_walk` in [src/format.odin](src/format.odin) tests
`written_format_member` without the visibility rule already implemented by
`type_has_written_format`. Apply that rule before deciding whether a report
can run user formatting code, then inspect the default formatter's parts.
Introduced in `a28b7aac`; the same program is accepted by its parent. Confirmed
on `1b7845aa` during review on 2026-11-01 (P2).


### A lifecycle question asked before a record's hooks are in place loses them

[Lifecycle hooks and resource types](design.md#lifecycle-hooks-and-resource-types)
runs a record's `hook(drop)` once per value, wherever the hook is written among the
record's `impl` blocks. Asking about the record's lifecycle before the hook has been
resolved loses it, with no diagnostic:

```loke
package main;
import "core:fmt";
main :: proc() {
    H :: move_only struct { fd: int }
    fmt.println(is_copyable(H));
    impl H {
        close :: hook(drop) proc(self: inout H) { fmt.println("close", self.fd); }
    }
    a := H{7};
    fmt.println(a.fd);
}
```

This prints `false` and `7`, and never `close 7`. Removing the `is_copyable` line
runs the hook. Making a value first, `a := H{7};` before the `impl` block, loses the
hook for that value and for every later one. A generic record does the same when a
member's bound is evaluated before a later member is resolved:

```loke
package main;
import "core:fmt";
G :: move_only struct($T: type) { value: T }
impl G($T) {
    helper :: proc(self) where !is_copyable(G(T)) { fmt.println("helper"); }
    release :: hook(drop) proc(self: inout) { fmt.println("drop", self.value); }
}
main :: proc() {
    a := G(string){"a"};
    a.helper();
    fmt.println(a.value);
}
```

This never prints `drop a`. A `hook(copy)` is lost in the same way, leaving the
generated copy, and with a bound that fails, as `where T == int` on the `hook(copy)`
after `helper :: proc(self) where is_copyable(G(T))`, `G(string)` keeps a copy it
should not have. A hook whose own bound asks is excluded after the answer was kept:
`release :: hook(drop) proc(self: inout) where is_copyable(G(T))` fails with `L0405`,
"internal backend contract violation: a resolved operation has no emitted name",
because the kept answer names a hook whose body is not emitted.

`lifecycle_of` in [src/hooks.odin](src/hooks.odin) caches its first answer for a
type, and `collect_hooks` can only see the members resolved so far: during
`install_one_generic_impl` in [src/generic.odin](src/generic.odin) for an instance,
and before the `impl` statement for a body-local record. A file-scope record is
not affected, since its `impl` blocks are checked first. Do not cache an answer
while the type or anything it holds can still gain a hook, as `lifecycle_of` already
does for a record still resolving its fields, and answer the question from what is
known so far. Found on 2026-11-01 while fixing the excluded generic drop hook.

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

### A map entry reached through a pointer is not held

[Weakening and reborrows](design.md#weakening-and-reborrows) suspends a carrier while
what was reborrowed through it is in use, and a map's entry is invalidated by a
`clear`. A result of `find_or_insert` on a map reached through a local pointer holds
neither the pointer nor the map, so this compiles and reads the cleared map:

```loke
package main;
import "core:fmt";
main :: proc() {
    q: map[int]int = {};
    p := &mut q;
    e := p^.find_or_insert(3, 7);
    p^.clear();
    fmt.println(e^); // should be rejected
}
```

`clear` may be written `clearing(inout p^)`, or a call handed `p`, with the same
result. The same steps on `q` directly report `L0511`, and a user procedure returning
`&mut d^[0]` from `p` reports `L0641`. The cause has not been traced. Found on
2026-11-01 while holding a printed value through a mutable call result (P2).

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

Mutable pointer fields have the analogous problem in reports too:

```loke
package main;
Holder :: struct { p: ^mut int }
test :: proc(ok: bool) {
    x := 1;
    held := Holder{&mut x};
    assert(ok, "stop", held.p, held.p);
}
main :: proc() { test(true); }
```

This reports `L0641` at the second `held.p`. A local `p := &mut x` printed twice
is accepted. `prov_printed_argument` falls back to `walk_flow_expr` for the
pointer field, which takes a mutable reborrow before borrowing the field
read-only. The plain-slice case above has a separate read-only path. This
pointer-field rejection is present in both `a28b7aac`'s parent and `1b7845aa`,
so it predates the report-borrow fix. Confirmed during review on 2026-11-01.

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

### Reading only the first instance misses a private member that later becomes a type

[Private names in public declarations](design.md#private-names-in-public-declarations)
reads a generic `impl`'s selected private member in each instance the build creates,
since whether it is a type can depend on that instance:

```loke
package shapes;
@(public) Point :: struct { value: int }
@(public) Item :: struct($T: type, $V: T) { value: int }
@(public) Holder :: struct($T: type, $V: T) { value: int }
impl Holder($T, $V) {
    @(private) Hidden: T : V;
    @(public) Exposed :: Item(T, Holder(T, V).Hidden);
}
@(private) use :: proc() {
    _ = Holder(int, 0){};
    _ = Holder(type, Point){};
}
```

This emits no `L0740`, though `Holder(type, Point).Hidden` is a private alias of
`Point`. Reversing the two uses warns about `Holder.Exposed` naming
`Holder.Hidden`. In [src/private_names.odin](src/private_names.odin),
`instance_declaration_unread` records `Exposed`'s span after its first instance,
when `Hidden` is a value, and never reads the later instance where it is a type.
Read instance-dependent selections in each instance and deduplicate the warnings,
rather than marking the whole declaration read after its first one. Confirmed on
`ad4ff130` and `1b7845aa` during review on 2026-11-01 (P2).

### Private-name probes resolve a generic method's parameters in its block's scope

[Private names in public declarations](design.md#private-names-in-public-declarations)
does not read a parameter as a private declaration of the package, and a private
value argument is not a private type. A generic method's own parameters are bound
by its calls, separately from the generic `impl`'s parameters:

```loke
package shapes;
@(public) Point :: struct { value: int }
@(private) T :: type;
@(private) V :: Point;
@(public) Item :: struct($T: type, $V: T) { value: int }
@(public) Holder :: struct($T: type, $V: T) { value: int }
impl Holder($T, $V) {
    @(private) Hidden: T : V;
}
@(public) Host :: struct($X: type) { value: int }
impl Host($X) {
    @(public) make :: proc(self, $T: type, $V: T) -> Item(T, Holder(T, V).Hidden) { return {}; }
}
@(private) use :: proc() {
    host := Host(int){};
    _ = host.make(int, 0);
}
```

This warns that `Host.make` names the private type `Holder.Hidden`. Its only call
binds `T = int` and `V = 0`, so that member is an integer value. Removing the two
unused package aliases `T` and `V` removes the warning. `resolves_to_type` in
[src/private_names.odin](src/private_names.odin) bypasses `names_bound` for an
instance and probes the selection in the block's checker scope, where the method's
parameters are absent and the package aliases resolve instead. Preserve the
method's parameter scope, or defer a selection that depends on its own generics
until a method instance supplies them. Introduced in `ad4ff130`; its parent
`85ee47f3` does not warn. Confirmed on that commit and `1b7845aa` during review on
2026-11-01 (P2).

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

### A dependent alias parameter can recurse before the instantiation limit applies

[Generic types](design.md#generic-types) bounds recursive instantiation with a
diagnostic, but resolving the type of a parametric alias's constant argument can
overflow the compiler's stack instead:

```loke
package main;
Record :: struct($T: type, $V: Alias(T, 0)) { item: T }
Alias :: Record($T, $V);
main :: proc() { _ = size_of(Alias(int, 0)); }
```

`resolve_alias_application` in [src/generic.odin](src/generic.odin) calls
`alias_dependent_type` before checking or pushing the instantiation stack. The
parameter type applies the alias again, so no frame is ever pushed and the
depth limit never sees the recursion. Guard dependent argument-type resolution
as well as body expansion. Confirmed at `c588e439` and the current checkout:
the process exits with Windows stack-overflow status `0xC00000FD` and no
diagnostic; its parent reports internal `L0405` instead. Found while reviewing
the dependent-constant alias change on 2026-11-01 (P2).

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

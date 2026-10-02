# Known gaps

Divergences between the specification documents and the shipped compiler, with
a minimal reproduction for each. A gap leaves this file when the compiler
accepts the program the spec describes — not when the spec is reworded to match
the compiler, unless the rewording is the intended fix.

## Gaps

### Container thunks bypass the large-value parameter ABI

[design.md "Parameter semantics and ABI lowering"](design.md#parameter-semantics-and-abi-lowering)
allows implementation-specific lowering while preserving procedure behavior.
The backend passes values larger than 4096 bytes by address, but
`container_less_thunk`, `container_equal_thunk`, and `sort_by_thunk` in
[src/emit_llvm_containers.odin](src/emit_llvm_containers.odin) load aggregate
registers and pass their storage types directly to user procedures:

```odin
package main;
Big :: struct { id: int, pad: [4096]u8 }
impl Big {
    less :: operator(<) proc(a, b: Big) -> bool { return a.id < b.id; }
}
main :: proc() {
    xs := [dynamic]Big{Big{2, {}}, Big{1, {}}};
    xs.sort();
    assert(xs[0].id == 1);
}
```

This compiles but exits with access violation `0xC0000005`, rather than
sorting successfully. The thunk calls `Big.less` with two aggregate operands,
although its definition takes two `ptr` operands. Reducing the padding to
4088 bytes, making the record exactly 4096 bytes, succeeds. Sorting the
4104-byte record through `core:slice.sort_by` also crashes.

`container_hash_thunk` has the related mismatch: it obtains an address from
`load_place` but labels a value receiver with `llvm_type`, so a large map key
with an inherent value-receiver `hash` fails LLVM validation with `L0403`.
Use the existing parameter ABI lowering for these direct calls and preserve
the address representation for large values, including comparator state.

### Borrowed map literal receivers are never dropped

[design.md "Evaluation order"](design.md#evaluation-order) destroys owned
temporaries at the end of their complete expression. Membership and index
reads borrow their maps, so a literal used as the receiver still owes cleanup:

```odin
package main;
import "core:fmt";
Res :: struct { id: int }
impl Res {
    release :: hook(drop) proc(self: inout Res) { fmt.println("drop", self.id); }
}
main :: proc() {
    fmt.println(1 in map[int]Res{1 = Res{7}});
    fmt.println(map[int]Res{1 = Res{8}}[1].id);
    fmt.println("done");
}
```

This prints `true`, `8`, and `done`, omitting both `drop 7` and `drop 8`.
`emit_map_membership` and `emit_map_element_address` in
[src/emit_llvm_containers.odin](src/emit_llvm_containers.odin) materialize the
receiver with `emit_address`, but its composite branch does not register
cleanup. The literal builder clears its partial-construction registration
after completion, leaving no owner of the completed map. Register an owned
literal receiver for complete-expression cleanup when borrowing it, as the
ordinary borrowed-receiver call path does.

### Map literal values lack unwind protection before insertion

[design.md "What the unwind runs, and what it does not"](design.md#what-the-unwind-runs-and-what-it-does-not)
requires every successfully initialized owner to be released on a panic.
`emit_map_literal_into` in
[src/emit_llvm_containers.odin](src/emit_llvm_containers.odin) guards the
partially built map and its temporary key, but leaves the incoming value
unregistered while `emit_map_entry` hashes or clones the key:

```odin
package main;
import "core:fmt";
Key :: struct { id: int }
impl Key {
    hash :: proc(self, seed: uint) -> uint { panic("hash failed"); return 0; }
    same :: operator(==) proc(a, b: Key) -> bool { return a.id == b.id; }
}
Res :: struct { id: int }
impl Res {
    release :: hook(drop) proc(self: inout Res) { fmt.println("drop", self.id); }
}
main :: proc() {
    defer fmt.println("unwound");
    m := map[Key]Res{Key{1} = Res{7}};
}
```

With the default panic strategy, this prints `unwound` but omits `drop 7`.
The map does not yet contain the value, and no other cleanup action owns it.
The same gap covers a cloned borrowed value, key-clone allocation failure,
and a panic while dropping an existing entry before replacement. Guard each
completed incoming value until it has been stored in the map, then clear the
guard before destroying the temporary key.

### Synthesized container insertion loses owners on panic

[design.md "Container insertion"](design.md#container-insertion) transfers
ordinary insertion arguments at the call boundary.
["What the unwind runs, and what it does not"](design.md#what-the-unwind-runs-and-what-it-does-not)
requires the new owner to release them on a panic. Synthesized insertion
bodies in [src/emit_llvm_containers.odin](src/emit_llvm_containers.odin)
destroy an unconsumed value only after the C helper returns a failed status:

```odin
package main;
import "core:fmt";
Res :: struct { id: int }
impl Res {
    release :: hook(drop) proc(self: inout Res) { fmt.println("drop", self.id); }
}
main :: proc() {
    defer fmt.println("unwound");
    xs: [dynamic]Res = {};
    xs.insert(1, Res{7});
}
```

The out-of-range insert panics and prints `unwound`, omitting `drop 7`.
The caller has handed the value over, and the synthesized body has no unwind
frame or live registration for it. `find_or_insert` also loses its consumed
value if an inherent key hash panics before the first probe completes.
Its staged values and those of `try_insert` similarly need protection across
later key callbacks. Register transferred arguments and completed staged
clones until insertion commits or explicit failure cleanup destroys them.

### Map literals clone elements through the default allocator

[design.md "Maps"](design.md#maps) constructs a map literal using its
destination allocator, including a declaration's `via` policy. Borrowed
elements must clone through that allocator, as dynamic-array literal elements
do. `emit_map_literal_into` in
[src/emit_llvm_containers.odin](src/emit_llvm_containers.odin) instead calls
`emit_clone_value` without supplying the map's bound allocator:

```odin
package main;
import "core:fmt";
import "core:mem";
Res :: struct { id: int }
impl Res {
    copy_res :: hook(copy) proc(self, allocator: Allocator) -> Result(Res, Allocator_Error) {
        fmt.println(allocator == mem.default_allocator());
        return .ok(Res{self.id});
    }
}
main :: proc() {
    arena := mem.Arena.init();
    value := Res{7};
    m: map[int]Res via arena.allocator() = {1 = value};
    xs: [dynamic]Res via arena.allocator() = {value};
    fmt.println(value.id, m[1].id, xs[0].id);
}
```

This prints `true`, `false`, and `7 7 7`; both clone calls should print
`false`. The map's table uses the arena, but its element clone uses the
default provider, violating the allocator selection for nested allocations
and their failure policy. Pass the map's allocator to the element clone.

These five container-emission findings were reproduced with a compiler built
from the source tree on 2026-10-02 at the default optimization level. All 108
compiler unit tests pass with memory tracking and both compiler vets enabled;
the current fixtures do not cover these cases.

### Distinct types implicitly inherit comparisons

[design.md "Distinct types"](design.md#distinct-types) says a distinct type
inherits no operations; comparisons must be supplied explicitly or through
`delegate`. This program should therefore reject both comparisons:

```odin
package main;
Meters :: distinct int;
main :: proc() {
    a, b := Meters(1), Meters(2);
    assert(a != b);
    assert(a < b);
}
```

It compiles and runs successfully. `type_is_comparable` and `type_is_ordered`
in [src/semantic.odin](src/semantic.odin) unwrap the nominal type, and
`check_comparison` accepts their answers even when operator lookup found no
overload. Records and arrays containing such a distinct type also receive
structural equality. Comparison availability must preserve the distinct
identity, while layout and lowering may still query its representation.

### Deep pointer types bypass runtime type validation

[design.md "Interfaces as reusable constraints"](design.md#interfaces-as-reusable-constraints)
makes an interface declaration compile-time metadata, rather than a runtime
value type. Adding pointer layers must not turn it into a supported storage
type. This generates a minimal rejected type inside 33 pointer layers:

```powershell
$source = 'package main; I :: interface($Self: type) {} ' +
    'main :: proc() { value: ' + ('^' * 33) + 'I = nil; _ = value; }'
New-Item -ItemType Directory -Path tests/tmp -Force | Out-Null
Set-Content -LiteralPath tests/tmp/deep-interface.loke -Value $source -Encoding ASCII
.\lokec.exe tests/tmp/deep-interface.loke -emit-ll
```

The compiler accepts it and emits LLVM IR. The same program with 32 pointer
layers is rejected with `L0350`. `type_is_supported_depth` in
[src/semantic.odin](src/semantic.odin) returns `true` past depth 32 before
inspecting the remaining component. Use type-identity cycle detection rather
than treating every sufficiently deep shape as supported; the related invalid
component and compile-time-only component walks need the same treatment.

### Compile-time indexing bypasses user operators

[design.md "Indexing and slicing"](design.md#indexing-and-slicing) and
["Compile-time procedure evaluation"](design.md#compile-time-procedure-evaluation)
require an evaluated indexing expression to call its resolved operator.
`src/eval.odin` instead indexes the receiver's stored fields, ignoring the
operator and any additional indices. This program prints `3 103`:

```odin
package main;
import "core:fmt";
Box :: struct { value: int }
impl Box {
	get :: operator([]) proc(self: Box, index: int) -> int {
		return self.value + index + 100;
	}
}
compute :: proc() -> int { box := Box{3}; return box[0]; }
VALUE :: compute();
main :: proc() { fmt.println(VALUE, compute()); }
```

Both results should be `103`. The evaluator must dispatch the checked indexing
operator rather than treat its receiver as a built-in sequence.

### Compile-time multiple map assignment loses earlier writes

[design.md "Evaluation order"](design.md#evaluation-order) requires all
assignment destinations to be prepared before any write. Preparing an absent
map key in `src/eval.odin` replaces the map's element storage, leaving a
previously prepared destination pointing into the old storage. This program
prints `20 1020`:

```odin
package main;
import "core:fmt";
compute :: proc() -> int {
	m: map[int]int = {};
	m[1], m[2] = 10, 20;
	return m[1] * 100 + m[2];
}
VALUE :: compute();
main :: proc() { fmt.println(VALUE, compute()); }
```

Both results should be `1020`. Prepared map destinations must continue to name
the live entries after later destination evaluation grows the same map.

### Compile-time map literals evaluate values before keys

[design.md "Evaluation order"](design.md#evaluation-order) requires literal
elements to evaluate in source order. `src/eval.odin` evaluates and copies a
map entry's value before evaluating its key; runtime emission evaluates the
key first. This program prints `1 20`:

```odin
package main;
import "core:fmt";
next :: proc(n: inout int) -> int { n += 1; return n; }
compute :: proc() -> int {
	n := 0;
	m := map[int]int{next(inout n) = next(inout n)};
	return (m.lookup_value(1) or_else 0) * 10 +
	       (m.lookup_value(2) or_else 0);
}
VALUE :: compute();
main :: proc() { fmt.println(VALUE, compute()); }
```

Both results should be `20`: the key is `1` and its value is `2`.

### Compile-time evaluation treats static storage as lexical locals

[design.md "Storage modifiers"](design.md#storage-modifiers) gives `static`
and `thread_local` bindings persistent storage. Such mutable runtime state
cannot be read or modified during
["Compile-time procedure evaluation"](design.md#compile-time-procedure-evaluation).
`src/eval.odin` ignores the duration of a local declaration, allocates a fresh
slot in each call, and accepts this program, which prints `2 3`:

```odin
package main;
import "core:fmt";
next :: proc() -> int {
	n: static int = 0;
	n += 1;
	return n;
}
VALUE :: next() + next();
main :: proc() { fmt.println(VALUE, next() + next()); }
```

`VALUE` must be rejected because its evaluation modifies and reads `n`.
The same declaration path also handles `thread_local` bindings.

### Compile-time ranges with very negative lengths are nonempty

[design.md "Ranges"](design.md#ranges) and
["foreach statement"](design.md#foreach-statement) require a range whose high
endpoint precedes its low endpoint to yield nothing. In `src/eval.odin`, a
length that does not fit `i64` is replaced with `max(i64)` regardless of its
sign. This program prints `1 0`:

```odin
package main;
import "core:fmt";
compute :: proc(lo, hi: u128) -> int {
	foreach (x in lo ..< hi) { return 1; }
	return 0;
}
VALUE :: compute(1267650600228229401496703205376, 0);
main :: proc() {
	fmt.println(VALUE, compute(1267650600228229401496703205376, 0));
}
```

Both results should be `0`. Negative lengths must be recognized before the
fallback for very large positive ranges.

### Compile-time calls cannot supply an inout result as a place

[design.md "`inout` results"](design.md#inout-results) makes a call returning
`inout T` a place, including during
["Compile-time procedure evaluation"](design.md#compile-time-procedure-evaluation).
`src/eval.odin` copies the returned expression as an ordinary value and has no
call case in its place evaluator. This program fails with `L0341`, "this
expression is not compile-time storage":

```odin
package main;
pick :: proc(x: inout int) -> inout int { return inout x; }
compute :: proc() -> int {
	x := 1;
	pick(inout x) = 9;
	return x;
}
VALUE :: compute();
main :: proc() { }
```

It should compile with `VALUE` equal to `9`. Removing `VALUE` and calling
`compute()` at runtime succeeds and returns `9`.

### Read-only aliases lose their source's suspension

[design.md "Weakening and reborrows"](design.md#weakening-and-reborrows)
requires the mutable source to stay suspended while a read-only reborrow, or a
copy of it, is live. The compiler accepts this program, although the write to
`source` must be rejected:

```odin
package main;
import "core:fmt";

main :: proc() {
    xs := [4]int{1, 2, 3, 4};
    source: []mut int = xs[:];
    view: []int = source;
    copy := view;
    source[0] = 9;
    fmt.println(copy[0]);
}
```

Using `view[0]` directly after the write produces `L0641`, but copying `view`
ends its slot's liveness without extending the reborrow to `copy`.
`live_reborrow_of` in [src/borrow.odin](src/borrow.odin) follows only explicit
reborrow edges, so it misses live read-only aliases. Taking an element pointer
through a read-only pointer reborrow has the same problem: a later
`source^.append(...)` can reallocate storage that the element pointer still
names.

### Publishing a mutable carrier does not suspend it

[design.md "Weakening and reborrows"](design.md#weakening-and-reborrows)
also applies when a mutable carrier is stored in a record field through a
pointer. The compiler accepts this program, although `source^.append(2)` must
be rejected while `element` is live:

```odin
package main;
import "core:fmt";

Holder :: struct { view: ^mut [dynamic]int }

main :: proc() {
    xs := [dynamic]int{1};
    source := &mut xs;
    holder: Holder = {};
    target := &mut holder;
    target.view = source;
    element := &holder.view^[0];
    source^.append(2);
    fmt.println(element^);
}
```

The append may reallocate the array and leave `element` dangling. Replacing
`target.view = source` with `holder.view = source` produces `L0641`.
`publish_into_loan` in [src/borrow.odin](src/borrow.odin) joins the published
loans into the resolved destination slots, but does not connect those slots
to the mutable source's reborrow lifetime.

Both reproductions were confirmed with a compiler built from the source tree
on 2026-10-02, using `-emit-ll`; both wrongly exit successfully. The 108
compiler unit tests pass without covering these cases.

### Procedure-literal calls are rejected in constant initializers

[grammar.md "Declarations"](grammar.md#declarations) permits an expression
constant, and ["Primary expressions"](grammar.md#primary-expressions) permits
a procedure literal followed by call suffixes. `parse_constant_value` in
[src/parser.odin](src/parser.odin) returns immediately after parsing the
procedure body, so this valid program fails with `L0206` at the call's `(`:

```odin
package main;
VALUE :: proc() -> int { return 7; }();
main :: proc() { }
```

It should compile with `VALUE` equal to `7`. Writing
`VALUE :: (proc() -> int { return 7; })();` works, and the unparenthesized
call also works as a variable initializer. A constant initializer must keep
parsing expression suffixes after its procedure literal.

### Generic impl patterns ignore nested concrete arguments

[design.md "Generic types"](design.md#generic-types) and
["Specialization"](design.md#specialization) restrict a generic `impl` to
instances matching its subject. The compiler accepts this program and installs
`only_two` on an instance with three elements:

```odin
package main;
import "core:fmt";
Box :: struct($T: type) { value: T }
impl Box([2]$E) {
    only_two :: proc(self) -> int { return 2; }
}
main :: proc() {
    b: Box([3]int) = {};
    fmt.println(b.only_two());
}
```

The call must report a missing member. `install_one_generic_impl` in
[src/generic.odin](src/generic.odin) accepts a nested pattern as soon as
`match_generic_arg` succeeds, but that matcher leaves concrete components to
procedure overload ranking, which impl installation never performs. The same
path lets `impl Box(Pair(int, $T))` apply to `Box(Pair(bool, int))`.

### Generic method bounds are checked before their parameters bind

[design.md "where clauses"](design.md#where-clauses) evaluates a generic
procedure's bounds when that procedure is instantiated. The compiler rejects
this program with `L0315`, "unknown name `U`", while instantiating `Box(int)`:

```odin
package main;
import "core:fmt";
Box :: struct($T: type) { value: T }
impl Box($T) {
    echo :: proc(self, value: $U) -> U where size_of(U) > 0 { return value; }
}
main :: proc() {
    b: Box(int) = {};
    fmt.println(b.echo(7));
}
```

It should compile: `U` is `int` at the method call. The equivalent method in
an ordinary, non-generic impl compiles. `exclude_member_on_failed_bound` in
[src/generic.odin](src/generic.odin) checks every method's bounds during block
installation, including methods that still need their own generic arguments.
Such dependent bounds must wait for method instantiation.

### Omitted compile-time defaults do not infer their type binding

[design.md "Default values"](design.md#default-values) requires an omitted
`$` argument's default to be evaluated like a written argument. The compiler
rejects this program with `L0437`, "`$I` is not bound here":

```odin
package main;
import "core:fmt";
identity :: proc($N: $I = 3) -> I { return N; }
main :: proc() { fmt.println(identity(), identity(4)); }
```

Both calls should compile, with `I` inferred as `int`, and print `3 4`.
Calling only `identity(4)` compiles. The omitted-argument branch of
`infer_generic_arguments` in [src/generic.odin](src/generic.odin) binds `N`
without performing the type inference that its written-argument branch does
for `$I`.

### Dependent generic parameter types retain another instance's annotations

[design.md "Generic data types"](design.md#generic-data-types) and
["Generic argument identity"](design.md#generic-argument-identity) require
each value argument to use its parameter type after the preceding arguments
have bound. The compiler rejects the second application here with `L0432`,
claiming that its `[3]int` argument must fit `[2]int`:

```odin
package main;
import "core:fmt";
Buffer :: struct($N: int, $V: [N]int) { values: [N]int }
main :: proc() {
    a: Buffer(2, [2]int{1, 2}) = {};
    b: Buffer(3, [3]int{3, 4, 5}) = {};
    fmt.println(a.values.len(), b.values.len());
}
```

It should compile and print `2 3`; the second application compiles in isolation.
Conversely, after the first application, an invalid
`Buffer(3, [2]int{3, 4})` is accepted. `instantiate_record_application` in
[src/generic.odin](src/generic.odin) resolves the template's shared parameter
syntax, whose `[N]int` node caches its first `denoted_type`. Resolving a fresh
copy for each application would keep the parameter type specific to its
bindings. Procedure inference shares this defect: successive calls to
`proc($N: int, $V: [N]int)` also reuse the first array length.

These four generic gaps were confirmed with a compiler built from the source
tree on 2026-10-02, using `-emit-ll`. All 108 compiler unit tests pass without
covering these cases.

### A last-use transfer in one defer expansion changes every exit

[design.md "Last-use transfer"](design.md#last-use-transfer) requires a copy
to remain a clone if any path reads its source again. `emit_cleanups` in
[src/cfg.odin](src/cfg.odin) walks one deferred AST at each exit, but
`settle_last_uses` rewrites that shared AST as soon as one expansion qualifies
for a move. Other expansions still have their original lifecycle `Use` event
even though emission now moves the source at those exits too:

```odin
package main;
import "core:fmt";
check :: proc(early: bool) {
    xs := [dynamic]int{1};
    {
        defer { copy := xs; fmt.println("copy", copy); }
        if (early) { return; }
    }
    fmt.println("source", xs);
}
main :: proc() { check(false); }
```

This compiles and prints `copy [1]` followed by `source []`; the source must
still contain `[1]` on the continuing path. Last-use eligibility must account
for every expansion of the same copy site before changing the shared node,
and the lifecycle events must agree with the resulting operation.

### A split for condition loses its effects before the body and exit

[design.md "Variable declarations"](design.md#variable-declarations) requires
a local to be live on every path to a use. In `walk_flow_for` in
[src/cfg.odin](src/cfg.odin), walking a short-circuit, conditional, or
`or_else` condition can advance `graph.current` to a new block, but the body
and done edges still leave the original `head`. Effects in the newly created
condition blocks do not reach either successor:

```odin
package main;
import "core:fmt";
consume :: proc(xs: move [dynamic]int) -> bool { return false; }
main :: proc() {
    xs := [dynamic]int{1};
    ready := true;
    for (ready && consume(move(xs))) { }
    fmt.println(xs);
}
```

This compiles and prints `[]`. The use after the loop must be rejected: the
condition may have consumed `xs`. Both edges must leave the block reached
after evaluating the condition, preserving its lifecycle and provenance
events, rather than bypassing those blocks.

### Multiple assignment initializes a local before later destinations are prepared

[design.md "Evaluation order"](design.md#evaluation-order) prepares every
destination before any write, and
["Variable declarations"](design.md#variable-declarations) forbids reading
an uninitialized local. `walk_flow_assign` in
[src/cfg.odin](src/cfg.odin) emits each destination's `Assign` event before
walking later destination expressions:

```odin
package main;
main :: proc() {
    index: int;
    xs := [1]int{0};
    index, xs[index] = 0, 1;
}
```

This wrongly compiles. The emitted LLVM loads `index` before its first store,
but the lifecycle graph treats it as initialized at that load. Conversely,
a move in a later destination can leave an earlier destination dead in the
graph even though the subsequent writes revive it. Destination preparation
must precede every assignment event.

### Deferred assignments share the last expansion's destination liveness

[design.md "Managed values and storage"](design.md#managed-values-and-storage)
and ["Assignment statements"](design.md#assignment-statements) require an
assignment to drop its destination's previous value only when that value is
live. `emit_cleanups` in [src/cfg.odin](src/cfg.odin) reuses one deferred
assignment node across exits. `report_events` in
[src/lifecycle.odin](src/lifecycle.odin) overwrites that node's
`destination_live` with each expansion's state, so the last reported state
controls emission at every exit:

```odin
package main;
import "core:fmt";
Tracked :: struct { id: int }
impl Tracked {
    release :: hook(drop) proc(self: inout Tracked) {
        fmt.println("drop", self.id);
    }
}
check :: proc(early: bool) {
    value := Tracked{1};
    {
        defer value = Tracked{2};
        if (early) { drop(value); return; }
    }
}
main :: proc() { check(false); }
```

This prints only `drop 2`; it must print `drop 1` before `drop 2`. The return
expansion sees the destination dead and suppresses the continuing path's
required drop too. With an allocating resource, this leaks the old value.
The expansion states must be reconciled with a runtime flag where they differ,
or retained separately for emission at their respective exits.

### Non-managed move parameters are not tracked for liveness

[design.md "Variable declarations"](design.md#variable-declarations) and
["Parameter semantics and ABI lowering"](design.md#parameter-semantics-and-abi-lowering)
make a moved or dropped variable dead regardless of its type.
`track_move_parameters` in [src/cfg.odin](src/cfg.odin) registers only managed
parameters, so consuming a non-managed `move` parameter produces no lifecycle
kill event:

```odin
package main;
import "core:fmt";
check :: proc(value: move int) { drop(value); fmt.println(value); }
main :: proc() { check(7); }
```

This wrongly compiles. The same use of a dropped ordinary `int` local is
rejected. Every `move` parameter needs liveness tracking; only managed ones
need an automatic cleanup registration.

### Returning a scalar kills the local before deferred reads

[design.md "Parameter semantics and ABI lowering"](design.md#parameter-semantics-and-abi-lowering)
transfers managed locals into a result; returning an ordinary scalar copies
its value. ["defer statement"](design.md#defer-statement) runs deferred code
after the result is taken. The return branch in `walk_flow_stmt` in
[src/cfg.odin](src/cfg.odin) emits a `Kill` for every bare tracked local whose
return needs no clone, including an `int`:

```odin
package main;
import "core:fmt";
check :: proc() -> int {
    value := 7;
    defer fmt.println(value);
    return value;
}
main :: proc() { fmt.println(check()); }
```

This wrongly reports `L0500` at the deferred read. It should print `7` twice.
LLVM emission already restricts the implicit return kill to managed values;
the lifecycle walk must follow the same rule.

### Diverging calls leave a fallthrough path in the lifecycle graph

[design.md "Diverging procedures"](design.md#diverging-procedures) ends
reachable execution at a direct `-> !` call. `walk_flow_call` in
[src/cfg.odin](src/cfg.odin) walks such a call without terminating the graph's
current path, so the branch containing it still reaches the merge:

```odin
package main;
import "core:fmt";
import "core:os";
stop :: proc() -> ! { os.exit(0); }
check :: proc(done: bool) {
    value: int;
    if (done) { stop(); } else { value = 7; }
    fmt.println(value);
}
main :: proc() { check(false); }
```

This wrongly reports `L0500`, claiming that `value` is live on only some
paths. Every path that reaches the print has initialized it. Both lifecycle
and provenance graphs must stop fallthrough after a diverging call while
preserving the call's argument effects and any applicable unwind behavior.

These seven CFG gaps were reproduced with a compiler built from the source
tree on 2026-10-02. The four invalid or rejected-program cases were checked
with `-emit-ll`; the deferred-copy, for-condition, and deferred-assignment
cases were also compiled and executed. All 108 compiler unit tests pass
without covering these cases.

### Pointer transmutation emits integer casts for non-integer types

[design.md "`unsafe.transmute`"](design.md#unsafetransmute) permits equal-size,
bitwise-copyable representations, including arrays and unchecked pointers.
This valid program passes checking but fails in Clang with `L0403`:

```odin
package main;
import "core:fmt";
import "core:unsafe";
bytes_of :: proc(p: rawptr) -> [8]u8 {
    return unsafe.transmute([8]u8, p);
}
main :: proc() { fmt.println(bytes_of(nil)[0]); }
```

On the 64-bit target it should print `0`. `reinterpret_bits` in
[src/emit_llvm_expr.odin](src/emit_llvm_expr.odin) emits
`ptrtoint ptr ... to [8 x i8]`, although that instruction requires an integer
destination. Transmuting the pointer to `f64` likewise emits an invalid
`ptrtoint ... to double`; the reverse path selects `inttoptr` without requiring
an integer source. These shapes need storage reinterpretation or an intermediate
integer of the pointer's width.

### Large transmutation treats address values as aggregate registers

[design.md "`unsafe.transmute`"](design.md#unsafetransmute) also permits this
equal-size conversion between two array layouts:

```odin
package main;
import "core:fmt";
import "core:unsafe";
words_of :: proc(a: [1024]u64) -> [2048]u32 {
    return unsafe.transmute([2048]u32, a);
}
main :: proc() {
    a: [1024]u64 = {};
    a[0] = 1;
    b := words_of(a);
    fmt.println(b[0]);
}
```

It should print `1`. Large values are represented by snapshot addresses, but
`reinterpret_bits` in [src/emit_llvm_expr.odin](src/emit_llvm_expr.odin) writes
the source with a raw aggregate `store`. Clang rejects the instruction because
its value is a `ptr`, not `[1024 x i64]`. The subsequent raw aggregate load
also fails to preserve the address representation of the destination. The
storage path must use the same typed large-value helpers as ordinary expressions.

### Packed/aligned equality reads discarded capacity

[design.md "Uninitialized capacity"](design.md#uninitialized-capacity) says
that elements outside an `@(initialized)` prefix are storage without values.
This program removes the sole live element from each buffer before comparing:

```odin
package main;
import "core:fmt";
import "core:unsafe";
Buf :: struct @(packed, align=8) {
    count: int,
    @(initialized=count) items: [4]int,
}
main :: proc() {
    a: Buf = {}; b: Buf = {};
    unsafe.write(a.items[0], 1); a.count = 1;
    unsafe.write(b.items[0], 2); b.count = 1;
    a.count = 0; b.count = 0;
    left := unsafe.take(a.items[0]);
    right := unsafe.take(b.items[0]);
    fmt.println(left, right, a == b);
}
```

Expected output is `1 2 true`; actual output is `1 2 false`.
`emit_byte_member_struct_equal` in
[src/emit_llvm_expr.odin](src/emit_llvm_expr.odin) compares the entire array
without consulting `initialized_by`, unlike the ordinary-record paths. With
owning elements, the discarded bits can refer to storage already released by
the values taken out. Byte-member records need the same prefix comparison.

### Packed/aligned equality violates the large-value representation

[design.md "Comparison operators"](design.md#comparison-operators) permits
equality for records containing comparable fixed arrays. This program should
print `true`:

```odin
package main;
import "core:fmt";
Big :: struct @(packed, align=8) { tag: u8, data: [1024]int }
main :: proc() { a: Big = {}; b: Big = {}; fmt.println(a == b); }
```

It instead fails with `L0403`. `emit_byte_member_struct_equal` in
[src/emit_llvm_expr.odin](src/emit_llvm_expr.odin) loads the 8192-byte field as
an LLVM aggregate, then passes it to `emit_equal`, whose large-array path
expects an address. Clang rejects its `getelementptr` because the operand is
`[1024 x i64]` rather than `ptr`. Large fields must retain their address
representation through this equality path too.

### Aggregate equality bypasses nested comparison overloads

[design.md "Comparison operators"](design.md#comparison-operators) makes
array equality element-wise, and
["Operator lookup and overload resolution"](design.md#operator-lookup-and-overload-resolution)
uses default structural equality only when no viable explicit overload exists.
This program defines an equality that deliberately ignores an annotation:

```odin
package main;
import "core:fmt";
Key :: struct { id, annotation: int }
impl Key {
    equal :: operator(==) proc(a, b: Key) -> bool { return a.id == b.id; }
}
Holder :: struct { value: Key }
main :: proc() {
    a := Key{1, 2}; b := Key{1, 3};
    aa := [1]Key{a}; bb := [1]Key{b};
    ah := Holder{a}; bh := Holder{b};
    fmt.println(a == b, aa == bb, ah == bh);
}
```

Expected output is `true true true`; actual output is `true false false`.
The recursive calls in `emit_equal` in
[src/emit_llvm_expr.odin](src/emit_llvm_expr.odin) always compare a nested
record structurally, bypassing its `==` overload. Union payload comparisons
use the same recursion. Nested comparison choices need to be resolved during
checking and honored by emission.

The checker also rejects a valid aggregate comparison when a nested type's
overload makes otherwise non-comparable fields comparable:

```odin
package main;
Box :: struct { items: [dynamic]int }
impl Box {
    equal :: operator(==) proc(a, b: Box) -> bool {
        return a.items.len() == b.items.len();
    }
}
Outer :: struct { box: Box }
main :: proc() {
    a, b: Outer = {}, {};
    assert(a.box == b.box);
    assert(a == b);
}
```

The direct `Box` comparison is accepted, but the `Outer` comparison reports
`L0355`. `type_is_comparable` in [src/semantic.odin](src/semantic.odin)
recurses into the dynamic array instead of considering the visible `Box`
operator. Arrays and union payloads follow the same query. Comparison
availability and the selected nested operation must both be resolved in the
checker, with the current package's operator visibility.

### Pointer-bearing union and packed/aligned constants are not emitted

[design.md "Unions"](design.md#unions) and
["String views"](design.md#string-views) permit a statically initialized union
containing a view of literal storage:

```odin
package main;
import "core:fmt";
Label :: union { text: string_view, number: int }
label: Label = .text("hi");
main :: proc() { fmt.println(label); }
```

It should compile, but fails with `L0405`, "a union payload constant cannot be
represented as bytes: string_view in Label". A combined packed/aligned record
has the same failure:

```odin
package main;
import "core:fmt";
Label :: struct @(packed, align=8) { tag: u8, text: string_view }
label: Label = {1, "hi"};
main :: proc() { fmt.println(label.text); }
```

The diagnostic is "a combined packed/aligned constant has a value that cannot
be represented as bytes". `union_constant` and `write_field_bytes` in
[src/emit_llvm_expr.odin](src/emit_llvm_expr.odin) require a plain byte image,
but `write_const_bytes` cannot represent a relocation to literal storage.
These layouts need constant emission that preserves pointer relocations.

### Empty string slices bypass UTF-8 endpoint validation

[design.md "String views"](design.md#string-views) requires each slice bound
to fall at a UTF-8 sequence start or the text's end, even when the slice is
empty. This program puts both bounds inside a two-byte sequence:

```odin
package main;
import "core:fmt";
main :: proc() {
    text: string_view = "\u00e9";
    offset := 1;
    fmt.println(text[offset:offset].len());
}
```

It should panic, but prints `0` and exits successfully. `emit_text_subrange`
in [src/emit_llvm_expr.odin](src/emit_llvm_expr.odin) validates only the bytes
of the resulting view; the UTF-8 validator accepts any empty range. Endpoint
validation must also reject an empty view whose offset is a continuation byte.

### Packed owner-to-view conversions lose field alignment

[design.md "@(packed)"](design.md#packed) permits reading fields with byte
alignment. Both owner-to-view conversions in this valid program must read
their headers at that alignment:

```odin
package main;
import "core:fmt";
Packed :: struct @(packed) { tag: u8, text: string, data: [dynamic]int }
main :: proc() {
    p := Packed{1, "hello", {3, 4}};
    text: string_view = p.text;
    data: []int = p.data;
    fmt.println(text, data[1]);
}
```

`emit_expr_at` in [src/emit_llvm_expr.odin](src/emit_llvm_expr.odin) uses raw
`load` for the `string` and dynamic-array headers. Their field addresses are
tracked as byte-aligned, but the emitted loads omit `align 1`, promising LLVM
the header types' ordinary alignment. The string field starts at byte 1 and
the dynamic-array field at byte 25 on the tested 64-bit target. These loads
need the alignment-aware place helper. The program currently prints `hello 4`
at both the default optimization level and `-opt=speed`; the gap is the
incorrect LLVM alignment contract, not a reproduced runtime failure.

These eight expression-emission gaps were confirmed with a compiler built
from the source tree on 2026-10-02, using Clang builds, runtime probes, and
inspection of emitted LLVM as described above. All 108 compiler unit tests
pass without covering these cases.

### File-scope thread-local values use shared globals and receive no teardown

[design.md "Storage modifiers"](design.md#storage-modifiers) creates one
`thread_local` instance per thread, and
["Values that outlive every scope"](design.md#values-that-outlive-every-scope)
drops managed TLS on normal thread return. `emit_global` in
[src/emit_llvm_runtime.odin](src/emit_llvm_runtime.odin) emits every file-scope
binding as an ordinary LLVM `global`, ignoring its duration.
`emit_thread_local_teardown` also omits these bindings because it walks only
the compiler's list of static-duration locals:

```odin
package main;
import "core:fmt";
import "core:thread";
Tracked :: struct { id: int }
impl Tracked {
    release :: hook(drop) proc(self: inout Tracked) {
        if (self.id != 0) { fmt.println("drop", self.id); }
    }
}
counter: thread_local int;
resource: thread_local Tracked;
worker :: proc() {
    counter = 20;
    resource = Tracked{2};
    fmt.println("worker", counter);
}
main :: proc() {
    counter = 10;
    resource = Tracked{1};
    child := thread.spawn(worker);
    child.join();
    fmt.println("main", counter);
}
```

Expected output is `worker 20`, `drop 2`, `main 10`, `drop 1`. Actual output
is `drop 1`, `worker 20`, `main 20`: the worker overwrites the main thread's
instances, and neither thread receives its required teardown. The emitted
module declares ordinary globals and its TLS cleanup body is empty. File-scope
TLS must use LLVM thread-local storage and participate in the same ordered
teardown as local TLS.

### Converting a runtime nil pointer retains a dyn witness

[design.md "Borrowed dynamic interface values"](design.md#borrowed-dynamic-interface-values)
requires conversion of a nil concrete pointer to produce a nil view with no
witness, and a slot call on that view to panic. `emit_dyn_value` in
[src/emit_llvm_runtime.odin](src/emit_llvm_runtime.odin) checks only whether
the checker supplied a witness, which recognizes an untyped literal `nil`.
A typed pointer that is nil at runtime still gets the concrete witness:

```odin
package main;
import "core:fmt";
Reader :: interface($Self: type) { slot read: proc(self: ^) -> int; }
Box :: struct {}
impl Box { read :: proc(self: ^) -> int { return 7; } }
erase :: proc(pointer: ^Box) -> dyn Reader {
    return (dyn Reader)(pointer);
}
main :: proc() {
    pointer: ^Box = nil;
    view := erase(pointer);
    fmt.println(view == nil);
    fmt.println(view.read());
}
```

This prints `false` and `7` and exits successfully. It must print `true` and
then panic on the slot call. A method that accesses its receiver can instead
read through the null data pointer, because slot dispatch checks only the
witness. Conversion must clear the witness when its evaluated pointer is nil.

### Large any-view extraction produces aggregate registers instead of snapshots

[design.md "any_view type"](design.md#any_view-type) permits checked extraction
of a copyable erased value. `emit_any_view_extract` in
[src/emit_llvm_runtime.odin](src/emit_llvm_runtime.odin) loads the payload with
raw `load`, bypassing the address representation described by
[compiler-architecture.md "LLVM and toolchain"](compiler-architecture.md#llvm-and-toolchain):

```odin
package main;
import "core:fmt";
main :: proc() {
    source: [1024]int = {};
    source[0] = 7;
    view: any_view = source;
    copy := view.([1024]int);
    fmt.println(copy[0]);
}
```

This valid program fails with `L0403`: the emitted `load [1024 x i64]` yields
an aggregate, but the subsequent large-value `memcpy` requires a pointer.
Replacing the extraction with
`view.as([1024]int) or_else [1024]int{}` fails the same way when wrapping its
success payload. Both paths must use the typed load/snapshot helper; both
programs should print `7`.

### Large variant constructors used as procedure values omit the result ABI

[design.md "Constructing a variant"](design.md#constructing-a-variant) makes
a payload variant's `U.name` a procedure value of type
`proc(payload: move P) -> U`. `emit_synth_variant_construct` in
[src/emit_llvm_runtime.odin](src/emit_llvm_runtime.odin) always declares a
direct aggregate return and emits raw `ret`, even when the union is large
and must return through a leading `sret` pointer:

```odin
package main;
import "core:fmt";
Big :: struct { values: [1024]int }
Value :: union { big: Big, absent: }
main :: proc() {
    construct := Value.big;
    value := construct(Big{});
    switch (payload in value) {
    case .big: fmt.println(payload.values[0]);
    case .absent: fmt.println(-1);
    }
}
```

This valid program fails with `L0403`: the constructor returns its pointer
snapshot as though it were a `%union.Value` aggregate. Its declaration also
disagrees with the indirect call's result ABI. It should print `0`. The
constructor must use the common result-signature and return helpers, including
`sret_param` and `emit_ret`.

### Default struct formatting loses packed-field alignment

[design.md "@(packed)"](design.md#packed) permits byte-aligned fields, and
["String format printing"](design.md#string-format-printing) supplies default
formatting for public fields. `emit_format_struct` in
[src/emit_llvm_runtime.odin](src/emit_llvm_runtime.odin) passes a packed
field's address directly to its ordinary type formatter, whose raw loads
assume the type's ABI alignment:

```odin
package main;
import "core:fmt";
Packed :: struct @(packed) {
    @(public) tag: u8,
    @(public) value: u64,
}
main :: proc() { value := Packed{1, 123}; fmt.println(value); }
```

The generated packed-record formatter passes its field at byte offset 1 to
the `u64` formatter, which emits `load i64, ptr %data` without `align 1`.
An omitted load alignment promises ABI alignment; overstating alignment is
undefined behavior under the
[LLVM load contract](https://llvm.org/docs/LangRef.html#load-instruction).
The reproduction currently prints `Packed{tag = 1, value = 123}`; this finding
is the incorrect LLVM alignment contract, not an observed runtime failure.
Copy under-aligned fields to aligned storage before calling their formatters,
and preserve alignment for live-prefix counter reads and array elements too.

These five runtime-emission gaps were reproduced with a compiler built from
the source tree on 2026-10-02, using executable builds and LLVM inspection.
All 108 tracked compiler unit tests and `runtime_abi_matches_header` pass
without covering them.

### Nested calls in defaults lose earlier parameter bindings

[design.md "Default values"](design.md#default-values) and
["Evaluation order"](design.md#evaluation-order) allow a default to read a
parameter to its left. `emit_bound_call` in
[src/emit_llvm_calls.odin](src/emit_llvm_calls.odin) replaces `e.param_values`
before evaluating a nested call's supplied arguments, hiding the enclosing
call's already-bound parameters:

```odin
package main;
import "core:fmt";
identity :: proc(x: int) -> int { return x; }
choose :: proc(a: int, b: int = identity(a)) -> int { return b; }
main :: proc() { fmt.println(choose(7)); }
```

This should print `7`. `-emit-ll` succeeds, but the default's `a` becomes a
load from `choose`'s local `%p0` inside `main`; LLVM rejects the undefined
value and the executable build reports `L0403`. Preserve the enclosing
bindings while evaluating nested supplied arguments, and keep each call's
default bindings scoped to that call.

### Variadic packs accumulate stack storage in loops

[design.md "Variadic parameters"](design.md#variadic-parameters) permits
mixed scalar and spread arguments. `emit_variadic_pack` in
[src/emit_llvm_calls.odin](src/emit_llvm_calls.odin) emits runtime-sized
`alloca` instructions at the call site without releasing their stack storage
after the call. A loop therefore retains every iteration's pack until its
containing procedure returns:

```odin
package main;
import "core:fmt";
sum :: proc(values: ..int) -> int {
    result := 0;
    foreach (v in values) { result += v; }
    return result;
}
main :: proc() {
    values := [2]int{2, 3};
    total := 0;
    for (i := 0; i < 200000; i += 1) {
        total += sum(1, ..values[:]);
    }
    fmt.println(total);
}
```

At the default optimization level on Windows x64 this exits with stack
overflow (`0xC00000FD`) instead of printing `1200000`. The same program with
1000 iterations prints `6000`. Managed packs also allocate their cleanup
flags at the call site, including packs without spreads. Reclaim runtime
pack storage after its last use and cleanup, and hoist fixed-size flags into
the entry block.

### Allocation cloning skips the source temporary's cleanup

[design.md "Allocators"](design.md#allocators) requires `new_clone` to
construct a clone, while
["Temporaries and procedure boundaries"](design.md#temporaries-and-procedure-boundaries)
ends the source temporary's lifetime at the complete expression.
`emit_allocation_pair` and `emit_new_clone_hook` in
[src/emit_llvm_calls.odin](src/emit_llvm_calls.odin) evaluate the source with
`emit_expr` without registering its cleanup:

```odin
package main;
import "core:fmt";
Res :: struct { id: int }
impl Res {
    copy_res :: hook(copy) proc(self, allocator: Allocator) -> Result(Res, Allocator_Error) {
        return .ok(Res{self.id + 100});
    }
    release :: hook(drop) proc(self: inout Res) { fmt.println("drop", self.id); }
}
build :: proc() -> Res { return Res{1}; }
main :: proc() {
    p := new_clone(build());
    fmt.println(p^.id);
    free(p);
    fmt.println("done");
}
```

This prints `101` and `done`, omitting `drop 1` before `101`. The original
owner is neither transferred into the clone nor destroyed, so resources it
owns leak. `try_new_clone` shares these paths. Register owned source
temporaries before evaluating the allocator or invoking the copy hook, and
clean them up on both normal completion and unwinding.

### Hashing large fixed arrays violates the address representation

[design.md "Standard interface catalogue"](design.md#standard-interface-catalogue)
makes fixed arrays of hashable elements `Hashable`.
`emit_hash_value` in [src/emit_llvm_calls.odin](src/emit_llvm_calls.odin)
unconditionally uses `extractvalue` for an array, but backend values larger
than 4096 bytes are represented by an address:

```odin
package main;
import "core:fmt";
main :: proc() {
    key: [513]int = {};
    fmt.println(key.hash(0));
}
```

This should compile and print the array's hash. Instead LLVM rejects
`extractvalue [513 x i64] %t, 0` because `%t` has type `ptr`, and the build
reports `L0403`. Large fixed-array map keys also use this hashing path.
Read elements through their addresses when the array uses the large-value
representation, including nested large arrays.

These four call-emission gaps were reproduced with a compiler built from
the source tree on 2026-10-02. All 24 tests in `src/emit_llvm_test.odin` pass
with memory tracking and both compiler vets enabled; they do not cover these
reproductions.

### Explicit drop remains registered while its hook runs

[design.md "Lifecycle hooks and resource types"](design.md#lifecycle-hooks-and-resource-types)
requires a drop hook to run exactly once per completed initialization.
`emit_explicit_drop` in
[src/emit_llvm_cleanup.odin](src/emit_llvm_cleanup.odin) calls
`emit_drop_place` before `kill_place` clears the owner's unwind registration:

```odin
package main;
import "core:fmt";
Tracked :: struct { id: int }
impl Tracked {
    release :: hook(drop) proc(self: inout Tracked) {
        if (self.id == 0) { return; }
        fmt.println("drop", self.id);
        if (self.id == 2) { panic("explicit drop failed"); }
    }
}
yes :: proc() -> bool { return true; }
main :: proc() {
    first := Tracked{1};
    second := Tracked{2};
    if (yes()) { drop(second); }
}
```

This prints `drop 2` twice and aborts with `panic while unwinding a panic`,
skipping `drop 1`. The conditional explicit drop leaves an implicit drop
needed on the other path, so its live unwind action reenters the same hook.
Clear that action before invoking the hook, while keeping the value intact
for the hook to read; write the inert zero after normal completion.

### Deferred statements leak addressed owning temporaries

[design.md "Evaluation order"](design.md#evaluation-order) requires a
complete expression's temporaries to be destroyed at its end.
`run_one_cleanup` and `emit_unwind_thunk` in
[src/emit_llvm_cleanup.odin](src/emit_llvm_cleanup.odin) replay deferred
statements with `emit_stmt` without opening and draining their own temporary
frame:

```odin
package main;
import "core:fmt";
Tracked :: move_only struct { id: int, items: [dynamic]int }
impl Tracked {
    release :: hook(drop) proc(self: inout Tracked) {
        if (self.id != 0) { fmt.println("drop", self.id); }
    }
}
build :: proc() -> Tracked { return Tracked{2, [dynamic]int{7}}; }
work :: proc() {
    earlier := Tracked{1, [dynamic]int{}};
    defer fmt.println(build().items[0]);
}
main :: proc() { work(); }
```

This prints `7` and `drop 1`, omitting `drop 2` between them. Addressing the
temporary's `items` registers its cleanup after the current cleanup walk
has taken its entries, so that walk never reaches it. During panic replay
there is no enclosing cleanup scope to register it in at all: replacing
`work`'s normal exit with `panic("begin unwinding")` also omits `drop 2`.
Repeated calls leak the temporary's owned array on normal exits. Give each
replayed deferred statement a complete-expression temporary frame and drain
it before continuing the surrounding cleanup walk.

### Generated clones omit panic cleanup for completed parts

[design.md "What the unwind runs, and what it does not"](design.md#what-the-unwind-runs-and-what-it-does-not)
requires partial construction to release resources whose initialization
completed. Copy hooks may panic for ordinary faults under
["Lifecycle hooks and resource types"](design.md#lifecycle-hooks-and-resource-types).
`emit_synth_try_clone` in
[src/emit_llvm_cleanup.odin](src/emit_llvm_cleanup.odin) cleans earlier
parts when a later hook returns `.err`, but creates no unwind frame or
registrations for a panic raised by that hook:

```odin
package main;
import "core:fmt";
Tracked :: struct { id: int }
impl Tracked {
    copy_owned :: hook(copy) proc(self, allocator: Allocator) -> Result(Tracked, Allocator_Error) {
        fmt.println("copy", self.id);
        if (self.id == 2) { panic("copy failed"); }
        return .ok(Tracked{self.id + 100});
    }
    release :: hook(drop) proc(self: inout Tracked) {
        if (self.id != 0) { fmt.println("drop", self.id); }
    }
}
Pair :: struct { first: Tracked, second: Tracked }
main :: proc() {
    source := Pair{Tracked{1}, Tracked{2}};
    cloned := source.clone();
    fmt.println(cloned.first.id);
}
```

This prints `copy 1`, `copy 2`, `drop 2`, and `drop 1`, omitting `drop 101`
before the source's drops. The successfully cloned first field leaks.
Fixed-array and initialized-prefix clones share the absence of panic
registration. Register completed destination parts for unwinding and
transfer or clear those registrations only after completion or explicit
failure cleanup; the incomplete containing record's custom drop must not
run.

### A panicking field drop skips the record's remaining fields

[design.md "Lifecycle hooks and resource types"](design.md#lifecycle-hooks-and-resource-types)
drops fields in reverse declaration order.
["What the unwind runs, and what it does not"](design.md#what-the-unwind-runs-and-what-it-does-not)
requires live owners to be cleaned up during a panic. In
[src/emit_llvm_cleanup.odin](src/emit_llvm_cleanup.odin),
`run_one_cleanup` clears the containing owner's unwind action before
`emit_drop_place` starts its recursive field drops, and those remaining
fields have no separate unwind registrations:

```odin
package main;
import "core:fmt";
Tracked :: struct { id: int }
impl Tracked {
    release :: hook(drop) proc(self: inout Tracked) {
        if (self.id == 0) { return; }
        fmt.println("drop", self.id);
        if (self.id == 2) { panic("field drop failed"); }
    }
}
Pair :: struct { first: Tracked, second: Tracked }
main :: proc() {
    source := Pair{Tracked{1}, Tracked{2}};
}
```

Normal scope exit prints `drop 2`, panics, and terminates without `drop 1`.
The panic starts during ordinary cleanup, so the rule aborting a second
panic during panic unwinding does not apply. The same issue affects fixed
arrays and initialized prefixes. Preserve cleanup progress so that a
first panic still releases pending fields or elements without replaying
the hook that raised it.

### Lifecycle operations lose packed-field alignment

[design.md "Record layout attributes"](design.md#record-layout-attributes)
requires packed fields to load and store unaligned. `element_address` in
[src/emit_llvm_cleanup.odin](src/emit_llvm_cleanup.odin) computes field
addresses without recording their effective alignment, so generated
field-wise cloning uses ordinary ABI-aligned loads and stores. Intrinsic
string dropping also uses `load` rather than `load_place`:

```odin
package main;
import "core:fmt";
Packed :: struct @(packed) { tag: u8, text: string, value: int }
main :: proc() {
    value := Packed{3, "hello" + " world", 7};
    cloned := value.clone();
    fmt.println(cloned.text, cloned.value, value.value);
}
```

With `-emit-ll`, `Packed.try_clone` loads and stores `%loke.string` at field
offset 1 and `i64` at offset 25 without `align 1`. Both ordinary scope exit
and the unwind thunk also load the string at offset 1 without `align 1`.
An omitted alignment means the loaded type's ABI alignment, eight bytes
here; overstating it is undefined behavior under the
[LLVM load contract](https://llvm.org/docs/LangRef.html#load-instruction).
The executable prints `hello world 7 7` at `-opt=speed` on Windows x64, but
that does not make the emitted alignment guarantees valid. Carry packed
alignment through lifecycle field and element addresses and use place-aware
loads and stores, including intrinsic drops.

These five cleanup-emission gaps were reproduced with a compiler rebuilt
from the source tree on 2026-10-02. All 108 compiler unit tests pass with
memory tracking and compiler vets enabled; those tests do not cover these
reproductions.

### Foreach bindings bypass duplicate-name and shadowing checks

[design.md "Variable declarations"](design.md#variable-declarations) requires
unique names in each local scope and rejects shadowing an outer local or
parameter. `bind_loop_name` in [src/iterate.odin](src/iterate.odin) checks
reserved names but inserts a symbol into the scope without either check:

```odin
package main;
import "core:fmt";
main :: proc() {
    values := [1]int{7};
    foreach (same, same in values.indexed()) { fmt.println(same); }
    name := 42;
    foreach (name in values) { fmt.println(name); }
    fmt.println(name);
}
```

Both headers should be diagnosed. Instead this compiles and prints `0`, `7`,
and `42`: the second `same` silently replaces the first binding in lookup,
and the loop's `name` hides the outer local. Apply the declaration checks to
every non-discard leaf, including nested binding groups.

### Mixed record yields mark owned leaves as borrowed

[design.md "Yield modes"](design.md#yield-modes) and
["Element bindings"](design.md#element-bindings) decide ownership per field
of a record yield. `check_protocol_foreach` and `bind_pattern_leaf` in
[src/iterate.odin](src/iterate.odin) instead apply `s.borrows` to every leaf
when any field is lent, including fields `next` hands over as owned values:

```odin
package main;
import "core:fmt";
Owned :: move_only struct { id: int }
impl Owned {
    release :: hook(drop) proc(self: inout Owned) { fmt.println("drop", self.id); }
}
Row :: struct { owned: Owned, lent: int }
Sequence :: struct { values: []int }
Cursor :: struct { values: []int, at: int }
impl Sequence {
    Element :: Row;
    iter :: proc(self) -> Cursor { return {self.values, 0}; }
}
impl Cursor {
    next :: proc(self: inout Cursor) -> Option((owned: Owned, lent: ^int)) {
        if (self.at >= self.values.len()) { return .none; }
        p := &self.values[self.at];
        self.at += 1;
        return .some({owned = Owned{self.at}, lent = p});
    }
}
take :: proc(value: move Owned) { fmt.println("take", value.id); }
main :: proc() {
    values := [1]int{7};
    foreach (owned, lent in Sequence{values[:]}) {
        take(move(owned));
        fmt.println(lent);
    }
}
```

The `owned` leaf should transfer into `take`, which drops it once. Instead
the compiler rejects `move(owned)` with `L0690`, claiming that the source
still owns it. Replacing the body with `fmt.println(owned.id, lent)`
compiles, prints `1 7`, and drops that owned value at the end of the step.
Preserve the yield descriptor through recursive binding and classify each
leaf separately; owned fields must remain movable and droppable even when
their siblings borrow.

### Owned foreach destructuring bypasses custom lifecycle hooks

[design.md "Destructuring"](design.md#destructuring), applied to
["Element bindings"](design.md#element-bindings), rejects consuming a record
with a custom copy or drop hook by taking its fields apart.
`check_foreach_pattern` in [src/iterate.odin](src/iterate.odin) checks only
field shape and visibility, omitting the lifecycle restriction for an owned
yield:

```odin
package main;
import "core:fmt";
Guarded :: struct { first: int, second: int }
impl Guarded {
    release :: hook(drop) proc(self: inout Guarded) { fmt.println("drop", self.first); }
}
Sequence :: struct {}
Cursor :: struct { done: bool }
impl Sequence {
    Element :: Guarded;
    iter :: proc(self) -> Cursor { return {}; }
}
impl Cursor {
    next :: proc(self: inout Cursor) -> Option(Guarded) {
        if (self.done) { return .none; }
        self.done = true;
        return .some(Guarded{7, 9});
    }
}
main :: proc() {
    foreach (first, second in Sequence{}) { fmt.println(first + second); }
    fmt.println("done");
}
```

The header should be rejected. Instead it compiles and prints `16` and
`done`, silently skipping `Guarded.release`. Binding `whole` and reading
`whole.first + whole.second` instead prints `16`, `drop 7`, and `done`.
Enforce the consuming-destructure restriction at each owned record that a
pattern splits, including nested records, while allowing borrowed records
to be projected without consuming them.

### Nested static foreach bindings are dispatched as runtime loops

[design.md "Static `foreach` expansion"](design.md#static-foreach-expansion)
requires `$` bindings to expand at compile time; the
["Element bindings"](design.md#element-bindings) pattern may nest.
The foreach dispatch in [src/check.odin](src/check.odin) inspects only
top-level bindings' `is_static`, although the parser stores each nested
leaf's marker inside its group:

```odin
package main;
import "core:fmt";
Pair :: struct { first: int, second: int }
PAIRS :: [1]Pair{{7, 9}};
main :: proc() {
    foreach (($first, $second) in PAIRS) {
        static_assert(first == 7);
        fmt.println(first + second);
    }
}
```

This should expand once and print `16`. Instead it enters
`check_runtime_foreach` and reports `L0341` on the static assertion because
`first` is a runtime variable. Inspect static markers recursively before
dispatching, so the existing recursive static-pattern validation also
handles nested mixed-mode and reference markers.

These iteration findings were reproduced with a compiler built from the
source tree on 2026-10-02. The existing `m4b_foreach`, `m6b_iteration`,
`foreach_elements`, `foreach_regressions`, `iteration_ownership`,
`derived_iterator`, `readonly_iteration`, and `mutable_iteration` run cases
all compile and match their expected output without covering these cases.

### Procedure groups allow direct lifecycle-hook calls

[design.md "Lifecycle hooks and resource types"](design.md#lifecycle-hooks-and-resource-types)
and ["Conversion hooks"](design.md#conversion-hooks) reserve hooks for their
corresponding language operations. `check_group_call` in
[src/check_calls.odin](src/check_calls.odin) selects and binds a candidate
without applying `reject_direct_hook_call`, although direct calls and method
calls apply that check:

```odin
package main;
import "core:fmt";
Tracked :: struct { id: int }
impl Tracked {
    release :: hook(drop) proc(self: inout Tracked) {
        if (self.id != 0) { fmt.println("drop", self.id); }
    }
    again :: proc{release};
}
main :: proc() {
    value := Tracked{7};
    Tracked.again(inout value);
    fmt.println("after", value.id);
}
```

This should reject access to the hook. Instead it prints `drop 7`, `after 7`,
and `drop 7`: the group invokes the hook without the language's drop
bookkeeping, leaving the same initialization eligible for automatic drop.
Reject a selected hook on the group-call path before binding it, and prevent
procedure groups from exposing hooks as ordinary callable operations.

### Inout arguments undergo value conversions

[design.md "Parameter semantics and ABI lowering"](design.md#parameter-semantics-and-abi-lowering)
defines `inout T` as an exclusive mutable borrow of the caller's variable.
`check_argument_value` in
[src/check_calls.odin](src/check_calls.odin) nevertheless applies ordinary
value materialization to an `inout` operand before checking assignability:

```odin
package main;
import "core:fmt";
fill :: proc(value: inout Simd(i32, 4)) { value = Simd(i32, 4)(9); }
main :: proc() {
    value: i32 = 7;
    fill(inout value);
    fmt.println(value);
}
```

This should reject the argument's type. Instead it prints `7`: the backend
splats the scalar into a temporary vector and passes that temporary's
address, losing the callee's write. The same missing type invariance permits
an `inout ^int` parameter to overwrite a `^mut int` variable with a read-only
pointer:

```odin
package main;
import "core:fmt";
global: int = 1;
replace :: proc(value: inout ^int) { value = &global; }
main :: proc() {
    local := 7;
    pointer := &mut local;
    replace(inout pointer);
    pointer^ = 99;
    fmt.println(global, local);
}
```

This prints `99 7`, obtaining mutable access from a read-only pointer in
conflict with ["Pointers"](design.md#pointers). Check an `inout` operand's
original place type without value conversions, and require invariant types
on direct, overloaded, generic, method, and procedure-value call paths.

### Ordinary inout arguments bypass packed-place validation

[design.md "@(packed)"](design.md#packed) makes a packed field
non-addressable. `check_bound_argument_mode` in
[src/check_calls.odin](src/check_calls.odin) validates only assignability for
an `inout` argument, whereas borrowing arguments and mutating method
receivers also reject packed projections:

```odin
package main;
import "core:fmt";
Packed :: struct @(packed) { tag: u8, value: int }
set :: proc(value: inout int) { value = 42; }
main :: proc() {
    packed := Packed{1, 7};
    set(inout packed.value);
    fmt.println(packed.value);
}
```

This compiles and prints `42` instead of reporting `L0614`. Its LLVM call
passes the field address at byte offset 1 to a callee performing an
ABI-aligned `store i64`, so the unchecked address is also an invalid alignment
promise. A mutating method on a record in the same packed position is
correctly rejected. Apply packed-place validation to every `inout` binding,
including elements reached through a packed array field.

### Overload and method binding loses named-argument evaluation order

[design.md "Evaluation order"](design.md#evaluation-order) evaluates supplied
arguments in written order. `check_group_call` and `check_method_call` in
[src/check_calls.odin](src/check_calls.odin) use `bind_chosen_call` in
[src/overload.odin](src/overload.odin), which fills parameter slots without
recording `bound_order`:

```odin
package main;
import "core:fmt";
mark :: proc(value: int) -> int { fmt.println(value); return value; }
use :: proc(first, second: int) { fmt.println(first, second); }
group :: proc{use};
main :: proc() { group(second = mark(2), first = mark(1)); }
```

This prints `1`, `2`, and `1 2`; the first two lines should be `2` and `1`.
Calling `use` directly produces the required order. A method with the same
two named parameters also evaluates them in parameter order. The backend,
compile-time evaluator, and lifecycle graph all use `call_slot_at` or
`bound_order`, so the missing order affects side effects and borrow/liveness
analysis. Preserve supplied candidate slots in written order, then append
omitted defaults in parameter order when binding the chosen procedure.

### A variadic spread runs after an omitted fixed-parameter default

[design.md "Evaluation order"](design.md#evaluation-order) evaluates all
supplied arguments before omitted defaults. `bind_variadic_arguments` in
[src/check_calls.odin](src/check_calls.odin) records an order only if named
arguments occur, even though a spread can skip a defaulted fixed parameter:

```odin
package main;
import "core:fmt";
mark :: proc(value: int) -> int { fmt.println(value); return value; }
spread :: proc() -> []int { fmt.println(2); return nil; }
use :: proc(first: int = mark(1), rest: ..int) {
    fmt.println(first, rest.len());
}
main :: proc() { use(..spread()); }
```

This prints `1`, `2`, and `1 0`; the first two lines should be `2` and `1`.
With no `bound_order`, parameter-slot order evaluates the default before
the written spread. Record the pack-before-default order even without a
name, retaining the existing order among fixed arguments and among spreads.

### Associated procedure groups lose required-result policy

[design.md "@(require_results)"](design.md#require_results) applies a group's
requirement to calls through that group. `required_result_of_call` in
[src/check_calls.odin](src/check_calls.odin) looks up groups only with
`callee_group`, whose name lookup recognizes free and package-qualified
groups, but not associated groups:

```odin
package main;
Box :: struct {}
impl Box {
    produce :: proc(value: int) -> int { return value; }
    @(require_results) group :: proc{produce};
}
main :: proc() { Box.group(1); }
```

This compiles and discards the result instead of reporting `L0612`. The same
attribute on a free group rejects the call correctly. Preserve the
originating group's result policy when selecting a candidate, including
associated and method groups, rather than recovering it later from only a
subset of callee spellings.

### Type-qualified container calls bypass operation-specific checks

[design.md "Zero values"](design.md#zero-values) requires a zero value for
operations that manufacture one. In
[src/check_calls.odin](src/check_calls.odin), the zero-value requirement for
container growth is applied only by `check_method_call`:

```odin
package main;
import "core:fmt";
Choice :: union { number: int, flag: bool }
main :: proc() {
    values: [dynamic]Choice = {};
    ([dynamic]Choice).resize(inout values, 1);
    fmt.println(values.len(), values[0]);
}
```

This prints `1 .number(0)`, although `Choice` has no zero value. The method
spelling `values.resize(1)` correctly reports `L0424`. The same bypass
affects the move-only requirement for `lookup_value`: a type-qualified call
on a `map[int]Token` with a move-only `Token` is accepted, then aborts at
runtime with `a move-only value was copied` when the key exists.
Apply container-specific operation constraints when resolving the operation
through any call spelling or exposing it as a procedure value, including
the move-only restrictions on copying insertion forms.

### Constant pointer conversions bypass capability checks

[design.md "Pointers"](design.md#pointers) forbids strengthening `^T` to
`^mut T`. `builtin_conversion` in
[src/check_calls.odin](src/check_calls.odin) folds a constant using its
value representation before checking `convertible`, so a typed nil skips
the source/target capability rule:

```odin
package main;
empty :: (^int)(nil);
main :: proc() {
    mutable := (^mut int)(empty);
    _ = mutable;
}
```

This compiles, whereas the same cast of a `^int` parameter is correctly
rejected with `L0373`. A constant's nil representation does not authorize
changing the pointer's declared capability. Validate source/target
conversion rules before folding concrete typed constants, while preserving
the separate contextual conversion rules for untyped literals.

These eight call-checking gaps were reproduced with a compiler rebuilt from
the source tree on 2026-10-02. All 108 compiler unit tests pass with memory
tracking and compiler vets enabled; those tests do not cover these
reproductions.

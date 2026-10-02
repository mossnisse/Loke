# Known gaps

Divergences between the specification documents and the shipped compiler, with
a minimal reproduction for each. A gap leaves this file when the compiler
accepts the program the spec describes — not when the spec is reworded to match
the compiler, unless the rewording is the intended fix.

## Gaps

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

This container-emission finding was reproduced with a compiler built from
the source tree on 2026-10-02 at the default optimization level. All 108
compiler unit tests pass with memory tracking and both compiler vets enabled;
the current fixtures do not cover it.

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

This generic gap was confirmed with a compiler built from the source
tree on 2026-10-02, using `-emit-ll`. All 108 compiler unit tests pass without
covering it.

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

These two expression-emission gaps were confirmed with a compiler built
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

This runtime-emission gap was reproduced with a compiler built from
the source tree on 2026-10-02, using executable builds and LLVM inspection.
All 108 tracked compiler unit tests and `runtime_abi_matches_header` pass
without covering it.

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

These two cleanup-emission gaps were reproduced with a compiler rebuilt
from the source tree on 2026-10-02. All 108 compiler unit tests pass with
memory tracking and compiler vets enabled; those tests do not cover these
reproductions.

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

These iteration findings were reproduced with a compiler built from the
source tree on 2026-10-02. The existing `m4b_foreach`, `m6b_iteration`,
`foreach_elements`, `foreach_regressions`, `iteration_ownership`,
`derived_iterator`, `readonly_iteration`, and `mutable_iteration` run cases
all compile and match their expected output without covering these cases.

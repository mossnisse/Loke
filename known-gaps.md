# Known gaps

Divergences between the specification documents and the shipped compiler, with
a minimal reproduction for each. A gap leaves this file when the compiler
accepts the program the spec describes — not when the spec is reworded to match
the compiler, unless the rewording is the intended fix.

## Gaps

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

### A moved owned foreach leaf is dropped again at the end of its step

[design.md "Lifecycle hooks and resource types"](design.md#lifecycle-hooks-and-resource-types)
runs a drop hook exactly once per initialization that is not transferred.
`bind_foreach_field` in [src/emit_llvm_iteration.odin](src/emit_llvm_iteration.odin)
registers an owned loop binding's drop with `register_scope_place`, which
`move` cannot cancel, and the lifecycle walk does not follow `foreach`
bindings, so moving one leaves the step's drop in place:

```odin
package main;
import "core:fmt";
Owned :: move_only struct { id: int }
impl Owned {
    release :: hook(drop) proc(self: inout Owned) { fmt.println("drop", self.id); }
}
Row :: struct { owned: Owned, lent: int }
Sequence :: struct { n: int }
Cursor :: struct { at: int, n: int }
impl Sequence {
    Element :: Row;
    iter :: proc(self) -> Cursor { return {0, self.n}; }
}
impl Cursor {
    next :: proc(self: inout Cursor) -> Option(Row) {
        if (self.at >= self.n) { return .none; }
        self.at += 1;
        return .some(Row{Owned{self.at}, 5});
    }
}
take :: proc(value: move Owned) { fmt.println("take", value.id); }
main :: proc() {
    foreach (owned, lent in Sequence{1}) { take(move(owned)); }
}
```

This prints `take 1`, `drop 1`, and then `drop 0`: the step drops the inert
value `move` left behind. Owned loop bindings need the liveness tracking and
cancellable drops a local has. The mixed-yield gap below needs the same.

This iteration-emission gap was reproduced with a compiler built from the
source tree on 2026-10-02.

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

This iteration finding was reproduced with a compiler built from the
source tree on 2026-10-02. The existing `m4b_foreach`, `m6b_iteration`,
`foreach_elements`, `foreach_regressions`, `iteration_ownership`,
`derived_iterator`, `readonly_iteration`, and `mutable_iteration` run cases
all compile and match their expected output without covering it.

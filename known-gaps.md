# Known gaps

Divergences between the specification documents and the shipped compiler, with
a minimal reproduction for each. A gap leaves this file when the compiler
accepts the program the spec describes — not when the spec is reworded to match
the compiler, unless the rewording is the intended fix.

## Gaps

### Evaluated carrier values keep referring to mutable provenance slots

[design.md "Evaluation order"](design.md#evaluation-order) prepares values
before later expressions or assignment writes can change their sources.
`cfg_provenance.odin` sometimes retains the source slot instead of a snapshot
of the value it held. These three independent programs are incorrectly
accepted:

```odin
package main;
bad :: proc(input: []int) -> []int {
    local := [1]int{42};
    a := local[:];
    b := input;
    a, b = b, a;
    return b;
}
main :: proc() {}
```

`prov_assign` defines `a` before consuming the recorded source slot for `b`.
The second assignment therefore sees the updated provenance of `a`, although
the runtime correctly swaps the original values. An explicit temporary for
the old `a` produces the required L0526 local-borrow escape diagnostic.

```odin
package main;
STABLE :: [1]int{7};
zero :: proc(@(escape=none) value: ^[1]int) -> int { return 0; }
bad :: proc() -> ^int {
    local := [1]int{42};
    p := &local;
    return &p^[zero(exchange(inout p, &STABLE))];
}
main :: proc() {}
```

`prov_read_through_carrier` keeps `p`'s slot while walking the index, which
changes that slot. The generated IR correctly loads the original pointer
before the index and returns a pointer into `local`; provenance instead sees
`STABLE`. Removing the exchange produces L0526.

```odin
package main;
STABLE :: int(7);
last :: proc(@(escape=none) previous: ^int) -> ^int { return &STABLE; }
Pair :: struct { first: ^int, second: ^int }
bad :: proc() -> Pair {
    local := 42;
    p := &local;
    return Pair{p, last(exchange(inout p, &STABLE))};
}
main :: proc() {}
```

`prov_composite_content` consumes the first element's source slot only after
evaluating the second element. Saving `p` in a separate variable before the
exchange produces L0526. Capture each evaluated value's provenance before
subsequent effects, retaining the source identity needed for reborrow checks.

### A `foreach` cannot destructure a record with padding

[design.md "Destructuring"](design.md#destructuring) applies to `foreach`
bindings, and a `_` padding field fills no binding:

```odin
package main;
Padded :: struct { first: u8, _: [7]u8, last: u8 }
main :: proc() {
    items := [1]Padded{};
    foreach (first, last in items) {}
}
```

Actual: L0459 says `Padded` has padding fields. Binding the whole element and
selecting its fields works, as does `first, last := items[0]`. The `foreach`
pattern walkers in `iterate.odin` and `emit_llvm_iteration.odin` pair bindings
with fields by position; they must map each binding to its named field's slot,
as declaration destructuring does.

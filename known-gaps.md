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

### Map literals discard their keys' borrows

[design.md "Values that contain borrows"](design.md#values-that-contain-borrows)
requires a map to carry its keys' dependencies as well as its values':

```odin
package main;
bad :: proc() -> map[^int]int {
    local := 42;
    return map[^int]int{&local = 1};
}
main :: proc() {}
```

Actual: accepted. Expected: L0526 because the returned map contains a pointer
to a local. `prov_composite_content` walks the key but discards its returned
loans. Creating an empty map and inserting the same key by indexed assignment
correctly rejects the return. Literal construction must define both key and
value paths.

### Allocators in ordinary record fields lose their region dependencies

[design.md "Allocator regions and region provenance"](design.md#allocator-regions-and-region-provenance)
requires an owner's region to outlive it:

```odin
package main;
import "core:mem";
Holder :: struct { allocator: Allocator }
bad :: proc() -> [dynamic]int {
    arena := mem.Arena.init();
    holder := Holder{arena.allocator()};
    xs: [dynamic]int via holder.allocator = {};
    xs.append(42);
    return xs;
}
main :: proc() {}
```

Actual: accepted, letting an owner escape the arena that backs it. Expected:
L0592, as already reported when `via arena.allocator()` is written directly.
`prov_declare_region` skips the non-managed `Holder`, while the selector's
`prov_region_content_at` finds no field region. `prov_store_region` also skips
non-managed allocator handles. Preserve allocator dependencies through
aggregate initialization and stores, using the existing region-bearing type
classification rather than management alone.

### Self-retaining call arguments lose dependencies between their fields

[design.md "Escape levels"](design.md#escape-levels) models `stored` retention
into every compatible writable destination, including the source argument:

```odin
package main;
Holder :: struct { left: []int, right: []int }
copy :: proc(@(escape=stored) h: inout Holder) { h.right = h.left; }
main :: proc() {
    h: Holder = {};
    {
        data := [1]int{42};
        h.left = data[:];
        copy(inout h);
    }
    assert(h.right[0] == 42);
}
```

Actual: accepted. Expected: L0513 when `right` is read after `data` ends.
Replacing the call with `h.right = h.left` gives that diagnostic; a `^mut
Holder` call variant also demonstrates the omission. `prov_retain_into_self`
adds a loan of the destination's own root but discards the incoming content
dependencies. Preserve those dependencies as well as the self-storage loan.

### An unrelated non-escaping argument erases a callback result's unknown provenance

[design.md "Temporaries and procedure boundaries"](design.md#temporaries-and-procedure-boundaries)
requires an erased callback result to retain unknown provenance when no
escaping argument establishes its root:

```odin
package main;
source: thread_local int = 1;
kept: static ^int = nil;
get :: proc(@(escape=none) scratch: ^int) -> ^int { return &source; }
main :: proc() {
    action: proc(@(escape=none) scratch: ^int) -> ^int = get;
    value := 2;
    kept = action(&value);
}
```

Actual: accepted, allowing a thread-local pointer into process-lifetime
storage. Expected: L0647. Both `action(nil)` and the direct `get(&value)`
correctly reject that retention. `prov_call_result` synthesizes an unknown
loan only when both escaping result sources and all borrowed arguments are
empty; the unrelated `escape=none` argument disables the fallback. Determine
the fallback from result dependencies, independently of call-only borrows.

### A marked allocator alternative covers an unrelated unknown reset

[design.md "Allocator regions and region provenance"](design.md#allocator-regions-and-region-provenance)
requires every received region that may be reset to have the reset promise:

```odin
package main;
bad :: proc(@(allocator_reset) allowed: Allocator, erased: any_view) {
    selected := erased.as(Allocator) or_else allowed;
    free_all(selected);
}
main :: proc() {}
```

Actual: accepted. Expected: L0538 because extraction from `any_view` can
select an unknown, unpromised allocator. Replacing `allowed` with `nil`
correctly produces L0538. `prov_reset_promise` examines parameter bits, and
`prov_reset` treats one marked parameter as coverage even when the set also
contains an unknown or default alternative. Coverage must include every
non-local alternative. A conditional selecting a marked parameter or an
allocator in another parameter's record field is also accepted and can reset
a caller's live owner backed by the unmarked region.

### Read-only call arguments do not reborrow existing mutable carriers

[design.md "Weakening and reborrows"](design.md#weakening-and-reborrows)
requires weakening an existing mutable carrier to suspend it while the
read-only reborrow is live:

```odin
package main;
bump :: proc(xs: []mut int) -> int { xs[0] = 99; return 0; }
observe :: proc(xs: []int, ignored: int) { _ = xs[0]; }
main :: proc() {
    storage := [1]int{1};
    source: []mut int = storage[:];
    observe(source, bump(source));
}
```

Actual: accepted. Expected: a reborrow conflict while evaluating the second
argument. First assigning `view: []int = source` and passing `view` instead
correctly gives L0641. `prov_call` supplies no destination to `prov_reborrow`,
which does not link an existing carrier in that case; only mutable parameter
types subsequently receive a call reborrow. Create the read-only call reborrow
before evaluating later arguments and keep it live through the call.

### Map literals merge distinct supported constant keys below the precision budget

[design.md "Minimum provenance precision"](design.md#minimum-provenance-precision)
requires these two integer keys and their single value path to remain distinct:

```odin
package main;
good :: proc(incoming: ^int) -> ^int {
    local := 42;
    values := map[int]^int{1 = incoming, 2 = &local};
    return values[1];
}
main :: proc() {}
```

Expected: accepted. Actual: L0526 claims the result borrows `local`. The
equivalent empty map followed by two indexed assignments is accepted.
`prov_composite_content` asks `prov_element_step` to interpret map keys as
record field names, so literal values are joined into every entry. Reuse
`prov_map_entry_step` and the existing key/value projections.

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

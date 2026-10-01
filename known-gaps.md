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

### Return checking does not enforce the declared `inout` mode before conversion

[design.md "`inout` results"](design.md#inout-results) requires
`return inout place`, with exactly the declared storage type and no result
conversion. Two invalid programs are accepted:

```odin
package main;
bad :: proc() -> inout int {
    local := 42;
    return local;
}
main :: proc() {}
```

The emitter returns `local`'s address because the signature is `inout`, but
the provenance walker reads the value because the return lacks that marker.
Adding the marker correctly reports L0526. `check_return` must validate the
return mode before classification and provenance analysis.

```odin
package main;
bad :: proc(value: inout [1]int) -> inout []int {
    return inout value;
}
main :: proc() {}
```

`check_return` calls `check_value_expr`, which converts the array expression
to a slice before the exact-type check. The expression retains its place
flags; LLVM materializes a slice in a frame-local temporary and returns that
temporary's address, which becomes invalid when the procedure returns.
`inout string` returned as `inout string_view` is also accepted. Check the
original place type without materializing a value conversion.

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

### Compile-time-only types reach runtime records and anonymous procedures

[design.md "`type` and `typeid`"](design.md#type-and-typeid) prohibits runtime
record storage and procedure values containing `type`. Both programs are
accepted:

```odin
package main;
Item :: struct { value: type }
main :: proc() { value: Item = {}; }
```

`resolve_struct_fields` does not reject compile-time-only field types, and
the ordinary storage gate accepts a record containing `type`. Validate fields
where their types are resolved.

```odin
package main;
main :: proc() {
    f := proc(t: type) {};
    f(int);
}
```

LLVM emits a runtime lambda taking `i64` and passes `0` for `int`.
The named equivalent correctly reports L0378. `check_proc_literal` calls
`check_proc_body` directly, bypassing `check_proc`'s signature-error and
compile-time-only component guards. Share those guards before checking or
hoisting either form.

### Compound indexed assignment omits the computed-setter fallback

[design.md "Indexing and slicing"](design.md#indexing-and-slicing) requires
compound assignment through `operator([])` and `operator([]=)` when the
container has no place-returning index operator:

```odin
package main;
Box :: struct { value: int }
impl Box {
    get :: operator([]) proc(self: Box, index: int) -> int {
        return self.value;
    }
    set :: operator([]=) proc(self: inout Box, index, value: int) {
        self.value = value;
    }
}
main :: proc() { box := Box{3}; box[0] += 4; }
```

Actual: L0419; `box[0] = box[0] + 4` is accepted. `check_compound_assign`
requires an assignable place before considering the setter path used by
ordinary assignment. Implement the specified fallback while evaluating the
receiver and indices only once.

### Floating literals round through `f64` before their destination width

[design.md "Number literals"](design.md#number-literals) requires one
round-to-nearest, ties-to-even conversion from the unfixed value:

```odin
package main;
Actual :: f32(1.0000000596046448);
Expected :: f32(1.00000011920928955078125);
static_assert(Actual == Expected);
main :: proc() {}
```

Actual: L0387; `Actual` is 1.0. The decimal exceeds the exact midpoint
1.000000059604644775390625 and must round upward. `check_literal` first uses
`parse_f64`, which rounds it to that midpoint; the later `f32` conversion
rounds down. The nearby decimal 1.0000000596046449 passes. Preserve the unfixed
literal's precision until the destination conversion.

### Destination context rounds unfixed floating arithmetic before its result

[design.md "Number literals"](design.md#number-literals) keeps an unfixed
expression unfixed until conversion:

```odin
package main;
VALUE: f32 : 16777217.0 - 16777216.0;
static_assert(VALUE == 1.0);
main :: proc() {}
```

Actual: L0387; `VALUE` is 0. `check_binary` passes the destination hint to
both literals, and `check_literal` converts each to `f32` before subtraction.
Computing an inferred constant first, then converting its result to `f32`,
correctly produces 1. Preserve unfixed operands until a concrete operand or
the final destination requires conversion.

### A destination type selects a floating operator overload

[design.md "Operator lookup and overload resolution"](design.md#operator-lookup-and-overload-resolution)
requires selection to depend on arguments, never the destination:

```odin
package main;
Marker :: struct {}
impl Marker {
    add32 :: operator(+) proc(left: f32, right: Marker) -> f32 {
        return left;
    }
    add64 :: operator(+) proc(left: f64, right: Marker) -> f64 {
        return left;
    }
}
main :: proc() {
    marker: Marker = {};
    chosen: f32 = 1.0 + marker;
    _ = chosen;
}
```

Actual: accepted, calling `add32`; changing the destination to `f64` calls
`add64`. The inferred declaration correctly reports L0391 ambiguity.
`check_binary`'s hint causes `check_literal` to give the argument a concrete
type before ranking. Keep destination conversion after operator selection.

### Designated fixed-array initializers are rejected

[design.md "Fixed arrays"](design.md#fixed-arrays) permits element indices
and index ranges as initializer keys:

```odin
package main;
main :: proc() { values := [3]int{2 = 9}; _ = values; }
```

Expected: `[0, 0, 9]`. Actual: L0372 says the literal is positional.
`check_array_literal` rejects every keyed element. The positional equivalent
works; implement the specified designated forms and zero only omitted slots.

### Wide runtime indices and slice bounds are truncated before validation

[design.md "Fixed arrays"](design.md#fixed-arrays) and
[design.md "Slices"](design.md#slices) require checked bounds:

```odin
package main;
import "core:fmt";
main :: proc() {
    xs := [dynamic]int{42};
    index: u128 = 18446744073709551616;
    fmt.println(xs[index]);
}
```

Actual: prints 42; expected: bounds panic. `check_integer_index` preserves
the valid `u128` type, but `emit_index_below` truncates it to `i64` before
comparing with the length. Slice indexing uses the same helper. Fixed-array
indexing correctly checks the original width first.

```odin
package main;
import "core:fmt";
main :: proc() {
    xs := [1]int{42};
    lo: u128 = 18446744073709551616;
    hi: u128 = 18446744073709551617;
    fmt.println(xs[lo:hi]);
}
```

Actual: prints `[42]`; expected: bounds panic. `emit_slice_bounds` also
truncates before validation. Preserve full-width comparisons before narrowing
valid indices or endpoints for address formation in
[src/emit_llvm_expr.odin](src/emit_llvm_expr.odin).

### Packed-storage address checks miss array projections and follow unrelated pointers

[design.md "@(packed)"](design.md#packed) and
[design.md "Address operator"](design.md#address-operator) prohibit exposing
misaligned packed fields as ordinary addresses:

```odin
package main;
Packed :: struct @(packed) { tag: u8, data: [1]int }
main :: proc() {
    p := Packed{1, {42}};
    pointer := &p.data[0];
    assert(pointer^ == 42);
}
```

Actual: accepted; `&p.data` correctly reports L0614. Slicing `p.data[:]`
also succeeds and exposes the same offset-1 storage. `packed_field_reached`
stops at an index, and built-in slicing never checks packed ancestry. The
emitter then uses ordinary aligned integer loads. Trace embedded array
projections, apply the borrow check to slicing, and retain alignment when
lowering direct packed element accesses.

```odin
package main;
Cell :: struct { value: int }
Packed :: struct @(packed) { tag: u8, pointer: ^Cell }
main :: proc() {
    cell := Cell{42};
    p := Packed{1, &cell};
    pointer := &p.pointer.value;
    assert(pointer^ == 42);
}
```

Expected: accepted; the address names `cell`'s ordinary storage. Actual:
L0614 calls `pointer` a packed field. First copying `p.pointer` to `q` and
using `&q.value` succeeds. Packed ancestry must stop when a dereference enters
separate storage, rather than following the pointer's source field.

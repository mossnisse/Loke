# Known gaps

Divergences between the specification documents and the shipped compiler, with
a minimal reproduction for each. A gap leaves this file when the compiler
accepts the program the spec describes — not when the spec is reworded to match
the compiler, unless the rewording is the intended fix.

## Gaps

The [compiler review of 2026-10-14](compiler-review-2026-10-14.md) found the
following divergences. These are open findings; the review does not change the
language or compiler behavior.

### G01: Package spelling changes compiler-contributed members

[Packages](design.md#packages) identifies a package by its directory, and
[Import statement](design.md#import-statement) makes aliases refer to the same
declarations. On Windows, changing only the directory's case can remove the
compiler-contributed members of a bundled package:

```loke
package main;
import s "core:Strings";
main :: proc() { _ = s.copy("a"); }
```

Compiling with `-emit-ll` reports unknown `allocate_string` and
`allocation_failed` in the library. Changing `Strings` to `strings` succeeds.
Even with the lowercase import, adding `-collection aaa=core` produces missing
library-member diagnostics. `package_key` chooses the alphabetically first
collection for equal roots and preserves directory case, while contribution
dispatch compares exact keys. See [packages.odin](src/packages.odin) and
[stdlib.odin](src/stdlib.odin).

### G02: Defined built-in operators can be replaced by user overloads

[Operator lookup and overload resolution](design.md#operator-lookup-and-overload-resolution)
gives defined built-ins priority. The applicability predicate disagrees with
ordinary checking for signed shift counts and mixed text operands:

```loke
package main;
import "core:fmt";
shift :: operator(<<) proc(a, b: int) -> int { return 99; }
add :: operator(+) proc(a: string, b: string_view) -> string { return "shadowed"; }
main :: proc() {
    n := 1;
    s := "a";
    v: string_view = "b";
    fmt.println(2 << n);
    fmt.println(s + v);
}
```

Observed output: `99` and `shadowed`. Required: `4` and `ab`.
The separate operand-unification rules in [operators.odin](src/operators.odin)
and [check_expr.odin](src/check_expr.odin) have drifted.

### G03: Local operators escape their scope and fail to shadow

[Operator lookup and overload resolution](design.md#operator-lookup-and-overload-resolution)
selects lexical scope before ranking candidates. Local declarations are instead
enrolled in the package operator set:

```loke
package main;
V :: struct { x: int }
outer :: operator(+) proc(a, b: V) -> V { return {a.x + b.x}; }
main :: proc() {
    {
        inner :: operator(+) proc(a, b: V) -> V { return {99}; }
        _ = V{1} + V{2};
    }
    _ = V{1} + V{2};
}
```

Both additions produce L0391 ambiguity between `outer` and `inner`.
The inner addition should select `inner`; the outer addition should select
`outer`. See [operators.odin](src/operators.odin).

### G04: Compound setters reread indices after right-hand effects

[Evaluation order](design.md#evaluation-order) requires preparing a compound
assignment's destination before its right operand. Setter lowering leaves
identifier indices uncaptured:

```loke
package main;
import "core:fmt";
Grid :: struct { cells: [2]int }
impl Grid {
    get :: operator([]) proc(self: Grid, i: int) -> int { return self.cells[i]; }
    set :: operator([]=) proc(self: inout Grid, i: int, value: int) {
        self.cells[i] = value;
    }
}
bump :: proc(i: inout int) -> int { i = 1; return 10; }
main :: proc() {
    grid := Grid{[2]int{1, 2}};
    i := 0;
    grid[i] += bump(inout i);
    fmt.println(grid.cells[0], grid.cells[1], i);
}
```

Observed: `1 12 1`. Required: `11 2 1`. A side-effect-free index read is not
stable across the right operand. See `bind_index_place` in
[check.odin](src/check.odin).

### G05: Parallel setters lose assignment type context

[Assignment statements](design.md#assignment-statements) and
[Implicit type conversions](design.md#implicit-type-conversions) allow an
unfixed literal to acquire its destination type. Setter lowering first stores
every right operand in an inferred temporary, losing that context:

```loke
package main;
Grid :: struct { cells: [2]i32 }
impl Grid {
    get :: operator([]) proc(self: Grid, i: int) -> i32 { return self.cells[i]; }
    set :: operator([]=) proc(self: inout Grid, i: int, value: i32) {
        self.cells[i] = value;
    }
}
main :: proc() {
    grid := Grid{};
    x: i32 = 0;
    grid[0], x = 1, 2;
}
```

Observed: L0310 and L0392 because both literals become `int`. Required: accept.
See `lower_parallel_setter_assign` in [check.odin](src/check.odin).

### G06: Compile-time foreach copies ordinary borrowed bindings

[Borrowing iteration](design.md#borrowing-iteration) makes ordinary sequence
bindings refer to the element's storage.
[Compile-time procedure evaluation](design.md#compile-time-procedure-evaluation)
must preserve those semantics:

```loke
package main;
import "core:fmt";
address_match :: proc() -> bool {
    xs := [1]int{7};
    p := &xs[0];
    foreach (x in xs) { return &x == p; }
    return false;
}
A :: address_match();
main :: proc() { fmt.println(A, address_match()); }
```

Observed: `false true`. Required: `true true`. `bind_foreach_element` in
[eval.odin](src/eval.odin) copies the ordinary binding into a new local instead
of binding the checked borrowed yield to its original slot.

### G07: Reflected field access cannot execute at compile time

[Compile-time reflection](design.md#compile-time-reflection) defines field
access, and the ordinary local read is admissible under
[Compile-time procedure evaluation](design.md#compile-time-procedure-evaluation):

```loke
package main;
P :: struct { x: int }
reflected :: proc() -> int {
    value := P{42};
    foreach ($field in fields_of(P)) { return field.get(&value); }
    return 0;
}
A :: reflected();
main :: proc() {}
```

Observed: L0344 claiming that `x` has a procedure body still being checked.
Required: fold `A` to 42. The runtime control returns 42.
[eval.odin](src/eval.odin) lacks dispatch for the checked `Call_Reflect`
operation and treats the field as a procedure.

### G08: Reflection descriptor calls discard argument labels and modes

[Parameters](design.md#parameters) and
[Compile-time reflection](design.md#compile-time-reflection) do not permit
arbitrary argument labels or a value argument marked `inout`:

```loke
package main;
import "core:fmt";
P :: struct { x: int }
main :: proc() {
    value := P{42};
    foreach ($field in fields_of(P)) {
        fmt.println(field.get(bogus = inout &value));
    }
}
```

Observed: accepts and prints 42. Required: reject the argument shape.
`check_descriptor_operation` in [reflect.odin](src/reflect.odin) retains only
the value expression without validating the written label and mode.

### G09: Owned scalar loop and switch bindings bypass liveness checks

[Variable declarations](design.md#variable-declarations),
[Element bindings](design.md#element-bindings), and
[Switch ownership](design.md#switch-ownership) require owned bindings to become
dead when consumed, including scalars:

```loke
package main;
main :: proc() {
    foreach (item in 0 ..< 1) {
        _ = move(item);
        _ = item;
        drop(item);
    }
    switch (Option(int).some(7)) {
    case .some(value):
        drop(value);
        _ = value;
        drop(value);
    case .none:
    }
}
```

Observed: accepts with `-emit-ll`. Required: dead-binding diagnostics.
`track_owned_foreach_leaves` and `track_case_binding` in
[cfg.odin](src/cfg.odin) skip unmanaged types entirely instead of separating
liveness registration from managed cleanup registration.

### G10: Owned switch payloads are treated as borrowed returns

[Switch ownership](design.md#switch-ownership) makes consuming-switch payloads
owned locals. Their managed return should transfer under
[Parameter semantics and ABI lowering](design.md#parameter-semantics-and-abi-lowering):

```loke
package main;
Token :: move_only struct { id: int }
U :: union { held: Token, empty: }
get :: proc() -> U { return .held(Token{1}); }
from_case :: proc() -> Token {
    switch (get()) {
    case .held(value): return value;
    case .empty: return Token{0};
    }
}
main :: proc() { _ = from_case(); }
```

Observed: L0502 says the owned `value` is borrowed. Required: accept and
transfer it. `symbol_is_owned_here` in [lifecycle.odin](src/lifecycle.odin)
requires a declaration node, which synthesized case and iteration bindings
lack. The analogous iteration-return and unnecessary-copy cases are
source-traced; this consuming-switch case is reproduced.

### G11: Nested excluded copy hooks do not make their container move-only

[where clauses](design.md#where-clauses) makes an instance with an excluded copy
hook move-only, and
[Lifecycle hooks and resource types](design.md#lifecycle-hooks-and-resource-types)
propagates that property to containing records:

```loke
package main;
import "core:fmt";
Bad :: struct($T: type) { value: int }
impl Bad($T) {
    copy_bad :: hook(copy) proc(self, allocator: Allocator)
        -> Result(Bad(T), Allocator_Error) where false {
        return .ok(Bad(T){self.value});
    }
}
Outer :: struct { inner: Bad(int) }
main :: proc() {
    fmt.println(is_copyable(Outer), is_copyable(Bad(int)));
    a := Outer{Bad(int){1}};
    b := a;
    fmt.println(a.inner.value, b.inner.value);
}
```

Observed: accepts, prints `true false`, then exits 1 with
`loke: a move-only value was copied`. Required: both types are move-only and the
copy is rejected. `type_clone_disabled_walk` in [hooks.odin](src/hooks.odin)
omits excluded hooks when a nested lifecycle has not yet been cached; querying
the nested type first changes the result.

### G12: Callback substitution loses named global borrow roots

[Procedure result contracts](design.md#procedure-result-contracts) and
[Capabilities and the one rule](design.md#capabilities-and-the-one-rule) require
an indirect result's actual borrow dependencies to fit its contract:

```loke
package main;
import "core:fmt";
a: int = 1;
b: int = 2;
get_a :: proc() -> ^int { return &a; }
get_b :: proc() -> ^int { return &b; }
main :: proc() {
    f := get_a;
    f = get_b;
    p := f();
    b = 3;
    fmt.println(p^);
}
```

Observed: accepts with `-emit-ll`. Required: reject the incompatible callback
contract. The initial `get_a` contract is substituted at the indirect call,
concealing the live borrow of `b`. Initializing `f` with `get_b` instead
correctly rejects the write with L0512. `dependency_contract_within` in
[proc_contracts.odin](src/proc_contracts.odin) does not compare named globals.

### G13: Local pointer aliases hide written allocator regions

[Allocator regions and region provenance](design.md#allocator-regions-and-region-provenance)
and [How root and region provenance compose](design.md#how-root-and-region-provenance-compose)
require a callee's writes to preserve the stored owner's allocator dependency:

```loke
package main;
import "core:fmt";
import "core:mem";
set :: proc(dst: ^mut [dynamic]int, alloc: Allocator) {
    alias := dst;
    alias^ = make([dynamic]int, 4, alloc);
}
main :: proc() {
    xs: [dynamic]int = {};
    arena := mem.Arena.init();
    set(&mut xs, arena.allocator());
    free_all(arena.allocator());
    fmt.println(xs[0]);
}
```

Observed: accepts with `-emit-ll`, despite resetting storage subsequently read
by `xs`. Changing only `alias^` to `dst^` correctly produces L0537 for reset
and provider destruction. The invalid program was not executed.
`prov_written_parameter` in [cfg_provenance.odin](src/cfg_provenance.odin)
follows syntax to a parameter identifier instead of following the alias's
solved destination provenance.

### G14: Direct owning results inherit unrelated allocator arguments

[Procedure result contracts](design.md#procedure-result-contracts) and
[Allocator regions and region provenance](design.md#allocator-regions-and-region-provenance)
give known calls their inferred result dependencies:

```loke
package main;
import "core:mem";
ignore :: proc(unused: Allocator) -> Box(int) { return box(1); }
outer :: proc() -> Box(int) {
    arena := mem.Arena.init();
    return ignore(arena.allocator());
}
main :: proc() { _ = outer(); }
```

Observed: L0592 claims the returned box depends on `arena`. Required: accept;
`box(1)` uses the default allocator. Removing the unused parameter and argument
accepts. After substituting a precise direct summary, `prov_call_region` in
[cfg_provenance.odin](src/cfg_provenance.odin) redundantly merges every allocator
argument into an owning result. That fallback belongs to calls without a
precise body or contract.

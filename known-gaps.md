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

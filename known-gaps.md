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

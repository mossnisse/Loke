# Known gaps

Divergences between the specification documents and the shipped compiler, with
a minimal reproduction for each. A gap leaves this file when the compiler
accepts the program the spec describes — not when the spec is reworded to match
the compiler, unless the rewording is the intended fix.

## Gaps

### Compile-time `swap` and `sort` reject a slice

[Compile-time procedure evaluation](design.md#compile-time-procedure-evaluation)
permits mutation, and [Swapping elements](design.md#swapping-elements) and
[Sorting slices](design.md#sorting-slices) define `swap` and `sort` on a
`[]mut T`. The evaluator accepts an element assignment through such a slice but
rejects these two members on one:

```loke
package main;
import "core:fmt";
build :: proc() -> [3]int {
    values := [3]int{3, 1, 2};
    view := &mut values[:];
    view.swap(0, 1);   // `view.sort()` is rejected the same way
    return values;
}
VALUES :: build();
main :: proc() { fmt.println(VALUES); }
```

The constant is reported with L0341, "a slice cannot be rearranged at compile
time" ("cannot be sorted" for `sort`). Writing `view[0] = 5` instead compiles
and prints `[5, 1, 2]`. `eval.odin` treats a slice receiver as a borrowed header
and accepts these members only on a dynamic array. `random.shuffle` swaps
through its slice, so it cannot run during compilation until this is fixed.

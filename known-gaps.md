# Known gaps

Divergences between the specification documents and the shipped compiler, with
a minimal reproduction for each. A gap leaves this file when the compiler
matches the specified behavior — not when the spec is reworded to match the
compiler, unless the rewording is the intended fix.

## Gaps

### Named arguments to a slot of a view converted in place

A [`dyn` slot call](design.md#borrowed-dynamic-interface-values) binds named
arguments by the slot's parameter names, as any call does, and does so through
a stored view. Through a view converted in place, the call is resolved as a
method instead, against the view type's forwarding member, which records no
parameter names:

```loke
package main;
import "core:fmt";
Shape :: interface($Self: type) { slot area: proc(self, scale: int) -> int; }
Square :: struct { side: int }
impl Square { area :: proc(self, scale: int) -> int { return self.side * scale; } }
main :: proc() {
    s := Square{3};
    view := (dyn Shape)(&s);
    fmt.println(view.area(scale = 2));               // 6
    fmt.println((dyn Shape)(&s).area(scale = 2));    // L0392
}
```

The second call is rejected: "no overload of method `area` applies to these
arguments", "it has no parameter named `scale`". Positional arguments work.

### Mutable-slice splitting reloads a rebound receiver during emission

[Splitting a mutable slice](design.md#splitting-a-mutable-slice) captures the
receiver before evaluating the index and takes its reborrow afterward. The
provenance graph models that capture, but LLVM emission reloads the receiver
after the index expression has rebound it. This reproduces with the baseline
compiler from `81d478b`, before storage normalization:

```loke
package main;
import "core:fmt";
replace :: proc(receiver: inout []mut int, @(escape=stored) replacement: []mut int) -> int {
    receiver = replacement;
    return 1;
}
main :: proc() {
    first := [2]int{1, 2};
    second := [2]int{3, 4};
    receiver := &mut first[:];
    halves := receiver.split_at_mut(replace(inout receiver, &mut second[:]));
    halves.left[0] = 9;
    fmt.println(first, second);
}
```

Expected output is `[9, 2] [3, 4]`; actual output is `[1, 2] [9, 4]`.
The emitter must preserve the evaluated receiver across later argument
evaluation, matching the analysis capture. The stage 2 inspection test
`normalization_captured_reassignment_contract` in
[provenance_normalization_test.odin](src/provenance_normalization_test.odin)
checks the analysis identity; it does not establish correct runtime emission.

### `-doc` omits compiler-contributed declarations

[`-doc`](compiler-guide.md#common-options) prints "each public declaration's
signature", but a public name the compiler contributes to a bundled package has
no source declaration, so the page leaves it out. `lokec core\mem -doc` prints
only the package comment, with none of `Allocator`, `Allocator_Error`,
`default_allocator`, `Arena`, `Scratch`, `Failure_Policy`, `try_arena`, and
`try_scratch`. The same holds for `core:unsafe`'s operations, `math.wrap`,
`log.Level`, `sync.Memory_Order`, and `core:meta`'s descriptors.
[Interface files](compiler-guide.md#interface-files) leave them out the same
way, so `core/mem/api.loki` holds only the package clause. Their signatures
are in comments in the package source, which nothing checks. See
[Using a package without reading its code](open-questions.md#using-a-package-without-reading-its-code-proposal-2026-10-21).

# Known gaps

Divergences between the specification documents and the shipped compiler, with
a minimal reproduction for each. A gap leaves this file when the compiler
matches the specified behavior — not when the spec is reworded to match the
compiler, unless the rewording is the intended fix.

## Gaps

### A held pointer can hide an owner from a later allocator reset

[Allocator regions and region provenance](design.md#allocator-regions-and-region-provenance)
rejects resetting a region while a live owner uses it. A call that writes an
owner through a pointer held in a local variable is accepted when the allocator
is a resettable parameter, even though the caller reads that owner after the
reset. Passing `&mut out` directly to `fill` instead is rejected with `L0537`.
The same omission occurs through a read-only `^Box` containing the pointer.

```loke
package main;

import "core:fmt";
import "core:mem";

fill :: proc(allocator: Allocator, dst: ^mut [dynamic]int) {
	dst^ = make([dynamic]int, 2, allocator);
}

check :: proc(@(allocator_reset) allocator: Allocator) {
	out: [dynamic]int = {};
	p := &mut out;
	fill(allocator, p);
	free_all(allocator);
	fmt.println(out[0]);
}

main :: proc() {
	arena := mem.Arena.init();
	check(arena.allocator());
}
```

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

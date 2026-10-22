# Known gaps

Divergences between the specification documents and the shipped compiler, with
a minimal reproduction for each. A gap leaves this file when the compiler
accepts the program the spec describes — not when the spec is reworded to match
the compiler, unless the rewording is the intended fix.

## Gaps

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

### A second read-only copy of a suspended carrier is rejected

[Weakening and reborrows](design.md#weakening-and-reborrows) lets a carrier
suspended by a read-only reborrow still be read, including "passing it where
a read-only carrier is wanted". Copying it into a second read-only carrier
while the first is live is `L0641` instead:

```loke
values := [2]int{1, 2};
xs := &mut values[:];
v1: []int = xs;
v2: []int = xs;            // L0641: a read-only reborrow of `xs` is still in use
fmt.println(v1[0], v2[0]);
```

The same happens for two record literals with read-only fields, `Views{xs}`
then `Views{xs}`, while the first is live.

### Mutable slices appended to one dynamic array conflict

Two distinct mutable carriers stored in one container should not conflict:
neither reborrows the other. Appending the second is `L0641`, naming it as
suspended by a reborrow it never had, and the message names no precision
limit, as [Minimum provenance precision](design.md#minimum-provenance-precision)
requires of a rejection a merge causes:

```loke
plain :: proc(a: []mut int, b: []mut int) {
	held := [dynamic][]mut int{};
	held.append(a);
	held.append(b);        // L0641: `b` cannot be used here
	held[0][0] = 1;
}
```

Found while implementing `chunks_mut`, whose chunks therefore cannot yet be
collected in a container.

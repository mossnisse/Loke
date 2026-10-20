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
`log.Level`, `sync.Memory_Order`, and `core:meta`'s descriptors. Their
signatures are in comments in the package source, which nothing checks. See
[Using a package without reading its code](open-questions.md#using-a-package-without-reading-its-code-2026-10-20).

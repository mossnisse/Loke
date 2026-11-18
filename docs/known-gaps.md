# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### Foreign exports accept an over-aligned nullable union

[Foreign-ABI-safe types](design.md#foreign-abi-safe-types) specifies that the
nullable-pointer case uses the same C pointer representation as its payload.
The foreign ABI check accepts an explicitly over-aligned user-defined union
based on its null niche. LLVM lowering then uses an indirect argument and an
`sret` result for the union.

```loke
package main;

@(align=16) Nullable :: union { none, some: ^int }
@(export) accept :: proc "c" (value: Nullable) -> Nullable { return value; }
main :: proc () {}
```

Run `lokec <file> -emit-ll`. The compiler accepts `accept` and emits
`define void @accept(ptr sret(...) align 16 ..., ptr ...)`. See the
[ABI review](compiler-source-audit-2026-11-18.md#srcabiodin).

### Atomic stores can retain a borrow beyond its lifetime

[Retaining a borrow](design.md#retaining-a-borrow) requires a borrowed value to
outlive storage that retains it. The compiler accepts a pointer to a local
stored in a process-lifetime atomic cell.

```loke
package main;
import "core:sync";

cell: static sync.Atomic(Option(^int)) = {};
publish :: proc() {
    value := 42;
    cell.store(.some(&value));
}
main :: proc() { publish(); }
```

Run `lokec <file> -emit-ll`. The compiler emits IR. Changing the cell to a
plain `Option(^int)` and using assignment produces `L0647`. See the
[atomics review](compiler-source-audit-2026-11-18.md#srcatomicsodin).

### File-scope `when` misses names in capture initializers

[The `when` statement](design.md#when-statement) specifies that a file-scope
condition waits for the declarations it reads, including through a procedure
body. The dependency walk skips the written initializers of capture literals.

```loke
package main;

choose :: proc() -> bool {
    get := proc() -> int capture(n = LATER) { return n; };
    return get() == 42;
}
when (choose()) { SELECTED :: true; }
when (true) { LATER :: 42; }
```

Run `lokec <file> -doc`. The compiler reports `L0315` for `LATER` and
`L0344` for the call to `choose`. See the
[AST review](compiler-source-audit-2026-11-18.md#srcastodin).

### A NUL in `link_name` reaches LLVM

[`link_name`](design.md#link_namestring) specifies a linkable symbol name.
The compiler accepts a decoded NUL and writes an identifier which LLVM rejects.

```loke
package main;
@(export, link_name="n\x00m") f :: proc "c" () {}
```

Run `lokec <file> -build-mode=obj -emit-ll`, then run `clang -c` on the
generated IR. Loke emits `@"n\00m"`, which Clang rejects with
“NUL character is not allowed in names.” See the
[attributes review](compiler-source-audit-2026-11-18.md#srcattributesodin).

### A merged allocator dependency is reported as certain

[Minimum provenance precision](design.md#minimum-provenance-precision)
requires the diagnostic to describe a dependency as possible when merged paths
could account for the rejection. The allocator control-block diagnostic says
“would” while its attached notes acknowledge that array elements merged.

```loke
package main;
import "core:mem";

main :: proc() {
    safe := mem.Arena.init();
    owner := mem.Arena.init();
    values: [9]Allocator = {};
    values[0] = safe.allocator();
    values[8] = owner.allocator();
    allocator := values[0];
    drop(owner);
    p := box(0, allocator);
    p^ = 42;
}
```

Run `lokec <file> -emit-ll`. `L0537` says dropping `owner` “would end an
allocator control block whose handle is still in use.” The version with eight
elements and a write at index seven compiles. See the
[borrow diagnostic review](compiler-source-audit-2026-11-18.md#srcborrow_reportodin).

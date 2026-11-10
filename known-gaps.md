# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### A `..T` pack's slice can reach the result

[design.md "Variadic parameters"](design.md#variadic-parameters): "The pack is a
temporary of the complete call expression, as is anything an argument creates
for it, so neither outlives that expression." The compiler lets the body return
the slice it receives, so the caller keeps a view of the ended pack:

```loke
package main;
import "core:fmt";

give :: proc(values: ..int) -> []int { return values; }

main :: proc() {
	x := give(3, 4); // should be an error: `x` views the call's pack
	fmt.println(x[0]);
}
```

Storing the slice is rejected, but L0646 then suggests the one fix the compiler
refuses: `saved = values` reports "`values`, which is not written
`@(escape=static)`", and `@(escape=static) values: ..int` is L0648, since `int`
carries no borrow. The `..^T` rule, "a result that may borrow one is an error at
the parameter", is the behavior to match for every pack, and L0646 should not
offer an escape level for a pack.

### A `@(cross_thread)` pack skips the call-site checks

A `..proc()` pack may be marked [`@(cross_thread)`](design.md#cross_thread), as
its element is of procedure type, but the checks at a call look at the pack as
one argument of type `[]proc()`, not at its elements. A named procedure passed in
the pack misses the [race warning](design.md#global-write-effects) the same
procedure gets through a single parameter:

```loke
package main;

counter: int;
bump :: proc() { counter += 1; }

direct :: proc(@(cross_thread) entry: proc()) { entry(); }
packed :: proc(@(cross_thread) entries: ..proc()) {
	foreach (entry in entries) { entry(); }
}

main :: proc() {
	direct(bump); // L0707: `bump` writes `counter`
	packed(bump); // no warning
}
```

`note_thread_spawn` in `src/global_effects.odin` and `prov_call_cross_thread` in
`src/provenance_results.odin` read `v.bound[index]` whole. design.md does not say
whether a pack may carry the attribute; either the spec says it may and both
checks walk the pack's operands, as `prov_spawn_transfers` does with
`call_pack_next`, or it says it may not and the attribute is L0723 on a pack.

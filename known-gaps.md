# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### An unfixed constant converts to a distinct type

[design.md "Implicit type conversions"](design.md#implicit-type-conversions)
"defines the implicit conversions" and sends an unfixed integer to "built-in
integer types" and an unfixed float to "built-in floating-point types". A
distinct type is not built in, and every example in design.md writes the
conversion, as `Meters(3)`. The compiler accepts the constant alone:

```loke
package main;
import "core:fmt";

Meters :: distinct f64;
Id :: distinct int;

main :: proc() {
	m: Meters = 3; // accepted; the list has no conversion that allows it
	i: Id = 7;
	fmt.println(f64(m), int(i)); // 3.0 7
}
```

`tests/err/declared_structs.loke` relies on it (`m: Meters = 1.0;`), so the
intended fix is probably to the list: an unfixed constant converts to a
distinct type as it does to that type's underlying built-in type. Found by the
[design review's third pass](design-review-2026-10-31.md#24-coercions), which
builds on the rule.

# Known gaps

Divergences between the specification documents and the shipped compiler, with
a minimal reproduction for each. A gap leaves this file when the compiler
accepts the program the spec describes — not when the spec is reworded to match
the compiler, unless the rewording is the intended fix.

Nothing here is checked by the test corpus: a test asserting today's behavior
would cement the wrong answer, and one asserting the right answer would be red.
Each entry carries its own repro instead, small enough to paste.

## Gaps

### Iteration still follows the pre-unification model

[design.md](design.md#iteration-protocol) specifies three traversal modes chosen
by the header — borrowed by default, mutable at an `&` leaf, consuming from a
temporary or `move(place)` — with recursive binding patterns, `Yield`
descriptors, `Consuming_Iterable`, and `copied()` as the written clone. The
compiler still implements the model that preceded it: an ordinary `foreach` over
a place copies each element, `refs()` is the borrowing traversal, bindings are
flat, and there is no consuming traversal.

This is one divergence rather than fifteen because it is one coordinated change.
[iteration-unification-plan.md](iteration-unification-plan.md) has the six
implementation steps; the specification is step 1, and the gap closes at step 6.

```odin
package main;

Entry :: move_only struct { id: int }

sum :: proc(items: []Entry) -> int {
	total := 0;
	foreach (item in items) {   // the spec borrows; the compiler tries to copy
		total += item.id;
	}
	return total;
}

main :: proc() {
	_ = sum([]Entry{});
}
```

```
error[L0491]: `Entry` is move-only, so a by-value `foreach` cannot copy it out of
the container; iterate `source.refs()` for read-only access, `&value` for mutable
access, or remove the elements
```

Until then the compiler's own diagnostics, `L0491` and the `L0507` copy-cost
report for a by-value loop, still name `refs()` — the spelling the specification
no longer has.

## Not gaps

Recorded because they look like gaps and are not, and each cost an
investigation once.

- **Enums are closed.** An enum switch covering every variant needs no trailing
  return when every arm terminates, just like a union variant switch. Integer
  input is validated with `Enum.from_int`, and an enum without a variant
  represented by zero has no zero value (`design.md` "Enumerations").
- **Overlapping range cases are accepted.** Correct: cases are tried top to
  bottom and the first match wins (`design.md` "switch statement"). Only
  duplicate constant values are diagnosed.

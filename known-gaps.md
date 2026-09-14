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
compiler is partway there: ordinary traversal of an array, a slice, or a dynamic
array now lends each element, while maps, text, ranges, protocol iterators, and
every `indexed()` traversal still copy. Bindings are flat, `refs()` still exists,
and there is no consuming traversal.

This is one divergence rather than fifteen because it is one coordinated change.
[iteration-unification-plan.md](iteration-unification-plan.md) has the six
implementation steps; the specification is step 1, and the gap closes at step 6.

Step 2 has landed the two representations, checked but not yet lowered: a nested
binding pattern parses and reports `L0693`, and an iterator's `Yield` is read and
validated against its element — a mismatch is `L0694` — but a descriptor that
lends reports `L0695` rather than binding storage the lowering would treat as
owned. The catalogue's `Iterable` still spells its constraint
`Iterator(Self.Iterator, Self.Element)` rather than design.md's
`Self.Iterator.Item`; the two agree while every built-in yields owned elements,
and step 4 is what makes them differ.

Step 3 has landed the ownership and lifetime rules the lowering needs: a `&`
binding is a non-owning view like a switch payload, its loan ends with the step,
a pointer into a switch payload borrows the subject, and a lending method's
result is attributed by the callee's summary. The two built-in iteration synths
have no body to summarize, so they are still named directly in
[cfg_provenance.odin](src/cfg_provenance.odin).

Step 4 has converted the contiguous containers: iterating an array, a slice, or a
dynamic array clones nothing, and a move-only element is read like any other. The
adapters are what remain of it. `reversed()` lends, because it only flips which
element the cursor reaches, but `indexed()` materializes a record and so still
copies its element into one — and neither adapter is contributed at all for a
move-only element, so the sequence below has no `indexed` member to call rather
than a copy to refuse. `copied()`, consuming traversal, and the move-iterators do
not exist yet.

```odin
package main;

Entry :: move_only struct { id: int }

walk :: proc(items: []Entry) {
	foreach (item in items) { _ = item.id; }               // lends, as specified
	foreach (item, at in items.indexed()) { _ = at; }      // no such member
}
```

`L0491` is now reached through the map views, which still hand back owned halves:

```
error[L0491]: `Only` is move-only, so this view cannot copy the value out of the
map; iterate `&value`, or remove the entries
```

The refusal a sequence used to give still names `refs()` in its remedy — the
spelling the specification no longer has, and which step 6 deletes.

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

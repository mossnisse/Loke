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

Step 2 landed the two representations. A nested binding pattern parses and
reports `L0693`, still unlowered. An iterator's `Yield` is read and validated
against its element — a mismatch is `L0694` — and a borrowed descriptor now
lowers; a mutable one, and a record of descriptors, still report `L0695`.

Step 3 has landed the ownership and lifetime rules the lowering needs: a `&`
binding is a non-owning view like a switch payload, its loan ends with the step,
a pointer into a switch payload borrows the subject, and a lending method's
result is attributed by the callee's summary. The two built-in iteration synths
have no body to summarize, so they are still named directly in
[cfg_provenance.odin](src/cfg_provenance.odin).

Step 4 has converted the contiguous containers and their iterators: iterating an
array, a slice, or a dynamic array clones nothing, a move-only element is read
like any other, and `iter()`/`next()` hand back a pointer into the container, so
a manual walk and a loop agree. `reversed()` carries that through, and
`indexed()` lends when the header names the value and the index separately.

What remains of step 4: one name over an `indexed()` pair still materializes the
record, so that form copies and is not contributed for a move-only element; maps,
text, and ranges still yield owned values; and `copied()`, consuming traversal,
and the move-iterators do not exist. A single binding over a record yield —
design.md's `entry.key`/`entry.value` form — is what step 6 must migrate before
maps convert, so that nothing silently starts printing an address.

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

That remedy still names `refs()` for a sequence — the spelling the specification
no longer has, and which step 6 deletes.

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

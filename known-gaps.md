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
compiler is partway there: traversal of an array, a slice, a dynamic array, or a
map's halves now lends each element, while text, ranges, and every record the
traversal has to build still copy. Bindings are flat, `refs()` still exists, and
there is no consuming traversal.

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

Step 4 has converted the contiguous containers, their iterators, and the map
halves: iterating an array, a slice, or a dynamic array clones nothing, a
move-only element is read like any other, and `iter()`/`next()` hand back a
pointer into the container, so a manual walk and a loop agree. `reversed()`
carries that through; `indexed()` lends when the header names the value and the
index separately. A map lends both halves to `foreach (key, value in table)`, and
`keys()` and `values()` lend the half they name.

What remains of step 4 is everything that builds a record the container does not
store, because that record is a new value and copies into it: one name over an
`indexed()` pair, one name over a map entry, and `entries()`, which is why
`foreach (k, v in table)` lends while `foreach (k, v in table.entries())` copies.
design.md gives those a record `Yield` whose fields are descriptors, so the
binding would receive `entry.key^`; that is unlowered (`L0695`). Text and ranges
generate their elements rather than storing them and stay owned. `copied()`,
consuming traversal, and the move-iterators do not exist.

Step 6's first migration has landed ahead of the rest of it, so that no site
quietly changes what it prints when the record `Yield` does land: a single name
over a record built from parts the traversal lends is `L0696`, and the remedy is
to bind the parts. `foreach (entry in table)`, `foreach (entry in
table.entries())`, and `foreach (pair in items.indexed())` are all refused; a
discard, a destructuring header, and a pair over a range or over text are not.
The error lifts when the record `Yield` lowers and the binding can be written
`entry.value^`. One shape it does not yet catch is a name bound to such a record
*inside* a larger one -- `foreach (entry, i in table.indexed())` -- because the
nested pattern that would replace it is itself unlowered (`L0693`).

```odin
package main;

Entry :: move_only struct { id: int }

walk :: proc(items: []Entry, table: map[int]Entry) {
	foreach (item in items) { _ = item.id; }               // lends, as specified
	foreach (item, at in items.indexed()) { _ = at; }      // no such member
	foreach (key, value in table) { _ = value.id; }        // lends, as specified
	foreach (entry in table) { _ = entry.value.id; }       // one name, a record: L0696
	foreach (k, v in table.entries()) { _ = v.id; }        // builds a record: L0491
}
```

`L0491` is what remains where a record still has to be built:

```
error[L0491]: `(key: int, value: Entry)` is move-only, so a by-value `foreach`
cannot copy it out of the container; iterate `&value`, or remove the elements
```

For a sequence that remedy still names `refs()` — the spelling the specification
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

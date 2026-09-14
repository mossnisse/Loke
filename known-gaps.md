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
map now lends what the container stores, through a `Yield` the iterator declares,
while text, ranges, and the library's own iterators stay owned. Bindings are
flat and there is no consuming traversal.

This is one divergence rather than fifteen because it is one coordinated change.
[iteration-unification-plan.md](iteration-unification-plan.md) has the six
implementation steps; the specification is step 1, and the gap closes at step 6.

Step 2 landed the two representations. A nested binding pattern parses and
reports `L0693`, still unlowered. An iterator's `Yield` is read and validated
against its element — a mismatch is `L0694` — and a borrowed descriptor and a
record of them now lower; a mutable one still reports `L0695`.

Step 3 has landed the ownership and lifetime rules the lowering needs: a `&`
binding is a non-owning view like a switch payload, its loan ends with the step,
a pointer into a switch payload borrows the subject, and a lending method's
result is attributed by the callee's summary. The two built-in iteration synths
have no body to summarize, so they are still named directly in
[cfg_provenance.odin](src/cfg_provenance.odin).

Step 4 has converted the contiguous containers, the maps, and their iterators.
Iterating an array, a slice, a dynamic array, or a map clones nothing, a
move-only element is read like any other, and `iter()`/`next()` hand back what
the container stores, so a manual walk and a loop agree. A map lends both halves
of a slot: `foreach (key, value in table)` binds them where the table holds them,
`keys()` and `values()` lend the half they name, and `entries()` hands over a
record of their addresses, which one name reads through `entry.value^`. That
record is the `Yield` of descriptors design.md specifies, declared by the map's
own iterator and checked the way a user iterator's would be. `reversed()` carries
a lending source through, and `indexed()` declares a record `Yield` of its own --
`{value: Yield_Borrowed, index: Yield_Owned}` -- so numbering a lending traversal
lends the element and owns only the counter, stored view included.

What remains unlowered is a record built out of a record: `indexed()` over a map
or over its entry view puts the `{key, value}` entry inside the `{value, index}`
pair. One name over that is `L0696`, and two names reach `L0695` through the
entry view, while `foreach (entry, i in table.indexed())` still copies the entry
as it did before. The replacement is the nested binding pattern step 2 left
unlowered (`L0693`), which is why these wait for it rather than changing what
they bind. Text and ranges generate their elements rather than storing them and
stay owned, and so do the library's own iterators, `Enum_Array` included.
`copied()`, consuming traversal, and the move-iterators do not exist.

```odin
package main;

Entry :: move_only struct { id: int }

walk :: proc(items: []Entry, table: map[int]Entry, counts: map[int]int) {
	foreach (item in items) { _ = item.id; }                // lends, as specified
	foreach (item, at in items.indexed()) { _ = at; }       // lends, as specified
	foreach (key, value in table) { _ = value.id; }         // lends, as specified
	foreach (entry in table) { _ = entry.value^.id; }       // lends, as specified
	foreach (pair in counts.indexed()) { _ = pair.index; }  // a record of records: L0696
}
```

Only the last loop is refused, because only it nests a record inside the pair:

```
error[L0696]: one name over `(value: (key: int, value: int), index: int)` binds a
record of records, which is not lowered yet; bind the parts separately
```

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

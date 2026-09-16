# Iteration unification — completed v1 scope

Iteration now has one recursive binding model and two source-access modes:

```odin
foreach (item in items) { inspect(item); }               // borrowed
foreach (&item in items) { item.count += 1; }            // mutable
foreach (item in items.copied()) { take(move(item)); }    // explicit clone
```

The completed implementation includes:

- recursive binding patterns in runtime loops and static expansion;
- recursive `Yield` descriptors, including borrowed, mutable, and mixed record
  leaves;
- borrowed traversal for container storage, with source provenance preserved;
- mutable traversal through `Mutable_Iterable`, including `indexed()`,
  `reversed()`, and `map.values()`;
- `indexed()` preserving a source's recursive yield shape;
- `copied()` cloning only borrowed leaves and passing owned leaves through;
- removal of the old implicit index and mutable-map-entry spellings.

A temporary root lives for the whole statement and lends its elements. A
written `move(root)` transfers the collection into that statement-owned root,
but does not create movable element bindings. A future consuming-iterator
proposal would need to specify and implement partial-container cleanup for
exhaustion, early exit, panic, fixed arrays, dynamic storage, maps, and library
containers before becoming normative.

Regression coverage belongs in the ordinary run, error, syntax, LLVM, and
front-end suites; unfinished behavior is not kept as an accepted diagnostic.

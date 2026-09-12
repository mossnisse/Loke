# Borrowed collection traversal with unified binding rules

## Summary

Make iteration follow the ownership rule `switch` already uses ([design.md "Switch ownership"](design.md#switch-ownership)): a place borrows; a temporary or `move(place)` consumes. Ordinary traversal of a place therefore borrows each element immutably instead of cloning it. Assignment and parameter semantics are unchanged, `&` still requests mutation, and `.copied()` is the explicit copy.

```odin
foreach (item in items) { inspect(item); }               // borrowed: no clone, works for move-only items
foreach (item in items.copied()) { take(move(item)); }   // one clone per element
foreach (item in move(items)) { take(move(item)); }      // consumed: elements transfer
foreach (item in make_items()) { take(move(item)); }     // a temporary is consumed too

foreach (&item, index in items.reversed().indexed()) { ... }
foreach ((key, &value), index in table.indexed()) { ... }
```

Land this as one coordinated change — compiler, library, documentation, and tests together, without a compatibility flag. `.refs()` is removed: a borrowed binding plus `&item` covers it.

## Traversal mode

The header alone decides the mode:

1. Any `&` leaf in the pattern selects **mutable** traversal. The root must be writable storage (a mutable place or a `[]mut` view). `&` together with `move(...)` or `.copied()` is an error.
2. Otherwise a root that is a temporary or `move(place)` selects **consuming** traversal when every adapter in the chain supports it, and borrowed traversal of the owned temporary otherwise. A borrowed view such as a slice never consumes its backing collection.
3. Otherwise traversal is **borrowed**.

The root is the expression the adapters and built-in views (`indexed`, `reversed`, `copied`, `keys`, `values`, `entries`) are applied to, so `foreach (&v in m.values())` roots at `m`. Those only carry the mode through; they never choose it. The root is evaluated once, and a temporary root lives for the whole statement ([design.md "Temporaries and procedure boundaries"](design.md#temporaries-and-procedure-boundaries)). User-defined methods with these names keep lookup precedence and are ordinary calls.

## Iterator contract

- In [the standard interfaces](base/interfaces/interfaces.loke), each traversal mode's iterator has `next(self: inout It) -> Option(Item)` and a `Yield` descriptor saying how foreach binds `Item`:
  - `Yield_Owned` — the binding is `Item` itself;
  - `Yield_Borrowed` / `Yield_Mutable` — `Item` is `^T` / `^mut T`, the binding is a borrowed `T`;
  - a record whose fields recursively describe a record `Item`, e.g. `struct{key: Yield_Borrowed, value: Yield_Mutable}`.
- `Element`, what a single binding receives, is `T` for a borrowed or mutable leaf and `Item` otherwise. The checker validates `Yield` against `Item`'s shape and rejects a record descriptor over a record with a custom `hook(copy)` or `hook(drop)` — the restriction consuming destructuring already has.
- **Defaults keep existing iterators unchanged:** an iterator declaring only `Element`, as every one does today, is owned with `Item = Element`. `Countdown` in design.md compiles as is.
- Keep `Iterable`/`iter` and `Mutable_Iterable`/`iter_mut`; add one `Consuming_Iterable` with `Move_Iterator` and `iter_move(self: move Self)`. Reversal in each mode is a receiver method found the way `iter_reverse` is today — `iter_reverse`, `iter_mut_reverse`, `iter_move_reverse` — with no new interfaces. A type's modes must agree on the logical element.
- Built-ins: arrays, slices, dynamic arrays, and `Small_Array` yield borrowed elements, move-only ones included. Map entries are borrowed `{key: ^K, value: ^V}`; `Enum_Array` entries are `{key: E, value: ^T}` with an owned key. Ranges, runes, and bytes stay owned. Consuming traversal yields owned elements and owned `{key, value}` entries.
- Manual `next()` returns `Item`. Code that must be generic over the yield mode uses `foreach`; no projection operation is added.

## Bindings

- Foreach bindings become recursive patterns: `(a, (b, &c))`. Leaves keep today's declaration-order, visibility, `_`, and arity rules. `:=` destructuring stays flat; design.md's destructuring section says foreach patterns add nesting and `&` leaves on top of it.
- An `&` leaf must land on a `Yield_Mutable` location; unmarked leaves are immutable.
- Remove the implicit index and map-value forms: `foreach (&v, i in seq)` becomes `seq.indexed()`, `foreach (&v in map)` becomes `map.values()`, and `foreach (key, &value in map)` is plain destructuring. The old spellings get a diagnostic naming the replacement.
- A single binding over a record yield receives the record with its pointer fields (`entry.value^`); destructuring binds the pointees directly. No transparent borrowed-record type is introduced.
- A borrowed binding cannot be moved or dropped — generalize `borrowed_binding` and L0690 ([lifecycle.odin:150](src/lifecycle.odin:150)) beyond switch payloads. `saved := item` still clones and so rejects a move-only `item`. `&item` on a borrowed binding yields a `^T` carrying the element's source provenance; that is the `.refs()` replacement.

## Adapters

- `.indexed()` and `.reversed()` work in all three modes and nest arbitrarily. `.reversed().indexed()` numbers the reversed traversal from zero. Reversal never allocates; maps and runes stay forward-only.
- `.copied()` lazily clones borrowed leaves using existing copy hooks, allocator selection, and failure behavior. Owned leaves pass through uncloned, so over a consuming traversal it is a no-op. It rejects non-copyable borrowed leaves and `&` leaves.
- A **stored** adapter (`v := items.indexed()`) is always a borrowed view that freezes its source while live — today's rule ([design.md "Iteration adapters"](design.md#iteration-adapters)). Mutable and consuming traversal through adapters exists only in a foreach header, where the root's loan or transfer spans the statement.

## Lifetimes and ownership

- **Borrowed yields** carry source provenance, so they — and `&item` — may outlive advancement and the iterator while the source stays valid. For a user-defined `next()` the returned pointer must derive from a view the iterator holds, not from the iterator's own storage; build this on the existing rule that a view carried by a receiver obeys its own source ([cfg.odin:4064](src/cfg.odin:4064)). It replaces the synth-kind list at [cfg.odin:4069](src/cfg.odin:4069) and `iteration_lends_source`.
- **Mutable traversal** holds an exclusive source loan. Every yielded loan, nested pointers and derived pointers included, ends before advancing or dropping the iterator — on every loop exit and for manual calls.
- **Consuming traversal** transfers each element without cloning. The move-iterator owns the collection and tracks the unyielded range or occupied map slots, so early exit drops only unyielded elements and frees storage once, without front removal or shifting. Map consumption transfers both key and value, unlike current removal. Provided for arrays, dynamic arrays, maps, `Small_Array`, and `Enum_Array`.

## Implementation sequence

1. Update [the specification](design.md) and [grammar](grammar.md): the mode rule, `Yield`, patterns, `.copied()`, consuming traversal, `.refs()` removal, migration examples, and the move-only `Small_Array` claims in the interface catalogue.
2. One checked yield description and one recursive pattern representation through parsing, AST cloning/dumping, interface checks, generic resolution, and diagnostics. Record the mode and every projection during checking.
3. Lifecycle, control-flow, and provenance: generalize borrowed bindings; distinguish descriptor loans, whole-traversal loans, and per-step loans; replace the `.refs()` exceptions with the verified yield rule.
4. Convert built-in and library iterators (dropping `where is_copyable(T)` from borrowed `next`), then adapters, `.copied()`, and move-iterators. Extend runtime transfer helpers for map consumption.
5. Direct LLVM loops, protocol calls, and supported CTFE/static-foreach paths consume the same checked description. Borrowed bindings register no cleanup; owned payloads keep exactly-once cleanup.
6. Migrate. First make a single binding over a record yield a temporary error and fix every site (including design.md's `entry.key, entry.value` example) by destructuring or writing `^`, then lift the error — so no `fmt.println(entry.value)` silently starts printing an address. Migrate the `&v, i` forms and the `.refs()` uses, then delete [iteration_refs.odin](src/iteration_refs.odin) and the `Refs_*` synths.

## Verification and acceptance

- **Copy costs:** instrument copy/drop hooks and allocation counts. Plain, indexed, reversed, generic, and manual borrowed traversal clone nothing; `.copied()` clones each borrowed element once; consuming traversal, including of temporaries, clones nothing.
- **Mode selection:** place, temporary, `move(place)`, `move(view)`, `&` leaves, each rejected combination, and chains without consuming reverse falling back to borrowing.
- **Move-only access:** owning sequences, immutable parameters, map values, library containers, temporaries. Reads succeed; copying, moving, or dropping a borrowed element fails with the L0690-style diagnostic.
- **Bindings:** whole records, flat and nested patterns, discards, visibility failures, pointer-valued user generators, `&item` provenance. Ordinary assignment stays independent.
- **Borrow correctness:** borrowed pointers survive advancement and iterator drop; source invalidation while they live is rejected; mutable-loan escape and advancement are rejected through nested records, helpers, and stored-adapter aliases; a user `next()` lending its own storage is rejected.
- **Cleanup:** exhaustion, `break`, `continue`, `return`, propagated failure, panic, and dropping an unstarted or partly consumed move-iterator; partial `.copied()` failure; managed map keys and values.
- **Backend agreement:** direct loops match manual and generic protocol traversal; pin "no hidden clone or snapshot" as `tests/ll` fixtures.
- Run citation checks, compiler unit tests, vetted builds, and the full matrix through `test-all.ps1`.

Acceptance requires matching behavior across direct loops, stored adapters, and protocol calls, unchanged ordinary assignment semantics, and no hidden element cloning in default traversal.

## Not in this change

- `.indexed().reversed()` with original indices, and the `Exact_Size_Iterable` it needs — design.md rejects it deliberately; add when a caller needs it.
- Stored adapters that observe later source mutation or carry write capability — the freeze rule is simpler and covers every current use.
- Consuming a string into a rune iterator — runes are generated by value either way.
- A separate `Into_Iterator` — `Consuming_Iterable` is the one consuming interface.

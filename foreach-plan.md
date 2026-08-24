# Unified `foreach` element bindings

## Status

Implemented. The compiler unit tests, the integration corpus, and the run/trap
corpus at every optimization level are green.

Two things landed differently from the outline below, and design.md records both:

- **Adapters are header forms, not values.** They are recognized in a `foreach`
  header and choose the lowering; no adapter type, iterator object, or
  allocation exists. That is what makes `a.indexed()` emit exactly the index loop
  the bare form used to, and it is the whole reason there is no `core:iter`
  package. Binding an adapter to a variable is not part of version 1.
- **`reversed()` is forward-only for maps and text** — a map's order is
  unspecified, and walking UTF-8 backwards needs a decoder version 1 does not
  have. Fixed arrays, slices, dynamic arrays, ranges, and any user type with
  `iter_reverse` do reverse.

One pre-existing defect surfaced and is fixed here: a `slot` requirement naming
`Self.Assoc` resolved that member with the *interface's* lookup package, so
`interfaces.Iterable(T)` would have demanded that every iterable publish its
`Iterator`. The signature now resolves at the application site, which is what
"an inherent member's visibility does not enter into it" already claimed.

## Context

Value-producing `foreach` currently means three different things depending on
what it iterates. A second binding is an index for a sequence, a byte offset for
a string, and a value for a map — and a map is the one container whose *first*
binding is not its `Element`. Each exception exists in the checker, in the
lowering, and in the interface catalogue.

This plan removes all three. **A `foreach` binds exactly the `Element` that
`source.iter().next()` yields.** Comma bindings destructure a record element
positionally. Everything a loop used to supply on its own — an index, a byte
offset, a key — becomes information the *iterable* carries, reached through an
adapter. Built-in by-reference iteration is untouched: it projects storage
rather than binding an element, so it keeps its own fixed names.

The language is pre-1.0, so this is a breaking cleanup with no compatibility
aliases. design.md and grammar.md are already updated; this plan implements them.

The normative sections are [Iteration protocol](design.md#iteration-protocol),
[Element bindings](design.md#element-bindings),
[Iteration adapters](design.md#iteration-adapters),
[By-reference iteration](design.md#by-reference-iteration),
[foreach statement](design.md#foreach-statement),
[Static `foreach` expansion](design.md#static-foreach-expansion),
[Iterating an enumeration](design.md#iterating-an-enumeration), and
[Standard interface catalogue](design.md#standard-interface-catalogue).

## Language changes

### The element rule

- One binding names the whole `Element`, whatever its type.
- N ≥ 2 bindings require a record `Element` with exactly N directly declared
  fields, all visible at the loop, bound positionally in declaration order.
  Promoted members of an embedded record are not flattened; visibility follows
  the positional-construction rule.
- Any binding may be `_`. The element is still produced whole, its fields are
  moved into the named bindings without a second copy, and the remainder is
  disposed of normally.
- Value bindings are immutable locals. No nesting, no patterns, no destructuring
  outside a `foreach` header.

### The protocol

- `Iterable` requires a `self`-receiver `iter`, stated in the catalogue as
  `slot iter: proc(self) -> Self.Iterator`. `iter` stays in the standard
  customization table, so the free call `iter(x)` remains available through the
  ordinary overload group — this is not a new lookup rule, it is what already
  happens when a type declares `len` with a receiver.
- A visible extension block satisfies the requirement inside its own package.
  Protocol member lookup stays inherent-plus-visible-extension; it must not
  consult the caller's extensions at a generic definition site.
- New `Reverse_Iterable` composes `Iterable` and adds
  `slot iter_reverse: proc(self) -> Self.Iterator`.

### Adapters

Recognized in the `foreach` header on **every** iterable, built-in or
user-declared: the adapter chooses the traversal the loop lowers to rather than
building an iterator object. There is no `core:iter` package and no second
free-call spelling. Adapter names are reserved in that position.

| Adapter | `Element` | Available on |
|---|---|---|
| `indexed()` | `struct{value: Element, index: int}` | every `Iterable` |
| `reversed()` | source `Element`, reversed | every `Reverse_Iterable` |
| `entries()` | `struct{key: K, value: V}` | `map[K]V` |
| `keys()` | `K` | `map[K]V` |
| `values()` | `V` | `map[K]V` |
| `runes()` | `rune` | `string`, `string_view` |
| `rune_offsets()` | `struct{value: rune, offset: int}` | `string`, `string_view` |
| `bytes()` | `u8` | `string`, `string_view` (already exists) |

- `indexed()` increments only after a successful `next`, and numbers whatever
  traversal precedes it — so it is written last and once.
- `reversed()` on a forward-only iterable is a compile-time error. No buffering
  fallback: adapter construction never allocates. Maps (unspecified order) and
  text (no backward decoder in version 1) are forward-only.
- Every adapter is a borrowing view. It holds the same whole-loop loan the bare
  iterable would, and none of them copies or allocates.

### Element changes

- `map[K]V.Element` becomes `struct{key: K, value: V}` with public fields.
- `string`/`string_view` `Element` stays `rune`.
- Enum types gain compiler-provided `Enum.values()`, a constant declaration-ordered
  fixed array — an ordinary constant expression, not a loop form, so it also
  serves `len`, indexing, a `$` argument, and a static expansion. **The
  enum-type-in-`foreach` special case is deleted** — a type is never an iterable —
  which removes compiler machinery rather than adding beside it, and lets
  adapters apply to enums like any other array.

### Unchanged

`foreach (&value in sequence)`, `foreach (&value, index in sequence)`,
`foreach (&value in map)`, and `foreach (key, &value in map)` keep their exact
current types, mutation effects, index/key meanings, and borrow diagnostics.
They are storage projections, not element bindings, and stay unavailable through
the value-returning protocol.

## Implementation

### 1. Grammar and AST

- `Binding ("," Binding)*` in the parser; AST carries a binding list.
- Classify each header as value, static, or built-in place iteration **before**
  checking binding semantics, so each classification owns its own arity rule.

### 2. Element binder

- One shared binder used by both the optimized built-in lowering and the generic
  protocol lowering. It takes an element value and a binding list and produces
  the locals. This replaces the map-specific, string-specific, and
  counter-specific binding paths in `src/iterate.odin`.
- Direct map lowering must produce entry records with the same cloning, failure,
  field order, and cleanup behavior as `map.iter().next()`.

### 3. Adapters

- Peel the adapter chain off the header, then classify the iterable: one
  traversal, with `indexed()` numbering it from the outside.
- **Built-in `indexed()` must keep the direct index-loop lowering.**
  `foreach (v, i in a.indexed())` over a fixed array, slice, dynamic array, or
  range must emit what `foreach (v, i in a)` emits today — no iterator object.
  This is the most common loop in the language and must not regress.
- `indexed()` and `reversed()` are compile-time evaluable over constant arrays,
  `Enum.values()`, ranges, and reflection descriptor arrays.

### 4. Lifecycle

**Unchanged, and deliberately so.** A by-value loop over a managed element is
still `L0504`: per-iteration cleanup is loop-body machinery the M5a CFG does not
place, and this change does not add it. What the element rule has to preserve is
the exemption that made managed *keys* iterable — a key binding borrows the
stored key rather than copying it — so the managed check runs per bound field
rather than over the whole element:

- a destructured map entry checks the value, not the borrowed key;
- `keys()` binds in place, so a `map[string]V`'s keys still iterate;
- a one-name loop binds the whole entry, which copies, so `L0504` applies to it
  exactly as it does to any other managed element.

Per-iteration drops, unobserved-payload cleanup, and iterator destruction order
remain open against the milestone that adds loop-body cleanup.

### 5. Diagnostics

- Arity mismatch names the element type, its field count, and the binding count.
- Scalar element with N ≥ 2 bindings over a **built-in sequence** must suggest
  `.indexed()` explicitly; over a **string**, `.rune_offsets()` or `.indexed()`;
  over a **map**, nothing (a map element already destructures).
- Inaccessible field in a destructure names the field and its visibility.
- `&` in a value or static binding list, and mixed `$`/`&`, keep their errors.
- A type in a `foreach` header (including an enum type) errors with a suggestion
  to write `.values()`.

### 6. Migration

Whole corpus is roughly 30 loops plus documentation. Mechanical:

| From | To |
|---|---|
| `foreach (v, i in seq)` | `foreach (v, i in seq.indexed())` |
| `foreach (c, off in s)` | `foreach (c, off in s.rune_offsets())` |
| `foreach (v in m)` | `foreach (v in m.values())` |
| `foreach (x in E)` for enum `E` | `foreach (x in E.values())` |
| `iter(source)` in stdlib and examples | `source.iter()` |
| `foreach ($f, $i in fields_of(T))` | `foreach ($f, $i in fields_of(T).indexed())` |

Two of these change meaning **silently** rather than failing to compile, and are
the only ones needing a grep rather than a rebuild:

1. `foreach (v, i in seq)` where the element is a two-field record — was
   value + index, now destructures the record.
2. `foreach (v in m)` — was the value, now the entry record; a body that only
   prints `v` still compiles.

Pre-1.0 with no external users, so no transitional diagnostic is worth carrying:
grep for two-binding value loops over sequences and one-binding loops over maps,
fix them, done. `design.md` §"Iterating through slices of structs" already
documents case 1 as a worked example.

Also updated: compiler diagnostics, `core:strings`, `core:path`,
`core:encoding/utf16`, the examples, `readme.md`, and the superseded iteration
rows in [m4b-plan.md](m4b-plan.md) and [m6b-plan.md](m6b-plan.md). There was no
free `reverse` procedure to delete — design.md described one that was never
written.

### 7. Tests

- **Parser/checker.** Two- and three-field records; arity too high; scalar
  element with two bindings; `_`; `&` on a place loop's index. Field visibility
  reuses `require_visible_field`, already covered by the visibility corpus.
- **Runtime.** Arrays, ranges, user iterables, map entries/keys/values, rune
  ordinals vs. byte offsets vs. byte indices, `reversed()`, `reversed().indexed()`,
  empty iterables, unspecified map order.
- **Compatibility.** Every existing place form: types, mutation effects,
  index/key behavior, borrow diagnostics unchanged.
- **Static.** `Enum.values().indexed()`, `fields_of(T).indexed()`, record
  constants, empty expansion, mixed `$`/`&` errors.
- **Lifecycle.** Only what exists: a managed map key still iterates by borrow
  through a destructured entry and through `keys()`, and `L0504` still rejects a
  managed element bound by value. The rest waits on loop-body cleanup.
- **Generic.** A user type needs only associated `Element`/`Iterator`, a receiver
  `iter`, and `next`; `user_value.indexed()` works with no default interface
  methods; `user_value.reversed()` fails to compile without `iter_reverse`.
- **Codegen.** `tests/ll/foreach_indexed.loke` pins the direct index-loop shape
  for `indexed()` over a fixed array and a slice, and the mirrored access
  `reversed()` emits — one cursor, one `getelementptr`, no iterator object.
- The `.ll` fixtures that contain `foreach` still hold: every migrated form
  lowers to what it lowered to before.
- Compiler unit tests, the full integration corpus, and the run/trap corpus at
  `-opt=minimal|size|speed|aggressive` (`LOKE_TEST_FLAGS`).

The new cases live in `tests/run/foreach_elements.loke`,
`tests/err/foreach_elements.loke`, and `tests/ll/foreach_indexed.loke`.

## Acceptance criteria

1. Every value and static loop binds exactly one `Element`; no loop-supplied
   counters, keys, or offsets remain in the value path.
2. `map[K]V.Element` is its entry record and every container's first binding is
   its `Element`.
3. `.indexed()` over built-in sequences and ranges emits the same code as the
   current two-binding form.
4. Adapters allocate nothing, and `reversed()` without `iter_reverse` is a
   compile error.
5. No enum type is accepted in a `foreach` header, and the special case is gone
   from the compiler rather than bypassed.
6. All place forms behave exactly as before.
7. Full corpus green at every optimization level.

## Assumptions

- Pre-1.0 breaking cleanup; no compatibility alias for free-`iter`-only types,
  value-only map iteration, implicit value-loop indices, or enum-type iteration.
- Adapter construction never allocates; copying a yielded managed element may
  allocate under its normal copy semantics.
- Interface default methods, reference-bearing records, and a user-definable
  reference-yielding iterator protocol stay out of scope.
- An adapter is a header form in version 1: it is not bound to a variable or
  passed to a procedure. A traversal that must travel is a type of its own with
  its own `Element`/`Iterator` pair, which nothing in the corpus needs yet.

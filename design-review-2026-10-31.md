# Language design review (2026-10-31)

A review of the Loke language as [design.md](design.md) and
[grammar.md](grammar.md) specify it, looking for ways to make the language
smaller, more regular, and faster, rather than for features to add. It is
non-normative: everything below is a proposal for discussion, not an amendment,
and backward compatibility was not a constraint. Where it recommends deleting
or merging something, it says what is lost, so that each item can be judged on
its merits for a general-purpose language and not by how often the repository
happens to use it.

The review read design.md, grammar.md, comments.md, open-questions.md,
known-gaps.md, future-plans.md, and the design rules of standard-library.md in
full, sampled the LLVM emitter, the runtime ABI header, and the benchmark
baselines, and ran probe programs against the shipped `lokec.exe` (see
[Probes](#probes)). It builds on the
[language design review of 2026-10-03](open-questions.md#language-design-review-2026-10-03)
and does not repeat what that review already settled.

A second pass the same day checked each proposal against the specification,
known-gaps.md, and the runtime, looking for costs the first draft had not
counted. Proposals whose costs outweighed their gains were withdrawn; each is
listed with its reason under [Withdrawn proposals](#withdrawn-proposals), so
that it is not proposed again without an answer. Others were narrowed, and
their **What is lost** now says what the first draft missed.

A [review of these proposals](open-questions.md#review-of-the-design-review-proposals-2026-10-31)
then checked the return and lifetime rules, LLVM capture semantics, and emitted
code. Its findings on address capture, slice bounds, and the small-value ABI
are incorporated below; the two on generic `Status` fallthrough and `any_view`
lifetimes were settled when those proposals were adopted. A check of the
alias-attribute step on 2026-11-01 linked hand-edited IR at `-O2` and found
that `noalias` is unsound under the default `unwind` strategy, that a callee
may read a global it holds `^mut` to, and that LLVM already infers the capture
attributes; [6.1](#61-alias-attributes-from-facts-the-checker-already-proves)
and step 4 of the [Suggested order](#8-suggested-order) are narrowed
accordingly.

On 2026-11-01 the review was revised to the language as it then stood. The
first five steps of its suggested order had landed: the editorial fixes, the
performance work that needed no language change, `Status` as an alias of
`Result(Unit, E)`, `variants_of` over enums, and the deletion of `any_view`.
Their proposals are removed from the text and listed under
[Adopted proposals](#adopted-proposals), the remaining sections are
renumbered, and the inventory and probes are taken again from the compiler at
`4173b622`.

A review of step 1 the same day found that the generated copy of the review's
own example of a field-wise copy, a `Box` chain with an iterative drop hook,
overflows the stack on a long chain ([Probes](#probes)). The copy decision for
drop hooks, argued on that ground and split from the attribute move, which is
syntax alone, then landed and is under [Adopted proposals](#adopted-proposals).

## Contents

- [Summary](#summary)
- [1. The shape of the language today](#1-the-shape-of-the-language-today)
- [2. Type theory as a simplifying lens](#2-type-theory-as-a-simplifying-lens)
- [3. Orthogonality](#3-orthogonality)
- [4. Syntax](#4-syntax)
- [5. Deletion candidates](#5-deletion-candidates)
- [6. Performance of the generated code](#6-performance-of-the-generated-code)
- [7. The specification itself](#7-the-specification-itself)
- [8. Suggested order](#8-suggested-order)
- [Adopted proposals](#adopted-proposals)
- [Withdrawn proposals](#withdrawn-proposals)
- [Probes](#probes)

## Summary

Loke's individual decisions are well argued, and comments.md records the
argument for nearly every one. The problem is the sum. The specification is
about 12,000 lines; it has three spellings of a sum type, two reflection tiers,
two mutable-borrow modes, four inferred effect systems, 27 attributes, and a
list of nineteen implicit conversions. Each was added for a reason. The two
clearest pairs that expressed one idea twice, `Status` beside
`Result(Unit, E)` and `any_view` beside `dyn`, are gone
([Adopted proposals](#adopted-proposals)). Of the pairs that remain, not every
one is a duplicate: `via` and construction with an allocator differ in a way
that matters, and `inout` and `^mut T` may ([2.5](#25-one-capability-axis)).

The remaining recommendations with the best ratio of concepts removed to
expressiveness lost, in rough priority order:

1. **Effects stated once**, as one algebra that the four inferred effects
   read ([2.3](#23-effects-as-one-algebra)).
2. **Attributes in one position**, with `move_only` as one of them
   ([3.1](#31-attributes-in-one-position)).
3. **Delete** `using` and, if wanted, the splat of a typed scalar into a
   `Simd` ([5](#5-deletion-candidates)).
4. **Generated-code performance.** Prove common index arithmetic
   overflow-free and indexed views' bounds stable; emit the container fast
   paths in the module, since linking the runtime as bitcode did not inline
   them; and emit `noalias` under `-panic=abort` once its soundness
   prerequisites hold, if a measurement then justifies it
   ([6](#6-performance-of-the-generated-code)).

Except where a section's **What is lost** says otherwise, none of these changes
what a Loke program can express.

## 1. The shape of the language today

An inventory, counted from design.md and grammar.md, to show where the weight
is:

| Area | Count | Where it is |
| --- | --- | --- |
| Reserved words | 36 | [Keywords](grammar.md#keywords) |
| Contextual keywords, each with a disambiguation rule | 17 | [Keywords](grammar.md#keywords) |
| Attributes | 27 | [Attribute categories](design.md#attribute-categories) |
| Implicit conversions | 19 | [Implicit type conversions](design.md#implicit-type-conversions) |
| Spellings of a sum type | 3 | `enum`, `union`, `(a: A \| b: B)`; `Option` and `Result` are library unions, and `Status` is a [parametric alias](design.md#parametric-aliases) of `Result(Unit, E)` |
| Spellings of a product type | 3 | `struct`, `(a: A, b: B)`, `(A, B)` |
| Type-erasure mechanisms | 1 | `dyn I`, including `dyn proc` |
| Reflection tiers | 2 | `meta.*` descriptors, `runtime.Type_Info` |
| Mutable-borrow parameter modes | 2 | `inout T`, `^mut T` |
| Interface requirement forms | 4 | expression, validity, truth, slot |
| Overload-ranking levels and tie-breakers | 4 + 5 | [Operator lookup and overload resolution](design.md#operator-lookup-and-overload-resolution) |
| Inferred whole-program effects | 4 | write, reach, allocator-use, pooled-join TLS |
| Checks a `parallel` block's task passes | 7 | [Structured concurrency](design.md#structured-concurrency) |
| Receiver forms | 4 | `self`, `self: ^`, `self: inout`, `self: move` |
| Yield modes | 4 | [Yield modes](design.md#yield-modes) |
| Lines in design.md | 11,982 | |

Three observations follow from the table.

**The language is largest where it is most original.** Ownership (chapter 8),
structured concurrency, and the inferred effects are about a third of the
specification. That is also where Loke's value is: local borrow checking
without lifetime annotations, and tasks checked without `Send` and `Sync`.
Simplifying there means stating the mechanisms once rather than removing them
([2.3](#23-effects-as-one-algebra)).

**The duplicates that were cheap to remove are gone; the pairs left differ.**
Deleting `any_view` left `dyn` as the one existential: a variadic `..dyn I`
parameter views each argument implicitly, which was the part of `any_view`
printing needed, and nothing asks an erased value for its type. Declaring
`Status :: Result(Unit, $E);` cost a new feature, parametric type aliases, but
removed a nominal type, its duplicate `map_error`, and the wart that generic
code over `Result` did not take a `Status`. `enum` and a union of payloadless
variants now share `variants_of` and keep separate surfaces, because a union's
tag order is not API. The pairs that remain only look alike: `inout` is
written at every call that mutates, which a `^mut T` value forwarded without
`&mut` is not ([2.5](#25-one-capability-axis)), and `via` gives a
declaration's fields and elements an allocator, which construction with an
allocator does not ([Withdrawn proposals](#withdrawn-proposals)).

**The spec carries implementation detail.** The minimum provenance precision
budgets, the normalized-input discussion, and several paragraphs under
[Allocator regions and region provenance](design.md#allocator-regions-and-region-provenance)
describe how a conforming analysis must behave in terms only an implementer
reads. They belong in a normative conformance appendix
([7](#7-the-specification-itself)).

## 2. Type theory as a simplifying lens

Type theory is useful here not as a source of new features but as a way of
noticing when two constructs denote the same thing. Loke's type system is, in
these terms: sums and products (nominal and structural), a two-point
capability lattice on borrows (read, mutable), affine types (move-only),
existential packages (`dyn`), region-based memory (allocator provenance), and
an inferred effect system. Each is sound and conventional. The simplifications
come from the places where one of those denotations has two spellings.

Two such places are already resolved: `dyn` is the only existential, and
`Status(E)` is `Result(Unit, E)` ([Adopted proposals](#adopted-proposals)).
Sums keep `enum` beside `union` for the reasons under
[Withdrawn proposals](#withdrawn-proposals); one kind for both inside the
checker and emitter would be a compiler refactor that changes nothing in the
specification, worth doing only for the code it removes.

### 2.1 Products: the current split is right

`struct` is nominal and generative, an anonymous record is structural, and an
unlabeled record is a structural record whose positions are its names. This is
the standard distinction, and comments.md
["Structs declare, parentheses describe"](comments.md#structs-declare-parentheses-describe)
gives the right reason to keep it: nominality is what pays for privacy, hooks,
and field reordering. No change proposed, beyond the attribute position in
[3.1](#31-attributes-in-one-position).

### 2.2 Procedures are callable records

`Callable(C, Signature)` "holds by a built-in rule, since a parameter list is
not a requirement an interface body can spell". That is true, and the only
general fix is variadic generics, which this review does not recommend. The
smaller observation is that the catalogue already treats a procedure value as a
record with a `call` method and no fields (`dyn proc(...)` is
`dyn Callable(...)`, and a procedure "occupies the view's data word"). Saying
so once in design.md, as the definition of procedure values, would let
[Calling a value](design.md#calling-a-value), `Callable`, and
[Borrowed callable views](design.md#borrowed-callable-views) share one
paragraph of rules instead of restating them.

### 2.3 Effects as one algebra

Loke has an inferred effect system without naming it: the write effect, the
reach effect, the allocator-use effect, and the pooled join's `thread_local`
write-back are each defined with their own resolution rule for callbacks,
procedure values, `dyn` views, and unions, and the specification says "with
callbacks and unions resolved as under Global write effects" three times.

**Proposal.** Define *effects* once: a procedure's effect is a set of facts
(writes global `g`, reaches through global carrier `g`, operates on region `r`,
writes `thread_local` `t`); a call takes the union of its callee's effects; a
call through a value takes the union over every procedure the value may hold,
by one rule for locals, parameters, `dyn` witnesses, and procedure groups. Then
each of the four is one sentence naming which facts it reads and where. This
does not change what is checked; it halves the text that specifies it, and
gives [Per-call effect precision](open-questions.md#per-call-effect-precision)
one place to improve instead of four. The consolidation must keep per-call
region substitution and the difference between a pooled join's and a spawn's
effects on the parent's thread-local storage
([Structured concurrency](design.md#structured-concurrency),
[Allocators and tasks](design.md#allocators-and-tasks)).

Type theory offers a second, larger question here: whether a declared effect
(a `Send`-like marker, or a written effect row on public procedures) would be
simpler than whole-program inference. comments.md
["Tasks that borrow, joined by their block"](comments.md#tasks-that-borrow-joined-by-their-block)
chooses inference deliberately and names the price: a body change elsewhere
can reject a block here. The open proposal
[Public borrow contracts should stand on their own](open-questions.md#public-borrow-contracts-should-stand-on-their-own)
is the right boundary: inferred inside a package, written at the public
surface. This review endorses it and adds that the same written form should
carry a procedure's effect summary, so that an `api.loki` tells a reader what
a call may touch without the body.

### 2.4 Coercions

[Implicit type conversions](design.md#implicit-type-conversions) lists
nineteen rules. Each is a subtyping or coercion rule that feeds the four-level
overload ranking. Most are sound and useful (owner to view, `mut` to
read-only, `dyn` to a composed base, a value to a `dyn I` view as an element of
a `..dyn I` parameter, unfixed constants). Two deserve attention:

- **A scalar to `Simd(T, N)`, the splat.** Two cases share the rule. An unfixed
  constant, as in `lanes * 2.0`, `v << 2`, or `half: Simd(f32, 4) = 0.5`
  ([Construction and conversion](design.md#construction-and-conversion)), is
  the common one; it belongs with the other unfixed-constant conversions and
  should stay. A typed scalar variable splatting into a vector is the one case
  in the list that manufactures a wider value from a run-time operand. If that
  case goes, its replacement needs a rule of its own: `Simd(f32, 4)(x)` is
  today a lane-wise conversion between vectors of the same lane count, so a
  splat would be `simd.splat(x)` or a new conversion form. Low priority.
- **A distinct procedure type to and from its underlying procedure type.** It
  undoes `distinct` for exactly one kind of type. If a distinct procedure type
  should be freely interchangeable with its base, it is an alias, not a
  distinct type; if not, the conversion should be explicit as for every other
  distinct type. The cost to weigh is that every named procedure or procedure
  literal passed where a distinct procedure type is expected then writes the
  conversion.

### 2.5 One capability axis

[Capabilities and the one rule](design.md#capabilities-and-the-one-rule) says
the language has one axis, read-only or `mut`, and spells it the same way on
pointers, slices, and `dyn` views. Parameters then have a second spelling of
the mutable side: `inout T`, "a distinct mode rather than a spelling of
`^mut T`". The stated differences are that it is non-null (so is `^mut T`),
bound to the call (so is any borrow a callee cannot store), marked at the call
site (`&mut x` is a marker too), and "may invalidate the whole owner it names"
(so may a `^mut [dynamic]T`, through `p^.append(1)`; what cannot is an
*interior* pointer, which is a provenance fact, not a mode).

The asymmetry shows in [Receiver forms](design.md#receiver-forms): `self: ^` is
a receiver, `self: inout` is a receiver, and `self: ^mut Type` "is **not** a
receiver: it is an ordinary pointer parameter with no method-call sugar". A
reader who has learned that `^` and `^mut` are the two capabilities meets a
rule that says the mutable one is spelled with a different word in this one
position.

**Proposal.** Make `^mut T` the only mutable-borrow parameter type:

- A parameter `p: ^mut T` is passed as `&mut x`, and `p.field` reaches through
  it as it already does for any pointer. `inout x` at a call site goes.
- `self: ^mut` is a receiver, with method syntax taking `&mut` implicitly, as
  `self: ^` takes `&` today. The four receiver forms become `self`, `self: ^`,
  `self: ^mut`, `self: move`: value, the two capabilities, and consumption.
- An interface binding `(value: inout T)` becomes `(value: ^mut T)`, and the
  rule that a `self: ^` slot is met by a plain `self` method stays.
- `-> inout T` stays as the one place-returning result form, which is what
  `operator([])` needs ([`inout` results](design.md#inout-results)). It is a
  second-class place, not a value, so the keyword fits it exactly, and nothing
  else needs it.

**What is lost.** `inout x` at a call is slightly more descriptive than
`&mut x` to a reader who does not know the language; against that, `&mut` is
already what the language writes for every other exclusive borrow, and it is
what every call that passes `&mut a[:]` or `&mut counter` already looks like.
The body writes `p^ = v` where it wrote `p = v`.

**Why it matters.** The parameter-mode table loses a row, the ownership table
loses a column, grammar.md loses `Parameter_Mode`'s `inout` alternative in
every binding form, and the "mutating methods use `self: inout`" rule and its
exception disappear. The borrow checker already treats the two alike: both are
destinations under [Retaining a borrow](design.md#retaining-a-borrow).

**Why it may be a bad idea.** The second pass found costs that the paragraphs
above understate:

- **The call site stops showing every mutation.** An `inout` parameter
  requires `inout expr` at every call
  ([Parameter semantics and ABI lowering](design.md#parameter-semantics-and-abi-lowering)),
  so a reader of the caller sees which calls may change which variable, and a
  procedure that holds a `^mut T` and calls an `inout` one still writes
  `f(inout p^)`. `&mut x` is the same marker only where it is written at the
  call. A `^mut T` is a value: once `p := &mut x;` is formed, `f(p)` and
  `g(p)` change `x` with nothing at either call to say so, and a procedure that
  received `p` passes it on the same way. Today that is true only of
  parameters declared `^mut T`; the proposal makes it true of every mutable
  parameter. Seeing what a call may change from the call alone is the kind of
  local reasoning the borrow rules otherwise protect.
- **Scalars and whole values gain carets.** Field selection, indexing, and
  method calls reach through a pointer ([Pointers](design.md#pointers)), so a
  record or container parameter reads as before. A scalar or a whole-value
  write does not: `count += 1` becomes `count^ += 1`, `out = parse(text)`
  becomes `out^ = parse(text)`, and resetting a container parameter becomes
  `values^ = {}`. Counters, out-parameters, and replacements are among the
  commonest reasons to take a mutable parameter.
- **It is the largest migration in this review, for a symmetry.** Every
  `inout` parameter, argument, receiver, and interface slot in `core`, the
  tests, and the examples changes, and what it buys is a row of one table, a
  column of another, and the receiver sentence.

**A cheaper fix for the asymmetry.** If both stay, explain them where the
reader meets the difference. [Capabilities and the one
rule](design.md#capabilities-and-the-one-rule) can say that a parameter spells
the mutable capability `inout` because the body works on the caller's variable
itself and every call must say so, while `^mut T` is the mutable borrow as a
value that can be held and passed on. Then `self: inout` is simply the mutable
receiver, and `self: ^mut Type` not being one follows from that rule instead
of reading as an exception.

This review lists the fold as a judgment call and leans against it.

### 2.6 What type theory should not drive

Three things the lens suggests and this review does **not** recommend:

- **Higher-kinded or variadic generics** to spell `Callable` or a generic
  `Functor`. Loke's monomorphized `$` parameters and structural interfaces are
  the right size for a systems language.
- **Lifetime variables.** The inferred result contracts plus written escape
  levels cover what Loke promises. Written public contracts
  ([2.3](#23-effects-as-one-algebra)) are the bounded alternative.
- **Nominal conformance.** comments.md
  ["Nominal conformance declarations"](comments.md#nominal-conformance-declarations)
  is right; structural satisfaction with `static_assert` is simpler.

## 3. Orthogonality

### 3.1 Attributes in one position

Attributes appear before a declaration (`@(public) Name :: ...`) and inside a
type (`Name :: struct @(packed) { ... }`,
`Maybe :: union @(zero=none) { ... }`). The second position exists for
attributes that describe the type. But a `struct` "is written only as the value
of a constant declaration", and a nominal `union` or `enum` has no meaningful
inline use either (the inline structural forms are the parenthesized record
and union). So every type attribute is already on a declaration, one token to
the right of where the others are. Nor do the two positions separate the
name from the type cleanly today: `@(require_results)` describes the type and
is written on the declaration, so
`@(require_results) Reply :: union @(zero=none) { ... }` already splits one
type's attributes across both.

**Proposal.** Nominal `struct`, `union`, and `enum` definitions are written
only as a constant's value, and their attributes go on the declaration:
`@(public, packed) Header :: struct { ... }` and
`@(zero=none, failure=none) Option :: union($T: type) { none, some: T }`.
grammar.md loses `Attributes?` from `Struct_Type` and `Union_Type`, the
inline `[size_of(enum { A, B })]u8` corner under
[Success returns](design.md#success-returns) goes with it, and `move_only`
becomes `@(move_only)` in the same place, beside `@(thread_affine)` and
`@(wakes_on_drop)`, and grammar.md loses `Move_Only_Struct_Type`. Like those
two, `@(move_only)` applies to struct and union types; a union is move-only
today only through a move-only payload. The name stays: "move-only" is the
term the specification, its glossary, and the diagnostics use.

**What is lost.** The inline nominal `enum` and `union`. The merged list also
mixes attributes about the name (`public`, `deprecated`) with attributes about
the layout (`packed`, `align`), and it needs one new rule: a type attribute on
a declaration whose value is not a `struct`, `union`, or `enum` definition,
such as `@(packed) Alias :: Header;`, is an error.

**Cost.** The gain is two grammar productions and a reserved word; the cost
is that every use of `packed`, `align`, `zero`, `failure`, `thread_affine`,
`fieldwise_copy`, `wakes_on_drop`, and `move_only` moves. Do it only when
`lokec -fmt` can rewrite the old forms mechanically; it is token-preserving today
and has no rewrite mode. The migration then gets its own upgrade note.

### 3.2 Runtime reflection

`runtime.Type_Info` carries a `members` table whose `Member_Kind` covers
fields, enum values, union variants, and, for a procedure type, its
parameters and result, as nameless entries carrying a type. The compile-time
tier (`fields_of`, `enum_values_of`, `variants_of`) gives the first three
where code can act on them, and comments.md
["Reflection beyond fields and enum values"](comments.md#reflection-beyond-fields-and-enum-values)
leaves procedure reflection out of that tier "without a demonstrated
consumer", so the runtime table is the one place a procedure's shape is
reflected. Printing does not read `Type_Info`: the printers take
`..dyn fmt.Formattable` and call each view's `format` slot, and `assert`,
`panic`, and a failing `main` print through per-type format thunks. The
remaining consumer is a program that wants a type's name, size, or member
table at run time.

**Proposal.** Either state the table's purpose and keep it whole, or shrink
`Type_Info` to `id`, `kind`, `name`, `size`, `align`, `element`, `key`, and
`count`, delete `Member_Info` and `Member_Kind`, and say that runtime
reflection describes shape, not members. The second loses the only
reflection of a procedure type's parameter and result types, which the
rationale in comments.md says no tool has needed; a serializer that later
needs runtime member tables can build them from `fields_of` in a static
`foreach`, which is the direction the language already prefers. This review
records it as a judgment call rather than a deletion.

### 3.3 `using`

[Promoted struct fields](design.md#promoted-struct-fields) is Odin's `using`
narrowed to field lookup. It adds a contextual keyword, an ambiguity rule, and
a "not flattened" exception in destructuring, reflection, and `foreach`
bindings, for the saving of one selector (`entity.x` for
`entity.position.x`). A general-purpose language can live without it; the
composition it serves is written as plainly with the field named.
Recommended for deletion, low urgency.

### 3.4 `@(initialized=count)` and uninitialized storage

[Uninitialized capacity](design.md#uninitialized-capacity) couples a fixed
array field to a sibling `int` by attribute so that the generated copy, drop,
equality, and formatting visit a counted prefix. It is the right facility for
`Small_Array`, but it is a special case of a more general and more orthogonal
primitive: a type `Uninit(T)` (Rust's `MaybeUninit`), storage of `T`'s size
and alignment that holds no value, is trivially copyable as bytes, and is
written and read only through `unsafe.write` and `unsafe.take`. A container
then holds `items: [N]Uninit(T)` and writes its own `hook(copy)` and
`hook(drop)`, which a container author writes anyway.

**What is lost.** The generated prefix-aware copy, drop, `==`, and `format`,
which the attribute gives `Small_Array` for free, including the cleanup of a
partial copy that fails. That is one type's convenience against an attribute
every reader of a record must know; this review leans toward the primitive but
records it as a judgment call.

## 4. Syntax

### 4.1 Forms that read badly, and fixes that keep diagnostics precise

Each of these is a place where the grammar's answer is correct and a reader
still stumbles. Each fix below keeps the parser's bounded lookahead and a
precise error message. Two forms the first draft listed, the doubled
parenthesis of `for ((key in counts))` and the parentheses of
`(f() or_return).len()`, cost less than their fixes did; see
[Withdrawn proposals](#withdrawn-proposals).

| Today | Problem | Proposal |
| --- | --- | --- |
| `(&mut a[:]).indexed()` | `&mut` applied to a slice suffix is a special grammatical case, and a member of the result needs parentheses | A postfix spelling of mutable slicing, `a.slice_mut()` or `a[mut lo:hi]`, which chains like every other postfix and removes the `&mut`-before-slice rule from grammar.md |
| `Name :: struct @(packed) { }` | Attributes in a second position | [3.1](#31-attributes-in-one-position) |
| `move_only struct @(thread_affine) { }` | A keyword and an attribute for two properties of the same kind | [3.1](#31-attributes-in-one-position) |
| `(dyn Drawable)(&circle)` | Conversion of a composite type is C-cast-like | Keep. `T(v)` with a parenthesized composite type is one rule for every conversion, and the alternative (`as`) is a keyword |

### 4.2 Verbosity hotspots

- **Callable constraints.** `f: $C` plus
  `where interfaces.Callable(C, proc(n: int) -> int)` is the common way to
  take a callback, and it is long. A sugar `f: some proc(n: int) -> int`
  meaning exactly that bound would remove the most repeated `where` clause in
  generic code; `some` is the word
  [Returning a capture literal](open-questions.md#returning-a-capture-literal)
  already considers for results. This is an addition, but it replaces a longer
  idiom, so it is a net reduction in what a reader sees. Two costs come with
  it. The procedure becomes generic with no `$` in its signature, so it is
  instantiated per callable type and has no single procedure value; `some`
  must be documented as saying so. And `some` is one more contextual keyword,
  against [4.3](#43-parsing-decisions-worth-keeping).
- **`interfaces.` everywhere.** The catalogue is used by nearly every generic
  procedure and must be qualified. Either predeclare the catalogue interfaces
  (they are language-defined predicates, closer to `Option` than to `fs`) or
  let `base:` packages be imported unqualified by a project setting. The
  first is the simpler rule, and since a predeclared name may be shadowed
  ([Predeclared names](design.md#predeclared-names)), a program's own
  `Iterable` keeps working.
- **`impl X { f :: proc(self, ...) -> T { } }`.** Three tokens (`::`, `proc`,
  and the receiver) per method. This is Odin's declaration model and is
  consistent with free procedures; no change recommended, but it is where
  the language's line counts come from.

### 4.3 Parsing decisions worth keeping

Parenthesized headers, mandatory braces, and explicit semicolons are the
choices that make Loke's grammar LL(k) with no composite-literal ambiguity
and no layout rule. They cost a token or two per statement and buy precise
errors (`expected ';'` at the exact position) and a formatter that never
re-flows. Every alternative (Go's automatic semicolons, Rust's unparenthesized
conditions with the literal restriction, Swift's layout) trades that for
appearance. Keep them.

The seventeen contextual keywords are a different matter. Each has a
disambiguation rule in [Resolved ambiguities](grammar.md#resolved-ambiguities)
that every tool must follow. [3.3](#33-using) removes `using`. `static` and
`thread_local`, whose rule has four cases, would be simpler as reserved words:
no program needs a type named `static`, and a keyword may still name a field
or member ([Predeclared names](design.md#predeclared-names)).

### 4.4 Rules whose text is longer than what they save

[Success returns](design.md#success-returns) lets `return n;` build `.ok(n)`.
The rule decides by the *syntactic form* of the expression before its type,
has four bullets, a `nil` exception, and a generic-argument exclusion with its
own definition of "names a generic argument". It saves four characters per
return. comments.md ["Success returns"](comments.md#success-returns) cites
Swift and Zig, but in both the success path is plain because the type system
makes it so (throws, error unions), not by a syntactic case analysis. This
review would delete it; it is listed as a judgment call because it was adopted
recently and deliberately.

## 5. Deletion candidates

For a general-purpose language, whether a feature is used in this repository
decides nothing; what decides is whether another feature already says the same
thing. Each row names the replacement and what is lost.

| Delete | Replaced by | Lost | Priority |
| --- | --- | --- | --- |
| Type-position attributes, inline nominal `enum`/`union` | Declaration attributes ([3.1](#31-attributes-in-one-position)) | `[size_of(enum { A, B })]u8` | Medium |
| `move_only` keyword | `@(move_only)`, also on unions ([3.1](#31-attributes-in-one-position)) | A reserved word | Medium |
| Splat of a typed scalar into a `Simd` | `simd.splat(x)`; constant splats stay ([2.4](#24-coercions)) | `v * scale` for a scalar variable `scale` | Low |
| Distinct-procedure-type conversions | Alias, or explicit conversion ([2.4](#24-coercions)) | The conversion at each site passing a procedure | Low |
| `using` | Named selection ([3.3](#33-using)) | One selector per access | Low |
| `inout` parameter mode and `self: inout` | `^mut T`, `&mut x`, `self: ^mut` ([2.5](#25-one-capability-axis)) | The marker at every call that mutates; carets on scalar and whole-value writes | Judgment call; leaning against |
| Success returns | `return .ok(n);` ([4.4](#44-rules-whose-text-is-longer-than-what-they-save)) | Four characters per return | Judgment call |
| `Option.ok_or` | `or_return .Variant` and a `switch` | An eager form for stored absences | Judgment call; the open question keeps it |
| `Type_Info.members`, `Member_Info`, `Member_Kind` | `fields_of` and `variants_of` at compile time ([3.2](#32-runtime-reflection)) | Runtime reflection of a procedure type's parameter and result types | Judgment call |

Not recommended for deletion, though a simplification pass might ask:
per-variant switch cases and union argument expansion (both are defined as
expansions of existing rules and earn their place in tree-walking code);
`delegate`; `hook(convert)`; `@(cpu_dispatch)`; `errdefer`; conditional
patterns; `Simd`; `Box`; `i128`/`u128` and `f16`; the wrapping operators;
`exchange`. Each is one rule that removes a class of boilerplate or a class
of bug.

## 6. Performance of the generated code

The emitter produces one textual LLVM module for the whole program and hands
it to Clang at `-O0` through `-O3`, so cross-package inlining is free. Above
`-opt=none`, where `lld-link` sits beside Clang, the runtime is linked as
bitcode with `-flto`, so the optimizer sees it too. Within that design these
are the remaining opportunities, largest first. None changes a specified
result of a program the checker rightly accepts;
[6.1](#61-alias-attributes-from-facts-the-checker-already-proves) also needs
design.md to state what unchecked code may do during a call, and holds only
under the `abort` panic strategy.

### 6.1 Alias attributes from facts the checker already proves

The emitter writes `nonnull` on pointer parameters and nothing else
(`param_nonnull` in `src/emit_llvm_abi.odin`); the IR for a `[]int` or
`[]mut int` parameter is a two-word struct with no attribute at all
([Probes](#probes)). [Performance opportunities and actual semantic limits](open-questions.md#performance-opportunities-and-actual-semantic-limits)
lists alias attributes as open because "read-only capability alone does not
promise that memory cannot change".

The one rule promises more than that. While a borrow is live its root may not
be written through any other path, and a mutable borrow excludes every other
access. For the duration of a call, then:

- a `^mut T` or `inout T` parameter is the only live path to its pointee:
  `noalias`. The global effects enforce this for a callee that reads a global
  by name while holding a mutable borrow of it, through the
  [read effect](design.md#global-write-effects);
- a `^T` parameter's pointee is not written by anyone, unless its type reaches
  a [`@(synchronized)`](design.md#synchronized) field, as `Atomic(T)`,
  `Mutex(T)`, and `Monitor(T)` do: `noalias readonly`. `readonly` alone says
  only that the callee does not write through the pointer, which the
  capability already guarantees; `noalias` says nobody else writes during the
  call, which is what lets loads move. Rust emits the same pair for a `&T`
  whose type has no interior mutability;
- a `value: T` parameter that travels by pointer ("borrowed for the call;
  borrows of its own storage cannot escape") is a candidate for
  `noalias readonly` under the same exclusion.

**Capture is a separate property.** Neither value-parameter storage rules nor
`@(escape=none)` imply `captures(none)`. Loke's
[escape levels](design.md#escape-levels) restrict retained borrows, but a
procedure may still return whether two pointer arguments have equal addresses.
LLVM counts that observable result as
[address capture](https://llvm.org/docs/LangRef.html#address-capture), even
when no borrow survives the call ([Probes](#probes)). Emit `captures(none)`
only after proving that neither address nor provenance escapes. If the address
may escape, `captures(address)` is a candidate only after proving that
provenance cannot escape, including through unchecked operations. Otherwise
omit the capture attribute.

That proof is not worth building. Every Loke procedure is `internal` in one
module, and LLVM's own attribute inference already writes `readonly` and
`captures(none)` on internal procedures where they hold ([Probes](#probes)).
The emitter would add capture attributes only where LLVM cannot see both
sides, at `@(export)` and foreign boundaries. `noalias` on an argument is the
one fact the checker knows that LLVM cannot infer.

To attach pointer parameter attributes to slices, expose their data pointer and
length as separate scalar LLVM parameters in the `loke` convention, which is
private to the compiler. This is distinct from machine register passing, which
already handles the example slice ([6.4](#64-union-layout-and-small-values)).
The gain is the usual one for `noalias`: loads hoisted out of loops
across stores, vectorization of loops that write through one slice and read
another, and fewer reloads around calls. Expect it to be modest: the
checked-arithmetic branches of [6.3](#63-checked-arithmetic-and-bounds-in-loops)
block vectorization first, and LLVM's loop vectorizer already versions a loop
with a runtime overlap check, so on slices `noalias` mostly saves that check.
Scoped `!alias.scope` and `!noalias` metadata on the body's accesses would
express the same fact without changing the calling convention. Start with
`^mut T`, `inout`, and `self: ^mut` parameters, which are single pointers
today and need neither.

**Prerequisites.** The attributes turn a borrow the checker wrongly accepts
into undefined behavior that the optimizer exploits, so they come last:

- Close the soundness gaps first, or emit the attributes only behind an option
  until they are closed. known-gaps.md lists accepted programs that leave two
  live mutable carriers to one place
  ([A call that moves carriers between elements or fields is not seen](known-gaps.md#a-call-that-moves-carriers-between-elements-or-fields-is-not-seen),
  [A borrow stored through a mutable traversal binding is not seen in the container](known-gaps.md#a-borrow-stored-through-a-mutable-traversal-binding-is-not-seen-in-the-container)).
  Today those alias as C code would; with `noalias` at `-opt=speed` they can
  miscompile.
- State an aliasing rule for unchecked code in design.md.
  [What is not checked](design.md#what-is-not-checked) makes raw pointers the
  programmer's responsibility but says nothing about aliasing, and the
  standard library drops provenance through `rawptr` casts, as `Channel`'s
  `queue_of` does
  ([Public borrow contracts should stand on their own](open-questions.md#public-borrow-contracts-should-stand-on-their-own)).
  The rule would be that while a `^mut T` parameter is live nothing else
  accesses its pointee, and while a `^T` parameter is live nothing writes it,
  by any route; each such cast in the library is then checked against it.
- Emit them only under `-panic=abort`. With `unwind`, the runtime runs every
  frame's registered cleanup inside the panic call, without unwinding the
  native stack ([runtime/panic.c](runtime/panic.c)), so a caller's drop hooks
  and `defer`s read the caller's locals while the callee holding the
  `noalias` pointer is still executing. LLVM may then treat a store through
  the parameter before a panic as dead, and a cleanup sees the old value: in
  the probe a drop hook prints `0` where
  [Panic strategy](design.md#panic-strategy) requires `3`
  ([Probes](#probes)). For an `inout` dynamic array that the callee grows
  before panicking, the drop would free the old buffer a second time. Keeping
  the store would need every call that may panic to be treated as reading
  every `noalias` pointee, which cancels most of the gain. Since `unwind` is
  the hosted default, most programs would get the attributes only by opting
  in.
- Give the global effects a read component, so that a call passing a mutable
  borrow of a global conflicts with a callee that reads that global. This is
  done: see the [read effect](design.md#global-write-effects). Thread-affine values in globals, under
  [Later concurrency extensions](open-questions.md#later-concurrency-extensions),
  would need the same effect.
- Measure before building. After
  [6.3](#63-checked-arithmetic-and-bounds-in-loops), add the attributes by hand
  to the `bench/` kernels' IR, as the probe does, and build the emitter
  support only if the gain under `-panic=abort` justifies a second set of
  optimization semantics.

### 6.2 Container operations in IR, not through an operation table

`x.append(v)` on a `[dynamic]int` lowers to a call of
`loke_rt_v1_dyn_append` with a table of function pointers for the element's
clone and drop, and a map lookup calls `loke_rt_v1_map_find` with `key_hash`
and `key_equal` through pointers on every probe. Rust and Go both specialize
these; it is the single largest difference between Loke's collections and
theirs.

Linking the runtime as bitcode in optimized builds
([Adopted proposals](#adopted-proposals)) made `bench/collections.loke` 9%
faster, but LLVM still calls `dyn_append`, `dyn_reserve`, and `map_find` out of
line from its hot loops, and `map_find` still reaches the key's `hash` and `==`
through the operation table
([Performance opportunities and actual semantic limits](open-questions.md#performance-opportunities-and-actual-semantic-limits)).

**Proposal.** Emit the fast paths in the module, specialized per element type
as every generic procedure already is: `append` as "if `len < cap` store and
increment, else call grow"; map probing with the key's `hash` and `==` called
directly, so an `int` key hashes and compares inline. The runtime keeps growth,
rehashing, and the generic clone/drop loops, and the operation table stays for
the paths that remain in C.

**What it costs.** The probe sequence then has two implementations, one in the
emitted IR and one in the runtime's growth and rehash, which must agree
forever; a disagreement corrupts a map silently rather than crashing. At the
default `-opt=none` nothing inlines, so emit the specialized fast paths only
when optimizing, or a debug build pays their IR for every element type and
gains nothing.

### 6.3 Checked arithmetic and bounds in loops

Checked `+`, `-`, `*` lower to `llvm.*.with.overflow` plus a branch, weighted
unlikely, to a call of the `cold noreturn` panic entry. The measured cost is
in [Overflow checks in index arithmetic](open-questions.md#overflow-checks-in-index-arithmetic):
3.5 to 5.7 times on a column-major product, because the branch per element
blocks vectorization. Three steps keep the semantics and remove most of the
cost:

- **Find out why LLVM does not already remove the checks.** It folds an
  overflow intrinsic whose operands it can bound (IndVarSimplify through
  `eliminateOverflowIntrinsic`, and correlated value propagation). On the
  measured kernel the likely obstacle is the multiplication by a run-time
  extent, which no range bounds; confirm that before building an analysis.
- **Range facts for loop bindings and lengths.** A `foreach (i in 0 ..< n)`
  binding is in `[0, n)`; a slice or array length is at most
  `MAX_INT / size_of(T)`; a constant is itself. From these, `i + 1` is
  provably in range; so is `i * stride` for a constant stride when `n` is a
  length whose element size is at least the stride, and
  `row * columns + column` when `row < rows`, `column < columns`, and
  `rows * columns` was computed, checked, before the loop. The emitter can then
  write `add nsw` and a plain `getelementptr` instead of the checked forms. The
  same facts remove the bounds check on `xs[i]` inside a loop over
  `0 ..< xs.len()` only when the compiler proves the index is in bounds for
  the view used at that access. A sufficient condition is an unchanged valid
  header throughout the loop, including across calls and writes through mutable
  aliases. Slice type alone proves no such invariance: `xs = xs[:0]` can
  replace its header while the range retains its original bound, and a later
  `xs[i]` must still panic ([Probes](#probes)). Read-only elements do not make
  the slice variable constant. Track this fact for both slices and dynamic
  arrays, invalidating it when a write or call can change it.
- **Loop versioning** for the remaining affine index expressions: check once
  before the loop that the maximum index fits, and run an unchecked body when
  it does, the checked body otherwise. LLVM does this for runtime alias checks
  but not for overflow intrinsics, so it is the compiler's to do, at the cost
  of a second copy of the loop.

### 6.4 Union layout and small values

The open item on compiler-chosen union layout
([Performance opportunities and actual semantic limits](open-questions.md#performance-opportunities-and-actual-semantic-limits))
is endorsed: `Result(Option(T), E)` and a `Result(Small, Enum)` should fit
their niches, with `@(repr=...)` for a stable layout where foreign code or
serialization needs one.

The earlier claim that slices and `Option(^T)` need a new register-passing ABI
was incorrect. `LARGE_VALUE_BYTES` is 4,096 bytes, and smaller ordinary values
already travel as LLVM values. An LLVM aggregate does not imply an indirect
machine argument: the assembly probe receives a slice in `rcx` and `rdx` and
an `Option(^int)` in `rcx` alone ([Probes](#probes)). The option already uses
the null niche specified under [Representation](design.md#representation),
and so do `Result(Unit, ^T)` and `Status(^T)`, since a `Unit` payload counts as
nothing there. There is no demonstrated small-value ABI change to recommend
here. Any further change needs a measured case; exposing a slice's pointer for
attributes under
[6.1](#61-alias-attributes-from-facts-the-checker-already-proves) is a separate
reason to change its LLVM signature.

### 6.5 What not to do

Do not add a fast-math mode, relax the no-contraction rule, or make overflow
checking depend on the optimization level. The reproducibility contract
(`core:math/repro`, `core:random`, lockstep) is one of Loke's distinctive
promises, and every item above keeps it. Where a kernel wants a reassociated
reduction, a separately named operation says so, for example
`simd.reduce_add_unordered`, as the open question proposes.

## 7. The specification itself

- **Separate the normative core from analysis guarantees.** Chapter 8 and the
  appendix mix the rules a programmer needs (the one rule, places, reborrows,
  escape levels) with what an implementation must prove (minimum provenance
  precision, how carrier paths are tracked, "known destinations keep their
  lifetime constraints and region updates when an unresolved target is also
  possible"). Move the second kind into a conformance appendix with its own
  heading structure. The appendix stays normative: minimum provenance
  precision is what makes a program accepted today accepted tomorrow and by
  another implementation, and known-gaps.md holds the compiler to it.
  compiler-architecture.md is the place only for how this implementation goes
  beyond it. The programmer-facing text would be about half the length.
- **State each mechanism once.** The effect rules
  ([2.3](#23-effects-as-one-algebra)) and the "takes its element like an
  initialization" rule, which [Container insertion](design.md#container-insertion),
  `box`, `shared`, `find_or_insert`, variant construction, and record literals
  each restate, appear in several places with slightly different wording.
  [One result](design.md#one-result) and
  [Success returns](design.md#success-returns) still give `Status(E)` as the
  example of a success with no payload, though as an alias of
  `Result(Unit, E)` its success now carries `Unit`
  ([review of Unit successes](open-questions.md#review-of-unit-successes-parametric-aliases-status-and-enum-variants-2026-10-31));
  describe it with the other `Unit` successes, and keep the fallthrough rule
  distinct from the generic restriction on implicit success wrapping.
- **Keep the required-diagnostics table.** It is unusual in a language
  specification and valuable; the proposals above would shorten it rather
  than lengthen it.

## 8. Suggested order

Each step is independent of the others unless noted, and each is a spec,
compiler, test, and changelog change in one commit as AGENTS.md requires. The
steps that have landed are under [Adopted proposals](#adopted-proposals).

1. Attributes in one position and `@(move_only)`
   ([3.1](#31-attributes-in-one-position)), once `lokec -fmt` can rewrite the
   old forms. A syntax migration with its own upgrade note.
2. Range facts and loop versioning for checked arithmetic
   ([6.3](#63-checked-arithmetic-and-bounds-in-loops)), with bounds proofs that
   account for reassigned slices, aliases, and calls. Then measure the dense
   kernels again.
3. Container fast paths in IR, emitted only when optimizing
   ([6.2](#62-container-operations-in-ir-not-through-an-operation-table)).
   Measure `bench/collections.loke` with `perf.ps1` before and after.
4. Alias attributes ([6.1](#61-alias-attributes-from-facts-the-checker-already-proves)),
   in this order. First the prerequisites, which are correctness work in their
   own right: close the borrow-checker gaps 6.1 lists, add a read component to
   the global effects, and state the aliasing rule for unchecked code in
   design.md. Then, after step 2, measure by adding `noalias` by hand to the
   `bench/` kernels' IR. Only if that pays, emit `noalias` (and
   `noalias readonly` for `^T`) under `-panic=abort`, starting with `^mut T`,
   `inout`, and `self: ^mut` parameters. No capture attributes: LLVM infers
   them for internal procedures.
5. If `inout` is folded into `^mut T` at all ([2.5](#25-one-capability-axis)),
   last: it is the largest surface change, and it needs the formatter able to
   rewrite call sites and receivers mechanically. The explanation in
   [Capabilities and the one rule](design.md#capabilities-and-the-one-rule)
   can be written now either way.

## Adopted proposals

These were proposed by this review and have landed; the specification and
CHANGELOG.md describe the result. Reviews of the commits recorded their open
findings in open-questions.md and known-gaps.md
([Unit successes and aliases](open-questions.md#review-of-unit-successes-parametric-aliases-status-and-enum-variants-2026-10-31),
[unwind and bitcode](open-questions.md#review-of-unwind-bookkeeping-and-runtime-bitcode-commits-2026-10-31),
[variadic `dyn` and `any_view`](open-questions.md#review-of-variadic-dyn-views-and-any_view-removal-2026-11-01)).

- **A record with a drop hook says how it is copied**
  ([Lifecycle hooks and resource types](design.md#lifecycle-hooks-and-resource-types),
  [`@(fieldwise_copy)`](design.md#fieldwise_copy), rationale under
  ["A drop hook states its copy"](comments.md#a-drop-hook-states-its-copy)). The
  rule is written only, which goes further than the step proposed: a record that
  a move-only field already makes move-only still writes `move_only`, so a
  generic record has one answer. The step asked for a count of the opt-ins, to
  judge the attribute: of 124 records that had to decide, 111 took `move_only`
  (`3a5b4f7b`) and 13 took `@(fieldwise_copy)`, all 13 in tests that exercise
  copies of hooked values. None is in `core`, `examples`, or `bench`, so the
  attribute has no use outside the tests yet and is worth revisiting if that
  stays true.
- **Editorial fixes** found while reading, with the review (`4f7ea5b2`): the
  stale "any of a union's variants to that union" conversion, which the
  compiler rejected with `L0352`, is deleted; [`type` and
  `typeid`](design.md#type-and-typeid) says what a procedure type's member
  table holds; and [Iteration protocol](design.md#iteration-protocol) spells
  `iter` `self: ^` as the catalogue does.
- **The program-ending runtime entries are `cold noreturn`**, and the branch
  to a checked operation's panic carries weights (`9e0c7f4f`). No run-time
  change beyond noise; it states what LLVM had inferred.
- **The runtime is linked as bitcode** in optimized builds where `lld-link` is
  available (`5b6a4da6`): run time 2 to 9% lower at `-opt=speed`, executables
  5 to 30% smaller, optimized builds 6 to 12% longer. The container fast paths
  remain ([6.2](#62-container-operations-in-ir-not-through-an-operation-table)).
- **Unwind bookkeeping publishes only the locals a replay reads**
  (`c43c7e20`), so a procedure that registers nothing keeps no frame, live
  flags, or environment: `bench/dense.loke` 14% faster, within 5% of
  `-panic=abort`.
- **A `Unit` success behaves as a payloadless one** (`e4d9c207`): it may reach
  the end of a body and use `return;` when the result as written makes it
  `Unit`, it prints as `.ok`, and it leaves the null niche available
  ([One result](design.md#one-result)).
- **Parametric type aliases** (`0ae279da`,
  [Parametric aliases](design.md#parametric-aliases)).
- **`Status :: Result(Unit, $E);`** (`99057210`,
  [Typed fallibility](design.md#typed-fallibility)), so generic code over
  `Result` takes a `Status` and `Status.map_error` is `Result.map_error`. A
  type name now reads `Result(Unit, E)`.
- **`variants_of` accepts an enum** (`3b49d840`), each member a payloadless
  variant with the payload `Unit`; `enum_values_of` keeps the integer view, and
  `meta.Variant` gains no value.
- **`any_view` is deleted** (`9337076b`, `03d04d34`, `701846e9`, `b73dfa55`,
  `426f1a13`). A value converts implicitly to a `dyn I` view as an element of a
  [`..dyn I` parameter](design.md#variadic-parameters); the printers take
  `..dyn fmt.Formattable`; `assert` and `panic` print any printable value by a
  built-in rule; `@(c_vararg)` is spelled `..`; and `.(T)`, `.as(T)`, and the
  type switch are gone
  (comments.md ["No runtime type inspection"](comments.md#no-runtime-type-inspection)).

## Withdrawn proposals

The first draft made these proposals. Each had a cost it did not count that
outweighs its gain, and none is recommended.

- **Remove `via`.** Assigning to a field or element uses the policy of the
  variable it belongs to ([Assignment statements](design.md#assignment-statements)).
  Without it an unbound inner array, after `resize` or `{}`, clones into the
  default allocator, so arena-backed nested structures spill onto the heap.
  The proposed replacement, cloning into a live destination's own allocator,
  contradicts [Last-use transfer](design.md#last-use-transfer): at a last use
  `x = y` moves and brings `y`'s allocator, so `x`'s allocator would depend on
  whether `y` is read later, which is why a `via` destination is excluded from
  the transfer today.
- **Infer the iteration `Element`.** The yield-mode table reads `Item` against
  `Element` ([Yield modes](design.md#yield-modes)); for an `Item` of `^X` it
  cannot tell an owned pointer from a borrowed `X`, and any default would
  silently change what loop bindings receive.
- **Make reversal only a `reversed()` method.** A `reversed(self: ^)` method
  loses mutable reversal; a user container would write a view type and its
  iterators instead of two methods returning its own iterator; and generic code
  would lose `Reverse_Iterable`. A user's own `reversed()` already takes
  precedence over the adapter ([Iteration adapters](design.md#iteration-adapters)).
- **An `init T` parameter mode** for one `append` per user container. The
  built-in `try_` forms copy a place only on success
  ([Container insertion](design.md#container-insertion)); an `init` parameter
  clones at the call site, before the callee can fail.
- **Prune the predeclared names.** By the draft's own criterion, what the
  language's rules reach without an import, `Allocator`, `Allocator_Error`,
  `Shared`, and `Weak` stay: the `hook(copy)` signature, the `try_` forms, and
  the region and ownership rules name them. What remained, `make` as named
  constructors and `free_all` as `a.reset()`, was churn that removed no
  concept.
- **Make `string` an ordinary owner.** A copy would allocate and could fail;
  returning a borrowed `string` parameter by value, as every getter of a
  `string` field does, would allocate on each call
  ([Parameter semantics and ABI lowering](design.md#parameter-semantics-and-abi-lowering));
  and the repository's measurements give about 12.5 ns for a shared copy and
  drop against 65 to 70 ns for an allocating 16-byte copy
  ([Thread-affine strings](open-questions.md#thread-affine-strings)), so every
  copy that is not a last use gets slower. The thread-affine string that open
  question describes saves the atomic part of the cost without a semantic
  change.
- **Table-driven unwinding.** The runtime runs the registered cleanup without
  unwinding the native stack and then aborts ([runtime/panic.c](runtime/panic.c)),
  so it runs every Loke frame's cleanup even where foreign frames sit between
  them, as in a callback from C or an `@(export)` procedure called by a host.
  Table-driven unwinding would have to pass through those foreign frames: a
  C++ host's `catch (...)` could catch the panic and continue, frames without
  unwind tables would stop it, and abort pads at each foreign entry would skip
  the cleanup of the Loke frames above it, which changes a specified result.
  The bookkeeping was made cheaper instead ([Adopted proposals](#adopted-proposals)).
- **Accept `for (key in counts)` as a membership loop.** After `i := 0;`,
  `for (i in 0 ..< n)` type-checks and loops forever or not at all; a hint for
  an undeclared name does not catch it, and the rejection exists for exactly
  that mistake ([Resolved ambiguities](grammar.md#resolved-ambiguities)).
- **Parenthesize `or_return`'s failure operand**, as `f() or_return(.io)`, so
  that `f() or_return.len()` reaches the payload. Whitespace does not separate
  the two, so today's `f() or_return .io` would re-parse as member `.io` of the
  success payload, changing old code's meaning where the payload has such a
  member instead of failing; `.name` would stop being an implicit selector in
  this one position; and every failure operand would grow to shorten the rarer
  member access.
- **Delete `stdcall`.** It records which of `core`'s Win32 bindings are
  `WINAPI` ([Calling conventions](design.md#calling-conventions)). It equals
  `c` on x64, but deleting it erases what a 32-bit target would need, and
  adding it back would mean auditing every binding again.
- **Default to `-cpu=x86-64-v2`.** It is free on Windows 11 24H2, which
  requires SSE4.2 and POPCNT, but not on Windows 10, which runs on processors
  without them, such as Core 2 and Phenom II. [CPU levels](compiler-guide.md#cpu-levels)
  already recommends `x86-64` for distribution and says what `x86-64-v2`
  costs, and the startup check makes opting in safe.
- **A checked downcast on every `dyn`**, which the first draft paired with
  retiring `any_view`. A downcast lets code special-case the concrete type
  behind an interface, and a wrapper type then silently loses those special
  cases, as Go's interface upgrades do. With `any_view` deleted, no erased
  value can be inspected, and that is the point of deleting it.
- **Lowering `any_view` as a `dyn` view while keeping its rules.** It changed
  representation and dispatch but kept every source rule, so the
  specification would not have shrunk, and it was superseded by deleting
  `any_view`.
- **A drop hook implies move-only.** Adding a hook to a public type would turn
  copies in other packages into errors at their call sites, while the
  declaration's author, who knows what the hook releases, is the one who should
  decide. A record now [says in writing how it is
  copied](design.md#lifecycle-hooks-and-resource-types) instead.
- **Give every payloadless union `enum`'s integer mapping and ordering.** A
  union's tag order is representation, not API:
  [Widening by label](design.md#widening-by-label) promises no tag number
  between two types, and [6.4](#64-union-layout-and-small-values) endorses
  letting the compiler choose union layout. Giving every payloadless union
  `from_int`, ordering, and integer conversion would make its declaration order
  a public contract: reordering or inserting a variant would silently change
  what `from_int(2)` and `<` mean, and adding a payload to one variant would
  take `values()`, ordering, and `Bit_Set` away from code that used them. The
  default sizes also differ: shrinking an enum's default `int` backing to a
  union's narrowest tag would change the layout of every foreign binding that
  uses an enum directly. For the same reason `meta.Variant` gained no tag
  value when `variants_of` learned enums.
- **Capture attributes from a separate proof.** LLVM already infers
  `captures(none)` and `readonly` for internal procedures, so the proof would
  add nothing inside the program
  ([6.1](#61-alias-attributes-from-facts-the-checker-already-proves)).
- **`noalias` under the `unwind` strategy.** Cleanup runs inside the panic
  call while the callee is still executing, and the probe shows a drop hook
  reading a stale value
  ([6.1](#61-alias-attributes-from-facts-the-checker-already-proves)).

## Probes

Programs compiled to confirm claims the review still depends on. The first
three were run again on 2026-11-01 with the `lokec.exe` in the repository root,
built from the sources at `4173b622`.

**Emitted IR carries no alias attributes.** For

```loke
sum :: proc(xs: []int) -> int {
	total := 0;
	foreach (x in xs) { total += x; }
	return total;
}
```

`lokec -emit-ll` produced (abridged):

```text
declare void @loke_rt_v1_panic(ptr) cold noreturn
...
define internal i64 @loke.p.sum(%struct.anon.143 %arg0) {
  ...
foreach.body.464:
  %t469 = getelementptr inbounds i64, ptr %t461, i64 %t467
  %t470 = load i64, ptr %t469
  %t471 = load i64, ptr %total.458
  %t472 = call { i64, i1 } @llvm.sadd.with.overflow.i64(i64 %t471, i64 %t470)
  %t473 = extractvalue { i64, i1 } %t472, 1
  br i1 %t473, label %int.overflow.474, label %ok.475, !prof !{!"branch_weights", i32 1, i32 1048575}
int.overflow.474:
  call void @loke_rt_v1_panic(ptr @.msg.4)
  unreachable
```

The slice parameter is an LLVM aggregate, so no `noalias` or `readonly` can be
attached to its data pointer in this ABI. The `%uframe`, `%ulive`, and `%uenv`
allocas and the per-iteration store into `%uenv` that the 2026-10-31 probe
showed are gone, since `sum` registers no cleanup. The container runtime
boundary was read from `runtime/loke_rt.h` and
`src/emit_llvm_containers.odin`: `append`, `insert`, `pop`, `remove`,
`resize`, `clone`, `drop`, and every map operation are calls into prebuilt C
taking a `loke_rt_container_ops_v1` table.

**Comparing addresses retains no borrow.** This program prints `true false`:

```loke
package main;
import "core:fmt";

same :: proc(@(escape=none) a: ^int, @(escape=none) b: ^int) -> bool {
	return a == b;
}

main :: proc() {
	x := 1;
	y := 2;
	fmt.println(same(&x, &x), same(&x, &y));
}
```

The comparison observes addresses without retaining borrows, which LLVM counts
as address capture.

**A reassigned slice keeps the range's bound.** This program is accepted and
panics with `index out of range` and exit code 3:

```loke
package main;
import "core:fmt";

main :: proc() {
	values := [2]int{10, 20};
	xs := values[:];
	foreach (i in 0 ..< xs.len()) {
		xs = xs[:0];
		fmt.println(xs[i]);
	}
}
```

The range bound does not shrink when the slice is reassigned. The panic is
required behavior for a bounds-removal optimization to preserve.

**A box chain's generated copy recurses.** This program builds a
million-node list whose drop hook unlinks it iteratively, as
[Owned values](design.md#owned-values) prescribes, and then clones it:

```loke
package main;
import "core:fmt";

Node :: struct { value: int, next: Option(Box(Node)) }
List :: struct { head: Option(Box(Node)), count: int }

impl List {
	push_front :: proc(self: inout, value: int) {
		rest := exchange(inout self.head, .none);
		self.head = .some(box(Node{value, move(rest)}));
		self.count += 1;
	}
	release :: hook(drop) proc(self: inout) {
		rest := exchange(inout self.head, .none);
		for (true) {
			switch (move(rest)) {
			case .none: break;
			case .some(node): rest = exchange(inout node.next, .none);
			}
		}
	}
}

main :: proc() {
	list := List{};
	for (i := 0; i < 1000000; i += 1) { list.push_front(i); }
	fmt.println("built", list.count);
	copy := list.clone();
	fmt.println("cloned", copy.count);
}
```

On 2026-11-01, before the rule above landed, it exited with `0xC00000FD`, a stack
overflow, in the clone; the buffered output was lost with it. Without the last
two lines it printed `built 1000000` and exited 0, so the drop hook handled the
drop and nothing handled the copy. It is now rejected with `L0747` at `List`, and
written `move_only`, its `clone()` is rejected as a missing member.

**Small arguments travel in registers.** On 2026-10-31, Clang assembly
generated from emitted IR with `-S -O0` showed that the `sum(xs: []int)`
procedure above receives the slice's two words in `rcx` and `rdx`. A
procedure taking `Option(^int)` received its single word in `rcx`. These
observations check the small-argument ABI claim; they are not performance
measurements or a claim about every aggregate shape.

**`noalias` under the `unwind` strategy.** On 2026-11-01 the `lokec.exe` in
the repository root, at `5580637f`, emitted IR for this program with
`-emit-ll`:

```loke
package main;
import "core:fmt";

Box :: struct { n: int }

impl Box {
	release :: hook(drop) proc(self: inout Box) { fmt.println("drop sees", self.n); }
}

fill :: proc(b: ^mut Box, xs: []int) {
	foreach (x in xs) { b^.n += x; }
}

main :: proc() {
	b := Box{0};
	values := [3]int{1, 2, 9223372036854775807};
	fill(&mut b, values[:]);
}
```

The third addition overflows, so the default `unwind` strategy runs the drop
hook after two additions. The IR was linked with Clang at `-O2` with the
runtime's C sources twice, once as emitted and once with `noalias` added by
hand to `fill`'s first parameter:

```text
as emitted:     drop sees 3
with noalias:   drop sees 0
```

In the optimized IR of the second build, the `store i64 3` before the call to
`loke_rt_v1_panic` is gone. Both builds also show `readonly captures(none)`
on internal procedures that the emitter wrote without them, inferred by LLVM.

**A callee reading a global it holds `^mut` to** was accepted by the same
compiler; the [read effect](design.md#global-write-effects) now rejects it.
With `noalias` added by hand it still printed `1` and `2` at `-O2`, so the
probe shows a broken contract, not a miscompilation.

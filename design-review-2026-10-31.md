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
baselines, and ran two probe programs against the shipped `lokec.exe` (see
[Probes](#probes)). It builds on the
[language design review of 2026-10-03](open-questions.md#language-design-review-2026-10-03)
and does not repeat what that review already settled.

A second pass the same day checked each proposal against the specification,
known-gaps.md, and the runtime, looking for costs the first draft had not
counted. Proposals whose costs outweighed their gains were withdrawn; each is
listed with its reason under [Withdrawn proposals](#withdrawn-proposals), so
that it is not proposed again without an answer. Others were narrowed, and
their **What is lost** now says what the first draft missed.

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
- [Withdrawn proposals](#withdrawn-proposals)
- [Probes](#probes)

## Summary

Loke's individual decisions are well argued, and comments.md records the
argument for nearly every one. The problem is the sum. The specification is
about 12,000 lines; it has three spellings of a sum type, two type-erasure
mechanisms, two reflection tiers, two mutable-borrow modes, four inferred
effect systems, 26 attributes, and a list of about twenty implicit
conversions. Each was added for a reason, and several pairs now express one
idea twice; those pairs are where the simplifications are. Not every pair is a
duplicate, though: `via` and construction with an allocator differ in a way
that matters, and `inout` and `^mut T` may ([2.9](#29-one-capability-axis)).

The recommendations with the best ratio of concepts removed to expressiveness
lost, in rough priority order:

1. **`Status(E)` is `Result(Unit, E)`** through a parametric type alias, which
   removes a nominal type and the wart that generic code over `Result` does not
   accept a `Status` ([2.3](#23-status-is-resultunit-e)).
2. **One type kind for sums.** `enum` and `union` share one kind in the
   checker, the emitter, and reflection, and one reflection descriptor; the
   integer mapping and ordering stay `enum`'s
   ([2.1](#21-sums-one-type-kind-for-enum-and-union)).
3. **One erasure lowering.** `any_view` is represented as a `dyn` view whose
   witness carries the `typeid` and the format thunk, so printing calls the
   formatter directly; the language surface does not change
   ([2.4](#24-existentials-any_view-as-a-dyn-view)).
4. **Effects stated once**, as one algebra that the four inferred effects
   read ([2.6](#26-effects-as-one-algebra)).
5. **Attributes in one position**, with `move_only` as one of them
   ([3.1](#31-attributes-in-one-position)), and **a drop hook needs a written
   copy decision** ([2.8](#28-affine-types-a-drop-hook-needs-a-copy-decision)).
6. **Delete** `using` and, if wanted, the splat of a typed scalar into a
   `Simd`; the stale "any of a union's variants to that union" conversion is
   already gone ([5](#5-deletion-candidates)).
7. **Generated-code performance.** Mark the panic entry `cold noreturn`; inline
   the container fast paths, first by linking the runtime as bitcode; trim the
   unwind bookkeeping; prove the common index arithmetic overflow-free; and emit
   `noalias` from the facts the borrow checker proves once the gaps it depends
   on are closed ([6](#6-performance-of-the-generated-code)).

Except where a section's **What is lost** says otherwise, none of these changes
what a Loke program can express.

## 1. The shape of the language today

An inventory, counted from design.md and grammar.md, to show where the weight
is:

| Area | Count | Where it is |
| --- | --- | --- |
| Reserved words | 36 | [Keywords](grammar.md#keywords) |
| Contextual keywords, each with a disambiguation rule | 15 | [Keywords](grammar.md#keywords) |
| Attributes | 26 | [Attribute categories](design.md#attribute-categories) |
| Implicit conversions | 20 | [Implicit type conversions](design.md#implicit-type-conversions) |
| Spellings of a sum type | 3 | `enum`, `union`, `(a: A \| b: B)`; `Option`, `Result`, and `Status` are library unions |
| Spellings of a product type | 3 | `struct`, `(a: A, b: B)`, `(A, B)` |
| Type-erasure mechanisms | 2 | `any_view`, `dyn I` |
| Reflection tiers | 2 | `meta.*` descriptors, `runtime.Type_Info` |
| Mutable-borrow parameter modes | 2 | `inout T`, `^mut T` |
| Interface requirement forms | 4 | expression, validity, truth, slot |
| Overload-ranking levels and tie-breakers | 4 + 5 | [Operator lookup and overload resolution](design.md#operator-lookup-and-overload-resolution) |
| Inferred whole-program effects | 4 | write, reach, allocator-use, pooled-join TLS |
| Checks a `parallel` block's task passes | 7 | [Structured concurrency](design.md#structured-concurrency) |
| Receiver forms | 4 | `self`, `self: ^`, `self: inout`, `self: move` |
| Yield modes | 4 | [Yield modes](design.md#yield-modes) |
| Lines in design.md | 11,973 | |

Three observations follow from the table.

**The language is largest where it is most original.** Ownership (chapter 8),
structured concurrency, and the inferred effects are about a third of the
specification. That is also where Loke's value is: local borrow checking
without lifetime annotations, and tasks checked without `Send` and `Sync`.
Simplifying there means stating the mechanisms once rather than removing them
([2.6](#26-effects-as-one-algebra)).

**Some pairs say one thing twice, and some only look as if they do.**
`any_view` and `dyn`, `enum` and a union of payloadless variants, and `Status`
and `Result(Unit, E)` each describe one idea twice. Two pairs that look the
same may not be: `inout` is written at every call that mutates, which a
`^mut T` value forwarded without `&mut` is not
([2.9](#29-one-capability-axis)), and `via` gives a declaration's fields and
elements an allocator, which construction with an allocator does not
([Withdrawn proposals](#withdrawn-proposals)).

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

### 2.1 Sums: one type kind for `enum` and `union`

A sum type is one thing. Loke spells it as `enum { A, B }`, as
`union { a, b }`, and as `(a: | b:)`, and the fallible shapes build on the
second. The first two are the same type up to representation: a closed set of
named, payloadless alternatives. What `enum` adds is a chosen backing integer
(`int` by default, where a union's tag is the narrowest integer that indexes
its variants), explicit member values with holes, an ordering, integer
conversion, `from_int`, and `values()`.

**Proposal.** Unify the implementation and the reflection, not the surface:

- One type kind in the checker, the emitter, the reflection tables, and the
  formatter, with an enum as the case whose representation is written.
  `Type_Kind.Enum` stays as the name of that case.
- `variants_of(T)` serves both, with `meta.Variant` gaining the tag `value`
  that `meta.Enum_Value` has; `enum_values_of` and `meta.Enum_Value` go.
- The integer mapping stays `enum`'s alone. Ordering, integer conversion,
  `from_int`, `values()`, and `Bit_Set`/`Enum_Array` eligibility are not
  extended to unions.

**What is lost.** `enum_values_of` and `meta.Enum_Value`, which `variants_of`
replaces. The cost is a migration of `Type_Kind` consumers and of `base:meta`.

**Why the surface stays.** A union's tag order is representation, not API:
[Widening by label](design.md#widening-by-label) promises no tag number between
two types, and [6.5](#65-union-layout-and-small-values) endorses letting the
compiler choose union layout. Giving every payloadless union `from_int`,
ordering, and integer conversion would make its declaration order a public
contract: reordering or inserting a variant would silently change what
`from_int(2)` and `<` mean, and adding a payload to one variant would take
`values()`, ordering, and `Bit_Set` away from code that used them. The default
sizes also differ: shrinking an enum's default `int` backing to a union's
narrowest tag would change the layout of every foreign binding that uses an
enum directly.

### 2.2 Products: the current split is right

`struct` is nominal and generative, an anonymous record is structural, and an
unlabeled record is a structural record whose positions are its names. This is
the standard distinction, and comments.md
["Structs declare, parentheses describe"](comments.md#structs-declare-parentheses-describe)
gives the right reason to keep it: nominality is what pays for privacy, hooks,
and field reordering. No change proposed, beyond the attribute position in
[3.1](#31-attributes-in-one-position).

### 2.3 `Status` is `Result(Unit, E)`

[`Status(E)`](design.md#typed-fallibility) is a separate nominal union that is
isomorphic to `Result(Unit, E)`, and the specification pays for the duplicate
in several places: a generic procedure over `Result($T, $E)` does not accept a
`Status` ([Error handling (2026-10-13)](open-questions.md#error-handling-2026-10-13)),
`map_error` is written twice, the end-of-body rule under
[One result](design.md#one-result) covers `Status` but must exclude
`Result(Unit, E)`, and `or_return` "crosses between" them by a special
sentence. comments.md ["`Status(E)`"](comments.md#statuse) says why: a type
alias takes no parameters.

**Proposal.** Add parametric type aliases, `Status :: Result(Unit, $E);`. An
alias adds no identity, so `Status(E)` *is* `Result(Unit, E)`, `map_error` is
one procedure, and generic code over `Result` takes a `Status`.
[Parametric aliases](open-questions.md#parametric-aliases) says such an alias
would not merge the two because their end-of-body rules differ; this proposal
removes the difference. The rule becomes: a procedure whose written result,
after alias expansion, has a success variant that carries nothing or carries
`Unit`, and that names no generic argument, may reach its end. That is the
exclusion [Success returns](design.md#success-returns) already uses, so a
generic `Result($T, E)` body still does not change meaning with its instance,
and the rule is stated once.

**What is lost.** Nothing a program can write. `return .ok;` stays valid; it is
already how a `Result(Unit, E)` returns. A non-generic procedure written
`-> Result(Unit, E)` may now reach its end, as a `Status(E)` one may.
Diagnostics should keep the alias a type was written with, or every `Status(E)`
in an error message reads `Result(Unit, E)`.

Parametric aliases are a type-level function with no new identity, and they
would also answer the `io.Result(T)` wish in the same open question. They are
still a generics feature with its own design: inference through an alias, its
`api.loki` form, and whether an alias may be named without its arguments each
need a rule.

### 2.4 Existentials: `any_view` as a `dyn` view

A `dyn I` is an existential package: a data pointer and evidence about the
hidden type (a witness). An [`any_view`](design.md#any_view-type) is the same
shape with different evidence: a data pointer and a `typeid`. Both are two
words, both borrow, and both have no zero value. Printing builds a
`[]any_view`, then recovers each element's `Formattable` witness from its
`typeid` through a table, which is the indirection a witness pointer would
carry directly.

**Proposal.** One lowering, with the surface unchanged:

- `any_view` is represented as a `dyn` view of a built-in interface whose
  witness starts with the concrete type's `typeid` and holds its format thunk.
  Printing calls the thunk directly; the type `switch`, `.(T)`, and `.as(T)`
  compare the `typeid`.
- design.md states `any_view`'s lifetime rules as those of a `dyn` view, plus
  its two differences: conversion to it is implicit at an `any_view`
  destination, and a `..any_view` parameter may form a temporary slice.

**What is lost.** Nothing a program can write. The cost is a witness table per
erased type, which the format-thunk table already is, with a word for the
`typeid`.

**What is not proposed.** The first draft also retired `any_view` in favor of
`..dyn fmt.Formattable` and gave every `dyn` view a checked downcast. Three
costs decide against it:

- A `dyn` conversion is explicit and starts from a pointer
  ([Borrowed dynamic interface values](design.md#borrowed-dynamic-interface-values)).
  `fmt.println(x, 42)` would need an implicit conversion from a value to `dyn`,
  a new entry in the list [2.7](#27-coercions) wants shorter, or an exception
  for variadic parameters, which is the exception the change was to remove.
- `assert` and `panic` are built-ins. Typed with `fmt.Formattable`, they would
  make the language core depend on `core:fmt`.
- A downcast on every `dyn` lets code special-case the concrete type behind an
  interface, and a wrapper type then silently loses those special cases, as
  Go's interface upgrades do. Today a `dyn I` holder can only call slots, and
  design.md sends checked inspection to `any_view`.

### 2.5 Procedures are callable records

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

### 2.6 Effects as one algebra

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
one place to improve instead of four.

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

### 2.7 Coercions

[Implicit type conversions](design.md#implicit-type-conversions) lists twenty
rules. Each is a subtyping or coercion rule that feeds the four-level overload
ranking. Most are sound and useful (owner to view, `mut` to read-only, `dyn`
to a composed base, unfixed constants). Three deserved attention:

- **"Any of a union's variants to that union"** contradicted
  [Unions](design.md#unions), which identifies a variant by name and allows two
  variants of one payload type. The shipped compiler rejects
  `v: Value = 7;` with `L0352` ([Probes](#probes)), so the line was a leftover
  from Odin's type-based unions. It is deleted from design.md with this review.
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

### 2.8 Affine types: a drop hook needs a copy decision

A `move_only struct` is an affine type. The keyword is needed because a type
with `hook(drop)` and no `hook(copy)` still receives a *generated* field-wise
copy, which for a file handle stored as an `int` duplicates the handle and
double-closes it.

Rust's rule, that a type with a destructor is not `Copy`, does not carry over.
Rust's `Copy` is an implicit bitwise copy, and a type with a destructor may
still derive a field-wise `Clone`, which is what Loke's generated copy is. The
field-wise copy is right for a record whose fields own what its drop hook
touches, such as a chain of `Box` fields with a drop hook that unlinks it
iteratively, as [Owned values](design.md#owned-values) recommends. It is wrong
for one whose drop hook releases something its fields only name.

**Proposal.** Make the copy a written decision rather than a default either
way:

- A record that declares `hook(drop)` without `hook(copy)`, and is not
  move-only, is rejected at its declaration unless it asks for the generated
  field-wise copy with an attribute (spelling to be designed, for example
  `@(fieldwise_copy)`).
- `move_only` becomes an ordinary type attribute, `@(move_only)`, beside
  `@(thread_affine)` and `@(wakes_on_drop)`, rather than a keyword with its own
  grammar production ([3.1](#31-attributes-in-one-position)).

**What is lost.** A record that relies on the generated copy beside its drop
hook writes the attribute. In exchange no drop hook receives a copy nobody
chose, and adding a drop hook never silently changes whether a type is
copyable. The first draft's rule, that a drop hook implies move-only, would
have made the iterative-unlink fix a breaking change, undone only by a
hand-written `hook(copy)` that a field added later would silently skip.

### 2.9 One capability axis

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

### 2.10 What type theory should not drive

Three things the lens suggests and this review does **not** recommend:

- **Higher-kinded or variadic generics** to spell `Callable` or a generic
  `Functor`. Loke's monomorphized `$` parameters and structural interfaces are
  the right size for a systems language.
- **Lifetime variables.** The inferred result contracts plus written escape
  levels cover what Loke promises. Written public contracts
  ([2.6](#26-effects-as-one-algebra)) are the bounded alternative.
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
the right of where the others are.

**Proposal.** Nominal `struct`, `union`, and `enum` definitions are written
only as a constant's value, and their attributes go on the declaration:
`@(public, packed) Header :: struct { ... }` and
`@(zero=none, failure=none) Option :: union($T: type) { none, some: T }`.
grammar.md loses `Attributes?` from `Struct_Type` and `Union_Type`, the
inline `[size_of(enum { A, B })]u8` corner under
[Success returns](design.md#success-returns) goes with it, and `move_only`
becomes an attribute in the same place
([2.8](#28-affine-types-a-drop-hook-needs-a-copy-decision)).

**What is lost.** The inline nominal `enum` and `union`. The merged list also
mixes attributes about the name (`public`, `deprecated`) with attributes about
the layout (`packed`, `align`), which the two positions now keep apart, and it
needs one new rule: a type attribute on a declaration whose value is not a
`struct`, `union`, or `enum` definition, such as `@(packed) Alias :: Header;`,
is an error.

### 3.2 Runtime reflection

`runtime.Type_Info` carries a `members` table whose `Member_Kind` covers
fields, enum values, union variants, and, for a procedure type, its
parameters and result, as nameless entries carrying a type. The compile-time
tier (`fields_of`, `enum_values_of`, `variants_of`) gives the first three
where code can act on them, and comments.md
["Reflection beyond fields and enum values"](comments.md#reflection-beyond-fields-and-enum-values)
leaves procedure reflection out of that tier "without a demonstrated
consumer", so the runtime table is the one place a procedure's shape is
reflected. Printing does not read `Type_Info`: it dispatches through
generated format thunks ([2.4](#24-existentials-any_view-as-a-dyn-view)), so
the remaining consumer is a program that wants a type's name, size, or member
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
which the attribute gives `Small_Array` for free. That is one type's
convenience against an attribute every reader of a record must know; this
review leans toward the primitive but records it as a judgment call.

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
| `move_only struct @(thread_affine) { }` | A keyword and an attribute for two properties of the same kind | [2.8](#28-affine-types-a-drop-hook-needs-a-copy-decision) |
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

The fifteen contextual keywords are a different matter. Each has a
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
| `Status` as a nominal type, `Status.map_error` | `Status :: Result(Unit, $E)` ([2.3](#23-status-is-resultunit-e)) | Nothing; a non-generic `Result(Unit, E)` gains the end-of-body rule | High |
| `enum_values_of`, `meta.Enum_Value`, a separate enum kind | `variants_of`, `meta.Variant` with `value`, one sum kind ([2.1](#21-sums-one-type-kind-for-enum-and-union)) | Nothing | Medium |
| Type-position attributes, inline nominal `enum`/`union` | Declaration attributes ([3.1](#31-attributes-in-one-position)) | `[size_of(enum { A, B })]u8` | Medium |
| `move_only` keyword | `@(move_only)` ([2.8](#28-affine-types-a-drop-hook-needs-a-copy-decision)) | A reserved word | Medium |
| "Any of a union's variants to that union" | Nothing; the compiler already rejects it | Nothing | Done with this review |
| Splat of a typed scalar into a `Simd` | `simd.splat(x)`; constant splats stay ([2.7](#27-coercions)) | `v * scale` for a scalar variable `scale` | Low |
| Distinct-procedure-type conversions | Alias, or explicit conversion ([2.7](#27-coercions)) | The conversion at each site passing a procedure | Low |
| `using` | Named selection ([3.3](#33-using)) | One selector per access | Low |
| `inout` parameter mode and `self: inout` | `^mut T`, `&mut x`, `self: ^mut` ([2.9](#29-one-capability-axis)) | The marker at every call that mutates; carets on scalar and whole-value writes | Judgment call; leaning against |
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
it to Clang at `-O0` through `-O3`, so cross-package inlining is free and the
optimizer sees everything but the runtime. Within that design these are the
opportunities, largest first. None changes a specified result of a program the
checker rightly accepts; [6.1](#61-alias-attributes-from-facts-the-checker-already-proves)
also needs design.md to state what unchecked code may do during a call.

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
  `noalias`;
- a `^T` parameter's pointee is not written by anyone, unless its type reaches
  a [`@(synchronized)`](design.md#synchronized) field, as `Atomic(T)`,
  `Mutex(T)`, and `Monitor(T)` do: `noalias readonly`. `readonly` alone says
  only that the callee does not write through the pointer, which the
  capability already guarantees; `noalias` says nobody else writes during the
  call, which is what lets loads move. Rust emits the same pair for a `&T`
  whose type has no interior mutability;
- a `value: T` parameter that travels by pointer ("borrowed for the call;
  borrows of its own storage cannot escape") is `noalias readonly` and
  `captures(none)` under the same exclusion;
- a `@(escape=none)` parameter is `captures(none)` whatever its mode.

This is exactly the argument Rust makes for `&mut` and `&`. Slices and views
need one ABI change to carry attributes: pass the data pointer and length as
separate scalar parameters in the `loke` convention, which is private to the
compiler. The gain is the usual one for `noalias`: loads hoisted out of loops
across stores, vectorization of loops that write through one slice and read
another, and fewer reloads around calls.

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
- Measure with and without unwind frames. Where a frame is pushed, the
  addresses stored in `%uenv` reach the runtime, which limits what LLVM may
  assume about those locals and may cancel some of the gain
  ([6.3](#63-unwind-bookkeeping)).

### 6.2 Container operations in IR, not through an operation table

`x.append(v)` on a `[dynamic]int` lowers to
`call i32 @loke_rt_v1_dyn_append(ptr self, ptr ops, ptr elem, i64 1)`, a call
into prebuilt C with a table of function pointers for the element's clone and
drop, and a map lookup calls `loke_rt_v1_map_find` with `key_hash` and
`key_equal` through pointers on every probe. Nothing inlines across that
boundary, so the most common container operations in the language cost a
call, an indirect call or two, and a table load each, whatever the element.
Rust and Go both specialize these; it is the single largest difference between
Loke's collections and theirs.

**Proposal, in two steps.**

1. Compile the runtime to bitcode and link it with `-flto` from the same
   cache, so that the container operations, `string_retain`, `alloc`, and the
   dispatch helpers inline where they are hot. The fast paths stay in one
   implementation, and the cache key already covers the flags this needs.
2. If that leaves the indirect calls through the operation table on the hot
   path, emit the fast paths in the module, specialized per element type as
   every generic procedure already is: `append` as "if `len < cap` store and
   increment, else call grow"; map probing with the key's `hash` and `==`
   called directly, so an `int` key hashes and compares inline. The runtime
   keeps growth, rehashing, and the generic clone/drop loops, and the ops
   table stays for the paths that remain in C.

**What the second step costs.** The probe sequence then has two
implementations, one in the emitted IR and one in the runtime's growth and
rehash, which must agree forever; a disagreement corrupts a map silently
rather than crashing. At the default `-opt=none` nothing inlines, so emit the
specialized fast paths only when optimizing, or a debug build pays their IR
for every element type and gains nothing.

### 6.3 Unwind bookkeeping

Under the `unwind` strategy the emitter maintains a frame list:
`loke_rt_v1_frame_push`/`pop` around procedures with cleanup, a live-flag
array, and an environment table of local addresses that the generated thunk
replays ([Probes](#probes) show the `%uframe`, `%ulive`, and `%uenv` allocas
and a store into `%uenv` on every loop iteration, left for LLVM to delete when
the frame is never pushed). Where a frame is pushed, every call to the
procedure pays the push, the pop, and the stores that keep the table current.

The design is deliberate. The runtime runs the registered cleanup without
unwinding the native stack and then aborts
([runtime/panic.c](runtime/panic.c)), so it runs every Loke frame's cleanup
even where foreign frames sit between them, as in a callback from C or an
`@(export)` procedure called by a host. Table-driven unwinding, which the first
draft proposed, would have to pass through those foreign frames: a C++ host's
`catch (...)` could catch the panic and continue, frames without unwind tables
would stop it, and abort pads at each foreign entry would skip the cleanup of
the Loke frames above it, which changes a specified result.

**Proposal.** Keep the logical unwind and make its bookkeeping cheaper.
Measure first: `-panic=abort` pushes no frames and shows the upper bound of the
saving. Then start from the probe: `sum` stores a loop binding's address into
`%uenv` on every iteration, though a borrowed `int` has nothing to drop.
Record only the addresses a registered cleanup reads.

### 6.4 Checked arithmetic and bounds in loops

Checked `+`, `-`, `*` lower to `llvm.*.with.overflow` plus a branch to a
panic block, and the panic callee is declared without `cold` or `noreturn`
(the `unreachable` that follows the call lets LLVM infer the latter). The
measured cost is in
[Overflow checks in index arithmetic](open-questions.md#overflow-checks-in-index-arithmetic):
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
  `0 ..< xs.len()` when the body cannot change `xs`'s length, which holds for
  a slice and not for a `[dynamic]T` the body appends to.
- **Loop versioning** for the remaining affine index expressions: check once
  before the loop that the maximum index fits, and run an unchecked body when
  it does, the checked body otherwise. LLVM does this for runtime alias checks
  but not for overflow intrinsics, so it is the compiler's to do, at the cost
  of a second copy of the loop.

Mark `loke_rt_v1_panic` `cold noreturn` and give the panic branch weights.
It is cheap and makes the block layout and inlining decisions explicit
rather than inferred.

### 6.5 Union layout and small values

The open item on compiler-chosen union layout
([Performance opportunities and actual semantic limits](open-questions.md#performance-opportunities-and-actual-semantic-limits))
is endorsed: `Result(Option(T), E)` and a `Result(Small, Enum)` should fit
their niches, with `@(repr=...)` for a stable layout where foreign code or
serialization needs one. Independently, the `loke` convention could pass a
two-word record such as a slice or an `Option(^T)` in registers rather than
as an LLVM aggregate, which the current `LARGE_VALUE_BYTES` rule handles
only by address.

### 6.6 What not to do

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
  another implementation, and known-gaps.md holds the compiler to it
  ([Reaching-definition limits weaken the per-storage chosen-place guarantee](known-gaps.md#reaching-definition-limits-weaken-the-per-storage-chosen-place-guarantee)).
  compiler-architecture.md is the place only for how this implementation goes
  beyond it. The programmer-facing text would be about half the length.
- **State each mechanism once.** The effect rules
  ([2.6](#26-effects-as-one-algebra)), the "takes its element like an
  initialization" rule, which [Container insertion](design.md#container-insertion),
  `box`, `shared`, `find_or_insert`, variant construction, and record literals
  each restate, and the generic-argument exclusion
  ([2.3](#23-status-is-resultunit-e)) each appear in several places with
  slightly different wording.
- **Editorial defects found while reading**, fixed in design.md in the same
  change as this review:
  - [Implicit type conversions](design.md#implicit-type-conversions) listed
    "any of a union's variants to that union", which was never implemented
    and contradicts [Unions](design.md#unions); the compiler reports `L0352`.
    The line is deleted.
  - [`type` and `typeid`](design.md#type-and-typeid) never said what a
    procedure type's member table holds, though `Member_Kind` names
    `Parameter` and `Result` and the compiler fills them. A sentence now
    does.
  - [Standard interface catalogue](design.md#standard-interface-catalogue)
    spells `Iterable`'s `iter` slot `self: ^` while
    [Iteration protocol](design.md#iteration-protocol) wrote `iter(self)`.
    The protocol now shows `self: ^` and says a plain `self` also meets it.
- **Keep the required-diagnostics table.** It is unusual in a language
  specification and valuable; the proposals above would shorten it rather
  than lengthen it.

## 8. Suggested order

Each step is independent of the others unless noted, and each is a spec,
compiler, test, and changelog change in one commit as AGENTS.md requires.

1. Editorial: delete the stale conversion, document procedure members, align
   the `iter` signatures. Done with this review; no behavior changes.
2. Performance that needs no language change: `cold noreturn` on the panic
   entry, the runtime linked as bitcode
   ([6.2](#62-container-operations-in-ir-not-through-an-operation-table)), and
   a leaner unwind bookkeeping ([6.3](#63-unwind-bookkeeping)). Measure each
   with `perf.ps1` and the `bench/` workloads before and after.
3. Parametric aliases with `Status` as the first user, and one type kind for
   `enum` and `union`. Both are mostly internal and shrink reflection and the
   error catalogue.
4. `any_view` lowered as a `dyn` view. Depends on nothing above; touches the
   witness layout and the printing path.
5. Attributes in one position, `@(move_only)`, and the copy decision for drop
   hooks.
6. Range facts and loop versioning for checked arithmetic
   ([6.4](#64-checked-arithmetic-and-bounds-in-loops)), then measure the
   dense kernels again; container fast paths in IR if step 2 left them hot.
7. Alias attributes ([6.1](#61-alias-attributes-from-facts-the-checker-already-proves)),
   after the soundness gaps they depend on are closed and design.md states the
   aliasing rule for unchecked code.
8. If `inout` is folded into `^mut T` at all ([2.9](#29-one-capability-axis)),
   last: it is the largest surface change, and it needs the formatter able to
   rewrite call sites and receivers mechanically. The explanation in
   [Capabilities and the one rule](design.md#capabilities-and-the-one-rule)
   can be written now either way.

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
- **Table-driven unwinding**, for the reasons in
  [6.3](#63-unwind-bookkeeping).
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
- **Retire `any_view` for `..dyn fmt.Formattable` with a downcast on every
  `dyn`**, for the reasons in [2.4](#24-existentials-any_view-as-a-dyn-view).
- **A drop hook implies move-only**, for the reasons in
  [2.8](#28-affine-types-a-drop-hook-needs-a-copy-decision).
- **Give every payloadless union `enum`'s integer mapping and ordering**, for
  the reasons in [2.1](#21-sums-one-type-kind-for-enum-and-union).

## Probes

Two programs were compiled with the `lokec.exe` in the repository root on
2026-10-31 to confirm claims the review depends on.

**A payload does not convert implicitly to its union.**

```loke
package main;
import "core:fmt";
Value :: union { number: int, text: string }
main :: proc() {
	v: Value = 7;
	fmt.println(v);
}
```

```text
error[L0352]: 7 is not representable by `Value`
```

**Emitted IR carries no alias attributes, and unwind bookkeeping is
materialized per procedure.** For

```loke
sum :: proc(xs: []int) -> int {
	total := 0;
	foreach (x in xs) { total += x; }
	return total;
}
```

`lokec -emit-ll` produced (abridged):

```text
define internal i64 @loke.p.sum(%struct.anon.146 %arg0) {
entry:
  %uframe.521 = alloca { ptr, ptr, ptr }
  %ulive.521 = alloca [1 x i1]
  %uenv.521 = alloca [3 x ptr]
  ...
foreach.body.532:
  %t537 = getelementptr inbounds i64, ptr %t529, i64 %t535
  %t538 = getelementptr ptr, ptr %uenv.521, i64 2
  store ptr %t537, ptr %t538
  %t539 = load i64, ptr %t537
  %t541 = call { i64, i1 } @llvm.sadd.with.overflow.i64(i64 %t540, i64 %t539)
  br i1 %t542, label %int.overflow.543, label %ok.544
int.overflow.543:
  call void @loke_rt_v1_panic(ptr @.msg.4)
  unreachable
```

with `declare void @loke_rt_v1_panic(ptr)` carrying no attributes. The slice
parameter is an LLVM aggregate, so no `noalias` or `readonly` can be attached
to its data pointer in this ABI. The container runtime boundary was read from
`runtime/loke_rt.h` and `src/emit_llvm_containers.odin`: `append`, `insert`,
`pop`, `remove`, `resize`, `clone`, `drop`, and every map operation are calls
into prebuilt C taking a `loke_rt_container_ops_v1` table.

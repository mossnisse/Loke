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
- [Probes](#probes)

## Summary

Loke's individual decisions are well argued, and comments.md records the
argument for nearly every one. The problem is the sum. The specification is
about 12,000 lines; it has four spellings of a sum type, two type-erasure
mechanisms, two reflection tiers, two mutable-borrow modes, four inferred
effect systems, 26 attributes, and a list of about twenty implicit
conversions. Each was added for a reason, but several pairs now express one
idea twice, and the pairs are where the simplifications are.

The recommendations with the best ratio of concepts removed to expressiveness
lost, in rough priority order:

1. **One mutable-borrow mode.** Fold `inout` into `^mut T`: `&mut x` at the
   call, `self: ^mut` as a receiver, and keep `inout` only as the marker of a
   place-returning result. This fixes the asymmetry that `self: ^` is a
   receiver and `self: ^mut` is not ([2.4](#24-one-capability-axis)).
2. **One erasure mechanism.** Make `any_view` a `dyn` view (`dyn Any`), give
   every `dyn` view a checked downcast, and print through
   `..dyn fmt.Formattable` ([2.5](#25-existentials-any_view-is-a-dyn-view)).
3. **Enums are unions.** Define `enum` as a union whose variants are all
   payloadless and whose representation is chosen, and merge the two
   reflection descriptors and the two iteration spellings
   ([2.1](#21-sums-enum-is-a-union)).
4. **`Status(E)` is `Result(Unit, E)`** through a parametric type alias, which
   removes a nominal type and the wart that generic code over `Result` does not
   accept a `Status` ([2.3](#23-status-is-resultunit-e)).
5. **One allocator mechanism.** Remove `via` and the "declaration allocation
   policy"; an allocator is a property of the value, chosen at construction
   ([3.2](#32-allocators-via-make-and-init)).
6. **Attributes in one position.** Nominal types are declared only as a
   constant's value, so `@(packed)`, `@(align)`, `@(zero=)`, `@(failure=)`,
   `@(thread_affine)`, and `@(wakes_on_drop)` can sit on the declaration with
   every other attribute, and `move_only` can be one of them
   ([3.1](#31-attributes-in-one-position)).
7. **One reversal spelling** and a smaller iteration protocol
   ([3.3](#33-the-iteration-protocol)).
8. **Delete** the scalar-to-`Simd` splat conversion, `stdcall`, `using`, the
   `for ((x in y))` escape hatch, and the stale "any of a union's variants to
   that union" conversion ([5](#5-deletion-candidates)).
9. **Generated-code performance.** Emit `noalias`, `readonly`, and
   `captures(none)` from the facts the borrow checker already proves;
   monomorphize the container fast paths in IR instead of calling the C runtime
   with an operation table; move unwinding off the runtime frame list; and
   prove the common index arithmetic overflow-free
   ([6](#6-performance-of-the-generated-code)).

None of these changes what a Loke program can express. Together they would
remove about a dozen concepts from design.md and a comparable number of parser
and checker rules.

## 1. The shape of the language today

An inventory, counted from design.md and grammar.md, to show where the weight
is:

| Area | Count | Where it is |
| --- | --- | --- |
| Reserved words | 36 | [Keywords](grammar.md#keywords) |
| Contextual keywords, each with a disambiguation rule | 15 | [Keywords](grammar.md#keywords) |
| Attributes | 26 | [Attribute categories](design.md#attribute-categories) |
| Implicit conversions | 20 | [Implicit type conversions](design.md#implicit-type-conversions) |
| Spellings of a sum type | 4 | `enum`, `union`, `(a: A \| b: B)`, `Option`/`Result`/`Status` |
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
([2.7](#27-effects-as-one-algebra)).

**The duplicated concepts are mostly historical.** `inout` predates `^mut T`
as a first-class checked borrow; `any_view` predates `dyn`; `enum` predates
payloadless union variants; `Status` predates success returns; `via` predates
`make` with an allocator argument. Each pair's second member made the first
one mostly redundant without retiring it.

**The spec carries implementation detail.** The minimum provenance precision
budgets, the normalized-input discussion, and several paragraphs under
[Allocator regions and region provenance](design.md#allocator-regions-and-region-provenance)
describe how a conforming analysis must behave in terms only an implementer
reads. They belong in a conformance appendix or in compiler-architecture.md
([7](#7-the-specification-itself)).

## 2. Type theory as a simplifying lens

Type theory is useful here not as a source of new features but as a way of
noticing when two constructs denote the same thing. Loke's type system is, in
these terms: sums and products (nominal and structural), a two-point
capability lattice on borrows (read, mutable), affine types (move-only),
existential packages (`dyn`), region-based memory (allocator provenance), and
an inferred effect system. Each is sound and conventional. The simplifications
come from the places where one of those denotations has two spellings.

### 2.1 Sums: `enum` is a union

A sum type is one thing. Loke spells it as `enum { A, B }`, as
`union { a, b }`, as `(a: | b:)`, and the fallible shapes build on the second.
The first two are the same type up to representation: a closed set of named,
payloadless alternatives. What `enum` adds is a chosen backing integer, explicit
member values with holes, an ordering, `from_int`, and `values()`.

**Proposal.** Keep the `enum` keyword as the readable spelling of a
payloadless union with a chosen representation, and define it as one:

- `enum u8 { Ok = 200, Teapot = 418 }` is a union of payloadless variants whose
  tag is a `u8` with the written values. A union without written values keeps
  the narrowest tag indexing `0 ..< variant_count`, as today.
- `variants_of(T)` serves both, with `meta.Variant` gaining the tag `value`
  that `meta.Enum_Value` has; `enum_values_of` and `meta.Enum_Value` go.
- `values()` and `from_int` are defined for any union whose variants are all
  payloadless, so `union { a, b }` and `enum { a, b }` differ only in whether
  a representation was written.
- `Type_Kind.Enum` becomes a flag on `Union`, or stays as a name for the
  payloadless case; either way one shape rule.
- Ordering stays a property of a union whose variants are all payloadless and
  whose tag values are its order, which is what enum ordering means today.

**What is lost.** Nothing a program can write. A payloadless-variant union
gains `values()` and `from_int`, which it should have anyway. The cost is a
migration of `Type_Kind` consumers and of `base:meta`.

**Why it matters.** Two type kinds become one in the checker, the emitter, the
reflection tables, the formatter, and `Bit_Set`/`Enum_Array`, whose
constraints become "a payloadless union" rather than "an enum".

### 2.2 Products: the current split is right

`struct` is nominal and generative, an anonymous record is structural, and an
unlabeled record is a structural record whose positions are its names. This is
the standard distinction, and comments.md
["Structs declare, parentheses describe"](comments.md#structs-declare-parentheses-describe)
gives the right reason to keep it: nominality is what pays for privacy, hooks,
and field reordering. No change proposed, beyond the attribute position in
[3.1](#31-attributes-in-one-position).

One small irregularity: a fixed array `[N]T` is "a record containing one field
per element" for layout, is comparable element-wise, and hashable, but is not a
`Sequence` of its own until converted to a slice. That is fine.

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

**Proposal.** Add parametric type aliases, `Status :: Result(Unit, $E);`, as
[Parametric aliases](open-questions.md#parametric-aliases) already sketches. An
alias adds no identity, so `Status(E)` *is* `Result(Unit, E)`, `map_error` is
one procedure, and generic code over `Result` takes a `Status`. The
end-of-body rule becomes: a procedure whose written result, after alias
expansion, has success payload `Unit` and names no generic argument may reach
its end. That is the same exclusion [Success returns](design.md#success-returns)
already uses, so the rule is stated once.

**What is lost.** The spelling `return .ok;` stays valid. The one visible
change is that `Result(Unit, E)` and `Status(E)` print the same way, which is
correct.

Parametric aliases are a small, well-understood feature (a type-level function
with no new identity), and they would also answer the `io.Result(T)` wish in
the same open question.

### 2.4 One capability axis

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
  else needs it. (If the keyword should go entirely, the alternative is
  "`operator([])` returning `^mut T` is dereferenced in place position", which
  is a narrower special case.)

**What is lost.** `inout x` at a call is slightly more descriptive than
`&mut x` to a reader who does not know the language; against that, `&mut` is
already what the language writes for every other exclusive borrow, and it is
what every call that passes `&mut a[:]` or `&mut counter` already looks like.
The body writes `p^ = v` where it wrote `p = v`, which the implicit
field-selection rule removes for the common record case.

**Why it matters.** The parameter-mode table loses a row, the ownership table
loses a column, grammar.md loses `Parameter_Mode`'s `inout` alternative in
every binding form, and the "mutating methods use `self: inout`" rule and its
exception disappear. The borrow checker already treats the two identically
(both are destinations under [Retaining a borrow](design.md#retaining-a-borrow)).

### 2.5 Existentials: `any_view` is a `dyn` view

A `dyn I` is an existential package: a data pointer and evidence about the
hidden type (a witness). An [`any_view`](design.md#any_view-type) is the same
shape with different evidence: a data pointer and a `typeid`. Both are two
words, both borrow, both have no zero value, and each has rules the other lacks
for no deep reason. `any_view` alone has the "variadic `..any_view` parameter
is the only exception to the container rule", the `switch` over types, and the
checked extractions `.(T)` and `.as(T)`; `dyn` alone has witnesses and slot
calls. Printing builds a `[]any_view`, then recovers each element's
`Formattable` witness from its `typeid` through a table, which is the
indirection a `dyn fmt.Formattable` would carry directly.

**Proposal.** One erasure mechanism:

- Every witness table starts with the concrete type's `typeid`. A `dyn I` view
  then supports `view.as(T) -> Option(^T)`, `view.(T)`, and the type `switch`,
  exactly as `any_view` does today, for any interface.
- `any_view` becomes `dyn Any`, where `Any` is the empty interface every type
  satisfies, or is simply retired in favor of `dyn fmt.Formattable` where
  printing is the purpose, which it nearly always is.
- `fmt.println`, `assert`, and `panic` take `..dyn fmt.Formattable`. The
  "variadic exception" is then unnecessary: a `[]dyn I` is an ordinary slice of
  views, allowed wherever a slice of borrows is.
- `@(c_vararg)` keeps its own notation; it was already "signature notation,
  not an `any_view`".

**What is lost.** A type that satisfies no interface can still be erased
(`Any` is empty), so nothing. The cost is a word in every witness table.

**Why it matters.** One language type, one chapter, one set of lifetime rules,
and one lowering go; [3.6](#36-runtime-reflection) asks what then remains for
`Type_Info`.

### 2.6 Procedures are callable records

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

### 2.7 Effects as one algebra

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

### 2.8 Coercions

[Implicit type conversions](design.md#implicit-type-conversions) lists twenty
rules. Each is a subtyping or coercion rule that feeds the four-level overload
ranking. Most are sound and useful (owner to view, `mut` to read-only, `dyn`
to a composed base, unfixed constants). Three deserve attention:

- **"Any of a union's variants to that union"** contradicts
  [Unions](design.md#unions), which identifies a variant by name and allows two
  variants of one payload type. The shipped compiler rejects
  `v: Value = 7;` with `L0352` ([Probes](#probes)), so this line is a leftover
  from Odin's type-based unions and should be deleted from the spec.
- **A scalar to `Simd(T, N)`, the splat.** It is the only implicit conversion
  that *manufactures* a wider value, and it exists so that `lanes * 2.0`
  reads well. The explicit `Simd(f32, 4)(2.0)` or a `simd.splat` costs a few
  characters and removes a rule from ranking. Low priority, but it is the one
  conversion a type theorist would strike first.
- **A distinct procedure type to and from its underlying procedure type.** It
  undoes `distinct` for exactly one kind of type. If a distinct procedure type
  should be freely interchangeable with its base, it is an alias, not a
  distinct type; if not, the conversion should be explicit as for every other
  distinct type.

### 2.9 Affine types: `move_only`

A `move_only struct` is an affine type. The keyword is needed because a type
with `hook(drop)` and no `hook(copy)` still receives a *generated* field-wise
copy, which for a file handle duplicates the handle and double-closes it. That
default is unsafe, and the keyword exists to turn it off.

**Proposal.** A record that declares `hook(drop)` without `hook(copy)` is
move-only (Rust's rule: a type with a destructor is not `Copy`). Then
`move_only` is needed only for types that are move-only without a destructor
(`Atomic(T)`, `Once`, a random generator), and for those it is an ordinary
type attribute, `@(move_only)`, beside `@(thread_affine)` and
`@(wakes_on_drop)`, rather than a keyword with its own grammar production.

**What is lost.** A resource type that wants the generated field-wise copy
*and* a drop hook writes `hook(copy)` to say so, which is the rare case and the
one that deserves a written decision.

### 2.10 What type theory should not drive

Three things the lens suggests and this review does **not** recommend:

- **Higher-kinded or variadic generics** to spell `Callable` or a generic
  `Functor`. Loke's monomorphized `$` parameters and structural interfaces are
  the right size for a systems language.
- **Lifetime variables.** The inferred result contracts plus written escape
  levels cover what Loke promises. Written public contracts
  ([2.7](#27-effects-as-one-algebra)) are the bounded alternative.
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
becomes an attribute in the same place ([2.9](#29-affine-types-move_only)).

### 3.2 Allocators: `via`, `make`, and `init`

Allocator selection has three spellings: `via` on a declaration, `make` with an
allocator argument, and library constructors such as `Arena.init(parent)` and
`String_Builder.init(allocator)`. `via` is a contextual keyword with a parser
rule, is forbidden on statics, on `string`, and on `Shared(T)`, and it
introduces a concept the other two do not need: the **declaration allocation
policy**, the allocator a later clone *into the variable* uses, which "belongs
to the declaration, not to the value it holds" and in turn excludes such
destinations from [last-use transfer](design.md#last-use-transfer).

**Proposal.** An allocator is a property of the value, chosen where the value
is constructed, as every library type already does:

- Remove `via`. Write `data := make([dynamic]int, allocator = arena.allocator());`
  or `data := [dynamic]int.init(arena.allocator());`, whichever spelling the
  built-in containers adopt (one of them; see [3.5](#35-the-predeclared-universe)).
- Copy assignment into a live container clones into *that container's* bound
  allocator; into a dead or unbound one, into the default. A move transfers the
  source's allocator, as now. `x = y.clone(arena)` is the explicit form.

**What is lost.** After `move(x)` out of an arena-bound variable, a later
plain copy into `x` goes to the default allocator, where today it returns to
the arena. That case is rare and `clone(arena)` states it. In exchange the
concept of a per-declaration policy, the `via` grammar and keyword, two
forbidding rules, and a last-use-transfer exclusion go.

### 3.3 The iteration protocol

[Iteration protocol](design.md#iteration-protocol) is the largest protocol in
the language: `Element`, `Iterator`, `Mut_Iterator`, `Item`, four yield modes,
`iter`, `iter_mut`, `iter_reverse`, `iter_mut_reverse`, three compiler
adapters, six container views, and three catalogue interfaces. Two cuts keep
every loop writable:

- **Reversal is an adapter, not a method quartet.** `reversed()` today requires
  `iter_reverse`, and under `&mut` requires `iter_mut_reverse`, and
  `Reverse_Iterable` names one of them. The spec already says that "a reverse
  traversal that needs another iterator representation must instead be a
  separate adapter with its own `Element` and `Iterator`". Make that the only
  rule: a type that reverses provides an ordinary `reversed(self: ^)` method
  returning an iterable view, the compiler provides it for built-in sequences,
  and `iter_reverse`, `iter_mut_reverse`, and `Reverse_Iterable` go.
- **`Element` can be inferred.** Every other associated type of the protocol
  "follows from those signatures", but `Element` "is always written". It is
  determined by `next`'s `Item` under the yield-mode table (`Item` itself,
  the pointee of `^Item`, or the record with pointer fields stripped). Writing
  it stays allowed; requiring it is one more rule than needed.

The mutable protocol (`iter_mut`, `Mut_Iterator`) is worth keeping: making
`foreach (&mut v in values)` reborrow the container is what lets a container
lend elements without first making a `[]mut T`.

### 3.4 The copying and consuming pairs

Two pairs double a container's surface: `op`/`try_op`, which
[The `op`/`try_op` pair](open-questions.md#the-optry_op-pair) already examines,
and the copying and consuming members of `append` and `insert`, which a user
container must write as a procedure group of two because only the built-in
containers get "takes its element like an initialization" for free.

The second pair is the one the language could remove. An **initializing
parameter mode**, say `value: init T`, would mean exactly what
[Container insertion](design.md#container-insertion) means: a place is cloned,
a temporary or `move(x)` is transferred. A user container then writes one
`append`, as `Small_Array` would like to. This is an addition of one mode, but
it removes a group of two from every container and the exclusion rule that
removes the copying member for move-only elements. It is also the mode `box`,
`shared`, `find_or_insert`, variant construction, and record literals already
use informally. One name for a rule that exists in five places is a
simplification even though it adds a keyword.

### 3.5 The predeclared universe

[Predeclared names](design.md#predeclared-names) puts into every scope names
that are also declared in packages: `Allocator` and `Allocator_Error`
(`core:mem`, `base:runtime`), `Shared`, `Weak`, `shared`, `try_shared`
(`base:runtime`, and the spec itself calls `Shared(T)` "a library type"),
`make`, `try_make`, `free_all`, `box`, `try_box`. `Atomic`, `Once`, and
`Lazy` are not predeclared though they are of the same kind as `Shared`.

**Proposal.** Predeclare only what the language's own rules reach without an
import: the primitive types, `Unit`, `Option`, `Result`, `Range`, `Simd`,
`Box`, the compile-time built-ins, and the build constants. Move `Shared`,
`Weak`, `shared`, `try_shared`, `Allocator`, `Allocator_Error`, `make`,
`try_make`, and `free_all` to their packages, and spell construction with an
allocator as a named constructor on the type (`[dynamic]T.init(len, cap,
allocator)` and `map[K]V.init(reservation, allocator)`, with `try_init`),
as `Arena.init` and `String_Builder.init` already do. `free_all(a)` becomes
`a.reset()` with the same `@(allocator_reset)` contract. `box` and `try_box`
can stay, since `Box` is a language type with a representation rule.

### 3.6 Runtime reflection

`runtime.Type_Info` carries a `members` table whose `Member_Kind` covers
fields, enum values, union variants, and, for a procedure type, its
parameters and result, as nameless entries carrying a type. The compile-time
tier (`fields_of`, `enum_values_of`, `variants_of`) gives the first three
where code can act on them, and comments.md
["Reflection beyond fields and enum values"](comments.md#reflection-beyond-fields-and-enum-values)
leaves procedure reflection out of that tier "without a demonstrated
consumer", so the runtime table is the one place a procedure's shape is
reflected. Printing does not read `Type_Info`: it dispatches through
generated `format` thunks. With `any_view` folded into `dyn`
([2.5](#25-existentials-any_view-is-a-dyn-view)), the remaining consumer is a
program that wants a type's name, size, or member table at run time.

**Proposal.** Either state the table's purpose and keep it whole, or shrink
`Type_Info` to `id`, `kind`, `name`, `size`, `align`, `element`, `key`, and
`count`, delete `Member_Info` and `Member_Kind`, and say that runtime
reflection describes shape, not members. The second loses the only
reflection of a procedure type's parameter and result types, which the
rationale in comments.md says no tool has needed; a serializer that later
needs runtime member tables can build them from `fields_of` in a static
`foreach`, which is the direction the language already prefers. This review
records it as a judgment call rather than a deletion.

### 3.7 `string` as the one sharing owner

`string` is the one container whose copy *shares* storage, with an atomic
handle count that [Thread-affine strings](open-questions.md#thread-affine-strings)
measures at about 12.5 ns per copy-and-drop and calls "the most frequent hidden
cost in ordinary code". The sharing rule is also a special case in at least
eight places: the ownership table, `via`, `clone`, copy-cost diagnostics,
last-use transfer, allocator provenance ("a shared-storage logical clone keeps
the source allocation's provenance"), thread transfer, and
`String_Builder.finish`'s copy.

**Proposal to evaluate.** Make `string` an ordinary owner: a copy clones (one
allocation, as a `[dynamic]u8` copy does), last-use transfer makes the last
copy a move, and reading passes a `string_view`, which is what every text API
already takes. The representation becomes data, length, and allocator, the
same three words, with no header and no atomics; a literal has a null
allocator and drops to nothing.

**What is lost.** `second := first` on a heap string allocates where it now
bumps a count. Programs that copy strings into many containers pay for it;
programs that pass text around do not, because they pass views. The gain is a
uniform value model, no atomic traffic, and one fewer special case in every
rule that mentions `Shared(T)`. It should be measured on the repository's
text-heavy programs before deciding, but it is the kind of change that
simplifies and speeds up at once.

### 3.8 `using`

[Promoted struct fields](design.md#promoted-struct-fields) is Odin's `using`
narrowed to field lookup. It adds a contextual keyword, an ambiguity rule, and
a "not flattened" exception in destructuring, reflection, and `foreach`
bindings, for the saving of one selector (`entity.x` for
`entity.position.x`). A general-purpose language can live without it; the
composition it serves is written as plainly with the field named.
Recommended for deletion, low urgency.

### 3.9 `@(initialized=count)` and uninitialized storage

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
precise error message.

| Today | Problem | Proposal |
| --- | --- | --- |
| `for ((key in counts)) { }` | A doubled parenthesis changes meaning, which no other construct does | Drop the special rejection of `for (key in counts)`. It type-checks only when `in` applies, so a mistyped traversal still fails, and the diagnostic can say "did you mean `foreach`" when `counts` is iterable and `key` is undeclared |
| `(f() or_return).len()` | A member of a propagated payload needs parentheses because any primary token begins the failure operand | Parenthesize the operand instead: `f() or_return(.io)`. A bare `or_return` is then followed by the payload's suffixes, `f() or_return.len()`, and `f() or_return + 1` keeps its meaning |
| `(&mut a[:]).indexed()` | `&mut` applied to a slice suffix is a special grammatical case, and a member of the result needs parentheses | A postfix spelling of mutable slicing, `a.slice_mut()` or `a[mut lo:hi]`, which chains like every other postfix and removes the `&mut`-before-slice rule from grammar.md |
| `self: ^` | A dangling caret that looks like a typo | With [2.4](#24-one-capability-axis), the receiver forms are `self`, `self: ^`, `self: ^mut`, `self: move`; allowing `self: ^Self` as the spelled-out form gives a name to read |
| `Name :: struct @(packed) { }` | Attributes in a second position | [3.1](#31-attributes-in-one-position) |
| `move_only struct @(thread_affine) { }` | A keyword and an attribute for two properties of the same kind | [2.9](#29-affine-types-move_only) |
| `data: [dynamic]int via arena.allocator() = {};` | A contextual keyword for one declaration-time choice | [3.2](#32-allocators-via-make-and-init) |
| `(dyn Drawable)(&circle)` | Conversion of a composite type is C-cast-like | Keep. `T(v)` with a parenthesized composite type is one rule for every conversion, and the alternative (`as`) is a keyword |

### 4.2 Verbosity hotspots

- **Callable constraints.** `f: $C` plus
  `where interfaces.Callable(C, proc(n: int) -> int)` is the common way to
  take a callback, and it is long. A sugar `f: some proc(n: int) -> int`
  meaning exactly that bound would remove the most repeated `where` clause in
  generic code; `some` is the word
  [Returning a capture literal](open-questions.md#returning-a-capture-literal)
  already considers for results. This is an addition, but it replaces a longer
  idiom, so it is a net reduction in what a reader sees.
- **`interfaces.` everywhere.** The catalogue is used by nearly every generic
  procedure and must be qualified. Either predeclare the catalogue interfaces
  (they are language-defined predicates, closer to `Option` than to `fs`) or
  let `base:` packages be imported unqualified by a project setting. The
  first is the simpler rule.
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
that every tool must follow. [3.2](#32-allocators-via-make-and-init) removes
`via`, [3.8](#38-using) removes `using`, and [2.4](#24-one-capability-axis)
simplifies `inout`. `static` and `thread_local`, whose rule has four cases,
would be simpler as reserved words: no program needs a type named `static`.

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
| `inout` parameter mode and `self: inout` | `^mut T`, `&mut x`, `self: ^mut` ([2.4](#24-one-capability-axis)) | The word `inout` at call sites | High |
| `any_view`, `[]any_view` exception | `dyn Any` with downcast, `..dyn fmt.Formattable` ([2.5](#25-existentials-any_view-is-a-dyn-view)) | Nothing | High |
| `enum_values_of`, `meta.Enum_Value`, separate enum kind | `variants_of`, `meta.Variant` with `value` ([2.1](#21-sums-enum-is-a-union)) | Nothing | High |
| `Status` as a nominal type, `Status.map_error` | `Status :: Result(Unit, $E)` ([2.3](#23-status-is-resultunit-e)) | Nothing | High |
| `via`, declaration allocation policy | Construction with an allocator ([3.2](#32-allocators-via-make-and-init)) | Re-binding an arena after a move | High |
| `iter_reverse`, `iter_mut_reverse`, `Reverse_Iterable` | A `reversed()` method returning a view ([3.3](#33-the-iteration-protocol)) | Nothing | Medium |
| Type-position attributes, inline nominal `enum`/`union` | Declaration attributes ([3.1](#31-attributes-in-one-position)) | `[size_of(enum { A, B })]u8` | Medium |
| `move_only` keyword | Drop hook implies move-only; `@(move_only)` otherwise ([2.9](#29-affine-types-move_only)) | Generated copy on a type with a drop hook, now written | Medium |
| "Any of a union's variants to that union" | Nothing; the compiler already rejects it | Nothing | Editorial, do now |
| Scalar-to-`Simd` splat conversion | `Simd(T, N)(x)` or `simd.splat(x)` | `v * 2.0` | Low |
| Distinct-procedure-type conversions | Alias, or explicit conversion | Nothing | Low |
| `stdcall` calling convention | `c`, which it equals on x64; add back with a 32-bit target | Nothing today | Low |
| `using` | Named selection ([3.8](#38-using)) | One selector per access | Low |
| `for ((x in y))` escape hatch | `for (x in y)` with a diagnostic hint | A doubled-parenthesis rule | Low |
| Success returns | `return .ok(n);` ([4.4](#44-rules-whose-text-is-longer-than-what-they-save)) | Four characters per return | Judgment call |
| `Option.ok_or` | `or_return .Variant` and a `switch` | An eager form for stored absences | Judgment call; the open question keeps it |
| `Type_Info.members`, `Member_Info`, `Member_Kind` | `fields_of`, `enum_values_of`, `variants_of` at compile time ([3.6](#36-runtime-reflection)) | Runtime reflection of a procedure type's parameter and result types | Judgment call |
| Predeclared `Shared`, `Weak`, `shared`, `try_shared`, `Allocator`, `Allocator_Error`, `make`, `try_make`, `free_all` | Their packages and named constructors ([3.5](#35-the-predeclared-universe)) | An import line | Medium |

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
opportunities, largest first. None changes a specified result.

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
- a `^T` parameter's pointee is not written by anyone: `readonly`, unless the
  type reaches a [`@(synchronized)`](design.md#synchronized) field, which an
  atomic may write through a read-only receiver;
- a `value: T` parameter that travels by pointer ("borrowed for the call;
  borrows of its own storage cannot escape") is `readonly` and
  `captures(none)` under the same exclusion;
- a `@(escape=none)` parameter is `captures(none)` whatever its mode.

This is exactly the argument Rust makes for `&mut` and `&`, and Loke's
[What is not checked](design.md#what-is-not-checked) already assigns the
unchecked cases (raw pointers, foreign aliases, `unsafe`) to the programmer.
Slices and views need one ABI change to carry attributes: pass the data
pointer and length as separate scalar parameters in the `loke` convention,
which is private to the compiler. The gain is the usual one for `noalias`:
loads hoisted out of loops across stores, vectorization of loops that write
through one slice and read another, and fewer reloads around calls.

### 6.2 Container operations in IR, not through an operation table

`x.append(v)` on a `[dynamic]int` lowers to
`call i32 @loke_rt_v1_dyn_append(ptr self, ptr ops, ptr elem, i64 1)`, a call
into prebuilt C with a table of function pointers for the element's clone and
drop, and a map lookup calls `loke_rt_v1_map_find` with `key_hash` and
`key_equal` through pointers on every probe. Nothing inlines across that
boundary, so the most common container operations in the language cost a
call, an indirect call or two, and a table load each, whatever the element.

**Proposal.** Keep the runtime for growth, rehashing, and the generic
clone/drop loops, and emit the fast paths in the module, specialized per
element type as every generic procedure already is: `append` as
"if `len < cap` store and increment, else call grow"; `x[i]` already is
inline; map probing with the key's `hash` and `==` called directly, so an
`int` key hashes and compares inline. Rust and Go both specialize these; it is
the single largest difference between Loke's collections and theirs. The ops
table stays for the paths that remain in C.

A related, smaller step: compile the runtime to bitcode and link it with
`-flto` from the same cache, so that `string_retain`, `alloc`, and the
dispatch helpers inline where they are hot. The cache key already covers the
flags this needs.

### 6.3 Unwinding without a runtime frame list

Under the `unwind` strategy the emitter maintains a shadow stack:
`loke_rt_v1_frame_push`/`pop` around procedures with cleanup, a live-flag
array, and an environment table of local addresses that the generated thunk
replays ([Probes](#probes) show the `%uframe`, `%ulive`, and `%uenv` allocas
and a store into `%uenv` on every loop iteration, left for LLVM to delete when
the frame is never pushed). Where a frame is pushed, every call to the
procedure pays the push, the pop, and the stores that keep the table current.

Windows x64 has table-driven unwinding with no cost on the non-panicking path,
and LLVM supports it through `invoke`, cleanup pads, and the MSVC personality.
Because a Loke panic is never caught, the landing pads would only run
cleanups and resume, which is the simple half of that machinery. The gain is
every push, pop, and bookkeeping store in every procedure that has a managed
local or a `defer`; the cost is a port of the cleanup emitter and a dependence
on platform unwind tables, which the roadmap's Linux and macOS phases would
have to provide (DWARF, which LLVM also emits). This should be measured
first; `-panic=abort` already shows the upper bound of the saving.

### 6.4 Checked arithmetic and bounds in loops

Checked `+`, `-`, `*` lower to `llvm.*.with.overflow` plus a branch to a
panic block, and the panic callee is declared without `cold` or `noreturn`
(the `unreachable` that follows the call lets LLVM infer the latter). The
measured cost is in
[Overflow checks in index arithmetic](open-questions.md#overflow-checks-in-index-arithmetic):
3.5 to 5.7 times on a column-major product, because the branch per element
blocks vectorization. Two steps keep the semantics and remove most of the
cost:

- **Range facts for loop bindings and lengths.** A `foreach (i in 0 ..< n)`
  binding is in `[0, n)`; a slice or array length is at most
  `MAX_INT / size_of(T)`; a constant is itself. From these, `i + 1`,
  `i * stride` for a constant stride, and `row * columns + column` where the
  product of the extents was computed once are provably in range, and the
  emitter can write `add nsw` and a plain `getelementptr` instead of the
  checked forms. The same facts remove the bounds check on `xs[i]` inside a
  loop over `0 ..< xs.len()`. This is the standard induction-variable range
  analysis; LLVM's own passes do part of it but cannot see through the
  overflow intrinsic plus branch.
- **Loop versioning** for the remaining affine index expressions: check once
  before the loop that the maximum index fits, and run an unchecked body when
  it does, the checked body otherwise. LLVM does this for runtime alias checks
  but not for overflow intrinsics, so it is the compiler's to do.

Mark `loke_rt_v1_panic` `cold noreturn` and give the panic branch weights.
It is cheap and makes the block layout and inlining decisions explicit
rather than inferred.

### 6.5 `string`

[3.7](#37-string-as-the-one-sharing-owner) is a performance item as much as a
design one: the atomic retain and release are an out-of-line call and a
locked memory operation on every copy and drop of a heap string, in code that
otherwise never touches a lock.

### 6.6 Union layout and small values

The open item on compiler-chosen union layout
([Performance opportunities and actual semantic limits](open-questions.md#performance-opportunities-and-actual-semantic-limits))
is endorsed: `Result(Option(T), E)` and a `Result(Small, Enum)` should fit
their niches, with `@(repr=...)` for a stable layout where foreign code or
serialization needs one. Independently, the `loke` convention could pass a
two-word record such as a slice or an `Option(^T)` in registers rather than
as an LLVM aggregate, which the current `LARGE_VALUE_BYTES` rule handles
only by address.

### 6.7 Defaults

- `-cpu=x86-64-v2` as the default costs nothing on any machine that runs the
  supported Windows versions ([Targeting x86-64 levels](open-questions.md#targeting-x86-64-levels))
  and gives `popcnt` and SSE4.2 to every program.
- `-opt=none` as the default is right for development. The guide should say
  plainly that `speed` is `-O2` and is what a shipped program uses.

### 6.8 What not to do

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
  heading structure, or into compiler-architecture.md where it describes
  this implementation. The programmer-facing text would be about half the
  length.
- **State each mechanism once.** The effect rules
  ([2.7](#27-effects-as-one-algebra)), the "takes its element like an
  initialization" rule ([3.4](#34-the-copying-and-consuming-pairs)), and the
  generic-argument exclusion ([2.3](#23-status-is-resultunit-e)) each appear
  in several places with slightly different wording.
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
2. Performance that needs no language change: alias attributes
   ([6.1](#61-alias-attributes-from-facts-the-checker-already-proves)),
   container fast paths in IR ([6.2](#62-container-operations-in-ir-not-through-an-operation-table)),
   `cold noreturn` on the panic entry, and the `-cpu` default. Measure each
   with `perf.ps1` and the `bench/` workloads before and after.
3. `enum` as a payloadless union, and parametric aliases with `Status` as the
   first user. Both are mostly internal and shrink reflection and the error
   catalogue.
4. `any_view` as a `dyn` view. Depends on nothing above; touches `fmt`,
   `assert`, `panic`, and the witness layout.
5. Attributes in one position, `move_only` as an attribute, and the drop-hook
   rule.
6. `inout` folded into `^mut`. The largest surface change; do it with the
   formatter able to rewrite call sites and receivers mechanically.
7. Remove `via`; add container constructors; prune the predeclared universe.
8. Range facts and loop versioning for checked arithmetic
   ([6.4](#64-checked-arithmetic-and-bounds-in-loops)), then measure the
   dense kernels again.
9. Evaluate `string` as an ordinary owner and table-driven unwinding on the
   repository's programs; decide on the measurements.

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

# Language design review (2026-10-31)

A review of the Loke language as [design.md](design.md) and
[grammar.md](grammar.md) specify it, looking for ways to make the language
smaller, more regular, and faster, rather than for features to add. It is
non-normative: everything below is a proposal for discussion, not an amendment,
and backward compatibility was not a constraint. Where it recommends deleting
or merging something, it says what is lost, so that each item can be judged on
its merits for a general-purpose language and not by how often the repository
happens to use it.

Compiler-only optimizations and their supporting observations are in the
[compiler optimization review](compiler-optimizations-2026-10-31.md#compiler-context).
The performance proposals remaining here require language-contract changes.

The review read design.md, grammar.md, comments.md, open-questions.md,
known-gaps.md, future-plans.md, and the design rules of standard-library.md in
full, sampled the LLVM emitter, the runtime ABI header, and the benchmark
baselines, and ran probe programs against the shipped `lokec.exe` (see
[Probes](#probes)). It builds on the
[language design review of 2026-10-03](#language-design-review-2026-10-03),
kept at the end of this file, and does not repeat what that review already
settled.

A second pass the same day checked each proposal against the specification,
known-gaps.md, and the runtime, looking for costs the first draft had not
counted. Proposals whose costs outweighed their gains were withdrawn; each is
listed with its reason under [Withdrawn proposals](#withdrawn-proposals), so
that it is not proposed again without an answer. Others were narrowed, and
their **What is lost** now says what the first draft missed.

A review of these proposals (`cfd20372`)
then checked the return and lifetime rules, LLVM capture semantics, and emitted
code. Its findings on address capture, slice bounds, and the small-value ABI
are incorporated below; the two on generic `Status` fallthrough and `any_view`
lifetimes were settled when those proposals were adopted. A check of the
alias-attribute step on 2026-11-01 linked hand-edited IR at `-O2` and found
that `noalias` is unsound under the default `unwind` strategy, that a callee
may read a global it holds `^mut` to, and that LLVM already infers the capture
attributes; [6.1](#61-alias-attributes-from-facts-the-checker-already-proves)
and step 1 of the [Suggested order](#8-suggested-order) are narrowed
accordingly.

On 2026-11-01 the review was revised to the language as it then stood. The
first five steps of its suggested order had landed: the editorial fixes, the
performance work that needed no language change, `Status` as an alias of
`Result(Unit, E)`, `variants_of` over enums, and the deletion of `any_view`.
Their proposals are removed from the text and listed under
[Adopted proposals](#adopted-proposals) or the compiler review's
[Adopted optimizations](compiler-optimizations-2026-10-31.md#adopted-optimizations),
the remaining sections are
renumbered, and the inventory and probes are taken again from the compiler at
`4173b622`.

A review of step 1 the same day found that the generated copy of the review's
own example of a field-wise copy, a `Box` chain with an iterative drop hook,
overflows the stack on a long chain ([Probes](#probes)). The copy decision for
drop hooks, argued on that ground and split from the attribute move, which is
syntax alone, then landed and is under [Adopted proposals](#adopted-proposals).

On 2026-11-02 attributes moved to the declaration and `move_only` became one
of them; that proposal is removed from the text and listed under
[Adopted proposals](#adopted-proposals), with the sections after it renumbered.

On 2026-11-02 the editorial proposals were applied to design.md: the conformance
appendix, effects and initialization stated once, procedures as callables, and the
explanation of `inout` beside `^mut T`. Library material left design.md for
standard-library.md at the same time. They are under
[Adopted proposals](#adopted-proposals), and their sections below say so. Line
counts in this review are those of the versions it examined.

On 2026-11-11 a third pass re-evaluated every proposal still open against the
language at `807ca6ab`, with probes run on `lokec` 0.9.0 built at `41c0e2d4`
([Probes](#probes)). It recounted the inventory, and it asked of each proposal
that offered only keeping or deleting whether a narrower change removes the
problem. It found two costs the earlier passes had wrong: deleting success
returns loses a transfer, not four characters
([4.4](#44-rules-whose-text-is-longer-than-what-they-save)), and an `Uninit(T)`
cannot be copyable as bytes ([3.2](#32-initializedcount-and-uninitialized-storage)).
It found one way to keep most of the alias proposal under the default panic
strategy ([6.1](#61-alias-attributes-from-facts-the-checker-already-proves)).
Where it changed or added to a section, the paragraph begins **Third pass.**

A review of step 3 of the [Suggested order](#8-suggested-order) the same day
found that it joined three independent changes of unequal merit, and split it.
Deleting `using` loses more than a selector
([Adopted proposals](#adopted-proposals)). The narrowed
distinct-procedure conversion leaves the unwrapping direction, whose target
type has no name (also there), and narrowing the splat exchanges one rule for
another rather than deleting one ([2.4](#24-coercions)); the splat moved to
the end of the order. Probes settled what the two narrowed rules must keep
([Probes](#probes)). Where it added to a section, the paragraph begins
**Review of step 3.**

On 2026-11-11 `using` was deleted, the first of those three changes. Its
proposal is removed from the text and listed under
[Adopted proposals](#adopted-proposals), with the section and the steps after
it renumbered.

The same day the distinct-procedure conversion was narrowed, the second. Probes
before the change showed what the conversion had cost, and probes of the
implementation fixed the narrowed rule's edges ([Probes](#probes)). Its
proposal is removed from the text and listed under
[Adopted proposals](#adopted-proposals), with the steps after it renumbered.
The splat is what remains of step 3.

## Contents

- [Summary](#summary)
- [1. The shape of the language today](#1-the-shape-of-the-language-today)
- [2. Type theory as a simplifying lens](#2-type-theory-as-a-simplifying-lens)
- [3. Orthogonality](#3-orthogonality)
- [4. Syntax](#4-syntax)
- [5. Deletion candidates](#5-deletion-candidates)
- [6. Performance requiring language-design decisions](#6-performance-requiring-language-design-decisions)
- [7. The specification itself](#7-the-specification-itself)
- [8. Suggested order](#8-suggested-order)
- [Adopted proposals](#adopted-proposals)
- [Withdrawn proposals](#withdrawn-proposals)
- [Probes](#probes)
- [Language design review (2026-10-03)](#language-design-review-2026-10-03)

## Summary

Loke's individual decisions are well argued, and comments.md records the
argument for nearly every one. The problem is the sum. The specification is
about 11,600 lines; it has three spellings of a sum type, two reflection tiers,
two mutable-borrow modes, four inferred effect systems, 30 attributes, and a
list of twenty implicit conversions. Each was added for a reason. The two
clearest pairs that expressed one idea twice, `Status` beside
`Result(Unit, E)` and `any_view` beside `dyn`, are gone
([Adopted proposals](#adopted-proposals)). Of the pairs that remain, not every
one is a duplicate: `via` and construction with an allocator differ in a way
that matters, and `inout` and `^mut T` may ([2.5](#25-one-capability-axis)).

The remaining recommendations, after the third pass, best ratio of concepts
removed to expressiveness lost first:

1. **Replace** `@(initialized)` with a storage type `Uninit(T)`
   ([3.2](#32-initializedcount-and-uninitialized-storage)). Three of the
   attribute's four uses in the library already encode one with a one-element
   array.
2. **Shrink** runtime reflection to shape ([3.1](#31-runtime-reflection)).
3. **Make design.md and releasing.md agree about union layout**
   ([6.2](#62-union-layout)): one specifies it and the other says it may
   change. The niches can follow when measured, and their gain is modest.
4. **Respell** mutable slicing as `a[mut lo:hi]`
   ([4.1](#41-forms-that-read-badly-and-fixes-that-keep-diagnostics-precise)).

The splat of a typed scalar can be narrowed to lane-wise operators
([2.4](#24-coercions)), but that exchanges one rule for another and removes
nothing harmful, so it is near the end of the
[Suggested order](#8-suggested-order).

Two findings are independent of any proposal: a returned construction clones a
local that a plain `return` would transfer
([4.4](#44-rules-whose-text-is-longer-than-what-they-save)), and the library
attaches provenance to a rebuilt pointer by calling through a plain procedure
type ([Public borrow contracts should stand on their
own](#public-borrow-contracts-should-stand-on-their-own)).

Except where a section's **What is lost** says otherwise, none of the deletion
candidates changes what a Loke program can express.

## 1. The shape of the language today

An inventory, counted from design.md and grammar.md, to show where the weight
is. The first four rows and the line count were taken again on 2026-11-11; the
others are as the review first counted them:

| Area | Count | Where it is |
| --- | --- | --- |
| Reserved words | 32 | [Keywords](grammar.md#keywords) |
| Contextual keywords, each with a disambiguation rule | 17 | [Keywords](grammar.md#keywords) |
| Attributes | 30 | [Attribute categories](design.md#attribute-categories) |
| Implicit conversions | 20 | [Implicit type conversions](design.md#implicit-type-conversions) |
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
| Lines in design.md | 11,609 | 11,982 when first counted |

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
reads. Those that track provenance now sit in a normative appendix
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
and field reordering. No change proposed.

### 2.2 Procedures are callable records

`Callable(C, Signature)` "holds by a built-in rule, since a parameter list is
not a requirement an interface body can spell". That is true, and the only
general fix is variadic generics, which this review does not recommend. The
smaller observation is that the catalogue already treats a procedure value as a
record with a `call` method and no fields (`dyn proc(...)` is
`dyn Callable(...)`, and a procedure "occupies the view's data word"). Saying
so once in design.md, as the definition of procedure values, lets
[Calling a value](design.md#calling-a-value), `Callable`, and
[Borrowed callable views](design.md#borrowed-callable-views) share one
statement of the rules. This is adopted: [Calling a value](design.md#calling-a-value)
holds it.

### 2.3 Effects as one algebra

Loke has an inferred effect system without naming it: the write effect, the
reach effect, the allocator-use effect, and the pooled join's `thread_local`
write-back are each defined with their own resolution rule for callbacks,
procedure values, `dyn` views, and unions, and the specification says "with
callbacks and unions resolved as under Global write effects" three times.

**Proposal (adopted as [Inferred effects](design.md#inferred-effects)).** Define
*effects* once: a procedure's effect is a set of facts
(writes global `g`, reaches through global carrier `g`, operates on region `r`,
writes `thread_local` `t`); a call takes the union of its callee's effects; a
call through a value takes the union over every procedure the value may hold,
by one rule for locals, parameters, `dyn` witnesses, and procedure groups. Then
each of the four is one sentence naming which facts it reads and where. This
does not change what is checked; it halves the text that specifies it, and
gives [Per-call effect precision](#per-call-effect-precision)
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
[Public borrow contracts should stand on their own](#public-borrow-contracts-should-stand-on-their-own)
is the right boundary: inferred inside a package, written at the public
surface. This review endorses it and adds that the same written form should
carry a procedure's effect summary, so that an `api.loki` tells a reader what
a call may touch without the body.

**Third pass.** The endorsement is narrowed under
[Public borrow contracts should stand on their own](#public-borrow-contracts-should-stand-on-their-own):
the library cases that motivated a written contract are better served by an
unchecked operation in the body, which leaves the written form for public
callback types. The `// inferred:` lines that
[Using a package without reading its code](open-questions.md#using-a-package-without-reading-its-code-proposal-2026-10-21)
proposes for `api.loki` give a reader the effect summary without any new
syntax, and should come before a written one.

### 2.4 Coercions

[Implicit type conversions](design.md#implicit-type-conversions) lists
twenty rules. Each is a subtyping or coercion rule that feeds the four-level
overload ranking. Most are sound and useful (owner to view, `mut` to
read-only, `dyn` to a composed base, a value to a `dyn I` view as an element of
a `..dyn I` parameter, unfixed constants). One deserves attention. A second,
the conversion of a distinct procedure type to and from the type it wraps, was
narrowed to named procedures and procedure literals
([Adopted proposals](#adopted-proposals)).

- **A scalar to `Simd(T, N)`, the splat.** Two cases share the rule. An unfixed
  constant, as in `lanes * 2.0`, `v << 2`, or `half: Simd(f32, 4) = 0.5`
  ([Construction and conversion](design.md#construction-and-conversion)), is
  the common one; it belongs with the other unfixed-constant conversions and
  should stay. A typed scalar variable splatting into a vector is the one case
  in the list that manufactures a wider value from a run-time operand. If that
  case goes, its replacement needs a rule of its own: `Simd(f32, 4)(x)` is
  today a lane-wise conversion between vectors of the same lane count, so a
  splat would be `simd.splat(x)` or a new conversion form. Low priority.

**Third pass.** There is a narrower fix than deletion: the conversion stays
for a constant and goes for a typed run-time value.

- **The splat belongs to the operators, not to the conversion list.** The
  conversion applies in every position: a typed `f32` passed to a
  `Simd(f32, 4)` parameter, initializing one, or returned as one splats
  ([Probes](#probes)), and so it also feeds overload ranking. What is worth
  keeping is `v * scale`, the scalar multiple of a vector, and the lane-wise
  table already describes it for a shift count. So let a lane-wise binary
  operator take a scalar of the lane type as either operand and apply it to
  every lane; let an unfixed constant convert wherever a vector is expected,
  as it does; and write a typed scalar anywhere else as the explicit
  conversion `Simd(f32, 4)(x)`, which is unambiguous beside the lane-wise
  conversion because its operand is a scalar. The entry leaves the list,
  `v * scale` is not lost, and the sentence under
  [Parameter semantics and ABI lowering](design.md#parameter-semantics-and-abi-lowering)
  that keeps a scalar from binding `inout Simd(T, N)` is no longer needed.
  What is lost is `take(scale)` and `half: Simd(f32, 4) = scale`.

**Review of step 3.** The narrowing has a cost the third pass did not count.

- **The splat narrowing is an exchange, not a deletion.** One entry leaves the
  conversion list, and two exceptions go with it: the sentence about
  `inout Simd(T, N)`, and the clause in
  [Destructuring](design.md#destructuring) that keeps a scalar field from
  splatting into a vector. No run-time conversion then feeds overload ranking.
  In return every row of the
  [lane-wise table](design.md#lane-wise-operators) gains a scalar operand, on
  either side, and that includes the comparisons and compound assignment,
  which splat today ([Probes](#probes)). The explicit form needs a rule of
  its own as well: `Simd(f32, 4)(x)` is accepted today only because `x` is
  assignable to the vector. That rule should keep what the compiler does now
  and reject a scalar of another type, so that the scalar conversion stays
  written, as in `Simd(i32, 4)(i32(x))`. What is lost is wider than the two
  forms named above: every procedure with a vector parameter takes a typed
  scalar only as a written conversion, and `simd.select(mask, v, x)` is one.
  Against all this the conversion does no harm of its own. It allocates
  nothing, loses no information, and moves no ownership; it is irregular only
  in taking a run-time operand. The concept count comes out about level, so
  this is the weakest recommendation still open.

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

**Third pass.** The first bullet claims more than `inout` delivers. Method
syntax supplies the marker, so `counter.bump()` and `values.append(1)` change
their receiver with nothing written at the call
([Receiver forms](design.md#receiver-forms)); only an argument shows it. The
case against the fold rests on the other two bullets, which stand. The pair is
also less of an asymmetry than [2.5](#25-one-capability-axis) first said:
read-only has the same two forms, `value: T`, which is the caller's value for
the call, and `^T`, which is a borrow held as a value. `inout T` and `^mut T`
are the mutable column of that table, and the explanation now in design.md
says so. The lean against the fold is unchanged.

One thing is left for the compiler. With `bump :: proc(self: ^mut Counter)`,
`c.bump()` is reported as ``L0363: `Counter` has no field or member `bump` ``
([Probes](#probes)), which sends the reader looking for a missing declaration.
A note that `bump` takes `self: ^mut Counter`, which is not a receiver, and
that the fix is `self: inout` or `Counter.bump(&mut c)`, would make the
documented exception a diagnosed one.

**A cheaper fix for the asymmetry (adopted).** If both stay, explain them where the
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

### 3.1 Runtime reflection

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

**Third pass: shrink it.** Deleting `any_view` changed what the table is for.
No value carries a `typeid` any more, so every `typeid` in a program was
written as `typeid_of(T)` at a place where `T` was known, and at that place
`fields_of`, `enum_values_of`, and `variants_of` give the same members with
their types usable. A member table reached from an id alone serves only code
that kept the id and discarded the type, a registry, and a registry is filled
at a registration call that has the type. The table is then a second,
weaker spelling of compile-time reflection, kept in the runtime ABI, where
[`type` and `typeid`](design.md#type-and-typeid) fixes its layout and the
compiler rejects a `base:runtime` that differs. What must stay is what
printing a `typeid` and sizing erased storage need: `id`, `kind`, `name`,
`size`, `align`, `element`, `key`, and `count`. `bits` and `signed` go with
the members, since `kind` and `size` say both for an integer. Going further
and deleting `type_info_of` is not available: `fmt` prints a `typeid` by its
name, which only a table by id supplies.

### 3.2 `@(initialized=count)` and uninitialized storage

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

**Third pass: recommend the primitive, with one correction.** How the
attribute is used decides it. `Small_Array` is the only declaration that
counts a prefix. The other three, `Ring_Slot` in `core:thread`, the thread
`Start` block, and `Shared_Block` in `base:runtime`, each write

```loke
@(initialized = live) item: [1]T,
live: int,
```

a one-element array and a count that is 0 or 1, to say that a slot may hold
no value. That is `Uninit(T)` spelled through a prefix, at the price of a
word that a strong count or a pair of ring indices already makes redundant.
`Deque` could not use the attribute at all, since its live elements wrap, and
holds them in the capacity of a dynamic array whose length stays zero. So the
language has one need, storage for a `T` that holds no value, and the
attribute meets one shape of it natively, a second by encoding, and a third
not at all. `Uninit(T)` meets all three, and an inline hash set or ring
besides.

The correction: `Uninit(T)` cannot be "trivially copyable as bytes". A record
holding `[N]Uninit(string)` and no hooks would then copy its owners bit for
bit and release them twice. It is copyable only where `T` has a trivial
lifecycle, as Rust's `MaybeUninit<T>` is `Copy` only where `T` is; for any
other `T` a record that holds one has no generated copy and says so, by the
rule that [a record with a drop hook says how it is
copied](design.md#lifecycle-hooks-and-resource-types). Its drop does nothing.
It must also carry what `T` borrows and the regions `T` is in, which is why
`Deque` could not hold a `[^]T`: a stored borrow has to stay tracked.

What it costs beyond the first draft's list: `Small_Array` writes five members
by hand, `hook(copy)`, `hook(drop)`, `==`, `hash`, and `format`, each a loop
over a view of the live prefix, with the copy's cleanup in an `errdefer`. What
it removes: the attribute, its count check in every generated operation, the
`live` fields, and one of the five unchecked syntax forms of
[The `unsafe` package](design.md#the-unsafe-package), since `unsafe.write`,
`unsafe.take`, and a view of initialized slots are named operations on a type.

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
| `(dyn Drawable)(&circle)` | Conversion of a composite type is C-cast-like | Keep. `T(v)` with a parenthesized composite type is one rule for every conversion, and the alternative (`as`) is a keyword |

**Third pass: `a[mut lo:hi]`.** The problem is larger than the parentheses.
`&a[0:2]` is rejected, "`&` needs an addressable operand", and so is
`&mut a[:].len()` ([Probes](#probes)): a slice expression is a value, not a
place. `&mut a[lo:hi]` is therefore not the address operator applied to
anything. It is a second slicing form that borrows the operator's spelling,
and `&mut xs[i]` beside it is the real operator and yields a `^mut T`. Of the
two spellings the table offers, `a[mut lo:hi]` is the one to take. `mut` is
reserved, so nothing else can begin there; it puts the capability where the
type `[]mut T` puts it; it keeps mutation visible at the call, which is what
comments.md ["Mutable slicing is written
`&mut a[lo:hi]`"](comments.md#mutable-slicing-is-written-mut-alohi) asks of
the form; and it selects between `operator([:])` overloads by the written
form as today. A method `a.slice_mut()` would need a second way to say the
endpoints. The cost is a mechanical rewrite of every `&mut x[lo:hi]`, which
`lokec -migrate` can do, since the old form has no other reading.

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

**Third pass.** Both additions are better as general rules than as the two
special cases above.

- **`some I` is the static twin of `dyn I`, not a callable sugar.** `dyn
  proc(...)` is already defined as `dyn Callable(...)`. Define `some I(args)`
  in a parameter's type as a fresh inferred `$T` with the bare bound
  `I(T, args)`, and `some proc(...)` follows as `some Callable(...)` with no
  rule of its own. A reader then learns one pair, erased and dispatched
  through a witness or specialized per argument type, over one type syntax,
  and the opaque result that
  [Returning a capture literal](open-questions.md#returning-a-capture-literal)
  considers is the same word in the other position. Restricted to callables
  it would be a keyword bought for one interface.
- **Predeclare the catalogue by the test this review already applied.**
  [Withdrawn proposals](#withdrawn-proposals) kept `Allocator`, `Shared`, and
  `Weak` predeclared because the language's own rules name them. The same
  test covers the catalogue: `foreach` is defined over `Iterable` and
  `Iterator`, a `dyn proc` is a `dyn Callable`, a map key must be `Hashable`
  and `Equatable`, and a copy is `Cloneable`'s slot. Fourteen names join the
  predeclared scope, all shadowable. A project setting that imports `base:`
  unqualified would add an import form the language otherwise does not have.

### 4.3 Parsing decisions worth keeping

Parenthesized headers, mandatory braces, and explicit semicolons are the
choices that make Loke's grammar LL(k) with no composite-literal ambiguity
and no layout rule. They cost a token or two per statement and buy precise
errors (`expected ';'` at the exact position) and a formatter that never
re-flows. Every alternative (Go's automatic semicolons, Rust's unparenthesized
conditions with the literal restriction, Swift's layout) trades that for
appearance. Keep them.

The sixteen contextual keywords are a different matter. Each has a
disambiguation rule in [Resolved ambiguities](grammar.md#resolved-ambiguities)
that every tool must follow. `static` and
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

**Third pass: keep it until a returned construction transfers.** "Four
characters per return" is wrong for any value that owns something. `return
list;` transfers an owned local, and a wrapped return inherits that. `return
.ok(list);` is a variant construction, whose operand is copied like any
aggregate element: it clones `list` with warning `L0507`, and for a move-only
value it is error `L0503` until written `return .ok(move(value));`
([Probes](#probes)). Deleting the rule as proposed would turn every return of
an owner into that, or into a silent allocation.

The probe shows the asymmetry is there today, apart from success returns.
`return .err(list);` and `return Pair{list, 1};` clone a local at its last
use, where `return list;` moves it, because
[Last-use transfer](design.md#last-use-transfer) covers a binding or an
assignment and not an aggregate element. So the failure path and a record
result already pay what the success path is spared. The smaller rule that
fixes this is one sentence: an owned local or `move` parameter named as an
operand of the construction a `return` returns transfers as it would if
returned itself. That is worth adopting whatever happens to success returns.
With it, deleting them does cost four characters, and the deletion can be
judged on what is left: a rule that decides by syntactic form, and the fact
that `return 5;` wraps where `x: Option(int) = 5;` is an error
([Probes](#probes)), so the wrapping is a property of one statement and not of
the type. This review would still delete it then; without the transfer rule
it should stay.

## 5. Deletion candidates

For a general-purpose language, whether a feature is used in this repository
decides nothing; what decides is whether another feature already says the same
thing. Each row names the replacement and what is lost.

| Delete | Replaced by | Lost | Priority |
| --- | --- | --- | --- |
| The implicit splat of a typed scalar | Lane-wise operators take a scalar operand; `Simd(T, N)(x)` elsewhere; constant splats stay ([2.4](#24-coercions)) | A typed scalar as any vector argument, initializer, or result, so `take(scale)`, `simd.select(mask, v, scale)`, and `v: Simd(f32, 4) = scale`; `v * scale` stays. The lane-wise table gains a scalar operand in exchange | Low; an exchange of rules |
| `@(initialized=count)` | `Uninit(T)` and written hooks ([3.2](#32-initializedcount-and-uninitialized-storage)) | `Small_Array`'s generated prefix-aware copy, drop, `==`, `hash`, and `format` | Recommended |
| `Type_Info.members`, `Member_Info`, `Member_Kind`, `bits`, `signed` | `fields_of` and `variants_of` at compile time ([3.1](#31-runtime-reflection)) | Runtime reflection of a procedure type's parameter and result types; a member table reached from an id alone | Recommended |
| `&mut a[lo:hi]` | `a[mut lo:hi]` ([4.1](#41-forms-that-read-badly-and-fixes-that-keep-diagnostics-precise)) | The resemblance to `&mut x` | Recommended; needs `-migrate` |
| `inout` parameter mode and `self: inout` | `^mut T`, `&mut x`, `self: ^mut` ([2.5](#25-one-capability-axis)) | The marker on every mutated argument; carets on scalar and whole-value writes | Judgment call; leaning against |
| Success returns | `return .ok(n);` ([4.4](#44-rules-whose-text-is-longer-than-what-they-save)) | Today the transfer of an owned local, so `.ok(move(x))`; four characters once a returned construction transfers | Keep until then |
| `Option.ok_or` | `or_return .Variant` and a `switch` | An eager form for stored absences | Keep: a library method that costs the language no rule |

Not recommended for deletion, though a simplification pass might ask:
per-variant switch cases and union argument expansion (both are defined as
expansions of existing rules and earn their place in tree-walking code);
`delegate`; `hook(convert)`; `@(cpu_dispatch)`; `errdefer`; conditional
patterns; `Simd`; `Box`; `i128`/`u128` and `f16`; the wrapping operators;
`exchange`. Each is one rule that removes a class of boilerplate or a class
of bug.

## 6. Performance requiring language-design decisions

These proposals need changes to the language contract. Optimizations that
preserve the existing contract are in the [compiler optimization review](compiler-optimizations-2026-10-31.md#compiler-context).
The alias-attribute proposal also needs correctness fixes and holds only under
the `abort` panic strategy.

### 6.1 Alias attributes from facts the checker already proves

The emitter writes `nonnull` on pointer parameters and nothing else
(`param_nonnull` in `src/emit_llvm_abi.odin`); the IR for a `[]int` or
`[]mut int` parameter is a two-word struct with no attribute at all
([compiler review probes](compiler-optimizations-2026-10-31.md#probes)). [Performance opportunities and actual semantic limits](#performance-opportunities-and-actual-semantic-limits)
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
already handles the example slice ([Small values and the existing ABI](compiler-optimizations-2026-10-31.md#small-values-and-the-existing-abi)).
The gain is the usual one for `noalias`: loads hoisted out of loops
across stores, vectorization of loops that write through one slice and read
another, and fewer reloads around calls. Expect it to be modest: the
checked-arithmetic branches of [Checked arithmetic and bounds in loops](compiler-optimizations-2026-10-31.md#checked-arithmetic-and-bounds-in-loops)
block vectorization first, and LLVM's loop vectorizer already versions a loop
with a runtime overlap check, so on slices `noalias` mostly saves that check.
Scoped `!alias.scope` and `!noalias` metadata on the body's accesses would
express the same fact without changing the calling convention. Start with
`^mut T`, `inout`, and `self: ^mut` parameters, which are single pointers
today and need neither.

**Prerequisites.** The attributes turn a borrow the checker wrongly accepts
into undefined behavior that the optimizer exploits, so they come last:

- Close the soundness gaps first, or emit the attributes only behind an option
  until they are closed. When this was written, a call moving carriers between
  elements or fields and a borrow stored through a mutable traversal binding were
  accepted with two live mutable carriers to one place; both have since been
  fixed, as was a whole element copied through a view parameter, which a call
  did not see until 2026-11-01. On 2026-11-11
  [known-gaps.md](known-gaps.md#gaps) lists no borrow-checker gap; several
  were found and closed in the ten days before, so "none known" is a weaker
  statement than "none".
  Accepted programs like those alias as C code would; with `noalias` at
  `-opt=speed` they can miscompile.
- State an aliasing rule for unchecked code in design.md.
  [What is not checked](design.md#what-is-not-checked) makes raw pointers the
  programmer's responsibility but says nothing about aliasing, and the
  standard library drops provenance through `rawptr` casts, as `Channel`'s
  `queue_of` does
  ([Public borrow contracts should stand on their own](#public-borrow-contracts-should-stand-on-their-own)).
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
  [Later concurrency extensions](#later-concurrency-extensions),
  would need the same effect.
- Measure before building. After
  [Checked arithmetic and bounds in loops](compiler-optimizations-2026-10-31.md#checked-arithmetic-and-bounds-in-loops), add the attributes by hand
  to the `bench/` kernels' IR, as the probe does, and build the emitter
  support only if the gain under `-panic=abort` justifies a second set of
  optimization semantics.

**Third pass: scoped metadata works under `unwind`.** The paragraph above
mentions `!alias.scope` and `!noalias` metadata as a way to avoid changing the
calling convention. It is more than that: it is the form of the fact that
survives the default panic strategy. A `noalias` parameter says that nothing
else reaches the pointee while the procedure runs, the panic call included,
and that is the part `unwind` breaks. Metadata on a load and a store says only
that those two accesses do not overlap. The panic call carries none, so LLVM
keeps treating it as reading everything, and no store before it is dead.

Two probes with Clang 22 at `-O2` ([Probes](#probes)) bear this out. The
`fill` program that prints `drop sees 0` with a `noalias` parameter prints
`drop sees 3` with the same fact written as metadata on its accesses. And in
a kernel `dst[i] = src[i] +% k^` over a `[]mut int`, a `[]int`, and a `^int`,
the unannotated loop reloads `k^` after every store and stays scalar, while
the loop with the store in a scope that the loads exclude loads `k^` once
and is vectorized.

This changes the proposal's shape:

- Emit the metadata on accesses through checked carriers, under both panic
  strategies. There is then one set of optimization semantics, not a second
  one for `-panic=abort`, and the slice convention stays as it is.
- An access through a `rawptr`, a C pointer, or a pointer of unknown
  provenance gets no metadata and may alias anything. The rule for unchecked
  code shrinks to what [What is not checked](design.md#what-is-not-checked)
  nearly says already: unchecked code may not make two checked carriers that
  break the one rule. A cast that only drops provenance, as `queue_of` does,
  needs no audit.
- What metadata cannot give is what `noalias` gave across a call: a callee
  that is not passed the pointer is still assumed to reach the pointee. That
  remainder is the only part left for `-panic=abort`, and it is unlikely to
  be worth a second mode.
- The soundness prerequisite is unchanged. An accepted program with two live
  mutable carriers to one place is miscompiled by either form.

The measurement step stays first, with metadata in place of the attribute.

### 6.2 Union layout

The open item on compiler-chosen union layout
([Performance opportunities and actual semantic limits](#performance-opportunities-and-actual-semantic-limits))
is endorsed: `Result(Option(T), E)` and a `Result(Small, Enum)` should fit
their niches, with `@(repr=...)` for a stable layout where foreign code or
serialization needs one.

**Third pass: reconcile the two documents first.** The proposal has a cheap
half and a costly half. The cheap one is a disagreement that exists today.
[Representation](design.md#representation) promises a payload region followed
by a tag, and [Compile-time reflection](design.md#compile-time-reflection)
says a variant's `index` "is also its tag".
[releasing.md](releasing.md#version-policy) says that "non-C-ABI layout" may
change between releases, and also that compatibility covers what design.md
specifies. A union's layout is both. Checked code observes none of it but the
size: a union is not [foreign-ABI-safe](design.md#foreign-abi-safe-types)
apart from the `Option` of a non-null reference, and `unsafe.transmute`
already gives a union no compile-time meaning.

The first step is therefore to make design.md say which it is. This review
would mark the layout and the tag values as the compiler's, and keep three
guarantees:

- a union's size and alignment are constants of a build;
- the null niche, which foreign bindings rely on;
- a union's zero value is all-zero bytes. `@(zero=name)` must name the first
  variant so that "the union's zero stays the all-zero representation every
  other zero is"
  ([Zero values and `@(zero=)`](design.md#zero-values-and-zero)), and zero
  filling depends on it.

That costs no compiler work and no `@(repr)`, which can wait for the first
program that needs a stable layout.

**What is lost.** A program can no longer rely on a union's size from one
compiler release to the next, in a `static_assert` for instance, or on its
bytes in a run-time `unsafe.transmute` or a memory dump. The other way to
reconcile the documents, keeping the layout specified and saying so in
releasing.md, keeps those and gives up the niches.

**What is gained is modest.** The null niche already covers the large case:
`Option` of a pointer, a `Box`, a `Shared`, a procedure value. What remains
is `Option(bool)`, `Option` of an enum, and a nested `Result`, where padding
often takes back the byte a niche saves. Choosing those niches is an
optimization to measure, on the compiler review's terms, and nothing about it
is urgent: releasing.md already excludes this layout from what a release
promises. An earlier draft of this paragraph, the same day, claimed that each
release made the layout harder to change and named the null niche as the only
guarantee to keep. Both were wrong.

The [small-value ABI observations](compiler-optimizations-2026-10-31.md#small-values-and-the-existing-abi)
need no language change and are recorded in the compiler review.

## 7. The specification itself

Both proposals below are adopted: [Analysis
guarantees](design.md#analysis-guarantees) is the appendix, and it holds the
provenance precision and tracking rules. The programmer-facing text did not reach
half its length, since the rules on reborrows, escape levels, and retention that
carry examples stayed with the chapter they explain.

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
- **Keep the required-diagnostics table.** It is unusual in a language
  specification and valuable; the proposals above would shorten it rather
  than lengthen it.

## 8. Suggested order

Each step is independent of the others unless noted, and each is a spec,
compiler, test, and changelog change in one commit as AGENTS.md requires. The
steps that have landed are under [Adopted proposals](#adopted-proposals).
The independent compiler work has its own [suggested order](compiler-optimizations-2026-10-31.md#suggested-order).

The order after the third pass, cheapest first:

1. Specification only, with no urgency: make design.md and releasing.md agree
   about union layout ([6.2](#62-union-layout)). The step's other half, the
   conversion list for an unfixed constant and a distinct type, is done
   ([Adopted proposals](#adopted-proposals)).
2. A returned construction transfers an owned local operand
   ([4.4](#44-rules-whose-text-is-longer-than-what-they-save)). It removes
   clones the failure path and record results make today, and it is what
   deleting success returns would wait for.
3. `Uninit(T)` in place of `@(initialized)`
   ([3.2](#32-initializedcount-and-uninitialized-storage)), moving the four
   library declarations with it, and shrink `Type_Info`
   ([3.1](#31-runtime-reflection)).
4. `a[mut lo:hi]`
   ([4.1](#41-forms-that-read-badly-and-fixes-that-keep-diagnostics-precise))
   and the reserved `static` and `thread_local`
   ([4.3](#43-parsing-decisions-worth-keeping)), together, since both need
   `lokec -migrate`.
5. Predeclare the catalogue, then decide `some I`
   ([4.2](#42-verbosity-hotspots)); the first shortens every bound, so the
   second is judged on what remains.
6. Alias facts ([6.1](#61-alias-attributes-from-facts-the-checker-already-proves)).
   The read effect is in place and no borrow-checker gap is known. After the
   compiler review's
   [checked-arithmetic work](compiler-optimizations-2026-10-31.md#checked-arithmetic-and-bounds-in-loops),
   measure by adding scoped alias metadata by hand to the `bench/` kernels'
   IR. If that pays, emit it for accesses through checked carriers under both
   panic strategies. No `noalias` parameters under `unwind`, and no capture
   attributes: LLVM infers them for internal procedures.
7. If the splat is narrowed at all ([2.4](#24-coercions)), on its own and
   late: it exchanges a conversion for an operator rule and removes nothing
   harmful. It first needs the scalar form of `Simd(T, N)(x)` stated as a
   rule of its own.
8. If `inout` is folded into `^mut T` at all ([2.5](#25-one-capability-axis)),
   last: it is the largest surface change, and it needs `lokec -migrate` able
   to rewrite call sites and receivers mechanically. The explanation in
   [Capabilities and the one rule](design.md#capabilities-and-the-one-rule)
   is written.

## Adopted proposals

These were proposed by this review and have landed; the specification and
CHANGELOG.md describe the result. Reviews of the commits recorded their open
findings in open-questions.md and known-gaps.md. Compiler-only changes are
listed under [Adopted optimizations](compiler-optimizations-2026-10-31.md#adopted-optimizations).

- **A procedure value converts to a distinct procedure type as written**
  (2026-11-11; [Implicit type conversions](design.md#implicit-type-conversions),
  [Distinct types](design.md#distinct-types), rationale under
  ["Distinct types"](comments.md#distinct-types)). The conversion was implicit
  in both directions and for a value held in a variable, which undid
  `distinct`: with `Less` and `Equal` over one signature, a `Less` reached an
  `Equal` parameter through any plain procedure type between them, while the
  direct conversion was `L0310` ([Probes](#probes)). It existed for a narrower
  case. A named procedure or a procedure literal has the type of its
  signature, so without it only a written conversion could initialize a
  distinct procedure type; that is an unfixed constant's position, and the
  rule is now stated that way. `run(twice)` keeps working, as do fields,
  array elements, `return`, a success return, and `h == twice`. What is lost
  is the unwrapping direction: the type a distinct procedure type wraps has
  no name, so storing a `Handler` as a plain procedure is
  `(proc(n: int) -> int)(h)`, or shorter through an alias for the signature.
  Calling it and viewing it as `dyn proc` need no conversion. Three edges
  came from the implementation's probes. `Type.member` is a named procedure,
  and there is no other procedure constant: `ALIAS :: inc` is `L0341`, and a
  procedure group, a generic procedure, and an explicit instance of one are
  not values. A conditional expression between two named procedures is a
  value and converts as written. The written conversion crosses in one step
  to or from a signature that asks more of the caller, as the unwritten one
  does for a named procedure. `lokec -migrate` does not rewrite the two
  directions, since it works from the parse alone. `tests/run/dyn_proc.loke`
  and `tests/err/distinct_procedure_conversion.loke` pin the rule.
- **`using` is deleted** (2026-11-11; [Structs](design.md#structs), rationale
  under ["Promoted struct fields"](comments.md#promoted-struct-fields)). A
  field no longer promotes its own fields, so the contextual keyword, the
  rule for which name wins and when a selector is ambiguous, and the "not
  flattened" exception in destructuring and `foreach` bindings are gone. Odin's
  `using` earns its rules by making the outer struct usable where the inner
  one is expected; Loke had kept the rules without that, so no narrower form
  was left to fall back to. What is lost is one selector per access, and
  moving a field into a nested struct without editing the code that reads it.
  `using name: T` is now `L0241`, naming the removed form, and a selector
  that relied on it is `L0363`. `lokec -migrate` does not rewrite either,
  since the rewrite needs the checker's resolution of each selector and
  `-migrate` works from the parse alone. `tests/syntax_err/using_field.loke`
  and `tests/err/nested_field_selector.loke` pin both diagnostics.
- **An unfixed constant converts to a distinct type** (2026-11-11;
  [Implicit type conversions](design.md#implicit-type-conversions),
  [Distinct types](design.md#distinct-types), rationale under
  ["Distinct types"](comments.md#distinct-types)). The compiler already did
  this and the list did not say so, which the third pass's probe of
  [2.4](#24-coercions) found; the change is to the specification, with
  `tests/run/distinct_unfixed_constant.loke` and its `tests/err` counterpart
  pinning what converts and what does not.
- **A record's attributes are on its declaration, and `move_only` is one of them**
  (2026-11-02; [Attributes](design.md#attributes), [`@(move_only)`](design.md#move_only),
  rationale under ["A record's attributes are on its
  declaration"](comments.md#a-records-attributes-are-on-its-declaration)). A nominal
  `union` or `enum` is now only a constant's value, as a `struct` was, and `@(move_only)`
  reaches a union. The rewrite the proposal required is
  [`lokec -migrate`](compiler-guide.md#common-options), a flag of its own rather than
  part of `-fmt`, which keeps its promise to move only whitespace. The IR of every program
  in `examples` and `bench` was byte-identical before and after the corpus moved.
- **The specification is stated once, and without the library** (2026-11-02). An
  editorial change, with no change to what a program means.
  [Inferred effects](design.md#inferred-effects) defines how effects are computed,
  one sentence defines taking a value [as an initialization
  does](design.md#value-semantics-and-the-ownership-rule),
  [Calling a value](design.md#calling-a-value) holds the `Callable` rule, and
  [Analysis guarantees](design.md#analysis-guarantees) holds what an analysis must
  prove. [standard-library.md](standard-library.md) now specifies printing,
  `core:slice`, `core:container`, `core:simd`, `core:sync`, `core:mem`'s regions, the
  interface catalogue, and the compiled log level.
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
  between two types, and [6.2](#62-union-layout) endorses
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

Programs compiled to confirm claims the review still depends on. The
address-comparison probe was run again on 2026-11-01 with `lokec.exe` built
from the sources at `4173b622`. The emitted-IR, reassigned-slice, and
register-passing observations are in the compiler review's [Probes](compiler-optimizations-2026-10-31.md#probes).

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

**`noalias` under the `unwind` strategy.** On 2026-11-01 the `lokec.exe` in
the repository root, at `5580637f`, emitted IR for this program with
`-emit-ll`:

```loke
package main;
import "core:fmt";

@(move_only) Box :: struct { n: int }

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

On 2026-11-11 the probe was repeated with Clang 22. The listing above now
carries the `@(move_only)` that the 2026-11-01 run did not need: a record with
a drop hook says how it is copied, and is `L0747` otherwise. The two results
were the same, and a third
build, with no `noalias` and the fact written as metadata instead, kept the
store: `!alias.scope` on the load and the store through `b`, and `!noalias`
naming that scope on the load through `xs`.

```text
as emitted:            drop sees 3
with noalias:          drop sees 0
with scoped metadata:  drop sees 3
```

**Scoped metadata removes a reload and lets a loop vectorize.** For

```loke
add_into :: proc(dst: []mut int, src: []int, k: ^int) {
	foreach (i in 0 ..< dst.len()) { dst[i] = src[i] +% k^; }
}
```

the emitted IR was optimized by Clang 22 at `-O2` twice, with `add_into`
marked `noinline`: as emitted, and with `!alias.scope` on the store to `dst`
and `!noalias` naming that scope on the loads from `src` and `k`. LLVM
specialized the one call's length of four in both. As emitted, the body is
four scalar adds, each after a fresh `load` of `k`. With the metadata it
loads `k` once and does two `<2 x i64>` adds.

**The third pass's language probes**, all with `lokec` 0.9.0 built at
`41c0e2d4`:

- *A typed scalar splats in every position.* With `scale: f32`,
  `take(scale)` for a `Simd(f32, 4)` parameter, `c: Simd(f32, 4) = scale`,
  and `return x;` from a procedure returning `Simd(f32, 4)` are all accepted
  and print `[2.0, 2.0, 2.0, 2.0]`.
- *A distinct procedure type converts both ways, for values too.* With
  `Handler :: distinct proc(n: int) -> int`, a named `twice`, and
  `f: proc(n: int) -> int = twice`, all of `h: Handler = twice`,
  `h2: Handler = f`, `g: proc(n: int) -> int = h`, `run(f)` for a `Handler`
  parameter, and `plain(h)` for a plain one are accepted.
- *An unfixed constant initializes a distinct type.* `m: Meters = 3;` with
  `Meters :: distinct f64` and `i: Id = 7;` with `Id :: distinct int` are
  accepted. So are a literal as an argument, a returned value, an operand of
  `<` or `==`, and an array literal's element; a named unfixed constant; and
  a literal for a distinct `string` or `bool`. A typed variable is `L0310`,
  and `s: Small = 300;` with `Small :: distinct u8` is `L0352`.
- *Only `return` wraps.* `return 5;` in a procedure returning `Option(int)`
  is accepted; `x: Option(int) = 5;` is ``L0352: 5 is not representable by
  `Option(int)` ``.
- *A returned construction clones.* With `list := [dynamic]int{};` as an
  owned local, `return list;` in a `Result([dynamic]int, E)` procedure is
  silent, and `return .ok(list);`, `return .err(list);` in a
  `Result(int, [dynamic]int)` one, and `return Pair{list, 1};` each draw
  `L0507`, "clones `list`, which may allocate". For a `@(move_only)` record
  `return .ok(o);` is `L0503`.
- *`&mut a[lo:hi]` is not the address operator.* For `a: [4]int`,
  `&a[0:2]` is ``L0357: `&` needs an addressable operand``, and so is
  `&mut a[:].len()`.
- *A `self: ^mut` method is reported as missing.* With
  `bump :: proc(self: ^mut Counter)` in `impl Counter`, `c.bump()` is
  ``L0363: `Counter` has no field or member `bump` ``.

**The step 3 review's probes**, with `lokec` 0.9.0 built from a modified tree
at `267ab0f9`:

- *A typed scalar splats under every operator form, and in a library call.*
  With `x: f32` and `v: Simd(f32, 4)`, all of `v < x`, `v *= x`, and
  `simd.select(mask, v, x)` are accepted.
- *The explicit scalar form takes the lane type only.* `Simd(f32, 4)(x)` is
  accepted and prints `[2.5, 2.5, 2.5, 2.5]`. `Simd(i32, 4)(x)` is
  ``L0373: `f32` cannot be converted to `Simd(i32, 4)` ``, and
  `Simd(f32, 4)(i)` with `i: i32` is the same diagnostic for its types.
- *A distinct procedure value is called and viewed without unwrapping.* With
  `h: Handler = twice`, all of `h(4)`, `call(h)` for a
  `dyn proc(n: int) -> int` parameter, and
  `view: dyn proc(n: int) -> int = h` are accepted.
- *A named procedure converts to a distinct type over a stricter signature.*
  With `Keeper :: distinct proc(destination: inout Holder, @(escape=stored)
  values: []int)` and an `ignore` that declares no escape level, `k: Keeper =
  ignore` and `run(ignore)` for a `Keeper` parameter are accepted.

**The distinct-procedure change's probes**, with `lokec` 0.9.0 built at
`61b746a3` for the first two and from the changed tree for the rest:

- *A plain procedure type laundered one distinct type into another.* With
  `Less` and `Equal` both `distinct proc(a, b: int) -> bool` and `l: Less`,
  `use_equal(l)` for an `Equal` parameter was `L0310`, and `through(l)`, where
  `through` takes a `proc(a, b: int) -> bool` and passes it to `use_equal`,
  compiled and ran.
- *A generic procedure pattern never took a distinct procedure value.* With
  `op: Op`, `apply(op, 1)` for a parameter `proc(x: $T) -> T` was `L0392`,
  "`Op` does not match the shape of parameter 1", while the
  `dyn proc(x: $T) -> T` form accepted it, and still does.
- *Named procedures and literals are the only procedure constants.*
  `ALIAS :: inc;` is `L0341`, `a: Op = group;` for a procedure group is
  `L0396`, `b: Op = identity;` for a generic procedure is `L0431`, and
  `identity(int)` is not a value. `Table{inc, Counter.bump}` for two `Op`
  fields is accepted.
- *The narrowed rule.* With `f := inc` and `op: Op = inc`, each of
  `a: Op = f`, `b: proc(n: int) -> int = op`, `plain(op)`, `only_op(f)`,
  `slot = f`, `return f;` from a procedure returning `Op`,
  `d: Op = stored` for a literal held in a variable, and
  `e: Op = inc if flag else dec` is `L0310`, and `op == f` is `L0354`.
  `Op(f)`, `(proc(n: int) -> int)(op)`, `Fn(op)` through an alias,
  `Op(inc if flag else dec)`, `op == inc`, `return inc;` from a procedure
  returning `Option(Op)`, and `many(inc, inc, lit)` for a `..Op` pack are
  accepted. With the `Keeper` of the step 3 review, `Keeper(value)` for a
  variable holding `ignore` is accepted too.

**A callee reading a global it holds `^mut` to** was accepted by the same
compiler; the [read effect](design.md#global-write-effects) now rejects it.
With `noalias` added by hand it still printed `1` and `2` at `-O2`, so the
probe shows a broken contract, not a miscompilation.

## Language design review (2026-10-03)

The earlier review this one builds on, moved here from open-questions.md.
Proposals from a review of the specification, not amendments to it; backward
compatibility was not a constraint. In the order the review suggested:
compiler-selected union layout and written borrow contracts first, then unchecked
operations at their use and checked thread transfer. Try each on a parser, a resource container, a partitioning
algorithm, and a parallel numeric kernel before deciding.

### Put unchecked obligations at their operation

The current [unsafe boundary](design.md#the-unsafe-package) is a file import.
Once a file imports `core:unsafe`, every unchecked pointer conversion and
C-pointer access in it is permitted, not only the one that needed it. Most
unchecked operations are already named at their use (`unsafe.raw_data`,
`unsafe.take`); the syntax forms are the exception. `x: T = ---` and
`@(initialized)` storage now need the import too.

**Proposal:** add a lexical `unsafe { ... }` boundary for unchecked pointer
use and unchecked calls. An unsafe procedure declaration should mean that its
caller owes a stated precondition; an ordinary wrapper can establish it
internally. The spelling is proposed syntax, not syntax accepted today. It
pays once a library exposes a procedure with a caller-owed precondition; none
outside `core:unsafe` does yet, and the files that import `core:unsafe` are
mostly OS wrappers that would wrap nearly every procedure.

Raw pointer constness is a separate idea: a C pointer currently loses both
provenance and read-only capability. Consider `[^]T` for read-only foreign
access and `[^]mut T` for writing, with an unchecked cast required to
strengthen capability. It would change every foreign signature in `core`, and
foreign pointer use would still require lifetime and bounds obligations;
constness alone does not establish either.

**Third pass (2026-11-11).** Neither half is recommended as written, and each
has a smaller form.

- *No `unsafe { ... }` block yet.* Its one use that the file import cannot
  serve is a caller-owed precondition, and no library exports one. What can be
  done now is to shrink the syntax that the import licenses.
  [The `unsafe` package](design.md#the-unsafe-package) lists five unchecked
  forms that are syntax rather than named members. `Uninit(T)`
  ([3.2](#32-initializedcount-and-uninitialized-storage)) turns the
  `@(initialized)` field into named operations on a type, leaving the three
  pointer forms and `x: T = ---`, each of which already shows a C pointer, a
  `rawptr`, or `---` at its use. A file-wide permission over four forms that
  are visible where they occur is close to what the block would give.
- *Constness is mostly expressible already.* `^T` and `^mut T` are
  foreign-ABI-safe and lower to C pointers, with `Option` for a nullable one
  ([Foreign-ABI-safe types](design.md#foreign-abi-safe-types)), so a binding
  can spell `const T *` to one object today. What `[^]mut T` would add is a
  read-only *array* pointer, `const T *` with a length beside it. That is a
  narrower gain than the proposal implies, against a change to every foreign
  signature in `core`.

### Performance opportunities and actual semantic limits

Fast programs are expressible: fixed arrays, slices, arena-backed owners,
monomorphized generics, static iteration, explicit moves, and `Simd(T, N)`.
What remains open is where the compiler could do more without changing a
specified result:

- **Union layout.** Null already encodes `.none` in an `Option` over a
  non-null reference ([Representation](design.md#representation)); every
  other union has a fixed payload-plus-tag layout. Making an ordinary union's
  layout the compiler's choice would allow other niches and a compact nested
  `Result(Option(T), E)`, keeping `size_of`, alignment, reflection, and the
  ABI within a build accurate, with an explicit representation where a
  stable tag and layout are needed for serialization or foreign code.
- **Alias attributes.** The emitted IR spells no general `noalias` or
  `readonly` parameter attributes. Read-only capability alone does not
  promise that memory cannot change, since atomics write through read-only
  receivers and foreign or unchecked aliases need their own contract, so each
  attribute needs [LLVM's precise obligations](https://llvm.org/docs/LangRef.html#parameter-attributes)
  shown to hold. `noalias` is unsound under the `unwind` strategy, whose
  cleanup reads callers' locals while the callee is still executing, and LLVM
  already infers the capture attributes; see
  [design review 6.1](#61-alias-attributes-from-facts-the-checker-already-proves).
- **Explicit reductions.** A floating-point sum is ordered, and the default
  arithmetic stays strict. Separately named reassociating or tree reductions,
  with their numerical differences documented, would let a kernel ask for the
  faster order.
- **Copy elision.** Which implicit copies of a type with a custom clone or
  drop may be elided is unspecified, so none is.
- **Container fast paths.** An optimized build links the runtime as bitcode
  ([compiler review](compiler-optimizations-2026-10-31.md#container-operations-in-ir-not-through-an-operation-table),
  [adopted bitcode linking](compiler-optimizations-2026-10-31.md#adopted-optimizations)),
  but in `bench/collections.loke` LLVM still calls `dyn_append`,
  `dyn_reserve`, and `map_find` out of line from the hot loops, and
  `map_find` calls the key's `hash` and `==` through the operation table. The
  review's remaining proposal, fast paths emitted in the module per element type,
  remains the way to remove those calls; its cost is a second implementation
  of the probe sequence.

Some transformations are forbidden outright: reordering floating-point
additions into another tree, fusing `a*b + c`, or hoisting a possible panic
above an earlier observable write. Vectorizing independent iterations, proving
checks cannot fail, and runtime alias checks stay available. A general purity
or effect language is not to be added only to request faster code.

### Public borrow contracts should stand on their own

[Procedure result contracts](design.md#procedure-result-contracts) can capture
precise dependencies, but `type_of(procedure)` ties a public callback contract
to that procedure's inferred body. A handwritten procedure type loses details;
`@(escape=none)` excludes whole arguments but cannot name a specific result
field's source or every allocator dependency.

**Proposal:** add a small written result-source contract, with syntax to be
designed, that says a result borrows specified parameter paths or is backed by
a named allocator parameter. Check the body against it. Keep inference as the
default for local helpers and an IDE/documentation aid.

This lets changing an implementation preserve its declared public contract,
and permits callbacks without manufacturing a reference implementation solely
to use its `type_of`. It can also reduce dependence on whole-program inference
as separate compilation develops. It does not require lifetime variables on
every local declaration.

The [minimum provenance budgets](design.md#minimum-provenance-precision) are
another source of surprises: four projection steps, eight distinguished fixed
array elements, and four constant map keys. A harmless wrapper or extra entry
can turn accepted code into a conservative rejection. Keep diagnostics naming
the limit, add acceptance tests just beyond each boundary, and make written
contracts/disjoint primitives reduce dependence on inferred shape. Raising
numeric limits alone does not solve this architectural issue.

A library getter whose result is rebuilt from untracked storage meets the same
gap from the other side. The rebuilt pointer has unknown provenance, which
proves nothing, so no declaration says that the result borrows its receiver.
The compiler asserts it for `Shared(T).get` alone; `Monitor_Guard.read` calls
through a plain procedure type instead, whose result derives from every
borrowed argument, so the borrow ends with the guard. A channel meets the
opposite case: an item taken out of its queue through a guard would look like a
borrow of the guard, though items carry only process-lifetime borrows, so
`Channel` reaches its queue through a `rawptr` cast (`queue_of`) to drop that
provenance. `Deque.slots` goes through a plain procedure type for the same
reason as `Monitor_Guard.read`. A written contract could say all three, and
replace the `Shared` special case.

**Third pass (2026-11-11): say it in the body, not in the signature.** The
library cases above are one problem, and it is not a public contract. A
pointer rebuilt from raw storage has no provenance, and the author knows what
it borrows. Today the library says so by a trick that appears three times, in
`Deque.slots`, `Deque.ring_slots`, and `Monitor_Guard.read`:

```loke
slots :: proc(self: ^) -> []T {
	reach: proc(self: ^Deque(T)) -> []T = Deque(T).slots_of;
	return reach(self);
}
```

The helper is stored in a local of plain procedure type only so that the call
through it "conservatively derives from every borrowed argument"
([Procedure result contracts](design.md#procedure-result-contracts)). The
conservative fallback is being used as the mechanism, and `Shared(T).get`
gets the same result from a rule inside the compiler.

A named unchecked operation states it directly: `unsafe.borrowed(view, from)`,
say, returns `view` with the root and region provenance of `from`, as
`unsafe.raw_data` discards provenance and a conversion from `rawptr` asserts
an address. It is a promise like the rest of `core:unsafe`, it adds no syntax
to signatures, and with it the three helpers lose their indirection and
`Shared(T).get` can be library code. `Channel`'s `rawptr` cast already states
its half, dropping provenance, directly.

The written result contract is then left with the case that is truly about a
public type: a callback whose result borrows one field of an argument or one
allocator. For that, extend the vocabulary a parameter already has rather
than design a result-side language. `@(escape=none)` excludes a whole
argument today; the missing precision is a path, so that a level can be
written for `list.items` and not for `list`. Whether that case occurs often
enough to build is still unshown.

### Thread transfer needs a visible contract

[Structured concurrency](design.md#structured-concurrency) answers this for work
joined before its caller continues
([reasons](comments.md#tasks-that-borrow-joined-by-their-block)). Still open:

- A thread `core:thread`'s `spawn` starts outlives any scope, so it still
  takes only `@(escape=static)` arguments, and keeping a `thread_local` borrow
  past the end of its thread is still unchecked; see
  [What is not checked](design.md#what-is-not-checked).
- The [later concurrency extensions](#later-concurrency-extensions).
- Whether the [waiting design](standard-library.md#corethread), with paired
  channel setup and explicit monitor termination, holds up in use. Measure the
  monitor's wake-all cost and the join check's conservative rejections on real
  pipelines; neither justifies a purity effect system or interprocedural
  closed-state analysis without evidence. The join check tells two parameters
  apart by the object types they reach, which is coarse at primitive fields: a
  `[]mut int` parameter still conflicts with a kept sender, since a channel's
  state holds `int` fields. Whether a finer rule, for example one using field
  privacy, would accept enough real programs to pay for itself is unmeasured.

### Later concurrency extensions

None of these blocks what [Structured
concurrency](design.md#structured-concurrency) and
[`core:thread`](standard-library.md#corethread) already specify.

1. **Erased callables at a spawn.** A spawned call may go through a procedure
   value or a `dyn` view, and the effects follow the callbacks each call passes.
   A view that arrives erased, as a parameter or stored local, is checked
   through every type converted to its interface application (answered
   2026-10-27; see [Sharing with tasks](design.md#sharing-with-tasks)), and a
   call through it takes its slot's whole effect union. What remains is
   precision: one conversion of a mutable or thread-affine type anywhere rejects
   every erased view of that application, and one fill writing a global rejects
   every call through it. Public callable-effect contracts, which would bound
   both, need a separate demonstrated requirement.

   The same union lets a task read through a `dyn` stored in a global, except
   a `dyn fmt.Formattable`, which stays unknown since printing builds its
   witnesses after the effects. Two more precise directions are open: keeping
   the concrete type through a view stored in a local, which helps only
   locals, and a view type that promises its target may be shared with a
   task, a language extension with a public contract that needs a
   demonstrated requirement.
2. **Recoverable submission.** How to return arguments after failure to
   start a task, without confusing submission failure with worker failure.
3. **Richer result destinations.** Whether live replacement, fields, indices,
   destructuring, or an implicit conversion on the worker justify their
   evaluation, initialization, and cleanup rules. The initial form supports
   only dead outer locals of the call's exact result type.
4. **Channel items carrying borrows.** A later retention rule for the
   read-only `send` receiver; process-duration retention remains the initial
   contract. Also rendezvous channels and nondefault queue allocators.
5. **Blocking-aware pools.** Whether to compensate for waits or provide a
   separate executor. Fixed pools make only the limited progress guarantee
   [Pools](standard-library.md#pools) gives. Scoped submission is compiler
   lowering under the existing spawn borrow checks, not a public
   `@(cross_thread)` submission API for borrowed arguments.
6. **Provider and allocator thread contracts.** Whether a build-selected
   allocator or logging provider must declare that it accepts concurrent use,
   so the compiler checks it instead of trusting it. Whether an `Allocator`
   parameter can promise a concurrent region, so a library can share a
   caller's allocator among tasks.
7. **Timed waits.** `lock_when`, `send`, and `receive` with a deadline from
   `core:time`, reporting a timeout apart from closure. An audio loop that must
   play silence when a decoder falls behind needs them.
8. **Selective cancellation and choice.** A stop token that ends one waiter
   among several on the same object or coordinates cancellation across several
   objects, and a wait on whichever of several channels is ready first. The
   library requires explicit shutdown protocols for those groups.
9. **Unscoped channels.** Endpoints that own shared channel state instead of
   borrowing a local, for a thread `core:thread`'s `spawn` starts or a
   foreign audio callback, which only `@(escape=static)` values reach. The
   [join check](design.md#releasing-before-the-join) cannot follow them, since
   they borrow no root.
10. **Targeted wakeups.** A hint that wakes fewer of a monitor's waiters,
    where waking all of them costs more than their checks. It would narrow
    which waiters wake, not which changes they see.
11. **Blocking ring adapters.** Parking one endpoint and waking it from the
    other requires a proven registration/recheck handshake, closure-race
    handling, and an explicit account of kernel calls on the deadline-bound
    side. It is outside the polling ring's API; see
    [The ring algorithm](standard-library.md#the-ring-algorithm).
12. **Thread-affine values in globals.** A task may borrow a
    `@(thread_affine)` value stored in a plain global, as `window.handle` reads
    one. [Sharing with tasks](design.md#sharing-with-tasks) follows arguments,
    receivers, captures, and results, not globals, so this is not a divergence.
    Closing it needs a task check over the
    [read effect](design.md#global-write-effects), or a rule that rejects a
    global of a type that is or reaches one. A `Lazy` cannot hold one.

### Per-call effect precision

The write, reach, and allocator-use effects the task checks read are per call:
a call takes in the callbacks it passes, a local's possible values, and a
converted view's concrete target, and a `dyn proc` parameter or local is
followed as a procedure-typed one is. Three conservative limits remain:

- **A body's own calls of its parameters keep the type union.** A wrapper
  that spawns a callback it received, `spawn r = g(1)` with `g` a parameter,
  is checked inside the wrapper, where any procedure of `g`'s type may be
  passed, so it is rejected when any procedure of that type writes a global,
  whatever its callers pass. Following the spawn to each caller would need
  the task checks themselves to become a summary a call substitutes, as the
  `thread_local` write-back is; nothing yet shows a program needing it.
- **What a local may hold is flow-insensitive.** `f := tally; f = step;
  spawn r = f(1);` takes `tally`'s effects, since every value stored into a
  local counts wherever it is called. This is the existing resolution the
  `thread_local` write-back shares, and is conservative.
- **A held procedure binds its arguments as a union does.** A callable view
  converted at the call from a named procedure takes that procedure's whole
  effect, but its allocator use takes every argument's region for each
  parameter-backed region, as any call through a value does, rather than the
  argument at that parameter. A capture literal's `call` and a converted
  slot are direct calls and bind by parameter.

### Ring algorithm validation

[The ring algorithm](standard-library.md#the-ring-algorithm) is built as
written, and an exhaustive interleaving search under sequential consistency
found no violation. Two checks remain:

- **Weak-memory model checking.** The interleaving search treats every access
  as sequentially consistent, so it cannot find a missing release or acquire.
  A C11 model check with GenMC or a tool like it, over the same capacities,
  laps, and drop placements, is still needed.
- **Measurements.** Measure the closure check on every send, with the flags
  separated from the indices, and latency and throughput on the intended
  target. The spare slot is for simpler arithmetic, not demonstrated higher
  speed.

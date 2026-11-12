# Language design review (2026-10-31)

A review of the Loke language as [design.md](design.md) and
[grammar.md](grammar.md) specify it, looking for ways to make the language
smaller, more regular, and faster, rather than for features to add. It is
non-normative: each item is a proposal, not an amendment, and backward
compatibility is not a constraint. Each proposal says what it would cost, so
that it can be judged on its merits for a general-purpose language and not by
how often the repository happens to use what it removes.

This file holds only what is still open, as it stands on 2026-11-11 after
several passes over the proposals and reviews of the steps taken. Proposals
that landed are described by the specification, [CHANGELOG.md](../CHANGELOG.md),
and [comments.md](comments.md); earlier drafts and their reasoning are in git.
[Open items from the 2026-10-03 review](#open-items-from-the-2026-10-03-review)
carries what remains of the review this one built on. Optimizations that change
no specified behavior are in the
[compiler optimization review](compiler-optimizations-2026-10-31.md#compiler-context).

## Contents

- [Summary](#summary)
- [The shape of the language](#the-shape-of-the-language)
- [Recommended](#recommended)
- [Judgment calls](#judgment-calls)
- [Not recommended](#not-recommended)
- [Open items from the 2026-10-03 review](#open-items-from-the-2026-10-03-review)
- [Probes](#probes)

## Summary

Loke's individual decisions are well argued, and comments.md records the
argument for nearly every one. The problem is the sum: a specification of about
11,700 lines with 30 attributes, 21 implicit conversions, and 16 contextual
keywords. The pairs that said one thing twice, such as `Status` beside
`Result(Unit, E)` and `any_view` beside `dyn`, are gone. The pairs that remain
differ in ways that matter ([The shape of the
language](#the-shape-of-the-language)).

What is left, in the suggested order, cheapest first. Each step is a spec,
compiler, test, and changelog change in one commit, as AGENTS.md requires, and
is independent of the others unless noted.

| Step | Proposal | Removes | Loses | Verdict |
| --- | --- | --- | --- | --- |
| 1 | [`Uninit(T)` in place of `@(initialized)`](#uninitt-in-place-of-initialized) | An attribute, its count check in every generated operation, the `live` fields, one unchecked syntax form | `Small_Array`'s generated copy, drop, `==`, `hash`, and `format` | Recommended |
| 1 | [Runtime reflection describes shape](#runtime-reflection-describes-shape) | `Member_Info`, `Member_Kind`, `bits`, `signed` | Run-time member tables, including a procedure type's parameters and result | Recommended |
| 2 | [Mutable slicing as `a[mut lo:hi]`](#mutable-slicing-as-amut-lohi) | The `&mut`-before-slice grammar rule | The resemblance to `&mut x` | Recommended; needs `lokec -migrate` |
| 2 | [Reserve `static` and `thread_local`](#reserve-static-and-thread_local) | A four-case disambiguation rule | Those two words as names | Recommended; needs `lokec -migrate` |
| 3 | [Predeclare the interface catalogue](#predeclare-the-interface-catalogue) | `interfaces.` in every bound | Nothing; the names stay shadowable | Recommended |
| 3 | [`some I`](#some-i-the-static-twin-of-dyn-i), after the catalogue | The longest repeated `where` clause | One more contextual keyword; a generic procedure without a `$` | Judgment call, judged after the catalogue |
| 4 | [Alias facts as scoped metadata](#alias-facts-from-the-one-rule) | Reloads and runtime overlap checks | Nothing, if the borrow checker is sound | Measure first |
| 5 | [Narrow the splat](#the-splat-of-a-typed-scalar) | One conversion and two exceptions | A typed scalar as a vector argument, initializer, or result | Weakest; an exchange of rules |
| 6 | [Delete success returns](#success-returns) | A rule that decides by syntactic form | Four characters per return | Judgment call; this review would delete |
| 7 | [Fold `inout` into `^mut T`](#inout-and-mut-t) | A parameter mode and a receiver form | The marker on every mutated argument; carets on scalar writes | Judgment call; leaning against |

One finding is independent of any proposal: the standard library attaches
provenance to a rebuilt pointer by calling through a plain procedure type, using
a conservative fallback as a mechanism
([Public borrow contracts should stand on their
own](#public-borrow-contracts-should-stand-on-their-own)).

Except where a proposal's cost says otherwise, none of them changes what a Loke
program can express.

## The shape of the language

An inventory, counted from design.md and grammar.md on 2026-11-11:

| Area | Count | Where it is |
| --- | --- | --- |
| Reserved words | 32 | [Keywords](grammar.md#keywords) |
| Contextual keywords, each with a disambiguation rule | 16 | [Keywords](grammar.md#keywords) |
| Attributes | 30 | [Attribute categories](design.md#attribute-categories) |
| Implicit conversions | 21 | [Implicit type conversions](design.md#implicit-type-conversions) |
| Spellings of a sum type | 3 | `enum`, `union`, `(a: A \| b: B)` |
| Spellings of a product type | 3 | `struct`, `(a: A, b: B)`, `(A, B)` |
| Type-erasure mechanisms | 1 | `dyn I`, including `dyn proc` |
| Reflection tiers | 2 | `meta.*` descriptors, `runtime.Type_Info` |
| Mutable-borrow parameter modes | 2 | `inout T`, `^mut T` |
| Interface requirement forms | 4 | expression, validity, truth, slot |
| Overload-ranking levels and tie-breakers | 4 + 5 | [Operator lookup and overload resolution](design.md#operator-lookup-and-overload-resolution) |
| Inferred whole-program effects | 4 | write, reach, allocator-use, pooled-join TLS |
| Receiver forms | 4 | `self`, `self: ^`, `self: inout`, `self: move` |
| Yield modes | 4 | [Yield modes](design.md#yield-modes) |
| Lines in design.md | 11,709 | |

**The language is largest where it is most original.** Ownership, structured
concurrency, and the inferred effects are about a third of the specification,
and they are where Loke's value is: local borrow checking without lifetime
annotations, and tasks checked without `Send` and `Sync`. Simplifying there
means stating each mechanism once, which [Inferred
effects](design.md#inferred-effects) and [Analysis
guarantees](design.md#analysis-guarantees) now do, not removing it.

**The pairs that remain are not duplicates.** Read as type theory, Loke has sums
and products (nominal and structural), a two-point capability lattice on
borrows, affine types, existential packages (`dyn`), region-based memory, and
an inferred effect system. A simplification is a place where one of those has
two spellings. The places left are not that:

- `struct` is nominal and generative, and a record is structural; nominality is
  what pays for privacy, hooks, and field reordering
  (["Structs declare, parentheses describe"](comments.md#structs-declare-parentheses-describe)).
- `enum` and a union of payloadless variants share `variants_of` but keep
  separate surfaces, because a union's tag order is not API
  ([Not recommended](#not-recommended)). One kind for both inside the checker
  would be a compiler refactor, worth doing only for the code it removes.
- `inout T` and `^mut T` are the mutable column of the same table as `value: T`
  and `^T`: the caller's variable for the call, against a borrow held as a value
  ([`inout` and `^mut T`](#inout-and-mut-t)).
- `via` gives a declaration's fields and elements an allocator, which
  construction with an allocator does not ([Not recommended](#not-recommended)).

## Recommended

### `Uninit(T)` in place of `@(initialized)`

[Uninitialized capacity](design.md#uninitialized-capacity) couples a fixed
array field to a sibling `int` by attribute, so that the generated copy, drop,
equality, and formatting visit a counted prefix. Its uses show that the
language has one need, storage for a `T` that may hold no value, and that the
attribute meets it in only one shape:

- `Small_Array` is the only declaration that counts a prefix.
- `Ring_Slot` in `core:thread`, the thread `Start` block, and `Shared_Block` in
  `base:runtime` each write `@(initialized = live) item: [1]T, live: int`: a
  one-element array and a count of 0 or 1, to say that one slot may be empty.
  The `live` word is redundant beside a strong count or a pair of ring indices.
- `Deque` cannot use the attribute, since its live elements wrap, and holds
  them in the capacity of a dynamic array whose length stays zero.

**Proposal.** A type `Uninit(T)`, like Rust's `MaybeUninit`: storage of `T`'s
size and alignment that holds no value, written and read only through
`unsafe.write` and `unsafe.take`. A container holds `items: [N]Uninit(T)` and
writes its own hooks. Three rules make it sound:

- It is copyable only where `T` has a trivial lifecycle. Otherwise a record
  holding `[N]Uninit(string)` would copy its owners bit for bit and release them
  twice; such a record has no generated copy and says how it is copied, by the
  rule that [a record with a drop hook says
  so](design.md#lifecycle-hooks-and-resource-types).
- Its drop does nothing.
- It carries what `T` borrows and the regions `T` is in, so a stored borrow
  stays tracked. That is why `Deque` could not hold a `[^]T` instead.

**What it removes.** The attribute, its count check in every generated
operation, the `live` fields, and one of the five unchecked syntax forms of
[The `unsafe` package](design.md#the-unsafe-package), since writing, taking,
and viewing initialized slots become named operations on a type. It also serves
an inline hash set or ring.

**What is lost.** `Small_Array` writes five members by hand, `hook(copy)`,
`hook(drop)`, `==`, `hash`, and `format`, each a loop over a view of the live
prefix, with the copy's cleanup in an `errdefer`. That is one type's
convenience against an attribute every reader of a record must know.

### Runtime reflection describes shape

`runtime.Type_Info` carries a `members` table of fields, enum values, union
variants, and a procedure type's parameters and result. Since `any_view` was
deleted, no value carries a `typeid`: every `typeid` was written as
`typeid_of(T)` where `T` was known, and there `fields_of`, `enum_values_of`, and
`variants_of` give the same members with their types usable. A table reached
from an id alone serves only code that kept the id and discarded the type, such
as a registry, and a registry is filled by a call that has the type. Printing
does not read the table: the printers call each view's `format` slot.

**Proposal.** Keep `id`, `kind`, `name`, `size`, `align`, `element`, `key`, and
`count`, which printing a `typeid` and sizing erased storage need. Delete
`members`, `Member_Info`, and `Member_Kind`, and with them `bits` and `signed`,
which `kind` and `size` already say for an integer. State that runtime
reflection describes shape, not members. [`type` and
`typeid`](design.md#type-and-typeid) fixes the table's layout in the runtime
ABI, so the change shrinks that too. `type_info_of` itself stays: `fmt` prints a
`typeid` by its name, which only a table by id supplies.

**What is lost.** The only reflection of a procedure type's parameter and result
types, which comments.md
["Reflection beyond fields and enum values"](comments.md#reflection-beyond-fields-and-enum-values)
says no tool has needed. A serializer that needs run-time member tables can
build them from `fields_of` in a static `foreach`.

### Mutable slicing as `a[mut lo:hi]`

`(&mut a[:]).indexed()` needs parentheses for a member of the result, and the
`&` in it is not the address operator: `&a[0:2]` and `&mut a[:].len()` are both
"`&` needs an addressable operand", since a slice expression is a value, not a
place ([Probes](#probes)). `&mut a[lo:hi]` is a second slicing form that borrows
the operator's spelling, beside `&mut xs[i]`, which is the operator and yields
a `^mut T`.

**Proposal.** Spell it `a[mut lo:hi]`. `mut` is reserved, so nothing else can
begin there; it puts the capability where the type `[]mut T` puts it; it chains
like every other postfix; it keeps mutation visible at the call, which is what
comments.md ["Mutable slicing is written
`&mut a[lo:hi]`"](comments.md#mutable-slicing-is-written-mut-alohi) asks of
the form; and it selects between `operator([:])` overloads by the written form
as today. A method `a.slice_mut()` would need a second way to write the
endpoints. grammar.md loses the `&mut`-before-slice rule.

**What is lost.** The resemblance to `&mut x`. Every `&mut x[lo:hi]` changes,
which `lokec -migrate` can rewrite, since the old form has no other reading.

### Reserve `static` and `thread_local`

Each contextual keyword has a disambiguation rule in [Resolved
ambiguities](grammar.md#resolved-ambiguities) that every tool must follow, and
the rule for `static` and `thread_local` has four cases. As reserved words they
need none: no program needs a type named `static`, and a keyword may still name
a field or member ([Predeclared names](design.md#predeclared-names)). Land it
with `a[mut lo:hi]`, since both need `lokec -migrate`.

### Predeclare the interface catalogue

Nearly every generic procedure names an interface from the catalogue, and must
qualify it: `where interfaces.Iterable(C)`. The test that keeps `Allocator`,
`Shared`, and `Weak` predeclared, that the language's own rules name them,
covers the catalogue too: `foreach` is defined over `Iterable` and `Iterator`,
a `dyn proc` is a `dyn Callable`, a map key must be `Hashable` and `Equatable`,
and a copy is `Cloneable`'s slot.

**Proposal.** Predeclare the fourteen catalogue interfaces. A predeclared name
may be shadowed, so a program's own `Iterable` keeps working. The alternative, a
project setting that imports `base:` unqualified, would add an import form the
language otherwise does not have.

### Alias facts from the one rule

The emitter writes `nonnull` on pointer parameters and nothing else, and a
slice parameter carries no attribute at all
([compiler review probes](compiler-optimizations-2026-10-31.md#probes)). Yet the
one rule promises a great deal: while a borrow is live its root is not written
through any other path, and a mutable borrow excludes every other access. So
for the duration of a call:

- a `^mut T`, `inout T`, or `self: ^mut` parameter is the only live path to its
  pointee;
- a `^T` parameter's pointee is written by no one, unless its type reaches a
  [`@(synchronized)`](design.md#synchronized) field, as `Atomic(T)`, `Mutex(T)`,
  and `Monitor(T)` do;
- a `value: T` parameter passed by pointer is, under the same exclusion,
  unchanged.

**The form of the fact is scoped metadata, not `noalias`.** A `noalias`
parameter says that nothing else reaches the pointee while the procedure runs,
the panic call included. Under the default `unwind` strategy that is false: the
runtime runs every frame's cleanup inside the panic call
([runtime/panic.c](../runtime/panic.c)), so a caller's drop hooks and `defer`s
read its locals while the callee still holds the pointer. LLVM then drops a
store before the panic as dead, and in the probe a drop hook prints `0` where
[Panic strategy](design.md#panic-strategy) requires `3`; an `inout` dynamic array
grown before a panic would be freed twice. `!alias.scope` and `!noalias`
metadata on the body's loads and stores say only that those accesses do not
overlap. The panic call carries none, so LLVM still treats it as reading
everything, and the drop hook sees `3` ([Probes](#probes)). The metadata also
leaves the calling convention alone, so a slice needs no split into scalar
parameters.

What metadata cannot give is what `noalias` gives across a call: a callee not
passed the pointer is still assumed to reach the pointee. That remainder is all
that `-panic=abort` would add, and it is not worth a second set of optimization
semantics.

**No capture attributes.** Escape levels restrict retained borrows, not
observed addresses: a procedure may return whether two pointer arguments are
equal, which LLVM counts as [address
capture](https://llvm.org/docs/LangRef.html#address-capture) though no borrow
survives ([Probes](#probes)). Proving more is not worth building, since every
Loke procedure is `internal` and LLVM already infers `readonly` and
`captures(none)` where they hold.

**Proposal.**

1. Measure first. After the compiler review's
   [checked-arithmetic work](compiler-optimizations-2026-10-31.md#checked-arithmetic-and-bounds-in-loops),
   whose branches block vectorization before aliasing does, add the metadata by
   hand to the `bench/` kernels' IR. In the probe's kernel it let LLVM load a
   pointee once instead of after every store and vectorize the loop. On slices
   the gain is mostly the runtime overlap check LLVM's vectorizer already
   inserts, so expect it to be modest.
2. If it pays, emit the metadata on accesses through checked carriers, under
   both panic strategies. An access through a `rawptr`, a C pointer, or a
   pointer of unknown provenance gets none and may alias anything.
3. State in [What is not checked](design.md#what-is-not-checked) that unchecked
   code may not make two checked carriers that break the one rule. A cast that
   only drops provenance, as `Channel`'s `queue_of` does, needs no audit.

**Prerequisite.** The metadata turns a borrow the checker wrongly accepts into
undefined behavior that the optimizer exploits. On 2026-11-11
[known-gaps.md](known-gaps.md#gaps) lists no borrow-checker gap, but several
were found and closed in the ten days before, so "none known" is weaker than
"none". Emit it behind an option until that has held for a while.

## Judgment calls

### `some I`, the static twin of `dyn I`

`f: $C` with `where interfaces.Callable(C, proc(n: int) -> int)` is the common
way to take a callback, and the longest repeated `where` clause in generic code.
A sugar for callables alone would be a keyword bought for one interface. The
general form is better: in a parameter's type, `some I(args)` is a fresh
inferred `$T` with the bound `I(T, args)`, and `some proc(...)` follows as
`some Callable(...)`, as `dyn proc(...)` is already `dyn Callable(...)`. A
reader then learns one pair over one type syntax, erased through a witness or
specialized per argument type, and the opaque result that [Returning a capture
literal](open-questions.md#returning-a-capture-literal) considers is the same
word in the other position.

**Costs.** A procedure becomes generic with no `$` in its signature, so it is
instantiated per argument type and has no single procedure value, which `some`
must be documented as saying. `some` is one more contextual keyword. Decide it
after the catalogue is predeclared, since that shortens every bound and the
sugar should be judged on what remains.

### Success returns

[Success returns](design.md#success-returns) lets `return n;` build `.ok(n)`.
The rule decides by the *syntactic form* of the expression before its type, and
has four bullets, a `nil` exception, and a generic-argument exclusion with its
own definition of "names a generic argument". comments.md
["Success returns"](comments.md#success-returns) cites Swift and Zig, but in
both the success path is plain because the type system makes it so (throws,
error unions), not by a syntactic case analysis. In Loke the wrapping is a
property of one statement and not of the type: `return 5;` wraps where
`x: Option(int) = 5;` is an error ([Probes](#probes)).

**What is lost.** Four characters per return. Since a [returned
construction](design.md#returned-constructions) transfers its operands,
`return .ok(list);` moves an owned local as `return list;` does, so deleting the
rule adds no clone. `lokec -migrate` can write the `.ok(...)` or `.some(...)`
each wrapped return stands for. This review would delete the rule; it is a
judgment call because the rule was adopted recently and deliberately.

### The splat of a typed scalar

[Implicit type conversions](design.md#implicit-type-conversions) converts a
scalar of a vector's lane type to that `Simd(T, N)`. Two cases share the rule.
An unfixed constant, as in `lanes * 2.0` or `half: Simd(f32, 4) = 0.5`, belongs
with the other unfixed-constant conversions and stays. A typed scalar is the one
entry in the list that manufactures a wider value from a run-time operand, and
it applies in every position: as an argument, an initializer, a result, and an
operand of every operator form, including comparisons and compound assignment
([Probes](#probes)).

**Proposal.** Let a lane-wise binary operator take a scalar of the lane type as
either operand, keep the constant conversion, and write a typed scalar anywhere
else as `Simd(f32, 4)(x)`. That form needs a rule of its own, since today it is
accepted only because `x` is assignable to the vector; the rule should keep what
the compiler does now and reject a scalar of another type, so that a scalar
conversion stays written, as in `Simd(i32, 4)(i32(x))`.

**It is an exchange, not a deletion.** One entry leaves the conversion list,
and with it two exceptions: the sentence under [Parameter semantics and ABI
lowering](design.md#parameter-semantics-and-abi-lowering) that keeps a scalar
from binding `inout Simd(T, N)`, and the clause in
[Destructuring](design.md#destructuring) that keeps a scalar field from
splatting. No run-time conversion feeds overload ranking any more. In return
every row of the [lane-wise table](design.md#lane-wise-operators) gains a
scalar operand on either side, and every procedure with a vector parameter,
`simd.select(mask, v, x)` among them, takes a typed scalar only as a written
conversion. `v * scale` is not lost. Against all this the conversion does no
harm of its own: it allocates nothing, loses no information, and moves no
ownership. The concept count comes out about level, so this is the weakest
proposal still open; if it is taken at all, it goes on its own and late.

### `inout` and `^mut T`

Parameters spell the mutable capability two ways. `inout T` is the caller's
variable for the call, and every call writes `inout x`; `^mut T` is the mutable
borrow as a value, which can be held and passed on. Read-only has the same two
forms, `value: T` and `^T`, and [Capabilities and the one
rule](design.md#capabilities-and-the-one-rule) explains the pair. The one rule
that still reads as an exception is in [Receiver
forms](design.md#receiver-forms): `self: inout` is a receiver, and `self: ^mut
Type` is an ordinary parameter with no method-call sugar.

**Proposal.** Make `^mut T` the only mutable-borrow parameter type. A parameter
`p: ^mut T` is passed as `&mut x`; `self: ^mut` becomes the mutable receiver,
with method syntax taking `&mut` implicitly as `self: ^` takes `&`; an interface
binding `(value: inout T)` becomes `(value: ^mut T)`. `-> inout T` stays as the
one place-returning result, which `operator([])` needs ([`inout`
results](design.md#inout-results)). The parameter-mode table loses a row, the
ownership table a column, and grammar.md the `inout` alternative of
`Parameter_Mode`. The borrow checker already treats the two alike under
[Retaining a borrow](design.md#retaining-a-borrow).

**What is lost.**

- *An argument stops showing the mutation.* A `^mut T` is a value: once
  `p := &mut x;` is formed, `f(p)` and `g(p)` change `x` with nothing at either
  call to say so. Today that is true only of parameters declared `^mut T`. A
  receiver already shows nothing, as `values.append(1)` does not, so only
  arguments lose their marker.
- *Scalars and whole values gain carets.* Selection, indexing, and method calls
  reach through a pointer, but `count += 1` becomes `count^ += 1`,
  `out = parse(text)` becomes `out^ = parse(text)`, and resetting a container
  becomes `values^ = {}`. Counters, out-parameters, and replacements are among
  the commonest reasons to take a mutable parameter.
- *It is the largest migration in this review, for a symmetry.* Every `inout`
  parameter, argument, receiver, and interface slot in `core`, the tests, and
  the examples changes, and `lokec -migrate` would have to rewrite call sites
  and receivers.

This review leans against the fold. If it is done at all, it goes last.

One improvement is independent of it. With `bump :: proc(self: ^mut Counter)`,
`c.bump()` is reported as ``L0363: `Counter` has no field or member `bump` ``
([Probes](#probes)), which sends the reader looking for a missing declaration. A
note that `bump` takes `self: ^mut Counter`, which is not a receiver, and that
the fix is `self: inout` or `Counter.bump(&mut c)`, would make the documented
exception a diagnosed one.

## Not recommended

These were proposed or considered and are not recommended. Each is listed with
the reason, so that it is not proposed again without an answer to it.

**Directions type theory suggests.**

- *Higher-kinded or variadic generics*, to spell `Callable` or a generic
  `Functor`. Monomorphized `$` parameters and structural interfaces are the
  right size for a systems language, and `Callable` keeps its built-in rule.
- *Lifetime variables.* Inferred result contracts and written escape levels
  cover what Loke promises; [Public borrow contracts should stand on their
  own](#public-borrow-contracts-should-stand-on-their-own) is the bounded
  alternative.
- *Nominal conformance.* ["Nominal conformance
  declarations"](comments.md#nominal-conformance-declarations) is right;
  structural satisfaction with `static_assert` is simpler.
- *A checked downcast on every `dyn`.* It lets code special-case the concrete
  type behind an interface, and a wrapper then silently loses those special
  cases, as Go's interface upgrades do. No erased value can be inspected, and
  that is the point of having deleted `any_view`.

**Deletions whose cost outweighs the gain.**

- *`via`.* Assigning to a field or element uses the policy of the variable it
  belongs to ([Assignment statements](design.md#assignment-statements)).
  Without it an unbound inner array, after `resize` or `{}`, clones into the
  default allocator, so arena-backed nested structures spill onto the heap.
  Cloning into a live destination's own allocator instead contradicts
  [Last-use transfer](design.md#last-use-transfer): at a last use `x = y` moves
  and brings `y`'s allocator, so `x`'s allocator would depend on whether `y` is
  read later.
- *`stdcall`.* It records which of `core`'s Win32 bindings are `WINAPI`
  ([Calling conventions](design.md#calling-conventions)). It equals `c` on x64,
  but a 32-bit target would need it, and adding it back would mean auditing
  every binding again.
- *Pruning the predeclared names.* `Allocator`, `Allocator_Error`, `Shared`,
  and `Weak` stay because the `hook(copy)` signature, the `try_` forms, and the
  region and ownership rules name them. Replacing `make` with named
  constructors and `free_all` with `a.reset()` is churn that removes no concept.
- *Reversal only as a `reversed()` method.* It loses mutable reversal, makes a
  user container write a view type and its iterators instead of two methods,
  and takes `Reverse_Iterable` from generic code. A user's own `reversed()`
  already takes precedence over the adapter
  ([Iteration adapters](design.md#iteration-adapters)).
- *`Option.ok_or`.* A library method that costs the language no rule.
- *Features a simplification pass might question:* per-variant switch cases and
  union argument expansion, which are expansions of existing rules; `delegate`;
  `hook(convert)`; `@(cpu_dispatch)`; `errdefer`; conditional patterns; `Simd`;
  `Box`; `i128`, `u128`, and `f16`; the wrapping operators; and `exchange`. Each
  is one rule that removes a class of boilerplate or of bug.

**Unifications that would change meaning.**

- *Giving every payloadless union `enum`'s integer mapping and ordering.* A
  union's tag order is representation, not API, and design.md leaves a union's
  layout to the compiler. `from_int`, ordering, and integer conversion would
  make declaration order a public contract: reordering a variant would silently
  change what `from_int(2)` and `<` mean, and adding a payload to one variant
  would take `values()`, ordering, and `Bit_Set` from code that used them.
  Shrinking an enum's default `int` backing to a union's narrowest tag would
  change every foreign binding that uses an enum. For the same reason
  `meta.Variant` has no tag value.
- *Inferring the iteration `Element`.* The yield-mode table reads `Item` against
  `Element` ([Yield modes](design.md#yield-modes)); for an `Item` of `^X` it
  cannot tell an owned pointer from a borrowed `X`, and any default would
  silently change what loop bindings receive.
- *Making `string` an ordinary owner.* A copy would allocate and could fail;
  every getter of a `string` field would allocate on each call
  ([Parameter semantics and ABI lowering](design.md#parameter-semantics-and-abi-lowering));
  and a shared copy and drop costs about 12.5 ns against 65 to 70 ns for an
  allocating 16-byte copy ([Thread-affine
  strings](open-questions.md#thread-affine-strings)). A thread-affine string
  saves the atomic part of the cost without a semantic change.
- *A drop hook implying move-only.* Adding a hook to a public type would turn
  copies in other packages into errors, while the declaration's author, who
  knows what the hook releases, should decide. A record [says how it is
  copied](design.md#lifecycle-hooks-and-resource-types) instead.
- *An `init T` parameter mode*, for one `append` per user container. The
  built-in `try_` forms copy a place only on success
  ([Container insertion](design.md#container-insertion)); an `init` parameter
  clones at the call, before the callee can fail.
- *Table-driven unwinding.* The runtime runs registered cleanup without
  unwinding the native stack ([runtime/panic.c](../runtime/panic.c)), so it runs
  every Loke frame's cleanup even across foreign frames, as in a callback from
  C. Unwinding through those frames would let a C++ host's `catch (...)` catch
  the panic, stop at frames without unwind tables, or skip the cleanup of Loke
  frames above an abort pad, which changes a specified result.
- *`noalias` parameters, and capture attributes from a proof of their own.* See
  [Alias facts from the one rule](#alias-facts-from-the-one-rule).

**Syntax that costs less than its fix.**

- *Parenthesized headers, mandatory braces, and explicit semicolons.* They make
  the grammar LL(k) with no composite-literal ambiguity and no layout rule, and
  buy precise errors and a formatter that never re-flows. Every alternative
  trades that for appearance.
- *`for (key in counts)` as a membership loop.* After `i := 0;`,
  `for (i in 0 ..< n)` would type-check and loop forever or not at all; the
  rejection exists for that mistake
  ([Resolved ambiguities](grammar.md#resolved-ambiguities)).
- *A parenthesized `or_return` operand*, as `f() or_return(.io)`, so that
  `f() or_return.len()` reaches the payload. Whitespace does not separate the
  two, so `f() or_return .io` would silently re-parse as a member of the
  payload; `.name` would stop being an implicit selector in this one position;
  and every failure operand would grow to shorten a rarer member access.
- *`as` for conversions.* `(dyn Drawable)(&circle)` reads like a C cast, but
  `T(v)` with a parenthesized composite type is one rule for every conversion,
  and `as` would be a keyword.
- *Shorter method declarations.* `impl X { f :: proc(self, ...) -> T { } }`
  costs three tokens per method, and is Odin's declaration model, consistent
  with free procedures.

**Defaults.** *`-cpu=x86-64-v2`* is free on Windows 11 24H2, which requires
SSE4.2 and POPCNT, but not on Windows 10, which runs on processors without them.
[CPU levels](compiler-guide.md#cpu-levels) already recommends `x86-64` for
distribution, and the startup check makes opting in safe.

## Open items from the 2026-10-03 review

The review this one built on, kept for its open items. It suggested trying each
proposal on a parser, a resource container, a partitioning algorithm, and a
parallel numeric kernel before deciding.

### Put unchecked obligations at their operation

The [unsafe boundary](design.md#the-unsafe-package) is a file import: once a
file imports `core:unsafe`, every unchecked pointer conversion and C-pointer
access in it is permitted, not only the one that needed it. Most unchecked
operations are named at their use (`unsafe.raw_data`, `unsafe.take`); five
syntax forms are the exception. The review proposed two changes, and neither is
recommended as written:

- *A lexical `unsafe { ... }` block*, with an unsafe procedure declaration
  meaning that its caller owes a stated precondition. Its one use that the file
  import cannot serve is a caller-owed precondition, and no library exports one;
  the files that import `core:unsafe` are mostly OS wrappers that would wrap
  nearly every procedure. The smaller step is to shrink what the import
  licenses. `Uninit(T)` turns the `@(initialized)` field into named operations,
  leaving three pointer forms and `x: T = ---`, each of which shows a C pointer,
  a `rawptr`, or `---` at its use. A file-wide permission over four forms that
  are visible where they occur is close to what the block would give.
- *Raw pointer constness*, `[^]T` for read-only foreign access and `[^]mut T`
  for writing. `^T` and `^mut T` are already foreign-ABI-safe and lower to C
  pointers, with `Option` for a nullable one
  ([Foreign-ABI-safe types](design.md#foreign-abi-safe-types)), so a binding
  can spell `const T *` to one object today. What remains is a read-only
  *array* pointer, a narrower gain than it looks, against a change to every
  foreign signature in `core`; and constness alone establishes neither the
  lifetime nor the bounds obligation.

### Performance opportunities and actual semantic limits

Fast programs are expressible: fixed arrays, slices, arena-backed owners,
monomorphized generics, static iteration, explicit moves, and `Simd(T, N)`.
What remains open is where the compiler could do more without changing a
specified result:

- **Union niches.** A union's layout is the compiler's, with three guarantees:
  its size and alignment are constants of a release and target, the null niche
  holds, and a designated zero is all-zero bytes
  ([Representation](design.md#representation)). The null niche already covers
  the large case, an `Option` of a pointer, `Box`, `Shared`, or procedure. What
  is left is `Option(bool)`, `Option` of an enum, and a nested
  `Result(Option(T), E)`, where padding often takes back the byte a niche saves.
  Choosing those niches is a compiler change to measure, in `union_layout` and
  the emitter's tag reads ([Union layout](compiler-architecture.md#union-layout)).
  `@(repr=...)` waits for the first program that needs a stable layout.
- **Alias facts.** See [Alias facts from the one
  rule](#alias-facts-from-the-one-rule).
- **Explicit reductions.** A floating-point sum is ordered, and the default
  arithmetic stays strict. Separately named reassociating or tree reductions,
  with their numerical differences documented, would let a kernel ask for the
  faster order.
- **Copy elision.** Which implicit copies of a type with a custom clone or
  drop may be elided is unspecified, so none is.
- **Container fast paths.** An optimized build links the runtime as bitcode,
  but in `bench/collections.loke` LLVM still calls `dyn_append`, `dyn_reserve`,
  and `map_find` out of line from the hot loops, and `map_find` calls the key's
  `hash` and `==` through the operation table. Fast paths emitted per element
  type would remove those calls, at the cost of a second implementation of the
  probe sequence
  ([compiler review](compiler-optimizations-2026-10-31.md#container-operations-in-ir-not-through-an-operation-table)).

Some transformations are forbidden outright: reordering floating-point
additions into another tree, fusing `a*b + c`, or hoisting a possible panic
above an earlier observable write. Vectorizing independent iterations, proving
checks cannot fail, and runtime alias checks stay available. A general purity
or effect language is not to be added only to request faster code.

### Public borrow contracts should stand on their own

[Procedure result contracts](design.md#procedure-result-contracts) are inferred
from bodies. That leaves two gaps.

**A pointer rebuilt from untracked storage.** It has unknown provenance, which
proves nothing, though its author knows what it borrows. The library says so
today by a trick that appears three times, in `Deque.slots`,
`Deque.ring_slots`, and `Monitor_Guard.read`:

```loke
slots :: proc(self: ^) -> []T {
	reach: proc(self: ^Deque(T)) -> []T = Deque(T).slots_of;
	return reach(self);
}
```

The helper is stored in a local of plain procedure type only so that the call
through it "conservatively derives from every borrowed argument". The
conservative fallback is used as the mechanism, and `Shared(T).get` gets the
same result from a rule inside the compiler. `Channel` meets the opposite case:
an item taken out of its queue through a guard would look like a borrow of the
guard, so `queue_of` reaches the queue through a `rawptr` cast that drops the
provenance.

*Proposal: say it in the body.* A named unchecked operation,
`unsafe.borrowed(view, from)` say, returns `view` with the root and region
provenance of `from`, as `unsafe.raw_data` discards provenance and a conversion
from `rawptr` asserts an address. It is a promise like the rest of
`core:unsafe` and adds no syntax to signatures. The three helpers lose their
indirection, and `Shared(T).get` can be library code. `Channel`'s cast already
states its half directly.

**A public callback type.** `type_of(procedure)` ties a callback's contract to
one procedure's inferred body, a handwritten procedure type loses details, and
`@(escape=none)` excludes a whole argument but cannot name one field of it or
one allocator. A written contract would let an implementation change without
changing its public contract, and permit a callback type without a reference
implementation to take `type_of` from; it would also reduce dependence on
whole-program inference as separate compilation develops.

*Proposal: extend what a parameter already says* rather than design a
result-side language: the missing precision is a path, so that an escape level
can be written for `list.items` and not for `list`. Whether that case occurs
often enough to build is unshown. Inference stays the default, and the
`// inferred:` lines that [Using a package without reading its
code](open-questions.md#using-a-package-without-reading-its-code-proposal-2026-10-21)
proposes for `api.loki` should come first: they tell a reader what a call may
borrow and touch, effects included, without new syntax. None of this needs
lifetime variables.

**Provenance budgets.** The [minimum provenance
budgets](design.md#minimum-provenance-precision), four projection steps, eight
distinguished fixed array elements, and four constant map keys, are another
source of surprise: a harmless wrapper or extra entry can turn accepted code
into a conservative rejection. Keep diagnostics naming the limit, add
acceptance tests just beyond each boundary, and let written contracts and
disjoint primitives reduce dependence on inferred shape. Raising the numbers
alone does not solve it.

### Thread transfer needs a visible contract

[Structured concurrency](design.md#structured-concurrency) answers this for work
joined before its caller continues
([reasons](comments.md#tasks-that-borrow-joined-by-their-block)). Still open:

- A thread `core:thread`'s `spawn` starts outlives any scope, so it takes only
  `@(escape=static)` arguments, and keeping a `thread_local` borrow past the end
  of its thread is unchecked; see
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

1. **Erased callables at a spawn.** A view that arrives erased, as a parameter
   or stored local, is checked through every type converted to its interface
   application ([Sharing with tasks](design.md#sharing-with-tasks)), and a call
   through it takes its slot's whole effect union. So one conversion of a
   mutable or thread-affine type anywhere rejects every erased view of that
   application, and one fill writing a global rejects every call through it.
   The same union lets a task read through a `dyn` stored in a global, except a
   `dyn fmt.Formattable`, which stays unknown since printing builds its
   witnesses after the effects. More precise directions: keeping the concrete
   type through a view stored in a local, which helps only locals; a view type
   that promises its target may be shared with a task; and public
   callable-effect contracts. The last two are language extensions that need a
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

## Probes

Programs run to confirm claims this review still depends on, with the compiler
each ran against. Emitted-IR and register-passing observations are in the
compiler review's [Probes](compiler-optimizations-2026-10-31.md#probes).

**Comparing addresses retains no borrow** (2026-11-01, `lokec` at `4173b622`).
This prints `true false`; the comparison observes addresses without retaining a
borrow, which LLVM counts as address capture:

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

**`noalias` breaks cleanup under `unwind`; scoped metadata does not**
(2026-11-01 with `lokec` at `5580637f`, repeated 2026-11-11 with Clang 22). The
third addition overflows, so the default `unwind` strategy runs the drop hook
after two additions:

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

The `-emit-ll` IR was linked with the runtime's C sources at `-O2` three ways:
as emitted; with `noalias` on `fill`'s first parameter; and with `!alias.scope`
on the load and store through `b` and `!noalias` naming that scope on the load
through `xs`.

```text
as emitted:            drop sees 3
with noalias:          drop sees 0
with scoped metadata:  drop sees 3
```

With `noalias` the `store i64 3` before the call to `loke_rt_v1_panic` is gone.
All builds show `readonly captures(none)` on internal procedures, inferred by
LLVM, though the emitter wrote neither.

**Scoped metadata removes a reload and lets a loop vectorize** (2026-11-11,
Clang 22 at `-O2`). For

```loke
add_into :: proc(dst: []mut int, src: []int, k: ^int) {
	foreach (i in 0 ..< dst.len()) { dst[i] = src[i] +% k^; }
}
```

marked `noinline`, LLVM specialized the one call's length of four. As emitted,
the body is four scalar adds, each after a fresh load of `k`. With
`!alias.scope` on the store to `dst` and `!noalias` naming that scope on the
loads from `src` and `k`, it loads `k` once and does two `<2 x i64>` adds.

**Language probes** (2026-11-11, `lokec` 0.9.0 built at `41c0e2d4`, and from a
modified tree at `267ab0f9` for the last two):

- *A typed scalar splats in every position.* With `scale: f32`, `take(scale)`
  for a `Simd(f32, 4)` parameter, `c: Simd(f32, 4) = scale`, and `return x;`
  from a procedure returning `Simd(f32, 4)` are accepted and print
  `[2.0, 2.0, 2.0, 2.0]`.
- *Only `return` wraps.* `return 5;` in a procedure returning `Option(int)` is
  accepted; `x: Option(int) = 5;` is ``L0352: 5 is not representable by
  `Option(int)` ``.
- *`&mut a[lo:hi]` is not the address operator.* For `a: [4]int`, `&a[0:2]` is
  ``L0357: `&` needs an addressable operand``, and so is `&mut a[:].len()`.
- *A `self: ^mut` method is reported as missing.* With
  `bump :: proc(self: ^mut Counter)` in `impl Counter`, `c.bump()` is
  ``L0363: `Counter` has no field or member `bump` ``.
- *A typed scalar splats under every operator form, and in a library call.*
  With `x: f32` and `v: Simd(f32, 4)`, all of `v < x`, `v *= x`, and
  `simd.select(mask, v, x)` are accepted.
- *The explicit scalar form takes the lane type only.* `Simd(f32, 4)(x)` is
  accepted and prints `[2.5, 2.5, 2.5, 2.5]`. `Simd(i32, 4)(x)` is
  ``L0373: `f32` cannot be converted to `Simd(i32, 4)` ``, and
  `Simd(f32, 4)(i)` with `i: i32` is the same diagnostic for its types.

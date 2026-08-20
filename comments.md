# Open questions

Decisions that are deliberately not yet made are recorded here rather than left implicit in normative prose. [`design.md`](design.md) defines the rules implementations must follow for the current language version; these questions concern possible later changes.

## Package and import versioning

Should import paths encode package versions, and should a package declaration remain mandatory in every file? The current version requires the declaration and leaves dependency versions to the build system or package manager. A future package design may need reproducible version selection without making source imports depend on a particular registry.

## package header files

An files containing all public signature and what is reachable from the outside.
Should be optional but if it exists it should be checked by the compiler that it's correct.
A way to improve encapsulation and make it easier to see what an package can do both for humans and LLM's.

## package declaration

is the package declaration needed or is it unessesary sermony?

## Retaining defer

Does scope-based `defer` provide enough clarity and utility to remain in the final language? Its current semantics are fully defined, including its ordering with automatic cleanup. The remaining question is whether explicit resource types and managed cleanup make most uses unnecessary.

## Multi-pointer terminology

Is *multi-pointer* the clearest name for `[^]T`, or would *bounded-form pointer*, *C pointer*, or another term better communicate its unchecked indexing and foreign-memory role? The syntax and semantics are independent of the eventual name.

## Pure procedures

Should there be a form of procedure, distinct from `proc`, that is guaranteed by the compiler to be free of side effects?

Compile-time evaluation no longer requires a second procedure kind: an ordinary
procedure is evaluated contextually when its executed path is admissible. A
separate purity contract could still permit safe runtime reordering, parallel
reactive evaluation, and clearer contracts on operations such as `hash` and
`compare`. The cost remains an effect system, especially once useful pure code
is allowed local mutation and result allocation. It is not required by the
current compile-time or interface design.

## Tuples

Should multiple return values be a real tuple type rather than a special form?

Today `a, b := swap(1, 2)` is a language rule that applies to return values and nothing else. A first-class tuple would unify multiple returns, multiple declarations, and pattern matching under one construct, and would let a tuple be stored, passed, and named. The counter-argument is that Odin's approach works, costs nothing, and never tempts anyone to return a tuple where a struct with named fields would document the code better.

## Owning runtime polymorphism

Borrowed `dyn Interface` views are now defined. Should a later version add an
owning erased value, and if so should it be a language type such as `box(dyn I)`
or a library owner built over an exposed witness primitive?

The proposal must specify allocator identity, alignment, fallible construction,
move, clone, drop, thread-affine destruction, and whether inline small-object
storage changes representation. Borrowed `dyn` intentionally settles none of
those questions and never allocates.

Note that the witness is currently a mechanism with no user-visible spelling: the
compiler builds one for each `(Interface, Concrete, arguments...)` tuple reached
by a `dyn` conversion, and nothing materializes it as a value. An earlier draft
exposed `witness_of` and a compiler-defined `Witness(...)` type for exactly this
future owner, which meant fixing a layout, a zero value, an invalid-witness panic
rule, and a normative slot-flattening order for a consumer that did not exist.
Whichever way the question above is answered, the primitive comes back with the
owner that needs it.

## Borrow checking across procedure boundaries

The rule in [Borrows and lifetimes](design.md#borrows-and-lifetimes) treats a returned borrow as derived from every borrowed argument whose storage is reachable through a parameter. It rejects results attributed to temporary arguments before they can escape, so it is sound but coarse and can force copies in code that does not need them. Whether that imprecision is acceptable in practice can only be answered by writing a real library against it.

## unsafe alive

should we add an function to mark an dead variable to alive. The idea is to have an explicit unsafe mechanism for optimizing code and cheat the mechanism that checks if variables are safe to use.

## Concurrency refinements

The current [memory model](design.md#concurrency-and-the-memory-model) defines data races, atomics, transfer between threads, and `shared(T)`. Experience with a real concurrent runtime should determine whether later versions need compiler-checked `Send` or `Sync` interfaces, additional atomic orderings, or a thread-affine owning type for code that wants non-atomic reference counts.

The cost of keeping immutable `string` safe to copy and drop across threads is treated separately under [Thread-affine strings](#thread-affine-strings).

## Implementation blocks

Should `self` be an implicit parameter? The current version requires it to be
written as the first parameter name, which is what lets the four receiver forms
— `self`, `inout self`, `move self`, and a plain `^Type` first parameter — be
distinguished at the declaration.

Should methods be written in a separate `impl` block or inside a struct? If they
are written inside structs, how should methods on other kinds of types work?
`impl` blocks were chosen partly because they extend to `distinct` types,
enums, and generic instantiations without a second syntax, but the cost is that
a type's data and its behavior are declared apart.

## Thread-affine strings

`string` is an owning value that may share backing storage, and the current
version requires atomic handle accounting in any sharing implementation. This is
the most expensive rule in the language per line of ordinary code: every string
copy is a potential atomic increment, and a freestanding target without atomics
is left with copy-always as the only conforming strategy. Atomic accounting does
not make an arbitrary allocator thread-safe; transferring the string still
asserts that its bound allocator may deallocate on the receiving thread.

A thread-affine string with a non-atomic count would be a distinct type rather
than a silent weakening of the guarantee. Deciding whether it is needed requires
measuring a real implementation; it is recorded here because the cost is
structural rather than an implementation detail, and because the answer affects
whether `string` is usable unchanged on embedded targets.

## Compile-time code generation

The current language evaluates ordinary procedures at compile time, treats
types as typed compile-time values, exposes typed reflection descriptors, and
supports statement-level static `foreach`. It deliberately does not expose
tokens or syntax trees, generate identifiers, inject declarations, or expand a
static loop at file scope.

Experience with serialization, GUI, RPC, and binding libraries should determine
whether typed reflection and expansion are sufficient. If declaration
generation is eventually required, it should preserve lexical name resolution,
hygiene, incremental compilation, and readable diagnostics rather than exposing
an untyped token macro system by default.

## Recoverable panics

Version 1 makes a panic unrecoverable: unwinding runs `defer`s and managed
`drop`s for cleanup, but there is no `recover`, `try`, or catch construct that
lets Loke code observe or resume from one. The [panic semantics](design.md#panics-and-unwinding)
are otherwise fully defined, including the two build-selected strategies.

The open question is whether a later version should add a bounded recovery
mechanism — a per-thread catch at a task or request boundary, say — without
reintroducing general exceptions. The appeal is server code that wants to fail
one request rather than the process; the cost is a second control-flow path that
every `drop` hook and `defer` would have to be correct under, and the temptation
to use it as ordinary error handling in place of [`or_return`](design.md#or_return-operator).
Not required by anything in this document.

## exponent operator

 ** for pow(a,b)? ^ are used for pointers.

## intrinsics and inline assembly

How to add some suport to go even more low level and use SIMD efficiently, Intrinsic or inline assembly?

## Compile time

file handling?
fail load, can the programmer easily see what is going to run at compile time

## abstraction over SOA

Is it the programers responsibility to abstract ove the right thing or does the language need some help with that?

## LLM optimization

token optimization, can the syntax be made to be token efficient?
LLM readability and writability, how does that differ from humans? LLM's are trained on human data but works differently.
Encapsulation and abstractions must still be important so they can work on an part of the code.

## garbage collection

add an garbage collected allocator as an alternative?

## memory managment

Could the compiler move a large fixed-size local variables to the heap? Does it need to be made to an "Owning value"?

## default allocator

I think the default allocator and logger should be choosen in the source code in the main package, is that an good idea and what effect does that have? So must be befor the import statements

# Differences from Odin and design motivations

This section is non-normative. It records why Loke differs from Odin and why
some larger design choices were made. [`design.md`](design.md) remains the
authoritative language definition.

## shorten dynamic array syntax

change [dynamic] to [dyn]

## directives

now when we have compile time procedures should some directives be changed to procedures?

## Added features compared to Odin

### Local borrow checking

Loke adds a deliberately small, procedure-local borrow checker. It catches
invalidating a container while a view is live and prevents obvious local
escapes without adding lifetime syntax. A returned borrow is conservatively
attributed to every borrowed argument from which it could have come. That can
require an unnecessary copy in ambiguous cases, but keeps procedure signatures
free of lifetime parameters.

Raw pointers, stored borrows, foreign calls, and cross-thread lifetimes remain
explicit trust boundaries. This keeps low-level optimization and interop
possible without making unsafe behavior the default.

### Managed lexical storage

Strings, dynamic arrays, maps, and user resource types are owning values with
automatic scope cleanup. `manual` suppresses only that automatic cleanup, while
`static` and `thread_local` control duration; none creates a second type.

File-scope and `static` managed values are not automatically dropped. A global
destruction order across packages would make shutdown depend on initialization
order and on whether other threads can still reach a value. Externally
observable process cleanup therefore uses an explicit owner, `defer`, or
`drop` in `main`. A managed `thread_local` does have a natural local endpoint
and is dropped on normal thread return, in reverse initialization order;
aborting termination makes no such guarantee.

### Storage modifiers instead of storage attributes

Odin spells static-duration locals `@(static)` and thread locals
`@(thread_local)`. Loke writes both in the declaration alongside `manual`,
because they answer the same question it does — where does this variable live,
for how long, and who releases it.

The dividing line is not metadata versus meaning: `@(packed)` and
`@(allocator_reset)` are attributes and both are load-bearing. It is that these
three answer a question about the declared storage itself, which is what the
declaration is for. Remove `@(link_name)` or `@(export)` and the program still
means what it meant; remove `static` and a counter resets on every call, cleanup
starts running at scope exit, and a borrow that used to be returnable no longer
is.

Splitting duration from ownership keeps `static manual Foo` expressible, which a
single modifier slot could not say.

### No `stack` modifier, and no heap-promoted locals

An earlier draft let the compiler place a large fixed-size local on the heap when
the frame would otherwise be impractical, and added a `stack` duration modifier
so that embedded and real-time code could forbid it per declaration.

Both are gone. A local with lexical duration lives in its frame, full stop; a
declaration too large for the stack overflows it, as in C. The promotion rule was
a silent allocation — and a silent allocation-failure path — behind a declaration
that reads as free, and `stack` existed only to buy back the property the
declaration started with. Deleting the pair removes a modifier, a placement rule,
and a guarantee, and puts the cost of eight megabytes of local back in the
declaration that asks for it.

### Value-semantic assignment

Odin assignment of a `[dynamic]T` or `map` copies only the header, so two
variables alias one mutable backing allocation and one of them frees it. Loke
makes `b := a` a deep copy for mutable owners: an owning value behaves like a
simple one, and the silent shared-backing alias — the classic source of
double-free and mutation-at-a-distance bugs — is never produced implicitly.
Immutable `string` may share backing storage because mutation cannot expose the
alias. Shared mutable ownership is opted into with a pointer or `shared(T)`.

The obvious objection is that the language spells `move`, `inout`, and `clone`
explicitly for visibility, yet leaves the potentially expensive copy unspelled.
The resolution is that the accident, not the semantics, is the problem, so the
fix targets the accident. Forbidding assignment or requiring `.clone()` on every
copy (the Rust answer) would defeat the goal of making owning values as simple as
integers, and copy-on-write would trade a visible copy for an unpredictable
mutation-time allocation and an atomic refcount — against a systems language's
need for predictable cost. Instead a large or allocating copy is reported by the
[copy-cost diagnostic](design.md#copy-cost-diagnostics), covering binding and
assignment sites. Ownership transfer remains explicitly written as `move`; the
compiler does not silently remove a fallible clone or change the allocator bound
to the destination merely because the source happens to be dead. Default deep
copy, explicit move, and a warning on expensive copies keep both semantics and
cost visible.

### Panics run lexical cleanup

Odin's managed model has no destructors, so a crash has nothing to unwind. Loke
adds managed `drop` and lifecycle hooks, which forces a decision Odin never had
to make: what runs when a program panics. The [answer](design.md#panics-and-unwinding)
is that a panic under the unwinding strategy runs exactly the cleanup attached to
live owners and `defer`s as it unwinds the faulting thread — so `defer os.close(f)`
and a resource's `drop` are reliable when they are on that thread's stack — and
nothing else. Loke has no automatic package shutdown hooks. An owner in `main`
is cleaned only when `main` is on the panicking thread's stack; a worker panic
does not unwind other threads.

Two strategies exist because the machinery is not free: hosted builds default to
`unwind` for the cleanup, while freestanding and embedded builds default to
`abort`, which runs no cleanup and needs no unwind tables. Because a panic cannot
be caught either way, the choice never changes which programs are valid, only what
observable cleanup happens on the way down.

### Methods, interfaces, and operator overloading

Methods and `impl`/`extend` blocks let libraries attach behavior to records and
other types without embedding procedure declarations in every type definition.
An extension affects implicit lookup only in its declaring package. A public
extension procedure is an ordinary export of that package, so importers call it
as `adapter.procedure(value)` unless they add a local forwarding extension. This
keeps an unrelated import from changing an existing expression.
Interfaces describe capabilities used by generic code. Named `slot`
requirements additionally let the compiler reify the same proof as a witness
table for explicit `dyn` values. Free-form expression requirements remain
static-only, so adding runtime dispatch does not weaken the concise structural
constraints used by numeric and container algorithms. The name `interface`
replaced the earlier draft's `concept` because it now describes both roles
directly.

Generic bodies and their interface requirements use definition-site lookup, so
a caller-local extension cannot change an existing instantiation. The built-in
map is stricter still: equality and hashing for a user key must be inherent to
the key type. Without that restriction, two packages could operate on the same
map using different hash policies and invalidate its contents.

Operator overloading, indexing, iteration, conversions, and lifecycle hooks let
library types be as convenient as built-in types.

### One language at compile time

`$`, `::`, `when`, and static `foreach` have separate jobs. `$` introduces a
specialization input or pattern, `::` binds a computed constant, `when` selects
which source is present, and `foreach ($item in values)` expands heterogeneous
typed code. Keeping those meanings separate avoids a general sigil that can
silently move arbitrary runtime work into compilation.

Ordinary procedures are interpreted when a constant context requires their
result. Their values retain ordinary Loke types; only `type` and the opaque
reflection descriptors are compile-time-only. This gives libraries loops,
local mutation, type computation, and reflection without a parallel untyped
macro language. File and environment access remain in an explicit build program
rather than becoming ambient compiler effects.

Built-in operations on built-in types cannot be shadowed. Domain-specific
behavior over a primitive representation uses a `distinct` type, keeping the
changed meaning visible at its declaration.

A `distinct` type inherits none of its underlying type's operators — `Meters ::
distinct f64` starts with no arithmetic at all — which is what stops a unit type
from silently behaving like its representation. The cost is per-operator
boilerplate for numeric newtypes, so `delegate` re-exports a chosen set of the
underlying operators in one line. It is deliberately a list rather than blanket
inheritance: `Meters` delegates `+` and `-` but not `*`, because two lengths add
to a length but do not multiply to one. Selective delegation keeps the newtype
convenient without reintroducing the wrong-dimensioned operations that
distinctness exists to forbid.

### Build-selected services and explicit runtime state

An earlier draft gave every Loke call a hidden pointer to an immutable ambient
context containing allocators, logging, tracing, clocks, and related services.
It made call-tree overrides concise, but also changed every procedure ABI and
introduced context derivation, installation, snapshotting, and thread
propagation rules for services most procedures never use.

Loke instead lets the final build select one default allocator provider and one
logging provider for the whole program. Imports cannot configure separate copies
of a package. Per-import configuration would require generic package instances:
two imports with different providers would need rules for duplicated code,
globals, initialization, symbol identity, transitive dependencies, and whether
public nominal types from the two instances are compatible. That is a package
type system, not a small service-selection feature.

Only the provider implementation is static. Allocator regions, scratch arenas,
request log fields, trace spans, clocks used by simulations, cancellation, and
other execution state remain ordinary runtime values. They are passed directly
or retained in application-defined state objects. This makes nondefault policy
visible and lets two concurrent requests use different state without a global or
thread-local override.

The removed context pointer is not retained as a closure substitute. It would
provide the caller's environment when a procedure is invoked, not the lexical
environment in effect when a procedure value was created, and retained work
would still need ownership and lifetime rules. Typed `state + proc` records and
callbacks with explicit generic state provide the useful mechanism using
ordinary language facilities while keeping procedure values thin.

## Removed or narrowed features

### Generics are not ABI surface

Generics are resolved before ABI lowering, so a generic procedure or type has no
representation of its own and is excluded from every binary interface: it cannot
be exported, given a foreign calling convention, placed in a `foreign` block, or
held in a procedure value. Only concrete instantiations reach the ABI, and
exposing generic functionality to C means instantiating it and wrapping the
result in a foreign-ABI-safe procedure. Saying so explicitly keeps the choice
between monomorphization and dictionary passing an implementation detail with no
observable consequence, and keeps the foreign boundary defined over concrete
types only.

### Constraint entailment in overload resolution

An earlier draft let [tie-breaker 4](design.md#operator-lookup-and-overload-resolution)
order two structurally identical candidates by constraint strength: the one whose
normalized constraint set syntactically entailed the other's won. Constraints now
decide only whether a candidate is *viable*; structure alone decides which viable
candidate wins, and a tie is an ambiguity error.

Entailment carried the most machinery of any single rule in the language — normalize
as an unordered conjunction, expand interface composition transitively, alpha-rename
bound names, test atom-subset — plus the caveat that an implementation reasoning more
strongly must not thereby change which overload is selected. It bought one pattern:
Rust-style automatic selection of a strictly-more-constrained refinement. Making that
refinement an explicit call is consistent with how the language treats every other
ambiguity, and it means a reader never has to perform a subset test to know which
procedure runs.

### Statement labels and multi-level breaks

Labels made structured control flow read like a hidden `goto`. The common
multi-level exit cases can use a returned helper procedure, a loop condition,
or an `if` chain. Loke therefore keeps `break` and `continue` limited to the
innermost applicable construct.

### File-private visibility

`@(private="file")` is gone; `@(private)` now takes no argument and names package
visibility explicitly, which is only load-bearing inside a file whose package
clause carries `@(public)`. A package is the encapsulation boundary, and one
level of hiding *inside* that boundary cost an attribute value, a package-clause
form, a mutual-exclusion rule against `@(public)`, and a rule for opting back out
of a file-wide private default. A file that wants its own boundary wants to be a
package.

### `fallthrough`

Multi-value case lists cover what most C fallthrough chains are written for, and
a case that must run another case's body calls a shared procedure. Keeping a
keyword to reintroduce the C behaviour that Loke's `switch` exists to remove was
not worth the reserved word, the statement, and the extra clause in the `defer`
restrictions.

### Named-result initializers

`-> (color := "blue")` is gone; a named result starts at its zero value and is
assigned in the body. It resembled a parameter default but fired on a different
condition — every entry, rather than every call that omits an argument — and two
similar spellings with different trigger conditions is a poor use of syntax.

### Reflection beyond fields and enum values

Compile-time reflection is `fields_of` and `enum_values_of` with two descriptor
types. An earlier draft also had `procedures_of`, `parameters_of`,
`requirements_of`, and `attributes_of`, with three further descriptors and a rule
about which extension members `procedures_of` observes. Field and enum shape is
what serialization, bindings, and GUI generation walk; the rest was a guess at
what an RPC or documentation generator might want. Adding a descriptor later is
additive.

### Associated interface members use expressions

`const T.NAME: Type;` is gone. `T.NAME -> Type;` is an ordinary expression
requirement that says the same thing, since `T.NAME` already names its owner
unambiguously. The dedicated form bought only the additional demand that the
member be a compile-time constant, which value requirements did not need. An
associated type uses the same mechanism as `T.Element -> type;`; because its
result is itself a type, that selected member is necessarily compile-time known.
No second member-declaration grammar is needed.

### Headless switch

Odin permits a condition-only switch:

```odin
switch {
case x < 0:
	fmt.println("x is negative");
case x == 0:
	fmt.println("x is zero");
case:
	fmt.println("x is positive");
}
```

The same logic is clearer as an `if`/`else if` chain, so Loke requires a switch
expression and avoids a second conditional construct with overlapping purpose.

### Compiler-defined domain types

Complex numbers, quaternions, matrices, and similar domains are library types
instead of compiler-defined primitives because ordinary records and overloads
can express their behavior. SIMD vectors remain built in because their
semantics include lowering to target vector operations, which an ordinary
record cannot guarantee.

### Owning type erasure

`any_view` remains borrowed and call-scoped, while `dyn Interface` is a more
capable borrowed view carrying a coherent interface witness. Neither owns the
erased payload. An owning `any` or `dyn` would need stable payload allocation,
allocator provenance, alignment, erased clone/drop behavior, borrow rules across
moves, thread-affine destruction, and an allocation-failure contract.

Keeping ownership out of the initial design lets generic and dynamic dispatch
interoperate without silently allocating. Closed owning sets use unions;
libraries that need open ownership can first validate an explicit owner record
around raw storage and their own callback record.

### General user-defined implicit conversions

`@(implicit)` applies only to a one-argument `init` overload and only where the
argument is an untyped constant. The
motivating case was always literals entering library numeric types — `z*z + 2.0`
should mean what it looks like — and that is a property of literals, not of
`f64`. A general facility would additionally have converted runtime values
silently based on what happened to be imported.

Narrowing it removed three rules that only existed to contain the general
version: the cap on conversion chain depth (a constant is not a user type, so no
chain can form), the argument that lookup terminates, and the advice that
implementations warn about lossy implicit conversions (constant representability
is already checked at compile time). Promoting a variable is written
`Complex_F64(x)`, which is what the reader needs to see anyway.

### A read-only-data attribute

Odin has `@(rodata)` for a global that lives in the read-only section. Loke
deleted it and made constants materializable instead: a constant indexed by a
non-constant or sliced is emitted into read-only storage, once, and shared by
every use. Taking its address is rejected because Loke pointers do not carry a
read-only capability; foreign access goes through a read-only slice and an
explicit `unsafe.raw_data` conversion.

`@(rodata)` existed for exactly one reason — a constant had no storage, so
`TABLE[index]` with a runtime index did not work. Everything else it provided,
process lifetime and immutability, a constant already had. Deleting it removed
the attribute, the rule that such a declaration's type had to be written `[]int`
rather than the `[]mut int` a literal would otherwise produce, and the last
exception to "there is no general `const` qualifier in the language."

The cost is that "constants exist only at compile time" is no longer literally
true, and the language has to say that all uses of a materialized constant share
one backing object. Rust keeps `const` and `static` separate to avoid exactly that
question. The trade was taken because a runtime-indexable read-only table is
ordinary systems code, and spending a declaration attribute on it — one that
looks like metadata but changes whether the program compiles — put it in the
wrong category.

### Sized boolean types

Loke has a single one-byte `bool`. Boolean-looking foreign typedefs bind as their
actual integer representation and are converted in a wrapper. This also handles
encodings such as `VARIANT_BOOL`, whose true value is `-1`, without pretending
that every foreign boolean is just a differently sized Loke `bool`.

### Unchecked union assertions

Union assertions are always checked. Unchecked multi-pointer indexing in
`core:unsafe` does not weaken a union assertion performed elsewhere.
Interpreting the wrong payload as an owning type can manufacture a container
header from unrelated bits and later pass an invalid pointer to `drop`.
`transmute` and raw storage in `core:unsafe` remain available for explicit
low-level work, but an unchecked ordinary assertion would bypass the lifecycle
restrictions placed on those features.

## Changed features

### Explicit overload groups

Overloads are assembled in named procedure groups. Each implementation keeps an
ordinary callable name, the overload set is visible, and ambiguity is diagnosed
instead of being resolved by declaration order. Methods and operators use the
same resolution rules.

### `+` concatenates strings at runtime

Odin's `+` on strings works only between constants; runtime concatenation is
`strings.concat` with an explicit allocator. Loke lets `+` concatenate at runtime
too, allocating from `mem.default_allocator()`.

The argument against was that it hides an allocation behind an operator. But the
language already hides allocations behind `append`, map insertion, and plain
assignment, and it has a [copy-cost diagnostic](design.md#copy-cost-diagnostics)
for exactly this — so `+` is not the place the rule would first be broken, and
refusing it only makes the common two-or-three-piece message the awkward case.
The quadratic loop is the real hazard, and it is answered by reporting it rather
than by removing the operator: `String_Builder` remains the way to accumulate,
and the way to choose an allocator.

### No enum arithmetic or bitwise operators

An earlier draft allowed `+`, `-`, and the bitwise operators on enums, inherited
from treating them as thin wrappers over integers. Enum members may have holes,
so the result of `Foo.A + Foo.B` need not be a member of `Foo`, and the language
has `Bit_Set(Enum)` for flag sets. Enums remain comparable and ordered, and
converting to the backing integer type is one call.

### Defined signed overflow

Signed `+`, `-`, `*`, and `<<` are defined to wrap two's-complement, and a
compiler may not assume signed overflow cannot happen. This costs the
optimizations undefined overflow buys — widening a 32-bit induction variable to
a 64-bit register, proving a loop terminates, strength-reducing address
arithmetic — on exactly the loops a systems language cares about, and `int` is
the recommended default type, so it costs them by default. It is the same trade
made for shift counts: a rule whose meaning does not change under optimization is
worth more than the code it costs, because the alternative is a program whose
correctness depends on a compiler flag. Code in a measured hot loop that wants
the wider assumption states it explicitly rather than inheriting it silently.

### `in` is a comparison, not an additive operator

Odin places `in` at the comparison precedence level and Loke had moved it to the
additive one. That silently regrouped `x in values + extra` as
`(x in values) + extra`. `in` produces a `bool`, so it belongs with `==` and `<`.

### Map element mutation

Odin prohibits `m[key].field = value`. Loke permits it because indexing a user
type can already return an `inout` place, and built-in maps should follow the
same place rules. Assignment through a missing key inserts a zero value first;
`m.find(key)` is the non-inserting lookup, with optional-ok results.

### `string` borrows as `string_view`

`string` converts implicitly to `string_view`. Without it the two types compete
for every signature that reads text: an API taking `string` cannot accept a
substring without allocating one, and an API taking `string_view` makes every
caller holding a `string` write a conversion. The conversion is a borrow, costs
nothing, and needs no validation, so the division is simply that `string_view`
reads and `string` owns. It is one-way; going back allocates, via `.clone()`.

### String ownership and concurrency

`string` is an immutable owning value. Implementations may share backing storage,
so a shared reference count is atomic. The allocator that eventually frees the
storage must separately support the thread on which the last drop occurs; as for
other owner lifecycles, version 1 leaves that transfer check to the programmer.
Code that does not want shared ownership uses a byte slice or `string_view`.

### Allocation failure

Implicitly allocating expressions have no result slot for an error, so each
allocator carries a failure policy. `.Panic` is the default because continuing
with a silently truncated value would corrupt later results, and `.Trap` is the
freestanding alternative. Recoverable allocation uses `try_` operations. The
earlier `.Error` policy was removed with ambient context because its sticky error
slot was a hidden side channel and could not identify which implicit operation
had failed.

## Changed syntax

### Statement termination

Statements end in `;` unless their outermost form ends in a declaration or
statement block. A block-closing `}` terminates that form; a trailing semicolon
is accepted only as a separate empty statement. This keeps termination
deterministic without requiring a redundant `;` after a block.

### `transmute` is a procedure, not an operator

Odin spells a bit cast `transmute(T)value`, which needs a reserved word and its
own unary binding rule. Loke writes `transmute(T, value)` and makes `transmute`
an ordinary predeclared built-in alongside `drop`, `len`, and `new` — types are
already passable as arguments, so nothing was gained by the operator form except
a keyword. `move` stays a keyword because it is also a parameter mode and has to
be reserved regardless.

### Parenthesized control-flow headers

Loke requires parentheses around every control-flow header, for example
`if (x >= 0) {}`. Odin omits them and needs a special parsing rule to
distinguish some condition expressions from composite literals. Loke's uniform
header shape keeps the header separate from the body brace.

### Slice literals state their capability

Odin's `[]int{1, 2, 3}` produces a mutable slice. Loke has two slice types, so
the literal is written with the one it produces: `[]int{...}` is read-only and
`[]mut int{...}` is not. Inferring `[]mut T` from a literal spelled `[]T` would
have made the most common example of a mutable slice the one place in the
language where a written type does not describe the value.

### No uniform call syntax

`x.f()` resolves only to a `self` receiver declared in an `impl` or `extend`
block, or to a built-in container operation. There is no rule rewriting `f(x)`
as `x.f()`. Free procedures therefore never acquire a method spelling by
accident, at the cost of `len(x)` and `x.append(v)` reading differently — which
is the right trade when `len` is what generic code calls on a type parameter and
`append` is an operation on a named receiver.

### `foreach`

Odin's `for value in values` form is written `foreach (value in values)`.
Keeping `for` and `foreach` separate makes the repetition form visible at the
keyword and lets `in` retain its membership-operator meaning in an ordinary
`for` condition.

## Features kept close to Odin

### Foreign declarations

The foreign system intentionally remains close enough to Odin that maintained
bindings can be ported mechanically. A port mainly updates visibility and
attributes and replaces owning C-string assumptions with `cstring_view` or the
appropriate explicit foreign-string type. Bindings keep foreign symbol spelling
and can expose an idiomatic wrapper separately.

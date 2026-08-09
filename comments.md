# Open questions

Decisions that are deliberately not yet made are recorded here rather than left implicit in normative prose. [`design.md`](design.md) defines the rules implementations must follow for the current language version; these questions concern possible later changes.

## Identifier character set

Should identifiers remain ASCII-only or adopt a normalized subset of Unicode identifiers? The current version accepts ASCII identifiers only. Unicode would improve native-language naming, but normalization, confusable characters, font support, and input ergonomics require a precise security policy before the rule can expand.

## Shadowing

Should inner scopes be allowed to shadow outer local variables? The current version rejects it except for the explicit parameter-copy idiom. Allowing shadowing is familiar and sometimes concise, while rejecting it prevents accidental reuse and makes references easier to follow.

## Package and import versioning

Should import paths encode package versions, and should a package declaration remain mandatory in every file? The current version requires the declaration and leaves dependency versions to the build system or package manager. A future package design may need reproducible version selection without making source imports depend on a particular registry.

## Retaining defer

Does scope-based `defer` provide enough clarity and utility to remain in the final language? Its current semantics are fully defined, including its ordering with automatic cleanup. The remaining question is whether explicit resource types and managed cleanup make most uses unnecessary.

## Multi-pointer terminology

Is *multi-pointer* the clearest name for `[^]T`, or would *bounded-form pointer*, *C pointer*, or another term better communicate its unchecked indexing and foreign-memory role? The syntax and semantics are independent of the eventual name.

## Pure procedures

Should there be a form of procedure, distinct from `proc`, that is guaranteed by the compiler to be free of side effects?

The appeal is compile-time evaluation, safe reordering, and clearer contracts on `interface` requirements such as `hash` and `compare`. The cost is a second procedure kind, an effect system to police it, and the usual problem that a genuinely useful purity rule has to permit local mutation and allocation, at which point it stops being simple. Not required by anything in this document.

## Tuples

Should multiple return values be a real tuple type rather than a special form?

Today `a, b := swap(1, 2)` is a language rule that applies to return values and nothing else. A first-class tuple would unify multiple returns, multiple declarations, and pattern matching under one construct, and would let a tuple be stored, passed, and named. The counter-argument is that Odin's approach works, costs nothing, and never tempts anyone to return a tuple where a struct with named fields would document the code better.

## Future runtime polymorphism

Should a later version allow `dyn Interface` runtime values or leave runtime dispatch to procedure tables and libraries? Version 1 deliberately omits `dyn`. A future proposal must be validated by a real UI, codec, or plugin library and specify vtable layout, erased ownership, binary methods, unsized results, and interaction with `any_view` before becoming normative. Owning type erasure was removed from version 1 for the same reason and would arrive with it, not before it.

## Borrow checking across procedure boundaries

The rule in [Borrows and lifetimes](design.md#borrows-and-lifetimes) treats a returned borrow as derived from every borrowed argument whose storage is reachable through a parameter. It rejects results attributed to temporary arguments before they can escape, so it is sound but coarse and can force copies in code that does not need them. Whether that imprecision is acceptable in practice can only be answered by writing a real library against it.

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

## More powerfull compile time feutures
    should we add stuff like compile time procedures and structs?
    The compile time untyped types are ergonomic but a little bit wierd and irregular.
    How does compile time in zig and jai work?

## Recoverable panics

Version 1 makes a panic unrecoverable: unwinding runs `defer`s and managed
`drop`s for cleanup, but there is no `recover`, `try`, or catch construct that
lets Loke code observe or resume from one. The [panic semantics](design.md#panics-and-unwinding)
are otherwise fully defined, including the two build-selected strategies and the
rule that `@(fini)` does not run on this path.

The open question is whether a later version should add a bounded recovery
mechanism — a per-thread catch at a task or request boundary, say — without
reintroducing general exceptions. The appeal is server code that wants to fail
one request rather than the process; the cost is a second control-flow path that
every `drop` hook and `defer` would have to be correct under, and the temptation
to use it as ordinary error handling in place of [`or_return`](design.md#or_return-operator).
Not required by anything in this document.

## Simplifying overload priority

[Overload resolution](design.md#operator-lookup-and-overload-resolution) currently
lets constraints participate in *ordering*, not only in whether a candidate is
viable. Tie-breaker 4 keeps structural specialization (`Table(string, int)` beats
`Table($K, $V)`) but then falls back to **constraint entailment**: between two
candidates of identical shape, the one whose normalized constraint set syntactically
entails the other's is more specific and wins. That entailment step carries the most
machinery of any single resolution rule — normalize as a conjunction, expand interface
composition transitively, alpha-rename bound names, test atom-subset — plus the caveat
that stronger reasoning must not change which overload is selected.

The proposal is to delete constraint entailment. Tie-breaker 4 would keep only its
structural half; two viable candidates that are structurally equal and differ only in
constraint strength would be an **ambiguity error**, resolved by naming the procedure
or by internal `when` dispatch. The mental model then collapses to: `interface` and
`where` decide *whether* a candidate is viable, and only structure decides *which*
viable candidate wins. Two things are unaffected — non-overlapping `where` filters in a
group (only one candidate is ever viable) and structural specialization — so the only
behavioral change is that auto-selecting a strictly-more-constrained overload of the
same shape (Rust-style specialization) becomes an explicit call.

The cost is an expressiveness loss for library authors who want a general
implementation plus an automatically-selected refinement. The benefit is a smaller,
more predictable priority order that fits the language's existing preference for
diagnosing ambiguity over resolving it implicitly. This is separate from the
[import-determinism](design.md#operator-lookup-and-overload-resolution) property, which
holds regardless; entailment operates on constraints fixed at each candidate's
declaration, so it is not itself an import hole. The question is comprehensibility
versus one advanced generic pattern, and it can only be settled by writing real generic
libraries against both rules.

# Differences from Odin and design motivations

This section is non-normative. It records why Loke differs from Odin and why
some larger design choices were made. [`design.md`](design.md) remains the
authoritative language definition.

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
`stack`, `static`, and `thread_local` control duration; none creates a second
type.

File-scope, `static`, and `thread_local` managed values are not automatically
dropped. A global destruction order across packages and threads would make
shutdown depend on initialization order and on whether other threads can still
reach a value. Externally observable cleanup therefore uses `@(fini)` or an
explicit owner in `main`.

### Storage modifiers instead of storage attributes

Odin spells static-duration locals `@(static)` and thread locals
`@(thread_local)`. Loke writes both in the declaration alongside `stack` and
`manual`, because they answer the same question those do — where does this
variable live, for how long, and who releases it — and because the answer changes
what the program does rather than describing it for a tool.

The dividing line is what survives dropping the annotation. Remove `@(link_name)`
or `@(export)` and the program still means what it meant; remove `static` and a
counter resets on every call, cleanup starts running at scope exit, and a borrow
that used to be returnable no longer is. Attributes are metadata; these are
semantics.

Splitting duration from ownership also made `stack manual Foo` expressible, which
a single modifier slot could not say.

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

### Panics run cleanup, not shutdown

Odin's managed model has no destructors, so a crash has nothing to unwind. Loke
adds managed `drop` and lifecycle hooks, which forces a decision Odin never had
to make: what runs when a program panics. The [answer](design.md#panics-and-unwinding)
is that a panic under the unwinding strategy runs exactly the cleanup attached to
live owners and `defer`s as it unwinds the faulting thread — so `defer os.close(f)`
and a resource's `drop` are reliable when they are on that thread's stack — and
nothing else. In particular
`@(fini)` does not run: it is orderly-shutdown code, and running end-of-program
hooks in a program whose invariants are already known broken tends to compound
the fault. An owner in `main` is cleaned only when `main` is on the panicking
thread's stack; a worker panic does not unwind other threads.

Two strategies exist because the machinery is not free: hosted builds default to
`unwind` for the cleanup, while freestanding and embedded builds default to
`abort`, which runs no cleanup and needs no unwind tables. Because a panic cannot
be caught either way, the choice never changes which programs are valid, only what
observable cleanup happens on the way down.

### Methods, interfaces, and operator overloading

Methods and `impl`/`extend` blocks let libraries attach behavior to records and
other types without embedding procedure declarations in every type definition.
An extension affects implicit lookup only in its declaring package; importers
use its named procedures through qualification unless they add a local
forwarding extension. This keeps an unrelated import from changing an existing
expression.
Interfaces describe compile-time capabilities used by generic code. The name
`interface` replaced the earlier draft's `concept` because it describes a
concrete programming-language role more directly.

Generic bodies and their interface requirements use definition-site lookup, so
a caller-local extension cannot change an existing instantiation. The built-in
map is stricter still: equality and hashing for a user key must be inherent to
the key type. Without that restriction, two packages could operate on the same
map using different hash policies and invalidate its contents.

Operator overloading, indexing, iteration, conversions, and lifecycle hooks let
library types be as convenient as built-in types.

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

### Statement labels and multi-level breaks

Labels made structured control flow read like a hidden `goto`. The common
multi-level exit cases can use a returned helper procedure, a loop condition,
or an `if` chain. Loke therefore keeps `break` and `continue` limited to the
innermost applicable construct.

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

### Owning type erasure and runtime interface values

`any_view` is deliberately borrowed and call-scoped. An owning `any` would need
stable payload allocation, allocator provenance, erased clone/drop behavior,
borrow rules across moves, and an allocation-failure contract. Those are also
the hard parts of runtime interface values. Version 1 uses unions for closed
sets and procedure tables for open runtime behavior instead of committing to a
vtable and erased-ownership model before real libraries validate one.

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

### Map element mutation

Odin prohibits `m[key].field = value`. Loke permits it because indexing a user
type can already return an `inout` place, and built-in maps should follow the
same place rules. Assignment through a missing key inserts a zero value first;
`&m[key]` remains a non-inserting lookup with optional-ok results.

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

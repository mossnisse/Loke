# Differences from Odin and design motivations

This document is non-normative. It records why Loke differs from Odin and why
some larger design choices were made. [`design.md`](design.md) remains the
authoritative language definition.
Open questions and unresolved findings are in [open-questions.md](open-questions.md).

## Added features compared to Odin

### Local borrow checking

Loke adds a deliberately small, procedure-local borrow checker. It catches
invalidating a container while a view is live and prevents obvious local
escapes without adding lifetime syntax. Named procedures and generic
instantiations infer result contracts that record borrowed parameters and
[carrier paths](design.md#values-that-contain-borrows), roots, and allocator-region
dependencies. Returning one field of a record argument uses that field's root
rather than everything the argument holds.

[Inferred callback types](design.md#procedure-result-contracts) preserve those
contracts: both `callback := choose` and `Chooser :: type_of(choose)` retain the
same provenance as a direct call. Copies and generic forwarding preserve it too.
The contract participates in type identity and compatibility, so changing a
published procedure's result dependencies can break clients.

Converting to a plain written `proc(...) -> T` signature erases that refinement;
converting back cannot recover it. Calls through that plain type conservatively
derive borrowed results from every borrowed argument not excluded by
[`@(escape=none)`](design.md#escapelevel). Owning results retain the region
dependencies of every moved owner and allocator argument. Plain signatures keep
this conservative precision tradeoff.

Raw pointers, stored borrows, foreign calls, and cross-thread lifetimes remain
explicit trust boundaries. This keeps low-level optimization and interop
possible without making unsafe behavior the default.

### Threads the language can start

The memory model, `thread_local` teardown, `Once` poisoning, `shared(T)`, and
atomic handle accounting on every `string` copy were specified and paid for
before anything in `core` or `base` started a thread, so no program exercised
them. `core:thread` is the smallest library that gives them a caller: `spawn`,
`join`, and `Mutex`.

Odin's `thread.create` hands the new thread a `rawptr` of data. `spawn` takes an
entry procedure and one moved argument instead, and the argument is checked
with `@(escape=static)`: any borrow it carries must be of process-lifetime
storage. The audit proposed "no checked borrow" at all; the escape level is the
rule the checker already had, and it lets a string literal travel while a
slice of a local does not. A static root can still race, but that is the case
the effect warning below covers. One argument is enough: several travel as a
record, and a procedure with no argument has its own overload.

A mutex beside its data would be of little use here. A `^T` cannot be written
through, so a `shared(T)` payload guarded by a `Mutex` field could not be
updated, and data in a global beside a mutex is exactly what the race warning
reports. So `Mutex(T)` owns the value, as Rust's does, and the guard returns it
as an `inout` result, whose provenance the language already ties to the guard.
Dropping an unjoined `Thread` joins it rather than detaching, so the owner of a
handle always outlives the thread.

The race check is a warning over the existing
[global write effects](design.md#global-write-effects): a spawned entry whose
effect writes shared, non-`thread_local` storage. Atomic operations and the
mutex take read-only receivers, so they are not writes and need no exemption.
It is a warning because it sees only globals and cannot prove that a global is
written only before a thread starts or after it is joined.

### Managed lexical storage

Strings, dynamic arrays, maps, and user resource types are owning values with
automatic scope cleanup. [`unsafe.forget`](design.md#unsafeforget) consumes an
individual value without cleanup; a lexical place is passed as
`unsafe.forget(move(value))`. `static` and `thread_local` control storage duration
without creating a second type.

File-scope and `static` managed values are not automatically dropped. A global
destruction order across packages would make shutdown depend on initialization
order and on whether other threads can still reach a value. Externally
observable process cleanup therefore uses a lexical owner, `defer`, or
`drop` in `main`. To extract a static-duration value for cleanup, use
[`exchange`](design.md#exchange) to leave a live replacement; direct `move` and
`drop` on that storage are forbidden. A managed `thread_local` has a natural
local endpoint and is dropped on normal thread return, in reverse initialization order;
aborting termination makes no such guarantee.

### Storage modifiers instead of storage attributes

Odin spells static-duration locals `@(static)` and thread locals
`@(thread_local)`. Loke writes `static` and `thread_local` in the declaration
because they specify where and how long the variable lives. The two modifiers
are mutually exclusive.

The dividing line is not metadata versus meaning: `@(packed)` and
`@(allocator_reset)` are attributes and both are load-bearing. It is that these
two answer a question about the declared storage itself, which is what the
declaration is for. Remove `@(link_name)` or `@(export)` and the program still
means what it meant; remove `static` and a counter resets on every call, cleanup
starts running at scope exit, and a borrow that used to be returnable no longer
is.

Cleanup suppression is a per-value operation through `unsafe.forget`, not a
declaration modifier.

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
keeps value semantics: a copy of an owner is independent of it, and the silent
shared-backing alias, the classic source of double-free and
mutation-at-a-distance bugs, is never produced. `b := a` over a `[dynamic]int`
clones it, from `b`'s declaration allocation policy. Immutable `string` and
`shared(T)` retain their storage instead. Shared mutable ownership is opted
into with a pointer or `shared(T)`.

This has gone back and forth. The allocating copy was first implicit, then
(0.7.1) an error, L0504, that offered `move(a)`, `a.clone()`, or a borrow: a
count across the examples and `tests/run` found the copy only in tests of the
copy rules, so requiring it to be written seemed to cost nothing. It is implicit
again because the error cost more than that count showed:

- assignment, the most common operation, did nothing useful for a whole class of
  types, and a beginner met three ways out of L0504 before a first `append`;
- adding a `[dynamic]T` field to a record of strings made every copy of the
  record elsewhere an error, so a private detail broke other packages;
- generic code copying a `T` had to write `.clone()`, so every copyable type
  needed one.

The cost the error guarded against is a hidden allocation. Loke already has
abstractions that hide work, and the answer here is to make the common case
free rather than forbid it: a copy at a local's last use is a move
([design.md "Last-use transfer"](design.md#last-use-transfer)), which removes
the copy people write when they mean "hand it over", and the copy-cost
diagnostic still reports large inline copies. What stays a copy is one whose
source is used afterwards, where the copy was the point.

Last-use transfer is decided on the procedure's control-flow graph, backward
from each candidate, and is conservative about borrows rather than exact: a
local that is ever stored into a borrow-carrying value, or passed as one to a
call with an `inout` argument, never moves at a last use, whether or not the
borrow is still live. An exact answer needs the provenance pass, which runs
after lifecycle analysis has already fixed each local's drop. The transfer is
then an ordinary `move(x)` in the syntax tree, so the borrow and region checks
see it as written, and a borrow the rule misses is an error at the copy with a
note, not unsoundness. It applies only to bindings and assignments; an
argument, an aggregate element, or an insertion still clones, which keeps the
rule short and each copy site's cost visible in one place.

A generic `clone` for fixed arrays and compile-time evaluation of a generated
`clone`, both added while the error stood, remain: the first is still needed by
generic code that clones, the second by constant evaluation of one.

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

Methods and `impl` blocks let libraries attach behavior to records and
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

The receiver is an explicit first parameter named `self`. A procedure in an
`impl` block is a method exactly when it declares one, so the declaration shows
whether it is called on a value or on the type, as instance and static methods
differ in Java. Writing it also places the receiver's mode where every other
parameter's mode is written: `self`, `self: ^`, `self: inout`, or
`self: move`.

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

`core:slice.sort_by` is the first standard generic callback algorithm built on
that choice. Its comparator is an ordinary record with an immutable `call`
method, so configuration and checked borrows remain typed and allocation-free. A
plain procedure is accepted too: the library wraps it in such a record, so it is
checked and lowered like one written by hand. The compiler erases addresses only
inside a generated call-scoped adapter to the shared runtime introsort; the
runtime neither owns nor retains the comparator. This keeps raw relocation and
one copy of the introsort below the language boundary without making `rawptr`
part of the user-facing callback protocol.

That settles the convention this area should follow: **a callable is a value
with a `call` method.** Three steps complete it, and none of them is worth
taking before something needs it.

A procedure should meet the convention itself, through a `call` the compiler
contributes to every procedure type, as it already contributes `iter` to the
built-in containers. One generic signature would then serve records and
procedures alike, a user's own included, and `sort_by`'s procedure member could
go. One standard API takes a `call` callable today, which is why that member is
a library wrapper rather than a language rule.

An API whose callable's result type varies cannot take a record at all. A
generic signature can name that type only by matching a procedure type, which is
why `Result.map_error` takes `proc(error: move E) -> $F`. Deriving a callable's
result from its only `call`, as an iterator's `Iterator` is derived from `iter`,
is what such an API would need first.

Closure syntax is then a shorthand for the same record and method, with written
captures, ordinary lifetime checks, and no implicit allocation. It is what gives
the other two steps a caller, so its capture, mutation, and escape rules should
be decided together with them. A callable that outlives the scope it was made in
stays a separate question. `fmt.Writer` and `log.Logger` were once cited as
needing one; they turned out to need only a `dyn mut` view
([Formatting and logging sinks are `dyn` views](#formatting-and-logging-sinks-are-dyn-views)).

### Typed fallibility, and the `Option` decision it reverses

An earlier revision of [`design.md`](design.md) said the language and core
library define no `Option`, `Maybe`, or `Result`, that a procedure with no value
returns `(T, bool)`, and that nothing prevents a library from declaring its own
`Option` because "no language construct is aware of it". That decision is
reversed. `Option(T)` and `Result(T, E)` are now ordinary generic unions in
`base:runtime`, and `or_else` and `or_return` are specified over the *shape* a
union declares rather than over a trailing result's position.

The old answer was defensible on its own terms — a trailing `bool` is cheap and
needs no library type. What it could not do was compose. A `(T, bool)` result
lived only in a result list: it could not be stored in a field, passed through
an unconstrained generic, or returned through a procedure value without a caller
rebuilding the convention by hand. Every producer that wanted the shape needed
privileged syntax, and every consumer needed to know which of two spellings it
was looking at.

Two shapes also cost more of the language than they looked like they did. To
make a trailing error work, a union needed a nil state to be the successful
value, which needed an `active_typeid()` to ask what was in a non-nil one, which
could not discriminate two variants sharing a payload type — so `Result(int,
int)` was not expressible. Meanwhile the specification carried an "optional-ok"
rule letting a destination change a producer's result count, and a "status
result" concept with two admissible spellings and an explicit list of types that
compare against `nil` but are *not* statuses. One shape removed all of it.

The migration was not free, and the cost is recorded rather than waved at:
front-end time rose 7–18%, largest on the smallest program, because
`base:runtime` is a fixed charge; an empty program's binary is byte-identical,
and two real example programs grew about 3%. The change also surfaced nine compiler defects, each fixed with the
migration.

One library contract changed with it. `io.Reader.read` used to return a count
*and* an error together, so a reader could report progress and a failure in one
result. A `Result` carries one or the other, so progress is reported and the
failure surfaces on the next call — the same contract Rust's `Read` has, and one
every helper in `core:io` was already written for, because they all loop until
they have what they asked for.

### One result, and the compatibility break that came with it

A procedure returns at most one value. Multiple results, named result locals,
and the bare `return;` that published them are gone, and so is the
definite-initialisation dataflow that existed only to let `or_return` perform
that bare return with several results outstanding. Several values are returned
as one [anonymous record](design.md#anonymous-records) and taken apart by
[destructuring](design.md#destructuring), which is now one rule in declarations,
assignments, and `foreach` rather than a result-only special case.

The migration cost was near zero because typed fallibility had already collapsed
the library to single results: `core:` had exactly one multi-result procedure
(`strings.encode_rune`), `base:` and `examples:` had none, and five naked
returns existed in the whole live corpus. Everything else was test fixtures for
the mechanism being deleted.

**The break.** `-> (a: int, b: int)` keeps compiling and changes meaning: it was
two named results, and it is now one record result. Result names used to be
excluded from procedure-type identity, while anonymous-record field names are
part of it — so `proc() -> (a: int, b: int)` and `proc() -> (x: int, y: int)`
were compatible before this phase and are not after it, through a procedure
value, an overload, an interface slot, reflection, and ABI lowering alike. The
one-result form changes too: `-> (n: T)` was one named `T`, and is now a
one-field record. `-> (T, U)` is no longer a type and says so.

That break is the price of the answer to the identity question. Interning on the
*semantic* vector — the ordered `(field name, field type)` pairs, compared pair
by pair — rather than on a printed type name is what keeps two packages'
unrelated `Token` types from collapsing into one record type merely because both
print as `Token`. A display-string key would have been shorter and wrong.

One pre-existing defect surfaced during the migration and was fixed with it: a
composite literal's *named* elements were joined into every borrow-provenance
path instead of being resolved to the field each names, because the checker's
resolved slot was not carried into the flow graph. Every migrated record literal
is written with named fields, so this turned an exact per-field result
provenance into a join. The same missing information was behind a second bug:
named call arguments evaluated in *parameter* order rather than source order.
Both now read the slot the checker already chose.

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

### Colon annotations on inferred generic bindings

The parser used to accept `x: $T: Shape`, but the checker bound `T` without
checking `Shape`; even `x: $T: []int` accepted `3.5`. The specification gave
the annotation no meaning. It is now rejected (`L0258`) at the declaration,
including an unused generic, rather than carrying an unenforced constraint.

[Specialization](design.md#specialization) already writes the shape in the
parameter type, such as `[]$Element`, and [where clauses](design.md#where-clauses)
filter inferred types by compile-time predicates. A fixed `[]int` parameter
needs no generic binding. Explicit parameters such as `$T: type` keep their
ordinary parameter-list type annotation. A new annotation would need a defined
matching and conversion rule before it could add anything to those mechanisms.
The parser recovery regression is
[tests/syntax_err/inferred-constraint.loke](tests/syntax_err/inferred-constraint.loke).

### Floating generic arguments use representation identity

The converted IEEE-754 encoding identifies a floating generic argument. Generic
code can observe a zero's sign through division or inspect a NaN's payload with
`unsafe.transmute`, so merging numerically equal arguments would let the first
instantiation's value replace the next caller's. Numeric equality also fails to
identify a NaN with itself, making it unsuitable for repeated bindings.

Instance and witness keys use the constant's retained encoding at its converted
width, and repeated bindings, concrete `impl` arguments, and `dyn` conversions
compare that same key. Using the widened numeric field alone lost the signalling
bit of an `f32` NaN and could merge distinct arguments. The rule applies inside
aggregates too; ordinary numeric comparisons keep their floating-point semantics.
See [Generic argument identity](design.md#generic-argument-identity) and the
[run](tests/run/generic_float_identity.loke) and
[error](tests/err/generic_float_identity.loke) regressions.

### Constraint entailment in overload resolution

An earlier draft let [the specialization tie-breaker](design.md#operator-lookup-and-overload-resolution)
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
innermost loop. A switch is selection rather than iteration and is not a break
target; its cases already stop automatically.

### File-private visibility

`@(private="file")` is gone; `@(private)` now takes no argument and names package
visibility explicitly, which is only load-bearing inside a file whose package
clause carries `@(public)`. A package is the encapsulation boundary, and one
level of hiding *inside* that boundary cost an attribute value, a package-clause
form, a mutual-exclusion rule against `@(public)`, and a rule for opting back out
of a file-wide private default. A file that wants its own boundary wants to be a
package.

### Standard free aliases

A closed set of nine names — `len`, `cap`, `hash`, `format`, `compare`, `iter`,
`iter_reverse`, `clone`, `try_clone` — used to perform receiver lookup, so
`len(x)` and `x.len()` selected one declaration. The second spelling bought no
expressiveness and cost four rules: the closed set itself, a restriction to
immutable receivers, a matching rule keeping mutators method-only so their
receiver borrow could not hide in free-call syntax, and a rule that an alias
contributes no overload candidates of its own. All four exist only to keep the
two spellings from disagreeing.

The method is now the only spelling. `len(x)` is not a call, a free procedure
named `len` is an ordinary declaration, and the one remaining rule is the one
already needed: `f(x)` is a lexical call and `x.f()` is a receiver call. The
built-in types keep their compiler-contributed `len`, `cap`, and `hash` members,
which is what `x.len()` selects on a slice exactly as on a user record. A fixed
array's and a vector's lengths stay properties of their type, but `x.len()` is
still an ordinary call and still evaluates `x`; the unevaluated operand is
`size_of`'s job, not a method call's.

### `mem.` spellings of the allocation built-ins

`design.md` once promised that `new`, `new_clone`, `make`, `free`, `free_all`,
and `drop` were also available in package `mem`. No compiler ever contributed
them, and a second name for each built-in would buy nothing: each allocating
built-in has a `try_` form returning `Result(T, Allocator_Error)`, so there is
no stricter error handling left for a `mem.` spelling to add. The universe name
is the only spelling.

### `fallthrough`

Multi-value case lists cover what most C fallthrough chains are written for, and
a case that must run another case's body calls a shared procedure. Keeping a
keyword to reintroduce the C behaviour that Loke's `switch` exists to remove was
not worth the reserved word, the statement, and the extra clause in the `defer`
restrictions.

### Named-result initializers

`-> (color := "blue")` was removed first, then named results themselves. The
initializer resembled a parameter default but fired on a different condition —
every entry, rather than every call that omits an argument — and two similar
spellings with different trigger conditions is a poor use of syntax. What
remains is simpler still: a result is anonymous and `return` always carries its
value.

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

### User-defined implicit conversions

There are none, at either scale. A general facility would have converted runtime
values silently based on what happened to be imported, so it was cut early; what
survived it was `@(implicit)`, a narrowed form that applied a one-argument
`hook(convert)` to an unfixed constant only. That went too.

Its motivating case was literals entering library numeric types: `z*z + 2.0`
should mean what it looks like. But the version that does is `z*z +
Complex_F64(2.0)`, which is four characters longer and needs no language feature.
Against that, `@(implicit)` cost an attribute, a rank below every built-in
conversion in overload resolution, an interaction with the unfixed-constant
rule, and a standing proof obligation that conversions cannot chain.

Removing it also removed the rules that existed only to contain the general
version: the cap on conversion chain depth, the argument that lookup terminates,
and the advice that implementations warn about lossy implicit conversions.
A conversion now happens exactly where one is written.

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

### No octal escapes

Odin's `\NNN` is a byte, as in C and Go. Loke's named a code point up to U+01FF
and UTF-8 encoded it, so `"\377"` was the two bytes of `ÿ` where C gives the
one byte `0xFF`: the escape a C programmer uses to write a byte meant something
else. `\x` spells a byte and `\u` a character, so it added nothing, and only
one test used it. It is removed; a backslash followed by a digit is an error
that names `\x` and `\u`.

### Sized boolean types

Loke has a single one-byte `bool`. Boolean-looking foreign typedefs bind as their
actual integer representation and are converted in a wrapper. This also handles
encodings such as `VARIANT_BOOL`, whose true value is `-1`, without pretending
that every foreign boolean is just a differently sized Loke `bool`.

### Unchecked union extractions

A union has no unchecked extraction: it is inspected with a `switch`, whose
cases are variant names and which the compiler requires to be exhaustive. A
branch pattern such as `.some(value)` exposes the payload only in the arm that
has already checked that variant. There is no spelling that reads one variant's
payload while another is active.

`value.as(.name)` is the checked read for code that wants one variant without a
switch. It tests the tag and yields an `Option`, the union counterpart of
`view.as(T)` and `Enum.from_int`, so `or_else`, `or_return`, and a switch on the
`Option` all apply. It copies rather than borrows because an `Option` cannot
hold a borrow, which is why a move-only payload still needs a switch. There is
no panicking `value.(.name)`: `or_else` makes the safe form just as short.
Interpreting the wrong payload as an owning type can manufacture a container
header from unrelated bits and later pass an invalid pointer to `drop`.
`unsafe.transmute` and raw storage in `core:unsafe` remain available for explicit
low-level work, and the checked extraction that does exist — `view.(T)` on an
`any_view`, where the set of types is open — traps rather than guessing.

## Changed features

### Unchecked operations need the import

design.md [The `unsafe` package](design.md#the-unsafe-package) always said the
`core:unsafe` import was the review mechanism, but three operations that give an
unchecked address a usable shape were ordinary syntax. With no import at all, a
procedure could return `(^mut int)(r)` for `r: rawptr = &mut local`, slice a
freed dynamic array through `([^]int)(rawptr(&mut values[0]))[0:3]`, and write
`d: [dynamic]int = ---; d.append(1);`, which stopped at run time with
"allocator record does not match this runtime's ABI".

The conversions and C-pointer accesses now need the import in the file that
writes them, and `---` is limited to plain data. Losing provenance stays free —
anything converts to `rawptr`, and `^T` to `[^]T` — because nothing can be read
through the result without one of the gated operations. The rule is per file
rather than per expression because the import is already the unit a reviewer
searches for, and the cost was two library files: `core:fmt` and `core:io`,
both for `fmt.Writer`'s `rawptr` state, which the `dyn` sinks below have since
removed. `base:` packages are exempt: they are
the runtime, reach the same operations through compiler-contributed names, and
cannot import `core:`.

### Formatting and logging sinks are `dyn` views

`fmt.Writer` and `log.Logger` were a procedure beside a `rawptr` of state, so a
sink that formatted into its own record converted `state` back to a typed
pointer: `core:fmt` did so in `to_string`'s collector, and `core:io` in the
latch adapter standard-library.md had to call "not a safe construction". The closing
paragraph of
[Build-selected services](#build-selected-services-and-explicit-runtime-state)
said neither a generic parameter nor a borrowed `dyn` describes a handle kept
for the life of the program. Neither use needs one. A
formatter uses its sink only for the call, which is what a borrowed `dyn mut`
view is, and a logger's factory already has to return process-lifetime
storage, so a `dyn mut` view of a `static` record is exactly that handle.

Both are now aliases of `dyn mut` views: `fmt.Writer :: dyn mut fmt.Sink`, with
one `write(bytes: []u8)` slot, and `log.Logger :: dyn mut log.Sink`. A sink is
any record with the method, the collector and the latch are ordinary records,
and neither library imports `core:unsafe`. What it cost is in the seed runtime,
whose scalar formatters write through a `Writer`. The generated module now
supplies `loke_rt_v1_sink_write`, which calls the witness's one slot with a
slice built in LLVM, so no C prototype has to agree with how LLVM passes a
two-word aggregate, and the process streams are a compiler-emitted witness
whose data pointer is the stream selector. A nil `Writer` used to write
nothing; it now panics, as every slot call through a nil view does.

A logger is no longer comparable with another: views are comparable only with
`nil`. The provider test that compared `current().write` with
`standard_logger().write` to see whether publication had happened now logs a
record and checks whether its own sink received it.

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

### Closed enums and payloadless unions

Enums are closed sums whose variants carry no payload. They retain `enum`
syntax, explicit integer representations, and integer ordering, while sharing
the meaning of variants and exhaustive control flow with tagged unions. A switch
covering every variant now guarantees that a case runs; when every arm returns,
no trailing return is needed.

The former unchecked integer conversion made member coverage weaker than value
coverage. [`Enum.from_int`](design.md#integer-conversion) now validates the
backing integer and returns `Option(Enum)`. Foreign APIs and wire formats keep
unknown numbers in an integer or `distinct` integer wrapper until validated.
Its argument may be any integer type: validation, not the argument's type,
decides membership, so demanding the backing type only moved a narrowing
conversion, which is what `from_int` exists to avoid, onto the caller. It also
keeps a small explicit backing type (`enum u8`) cheap to choose, which is why
the default stays `int` rather than shrinking to fit the members and tying the
enum's layout to its member list.
An enum without a variant represented by zero has no zero value, and that
restriction propagates through aggregates just as it does for unions.

### Signed overflow panics

Signed `+`, `-`, `*`, and `<<` used to wrap two's-complement, defended against
C's undefined overflow: a meaning that does not change under optimization is
worth more than the loop optimizations undefined overflow buys, because the
alternative is a program whose correctness depends on a compiler flag.
Trapping was never weighed, and it keeps that property while catching the bugs
the library had guarded by hand:

- `strings.repeat` reserved `text.len() * times`, which wrapped to a small
  reservation (fixed in `c2f30eb` with a hand-written bound);
- `String_Builder.try_reserve` computed `len + additional`, which wrapped
  negative (same commit);
- `core:fs` documents a tick subtraction in `unix_nanoseconds` that would wrap
  an unrecorded time into the far future.

All three are `int` or `i64`. Nothing in `core`, `base`, or the examples relied
on signed wrap: turning the rule on changed three corpus programs, each of which
existed to demonstrate wrapping. The rule is also what the rest of the language
already did where a value does not fit — `u32(-0.5)` panics, while
`i32(2147483647) + 1` gave `-2147483648` silently.

So signed `+`, `-`, `*`, `/`, and unary `-` panic when the mathematical result
does not fit, at every optimization level, and are a diagnostic (L0397) where
they are evaluated at compile time. Unsigned arithmetic stays modular, since
hashing and bit manipulation are written in it, and signed wrap is spelled by
computing in the unsigned type and converting back, which keeps the low bits.
The exceptions each keep an existing definition: `<<` is a bit operation whose
limit is already defined for every count; `%` cannot overflow; a SIMD lane has
no per-lane overflow flag to test; an atomic `add` is a hardware
read-modify-write whose other readers have already seen the result; and integer
conversion is the explicit wrap.

The cost is a checked operation, `llvm.sadd.with.overflow` and its siblings, per
signed arithmetic step, much of it removed where loop bounds already prove the
range. It returns part of what wrapping cost: on the path that continues, the
result is known to be in range, so the optimizer may widen induction variables
the old rule forbade it to.

### `in` is a comparison, not an additive operator

Odin places `in` at the comparison precedence level and Loke had moved it to the
additive one. That silently regrouped `x in values + extra` as
`(x in values) + extra`. `in` produces a `bool`, so it belongs with `==` and `<`.

### Comparisons do not chain

Odin, like C, groups comparisons left, so `a == b == false` is
`(a == b) == false`: for `a := 1; b := 2` it is `true`, although it reads as a
chain and is not one. Ordering chains such as `1 < 2 < 3` were already rejected
by type, leaving only the misleading `bool` equality chains. Making the
comparison level non-associative, as the range level already is, turns every
such chain into a syntax error whose note gives both the parenthesised form and
the `&&` chain. Nothing expressible is lost: `(a == b) == c` still means what it
says.

### Field order stays inside the declaring package

Odin accepts an imported struct's positional literal, so reordering the
struct's fields, a routine change to remove padding, silently swaps any two of
the same type at every such site; destructuring would add more. With
`Point :: struct { y: int, x: int }`, formerly `{ x: int, y: int }`,
`x, y := origin_offset()` would put the old `y` in `x`, and `Point{3, 4}` would
set `y` to 3, and both would compile. Outside the declaring package both forms
are therefore rejected in favour of named fields, as Go vet treats unkeyed
fields of an imported struct. Inside the package, a reordering is a change its
author can see. Anonymous records are unaffected, since their field order is
their type identity, so `core:container`'s `Enum_Array` yields
`(key: E, value: T)` rather than a nominal entry struct. The migration was 85
literals, all in tests; 50 of them were `core:math` `Complex` and `Quaternion`
values in one file.

### Diverging procedures belong to the declaration

Loke takes Odin's `-> !`. Before it, a call that never returned could not say
so: `os.exit` at the end of a value-returning procedure was L0365, and `panic`
was not a value, so `m.lookup_value(key) or_else panic("missing")` was L0309.
The library wrote a one-line procedure per fallback type instead, ten in core
and nine in tests, all now gone.

Unlike Odin, divergence is not part of the procedure type. A diverging call
takes whatever type its context expects, which the checker settles from the
callee's declaration; carrying it through procedure values would add a
subtyping rule (`proc() -> !` wherever `proc() -> T` is expected) for a case
nothing in the tree needs. A later change can add it without breaking code.

### The allocation built-ins follow the `try_` convention

Odin's `new` and `make` return the value and an error. Loke's returned a
`Result` under the plain name, the opposite of the library-wide convention
that `try_` marks the form returning the failure its plain form would panic
on. Callers wanted both: of the twelve calls in `core` and `base`, seven
returned or reported the error and five turned it into a panic through a
one-line helper, and design.md's `make` examples used `or_else {}`, which
turns an allocation failure into an empty container. `new`, `new_clone`, and
`make` now follow the allocator's failure policy, and `try_new`,
`try_new_clone`, and `try_make` return the `Result`. About a hundred calls in
`tests/` changed spelling.

### `main` may return an `i32` status

Odin's `main` has no result, and neither had Loke's. Since `os.exit` runs no
cleanup, a program that had to fail after cleanup moved its body into a
helper and called `os.exit` on what the helper returned. `main :: proc() ->
i32` returns the status instead, after its scope-exit actions, as C's `main`
does. The status is `i32` because that is what the process gets: `os.exit`
took an `int` and narrowed it, so `os.exit(4294967297)` exited with 1. It now
takes an `i32` as well, and a wider value needs an explicit conversion.

### `assert` and `panic` print values after the message

Odin's `assert` and `panic` take a runtime message string, and `fmt.assertf`
and `fmt.panicf` format one. Loke's message is a compile-time string, so the
report never needs an allocation that could itself fail, and a failed check
could not say which value failed it. Values now follow the message as
`..any_view` arguments. The generated code formats them onto the report line
through the same per-type formatters `fmt.print` uses, writing straight to
the error stream, so `base` and `core` code can use them without importing
`core:fmt`. The runtime's panic entry is split into a begin and an end so the
values land between the message and the newline. An `assert`'s arguments are
evaluated only on the failing path, like its message in C, so an expensive
argument costs nothing while the check holds.

### An iterator's yield mode follows from `next`

An iterator used to declare a `Yield` descriptor, built from the predeclared
markers `Yield_Owned`, `Yield_Borrowed`, and `Yield_Mutable`, and the checker
computed `Item` from it and `Element`. The declaration carried no
information: `next` already says what it returns, and a `Yield` that
disagreed with it was an error. The checker now reads the mode off `next`'s
`Item`, as it reads `Iterator` off `iter`, and the three markers are gone from
the universe. The library declared `Yield` three times, in
`Small_Array_Iterator` and the two `Enum_Array` iterators, and the compiler
no longer synthesizes one for its own iterators. The derivation tries owned
before borrowed, so an element that is itself a pointer, returned unchanged,
stays owned; the old descriptor could say otherwise only by making `Item` a
pointer to the pointer, which `next` would then have to return anyway.

### A map's mutable lookup is the marked one

Everywhere else the mutable form is the marked one: `^mut`, `[]mut`,
`dyn mut`, `iter_mut`, `get_mut`. The map had it the other way round, with
`find` returning `Option(^mut V)` from an `inout` receiver and the read-only
probe spelled `find_ref`. `find` now returns `Option(^V)` and `find_mut`
`Option(^mut V)`. Every call in the tree was renamed to keep its meaning.

### A `[]mut T` destination selects a mutable slicing overload

A slice of a mutable place is `[]mut T` when a `[]mut T` destination asks for
one, but a user container could not do the same: `operator([:])` overloads
were ranked by their arguments alone, so `Small_Array`'s one read-only
overload made `sv: []mut int = s[0:2]` L0310 where the same line over a
dynamic array compiled. A `[]mut T` destination now counts as a place
position for slicing, as an `inout` argument does for indexing, and
`Small_Array` has a `span_mut` overload for it. Its `slice()` stays: a method
receiver is not a destination, so `small.slice().indexed()` still names the
mutable view it iterates.

### A string literal receiver is a static `string_view`

`"hello".len()` compiled and `"hello".bytes()` was L0363, because an unfixed
receiver took its default type, `string`, through ordinary method lookup,
while the text operations looked only at receivers whose type was already
fixed. A literal's storage is static, so the receiver that describes it
without an owner is a `string_view`, and nothing borrowed from it can end:
`"hello".bytes()` may be returned from a procedure. An extension method
declared on `string` alone no longer applies to a literal receiver; the
view is what the literal is.

### Map element mutation

Odin prohibits `m[key].field = value`. Loke permits it because indexing a user
type can already return an `inout` place, and built-in maps should follow the
same place rules. It writes a field of an element that must already be there:
creating one to hold a partial update was a way to end up with a half-written
object nobody asked for, and it made the read depend on whether the element type
had a zero at all. So the whole-element assignment `m[key] = elem` is the one
index form that creates an entry — it writes the value, so nothing is
manufactured — and every other position panics for a missing key, as a dynamic
array's index does. `m.find(key)` answers `Option(^mut V)` without inserting,
and `m.find_or_insert(key, elem)` answers the slot either way, so a caller that
wants a default names the default rather than inheriting the element's zero.

### Container insertion takes its element like an initialization

`append`, `insert`, `try_insert` and `find_or_insert` once borrowed their
element and cloned it in, which left a move-only element no way into a
container but `m[key] = elem` and a literal. Giving them `move` parameters was
rejected: `move(...)` needs a lexical owner, so `d.append(File{...})` could not
be written at all, and `d.append(move(x))` would be required for every `int`.
Instead the element is taken exactly as `x := elem` takes it — a temporary or
`move(x)` transfers, a borrowed place copies — which is already what assignment
and literals do. A copyable element reads and behaves as before; a move-only one
needs `move(x)` only where any other copy of it would. The operation owns the
element from the call, so it drops the one it does not store: the duplicate a
`find_or_insert` hit makes unnecessary, or a pack an allocation failure left out.

### `string` borrows as `string_view`

`string` converts implicitly to `string_view`. Without it the two types compete
for every signature that reads text: an API taking `string` cannot accept a
substring without allocating one, and an API taking `string_view` makes every
caller holding a `string` write a conversion. The conversion is a borrow, costs
nothing, and needs no validation, so the division is simply that `string_view`
reads and `string` owns. It is one-way; going back allocates, via `.copy()`.

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

### `transmute` is a procedure in `core:unsafe`, not an operator

Odin spells a bit cast `transmute(T)value`, which needs a reserved word and its
own unary binding rule. Loke writes `unsafe.transmute(T, value)` and makes it an
ordinary call — types are already passable as arguments, so nothing was gained
by the operator form except a keyword. `move` stays a keyword because it is also
a parameter mode and has to be reserved regardless.

It is not predeclared either. Reinterpreting bits is not a safe, universally
valid conversion: nothing about the source value says the destination
representation is one its type ever admits. That is the same loss `raw_data` and
`free` make visible, so it is spelled at the same boundary and an import says
the program does it.

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

`x.f()` resolves only to a `self` receiver declared in an `impl`
block, or to a built-in container operation. There is no rule rewriting `f(x)`
as `x.f()`, and none rewriting `f(x)` to a receiver either — see
[Standard free aliases](#standard-free-aliases) above. Free procedures therefore
never acquire a method spelling by accident, and every receiver operation reads
the same way: `x.len()` and `x.append(v)` are both calls on a named receiver.

### `foreach`

Odin's `for value in values` form is written `foreach (value in values)`.
Keeping `for` and `foreach` separate makes the repetition form visible at the
keyword and lets `in` retain its membership-operator meaning in an ordinary
`for` condition.

`for (key in counts)` is nonetheless rejected: it is the header a programmer from
Odin, or one who forgot `foreach`, writes, and as a membership loop it compiled
and ran whenever `key` happened to be declared, or failed with only "unknown
name `key`". `for` therefore takes the rule `switch` already uses for the same
collision: the membership loop is `for ((key in counts))`.

## Features kept close to Odin

### Foreign declarations

The foreign system intentionally remains close enough to Odin that maintained
bindings can be ported mechanically. A port mainly updates visibility and
attributes and replaces owning C-string assumptions with `cstring_view` or the
appropriate explicit foreign-string type. Bindings keep foreign symbol spelling
and can expose an idiomatic wrapper separately.

## Formatting

`lokec -fmt` ([src/formatter.odin](src/formatter.odin)) settles the layout
`core/` already used, and changes whitespace only. The rules:

- **Line breaks are the author's.** It never joins or splits a line, and a run
  of blank lines becomes one. Wrapping at a width was rejected: it is most of a
  formatter's code, and a renamed identifier would re-flow its neighbours in a
  diff.
- **Tabs, one per enclosing bracket** opened on an earlier line, however many
  opened together. A `case` sits at its `switch`'s level, and a line that
  continues an unfinished statement outside any `(` or `[` goes one deeper. A
  file-scope `when` body stays at column zero when written there, as `core/`'s
  long platform blocks are.
- **Spacing between tokens** is one space after a comma, around `::`, `:=`,
  assignment, comparison, logical, range, and arrow operators, and none inside
  brackets, before `,`, `;`, `)`, and `]`, or after a prefix operator. An
  arithmetic or bitwise operator written with no space on either side stays
  tight, because `core/` writes `a*b + c*d` by precedence; one written with a
  space on either side gets one on both.
- **Extra spaces inside a line are kept.** `core/` aligns field types and
  trailing comments with them. Only the leading indentation is recomputed.

It works on the real lexer's tokens rather than printing the syntax tree:
keeping the author's breaks leaves nothing for a tree printer to decide, and a
token stream cannot lose or reorder syntax. The parser still runs, so a file
that does not parse is refused, and each result is lexed again and must hold
the input's tokens exactly, or the formatter reports an internal error instead
of writing. tests/corpus_test.odin keeps `core/` and `base/` formatted and
formats every program corpus to a layout that formats to itself.

Possible refinements are recorded in [open-questions.md "Formatting"](open-questions.md#formatting).

## Extended UNC volume boundaries

Extended UNC paths use the same server/share boundary as ordinary UNC paths,
after the `\\?\UNC\` marker. Recognizing that boundary in `path.volume` fixes
every lexical operation that stops at a root and lets `fs.create_directories`
begin below the share. It does not normalize the path: [Windows's extended-path
rules](https://learn.microsoft.com/en-us/windows/win32/fileio/maximum-file-path-limitation)
require preserving its text, so `clean` continues to return it unchanged.
The contract is in [standard-library.md "`core:path`"](standard-library.md#corepath),
with regression cases in [tests/run/lib_path.loke](tests/run/lib_path.loke).

## Portable process input and path errors

Environment names are non-empty and exclude `=` and U+0000. Rejecting them
before a platform call gives reads, writes, and removals the same `Invalid_Data`
answer without confusing an invalid name with a missing variable. The existing
`Result(Option(string), io.Error)` already separates those outcomes; no API
signature change or native allocation is needed for validation.

Windows [path errors](https://learn.microsoft.com/en-us/windows/win32/debug/system-error-codes--0-499-)
123, 161, 206, and 267 normalize to `Invalid_Path` in both process and filesystem
operations. In particular, giving an existing file to an operation requiring a
directory preserves that identity and the native code instead of reporting
`Other`. The contracts are in [standard-library.md "`core:os` additions"](standard-library.md#coreos-additions)
and ["`core:fs`"](standard-library.md#corefs); regressions live in
[tests/run/lib_process.loke](tests/run/lib_process.loke) and
[tests/run/lib_fs.loke](tests/run/lib_fs.loke). The separate native translation
tables remain an [open question](open-questions.md#open-questions-in-coreos).

## Malformed console input

Programs can write arbitrary UTF-16 units into the console input buffer.
`read_key` reports unmatched surrogates as `Invalid_Data`, matching `read_line`
and letting callers decide how to recover. This keeps character events valid
Unicode scalars without silently replacing or dropping malformed input.

The existing repeat buffer holds a valid key following an unmatched high half,
so reporting the error preserves that key's order, modifiers, and repeats.
Another high half remains pending and can begin a valid pair. The contract is
in [standard-library.md "Raw mode and key events"](standard-library.md#raw-mode-and-key-events),
with injected-input regressions in
[tests/run/lib_term_console.loke](tests/run/lib_term_console.loke).

## Two slices of one local array in one call

`fmt.println(primes[1:4], total(primes[:]))` is rejected (`L0511`): slicing a
mutable local gives `[]mut int`, which keeps that type inside the `any_view`,
so the second slice conflicts with it. That follows [design.md "Slices"](design.md#slices),
and an extracted `[]mut int` could indeed write. A reader who only prints binds
`middle := primes[1:4];` first, as in
[Arrays and slices](tutorials/04-strings-and-containers.md#arrays-and-slices).

Erasing a fresh slice into an `any_view` could settle it read-only, as a `[]T`
destination does, but that would make an erased slice's type depend on where
it lands. The rule stays: one extra binding is a small price for a slice type
that does not change.

## Compiler regression fixes

The checker fuzzer's fixed-array slowdown came from emitting every earlier
element's cleanup separately at every possible copy failure. The backend now
uses its existing reverse-prefix drop loop at each failure point, so generated
cleanup grows linearly with array length. This preserves the completed-prefix
and reverse-order guarantees in [design.md "Lifecycle hooks and resource types"](design.md#lifecycle-hooks-and-resource-types).
[src/emit_llvm_test.odin](src/emit_llvm_test.odin) checks IR growth and
[tests/run/fixed_array_clone_failure.loke](tests/run/fixed_array_clone_failure.loke)
checks success and failures at each element.

An index whose integer conversion failed previously continued into the bounds
check. Returning immediately preserves its `L0352` cause and avoids a false
`L0361` follow-on. Every field error receives its instantiation context; the
reporter prints an identical cause once with the additional contexts. Human
argument spellings are separate from cache keys: arrays print their type and
elements, signed zeros remain distinct, and NaNs retain their encoding in the
display. Instantiation notes abbreviate long names at UTF-8 boundaries.
Regressions include [generic field errors](tests/err/generic_field_diagnostics.loke),
[index conversion errors](tests/err/invalid_index_materialization.loke), and
[floating generic identities](tests/err/generic_float_identity.loke).

Ctrl+letter key events retain the console's control character rather than
inventing a printable letter. The explicit contract is in
[standard-library.md "Raw mode and key events"](standard-library.md#raw-mode-and-key-events),
with Ctrl+C/I/M regressions in [tests/run/lib_term_console.loke](tests/run/lib_term_console.loke).

## Compiler architecture audit (2026-09-28)

The audit reviewed revision `b2cc712`, tracing the driver, checking, CTFE,
generics, ownership, emission, runtime interface, and test harnesses. Its
corrective findings A1–A10 have since been addressed. Their original priority
order is no longer a work list; the current contracts are in
[compiler-architecture.md](compiler-architecture.md), and the remaining
structural questions are in
[open-questions.md](open-questions.md#open-questions-in-the-compilers-structure).

The review favored enforcing the existing phase boundaries over adding an IR
or splitting the compiler into packages. Stable IDs, arena ownership, one
annotated AST, explicit call operations, shared constant operations, and a
separate toolchain layer already fit the compiler. The completed follow-ups:

- **A1: Bound constant construction.** Literal folding and zero values use the
  CTFE element budget, while large runtime literals need no eager constant.
  Regressions include [large constant arrays](tests/err/large_constant_arrays.loke),
  [runtime literals](tests/run/large_literal_runtime.loke), and
  [LLVM arrays](tests/ll/large_arrays.loke).
- **A2: Collect generic bindings from syntax.** `pattern_shape` replaced the
  raw-source scanner, so comments cannot introduce or hide bindings.
- **A3–A4: Close the emission boundary.** Carrier fields and semantic registries
  are settled before emission; the backend validates them and checks that
  emission cannot grow semantic state. Tests in
  [src/emit_llvm_test.odin](src/emit_llvm_test.odin) cover the production path
  and reject incomplete phase state.
- **A5: Centralize speculative commitment.** Enrollment uses `committing(c)`;
  probe rollback and cached rejection diagnostics follow the same protocol.
  [src/front_end_test.odin](src/front_end_test.odin) checks registry isolation,
  and [generic probe then use](tests/run/generic_probe_then_use.loke) and its
  [error cases](tests/err/generic_probe_then_use.loke) cover later real uses.
- **A6–A7: Fix analysis storage and reset identities.** Superseded provenance
  graphs are reclaimed, and reset points retain the exit and `defer` expansion
  identity needed to check owners live at each exit.
- **A8–A9: Validate runtime ABI and cache inputs.** `runtime_abi_matches_header`
  lowers the C header with clang and compares signatures, calling-convention
  attributes, and record layouts with LLVM emission. `runtime_cache_follows_build_inputs`
  checks reuse and invalidation of prebuilt objects. Both live in
  [tests/runtime_test.odin](tests/runtime_test.odin).
- **A10: Resolve generic member applicability consistently.** Specialization
  and ambiguity use the overload rules, including instances created before a
  more specialized block is registered.

The original review's quick gate passed 1,010 specification citations, 100
compiler unit tests, the vetted build, and 33 integration functions. NASM was
unavailable; the optimization matrix and mutation fuzzer were not run locally.
Those counts describe the reviewed revision, not the current test inventory.

No registry wrapper or package split was justified after centralizing the
mutation gate and enforcing the emission boundary. Revisit one when a concrete
failure or independent consumer requires it.

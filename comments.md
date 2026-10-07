# Differences from Odin and design motivations

This document is non-normative. It records why Loke differs from Odin and why
some larger design choices were made. [`design.md`](design.md) remains the
authoritative language definition.
Open questions and unresolved findings are in [open-questions.md](open-questions.md).

The main sections explain current design choices. [Design history](#design-history)
records migrations; [implementation notes and review history](#implementation-notes-and-review-history)
provide the compiler details.

## Added features compared to Odin

### Local borrow checking

Loke's procedure-local borrow checker prevents a live view's storage from being
invalidated and catches local borrows escaping their scope, without lifetime
syntax. An inferred [result contract](design.md#procedure-result-contracts)
records which arguments or allocator regions a result depends on. For a borrow
inside a record, it also records the field path to that borrow, called a
[carrier path](design.md#values-that-contain-borrows). Returning one field uses
that field's storage rather than all storage reachable from the argument.

[Inferred callback types](design.md#procedure-result-contracts) preserve those
contracts: both `callback := choose` and `Chooser :: type_of(choose)` retain the
same information about borrowed storage as a direct call. Copies and generic
forwarding preserve it too. The contract participates in type identity and
compatibility, so changing a
published procedure's result dependencies can break clients.

Converting to a plain written `proc(...) -> T` signature erases that information;
converting back cannot recover it. Calls through that plain type conservatively
derive borrowed results from every borrowed argument not excluded by
[`@(escape=none)`](design.md#escapelevel). Owning results retain the region
dependencies of every moved owner and allocator argument. Plain signatures keep
this conservative precision tradeoff.

Raw pointers, stored borrows, foreign calls, and cross-thread lifetimes remain
explicit trust boundaries. This keeps low-level optimization and interop
possible without making unsafe behavior the default.

Hooks the language calls are counted in [global write
effects](design.md#global-write-effects) rather than forbidden from writing
globals: a guard whose drop restores or clears global state is a legitimate
idiom, and counting rejects only the programs where that write would invalidate
a live borrow. Printing reaches every `format` method because the witness for
an erased value is chosen by its run-time type; tracking which types reach
`any_view` would be more precise, but only a `format` that writes globals pays
for the approximation.

Copy hooks are the exception: one that writes a global is rejected instead of
counted. Copies happen in more places than the borrow walk has points for —
bindings, arguments, container insertion, generated clones of records holding
the type — and under the copy contract their number is unspecified, so a
global write there is either a count, which `Atomic(T)` keeps without a write
and which copies on several threads need anyway, or a bug.

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

### Child processes

`core:process` was deferred until handle inheritance, quoting, environment
replacement, and pipe ownership could be decided together, because on Windows
each default is something the caller did not ask for. `CreateProcessW` searches
the working directory before `PATH`, which runs whatever a downloaded folder
names `git.exe`; a child given `bInheritHandles` gets every inheritable handle
in the parent, including another thread's pipe; and the command line is one
string that the child splits by rules no caller should have to know. So a name
is looked up on `PATH` alone, the arguments are quoted to come back exactly as
given, and the handle list names the three standard handles and nothing else.

Dropping a `Child` detaches it, where dropping a `Thread` joins it. A thread
shares the parent's memory, so it must not outlive its owner, but a child shares
nothing and is often meant to outlive it. Waiting in `drop` would hide a block,
and killing would hide a lost result, so both are calls.

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

### An owner for one value

Odin's `new` hands back a `^T` that the caller must remember to `free`; the
type of the result is the type of a borrow. [`box(T)`](design.md#owned-values)
is the owning form: it is to `^T` what `[dynamic]T` is to `[]T`, so ownership,
cleanup, region provenance, copying, and the implicit read-only loan follow
rules the language already had for containers. That is also why a box is
copyable when its payload is: the [ownership rule](design.md#value-semantics-and-the-ownership-rule)
makes a copy of an owner an independent value, last-use transfer removes the
common copy, and the copy-cost diagnostic reports the rest. A move-only box
would have been the one owner that broke that rule.

It is a compiler type rather than a library record over a `rawptr`, for three
reasons. A record over a raw pointer has a zero value, the null one, which a box
must not have. It carries no borrows, so a box of a view would drop what the
view owes; `shared(T)` had exactly that hole until the compiler supplied its
payload's carrier shape. And `b^`, the payload as a
place with the box's capability, is a projection the borrow checker has to
see, as it sees a dynamic array's element. The cost is one more type kind
handled where `[dynamic]T` is.

A box is one address and its allocation records the allocator, so a child
link in a tree is one word, and an `Option` of it is one word too
([Zeros that are values](#zeros-that-are-values)).

Checked `new`, `new_clone`, and `free` went when `box` arrived. They were a
second way to own one value whose type still said nothing about who releases
it, and the borrow checker kept an allocation-root category and a same-region
rule for `free` that no program in `examples/` used. What is left for raw
storage, `unsafe.new` and `unsafe.free`, answers a `[^]T` and checks nothing,
which is what the library's two callers, `shared(T)` and `core:thread`, were
already doing through `unsafe.free`.

### Zeros that are values

In Odin, `nil` is the zero of a slice, a `typeid`, an allocator, and a string
view as well as of a pointer, and a nil slice compares unequal to an empty
subslice that behaves identically. Loke gives each such type a zero that
supports every operation the type has, written `{}` like any other zero: the
empty view, the invalid id with its `Invalid` reflection entry, the default
provider, an empty `weak` handle. `nil` is then only ever an address that is
not there, which is what lets references stop having one at all.
Slices stop comparing with `nil` because the only question that comparison
could answer, besides emptiness, was which of two empty views had been sliced
from memory.

A reference has no such zero, so it has none at all: `^T`, a procedure value,
`dyn I`, `any_view`, `cstring_view`, and `shared(T)` are never null, and absence
is `Option(^T)`, as it already was for every other type. Odin's `^T` has three
states inside an `Option` where two are meant, and every dereference and
indirect call pays a null test. Loke used to keep those tests and add a
whole-body diagnostic for a local given only `nil`; it caught the certain cases
and nothing that arrived through a field, a parameter, or a container. Now the
null test happens once, where an unchecked address becomes a reference, and the
type promises the rest. The cost is that a record holding a reference has no
`{}`, which the language already handled for unions and enums without a zero,
and that a global reference is an `Option`, since no address is a compile-time
constant.

Absence costs nothing in return. With the null address free, `Option(^T)` is
that address alone, as Rust's `Option<&T>` is, so a chain of
`Option(box(Node))` links is one word per link and `Option(^T)` is what C
means by a nullable pointer, both across the foreign boundary and inside an
`Atomic`. design.md "Representation" states the rule by shape rather than by
naming `Option`, so a hand-written two-variant union gets the same layout.

Two other designs were rejected. A nullable `^T` with a flow-sensitive nil
analysis keeps three states inside an `Option` and a test on every
dereference, and promises nothing across a field, a parameter, or a container.
A second, non-null pointer type beside `^T` would make every API choose
between two pointer types to say what `Option` already says.

### Updating a payload in place

Once absence is an `Option`, updating a payload in place is common, as in
inserting into an `Option(box(Tree))`. Without a mutable binding that update is
an `exchange` of the field for `.none`, a consuming switch, and an assignment
back. `case .some(&node):` binds the payload as a writable place instead,
spelled as `foreach (&value in items)` binds an element, and it would move to
`&mut` with `foreach` if that ever changes
([Switch ownership](design.md#switch-ownership)).

A borrow taken through the binding is a borrow of that field of the binding,
tracked as precisely as one of a local, and it also carries the subject's
borrow. When the case runs again the binding names different storage, so the
checker stops counting the earlier pass's borrows against it; the subject's
borrow they carry still guards what they point into. That is what makes a
cursor walk work: in `switch (cursor^) { case .some(&node): cursor = &mut
node.next; }`, the new pointer reborrows `cursor` and is stored back into it,
the self-store that `xs = &mut xs[1:]` already was, and the next pass's `node`
is free to borrow again. Treating every borrow through the binding as the
subject's whole borrow would also work for the cursor, but it lost field
tracking: growing a buffer under a pointer into it went unreported. A list's `push_back` and an
in-place `remove` are written that way, with no unchecked code.

Two limits stay. Generated drop, clone, and formatting recurse once per box, so
a long chain can exhaust the stack; a list type declares an iterative drop hook
that moves each node's `next` out before the node drops, while a tree, whose
depth is logarithmic, can keep the generated hooks. And a tail pointer or a
`prev` link is a second mutable path into storage the chain owns, which no
checked reference may be: an O(1) queue or a doubly linked list uses handles,
`prev` and `next` as `Option(int)` into a `[dynamic]` slot array, or a
container that uses `unsafe.new` inside and exposes a checked cursor.

### Storage modifiers instead of storage attributes

Odin spells static-duration locals `@(static)` and thread locals
`@(thread_local)`. Loke writes `static` and `thread_local` in the declaration
because they specify where and how long the variable lives. The two modifiers
are mutually exclusive.

Storage duration belongs in the declaration because it determines lifetime and
cleanup: removing `static` resets a counter on every call and can make a returned
borrow invalid. Attributes describe other properties, including layout,
allocator effects, and linkage. `@(link_name)` and `@(export)` affect external
linking; they do not select the variable's storage duration.

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

Copying a `[dynamic]T` or map creates an independent value. Unlike Odin's
header-only assignment, it does not silently share mutable backing storage.
For `[dynamic]int`, `b := a` clones using `b`'s declaration allocation policy
when `a` is used afterwards. Immutable `string` and `shared(T)` retain their
storage instead. A pointer or `shared(T)` makes shared mutable ownership explicit.

Allocating copies are implicit so assignment works uniformly in generic code
and adding an owning field does not break every caller that copies a record.
The cost is a possible allocation. [Last-use transfer](design.md#last-use-transfer)
avoids it for eligible bindings and assignments whose source is finished;
the copy-cost diagnostic reports each allocating copy that remains, and large
inline copies. It is on by default: measured when it was added, it reported
nothing in `examples/` or the standard library they use, so the noise that
sank the explicit-copy policy does not return as warnings.

Last-use transfer is conservative about borrows. A local ever stored into a
borrow-carrying value, or passed as one to a call with an `inout` argument, is
not transferred automatically, even if that borrow has ended. Arguments,
aggregate elements, and insertions still follow their ordinary copy rules.
This keeps transfer checking simple while preserving borrow safety.

Last-use transfer is sound only because a copy hook must preserve its source's
value (design.md "Lifecycle hooks and resource types"). Without that contract,
a hook that traced or renumbered its copies let a debug print of the source,
added after an assignment, change the assignment's result. The alternatives
were worse: excluding types with custom copy hooks from transfer would make
every `shared(T)` assignment pay an atomic increment and a later decrement,
and no checker can prove a hook preserves a value, since the effect analysis
deliberately does not see foreign I/O. C++ copy elision makes the same choice.
A duplicate that must differ from its source belongs on a `move_only` type as
a named method, where every call is written.

The [assignment history](#assignment-history) records the rejected explicit-copy
policy; [last-use transfer implementation](#last-use-transfer-implementation)
explains the analysis order and generated moves.

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
requirements additionally supply a [witness table](design.md#runtime-polymorphism),
a table of method addresses used for runtime dispatch through `dyn` values.
Free-form expression requirements remain
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

A `distinct` type inherits none of its underlying type's operators apart from
comparisons — `Meters :: distinct f64` starts with no arithmetic at all — which
is what stops a unit type from silently behaving like its representation.
Comparisons are the exception because they cannot produce a wrong-dimensioned
value: both operands already have the same distinct type, and the result is a
`bool`. Requiring `delegate(==, !=, <, ...)` on nearly every identifier and unit
type would be boilerplate that protects nothing. The cost is per-operator
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

A record with a `call` method is the current callable convention. Compiler-added
procedure members, callable result inference, and closure syntax are
[exploratory proposals](open-questions.md#callable-records-procedures-and-closures),
not requirements of the current language.

### Typed fallibility, and the `Option` decision it reverses

`Option(T)` represents absence and `Result(T, E)` represents failure. Both are
ordinary generic unions in `base:runtime`. [Typed fallibility](design.md#typed-fallibility)
recognizes their declared shape rather than their names, so library unions can
use the same `or_else` and `or_return` operations.

A fallible answer is one value that can be stored in a field, passed to generic
code, or returned through a procedure value. Named variants also distinguish
success from failure when both payloads have the same type, as in `Result(int, int)`.
This replaces special rules for trailing Boolean or error results with ordinary
value semantics.

The [fallibility migration](#fallibility-migration) records the reversed decision,
measured costs, and changed reader contract.

### One result, and the compatibility break that came with it

A procedure returns at most one value. Several values travel as one
[anonymous record](design.md#anonymous-records), then are unpacked by
[destructuring](design.md#destructuring). The same unpacking rule serves
declarations, assignments, and `foreach`; there is no separate result-list rule
or named-result local to initialize implicitly.

Field names are part of an anonymous record's type. For example,
`proc() -> (a: int, b: int)` and `proc() -> (x: int, y: int)` are incompatible.
This keeps a returned record's identity the same whether it is stored, passed,
or returned. Type identity uses the field names and actual field types, so two
unrelated types named `Token` do not become interchangeable.

The [one-result migration](#one-result-migration) records the compatibility
break and compiler defects found while migrating named fields.

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

The method is the only built-in spelling. `len(x)` performs ordinary lexical
lookup and works only when a procedure named `len` is in scope; it does not
look for `x.len()`. The remaining rule is uniform: `f(x)` is a lexical call
and `x.f()` is a receiver call. Built-in types keep their compiler-contributed
`len`, `cap`, and `hash` members,
which is what `x.len()` selects on a slice exactly as on a user record. A fixed
array's and a vector's lengths stay properties of their type, but `x.len()` is
still an ordinary call and still evaluates `x`; the unevaluated operand is
`size_of`'s job, not a method call's.

### `mem.` spellings of the allocation built-ins

`design.md` once promised that the allocation built-ins, `make`, `free_all`,
and `drop` among them, were also available in package `mem`. No compiler ever contributed
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
uses [materialized constants](design.md#materialization) instead: runtime
indexing, slicing, taking an address, or borrowing a traversal creates one
shared read-only object. `&C` yields a read-only `^T`; `&mut C` is rejected.
Low-level access needing a mutable foreign pointer uses a slice and an explicit
`unsafe.raw_data` conversion.

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
`Option` all apply. It returns a copy of the payload rather than lending the
original storage, so a move-only payload still needs a switch. An `Option` can
contain a borrow, as `Option(^T)` does; wrapping it preserves its lifetime checks.
There is no panicking `value.(.name)`: `or_else` makes the safe form just as short.
Interpreting the wrong payload as an owning type can manufacture a container
header from unrelated bits and later pass an invalid pointer to `drop`.
`unsafe.transmute` and raw storage in `core:unsafe` remain available for explicit
low-level work, and the checked extraction that does exist — `view.(T)` on an
`any_view`, where the set of types is open — traps rather than guessing.

### Nominal conformance declarations

An `implements Drawable(Circle);` declaration was proposed and rejected. With no
semantic force it is only a second spelling of `static_assert(Drawable(Circle));`
while suggesting a nominal relationship the language does not create. The
structural interface model is complete without it, and a file-scope assertion
stays a check rather than a registry.

Reconsider it only as a proposal in which it *has* force. That proposal must
define ownership and orphan rules, coherence, generic and conditional
conformances, conformances for built-in types, compatibility with existing
structural code, and whether a claim gates static satisfaction or only `dyn`
witness construction.

### A `()` unit type

`()` is not a type. The library's `Unit :: struct {}` already covers
`Result(Unit, E)`, and the product, call-matching, and one-result work all
shipped without a second spelling for one zero-sized type. Reopen it if a second
zero-sized use appears that `Unit` serves badly.

### Reviving a variable without a write

`core:unsafe` has no operation that makes a dead variable live without writing
a value into it. A full assignment already revives one (see
[Assignment statements](design.md#assignment-statements)), and
[`unsafe.forget`](design.md#unsafeforget) covers the opposite direction. Liveness
is a compile-time property, so a definitely-live or definitely-dead variable
costs nothing at runtime. Only a conditionally live one keeps a hidden drop
flag, and the operation would only let a programmer delete that flag and its
branch. No program has shown the flag mattering; reopen this when one does.

## Changed features

### Reading a carrier under a read-only reborrow

A read-only reborrow used to suspend its source for every use, so
`slice.equal(xs, xs)` with `xs: []mut int` was rejected although both
arguments only read, and so was `view: []int = xs; x := xs[1];`. The
suspension exists so that no mutable alias writes behind the reborrow, and a
read cannot, so only writes and mutable reborrows now conflict with a
read-only one. A mutable reborrow still excludes reads, because the reader
could observe a half-done update. The compiler accepts a read only where the
provenance walk tags it as one, so a read it has not been taught to recognize
stays rejected rather than letting a write through. A read through a field, a
pointer, or an element qualifies when what it yields carries no mutable
borrow, and an unnamed value read out of a mutable carrier takes the
capability of the destination it is stored into, as a fresh borrow does.

### Each required result is asked about

`@(require_results)` used to ask only whether a binding's name was ever read,
so `outcome = fail();` after one `_ = outcome` dropped the second error
unseen, and so did `r := fail(); r = fail(); use(r)`, losing the first. Each
result a call stores in a local is now asked about. The check reuses the
backward read analysis last-use transfer already runs, so it cost no new
analysis. It reports only a result no path reads, the same certainty the nil
diagnostic asks for: a result read on one branch and not another is quiet,
because rejecting it would reject a program whose author knows the other path
cannot fail. A value built in place, such as `.err(0)`, is not asked about; it
is the program's own value, not a failure handed to it. No program in the
tree tripped the check.

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

Two unchecked declarations stayed ungated after that: `x: T = ---` on plain
data, whose reads go unchecked, and `@(initialized = count)`, whose count
generated copy and drop trust, so `Bad{count = 2}` over a one-element array
dropped past its end. Both now need the import too. Removing `---` behind a
new uninitialized-storage API was considered, but nothing in `base`, `core`, or
`examples` used it, so gating kept its two uses (a foreign out-parameter, and a
`static` of a type with no zero) for one rule. Nor did the gate cost the
library anything: `core:container` and `core:thread` already imported
`core:unsafe` for `unsafe.write` and `unsafe.take`, and `shared(T)` lives in
`base`. Generated traversals also check `0 <= count <= N`, which turns a count
past the capacity into a panic, though it cannot show the prefix holds values.

### Formatting and logging sinks are `dyn` views

`fmt.Writer :: dyn mut fmt.Sink` and `log.Logger :: dyn mut log.Sink` are
borrowed views. A formatting sink implements `write(bytes: []u8)`; the view
keeps the record's type and borrow checks without a user-written `rawptr` cast.
The collector and latch adapters are ordinary records, and neither library
needs `core:unsafe`.

A formatter uses its sink only during the call. A logger factory must return
process-lifetime storage, so it can lend a `static` sink. Neither use needs an
owning closure. A view always names a sink, and views are not comparable.
The [sink implementation notes](#formatting-and-logging-sink-implementation)
record the migration from raw state pointers and the runtime adapter.

### Generated printed forms say what they print

Go's `Println` prints `1.0` as `1` and a nested string bare, and Loke's
generated formats did too. They ([String format printing](design.md#string-format-printing))
now differ in three places, each so the output cannot be read as something
else:

- A float always has a fraction or an exponent. `1` printed for `1.0` is the
  integer's form, so a reader of `[1, 2]` could not tell `[]f64` from `[]int`;
  `1.0` and `1e21` are also float literals that read back as the same value.
  The exponent is bare, `1e-7` rather than C's `1e-07`.
- A string or rune nested in an aggregate is quoted and escaped. Bare,
  `["a b", "c"]` and `["a", "b c"]` both printed `[a b c]`, and a field
  holding `", y = 2"` could forge another field. Printed on its own a string
  is still its text, since that is what `println("hello")` is for.
- An anonymous record prints `(x = 1, y = 2)`. It had printed its type as
  a struct prints its name, `(x: int, y: string){x = 1, y = s}`, repeating
  every field name for no information.

A struct still prints only its public fields. One printed form serves every
package, so it can show only what every package may see; a type that wants its
private fields printed declares `format`.

### Explicit overload groups

Overloads are assembled in named procedure groups. Each implementation keeps an
ordinary callable name, the overload set is visible, and ambiguity is diagnosed
instead of being resolved by declaration order. Methods and operators use the
same resolution rules.

### `+` concatenates strings at runtime

Odin's `+` on strings works only between constants; runtime concatenation is
`strings.concat` with an explicit allocator. Loke lets `+` concatenate at runtime
too, allocating from `mem.default_allocator()`.

The convenience costs an allocation, as `append`, map insertion, and copying
owners can too. It keeps short messages easy to write. Each `+` copies the
accumulated result, so repeated concatenation is quadratic; use `String_Builder`
for loops and for choosing an allocator. Copy-cost diagnostics report large
inline copies, not the allocation or growing text copied by concatenation.

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
hashing and bit manipulation are written in it, and signed wrap is asked for
by name, with `math.wrapping_add` and its siblings.
The exceptions each keep an existing definition: `<<` is a bit operation whose
limit is already defined for every count; `%` cannot overflow; an atomic `add`
is a hardware read-modify-write whose other readers have already seen the
result.

The cost is a checked operation, `llvm.sadd.with.overflow` and its siblings, per
signed arithmetic step, much of it removed where loop bounds already prove the
range. It returns part of what wrapping cost: on the path that continues, the
result is known to be in range, so the optimizer may widen induction variables
the old rule forbade it to.

### Integer conversions keep the value

`T(v)` between integer types used to keep the low bits, so a runtime `int` of
300 became a `u8` of 44, while the constant `u8(300)` was rejected and a float
out of range panicked. Which policy applied depended on whether the operand was
a literal, a typed constant, or a variable, and moving a value between those
silently changed it. Converting is now one rule: the value is kept or the
program stops, at compile time where it can.

Wrapping is still needed, so it got a name, `math.wrap`, rather than staying
the meaning of the shortest spelling. Measuring before the change, a compiler
that panicked on every lossy integer conversion ran all 276 run programs and
every example. Three stopped: `math.to`, whose body was the round trip it now
writes with `wrap`, and two tests of the old signed-wrap idiom
`i8(u8(b) + 1)`. The hashing, UTF-8, `strconv`, and formatting code they run
through already did its bit work in unsigned types. Masking first, as in
`u8(x & 0xFF)`, needs no `wrap`, and the optimizer removes the check.

With conversion no longer wrapping, `i8(u8(b) + 1)` has no meaning left, so the
policies for signed arithmetic are named too: `wrapping_add`, `wrapping_sub`,
and `wrapping_mul` keep the low bits; `checked_add`, `checked_sub`, and
`checked_mul` answer `Option(T)`, which is what a parser accumulating digits
wants. They are ordinary library procedures over `math.wrap`, computing in
`u128`. A saturating family was left out until a caller needs one.

### Signed SIMD lanes follow the scalar rule

Signed SIMD lanes first stayed modular, on the grounds that a vector instruction
has no per-lane overflow flag. That made replacing a scalar kernel with a vector
one change its results at the boundary values. LLVM's `*.with.overflow`
intrinsics take vectors, so a lane is now checked as a scalar is: the overflow
lanes are ORed together and the operation branches once.

Looking at `a * x + y` over `Simd(i32, 8)` at `-O2` with AVX2: the checked `+`
is `vpaddd` plus two compares, an xor, a movemask, and one branch; the checked
`*` adds about nine instructions, because x86 has no vector high-half multiply
for 32-bit lanes and the high halves come from two `vpmuldq`. A kernel that
means to wrap says so with `math.wrapping_add` and its siblings, which take
vectors and compile to the bare `vpaddd` and `vpmulld`. Signed `reduce_add` and
`reduce_mul` fold through the scalar checked operator, lane by lane, so they
agree with the loop they replace; a reduction usually runs once per kernel,
outside its loop.

### Signed shifts stay bit operations

When signed `+`, `-`, and `*` started panicking on overflow, and again when
integer conversions started keeping the value, signed `<<` was weighed and left
modular: the bits shifted out are discarded, the sign bit included, and no shift
panics.

A shift is written for its bits: building a mask, packing a field, reaching
`MIN` as `i64(1) << 63`. Checking it would need a definition of overflow that
code written that way breaks. If overflow means "a bit that differs from the
result's sign was shifted out", then `i64(1) << 63` panics. If it means "the
result is not `x * 2^n`", the shift is a multiplication with a different
spelling. Rust reaches the same answer and checks only the count, and Loke
defines every count already, as the limit of the repeated one-bit shift, so
there is nothing left to check.

The arithmetic meaning has its own spelling. `x * 2` panics where the product
does not fit, and `math.checked_mul(x, 2)` asks whether it does, so code that
means multiplication writes multiplication. The same reasoning keeps unsigned
`<<` modular, as all unsigned arithmetic is.

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
turns an allocation failure into an empty container. `make` now follows the
allocator's failure policy and `try_make` returns the `Result`, as `box` and
`try_box` later did. About a hundred calls in `tests/` changed spelling.

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

### Mutable slicing is written `&mut a[lo:hi]`

A slice of a mutable place used to be `[]mut T` or `[]T` depending on where it
went: a `:=` binding took `[]T`, a `[]mut T` parameter or annotation took
`[]mut T`, and a user `operator([:])` was selected by its destination. That
made `view := a[:].indexed()` a mutable view where `view := a[:]` was not,
and it was the one place a destination selected an overload. Pointers never
worked that way: `&x` is always `^T` and `&mut x` always `^mut T`. Slicing now
matches them. `a[lo:hi]` is always read-only and `&mut a[lo:hi]` is mutable,
for built-in and user slicing alike, so a call that may write elements says
so, and an annotation or an adapter never changes a slice's capability.

The spelling reuses `&mut`, which already means an exclusive mutable borrow,
and a slice is a borrow. Rust writes the same `&mut a[lo..hi]`. A method
spelling such as `a.mut_slice(lo, hi)` was the alternative, but passing a
buffer to a reader is the most common use, and `read(&mut buffer[:])` is
shorter than `read(buffer.mut_slice())`. The cost is parentheses around a
mutable slice whose member is called, `(&mut a[:]).indexed()`, because a
suffix binds tighter than `&mut`. Measured before the change, 146 places in
the tree needed the spelling, about 20 of them outside tests.

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
array's index does. `m.find(key)` returns `Option(^V)` and `m.find_mut(key)`
returns `Option(^mut V)`, both without inserting. `m.find_or_insert(key, elem)`
returns the slot either way, so a caller that
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

The `try_` forms follow the same rule. They once copied even a temporary, so
that a failure could leave the caller's argument untouched, and so rejected
every move-only element. That promise only means something for a borrowed
place, which is still copied: a temporary has no binding to restore, and
`move(x)` has already ended `x`. So a failed `try_` form drops what it took. The
alternative, returning the element inside the error, would change the error
type from `Allocator_Error`, so `or_return` would stop composing with the other
allocation failures, all to support retrying after running out of memory. A
caller who wants that reserves first and then moves the element in.

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

A procedure constant therefore ends at its body's `}`, and calling the literal
in place needs parentheses: `VALUE :: (proc() -> int { return 7; })();`.
Continuing into a call suffix would make the statement after a local
procedure constant ambiguous: in `f :: proc() { }` followed by `(p)^ = 3;`, the
`(` would call `f`. Odin avoids this through newline-based semicolon insertion,
which Loke does not have.

### `transmute` is a procedure in `core:unsafe`, not an operator

Odin spells a bit cast `transmute(T)value`, which needs a reserved word and its
own unary binding rule. Loke writes `unsafe.transmute(T, value)` and makes it an
ordinary call — types are already passable as arguments, so nothing was gained
by the operator form except a keyword. `move` stays a keyword because it is also
a parameter mode and has to be reserved regardless.

It is not predeclared either. Reinterpreting bits is not a safe, universally
valid conversion: nothing about the source value says the destination
representation is one its type ever admits. That is the same loss `raw_data` and
`unsafe.free` make visible, so it is spelled at the same boundary and an import says
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

### Standard output is binary

Odin writes its standard handles without translation, and so does Loke. The C
library opens `stdout` and `stderr` in text mode on Windows, which turned each
`\n` that `core:fmt` printed into `\r\n` while `core:term` wrote the handles
directly, so one redirected stream could mix both endings and `fmt` could not
print a bare `\n`. Text mode for both would instead make a program's bytes
depend on the platform, which Linux support would then have to undo. The
runtime sets both streams to binary at startup; an object build leaves them to
its host.

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

## Design history

### Assignment history

Allocating copies were initially implicit. Version 0.7.1 rejected them with
`L0504`, suggesting `move(a)`, `a.clone()`, or a borrow. A corpus count found
such copies only in tests of the rule, but that missed the cost to library APIs:
adding an owning field broke clients' copies, generic code needed `clone` on
every copyable type, and beginners had to choose among three alternatives to
ordinary assignment.

Implicit copies were restored with conservative last-use transfer to avoid
unnecessary allocations. The generic fixed-array `clone` and compile-time
evaluation of generated `clone`, added while the explicit-copy policy stood,
remain useful independently of it.

### Fallibility migration

The earlier design rejected standard `Option` and `Result` types and used
trailing Boolean or error results. Its two result conventions required
optional-result-count rules and a status-result category. Unions also had a nil
state and `active_typeid()`, which could not distinguish variants with the same
payload type. Named variants and ordinary `Option`/`Result` values replaced
these special cases.

The recorded migration measurements compared with baseline `d2e3f6f`:
front-end time rose 7–18% because `base:runtime` adds a fixed cost, an empty
program's binary was unchanged, and two example binaries grew about 3%.
The migration also exposed nine compiler defects, fixed during adoption.
These are historical measurements, not benchmarks of the current compiler.

`io.Reader.read` also changed from returning progress and an error together to
returning `Result`. A read reports any progress first and surfaces a following
failure on the next call. The helpers in `core:io` loop until they have their
requested input, so they work with that contract.

### One-result migration

Typed fallibility had already reduced the library to single results. At the
migration, `core:` had one multi-result procedure (`strings.encode_rune`),
`base:` and `examples:` had none, and the live corpus contained five bare
returns. The remaining uses were test fixtures.

`-> (a: int, b: int)` changed from two named results to one record result.
Result names had not participated in procedure-type identity; record field
names do. Consequently, differently named results became incompatible through
procedure values, overloads, interface slots, reflection, and ABI lowering.
`-> (n: T)` likewise became a one-field record, and `-> (T, U)` was rejected.
Named result locals and the initialization analysis supporting their bare
returns were removed.

The migration exposed two defects in named-field handling: result-borrow
analysis joined unrelated fields, and named call arguments ran in parameter
order rather than source order. Both now use the field or parameter slot
already selected by the checker.

## Implementation notes and review history

### Last-use transfer implementation

Last-use transfer is decided by a backward control-flow analysis. Exact borrow
liveness would require the provenance pass, which runs after lifecycle analysis
has fixed each local's cleanup. The earlier pass therefore excludes locals that
have carried borrows rather than trying to prove those borrows have ended.

An accepted transfer becomes an ordinary `move(x)` in the syntax tree, so later
borrow and allocator-region checks see it as written. A borrow that prevents a
copy still produces a diagnostic at the copy site; conservative transfer does
not bypass that check. See [design.md "Last-use transfer"](design.md#last-use-transfer).

### Formatting and logging sink implementation

The former `state + proc` sink cast a `rawptr` back to a typed pointer in
`core:fmt`'s collector and `core:io`'s latch adapter. Borrowed `dyn mut` views
removed those casts without requiring retained closures. A nil `Writer`, which
used to discard output, first panicked like every other nil view's slot call,
and then stopped existing when references lost their null state.

The generated module supplies `loke_rt_v1_sink_write` for the runtime's scalar
formatters. It calls the witness slot with a slice built in LLVM, avoiding a C
prototype for LLVM's two-word aggregate convention. Process streams use a
compiler-emitted witness whose data pointer identifies the stream.

Because views are not comparable, the logger-provider test checks sink
output instead of comparing `current().write` with `standard_logger().write`.

### Extended UNC volume boundaries

Extended UNC paths use the same server/share boundary as ordinary UNC paths,
after the `\\?\UNC\` marker. Recognizing that boundary in `path.volume` fixes
every lexical operation that stops at a root and lets `fs.create_directories`
begin below the share. It does not normalize the path: [Windows's extended-path
rules](https://learn.microsoft.com/en-us/windows/win32/fileio/maximum-file-path-limitation)
require preserving its text, so `clean` continues to return it unchanged.
The contract is in [standard-library.md "`core:path`"](standard-library.md#corepath),
with regression cases in [tests/run/lib_path.loke](tests/run/lib_path.loke).

### Portable process input and path errors

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
[tests/run/lib_fs.loke](tests/run/lib_fs.loke). Every package now translates
through the one table in `io.from_native_code`, so a code means the same thing
whichever package reports it; only `core:term` reads `ERROR_INVALID_HANDLE` as
`Not_A_Terminal`, because there it means the handle is not a console.

### Malformed console input

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

### Two slices of one local array in one call

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

### Compiler regression fixes

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

### Foreign ABI validation

The Win64 boundary checks an enum's written backing rather than assuming every
enum is a supported scalar. Zero-sized records are rejected recursively:
Loke's empty record occupies no bytes, while Clang's Windows C extension gives
it four, changing both enclosing field offsets and argument classification.
Pointers remain permitted under [design.md "Foreign-ABI-safe types"](design.md#foreign-abi-safe-types).
[Enum](tests/err/foreign_abi_enum_backings.loke),
[empty-record](tests/err/foreign_abi_empty_records.loke), and
[export](tests/err/foreign_abi_exports.loke) regressions cover the shared rule;
[tests/obj/host.c](tests/obj/host.c) checks a valid enum against a C caller.

Completed, acyclic safety answers are cached within one traversal. Cycles and
unresolved fields remain provisional, and a fixed array's placement is checked
before consulting the cache. [src/front_end_test.odin](src/front_end_test.odin)
checks shared record graphs and the array placement rule.

### Debug build regression fixes

The debug-code review found five correctness bugs. Temporary cleanup now
preserves output paths that alias `.ll` or `.natvis`, including Windows case
variants. Every emitted deferred block binds its locals to that copy's storage
and scope. Exported debug names use the literal linker name, while internal
names use Loke's decoder. Statement locations belong to the shared emitter
entry, and conditions restore their own locations after initializers.

LLVM's CodeView writer saturates enum constants above 64 bits. Representing
128-bit integers and enums as `low` and `high` unsigned words preserves their
exact bits without changing language types or adding a second debug backend.
[src/emit_llvm_test.odin](src/emit_llvm_test.odin) checks deferred bindings,
literal names, wide storage, and actual condition locations;
[tests/corpus_test.odin](tests/corpus_test.odin) runs outputs whose names alias
the temporary extensions.

The gate also exposed two example tests compiling the same executable in
parallel. The driven corpus runner now uses a separate output path.

### Compiler architecture audit (2026-09-28)

The audit reviewed revision `b2cc712`, tracing the driver, checking, CTFE,
generics, ownership, emission, runtime interface, and test harnesses. Its
corrective findings A1–A10 have since been addressed. Their original priority
order is no longer a work list; the current contracts are in
[compiler-architecture.md](compiler-architecture.md), and the remaining
structural questions were settled in a follow-up review, below.

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

The query walkers it named (`first_unresolved_name`, `type_syntax_names`,
`pattern_shape`) now switch exhaustively rather than sharing one child
enumeration. Each deliberately covers different positions: value and type
names, every name, or pattern layers. A shared enumeration would have made
them all descend everywhere. Making `first_unresolved_name` exhaustive found
that it skipped anonymous-record field types and `move`
([tests/run/when_anonymous_record_condition.loke](tests/run/when_anonymous_record_condition.loke)).

A follow-up review (2026-10-06) settled the three structural questions the
audit left open:

- **Probes keep the `committing(c)` gate.** Journaling registry writes for
  rollback needs the same discipline at every write, and would have to tell
  enrollment from caches that must outlive a probe. Stopping probes before
  body-level work would change what a requirement means: an interface
  requirement may hold a procedure literal whose body decides it, and a
  `where` bound runs bodies at compile time. What was missing was detection,
  so `end_probe` now asserts that the registries emission reads did not grow.
  Its first run found synthesized members enrolled during probes; they now
  enroll from the use that commits them (`enroll_synth`).
- **Lifecycle and provenance keep their shared `Reset_Key`s.** The provenance
  walk reads liveness while it builds, and lifecycle must still run first
  because last-use transfer rewrites the syntax provenance walks, so solving
  liveness on the provenance graph would solve it twice per body and again per
  summary round and region pass. The keys agree because one walk builds both
  graphs; a missing one is an assertion failure at every lookup.
- **One walk keeps building every mode's graph.** Blocks begin inside
  expressions, and the provenance walk returns loans from each one, so
  separate topology would be a recorded list of event sites per block: the IR
  this audit declined. The mode branches at one syntax position are what keep
  the graphs, and so the reset keys, in agreement. The copy decisions the
  lifecycle walk used to make moved to the checker instead, which already
  made the others; a declaration in a `defer` is now classified once, not once
  per expansion.

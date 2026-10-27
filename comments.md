# Differences from Odin and design motivations

This non-normative document explains Loke's design decisions and tradeoffs.
[design.md](design.md) defines the language, [grammar.md](grammar.md) its syntax,
and [open-questions.md](open-questions.md) the unresolved choices. API contracts
belong in [standard-library.md](standard-library.md); release history is in
[CHANGELOG.md](CHANGELOG.md).

| Topic | Start here |
| --- | --- |
| Ownership and cleanup | [Borrow checking](#local-borrow-checking), [assignment](#value-semantic-assignment), [panics](#panics-run-lexical-cleanup) |
| Types and errors | [Zeros](#zeros-that-are-values), [records](#structs-declare-parentheses-describe), [fallibility](#typed-fallibility) |
| Procedures and callbacks | [Methods](#methods-interfaces-and-operator-overloading), [captures](#capture-literals), [callable views](#borrowed-callable-views) |
| Compilation and configuration | [Compile time](#one-language-at-compile-time), [providers](#build-selected-services-and-explicit-runtime-state) |
| Simpler language surface | [Removed or narrowed features](#removed-or-narrowed-features) |
| Values and operations | [Overflow](#integer-overflow-panics), [slicing](#mutable-slicing-is-written-mut-alohi), [text](#slicing-text-keeps-its-panic) |
| Syntax and layout | [Syntax choices](#changed-syntax), [formatter](#formatting) |
| Library and compiler decisions | [Library APIs](#standard-library-api-choices), [compiler audit](#compiler-architecture-audit-2026-09-28) |

## Added features compared to Odin

### Local borrow checking

The procedure-local checker catches invalidated views and escaping local
borrows without lifetime annotations. Inferred [result contracts](design.md#procedure-result-contracts)
track which arguments or allocator regions a result depends on, including the
field carrying a borrow. That gives ordinary code useful precision without a
whole-program lifetime type system.

Inferred callback types preserve those contracts. A written `proc(...) -> T`
type erases them and uses conservative dependencies instead; converting back
cannot recover precision. Raw pointers, foreign calls, stored borrows, and
cross-thread lifetimes still require programmer discipline.

Lifecycle and formatting hooks contribute to [global write effects](design.md#global-write-effects):
cleanup may legitimately restore global state, but must not invalidate a live
borrow. Copy hooks cannot write globals because copies can be inserted or
elided in many contexts and their count is unspecified.

A result's [region provenance](design.md#allocator-regions-and-region-provenance)
follows the callee's body, not its signature: an allocator a constructor takes
but never uses backs nothing, so resetting it while the result is live is
accepted. The signature reading would let a constructor start using its
allocator without its callers changing, but it rejects programs that are
safe, and the checker already infers the rest of the result contract from the
body. A call it cannot follow keeps the signature reading.

### One temporary-lifetime rule

How long a temporary lives once depended on what viewed it: a slice literal's
backing array lived until its scope ended, a temporary erased into a local
`any_view` did so only when its lifecycle was trivial, and a capture literal
stored straight into a `dyn proc` local ended with its statement and made the
next call an error. The [one rule](design.md#temporaries-and-procedure-boundaries)
is C++'s and Rust's for a reference a declaration binds: a temporary that a
local's value borrows along a syntactic path lives until the block ends, and
is dropped there with the locals.

The path is syntactic so that when a drop hook runs never depends on what the
borrow checker infers; a reader sees the extension in the statement itself.
Calls end the path because a call's result says what it borrows only through
an inferred contract, and keeping every argument alive in case the result
borrows it would delay drops that nothing needs. A literal's fields do not
extend either, though Rust's do: they can be added later without breaking a
program.

Loke goes one step past C++ and Rust and extends through an assignment to a
whole local too. The temporary still ends with the block holding the
assignment, and a statement runs once per entry to its block, so the storage
stays bounded; a `for` update and a deferred statement, which rerun in one
scope, are the exceptions. That keeps assigning a fresh `any_view` or slice
literal to an existing local working as it did. The cost is that a managed
temporary bound this way drops at the end of the block rather than of its
statement, the drop a named local would have had.

### Threads the language can start

`core:thread` moves an argument into a new thread and checks its borrows with
`@(escape=static)`. Static text can travel; a slice of a local cannot. Several
arguments travel as one record, avoiding untyped callback state.

`Mutex(T)` owns its protected value, and its guard lends an `inout` result.
Keeping lock and data together makes the borrow follow the lock's lifetime.
The guard is `@(thread_affine)` because the system lock must be released by
the thread that took it; a guard handed to another thread would unlock there.
Dropping an unjoined thread joins it, so the thread cannot outlive its handle.

The global-write warning catches spawned entries that write shared globals.
It is a warning because it cannot establish whether the writes happen only
before spawning or after joining. The [memory model](design.md#concurrency-and-the-memory-model)
defines the synchronization guarantees.

The warning and the checks on what a thread receives key on
[`@(cross_thread)`](design.md#cross_thread), not on the name `thread.spawn`,
so a wrapper or executor a program writes is checked by declaring the same
parameters. The attribute is part of the procedure type, as an escape level
is: a fact kept only on the declaration would let a call through a procedure
value skip the checks it promised. A trampoline entry that calls a procedure
value it received, itself or through helpers it hands the value to, is not
warned about for that call, since the procedure is the one its caller passed,
and that crossing call is reported. Following the value takes a second
whole-program summary of which parameters each body calls; the write effect
itself keeps the plain union, which borrow checking needs. Within a body the
value is followed through its parameters and locals by what each is assigned,
without regard to order: a variable assigned a named procedure anywhere may
run it, and one written any other way may run anything, so reassigning the
received value, even through `inout`, cannot hide a writer. A first version
instead skipped every `spawn` in a body with a `@(cross_thread)` parameter,
which also hid an entry the wrapper named itself.

`Atomic` and `Mutex` keep `value` public so that a caller owning one outright,
before spawning or after joining, pays for no synchronization.
[`@(synchronized)`](design.md#synchronized) keeps that access from reaching a
borrowed one, where an atomic operation through another read-only loan may be
writing it. It is an attribute, not a list of types, so `Monitor` and
`Channel` needed no compiler change.

### Waiting on a condition, not a signal

A condition variable asks for three things at every use: a loop around the
wait that checks the condition again, an unlock and sleep that happen as one
step, and a notification after every change the condition depends on.
Forgetting the loop acts on a spurious wakeup, and forgetting a notification
leaves a waiter asleep, often only under load.
[`Monitor(T)`](standard-library.md#monitors) packages all three: `lock_when`
takes the condition and owns the loop and the sleep, and dropping a guard on
which `get` was called notifies. There is no notification to forget, only the
condition's own obligations, which stay the caller's: read-only access does
not prove that the condition is repeatable or that every input to it changes
under the lock, and a purity effect to prove it is not justified without
evidence.

`get` marks the guard changed whether or not the caller writes, because the
`inout` result it lends can be written anywhere. Waking every waiter on each
change is the initial cost: each checks its condition and most sleep again.
Targeted wakeups are a [later extension](open-questions.md#later-concurrency-extensions)
that must still wake every waiter whose condition may have become true.

A guard's drop releases the lock, but it does not say that no one will change
the state again, so a monitor needs an explicit termination transition or
`close`. That keeps the monitor apart from channels, where dropping the last
endpoint on a side does say a peer has gone. `close` ends only waits whose
condition is false: a waiter whose condition still holds gets its guard, so a
closed monitor can be drained, and a loop that must stop also reads a state
such as `stopping`.

### Tasks that borrow, joined by their block

A [`parallel` block](design.md#structured-concurrency) answers one problem:
letting threads work on the caller's data, such as two halves of a slice,
without copying it to the heap or proving a lifetime by hand. A task joined
before its block ends is a call that lasts longer, so the borrow checker
already knows what it may touch. Odin leaves this to `thread.create` and the
programmer; Rust's scoped threads solve it with a closure, `Send` and `Sync`,
and lifetimes on the scope.

**Lexical joins, not handles.** The join belongs to the block, which cannot be
named, stored, or forgotten. A join a handle's drop performed would be skipped
by `unsafe.forget` or by storing the handle, and every borrow a task holds
would then outlive its storage. A helper cannot receive the scope either: that
would need a contract for what the helper may lend to its caller's tasks. A
helper opens its own block, and a long-lived server puts its block in `main`.
The cost is that results come back through locals declared before the block,
rather than as values a handle returns.

**Inferred checks, not `Send` and `Sync`.** The facts a task needs are about
values, not types: two owners of one type may use different allocators, and a
record is safe to share when what it reaches is read-only, not because its
type says so. The checks are inferred, as the borrow checks and the write
effect are, so ordinary types need no annotation. The few declarations that
remain say what inference cannot see: `@(thread_affine)` for a handle that
must stay on its thread, `@(synchronized)` for state a package protects
itself, and `@(cross_thread)` for a library procedure that starts a thread.
The price is whole-program effects, so a change in one procedure's body can
reject a block elsewhere, and the diagnostics name the procedure that
contributed the effect.

**Errors where `thread.spawn` warns.** A thread `core:thread` starts may run
until any later point, so a write to a global there is only a likely race. A
task runs between its spawn and the join, which the compiler sees, so the same
write while a task may be running is an error.

**An erased view by its conversions.** A `dyn` view stored in a global hides
what it views, yet a registry of handlers is a common reason to store one.
[Globals while tasks run](design.md#globals-while-tasks-run) takes every type
the program converts to the view's interface application, wherever that
happens, instead of following what is stored in that global. That answer is
coarser, since one conversion of a mutable record anywhere rejects every
registry of the interface. In exchange it needs no tracking of stores, which
any procedure may make, and it reads the witnesses calls through the view
already dispatch to. Printing is the exception: it converts every printed type
to `dyn fmt.Formattable` after the effects are computed, so that view stays
unknown. A view a task receives already erased is judged the same way, so a
library can spawn the callbacks it is handed. A read-only view's targets stay
shared however the view is passed: moving the view does not move what it
views.

**Lazy setup that owns its value.** A `Once` guards storage declared
elsewhere, so the action writes a global and a task calling it is rejected,
though the write happens once and is published before any reader sees it.
`sync.Lazy(T)` keeps the value inside the guard instead, in a field
`@(synchronized)` already exempts, so the compiler checks lazy setup with the
rules it has rather than a special case for `Once`. What `init` writes and
what the value stores are still checked, since they are the parts the library
cannot vouch for. It is a separate type, not `Once(T)`, because `Once` is
already a type without parameters. Its `init` is any callable answering `T`,
so a setup step can capture what it needs, and `get` answers a `^T` that
borrows the `Lazy` through its payload binding, so a local one cannot hand out
its value past its end.

**A thread per task, with no serial fallback.** Running the tasks one after
another would be cheaper, but it is a different program: `thread_local`
storage starts fresh on each task's thread, and blocking tasks that wait for
each other would deadlock in sequence. The first executor starts a thread per
spawn and makes a failure to start one panic, so a spawn has no result to
handle. A [pool](#pools-that-help-at-joins), named in the block's header, is
the cheaper executor, under the same checks.

**Results only to dead outer locals.** A task's result is written on the
worker, so the destination cannot be read, replaced, or dropped until the
join. A dead local of exactly the result type needs no zero value, no
conversion on the worker, and no rule for dropping a value it replaces, and the
existing definite-initialization analysis says where it holds a value after
the join. Fields, indices, and conversions can be added if a program needs
them.

### Pools that help at joins

A loop that wakes the same workers for every round of work and waits for them
to finish, as a mixer does once per buffer, could keep its workers alive and
signal them each round. It would then lose what a `parallel` block gives: the
round's tasks borrow that round's inputs and outputs, and after the join the
parent has every one of them back, which no wait between rounds proves. What
made a block per round too slow was a thread started per spawn, and a pool
removes only that.

**Helping, and only within the subtree.** A worker that waits at a join while
its block's tasks sit in the queue would hold up the pool, and with one worker
a nested block would never finish. So a joining worker runs queued tasks of
the block it joins, and of the blocks those tasks open on the same pool. It
runs nothing else: a sibling of its own task might wait for that task, and an
unrelated block's task might block for longer than the join it was meant to
speed up. A thread that is not a worker of that pool waits instead, so a
`main` thread never runs a task, and a worker of one pool never runs
another's.

**The join's thread-local effect.** Helping runs a task on the joining
thread, where the parent may hold a borrow of `thread_local` storage: a view of
a thread-local buffer that a helped child grows would be left dangling. A
task's own `thread_local` writes are its thread's, which is why a bare block
needs no rule here, but a pooled block's join may be that thread. Treating the
join as a call that writes what its tasks may write puts the case under the
existing write-effect check instead of a new rule. The tasks a join may run
are only known at run time, so the effect counts every pooled descendant, and
no task of a bare block, which never runs on its parent's thread. A spawn has
no such effect: a pooled task runs on the parent's thread only at the join.

**Lexical selection, persistent storage.** A block names its executor, so a
library procedure's bare `parallel` keeps starting threads of its own wherever
it is called from, and its `thread_local` storage starts fresh as its author
expected. Passing a pool explicitly makes the choice visible where it matters.
Workers keep their `thread_local` storage between tasks, as any thread that
runs several calls does; resetting it would make a pool a different program
from the same calls made in sequence.

**No compensation for blocking.** Helping only covers joins. A task that
waits on a queued sibling, or on a lock a child needs, can exhaust a fixed
pool. Starting extra threads when workers block, as some schedulers do, needs
to know which waits are blocking, including foreign ones; that and a separate
executor for blocking work remain a
[later extension](open-questions.md#later-concurrency-extensions). A pool is for
independent compute work.

### Channels end by ownership

An earlier design passed a stop token to every blocking call, so each failure
path had to request a stop explicitly, and a forgotten request was a hang at
the join. A [channel](standard-library.md#channels) endpoint's drop says
instead that a participant has gone: a task's arguments drop when its call
returns, on every path, and the parent's block cleanup runs before the join,
so a pipeline needs no stop code of its own. Ownership does not infer that a
monitor's condition has become impossible, interrupt a foreign wait, or cancel
a group of tasks using several objects; those need explicit protocols, and
selective or group cancellation tokens remain a
[later extension](open-questions.md#later-concurrency-extensions).

**Paired setup and explicit duplication.** Separate factories for each side
let a receiver start before any sender existed, leaving no sender to drop when
setup failed early. One `split` makes both sides together. A setup endpoint
keeps its side open while the workers start, and the parent drops it before
blocking work. Move-only endpoints make each transfer visible, and `fork` adds
a participant explicitly rather than changing what a generated `clone` means.
A spare endpoint can still hide a peer's loss, so the documented setup shape
and the join check are both needed.

**A join check over marked types.** A value the parent keeps past a join can
hold up a task the join waits for: a guard on the lock a task needs, or a
sender keeping a draining task's channel open. The check rejects such a value
when its borrowed storage may overlap a task's, using the borrow checker's
root provenance; it cannot know which waits a task makes, so it is
conservative rather than a termination proof. Which types matter is an
attribute, [`@(wakes_on_drop)`](design.md#wakes_on_drop), not a list in the
compiler, so a library's own waiting types get the same check, as with
`@(synchronized)`. A guard kept over a block whose tasks borrow its mutex
compiled before the check and is rejected now; it was a deadlock whenever a
task took that lock.

Two parameters are told apart by type rather than assumed to alias. An audio
loop taking its command receiver and a borrowed `[]mut Voice` was rejected
because the caller could, in principle, have made the two the same storage,
though no `Voice` holds or reaches a channel. Typed storage overlaps only by
nesting, so comparing the object types each root reaches decides it without
tracking the caller. Primitive fields make the test coarse (a `[]mut int`
may view a channel's counters, so it still conflicts with a sender), and a raw
pointer or erased view keeps the old answer. Moving the voices in, which the
check already accepted, stays the stronger shape when the loop owns them.

### A spare slot in the ring

The [ring](standard-library.md#rings) is a cached-index SPSC ring with one
spare slot, a shape also used by
[Rigtorp's SPSCQueue](https://github.com/rigtorp/SPSCQueue#implementation).
One producer and one consumer need only index loads and stores; the ring
keeps that structure and its release/acquire publication and reclamation.
[The ring algorithm](standard-library.md#the-ring-algorithm) gives the
algorithm and why it is correct.

The spare slot makes empty `head == tail` and full `next(tail) == head`.
Indices stay inside the allocation and reset explicitly at its end. This
avoids machine-word overflow arithmetic and allocates exactly `capacity + 1`
slots, excluding padding, for arbitrary requested capacities. The earlier
proposal rounded storage to a power of two, used a mask for indexing, and
needed explicit wrapping operators for its position counters: ordinary
unsigned addition and subtraction in Loke can panic. At power-of-two
capacities that scheme saves one slot; the revised scheme adds an end-of-array
comparison on each operation. The choice favors simpler arithmetic, not an
unmeasured performance advantage.

A latest-value handoff is a different contract. A triple buffer can suit
settings snapshots when a newer value supersedes intermediate updates;
[Boost's SPSC value](https://www.boost.org/doc/libs/1_92_0/doc/html/lockfree.html)
is such a structure. The mixer's command queue must preserve every accepted
command in order, so the ring is a FIFO. Batching remains a possible later
optimization if measurements justify its publication-latency tradeoff.

**Endpoints that wake nothing, marked anyway.** No ring operation blocks, so
dropping an endpoint wakes no thread. But a task that polls `try_receive`
until `.closed` waits for the sender's drop as surely as a blocked `receive`
does, and a parent holding the sender across that task's join would spin
forever. Marking both endpoints `@(wakes_on_drop)` brings the
[join check](design.md#releasing-before-the-join) to polling loops. Its cost is
rejecting a parent that holds an endpoint across a join whose tasks never poll
for closure, which moving the endpoint into a task, or dropping it first,
answers.

### Child processes

A child process needs explicit choices about argument quoting, handle
inheritance, environment, and waiting. `core:process` searches a bare program
name on `PATH`, quotes arguments, and restricts inherited handles to the
requested standard streams. Those choices prevent ambient process state from
silently changing which program runs or which resources it receives.

Dropping a `Child` closes handles without waiting or killing. A separate process
may be intended to outlive its parent; silently blocking or destroying its work
would be surprising. See the [process contract](standard-library.md#coreprocess).

### Managed lexical storage

Owning values release storage at scope exit. `unsafe.forget(move(value))`
explicitly suppresses cleanup for one value; `static` and `thread_local` select
storage duration without creating another type.

File-scope and static owners have no automatic shutdown order: their cleanup
could depend on other globals or running threads. Use a lexical owner for
observable cleanup, or `exchange` to extract a static value while leaving a
live replacement. Thread-local owners do have an endpoint and drop on normal
thread return, in reverse initialization order.

### An owner for one value

[`Box(T)`](design.md#owned-values) gives one allocated value the same ownership
rules that a dynamic array gives many: cleanup, region tracking, copying, and
read-only borrowing. It is copyable when its payload is; last-use transfer
avoids unnecessary clones and copy-cost diagnostics expose the rest.

A library record over `rawptr` cannot express the same contract. It would admit
a null zero, hide borrows carried by its payload, and need the checker to
recognize payload projection separately. A built-in box makes those properties
part of the type. It occupies one address, as does an optional box.

Raw allocation remains available as `unsafe.new` and `unsafe.free`. Checked
ownership uses `Box(T)`, so the result's type says who releases it.

The type is `Box(T)` and its constructor `box(value)`, as `Shared(T)` and
`Weak(T)` are types and `shared(value)` a constructor. Every predeclared generic
type is capitalised and nothing else is, so a reader can tell a type from a
call. When one lower-case name was both, `box(x)` was a type or an allocation
depending on whether `x` named a type, and the compiler needed a rule for each
handle to decide which.

### Zeros that are values

`{}` means a usable zero: an empty view, invalid type id, default allocator,
or empty weak handle. `nil` means an absent raw address. A non-null type has no
valid zero, so `^T`, procedure values, `dyn` views, `any_view`, `cstring_view`,
`Box(T)`, and `Shared(T)` cannot be null. Absence is represented by `Option`.
The non-null types split into references, which are borrows and checked as
such, and owning handles, which are owners. Calling them all references would
make an owning handle look like a borrow; the shared name is what the zero rule
and the `Option` niche need.

This moves the null check to the conversion from an unchecked address rather
than every dereference. It also avoids a nullable reference inside an optional
reference having two representations of absence. The freed null representation
lets `Option(^T)` and `Option(Box(T))` occupy one word.

The cost is explicit construction: records containing references have no `{}`,
and globals cannot initialize a reference from a runtime address. A second
non-null pointer type would instead make every API choose between two pointer
families for a distinction `Option` already expresses.

### Required fields

A representable zero need not be meaningful for a particular field.
`@(required)` prevents a literal from omitting that field and prevents implicit
construction of the record's zero.

Requiring every field in every literal would discard useful zero filling.
A record-wide prohibition on `{}` would still allow a literal to omit the
specific invalid field. A field-level requirement covers both problems while
remaining opt-in. A file handle needs no such mark: its zero is a valid closed
state.

### Conditional patterns

`if (case ...)` and `for (case ...)` abbreviate a switch over one variant.
For a fallible stream, `for (case .some(entry) = next() or_return)` combines
error propagation and end detection without an extra switch body.

The parser lowers these headers to the switch they describe, preserving its
ownership, scope, and control-flow rules. Nested patterns, multiple cases, and
header initialization are omitted to keep the abbreviation small.

### Updating a payload in place

`case .some(&mut node):` exposes the payload as a writable place. Without it,
an update would require exchanging the union for an empty value, consuming it,
and assigning the result back. The spelling matches mutable `foreach` bindings
and `&mut` expressions.

The binding retains the subject's borrow and tracks its fields separately.
This permits checked cursor walks without overlooking invalidation of another
borrowed field. A second mutable path into an owning chain still requires a
different representation, such as indices into a slot array.

Generated box lifecycle operations recurse. Long linked chains may need an
iterative drop hook to avoid exhausting the stack.

### Field bindings in a case

A payload is often a record, and binding it whole leaves selection or
destructuring as the next step. Destructuring a borrowed payload clones it, so
`case .add(pair): left, right := pair;` over a place copied both boxes and
everything under them. `case .add(left, right):` binds the fields as a
`foreach` header binds an element's: borrowed over a place, `&mut` leaves
included, and transferred over a temporary, as consuming destructuring does.
A recursive union, such as a syntax tree a compiler written in Loke walks, is
where this pays most.

It stays one level, a variant and its record's fields, so patterns still do
not nest. One binding still names the whole payload, as one `foreach` binding
names the whole element, so the arity of a pattern decides which it means.

### Storage modifiers instead of storage attributes

`static` and `thread_local` are declaration modifiers because they determine
lifetime and cleanup. Removing one can reset state on every call or invalidate
a returned borrow. Attributes such as `@(link_name)` describe other properties;
they do not choose storage duration. Cleanup suppression belongs to the
per-value `unsafe.forget` operation.

### No `stack` modifier, and no heap-promoted locals

Lexical locals stay in their stack frame. Automatically moving a large local
to the heap would hide an allocation and a failure path behind an ordinary
declaration. A `stack` modifier would then exist only to undo that policy.
Programs needing a large heap allocation can use an owning value. Oversized
stack frames can still overflow.

### Value-semantic assignment

Copying a dynamic array or map produces an independent value; pointers and
`Shared(T)` make sharing explicit. Strings share immutable storage. Implicit
copying keeps generic assignment uniform and lets records gain owning fields
without breaking every caller.

The cost is possible allocation. [Last-use transfer](design.md#last-use-transfer)
avoids a clone when an eligible local is finished, and copy-cost diagnostics
report allocating copies and large inline copies that remain. Borrow-related
exclusions keep this optimization conservative.

A copy hook must preserve the source's value, since an eligible copy may become
a move. Otherwise adding a later read could change an earlier assignment's
meaning. A duplicate that intentionally differs belongs in a named operation,
not a copy hook. Analysis order and generated moves are documented under
[Ownership, lifecycle, and provenance](compiler-architecture.md#ownership-lifecycle-and-provenance).

### Panics run lexical cleanup

Managed resources need a defined answer when execution fails. Under `unwind`,
a panic runs the faulting thread's live owners and `defer`s. A file's `drop`,
for example, closes its handle. It does not run package shutdown hooks or unwind
other threads.

`abort` exists for builds that cannot afford unwind machinery; it runs no
cleanup. Neither strategy permits catching a panic. The choice changes cleanup
on termination, not program validity. See [Panics and unwinding](design.md#panics-and-unwinding).

### Methods, interfaces, and operator overloading

Methods attach behavior to types without putting procedure declarations in
their data representation. An explicit `self` parameter distinguishes instance
methods from type-level procedures and exposes the receiver's parameter mode.

Structural interfaces serve generic constraints; named `slot` requirements also
provide runtime dispatch through `dyn` views. Expression requirements remain
static-only. Operators, indexing, iteration, and lifecycle hooks use the same
lookup and overload rules as other calls.

Extensions affect implicit lookup only inside their declaring package. Generic
bodies use definition-site lookup, and map key equality and hashing must be
inherent to the key type. Those limits prevent an import or caller-local
extension from changing existing code or corrupting a shared map's policy.

### One language at compile time

Ordinary procedures execute when a constant context requires their result.
They keep ordinary types, loops, mutation, and reflection rather than introducing
an untyped macro language. `$` names specialization inputs, `::` binds constants,
`when` selects source, and static `foreach` expands typed code; no single marker
silently moves arbitrary runtime work into compilation.

File and environment access belong in explicit build inputs. Ambient compiler
I/O would make evaluation depend on the machine instead of the source and build
configuration. A runtime call with constant arguments remains a runtime call.

User lifecycle hooks are excluded from evaluated paths. Running them correctly
would require reproducing runtime copies, moves, cleanup, and their order;
getting that wrong could make compile-time and runtime results disagree. See
[Compile-time phases](design.md#compile-time-phases).

### Build-selected services and explicit runtime state

The final build selects one default allocator and one logging provider.
Per-import configuration would require separately instantiated packages, with
rules for duplicated globals, initialization, symbols, and public type identity.
That is too much machinery for selecting services.

Request-specific allocators, log fields, clocks, cancellation, and other state
remain ordinary values. An ambient context pointer on every call would change
every ABI and require installation, derivation, and thread-propagation rules.
It would also pass the caller's current environment, not a callback's captured
environment.

Generic callback APIs instead accept a procedure or a record with `call`, checked
by `interfaces.Callable`. Captures remain typed and can borrow without allocation.
For one non-generic callback type, use a borrowed callable view.

### Capture literals

A [capture literal](design.md#capture-literals) abbreviates an ordinary record,
its fields, and its `call` method. Captures are initialized when the literal is
created. Keeping them in a clause after the signature makes ownership and escape
visible without reading the body.

Unmarked captures follow bindings: a place copies, while a temporary or explicit
move transfers. Borrowing is written. A borrowing default would silently share
state and constrain the source's later use; captures do not have the call-scoped
lifetime that makes ordinary parameter borrowing convenient. Copying a captured
owner can allocate, just as copying that owner into a local can.

The main rejected alternatives were:

- **Capture statements inside the body:** they appear to run on every call,
  hide the callable's layout and lifetime, and need rules for conditional or
  unreachable captures.
- **Inferred receiver modes:** a body edit could change which callback APIs
  accept the literal. The current plain `self` matches the library's callable
  constraint; mutable and consuming callable designs remain
  [open](open-questions.md#what-a-capture-literals-call-cannot-do).
- **A structural environment plus code pointer:** it would expose captures in
  type identity and make calls indirect. An ordinary generated record keeps
  generic calls direct and optimizable.
- **New generic parameter syntax:** `interfaces.Callable` and its associated
  result type reuse existing constraints rather than giving `proc(...)` a
  different meaning when a `$` appears inside it.

`capture` is contextual after a procedure literal's signature, preserving its
use as an ordinary identifier elsewhere.

### Borrowed callable views

A [`dyn proc` view](design.md#borrowed-callable-views) gives heterogeneous
callbacks one non-generic type. It holds data and code pointers and borrows its
target. Generic `Callable` parameters permit direct, inlinable calls; a view
trades that specialization for one signature and indirect dispatch.

There is only one call slot, so a separate witness table would add a load
without adding capability. A procedure value occupies the data word itself,
with a shared adapter, so converting a procedure does not borrow the local
variable that happened to hold it.

Conversion from a procedure or capture literal is implicit because the
destination fixes the complete call signature and capability. Converting a
named record stays explicit: it can expose roles other than calling. Temporary
targets follow the [one temporary-lifetime rule](#one-temporary-lifetime-rule),
so a literal stored straight into a `dyn proc` local lives until the block
ends.

Making every procedure value carry an environment was rejected. It would widen
thin procedure pointers, disrupt C callbacks, and require either owned
environments with allocation and lifecycle rules or borrowed environments with
lifetime tracking on every procedure value. Capture records can still allocate
when they copy owning fields; the decision avoids requiring a heap environment
merely to represent a callable.

### Typed fallibility

`Option(T)` represents absence and `Result(T, E)` represents failure. Each is
one ordinary union value that can be stored, passed, or returned. Named variants
remain unambiguous even when success and failure have the same payload type.

[Typed fallibility](design.md#typed-fallibility) recognizes declared union shape,
not privileged type names. This replaces special trailing-status rules while
letting library unions use `or_else` and `or_return`.

### Leaving from `or_else`

`or_else continue`, `or_else break`, and `or_else return value` cover the
common case of an absent value that ends a step, without a nested switch or
`if (case ...)`. They are the statements themselves in the fallback position,
not new expressions, so they keep the statements' rules and cleanups. A loop's
header cannot use `break` or `continue` this way: it is evaluated outside the
body, so whether it leaves the loop or an enclosing one would be a new rule.

### The failure operand of `or_return`

Before the failure operand, changing an error's domain was a method call to the
left of the operator that consumed it, `f().map_error(App_Error.io) or_return`,
which read as "convert, then maybe return" although conversion matters only on
the path that returns. `map_error` rebuilt the result on success, `ok_or` built
its error on every call, and an enum argument to `ok_or` needed its type
because `ok_or` infers it. Writing the error to the right of `or_return` puts
it on the failure path only, and lets `.name` resolve against the procedure's
error type, which has already chosen the union.

Wrapping stays explicit: each site names its variant. Alternatives that removed
the name were rejected:

- **Declared wrapping**, `@(wraps)` on a variant, makes the conversion implicit
  at the site and visible only at the union.
- **Inferring the variant from a unique payload type** breaks every distant
  `or_return` that relied on it when a second variant of that type is added.
- **Matching variant names to error types**, `io` to `io.Error`, gives names a
  meaning they have nowhere else; a rename or an import alias would change
  behavior.
- **A conversion interface like Rust's `From`** is implicit and needs coherence
  rules for who may declare a conversion.

The operand is a postfix expression after a postfix operator, so binary
operators still apply to the payload: `f() or_return + 1` keeps its meaning. The
cost is that a member of a bare `or_return`'s payload needs parentheses,
`(f() or_return).len()`; nothing in the repository wrote the unparenthesised
form, and the diagnostic suggests the parentheses.

`Option.ok_or` stays after the failure operand took over propagation. A
failure operand adapts an absence only where it returns. An `Option` that
becomes a `Result` value has no such site: it is stored, passed to a
procedure that takes a `Result`, or switched on. Without `ok_or` each of those
is a switch of its own, and `map_error` keeps the same job for a `Result`. Its
cost is the eager argument, which is built on every call, so it suits a cheap
error such as an enum value. An expensive error belongs after `or_return` or in
a switch. A lazy `ok_or_else` taking a callable was not added, since a switch
already writes that case plainly.

### `Status(E)`

A procedure that only fails returned `Result(Unit, E)`, so the empty type
appeared in every such signature and every body ended in `return .ok;`.
`Status(E)` is a fallible union of its own shape rather than a second name for
`Unit`, which [A `()` unit type](#a--unit-type) rejected. A parametric alias,
`Status :: Result(Unit, $E)`, would keep one type, so `map_error` and generic
code over `Result` would work unchanged, but a type alias takes no parameters.
The cost is that a generic procedure over `Result($T, $E)` does not accept a
`Status(E)`. `Outcome` was the alternative name; `Status` was kept although it
can be misread as a process exit status.

A body whose success carries nothing may reach its end, which returns that
success. Every failure in such a procedure is written explicitly, so the end
has one meaning, as in a procedure with no result. `Result(Unit, E)` is not
covered, so a generic `Result($T, E)` body cannot change meaning with its
instance.

### Success returns

`return .ok(x);` and `return .some(x);` named the one variant a success could
be, so [Success returns](design.md#success-returns) let `return x;` build it.
The form of the expression decides before its type does, so a constant or a
literal is never compared with the result, and a variant construction keeps its
meaning. A value that is already the whole result is returned unchanged; the
alternative, always wrapping, would make `return other_result;` a type error.

Only the success is implicit. A failure built from a value's type would choose
a variant by type, which [the failure operand](#the-failure-operand-of-or_return)
rejected for `or_return`, and it would make `Result(int, int)` ambiguous.
Swift and Zig also make the success path the plain one. Zig coerces an error
value by its type as well, which works there because error sets are a kind of
type of their own; a Loke failure payload is an ordinary type that a success
payload may share.

`nil` is excluded because several languages spell an optional pointer's absence
with it (Zig's `?*T`, Swift, Kotlin), while in Loke `nil` is a pointer value, not
a failure. Wrapping it would silently turn `return nil;` from absence into
`.some(nil)`.

A wrapped return takes its value as the plain statement does, so an owned
local transfers. A written `.ok(x)` copies a place, as any construction does;
making a return copy where the same statement without a wrapper would move
would be a difference nobody could see in the source.

Generic bodies are monomorphized, so the choice between success and error
could otherwise depend on the instance: in a body over `Result(T, E)`,
`return error;` is an error for most instances and a success where `T` and `E`
are the same type. Excluding results that name a generic argument keeps the
meaning of the body the same in every instance. A result whose failure carries
nothing, such as `Option(T)`, has only one payload to build, so it keeps the
shorthand.

### `errdefer`

`defer if (failed)` left the flag to the programmer, who had to set it on every
failure path. `errdefer` runs when the procedure returns its failure variant,
decided by the returned value's tag, so `return .err(e)` and returning a saved
outcome behave alike. Its spelling follows Zig: one reserved word, found by
search, shaped like `defer`. Unlike Zig's, it also runs during panic unwinding:
it exists to undo incomplete work, a panic leaves work as incomplete as a
failure return does, and `defer` already runs there. Binding the error, Zig's
`errdefer |err|`, is left for later.

Once a success return has walked past an `errdefer`, it is retired: a panic in
an older cleanup does not bring it back. Scope exit is one LIFO traversal, and
an action it passed is behind it, as with the ordinary scope exit that already
discards an `errdefer`. Running it then would undo work after the newer
cleanups that depended on that work had already run.

### A fallible `main`

`or_return` needs a fallible result, so a `main` returning nothing or an `i32`
ended every program that could fail in a switch, and examples that printed the
error forgot the status. A `main` returning `Status(E)` reports the
failure the way a formatted panic reports its arguments, after cleanup, and
exits 1. The success arm carries nothing because there is nowhere for a value
to go.

### One result

A procedure returns at most one value. Several results form an anonymous record
and use the same destructuring as other records. That removes separate rules
for result lists and implicitly initialized named-result locals.

Labeled result names participate in type identity: `(width: int, height: int)`
is not `(height: int, width: int)`. Keeping the same identity when a record is
stored or returned prevents field-name changes from silently reinterpreting it.

### Records without field names

Unlabeled records serve results whose names callers would immediately discard
through destructuring. They are structural records with positions instead of
names, not a separate tuple model.

Only destructuring and positional construction access their fields; there is
no `.0` selector. `(T)` remains grouping, so an unlabeled record needs at least
two fields. A labeled record can implicitly lose its names, but the reverse
conversion and conversion between different labels are absent. All fields must
be labeled or all unlabeled. See [Anonymous records](design.md#anonymous-records).

### Structs declare, parentheses describe

A struct is nominal and belongs to a package. That ownership supports private
fields, hooks, `move_only`, and changes to field order without changing outside
callers. An anonymous record describes a structural value without those rights.

Combining the two would either weaken encapsulation or make every returned pair
a declaration. Instead, `struct` declares a type and parentheses describe one.
Inline anonymous `struct { ... }` types and `distinct` over anonymous records
would add nominal identities without useful ownership, so they are rejected.

### Ordered anonymous records

Sorting by `(priority, id)` would otherwise need a comparator. An anonymous
record has no encapsulation to protect, and its field order is its identity, so
lexicographic order is the only one it can mean. A struct may reorder its
fields, so it keeps writing its own `<`.

The first unequal field decides, rather than the first field where either
operand is less. A record of one float then orders exactly as the float does,
NaN included, and the four operators need only each field's `==` and `<`, as
`interfaces.Ordered` provides. A field whose type declares its own comparison
makes the record unordered. Comparing that field by the built-in operator would
contradict its type, and calling the type's operators would make record order
run user code; that can come later if programs need it. See
[Comparison operators](design.md#comparison-operators).

### Methods on structural types

An anonymous record or union belongs to no package, so an `impl` on one is an
[extension](design.md#methods-and-implementation-blocks), as one on `int` is.
Rejecting it would make a structural type the one type that cannot be
extended, though extending it grants nothing that "Structs declare, parentheses
describe" protects: an extension adds no hook, sees no private field, and stays
in its own package. Inside that package it reaches every spelling of the shape,
which is what an extension of `[2]int` does too.

For the same reason a structural type counts as built-in for
[operator lookup](design.md#operator-lookup-and-overload-resolution): an
extension `==` or `<` cannot change how it compares. Its equality and order
come from its parts, as an array's do, and part comparison already ignores
extensions. Letting a top-level extension win would make `a == b` and
`[1]T{a} == [1]T{b}` disagree, and make one shape compare differently in each
package that extends it.

### Anonymous unions

A procedure whose result has several outcomes needed a declared union even when
no other code named it, and a set of errors from different packages needed one
for each combination. [Anonymous unions](design.md#anonymous-unions) are to
named unions what anonymous records are to structs: parentheses describe one,
`union` declares one.

The alternatives keep their labels. An unordered set of payload types, `(A |
B)`, would need type-based matching and set normalization, and could not keep
two alternatives with one payload type apart, which `(read: io.Error |
log_write: io.Error)` does. The colon is required so that `(a | b)` stays an
expression.

Identity is ordered for the reason a record's is: the order is the tag order,
and making two orders one type would need a canonical order that the source no
longer shows. Converting between orders and between sets of labels is
[widening](#widening-by-label).

An anonymous union carries no attributes, so it is never fallible. A failure
policy is the job of `Result`, `Option`, and a named union with `@(failure=)`;
an attribute on a structural type would become part of its identity, and two
otherwise equal types would differ only by it. An anonymous union is therefore
used as data, or as the error payload of a `Result`, where the
[failure operand](#the-failure-operand-of-or_return) already wraps into it.

Nor do anonymous unions replace `Result`, `Option`, and `Status`. The labels
would differ per API, so `map_error`, `ok_or`, and any code generic over a
result would need a protocol to find the success and the failure, which the
nominal generics give for nothing. The failure, zero, and acknowledgment
properties would join the structural identity, callers would lose the uniform
`.ok` and `.err`, and `Result(File, io.Error)` would grow into an attributed
inline union. A flat union with marked failures, `(T | Error(E))`, is worse:
flattening merges a nested result into one layer, so one `or_return` would
take both an outer and an inner failure, and an `Error(X)` returned as a
generic success would read as a failure.

### Widening by label

Without a conversion, every helper over a smaller error set needed its own
`or_return .name` at each caller, or one application-wide union that every
helper over-reported. [Widening by label](design.md#widening-by-label) lets a
bare `or_return` propagate a helper's set into any set that contains it, so a
helper reports exactly what it can fail with.

It is not the variant inference that
[the failure operand](#the-failure-operand-of-or_return) rejected. The label and
the payload type are written on both sides, so adding an alternative to the
destination changes no existing conversion, and adding one to the source,
renaming a label, or changing a payload type is a diagnostic at each site whose
destination lacks it, naming the alternative.

The rule matches exact payload types, not assignable ones. A payload that
converted on the way, such as a `string` into a `string_view` alternative,
would need a conversion per alternative and a borrow the source never had, and
would make a nested anonymous union widen through its parent, which the record
rule does not do either. Named unions stay out because their variant names
belong to their declaration: two packages' `io:` variants need not mean the
same thing, while an anonymous union's labels are its whole identity.

A comparison widens as well: the comparison rule already asks only that one
operand be assignable to the other, and two values with the same label compare
as the same alternative.

A place is copied at its own type rather than at the destination's, so a
source that is copyable widens into a destination with a move-only alternative
it does not have. An argument to a value parameter is lent, as any argument
is, so it is widened without a copy. The conversion does not reach through containers, since a
`[dynamic]` of the wider union has a different element size; that rebuilds the
container, which is a loop the program writes.

### Structural patterns

Without bindings, a helper over "a value or nothing" took a named union such as
`Option(T)` or one concrete shape, so an anonymous union could not reach generic
code by its own spelling. A `$` inside a [structural
pattern](design.md#specialization) makes the shape the constraint, as `[]$E`
already does for a slice.

The matching follows each type's own conversions, so a pattern accepts what a
concrete parameter of the produced type would. A record's identity is its
ordered fields and it converts only by dropping labels, so a record pattern
needs the same labels in the same order, and an unlabeled one takes any record
by position. A union converts by widening, so a union pattern takes any
argument whose alternatives it has, in any order, and binds each payload by its
label. Binding by label rather than position also means a reordered union
binds the same names, which positional binding would silently swap. Named types
stay out for the reason they stay out of widening: their fields and variants
belong to a declaration, which `Option($T)` already matches.

### Per-variant switch cases

Interpreters walking a tree, protocol handlers, and error reporters often do
the same thing for every alternative: call `area()`, print the payload, or
report the label. Without help that is one case per variant whose bodies differ
only in the payload type, or a `default:` that cannot touch the payload and
silently absorbs a variant added later. [An expanded
case](design.md#per-variant-switch-cases) writes the body once and keeps the
check: each copy is checked against its own payload, so a new variant whose
payload lacks what the body uses is a diagnostic naming it.

It stays inside `switch` rather than adding a construct. A case already binds
a payload under switch ownership, and a static `foreach` already checks one
body per element; the expanded case is those two rules together, so it
inherits their ownership, diagnostics, and control flow instead of defining
its own. Zig's `inline else` does the same for its switch prongs; here the `$`
marks a compile-time binding as it does in a static `foreach` header.

It comes last and covers the rest, because a case that matched some variants
before the explicit ones would make the explicit cases' coverage depend on
order. Field bindings are rejected because the payloads differ in shape. A
payloadless variant binds `Unit{}` so that one body can name `payload` for
every variant, the value `.as(.name)` already gives such a variant.

`variant` is a compile-time descriptor rather than a name the body can use as a
label, since static expansion never synthesizes identifiers. `when` over
`variant.name` or `variant.type` covers the cases that differ. `variants_of(T)`
is the same descriptor as an array, for generic code that walks a union's
shape the way `fields_of` walks a record's.

A generic subject can require a union with the bound `where is_union(E)`, so a
wrong argument is reported at the call rather than inside the instance.
Whether a type is a union is a fact about its kind, not something it can do, so
it is a built-in predicate like `is_copyable` instead of an interface. An
interface for it would have no slots, and the compiler would have to supply
its satisfaction. A kind annotation such as `$E: union` was declined too: it
would add parameter syntax for one kind, while the existing `where` clause
already carries the bound and its diagnostics.

### Union argument expansion

A handler set dispatched from several places, such as an event loop's
handlers or a message protocol's, otherwise repeats the same switch at every
site. [`handle(..event)`](design.md#union-argument-expansion) dispatches it in
one expression, exhaustively and by label, to an ordinary procedure group.

It is defined as an expanded case calling the callee with the label as the
argument name, so it adds a spelling, not a mechanism. Ownership, exhaustive
checking, a payloadless variant's `Unit{}`, and the diagnostic naming a
variant without a handler all follow from that definition. The one rule the
switch does not supply is the call's value: every expansion has one result
type, since a call has one type.

Labels become parameter names. That is the coupling a visitor's method names
have with the cases it visits, but checked: renaming a label or a parameter is
a compile error at the expansion. It is also why `(left: int | right: int)`
reaches two members although both payloads are `int`; dispatch by payload type
could not tell them apart. One hazard remains: a new label that matches a
parameter of another member, with a payload type that member accepts,
dispatches to it. The explicit `..` keeps such a group deliberate.

The union is the only written argument, so a label never competes with a
positional argument for a parameter. Handlers are procedures, so `return` and
`or_return` in one leave the handler, not the caller; a switch or an expanded
case is the form for the caller's control flow. A member returning a place is
rejected, because each expansion would name a different place.

`..` was chosen over a method such as `answer.dispatch(show)`, which would need
procedure groups as values. A union is never a sequence, so the operand's type
decides between spreading and expanding. A visitor written as
`visit(answer, left = ..., right = ...)` was declined: deriving its parameters
needs compiler support beyond this expansion, every callback and its captures
are evaluated though one body runs, so two `&mut` captures of one place
conflict, and a capture literal per variant is longer than a case.

### Distinct types

A `distinct` type inherits comparisons but no other operators by default.
Comparisons cannot produce a value with the wrong dimension; arithmetic can.
`delegate` exposes a chosen set of underlying operators so a unit type can
permit addition without also permitting meaningless multiplication. This costs
some explicit declarations while keeping representation and meaning separate.

### One pattern grammar, flat declarations

Binding forms use subsets of one pattern grammar: names and `_`, writable
`&mut` leaves, static `$` leaves, and groups that descend into record fields.
`foreach` supports nested groups because adapters may wrap the yielded value.
A switch case takes one flat list over its payload's fields.
Declarations stay flat: a nested value the program constructed can be unpacked
in another statement, without adding recursive declaration and cleanup rules.

## Removed or narrowed features

### Generics are not ABI surface

Generic declarations have no runtime representation and cannot themselves be
exported or passed as procedure values. Only concrete instantiations reach ABI
lowering. A foreign wrapper exposes a concrete signature, keeping generic
specialization separate from the binary interface.

### Colon annotations on inferred generic bindings

`x: $T: Shape` had no specified constraint semantics. Parameter patterns such
as `[]$Element` already describe shape, and `where` clauses filter candidates.
Rejecting the extra colon avoids accepting an annotation that checks nothing;
explicit generic parameters such as `$T: type` keep their ordinary annotation.

### Floating generic arguments use representation identity

A floating generic argument is identified by its converted IEEE-754 encoding.
Positive and negative zero can behave differently, and code can inspect NaN
payloads. Numeric equality would merge observable distinctions and cannot even
identify a NaN with itself. [Generic argument identity](design.md#generic-argument-identity)
uses representation recursively through aggregates; ordinary numeric comparisons
keep their usual meaning.

### Constraint entailment in overload resolution

Constraints decide whether a candidate is viable; structural specialization
decides which viable candidate wins. A tie remains an ambiguity.

Ordering candidates by logical constraint strength would require normalization,
interface expansion, and entailment rules just to select a refinement
automatically. Explicitly naming the refinement keeps overload resolution
predictable without that second ordering system.

### Statement labels and multi-level breaks

`break` and `continue` target the innermost loop. A switch selects and is not a
break target. Multi-level exits use a helper return or an explicit loop condition,
keeping control flow structured without labels.

### `package main` shows its fields

Nothing imports an executable's root, so package-private fields there protect
nothing, yet they hid every field from printing: a first program's
`fmt.println(Point{1, 2})` printed `Point{}`. Making `main` unimportable and its
fields public by default fixes that without a second printed form per type.
Declarations keep the package default, because a public extension exports a
name into its package's scope.

### File-private visibility

The package is the encapsulation boundary. `@(private)` means package-private;
`@(private="file")` would add another visibility level and rules for interacting
with public defaults. Code needing an independent boundary belongs in another
package.

### No public variables

Odin exports a variable as it exports anything else. Loke rejects
`@(public)` on a variable, and a public-default file or foreign block leaves
its variables package-private. [Global write effects](design.md#global-write-effects)
are inferred over the whole program and are not part of a procedure's type,
so with public variables a library that added a write to one of its globals
could break a caller in another package that held a borrow of it, with no
signature changed. A caller can now borrow another package's storage only
through a procedure whose result contract shows that it lends static storage,
and incremental checking has one inferred dependency fewer that signatures
miss. The cost to `core` was `os.args`, a zero-sized view that became a
constant. Read-only public globals were not added to soften the rule: a
constant already covers a value fixed at compile time, and a value computed
at run time is a procedure, which can still change how it is computed. This
was proposed by the language design review of 2026-10-11.

### Standard free aliases

`f(x)` uses lexical lookup; `x.f()` uses receiver lookup. Special aliases such
as rewriting `len(x)` to `x.len()` would duplicate spellings and need exceptions
to stop mutating receiver borrows from hiding in free-call syntax.

Built-in types keep ordinary contributed members such as `len`, `cap`, and
`hash`. Even a fixed array's `x.len()` evaluates its receiver; unevaluated
operands belong to operations such as `size_of`.

### `mem.` spellings of the allocation built-ins

Allocation built-ins have one spelling in the universe. A duplicate `mem.make`
or `mem.drop` would add no capability; fallible allocation is already available
through the corresponding `try_` operation.

### `fallthrough`

A switch case stops automatically. Multi-value cases cover shared choices;
shared procedures cover shared work. `fallthrough` would add control-flow and
cleanup exceptions to reintroduce an accidental behavior the switch avoids.

### Named-result initializers

Results are values supplied by `return`, not implicit locals initialized on
procedure entry. A result initializer resembling a parameter default would
attach similar syntax to a different trigger and complicate initialization.

### Reflection beyond fields and enum values

`fields_of`, `enum_values_of`, and `variants_of` cover data shape used by
serialization, bindings, and expanded switch cases. Reflecting procedures, parameters, requirements, and attributes would
need more descriptors and lookup rules without a demonstrated consumer.
Additional reflection can be introduced when an actual tool needs it.

### Associated interface members use expressions

`T.NAME -> Type;` is an expression requirement. Associated types use the same
form, `T.Element -> type;`, whose result is necessarily compile-time known.
A separate associated-constant declaration grammar adds little to that model.

### Headless switch

An `if`/`else if` chain already selects among unrelated conditions. Requiring
a switch subject avoids a second construct with the same purpose.

### `default:` switch arm

`default:` names the fallback arm clearly; `case:` remains accepted. Reserving
`default` avoids ambiguity with a declaration at the end of an arm, where
`default: int = 0;` would otherwise also be valid syntax.

### Compiler-defined domain types

Complex numbers, quaternions, and matrices belong in libraries because records
and overloads can express them. SIMD remains built in because its semantics
include target vector operations that a record cannot promise.

### Owning type erasure

`any_view` and `dyn` borrow their payloads. An owning erased value would also
need allocation, alignment, clone/drop dispatch, region tracking, and rules for
borrows across moves. Keeping those out makes dynamic dispatch usable without
silently allocating. Closed owning sets use unions; an open owning abstraction
needs an explicit storage and lifecycle contract.

### User-defined implicit conversions

User-defined conversions are written at the call site. Otherwise an import or
an overload could silently select runtime conversion work, requiring ranking
and chaining rules to contain the effect. Even a special case limited to
unfixed literals adds those interactions for little saved text.

Built-in implicit conversions remain, including owner-to-view borrowing. Their
meaning depends on the source and destination types, not imported conversion
code.

### A read-only-data attribute

Constants materialize as shared read-only storage when runtime indexing,
slicing, or an address requires it. They already provide immutability and
process lifetime, so a separate `@(rodata)` attribute would duplicate them.
The cost is an explicit [materialization](design.md#materialization) rule:
constants are not exclusively compile-time objects, and all uses share one
backing object.

### No octal escapes

Octal escapes added an ambiguous byte-versus-character spelling. Loke's former
`"\377"` encoded the Unicode character `ÿ`, rather than one byte `0xFF`.
`\x` already spells bytes and `\u` characters, so octal escapes are rejected
and the diagnostic points to those alternatives.

### No exponent operator

Odin has no `**`, and Loke does not add one. Its precedence has a trap:
`-2 ** 2` is -4 in Python and an error in JavaScript, and either answer
surprises someone. It would be the one right-associative binary operator. An
integer `**` needs its own overflow rule and an answer for a negative
exponent, and a floating one is `pow`, whose special cases (`pow(NaN, 0)`
is 1) are a library contract rather than an operator's. `^` is taken by
pointers, as in Odin. `math.pow` and `math.pow_f32` name the operation.

### Sized boolean types

Loke has one byte-sized `bool`. Foreign boolean typedefs bind as their actual
integer representation and convert in a wrapper. That handles conventions such
as true being `-1` without pretending every foreign boolean is a wider Loke bool.

### Unchecked union extractions

A union is inspected by exhaustive switch or checked `value.as(.variant)`,
which returns an optional copy. Move-only payloads need a switch. Reading an
inactive payload as an owner could manufacture a container header and later
free an invalid address, so no unchecked extraction is part of ordinary syntax.

Raw representation work remains in `core:unsafe`. The open type set of
`any_view` has a separate checked, panicking extraction; neither form guesses
the active payload.

### Nominal conformance declarations

Structural interfaces need no `implements` registry. A declaration with no
semantic force would only repeat `static_assert(Interface(Type))` while implying
nominal membership. Giving it force would require a different design for
coherence, generic conformance, and witness construction.

### A `()` unit type

`Unit :: struct {}` already represents the empty result payload in
`Result(Unit, E)`. A second spelling for a zero-sized type is unnecessary;
`()` is not a type.

### Reviving a variable without a write

A full assignment revives a dead variable; `unsafe.forget` consumes a live
value without cleanup. A separate unsafe operation that marks dead storage live
would mainly let callers bypass conditional drop tracking. It has no demonstrated
use that justifies pretending unwritten storage contains a value.

### Hand-written package header files

A public-signature file maintained beside the implementation would duplicate
every public declaration, and the two copies would drift, as C's headers and
their definitions do. The [interface file](compiler-guide.md#interface-files)
gives readers the same view without a second copy: `lokec -api` generates
`api.loki` from the source, `-api-check` fails when it is stale, and no
compilation reads it, so the `.loke` files stay the only authority.

It is checked in rather than generated on demand because people and agents
read what is in the directory, and a command they must first learn about loses
to that; a checked-in file also turns a change to a package's public API into
a diff in the commit that makes it, as Kotlin's API dumps and Android's
`api/current.txt` do. It is Loke rather than Markdown because a reader already
knows the syntax, the editor highlights it, and the signatures are the source's
own, with no headings or fences repeating the names. The `.loki` extension
keeps it out of the package, whose files are its `.loke` files.

## Changed features

### Reading a carrier under a read-only reborrow

A read-only reborrow prevents writes through another path, but need not prevent
another read. Permitting recognized read-only uses allows `slice.equal(xs, xs)`
without weakening exclusivity. A mutable reborrow still excludes other reads,
which could observe a partially updated value.

### Each required result is asked about

`@(require_results)` checks each result stored in a local, not merely whether
the variable is ever read. Overwriting an unexamined error must not become valid
because an earlier value was examined. The check reports results no path reads;
values explicitly constructed by the caller do not represent an ignored call
result.

### Unchecked operations need the import

`core:unsafe` is the visible review boundary for operations that discard
lifetime or initialization guarantees. The file using unchecked pointer
conversions, C-pointer access, `---`, or `@(initialized=...)` must import it.
Converting to raw storage alone does not grant checked access back into it.

A file-level gate makes these operations searchable without adding an unsafe
expression language. `base:` packages are exempt because they implement runtime
facilities and cannot import `core:`. Generated traversal checks bound an
initialized prefix, but cannot prove those slots contain valid values.

### Formatting and logging sinks are `dyn` views

`fmt.Writer` and `log.Logger` are borrowed `dyn mut` views. Records implement
their write slot and keep ordinary type and borrow checks, avoiding raw state
pointers in user-facing adapters.

A formatter uses the sink during its call. A logger provider lends static
storage for process lifetime. Neither requires an owned closure, and neither
view has a null state.

### A checked pointer prints its referent

Every other checked view prints what it views, and a box prints its payload. A
`^T` printing its address made a map loop with one binding print addresses.
A checked pointer is never null, so it prints the value; an unchecked address,
which may be null or dangling, still prints as an address.

### Generated printed forms say what they print

Generated formatting distinguishes values that would otherwise look identical:

- Finite floats include a fraction or exponent, so a printed integer and float
  do not share the same spelling.
- Strings and runes inside aggregates are quoted and escaped, preserving
  element boundaries. A string printed alone remains plain text.
- An anonymous record prints its fields without repeating its type.

Struct formatting includes only public fields because one generated form serves
all packages. A type wanting a different representation declares `format`.
See [String format printing](design.md#string-format-printing).

### Explicit overload groups

Named groups make the overload set visible while each implementation keeps an
ordinary callable name. Ambiguity is diagnosed rather than settled by declaration
order. Methods and operators follow the same resolution rules.

### `+` concatenates strings at runtime

Runtime `+` keeps short text expressions convenient, allocating through the
default allocator. Each concatenation copies its operands, so repeated growth
can be quadratic. Use `String_Builder` for loops or allocator selection.
Copy-cost diagnostics do not measure concatenation's allocation cost.

### No enum arithmetic or bitwise operators

Enum values can have gaps, so arithmetic or bitwise operations can produce a
non-member. Enums remain comparable and ordered; `Bit_Set(Enum)` represents
flag sets, and explicit integer conversion supports representation-level work.

### Closed enums and payloadless unions

Enums are closed sets, allowing exhaustive control flow to guarantee a matching
arm. `Enum.from_int` validates membership and returns an `Option`; foreign or
wire values remain integers until validated. An enum without a zero member has
no zero value.

Payloadless union variants use bare names. A type name cannot accidentally become
a payloadless variant, so Odin-style `union { int, string }` is diagnosed instead
of silently changing meaning. The older `name:` spelling remains accepted.

### Integer overflow panics

Integer `+`, `-`, and `*` panic when the mathematical result cannot fit, signed
and unsigned alike. This catches bad sizes and bounds while keeping behavior
independent of optimization level. The cost is an overflow check where the
compiler cannot prove the range; for unsigned arithmetic it is one branch on the
carry flag.

Unsigned arithmetic was once modular, as in C, Go, and Odin. Lengths are `int`,
so unsigned values appear mostly in byte, `u32`, and `u64` code: parsers,
codecs, and bindings. There an unnoticed wrap does harm: `u32(3) - u32(5)` is
4294967294, which converts to `int` without complaint and then sizes an
allocation or bounds a loop. A length that goes below zero is the same bug as a
signed sum that goes past its maximum, and the choice of a type should not decide
whether it is caught. Swift checks both, and so does Zig in its safe modes;
Rust checks both in debug builds only, which makes behavior depend on the build.

Arithmetic that is modular by design — hashing, checksums, random number
generators, multi-word carries — asks for it with `+%`, `-%`, and `*%`, Zig's
spelling. Operators rather than only `math.wrapping_*` calls, because such code
is chains of wrapping steps and must stay readable beside the reference it
implements: `x *% PRIME +% c`, not nested calls. `math.wrapping_*` remains for
generic code and procedure values, and `checked_*` returns an `Option`. The
wrapping operators are integer-only: a rune that wraps is not a character, and a
float has no low bits to keep.

A wrapping operator also replaces the idioms that relied on unsigned wrap.
`c - '0' < 10`, a digit test in one comparison, panics for a byte below `'0'`;
it is written `c >= '0' && c <= '9'`, or `c -% '0' < 10` where the trick is
wanted. Generic code over `interfaces.Integral` cannot write the constant
`T(0) - T(1)` for an unsigned `T`, even in a branch that never runs for one,
because the fold is checked; `math.wrapping_add(a, T(1)) == T(0)` tests for -1
instead. `Integral` does not require `+%`, so a distinct integer can satisfy it
without one, and generic code wraps through `math.wrapping_*`, which work on
the integer representation.

Shifts remain bit operations and atomic arithmetic keeps its hardware
read-modify-write semantics. See [Integer overflow](design.md#integer-overflow).

### Integer conversions keep the value

Integer conversion preserves the value or fails, whether the operand is a
literal or a runtime variable. Keeping only low bits for runtime values would
make a refactor from constant to variable change behavior silently.

`math.wrap` names truncation and `math.to` offers a checked optional conversion.
Those explicit operations also make wrapping arithmetic possible without
relying on lossy ordinary casts.

### Fused multiply-add is written

A floating-point expression is evaluated as written: `a*b + c` rounds the
product and then the sum, and the compiler never fuses them. A fused result is
usually more accurate but not always wanted. `a*b - a*b` stops being zero when
one product is fused and the other rounded, and the sign of a discriminant
`b*b - 4.0*a*c` can flip. If the compiler chose, the result would change
with the optimization level and the target. C and Go let the implementation fuse; Rust and Java never do and offer the
fused operation by name.

`math.fma(a, b, c)` is that name. It rounds once on every target, so code that
relies on the extra precision, such as an error-free product or a polynomial in
Horner form, says so. It is a procedure rather than an operator because it is
rare outside such kernels and takes three operands. See
[Floating-point operators](design.md#floating-point-operators).

It is computed in integer arithmetic, with the exact product in a `u128`,
instead of calling the C library. Microsoft documents its `fma` as allowed to
round incorrectly, and older versions did on processors without the
instruction; the CRT is linked statically from whichever SDK a build finds.
The baseline x86-64 target has no FMA instruction, so the software path is the
only one today. It is slower than the instruction, and correct.

### SIMD lanes follow the scalar rule

Replacing a scalar kernel with SIMD should not change overflow behavior.
Integer vector arithmetic therefore checks lanes and panics if any overflows;
`+%`, `-%`, and `*%` wrap lane by lane. Byte-lane image and codec kernels that
rely on wrap say so with them rather than through an exemption for unsigned
lanes. Reductions fold through the scalar checked operation so they agree with
the loop they replace. This costs checks but preserves the numerical contract
across optimization strategies.

### Signed shifts stay bit operations

Shifts build masks and pack representations. Bits shifted out are discarded,
including the sign bit, and every non-negative count has a defined result.
Treating a shift as checked multiplication would reject useful expressions such
as `i64(1) << 63`.

A negative signed count panics. Reading it as unsigned made `1 << k` for
`k := -1` quietly zero, which is never what a negative count meant; Go panics
there too. A constant negative count was already an error, so the run-time rule
only makes a variable agree with a constant.

Signed `x << n` equals multiplication by a power of two only when that product
fits. Explicitly separating bit operations from checked arithmetic keeps both
uses predictable.

### Generated `hash` follows generated `==`

A record already compares field by field without a written `==`, so requiring a
written `hash` before it could be a map key cost a hand-written pair for every
key type. The inherent-pair rule exists so one policy holds across packages; a
generated member is inherent, and a structural hash is coherent with structural
equality by construction. A part with its own `==` must bring its own `hash`,
which the generated one calls, so the pair stays coherent at every depth.

### `in` is a comparison, not an additive operator

`in` produces a Boolean, so it shares comparison precedence. Giving it additive
precedence would regroup `x in values + extra` as `(x in values) + extra`, making
the apparent collection expression mean something else. Ranges bind between the
two, as Swift's do, so `c in 'a' ..= 'z'` tests a range while `0 ..< n + 1`
still ends at `n + 1`; no grouping the move changed had a meaning before,
because each put a `bool` at a range's end.

### Comparisons do not chain

`a == b == false` looks like a chain but a left-associative reading means
`(a == b) == false`. Requiring parentheses or an explicit `&&` avoids that
ambiguity for both equality and ordering comparisons.

### Field order stays inside the declaring package

Positional construction or destructuring of an imported struct would make
field reordering silently swap values at outside call sites. Requiring names
outside the owning package preserves encapsulation. Anonymous records remain
positional because their field order participates in structural identity.

### Diverging procedures belong to the declaration

`-> !` lets calls such as `panic` satisfy any expected result position and lets
the checker recognize paths that cannot return. Divergence belongs to the
declaration rather than the procedure-value type: propagating it through values
would require a subtyping rule without an established use.

### The allocation built-ins follow the `try_` convention

`make`, `box`, and other policy-following forms apply the allocator's failure
policy. Their `try_` counterparts return a failure value. Keeping that convention
across built-ins and libraries makes error handling visible in the name without
forcing every allocation into a separate panic wrapper.

### `main` may return an `i32` status

Returning a status from `main` allows normal scope cleanup before the process
exits. `os.exit` terminates immediately and skips cleanup. An `i32` status matches
the process interface and avoids silently narrowing a wider integer.

### `assert` and `panic` print values after the message

A compile-time message plus value arguments can report the failing state
without first allocating a formatted string. Formatting writes directly to the
error stream. `assert` evaluates those arguments only on failure, keeping an
expensive diagnostic expression off the successful path.

### An iterator's yield mode follows from `next`

`next` already determines the item type and whether iteration owns or borrows
it. Reading that information from the signature avoids a redundant `Yield`
descriptor that could disagree. An owned pointer element remains an owned
element; yielding a borrow of it requires another reference level.

### A map's mutable lookup is the marked one

`find` returns a read-only optional reference and `find_mut` a mutable one.
This follows the same convention as `^mut`, `[]mut`, and `iter_mut`: the spelling
that can write is visibly marked.

### Mutable slicing is written `&mut a[lo:hi]`

`a[lo:hi]` is read-only; `&mut a[lo:hi]` is mutable. The destination type does
not select the capability or change which slicing overload runs. This matches
`&x` and `&mut x` and makes mutation visible at the call site.

Consequently, `fmt.println(primes[1:4], total(primes[:]))` can use both read-only
slices in one call. It needs no intermediate binding to change a slice's type.
Parenthesize a mutable slice before selecting a member:
`(&mut a[:]).indexed()`.

### A string literal receiver is a static `string_view`

A literal's storage is static and needs no owner. Member lookup treats it as
a `string_view`, so `"hello".bytes()` can lend static bytes without creating
a temporary owning string. Extensions declared only on `string` do not change
that receiver type.

### Map element mutation

Whole-element assignment `m[key] = value` may insert because it supplies the
complete value. Reading or modifying a field requires an existing entry and
panics if it is missing. Automatically inserting a zero for partial mutation
would make behavior depend on whether the element type has a meaningful zero.
`find`, `find_mut`, and `find_or_insert` provide explicit alternatives.

### Container insertion takes its element like an initialization

Insertion follows initialization: a temporary or `move(x)` transfers; a borrowed
place copies. Always borrowing would exclude move-only elements, while a `move`
parameter would require explicit moves even for simple values.

Fallible insertion uses the same rule. On failure it drops an argument it took;
an explicitly moved source is already dead. Returning the element inside the
error would disrupt the shared allocator-error type. A caller needing to retain
the value on allocation failure can reserve capacity before moving it.

### `string` borrows as `string_view`

Implicit conversion lets a read-only text API accept owners, substrings, and
literals through one signature. It is a validated, allocation-free borrow.
The reverse conversion must acquire ownership and is explicit through `.copy()`.

### Slicing text keeps its panic

A text slice must preserve UTF-8: a bound inside a code point panics. Rounding
silently would return different text, while an opaque index type would burden
every ordinary byte offset with a conversion.

Text and rune searches, and `rune_offsets()`, locate code-point boundaries.
Raw byte searches can locate continuation bytes: `strings.index_byte("é", 0xA9)`
returns `.some(1)`, but `strings.try_slice("é", 0, 1)` returns `.none`.
Use `try_slice`, `floor_boundary`, or `ceil_boundary` for untrusted byte offsets;
`prefix_runes` expresses a limit in scalar values. See [Boundaries](standard-library.md#boundaries).

### String ownership and concurrency

Immutable strings can share storage, so reference counting is atomic. The
allocator must separately support the thread performing the final drop; that
transfer obligation remains with the programmer. A `string_view` borrows text
without sharing ownership.

### Allocation failure

Copies, container growth, and string concatenation can allocate implicitly.
Because those expressions have no error-result slot, the allocator selects a
failure policy. Recoverable allocation uses `try_` operations.

A hidden sticky error flag would not identify which implicit operation failed.
An explicit result or termination is preferable to continuing with a silently
truncated value. The policies are defined under [Allocation failure](design.md#allocation-failure).

### Test procedures

A unit test has to reach package-private code, which only code in the package
can, so tests are declarations in the package and not a separate program. Odin
marks them `@(test)` too, but they take a `^testing.T` that a library runner
passes in. Loke's take nothing. A failed `assert` or a panic is the failure,
and a fallible result is one too, so `or_return` works in a test as it does in
`main`. An attribute needs no new syntax, where Zig's `test "name" { ... }`
blocks would, and a test's name is its procedure's, which the runner passes to
the executable to run it alone.

A test is checked in every build, unlike Go's `_test.go` files, Rust's
`#[cfg(test)]`, or Zig's tests, which only test builds analyze. A test that
only a test build sees goes stale without anyone noticing, and the editor would
need a second configuration to report its errors. The cost is that whatever a
test names exists in every build. A helper behind
`when (LOKE_BUILD_MODE == .Test)` is not visible to a test in other builds, so
helpers are ordinary procedures, which optimized builds drop when nothing calls
them. Because no code may name a test, checking it everywhere does not mean
emitting it everywhere. Only a test build includes a test's body.

A panic cannot be caught ([Recoverable panics](open-questions.md#recoverable-panics)),
so one process cannot report several failing tests. The executable runs one
test when it is given that test's name, and `lokec -test` starts it once per
test. This isolates the tests' globals as well as their panics, and keeps the
runner out of the language runtime. With no name, the executable runs every
test until the first failure, which is still useful under a debugger. Tests run
one after another, in declaration order, so their output is deterministic.
Running them in parallel is something the runner can add later without
changing the executable.

Only the root package's tests run. A package's test build is a statement about
that package. Running the tests of everything it imports, `core` included,
would repeat the same tests in every package's report.

## Changed syntax

### Statement termination

Semicolons terminate statements unless their outermost form ends in a block.
This keeps termination independent of line breaks without requiring a redundant
semicolon after a procedure body.

Calling a procedure literal immediately requires parentheses:
`VALUE :: (proc() -> int { return 7; })();`. Otherwise a following statement
beginning with `(` could be mistaken for a call on the preceding declaration.

### A carriage return only ends a line with a newline

Odin's lexer skips a carriage return as whitespace wherever it stands. Loke
accepts one only before a newline and rejects any other as `L0115`, inside
comments and literals too. Every line table in the toolchain (diagnostics,
the formatter, the language server) ends lines at `\n` alone, while the
[LSP text-document rules](https://github.com/microsoft/language-server-protocol/blob/gh-pages/_specifications/specification-3-14.md#text-documents)
also end one at a lone `\r`. A file with one therefore had two line
numberings: in `"abc\rdef"` an editor's line 1 was the compiler's line 0, and
a line comment before the `\r` hid everything after it. Accepting lone `\r`
as a line ending everywhere would fix that only at the cost of a third line
ending no current editor writes by default. Normalizing it on load would make
a raw string's value differ from its bytes.

### Doc comments start with `///`

Odin's documentation tools show the comments directly above a declaration. In
Loke's bundled packages about 40% of that text was for maintainers: spec
citations, how an operation is implemented, and work still to do. A marker lets
the author say once, where the comment is written, who it is for, so a note for
maintainers can stand beside the documentation without being shown. An
attribute such as `@(doc="…")` would need escaping and long strings, and a
prefix inside an ordinary comment, such as `// doc:`, would be dropped silently
by a typo. `///` is also Rust's and C#'s marker. A `///` that documents nothing
is a warning, so a doc comment cannot be lost by a blank line or by standing
above something that is not documented. See
[Using a package without reading its code](open-questions.md#using-a-package-without-reading-its-code-proposal-2026-10-21).

### `transmute` is a procedure in `core:unsafe`, not an operator

Bit reinterpretation uses `unsafe.transmute(T, value)`. Types are already call
arguments, so a separate operator would add a keyword and precedence rule.
The import also exposes a trust boundary: a bit pattern valid for the source
need not represent a valid destination value.

### Parenthesized control-flow headers

Parentheses separate a control-flow header from its body. A uniform boundary
avoids special parsing rules for composite literals in conditions.

### Slice literals state their capability

`[]T{...}` produces a read-only slice and `[]mut T{...}` a mutable one.
Inferring mutability from surrounding context would make the written type fail
to describe the value.

### No uniform call syntax

Free calls use lexical lookup and receiver calls use methods or contributed
built-in operations. An unrelated free procedure never acquires a method spelling
through an import. See [Standard free aliases](#standard-free-aliases).

### `foreach`

`foreach` marks traversal; `for` handles ordinary repetition. A bare
`for (key in counts)` is rejected because it resembles a mistyped traversal.
The explicit membership loop is `for ((key in counts))`.

Switch has no competing traversal or header-binding form, so
`switch (key in counts)` needs no extra parentheses. Payload bindings belong
in its cases.

### Keywords as member names, and five contextual keywords

Loke is meant for general programs, whose data models and C bindings bring
their own names: a JSON field `type` or `default`, a network type's
`interface`, a set's `union`, a parser's `operator`. A reserved word costs
most where it blocks such a name. A member is reached only through a value or
a type, after `.` or as a keyed-literal field. In those positions a keyword
means nothing else, so freeing them confuses no reader. The grammar already
did this for `type`; it now does it for every reserved word.

Of the words that begin a construct, `dynamic`, `hook`, `operator`, `via` and
`where` each have one fixed position, decided by the tokens around it, much
as `delegate` and `capture` are. Those five are contextual and otherwise
ordinary names. Two of them need a rule that takes a meaning away from a name:
- `[dynamic]` is always the dynamic array, so a length named `dynamic` is
  parenthesised.
- `hook(...)` begins a hook only when `proc` follows, since `hook(drop)` is
  also a call.

The rest stay reserved because both meanings fit the same position. That
covers:
- control flow;
- `map`, since `map[k]` could index a variable;
- `move`, since `move(x)` reads as a call;
- `in`, an operator;
- `default`, a case label;
- the words that begin a type in an expression.

A reserved word also never names a local, a parameter or a file-scope
declaration, so code always reads a keyword in statement and expression
position as the keyword.

Each contextual word adds a disambiguation rule, and every tool that colours
or formats Loke has to follow it. That cost is why the list stops at five.
Raw identifiers, Rust's `r#type`, would free every word but make the freed
names ugly at every use.

## Features kept close to Odin

### Standard output is binary

Writing `\n` produces that byte, without Windows text-mode translation to
`\r\n`. Formatting and direct stream writes therefore agree even when output
is redirected. The runtime configures process streams at startup; an object
build leaves stream configuration to its host.

### `defer`

Managed owners handle resource lifetimes, but not every cleanup is an owner's
destruction. `defer` can restore state, roll back a partial operation, or publish
completion on every exit without introducing a resource type for one statement.

The library uses it: `Once` publishes completion or poisoning, shared ownership
releases its allocation even if a payload drop panics, and process spawning
cleans up native handles. It follows the same panic-strategy limits as other
lexical cleanup.

### Foreign declarations

Foreign bindings keep external symbol names and ABI types, then expose ordinary
Loke wrappers where useful. Staying close to Odin's declaration model makes
bindings easier to port, while explicit foreign-string and nullable-pointer
types keep ownership and representation promises visible.

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

## Standard-library API choices

Public contracts live in [standard-library.md](standard-library.md). The package
boundaries and API shapes follow a few common choices:

- **Files and process state are separate.** `core:fs` owns files; `core:os` owns
  process state. There is one spelling for opening a file.
- **I/O errors own scalar data.** An operation enum and native code avoid
  allocating or borrowing diagnostic text. Public constructors let callers
  implement streams without exposing the error's fields.
- **Formatting avoids a builder dependency.**
  `builder.append(fmt.to_string(allocator, ...))` provides formatted append
  without making every `fmt` importer also depend on `core:strings`.
- **Directory iteration streams borrowed names.** Walkers avoid allocating a
  name at every step; callers retaining entries copy them. An explicit loop
  distinguishes failure from end of input.
- **Joining takes a slice.** A variadic would absorb trailing allocator
  arguments or prevent a preceding default allocator from being omitted.
- **Case conversion is ASCII-only.** Full Unicode mapping requires tables and
  a defined contract. The owning result already permits text length to change;
  locale rules must not depend silently on process state.
- **Float widths have separate names.** `sqrt` takes `f64` and `sqrt_f32` takes
  `f32`. Overloading both would make an unfixed literal ambiguous; converting
  through a wider result can round twice.
- **Random generators are explicit values.** Every `core:random` procedure
  takes a generator `inout`, as `core:io` takes a stream. A package-owned
  default would double the API with generator-free overloads and give the
  library hidden state. A program that wants a global declares
  `rng: thread_local random.Xoshiro256;`.
- **A generator is move-only.** Copying one copies its future: both copies
  draw the same values. The classic case is a generator handed to a thread and
  then used again by its spawner. `split` and `from_state(rng.state())` make the
  second stream explicit.
- **An unseeded generator seeds itself.** The alternatives were a zero value
  that acts as seed 0, which gives every `thread_local` generator the same
  stream, and no zero value at all, which would take the zero value away from
  every record that holds a generator. Reading entropy happens on a draw, never
  on import. The cost is one predictable branch per draw: an all-zero
  xoshiro state is otherwise unreachable.
- **xoshiro256++ is the generator.** It is fast, passes BigCrush and
  PractRand, needs only 64-bit operations, and has jumps for disjoint parallel
  blocks; Julia and Rust's `SmallRng` use it. MT19937 has 2.5 KB of state,
  fails linearity tests, and seeds poorly from small seeds. xorshift128+ has
  weak low bits. Linear congruential generators fail statistical tests outright.
- **PCG64 is numpy's DXSM variant.** The second generator exists for
  `advance`, which moves a stream any distance in 128 steps, and for matching
  another tool's output. numpy's `PCG64DXSM` mixes the state before stepping,
  with the 64-bit multiplier, and is the published reference users can
  check against; Go's `math/rand/v2` PCG uses a full 128-bit multiplier and
  mixes after stepping, so the two disagree. The older XSL-RR output is not
  offered: O'Neill replaced it with DXSM after it was shown to correlate
  across closely related streams.
- **Counting distributions follow numpy.** `unit` is numpy's `next_double`
  bit for bit, so porting `random_poisson` and `random_binomial` step for step
  gives algorithms with decades of use and a reference to compare against, and
  a fixed draw accounting to specify. BTPE is long, but inversion alone costs
  draws in proportion to the mean, and the beta-recursion alternative takes
  about `2 log2(trials)` gamma draws per value. One step departs: numpy's PTRS
  test computes the Poisson log mass as `-mean + k*log(mean) - log(k!)`, whose
  terms cancel catastrophically at large means, so `poisson` uses Loader's
  saddle-point form there and everywhere, for one algorithm at every mean.
  BTPE's final test has the same shape, but its squeeze band narrows faster
  than its error grows, and its measured spread is right up to 2^64 - 1
  trials, so it is kept as numpy has it.
- **`geometric` counts failures, not trials.** Its support then starts at 0,
  as `poisson` and `binomial` do, and as C++'s `geometric_distribution` and
  Rust's `rand_distr` count. numpy counts trials, which is this value plus one.
- **Counts are `u64`.** A count is never negative, so the type carries what a
  panic would otherwise check, and a mean or trial count above 2^63 still has a
  result type.
- **`gamma` below shape 1 uses Marsaglia and Tsang's boost.** The same paper's
  method for a shape of at least 1, with one extra `open_unit` power, keeps one
  algorithm for every shape; numpy instead uses a separate rejection sampler
  there.
- **`sample` rearranges in place.** Partial Fisher–Yates needs no allocation,
  works on any element type, and leaves the unchosen elements behind the
  sample. Floyd's algorithm, which picks indices from a range without
  materializing it, needs a set and waits for a caller.
- **`Weighted` is an alias table.** Vose's construction is linear and draws in
  constant time, against a cumulative table's logarithmic binary search. The
  construction order is specified, so a table's picks replay from a seed.
- **Seeding never reads the clock.** Processes started together share a clock
  reading and often a process-ID range. The documented idiom is to draw a seed
  with `secure_u64`, record it, and seed with `from_seed`.
- **OS entropy panics instead of returning an error.** The system generator does
  not fail on a supported system, as Go 1.24's `crypto/rand` also concludes.
  Continuing with predictable bytes would be worse than stopping. A `Status`
  would put an `or_return` on every seed for an error no caller can handle, and
  a new `io.Operation` would break exhaustive switches over it.
- **Draw mappings are specified.** A seeded program's output is behavior a
  reader can depend on, so how each procedure maps draws to values is part of
  its contract, not an implementation detail. The ziggurat tables are constants
  rather than computed at startup, so most normal and exponential values do not
  depend on the C library at all.
- **`Time` is an `i64` of nanoseconds.** It is what `fs.Metadata` already
  held and what Odin uses: arithmetic is one integer operation, and 1677 to
  2262 covers every clock reading and every file time. Seconds and
  nanoseconds in 16 bytes, as Go and jiff hold them, would make
  `Offset_Date_Time.to_time` total, at twice the size and with a carry in
  every operation. Dates outside the range stay in the calendar types.
- **Dates count days.** A `Date` holds days since 1970 rather than a year,
  month, and day, so its zero value is a date, 1970-01-01, rather than month
  0, and comparing and stepping are integer operations. The fields come back
  through Hinnant's `civil_from_days`, which is exact over the whole range
  without tables.
- **Years are 0000 to 9999.** They are the years ISO 8601 writes in four
  digits without prior agreement and the ones RFC 3339 allows, and widening
  the range later breaks nothing.
- **A duration prints in a short form.** ISO 8601 spells 153 milliseconds
  `PT0.153S`, which reads poorly in a log line. The short form is close to
  Go's, but drops zero components, `1h30m` where Go prints `1h30m0s`, since
  every number carries its unit. ISO 8601 remains a style away and both forms
  parse.
- **There is no `DAY` and no `Duration / Duration`.** With daylight saving a
  calendar day is not always 24 hours, so steps of days belong to `Date`.
  `Duration / Duration` beside `Duration / i64` would make `d / 2` ambiguous,
  because the constant converts to either; the count of a unit is a method.
- **A leap second reads as second 59.** Rejecting `23:59:60` would fail
  valid RFC 3339 timestamps from a log written during one, and reading it as
  the next day's 00:00:00 changes the date, so a `Date` or `Time_Of_Day` read
  from the text would disagree with it. Second 59 keeps the date, hour, and
  minute as written, loses only what Unix time cannot hold anyway, and is
  what the Rust library jiff does. Values inside a leap second keep their
  order among themselves but can sort before the end of the second 59 they
  follow. Leap seconds are rare, the last at the end of 2016, and are to stop
  by 2035. The check is on the UTC minute, not the local one, because RFC 3339
  shifts the leap second by the offset: it is `05:29:60` at `+05:30`. Text
  without an offset could belong to any offset, so no minute can be ruled out.
- **A fixed precision truncates.** Rounding could print a second, or a day,
  that has not arrived yet. A fixed width also makes timestamps sort as text;
  the shortest form does not, because `.` sorts before `Z`.
- **`Offset_Date_Time` is not ordered.** Its fields would order 14:00+02:00
  after 13:00Z, although it is the earlier instant. Ordering by instant
  instead would make two unequal values neither less nor greater. `to_time()`
  makes the comparison explicit.
- **There are no named time zones.** Their data changes several times a year,
  and a stale copy gives wrong local times with no error. When a caller needs
  them, the data is the system's own, kept current by its updates: ICU on
  Windows and the TZif files elsewhere. The compiler never ships tzdata.
- **A duration prints `µs`.** The `µ` is U+00B5, two bytes of UTF-8, as Go
  prints it. A console whose code page is not UTF-8 shows it wrongly, but
  that console misprints every non-ASCII string, and the parser accepts `us`
  and the Greek `μ` alike, so an ASCII-only writer loses nothing.

## Compiler architecture audit (2026-09-28)

The audit of `b2cc712` and its follow-up favored enforcing existing phase
boundaries over introducing another IR or splitting the compiler into packages.
The current contracts are in [compiler-architecture.md](compiler-architecture.md).
Two labels remain useful to the regression cases citing this review:

- **A1:** compile-time construction obeys an element budget; large runtime
  literals do not require eager constant construction.
- **A5:** speculative checks use `committing(c)`, and assertions detect changes
  to registries that must remain unchanged during a probe.

The other lasting choices are shared lifecycle/provenance reset identities,
one walk building their related graphs, and exhaustive specialized query walkers
instead of a universal child traversal. Each avoids duplicating facts or visiting
positions that a particular analysis should ignore. Implementation details belong
with the [semantic architecture](compiler-architecture.md#semantic-architecture);
historical fix lists and test counts are available in Git history.

## Provenance replay and precise publication

Provenance analysis reads a
[normalized body](compiler-architecture.md#normalized-provenance-input) rather
than interpreting the checked AST in each fact visitor. Before that, every
spelling of a transfer needed its own handling in each visitor: borrowed switch
payloads in anonymous storage, `unbox`, checked `as`, and owner-to-view
conversions each lost facts that another spelling kept, until it was fixed
separately. Describing storage, places, and transfers once makes those rules
shared. A durable general-purpose MIR would unify more consumers, but LLVM
lowering still reads the checked AST, and no other consumer needs one yet.

The normalized operations are kept apart from the growing target and
allocator-region facts. Fact-changing operations are replayed until the facts
settle. Borrowed payload publication can resolve more destinations on a later
fact round; freezing its first loan-event expansion would preserve an
incomplete set or the wrong replacement precision.

The analysis keeps the construction graph instead of walking the body again. Its
loans, roots, slots, and event sequence do not depend on the carried facts, so
only what does is recorded and materialized again from the settled facts. The
materialization replays the fact operations once more, interleaved with the
recorded events, so a region escape through a borrowed payload sees the
binding's aliases as they were at its site. Rebuilding the events from the
recorded inputs alone, rather than splicing them into the construction graph,
would mean recording every loan and slot the walk creates, which no fact
changes.

The frozen input is shared within one concrete body build. Whole-program summary
visits still rebuild the body, so retaining normalized bodies across those visits
remains a [measured later decision](open-questions.md#normalized-input-for-provenance-analysis).
The [profiling records](bench/baselines/README.md#provenance-normalization)
distinguish normalization, fact replay, and event materialization cost.

# Differences from Odin and design motivations

This non-normative document explains Loke's design decisions and tradeoffs,
for the language, its standard library, and the compiler's internals.
[design.md](design.md) defines the language, [grammar.md](grammar.md) its syntax,
and [open-questions.md](open-questions.md) the unresolved choices. API contracts
belong in [standard-library.md](standard-library.md); release history is in
[CHANGELOG.md](CHANGELOG.md).

| Topic | Start here |
| --- | --- |
| Ownership and cleanup | [Borrow checking](#local-borrow-checking), [assignment](#value-semantic-assignment), [panics](#panics-run-lexical-cleanup) |
| Types and errors | [Zeros](#zeros-that-are-values), [records](#structs-declare-parentheses-describe), [fallibility](#typed-fallibility) |
| Procedures and callbacks | [Methods](#methods-interfaces-and-operator-overloading), [captures](#capture-literals), [callable views](#borrowed-callable-views) |
| Concurrency | [Threads](#threads-the-language-can-start), [`parallel` blocks](#tasks-that-borrow-joined-by-their-block), [pools](#pools-that-help-at-joins), [channels](#channels-end-by-ownership) |
| Compilation and configuration | [Compile time](#one-language-at-compile-time), [providers](#build-selected-services-and-explicit-runtime-state) |
| Simpler language surface | [Removed or narrowed features](#removed-or-narrowed-features) |
| Values and operations | [Overflow](#integer-overflow-panics), [slicing](#mutable-slicing-is-written-mut-alohi), [text](#slicing-text-keeps-its-panic) |
| Syntax and layout | [Syntax choices](#changed-syntax), [formatter](#formatting) |
| Library and compiler decisions | [Library APIs](#standard-library-api-choices) (files, random numbers, time, JSON), [compiler design](#compiler-design-choices) |

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

### Splitting a mutable slice is compiler-known

Two runtime slice ranges conservatively overlap, so after
`left := &mut xs[:mid]` the source is suspended and `&mut xs[mid:]` is
rejected. Most algorithms never need both halves at once: a recursive merge
sort ends each half's reborrow before the next, and its merge reads both
halves through read-only views. Handing each half to its own task does need
both.

[Splitting a mutable slice](design.md#splitting-a-mutable-slice) is built into
the compiler, as `swap` is, because a library cannot write it. Written with
`unsafe.raw_data`, its halves carry no provenance, so appending to the owner or
writing through `xs` while they are live is accepted: a use after reallocation
the checker cannot see. Written with checked slicing, its body needs the two
simultaneous reborrows it is meant to provide. The compiler's form is one bounds
check, two slice headers, and a result whose two fields are one mutable
reborrow of `xs`, so no disjointness relation needs tracking: that reborrow
keeps `xs` suspended until both halves are finished, and writes through the
halves do not conflict, since suspension constrains uses of the source and not
of its reborrows. [Chunks of a mutable slice](design.md#chunks-of-a-mutable-slice)
extends this to the data-parallel case.

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
its value past its end. The value itself is published through an unchecked
address, as a channel's queue is, so it takes a channel item's contract:
process-lifetime borrows, and the checks for crossing threads, since any
thread may read what one thread made. That is stricter than a local `Lazy`
needs, but a `Lazy` that one thread uses has little reason to exist, and a
contract tied to the receiver's own lifetime would need a write through a
read-only receiver that the borrow rules can follow.

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

[Compile-time evaluation](design.md#compile-time-procedure-evaluation) runs a
capture literal as the record it abbreviates, so a constant can be computed
through a callback API. The record stays out of the constant itself. A literal
is declared with `:=` because it is a runtime value; admitting one through a
generic identity, while `::` rejects it written directly, would make the rule
depend on spelling. A named record with a `call` method is a constant like any
other record.

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
`(f() or_return).len()`. A member call on a propagated value is short enough
to bind first or parenthesise, and the diagnostic suggests the parentheses.

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
with it (Zig's `?*T`, Swift, Kotlin), while in Loke `nil` is the null unchecked
address, not a failure. A checked reference cannot hold it, so in an
`Option(^T)` `return nil;` is an error either way, but in an `Option(rawptr)`
wrapping would silently turn it from absence into `.some(nil)`.

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
is, so it is widened without a copy. The conversion does not reach through
containers, since a `[dynamic]` of the wider union has a different element
size; that rebuilds the container, which is a loop the program writes.

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

### Arguments typed after inference

An implicit selector or a typeless literal has no type of its own; it takes its
parameter's. A generic parameter written `Option(T)` has none until `T` is
inferred, so before [Arguments typed after
inference](design.md#arguments-typed-after-inference) such an argument could
fill only a parameter whose type named no `$` parameter, and
`value_or(x, .some(y))` against `proc(value: $T, fallback: Option(T))` was
rejected though `x` alone settles `T`. `linalg.quaternion_between` became a
procedure group with a plain `Vector3(T)` parameter for that reason, where one
procedure with an `Option(Vector3(T))` default would say what it means.

Letting the argument wait costs nothing in meaning, because it contributes
nothing to inference: it has no type to match a pattern against, so typing it
before or after the other arguments cannot change what they bind, and the
result is the same whichever argument is written first. Only typing waits;
arguments still run in written order, so the rule never shows at run time.

The case where the waiting argument is the only one that could bind a `$` name
stays an error. Binding `U` from `.none` against `Option($U)` would have to
guess `U`, and from `.some(5)` it would have to type `5` with no destination
and then read `U` back out of the result: a second, inside-out inference for
one argument shape. Requiring the type to be written, as
`Option(int).none`, keeps inference reading only arguments that have types.

In a group the waiting argument does not take part in choosing the member, as
a destination type does not: selection reads the arguments that have types,
and the chosen member's parameter then checks the one that waited. The
alternative, typing it speculatively against each member and dropping those it
does not fit, would let an implicit selector choose between overloads, which
is exactly what a destination type is denied, and would check one expression
once per member. The cost is that `show(1, .none)` picks the non-parametric
`show_color` from `1` and then rejects `.none`, though a generic member would
have taken it; the error says that the other arguments chose the member.

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

Each copy is a case of the same switch, so the copies are basic blocks of one
procedure rather than procedures of their own, and the compiler does nothing to
merge them: that is left to clang, which already does it. Measured on
2026-10-28 with clang 22, at `-opt=size` identical copies are sunk into one
block before code generation, and at `-opt=speed` and `-opt=aggressive` the
machine-level tail merging folds them, so a body that ignores the payload costs
one copy and a body with a `when` costs one copy per distinct branch;
`-opt=none` and `-opt=minimal` keep every copy, as they keep any duplicate.
LLVM's function-merging pass merges whole procedures and measured no effect, so
it is not enabled.

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

### A warning for private names in public declarations

A public procedure that returns a private type compiles, and an importer can
call it, but cannot declare a variable of the result's type, store it in a
field, or pass it through a procedure of its own. A public `where` clause
written in private terms, as `core:time`'s `styled` had with
`is_styled(T)`, states a bound the importer can neither read nor name. Both
are almost always accidents: following the references the interface files
make found `fmt.Padded`'s public `fill: Fill`, since made private, and that
`where` clause, since written out. Rust warns on a private type in a public signature; Go
allows an unexported result type, which its documentation then cannot
describe.

[Private names in public declarations](design.md#private-names-in-public-declarations)
makes it a warning, `L0740`, rather than an error, since the code is sound
and occasionally deliberate: a constructor may hand out a value of a type
whose name is withheld so that only its methods are API. An error would also
have no way out short of exporting the name. The interface file still shows
such a declaration, marked private, so an importer can read what it calls.

The warning reads names, not types: a public `Alias :: Inner` is reported
for its private target, but it gives importers a name, so a signature that
writes `Alias` is not. Values are left out because an
importer can write them without the name: a private constant as a default, an
array length, or an attribute's value. A procedure group's members are left
out by name, because a group exports one name over several signatures, as
`thread.spawn` and `runtime.shared` do, but the signatures it exports are
read. `package main` is left out entirely: nothing imports it, and its fields
are public by default, so a warning there would fire on every program that
stores a private enum in a struct.

A generic `impl`'s constant with no written type is the one place the warning
reads a type rather than a name, and its template has no type to read. The
syntax cannot stand in for one: `Corner{}` writes its type, but
`size_of(Corner)` names a type and is an `int`. So the value is checked as a
`$` default is ([Default values](design.md#default-values)): one that names
none of the block's `$` names means the same in every instance and is read at
the declaration, which is where a library's author builds it, usually with no
instance in sight. One that names a `$` name is read per instance, and a type
an instance binds is passed over, since a `$` name names no type. This misses
a private type the value also writes when every instance binds that same type,
as `Twin(T, Corner){}` in a package that only uses `Holder(Corner)`; telling
the two apart would need the value checked against a type no instance binds.
A block no instance uses gives such a value no type, as its members get no
other diagnostic, and is not read; one instance anywhere in the build is
enough, and the warning names the declaration, once, however many instances
show it.

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
serialization, bindings, and expanded switch cases. Reflecting procedures,
parameters, requirements, and attributes would need more descriptors and lookup
rules without a demonstrated consumer.
Additional reflection can be introduced when an actual tool needs it.

### Associated interface members use expressions

`T.NAME -> Type;` is an expression requirement. Associated types use the same
form, `T.Element -> type;`, whose result is necessarily compile-time known.
A separate associated-constant declaration grammar adds little to that model.

### A bound grants what met it

A bare bound already granted its declaration the slots that satisfied it, so a
package could meet an interface for a built-in type with private extensions
and every importer's generic code could call them. An associated constant met
the same way was not granted, and was not even found by the requirement
outside the interface's package, since an expression requirement is checked
with the visibility of the package applying it. `core:math/linalg` meets
`Scalar` for `f32`, `f64`, and `math.Complex` with a private `Real :: f64`, a
private extension because a public one would be exported as `linalg.Real`, the
interface's own name. So `Scalar(f64)` was false in any package that did not
declare its own `Real` for `f64`, and `core:math/dense` declared one for each
of the three types, as every package with generic code over `Scalar` would
have had to.
An associated constant is now found as a slot is when the applying package
sees none, and a bound grants it as it grants a slot
([Interface bodies](design.md#interface-bodies)). The requirement already
makes the member a compile-time constant, usually a type, so the grant hides
nothing at run time; it makes `T.Real` mean in every package what it meant
where the requirement was checked.

`Scalar` also composes `Real(T.Real)`, and an application standing alone in an
interface body contributes its slots. A body bounded by `Scalar(T)` could call
`Real`'s slots on a `T.Real` only when `T.Real` was `T` itself, because the
grant was matched against the bound's own subject. Matching each slot against
the subject of the application that writes it reads "contributing its slots" as
the composition's own wording says: the slots on the type they were checked on.
`core:math/dense` had reached them through helpers bounded by `linalg.Real(R)`,
which a `T.Real` argument satisfies; those helpers are gone.

The grant stays narrow: the members that met a requirement, on the types they
were required of, in the declaration the bound constrains, and only where
ordinary lookup finds nothing. A bound on a record still does not carry into
the record's methods ([Slots through a record's bound](open-questions.md#slots-through-a-records-bound)),
so `core:math/dense`'s methods that name `T.Real` restate `linalg.Scalar(T)`.
Operators and other expression requirements keep the applying package's
visibility ([Visibility in slot and expression requirements](open-questions.md#visibility-in-slot-and-expression-requirements)).

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

An invalid representation is undefined behavior rather than a bounded outcome
because a bound would be paid for everywhere and used nowhere. A `bool` is
branched on, an enum switch is closed, and a `^T` is dereferenced without a
test precisely because every value is assumed to be one; promising that an
out-of-range enum runs no arm would need a range check at each switch, and a
stable "some value" for unwritten `---` storage would need every such read
pinned, in checked code that never produces either. The obligation sits where
the bits enter, the `transmute`, the foreign declaration, or the `---`
declaration, which is also the only place a review can see it, and the same
place the import gate already marks. `rune` is deliberately on the other side
of the line: it is a 32-bit integer type, `rune(x)` and rune arithmetic check
only that width, so a surrogate or an out-of-range code point is a value that
text operations reject or replace, not a representation the compiler may
assume away.

`typeid` is on the same side. Its zero must be a value for `typeid{}` to be a
safe zero, and its one consumer, the `type_info_of` lookup, already checks the
range: the reflection table is indexed by an id that comes from data, not from
a branch the compiler controls, so the check costs one compare and a select
and spares every reflection caller an obligation. A forged id therefore reads
as the `Invalid` entry rather than past the table, compares unequal to every
real id, and prints as its number. An `any_view` is different: it promises a
value of the type its id names, as a slice header promises its storage, so
formatting dispatches through it unchecked, and one whose id names no type is
an invalid `any_view` though the id alone is a valid `typeid`.

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
with the optimization level and the target. C and Go let the implementation
fuse; Rust and Java never do and offer the fused operation by name.

`math.fma(a, b, c)` is that name. It rounds once on every target, so code that
relies on the extra precision, such as an error-free product or a polynomial in
Horner form, says so. It is a procedure rather than an operator because it is
rare outside such kernels and takes three operands. See
[Floating-point operators](design.md#floating-point-operators).

It is computed in integer arithmetic, with the exact product in a `u128`,
instead of calling the C library. Microsoft documents its `fma` as allowed to
round incorrectly, and older versions did on processors without the
instruction; the CRT is linked statically from whichever SDK a build finds.
The baseline x86-64 target has no FMA instruction, so the software path serves
it; it is slower than the instruction, and correct. At `-cpu=x86-64-v3`,
`math.fma` is the instruction, with the same results.

### A dispatched procedure is copied with its callees

A program for distribution is built for `x86-64`, and most processors running
it have `x86-64-v3`, on which `core:math/repro`'s `f64` functions take a fifth
less time with the FMA instruction. [`@(cpu_dispatch)`](design.md#cpu_dispatchstring)
lets one build have both: the marked procedure is emitted once for the build's
level and once for the higher one, and a cached check picks one per call.

The copy takes its callees with it, made the same way, rather than calling
them at the build's level. An exact product is two instructions inside a
kernel's inner loop, so it pays only when the whole kernel is compiled with
FMA and the optimizer can inline it there; and LLVM never inlines a function
into one whose features lack the callee's, so code for the higher level stays
behind the check without any further rule. The alternatives each had a cost
this avoids. Writing the kernels generic over a `fused` constant would thread
a parameter through most of `core:math/repro`'s procedures, and would still
need a way to give one instance other target features. A per-procedure
target attribute, the shape GCC and Rust have, leaves the user to mark every
callee and to keep the marked code from being reached without a check. A
whole second program, a fat binary, multiplies the code and the link for one
package's benefit.

Only a direct call reaches a copy. A call through a procedure value or `dyn`
value reaches the procedure as written, which is correct at any level and
only slower; following values would make a copy of every procedure of a type.

`math.fma_is_instruction()` stopped being a constant for this, since a copy
must answer differently from the procedure it copies, which a `when` decided
once could not. In an `if` the optimizer still keeps only the branch taken. In
code without the instruction `fma_instruction` traps rather than becoming
LLVM's call to the C library's `fma`, which is not correctly rounded in every
version a toolchain may link; the `if` keeps any call from reaching it.

The `_f32` functions are not marked: their first approximation in one `f64`
decides almost every argument with no exact product, and their copies measured
no faster. `sqrt` is one instruction at every level.

### The floating-point environment is fixed

Loke code always runs with rounding to nearest, subnormals kept, and
exceptions non-stop ([Floating-point operators](design.md#floating-point-operators)),
and offers no way to change that. Every result the language pins depends on
it: constant folding, compile-time evaluation, and the optimizer all assume
the default environment, as LLVM does for code without `strictfp`. Under
another rounding mode, a sum of two `f64` constants folded at compile time and
the same sum computed at run time would differ, and with an exception unmasked an operation the optimizer
hoisted out of a branch could trap on a path the source never took. A
directed-rounding or interval facility belongs in a library whose operations
name their rounding, not in a mode that changes the meaning of `+`.

Foreign code can still change the state, so the contract is a rule for it:
restore before Loke runs again. Windows starts every process and thread in
this environment, which `tests/run/float_environment.loke` checks on the main
thread and on a started one.

A C host is the exception the rule cannot reasonably cover: a library is
called by code it did not write, which may run with flush-to-zero for its own
graphics or an exception unmasked for its own debugging. So each procedure
Loke defines with a foreign calling convention guards its own entry, rather
than leaving a scoped enter-and-leave call to every host. Such a call was
the first proposal; a guard cannot be forgotten, and it covers what the call would
miss: a callback reached from a C library that changed the state, and a
thread the host created. When the caller's control bits already match, which
is every call from Loke and from a well-behaved host, the guard costs one
read of MXCSR and a branch; it writes MXCSR only when they differ. The body is
a function no caller may inline, because LLVM assumes the default
environment everywhere in a function without `strictfp` and may move
arithmetic above the switch, where it would run in the caller's environment,
and with an exception unmasked could trap. The flags the call raised are left
raised, as they would be had the host computed the same thing, but nothing
promises them.

The other direction, a call from Loke into foreign code, keeps the rule, since
checking every call would cost every program. A `-debug` build checks it:
after each call to a foreign procedure it reads MXCSR and panics, naming the
procedure, when the control bits changed. That turns a silent wrong result
far from its cause into a report at the call that caused it.

### Which NaN an operation gives is unspecified

[Floating-point operators](design.md#floating-point-operators) pins every
result's bits but a NaN's. IEEE 754 does not say which NaN `a + b` gives when
both operands are NaNs, and LLVM, without which Loke has no optimizer, treats
`+` and `*` as commutative and the result's NaN sign and payload as free.
x86 keeps the first operand's NaN, so a swap the register allocator makes
changes them: at `-opt=speed`, `core:math/linalg`'s `Simd` `m * v` and the
scalar formula it replaced computed the same sums but disagreed in the sign of
a NaN where a positive `math.F32_NAN` met the negative NaN that `inf * 0`
makes, and moving any statement in the test moved the swap. Pinning the NaN
would need a canonicalizing step after every operation that may make one, a
cost on every floating-point expression, for bits no operation but a bit test
reads. A library that wants one NaN, as
[`core:math/repro`](standard-library.md#coremathrepro) does, canonicalizes its
own results.

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

Immutable strings can share storage, so reference counting is atomic. The cost is measured under [Thread-affine strings](open-questions.md#thread-affine-strings). The
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
[LSP text-document rules](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocuments)
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

### Long doc comments are `/** */` blocks

A paragraph written as `///` lines repeats its marker on every line, which is
noise to read and stops an editor from reflowing it as prose. A block suits a
package overview or a procedure's contract; a line suits a one-line summary, so
Loke has both. `/**` is the marker Java, Kotlin, JavaScript, Swift, and Rust
use, and it was already the start of a block comment, so the lexer is
unchanged and no code changes meaning but the comments written `/**`, of which
there were none. A new opener such as `/#` would have been a third comment
syntax to learn. The text drops the indentation its lines share instead of
following Javadoc's ` * ` on every line, which would bring the repeated marker
back. `/***` and `/**/` stay ordinary, as `////` does, so a banner of stars is
never documentation.

The bundled packages write a doc comment of one line with `///` and a longer
one as a block, with its text indented one tab past `/**` and the `*/` on a line
of its own. The [interface file](compiler-guide.md#interface-files) follows the
same rule from the text alone, so it reads like the source. `-fmt` changes only
whitespace, so it does not choose between the forms.

### `transmute` is a procedure in `core:unsafe`, not an operator

Bit reinterpretation uses `unsafe.transmute(T, value)`. Types are already call
arguments, so a separate operator would add a keyword and precedence rule.
The import also exposes a trust boundary: a bit pattern valid for the source
need not represent a valid destination value.

### A `typeid_of` constant has no compile-time number

[`type` and `typeid`](design.md#type-and-typeid) leaves a `typeid_of(T)`
constant without a number during compilation, so bit casting it, or comparing
it with a forged id, waits for the program to run. Emission numbers the
program's types densely, by each one's place in the sorted set of every type
the program requests, so that `type_info_of` and formatting index their
tables with one range check
([Unchecked operations need the import](#unchecked-operations-need-the-import)).
One type's number therefore depends on which others are requested, and that
set depends on constants: a `when` on such a number, or an instance whose
argument is one, could add a type that sorts earlier and move the number it
was computed from. Numbering in order of request would let checking order,
which an incremental session does not keep, change an observable value.

Two other routes would fold the number. Numbering a type by a hash of its
identity makes its number known as soon as the type is, but turns each table
lookup into a search, needs a compile-time error for two types that hash
alike, and makes the value depend on package keys and, for a type declared in
a procedure, its source position. Leaving the number to emission while the
expression stays a constant would give a constant with no value where one is
needed, as an array length, a `case`, or a generic argument. Comparing two
`typeid_of` constants needs no number, only the types, so it folds.

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

### Keywords as member names, and contextual keywords

Loke is meant for general programs, whose data models and C bindings bring
their own names: a JSON field `type` or `default`, a network type's
`interface`, a set's `union`, a parser's `operator`. A reserved word costs
most where it blocks such a name. A member is reached only through a value or
a type, after `.` or as a keyed-literal field. In those positions a keyword
means nothing else, so freeing them confuses no reader. The grammar already
did this for `type`; it now does it for every reserved word.

Of the words that begin a construct, `dynamic`, `hook`, `operator`, `via` and
`where` each have one fixed position, decided by the tokens around it, much
as `delegate` and `capture` are. Those five became contextual and are
otherwise ordinary names. Two of them need a rule that takes a meaning away
from a name:
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

A reserved word also never names a local, a parameter, a generic parameter, or
a file-scope declaration, so code always reads a keyword in statement and
expression position as the keyword.

Each contextual word adds a disambiguation rule, and every tool that colours
or formats Loke has to follow it. That cost is why a word is contextual only
when the tokens around it alone decide its meaning; `parallel` and `spawn`,
added later, met the same test. The [keyword table](grammar.md#keywords) lists
every contextual word and its position. Raw identifiers, Rust's `r#type`,
would free every word but make the freed names ugly at every use.

Odin's `#directive` tokens, `#load` or `#partial`, are a second lexical form
that no declaration can shadow. Loke has none: `size_of`, `static_assert`, and
every other built-in procedure is a predeclared identifier, shadowed like any
other, and element counts are receiver members. One lexical form means one
lookup rule, and a shadowed built-in reads as what it is.

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

### Cold procedures stay out of line

[`@(cold)`](design.md#cold) has Odin's spelling and placement, local
procedures included, which Odin's runtime uses for its assertion failure path.
Odin documents its attribute as a hint that the procedure is rarely called;
Loke's also promises that the procedure is never inlined, because that is what
the gain depends on. LLVM's `cold` alone lowers the inlining threshold, but
the bonus for an internal function's last call can still bring one in whole,
and `core:math/repro`'s fixed-point slow paths are such functions: inlined, each
made every call of its public function pay its frame, 968 bytes for `exp`, and
the saves and restores of the callee-saved registers it uses. Marked, `hypot`
went from 17.9 to 13.4 ns a call and `pow` from 58.4 to 55.2, with every result
unchanged, measured with [bench/math_compare](bench/math_compare/README.md).
`core:math/geometry`'s predicates had the same shape: LLVM inlined each exact
path into its filter, its one caller, and the `f64` `orient2d` filter then
cost 1265 against the inliner's threshold of 225, so no caller inlined it.
With the exact paths marked, on `bench/geometry.loke` at `-opt=speed`,
`orient2d` went from 6.9 to 2.7 ns, `orient3d` from 10.5 to 5.9, `incircle`
from 7.2 to 6.3, and `insphere` from 17.9 to 16.7; each filter was 6 to 62 %
faster at both CPU levels and at `-opt=aggressive` and `-opt=size`, while the
exact paths themselves cost a few percent more. A smaller callee can push its
caller over the threshold instead: the triangle cast's `edge_sign`, with
`orient2d`'s filter inlined, stopped being inlined into the cast and made the
`f64` cast 42 % slower, so its zero case is a cold procedure of its own. The
casts then run as before, but for the `f32` cast at `-opt=aggressive`, 4 %
slower at `x86-64` and 12 % at `x86-64-v3`, whose code inside the benchmark
loop is the same; the box casts, which call no predicate, moved by up to a
quarter between the same two builds.

The attribute marks a procedure rather than a branch. A branch-likelihood hint
would order a caller's blocks but leave the rare code's frame in the caller,
which is the larger cost here, and the grammar's statement attributes stay
undefined until a use needs one. A dispatched procedure's dispatch is cold
with it, so a call to it is as unlikely through the dispatch as without one.

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
of writing. [tests/corpus_test.odin](tests/corpus_test.odin) keeps `core/` and
`base/` formatted and formats every program corpus to a layout that formats to
itself.

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
- **Directory order is the filesystem's, and the walk is live.** Sorting in
  the reader would buffer every name and pay the copy the streaming design
  avoids, and a snapshot would be stale by the time a caller acted on it.
  Windows promises neither an order nor isolation from concurrent changes:
  NTFS usually enumerates by name and FAT in on-disk order, and a contract
  that promised more would be a per-filesystem implementation inside `fs`.
  The contract states the weak native behavior, and a caller that needs
  stability collects and sorts, which pays only when wanted.
- **A reparse point reads by its directory bit.** `Kind.Other` would be the
  explicit answer for a link before links are supported, but a Windows
  profile holds compatibility junctions (`Application Data`, `My Documents`),
  and `create_directories` settles a failed creation by asking whether a
  directory is there; `Other` would make it fail through every one. Every
  other operation already goes through the link, so reporting the link's own
  directory bit is consistent with them, costs nothing, and leaves `Other`
  free for link support to give a meaning to.
- **Positional I/O leaves the position unspecified.** On a handle not
  opened for overlapped I/O, Windows moves the file pointer to just past the
  bytes a positional `ReadFile` or `WriteFile` moved, while POSIX `pread` and
  `pwrite` leave it alone. Promising either would cost the other platform an
  extra seek on every call, and a caller mixing positional and stream I/O
  already has `seek` to say where the stream goes next. Opening every Windows
  handle for overlapped I/O would leave the pointer alone, but such a handle
  keeps no file pointer at all, so `read` and `write` would have to track the
  position themselves.
- **File locks are advisory.** A Windows byte-range lock is mandatory: the
  bytes it covers refuse reads and writes through other handles, the locking
  program's own other handles included. A POSIX `flock` lock is advisory and covers the whole
  file. A mandatory whole-file lock would make every other handle fail, even
  `fs.read_bytes` in the program holding it, and could not be had on POSIX at
  all. `core:fs` therefore locks the one byte at offset `2^63 - 1`, which no
  file holds and no `fs` call can reach, so the Windows lock is seen only by
  other locks, as `flock`'s is. SQLite keeps its lock bytes apart from the
  bytes it reads and writes for the same reason. Each handle holds one lock and a second is refused, because
  the platforms disagree about the second: Windows stacks it and needs two
  unlocks, and `flock` converts the first without promising atomicity.
- **A failed release is a build-time fault.** Nothing a program does makes
  `UnlockFileEx` fail on a handle that holds its lock, yet what a failed
  `unlock` leaves behind is a promise: the lock stays held and a retry
  releases it. `core:fs` therefore reads one
  [`build_config`](design.md#build_configidentifier-default),
  `CORE_FS_FAIL_FIRST_UNLOCK`, which makes the first native release fail
  without releasing; `tests/run/lib_fs_unlock_failure.loke` is built with it.
  A public hook would put a test's needs into every caller's API, and
  interposing on the system call would depend on how the program is linked.
  A constant that defaults to false compiles to nothing in every other build.
- **Paths keep Windows' own normalization.** `core:fs` hands a path to
  Windows unchanged, so it names what it names to a shell or any other
  Windows program. Following each link before a later `..`, as POSIX does, would mean
  resolving the path one element at a time, a system call per element, and
  would make `fs` disagree with the native tools about which file a path
  names. A caller that wants no normalization already has the
  extended-length `\\?\` form, which Windows passes on as written.
  `create_directories`, the one operation that walks the prefixes of its
  path, takes them from what `GetFullPathNameW` returns rather than from a
  lexical cleaner of its own, so they are the elements Windows looks up by
  construction.
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
  rather than computed at startup, so most normal and exponential values call
  no `exp` or `log` at all.
- **Distributions use `core:math/repro`.** A seed that replays only on the
  machine that recorded it is not much of a contract: a replay, a lockstep
  peer, or content generated from a shared seed needs the same values
  everywhere, and a count that differs shifts every later draw. Correctly
  rounded functions give that, and let a distribution run at compile time.
  Numpy, C++'s `<random>`, and Rust's `rand_distr` call the platform's
  library instead and are faster for it, by up to 16 times for `beta` by
  Jöhnk's method, though not at all for `normal` and `exponential`. A second,
  fast set beside the reproducible one would list every distribution twice,
  and the slow paths are better won back in `core:math/repro` itself, for
  every caller. Switching in place changed few values: of 2 million seeded
  draws of each distribution, only `log_normal` and `gamma` below shape 1
  changed any bits, and two of the 1,028 ziggurat entries had been the
  UCRT's and an ulp off. Measured on 2026-10-29 at `-opt=speed` against the
  UCRT's functions, `normal` and `exponential` stayed at about 7 and 4 ns,
  `gamma` of shape 0.5 went from 40 to 112 ns, `poisson` at a mean of 4 from
  24 to 53, `geometric` from 13 to 69, and `beta` by Jöhnk's method from 13
  to 205.
- **Reproducible math is a package, not a switch.** `core:math/repro` and
  `core:math` coexist, so a game's simulation can be reproducible and its
  renderer use platform math in one executable, and a library states which it
  depends on in its imports. A global switch that silently redirected every
  dependency's math would let a build flag change a library's results, and
  the optimization level and CPU level decide effort and instructions, never
  a contract. `core:math` keeps the C library until a release decides
  otherwise (see [Future plans](future-plans.md#standard-library-maturity)).
- **Reproducible means correctly rounded.** A fixed approximation, fdlibm's
  or musl's, would be deterministic too, but it freezes one algorithm's bits,
  so every bug fix is a breaking change, and it matches no other
  implementation. A correctly rounded result is defined by the arithmetic
  alone, so it is the same on every machine and at compile time, and the most
  accurate the width holds; determinism and accuracy are separate properties,
  and correct rounding gives both for ordinary results, which leaves only the
  special cases and NaNs to specify. The functions are written in Loke rather
  than bound from C, so compile-time evaluation runs the same code, and a
  missing function is missing rather than a fallback to `libm`. Each has a
  double-`f64` fast path within about 2^-67 relative, deciding at twice its
  bound, and a slow path in 320-bit fixed point for the rest; most `_f32`
  functions first try a single `f64`. `sqrt` is the instruction, which IEEE
  754 requires to be correctly rounded: a software root agreed with it and
  took 42 ns to its 1.5.
- **The composite magnitudes are `core:math/repro`'s.** The only callers of
  a nondeterministic function outside `core:math`'s own procedures were the
  magnitudes of `Complex` and `Quaternion`. `core:math` cannot call
  `core:math/repro`, which imports it, and `repro.hypot` took 30 ns to the
  UCRT's 4.4, so `abs` keeps the C library and `core:math/repro` adds
  `complex_abs` and `quaternion_abs`, the second rounded once where `q.abs()`
  nests `hypot` and rounds three times. `hypot`'s proof of correct rounding
  does not carry over to four components, whose smallest square can be finer
  than any fixed point holds and still decide a near tie, so a root within
  2^-300 of a midpoint is settled exactly in integers over the whole span,
  about 4,200 bits.
- **Reproducible results carry a version.** `repro.RESULTS_VERSION` and
  `random.SEQUENCE_VERSION` change with any result of their package. Correct
  rounding is a fixed target, but a bug fix still changes a shipped result,
  so a replay or lockstep peer records the versions and refuses another,
  rather than relying on the contract being unchanged. No build-configuration
  field is needed, since no CPU or optimization level changes a value. The
  rest of a lockstep recipe is the program's: a fixed timestep and input
  order, no clock, entropy, address, map order, or scheduling in a step, a
  canonical serialization with explicit byte order, an explicit rule for
  signed zeros, which `==` equates but later arithmetic does not, and a
  specified tie rule for SIMD extrema of equal signed-zero lanes, as
  [examples/lockstep.loke](examples/lockstep.loke) shows. NaN results of
  `core:math/repro` are canonical, but other arithmetic NaNs are not; a
  program that inspects or serializes NaNs canonicalizes them first.
- **Two `f64` experiments did not pay.** On 2026-10-30, specializing `log2`
  and `log10` to their constant, so that its split folds, saved 1.3 of their
  13 ns over `log`; and one trigonometric kernel with its coefficients chosen
  by the quadrant, as the `f32` first approximation does, took 43.2 ns
  against 42.8 for the branch it removed. The remaining `f64` gap is the
  double-`f64` kernels' arithmetic, which a latency count of each chain, as
  shortened `exp`'s and `log`'s, would locate.
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
- **The local zone is Windows' own rules, read on each use.** The clock a
  user sees is the system's, so a zone from `TZ`, which only the C runtime
  reads, or from a copy of tzdata could disagree with it. Reading the setting
  at every use costs a registry lookup, about 9 µs, and lets a long-running
  program follow a change without a cache to invalidate or a value read at
  import. A failure panics for the reason `random.fill_secure` does: Windows
  does not fail here on a supported system, and a guessed offset would give
  wrong times silently.
- **The package evaluates the yearly rules itself.** Calling
  `SystemTimeToTzSpecificLocalTimeEx` for every instant would be simpler for
  `offset_at`, but `resolve` needs the reverse, and
  `TzSpecificLocalTimeToSystemTimeEx` picks one side of a gap or overlap
  without saying so. Its `SYSTEMTIME` also stops at 1601 and holds only
  milliseconds. Evaluating `GetTimeZoneInformationForYear`'s rules in Loke
  reaches the whole calendar, and taking a rule as data lets the package's
  tests give it the European Union's or Samoa's.
- **The new year is read as Windows reads it.** Windows' per-year rules say
  nothing about when one year's rule gives way to the next, so the reading
  was found by comparing with `SystemTimeToTzSpecificLocalTimeEx` over all
  141 zones of a Windows 10 installation. Taking the rule of the UTC year, as
  Wine does, disagreed in 14 zones wherever the rule changes at the new year.
  Taking over when the old rule's clock shows the new year disagreed in 41,
  for an hour each, until a midnight transition in January's first week was
  read as the state the year starts in: that is how Windows writes "this year
  starts in daylight saving", as in Perth in 2009, and it is also why Windows
  ends Central Brazilian Standard Time's daylight saving on January 1st in
  the years before its first record, 2004, rather than on the first Thursday
  that record names. With both, the two agree at every instant compared:
  hourly from 1990 to 2030 on both sides of each hour, and every 15 minutes
  around each new year and every 37 hours from 1678 to 2261.
- **A zone's own fixed rule stands when Windows' records do not apply.**
  `DynamicDaylightTimeDisabled` turns off the per-year records, not daylight
  saving: Windows then uses the fixed annual transitions the zone supplies,
  and only a zone whose transition dates are cleared, as turning off "Adjust
  for daylight saving time automatically" leaves it, shows standard time all
  year. A zone set with `SetTimeZoneInformation` can have no registry key, so
  `GetTimeZoneInformationForYear` has nothing to look up, though Windows still
  applies the zone's own rule. In both cases the package reads that rule, as
  `SystemTimeToTzSpecificLocalTime` does. `SystemTimeToTzSpecificLocalTimeEx`
  ignores the flag and still applies the records, but the zone is the one the
  clock shows, as .NET's `TimeZoneInfo.Local` also takes it.
- **`resolve` tries offsets rather than inverting the rule.** Each offset the
  zone uses within a day of the time is converted back, and those that show
  the time again are kept. That handles any rule, including a change of rule
  at the new year such as Samoa's skipped day, with at most four conversions
  and no case analysis of its own. `Compatible` is the default of RFC 5545,
  Temporal, and Python's `fold=0`, and what a calendar entry at 02:30 on the
  spring change most plausibly means.
- **The sketch's `Resolution` needed no change.** A payload written
  `(before: Offset, after: Offset)` is an anonymous record, so a caller binds
  `.gap(before, after)` in any package: only a nominal record's fields are
  limited to the package that declares them. `Zone` is a struct around a
  private union, so a named variant can be added later without changing its
  type, and its zero value is the first variant's, UTC.
- **The rule evaluation is tested from inside the package.** Known rules have
  to reach private declarations, so they are `@(test)` procedures in
  `core/time/zone_test.loke`, which the integration harness runs for every
  bundled package that declares tests. A program under `tests/run` compares
  the public procedures with `SystemTimeToTzSpecificLocalTimeEx` in the
  machine's own zone. The package's foreign declarations take `rawptr`, as the
  clock's do, because a foreign symbol has one type: that program declares
  the same functions with its own structures.
- **A duration prints `µs`.** The `µ` is U+00B5, two bytes of UTF-8, as Go
  prints it. A console whose code page is not UTF-8 shows it wrongly, but
  that console misprints every non-ASCII string, and the parser accepts `us`
  and the Greek `μ` alike, so an ASCII-only writer loses nothing.
- **A JSON document keeps every repeated key.** Rejecting or collapsing them
  would build a hash table during every parse. Instead a lookup that matches
  twice is an error rather than a silent choice of the first or last, and a
  protocol that needs globally unique keys checks for them explicitly.
- **A JSON document stores offsets, not views.** A record holding a buffer and
  views into it would need address stability and an internal-borrow rule
  ([Self-referential storage](open-questions.md#self-referential-storage)).
  Node offsets into the source or the decoded text, with views computed by
  accessors wherever the document now is, need no language feature, and the
  document's input is a union of a borrowed view and an owned string.
- **JSON numbers keep their spelling.** Converting eagerly would round 64-bit
  identifiers through `f64`, lose negative zero and huge exponents on a
  rewrite, and spend time on numbers nobody reads. A conversion is asked for,
  and can fail even though the number is valid JSON.
- **JSON nodes are 16 bytes.** Four `u32` fields hold a kind and flags, a token
  offset, a payload, and a count; only a container needs its subtree's end, so
  iteration skips a subtree in one step. Four million nodes take 64 MB rather
  than the 96 MB of the 24-byte layout first considered. Smaller storage is
  not itself a throughput measurement, and no comparison has been made yet.
- **Root access is optional.** An empty, cleared, or failed document needs an
  ordinary representation, and a second owner type only to remove one unwrap
  would double the parser's surface.
- **JSON recognition is not `strconv`'s.** `strconv` accepts whitespace, a
  leading `+`, prefixes, and underscores, none of which JSON allows, so the
  scanner checks the spelling and `strconv` only converts it.
- **The numeric conversions have fallible forms.** Float text goes through the
  C library's "C" numeric locale, whose creation can fail. Printing has no way
  to report that and panics; a JSON writer or reader must report it, so
  `fmt.try_spell_f64` and `strconv.try_parse_f64` expose the failure while the
  conversion algorithms stay in those packages. A bounded output buffer would
  not make the panic recoverable. Each package has its own two-member
  `Backend_Error`, because neither imports the other.
- **`strconv.parse_f64` reduces a long mantissa itself.** The UCRT's `strtod`
  reads only the first 768 significant digits and ignores the rest without a
  sticky digit, so a tie broken by a later digit rounded the wrong way. Keeping
  767 digits and one standing for any nonzero remainder gives the correctly
  rounded result for any length, from a fixed buffer.
- **Small vectors and matrices are records, not `Simd`.** `Vector3(f32)` has
  the layout of `[3]f32` and `Matrix(f32, 4, 4)` that of `[16]f32`, so arrays
  of them have no padding the program did not ask for and go to a GPU upload
  or a C library as they are; `Simd(f32, 4)` is 16-byte aligned and takes
  only constant lane indices, the wrong contract for stored data. Vectors of
  2 to 4 components are named records, since `p.x` reads as the mathematics
  does and a fixed array has no `.x` and the language no swizzles. Matrices
  are one generic `Matrix(T, R, C)`, so a 6 x 6 spatial inertia or a 3 x 4
  fit needs nothing new, and a method bound restricts each operation to the
  shapes it means; a failed bound removes the method from that instantiation
  and leaves the type usable. A generic `Vector(T, N)` beside the named ones
  would give `N = 3` two vector types with a conversion between them, the
  interoperability problem the package exists to remove, so a vector of
  another length is a column matrix. No short names are exported: an alias
  is the same type, so a program's own `Vec3 :: linalg.Vector3(f32);` costs
  nothing, and the package avoids a grid of `Vector3f`, `Vector3d`, and
  `Vector3i`. Large or run-time sizes belong in `core:math/dense`.
- **`linalg` is generic over `Real`, not specialized for the floats.** The
  members that need a square root, trigonometry, or a degenerate-input test
  are bounded by `linalg.Real(T)`, whose slots `linalg` implements for `f32`
  and `f64` and a user type with inherent methods, so a dual number
  differentiates through a transform and fixed point and intervals work with
  nothing from the package. Blocks for `f32` and `f64` alone would have left
  those types with arithmetic only. Methods need no `_f32` suffix, since the
  receiver's type selects the member, and constructors that take only scalars
  are members of the instantiated type, `Matrix(f32, 4, 4).perspective(...)`,
  so an unfixed literal never chooses a width. `Real` requires unary `-`,
  since `T(0) - x` loses the sign of zero, and its bodies compare with `<` and
  `==` alone, since `Ordered` has no `<=` and `!(a < b)` holds for a NaN.
  `Matrix.splat` exists because a zero-initialized record holds `T`'s zero
  value, which for a user rational `{0, 0}` is not `T(0)`. `dot` is the
  bilinear product for every `T`; the Hermitian products need a conjugate
  and came with `linalg.Scalar` for the dense package.
- **Vectors are columns, stored column-major, and `a * b` applies `b`
  first.** It is the order OpenGL takes with `transpose = GL_FALSE`, Direct3D
  and Vulkan shaders read as `column_major`, and LAPACK expects; a row-major
  consumer transposes once at the boundary. `from_rows` lets a constant be
  written as a textbook prints it.
- **Conventions that differ between domains are names or arguments.** The
  clip depth is a required `Depth_Range`, since a silent default is the
  classic source of depth-buffer bugs; Vulkan's downward framebuffer `y` is a
  viewport choice, not a fourth range. Euler angles take a required sequence,
  since aerospace, robotics, and graphics each use a different one. The
  camera constructors are right-handed, as mathematics, OpenGL, glTF, and
  robotics are, with `_lh` forms for Direct3D's convention: a required
  handedness argument would be noise for the right-handed majority, and a
  right-handed library alone leaves the caller a `Z` flip that goes after the
  view matrix and before the projection, which is easy to place wrongly. The
  `_lh` projections are their twins times `diag(1, 1, -1, 1)`, bit for bit.
  Invalid projection parameters panic, as `math.clamp` does for reversed
  bounds, rather than returning an `Option` that no caller could handle
  usefully. Rotations are `math.Quaternion(T)`: a separate unit-rotation type
  could not keep its invariant through rounding, and since an extension
  `impl` is visible only in its own package, the rotation operations are free
  procedures.
- **`approx_equal` takes both tolerances.** The absolute one governs near
  zero, where a relative one means nothing, and no default suits both metres
  and nanometres. An ulp-distance model breaks down at zero, which is where
  geometric residuals land. An infinity equals only itself, since
  `relative * max(|a|, |b|)` is infinite for an infinite operand and would
  call `+Inf` close to `-Inf`.
- **The rotation formulas avoid cancellation.** `quaternion_between` takes an
  angle, `atan2(|u x v|, u . v)`, and an axis, `u x v` without its part along
  `u`, rather than a halfway vector: `normalize(u + v)` and `1 + dot(u, v)`
  cancel for nearly opposite vectors, and at `(1, 0, 0)` and
  `(-1, 1e-9, 0)` the halfway vector was off by `1e-9` radians. `to_euler`
  follows Bernardes and Viollet (PLOS ONE, 2022), one formula for every
  sequence, and takes the middle angle from `4*(w*q_j - sign*q_i*q_k)`, which
  does not cancel near 0, rather than from `2*atan2(n, p) - pi/2`; gimbal
  lock is a pair within two ulps of each other, since at `f64(pi/2)` the pair
  left by rounding is about one ulp. `slerp` takes its angle as
  `2*atan2(|a - b|, |a + b|)`, accurate for close rotations where
  `acos(dot)` is not, so neither it nor `nlerp` has a degenerate case to
  return an `Option` for. `quaternion_from_matrix` returns a non-negative real
  part, so a round trip gives the same quaternion and not its negation.
- **Only three `f32` transforms use lanes.** `transform_point`,
  `transform_direction`, and a 3 x 3 `m * v` at `f32` compute in a
  `Simd(f32, 4)`, since LLVM compiled their scalar forms to two lanes and a
  separate third: `transform_point` went from 2.48 to 1.84 ns. A 4 x 4 product
  and `m * v` of a `Vector4` already vectorize to what lanes give. `f64` lanes
  are two registers at `x86-64`, where `transform_point` ran 2.55 against
  2.42 ns, faster only at `x86-64-v3`, and a program cannot choose by CPU
  level in source. `rotate`'s cross products need lane shuffles, 23 % slower
  at `f64`, and repacking a 3 x 3 product's columns gained 2 to 9 %, too
  little for a second form. A hand-written loop over slices is slower than
  the package, a product by three times, because it bounds-checks each index
  where the records index fixed arrays by constants.
- **Geometry shapes are plain records with named dimensions.** Public fields
  with no padding beyond their vectors' let an array of boxes or triangles go
  to a foreign API as it is. `Aabb2` and `Aabb3` follow `linalg`'s named
  vectors: a generic `Aabb(T, N)` would need a vector type chosen by `N`,
  which `linalg` rejected for the vectors themselves, and the two dimensions
  share private generic helpers instead. `Aabb` is the name graphics,
  physics, and Ericson's *Real-Time Collision Detection* use; `Box` would read
  as the owning [`Box(T)`](design.md#owned-values). A box is its corners,
  which the slab and overlap tests read, rather than a center and extents,
  which cannot represent every box of float corners exactly. A plane is
  `dot(normal, p) == offset` rather than `dot(n, p) + d == 0`, so `offset`
  reads as the distance from the origin along the normal with no sign to
  remember. The package is `core:math/geometry`, beside `linalg` and `dense`,
  where its dependencies and its siblings are, rather than a top-level
  `core:geometry`.
- **Every geometric solid is closed.** Touching shapes intersect and
  `contains` holds on the boundary: that is the collision literature's
  convention, and the only one under which an overlap test between closed
  sets has an exact answer. An integer `Aabb2` is closed too; a pixel or UI
  rectangle with an exclusive maximum belongs with the image and UI code that
  needs it, whose conventions, a width and height or a corner, differ again.
  An empty box has no nearest point, so `closest_point` and the distances
  panic for one rather than answer with a point outside it, and a negative or
  NaN radius panics rather than meaning empty, which would make `contains`
  with `r*r` silently true.
- **Geometric conventions are arguments.** A ray query's `t_min` and `t_max`
  are required, since a default of `[0, inf]` would hide the self-intersection
  bug every ray tracer meets first; the frustum's clip depth and the polygon
  fill rule are required because the domains disagree on them. `cast` takes
  the reciprocal direction as an argument rather than through a second ray
  type. The slab test (Williams et al., 2005) is conservative because bounding
  volumes are where a false miss loses a hit and a false hit costs one more
  test. Its widening is `2*gamma(4)` of the larger end's magnitude, from Ize's
  (2013) `gamma(3)` bound on each distance, rather than `far*(1 + 2*gamma(3))`,
  which narrows a line's range where it is negative. The triangle test is the
  watertight one of Woop, Benthin, and Wald (2013), since Möller and
  Trumbore's leaks at shared edges; it leaves out their axis swap for a
  negative direction, which keeps the winding only for backface culling,
  which `cast` does not do.
- **The predicates are exact, in two stages.** Kettner et al. (2008) show the
  floating-point formulas judging points collinear one way and not another,
  building hulls with a dent, and flipping Delaunay edges forever. Shewchuk's
  (1997) adaptive method needs exactly what
  [Floating-point operators](design.md#floating-point-operators) guarantees,
  and the package keeps its own copy of the error-free sum and product rather
  than adding them to `core:math/repro`'s API. Shewchuk adds two intermediate
  stages between the filter and the exact determinant; here the exact path
  goes straight to the determinant of the raw coordinates, expanded into
  pairwise minors so that no coordinate difference has to be exact. The sign
  is the same and is reached only near a degenerate input. `f64` exactness is
  a documented range for each predicate rather than every finite input:
  scaling by a power of two outside it would cost a branch on every call, and
  can be added without changing a result inside it. The predicates need only
  `Numeric` and `Ordered`, so integers and user ordered types get them, and
  one `Sign` serves all four, since "positive" means something different for
  each anyway. `insphere`'s exact path keeps its 120 KB of expansions in its
  own frame, so the common path's stays small.
- **Polygons are slices, and a ring does not repeat its first vertex.**
  Polygons come from files, tessellators, and other libraries as arrays of
  points, which a slice borrows without a copy. A ring closed by repeating its
  first vertex, as GeoJSON writes one, has an edge of no length, which
  `is_convex` and `is_simple` reject; the caller drops the last vertex.
  `is_convex` counts the sign changes of `b.x - a.x` around the polygon, which
  tells a convex pentagon from a pentagram with comparisons alone. Andrew's
  (1979) monotone chain takes into its upper chain only the points above the
  line from the first sorted point to the last, so `out` needs room for `n`
  points rather than `2n`.
- **Only the `f32` box cast uses lanes.** Its three slabs are a
  `Simd(f32, 4)`, since LLVM compiles the scalar choice of each slab's near
  face to a branch on the direction's sign, which a random ray mispredicts
  half the time, and a lane-wise select is never a branch. `f64` lanes are two
  registers at `x86-64`; they were 20 to 25 % faster at `-opt=speed` but
  13 % slower at `-opt=aggressive` and 64 % slower at `-opt=size`. The
  predicates' filters in lanes were faster only at `x86-64`, and a slab test
  without branches was 35 % slower. Timings moved with code placement, a
  hand-written loop whose code did not change running 18 % faster after an
  unrelated change, so each decision needed an effect at both CPU levels and
  was checked at `-opt=aggressive` and `-opt=size`. What separates the casts
  from a hand-written loop is mostly not their robustness: LLVM vectorizes the
  hand-written box loop four rays at a time, which the cast's branches
  prevent. The predicates' exact paths are `@(cold)`
  ([Cold procedures stay out of line](#cold-procedures-stay-out-of-line)).
- **Geometry recomputes out-of-range values instead of always widening.** A
  ball query, a ball cast, or a triangle cast whose squares, edge functions,
  or determinant are normal numbers keeps its `T` arithmetic and its bits;
  only one whose values overflowed or underflowed is computed again in
  `f64`. A ball cast scales its direction apart from its positions, since
  `t` is a ratio of the two and a unit direction is common with any size of
  ball. `f32` widens
  to `f64` because every product of two `f32`s is exact there and no `f32`
  square leaves its range. `f64` has nothing wider, so it scales by powers of
  two, which are exact and change no rounding, in steps of `2^64` so that the
  scale factor itself never overflows; a triangle whose largest sheared
  coordinate is within `[2^-64, 2^64)` is not scaled at all, since scaling a
  unit-sized triangle down would round away the bits of a subnormal corner.
  Loops of multiplications by constants find and apply the scale with no
  bit manipulation, and keep the triangle cast and the overlap tests
  evaluable at compile time.
- **Dense decompositions rescale by powers of two.** `symmetric_eigen` and
  `svd` scale a matrix outside a safe range first, as LAPACK's `syev` and
  `gesvd` do, rather than making each deflation test, shift, and rotation
  overflow-safe on its own: a half-scale form of the convergence test alone
  still leaves the shift's `d1 - d0` and the bidiagonal's products to
  overflow. LAPACK's `lascl` multiplies by a ratio that rounds each element;
  a power of two rounds nothing that is not subnormal, so a scaled matrix
  gives the unscaled method's bits wherever that one worked, and the
  same-bits promise and every earlier result stand. The limit is the
  largest power of two whose square is finite, rather than LAPACK's
  `sqrt(1/smlnum)`, because it is found with `is_finite` alone, so a user
  real type such as a dual number gets the same limit and keeps `f64`'s
  bits. The Householder builder halves its operands only when
  `alpha - beta` overflows, since halving always would round a subnormal
  operand, and rescales a subnormal column as `larfg` does, so `Q` stays
  orthonormal. `reciprocal_condition` multiplies its right-hand sides by a
  power of two near `|A|_1` instead of tracking a scale through each
  triangular solve, as LAPACK's `latrs` does: Hager's estimator is
  homogeneous, so one factor keeps a well-conditioned matrix's solutions
  near 1 at any scale, and the plain solves are kept.
- **A dense matrix is one owner and two strided views.** `Matrix(T)` owns
  column-major storage, the order LAPACK, Fortran, and `linalg.Matrix` use,
  and `View(T)` and `View_Mut(T)` borrow elements anywhere through a row and a
  column stride, so a block, a transpose, a row, and a foreign buffer in
  either order are one type without a copy, and a vector is a view with one
  column. The strides are private and every constructor checks the extent
  once, so the kernels index through `unsafe.raw_data` with wrapping
  arithmetic and stay memory-safe. Before the package was written, a spike
  measured a 256 x 256 product through a view's checked `[r, c]` at five to
  eight times the final kernel's time, and checked index arithmetic alone
  kept the loop from vectorizing
  ([Overflow checks in index arithmetic](open-questions.md#overflow-checks-in-index-arithmetic)).
  The one rule, not a run-time check, keeps `multiply_into(out, a, b)` from
  writing what it reads. Strides are not negative; a reversed view waits for
  a caller.
- **A dense matrix copies, and has no operators.** `move_only` would stop an
  accidental copy, but a matrix is a value in every numerical language, an
  algorithm sometimes wants the copy, and the copy-cost diagnostic already
  names it. `*` and `+` allocating from the default allocator, as NumPy and
  Eigen read, would hide an allocation and a temporary per operator, the cost
  a numerical program most wants to see, so each operation is a named
  procedure with an `_into` form that never allocates. One `dense.Error` for
  every numerical failure keeps `or_return` working through "factor, solve,
  refine"; a type per factorization would say more in each signature and
  break that chain. The package is `core:math/dense` rather than
  `core:math/matrix`, which reads as the home of the fixed-size matrices too,
  or `core:math/linalg/dense`, a longer import for the same relation.
- **Dense results keep one order, so there is no BLAS and no blocked QR.** A
  foreign BLAS is faster, and its bits differ by machine, library, and thread
  count; it belongs in a package that binds one and states that contract, not
  behind a flag. Cache blocking, `Simd` lanes across outputs, and a pool that
  splits the output keep each element's order, so `lu` and `cholesky` are
  blocked. Splitting one sum into several accumulators does not, and neither
  does the compact WY form of blocked Householder QR, LAPACK's choice, so QR
  applies its reflectors a panel of columns at a time instead, and a faster
  QR with other bits waits for a caller. Cholesky without a pool is
  left-looking, 18.6 against 14.4 operations a nanosecond at `n = 1024`,
  since it reads each earlier column once a panel and writes only the panel;
  with a pool, the right-looking update is the one that splits into tasks.
  Recording a sweep's rotations and applying them to the vectors in blocks
  kept the bits and was 45 % slower, since applied at once, each rotation's
  update overlaps the serial computation of the next, so the eigensolver and
  the SVD apply them one at a time.
- **The dense iterations pool their limit.** `symmetric_eigen` and `svd` allow
  `30 n` sweeps for the whole matrix rather than 30 for each value, as
  `dsvdc` and `imtql2` have it. In a 200 x 200 column-graded matrix the shift,
  computed from the small trailing block, is lost in rounding against the
  large top of the bidiagonal, so the sweeps converge only linearly: the first
  singular value took 62 sweeps and the other 199 took 212 between them.
  LAPACK's `bdsqr` pools its limit too. Neither decomposition has an in-place
  form: each needs scratch vectors beyond the matrix, which would take a
  workspace argument, and the allocator argument already places everything.
- **Complex elements share one generic implementation.** `linalg.Scalar(T)`
  adds `T.Real`, `conjugate`, `real_part`, and `imaginary_part` to what a
  number needs, and generic code recognises a real `T` as `T == T.Real` and
  keeps the real form of each step there, so no real result changed when
  complex elements arrived, and `math.Complex` needs no second implementation
  of each algorithm. The conjugate transpose is a view, `View.adjoint()`;
  `View_Mut` has none, since a write through it would have to conjugate on
  the way in. `dot` conjugates nothing, as `Numeric` defines it.
  `symmetric_eigen` keeps its name for a Hermitian matrix, since a complex
  symmetric one, `A = A^T`, is not what it computes. A pivot's magnitude is
  LAPACK's `cabs1`, `|re| + |im|`, which needs no square root and is `|x|`
  for a real element.
- **The integer bit operations are compiler-known, and zero is the width.**
  A population count or a zero count written in Loke is a loop or a SWAR
  fold, and the default `-opt=none` build runs it as written; set-bit
  iteration in an engine's inner loop needs the one instruction. The library
  had grown three private copies (a SWAR `popcount` in `core:container`, a
  binary-search `leading_zeros_u128` in `core:math`, and a `rotate_left` in
  `core:random`), which the public operations replace. A zero operand
  counts as the width, LLVM's defined form of `ctlz` and `cttz`, rather than
  poison or a panic: `W - leading_zeros(x)` is then the bit width of every
  `x`, and a zero word ends an iteration rather than needing a guard. The
  counts return `int`, as `len` does, whatever the operand's width, and read
  a signed operand's two's-complement pattern rather than refusing it, as
  the bitwise operators do. Odin spells them `count_ones`,
  `count_leading_zeros`, and `count_trailing_zeros` in `base:intrinsics`
  and returns the operand's type; Rust's `count_ones`, `leading_zeros`, and
  `trailing_zeros` are the names kept here.
- **A rotation count is an `int`, taken modulo the width and floored.**
  Every count is then defined without a panic, and a negative count rotates
  the other way, as Go's `bits.RotateLeft` does, so one procedure serves a
  rotation whose direction is computed. A shift's count panics when
  negative because a negative shift has no single meaning; a negative
  rotation does. The rotations are compiler-known for the same type rule as
  the counts: written in Loke over `interfaces.Integral(T)`, a record that
  merely has the operators would be rotated at a width it does not have.
- **The power-of-two operations read the value, and the round-up is checked
  arithmetic.** A power of two is a number, so `is_power_of_two` answers for
  the value: a signed minimum has one set bit but is negative, and calling
  it a power of two would make `is_power_of_two(x)` true where `x > 0` is
  false. `next_power_of_two` is the least power of two at least its operand,
  which is 1 for every operand up to 1, so zero and a negative operand need
  no panic or special case of their own; Rust and C++20 offer it only for
  unsigned types, which Loke's `int` lengths would make every caller
  convert. A result past the type's largest power is a mathematical result
  that does not fit, and design.md "Integer overflow" already says what that
  does: it panics, and is a compile-time error where it is folded. The
  arithmetic policies are panic, wrap, and checked; the checked form,
  `checked_next_power_of_two`, is kept, while a wrapping one is not, since
  the low bits of the power that does not fit are zero, never a power of
  two. The checked form is compiler-known like the rest, not written over
  `interfaces.Integral(T)` as `checked_add` is, because a `distinct`
  integer has no arithmetic until it is given some and would fail that
  constraint where the other bit operations accept it. `bit_width` is C++20's
  name for `W - leading_zeros(x)`, Go's `bits.Len`, and reads the pattern as
  the counts do, so a negative value needs the full width; `reverse_bits`,
  `is_power_of_two`, and `next_power_of_two` are Rust's names.
- **An index set is a set, as `Bit_Set` is.** Its members are the indices
  present, so `len` counts them, `cap` is the capacity, and iteration yields
  the present indices, with the verbs `Bit_Set` already uses. A packed
  `[N]bool` with `len == N` is the other reading, but every engine use named
  for it (dug cells, dirty cells, visited cells) asks set questions:
  whether an index is present, how many, and which. The name says what a
  member is, which `Bit_Set(Enum)` says by its parameter; Odin's
  `core:container/bit_array.Bit_Array` is the dynamic, `get`/`set` reading.
- **One contract over three storages, written once.** A fixed set lives in
  a chunk record, a run-time capacity needs an allocator, and an arena or a
  record field the caller already owns needs neither, so the gap asked for
  one of the first and the last. Rather than three APIs, every operation is
  a private procedure over a word slice and a capacity, the owners lend a
  view, and a procedure that takes `Index_View` takes them all, as
  `core:math/dense` lends `View` from `Matrix`.
- **A view ignores and preserves the bits past its capacity.** A caller's
  words are not ours to clean, and a view that required clear tail bits
  would make every `over` a scan or a trust. Masking the final word on each
  read and writing only below the capacity costs one `and` per operation,
  and lets a caller pack other data into the spare bits. An owner keeps them
  clear as well, so `Index_Set(N)`'s generated `==` compares words.
- **The byte form is fixed, and the words are not it.** Words in host order
  would make a save written on one machine unreadable on another of the
  other byte order, and exposing them as bytes would invite exactly that.
  So the words are reachable only as `u64` values through a view, and the
  file form is its own operation, least significant bit first in each byte
  and bytes in index order, which is also what a little-endian host's words
  look like, so a reader in another language can take it as either. Padding
  in the final byte must be zero: a reader then rejects a save of a larger
  capacity instead of quietly dropping its high indices.
- **`i in set` panics where `contains` does.** A range's `in` answers
  `false` for a value outside it, so the operator could have read an index
  outside `0 ..< cap` as absent. But every other index set operation treats
  such an index as a programmer error, as an array index is, and an `in`
  that quietly answered would hide the miscomputed index that a `contains`
  in the same place reports. The operator is `contains` respelled, so the
  two can be swapped without changing what a program does.

## Compiler design choices

### Compiler-supplied names are declared in source

Some names in the bundled packages cannot be ordinary Loke: `mem.Arena` is a
type the region checker recognizes, `mem.Allocator` must be the predeclared
`Allocator` and not a second nominal type, and `unsafe.transmute` takes a type
and a value of any shape. The compiler supplies them (`src/stdlib.odin`), and
before [`@(intrinsic)`](design.md#intrinsic) their signatures lived in
comments nothing checked, while `-doc` and the interface file left them out.

Declaring each one in its package's source, as Rust declares its intrinsics,
writes the signature once, where readers already look, and puts its doc comment
on a declaration like any other. The compiler checks what it can: that the name
is one it supplies, that a procedure's parameter types, modes, names, and
defaults and its result are its own, and that an enum's members and a
descriptor's fields match. Requiring a declaration for every public name keeps
a new contribution from going undocumented.

A generated description was the alternative: the compiler could render its own
symbols into `-doc` and `api.loki`. That keeps no doc comment beside the
package's other declarations, and an operation the compiler types itself would
still need a signature kept as text in the compiler. Declaring the name in
source has the same limit for those operations, `raw_data`'s five operand forms
among them: their written signature is for readers, checked only for its name,
and the specification defines their typing. Such an operation is still
documented where its package is, which a generated table would not do.

The declaration adds no symbol. It never reaches the selected view the checker
walks, so no other pass treats a `---` body as a foreign procedure or a missing
definition, and the name keeps the one identity the compiler gave it.

### Projects name dependencies, not versions

Imports carry no version and no location. A project gives each dependency a
name, and the name is a collection prefix, `import "json:parse";`, so moving or
vendoring `json` changes one manifest line and no source
([Projects](compiler-guide.md#projects)). One name names one directory in the
whole program, across every dependency's manifest: a conflict is an error
rather than two copies of a package, because two copies would give one type two
identities, and a `-collection` override chooses the directory for the whole
program. The names are one flat space, so a program can import a dependency of
a dependency without requiring it. The manifest is plain `require <name>
<path>` lines, trivial to parse now and in a self-hosted compiler.

When versioned sources arrive, the version chosen is the highest minimum any
manifest asks for, as Go's minimal version selection does: deterministic
without a solver. Selection alone does not pin content, so the lock records
each dependency's source, version, immutable commit, and checksum
([Packages and dependencies](future-plans.md#packages-and-dependencies)). What
identity and compatibility boundary that selection works within is open
([Package and import versioning](open-questions.md#package-and-import-versioning)).

### A CPU level changes instructions, not results

The instructions a build may use, the numerical contract of its math, and its
optimization effort are three separate choices: `-cpu`, the package a program
imports, and `-opt`. A faster level must not relax a result, so a level with
FMA accelerates an explicit `math.fma` and never turns `a*b + c` into one. The
levels are the standard cumulative x86-64 ones, as GCC and Clang define them,
rather than a hand-picked approximation such as "v3 means AVX2", and baseline
stays the default. `x86-64-v4` waits for AVX-512 hardware to test on, and
`native` for a reason to resolve one machine's features. There is no public
`-target` while Windows x64 is the only target, since an option accepting one
value would fix triple spelling before a second target forces it
([More platforms](future-plans.md#more-platforms)).

IR flags are not the only control on fusion: Clang's `-ffp-contract` also sets
the backend's mode for `.ll` input, and the runtime's C sources would get
Clang's default, which fuses within an expression. Harmless at baseline, which
has no FMA, that stops being so at `x86-64-v3`, so every Clang command passes
`-ffp-contract=off` rather than relying on a default.

A build above baseline must check the processor before any code of its level
runs. `wmain` carries an explicit baseline `"target-features"` list and calls
the check first, which is compiled as baseline code under a
`target("arch=x86-64")` pragma; a `"target-cpu"` attribute alone was not
enough, since the command line's features still applied and a v3 callee was
inlined into it. An object build enforces its level with a baseline static
constructor that runs the same check before the host's `main`, rather than
metadata every host would have to read; a host that chooses between builds
can still ask `loke_rt_v1_cpu_supports` first.

### The processor check asks compiler-rt

A build above baseline checks the processor at startup
([CPU levels](compiler-guide.md#cpu-levels)), and `runtime/cpu.c` asks
Clang's `__builtin_cpu_supports("x86-64-v2")` or `("x86-64-v3")` after
`__builtin_cpu_init()` rather than reading CPUID and XGETBV itself. Every link
already takes compiler-rt, which supplies the detection, built for every x64
processor, and keeps it current with Clang; the hand-written version was CPUID
and XGETBV assembly with two compilers' spellings and a mask for each level's
feature bits, all of it to review again for each new level.

The level names arrived in Clang 18 (`27da15381cbe`, "[X86]
`__builtin_cpu_supports`: support x86-64{,-v2,-v3,-v4}", August 2023); Clang
17's compiler-rt has no level bits, and its Clang rejects the strings. So
Clang 18 is the stated minimum ([readme.md](readme.md#getting-started)). The
alternative, keeping the manual version as a fallback for older Clang, would
keep all of it for toolchains nothing tests, and a toolchain older than the
minimum fails while compiling the runtime instead of misjudging a processor.

The detection is libgcc's definition of the levels. Its `x86-64-v3` needs
AVX2, which it counts only when CPUID reports OSXSAVE and AVX and XCR0 shows
that the operating system saves the SSE and AVX registers, the check the
manual version made. Its `x86-64-v2` tests SSE4.2, POPCNT, CMPXCHG16B, and
LAHF/SAHF but not SSE3, SSSE3, and SSE4.1, which every processor with SSE4.2
has; only a hypervisor hiding those three could tell the two apart.

A test cannot choose the processor it runs on, so
`tests/obj/cpu_missing_host.c` defines compiler-rt's detection symbols itself,
which keeps the linker from taking the library's, and reports no level; the
runtime's real check then reports a missing `x86-64-v2` on any machine.

### The evaluator's memory limit counts what it holds

[Compile-time evaluation](design.md#compile-time-procedure-evaluation) has a
memory limit so that a runaway evaluation ends with a diagnostic. Counting
storage that evaluation had already released did not help with that. It
rejected ordinary constants instead: `core:math/repro`'s fixed-point slow path
does thousands of integer operations, and `core:math/big` gives every result
room for 32 digits whatever it needs, so one call left 4.7 to 24 MB charged
and eight of the larger ones together passed the limit. The evaluator's
allocator now honors a release (`src/eval_memory.odin`). A small block goes back
to a free list of its size class, and the next request of that class reuses it.
A block over 32 KB goes back to the system heap, so released large storage
does not wait for a request of its own size. An integer built during
evaluation is shrunk to the digits it uses, and its temporaries are released
once dead; a returned frame releases its table and record, and an assignment its
scratch arrays. The same calls now take 1.2 to 5.6 MB.

The accounting depends only on the sizes and order of requests, never on
addresses, so whether a constant fits is the same on every run. Each block's
header records whether it is live, which turns a double or stray release in the
compiler into an assertion rather than a corrupted free list. Evaluated code
never addresses storage that is reused: its slots, elements, and strings are
never released, so reuse cannot make a pointer in evaluated code read another
value.

A value the evaluated program drops is not reclaimed. Copies of a value share
its integers' digits and its elements, as `copy_value` shares a slice's, so the
evaluator cannot tell when the last copy goes. A tracing collector would need
every temporary held on the host stack by the recursive interpreter as a root.
Reference counts would need every copy of an `Eval_Value` to be explicit, and
copies are ordinary Odin assignments throughout the interpreter. design.md
lets such storage stay counted, so the limit holds either way. The remaining
cost is temporaries the program creates and drops. An `append` in evaluated code
copies the whole array into new storage, so building a long array by appending
keeps every earlier copy charged.

### Compiler architecture audit (2026-09-28)

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

### Provenance replay and precise publication

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
The profiling records under
[Provenance normalization](bench/baselines/README.md#provenance-normalization)
distinguish normalization, fact replay, and event materialization cost.

# Structured concurrency: a proposal

Status: **proposal**. Nothing here is accepted syntax or behavior yet;
[design.md](design.md) stays normative. This answers
[Thread transfer needs a visible contract](open-questions.md#thread-transfer-needs-a-visible-contract)
and part of [Concurrency refinements](open-questions.md#concurrency-refinements).

This revision incorporates the
[pre-implementation review](open-questions.md#structured-concurrency-proposal-review-2026-10-22).
The initial feature is lexical fork/join with statically known calls and
results assigned to dead outer locals. Channels, cancellation-aware waiting,
and pools follow as separate library additions under the contracts below.

## Contents

- [The idea](#the-idea)
- [Syntax](#syntax)
- [Rules from existing rules](#rules-from-existing-rules)
- [Failure and cleanup](#failure-and-cleanup)
- [Failure to start a task](#failure-to-start-a-task)
- [New checks](#new-checks)
- [Procedure summaries](#procedure-summaries)
- [What the checks buy](#what-the-checks-buy)
- [Waiting for work](#waiting-for-work)
- [Rejected programs](#rejected-programs)
- [What it does not do](#what-it-does-not-do)
- [Open choices](#open-choices)
- [Order of work](#order-of-work)

## The idea

A task joined before its scope ends is a call that lasts longer.
[The one rule](design.md#capabilities-and-the-one-rule) says a mutable borrow
excludes every other access and a read-only borrow excludes writes. Holding a
task's argument borrows until the join supplies the foundation for checking
concurrent access to that storage.

The join alone is not enough. Transfers in both directions, access through
globals, thread-affine resources, and allocator operations need the
[new checks](#new-checks) below. Together they allow checked scoped concurrency
without `Send` or `Sync` interfaces or lifetime annotations, within the
[stated trust boundaries](#what-the-checks-buy).

## Syntax

```loke
sort :: proc(xs: []mut int) {
	if (xs.len() <= 4096) { slice.sort(xs); return; }
	left, right := xs.split_at_mut(partition(xs));
	parallel {
		spawn sort(left);
		sort(right);              // the parent takes the other half
	}
	// both halves are sorted here
}
```

- `parallel { ... }` is a block. Leaving it by any path — its end, `return`,
  `break`, `continue`, `or_return`, or a panic unwinding through it — waits for
  every task it started.
- `spawn call;` evaluates the callee, receiver, and arguments on the parent,
  at the statement, in ordinary [evaluation order](design.md#evaluation-order).
  Borrows are taken and moves happen there. The prepared call becomes a task;
  the initial executor starts a new thread for it. Initially the callee must
  resolve statically to a procedure or method, including a generic instance.
  Indirect calls need the [procedure summaries](#procedure-summaries) below.
- `spawn result = call;` assigns the returned value to `result` on the worker.
  Initially `result` must name a dead lexical local declared outside the
  block. Fields, indices, destructuring, `_`, and replacement of a live value
  are not result destinations. Its storage is reserved exclusively until
  joining: the parent cannot read, borrow, assign, move, or drop it, even if
  the worker has already completed. There can be only one assigning spawn
  for that local on an executed path before joining. No zero value or copy
  of the returned value is needed. After the join it is definitely initialized
  only on paths that executed its assigning spawn:

  ```loke
  parallel_sum :: proc(xs: []f64) -> f64 {
      mid := xs.len() / 2;
      low: f64;                     // unreadable until the join completes
      high: f64;
      parallel {
          spawn low = sum(xs[:mid]);
          spawn high = sum(xs[mid:]);
      }
      return low + high;
  }
  ```

- A fallible call assigns its whole `Result` or `Status` to a result local.
  Handle it after the block with ordinary `or_return`, `or_else`, or `switch`; see
  [Failure and cleanup](#failure-and-cleanup). `spawn call or_return;` is not
  supported, and a fallible result cannot be silently discarded by a bare spawn.
- `parallel (executor) { ... }` is the later pool form; see
  [Waiting for work](#waiting-for-work). The initial implementation accepts
  only `parallel { ... }`. An executor is selected lexically, never inherited
  implicitly by a helper or nested block.
- `spawn` appears only lexically inside a `parallel` block of the same
  procedure: not in a helper it calls, and not in a capture literal's body,
  which is a procedure of its own. Nested blocks each join their own spawns.

Proposed grammar additions, using [grammar.md](grammar.md#expressions):

```text
Parallel_Statement = "parallel" Block
                   | "parallel" "(" Expression ")" Block  // later: pools
Spawn_Statement    = "spawn" (Identifier "=")? Task_Call ";"
Task_Call          = Postfix_Expression
```

`Task_Call` must start with an identifier and end in a procedure-call suffix;
the entire expression must be a call, not a conversion or an `or_return`
expression. Qualified names and method calls use ordinary call syntax.
`spawn` is a statement, not an expression: neither `x := spawn f();` nor
`x = spawn f();` is supported. A bare spawn applies ordinary result-use rules;
when discarding a nonfallible result is permitted, the worker drops it.

Both words remain contextual. At statement start, `parallel` is a keyword
only before `{`, or before a parenthesized header whose matching `)` is
followed by `{`. `spawn` is a keyword only when followed by an identifier.
Thus `parallel(pool);` and `spawn(callback);` remain ordinary calls, and
`object.spawn(args);` remains a method call. Parenthesized callees and direct
capture literals are outside the initial spawn syntax; later callable support
must preserve these parsing decisions.

Temporaries in a spawn's arguments belong to the task and are dropped on the
worker when the call returns. A result cannot borrow their storage. A result
that borrows an older root retains its own loan after the join, for as long as
that result requires it; joining ends the task's loans, not the result's.

## Rules from existing rules

A `parallel` block behaves as if it declared, before its first statement, a
hidden local that holds its tasks and whose `drop` hook joins them. Existing
rules then give:

1. **Borrows live until the join.** Dropping a value with a drop hook is a use
   of every borrow it carries ([Places and overlap](design.md#places-and-overlap)),
   so a spawn's argument loans stay live until the join. A spawn's call is
   checked as a call whose duration extends to the join: a read-only argument
   keeps its root read-only borrowed, and a mutable carrier, `inout`, or `move`
   argument is the task's alone. A `[]mut T` is exclusive even when passed as
   a named view without another `&mut` at the call site.
2. **Older roots only.** A task may borrow only storage that outlives the
   block, as [Retaining a borrow](design.md#retaining-a-borrow) requires of
   anything stored in an older local. A local declared inside the block is
   younger than the hidden local and is dropped before the join, so
   `spawn fill(&mut local)` of one is rejected. A view copied from outer data,
   such as `chunk := xs[a:b]` inside the block, borrows `xs` and is fine.
   For a local buffer, declare it before a nested `parallel` block and spawn
   there. Diagnostics should suggest that arrangement. This restriction
   follows the chosen cleanup order; the compiler does not silently move a
   local's destruction after the join.
3. **Cleanup order.** On exit the block's own deferred statements and locals run
   first, then the join, then the enclosing scope. That order lets
   `defer jobs.close()` inside the block wake waiting workers before the join
   waits for them. Task loans and allocator exclusions remain live throughout
   this cleanup, so an incompatible deferred access or implicit drop is an
   error. `errdefer` follows the ordinary exit reason, as below.
4. **No handle to forget.** The scope is not a value. It cannot be moved,
   returned, stored, or passed to [`unsafe.forget`](design.md#unsafeforget), so
   the join survives every early exit. This is the scope-owned join guarantee the
   open question asks for.

## Failure and cleanup

A worker's fallible result is a value, not an implicit return from its parent.
The join waits for every task, including when one has returned a failure, and
does not select an error or cancel siblings. The parent handles completed
results in an explicit order:

```loke
run_pair :: proc() -> Status(Work_Error) {
	errdefer rollback();
	first: Status(Work_Error);
	second: Status(Work_Error);
	parallel {
		spawn first = work(0);
		spawn second = work(1);
	}
	first or_return;
	second or_return;
	return .ok;
}
```

Here `first` wins if both fail, independent of completion order. Ordinary
ownership rules drop any unconsumed result. The enclosing `errdefer` runs on
failure propagation after the join. An `errdefer` inside the `parallel` block
would already have been discarded at its normal end; put rollback for worker
results in the scope that handles those results.

A parent `return`, `break`, `continue`, or `or_return` keeps its ordinary
meaning: evaluate the exit value, run block cleanup, join, then continue the
exit. Worker result values do not override a pending return or panic. A return
expression cannot read a place still lent to a task. Parent-side `or_return`
inside the block still runs its pending `errdefer`s before joining, subject to
the same borrow checks as other cleanup. A panic follows the selected
[panic strategy](design.md#panics-and-unwinding); this proposal adds no recovery.

On every exit, including unwinding, completed result locals become live before
enclosing cleanup reaches them. A local whose spawn was not executed stays
dead. The runtime must track completed initialization where control flow needs
it, so joining during an early exit neither leaks a completed result nor drops
uninitialized storage. No result is readable during the block's own cleanup.

## Failure to start a task

Failure to allocate task bookkeeping, create a thread, or submit to a later
executor panics. Plain `spawn` has no recoverable submission result. This is
distinct from the worker returning an ordinary failure value.

Prepare arguments on the parent, then register the task with its scope before
it can run. Registration and submission must ensure that either the task is
owned by the scope and will be joined, or no task can execute and the parent
still owns the prepared arguments. A backend reporting failure after starting
work must retain and join that work; it cannot report an unstarted task.

Under `unwind`, failed preparation destroys only initialized temporaries;
failed submission destroys the prepared arguments on the parent. Explicitly
moved sources remain dead. The failed spawn's result local stays dead. Earlier
successful spawns remain registered, block cleanup runs, and those tasks join
before enclosing storage is released. Under `abort`, the ordinary immediate
termination rule applies. Cleanup that panics while unwinding also follows the
ordinary abort rule.

There is no fallback that runs the failed task on the parent: it would change
TLS and blocking behavior. A later recoverable submission API needs its own
ownership contract. Workloads must bound recursive spawning or use cutoffs;
thread-per-spawn does not promise unlimited resources.

## New checks

Threads add what one thread cannot do. These checks are new:

5. **Shared means read-only all the way down.** A plain-`self` capture literal
   writes through its `&mut` captures
   ([Capture literals](design.md#capture-literals)), so two tasks sharing one
   would race. A read-only argument given to a task must therefore reach no
   `mut` carrier along its [carrier paths](design.md#values-that-contain-borrows):
   no `^mut`, `[]mut`, `dyn mut`, or `&mut` capture. A mutable carrier passed
   directly, an `inout` argument, or a moved value instead transfers exclusive
   access. A value converted to a `dyn`
   view at the spawn is checked through its concrete type; a `dyn` view that
   arrives already erased hides its captures and requires exclusive access,
   as well as the transfer eligibility required by check 8.
   Only compiler-recognized synchronizing operations may mutate shared state
   through a read-only receiver: `Atomic`, `Mutex`, and `Once`, extended to
   `Channel` and cancellation state when those libraries are added. Their
   ordinary fields get no exemption. This is an inferred sharing check;
   omitting a user-written `Sync` interface does not remove the check.
6. **Check global access, including stored aliases.** From the first spawn to
   the join, neither a spawned call's [write effect](design.md#global-write-effects) nor
   the block's own statements may write file-scope or `static` storage. This is
   an error, where `thread.spawn` gets a warning. Existing write effects exclude
   writes through pointers or views stored in globals, so they are insufficient.
   A new conservative effect also records access through global borrow carriers,
   including nested fields, stored callables, and aliases forwarded by helpers.
   Access through a global carrier with reachable mutable, erased, or unknown
   state is rejected; an unresolved target is not an empty effect. Read-only
   access is allowed only when its reachable state meets check 5 and cannot be
   written without triggering these checks. This rejects two argument-free
   workers writing through a global `[]mut T` even if its header never changes.

   Both effects propagate through calls, callbacks, implicit hooks, and cleanup,
   including worker TLS destruction on thread exit. They apply to the parent
   while tasks are live as well as to every task. Synchronizing operations on
   `Atomic`, `Once`, `Mutex`, and later channel and cancellation state are
   allowed; access to a mutex's
   payload must be through its guard. Their ordinary fields receive no
   exemption. A thread's own TLS may be mutated, but a carrier stored there
   must not hide unsynchronized access to shared storage. Apply the same carrier
   check to such access; TLS duration alone does not make its pointee local.
7. **Check borrow transfers in both directions.** A borrow rooted in
   `thread_local` storage cannot cross between parent and worker, even with a
   persistent pool. This applies recursively to arguments, receivers, captures,
   results, failure payloads, and values written back through mutable arguments.
   The callee's [result contract](design.md#procedure-result-contracts) supplies
   result provenance. Reject a returned borrow into worker locals or task-owned
   temporaries; borrowed results must derive from storage that outlives their
   destination, with the corresponding loans retained after the join. The same
   checks apply to a retained borrow written into caller-owned storage. A worker
   may use and drop a borrow of its own TLS entirely within that worker.
8. **`@(thread_affine)`.** A record attribute that propagates structurally, as
   `move_only` does. A thread-affine value cannot be moved, copied, or borrowed
   across a task boundary in either direction, into a channel, or into
   `thread.spawn`. The restriction follows nested values and pointees, including
   owned and shared payloads, returned values, and error
   payloads. A worker may create and destroy its own thread-affine local without
   transferring it; it may not access a thread-affine global owned by another
   thread. Erasure must preserve proof of transfer eligibility. Initially,
   reject erased values whose eligibility cannot be established; exclusive
   access alone does not prove it. This is the opt-out for foreign handles and
   drop hooks that must run on their own thread, so ordinary types need no
   annotation.
9. **Every allocator operation participates in region exclusion.** Allocation,
   resize, deallocation, reset, and provider destruction access allocator state.
   When a task may use a region that is not safe for concurrent access, it
   exclusively reserves that region from spawn until join. Use
   [region provenance](design.md#allocator-regions-and-region-provenance), which
   survives handle copies and owner moves, to check every alias of that region.
   A different task or the parent may not operate on it during the reservation.
   An unknown alias of a known region is treated as possibly the same region.

   Count allocator handles as well as regions retained by owners, whether
   borrowed or moved. Count implicit operations too: cloning, argument temporary
   cleanup, owner drops, returned owners, and parent cleanup
   before the join. Include parent providers of local regions: two separate
   arenas backed by one unsynchronized parent do not have independent allocator
   state. A call whose allocator use cannot be narrowed conservatively reserves
   all regions it can reach through those handles and owners. Merely accessing
   existing elements through a slice needs no allocator reservation; the normal
   lifetime rules still prohibit resetting its region while it is borrowed.

   Permission to use a provider on another thread is a separate requirement.
   The default provider must permit concurrent allocation and deallocation from
   any worker. `Arena` and `Scratch` must permit sequential use from different
   threads under the reservation above; a provider tied to its creating thread
   is thread-affine and cannot transfer even when exclusive. A provider with
   known identity but no cross-thread contract is rejected. Unknown region
   provenance remains an explicit trust boundary, not evidence of independence.
   Debug overlap checks in `Arena` and `Scratch` supplement these rules; they
   do not establish transfer permission or compile-time exclusion.

Checks 7 and 8 apply at channel transfers too. The same argument checks — 7, 8,
and the complete region rule — apply to `thread.spawn`, which keeps
`@(escape=static)`; any region reservation ends at its join. Stored values must
also meet the channel's stricter retention requirement below.

## Procedure summaries

The compiler needs sharing and transfer facts, global-access effects,
allocator-use effects, and result provenance. These are inferred checks, not
new user-written interfaces. They include transitive calls, callbacks,
implicit copy/drop hooks, and cleanup; a named entry is not sufficient if a
callback it invokes has unknown effects.

Initially accept statically resolved calls only when all required facts are
available. Reject unresolved effects and unsupported indirect calls, including
ones reached transitively. Existing explicit trust boundaries for raw pointers,
foreign contracts, and unknown provenance still apply; an unknown checked
callee is not such an exemption.

Before accepting procedure values or erased callables, preserve those facts
through assignments, arguments, and public procedure contracts. A caller must
check the advertised contract; changing a body cannot silently weaken it.
Erasure must preserve both transfer eligibility and effects, and missing facts
mean rejection. Extending callable support must not weaken any check above.

## What the checks buy

- **Checked race freedom within the structured task tree.** With all checks
  implemented, conflicting unsynchronized accesses through checked roots and
  known allocator regions are compile errors. Raw pointers, unknown provenance,
  foreign code, and interference from unstructured threads remain trust
  boundaries. Foreign wrappers and allocator providers must honor their thread
  contracts, including declaring affinity where required. A join does not
  validate those contracts.
- **Serial equivalence for independent computations.** Disjoint tasks that
  depend only on their explicit inputs and have no observable scheduling or
  thread-dependent effects compute the same values when run serially. Absence
  of synchronization types alone does not establish this: two fresh threads
  each incrementing a zero-initialized TLS counter return `(1, 1)`, whereas two
  calls on one fresh thread return `(1, 2)`. Pool reuse, I/O, clocks, randomness,
  and observable lifecycle effects can also distinguish executions. Serial
  debug execution is only an opt-in diagnostic for suitable computations, not
  a generally semantics-preserving implementation of a block. Blocking tasks
  may additionally deadlock if serialized.

The memory model gains these happens-before edges: evaluation of a spawn's
callee, receiver, and arguments happens before its task starts; all task
completion work, including result assignment and argument cleanup, happens
before its block's join completes; a successful channel send happens before
the receive that takes that item. A stop request happens before a token check
or wait observes it.
For a thread-per-spawn executor, completion includes that thread's normal TLS
destruction. A persistent pool retains its TLS between tasks; joining a block
does not destroy the worker's TLS.

## Waiting for work

These are later library additions in `core:sync` and `core:thread`, not
prerequisites for independent computations. No wait group or latch is needed
to join the block's tasks. Data-parallel work already uses a compiler-known
`chunks_mut`:

```loke
shade_all :: proc(pixels: []mut Rgb, scene: ^Scene) {
	parallel {
		foreach (rows in pixels.chunks_mut(4096)) {
			spawn shade(rows, scene);      // `scene` is shared, so it must be read-only throughout
		}
	}
}
```

### Cancellation and shutdown

Cancellation is cooperative and explicit. A move-only `sync.Stop_Source` owns
synchronized stop state; `token()` returns a read-only `Stop_Token` borrowing
that source. The source must outlive every token and registered wait.
`request_stop()` is idempotent, callable through a read-only source reference,
and wakes registered waits. Workers receive tokens as ordinary arguments;
there is no ambient cancellation scope or automatic cancellation on a failure
result. A compute loop may check its token between units of work.

Blocking library operations must integrate the token with wait registration
so a request between checking the state and sleeping cannot be missed.
Cancellation returns an ordinary failure; it does not kill a thread or unwind
its stack. A request observed before an operation commits prevents that
operation. A concurrent request and commit may yield either cancellation or
success, but never a reported cancellation for an item already transferred.
Cancellation does not undo completed operations.

A bounded producer/consumer pipeline uses this shutdown protocol:

1. Declare the channel and stop source outside `parallel` and pass their
   borrows explicitly to every participant.
2. The producer closes the channel on normal completion, using a defer in
   the block; consumers drain it and finish.
3. A participant that fails, or stops before fulfilling its part of the
   protocol, requests stop before leaving. Workers can use `errdefer` for
   their own failure returns; the parent needs the same action for its own
   failure. A parent handling errors only after joining cannot supply this
   wakeup on a failed worker's behalf.
4. Every potentially blocking send, receive, and condition-variable wait in
   the pipeline uses the token. Participants handle cancellation and return;
   the lexical join waits for their cleanup. The parent then handles results
   in its chosen order, including deciding how cancellation errors relate to
   the original work failure.

`defer jobs.close()` alone is insufficient if the producer is already stuck
in `send` after all consumers have stopped. An atomic flag alone cannot wake
a blocked receiver. Neither token cancellation nor a join promises bounded
shutdown for foreign blocking calls, noncooperating code, or lock cycles.

### Channels

`sync.Channel(T)` is bounded, move-only, and owns its queued items. The first
API uses the concurrent default allocator and requires positive capacity;
zero or negative capacity is a programmer error and panics. Rendezvous,
custom queue allocators, `try_`, and deadline variants are later extensions.
The proposed operation shapes are:

```text
Channel(T).init(capacity: int) -> Channel(T)
Channel(T).send(self: ^, value: move T, stop: Stop_Token) -> Status(Send_Error(T))
Channel(T).receive(self: ^, stop: Stop_Token) -> Result(Option(T), Cancelled)
Channel(T).close(self: ^)
```

- `send` waits while full. On success the queue owns the item. On closure or
  cancellation, `Send_Error(T)` owns the unsent item and names the reason;
  dropping the error drops the item. No failure silently loses ownership.
- `receive` waits while empty and open. It transfers one queued item, returns
  `.none` once closed and drained, or reports cancellation without consuming
  an item. Cancellation may leave queued items undrained.
- `close` is idempotent. It prevents further sends, wakes blocked senders and
  receivers, and preserves queued items for draining. A send racing with
  close either commits before closure or returns its item as a failure.
- Dropping the channel drops remaining queued items. Ordinary borrow checks
  require every active operation to have finished before that drop.

Fallible receives use ordinary loops and explicit error handling. A `foreach`
adapter must not silently translate cancellation into normal end-of-stream.
Token-free convenience operations, if added, must be explicitly documented as
noncancellable.

Items carry no borrow of storage shorter than the process
(`@(escape=static)`, as `thread.spawn`). Shared borrowed data reaches workers
through spawn arguments; the channel carries indices or owned jobs. TLS
borrows and thread-affine payloads are rejected recursively. An owner backed
by a local region cannot satisfy process-duration retention. A retained
allocator must permit use and destruction on a receiving thread; queue
synchronization does not make an item's allocator thread-safe.

### Mutex waiting

`guard.wait_until(ready, stop)` accepts a predicate over `^T` and returns
`Status(Cancelled)`. It checks the predicate with the mutex held, atomically
releases the mutex while entering the wait, then reacquires it before checking
again. Spurious wakeups repeat the check. It returns with the guard holding
the mutex on both success and cancellation; reacquisition itself may block.
No borrow of the payload may remain live across the release. The predicate's
effects receive the same checks as other callbacks.

`mutex.notify_one()` and `notify_all()` take read-only receivers. Keeping the
condition variable inside the mutex prevents pairing it with the wrong lock;
the predicate loop handles spurious wakeups. Callers still need a correct
predicate, notification protocol, and lock order.

### Pools

`thread.Pool` has a fixed positive number of persistent workers and is opt-in
for independent compute work. `parallel (&pool)` evaluates the executor once
on entry and borrows it through the join. Dropping the pool stops submission
and joins its workers after all borrowing scopes have ended.

A worker joining a block submitted to its own pool may execute queued tasks
of that block, including descendants submitted to the same pool. This permits
finite, independent nested fork/join computations to finish even with one
worker. Such a child may execute on its spawning worker while that worker
joins; a fresh thread or distinct thread identity is not promised by a pool.
The thread-per-spawn executor still creates a fresh thread for each task.

Helping at joins does not compensate for arbitrary blocking. With one worker,
a task receiving from a queued sibling can block before reaching a join;
holding a lock needed by a child across a join can also deadlock. Cross-pool
wait cycles get no progress guarantee. Initially there is no blocking
compensation, and cancellable waits do not by themselves free a pool worker.

Executor selection stays lexical. A bare `parallel` inside `sort` uses fresh
threads even if its caller used `parallel (&pool)`. A recursive pool algorithm
passes the pool explicitly and selects it in every recursive block. Persistent
workers retain TLS between tasks; neither nesting nor joining resets it.

## Rejected programs

```loke
parallel {
	spawn add_into(&mut total, xs[:mid]);
	spawn add_into(&mut total, xs[mid:]);  // ERROR: `total` is lent to the first task until the join
}

parallel {
	spawn fill(&mut buffer);
	fmt.println(buffer[0]);                // ERROR: `buffer` is lent to a task until the join
}

parallel {
	scratch := [dynamic]int{};
	spawn fill(&mut scratch);              // ERROR: `scratch` is dropped before the join
}

hits: int;                                 // file scope
record_hit :: proc() { hits += 1; }
parallel { spawn record_hit(); }           // ERROR: the task writes `hits`; use sync.Atomic

bump := proc() capture(&mut n) { n += 1; };
parallel { spawn run(bump); }              // ERROR: a shared callable writes `n`; pass move(bump)
```

Checks also cover the return path and access not visible in an argument list:

```loke
counter: thread_local int;                 // file scope, one instance per thread
borrow_tls :: proc() -> ^int { return &counter; }
// In the parent procedure:
result: ^int;
parallel {
	spawn result = borrow_tls();           // ERROR: a worker TLS borrow crosses to the parent
}

values: [1]int;                            // file scope
view: []mut int;                           // file scope
increment :: proc() { view[0] += 1; }
// In the parent procedure:
view = &mut values[:];
parallel {
	spawn increment();                    // ERROR: access through a global mutable carrier
}

arena := mem.Arena.init();
allocator := arena.allocator();
parallel {
	spawn allocate_work(allocator);       // reserves `arena`, including its allocator state
	allocate_work(allocator);             // ERROR: a copied handle still names `arena`
}

parallel {
	spawn work(0) or_return;              // ERROR: assign the outcome; propagate after joining
}

live_answer := 0;
parallel {
	spawn live_answer = compute();       // ERROR: result destination is already live
}

pending_answer: int;
parallel {
	spawn pending_answer = compute();
	spawn pending_answer = compute();    // ERROR: destination already reserved until this join
}

conditional_answer: int;
parallel {
	if (needed) { spawn conditional_answer = compute(); }
}
use(conditional_answer);                 // ERROR: not initialized on the other path
```

Here `allocate_work` allocates through its `Allocator` argument, and `work`
returns a fallible result. Moving an arena-backed owner into a worker does not
avoid the reservation: its eventual drop accesses that same allocator.

## What it does not do

- No `async`, futures, or green threads. A task is a prepared call owned by
  its lexical block and scheduled on that block's executor.
- No passing a scope to helper procedures. That would require a separate
  contract for which storage a helper may lend to the caller's scope. A
  helper opens its own block; a long-lived server puts its block in `main`.
- Panics stay unrecoverable ([Panics and unwinding](design.md#panics-and-unwinding)).
  A task's panic ends the program. A panic in the parent unwinds into the block,
  which joins its tasks before older frames are dropped, since the tasks borrow
  them. A task that never finishes would hang that unwind.
- No automatic cancellation or bounded shutdown guarantee. Explicit tokens
  and wakeable waits follow the [shutdown protocol](#cancellation-and-shutdown);
  a flag is sufficient only for computations that check it without blocking.
- `thread_local` storage a task touches is that of whichever thread runs it.

## Open choices

The initial spelling, thread-per-spawn default, panic-on-submission-failure
policy, and join during parent unwinding are chosen within this proposal.
They are still subject to acceptance with the proposal as a whole. Remaining
extensions are:

1. **Indirect call contracts.** How to encode and expose the
   [procedure summaries](#procedure-summaries) without losing facts through
   erasure. Unsupported checked calls remain rejected in the meantime.
2. **Recoverable submission.** How to return arguments after failure to
   start a task, without confusing submission failure with worker failure.
3. **Richer result destinations.** Whether live replacement, fields, indices,
   or destructuring justify their evaluation, initialization, and cleanup
   rules. The initial form intentionally supports only dead outer locals.
4. **Channel items carrying borrows.** A later retention rule for the
   read-only `send` receiver; process-duration retention remains the initial
   contract. Also defer rendezvous channels and nondefault queue allocators.
5. **Blocking-aware pools.** Whether to compensate for waits or provide a
   separate executor. Fixed pools initially make only the limited progress
   guarantee above.

## Order of work

1. Compiler-known `split_at_mut` and `chunks_mut`, from
   [Provide checked disjoint access](open-questions.md#provide-checked-disjoint-access).
   Without them, tasks cannot each take a mutable piece of one slice.
2. The checking model for statically resolved calls: the scope-owned join,
   result initialization and provenance, checks 5 to 9, and propagation through
   all reachable calls and cleanup. Reject unsupported indirect effects.
   Global-carrier access and allocator lifecycle exclusion are prerequisites
   for checked concurrency, not follow-up safety improvements.
3. `parallel`, `spawn call`, and `spawn result = call`: parser and lowering
   onto a thread-per-spawn runtime in [`core:thread`](standard-library.md#corethread).
   Include atomic task registration and failed-submission cleanup. Keep the
   feature unavailable to ordinary checked programs until the checks above
   are enforced together.
4. Validate the rules with acceptance and rejection tests before adding other
   executors: return an outer slice and keep its loan after the join; reject TLS
   results, temporary-backed results, thread-affine results, and nested error
   payloads carrying them; reject races through global carriers and copied
   allocator handles; check moved-owner drops, completed result cleanup, parent
   cleanup, and shared parent allocators. Reject live or repeated result
   destinations. Test conditional spawns for definite assignment, all early
   exits, enclosing `errdefer` on explicit post-join propagation, and injected
   submission failure after a successful spawn. Check that ordinary calls
   named `parallel` and `spawn` still parse.
5. Extend callable support only after summaries preserve every needed fact.
6. Add `Stop_Source`, `Channel`, and mutex waiting together with the shutdown
   protocol. Test stop-before-wait and stop-during-registration races, close
   racing with send, ownership of unsent items, draining after close, and all
   consumers failing while a producer is blocked. Verify that an operation
   reports success exactly when it committed and cleans up exactly once.
7. Add `Pool` and the executor header. Test independent nested work with one
   worker, explicit recursive executor selection, TLS reuse, and pool lifetime.
   Check documented blocking limits with bounded test harnesses; do not make
   the suite depend on a deadlock resolving. Serial execution is not a
   correctness oracle for thread-dependent tasks.

Once callable summaries are supported, scoped spawning can also accommodate
the thread worker named under
[What a capture literal's `call` cannot do](open-questions.md#what-a-capture-literals-call-cannot-do):
its callable need not outlive the joining scope. The first implementation
uses a named entry and explicit arguments instead.

Try it on the concrete programs open-questions names before deciding: a
sorting or partitioning algorithm, a parallel numeric kernel, and a worker pool
fed by a channel.

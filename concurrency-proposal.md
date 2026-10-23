# Structured concurrency: the library additions

Status: **milestones 1 to 5 are done**. `parallel` blocks and `spawn`
statements are part of the language: [design.md](design.md) defines them
under [Structured concurrency](design.md#structured-concurrency),
[grammar.md](grammar.md#control-flow) parses them, and
[comments.md](comments.md#tasks-that-borrow-joined-by-their-block) gives the
reasons for their shape. What remains here is proposed, not accepted: the
library additions for tasks that wait for each other, the
[later extensions](#later-extensions) still undecided, and the milestones that
add them. Each milestone moves its part of this text into design.md and
standard-library.md in the same commit as the compiler change, as
[AGENTS.md](AGENTS.md) requires.

The reviews that shaped the design are recorded in open-questions.md, from
[Thread transfer needs a visible contract](open-questions.md#thread-transfer-needs-a-visible-contract)
on.

## Contents

- [Waiting for work](#waiting-for-work)
  - [Cancellation and shutdown](#cancellation-and-shutdown)
  - [Channels](#channels)
  - [Mutex waiting](#mutex-waiting)
  - [Pools](#pools)
- [Later extensions](#later-extensions)
- [Implementation plan](#implementation-plan)

## Waiting for work

These are later library additions in `core:sync` and `core:thread`, not
prerequisites for independent computations. No wait group or latch is needed
to join a block's tasks, and data-parallel work already splits its data with
[`chunks_mut`](design.md#chunks-of-a-mutable-slice), as `examples/parallel.loke`
does. What follows is for tasks that wait for each other, and for executors
other than a thread per task. Each addition is checked as
[Structured concurrency](design.md#structured-concurrency) checks a task.

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

Helping makes the join act on the joining thread's TLS.
[Globals while tasks run](design.md#globals-while-tasks-run) lets a task write
its own thread's TLS, and
[Borrows crossing between tasks](design.md#borrows-crossing-between-tasks)
stops TLS borrows only from crossing threads; neither covers a child that runs on its parent's thread while the
parent waits. A parent holding `view := tls_buffer[:]` across the join could
have a helped child append to `tls_buffer` and reallocate it under the view.
So a join under a helping executor counts as a call whose effect includes the
`thread_local` writes, invalidations, and mutable borrows of every task it
may run: the block's tasks and their descendants submitted to the same pool.
[Global write effects](design.md#global-write-effects) then rejects a parent
TLS borrow that is still live across that join, as it rejects one live across
a call that writes the same storage. The thread-per-spawn join needs no such
effect, because a child never runs on its parent's thread.

Helping at joins does not compensate for arbitrary blocking. With one worker,
a task receiving from a queued sibling can block before reaching a join;
holding a lock needed by a child across a join can also deadlock. Cross-pool
wait cycles get no progress guarantee. Initially there is no blocking
compensation, and cancellable waits do not by themselves free a pool worker.

Executor selection stays lexical. A bare `parallel` inside `sort` uses fresh
threads even if its caller used `parallel (&pool)`. A recursive pool algorithm
passes the pool explicitly and selects it in every recursive block. Persistent
workers retain TLS between tasks; neither nesting nor joining resets it.

## Later extensions

The initial spelling, thread-per-spawn default, panic-on-submission-failure
policy, join during parent unwinding, and the `@(synchronized)` and
`@(cross_thread)` declarations are decided and in design.md. These remain
open, and none blocks milestones 6 and 7:

1. **Indirect call contracts.** How to encode and expose the procedure
   summaries, the [reach](design.md#globals-while-tasks-run) and
   [allocator-use](design.md#allocators-and-tasks) effects among them, without
   losing facts through erasure, so the spawned call itself may be indirect. Until then it must
   resolve statically; calls it makes in turn use the whole-program union.
2. **Recoverable submission.** How to return arguments after failure to
   start a task, without confusing submission failure with worker failure.
3. **Richer result destinations.** Whether live replacement, fields, indices,
   destructuring, or an implicit conversion on the worker justify their
   evaluation, initialization, and cleanup rules. The initial form supports
   only dead outer locals of the call's exact result type.
4. **Channel items carrying borrows.** A later retention rule for the
   read-only `send` receiver; process-duration retention remains the initial
   contract. Also defer rendezvous channels and nondefault queue allocators.
5. **Blocking-aware pools.** Whether to compensate for waits or provide a
   separate executor. Fixed pools initially make only the limited progress
   guarantee above. A pool's scoped submission also needs a crossing rule for
   borrowed arguments, which `@(cross_thread)` does not give.
6. **Provider and allocator thread contracts.** Whether a build-selected
   allocator or logging provider must declare that it accepts concurrent use,
   so the compiler checks it instead of trusting it. Whether an `Allocator`
   parameter can promise a concurrent region, so a library can share a
   caller's allocator among tasks.
7. **Checked lazy initialization.** Whether a `sync.Once(T)` or similar that
   owns its value, as `Mutex(T)` does, should replace `Once` guarding separate
   file-scope storage, so tasks can run lazy setup.

## Implementation plan

Each milestone is one or more commits that leave `.\test-all.ps1` passing and
update the documents [AGENTS.md](AGENTS.md) lists in the same commit as the
behavior. File names follow the
[source-code map](compiler-architecture.md#source-code-map).

Done: disjoint slice access (`split_at_mut` and `chunks_mut`); the
`@(synchronized)`, `@(cross_thread)`, and `@(thread_affine)` declarations and
their checks on `thread.spawn`; the reach, allocator-use, and thread-exit
summaries; and `parallel` blocks with `spawn`, checked and lowered to a thread
per task (see [Lowering parallel blocks](compiler-architecture.md#lowering-parallel-blocks)).
Where the compiler is narrower than design.md, [known-gaps.md](known-gaps.md)
says so.

### Milestone 6: waiting and channels

Add `Stop_Source`, `Channel`, and mutex waiting together with the shutdown
protocol, marking their state `@(synchronized)` and `Channel.send`'s item
`@(cross_thread)`. Test stop-before-wait and stop-during-registration races,
close racing with send, ownership of unsent items, draining after close,
and all consumers failing while a producer is blocked. Verify that an
operation reports success exactly when it committed and cleans up exactly
once. Add the channel-fed worker pipeline to `examples/`.

### Milestone 7: pools

Add `Pool` and the executor header. Test independent nested work with one
worker, explicit recursive executor selection, TLS reuse, and pool lifetime.
Reject a parent TLS borrow live across a pool join whose tasks write that
storage. Check documented blocking limits with bounded test harnesses; do
not make the suite depend on a deadlock resolving. Serial execution is not
a correctness oracle for thread-dependent tasks.

### Milestone 8: indirect spawned calls

Extend callable support only after summaries preserve every needed fact
([later extension](#later-extensions) 1).

Once callable summaries are supported, scoped spawning can also accommodate
the thread worker named under
[What a capture literal's `call` cannot do](open-questions.md#what-a-capture-literals-call-cannot-do):
its callable need not outlive the joining scope. The first implementation
uses a named entry and explicit arguments instead.

The concrete programs open-questions names are part of the plan: the sort
and the numeric kernel are in `examples/parallel.loke`, and the worker pool
fed by a channel comes with milestone 6.

# Structured concurrency: the library additions

Status: **milestones 1 to 6 are done**. `parallel` blocks and `spawn`
statements are part of the language: [design.md](design.md) defines them
under [Structured concurrency](design.md#structured-concurrency),
[grammar.md](grammar.md#control-flow) parses them, and
[comments.md](comments.md#tasks-that-borrow-joined-by-their-block) gives the
reasons for their shape. `Monitor(T)` is in `core:thread`, specified under
[Monitors](standard-library.md#monitors) in standard-library.md. What remains
here is proposed, not accepted: the other library additions for tasks that
wait for each other, the
[later extensions](#later-extensions) still undecided, and the milestones that
add them. Each milestone moves its part of this text into design.md and
standard-library.md in the same commit as the compiler change, as
[AGENTS.md](AGENTS.md) requires.

The reviews that shaped the design are recorded in open-questions.md, from
[Thread transfer needs a visible contract](open-questions.md#thread-transfer-needs-a-visible-contract)
on. The [waiting review](open-questions.md#waiting-and-ownership-review-2026-10-26)
was incorporated on 2026-10-26, before any of these additions were built.
The first delivery is monitors and channels, followed independently by compute
pools. The ring is deferred. Earlier drafts used stop tokens for every wait,
then independent endpoint factories and a stronger automatic-shutdown claim.
[Why waits end by ownership](#why-waits-end-by-ownership) says what changed
and why.

## Contents

- [Waiting for work](#waiting-for-work)
  - [Monitors](#monitors)
  - [Channels](#channels)
  - [Real-time handoff](#real-time-handoff)
  - [Shutdown](#shutdown)
  - [Releasing before the join](#releasing-before-the-join)
  - [Pools](#pools)
  - [A mixer, end to end](#a-mixer-end-to-end)
  - [Why waits end by ownership](#why-waits-end-by-ownership)
- [Later extensions](#later-extensions)
- [Implementation plan](#implementation-plan)

## Waiting for work

These are library additions in `core:thread`, beside `Mutex`, because
waiting needs the system's wait and wake calls and `core:sync` makes none.
They are not prerequisites for independent computations. No wait group or
latch is needed to join a block's tasks, and data-parallel work already splits
its data with [`chunks_mut`](design.md#chunks-of-a-mutable-slice), as
`examples/parallel.loke` does. What follows is for tasks that run side by side
and wait for each other: a worker waiting for a job, a producer waiting for
room, an audio loop taking the commands a user interface sends it. Each
addition is checked as
[Structured concurrency](design.md#structured-concurrency) checks a task.

**Structured concurrency keeps borrowed storage alive until tasks finish;
the application's protocol must let those tasks finish.** The waiting types
make common protocols easier to get right:

- **A waiter checks a condition, not a signal.** A monitor wait names a
  predicate over the guarded value, and dropping a guard used for mutation
  wakes the waiters to check it again. Under the
  [condition's obligations](standard-library.md#monitors), there is no
  separate notification to forget.
- **A participant's end is an ownership event.** A task's arguments are
  dropped when its call returns, on every path, and the parent's block locals
  and defers are cleaned up before the join
  ([Parallel blocks](design.md#parallel-blocks)). Dropping the last channel
  endpoint on a side closes that side and wakes its peers. A monitor guard's
  drop releases its lock, but does not say that no one will change its state
  again: a monitor needs an explicit termination transition or `close`.

The [join check](#releasing-before-the-join) rejects retained guards and
endpoints that may prevent a join. It is conservative, not a proof of
termination or a mechanism for cancelling a group of tasks.

### Monitors

Built with [milestone 6](#milestone-6-monitors):
[Monitors](standard-library.md#monitors) in standard-library.md specifies
`Monitor(T)`, `Monitor_Guard(T)`, `lock_when`, and `close`, the obligations on
a condition, and the controller shutdown of a render loop, and
[comments.md](comments.md#waiting-on-a-condition-not-a-signal) gives the
reasons. The channels below are written over it. Dropping a borrow of a
monitor does not close it, and a guard's drop does not say that no one will
change its state again: a monitor needs an explicit termination transition or
`close`, as [Shutdown](#shutdown) lists.

### Channels

`Channel(T)` is a bounded queue between tasks. It is move-only and owns its
queued items. The first version uses the concurrent default allocator and
requires a positive capacity; zero or negative capacity is a programmer error
and panics. A task reaches a channel through an **endpoint** that borrows it:
a `Sender(T)` sends and a `Receiver(T)` receives.

```text
Channel(T).init(capacity: int) -> Channel(T)
Channel(T).split(self: ^) -> (sender: Sender(T), receiver: Receiver(T))
Channel(T).close(self: ^)
Sender(T).fork(self: ^) -> Sender(T)
Receiver(T).fork(self: ^) -> Receiver(T)
Sender(T).send(self: ^, @(cross_thread, escape=static) value: move T) -> Status(Unsent(T))
Sender(T).try_send(self: ^, @(cross_thread, escape=static) value: move T) -> Status(Unsent(T))
Receiver(T).receive(self: ^) -> Option(T)
Receiver(T).try_receive(self: ^) -> Received(T)

Unsent   :: union($T: type) { closed: T, full: T }
Received :: union($T: type) { item: T, empty, closed }
```

`Channel`, `Sender`, and `Receiver` have no zero value. The endpoints are
move-only: ordinary assignment transfers them only under the ordinary move
rules, and implicit copying and generated `clone` are unavailable. `fork`
explicitly creates an additional endpoint of the same side, incrementing its
count without allocating. Its result borrows the channel, not the source
endpoint, so it can outlive that endpoint. Endpoints may be shared through
read-only borrows: queue operations serialize under the channel's lock.

`split` is a one-time operation that creates both initial endpoints together,
under the same lock. There is no state in which a task has an endpoint but
the opposite side has never had one. Calling `split` again, or after `close`,
is a programmer error and panics. A channel's lifecycle is:

| Event | Sending side | Receiving side | Queue and waiters |
| --- | --- | --- | --- |
| `init` | not established | not established | empty; no endpoint operations possible |
| first `split` | open, one sender | open, one receiver | both endpoints become owned together |
| `fork` | increments sender count if a sender | increments receiver count if a receiver | no change to closure or items |
| last sender drops | permanently closed | unchanged | wake receivers; drain committed items, then end-of-stream |
| last receiver drops | unchanged | permanently closed | wake senders; all subsequent sends fail |
| `close` | permanently closed | permanently closed | wake all waiters; sends fail, existing receivers may drain |
| channel drops | no endpoints remain | no endpoints remain | drop all remaining items and free the queue |

A closed side never reopens. Forking a still-owned endpoint after explicit
closure is allowed, but produces another closed endpoint and does not restore
communication. Count updates, closure, and queue operations share the lock;
count overflow panics before changing the count. `close` before `split` is
allowed and permanently prevents splitting. Moves do not change counts.

The operations:

- `send` waits while the queue is full and both sides are open. On
  success the queue owns the item; on failure `Unsent(T)` owns it, and
  dropping the error drops the item, so no failure loses ownership. `try_send`
  never waits for capacity, and returns the item of a send to a full open
  queue as `.full`. Closure takes precedence over fullness: either closed
  side means `.closed`. Blocking `send` never returns `.full`.
- `receive` waits while the queue is empty and the sending side is open, then
  transfers one item. `try_receive` never waits for an item; `.empty` means
  more may come. Both `try_` operations still acquire the channel's lock.
- Items are FIFO in send-commit order. Each item is transferred to at most
  one receiver; several receivers share work, not copies. Sequential sends
  preserve their order. Concurrent calls have no promised ordering until
  they commit, and neither waiters nor lock acquisition have a fairness or
  bounded-latency guarantee.
- A send racing with closure either commits before it, and is then received or
  dropped with the channel, or returns its item. A successful enqueue and a
  successful dequeue each commit under the lock. Receivers may report
  end-of-stream only when the queue is empty and the sending side is closed;
  items committed before closure remain available for draining.
- `Receiver(T)` is iterable: `foreach (job in jobs)` receives until the
  sending side has closed and the queue is empty.
- Endpoint drop and `close` do not destroy queued items. Dropping the channel
  drops remaining items on the channel owner's thread. An unsent item is
  dropped by whoever drops its error, and a received item by its new owner.
  Ordinary borrow checks require every endpoint to end before the channel.

Split inside the `parallel` block, before any participant is started. Early
return then drops every endpoint that has not been transferred to a task.
For multiple workers, retain a receiver only during setup, fork worker
endpoints from it, and drop it before the parent starts blocking sends:

```loke
jobs := thread.Channel(Job).init(16);
parallel {
	send, receive := jobs.split();
	foreach (i in 0..<worker_count) { spawn consume(receive.fork()); }
	drop(receive);   // setup is complete; no spare receiver masks worker failure
	foreach (job in make_jobs()) { send.send(move(job)) or_return; }
}   // the parent's sender drops before the join
```

The application supplies `Job`, `consume`, and `make_jobs`; the enclosing
procedure handles `Unsent(Job)`. If `worker_count` is zero, dropping `receive`
closes its side and the first send fails. A worker exiting during setup cannot
close that side while the setup receiver remains. Once setup ends, failure
of every worker wakes a blocked sender. A spare receiver held during blocking
sends can still cause a deadlock, even if it would drop before the join; the
join check does not prove the parent's body makes progress.

Items carry no borrow of storage shorter than the process
(`@(escape=static)`, as `thread.spawn`'s argument), and both send operations mark
the item `@(cross_thread)`, so it is checked as an argument crossing to another thread
is: no `thread_local` borrow, nothing thread-affine, no owner backed by an
allocator the sending procedure received. Shared borrowed data reaches workers
through spawn arguments; the channel carries indices or owned jobs. Queue
synchronization does not make an item's allocator thread-safe.

### Real-time handoff

Deferred until a concrete application needs it; it does not gate monitors,
channels, or pools. `Ring(T)` is a bounded single-producer/single-consumer
queue. Its first API has only `try_` operations, with no parking, wake calls,
or blocking adapters. Queue operations take no locks and allocate no memory.
This is an algorithmic constraint, not a hard real-time bound on a general
operating system or on application code handling the returned item.

```text
Ring(T).init(capacity: int) -> Ring(T)
Ring(T).split(self: ^) -> (sender: Ring_Sender(T), receiver: Ring_Receiver(T))
Ring_Sender(T).try_send(self: inout, @(cross_thread, escape=static) value: move T) -> Status(Unsent(T))
Ring_Receiver(T).try_receive(self: inout) -> Received(T)
```

- The ring and endpoints have no zero value and are move-only. Capacity is
  positive and allocated from the concurrent default allocator. `split` runs
  once; repeating it panics. Its endpoints borrow the ring's storage; the
  package synchronizes their access to its private state. They cannot be forked.
- An operation requires exclusive access to its endpoint, so two tasks cannot
  operate on that endpoint concurrently. A task can move it to another thread
  sequentially; it is not thread-affine. Merely counting endpoint creation
  would not provide this exclusion. Compile-fail tests must cover sharing
  either endpoint between two tasks.
- Dropping the sender closes the sending side; the receiver drains then sees
  `.closed`. Dropping the receiver closes the receiving side; later sends
  return `.closed` with their item. Closure wins over fullness when observed.
  A send concurrent with receiver drop may commit or return its item; committed
  items remain owned by the ring until received or dropped with the ring.
  There is no public `close` operation in this first API: cancellation of a
  polling loop uses its application's checked flag or termination protocol.
- Slot publication uses release/acquire synchronization before the receiver
  reads an item; slot reclamation uses it before the sender reuses that slot.
  Observing sender closure must also make its final publications visible:
  a receiver rechecks the published tail after observing closure before it
  reports `.closed`. Counters must remain correct through wraparound. The
  exact atomic layout and progress bound require a written algorithm and
  validation before this deferred milestone begins.
- The ring retains ownership on enqueue and transfers it on dequeue, as the
  channel does. Endpoint drop does not destroy buffered items. An unsent item
  stays in its error; remaining queued items drop with the ring after both
  endpoint borrows end. A real-time receiver that must not free memory uses
  non-owning items or returns owned buffers through a second ring for reuse.

The item checks, FIFO ordering, and result variants match the channel, but
changing a channel to a ring also requires exclusive endpoint access and a
polling protocol. A future blocking adapter must specify its waiter
registration and recheck handshake and test wake/close races before it is
added; a kernel wake on the real-time side would need a separate timing claim.

### Shutdown

Shutdown is a protocol over the objects the participants actually use:

| Event | Mechanism | Effect and limit |
| --- | --- | --- |
| A channel participant returns | its owned endpoints drop on the worker | closing the last endpoint on a side wakes its peers; other endpoints keep that side live |
| The parent leaves the block | locals and defers run before the join | block-local endpoints drop and installed monitor cleanup runs |
| A monitor controller ends | explicit termination state or `close` | guard drop alone is insufficient; a true predicate may still proceed after close |
| A channel is cancelled | `Channel.close` | sends fail and receivers drain; a task blocked elsewhere is unaffected |
| A polling loop is cancelled | a flag it checks, such as an `Atomic(bool)` | the loop must check and act on it |

The parent then handles results after the join, in the order it chooses, as
[Task failure and cleanup](design.md#task-failure-and-cleanup) describes. A
receiver cannot tell a sending side closed by a producer's failure from one
closed by its completion; the parent can, from the producer's result, and a
protocol that must tell them apart sends a final item.

Closing a channel is end-of-stream, not an error result or cancellation of a
whole task group. For a group spanning several objects, the application must
close or transition each one whose wait needs to end. Task failure does not
automatically stop unrelated siblings. A foreign blocking call, such as
a device wait or a terminal read, a lock-order cycle, and a protocol whose live
participants all wait on each other are not ended by any of this. No join
promises bounded shutdown for them.

### Releasing before the join

The join waits for every task, and a task may be waiting for the parent to
release something: a guard on the lock it needs, or the last endpoint on a
side of its channel. A value declared before the block is dropped only after
the join, so if the parent still holds one there, the task and the join wait
for each other forever:

```loke
jobs := thread.Channel(Job).init(16);
send, receive := jobs.split();
parallel {
	spawn consume(move(receive));
	foreach (job in make_jobs()) { send.send(move(job)) or_return; }
}   // ERROR: `send` keeps `jobs` open past the join, and `consume` may wait on it
```

Splitting inside the block fixes it: the block's locals are cleaned up before
its join. Moving the sender to a producer task fixes it too, provided that
task ends rather than retaining or returning the endpoint.

A type marked `@(wakes_on_drop)` is one whose drop may wake threads waiting on
the storage it borrows. It takes no value and is permitted on struct and union
types. `Mutex`'s `Guard`, `Monitor_Guard`, and channel endpoints carry it; the
polling-only ring has no waiters and does not need it. It is an attribute rather
than a list of types, as
[`@(synchronized)`](design.md#synchronized) is, so a library's own waiting
types get the same check.

At each block exit, after its locals and defers have been accounted for but
before joining, reject a value retained by the parent if it is or reaches a
marked value whose borrowed storage may overlap a root borrowed by any task
of that block. In particular:

- Follow fields, active or possible union variants, array and container
  elements, owned and shared payloads, and checked pointers or views to
  marked values. Use the existing provenance and call-result summaries to
  find their borrowed roots. Unknown overlap is treated as possible overlap;
  raw pointers and foreign code remain trust boundaries.
- Include enclosing locals, parameters, and values reached through borrowed
  parameters. A borrowed endpoint parameter does not own the caller's endpoint
  and cannot release it by ending the borrow. Each nested block applies the
  check at its own join; cleanup at an outer join is too late for an inner one.
- Include task result destinations and writebacks that can retain a marked
  value after the join. Returning a sender into a parent result slot is
  rejected when a task of that block borrows its channel, including when a
  sibling is draining it. Result provenance must participate even though the
  parent cannot read the result yet.
- Moves into task-owned arguments cease to count as parent retention, unless
  a result or writeback can return the value to the parent. A block-local
  endpoint dropped before the join is allowed, subject to ordinary borrow
  checks. An outstanding borrow that prevents that drop is still an error.
- Check every exit path. A drop at the normal end does not cover an earlier
  `or_return`. Explicit `close` does not discharge this check: retain no such
  endpoint at the join, even if runtime closure would make it harmless.

This intentionally rejects some terminating programs: it does not prove that
the task waits on the retained root, that an endpoint is the last on its side,
or that two aliases refer to different queue instances when provenance cannot
show that. Diagnostics name the retained value, the possibly shared root, and
the joining block, suggesting an earlier drop or transfer. It does not detect
general wait cycles, a parent stuck before cleanup, or missing monitor shutdown.

### Pools

A loop that wakes the same workers for every round of work and waits for them
to finish, as a mixer does once per buffer, is a `parallel` block opened once
per round. Its tasks borrow that round's inputs and outputs, and after the join
the parent has all of them back, which no wait between rounds can give it.
What makes that too slow today is a thread started per spawn; a pool removes
it.

`thread.Pool` has a fixed positive number of persistent workers and is opt-in
for independent compute work. `parallel (&pool)` evaluates the executor once
on entry and borrows it through the join. Dropping the pool stops submission
and joins its workers after all borrowing scopes have ended.

A worker joining a block submitted to its own pool may execute queued tasks
of that block, including descendants submitted to the same pool. It may not
help an unrelated block or a sibling of the task that owns its current join.
A joining thread that is not a worker of that pool only waits; it does not
execute queued work. This exact helping set is also the set summarized by the
compiler's TLS effects below. This permits
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
a task receiving from a queued sibling can block before reaching a join; a
lock a child needs, taken inside a task and held across a nested join, can
also deadlock, though one declared before the block is rejected by
[Releasing before the join](#releasing-before-the-join). Cross-pool wait
cycles get no progress guarantee. Initially there is no blocking
compensation, and ending a wait by closing what it waits on does not by itself
free a pool worker.

Executor selection stays lexical. A bare `parallel` inside `sort` uses fresh
threads even if its caller used `parallel (&pool)`. A recursive pool algorithm
passes the pool explicitly and selects it in every recursive block. Persistent
workers retain TLS between tasks; neither nesting nor joining resets it.

### A mixer, end to end

An audio mixer uses the pieces together. `Device` stands for a binding to the
platform's audio API, whose `write` waits until the device takes a buffer.

```loke
Command :: union { play: int, stop: int, gain: (voice: int, gain: f32) }

main :: proc() -> Status(Audio_Error) {
	device := open_device(48000, FRAMES) or_return;
	voices := load_voices() or_return;
	commands := thread.Channel(Command).init(64);
	pool := thread.Pool.init(3);
	audio: Status(Audio_Error);
	parallel {
		send, receive := commands.split();
		spawn audio = audio_loop(&mut device, &pool, move(receive), move(voices));
		user_interface(move(send));     // takes an owned Sender; drops it on return
	}
	audio or_return;
}

audio_loop :: proc(
	device: ^mut Device, pool: ^thread.Pool,
	commands: move thread.Receiver(Command), voices: move [dynamic]Voice,
) -> Status(Audio_Error) {
	mix := make([dynamic]f32, 2 * FRAMES);
	for (;;) {
		if (!apply_commands(&commands, &mut voices[:])) { return; }   // the interface has ended
		all := &mut voices[:];
		parallel (pool) {
			foreach (group in all.chunks_mut(8)) { spawn render(group); }
		}
		mix_down(voices[:], &mut mix[:]);      // the voices are this loop's again
		device.write(mix[:]) or_return;        // waits one period at most
	}
}

// Applies every command already sent without waiting; `false` once the
// interface has ended.
apply_commands :: proc(commands: ^thread.Receiver(Command), voices: []mut Voice) -> bool {
	for (;;) {
		switch (commands.try_receive()) {
		case .item(command): apply(command, voices);
		case .empty: return true;
		case .closed: return false;
		}
	}
}
```

The pool makes a block per buffer cheap. Its tasks borrow this period's voices
mutably, one group each, and after the join the loop reads them all to mix
down. Commands cross by channel, and the audio loop takes them with
`try_receive`, so it never waits for a command. This is a paced audio worker,
not a hard real-time callback: channel lock acquisition, draining commands,
pool submission and joining, and device I/O have no hard deadline guarantee.
Replacing the channel with a ring would not make that entire loop real-time.

The channel protocol covers these exits. When the user quits, `user_interface`
returns and its sender ends; the audio loop's next `apply_commands` sees
`.closed`, the loop returns, and the join completes. When the device fails,
the audio loop returns its error and its receiver ends, so the interface's
next `send` returns `.closed` and the interface can report it and return. When
the parent unwinds, the unwind drops whichever scope owns the sender, as
quitting would. A user interface blocked in terminal input still needs its
own way to observe device failure; channel closure does not interrupt that
foreign wait. Device latency is an assumption of this example's binding.

### Why waits end by ownership

Each part of this rationale moves to comments.md with the milestone that
builds it. The case for predicate waits moved with monitors, to
[Waiting on a condition, not a signal](comments.md#waiting-on-a-condition-not-a-signal).

**Endpoint ownership.** The earlier token design required explicit stop
requests on each failure path. Endpoint drop naturally expresses completion
and peer loss for a channel, using task argument cleanup and block cleanup
before the join. That removes boilerplate for a pipeline. It does not infer
that a monitor predicate has become impossible, interrupt foreign waits, or
cancel an entire group using several objects. Those need explicit protocols;
selective or group cancellation tokens remain a possible extension.

**Paired setup and explicit duplication.** Independent factories allowed a
receiver to start before a sender ever existed, leaving no sender to drop
on early failure. One `split` establishes both sides together. A setup endpoint
also keeps a side alive while siblings are being started; the parent releases
it before blocking work. Move-only endpoints make transfers visible, and
`fork` adds a participant explicitly without altering Loke's generated `clone`
semantics. Spare endpoints can still mask peer loss, so the setup example and
the conservative [join check](#releasing-before-the-join) are both needed.

**Separate compute and real-time work.** Pools amortize thread creation for
independent computations. They do not make blocking pipelines safe on a fixed
worker count. A ring removes the channel lock for one producer and one consumer,
but does not establish a deadline for a whole audio application. Keeping its
first API polling-only avoids coupling that algorithm to a parking protocol.

## Later extensions

The initial spelling, thread-per-spawn default, panic-on-submission-failure
policy, join during parent unwinding, and the `@(synchronized)` and
`@(cross_thread)` declarations are decided and in design.md. These remain
open; none blocks monitors, channels, or the compute pool. The deferred ring
has its own readiness requirements under milestone 8:

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
   guarantee above. Its scoped submission is compiler lowering under the
   existing spawn borrow checks, not a public `@(cross_thread)` submission API
   for borrowed arguments.
6. **Provider and allocator thread contracts.** Whether a build-selected
   allocator or logging provider must declare that it accepts concurrent use,
   so the compiler checks it instead of trusting it. Whether an `Allocator`
   parameter can promise a concurrent region, so a library can share a
   caller's allocator among tasks.
7. **Checked lazy initialization.** Whether a `sync.Once(T)` or similar that
   owns its value, as `Mutex(T)` does, should replace `Once` guarding separate
   file-scope storage, so tasks can run lazy setup.
8. **Timed waits.** `lock_when`, `send`, and `receive` with a deadline from
   `core:time`, reporting a timeout apart from closure. An audio loop that must
   play silence when a decoder falls behind needs them.
9. **Selective cancellation and choice.** A stop token that ends one waiter
   among several on the same object or coordinates cancellation across several
   objects, and a wait on whichever of several channels is ready first. The
   initial library requires explicit shutdown protocols for those groups.
10. **Unscoped channels.** Endpoints that own shared channel state instead of
    borrowing a local, for a thread `core:thread`'s `spawn` starts or a
    foreign audio callback, which only `@(escape=static)` values reach. The
    [join check](#releasing-before-the-join) cannot follow them, since they
    borrow no root.
11. **Targeted wakeups.** A hint that wakes fewer of a monitor's waiters,
    where waking all of them costs more than their checks. It would narrow
    which waiters wake, not which changes they see.
12. **Blocking ring adapters.** Parking one endpoint and waking it from the
    other requires a proven registration/recheck handshake, closure-race
    handling, and an explicit account of kernel calls on the deadline-bound
    side. It is outside the polling ring's initial API.

## Implementation plan

Each milestone is one or more commits that leave `.\test-all.ps1` passing and
update the documents [AGENTS.md](AGENTS.md) lists in the same commit as the
behavior. File names follow the
[source-code map](compiler-architecture.md#source-code-map).

Done: disjoint slice access (`split_at_mut` and `chunks_mut`); the
`@(synchronized)`, `@(cross_thread)`, and `@(thread_affine)` declarations and
their checks on `thread.spawn`; the reach, allocator-use, and thread-exit
summaries; `parallel` blocks with `spawn`, checked and lowered to a thread
per task (see [Lowering parallel blocks](compiler-architecture.md#lowering-parallel-blocks));
and monitors.
Where the compiler is narrower than design.md, [known-gaps.md](known-gaps.md)
says so.

Delivery order is milestone 7, then the independent compute pool in
milestone 9 when needed. Milestone 8 keeps its identifier for existing
references, but is deferred and is not a prerequisite for milestone 9.
Milestone 10 remains conditional on its callable-summary work.

### Milestone 6: monitors

Done. `Monitor`, `Monitor_Guard`, `lock_when`, and `close` are in
`core:thread`, with the value `@(synchronized)`; on Windows the lock is an
SRWLOCK, as `Mutex`'s is, and the sleep a condition variable over it.
`tests/run/lib_thread_monitor.loke` covers turns handed back and forth, each
depending on a wakeup, so a change racing a waiter's check and its sleep would
hang; a `get` that writes nothing, which wakes a waiter as a spurious wakeup
does; `close` while threads wait; a `ready` that holds after `close`; and a
guard used only through `read`, which wakes no one.
`tests/trap/monitor_ready_unwind.loke` covers an unwind out of `ready`, which
releases the lock. `tests/run/lib_thread_monitor_transport.loke` is the
controller shutdown example with a stand-in renderer, covering early parent
exit, a paused renderer, and a playing renderer that must see `stopping`.
Each carries a watchdog thread that ends the program if a wait never ends.
`tests/err/lib_thread_monitor.loke` checks that no borrow `get` or `read`
handed out outlives the guard. standard-library.md documents the condition's
obligations without claiming compiler-checked purity.

### Milestone 7: channels and the join check

Add `Channel`, its endpoints, `Unsent`, and `Received`, written over
`Monitor`, with both send operations' items `@(cross_thread, escape=static)`.
Implement one-time `split`, move-only endpoints, and `fork`. Add
`@(wakes_on_drop)` and its check, and mark `Guard`, `Monitor_Guard`, and the
endpoints with it. The check rejects code that compiled before, a guard
declared before a block whose tasks lock its mutex, so the commit adds an
upgrade note. Test closure racing with send, ownership of unsent items,
draining after close, every receiver failing while a sender waits, and the
last sender ending while receivers wait. Cover every lifecycle-table
transition: close before split, repeated split, fork after close, endpoint
transfer, and both directions of closure. Check FIFO order, closed-over-full
precedence, and that `try_` send applies the same item checks as `send`.

Add a producer/consumer example and the multi-worker pipeline to `examples/`.
Test early return after split but before the first spawn, between spawns,
and after setup, plus zero workers and a worker returning during setup.
Verify that every committed, unsent, and abandoned queued item is dropped
exactly once on the specified owner thread.

The join-check suite must reject retained guards and endpoints in enclosing
locals, parameters, borrowed wrappers, containers, task results, and
writebacks, including nested joins and early-exit paths. Check acceptance
when endpoints move into tasks or drop during block cleanup. An explicit
close without dropping a retained endpoint remains a documented rejection.
Use bounded harnesses for runtime progress tests; no test may depend on a
deadlock resolving.

### Milestone 8: real-time handoff

Deferred. Before implementation, write the atomic algorithm, including
publication and reclamation ordering, closure observation after the final
enqueue, and wraparound. Validate the exclusive-endpoint API with the borrow
checker and a concrete application. Then add only the polling API over
`Atomic` indices. Test FIFO and wraparound, repeated split, endpoint sharing
rejections, sequential endpoint transfer, producer/consumer drop races, item
ownership, and allocation-free operation. Measure its cost on the intended
target; do not claim a hard real-time bound from throughput measurements.
Blocking adapters require a separate proposal and are not part of this milestone.

### Milestone 9: pools

Add `Pool` and the executor header. Test independent nested work with one
worker, explicit recursive executor selection, TLS reuse, and pool lifetime.
Verify that only workers of that pool help, only within their current joining
block's subtree, and that the TLS-effect summary covers exactly that permission.
Reject a parent TLS borrow live across a pool join whose tasks write that
storage. Check documented blocking limits with bounded test harnesses; do
not make the suite depend on a deadlock resolving. Serial execution is not
a correctness oracle for thread-dependent tasks. Add the mixer's per-buffer
block, with a stand-in device, to `examples/`.

### Milestone 10: indirect spawned calls

Extend callable support only after summaries preserve every needed fact
([later extension](#later-extensions) 1).

Once callable summaries are supported, scoped spawning can also accommodate
the thread worker named under
[What a capture literal's `call` cannot do](open-questions.md#what-a-capture-literals-call-cannot-do):
its callable need not outlive the joining scope. The first implementation
uses a named entry and explicit arguments instead.

The concrete programs open-questions names are part of the plan: the sort
and the numeric kernel are in `examples/parallel.loke`, and the worker pool
fed by a channel comes with milestone 7.

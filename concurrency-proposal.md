# Structured concurrency: the library additions

Status: **milestones 1 to 7 are done**. `parallel` blocks and `spawn`
statements are part of the language: [design.md](design.md) defines them
under [Structured concurrency](design.md#structured-concurrency),
[grammar.md](grammar.md#control-flow) parses them, and
[comments.md](comments.md#tasks-that-borrow-joined-by-their-block) gives the
reasons for their shape. `Monitor(T)` and `Channel(T)` are in `core:thread`,
specified under [Monitors](standard-library.md#monitors) and
[Channels](standard-library.md#channels) in standard-library.md, and the join
check under [Releasing before the join](design.md#releasing-before-the-join)
in design.md. What remains here is proposed, not accepted: the real-time ring
and pools, the
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

Built with [milestone 7](#milestone-7-channels-and-the-join-check):
[Channels](standard-library.md#channels) in standard-library.md specifies
`Channel(T)`, its `Sender(T)` and `Receiver(T)` endpoints, `Unsent` and
`Received`, the lifecycle table, the setup shape for several workers, and
what an item may carry, and `examples/channels.loke` builds the worker
pipeline. [comments.md](comments.md#channels-end-by-ownership) gives the
reasons.

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

Built with monitors and channels: [Shutdown](standard-library.md#shutdown)
in standard-library.md lists what ends each kind of wait, and what nothing
ends.

### Releasing before the join

Built with [milestone 7](#milestone-7-channels-and-the-join-check):
[Releasing before the join](design.md#releasing-before-the-join) in design.md
specifies the check, and [`@(wakes_on_drop)`](design.md#wakes_on_drop) the
attribute that marks `Guard`, `Monitor_Guard`, and the channel endpoints. It is
conservative: it does not prove that a task waits on what a kept value
borrows, and detects no general wait cycle.

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
[Waiting on a condition, not a signal](comments.md#waiting-on-a-condition-not-a-signal),
and the case for endpoint ownership, paired setup, and the join check moved
with channels, to [Channels end by ownership](comments.md#channels-end-by-ownership).

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
monitors; and channels with the join check.
Where the compiler is narrower than design.md, [known-gaps.md](known-gaps.md)
says so.

Delivery continues with the independent compute pool in
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

Done. `Channel`, `Sender`, `Receiver`, `Unsent`, and `Received` are in
`core:thread`, written over `Monitor`, with both send operations' items
`@(cross_thread, escape=static)`. `@(wakes_on_drop)` marks `Guard`,
`Monitor_Guard`, and the endpoints, and the join check (`L0733`) runs at each
`Task_Join` in `borrow.odin`. It rejects a guard declared before a block whose
tasks lock its mutex, which compiled before, so CHANGELOG.md carries an
upgrade note.

- `tests/run/lib_thread_channel.loke` covers FIFO order, `try_send` on a full
  queue, closure taking precedence over fullness, draining after `close`, a
  fork after `close`, the last sender ending while receivers wait, the last
  receiver ending while a sender waits, sends racing `close` with every item
  committed or returned and dropped once, abandoned items dropped on the
  channel owner's thread, and the worker setup with no workers, early returns
  after the split, between spawns, and after setup, and a worker returning
  during setup. A watchdog bounds every wait.
- `tests/trap/channel_split_twice.loke`, `channel_split_after_close.loke`, and
  `channel_capacity.loke` cover the panics.
- `tests/err/lib_thread_channel_items.loke` checks that `try_send` applies
  `send`'s item checks.
- `tests/err/parallel_join_retention.loke` rejects guards and endpoints kept in
  an enclosing local, a parameter, a wrapper, a container, a task result, a
  writeback, at a nested join, on an early exit, and after an explicit
  `close`, and accepts endpoints moved to tasks or dropped before the join.
- `examples/channels.loke` is the producer/consumer and the worker pipeline.

The parent's cleanup of an endpoint is checked by the join check, not by a
runtime test of the endpoint's drop on each exit path; `pool` in the run test
exercises those exits at runtime.

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

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
on. The waiting design was revised on 2026-10-26, before any of it was built:
an earlier draft passed a stop token to every blocking call and woke waiters
by explicit notification.
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

One rule governs every wait here: **a wait ends when what it waits for holds,
or when nothing remains that could make it hold.** Two properties give that
rule without the programmer's help:

- **A waiter checks a condition, not a signal.** A monitor wait names a
  predicate over the guarded value, and every change made under the lock
  wakes the waiters to check it again. There is no notification to forget, or
  to send before the waiter sleeps.
- **A participant's end is an ownership event.** A task's arguments are
  dropped when its call returns, on every path, and the parent's block locals
  and defers are cleaned up before the join
  ([Parallel blocks](design.md#parallel-blocks)). A channel endpoint or a
  guard dropped there releases the threads waiting on it. A producer that
  finishes, a consumer that fails, and a parent that leaves early by
  `or_return` all end the waits on them the same way, with no token to pass
  and no `errdefer` to write.

The compiler checks the one case ownership cannot settle: a value released
only after the join that waits for its waiters
([Releasing before the join](#releasing-before-the-join)).

### Monitors

`Monitor(T)` is a mutex whose holder can wait for the guarded value to reach a
state. As `Mutex(T)` does, it owns its `T`; its zero value is unlocked and
open and holds `T`'s zero; its operations take a read-only receiver, so it
works in file-scope storage and behind a `Shared(T)`; its `value` field is
`@(synchronized)`; and it is move-only. A `Mutex` stays the choice where no
one waits for a state, since it keeps no wakeup bookkeeping.

```text
Monitor(T).lock(self: ^) -> Monitor_Guard(T)
Monitor(T).lock_when(self: ^, ready: $C) -> Option(Monitor_Guard(T))
    where interfaces.Callable(C, proc(value: ^T) -> bool)
Monitor(T).close(self: ^)
Monitor_Guard(T).get(self: inout) -> inout T
Monitor_Guard(T).read(self: ^) -> ^T
```

- `lock_when` locks and calls `ready` with the lock held. While `ready`
  answers `false` and the monitor is open, the thread releases the lock and
  sleeps in one step, then relocks and asks again when woken. Once `ready`
  answers `true`, it returns the guard still holding the lock, so the state
  `ready` saw is the state the guard reaches. Spurious wakeups only repeat the
  check.
- A guard on which `get` was called has **changed** the value. Dropping a
  changed guard wakes every thread sleeping in `lock_when` on that monitor, so
  a change made under the lock happens before every waiter's next check, and
  none is missed. `read` reaches the value without changing it, and dropping
  a guard used only through `read` wakes no one.
- `close` is idempotent and wakes every waiter. From then on, a `lock_when`
  whose `ready` answers `false` returns `.none` instead of sleeping; one whose
  `ready` answers `true` still returns its guard, so a closed monitor can be
  drained. `lock`, `get`, and `read` keep working, so cleanup can read what the
  protocol left.
- `ready` reaches the value only through `^T`, and its effects are checked as
  other callbacks' are. It runs on the waiting thread with the lock held, so it
  must not lock the same monitor: as with `Mutex`, relocking from the holding
  thread never returns.
- There is no wait on a guard already held. A waiter that changes the value
  drops its guard and then calls `lock_when`, whose first check sees any change
  made in between. The only release is a guard's drop, which ends every borrow
  `get` and `read` handed out, so no borrow of the value survives the lock.

```loke
Transport :: struct { playing: bool, stopping: bool }

can_render :: proc(transport: ^Transport) -> bool {
	return transport.playing || transport.stopping;
}

render_loop :: proc(transport: ^thread.Monitor(Transport)) {
	for (;;) {
		state := transport.lock_when(can_render) or_else return;   // sleeps while paused
		if (state.read().stopping) { return; }
		drop(state);
		render_block();
	}
}

set_playing :: proc(transport: ^thread.Monitor(Transport), playing: bool) {
	state := transport.lock();
	state.get().playing = playing;   // dropping the changed guard wakes the loop
}
```

### Channels

`Channel(T)` is a bounded queue between tasks. It is move-only and owns its
queued items. The first version uses the concurrent default allocator and
requires a positive capacity; zero or negative capacity is a programmer error
and panics. A task reaches a channel through an **endpoint** that borrows it:
a `Sender(T)` sends and a `Receiver(T)` receives.

```text
Channel(T).init(capacity: int) -> Channel(T)
Channel(T).sender(self: ^) -> Sender(T)
Channel(T).receiver(self: ^) -> Receiver(T)
Channel(T).close(self: ^)
Sender(T).send(self: ^, value: move T) -> Status(Unsent(T))
Sender(T).try_send(self: ^, value: move T) -> Status(Unsent(T))
Receiver(T).receive(self: ^) -> Option(T)
Receiver(T).try_receive(self: ^) -> Received(T)

Unsent   :: union($T: type) { closed: T, full: T }
Received :: union($T: type) { item: T, empty, closed }
```

Each side of a channel is open until it **closes**, and a closed side never
reopens:

- The receiving side closes when its last receiver ends, once one has been
  made, or when `close` is called. From then on no send succeeds. Items
  already queued stay until the channel is dropped.
- The sending side closes when its last sender ends, once one has been made,
  or when `close` is called. Receivers then take what is queued; once it is
  empty, `receive` returns `.none` and `try_receive` returns `.closed`.

The operations:

- `send` waits while the queue is full and the receiving side is open. On
  success the queue owns the item; on failure `Unsent(T)` owns it, and
  dropping the error drops the item, so no failure loses ownership. `try_send`
  never waits, and returns the item of a send to a full queue as `.full`.
- `receive` waits while the queue is empty and the sending side is open, then
  transfers one item. `try_receive` never waits; `.empty` means more may come.
- A send racing with closure either commits before it, and is then received or
  dropped with the channel, or returns its item. A receive racing with the
  last sender's end takes every item committed before that end.
- `Receiver(T)` is iterable: `foreach (job in jobs)` receives until the
  sending side has closed and the queue is empty.
- Dropping the channel drops its queued items. Ordinary borrow checks require
  every endpoint to have ended first.

Every endpoint counts until it ends, so make one where it is needed and keep
it: a sender made for one statement, `jobs.sender().send(job)`, closes the
sending side when that statement ends, and the next one made cannot send. A
consumer that fails while a loop is still spawning its siblings closes the
receiving side early in the same way; the senders then see `.closed`, as they
would once every consumer had failed.

Items carry no borrow of storage shorter than the process
(`@(escape=static)`, as `thread.spawn`'s argument), and `send`'s item is
`@(cross_thread)`, so it is checked as an argument crossing to another thread
is: no `thread_local` borrow, nothing thread-affine, no owner backed by an
allocator the sending procedure received. Shared borrowed data reaches workers
through spawn arguments; the channel carries indices or owned jobs. Queue
synchronization does not make an item's allocator thread-safe.

### Real-time handoff

An audio callback, or any loop with a deadline, must not wait for a lock
another thread may hold. `Ring(T)` is a channel with one sender and one
receiver whose `try_` operations take no lock and never allocate: each is a few
atomic operations on the ring's indices. It uses the channel's words, so a
program can start with a `Channel` and change the type.

```text
Ring(T).init(capacity: int) -> Ring(T)
Ring(T).sender(self: ^) -> Ring_Sender(T)
Ring(T).receiver(self: ^) -> Ring_Receiver(T)
Ring(T).close(self: ^)
Ring_Sender(T).send(self: ^, value: move T) -> Status(Unsent(T))
Ring_Sender(T).try_send(self: ^, value: move T) -> Status(Unsent(T))
Ring_Receiver(T).receive(self: ^) -> Option(T)
Ring_Receiver(T).try_receive(self: ^) -> Received(T)
```

- Each endpoint is made at most once; making a second sender or receiver is a
  programmer error and panics. With one thread on each side, no slot is
  reached by two threads at once.
- Its sides close as a channel's do: by the end of their endpoint, or by
  `close`.
- `send` and `receive` may wait, for the side that can afford to, such as a
  decoder waiting for room. A `try_` operation on the other side wakes a
  waiting peer: one atomic read when the peer is not waiting, one kernel call
  when it is.
- An item's drop runs on the thread that drops it. A real-time receiver that
  must not free memory takes items that own none, or sends owned buffers back
  through a second ring to be reused.

### Shutdown

Every way a participant leaves ends the waits on it:

| Who leaves | How | What ends the waits on it |
| --- | --- | --- |
| A task | its call returns, with success or failure | its endpoints and guards, dropped with its arguments on the worker |
| The parent | any exit from the block, unwinding included | the block's locals and defers, cleaned up before the join |
| Anyone, cancelling the rest | `close` on the channel, ring, or monitor | every waiter wakes; sends fail and receives drain |
| A loop that never waits | none | a flag it checks, such as an `Atomic(bool)` |

The parent then handles results after the join, in the order it chooses, as
[Task failure and cleanup](design.md#task-failure-and-cleanup) describes. A
receiver cannot tell a sending side closed by a producer's failure from one
closed by its completion; the parent can, from the producer's result, and a
protocol that must tell them apart sends a final item.

Ownership ends only the waits on these types. A foreign blocking call, such as
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
send := jobs.sender();
parallel {
	spawn consume(jobs.receiver());
	foreach (job in make_jobs()) { send.send(job) or_return; }
}   // ERROR: `send` keeps `jobs` open past the join, and `consume` may wait on it
```

Declaring `send` inside the block fixes it: the block's locals are cleaned up
before its join. So does passing it to a task.

A type marked `@(wakes_on_drop)` is one whose drop may wake threads waiting on
the storage it borrows. A value that is or holds one, declared before a
`parallel` block and live at its join on any path, is an error when it borrows
a root that a task of the block also borrows. The check is per path: dropping
the value at the block's end does not cover an `or_return` taken before it.
`Mutex`'s `Guard`, `Monitor_Guard`, and the channel and ring endpoints carry
the attribute. It is an attribute rather than a list of types, as
[`@(synchronized)`](design.md#synchronized) is, so a library's own waiting
types get the same check.

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
		spawn audio = audio_loop(&mut device, &pool, commands.receiver(), move(voices));
		user_interface(commands.sender());     // the sender ends when this returns
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
`try_receive`, so it never sleeps on the user interface. `try_receive` still
takes the channel's lock for a moment; a strict real-time loop takes its
commands from a `Ring` instead.

Each way out ends the other side. When the user quits, `user_interface`
returns and its sender ends; the audio loop's next `apply_commands` sees
`.closed`, the loop returns, and the join completes. When the device fails,
the audio loop returns its error and its receiver ends, so the interface's
next `send` returns `.closed` and the interface can report it and return. When
the parent unwinds, the unwind drops the sender, as quitting would.

### Why waits end by ownership

This rationale moves to comments.md with the milestone that builds it.

**Conditions, not notifications.** A condition variable is two halves the
compiler cannot relate: a wait in one place and a `notify` in another. A
notification sent before the waiter sleeps, or never sent, is a hang that no
check finds. Waking every waiter on every change, and letting each check its
own condition, removes both mistakes, as Ada's protected entries do by
re-checking their barriers. The cost is waking waiters that a change does not
concern, which a monitor with many waiters pays; a hint to narrow the wakeups
can come later without changing what a waiter observes
([later extension](#later-extensions) 11). A waiter's check reads through
`^T` and changes nothing, so waiters checking again never wake one another
into a loop.

**Ownership, not tokens.** The earlier draft passed a `Stop_Token` to every
blocking call and asked every participant to request a stop before leaving:
an `errdefer` in each worker, and the same in the parent for its own
failures. Each forgotten request was a hang at the join. But Loke already ends
every participant at a point the compiler knows, and the drop there can be the
wakeup: a task's arguments at its return, the parent's block locals before the
join. Closing what others wait on covers cancelling them, and a loop that
never waits needs only a flag. What a token adds beyond that is cancelling one
waiter among several on the same object, which no program has needed yet
([later extension](#later-extensions) 9).

**Endpoints made from the channel.** Rust makes a sender and a receiver as a
pair and clones them. The parent then holds originals it must remember to
drop, and a parent blocked in `send` while still holding a receiver never
closes the receiving side. Making each endpoint from the channel, where it is
needed, leaves the parent holding none unless it asks, and the
[join check](#releasing-before-the-join) rejects one held past the join. The
price is that a side closes for good when its count first falls to zero, so an
endpoint made for a single statement closes its side.

## Later extensions

The initial spelling, thread-per-spawn default, panic-on-submission-failure
policy, join during parent unwinding, and the `@(synchronized)` and
`@(cross_thread)` declarations are decided and in design.md. These remain
open, and none blocks milestones 6 to 9:

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
8. **Timed waits.** `lock_when`, `send`, and `receive` with a deadline from
   `core:time`, reporting a timeout apart from closure. An audio loop that must
   play silence when a decoder falls behind needs them.
9. **Selective cancellation and choice.** A stop token that ends one waiter
   among several on the same object, and a wait on whichever of several
   channels is ready first. Closing the object, and a channel per consumer,
   cover the programs so far.
10. **Unscoped channels.** Endpoints that own shared channel state instead of
    borrowing a local, for a thread `core:thread`'s `spawn` starts or a
    foreign audio callback, which only `@(escape=static)` values reach. The
    [join check](#releasing-before-the-join) cannot follow them, since they
    borrow no root.
11. **Targeted wakeups.** A hint that wakes fewer of a monitor's waiters,
    where waking all of them costs more than their checks. It would narrow
    which waiters wake, not which changes they see.

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

### Milestone 6: monitors

Add `Monitor`, `Monitor_Guard`, `lock_when`, and `close` to `core:thread`,
marking the value `@(synchronized)`. On Windows the lock is an SRWLOCK, as
`Mutex`'s is, and the sleep a condition variable over it. Test a change made
between a waiter's check and its sleep, spurious wakeups, `close` while
threads wait, a `ready` that holds after `close`, a guard used only through
`read`, which wakes no one, and an unwind out of `ready`, which releases the
lock.

### Milestone 7: channels and the join check

Add `Channel`, its endpoints, `Unsent`, and `Received`, written over
`Monitor`, with `send`'s item `@(cross_thread, escape=static)`. Add
`@(wakes_on_drop)` and its check, and mark `Guard`, `Monitor_Guard`, and the
endpoints with it. The check rejects code that compiled before, a guard
declared before a block whose tasks lock its mutex, so the commit adds an
upgrade note. Test closure racing with send, ownership of unsent items,
draining after close, every receiver failing while a sender waits, the last
sender ending while receivers wait, an endpoint made after its side closed,
and the join check's rejections: an endpoint or guard declared before the
block, live on an `or_return` path, or held in a record. Verify that an
operation reports success exactly when it committed and cleans up exactly
once. Add the channel-fed worker pipeline to `examples/`.

### Milestone 8: real-time handoff

Add `Ring` and its endpoints over `Atomic` indices. Test wraparound at
capacity, the second endpoint's panic, a `try_` operation waking a waiting
peer, and closure from either side.

### Milestone 9: pools

Add `Pool` and the executor header. Test independent nested work with one
worker, explicit recursive executor selection, TLS reuse, and pool lifetime.
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

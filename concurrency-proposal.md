# Structured concurrency: the library additions

Status: **milestones 1 to 9 are done**. `parallel` blocks and `spawn`
statements are part of the language: [design.md](design.md) defines them
under [Structured concurrency](design.md#structured-concurrency),
[grammar.md](grammar.md#control-flow) parses them, and
[comments.md](comments.md#tasks-that-borrow-joined-by-their-block) gives the
reasons for their shape. `Monitor(T)`, `Channel(T)`, `Ring(T)`, and `Pool`
are in `core:thread`, specified under [Monitors](standard-library.md#monitors),
[Channels](standard-library.md#channels), [Rings](standard-library.md#rings),
and [Pools](standard-library.md#pools) in standard-library.md, and the join
check under [Releasing before the join](design.md#releasing-before-the-join)
in design.md. What remains here is proposed, not accepted: the
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

Built with [milestone 8](#milestone-8-real-time-handoff): `Ring(T)` is
specified under [Rings](standard-library.md#rings) in standard-library.md, and
[comments.md](comments.md#a-spare-slot-in-the-ring) gives the reasons for its
shape. Its algorithm, and why it is correct, follows.

#### The ring algorithm

Built in `core/thread/ring.loke`. It is a single-producer/single-consumer
ring with one spare slot, bounded indices, a cached copy of the other side's
index in each endpoint, and closure as two flags. This replaced the earlier
draft's power-of-two storage and machine-word position counters;
[A spare slot in the ring](comments.md#a-spare-slot-in-the-ring) records the
tradeoff. The orderings are those of
[Concurrency and the memory model](design.md#concurrency-and-the-memory-model),
which adopts C++20's.

```text
Ring(T) :: move_only struct               // no zero value; cannot move while split
    slots:         [dynamic]Ring_Slot(T)  // `size` slots; only queued ones hold an item
    size:          uint                   // requested capacity + 1; immutable after init
    pad_metadata:  [CACHE_LINE_BYTES]u8
    tail:          sync.Atomic(uint)      // next write index; stored by the sender only
    pad_tail:      [CACHE_LINE_BYTES]u8
    head:          sync.Atomic(uint)      // next read index; stored by the receiver only
    pad_head:      [CACHE_LINE_BYTES]u8
    sender_gone:   sync.Atomic(bool)
    receiver_gone: sync.Atomic(bool)
    split_done:    sync.Atomic(bool)
    pad_flags:     [CACHE_LINE_BYTES]u8

@(wakes_on_drop)
Ring_Sender(T)   :: move_only struct { ring: ^Ring(T), tail: uint, head_seen: uint }
@(wakes_on_drop)
Ring_Receiver(T) :: move_only struct { ring: ^Ring(T), head: uint, tail_seen: uint }
```

A `Ring_Slot(T)` is one item of [uninitialized capacity](design.md#uninitialized-capacity)
with a count of zero or one, so no slot needs `T`'s zero, and the slots' own
drop releases only queued items. `CACHE_LINE_BYTES` is a target-specific
separation distance, not a universal 64-byte assumption: 128 on both
supported targets, since x86-64 fetches lines in adjacent pairs and some
Arm64 cores have 128-byte lines. Padding by that distance keeps `tail`,
`head`, and the flag group on disjoint cache lines whatever the ring's own
alignment. The gaps also separate these groups from adjacent
metadata or allocations. In particular, `receiver_gone` must not share
`head`'s line: every send reads the flag. Endpoint-local indices must also be
placed so different tasks do not write the same cache line in measurements.

An index is a `uint` in `[0, size)`, directly naming a slot. `next(p)` is:

```text
n := p + 1
return 0 if n == size else n
```

There is always one spare slot: empty is `head == tail`, full is
`next(tail) == head`, and usable capacity is `size - 1`. Both indices start
at zero. Incrementing a valid index produces at most `size`, which fits
the type; neither subtraction nor machine-word overflow is needed. Ordinary
unsigned arithmetic in Loke is checked, as
[Integer overflow](design.md#integer-overflow) specifies.

- **`init(capacity)`** panics unless capacity is positive and both
  `capacity + 1` and the storage byte size fit the allocator's size range.
  It checks these before allocating or publishing state, allocates exactly
  `size = capacity + 1` slots from the concurrent default allocator, and
  initializes both indices to zero and all three flags to false. No slot
  contains a live `T` yet. Storage must satisfy `T`'s alignment.
- **`split(self: ^)`** panics if `split_done.exchange(true, .Relaxed)` answers
  `true`, so two tasks splitting at once get one pair. Each endpoint starts
  with both of its indices at zero. The endpoint annotations bring polling
  for closure under the [join check](design.md#releasing-before-the-join),
  just as for the channel endpoints.

`try_send(self: inout, value)`:

```text
1   if ring.receiver_gone.load(.Acquire)          return .err(.closed(value))
2   t := self.tail
3   n := next(t)
4   if n == self.head_seen {
5       self.head_seen = ring.head.load(.Acquire)
6       if n == self.head_seen {
7           if ring.receiver_gone.load(.Acquire)  return .err(.closed(value))
8           return .err(.full(value))
9       }
10  }
11  unsafe.write(slot(t), move(value))
12  ring.tail.store(n, .Release)
13  self.tail = n
14  return .ok
```

`try_receive(self: inout)`:

```text
1   h := self.head
2   if h == self.tail_seen {
3       self.tail_seen = ring.tail.load(.Acquire)
4       if h == self.tail_seen {
5           if !ring.sender_gone.load(.Acquire)   return .empty
6           self.tail_seen = ring.tail.load(.Acquire)   // the sender's last sends
7           if h == self.tail_seen                return .closed
8       }
9   }
10  n := next(h)
11  item := unsafe.take(slot(h))
12  ring.head.store(n, .Release)
13  self.head = n
14  return .item(item)
```

Dropping the sender is `sender_gone.store(true, .Release)`, and dropping the
receiver is `receiver_gone.store(true, .Release)`. Dropping the ring needs
both endpoint borrows ended: an endpoint dropped on another thread ended its
borrow at that task's join, which orders everything it did before the drop.
So the ring's drop reads `head` and `tail` as plain values. Until they are
equal, it saves the old `head`, advances `head` with `next`, then takes and
drops the item in the saved slot, as containers shorten before they drop.
If an item's drop panics, a deferred drain goes on from `head` while the
unwind runs, so the rest still drop oldest first rather than in the slots'
index order. It frees the storage after draining. Endpoint drop never touches the slots.

Why each requirement holds:

- **One writer per index.** Only the sender stores `tail` and only the
  receiver stores `head`, and an operation needs its endpoint `inout`, so two
  tasks never run one side at once. Sequential transfers between threads must
  order the old user's operations before the new user's, as scoped task
  transfer and join do. Each endpoint's own index is current, and atomic
  coherence prevents its peer observations from going backward in modification
  order, even when a numeric index repeats on a later lap.
- **Bounds.** For the proof only, let `T` and `H` count all sends and receives
  as unbounded integers, and `Hs` and `Ts` name the counts whose stores the
  cached indices observed. Maintain `0 <= T - Hs <= size - 1` and
  `0 <= Ts - H <= size - 1`, with `Hs <= H <= T` and `Ts <= T`.
  The sender refreshes at `next(tail) == head_seen`, which within these
  bounds means `T - Hs == size - 1`, and advances only with room. The
  receiver refreshes at `head == tail_seen`, which means `H == Ts`, and
  advances only with a published item. A stale cache can withhold progress
  but cannot permit overwriting or taking an unpublished item. The live
  positions are at most `size - 1` consecutive ones, so occupy distinct slots.
- **Publication.** The write of an item (line 11 of `try_send`) is
  sequenced before the release store publishing its successor index. The
  receiver takes that item only
  after an acquire load that read that store or a later one, each a release
  store sequenced after it, so the write happens before the take.
- **Reclamation.** In those conceptual counts, a send at `T` requires
  `T - Hs < size - 1`. Thus `Hs > T - size`, so any previous item in that
  slot, at `T - size`, was taken before the head publication the sender
  acquired. Its take happens before the write that reuses the slot.
- **Closure after the final send.** The sender's last `tail` store is
  sequenced before its release store of `sender_gone`. A receiver whose
  acquire load reads `true` there then loads `tail` again (line 6), and by
  coherence that load sees the last store or a later one, so no committed
  item is reported as `.closed`. Without line 6, a receiver that loaded
  `tail` just before the sender's last send and drop would lose that item.
  A send racing the receiver's drop either saw `receiver_gone` and returned
  its item, or committed it; a committed item stays in the ring until the
  ring drops it.
- **Closure over fullness.** A send checks `receiver_gone` before it reports
  `.full` (line 7) as well as first, so once it observes closure it never
  reports fullness.
- **Repeated laps.** `next` resets `size - 1` to zero without overflowing.
  The bounds above prevent either endpoint from lapping its cached peer
  position, so equal indices cannot confuse a full queue with an empty one.
  This holds for arbitrary capacities; no power-of-two allocation is needed.
- **Ownership.** An item belongs to exactly one of the sender's caller, an
  `Unsent` error (it was never written), the ring (from line 11 of
  `try_send` to line 11 of `try_receive`), or the receiver's caller. Successor
  indices are computed before moving an item. Valid slot addressing and
  moves invoke no user hooks, and neither operation can panic between
  taking ownership and publishing it.

**Progress.** In the abstract algorithm neither operation loops: `try_send` makes
at most three atomic loads and one atomic store, and `try_receive` at most
three loads and one store. Calling the implementation wait-free requires
bounded native loads/stores for `Atomic(uint)` and `Atomic(bool)` on the
intended target, without lock, retry-loop, or system-call fallbacks. Atomic
ordering alone does not establish this; verify the lowering before claiming
it. With that requirement met, neither queue operation locks, allocates, or
calls the system.
Moving the item copies `size_of(T)` bytes and runs no hook. That bounds the
ring's own steps, not their time: preemption, page faults, and cache misses
are outside it, and dropping a returned item is the caller's code. With the
verified layout above, cached indices avoid reading the peer's index line
except when the queue looks full or empty. Every send still loads the
separate flag line; endpoint drop invalidates it. Slots carrying items also
cause cache traffic, so this is no claim of eliminating all sharing.

Validation, as of milestone 8:

1. **Model checking.** An exhaustive search of the interleavings under
   sequential consistency, with every shared access one step, found no
   violation over one producer and one consumer, capacities 1, 2, and 3,
   repeated index laps, stale peer caches, retries on a full ring, and every
   placement of either endpoint's drop. It checked FIFO, no overwrite or read
   of an empty slot, drain-before-closed, and exactly-once item ownership
   including the ring's drop, and it fails on two seeded mutants: without the
   final-tail reload, and without the fullness check. It does not cover
   weak-memory reorderings; a C11 model check, with GenMC or a tool like it,
   is still open.
2. **The exclusive-endpoint API under the borrow checker.**
   `tests/err/lib_thread_ring.loke` rejects sharing either endpoint between
   two tasks, sending through a read-only endpoint, keeping the sender past a
   join whose task polls for closure, dropping the ring while split, and a
   borrowing item. `tests/run/lib_thread_ring.loke` moves the sender from a
   task to a task it starts, while another polls.
3. **A concrete application.** The [mixer](#a-mixer-end-to-end)'s audio loop
   polls a ring for its commands. A foreign audio callback cannot hold an
   endpoint, since endpoints borrow the ring
   ([later extension](#later-extensions) 10).
4. **Target validation and measurement.** In the emitted LLVM IR, the
   operations' loads and stores are `load atomic` acquire and `store atomic`
   release on naturally aligned fields, which both targets lower to single
   instructions, and they call nothing that locks or allocates. No test counts
   allocations, and no latency or throughput has been measured on a target;
   the spare slot is a simplicity choice, not an established speed
   improvement, and measurements would not establish a hard real-time
   bound.

The points this leaves for review are in
[open-questions.md](open-questions.md#ring-algorithm-review-points-2026-10-26).

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

Built with [milestone 9](#milestone-9-pools): `parallel (pool)` is specified
under [Parallel blocks](design.md#parallel-blocks) in design.md, `thread.Pool`
and its helping rule under [Pools](standard-library.md#pools) in
standard-library.md, and [comments.md](comments.md#pools-that-help-at-joins)
gives the reasons. The join's `thread_local` effect counts every task spawned
in a pooled block below, on any pool, since which pool a nested block names is
known only when it runs; a bare block's tasks never count.

### A mixer, end to end

Built with [milestone 9](#milestone-9-pools): `examples/mixer.loke` is the
audio loop with a stand-in device. A user interface sends commands over a
channel, the loop takes them with `try_receive` so it never waits for one, and
it renders its voices in a `parallel (pool)` block per buffer, then mixes them
down. When the interface quits, its sender drops and the loop returns; when the
device fails, the loop returns its error, its receiver drops, and the
interface's next send fails. This is a paced audio worker, not a hard
real-time callback: the channel's lock, pool submission and joining, and device
I/O have no deadline guarantee. A user interface blocked in terminal input
still needs its own way to observe device failure.

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
monitors; channels with the join check; the polling ring; and pools.
Where the compiler is narrower than design.md, [known-gaps.md](known-gaps.md)
says so.

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

Done. `Ring`, `Ring_Sender`, and `Ring_Receiver` are in `core:thread`, written
as [The ring algorithm](#the-ring-algorithm) gives, with both endpoints
`@(wakes_on_drop)` and `try_send`'s item `@(cross_thread, escape=static)`.
The algorithm's validation, and what it still lacks, is listed there.

- `tests/run/lib_thread_ring.loke` covers FIFO order through repeated laps at
  capacities 1 to 3, with every full and empty boundary; closure by either
  endpoint, closure taking precedence over fullness, and draining before
  `.closed`; queued items dropped with the ring; a producer and a consumer on
  two threads, polling both ways, at capacities 1 and 3; the sender moving
  from task to task; and sends racing the receiver's drop, every item dropped
  once. A watchdog bounds every polling loop.
- `tests/trap/ring_split_twice.loke` and `ring_capacity.loke` cover the
  panics.
- `tests/err/lib_thread_ring.loke` covers the endpoint and item checks.
- `examples/mixer.loke` takes its commands from a ring.

Blocking adapters require a separate proposal and are not part of this
milestone.

### Milestone 9: pools

Done. `Pool` is in `core:thread`, and `parallel (pool)` lowers to a hidden
`^thread.Pool` local and a `Task_Scope` that borrows it until the join. A
joining worker runs a queued task through `loke_rt_v1_run_task`, so the effect
analysis does not take the join for a call to every task in the program; the
join of a pooled block carries its own tasks' `thread_local` writes instead,
and a bare block's tasks' `thread_local` writes leave the spawn site and the
enclosing procedure's write effect.

- `tests/run/lib_thread_pool.loke` covers nested work with one worker, many
  rounds borrowing chunks of one array, a worker's `thread_local` storage kept
  between tasks and dropped with the pool, a bare block inside a pool task
  starting a fresh thread, a joining thread that is not a worker running no
  task, a joining worker running its block's descendant but not its own
  task's sibling, a worker of another pool only waiting, and a task waiting on
  a queued sibling, bounded by polling. A watchdog bounds every wait.
- `tests/trap/pool_workers.loke` covers a pool with no workers.
- `tests/err/parallel_pool.loke` rejects an executor of another type, a pool
  dropped or lent mutably inside its block, and a `thread_local` view live
  across a pool join whose task or pooled descendant writes it. It accepts a
  view that ends before the join or spans only the spawn, a bare descendant's
  write, and a bare block's task writing the parent's `thread_local` variable.
- `examples/mixer.loke` is the mixer's per-buffer block, with a stand-in
  device.

The example keeps the proposal's shape, moving the voices into the audio loop.
With the voices passed as a borrowed `[]mut Voice` beside the `move` receiver,
the join check rejects the receiver, since two parameters' storage may be the
same.

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

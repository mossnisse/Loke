# Structured concurrency: a proposal

Status: **proposal**. Nothing here is accepted syntax or behavior yet;
[design.md](design.md) stays normative. This answers
[Thread transfer needs a visible contract](open-questions.md#thread-transfer-needs-a-visible-contract)
and part of [Concurrency refinements](open-questions.md#concurrency-refinements).

## Contents

- [The idea](#the-idea)
- [Syntax](#syntax)
- [Rules from existing rules](#rules-from-existing-rules)
- [New checks](#new-checks)
- [What the checks buy](#what-the-checks-buy)
- [Waiting for work](#waiting-for-work)
- [Rejected programs](#rejected-programs)
- [What it does not do](#what-it-does-not-do)
- [Open choices](#open-choices)
- [Order of work](#order-of-work)

## The idea

A task joined before its scope ends is a call that lasts longer. When the
compiler sees where the join is, the existing borrow checker is a data-race
checker. [The one rule](design.md#capabilities-and-the-one-rule) says a mutable
borrow excludes every other access and a read-only borrow excludes writes. Hold
every borrow a task receives until the join, and two tasks cannot touch the same
storage unless both only read it. That is data-race freedom, with no `Send` or
`Sync` interfaces and no lifetime annotations.

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
- `spawn call;` evaluates the call's arguments on the parent, at the statement,
  where borrows are taken and moves happen. The call runs on another thread.
  The callee may be a named procedure, a method, a procedure value, a capture
  literal, or a `dyn proc` view.
- `place = spawn call;` assigns the result when the call returns. The place is
  lent to the task until the join, so the block cannot read it. A dead local
  works, so a result type needs no zero value:

  ```loke
  parallel_sum :: proc(xs: []f64) -> f64 {
  	mid := xs.len() / 2;
  	low: f64;                     // dead until the join assigns it
  	high: f64;
  	parallel {
  		low = spawn sum(xs[:mid]);
  		high = spawn sum(xs[mid:]);
  	}
  	return low + high;
  }
  ```

- `spawn call or_return;` spawns a fallible call. At the join the failures are
  taken in spawn order and the first is returned as
  [`or_return`](design.md#or_return-operator) returns it; the others are
  dropped. The outcome does not depend on which task finished first.
- `parallel (executor) { ... }` runs the block's tasks on the named executor,
  such as `&pool`; see [Waiting for work](#waiting-for-work).
- `spawn` appears only lexically inside a `parallel` block of the same
  procedure: not in a helper it calls, and not in a capture literal's body,
  which is a procedure of its own. Nested blocks each join their own spawns.

Both words are contextual keywords, as `capture` is: `parallel` at the start of a
statement followed by `{` or `(`, and `spawn` at the start of a statement or
after `=` followed by an expression.

Temporaries in a spawn's arguments belong to the task and are dropped on the
worker when the call returns.

## Rules from existing rules

A `parallel` block behaves as if it declared, before its first statement, a
hidden local that holds its tasks and whose `drop` hook joins them. Existing
rules then give:

1. **Borrows live until the join.** Dropping a value with a drop hook is a use
   of every borrow it carries ([Places and overlap](design.md#places-and-overlap)),
   so a spawn's argument loans stay live until the join. A spawn's call is
   checked as a call whose duration extends to the join: a read-only argument
   keeps its root read-only borrowed, and a `&mut`, `inout`, or `move` argument
   is the task's alone.
2. **Older roots only.** A task may borrow only storage that outlives the
   block, as [Retaining a borrow](design.md#retaining-a-borrow) requires of
   anything stored in an older local. A local declared inside the block is
   younger than the hidden local and is dropped before the join, so
   `spawn fill(&mut local)` of one is rejected. A view copied from outer data,
   such as `chunk := xs[a:b]` inside the block, borrows `xs` and is fine.
3. **Cleanup order.** On exit the block's own deferred statements and locals run
   first, then the join, then the enclosing scope. That order lets
   `defer jobs.close()` inside the block wake waiting workers before the join
   waits for them.
4. **No handle to forget.** The scope is not a value. It cannot be moved,
   returned, stored, or passed to [`unsafe.forget`](design.md#unsafeforget), so
   the join survives every early exit. This is the scope-owned join guarantee the
   open question asks for.

## New checks

Threads add what one thread cannot do. These checks are new:

5. **Shared means read-only all the way down.** A plain-`self` capture literal
   writes through its `&mut` captures
   ([Capture literals](design.md#capture-literals)), so two tasks sharing one
   would race. A read-only argument given to a task must therefore reach no
   `mut` carrier along its [carrier paths](design.md#values-that-contain-borrows):
   no `^mut`, `[]mut`, `dyn mut`, or `&mut` capture. Mutable access goes through
   `&mut`, `inout`, or `move`, which are exclusive. A value converted to a `dyn`
   view at the spawn is checked through its concrete type; a `dyn` view that
   arrives already erased hides its captures and is treated as exclusive.
   In checked code only `Atomic`, `Mutex`, `Once`, and `Channel` write through a
   read-only receiver, and each synchronizes. Loke needs no `Sync` because
   checked code has no unsynchronized interior mutability.
6. **No global writes while tasks run.** From the first spawn to the join,
   neither a spawned call's [write effect](design.md#global-write-effects) nor
   the block's own statements may write file-scope or `static` storage. This is
   an error, where `thread.spawn` gets a warning. `Atomic` operations, storage
   behind a `thread.Mutex` guard, and `thread_local` storage are excluded as
   they are today. With read effects this could narrow to the globals a task
   reads.
7. **No thread-local borrows.** A borrow whose root is `thread_local` storage
   cannot be a spawn argument. This closes a case
   [What is not checked](design.md#what-is-not-checked) lists.
8. **`@(thread_affine)`.** A record attribute that propagates structurally, as
   `move_only` does. A thread-affine value cannot be moved, copied, or borrowed
   into a task, a channel, or `thread.spawn`. It is the opt-out for foreign
   handles and drop hooks that must run on their own thread. It is an opt-out
   rather than an opt-in, so ordinary types need no annotation.
9. **Allocating is a write to the region.** An owner backed by a local region
   that is not safe across threads, a `mem.Arena` or `mem.Scratch`, passed
   mutably to a task lends that region
   ([region provenance](design.md#allocator-regions-and-region-provenance)).
   A second task, or the parent, allocating from it then conflicts. The default
   allocator provider must be safe across threads. A region the checker cannot
   name stays the programmer's obligation, and a debug-build check in `Arena`
   and `Scratch` reports two threads inside one at once.

The same argument checks — 7, 8, and the region rule — apply to `thread.spawn`,
which keeps `@(escape=static)`.

## What the checks buy

- In checked code inside `parallel` blocks, a data race is a compile error. What
  remains is `unsafe` code, raw pointers, foreign code, regions the checker
  cannot name, and unstructured `thread.spawn`.
- **Determinism by construction.** Tasks in a block that uses no
  synchronization type cannot observe one another, so the block computes what
  running its spawns in order would. A debug build could run blocks serially.
  This does not hold for a block whose tasks wait on each other through a
  channel or a mutex.

The memory model gains these happens-before edges: a spawn's argument
evaluation happens before its task starts; a task's return happens before its
block's join completes; a channel send happens before the receive that takes
that item.

## Waiting for work

Library additions in `core:sync` and `core:thread`:

- **`sync.Channel(T)`**, bounded, with many senders and receivers, owning its
  queued items:

  ```loke
  Channel(T).init(capacity: int, allocator := mem.default_allocator()) -> Channel(T)
  Channel(T).send(self: ^, value: move T)    // blocks while full
  Channel(T).receive(self: ^) -> Option(T)   // blocks; .none once closed and empty
  Channel(T).close(self: ^)
  ```

  `foreach (job in &jobs)` receives until the channel is closed and drained.
  `try_` and timeout forms complete the set. Items carry no borrow of storage
  shorter than the process (`@(escape=static)`, as `thread.spawn`); shared data
  reaches workers through spawn arguments, and the channel carries indices or
  owned jobs. `Channel` is move-only.
- **Waiting on a `Mutex(T)`.** `guard.wait_until(ready)` with a predicate over
  `^T`, and `mutex.notify_one()` and `notify_all()` through a read-only
  receiver. It is a condition variable that cannot be paired with the wrong
  mutex, and the predicate form leaves no spurious-wakeup bug to write.
- **`thread.Pool`**: a fixed set of persistent workers waiting on an internal
  queue. `parallel (&pool)` submits to it. A join on a pool thread runs queued
  tasks of its own block instead of sleeping, so nested blocks cannot exhaust
  the pool. Dropping the pool stops and joins its threads.

No wait group or latch is needed; the `parallel` block is the wait group.

```loke
worker :: proc(jobs: ^sync.Channel(Job), reports: ^thread.Mutex([dynamic]Report)) {
	foreach (job in jobs) {                // sleeps until a job arrives; ends once closed and drained
		report := Report{path = job.path, lines = count_lines(job.path)};
		guard := reports.lock();
		guard.get().append(move(report));
	}
}

count_all :: proc(paths: []string) -> [dynamic]Report {
	jobs := sync.Channel(Job).init(capacity = 64);
	reports: thread.Mutex([dynamic]Report) = {};
	parallel {
		defer jobs.close();                // runs before the join, so the workers finish
		for (i := 0; i < thread.processor_count(); i += 1) {
			spawn worker(&jobs, &reports);
		}
		foreach (path in paths) { jobs.send(Job{path = path}); }
	}
	return exchange(inout reports.value, {});  // every task has joined; no lock needed
}
```

Data-parallel work over disjoint pieces uses a compiler-known `chunks_mut`:

```loke
shade_all :: proc(pixels: []mut Rgb, scene: ^Scene) {
	parallel {
		foreach (rows in pixels.chunks_mut(4096)) {
			spawn shade(rows, scene);      // `scene` is shared, so it must be read-only throughout
		}
	}
}
```

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

## What it does not do

- No `async`, futures, or green threads. A task is a call on another thread.
- No passing a scope to helper procedures, as Trio's nurseries allow. Doing
  that safely needs lifetime variables Loke does not have. A helper opens its
  own block; a long-lived server puts its block in `main`.
- Panics stay unrecoverable ([Panics and unwinding](design.md#panics-and-unwinding)).
  A task's panic ends the program. A panic in the parent unwinds into the block,
  which joins its tasks before older frames are dropped, since the tasks borrow
  them. A task that never finishes would hang that unwind.
- Cancellation is explicit: a stop flag passed as an ordinary argument, since
  threads receive only the arguments given to them
  ([Concurrency and the memory model](design.md#concurrency-and-the-memory-model)).
- `thread_local` storage a task touches is that of whichever thread runs it.

## Open choices

Recommendations first.

1. **Spelling.** `parallel` and `spawn`. Alternatives: `scope`, or `fork` and
   `join`.
2. **Default executor.** A thread per spawn: simple, and a blocked task cannot
   starve others. A process pool makes spawns cheap, but blocking tasks can
   starve it until the pool adds a thread when one blocks in `core:sync`.
   Recommended: a thread per spawn by default, the pool opt-in, until the pool
   can compensate for blocking.
3. **A panic in the parent.** Join, keeping the older frames' cleanup but
   possibly hanging; or end the program at the block, which cannot hang but
   skips that cleanup. Recommended: join.
4. **Channel items carrying borrows.** Later; it needs the read-only `send`
   receiver to count as a retention destination.

## Order of work

1. Compiler-known `split_at_mut` and `chunks_mut`, from
   [Provide checked disjoint access](open-questions.md#provide-checked-disjoint-access).
   Without them, tasks cannot each take a mutable piece of one slice.
2. `parallel` and `spawn`: parser, the checker's hidden local, and lowering onto
   a thread-per-spawn runtime in [`core:thread`](standard-library.md#corethread).
3. Checks 5 to 8.
4. `Channel`, waiting on a `Mutex`, and `Pool`.
5. The allocator region rule, check 9.

Spawning a call directly also settles the thread worker named under
[What a capture literal's `call` cannot do](open-questions.md#what-a-capture-literals-call-cannot-do):
no callable has to outlive its scope.

Try it on the concrete programs open-questions names before deciding: a
sorting or partitioning algorithm, a parallel numeric kernel, and a worker pool
fed by a channel.

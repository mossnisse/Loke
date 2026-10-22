# Structured concurrency: a proposal

Status: **ready for implementation**. Every decision the first
implementation needs is settled here, and the
[implementation plan](#implementation-plan) says what each milestone changes.
Nothing here is accepted syntax or behavior yet: [design.md](design.md) and
[grammar.md](grammar.md) stay normative, and each milestone moves its part of
this text into them in the same commit as the compiler change, as
[AGENTS.md](AGENTS.md) requires. This answers
[Thread transfer needs a visible contract](open-questions.md#thread-transfer-needs-a-visible-contract)
and part of [Concurrency refinements](open-questions.md#concurrency-refinements).

This revision incorporates the
[pre-implementation review](open-questions.md#structured-concurrency-proposal-review-2026-10-22)
and the [follow-up review](open-questions.md#structured-concurrency-follow-up-review-2026-10-22),
and settles the thread-crossing and synchronization declarations they left
open, as [recorded](open-questions.md#structured-concurrency-implementation-readiness-2026-10-22)
with the questions that pass raised. The initial feature is lexical
fork/join with statically known spawned calls and results assigned to dead
outer locals. Channels, cancellation-aware
waiting, and pools follow as separate library additions under the contracts
below; [later extensions](#later-extensions) lists what stays undecided, none
of which blocks the first implementation.

## Contents

- [The idea](#the-idea)
- [Syntax](#syntax)
- [Rules from existing rules](#rules-from-existing-rules)
- [Failure and cleanup](#failure-and-cleanup)
- [Failure to start a task](#failure-to-start-a-task)
- [New checks](#new-checks)
- [Procedure summaries](#procedure-summaries)
- [What the checks buy](#what-the-checks-buy)
- [Lowering](#lowering)
- [Waiting for work](#waiting-for-work)
- [Rejected programs](#rejected-programs)
- [What it does not do](#what-it-does-not-do)
- [Later extensions](#later-extensions)
- [Implementation plan](#implementation-plan)

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
sort :: proc(xs: []mut int, depth := 0) {
	if (xs.len() <= 4096) { slice.sort(xs); return; }
	left, right := xs.split_at_mut(partition(xs));
	if (depth >= 6) {                     // at most 64 threads at once
		sort(left, depth + 1);
		sort(right, depth + 1);
		return;
	}
	parallel {
		spawn sort(left, depth + 1);
		sort(right, depth + 1);           // the parent takes the other half
	}
	// both halves are sorted here
}
```

The depth limit matters. Every ancestor waits at its join, so a size cutoff
alone would keep one thread alive per partition: tens of thousands for 10⁸
elements under the initial thread-per-spawn executor.

- `parallel { ... }` is a block. Leaving it by any path — its end, `return`,
  `break`, `continue`, `or_return`, or a panic unwinding through it — waits for
  every task it started.
- `spawn call;` evaluates the callee, receiver, and arguments on the parent,
  at the statement, in ordinary [evaluation order](design.md#evaluation-order).
  Borrows are taken and moves happen there. The prepared call becomes a task;
  the initial executor starts a new thread for it. Initially the spawned
  callee must resolve statically to a procedure or method, including a generic
  instance. Calls it makes in turn may be indirect; see
  [procedure summaries](#procedure-summaries).
- An argument for an ordinary `value: T` parameter is **copied into the task**
  when `T` copies without a `hook(copy)` and without allocating: scalars,
  enums, borrow carriers, and records and arrays of them. The task's parameter
  then lives in task storage, and only the borrows the value carries extend to
  the join. Ordinary calls borrow such a place for the call, which no program
  can tell apart from a copy; a task's call outlives the place, so the copy is
  the rule here. Thus `foreach (i in 0..<n) { spawn work(i, data); }` is
  accepted although `i` ends with each iteration. A managed owner, or a record
  holding one, is still borrowed until the join, as an ordinary call borrows it;
  it must then be an older root (rule 2). Move or clone it to give the task
  its own.
- `spawn result = call;` assigns the returned value to `result` on the worker.
  Initially `result` must name a dead lexical local declared outside the
  block. Fields, indices, destructuring, `_`, and replacement of a live value
  are not result destinations. The call must have one result, of exactly the
  local's declared type: no implicit conversion runs on the worker, and a
  multiple-result call has no destination. Its storage is reserved exclusively until
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
  [Waiting for work](#waiting-for-work). The initial implementation parses the
  header, so the syntax is reserved, and rejects it in the checker: it accepts
  only `parallel { ... }`. An executor is selected lexically, never inherited
  implicitly by a helper or nested block.
- `spawn` appears only lexically inside a `parallel` block of the same
  procedure: not in a helper it calls, and not in a capture literal's body,
  which is a procedure of its own. Nested blocks each join their own spawns.
  A `defer` or `errdefer` body may not contain `spawn`, as it may not contain
  `return`: a deferred spawn would start a task during cleanup, possibly while
  unwinding, where a failure to start one aborts.
- A `parallel` block cannot run during
  [compile-time evaluation](design.md#compile-time-procedure-evaluation): reaching one
  there is a compile-time evaluation error, as calling a foreign procedure is.
  Running its tasks serially is not a faithful substitute (see
  [What the checks buy](#what-the-checks-buy)).

Proposed grammar additions, using [grammar.md](grammar.md#expressions):

```text
Parallel_Statement = Attributes? "parallel" ("(" Expression ")")? Block
                     // the parenthesized executor is the later pool form
Spawn_Statement    = Attributes? "spawn" (Identifier "=")? Task_Call ";"
Task_Call          = Postfix_Expression
```

Both join `Statement`, and both words join the contextual-keyword table.

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

One existing form does change meaning. A
[composite literal](grammar.md#primary-expressions) of a type named
`parallel` that starts a statement, as in `parallel{...}.run();` or
`parallel(T){...}.run();`, would now parse as a `parallel` statement. Such a
statement must parenthesize the literal: `(parallel{...}).run();`. The
diagnostic for a `parallel` statement whose block is followed by `.` or `(`
should suggest that.

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
   a named view without another `&mut` at the call site. An argument copied
   into the task (see [Syntax](#syntax)) lends nothing of its own storage; only
   the borrows it carries extend to the join.
2. **Older roots only.** A task may borrow only storage that outlives the
   block. The hidden local is a use of every task loan at the join, and
   [the one rule](design.md#capabilities-and-the-one-rule) lets a borrow be
   used only while its root is live. A local declared inside the block is
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
   This is an inferred sharing check; omitting a user-written `Sync` interface
   does not remove it.

   Checked code cannot write through a read-only receiver except by an atomic
   operation, or by a cast through `unsafe` such as `Mutex`'s guard performs.
   The state tasks can change through a shared borrow is therefore the storage
   those operations reach, and its declaring package marks each field holding
   it **`@(synchronized)`**: `Atomic(T).value` and `Mutex(T).value` now, and
   the private state of `Channel` and `Stop_Source` when they are added.
   `Once` needs no mark, since its only field is a private `Atomic`.

   Outside the package that declares it, any access to a synchronized field —
   read, write, or borrow — requires exclusive access to the record holding
   it: an owner with no live loan, or a path through `^mut`, `[]mut`, or
   `inout`. Through a read-only borrow it is an error, with or without tasks,
   and while the owner is lent read-only, to a task or otherwise, a direct
   access through the owner is an error too. A synchronizing operation thus
   counts as a write against every plain access, reads included. Within one
   thread a plain read and an atomic operation are ordered, but across tasks
   they race:

   ```loke
   hits: sync.Atomic(int) = {};
   parallel {
       spawn count_into(&hits, xs);   // hits.add(1) through `^`
       fmt.println(hits.value);       // ERROR: `value` is synchronized, and `hits` is lent to a task
   }
   ```

   The declaring package's own code is trusted to synchronize its accesses, as
   `Guard.get` does under the lock; that is the `unsafe` boundary it already
   crosses. Taking a synchronized field's address only to convert it to
   `rawptr` is not an access either: `Mutex.lock` hands
   `rawptr(&self.word.value)` to the system lock from outside `core:sync`, and
   what a raw pointer does is the raw-pointer trust boundary. The rule
   enforces what both fields' documentation already says, that they serve a
   caller owning the value outright, and the compiler keys
   on the attribute rather than on the names `Atomic` and `Mutex`. It rejects
   a plain read through `^Atomic(T)` that compiles today, so the release that
   adds it needs an [upgrade note](releasing.md#upgrade-notes).
6. **Check global access, including stored aliases.** From the first spawn to
   the join, the block's [window](#the-summaries-the-checks-read), neither a
   spawned call's [write effect](design.md#global-write-effects) nor the
   block's own statements may write file-scope or `static` storage. This is
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
   while tasks are live as well as to every task. An atomic operation, and the
   declaring package's access to a `@(synchronized)` field, is not a write
   here, as under [Global write effects](design.md#global-write-effects) today;
   access to a mutex's payload must be through its guard. Other access to a
   synchronized field gets no exemption. A thread's own TLS may be mutated,
   but a carrier stored there must not hide unsynchronized access to shared
   storage. Apply the same carrier check to such access; TLS duration alone
   does not make its pointee local.

   Two consequences need stating. First, a `Once` action's own writes are not
   exempt: lazy setup of a file-scope value through `once.do(load)` writes that
   value, so a task that may run it is rejected. Initialize before the first
   spawn, or pass the value as an argument; a checked form is a
   [later extension](#later-extensions). Second, under thread-per-spawn a task's
   completion includes its thread's TLS destruction, so every task carries the
   effects of every managed `thread_local` drop in the program. One
   `thread_local` owner, in any package, whose drop hook writes a global
   rejects every `parallel` block. The diagnostic must name that declaration
   and its hook, not only the spawn.

   Calls through the build-selected
   [providers](design.md#build-selected-providers) are a stated trust boundary,
   not a global-carrier access. `core:log` dispatches through its file-scope
   `selected: Option(Logger)`, a `dyn mut` handle, which this check would
   otherwise reject in every task that logs. A provider is published before
   `main` and never replaced, and its thread safety is already the provider's
   responsibility; the standard logger serializes with a `Mutex`. This
   proposal makes that a requirement: a logging provider must accept
   concurrent records, and the default allocator provider must accept
   concurrent use (check 9). The compiler does not verify it. Whether
   selection should declare it is a [later extension](#later-extensions).

   The boundary is declared, not inferred from names. `@(synchronized)` on a
   file-scope or `static` variable says its package vouches for every access
   to it and through every carrier stored in it: the package's own accesses
   are not writes for this check, and access through its stored carriers is
   not a global-carrier access. Since no variable is
   [public](design.md#public), only the declaring package's code reaches one
   directly, and others reach it through what that package's procedures
   return, such as `log.current()`. `core:log` marks `selected`. The standard
   sink needs nothing: `standard_logger` already builds its view from a raw
   address so no global write is recorded. Allocator operations are governed by
   check 9, not by this one.
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
   any worker, so its region needs no reservation. A build may select a
   [default provider](design.md#build-selected-providers) built over an arena,
   which does not; selecting one is a trust-boundary violation the compiler
   does not detect (see check 6). `Arena` and `Scratch` must permit sequential
   use from different threads under the reservation above; a provider tied to
   its creating thread is thread-affine and cannot transfer even when
   exclusive. A provider with known identity but no cross-thread contract is
   rejected.

   An allocator received as a parameter is neither known nor unknown: its
   region is whatever each caller passes. Inside the receiving procedure it is
   a possibly non-concurrent region, so it is reserved by the first task that
   may use it, and a second task or the parent using it is rejected. A library
   therefore cannot hand one caller-supplied allocator to several tasks, even
   when every caller passes the default provider; that needs a concurrency
   contract on the parameter, a [later extension](#later-extensions). Unknown region
   provenance, from unchecked code, remains an explicit trust boundary and is
   not evidence of independence.
   Debug overlap checks in `Arena` and `Scratch` supplement these rules; they
   do not establish transfer permission or compile-time exclusion.

Checks 7 and 8 apply at channel transfers too. The same argument checks — 7, 8,
and the complete region rule — apply to `thread.spawn`, which keeps
`@(escape=static)`; any region reservation ends at its join. Stored values must
also meet the channel's stricter retention requirement below.

`thread.spawn`, `Channel.send`, and a pool's submission are ordinary library
procedures, so the checks key on a declaration rather than a list of names.
The parameter attribute **`@(cross_thread)`** marks an argument that crosses to
another thread:

- On a `move` parameter, which must also be `@(escape=static)`, it applies
  checks 7 to 9 to the argument at every call. Nothing shorter than the
  process can bound an unstructured thread, so a borrowed parameter cannot
  carry it; a pool's scoped submission will need its own rule.
- On a parameter of procedure type, it says the procedure runs on another
  thread. Its target's write effect then gets the existing warning
  (`L0707`), which `global_effects.odin` today raises only for
  `thread.spawn` by name. A procedure value cannot carry state, so checks 7
  to 9 have nothing more to inspect.
- On any other parameter, or on a foreign procedure's parameter, it is an
  error.

`thread.spawn_with` marks both `entry` and `arg`, and `spawn_plain` marks
`entry`. A user-written thread wrapper or executor that marks its parameters
is checked as `thread.spawn` is. A foreign or `unsafe` wrapper that omits the
attribute crosses threads unchecked, which is the raw-pointer trust boundary
again. Together with `@(synchronized)` under check 5, this settles the
declaration question the follow-up review left open: the compiler recognizes
no concurrency type or procedure by name.

Applying checks 7 to 9 to `thread.spawn` rejects programs that compile today:
a `thread_local` borrow, a thread-affine value, or an owner whose provider
has no cross-thread contract, moved into a thread. design.md currently leaves
those to the programmer. The release that enforces them is a breaking change
and needs an [upgrade note](releasing.md#upgrade-notes).

## Procedure summaries

The compiler needs sharing and transfer facts, global-access effects,
allocator-use effects, and result provenance. These are inferred checks, not
new user-written interfaces. They include transitive calls, callbacks,
implicit copy/drop hooks, and cleanup; a named entry is not sufficient if a
callback it invokes has unknown effects.

Two kinds of call need different treatment:

- **The spawned call itself.** Initially it must resolve statically, so its
  arguments' sharing and transfer facts and its result provenance come from
  one known declaration.
- **Calls the task makes in turn.** Effects of indirect calls are already
  defined. Under [Global write effects](design.md#global-write-effects), a call
  through a procedure value takes the union of the effects of every procedure
  of a compatible type, and a `dyn` call the union over every witness the
  program builds for that slot. The global-access, allocator-use, and TLS
  effects above use the same whole-program union. Without it no task could
  print (`core:fmt` reaches `format` methods through `any_view`), call
  `once.do(action)`, or pass a comparison procedure to `slice.sort_by`.

### The summaries the checks read

Each is a whole-program fact per procedure, settled to a fixed point over
recursion like the existing summaries, and taken through calls, callbacks,
hooks, and cleanup as [Global write effects](design.md#global-write-effects)
already does. Only the second and third are new.

| Summary | What it holds | Status |
| --- | --- | --- |
| Write effect | Globals a procedure may write, invalidate, or borrow mutably | Exists in `global_effects.odin` |
| Reach effect | Globals whose *stored carriers* a procedure dereferences, indexes, slices, calls, or dispatches through | New |
| Allocator-use effect | Regions on which a procedure may allocate, resize, free, reset, or destroy, per parameter or captured region | New; reset is the existing [`@(allocator_reset)`](design.md#allocator_reset) fact |
| Result contract | Root and region provenance of results and written-back arguments | Exists in `borrow.odin` |
| Transfer facts | Whether a value's type reaches a `thread_local` borrow, a thread-affine type, or an erased value of unknown eligibility | New, per type, not per procedure |

The reach effect gives a carrier loaded from global storage a provenance
origin naming that global, as `content_loans` does for loads through caller
storage, and records every access through a value of that origin, after
copies into locals and through helper arguments and results. During a block's
window, for each global reached by a task or by the parent, every carrier path
of the global's declared type must be read-only in the sense of check 5: no
`^mut`, `[]mut`, `dyn mut`, `&mut` capture, `dyn`, or `any_view`. A reached
`thread_local` global is held to the same rule. Raw pointers stored in globals
stay a trust boundary, and a `@(synchronized)` variable is exempt.

The **window** of a block is every program point inside it reachable from an
executed `spawn`, including its cleanup, up to the join. Statements before the
first `spawn` on every path are outside it, so a block may set up globals and
then spawn. The checks of 6 and 9 that apply "from spawn to join" use this
definition, computed on the `Prov_Diagnose` control-flow graph.

The union is conservative: one compatible procedure anywhere in the program
that writes a global puts that write in every such call's effect. Diagnostics
must name the procedure or witness that contributes the rejected effect.
Existing explicit trust boundaries for raw pointers, foreign contracts, and
unknown provenance still apply; a checked callee whose facts are missing is not
such an exemption.

Before accepting procedure values or erased callables as the spawned call,
preserve those facts through assignments, arguments, and public procedure
contracts. A caller must
check the advertised contract; changing a body cannot silently weaken it.
Erasure must preserve both transfer eligibility and effects, and missing facts
mean rejection. Extending callable support must not weaken any check above.

## What the checks buy

- **Checked race freedom within the structured task tree.** With all checks
  implemented, conflicting unsynchronized accesses through checked roots and
  known allocator regions are compile errors. Raw pointers, unknown provenance,
  foreign code, build-selected providers, and interference from unstructured
  threads remain trust boundaries. Foreign wrappers, allocator providers, and
  logging providers must honor their thread contracts, including declaring
  affinity where required. A join does not validate those contracts.
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

## Lowering

The runtime side is ordinary Loke in `core:thread`, as `thread.spawn` is
today; no new C runtime entry point is needed. The package gains a private
task scope that the compiler names through a registered lifecycle operation,
not by lookup from user code:

```text
Task_Scope :: move_only struct          // private to core:thread
Task_Scope.start(self: inout, run: proc(frame: rawptr), frame: rawptr)
                                        // reserves a slot, then creates the thread
hook(drop) on Task_Scope                // joins every started thread, in start order
```

- **The block.** Entering `parallel` initializes a hidden `Task_Scope` local
  with a zero value: no allocation until the first spawn. Its drop is the
  join, ordered by [rule 3](#rules-from-existing-rules) after the block's own
  cleanup. The scope's drop needs no flag: it is always initialized.
- **Each spawn site.** Checking a spawn synthesizes a frame record and a run
  procedure, much as [capture literals](design.md#capture-literals) lower to a
  record and a `call` method in `capture.odin`. The frame holds the prepared
  callee receiver, the arguments (copied, moved, or as borrows), the
  argument temporaries, and, for `spawn result = call`, a `^mut` to the
  result local. The run procedure performs the call, writes the result
  through that pointer with `unsafe.write`, since the local is dead, drops the
  frame's remaining contents, and frees the frame.
- **Registration.** `start` first grows the scope's thread list so the next
  append cannot fail; growth failure panics while the parent still owns the
  frame, whose contents the unwind then drops. It then creates the thread;
  creation failure takes the frame back, as `spawn_with` does today, and
  panics. Only then does it append the handle. This is the
  [ordering contract](#failure-to-start-a-task): either the task is owned and
  joined, or it never runs.
- **Result initialization.** A task that is registered completes unless the
  program ends, since a worker's panic terminates the program. So a result
  local is initialized after the join exactly when its spawn registered. The
  lifecycle analysis records that with the ordinary dynamic initialization
  flag, set by the parent right after `start` returns, and the enclosing
  scope drops the result through that flag on every exit, unwinding
  included. No runtime completion tracking is needed.
- **Frames.** A frame is allocated from the default allocator, which check 9
  already requires to accept concurrent use, and freed on the worker. A frame
  outlives the spawn statement, so spawns in a loop need no per-iteration
  stack slot.
- **Threads.** Each task runs through the existing `thread_main`, which
  attaches to the runtime's panic state and runs the thread's `thread_local`
  drops before exit. Waiting for the thread handle therefore orders TLS
  destruction before the join returns, as
  [What the checks buy](#what-the-checks-buy) requires.

Emission follows the [recorded operations](compiler-architecture.md#one-annotated-ast):
the checker records the synthesized frame type, run procedure, and scope
operations on the statement nodes, enrolls them as committed artifacts, and
`emit_llvm_stmt.odin` lowers the recorded operations without lookup.

## Waiting for work

These are later library additions in `core:sync` and `core:thread`, not
prerequisites for independent computations. No wait group or latch is needed
to join the block's tasks. Data-parallel work instead uses a compiler-known
`chunks_mut`, proposed here alongside `split_at_mut`:

```loke
shade_all :: proc(pixels: []mut Rgb, scene: ^Scene) {
	parallel {
		foreach (rows in pixels.chunks_mut(4096)) {
			spawn shade(rows, scene);      // `scene` is shared, so it must be read-only throughout
		}
	}
}
```

No rule before milestone 1 allowed this loop. A mutable traversal ends each
loan before the iterator advances
([By-reference iteration](design.md#by-reference-iteration)), and a mutable
reborrow suspends its source until its last use, but here every chunk stays
lent to a task until the join. `chunks_mut` is therefore a compiler-known
operation built like `split_at_mut`. Both are now in design.md, under
[Splitting a mutable slice](design.md#splitting-a-mutable-slice) and
[Chunks of a mutable slice](design.md#chunks-of-a-mutable-slice):

- `xs.chunks_mut(n)` on `[]mut T` takes one mutable reborrow of `xs`, and
  `xs` stays suspended while the view or any chunk is live.
- Each chunk is a reborrow of the view that does not suspend the view, so the
  loop advances while earlier chunks are held; through the view, each chunk
  keeps `xs` suspended. Chunks remain valid after the loop, as
  `split_at_mut`'s halves do.
- Chunks are disjoint by construction. A chunk binding is a fresh value on
  each step, so the analysis severs reborrows of the previous step's chunk
  when it binds the next one; within one step, a copy of the chunk suspends
  it as any reborrow does. No disjointness relation is tracked.
- `n` must be positive; a final chunk may be shorter. `n <= 0` panics.

A user-written iterator cannot provide this, for the reason a library
`split_at_mut` cannot (see
[Provide checked disjoint access](open-questions.md#provide-checked-disjoint-access)).

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

Helping makes the join act on the joining thread's TLS. Check 6 lets a task
write its own thread's TLS, and check 7 stops TLS borrows only from crossing
threads; neither covers a child that runs on its parent's thread while the
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

fan_out :: proc(allocator: Allocator) {
	parallel {
		spawn allocate_work(allocator);
		spawn allocate_work(allocator);  // ERROR: a received allocator may be a non-concurrent region
	}
}

config: Config;                          // file scope
config_once: sync.Once;
load_config :: proc() { config = read_config(); }
use_config :: proc() { config_once.do(load_config); run_with(&config); }
parallel { spawn use_config(); }         // ERROR: the `Once` action writes `config`

parallel {
	defer spawn flush();                 // ERROR: no `spawn` in a deferred statement
}

peek :: proc(hits: ^sync.Atomic(int)) -> int {
	return hits.value;                   // ERROR: `value` is synchronized; use `hits.load()`
}

submit :: proc(@(cross_thread) job: move Job) { ... }
                                         // ERROR: `@(cross_thread)` needs `@(escape=static)`
```

Here `allocate_work` allocates through its `Allocator` argument, and `work`
returns a fallible result. Moving an arena-backed owner into a worker does not
avoid the reservation: its eventual drop accesses that same allocator.

These are accepted:

```loke
parallel {
	foreach (i in 0..<n) {
		spawn work(i, data);             // `i` is copied into the task
	}
}

parallel {
	spawn work(0, data);
	log.info("started");                 // `log.selected` is `@(synchronized)`
}
```

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

## Later extensions

The initial spelling, thread-per-spawn default, panic-on-submission-failure
policy, join during parent unwinding, and the `@(synchronized)` and
`@(cross_thread)` declarations are decided here. These remain open, and none
blocks milestones 1 to 5 of the [implementation plan](#implementation-plan):

1. **Indirect call contracts.** How to encode and expose the
   [procedure summaries](#procedure-summaries) without losing facts through
   erasure, so the spawned call itself may be indirect. Until then it must
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
behavior. Milestones 1 to 3 are useful on their own and ship as they land.
Milestone 4 lands behind a gate; milestone 5 removes it. File names follow the
[source-code map](compiler-architecture.md#source-code-map).

### Milestone 1: disjoint slice access

**Done.** `split_at_mut` and `chunks_mut` are in design.md under
[Splitting a mutable slice](design.md#splitting-a-mutable-slice) and
[Chunks of a mutable slice](design.md#chunks-of-a-mutable-slice). The
implementation found and fixed a checker hole first: two mutable reborrows of
one carrier in one composite literal, `Pair{xs, xs}`, were accepted, which let
a library procedure return two overlapping mutable views.

- **Compiler:** both members and the `Chunks_Mut([]mut T)` view in
  `container.odin`; their bodies in `emit_llvm_containers.odin`; the
  receiver lent after the other arguments, per-field result summaries, and
  chunk bindings in `cfg_provenance.odin` and `cfg.odin`; severing of
  reborrows taken from a previous chunk in `borrow.odin`; compile-time
  `split_at_mut` in `eval.odin`.
- **Tests:** `split_at_mut` and `chunks_mut` in `tests/run`, `tests/err`, and
  `tests/trap`, and `composite_mutable_reborrow` in `tests/err`.
- **Fixed later:** chunks could not at first be collected in a container: a
  container operation's own read of its argument conflicted with the
  reborrow it stored, so any `[]mut T` appended to a container that was used
  afterwards was `L0641`. `tests/run/chunks_mut` now collects them.

### Milestone 2: thread declarations

**Done.** The three attributes are in design.md under
[Attribute reference](design.md#attribute-reference), and the checks at a
crossing argument under
[Concurrency and the memory model](design.md#concurrency-and-the-memory-model).
`@(cross_thread)` is part of the procedure type, as escape levels are, so a
call through a procedure value is checked too. The race warning skips a thread
wrapper's own forwarding by the wrapper's attribute, not by its package, and
the refusal to borrow a constant from read-only storage keys on a synchronized
field, where it used to recognize `Atomic` by name. The erased-eligibility
check accepts a view converted at the call.

- **Left for milestones 3 and 4:** an owner backed by a file-scope or `static`
  `mem.Arena` crosses unchecked, since region provenance names such a region
  as unknown; design.md lists it under
  [What is not checked](design.md#what-is-not-checked). The allocator-use
  effect and the reservation of check 9 close it.

The plan as written:

`@(synchronized)`, `@(cross_thread)`, and `@(thread_affine)`, applied to
`thread.spawn`. This makes today's unstructured threads safer before any new
syntax exists, and gives milestone 4 the facts it keys on.

- **Spec:** three entries under
  [Attribute reference](design.md#attribute-reference), and their categories
  under [Attribute categories](design.md#attribute-categories). In
  [Concurrency and the memory model](design.md#concurrency-and-the-memory-model),
  replace "Its plain `value` field keeps the ordinary rules" with the
  synchronized-field rule of check 5, and state checks 7 and 8 for crossing
  arguments. Key the warning in
  [Global write effects](design.md#global-write-effects) on `@(cross_thread)`.
  Narrow the thread bullets of [What is not checked](design.md#what-is-not-checked).
- **Compiler:** validation in `attributes.odin`; `thread_affine` propagation
  beside `move_only` in `hooks.odin`; the exclusive-access rule for
  synchronized fields at place access in `borrow.odin`; the `@(synchronized)`
  variable exemption and an attribute-keyed `note_thread_spawn` in
  `global_effects.odin`, removing its package-and-name test; transfer facts
  (TLS borrows, thread-affine reach, erased eligibility) per type, checked at
  each `@(cross_thread)` argument in `borrow.odin`. With `@(escape=static)`
  only process-lifetime regions can cross, so check 9 here reduces to
  rejecting a region whose provider has no cross-thread contract.
- **Library:** mark `sync.Atomic(T).value`, `thread.Mutex(T).value`, and
  `log.selected` `@(synchronized)`, and the parameters of `spawn_with` and
  `spawn_plain` `@(cross_thread)`. Regenerate `api.loki` for `core/sync`,
  `core/thread`, and `core/log` with `lokec <dir> -api`.
- **Tests:** in `tests/err`, a plain `value` read through `^Atomic(T)`, a
  `value` read while the atomic is lent, a TLS borrow moved into
  `thread.spawn`, a thread-affine payload nested in an owner, an erased value
  of unknown eligibility, and `@(cross_thread)` without `@(escape=static)` or
  on a foreign parameter. In `tests/run`, a user-written thread wrapper whose
  marked argument is accepted, with the existing `L0707` warning cases
  unchanged.
- **Changelog:** Breaking changes, with upgrade notes for the `value` read
  (call `load()`, or reach the atomic through `^mut`) and for the values
  `thread.spawn` now rejects.

### Milestone 3: the new summaries

**Done**, except the window. `compute_thread_summaries` in
`global_effects.odin` builds each body's graph once more after the result
summaries settle and records, per procedure, the reach effect
(`Compiler.reach_effects`) and the allocator-use effect
(`Compiler.allocator_uses`), and for the program the drops every thread runs at
exit (`Compiler.thread_exit_drops`), one per managed `thread_local` owner's
release and per hook. Each part keeps an `Effect_Source`: the body's own access,
or the call, witness target, or hook it came through, with any provenance
precision loss. Unit tests are in `src/thread_summaries_test.odin`.

- **Conservative where the plan left room:** handing a carrier with a global
  origin to any call, returning it, or storing it counts as reaching through
  it, rather than consulting per-parameter facts of the callee. A copy of an
  owner from a place counts as a possible clone from the default provider.
- **Unknown regions:** a static-duration provider, an allocator read from a
  global or a received record's field, a temporary provider's parent, and a
  `thread_local` owner's `via` allocator are an unknown region, as region
  provenance names them today. Check 9 can reserve them only as a whole.
- **Off unless wanted:** the pass costs one more graph per body, 10 to 20
  percent of front-end time in `perf.ps1`, and nothing reads the summaries yet,
  so it runs only when `Compiler.thread_summaries_wanted` is set. Milestone 4
  sets it for a program containing a `parallel` block.
- **Left for milestone 4:** the window needs the `parallel` statement, so it
  is computed with the hidden join local there.

The plan as written:

The reach effect, allocator-use effect, `thread_local` drop effects, and the
window, as defined under
[The summaries the checks read](#the-summaries-the-checks-read).

- **Compiler:** global-origin carrier provenance in `cfg_provenance.odin`;
  the reach effect and the program-wide set of managed `thread_local` drop
  effects in `global_effects.odin`; per-parameter allocator use, extending
  the region analysis that already carries `@(allocator_reset)`, in
  `borrow.odin`. Diagnostics name the contributing procedure, witness, or
  hook, through the existing notes in `precision.odin` where a merge is
  involved.
- **Tests:** unit tests in `src` for each summary over direct calls,
  recursion, procedure-value unions, `dyn` witnesses, hooks, and cleanup.
  Nothing user-visible consumes the summaries yet, so there is no changelog
  line.

### Milestone 4: `parallel` and `spawn`, gated

The statements, every rule and check above for statically resolved calls,
and thread-per-spawn lowering. A hidden `-unstable-parallel` option, not in
[compiler-guide.md](compiler-guide.md), enables the checker; without it a
`parallel` statement is an error saying the feature is not available yet.
The parser always accepts the syntax, so its decisions are tested from the
start.

- **Syntax:** `Stmt_Parallel` and `Stmt_Spawn` in `ast.odin`, with support in
  `ast_dump.odin`, `ast_clone.odin`, and `formatter.odin`; the contextual
  decisions under [Syntax](#syntax) at statement start in `parser.odin`, with
  recovery fixtures. The lexer is unchanged: both words stay identifiers.
- **Checking:** a new `parallel.odin` owns block and spawn checking: lexical
  placement, the `defer` ban, static callee resolution, the argument copy
  rule, result destination rules, and the executor header's rejection. It
  synthesizes each spawn's frame record and run procedure, as `capture.odin`
  does for capture literals, and records them on the statement.
- **Ownership:** the hidden join local and the window in `cfg.odin`; spawn
  loans lasting to the join, checks 5, 7, and 9, and result provenance in
  `borrow.odin`; result-local reservation and initialization at registration
  in `lifecycle.odin`; check 6's errors in `global_effects.odin`.
  Compile-time evaluation rejects a block in `eval.odin`.
- **Lowering:** `Task_Scope` in `core/thread/thread.loke`, as under
  [Lowering](#lowering); the recorded operations in `emit_llvm_stmt.odin`;
  the new records in `emission_contract.odin`.
- **Tools:** `parallel` and `spawn` in the language server's completion and
  semantic tokens, and in the VS Code grammar under `editors/vscode/syntaxes`.
- **Tests:** every program under [Rejected programs](#rejected-programs) in
  `tests/err`, with its accepted counterpart in `tests/run`; parse cases in
  `tests/syntax` and `tests/syntax_err`, including `parallel(pool);`,
  `spawn(callback);`, `object.spawn(args);`, and a parenthesized `parallel`
  literal. Also: an outer slice returned and its loan kept after the join;
  TLS, temporary-backed, and thread-affine results, including inside error
  payloads; races through global carriers and copied allocator handles;
  moved-owner drops, completed-result cleanup, parent cleanup, and shared
  parent allocators; conditional spawns and definite assignment; every early
  exit, including unwinding through the block; an enclosing `errdefer` on
  post-join propagation; a submission failure injected after a successful
  spawn; a multiple-result callee and a mismatched result type; a block in
  compile-time evaluation; and a `thread_local` drop hook writing a global,
  with the diagnostic naming the hook.
- **Changelog:** none while gated.

### Milestone 5: enable

Remove the gate once every test of milestone 4 passes and
`.\test-all.ps1 -Full` passes.

- **Spec:** move [Syntax](#syntax) through
  [Failure to start a task](#failure-to-start-a-task), the checks, and the
  happens-before edges into a new "Structured concurrency" section under
  [Concurrency and the memory model](design.md#concurrency-and-the-memory-model);
  the statements into [Statements](grammar.md#statements), both words into
  the contextual table under [Keywords](grammar.md#keywords), and the
  statement-start decisions into
  [Resolved ambiguities](grammar.md#resolved-ambiguities). The rationale for
  inferred checks over `Send` and `Sync`, and for lexical joins over handles,
  goes to [comments.md](comments.md).
- **Library and examples:** the `core:thread` section of
  [standard-library.md](standard-library.md#corethread); the sort and
  `parallel_sum` above as programs in `examples/`, run by the test suite.
- **Bookkeeping:** close the answered part of
  [Thread transfer needs a visible contract](open-questions.md#thread-transfer-needs-a-visible-contract),
  leaving the later extensions there; record any check that ships narrower
  than specified in [known-gaps.md](known-gaps.md) with a reproduction; and
  reduce this proposal to the milestones still ahead.
- **Changelog:** Added, and a breaking-change note for the statement-start
  `parallel` literal.

### Later milestones

6. Add `Stop_Source`, `Channel`, and mutex waiting together with the shutdown
   protocol, marking their state `@(synchronized)` and `Channel.send`'s item
   `@(cross_thread)`. Test stop-before-wait and stop-during-registration races,
   close racing with send, ownership of unsent items, draining after close,
   and all consumers failing while a producer is blocked. Verify that an
   operation reports success exactly when it committed and cleans up exactly
   once. Add the channel-fed worker pipeline to `examples/`.
7. Add `Pool` and the executor header. Test independent nested work with one
   worker, explicit recursive executor selection, TLS reuse, and pool lifetime.
   Reject a parent TLS borrow live across a pool join whose tasks write that
   storage. Check documented blocking limits with bounded test harnesses; do
   not make the suite depend on a deadlock resolving. Serial execution is not
   a correctness oracle for thread-dependent tasks.
8. Extend callable support only after summaries preserve every needed fact
   (later extension 1).

Once callable summaries are supported, scoped spawning can also accommodate
the thread worker named under
[What a capture literal's `call` cannot do](open-questions.md#what-a-capture-literals-call-cannot-do):
its callable need not outlive the joining scope. The first implementation
uses a named entry and explicit arguments instead.

The concrete programs open-questions names are part of the plan: the sort
and the numeric kernel become examples in milestone 5, and the worker pool fed
by a channel in milestone 6.

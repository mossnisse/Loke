# Loke standard library

Implemented for Windows x64. Other targets are planned; see
[More platforms](future-plans.md#more-platforms).

This is the library's API reference. Signature blocks are summaries: they may
omit generic constraints, parameter modes, or private fields. For exact
declarations, read the package's `api.loki`
(see [Interface files](compiler-guide.md#interface-files)) or its source.
Examples use Loke syntax; the API summaries use Odin-style declaration sketches.

| Task | Packages |
| --- | --- |
| Read, write, or enumerate files | [`core:fs`](#corefs), [`core:path`](#corepath) |
| Work with byte streams | [Shared I/O contract](#shared-io-contract) |
| Read lines or terminal keys | [`core:term`](#coreterm) |
| Format values or log messages | [`core:fmt`](#corefmt), [`core:log`](#corelog) |
| Search and build UTF-8 text | [`core:strings`](#corestrings) |
| Parse scalar values | [`core:strconv`](#corestrconv) |
| Read or write JSON | [`core:encoding/json`](#coreencodingjson) |
| Call foreign text APIs | [`core:cstrings`](#corecstrings), [`core:encoding/utf16`](#coreencodingutf16) |
| Store integers in a fixed byte order | [`core:endian`](#coreendian) |
| Access process state or start a child | [`core:os`](#coreos-additions), [`core:process`](#coreprocess) |
| Start threads, protect shared state, wait for it to change, pass work between tasks, with or without waiting, or run tasks on a pool | [`core:thread`](#corethread) |
| Use numeric functions and types | [`core:math`](#coremath) |
| Draw random numbers, shuffle, sample, or get secret bytes | [`core:random`](#corerandom) |
| Read clocks, work with dates, or print and parse ISO 8601 times | [`core:time`](#coretime) |

Start with the [design rules](#design-rules) for text, errors, and ownership.
The [package layout](#package-layout) lists the remaining foundational packages.
The [tutorials](tutorials/README.md) teach complete programs from first steps.

## Design rules

### Small packages and explicit imports

There is no implicit convenience prelude. Programs import the facilities they
use. Packages should be cohesive and should not become broad collections of
unrelated helpers.

`base:` is reserved for declarations that participate in the language or its
runtime ABI. General-purpose code belongs in `core:`. Adding a package to
`base:` should require a compiler or language-design reason.

### UTF-8 text, bytes for everything else

`string` and `string_view` always contain valid UTF-8. APIs handling arbitrary
file, network, or device data use `[]u8`, `[]mut u8`, or `[dynamic]u8`.

Text APIs validate at the byte-to-text boundary. They do not replace invalid
input silently. String indices and search results are byte offsets, including
`index_rune`; operations such as `prefix_runes` count Unicode scalar values.

Paths are accepted as UTF-8 `string_view`s. On Windows they are converted to
UTF-16 (through `core:encoding/utf16`) and passed to the wide operating-system
APIs. A native path that cannot be represented as valid Unicode is reported as
invalid data rather than being silently changed. A path containing U+0000 is
`Invalid_Path`, because the wide call would read it only up to the zero.

### Errors are values

Absence alone answers `Option(T)`. A failure with useful information answers
`Result(T, Error)`, whose failure variant carries the error value, so it
composes with `or_return`; an operation with nothing to return on success
answers `Status(Error)`. None is a trailing status: `nil` is not a failure and a
trailing `bool` is not one either.

The `try_` prefix keeps its existing meaning: it is the fallible version of an
operation that would otherwise apply an allocation or capacity failure policy.
Operations that are inherently fallible, such as `open`, `read`, and `remove`,
do not use a `try_` prefix.

Programmer errors may panic. Missing files, denied access, invalid input data,
end of input, and a disconnected terminal are ordinary returned errors.

### Ownership is visible

Owning handles and lock guards are move-only and release resources with `drop`.
Their explicit lifecycle operations depend on the resource:

| Resource | Zero value | Explicit operation | `drop` |
| --- | --- | --- | --- |
| `fs.File`, `process.Pipe` | Closed | Fallible `close` | Best-effort close |
| `term.Raw_Mode` | Inactive | Fallible `close` | Restore terminal mode |
| `thread.Thread` | Inactive | `join` | Join |
| `thread.Guard` | None | Release by leaving its scope | Unlock |
| `process.Child` | Inactive | `wait` or `kill` | Close handles without waiting or killing |

File and pipe `close` is idempotent and leaves the value closed even on error.
Raw-mode restoration has a separate failure contract; see [Raw mode and key
events](#raw-mode-and-key-events). `drop` cannot report an error.

Cleanup runs on scope exit, `return`, `break`, and `continue`. It runs during
panic unwinding only with the `unwind` strategy, and never after `os.exit`.
Terminal mode also needs a process-level restore path because it can outlive
the program.

Borrowed views never hide allocation. Procedures that return owning storage
accept an allocator when the caller may reasonably need to select one.

### No hidden process behavior

Importing a package performs no I/O, reads no environment state, starts no
thread, and changes no terminal mode. Standard handles are acquired by a call.
Raw terminal mode is represented by a scoped resource whose `drop` restores the
previous mode.

### Portable contract, platform-specific implementation

Windows x64 is the first implementation target. Public APIs should describe
portable behavior and use normalized error codes. Platform handles, native error
numbers, separators, and terminal records must not leak into otherwise portable
APIs.

Platform selection and compiler-supplied primitives are described in
[Runtime and library boundary](compiler-architecture.md#runtime-and-library-boundary).
Normal file and terminal operations are Loke code over foreign operating-system
calls.

## Package layout

This is a package index, not a dependency order. Imports must not form cycles.
Each package name corresponds to its source directory (`core:fs` is `core/fs/`).

```text
base:runtime          compiler/runtime ABI types
base:meta             compile-time descriptors
base:interfaces       structural interface catalogue

core:mem              allocators and regions                  *
core:unsafe           explicit trust boundary                 *
core:sync             atomics, fences, once, lazy values      *
core:simd             cross-lane SIMD operations              *
core:thread           threads, mutexes, monitors, channels, rings, and pools
core:fmt              value formatting and process diagnostics
core:strconv          scalar parsing
core:strings          UTF-8 algorithms and String_Builder
core:cstrings         owned zero-terminated buffers
core:encoding/utf16   UTF-8 to UTF-16 and back
core:encoding/json    JSON documents, values, and a streaming writer
core:endian           fixed byte-order storage wrappers
core:math             elementary functions, Complex, Quaternion
core:math/repro       correctly rounded elementary functions
core:math/linalg      fixed-size vectors, matrices, rotations, projections
core:random           seeded generators, entropy, distributions
core:time             clocks, durations, the calendar, ISO 8601 text
core:slice            slice algorithms and sorting            *
core:container        Small_Array, Bit_Set, Enum_Array        *
core:log              logging over the selected provider
core:io               byte stream protocols and the I/O error
core:path             lexical path operations
core:fs               files, directories, and file metadata
core:term             standard streams and terminal key input
core:os               arguments, exit, environment, process state
core:process          child processes and their pipes
```

A package marked `*` is specified by `design.md`, in the section its source
header comment cites; this document covers the unmarked packages.

Planned additions are in [Standard-library maturity](future-plans.md#standard-library-maturity).

Nested paths are taxonomy, not inheritance. For example,
`core:encoding/json` does not automatically import `core:encoding`.

### Files are in `core:fs`, not `core:os`

Use `fs.open` for files and `core:os` for process state. There is no `os.open`
alias. The package split is explained in
[Standard-library API choices](comments.md#standard-library-api-choices).

## Shared I/O contract

`core:io` owns the error type used by `io`, `fs`, `term`, and fallible process
I/O. It is not a universal application error type.

The declarations are:

```loke
Code :: enum {
	End_Of_Input,
	Unexpected_End,
	Not_Found,
	Permission_Denied,
	Already_Exists,
	Invalid_Path,
	Invalid_Data,
	Interrupted,
	Would_Block,
	Broken_Pipe,
	Not_A_Terminal,
	Closed,
	Directory_Not_Empty,
	Out_Of_Space,
	Out_Of_Memory,
	Limit_Exceeded,
	Unsupported,
	Other,
}

Operation :: enum {
	Read,
	Write,
	Open,
	Close,
	Flush,
	Seek,
	Read_Line,
	Read_To_End,
	Metadata,
	Remove,
	Remove_Directory,
	Rename,
	Create_Directory,
	Read_Directory,
	Terminal_Mode,
	Read_Key,
	Environment,
	Working_Directory,
	Executable_Path,
	Spawn,
	Wait,
	Kill,
	Other,
}

Error :: struct {
	@(private) code:        Code,
	@(private) native_code: u32,
	@(private) operation:   Operation,
}

make_error(code: Code, operation: Operation,
	native_code: u32 = 0) -> Error
from_native_code(native_code: u32, operation: Operation) -> Error
from_allocator_error(operation: Operation) -> Error
is(error: Error, code: Code) -> bool
code_of(error: Error) -> Code
operation_of(error: Error) -> Operation
native_code_of(error: Error) -> u32
```

`Error` owns scalar data; it neither borrows a path nor allocates to report a
failure. Use `code_of`, `operation_of`, and `native_code_of` to inspect it.
The constructors are public so callers can implement their own streams.

`native_code` is zero without a platform error. `from_native_code` maps Windows
system errors to normalized codes, preserving the native number; an unknown
number becomes `Other`. `core:term` maps `ERROR_INVALID_HANDLE` (6) to
`Not_A_Terminal`. `Closed` means a stream was closed before the call;
`Unsupported` means a live stream does not support the requested direction.

Fallible operations in `core:io`, `core:fs`, `core:term`, and `core:os` convert
allocation failures to `io.Error` with code `Out_Of_Memory`, destroying partial
owning results before returning `.err`. A failure payload is either
`Allocator_Error` or `io.Error`.

An allocator parameter selects storage for the returned data; it does not
necessarily select every temporary allocation. For example, `fs.open` and
`fs.metadata` have no allocator parameter and use the default allocator for
UTF-16 path conversion. Check each API's signature and allocation contract.

Streams are synchronous and blocking. `Reader` and `Writer` have `slot`
requirements, so they support dynamic interface views such as `dyn mut io.Writer`.

```loke
Reader :: interface($Self: type) {
	slot read: proc(self: inout Self, destination: []mut u8) -> Result(int, Error);
}

Writer :: interface($Self: type) {
	slot write: proc(self: inout Self, source: []u8) -> Result(int, Error);
}
```

The contracts are:

- a count is always between zero and the supplied slice length;
- an empty slice succeeds immediately with a zero count;
- a read reports `End_Of_Input` only when it produced no more bytes;
- an implementation that made progress reports the count and surfaces the
  failure on the *next* call, because a `Result` carries one or the other and
  progress must never be lost;
- a zero count with no error is permitted only for an empty slice;
- `write` may write only a prefix; `write_all` handles partial writes; and
- implementations retry an interrupted platform call where doing so is safe
  and no observable progress has occurred.

Core helpers:

```loke
Line_Options :: struct { keep_ending: bool }

copy(destination, source, buffer: []mut u8 = {}) -> Result(u64, Error)
read_exact(reader, destination) -> Status(Error)
read_to_end(reader, allocator: Allocator = mem.default_allocator(),
	limit: int = 0) -> Result([dynamic]u8, Error)
write_all(writer, source) -> Status(Error)
write_string(writer, text: string_view) -> Status(Error)
read_line(reader, allocator: Allocator = mem.default_allocator(),
	options: Line_Options = {}) -> Result(string, Error)
```

A `limit` of zero or less means no library-imposed limit. A positive limit
prevents an untrusted stream from causing unbounded allocation. An input that
would make the result exceed a positive limit returns `Limit_Exceeded`; the
partial owning result is destroyed and the call returns `.err`.
`read_line` removes `\n` and one
immediately preceding `\r` by default; `keep_ending` retains it. An unterminated
final line is returned successfully. End of input before any bytes returns
`End_Of_Input`.

There are no buffered wrappers yet. See [Standard-library maturity](future-plans.md#standard-library-maturity).

### Byte buffer

```loke
Buffer_Writer :: struct { /* private */ }
Buffer_Writer.init(allocator: Allocator = mem.default_allocator()) -> Buffer_Writer
Buffer_Writer.write(self: inout, source: []u8) -> Result(int, Error)
Buffer_Writer.bytes(self: ^) -> []u8
Buffer_Writer.len(self) -> int
Buffer_Writer.clear(self: inout)
Buffer_Writer.into_bytes(self: move) -> [dynamic]u8
```

`Buffer_Writer` is an owning, growable byte sink that satisfies `Writer`, for
output assembled in memory before it is published, such as a document passed
to `fs.replace_atomic`. A write appends all of its bytes or none: an allocation
failure is `Out_Of_Memory` with operation `Write`, and the buffer is unchanged.
`bytes` borrows the contents, so a write while that view is in use is rejected.
`clear` keeps the capacity for reuse, and `into_bytes` transfers the storage
without a copy. **The zero value is usable**: empty and allocator-unbound, its
first growth binding the default allocator; `init` selects another without
allocating.

### Formatting bridge

Use `io.write_formatted` for fallible output. A `fmt.Sink` cannot return an
error; the bridge stops writing after the first stream failure and returns that
error after formatting. `write_formatted_line` also appends a newline.

```loke
write_formatted(writer, args: ..any_view) -> Status(Error)
write_formatted_line(writer, args: ..any_view) -> Status(Error)
```

`fmt` formats into memory with:

```loke
to_string(allocator: Allocator, args: ..any_view) -> string
```

The allocator is a required leading parameter because the variadic consumes
the remaining arguments. For another sink, format in memory and call
`io.write_string`. To append formatted text to a builder, use
`builder.append(fmt.to_string(allocator, ...))`.

## `core:thread`

`core:thread` starts threads, guards what they share, lets one wait for
another to change it, carries work between them, and keeps workers for
`parallel (pool)` blocks. It supplies the thread start, join, and unlock edges
of design.md "Concurrency and the memory model".

For work that ends before its caller continues, a `parallel` block is usually
the better tool: its tasks may borrow the caller's locals, and the compiler
checks what they share (design.md "Structured concurrency"). The block starts
each task on a thread of its own, or on a [pool](#pools)'s workers, through a
private part of this package, so a program with a `parallel` block depends on
`core:thread` without importing it.
`spawn` below is for a thread that outlives the procedure starting it.

```loke
spawn(entry: proc(value: move T), arg: move T) -> Thread
spawn(entry: proc()) -> Thread
Thread.join(self: inout)
Mutex(T).lock(self: ^) -> Guard(T)
Guard(T).get(self: inout) -> inout T
Monitor(T).lock(self: ^) -> Monitor_Guard(T)
Monitor(T).lock_when(self: ^, ready: $C) -> Option(Monitor_Guard(T))
	where interfaces.Callable(C, proc(value: ^T) -> bool)
Monitor(T).close(self: ^)
Monitor_Guard(T).get(self: inout) -> inout T
Monitor_Guard(T).read(self: ^) -> ^T
Channel(T).init(capacity: int) -> Channel(T)
Channel(T).split(self: ^) -> (sender: Sender(T), receiver: Receiver(T))
Channel(T).close(self: ^)
Sender(T).fork(self: ^) -> Sender(T)
Receiver(T).fork(self: ^) -> Receiver(T)
Sender(T).send(self: ^, @(cross_thread, escape=static) value: move T) -> Status(Unsent(T))
Sender(T).try_send(self: ^, @(cross_thread, escape=static) value: move T) -> Status(Unsent(T))
Receiver(T).receive(self: ^) -> Option(T)
Receiver(T).try_receive(self: ^) -> Received(T)
Ring(T).init(capacity: int) -> Ring(T)
Ring(T).split(self: ^) -> (sender: Ring_Sender(T), receiver: Ring_Receiver(T))
Ring_Sender(T).try_send(self: inout, @(cross_thread, escape=static) value: move T) -> Status(Unsent(T))
Ring_Receiver(T).try_receive(self: inout) -> Received(T)
Pool.init(workers: int) -> Pool
processor_count() -> int
```

`spawn` runs `entry(arg)` on a new thread. The argument is moved in, and any
borrow it carries must be of process-lifetime storage, as
`@(escape=static)` requires, so a string literal travels and a slice of a local
does not. Several values travel as one record. Both parameters are
`@(cross_thread)`, so the argument is checked on its way: it may hold or reach
nothing `@(thread_affine)`, reach no `dyn` view the call did not make, and own
nothing backed by an allocator its caller received (design.md "Concurrency and
the memory model"). Running out of memory or of threads panics; there is no
`try_spawn` yet.

`join` waits for the thread to return: its writes and its `thread_local` drops
happen before `join` returns, and a second `join` does nothing. Dropping a
`Thread` that has not been joined joins it, so a thread never outlives its
handle. A panic on any thread ends the program (design.md "Threads").

`Mutex(T)` owns its `T`. Its zero value is unlocked and holds `T`'s zero, so a
mutex can live in file-scope storage with no initializer. `lock` blocks until
this thread holds the lock and returns a guard; `guard.get()` is the value, as
an `inout` result that borrows the guard, and dropping the guard unlocks. An
unlock happens before the next lock. `lock` takes a read-only receiver, as the
`Atomic` operations do, so a mutex behind a `Shared(T)` handle or in file-scope
storage still locks. The field `value` is public for a caller that owns the
mutex outright, before spawning or after joining. It is `@(synchronized)`, as
`Atomic`'s `value` is: it is reached only through the owner or through `^mut`
or `inout`, and not while the mutex is lent (design.md "@(synchronized)").
Locking a mutex the thread already holds never returns. `Mutex` is move-only.
A `Guard` is `@(thread_affine)`: the lock is released by the thread that took
it, as an SRWLOCK requires, so a guard does not move, or lend its borrow, to
another thread or task (design.md "@(thread_affine)"). It is also
`@(wakes_on_drop)`: a guard the parent keeps past a `parallel` block's join
while a task of the block borrows its mutex is an error
(design.md "Releasing before the join").

`processor_count` is how many threads can run at once: the machine's logical
processors, at least one. A program that divides work among threads, such as a
test harness running a case per thread, sizes its pool by it.

The compiler warns when a spawned entry writes file-scope or `static` storage
(design.md "Global write effects"). Storage behind a `Mutex`, a `Monitor`, or an `Atomic`,
`thread_local` storage, and a `@(synchronized)` variable do not count. A wrapper
whose own parameters are `@(cross_thread)` is checked and warned about as
`spawn` is. A task of a `parallel` block that writes such storage is an error
instead (design.md "Globals while tasks run").

### Monitors

`Monitor(T)` is a mutex whose holder can wait for the guarded value to reach a
state: a worker waiting for a job, a render loop waiting to be unpaused. As
`Mutex(T)` does, it owns its `T`; its zero value is unlocked and open and holds
`T`'s zero; its operations take a read-only receiver, so it works in file-scope
storage and behind a `Shared(T)`; its `value` field is `@(synchronized)`; and
it is move-only. `lock`, and `get` on its guard, work as `Mutex`'s do. A
`Mutex` stays the choice where no one waits for a state, since it keeps no
wakeup bookkeeping. A `Monitor_Guard` is `@(thread_affine)`, as a `Guard` is,
and so is the `Option` `lock_when` returns.

- `lock_when` locks and calls `ready` with the lock held. While `ready`
  answers `false` and the monitor is open, the thread releases the lock and
  sleeps in one step, then relocks and asks again when woken. Once `ready`
  answers `true`, it returns the guard still holding the lock, so the state
  `ready` saw is the state the guard reaches. Spurious wakeups only repeat the
  question.
- A guard on which `get` was called is marked **changed**, even if the caller
  makes no change. Dropping a changed guard wakes every thread sleeping in
  `lock_when` on that monitor, so a change made under the lock happens before
  every waiter's next question, and none is missed when the obligations below
  are kept. `read` answers the value read-only and leaves the guard unchanged;
  dropping a guard used only through `read` wakes no one.
- `close` is idempotent and wakes every waiter. From then on, a `lock_when`
  whose `ready` answers `false` returns `.none` instead of sleeping; one whose
  `ready` answers `true` still returns its guard, so a closed monitor can be
  drained. `lock`, `get`, and `read` keep working, so cleanup can read what the
  protocol left. `close` acquires the monitor's lock; calling it while holding
  that lock never returns. Closing does not stop a loop whose condition stays
  true, so that loop must also follow its termination protocol.
- There is no wait on a guard already held. A waiter that changes the value
  drops its guard and then calls `lock_when`, whose first question sees any
  change made in between. The only release is a guard's drop, which ends every
  borrow `get` and `read` handed out, so no borrow of the value survives the
  lock.

`ready` runs on the waiting thread with the lock held. It must answer the same
for unchanged state, must not block, and must not change state or perform
externally visible actions. It may use immutable captures. Every mutable
dependency of its answer must be guarded by this monitor and changed through a
guard on which `get` has been called. Reading an independently updated atomic
or the current time does not arrange a wakeup, and neither does updating an
atomic nested in `T` through `read`: either may leave a waiter asleep. These
are the caller's obligations, not a purity effect the compiler checks. The
ordinary checks on a callable argument still apply; they do not prove this
protocol. A panic out of `ready` unwinds through `lock_when`, whose guard's
drop releases the lock.

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

stop_render :: proc(transport: ^thread.Monitor(Transport)) {
	{
		state := transport.lock();
		state.get().stopping = true;
	}
	transport.close();   // the guard has already released the lock
}
```

A structured block keeps the monitor alive until its tasks finish, but the
application's protocol must let them finish: dropping a borrow of the monitor
does not close it, and a guard's drop does not say that no one will change its
state again. The controller arranges termination before starting a waiter. For
a controller running in the parent, the scope has this shape (the application
supplies `user_controls` and `render_block`):

```loke
transport: thread.Monitor(Transport) = {};
parallel {
	defer stop_render(&transport);
	spawn render_loop(&transport);
	user_controls(&transport);   // termination cleanup runs before join on every exit
}
```

The helper sets `stopping` as well as closing: closure alone only ends waits
whose condition is false, and a playing loop's condition is already true. A
controller running as another task needs its own termination cleanup when it
must stop peers before the parent exits. A monitor makes no fairness or
bounded-wakeup-latency guarantee. On Windows the lock is an SRWLOCK, as
`Mutex`'s is, and the sleep a condition variable over it.

### Channels

`Channel(T)` is a bounded queue between tasks, written over `Monitor`. It is
move-only, owns its queued items, and has no zero value. `init` takes the
capacity, which must be positive: a smaller one panics. The queue's slots come
from the default allocator, which accepts concurrent use. A task reaches a
channel through an **endpoint** that borrows it: a `Sender(T)` sends and a
`Receiver(T)` receives.

```loke
Unsent   :: union($T: type) { closed: T, full: T }
Received :: union($T: type) { item: T, empty, closed }
```

The endpoints have no zero value and are move-only: a move transfers one, and
there is no implicit copy or generated `clone`. `fork` makes another endpoint
of the same side, counting it without allocating. Its result borrows the
channel, not the endpoint it was forked from, so it can outlive that one.
Endpoints may be shared through read-only borrows: queue operations take the
channel's lock. Both endpoints are
[`@(wakes_on_drop)`](design.md#wakes_on_drop), as `Guard` and `Monitor_Guard`
are.

`split` makes the first sender and receiver together, under the lock, so no
task holds an endpoint while the other side has never had one. Calling `split`
again, or after `close`, panics. The lifecycle:

| Event | Sending side | Receiving side | Queue and waiters |
| --- | --- | --- | --- |
| `init` | not established | not established | empty; no endpoint operations possible |
| first `split` | open, one sender | open, one receiver | both endpoints owned together |
| `fork` | one more sender, if a sender | one more receiver, if a receiver | no change to closure or items |
| last sender drops | closed for good | unchanged | wakes receivers, which drain the committed items and then see the end |
| last receiver drops | unchanged | closed for good | wakes senders; every later send fails |
| `close` | closed for good | closed for good | wakes every waiter; sends fail, and receivers still drain |
| channel drops | no endpoints remain | no endpoints remain | drops the remaining items and frees the queue |

A closed side never reopens. Forking an endpoint after `close` is allowed and
makes another closed endpoint. Count updates, closure, and queue operations
share the lock; a count that would overflow panics first. `close` before
`split` is allowed and prevents splitting for good. Moves do not change counts.

- `send` waits while the queue is full and both sides are open. On success the
  queue owns the item; on failure `Unsent(T)` owns it, and dropping the error
  drops the item, so no failure loses it. `try_send` never waits for room, and
  returns an item sent to a full, open queue as `.full`. Closure takes
  precedence: if either side has closed, the result is `.closed`. `send` never
  returns `.full`.
- `receive` waits while the queue is empty and the sending side is open, then
  takes one item; `.none` is the end of the stream. `try_receive` never waits
  for an item: `.empty` means more may come. Both `try_` operations still take
  the lock.
- Items arrive in the order their sends committed, each at one receiver only:
  several receivers share the work, not copies. Sequential sends keep their
  order. Concurrent sends are ordered only as they commit, and neither waiters
  nor the lock make a fairness or bounded-latency guarantee.
- A send racing `close` either commits first, and its item is then received or
  dropped with the channel, or returns its item. Receivers report the end only
  once the queue is empty and the sending side has closed, so items committed
  before closure can be drained.
- `Receiver(T)` is iterable: `foreach (job in jobs)` receives until the stream
  ends. The iterator borrows the receiver, so the receiving side stays open
  while it can receive.
- Dropping an endpoint or closing does not drop queued items. Dropping the
  channel drops the rest on the thread that drops it. An unsent item is dropped
  by whoever drops its error, and a received one by the receiver. Every
  endpoint borrows the channel, so the borrow checks end them before it.

Split inside the `parallel` block, before any participant is started: an
early exit then drops every endpoint not yet moved to a task, and the
[join check](design.md#releasing-before-the-join) rejects an endpoint kept
past the join while a task borrows its channel. For several workers, keep a
receiver only while setting up, fork the workers' endpoints from it, and drop
it before the parent starts sending:

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
procedure handles `Unsent(Job)`. With no workers, dropping `receive` closes
its side and the first send fails. A worker returning during setup cannot
close the side while the setup receiver remains; once setup ends, the failure
of every worker wakes a blocked sender. A spare receiver held during blocking
sends can still deadlock even if it drops before the join: the join check does
not prove that the parent's body makes progress. `examples/channels.loke`
builds this pipeline.

An item carries no borrow of storage shorter than the process
(`@(escape=static)`, as `spawn`'s argument does), and both send operations
mark it `@(cross_thread)`, so it is checked as an argument crossing to another
thread is: no `thread_local` borrow, nothing thread-affine, and no owner backed
by an allocator the sending procedure received. Shared borrowed data reaches
workers through spawn arguments; a channel carries indices or owned jobs.
The queue's lock does not make an item's allocator thread-safe.

### Rings

`Ring(T)` is a bounded queue from one sender to one receiver for a thread that
must not wait, such as an audio loop taking commands once per buffer. Its
operations poll: `try_send` and `try_receive` never wait, take no lock, and
allocate nothing. It is move-only, owns its queued items, and has no zero
value. `init` takes the capacity, which must be positive: a smaller one, or
one too large to allocate, panics. It allocates one slot more than the
capacity from the default allocator, which accepts concurrent use.

```loke
commands := thread.Ring(Command).init(64);
parallel {
	send, receive := commands.split();
	spawn audio_loop(&mut device, move(receive));
	user_interface(move(send));   // drops the sender on return
}
```

The audio loop polls once per buffer and moves on whatever it finds:

```loke
switch (receive.try_receive()) {
case .item(command): apply(command);
case .empty:                    // nothing new this period
case .closed: return;           // the interface has gone
}
```

- **One sender and one receiver.** `split` makes the only pair, and splitting
  again panics. Both borrow the ring, which therefore cannot move or drop
  while either lives. There is no `fork`, and each operation needs its
  endpoint `inout`, so two tasks never operate on one endpoint at once; an
  endpoint moves from task to task in sequence, as any owner does. It is not
  thread-affine.
- **Results.** `try_send` and `try_receive` answer as a channel's do, with
  `Unsent(T)` and `Received(T)`: `.full` hands an item back from a full ring,
  `.empty` means more may come, and `.closed` that a side has closed, which
  takes precedence over fullness once a send observes it.
- **Closure.** Dropping the sender closes the sending side: the receiver
  drains what is queued, then sees `.closed`. Dropping the receiver closes the
  receiving side: later sends hand their items back as `.closed`. A send racing
  that drop commits its item or hands it back. Nothing wakes, since nothing
  waits, but a task polling until a side closes waits for the drop all the
  same, so both endpoints are [`@(wakes_on_drop)`](design.md#wakes_on_drop)
  and the join check covers them. There is no `close`: a polling loop that must
  stop sooner checks a flag of its own.
- **Ownership.** The ring owns an item from a committing send until the
  receive that takes it; dropping the ring drops the items still queued, in
  queue order, and an item's drop that panics leaves the rest to drop in that
  order as the unwind goes on. An endpoint's drop leaves them in place. An
  item is checked as a channel's is: it carries no borrow shorter than the
  process, and it crosses threads. A receiver that must not free memory takes non-owning
  items, or returns owned buffers through a second ring for reuse.
- **Bounds.** Each operation runs a fixed number of steps: at most three
  atomic loads and one atomic store, and no loop. That bounds the ring's own
  work, not its time: preemption, page faults, and cache misses are outside
  it, and so is dropping a returned item. It is not a real-time guarantee.

A committing send happens before the receive that takes its item, and an
endpoint's drop happens before its peer observes the side closed
(design.md "Concurrency and the memory model"). [The ring algorithm](#the-ring-algorithm)
gives the algorithm and why it meets these.

#### The ring algorithm

Built in `core/thread/ring.loke`. It is a single-producer/single-consumer
ring with one spare slot, bounded indices, a cached copy of the other side's
index in each endpoint, and closure as two flags. This replaced the earlier
design's power-of-two storage and machine-word position counters;
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
separation distance, not a universal 64-byte assumption: 128 on x86-64,
which fetches lines in adjacent pairs, and 128 again on Arm64 should it become
a target, since some Arm64 cores have 128-byte lines. Padding by that distance
keeps `tail`, `head`, and the flag group on disjoint cache lines whatever the
ring's own alignment. The gaps also separate these groups from adjacent
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

Validation:

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
3. **A concrete application.** The audio loop in `examples/mixer.loke`
   polls a ring for its commands. A foreign audio callback cannot hold an
   endpoint, since endpoints borrow the ring
   ([unscoped channels](open-questions.md#later-concurrency-extensions)).
4. **Target validation and measurement.** In the emitted LLVM IR, the
   operations' loads and stores are `load atomic` acquire and `store atomic`
   release on naturally aligned fields, which x86-64 lowers to single
   instructions, and they call nothing that locks or allocates.
   `tests/pkg/ring_allocation` fills its default allocator, a fixed arena,
   until it refuses a byte, then runs a million operations, closure by either
   endpoint, and the ring's drop; an allocation seeded into either operation
   panics there. No latency or throughput has been measured on a target;
   the spare slot is a simplicity choice, not an established speed
   improvement, and measurements would not establish a hard real-time
   bound.

The points this leaves for review are in
[open-questions.md](open-questions.md#ring-algorithm-validation).

The item checks, FIFO ordering, and result variants match the channel, but
changing a channel to a ring also requires exclusive endpoint access and a
polling protocol. A future blocking adapter must specify its waiter
registration and recheck handshake and test wake/close races before it is
added; a kernel wake on the real-time side would need a separate timing claim.

### Shutdown

Shutdown is a protocol over the objects the tasks use:

| Event | Mechanism | Effect and limit |
| --- | --- | --- |
| A channel participant returns | its owned endpoints drop on its thread | dropping the last endpoint on a side wakes its peers; other endpoints keep that side open |
| The parent leaves the block | its locals and defers run before the join | block-local endpoints drop, and installed monitor cleanup runs |
| A monitor's controller ends | an explicit termination state or `close` | a guard's drop alone does not end a wait; a true condition still proceeds after `close` |
| A channel is cancelled | `Channel.close` | sends fail and receivers drain; a task blocked elsewhere is unaffected |
| A ring endpoint drops | its owner returns or drops it | the peer sees `.closed`: a receiver once it has drained, a sender at once; nothing waits, so nothing wakes |
| A polling loop is cancelled | a flag it checks, such as an `Atomic(bool)` | the loop must check it and act |

The parent handles the tasks' results after the join, in the order it
chooses (design.md "Task failure and cleanup"). A receiver cannot tell a side
closed by a producer's failure from one closed by its completion; the parent
can, from the producer's result, and a protocol that must tell them apart
sends a final item. Closing a channel ends a stream; it is not an error result
or the cancellation of a group of tasks. For a group spanning several objects,
the application closes or changes each one whose wait must end. A task's
failure does not stop its siblings. A foreign blocking call, such as a device
wait or a terminal read, a lock-order cycle, and a protocol whose live tasks
all wait on each other are ended by none of this, and no join promises bounded
shutdown for them.

### Pools

`Pool` is a fixed set of persistent worker threads that run the tasks of the
`parallel (&pool)` blocks naming it (design.md "Parallel blocks"). A loop that
opens a block for every round of work, as an audio mixer does once per buffer,
then starts no thread per spawn. Its tasks still borrow that round's inputs
and outputs, and after the join the parent has all of them back:

```loke
pool := thread.Pool.init(thread.processor_count());
foreach (_ in 0..<frames) {
	all := &mut particles[:];
	parallel (&pool) {
		foreach (group in all.chunks_mut(256)) { spawn step(group); }
	}
	draw(particles[:]);
}
```

`init` starts `workers` threads, which wait for tasks until the pool drops.
Fewer than one worker panics, as does failing to start a thread. The pool is
move-only and has no zero value. A block borrows it read-only from its entry
to its join, so a pool cannot be dropped, moved, or lent mutably while a block
uses it, and tasks may borrow it to open blocks of their own. Dropping it lets
the workers finish and joins them; their `thread_local` drops happen then, and
before the drop returns.

- **Helping.** Tasks queue in the order they are spawned, and an idle worker
  takes the oldest. A worker of the pool that joins a block of that pool runs,
  while it waits, the oldest queued task of that block, or of a block that one
  of those tasks opened on the same pool, at any depth. It runs no sibling of
  the task it is running and no unrelated block's task. A joining thread that
  is not a worker of the block's pool only waits. So finite, independent
  nested fork/join work finishes even with one worker. A task may run on the
  thread that spawned it while that thread joins: a pool promises no fresh
  thread or distinct thread identity.
- **Thread-local storage.** A worker keeps its `thread_local` storage from one
  task to the next; neither nesting nor joining resets it. A helping join runs
  tasks on the joining thread, so it writes the `thread_local` storage they
  write, which design.md "Parallel blocks" checks.
- **Lexical selection.** Each block names its own executor: a bare `parallel`
  inside a pool task starts threads of its own. A recursive algorithm passes
  the pool and names it in every block.
- **Ordering.** Spawning a task happens before it runs, and its return,
  including its argument cleanup and result, happens before its block's join
  completes, through the pool's lock.

Helping at joins does not make up for other waits. With one worker, a task
waiting for an item from a queued sibling waits forever: the sibling runs only
once the waiter returns. A lock a child needs, taken inside a task and held
across a nested join, deadlocks the same way, though one declared before the
block is rejected (design.md "Releasing before the join"). Waits across pools
have no progress guarantee, and closing what a task waits on does not by
itself free a worker another wait holds. A pool is for independent compute
work; it does not compensate for blocking.

## `core:fmt`

```loke
Sink :: interface($Self: type) {
	slot write: proc(self: inout Self, bytes: []u8);
}
Writer :: dyn mut Sink;
Options :: struct { base: int, uppercase: bool }
DEFAULT_OPTIONS :: Options{10, false};

Formattable :: interface($Self: type) {
	slot format: proc(self: ^, writer: Writer, options: Options);
}

print(args: ..any_view)
println(args: ..any_view)
eprint(args: ..any_view)
eprintln(args: ..any_view)
stdout() -> Writer
stderr() -> Writer
format_to(w: Writer, args: ..any_view)
concat_to(w: Writer, args: ..any_view)
format_to_with(w: Writer, options: Options, args: ..any_view)
to_string(allocator: Allocator, args: ..any_view) -> string

Fixed :: struct { /* private */ }
Padded :: struct($T: type) { /* private */ }
fixed(value: f64, digits: int) -> Fixed
pad_left(value: $T, width: int) -> Padded(T)
pad_right(value: $T, width: int) -> Padded(T)
zero_pad(value: $T, width: int) -> Padded(T) where interfaces.Integral(T), T != rune

Backend_Error :: enum { Out_Of_Memory, Unavailable }
FLOAT_SPELLING_MAX :: 32
try_spell_f64(value: f64, destination: ^mut [FLOAT_SPELLING_MAX]u8)
	-> Result(int, Backend_Error)
```

A `Writer` borrows its sink: any record with a `write(self: inout, bytes:
[]u8)` becomes one with `(fmt.Writer)(&mut sink)`, and the process streams are
`stdout()` and `stderr()`. A `Writer` always names a sink.

`Formattable` describes a value's printed representation. Declare an inherent
`format(self, writer: fmt.Writer, options: fmt.Options)` method, or use
`self: ^` to make the borrow explicit. The compiler supplies defaults for other
printable runtime types, so both custom methods and defaults satisfy
`fmt.Formattable(T)`. A `(dyn fmt.Formattable)(&value)` view borrows the value
and exposes the same slot that printing calls. Formatting does not copy or
consume the receiver, including a move-only value.

The variadic procedures retain `..any_view` so callers can mix types and forward
arguments. Internally each erased value becomes a `dyn Formattable` view and
is formatted through its slot. Extensions in
other packages do not change a type's printed representation.

`println` and `eprintln` append a newline; `print` and `eprint` do not.
Arguments are separated by one space, except by `concat_to`, which writes them
back to back for a `format` method or a line whose punctuation is its own.
`Options.base` is 2 to 36 and any other
value reads as 10; it and `uppercase` reach integers and whatever a type's
`format` passes them to. A float prints the shortest spelling that reads back
as the same value at its own width. Floats always print with a `.` point,
whatever numeric locale foreign code has set for the C library; if the C
library cannot create its "C" numeric locale for this, printing a float panics.
design.md "String format printing" gives
every generated form, including floats and the quoting of strings inside
aggregates.

`try_spell_f64` writes the bytes printing would write for an `f64`, `nan`,
`inf`, and `-inf` included, to the start of a caller's fixed buffer and
answers their count. It neither allocates nor writes through a sink, and it
reports the numeric locale failure as a `Backend_Error` instead of panicking:
`Out_Of_Memory` when creating the locale failed to allocate, `Unavailable`
otherwise. A writer that must report every failure, such as
[`core:encoding/json`'s](#writing), spells floats with it.

Width and precision belong to one value, not to a call, so they are spelled
by wrapping it: nothing nested and no type's own `format` has to interpret
them. `fixed(value, digits)` prints a float with exactly `digits` fractional
digits, 0 to 40 with anything outside reading as the nearer end, rounded to
nearest with ties to even: `fixed(3.14159, 2)` is `3.14` and `fixed(2.5, 0)`
is `2`. NaN and the infinities print as a plain float does.
`pad_left(value, width)` prints the value after enough spaces to fill `width`
runes, so a column lines up on the right, and `pad_right` puts the spaces
after it; a longer value prints whole. Width counts runes, not display
columns. `zero_pad(value, width)` fills an integer with zeros between its sign
and its digits instead: `zero_pad(7, 3)` is `007`, `zero_pad(-7, 3)` is `-07`,
and the sign counts toward `width`. A leading `+` from a type's own `format`
is a sign too. A `rune` is rejected, since it prints as its character; pad
`int(r)` for its code point. Padding formats the value twice, once to
measure it. Each wrapper holds its value as a returned `value` parameter does
(design.md "Parameter semantics and ABI lowering"), so pad a view of a
container rather than the container. They nest, as in
`pad_left(fixed(x, 1), 8)`, and the call's `Options` reach the wrapped value.

## `core:strings`

The built-in string already owns UTF-8 validation, byte/rune counts, immutable
bytes, comparisons, slicing, concatenation, rune iteration, and conversions.
`core:strings` adds algorithms and efficient construction and does not duplicate
those primitives.

### Non-allocating queries

All returned indices are byte offsets:

```loke
contains(text, needle: string_view) -> bool
starts_with(text, prefix: string_view) -> bool
ends_with(text, suffix: string_view) -> bool
index(text, needle: string_view) -> Option(int)
last_index(text, needle: string_view) -> Option(int)
index_byte(text: string_view, value: u8) -> Option(int)
index_rune(text: string_view, value: rune) -> Option(int)
count(text, needle: string_view) -> int
is_space(value: rune) -> bool
```

An empty needle matches at byte offset zero; `last_index` answers
`.some(text.len())` for it, and `count` returns `text.len() + 1`. `count` counts
non-overlapping occurrences. `is_space` is the whitespace test `trim_space` and
`fields` use: Unicode White_Space, not only the five ASCII spaces.

### Borrowing transformations and iterators

These do not allocate and return `string_view`s borrowing the input:

```loke
trim_space(text) -> string_view
trim_left_space(text) -> string_view
trim_right_space(text) -> string_view
trim(text, cutset: string_view) -> string_view
Cut :: struct { before: string_view, after: string_view }
cut(text, separator: string_view) -> Option(Cut)
split(text, separator: string_view) -> Split_Iterator
fields(text) -> Fields_Iterator
lines(text) -> Lines_Iterator
```

Whitespace in `trim_space` and `fields` is Unicode White_Space (25 code points).
Matching a non-empty valid UTF-8 needle or a rune gives a code-point boundary.
`index_byte` matches an arbitrary byte and can point inside a code point; use
the [boundary helpers](#boundaries) before slicing at its result. An empty
needle also requires care: `count` counts every byte position, not runes.

`split` yields every part between separators, so a trailing separator yields a
final empty part; an empty separator yields the whole text once.
`lines` recognizes `\n`, `\r\n`, and a final unterminated line. General Unicode
normalization, locale rules, grapheme segmentation, and case folding belong in
a later `core:unicode` package.

### Boundaries

Slicing inside a code point panics. Validate offsets obtained from raw byte
searches or outside input, or round them to a code-point boundary:

```loke
try_slice(text: string_view, low, high: int) -> Option(string_view)
floor_boundary(text: string_view, offset: int) -> int
ceil_boundary(text: string_view, offset: int) -> int
prefix_runes(text: string_view, limit: int) -> string_view
```

`try_slice` is `text[low:high]`, or `.none` wherever that slice would panic: a
bound out of range, `low` after `high`, or a bound inside a code point.
`floor_boundary` and `ceil_boundary` answer the nearest boundary at or before,
and at or after, `offset`; past the end they answer `text.len()`, and a
negative offset panics. `text[:floor_boundary(text, n)]` is the longest prefix
of at most `n` bytes. `prefix_runes` is the first `limit` scalar values, or the
whole text when it has fewer.

For example, `strings.index_byte("é", 0xA9)` returns `.some(1)`, but
`strings.try_slice("é", 0, 1)` returns `.none`: that byte is inside the two-byte
encoding of `é`.

### Allocating transformations

```loke
copy(text: string_view, allocator: Allocator = ...) -> string
try_copy(text: string_view, allocator: Allocator = ...)
	-> Result(string, Allocator_Error)
join(parts: []string_view, separator: string_view = "",
	allocator: Allocator = ...) -> string
repeat(text: string_view, times: int, allocator: Allocator = ...) -> string
replace(text, old, new: string_view, limit: int = -1,
	allocator: Allocator = ...) -> string
to_upper(text: string_view, allocator: Allocator = ...) -> string
to_lower(text: string_view, allocator: Allocator = ...) -> string
```

`copy` creates owning text with the selected allocator; `try_copy` returns
allocation failure as a value. The other transformations also return owning
storage with the selected allocator. `join` takes a slice of parts.

Case conversion is ASCII-only and leaves other code points unchanged.

The policy-following forms apply the allocator's failure policy. Negative
counts and other programmer mistakes panic. `replace` replaces every occurrence
when `limit` is negative, and an empty `old` matches nowhere. A `repeat` result
longer than the largest `int` is an allocation failure, detected before appending.

`join`, `repeat`, `replace`, `to_upper`, and `to_lower` have no `try_` twins.
For fallible construction use `String_Builder.try_reserve`, `try_append`, and
`try_finish`.

### `String_Builder`

`String_Builder` maintains valid UTF-8 at every public boundary. It is an
ordinary owning value over `[dynamic]u8`.

Its zero value is a usable empty builder, initially unbound to an allocator;
it binds on first growth. Use `strings.init(allocator)` to select an allocator
up front. Length and capacity count bytes. The append operations below are
methods; `append` and `try_append` accept either text or a rune.

```loke
String_Builder :: struct { /* private representation */ }

init :: proc(allocator: Allocator = mem.default_allocator()) -> String_Builder

impl String_Builder {
	len          :: proc(self) -> int;
	cap          :: proc(self) -> int;
	reserve      :: proc(self: inout String_Builder, additional: int);
	try_reserve  :: proc(self: inout String_Builder, additional: int)
		-> Status(Allocator_Error);
	append_text  :: proc(self: inout String_Builder, text: string_view);
	append_rune  :: proc(self: inout String_Builder, value: rune);
	append       :: proc{append_text, append_rune};
	append_byte_ascii :: proc(self: inout String_Builder, value: u8);
	try_append_text :: proc(self: inout String_Builder, text: string_view)
		-> Status(Allocator_Error);
	try_append_rune :: proc(self: inout String_Builder, value: rune)
		-> Status(Allocator_Error);
	try_append   :: proc{try_append_text, try_append_rune};
	try_append_byte_ascii :: proc(self: inout String_Builder, value: u8)
		-> Status(Allocator_Error);
	clear        :: proc(self: inout String_Builder);
	finish       :: proc(self: inout String_Builder) -> string;
	try_finish   :: proc(self: inout String_Builder)
		-> Result(string, Allocator_Error);
	view         :: proc(self: ^) -> string_view;
	copy_string :: proc(self, allocator: Allocator
		= mem.default_allocator()) -> string;
	try_copy_string :: proc(self, allocator: Allocator
		= mem.default_allocator()) -> Result(string, Allocator_Error);
}
```

`finish` copies the text into a string, then clears the builder while retaining
its allocation for reuse. `try_finish` does the same on success and leaves the
builder unchanged on allocation failure. `finish` applies the builder
allocator's failure policy. `copy_string` and `try_copy_string` leave the
builder unchanged.

A reservation whose total exceeds the largest `int` is an allocation failure:
`try_reserve` reports it and `reserve` applies the allocator's policy.

`view` borrows the text written so far without allocating. The borrow checker
rejects an append while the view is live, so a reader that only inspects the
result (as `path.join` does before `path.clean`) need not copy it.

Arbitrary byte append is absent because it could break the UTF-8 invariant.
Validate bytes before appending or use a byte buffer. Compiler support for
string allocation is described in
[Runtime and library boundary](compiler-architecture.md#runtime-and-library-boundary).

Example (imports `core:strings`):

```loke
greeting :: proc(name: string_view) -> string {
	builder: strings.String_Builder = {};
	builder.append("Hello, ");
	builder.append(name);
	builder.append('!');
	return builder.finish();
}
```

## `core:cstrings`

`C_String` is an ordinary owning zero-terminated byte buffer for foreign APIs
that retain a string after the call. Unlike `string`, it does not promise UTF-8.
Moving it is cheap; copying follows the normal lifecycle rules and clones the
owned buffer.

`from_string` is a free constructor; `view` and `len` are methods.

```loke
C_String :: struct { /* private representation */ }

Error :: enum { Contains_Zero, Out_Of_Memory }

from_string :: proc(text: string_view, allocator := mem.default_allocator())
	-> Result(C_String, Error)

impl C_String {
	view :: proc(self: ^) -> cstring_view;
	len  :: proc(self) -> int;             // excludes the terminator
}
```

`from_string` rejects an interior U+0000 as `Contains_Zero` and reports allocation
failure as `Out_Of_Memory`. `view` borrows the owned buffer. There is no
byte-oriented constructor or accessor yet.

## `core:encoding/utf16`

The conversion `core:fs`, `core:os`, and `core:term` share for the wide Windows
APIs.

```loke
Error :: enum { Invalid_Data, Out_Of_Memory, Contains_Zero }

encode(text: string_view, allocator := mem.default_allocator())
	-> Result([dynamic]u16, Error)
decode(units: []u16, allocator := mem.default_allocator())
	-> Result(string, Error)
length_of(units: []u16) -> int
```

`encode` returns zero-terminated units; the terminator is not part of the text,
so the unit count is `len() - 1`. Text containing U+0000 is `Contains_Zero`, for
the same reason `core:cstrings` rejects it. `decode` converts exactly the range
it is given, zeros included, and an unpaired surrogate is `Invalid_Data` rather
than U+FFFD. `length_of` counts the units before the first zero, for an API that
returns a terminated buffer.

## `core:encoding/json`

JSON text: a fully validating parser into an immutable document, borrowed views
of its values, and a buffered writer over any `io.Writer`. It is ordinary Loke
with no compiler support; the reasons for its shape are in
[Standard-library API choices](comments.md#standard-library-api-choices).

Input is [RFC 8259](https://www.rfc-editor.org/rfc/rfc8259.txt) JSON, with an
explicit Unicode and object-lookup policy:

| Case | Behavior |
| --- | --- |
| Root | Exactly one value, a scalar included; JSON whitespace (space, tab, LF, CR) may surround it. |
| Extra input | Anything but whitespace after the root value is `Trailing_Input`. |
| Extensions | Comments, trailing commas, leading zeros, a leading `+`, hexadecimal, `NaN`, and `Infinity` are errors. |
| Text | UTF-8. A byte order mark, invalid UTF-8, a raw control character in a string, and an unpaired escaped surrogate are errors: every string is a Unicode scalar sequence, as Loke's string types require. |
| Object members | Kept in order, every occurrence of a key included. Keys compare byte for byte once decoded, without Unicode normalization, so `"\u0061"` and `"a"` are the same key. |
| Numbers | Validated as JSON spells them and kept exactly as written; parsing never requires a number to fit a machine type. |

### Documents and values

```loke
Kind :: enum { Null, Boolean, Number, String, Array, Object }

parse(input: []u8, allocator := mem.default_allocator(), options: Parse_Options = {})
	-> Result(Document, Parse_Error)
parse_text(input: string_view, allocator := mem.default_allocator(),
	options: Parse_Options = {}) -> Result(Document, Parse_Error)
parse_owned(input: move string, allocator := mem.default_allocator(),
	options: Parse_Options = {}) -> Result(Document, Parse_Error)

Document :: move_only struct { /* private */ }
Document.init(allocator := mem.default_allocator()) -> Document
Document.root(self: ^) -> Option(Value)
Document.reparse(self: inout, input: []u8, options: Parse_Options = {}) -> Status(Parse_Error)
Document.reparse_text(self: inout, input: string_view, options: Parse_Options = {})
	-> Status(Parse_Error)
Document.reparse_owned(self: inout, input: move string, options: Parse_Options = {})
	-> Status(Parse_Error)
Document.clear(self: inout)

Value.kind(self) -> Kind
Value.boolean(self) -> Result(bool, Access_Error)
Value.string(self) -> Result(string_view, Access_Error)
Value.number(self) -> Result(Number, Access_Error)
Value.to_i64(self) -> Result(i64, Access_Error)
Value.to_u64(self) -> Result(u64, Access_Error)
Value.to_f64(self) -> Result(f64, Access_Error)
Value.array(self) -> Result(Array, Access_Error)
Value.object(self) -> Result(Object, Access_Error)

Array.Element :: Value
Array.len(self) -> int
Array.at(self, index: int) -> Option(Value)
Object.Element :: Member
Object.len(self) -> int
Object.find(self, key: string_view) -> Result(Option(Value), Access_Error)
Object.require(self, key: string_view) -> Result(Value, Access_Error)
Member :: (key: string_view, value: Value)
```

`parse` and `parse_text` borrow their input; `parse` first validates it as
UTF-8, which `parse_text` skips. `parse_owned` takes ownership of a string
without copying its bytes: its allocator selects the document's own storage,
and the string keeps its allocator. So `fs.read_bytes` followed by `parse`, and
`fs.read_text` followed by `parse_owned`, both work; the second still copies
the file once while loading it (see [Whole-file convenience](#whole-file-convenience)).

A `Document` owns its value storage and decoded text, and its input when owned.
It is move-only. **Its zero value is empty and allocator-unbound**: `root` is
`.none`, and its first growth binds the default allocator. `init` selects an
allocator without allocating. A successful parse always has a root, `.some` of a
null value included. `clear` releases the input and contents but keeps the
allocator and capacity; dropping the document releases the capacity. The three
`reparse` forms reuse that allocator and capacity, and may switch between
borrowed and owned input. Any failed reparse leaves the document empty, with its
capacity and no input, even for invalid options; an owned string is consumed on
failure too. A failed free-function parse releases every partial allocation.

`Value`, `Array`, and `Object` are small read-only views: a pointer to the
document and an index. A string or `Number` from them borrows the input or the
document. Ordinary borrow checking therefore keeps both alive and rejects
clearing, reparsing, moving, or dropping a document while a view of it is in
use. No accessor allocates.

`null`, an absent member, and a value of another kind are distinct, and no
accessor converts one kind to another. `find` returns `.none` for no matching
member and `Duplicate_Key` for more than one, never choosing the first or last;
`require` reports no match as `Missing_Key` instead. A successful lookup says
nothing about whether other keys repeat. `Array` and `Object` implement the
[iteration protocol](design.md#iteration-protocol), so
`foreach (key, value in object)` takes each member apart.

Array length is immediate. Iteration steps over a whole subtree at once, but
`at` walks from the first element and lookup is linear in the member count,
scanning past a match to detect a duplicate. Reading every field with its own
lookup, or an array with repeated `at`, is therefore quadratic; a complete
traversal is a `foreach`. A schema-shaped reader can switch on each key in one
traversal and reject repeated known fields with flags of its own.

```loke
Access_Code :: enum {
	Wrong_Kind, Missing_Key, Duplicate_Key, Not_Integer, Out_Of_Range,
	Out_Of_Memory, Backend_Failure,
}
Access_Error :: struct { code: Access_Code, offset: int, expected: Kind, actual: Kind }
```

An `Access_Error` owns its data: a code, a zero-based byte offset in the input,
and for `Wrong_Kind` the expected and actual kinds. A wrong kind or a conversion
points at the value's first byte; a missing key at the opening brace of the
object searched; a duplicate at the opening quote of the second matching key.
No error borrows a key or allocates a path.

### Numbers

```loke
Number :: struct { /* private, required */ }
Number.text(self) -> string_view
Number.to_i64(self) -> Result(i64, Access_Error)
Number.to_u64(self) -> Result(u64, Access_Error)
Number.to_f64(self) -> Result(f64, Access_Error)
number(text: string_view) -> Result(Number, Parse_Error)
```

A number keeps its spelling: `9007199254740993`, `1e400`, and `-0` are written
back as they were read, so rewriting a document neither rounds an identifier
nor erases a negative zero. `Number` has a required private field, so it has no
zero value: only a document or `number` makes one. `number` accepts exactly one
JSON number with no surrounding whitespace, borrowing the text, so a caller can
write an exact decimal without a document; its conversion errors have offset
zero.

The integer conversions require integer spelling: `1.0` and `1e0` are
`Not_Integer`. They check the whole range, signed minimum and unsigned maximum
included; `to_u64` reads `-0` as zero and any other negative integer is
`Out_Of_Range`. `to_f64` is [`strconv.try_parse_f64`](#corestrconv): correctly
rounded, losing integer precision past 2^53, rounding a magnitude too small to
a signed zero, and reporting one too large as `Out_Of_Range` rather than an
infinity. A valid number can therefore fail a requested conversion. The
`Value` conversions are `number()` and its conversion, with either error.

### Parsing

```loke
Parse_Code :: enum {
	Invalid_Syntax, Unexpected_End, Invalid_Utf8, Invalid_Escape, Invalid_Number,
	Trailing_Input, Limit_Exceeded, Invalid_Options, Out_Of_Memory,
}
Parse_Error :: struct { code: Parse_Code, offset: int }
Parse_Options :: struct { max_bytes: int, max_nodes: int, max_depth: int }
MAX_DEPTH :: 256

Position :: struct { line: int, column: int }
position(source: []u8, offset: int) -> Position
```

The parser is one iterative pass with an inline stack of open containers, so
nesting cannot overflow the call stack. Every allocation uses a fallible
operation on the selected allocator: malformed or oversized input reports an
error and never invokes a failure policy. Each value is a 16-byte node in
source order. Text without escapes stays in the input; escaped text is decoded
once into one buffer the document owns.

Limits default to 64 MiB of input, four million nodes, and `MAX_DEPTH`. A zero
field selects its default; a positive one lowers or raises the byte and node
limits and lowers the depth limit. An object's key is a node, and depth counts
open arrays and objects, so a scalar is at depth zero. A negative field or a
depth above `MAX_DEPTH` is `Invalid_Options`. Offsets are 32-bit, so input of
4 GiB or more is `Limit_Exceeded` whatever the options say. The limits bound the
document's logical contents, not peak memory: growing storage and capacity a
reused document keeps come on top. An array of single digits reaches four
million nodes at only 8 MB of input.

Options and the input's size are checked before the input is validated or any
storage reserved, and both report offset zero. Invalid UTF-8 given to `parse`
is reported at the first byte of its first invalid sequence, in preference to
any JSON error anywhere in the input; otherwise the first error the scanner
meets is reported. An input that ends inside a value reports `Unexpected_End`
at its length. A node or depth limit points at the token that would exceed it,
and an allocation failure at the token being stored. A malformed number is
reported at its first byte. `position` computes a one-based line and byte column
from the caller's text, outside the parser.

### Writing

```loke
Write_Code :: enum {
	Invalid_State, Invalid_Options, Limit_Exceeded, Non_Finite, Out_Of_Memory,
	Backend_Failure, Io,
}
Write_Error :: struct { code: Write_Code, io: io.Error }
Write_Options :: struct { pretty: bool, max_depth: int, max_bytes: int }

writer(output: ^mut $W, buffer: []mut u8, options: Write_Options = {})
	-> Result(Writer(W), Write_Error) where io.Writer(W)

Writer.begin_object(self: inout) -> Status(Write_Error)
Writer.end_object(self: inout) -> Status(Write_Error)
Writer.begin_array(self: inout) -> Status(Write_Error)
Writer.end_array(self: inout) -> Status(Write_Error)
Writer.key(self: inout, key: string_view) -> Status(Write_Error)
Writer.string(self: inout, text: string_view) -> Status(Write_Error)
Writer.boolean(self: inout, value: bool) -> Status(Write_Error)
Writer.null(self: inout) -> Status(Write_Error)
Writer.i64(self: inout, value: i64) -> Status(Write_Error)
Writer.u64(self: inout, value: u64) -> Status(Write_Error)
Writer.f64(self: inout, value: f64) -> Status(Write_Error)
Writer.number(self: inout, value: Number) -> Status(Write_Error)
Writer.value(self: inout, value: Value) -> Status(Write_Error)
Writer.finish(self: inout) -> Status(Write_Error)

stringify(value: Value, allocator := mem.default_allocator(),
	options: Write_Options = {}) -> Result(string, Write_Error)
```

A `Writer(W)` borrows its output and the caller's nonempty buffer, and keeps its
open containers inline, so it allocates nothing for structure or buffering.
Bytes reach the output with `io.write_all` when the buffer fills and at
`finish`; a span longer than the buffer goes straight through after the
buffered bytes. Integers are spelled by `core:fmt` into a local buffer, and
floats by [`fmt.try_spell_f64`](#corefmt), so numeric output cannot panic.

The writer accepts one root value, a `key` before each member's value, and
closes that match what is open. The first failure of any kind is latched:
invalid ordering, an unmatched close, a depth or output limit, a non-finite
float, an allocation or numeric backend failure, and an `io.Error` from the
output, which `Write_Error.io` keeps. Every later call writes nothing and
returns that error. `finish` requires a complete root, flushes the buffer, and
seals the writer; a repeated `finish` succeeds without I/O, and any other call
after it latches `Invalid_State`. Dropping a writer performs no I/O, and the
caller remains responsible for flushing or closing a file, or for choosing
[atomic replacement](#atomic-replacement). A failed write may leave part of a
document in the output; nothing is rolled back.

Options select compact output (the default) or a pretty layout with two-space
indentation, one member or element per line, LF line breaks, and a space after
each key's colon; neither adds a final newline. The depth limit is at most
`MAX_DEPTH` and the output limit defaults to 64 MiB; a zero limit selects its
default, and a negative limit, a depth above `MAX_DEPTH`, or an empty buffer is
`Invalid_Options`. The output limit is checked before each span is written.

Strings escape `"`, `\`, and the control characters, with the short escapes
where JSON has them, and leave every other scalar as UTF-8. A float is written
as `fmt` prints it, the shortest spelling that reads back, with negative zero
kept; a NaN or infinity is `Non_Finite`, refused before anything is written
for it. `number` writes a spelling exactly. `value` writes a subtree in one
iterative pass, keeping member order, repeated keys, and number spellings; its
containers count toward the depth limit on top of those already open, so a
parsed value cannot bypass the writer's limits. Re-encoding keeps values and
number spellings, not the original whitespace or string escapes.

`stringify` writes a value into an [`io.Buffer_Writer`](#byte-buffer) and
copies the finished bytes into one string from `allocator`; the copy is part of
its cost. To write a file, emit into a buffer and replace the file only once
the document is finished, so a failed write never publishes part of one:

```loke
save_generation :: proc(path: string_view, generation: u64, allocator: Allocator)
	-> Status((json: json.Write_Error | file: io.Error)) {
	bytes := io.Buffer_Writer.init(allocator);
	scratch: [8192]u8 = {};
	out := json.writer(&mut bytes, &mut scratch[:]) or_return .json;
	out.begin_object() or_return .json;
	out.key("generation") or_return .json;
	out.u64(generation) or_return .json;
	out.end_object() or_return .json;
	out.finish() or_return .json;
	fs.replace_atomic(path, bytes.bytes()) or_return .file;
}
```

## `core:endian`

A binary format fixes each field's byte order; these wrappers put that order in
the field's type, so the swap happens at `store` and `load` rather than wherever
a caller remembers it.

```loke
Order :: enum { Little, Big }
host_order() -> Order
byte_swap(value: $T) -> T where interfaces.Integral(T)

Little_Endian :: struct($T: type) where interfaces.Integral(T) { /* private */ }
Big_Endian    :: struct($T: type) where interfaces.Integral(T) { /* private */ }

impl Little_Endian($T) {   // Big_Endian likewise
	store     :: proc(value: T) -> Little_Endian(T);
	load      :: proc(self) -> T;
	from_host :: hook(convert) proc(value: T) -> Little_Endian(T);
	format    :: proc(self, writer: fmt.Writer, options: fmt.Options);
}
```

A wrapper has the size and alignment of `T` and defines no arithmetic. The
conversion hook is explicit only, `Big_Endian(u32)(x)`, because an implicit one
would let a host value land in a stored field unswapped. Equality compares the
stored bytes, which is equality of the values. Formatting prints the loaded
value, with the caller's options. Where the host order already matches, `store`
and `load` compile to nothing.

## `core:strconv`

Parsing does not belong in `strings`: it interprets text as another type.

The procedures are:

```loke
parse_bool(text: string_view) -> Option(bool)
parse_i64(text: string_view, base := 0) -> Result(i64, Parse_Error)
parse_u64(text: string_view, base := 0) -> Result(u64, Parse_Error)
parse_int(text: string_view, base := 0) -> Result(int, Parse_Error)
parse_uint(text: string_view, base := 0) -> Result(uint, Parse_Error)
parse_f64(text: string_view) -> Result(f64, Parse_Error)

Backend_Error :: enum { Out_Of_Memory, Unavailable }
try_parse_f64(text: string_view)
	-> Result(f64, (parse: Parse_Error | backend: Backend_Error))
```

`Parse_Error` distinguishes invalid syntax, invalid base, overflow, and trailing
data, and reaches a caller as the failure payload of `Result`. `parse_bool` has
only one way to fail, so it answers `Option(bool)` instead; it accepts `true`,
`True`, `TRUE`, `1`, and the matching `false` spellings and `0`. Parsing consumes the
whole string after permitted surrounding ASCII whitespace. A separate scanner
API can later parse a prefix.

`base == 0` recognizes the language prefixes `0b`, `0o`, and `0x`, in lower
case only; otherwise the accepted range is 2 through 36, with no prefix.
Underscores may separate digits, as in a Loke literal: one may follow a digit or
a prefix, never lead the digits.

`parse_f64` accepts `[+-]digits[.digits][(e|E)[+-]digits]`, where the digits on
one side of the point may be absent but not on both. Underscores follow the
integer rule in all three digit runs, the exponent included. The result is the
correctly rounded `f64`, so every finite `f64` printed by the default
`core:fmt` format parses back to itself. Precision wrappers such as `fmt.fixed`
may round the value before printing.
A finite spelling beyond the largest `f64` is `Overflow`; one below the smallest
subnormal rounds to a signed zero. `inf` and `nan` are not accepted. The point is
always `.`, whatever numeric locale foreign code has set for the C library.
Parsing allocates nothing, however long the text: digits past the 767th
significant one are reduced to whether any of them is nonzero, which is all
that can change the rounding. As with formatting, failing to create the "C"
numeric locale panics. `try_parse_f64` gives every other answer `parse_f64`
gives and reports that failure as a `Backend_Error` instead: `Out_Of_Memory`
when creating the locale failed to allocate, `Unavailable` otherwise.
[`core:encoding/json`](#numbers) converts numbers with it.

Formatting scalars remains in `core:fmt`; `strconv` should not grow a second
formatting system.

## `core:log`

design.md "Build-selected providers" says how a program selects its logger, and
"Compiled log level" what `-log-level` removes. This is the package's surface.

```loke
Level :: enum { Debug, Info, Warning, Error, Off }   // contributed by the compiler

Sink :: interface($Self: type) {
	slot write: proc(self: inout Self, level: Level, message: string_view);
}
Logger :: dyn mut Sink;

debug(args: ..any_view)
info(args: ..any_view)
warning(args: ..any_view)
error(args: ..any_view)
at(level: Level, args: ..any_view)
enabled(level: Level) -> bool
current() -> Logger
standard_logger() -> Logger
```

The compiler contributes `Level` so that it and `LOKE_LOG_LEVEL` are one type.
`Off` is a threshold only: nothing records at it, `enabled(.Off)` is false, and
`at(.Off, ...)` records nothing. `at` and `enabled` apply the compiled level to
a level held in a variable.

A record formats its arguments separated by one space, as `fmt.print` does,
into `mem.default_allocator()`, and hands the logger that text without a line
ending. The allocation follows that allocator's failure policy, so a record can
panic under memory pressure. The standard logger writes `[Level] message` and a
newline to the error stream, holding a lock for the whole record so that records
from different threads never share a line; other writers to the error stream
are not serialized against it. A selected provider's own thread safety is the
provider's responsibility. `current` returns the selected logger, or the
standard one when none is selected or before it is published.

A provider's factory returns `(log.Logger)(&mut sink)` over a `static` record
with a `write` method, which is the process-lifetime storage design.md
"Provider initialization" asks for.

## `core:fs`

`fs.File` is the safe owning wrapper around a native file handle. Its fields are
private, its zero value is closed, it disables cloning, and its `drop` closes a
live handle.

### Opening and file I/O

```loke
Access :: enum {Read, Write, Read_Write}
Disposition :: enum {
	Open_Existing,
	Open_Or_Create,
	Create_New,
	Create_Or_Truncate,
	Truncate_Existing,
}

Open_Options :: struct {
	access:      Access,
	disposition: Disposition,
	append:      bool,
}

Seek_Origin :: enum {Start, Current, End}

File :: move_only struct { /* private handle and access */ }

open(path: string_view, options: Open_Options) -> Result(File, io.Error)
open_read(path: string_view) -> Result(File, io.Error)
create(path: string_view) -> Result(File, io.Error)
append(path: string_view) -> Result(File, io.Error)

impl File {
	read    :: proc(self: inout File, destination: []mut u8) -> Result(int, io.Error);
	write   :: proc(self: inout File, source: []u8) -> Result(int, io.Error);
	seek    :: proc(self: inout File, offset: i64, origin: Seek_Origin)
		-> Result(u64, io.Error);
	flush   :: proc(self: inout File) -> Status(io.Error);
	close   :: proc(self: inout File) -> Status(io.Error);
	is_open :: proc(self) -> bool;
}
```

Because structural interface satisfaction is determined by the static type,
`File` satisfies both `io.Reader` and `io.Writer`: it has both slots regardless of
the options used for a particular instance. The open mode is checked at runtime:
using an unsupported direction returns `Unsupported`, and a nonempty read or
write, or a seek, on a closed file returns `Closed`; `flush` and `close` on a
closed file succeed. A disposition that truncates needs `Write` or
`Read_Write` access, and `Truncate_Existing` cannot be combined with `append`
(Windows truncates an existing file only for a caller holding the full write
right, which append mode gives up); `open` answers `Unsupported` for either
without touching the file. Append mode guarantees
that each underlying write begins at the current end of file; it does not make
multiple writes from multiple processes into one atomic transaction.

`flush` returns once the file's written data and metadata have been handed to
the storage device, so they survive a crash or power loss as far as the device
honors the request. `File` keeps no buffer of its own, so there is no weaker
meaning for `flush` to have.

### Whole-file convenience

```loke
read_bytes(path, allocator := mem.default_allocator(), limit := 0)
	-> Result([dynamic]u8, io.Error)
read_text(path, allocator := mem.default_allocator(), limit := 0)
	-> Result(string, io.Error)
write_bytes(path, data: []u8) -> Status(io.Error)
write_text(path, text: string_view) -> Status(io.Error)
append_bytes(path, data: []u8) -> Status(io.Error)
append_text(path, text: string_view) -> Status(io.Error)
```

`read_text` validates UTF-8. `write_*` truncates an existing file only after it
has successfully opened the target. It does not promise atomic replacement;
[`replace_atomic`](#atomic-replacement) does.
`read_bytes` and `read_text` use the same `limit` contract as `io.read_to_end`:
exceeding a positive limit answers `.err(Limit_Exceeded)` and destroys partial
storage.

Example (imports `core:fs` and `core:io`):

```loke
read_notes :: proc(path: string_view) -> Result(string, io.Error) {
	return fs.read_text(path, limit = 1_048_576);
}
```

This bounds the input at 1 MiB and returns UTF-8 validation, allocation, and
filesystem failures to the caller. For formatted stream output, use
`io.write_formatted` and explicitly close an owning file when close errors matter.

### Atomic replacement

```loke
replace_atomic(path, data: []u8) -> Status(io.Error)
replace_atomic_text(path, text: string_view) -> Status(io.Error)
```

`replace_atomic` makes `path` hold exactly `data`, whether or not it existed. A
reader, or the program after a crash or power loss, sees either the whole
previous file or the whole new one, never a mixture. On `.ok` the new content
and the name switch are both durable, as far as the device honors flush
requests. On `.err` the target is as it was before the call, unless the switch
was made but could not be made durable, in which case it holds the new content.

The data is first written and flushed to a new file in the target's directory,
named `.replace-<process>-<attempt>.tmp` so that a target name of any valid
length leaves room for it, and that file then takes the target's name; only a
rename within one volume can be atomic. A failure removes
the temporary file, but a crash before the switch can leave it behind. Each
call writes the whole file, so a program that keeps large state in several
files replaces a small manifest naming them last.

Example (imports `core:fs` and `core:io`):

```loke
save :: proc(generation: string_view) -> Status(io.Error) {
	return fs.replace_atomic_text("save/manifest.txt", generation);
}
```

### Filesystem operations

```loke
metadata(path) -> Result(Metadata, io.Error)
exists(path) -> Result(bool, io.Error)
remove(path) -> Status(io.Error)
rename(old_path, new_path) -> Status(io.Error)
create_directory(path) -> Status(io.Error)
create_directories(path) -> Status(io.Error)
remove_directory(path) -> Status(io.Error)
read_directory(path, allocator := mem.default_allocator())
	-> Result(Directory_Reader, io.Error)
```

`Directory_Reader.next` returns `Result(Option(Directory_Entry), io.Error)`:
`.none` means enumeration ended, while `.err` means it failed. The move-only
reader yields one entry at a time and closes its search handle on `drop`.
An entry's name borrows the reader's buffer until the next `next` call; copy it
if it must be retained. A fallible reader uses an explicit loop, not `foreach`.

The reader streams the native enumeration. Its order is unspecified: it is
whatever the filesystem returns, which differs between NTFS and FAT and is
promised by neither, so a caller that needs a stable listing collects the
entries and sorts them. `.` and `..` are never yielded. The directory is not
snapshotted: an entry added, removed, or renamed while the walk is in progress
may be yielded, missed, or yielded under both names, and the walk does not
fail because of the change. A yielded name is not a promise that the entry
still exists: `metadata` on it can answer `Not_Found`.

Example (imports `core:fmt`, `core:fs`, and `core:io`):

```loke
list_names :: proc(path: string_view) -> Status(io.Error) {
	reader := fs.read_directory(path) or_return;
	for (;;) {
		entry := reader.next() or_return;
		switch (entry) {
		case .some(found): fmt.println(found.name);
		case .none: return .ok;
		}
	}
}
```

The name is consumed before the next step, and `or_return` propagates errors.

`rename` replaces an existing file at the new path. It refuses a move across
volumes rather than copying, so a rename that succeeds is atomic, and on `.ok`
it is durable as far as the device honors flush requests.

`create_directories` succeeds when the path ends up naming a directory, so an
existing directory and a volume root such as `C:\` are not failures, while an
existing file is `Already_Exists`. A path ending in a drive's colon, such as
`C:`, names that drive's current directory for `read_directory` as for every
other operation.
Removing an existing file with `remove_directory` is `Invalid_Path`; the
operation requires a directory and preserves the native error number.

`exists` answers `.ok(false)` only for a definite not-found result; permission
and I/O failures remain errors. `Metadata` holds `kind` (`File`, `Directory`,
or `Other`), `size` in bytes, and `modified`, the last write as an
`Option(time.Time)`: `.none` where the filesystem keeps no such time, and a
time outside the range of `time.Time` saturating at its end. `Other` is
reserved; no operation produces it today.

There is no symbolic-link support: no operation creates, resolves, or
identifies a link. Until it arrives, a link, whether a file link, a directory
link, or a junction, behaves as follows:

- A link anywhere before the last element of a path is followed, so
  `create_directories` succeeds through a junction.
- `metadata` and a directory entry describe the link itself, by its directory
  bit: a junction or a directory link is a `Directory` and a file link is a
  `File`, whether or not the target exists. Likewise `exists` is true for a
  link whose target is missing.
- `open` and the whole-file reads, writes, and appends act on the target, and
  `read_directory` enumerates the target.
- `remove`, `remove_directory`, `rename`, and `replace_atomic` act on the name,
  never the target. `remove` deletes a file link and `remove_directory` a
  junction or directory link, leaving the target. `rename` moves the link, and
  when `new_path` names a file link it replaces that link. `replace_atomic` puts
  an ordinary file in place of a file link at `path`, leaving the old target
  unchanged.
- `create_directory` on a name a link already takes is `Already_Exists`.

When link support arrives its behavior is explicit, not inherited from what
Windows does.

## `core:path`

Path operations are lexical and perform no filesystem access:

```loke
separator() -> rune
is_absolute(path: string_view) -> bool
volume(path: string_view) -> string_view
base(path: string_view) -> string_view
directory(path: string_view) -> string_view
extension(path: string_view) -> string_view
stem(path: string_view) -> string_view
join(parts: []string_view, allocator := mem.default_allocator()) -> string
clean(path: string_view, allocator := mem.default_allocator()) -> string
```

`volume` is public because nothing above a volume is a directory anything can
create or remove — `C:` is a drive and a UNC prefix is a share — so a caller
walking a path has to know where the walkable part starts. `fs.create_directories`
is the one that needs it.
On Windows an extended UNC volume includes the complete server and share:
`\\?\UNC\server\share\child` has volume `\\?\UNC\server\share`, with a
case-insensitive `UNC` marker. Both server and share must be non-empty.
`base` and `directory` stop at that boundary as they do for ordinary UNC roots,
and `fs.create_directories` begins below the share.

`join` and `clean` use the selected allocator for both scratch and result
storage; budget a few times the result size when using a bounded arena.
`join` takes a slice, as in `path.join([]string_view{a, b})`. It puts exactly
one separator at each boundary between nonempty parts, however many either side
supplies, and none after a bare drive volume such as `C:`. A part of separators
alone adds no boundary of its own, and separators that end the last part are
kept as written.

The result follows target-platform path rules. `clean` removes redundant
separators and lexical `.`/`..` elements but does not resolve symlinks or access
the filesystem. Resolving a path against the filesystem is planned as
`fs.absolute` and `fs.canonicalize`, which will return an I/O error; neither
exists yet.

`clean` returns an extended-length path unchanged because Windows uses it to
bypass normalization. There is no automatic long-path prefixing.

## `core:term`

Terminal input has two distinct levels. Line input is the default for command
line programs. Key events are an explicit terminal-only facility, not a global
keyboard hook and not GUI input.

### Standard byte streams and line input

```loke
stdin() -> Input
stdout() -> Output
stderr() -> Output

read_line(allocator := mem.default_allocator(),
	options: io.Line_Options = {}) -> Result(string, io.Error)
prompt(label: string_view, allocator := mem.default_allocator(),
	options: io.Line_Options = {}) -> Result(string, io.Error)
```

`Input` satisfies `io.Reader`; `Output` satisfies `io.Writer`. These lightweight
values do not own and cannot close the process standard handles. They work when
the handles are redirected to pipes or files.

Standard output and standard error carry exactly the bytes a program writes,
whether through `term`, `core:fmt`, or a panic report: `\n` is never turned
into `\r\n`, on any platform. A program that wants `\r\n` writes it.

`read_line` reads a real console through `ReadConsoleW` and a redirected handle
through `io.read_line`, so typed non-ASCII text arrives intact. Ctrl+Z at the
start of a console line is `End_Of_Input`, as the end of a redirected stream is.
Malformed UTF-16 console text or UTF-8 redirected text returns `Invalid_Data`
with operation `Read_Line` and native code zero.
The raw `Input.read` stream is bytes through `ReadFile` either way, and one call
moves at most `0x3FFFFFFF` bytes, as `core:fs` does.

`prompt` writes the label to standard output, flushes it, and then reads a line.
It returns output failures as well as input failures. It does not print a
newline automatically.

Formatted console diagnostics remain available through `core:fmt`. Raw and
fallible stream output uses `term.stdout()` with `io.write_all` or
`io.write_formatted`.

### Raw mode and key events

```loke
Raw_Options :: struct { interrupt_as_key: bool }
Raw_Mode :: move_only struct { /* private state */ }

begin_raw(input: Input = stdin(), options: Raw_Options = {})
	-> Result(Raw_Mode, io.Error)

impl Raw_Mode {
	read_key :: proc(self: inout Raw_Mode) -> Result(Key_Event, io.Error);
	close    :: proc(self: inout Raw_Mode) -> Status(io.Error);
}

Key :: enum {
	Character,
	Up, Down, Left, Right,
	Home, End, Page_Up, Page_Down,
	Insert, Delete, Backspace, Enter, Escape, Tab,
	F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12,
	Unknown,
}

Key_Event :: struct {
	key:     Key,
	value:   rune,
	shift:   bool,
	control: bool,
	alt:     bool,
}
```

`Raw_Mode.drop` restores the previous terminal mode on normal scope exit and
during panic unwinding with the `unwind` strategy. The `abort` strategy does not
guarantee cleanup. `os.exit` runs no cleanup and can leave the terminal raw.

`begin_raw` also registers a Windows process-level handler that restores the
saved mode on Ctrl+C, Ctrl+Break, and console close. It is registered only when
raw mode is requested. Restoration is idempotent with `close` and `drop`.
If restoration fails, the handler stays armed and the raw-mode claim remains
held; a later `begin_raw` returns `.err(Already_Exists)`.

`begin_raw` turns off line input, echo, and virtual-terminal input; with the
last left on, the console would deliver every key as the characters of an escape
sequence. On redirected input it answers `.err(Not_A_Terminal)`.

Only one `Raw_Mode` may be live in a process. A second `begin_raw` returns
`.err(Already_Exists)` without changing the terminal.

Text input is `key == .Character` with the scalar value in `value`; a named key
leaves `value` zero, and is preferred when a key such as Enter or Tab also
carries a control character. A key the decoder has no name for is `.Unknown`.
Modifiers are explicit flags, so Shift, Ctrl, or Alt pressed alone is no event.
Key releases, mouse, focus, and resize records are skipped. A held key's
repeat count becomes that many events, in order.

Ctrl+letter input uses the reported control character as `value`, with
`control` set. With `interrupt_as_key`, Ctrl+C is `.Character` with `value == 3`.
Ctrl+I and Ctrl+M are likewise `.Character` with values 9 and 13; physical Tab
and Enter retain their named events.

`read_key` combines UTF-16 surrogate pairs into one scalar. A low half without
a preceding high half, or a high half followed by another key's unit that is
not a low half, returns `Invalid_Data` with operation `Read_Key` and native code
zero. A high half still pending at end of input returns the same error. Skipped
records do not break a pair. After an unmatched high half, the following key
remains available to the next call, with its modifiers and repeats; another
high half is retained to begin a new pair.

By default Ctrl+C keeps interrupting the process; `Raw_Options{interrupt_as_key =
true}` delivers it as a key event instead, and the program then terminates
itself.
Mouse events, window resizing, colors, cursor movement, and full-screen terminal
UI are not provided.

## `core:os` additions

Besides `os.args` and `os.exit` ([Program entry and
exit](design.md#program-entry-and-exit)), `core:os` has these process-level
operations:

```loke
view_at(index: int) -> string_view
get_environment(name: string_view,
	allocator := mem.default_allocator()) -> Result(Option(string), io.Error)
set_environment(name, value: string_view) -> Status(io.Error)
unset_environment(name: string_view) -> Status(io.Error)
working_directory(allocator := mem.default_allocator())
	-> Result(string, io.Error)
set_working_directory(path: string_view) -> Status(io.Error)
executable_path(allocator := mem.default_allocator())
	-> Result(string, io.Error)
```

`view_at(i)` borrows argument `i` instead of copying it as `os.args[i]` does.
The arguments are cached for the life of the process, so the view has no owner
to outlive. An index out of range panics.

The `Option` from `get_environment` distinguishes a missing variable from a
present empty value: a variable set to the empty string is present, and a value
another thread changes or removes during the call reads as one of the states
it passed through. Its owning result uses the supplied allocator. Environment
names and values must become valid UTF-8 or the operation returns invalid data.
A name must be non-empty and contain neither `=` nor U+0000. All three
environment operations reject such names as `Invalid_Data`, with operation
`Environment` and native code zero, before consulting the platform.
A value or path passed in containing U+0000 is invalid data as well.
`set_working_directory` given an existing file returns `Invalid_Path`,
preserving the native error number. In Windows process and
filesystem calls, path errors 123, 161, 206, and 267 all have that code.
Starting another process is [`core:process`](#coreprocess).

## `core:process`

A child process is started from a `Command` and owned by the `Child` it returns:

```loke
Stdio :: enum {Inherit, Null, Pipe}

Variable :: struct {
	name:  string_view,
	value: string_view,
}

Command :: struct {
	program:     string_view,
	arguments:   []string_view,
	environment: Option([]Variable),
	directory:   string_view,
	stdin:       Stdio,
	stdout:      Stdio,
	stderr:      Stdio,
}

Child :: move_only struct {
	stdin:  Pipe,
	stdout: Pipe,
	stderr: Pipe,
	// and the process, private to the package
}

Pipe :: move_only struct { /* private */ }

Output :: struct {
	status: i32,
	stdout: [dynamic]u8,
	stderr: [dynamic]u8,
}

spawn(command: Command) -> Result(Child, io.Error)
run(command: Command) -> Result(i32, io.Error)
output(command: Command) -> Result(Output, io.Error)
Child.id(self) -> u32
Child.wait(self: inout Child) -> Result(i32, io.Error)
Child.kill(self: inout Child) -> Status(io.Error)
Pipe.read / write / close / is_open
```

The rules, each one explicit so that a child never gets something the parent
did not ask for:

- **Program.** A `program` that contains `/` or `\` is a path, relative to
  the parent's working directory, and is used as written. Any other name is
  looked up in each directory of the parent's `PATH`, in order, as written and
  then with `.exe` added when it has no extension (`core:path.extension`, so
  a leading dot alone is not one). The working directory and
  the parent's own directory are not searched. A name found nowhere is
  `Not_Found`.
- **Arguments.** `arguments` follow the program, which the child sees as its
  first argument, as given. Each argument reaches the child unchanged: on
  Windows they are quoted by the rules `CommandLineToArgvW` and the C runtime
  parse back, and a program containing `"` cannot be quoted, so it is
  `Invalid_Data`. Text containing U+0000 is `Invalid_Data` as well.
- **Environment.** `.none` gives the child a copy of the parent's environment
  when it starts; `.some(variables)` gives it exactly those, and an empty slice
  gives it none. Names follow the `core:os` rules, and a name given twice,
  ignoring ASCII case, is `Invalid_Data`.
- **Directory.** An empty `directory` keeps the parent's working directory;
  any other is the child's.
- **Standard handles.** Each of `stdin`, `stdout`, and `stderr` is the parent's
  own stream (`Inherit`), the null device (`Null`), or a new pipe whose other
  end is the `Child`'s field of that name (`Pipe`). A parent with no such
  stream gives the child none. The child inherits those three handles and no
  other: a file or pipe the parent has open never leaks into it. `spawn` first
  writes out what `core:fmt` holds for standard output, so a child writing to
  an inherited stdout comes after it.
- **Pipes.** A `Pipe` is an `io.Reader` and an `io.Writer`, owned like an
  `fs.File`: its zero value is closed, `close` reports a failure, and `drop`
  closes it. `stdin` is written and the other two are read; the other direction
  is `Unsupported`, and a field the command did not pipe is closed. A read
  after the child has closed its end is `End_Of_Input`. Pipes are not
  buffered without bound: a parent that waits for a child, or reads one pipe to
  its end, while the child fills the other can deadlock.
- **Waiting.** `wait` first closes `stdin`, so a child reading to the end of
  its input finishes, then blocks until the child exits and returns its exit
  status. Waiting again returns the same status. On Windows the status is the
  exit code reinterpreted as `i32`, so a crash shows as its negative `NTSTATUS`.
  `run` spawns, waits, and returns the status. `output` pipes stdout and
  stderr, closes a piped stdin, reads both to their end at once, stderr on a
  thread of its own so neither pipe can fill and deadlock, and waits. When
  either read fails, `output` kills the child and returns that error.
- **Lifetime.** `kill` ends the child at once, with status 1 on Windows, and
  succeeds if the child has already exited. Dropping a `Child` closes its pipes
  and its handle to the process without waiting or killing: the child runs on,
  detached.

`spawn` fails with operation `Spawn`, `wait` with `Wait`, and `kill` with
`Kill`. `run` reports either of the first two. Spawning takes its scratch
storage — the program path, the command line, the environment block — from the
default allocator, and reports a failed allocation as `Out_Of_Memory` rather
than panicking. `output` also starts a thread to read stderr, and running out
of memory or threads there panics, as `thread.spawn` does.

Example (imports `core:process` and `core:io`):

```loke
compiler_version :: proc(program: string_view) -> Result(process.Output, io.Error) {
	return process.output(process.Command{
		program = program,
		arguments = []string_view{"-version"},
	});
}
```

Call with a path such as `"./lokec.exe"` when the compiler is in the current
directory. `output` drains both pipes and returns bytes; check `status` and
validate UTF-8 before treating them as text.

## `core:math`

`design.md` "Library numeric types" makes `Complex(T)` and `Quaternion(T)`
ordinary records. `design.md` "Type conversion" specifies `math.wrap(T, value)`,
which keeps an integer's low bits, and `math.to(T, value)`, which returns
`Option(T)`; `design.md` "Integer overflow" specifies `wrapping_add`,
`wrapping_sub`, and `wrapping_mul`, the procedure forms of `+%`, `-%`, and
`*%`, and `checked_add`, `checked_sub`, and `checked_mul`; `design.md`
"Integer operators" specifies `floor_div` and `floor_mod`, the floored
counterparts of `/` and `%`.

For any `interfaces.Numeric(T)`, `Complex(T)` has the fields `real` and
`imaginary`, and `Quaternion(T)` has `real`, `i`, `j`, and `k`. Both have
`from_components`, a conversion hook from `T` written `Complex(f64)(x)`, `+`,
unary and binary `-`, `*`, `==`, `conjugate`, and `norm_squared`; `Complex` also
has `/`. Quaternion multiplication follows Hamilton, so `i*j == k` and
`j*i == -k`. At `f32` and `f64` both types add `abs` and `inverse`. `abs` uses
`hypot`, and complex division uses Smith's method, so finite non-zero
components do not overflow merely because their squares would. A value prints
as `1-2i` or `1+2i-3j+0k`, each component with the caller's `fmt.Options`. A
component with its sign bit set brings its own `-`, negative zero included.

The rest of the package is:

- unfixed constants `PI`, `TAU`, `E`, `LN2`, `LN10`, and `SQRT_TWO`, and, per
  format, `F32_`/`F64_` `EPSILON`, `MAX`, `MIN_NORMAL`, `MIN_SUBNORMAL`,
  `INFINITY`, and `NAN`, each written as its exact IEEE-754 bit pattern;
- `is_nan`, `is_infinite`, `is_finite`, `sign_bit`, `abs`, and `copy_sign`, which
  are bit tests: no rounding, and a NaN is never quieted;
- `min`, `max`, and `clamp` over any numeric, ordered `T`; `clamp` with
  `high < low` panics;
- `floor`, `ceil`, `round`, `trunc`, `mod`, `sqrt`, `hypot`, `fma`, `pow`,
  `exp`, `log`, `log2`, `log10`, `sin`, `cos`, `tan`, `asin`, `acos`, `atan`,
  `atan2`, `to_radians`, and `to_degrees`.

Floating-point functions use an unsuffixed name for `f64` and `_f32` for
`f32`, avoiding ambiguous overloads for untyped literals. There is no implicit
widening and no `f16` variant.

The procedures backed by the C library promise the classifications, signs,
poles, and domain results documented on each one. They do not promise correctly
rounded results, a particular NaN payload, or `errno` contents, and they never
turn a floating-point exception into a panic. `fma(a, b, c)` is not one of
them: it computes `a*b + c` with a single rounding, correctly rounded, since
`design.md` "Floating-point operators" never fuses the written expression. Its
result does not depend on the C library, and the product's exponent is not
bounded, so a finite product too large for the format still meets the addend.
On a [CPU level](compiler-guide.md#cpu-levels) with an FMA instruction it is
that instruction, and elsewhere integer arithmetic; the results agree, except
which NaN a NaN operand yields, which neither promises.

The transcendental functions are not deterministic: `pow`, `exp`, `log`,
`log2`, `log10`, `hypot`, `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, and
`atan2`, in both widths, and the `abs` of `Complex` and `Quaternion`, which uses
`hypot`, can give different last bits for the same arguments. The C library
chooses its algorithm by the processor's features, so one executable can
disagree with itself on another machine; an optimized build can evaluate a
call with constant arguments using the compiling machine's library; and
another platform has another library. Code whose results must agree bit for
bit everywhere, such as a lockstep simulation or content generated from a
shared seed, should not use them; [`core:math/repro`](#coremathrepro) has
the functions it implements with results that agree. The remaining
procedures, `sqrt` and `mod` included, are exact or correctly rounded, so
their results are the same everywhere. See
[Deterministic math functions](open-questions.md#deterministic-math-functions).

## `core:math/repro`

Each procedure returns its exact mathematical result rounded once to the
result's width, to nearest with ties to even, with gradual underflow and
overflow to infinity. The result is therefore the same bits on every machine,
[CPU level](compiler-guide.md#cpu-levels), and optimization level, and when a
call is evaluated at compile time. No procedure calls the C library or uses
`math.fma`, so none depends on the processor's FMA either. Every NaN result
is the positive quiet NaN with no payload (`0x7ff8000000000000`,
`0x7fc00000`), whatever NaN produced it.

The package has `exp`, `log`, `pow`, `sin`, `cos`, `asin`, `acos`, `atan`,
and `atan2`, each with the `f64` and `_f32` naming of `core:math`. A function missing here is
not provided by falling back to `core:math`. Each `_f32` procedure is rounded
once to `f32`, not the `f64` one narrowed, which could round twice.

- `exp` of NaN is NaN, of +Inf is +Inf, of -Inf is +0, and of ±0 is exactly
  1.
- `log` is the natural logarithm. NaN and every argument below zero, -Inf
  included, give NaN; ±0 gives -Inf, 1 gives +0, and +Inf gives +Inf.
- `pow(x, y)` is x^y, with the special cases of IEC 60559 and C17's annex F
  but for NaN results, in this order: y = ±0 gives 1, and so does x = +1,
  NaN included; any other NaN argument gives NaN. x = ±0 gives ±Inf for an
  odd integer y < 0, with x's sign, +Inf for any other y < 0, ±0 for an odd
  integer y > 0, and +0 for any other y > 0. x = -1 and y = ±Inf give 1;
  |x| < 1 gives +Inf for y = -Inf and +0 for +Inf, and |x| > 1 the reverse.
  x = -Inf gives -0 for an odd integer y < 0, +0 for any other y < 0, -Inf
  for an odd integer y > 0, and +Inf for any other y > 0; x = +Inf gives +0
  for y < 0 and +Inf for y > 0. A finite x < 0 gives NaN when y is not an
  integer, and -|x|^y when y is odd. An exact result, such as `pow(4, 0.5)`,
  is exact, and one exactly halfway between two floats, such as
  `pow_f32(1 + 2^-12, 2)`, rounds to even.
- `sin` and `cos` take radians. Every finite argument is reduced by an exact
  multiple of pi/2, however large. NaN and ±Inf give NaN; `sin(±0)` is ±0 and
  `cos(±0)` is exactly 1, and `sin(-x)` is `-sin(x)`.
- `asin` and `acos` give radians, from -pi/2 to pi/2 and from 0 to pi. NaN
  and every argument outside [-1, 1], ±Inf included, give NaN. `asin(±0)`
  is ±0 and `asin(±1)` is ±pi/2; `acos(1)` is +0, `acos(-1)` is pi, and
  `acos(±0)` is pi/2, each multiple of pi correctly rounded.
- `atan2(y, x)` is the angle from the positive x axis to the point (x, y),
  from -pi to pi with y's sign, with the special cases of IEC 60559 and
  C17's annex F but for NaN results: NaN gives NaN; y = ±0 gives ±pi for
  x = -0 or x < 0 and ±0 for x = +0 or x > 0; any other finite y gives ±pi/2
  for x = ±0, ±pi for x = -Inf, and ±0 for x = +Inf; and y = ±Inf gives
  ±pi/2 for a finite x, ±3pi/4 for x = -Inf, and ±pi/4 for x = +Inf, each
  multiple of pi correctly rounded. A quotient too small for the result's
  width gives a subnormal or a zero of y's sign; atan t is just below t, so
  a t exactly halfway between two floats rounds toward zero, and
  `atan2(3*2^-1074, 2)` is 2^-1074.
- `atan(x)` is `atan2(x, 1)`: NaN gives NaN, ±0 gives itself, and ±Inf gives
  ±pi/2.

The plan for the rest of the package, and its special cases for further
functions, is in the
[deterministic math and CPU targeting plan](deterministic-math-and-targets-plan.md#special-cases).

## `core:math/linalg`

Small vectors and matrices as ordinary records that never allocate, so that
two libraries can pass a point or a transform to each other as it is. The
design and its later milestones are in the
[linear algebra library plan](linear-algebra-plan.md).

`Vector2(T)`, `Vector3(T)`, and `Vector4(T)` have the fields `x`, `y`, `z`,
and `w` as their length allows, and the layout of `[N]T`.
`Matrix(T, R, C)` is `R` rows by `C` columns of any fixed shape, stored
column-major in `columns: [C][R]T`; `m[r, c]` reads `m.columns[c][r]`, and
`Matrix(f32, 4, 4)` has the layout of `[16]f32`, the order OpenGL takes with
`transpose = GL_FALSE` and Direct3D and Vulkan shaders read as
`column_major`. Vectors are columns: `m * v` transforms `v`, there is no
`v * m`, and `a * b` applies `b` first. Each element of a product is the dot
product of a row and a column, summed in index order from the first product.
A literal outside the package names its fields,
`linalg.Vector3(f32){x = 1, y = 2, z = 3}`, or uses `from_components`. The
package exports no short names; a program's own alias,
`Vec3 :: linalg.Vector3(f32);`, is the same type.

Arithmetic needs only `interfaces.Numeric(T)`, so integers, whose overflow
panics as for the scalar, and user number types get:

- on every vector: `from_components`, `splat`, `unit_x` to `unit_w`,
  `from_array` and `to_array`, `+`, `-`, unary `-`, component-wise `*` and
  `/`, `*` and `/` by a scalar and `*` of a scalar, exact `==`, `[]` with a
  runtime index that panics outside the components, `dot`,
  `length_squared`, `distance_squared`, and component-wise `min` and `max`;
  `Vector3` has `cross`, `extend(w)`, and `xy`; `Vector4` has `xyz`; and
  `Vector2` has `cross`, the z of the 3D cross product, `perp`, the quarter
  turn `(-y, x)`, and `extend(z)`;
- on every matrix: `splat`, `identity` where `R == C`, `from_columns`,
  `from_rows`, which reads as it is printed, `from_array` and `to_array` in
  storage order, `[r, c]`, `column`, `row`, `transpose`, `*` of
  `Matrix(T, R, K)` and `Matrix(T, K, C)`, `+`, `-`, unary `-`, `*` by and of
  a scalar, exact `==`, `trace`, `determinant` up to 4 x 4 by cofactor
  expansion along the first row, which is exact for integers, and `m * v`
  for a square matrix of the vector's length; `Matrix(T, N, 1).from_vector`
  and `to_vector` convert a column for `N` from 2 to 4;
- the transforms: `Matrix(T, 4, 4)` `translation`, `scaling`,
  `transform_point` (`w` 1), `transform_direction` (`w` 0), which never
  divide, `upper_left`, and `inverse_rigid`, which inverts a rotation plus a
  translation by transposition without checking that it is one;
  `Matrix(T, 3, 3)` `translation_2d`, `scaling_2d`, `transform_point_2d`,
  `transform_direction_2d`, and `extend` to 4 x 4; and `from_quaternion` at
  3 x 3 and 4 x 4;
- `rotate(q, v)`, which rotates `v` by the unit `math.Quaternion(T)` `q`.

A conversion hook converts each component as the scalar `T(value)` does, so
`linalg.Vector3(f32)(v)` narrows a `Vector3(f64)` and widens an integer
vector, and matrices of one shape convert the same way. `format` prints a
vector as `(1, 2, 3)` and a matrix by rows, `[[1, 2], [3, 4]]`, each element
with the caller's `fmt.Options`. A zero-initialized vector or matrix holds
`T`'s zero value, which is `T(0)` for the built-in numbers but not for every
user type; `splat(T(0))` is the zero matrix for any `T`.

A member that needs a square root, trigonometry, or a test for a degenerate
input needs `linalg.Real(T)`: `Numeric` and `Ordered`, unary `-`, a
conversion from `f64`, and the slots `sqrt`, `sin`, `cos`, `asin`, `acos`,
`atan2`, `abs`, `floor`, `ceil`, `round`, `is_finite`, and `is_normal`
(finite, non-zero, and full precision). The package implements it for `f32`
and `f64`, and a user type, such as a dual number for automatic
differentiation, implements it with inherent methods. Its generic bodies
compare with `<` and `==` alone, so a user type need not declare `<=`. A user
type declared in `package main` marks its operators and conversion
`@(public)`, since those requirements are checked in `linalg`. The `Real`
members are:

- on every vector: `length`, `distance`, `normalize`, `normalize_or`,
  `lerp(other, t)`, which is `self*(1 - t) + other*t` and exact at both ends,
  and component-wise `abs`, `floor`, `ceil`, and `round`;
- on a square matrix: `solve(b)` for any `Matrix(T, R, K)` right-hand side,
  `inverse`, and `determinant` above 4 x 4. They use Gaussian elimination
  with partial pivoting, the pivot the first element of largest magnitude in
  its column, in a fixed order;
- the rotations: `rotation_x`, `rotation_y`, `rotation_z`, and
  `rotation(axis, angle)` at 3 x 3 and 4 x 4, `Matrix(T, 2, 2).rotation(angle)`,
  and `Matrix(T, 3, 3).rotation_2d(angle)`; and the free procedures
  `quaternion_from_axis_angle(axis, angle)`, which takes the axis as given,
  and `quaternion_normalize`;
- the cameras, on `Matrix(T, 4, 4)`: `perspective`, `orthographic`,
  `look_at`, `look_to`, and the `_lh` form of each.

Angles are radians, and space is right-handed: `unit_x().cross(unit_y())` is
`unit_z()`, and a positive angle turns counterclockwise seen from the
positive end of the axis. A quaternion's `real` is its scalar part; a unit
`q` rotates as `q v q*`, `q` and `-q` rotate alike, and `rotate(a * b, v)`
rotates by `b` first, as `from_quaternion(a * b)` equals
`from_quaternion(a) * from_quaternion(b)` up to rounding.

`perspective(fovy, aspect, near, far, depth)` and
`orthographic(left, right, bottom, top, near, far, depth)` map a view space
looking down `-Z` with `+Y` up to clip space, with `x` and `y` in `[-1, 1]`,
`+Y` up, and `z` in the range `depth` names, the near plane at its first
value. `Depth_Range` has no default: `.Negative_One_To_One` is OpenGL's,
`.Zero_To_One` Direct3D's, Vulkan's, Metal's, and WebGPU's, and
`.One_To_Zero` reversed depth. A perspective's clip `w` is the view-space
`-z`, and an infinite `far` gives the limit of the matrix as `far` grows. A
field of view outside `(0, pi)`, a non-positive or infinite `aspect` or
`near`, `far <= near`, and a NaN panic; an orthographic box needs finite,
distinct bounds with `far` beyond `near`. Each `_lh` form takes the same
parameters for a view space looking down `+Z`: the projection is its twin
with the third column negated. `look_at(eye, target, up)` and
`look_to(eye, forward, up)` return the view matrix whose rows are the side,
up, and back directions (side, up, and forward for `_lh`), or `.none` when
the direction is zero or parallel to `up`.

Degenerate input is never a silent zero or NaN. `normalize` and
`quaternion_normalize` return `.none` when the squared length is not
`is_normal`: zero, underflowing or overflowing squares, an infinity, or a
NaN. `inverse` and `solve` return `.none` when a pivot is zero or NaN or a
result element is not finite; a nearly singular matrix still inverts, with
large elements, since no tolerance decides that it is singular.

`approx_equal(a, b, absolute, relative)` compares two scalars, vectors,
matrices, or quaternions with a `Real` element: every component pair has
`|a - b| <= max(absolute, relative * max(|a|, |b|))`. Both tolerances are
required, and a negative or NaN one panics. A NaN component is never equal,
and an infinity equals only itself, whatever the tolerances.

Every operation is computed in the order documented on it, with no `fma` and
no C library call: the `f32` and `f64` slots of `Real` are `math.sqrt`, which
is correctly rounded, and [`core:math/repro`](#coremathrepro). Results are
the same bits on every machine, [CPU level](compiler-guide.md#cpu-levels),
and optimization level. A call that does not reach `sqrt` can also be
evaluated at compile time with the same result; one that does cannot, since
`math.sqrt` calls a foreign procedure.

## `core:random`

`core:random` draws reproducible values from seeded generators and secret bytes
from the operating system. Every procedure takes the generator `inout`, as
`core:io` takes a stream; the package owns no generator of its own.

```loke
Source :: interface($Self: type) {
	slot next_u64: proc(self: inout Self) -> u64;
}

Xoshiro256 :: move_only struct { /* private state */ }

impl Xoshiro256 {
	from_seed    :: proc(seed: u64) -> Xoshiro256;
	from_entropy :: proc() -> Xoshiro256;
	from_state   :: proc(state: [4]u64) -> Xoshiro256;
	state        :: proc(self) -> [4]u64;
	next_u64     :: proc(self: inout) -> u64;
	jump         :: proc(self: inout);
	long_jump    :: proc(self: inout);
	split        :: proc(self: inout) -> Xoshiro256;
}

Pcg64 :: move_only struct { /* private state */ }

impl Pcg64 {
	from_seed    :: proc(seed: u64) -> Pcg64;
	from_entropy :: proc() -> Pcg64;
	from_state   :: proc(state: u128, increment: u128) -> Pcg64;
	state        :: proc(self) -> (state: u128, increment: u128);
	next_u64     :: proc(self: inout) -> u64;
	advance      :: proc(self: inout, delta: u128);
	split        :: proc(self: inout) -> Pcg64;
}

fill_secure(destination: []mut u8)
secure_u64() -> u64

in_range(source: inout $G, range: Range($T)) -> T
boolean(source: inout $G) -> bool
bernoulli(source: inout $G, probability: f64) -> bool
fill(source: inout $G, destination: []mut u8)
shuffle(source: inout $G, values: []mut $T)
choose(source: inout $G, values: []$T) -> Option(T)
unit(source: inout $G) -> f64
unit_f32(source: inout $G) -> f32
uniform(source: inout $G, low, high: f64) -> f64
uniform_f32(source: inout $G, low, high: f32) -> f32
normal(source: inout $G, mean: f64 = 0, standard_deviation: f64 = 1) -> f64
exponential(source: inout $G, rate: f64 = 1) -> f64
log_normal(source: inout $G, mean: f64 = 0, standard_deviation: f64 = 1) -> f64
gamma(source: inout $G, shape: f64, scale: f64 = 1) -> f64
beta(source: inout $G, alpha: f64, beta: f64) -> f64
chi_squared(source: inout $G, degrees_of_freedom: f64) -> f64
student_t(source: inout $G, degrees_of_freedom: f64) -> f64
geometric(source: inout $G, probability: f64) -> u64
poisson(source: inout $G, mean: f64) -> u64
binomial(source: inout $G, trials: u64, probability: f64) -> u64
sample(source: inout $G, values: []mut $T, count: int)

Weighted :: struct { /* private tables */ }

impl Weighted {
	from_weights     :: proc(weights: []f64,
		allocator: Allocator = mem.default_allocator()) -> Weighted;
	try_from_weights :: proc(weights: []f64,
		allocator: Allocator = mem.default_allocator()) -> Result(Weighted, Allocator_Error);
	len              :: proc(self) -> int;
	pick             :: proc(self, source: inout $G) -> int;
}
```

Each procedure taking a `source` requires `Source(G)`, so a caller's own source
and a `dyn mut random.Source` view work as well as either generator. `in_range`
accepts integer and rune endpoints of at most 64 bits, and `choose` a copyable
element type.

Example (imports `core:random`):

```loke
roll :: proc(rng: inout random.Xoshiro256) -> int {
	return random.in_range(inout rng, 1 ..= 6);
}
```

### Generators

`Xoshiro256` is xoshiro256++ (Blackman and Vigna, 2018): 256 bits of state, a
period of 2^256 − 1, and output identical to the reference implementation at
prng.di.unimi.it. It is the general-purpose generator for simulations, games,
sampling, and tests. Its output is predictable from earlier output, so it is
never a source of secrets; use [`fill_secure`](#operating-system-entropy).

`Pcg64` is PCG64-DXSM (O'Neill, 2014 and 2019): a 128-bit linear congruential
state, an odd 128-bit increment that selects one of 2^127 streams, and a period
of 2^128 per stream. Its output, seeding step, and `advance` are those of
numpy's `PCG64DXSM`, so a state that numpy reports draws the same 64-bit values
here. Choose it over `Xoshiro256` to move a stream any distance with `advance`,
or to match numpy's raw output.

A generator is move-only, so it cannot be duplicated by accident; a copy would
draw the same values as the original. Moving one into `thread.spawn` leaves the
caller without it. `split` and `from_state(rng.state())` are the explicit ways
to get a second generator.

### Seeding

- `from_seed(seed)` sets the state to the first four outputs of SplitMix64
  (Steele, Lea, and Flood, 2014) started at `seed`. The state is never all zero.
- The zero value is unseeded. Its first draw seeds it from the operating system,
  so `rng: thread_local random.Xoshiro256;` gives each thread its own stream,
  and a record holding a generator needs no initializer.
- `from_entropy()` seeds from the operating system at once.
- `state()` returns the whole state and `from_state` restores it exactly.
  An all-zero state is the unseeded zero value, so an unseeded generator's
  snapshot restores to an unseeded generator.
- `split()` returns a generator whose state is four draws from this one, each
  passed through the SplitMix64 finalizer. The child depends only on the
  parent's state, so splitting is reproducible however deeply it nests.
- `jump()` and `long_jump()` advance the state as 2^128 and 2^192 draws would.
  Giving each worker the current generator and then jumping divides one stream
  into blocks that cannot overlap.

`jump`, `long_jump`, and `split` on an unseeded generator seed it first.

`Pcg64` is seeded the same way, with these differences:

- `from_seed(seed)` takes the same four SplitMix64 outputs, high word first, as
  a 128-bit initial state and a 128-bit stream, then applies PCG's seeding: the
  increment is the stream shifted left with its low bit set, and the state is
  stepped once before and once after the initial state is added.
- `state()` returns the state and the increment, and `from_state` restores
  them. The increment must be odd; a state and increment of zero is the
  unseeded zero value.
- `advance(delta)` moves the state as `delta` draws would, in at most 128
  steps. The distance wraps modulo 2^128, so `advance(~u128(0))` steps back one
  draw. Advancing copies of one generator by multiples of a block length gives
  each worker its own block.
- `split()` seeds a child from four draws through the SplitMix64 finalizer, as
  `from_seed` uses its four words.

`advance` and `split` on an unseeded generator seed it first.

To make an unseeded run replayable, draw the seed with `secure_u64()`, record
it, and construct the generator with `from_seed`, as
[examples/dice.loke](examples/dice.loke) does. Do not seed from the clock or a
process ID: parallel runs started together share them.

Seeded generators, the procedures that compute on integers and floats, and
`fill`, `shuffle`, and `sample` can run during
[compile-time evaluation](design.md#compile-time-procedure-evaluation), for
example to build a table of random constants. `from_entropy`, a draw from an
unseeded generator, `fill_secure`, and `secure_u64` cannot. Neither can the
[distributions](#distributions), which call `core:math`, or
`Weighted.from_weights`, which allocates from a runtime allocator.

### Reproducibility

A seeded or restored generator produces the same sequence in every release.
The mapping from draws to values is part of each procedure's contract:

| Procedure | Draws |
| --- | --- |
| `in_range` | Lemire's nearly-divisionless method (2019): one draw per attempt, a new attempt only when the draw would bias the result. The result is `low` plus the offset. A range of all 2^64 values uses one draw as the offset. A one-value range still takes one draw. |
| `boolean` | One draw; its top bit. |
| `bernoulli` | One `unit` draw, compared with `probability`, even for 0 and 1. |
| `fill` | One draw per eight bytes, written little-endian; the unused bytes of a final partial draw are discarded. |
| `shuffle` | Fisher–Yates from the end: for each index `i` from the last down to 1, `in_range(0 ..= i)` picks the index to swap with. Fewer than two elements take no draw. |
| `choose` | One `in_range(0 ..< len)`; none for an empty slice, which answers `.none`. |
| `unit` | One draw; its top 53 bits times 2^-53, in [0, 1). |
| `unit_f32` | One draw; its top 24 bits times 2^-24, in [0, 1). |
| `uniform` | `low + (high - low)*u` for one `unit` draw `u`, or `low*(1 - u) + high*u` when `high - low` overflows; a result equal to `high` is drawn again. `uniform_f32` likewise with `unit_f32`. |
| `sample` | Fisher–Yates from the front: for each index `i` below `count`, `in_range(i ..< len)` picks the index to swap with. |
| `Weighted.pick` | One `in_range(0 ..< len)` picks a column, then one `unit` draw keeps it or takes its alias. |
| The distributions | See [Distributions](#distributions). |

Changing a generator's output or any of these mappings is a breaking change.
An unseeded generator is not reproducible.

### Distributions

Every distribution is built from `unit`, `open_unit` (an odd multiple of
2^-53 in (0, 1), from one draw's top 52 bits), and the standard normal and
exponential below, so its draws follow from the algorithm named here.

| Procedure | Algorithm and draws |
| --- | --- |
| `normal`, `exponential` | The ziggurat described below. |
| `log_normal` | `exp` of one `normal` draw; `mean` and `standard_deviation` are the logarithm's. |
| `gamma` | Marsaglia and Tsang (2000). Each attempt takes standard normal draws until `1 + c*z` is positive, then one `unit` draw for the squeeze and density tests. A shape below 1 samples `shape + 1`, then multiplies by `open_unit^(1/shape)`, from one more draw. |
| `beta` | Two gammas, `x / (x + y)`, when either shape exceeds 1. Otherwise Jöhnk's method, two `unit` draws per attempt. When both shapes are below 3e-103, one `unit` draw `u` gives 1 if `u < alpha / (alpha + beta)` and 0 otherwise. |
| `chi_squared` | Twice a gamma of shape `degrees_of_freedom / 2`. |
| `student_t` | A standard normal `z`, then a gamma `g` of shape `degrees_of_freedom / 2`; `z * sqrt(degrees_of_freedom / 2 / g)`, or an infinity of `z`'s sign when `g` is zero. |
| `geometric` | One `unit` draw `u`: `floor(log(1 - u) / log(1 - probability))`, the number of failures before the first success, capped at the largest `u64`. |
| `poisson` | No draw for a mean of 0. Below 10, Knuth's multiplication: one `unit` draw per unit of the result, plus one. From 10, Hörmann's PTRS (1993): two `unit` draws per attempt. |
| `binomial` | No draw for 0 trials or a probability of 0. With `p` the smaller of the probability and its complement, inversion when `trials * p` is at most 30: one `unit` draw per pass, and a pass that runs ten standard deviations above the mean starts over. Otherwise BTPE (Kachitvichyanukul and Schmeiser, 1988): two `unit` draws per attempt. For the complement the result is `trials` minus the count. |

`poisson` and `binomial` follow numpy's `random_poisson` and `random_binomial`
step for step, including numpy's correction to BTPE's final test, except that
`poisson`'s exact test computes the log mass by Loader's saddle-point method
(2000), which stays accurate where numpy's difference of large terms cancels.
`poisson` accepts a mean up to 2^62.

`normal` and `exponential` use a 256-layer ziggurat (Marsaglia and Tsang,
2000). One draw picks a layer from its low 8 bits and a position from its top
52 bits, so no bit serves both. About 99% of values are accepted from that one
draw. A value in a strip's wedge takes one more `unit` draw to test against the
density. A value in the base strip samples the tail: Marsaglia's method for the
normal, taking two draws per attempt, and one draw for the exponential. `normal`
returns `mean + standard_deviation*z` and `exponential` returns `x/rate`, for a
standard `z` or `x`.

The tables are constants in the source, and the common path uses no
`core:math` call. A wedge or tail value depends on `core:math.exp` and `log`,
and the other distributions call `exp`, `log`, `pow`, or `sqrt` on every value.
`exp`, `log`, and `pow` are not deterministic across machines (see
[`core:math`](#coremath)), so neither are the values that use them; see
[Random distributions across platforms](open-questions.md#random-distributions-across-platforms).

### Sampling

`sample(source, values, count)` moves a uniformly random `count` of the
elements to the front of `values`, in random order, so `values[:count]` is a
sample without replacement and the rest are the elements not chosen. Like
`shuffle`, it swaps without running copy or drop hooks, so any element type
works.

`Weighted` draws an index in proportion to its weight in constant time, by
Vose's alias method (1991). `from_weights` builds the table in time and
storage proportional to the number of weights, and each `pick` costs two
draws. Weights must be finite and not negative, with a finite positive sum. A
zero weight's index is never drawn. The table's arrays come from the given
allocator: `from_weights` follows its failure policy and `try_from_weights`
returns the error. The construction is deterministic, so a table built from the
same weights picks the same indices from the same draws.

### Operating-system entropy

`fill_secure` fills a buffer from the operating system's cryptographically
secure generator: `BCryptGenRandom` with the system-preferred generator on
Windows, in requests of at most 1 GiB. These are the bytes for keys, tokens,
and nonces. `secure_u64` is eight of them, little-endian. Neither returns an
error: the system generator does not fail on a supported system, and if it
ever reported failure the program panics, rather than continue with
predictable bytes.

### Panics

These are programmer errors and panic, naming the procedure:

- an empty range: `high < low` for `..=`, `high <= low` for `..<`;
- `uniform` or `uniform_f32` bounds that are not finite or not `low < high`;
- a `bernoulli` probability outside [0, 1], or NaN;
- a `normal` or `log_normal` mean or deviation that is not finite, or a
  negative deviation;
- an `exponential` rate that is not finite or not positive;
- a `gamma` shape or scale, a `beta` shape, or `chi_squared` or `student_t`
  degrees of freedom that are not finite or not positive;
- a `geometric` probability outside (0, 1], or a `binomial` probability
  outside [0, 1], or NaN;
- a `poisson` mean that is negative, NaN, or above 2^62;
- a `sample` count outside `0 ..= values.len()`;
- a `Weighted` weight that is not finite or is negative, or weights whose sum
  is not finite and positive;
- a `Pcg64.from_state` increment that is even, unless the state is zero too.

An endpoint type wider than 64 bits is rejected when `in_range` is
instantiated.

## `core:time`

`core:time` has clocks, durations, instants, the proleptic Gregorian calendar,
fixed UTC offsets, and ISO 8601 text. Dates and times print in the ISO 8601
extended format, in the RFC 3339 profile where one applies, and parse back. A
duration prints in a short form, `1h30m` or `153ms`; its ISO 8601 form,
`PT1H30M`, is one style away and parses too. There is no locale, no month or
weekday name in text, and no pattern language. Other forms are built from the
[accessors](#the-calendar) with [`fmt.zero_pad`](#corefmt), as in
`fmt.concat_to(w, fmt.zero_pad(date.day(), 2), ".", fmt.zero_pad(int(date.month()), 2), ".", date.year())`
for `15.10.2026`.

Named time zones and the system's local zone are not here yet; see
[Open questions in `core:time`](open-questions.md#open-questions-in-coretime).

| Type | Holds | Zero value |
| --- | --- | --- |
| `Duration` | Signed nanoseconds, a `distinct i64`: about ±292 years | No time |
| `Tick` | A monotonic clock reading | A reading at an unspecified moment |
| `Time` | An instant: nanoseconds since 1970-01-01T00:00:00Z in an `i64`, from 1677-09-21 to 2262-04-11 | The Unix epoch |
| `Date` | A date from 0000-01-01 to 9999-12-31, held as days since 1970-01-01 | 1970-01-01 |
| `Time_Of_Day` | Nanoseconds since midnight, less than 24 hours | Midnight |
| `Date_Time` | A `Date` and a `Time_Of_Day`, with no offset | 1970-01-01T00:00:00 |
| `Offset` | Whole minutes east of UTC, −23:59 to +23:59 | UTC |
| `Offset_Date_Time` | A `Date_Time` and the `Offset` it was read at | 1970-01-01T00:00:00Z |

Every zero value is a valid value. All of them are plain copyable data with no
resource to drop, so they cross threads freely. The four calendar types are the
four kinds of date and time ISO 8601 text distinguishes, and TOML's four:
local date, local time, local date-time, and offset date-time.

Everything except `now`, `tick_now`, and `sleep` is integer arithmetic in Loke,
so it also runs during
[compile-time evaluation](design.md#compile-time-procedure-evaluation).

### Clocks

```loke
now() -> Time
tick_now() -> Tick
Tick.elapsed(self) -> Duration
Tick - Tick -> Duration
Tick + Duration -> Tick
sleep(duration: Duration)
```

`now` reads the system clock: `GetSystemTimePreciseAsFileTime` on Windows, in
100-nanosecond units. It follows changes to the clock's setting, so a reading
can be earlier than the one before it. Measure intervals with `Tick`, which is
monotonic: `QueryPerformanceCounter` on Windows, scaled to nanoseconds by a
quotient and a remainder so the product cannot overflow. Only the difference
between two ticks of one process means anything.

`sleep` blocks the calling thread for at least `duration`; zero or a negative
duration returns at once. Windows' `Sleep` counts whole milliseconds on a
scheduler tick and can return early, so `sleep` sleeps again until a monotonic
reading shows the time has passed.

### Durations

```loke
Duration :: distinct i64
NANOSECOND, MICROSECOND, MILLISECOND, SECOND, MINUTE, HOUR :: Duration

Duration + Duration, Duration - Duration, -Duration, Duration * i64,
i64 * Duration, Duration / i64, Duration % Duration, comparisons
Duration.seconds(self) -> i64           // and milliseconds, microseconds;
                                        // each rounds toward zero
Duration.seconds_f64(self) -> f64
from_seconds_f64(seconds: f64) -> Option(Duration)
Duration.truncate(self, unit: Duration) -> Duration
Duration.round(self, unit: Duration) -> Duration
```

A `Duration` is exact, and arithmetic that overflows panics, as integer
arithmetic does ([Integer overflow](design.md#integer-overflow)). There is no
`DAY`: once a zone has daylight saving, a calendar day is not always 24 hours,
so steps of days belong to `Date`. There is no `Duration / Duration` either:
beside `Duration / i64` it would make `d / 2` ambiguous. A count of units is
`seconds()` and its siblings, or `i64(d) / i64(unit)`.

`from_seconds_f64` rounds to the nearest nanosecond and answers `.none` for a
NaN, an infinity, or a value beyond the range. `truncate` moves toward zero to
a multiple of `unit` and `round` to the nearest one, halves away from zero; a
unit of zero or less leaves the duration as it is.

A duration prints in the short form:

| Duration | Short form | ISO 8601 (`iso = true`) |
| --- | --- | --- |
| 90 minutes | `1h30m` | `PT1H30M` |
| 36 hours | `36h` | `PT36H` |
| 2 minutes 0.5 seconds | `2m0.5s` | `PT2M0.5S` |
| 1.5 seconds | `1.5s` | `PT1.5S` |
| 153 milliseconds | `153ms` | `PT0.153S` |
| 1.5 microseconds | `1.5µs` | `PT0.0000015S` |
| 250 nanoseconds | `250ns` | `PT0.00000025S` |
| None | `0s` | `PT0S` |
| −1.5 seconds | `-1.5s` | `-PT1.5S` |

- From one second up, the form is hours, minutes, and seconds, each written
  only when it is not zero, with a fraction only on the seconds. Below one
  second it is a single unit, `ms`, `µs`, or `ns`, the largest that leaves a
  whole number in front of the point, with a fraction as needed.
- Hours never roll over into days, for the same reason there is no `DAY`.
- A negative duration takes a leading `-`, which is also how Temporal writes
  a negative ISO 8601 duration and Java's `Duration.parse` reads one.

### Instants

```loke
Time :: struct { /* private: Unix nanoseconds */ }

from_unix_nanoseconds(nanoseconds: i64) -> Time
from_unix_seconds(seconds: i64) -> Option(Time)
Time.unix_nanoseconds(self) -> i64
Time.unix_seconds(self) -> i64          // rounds down
Time + Duration -> Time, Time - Duration -> Time, Time - Time -> Duration,
comparisons
Time.utc(self) -> Date_Time
Time.at_offset(self, offset: Offset) -> Offset_Date_Time
```

`Time` is Unix time: every day has 86 400 seconds and
[leap seconds](#leap-seconds) are not counted, as in POSIX, Go, Java, and
Rust. It prints in UTC with `Z`: `2026-10-15T12:34:56.789Z`. Arithmetic past
the range panics. `at_offset` never overflows: an instant at either end of the
range has a local date and time at every offset.

### The calendar

```loke
Month :: enum { January = 1, February, ..., December }
Weekday :: enum { Monday = 1, Tuesday, ..., Sunday }

Date.from_components(year: int, month: Month, day: int) -> Option(Date)
Date.from_unix_days(days: i64) -> Option(Date)
Date.year(self) -> int                  // and month, day, weekday, day_of_year
Date.iso_week(self) -> (year: int, week: int)
Date.unix_days(self) -> i64
Date.add_days(self, days: i64) -> Date
Date.add_months(self, months: i64) -> Date
Date.add_years(self, years: i64) -> Date
Date.days_until(self, later: Date) -> i64
is_leap_year(year: int) -> bool
days_in_month(year: int, month: Month) -> int

Time_Of_Day.from_components(hour, minute, second: int,
	nanosecond: int = 0) -> Option(Time_Of_Day)
Time_Of_Day.hour(self) -> int           // and minute, second, nanosecond

Date_Time :: struct { date: Date, time: Time_Of_Day }
Date_Time + Duration -> Date_Time, Date_Time - Duration -> Date_Time,
comparisons
Date_Time.at_offset(self, offset: Offset) -> Offset_Date_Time
```

The calendar is ISO 8601's proleptic Gregorian calendar, with year 0 the year
before year 1. Years 0000 to 9999 are the ones ISO 8601 writes in four digits
without prior agreement and the ones RFC 3339 allows. Weekdays are numbered as
ISO 8601 numbers them, Monday first, and `iso_week` gives the ISO 8601
week-numbering year and week: 2021-01-03 is in 2020's week 53.

`add_months` and `add_years` keep the day of the month unless the resulting
month is shorter, and then take its last day: 2026-01-31 plus one month is
2026-02-28, and 2024-02-29 plus one year is 2025-02-28. A computed date
outside the range panics, as integer overflow does. Dates read from input are
checked by the constructors and parsers, which answer `.none` or an error
instead.

Adding a `Duration` to a `Date_Time` counts every day as 24 hours: without a
zone there is no daylight saving.

`Time`, `Date`, `Time_Of_Day`, and `Date_Time` declare `<`, `<=`, `>`, and
`>=`, ordering chronologically, since a struct is not ordered field by field
([Comparison operators](design.md#comparison-operators)).

### Offsets

```loke
Offset :: struct { /* private: minutes east of UTC */ }
UTC :: Offset{}
Offset.from_minutes(minutes: int) -> Option(Offset)
Offset.minutes(self) -> int

Offset_Date_Time :: struct { date_time: Date_Time, offset: Offset }
Offset_Date_Time.to_time(self) -> Option(Time)
```

Offsets are whole minutes up to ±23:59, the range RFC 3339 writes.
`to_time` answers `.none` outside the range of `Time`.

`Offset_Date_Time` has `==` and no `<`. Two values for one instant at
different offsets are unequal, and ordering their fields would put the later
instant first; compare `to_time()` instead.

### ISO 8601 text

| Type | Prints | With `basic = true` |
| --- | --- | --- |
| `Time` | `2026-10-15T12:34:56.789Z` | `20261015T123456.789Z` |
| `Offset_Date_Time` | `2026-10-15T14:34:56.789+02:00` | `20261015T143456.789+0200` |
| `Date_Time` | `2026-10-15T14:34:56` | `20261015T143456` |
| `Date` | `2026-10-15` | `20261015` |
| `Time_Of_Day` | `14:34:56.789` | `143456.789` |
| `Offset` | `+02:00`, or `Z` when zero | `+0200` |
| `Duration` | `1h30m0.5s` | The same |

- Seconds always print. A fraction prints with as few digits as are exact, and
  not at all for whole seconds, as Temporal and Go's `RFC3339Nano` do.
- A zero offset prints `Z`; ISO 8601 treats `Z` and `+00:00` as the same
  offset.
- `fmt.Options` do not affect these types.

A wrapper chooses another form, as `fmt.fixed` does for floats:

```loke
Precision :: enum { Shortest, Seconds, Milliseconds, Microseconds, Nanoseconds }
Style :: struct { basic: bool, iso: bool, precision: Precision }
DEFAULT_STYLE :: Style{}
styled(value: $T, style: Style) -> Styled(T)
```

`iso` prints a `Duration` in ISO 8601 and does nothing for the other types,
which print ISO 8601 already. A fixed precision prints exactly that many
digits of a second, so every date and time of one type prints at one width and
the text sorts as the times do. It truncates and never rounds, so it never
prints a second that has not arrived yet. For a `Duration` it truncates to that
unit before the short form prints, so `.Milliseconds` gives `1.234s` and
`153ms`. `basic` drops the separators, which also makes a timestamp fit in a
Windows file name, where `:` is not allowed: `backup-20261015T123456Z.zip`.

```loke
Parse_Error :: enum { Invalid_Syntax, Invalid_Value, Missing_Offset, Out_Of_Range }

parse_time(text: string_view) -> Result(Time, Parse_Error)
parse_offset_date_time(text: string_view) -> Result(Offset_Date_Time, Parse_Error)
parse_date_time(text: string_view) -> Result(Date_Time, Parse_Error)
parse_date(text: string_view) -> Result(Date, Parse_Error)
parse_time_of_day(text: string_view) -> Result(Time_Of_Day, Parse_Error)
parse_offset(text: string_view) -> Result(Offset, Parse_Error)
parse_duration(text: string_view) -> Result(Duration, Parse_Error)
```

- Each parser reads what its type prints, in either format, but one value is
  all basic or all extended, as ISO 8601 requires. It also takes RFC 3339's
  allowances, lower-case `t` and `z` and a space in place of `T`, and ISO
  8601's comma as the decimal sign. Seconds are required, as in RFC 3339, and
  an offset is `Z` or a sign with hours and minutes.
- A fraction of any length is read. A timestamp's is truncated after nine
  digits. A duration's counts in full before the total is truncated to whole
  nanoseconds, so `0.0000000000002777778h`, a little over 1ns, reads as `1ns`.
- `-00:00` reads as `Z`. RFC 3339 used it for an unknown local offset, which
  RFC 9557 now writes as `Z`.
- Hour 24 is invalid, as in RFC 3339. Second 60 is a
  [leap second](#leap-seconds).
- `parse_time` and `parse_offset_date_time` require an offset, reporting
  `Missing_Offset` without one; `parse_time` converts to UTC.
  `parse_date_time` rejects an offset rather than drop it.
- `parse_duration` reads the short form and the ISO 8601 form. In either, the
  units come largest first, each at most once, with a fraction only on the
  last, and an optional leading `-`. The short form also takes `us` and the
  Greek `μ` for `µs`, as Go does. Years, months, weeks, and days are calendar
  units a `Duration` cannot hold exactly, so they are `Invalid_Value`.
- As in `core:strconv`, surrounding ASCII whitespace is allowed and anything
  else left over is `Invalid_Syntax`.
- `Invalid_Syntax` is the wrong shape. `Invalid_Value` is a field outside its
  range: month 13, 2026-02-29, minute 60. `Out_Of_Range` is a valid value the
  type cannot hold: a `Time` after 2262, a duration beyond ±292 years.

### Leap seconds

Second 60 reads as second 59, keeping its fraction. A leap second ends a UTC
minute, so with an offset it is valid only where the UTC minute is 59: local
minute 59 at `Z`, 29 at `+05:30`, 44 at `+05:45`. Elsewhere it is
`Invalid_Value`. A `Date_Time` or `Time_Of_Day` has no offset, and an offset of
whole minutes can make any minute end a UTC one, so these accept second 60 at
every minute. The date, hour, and minute stay as written, and the instant is
off by one second at most, as it is in every Unix clock during a leap second.
Printing never produces second 60, and `Time_Of_Day.from_components` does not
accept it.

## What is deliberately absent

There is no async I/O, networking, global keyboard input, GUI or full-screen
terminal UI, locale-sensitive text, Unicode normalization or grapheme
segmentation, globbing, regex, memory-mapped files, file locking, automatic
serialization, or general `core:util` package.

Planned additions and smaller gaps are listed in
[Standard-library maturity](future-plans.md#standard-library-maturity).

## Test requirements

See [Standard-library verification](compiler-architecture.md#standard-library-verification)
for required coverage and terminal checks. The checked library examples live
in [examples/](examples/) and [tests/run/](tests/run/).

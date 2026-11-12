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
| Read or write a binary format | [`core:encoding/binary`](#coreencodingbinary) |
| Detect accidental corruption with a CRC | [`core:checksum`](#corechecksum) |
| Call foreign text APIs | [`core:cstrings`](#corecstrings), [`core:encoding/utf16`](#coreencodingutf16) |
| Store integers in a fixed byte order, or read a field of validated bytes | [`core:endian`](#coreendian) |
| Access process state or start a child | [`core:os`](#coreos-additions), [`core:process`](#coreprocess) |
| Start threads, protect shared state, wait for it to change, pass work between tasks, with or without waiting, or run tasks on a pool | [`core:thread`](#corethread) |
| Use numeric functions and types | [`core:math`](#coremath), [`core:simd`](#coresimd) |
| Sort, search, partition, select, divide slices, or keep a heap in one | [`core:slice`](#coreslice) |
| Keep a queue, a priority queue, a few elements without allocating, or sets of enum values and indices | [`core:container`](#corecontainer) |
| Use arenas and other allocators | [`core:mem`](#coremem) |
| Use atomics, once-only initialization, or lazy values | [`core:sync`](#coresync) |
| Constrain generic code | [Standard interface catalogue](#standard-interface-catalogue) |
| Draw random numbers, shuffle, sample, derive stable seeds and IDs, or get secret bytes | [`core:random`](#corerandom) |
| Read clocks, work with dates and the local time zone, or print and parse ISO 8601 times | [`core:time`](#coretime) |

Start with the [design rules](#design-rules) for text, errors, and ownership.
The [package layout](#package-layout) lists the remaining foundational packages.
The [tutorials](../tutorials/README.md) teach complete programs from first steps.

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

A `try_` operation reports the failure that its ordinary form would panic on, and
leaves the value unchanged on failure. It returns a
[`Result`](design.md#typed-fallibility), never a bare `bool`:

- An operation that can fail only by allocating uses `Allocator_Error`.
- A never-allocating container such as
  [`Small_Array(T, N)`](#fixed-capacity-arrays) uses a library-declared error
  such as `Capacity_Error`.
- A success with nothing to return uses `Status(E)`.

### Streaming a fallible source

A fallible source returns `Result(Option(T), E)` at each step, distinguishing a
value, end of input, and failure. It is not an [iterable](design.md#iteration-protocol):
`foreach` has no error channel. Use an ordinary loop, `or_return`, and `switch`:

```loke
count_entries :: proc(directory: string_view) -> Result(int, io.Error) {
	reader := fs.read_directory(directory) or_return;
	total := 0;
	for (;;) {
		entry := reader.next() or_return;
		switch (entry) {
		case .some(found):
			total += 1;        // finish with `found` before the next step
		case .none:
			return .ok(total);
		}
	}
}
```

Each step propagates its own failure, so the loop belongs in a procedure whose
result is a compatible fallible union; a caller that continues afterwards calls
a helper like this one. A yielded value that borrows the source (an entry naming
the reader's own buffer) is valid only until the next step, and the switch arm
is where it is used. A move-only payload is consumed by the switch, written
`switch (move(entry))`.

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
base:runtime          compiler/runtime ABI types              *
base:meta             compile-time descriptors                *
base:interfaces       structural interface catalogue

core:mem              allocators and regions
core:unsafe           explicit trust boundary                 *
core:sync             atomics, fences, once, lazy values
core:simd             cross-lane SIMD operations
core:thread           threads, mutexes, monitors, channels, rings, and pools
core:fmt              value formatting and process diagnostics
core:strconv          scalar parsing
core:strings          UTF-8 algorithms and String_Builder
core:cstrings         owned zero-terminated buffers
core:encoding/utf16   UTF-8 to UTF-16 and back
core:encoding/json    JSON documents, values, and a streaming writer
core:encoding/binary  typed fields over bytes, bounded readers, sink-generic writers
core:checksum         CRCs of any catalogue parameter set
core:endian           fixed byte-order wrappers and byte-slice fields
core:math             elementary functions, Complex, Quaternion
core:math/repro       correctly rounded elementary functions
core:math/linalg      fixed-size vectors, matrices, rotations, projections
core:math/dense       run-time-sized matrices, views, LU, Cholesky, QR, eigenvalues, SVD
core:math/geometry    shapes, rays, frustums, polygons, overlap tests, exact predicates
core:random           seeded generators, entropy, distributions
core:time             clocks, durations, the calendar, ISO 8601 text
core:slice            slice algorithms, sorting, selection, heaps
core:container        Small_Array, Bit_Set, Enum_Array
                      index sets, Priority_Queue, Deque
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
	Set_Size,
	Lock,
	Unlock,
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
Buffer_Writer.bytes_mut(self: inout) -> []mut u8
Buffer_Writer.len(self) -> int
Buffer_Writer.clear(self: inout)
Buffer_Writer.into_bytes(self: move) -> [dynamic]u8
```

`Buffer_Writer` is an owning, growable byte sink that satisfies `Writer`, for
output assembled in memory before it is published, such as a document passed
to `fs.replace_atomic`. A write appends all of its bytes or none: an allocation
failure is `Out_Of_Memory` with operation `Write`, and the buffer is unchanged.
`bytes` borrows the contents, so a write while that view is in use is rejected,
and `bytes_mut` does the same for patching a finished record in place.
`clear` keeps the capacity for reuse, and `into_bytes` transfers the storage
without a copy. **The zero value is usable**: empty and allocator-unbound, its
first growth binding the default allocator; `init` selects another without
allocating.

### Bounded byte sink

```loke
Slice_Writer :: struct { /* private */ }
Slice_Writer.init(target: []mut u8) -> Slice_Writer
Slice_Writer.write(self: inout, source: []u8) -> Result(int, Error)
Slice_Writer.bytes(self: ^) -> []u8
Slice_Writer.len(self) -> int
Slice_Writer.space(self) -> int
```

`Slice_Writer` is `Buffer_Writer`'s fixed-capacity peer, for output into memory
the caller owns. A write that does not fit is `Out_Of_Space` with operation `Write`
and writes nothing, even where the `Writer` protocol would allow a prefix. An empty
write succeeds even when full. It never allocates, and its zero value is a usable
writer with no room.

### Formatting bridge

Use `io.write_formatted` for fallible output. A `fmt.Sink` cannot return an
error; the bridge stops writing after the first stream failure and returns that
error after formatting. `write_formatted_line` also appends a newline.

```loke
write_formatted(writer, args: ..dyn fmt.Formattable) -> Status(Error)
write_formatted_line(writer, args: ..dyn fmt.Formattable) -> Status(Error)
```

`fmt` formats into memory with:

```loke
to_string(allocator: Allocator, args: ..dyn Formattable) -> string
```

The allocator is a required leading parameter because the variadic consumes
the remaining arguments. For another sink, format in memory and call
`io.write_string`. To append formatted text to a builder, use
`builder.append(fmt.to_string(allocator, ...))`.

## Standard interface catalogue

`base:interfaces` exports the standard catalogue. Outside that package, use its
qualifier, as in `interfaces.Sequence(S)`. Built-in and user-defined types use
the same structural checks.

```loke
Equatable :: interface($T: type) {
	(a, b: T) a == b -> bool;
}

Ordered :: interface($T: type) {
	Equatable(T);
	(a, b: T) a < b -> bool;
}

Hashable :: interface($T: type) {
	Equatable(T);
	(value: T, seed: uint) value.hash(seed) -> uint;
}

Numeric :: interface($T: type) {
	T(0) -> T;
	T(1) -> T;
	(a, b: T) a + b -> T;
	(a, b: T) a - b -> T;
	(a, b: T) a * b -> T;
	(a, b: T) a / b -> T;
}

Integral :: interface($T: type) {
	Numeric(T);
	(a, b: T) a % b -> T;
	(a, b: T) a | b -> T;
	(a, b: T) a ~ b -> T;
	(a, b: T) a & b -> T;
	(a, b: T) a &~ b -> T;
	(a: T, shift: uint) a << shift -> T;
	(a: T, shift: uint) a >> shift -> T;
}

Cloneable :: interface($T: type) {
	slot try_clone: proc(self: ^, allocator: Allocator) -> Result(T, Allocator_Error);
}

// Satisfied by a built-in rule; it writes no requirement.
Callable :: interface($Self: type, $Signature: type) {}

Iterator :: interface($Self, $Item: type) {
	slot next: proc(self: inout Self) -> Option(Item);
}

Iterable :: interface($Self: type) {
	Self.Element -> type;
	Self.Iterator -> type;
	slot iter: proc(self: ^) -> Self.Iterator;
	Iterator(Self.Iterator, Self.Iterator.Item);
}

Reverse_Iterable :: interface($Self: type) {
	Iterable(Self);
	slot iter_reverse: proc(self: ^) -> Self.Iterator;
}

Mutable_Iterable :: interface($Self: type) {
	Self.Element -> type;
	Self.Mut_Iterator -> type;
	(value: inout Self) value.iter_mut() -> Self.Mut_Iterator;
	Iterator(Self.Mut_Iterator, Self.Mut_Iterator.Item);
}

Sequence :: interface($Self: type) {
	Iterable(Self);
	(value: Self) value.len() -> int;
	(value: Self, index: int) value[index] -> Self.Element;
}

Mutable_Sequence :: interface($Self: type) {
	Sequence(Self);
	(value: inout Self, index: int) value[index] -> inout Self.Element;
}

Growable_Sequence :: interface($Self: type) {
	Mutable_Sequence(Self);
	(value: inout Self, element: Self.Element) value.append(element) -> _;
}
```

- `Ordered` means the `<` operation is available; it does not promise a
  mathematical total order, so floating-point types satisfy it with IEEE-754
  comparisons. An algorithm needing a total or strict-weak order states that
  precondition or takes a comparator. `Numeric` does not compose `Ordered` and
  requires no ordering.
- `Cloneable` names the fallible public `try_clone` operation, not the
  policy-following `clone`. Every copyable type satisfies it, including plain
  values such as `int`, pointers, and slices, each of which is its own clone. A
  `@(move_only)` type, or a type that holds one in a field, does not.
- `Callable(C, Signature)` holds by a built-in rule; [Calling a
  value](design.md#calling-a-value) defines it, and `C.Result`.
- `Iterable` describes reading traversal, whose elements a built-in container
  lends rather than copies.
- `Mutable_Iterable` describes mutable traversal, met by a container's
  `iter_mut(self: inout)` and a mutable view's `iter_mut(self)` alike. Generic
  indexed mutation uses `Mutable_Sequence`.
- An owned iterator has `Item = Element`, so
  `Iterator(Self.Iterator, Self.Iterator.Item)` also accepts it.

Formatting has its own `Formattable` interface in `core:fmt`, described under
[String format printing](#printed-forms). Two capabilities have no
catalogue interface. UTF-8 text is its concrete `string`/`string_view` type.
Maps are constrained by their concrete `map[K]V` shape: a map's `Element` is its
`(key: K, value: V)` entry, so a map satisfies `Iterable` but not `Sequence`,
whose `value[index] -> Element` requirement an unordered keyed container cannot
meet.

Built-in satisfaction follows the operations the language already defines:

- `bool`, integers, floats, runes, `string`, `string_view`, pointers including
  `rawptr` and C pointers, enums, `typeid`, and recursively comparable fixed
  arrays satisfy `Equatable`; records and unions do so when their generated or
  inherent equality is available;
- integers, floats, runes, `string`, `string_view`, pointers on targets that
  support pointer ordering, enums, and anonymous records whose fields are all
  [ordered](design.md#comparison-operators) satisfy `Ordered`;
- `bool`, integers, runes, `string`, `string_view`, pointers, enums, `typeid`,
  fixed arrays of hashable elements, and records and unions with a [generated
  `hash`](design.md#maps) satisfy `Hashable`. Floats do not: a NaN is unequal to itself,
  so no hash is coherent with float `==`, and a float key could be inserted
  repeatedly and never found. A map keyed by a float value keys by an integer
  image of it instead, such as its bits through
  [`unsafe.transmute`](design.md#unsafetransmute) or a scaled, rounded integer. Other
  user records and unions require the inherent coherent equality/hash pair
  specified under [Maps](design.md#maps);
- built-in integer, floating-point, and rune types satisfy `Numeric`; integer
  and rune types satisfy `Integral`;
- every copyable type satisfies `Cloneable`. A plain value (`bool`, integers,
  floats, runes, enums, pointers, slices, views, `typeid`, and procedures) is
  its own clone; owning built-ins such as `string`, dynamic arrays, maps, and
  `Shared(T)`, and aggregates containing them, clone ownership-recursively.

The built-in iterables satisfy the iteration and sequence interfaces as follows.
Every one satisfies `Iterable`:

| Type | `Element` | Elements are | `Reverse_Iterable` | `Mutable_Iterable` | Sequence interfaces |
| --- | --- | --- | --- | --- | --- |
| runtime range | the endpoint type | owned | yes | no | none |
| `string`, `string_view` | `rune` | owned | no | no | none |
| fixed array | the stored element | lent | yes | yes | `Sequence`, `Mutable_Sequence` |
| `[]T` | the stored element | lent | yes | no | `Sequence` |
| `[]mut T` | the stored element | lent | yes | yes | `Sequence`, `Mutable_Sequence` |
| dynamic array | the stored element | lent | yes | yes | `Sequence`, `Mutable_Sequence`, `Growable_Sequence` |
| map | `(key: K, value: V)` | lent as `(key: ^K, value: ^V)` | no | yes | none |
| `reversed()` view | the source's | as the source's | yes | over a `[]mut T` | none |
| `indexed()` view | `(value, index)` | as the source's, index owned | no | over a `[]mut T` | none |
| text and map [views](design.md#iteration-adapters) | as each names | as each names | no | no | none |

`Mutable_Iterable` and `Mutable_Sequence` hold where the value is supplied as a
mutable place. The sequence interfaces also require a copyable element:
`value[index] -> Element` would copy a
[move-only](design.md#lifecycle-hooks-and-resource-types) element out of its place, and
every sequence interface composes `Sequence`, so a move-only element leaves a
container with none of them. It remains `Iterable`, and `foreach` borrows each
element. The standard `Small_Array(T, N)` and `Deque(T)` supply the same members as a
dynamic array and follow the same rule, since their copying members are
[excluded](design.md#where-clauses) for a move-only element.

## `core:mem`

The [allocator model](design.md#allocators) is part of the language; this package
adds its regions and low-level operations.

`Arena` and `Scratch` are move-only region owners. A fixed-buffer arena borrows
the supplied storage; provider-backed construction takes a parent allocator and
defaults it to the program provider. Ordinary construction applies the parent's
failure policy if the owner cannot be created, while the `try_` procedures
return a `Result` containing either the owner or an error, never a partial
owner. Every constructor takes a final `policy: mem.Failure_Policy`, `.Panic`
unless written, which the new region's own allocation failures follow; see
[Allocation failure](design.md#allocation-failure). A provider-backed child must be
dropped before its parent region is reset or ended. The zero `Arena` or
`Scratch`, which a `static` provider holds until it is assigned, owns an empty
region: allocating a byte or more from it fails, and resetting or dropping it
does nothing.

```loke
fixed := mem.Arena.from_buffer(&mut buffer[:]);
arena := mem.Arena.init(parent_allocator);
scratch := mem.Scratch.init();
outcome := mem.try_scratch(parent_allocator); // Result; handle before using the owner
embedded := mem.Arena.from_buffer(&mut buffer[:], policy = .Trap);
```

`mem.Failure_Policy` is `enum { Panic, Trap }`, and `init`, `from_buffer`,
`try_arena`, and `try_scratch` each take it.

Additional declarations are in the package's `api.loki`.

## `core:sync`

`core:sync` provides `Atomic(T)` for booleans, integers, runes, enums with
a supported integer backing type, pointers, and an `Option(^T)`, which is one
address (see [Representation](design.md#representation)) and starts as `.none`.

- Operations accept `.Relaxed`, `.Acquire`, `.Release`, `.Acquire_Release`, or
  `.Sequentially_Consistent` where meaningful. `core:sync.fence(order)` accepts
  every ordering except `.Relaxed`. Invalid type, operation, or ordering
  combinations are compile-time errors.
- Every operation, including writes, takes a read-only `self: ^` receiver.
  Atomic operations do not conflict with each other, so an `Atomic(T)` can be
  updated through a `^T`, including inside a `Shared(T)` payload.
- The plain `value` field is [`@(synchronized)`](design.md#synchronized). Outside
  `core:sync`, reading, writing, or borrowing it requires exclusive access
  through an owner, `^mut`, `[]mut`, or `inout`. Read-only borrows cannot access
  it. Even an owner's read of `value` conflicts with a live read-only loan of
  the atomic: another thread may write through that loan. `thread.Mutex(T)` and
  `thread.Monitor(T)` apply the same rule to their `value` fields.
- `Atomic(T)` is move-only, because copying one is a non-atomic read that yields
  a second, unrelated atomic. `Once` holds an `Atomic` and is move-only by the
  same structural rule.

### Atomic operations and Once

`core:sync` exposes the ordering type as `sync.Memory_Order`, an
`enum { Relaxed, Acquire, Release, Acquire_Release, Sequentially_Consistent }`
declared by `base:runtime`. Every ordering argument must be a compile-time
constant and defaults to `.Sequentially_Consistent`.

| Operation | Result |
| --- | --- |
| `a.load(order)` | the value; `order` is `.Relaxed`, `.Acquire`, or `.Sequentially_Consistent` |
| `a.store(value, order)` | nothing; `order` is `.Relaxed`, `.Release`, or `.Sequentially_Consistent` |
| `a.exchange(value, order)` | the previous value |
| `a.compare_exchange(expected, desired, success, failure)` | `(observed: T, swapped: bool)`: `swapped` says whether `desired` was written, and `observed` is the value found, which equals `expected` exactly when it swapped. `failure` permits what a load permits |
| `a.add`, `a.sub`, `a.bit_and`, `a.bit_or`, `a.bit_xor` `(value, order)` | the previous value. Integers only; `add` and `sub` wrap |
| `sync.fence(order)` | nothing; every ordering but `.Relaxed` |
| `once.do(action: proc())` | runs `action` exactly once across every thread that reaches `once`. A call that finds the action running waits for it, so a return means the action has completed and its writes are visible. An action that reaches its own `Once` never returns. If `action` panics, the `Once` is poisoned: every later call, and every call waiting on it, panics |
| `once.is_done()` | whether the action has completed; `false` may be stale when it is read |
| `lazy.get(init)` | a `^T` to the value of a `Lazy(T)`, made by calling `init`, a callable answering `T`, if no thread has yet. It runs as `once.do` runs an action: a call that finds `init` running waits, `init` must not reach its own `Lazy`, and a panic in `init` poisons it. The result borrows `lazy`. Every thread may reach the value as long as the process runs, so `init` is `@(escape=static)` and the value it makes is checked as an argument of a [`@(cross_thread)`](design.md#cross_thread) `move` parameter, as a channel's item is |
| `lazy.is_done()` | whether the value has been made; `false` may be stale when it is read |

`Once`, `Lazy(T)` for any `T`, and `Atomic(T)` for a `T` with a zero value, have
usable zero values, so each may live in `static` storage with no initializer. A
`Lazy(T)` holds a `Once`, so it is move-only, and its value is
`@(synchronized)`: `core:sync` writes it once, before `get` publishes it, and
only reads it after. An atomic pointer that starts empty is an
`Atomic(Option(^T))`.

## `core:simd`

`core:simd` supplies what the operators cannot spell. A lane index is constant,
so none of these can be written as a loop in ordinary Loke:

- `from_array(array) -> Simd(T, N)` and `to_array(v) -> [N]T`, the two
  conversions between a vector and an array of the same element and length. They
  are how vector data reaches ordinary code and how ordinary code reaches a
  vector;
- `select(mask, a, b) -> Simd(T, N)`, choosing lane-wise between two vectors,
  which is what a lane mask is for;
- `any(mask) -> bool` and `all(mask) -> bool`, which turn a lane mask back into
  control flow;
- `reduce_add`, `reduce_mul`, `reduce_min`, and `reduce_max`, each folding a
  vector to one scalar. A floating-point sum and product are ordered, left to
  right, so their results do not depend on the target's vector width; an integer
  sum and product fold left to right too, through the checked scalar operator,
  so they panic where that loop over the lanes would; a minimum and a maximum
  need no such rule, because they do not depend on order. A floating-point sum
  starts from `-0.0` and a product from `1.0`, so a vector of nothing but `-0.0`
  sums to `-0.0`. `reduce_min` and `reduce_max` ignore NaN lanes and return a
  number whenever any lane holds one; a vector of nothing but NaN reduces to
  NaN. Where two lanes compare equal, including `-0.0` against `+0.0`, either
  may be the answer.

The splat needs no procedure: a scalar in a vector position already is one.

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
- Both take the item by `move`, as a ring's `try_send` does. A temporary such
  as `Job{id}` needs no marker, and a place is written `move(job)`, which ends
  it. A place the sender goes on using, such as a counter, is sent as a copy:
  `send.send(next.clone())`.
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
@(move_only) Ring(T) :: struct               // no zero value; cannot move while split
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
@(move_only) Ring_Sender(T)   :: struct { ring: ^Ring(T), tail: uint, head_seen: uint }
@(wakes_on_drop)
@(move_only) Ring_Receiver(T) :: struct { ring: ^Ring(T), head: uint, tail_seen: uint }
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

1. **Model checking.** `tests/model/ring_model.py` searches every
   interleaving and every stale read that C11 release/acquire semantics
   permit, with every shared access one step, over one producer and one
   consumer, capacities 1, 2, and 3, two laps of the indices, stale peer
   caches, retries on a full ring, and every placement of either endpoint's
   drop. Each atomic location has one writer and every access is a release
   store or an acquire load, so the model is exact for the algorithm, and it
   includes every sequentially consistent interleaving. It found no violation
   of FIFO order, no overwrite or take of an empty slot, no data race on a
   slot, no `.closed` before the queue drained, no item owned twice or lost
   (including in the ring's drop), no send result other than `.closed` after
   one, and no drop failing to happen before its peer observes the side
   closed. Every seeded mutant fails: a relaxed `tail` or `head` store or
   acquire races on a slot; a relaxed `sender_gone` store or load loses the
   sender's last item; a relaxed `receiver_gone` store or load breaks only the
   drop's happens-before guarantee; and so does removing the final-tail reload
   or the fullness check. The reload at line 6 of `try_receive` needs no
   acquire, since line 5's acquire of `sender_gone` already orders the
   sender's last `tail` store; on x86-64 an acquire load costs nothing extra.
   The model checks the algorithm, not compiled code; item 4 checks the
   emitted orderings.
2. **The exclusive-endpoint API under the borrow checker.**
   `tests/err/lib_thread_ring.loke` rejects sharing either endpoint between
   two tasks, sending through a read-only endpoint, keeping the sender past a
   join whose task polls for closure, dropping the ring while split, and a
   borrowing item. `tests/run/lib_thread_ring.loke` moves the sender from a
   task to a task it starts, while another polls.
3. **A concrete application.** The audio loop in `examples/mixer.loke`
   polls a ring for its commands. A foreign audio callback cannot hold an
   endpoint, since endpoints borrow the ring
   ([unscoped channels](design-review-2026-10-31.md#later-concurrency-extensions)).
4. **Target validation and measurement.** In the emitted LLVM IR, the
   operations' loads and stores are `load atomic` acquire and `store atomic`
   release on naturally aligned fields, which x86-64 lowers to single
   instructions, and they call nothing that locks or allocates.
   `tests/pkg/ring_allocation` fills its default allocator, a fixed arena,
   until it refuses a byte, then runs a million operations, closure by either
   endpoint, and the ring's drop; an allocation seeded into either operation
   panics there.

   `tests/model/ring_measure.loke` measured an `int` ring of capacity 1023 on
   an Intel Core i5-9600K (six cores, Windows 10), built at `-opt=speed` by
   `lokec` at `85c586a7`, against copies of the algorithm that each change one
   thing. Figures are medians of 15 runs:

   - **Alone.** One thread sending 512 items, then receiving them, spends
     3.9 to 4.3 ns on a send and its receive. Checking `receiver_gone` at the
     start of every send costs 0.55 to 0.8 ns of that. A power-of-two mask in
     place of the end-of-array comparison saves 0 to 0.35 ns, about as much as
     code layout moves the figures between builds. A 16-byte slot, as
     `Ring_Slot(int)` is with its `live` count, costs 0.35 ns over an 8-byte one.
   - **Between threads.** One producer and one consumer pass an item in 4 to
     30 ns. The figures cluster near 4 ns and near 15 to 30 ns, and the build
     of the program, not the variant, decided where: the unchanged copy
     measured 4 to 9 ns in some builds and 20 to 22 ns in another, and with the
     flags on `head`'s line it measured 4 ns in one process and 13 to 34 ns in
     the rest. The library measured 7 to 19 ns. Whether the producer and
     consumer fall in step on the same cache lines likely outweighs the
     variants' differences, so this benchmark cannot rank them, nor confirm
     that keeping the flags off `head`'s line pays.
   - **Round trip.** An item sent out on one ring of capacity 16 and echoed
     back on another returns in a mean of 285 to 325 ns; the median is 200 ns
     and the 99th percentile 300 ns, at the clock's 100 ns resolution. One
     round trip in a thousand took 0.3 to 15 µs and the slowest 0.5 to 7 ms,
     which is preemption: no real-time bound follows.

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

print(args: ..dyn Formattable)
println(args: ..dyn Formattable)
eprint(args: ..dyn Formattable)
eprintln(args: ..dyn Formattable)
stdout() -> Writer
stderr() -> Writer
format_to(w: Writer, args: ..dyn Formattable)
concat_to(w: Writer, args: ..dyn Formattable)
format_to_with(w: Writer, options: Options, args: ..dyn Formattable)
to_string(allocator: Allocator, args: ..dyn Formattable) -> string

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

The variadic procedures take `..dyn Formattable`, so callers can mix types and
forward arguments: each argument is viewed where it is written and formatted
through its slot, and a `dyn Formattable` argument is passed as itself.
Extensions in other packages do not change a type's printed representation.

`println` and `eprintln` append a newline; `print` and `eprint` do not.
Arguments are separated by one space, except by `concat_to`, which writes them
back to back for a `format` method or a line whose punctuation is its own.
`Options.base` is 2 to 36 and any other
value reads as 10; it and `uppercase` reach integers and whatever a type's
`format` passes them to. A float prints the shortest spelling that reads back
as the same value at its own width. Floats always print with a `.` point,
whatever numeric locale foreign code has set for the C library; if the C
library cannot create its "C" numeric locale for this, printing a float panics.
[Printed forms](#printed-forms) gives every generated form, including floats and
the quoting of strings inside aggregates.

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

### Printed forms

A type defines how it is printed by declaring a `format` method in the same
package as the type:

```loke
Suit :: enum { Clubs, Diamonds, Hearts, Spades }
Card :: struct { rank: int, suit: Suit }

impl Card {
	format :: proc(self, writer: fmt.Writer, options: fmt.Options) {
		fmt.format_to(writer, self.rank, "of", self.suit);
	}
}

fmt.println(Card{7, .Hearts}); // 7 of Hearts
```

Each concrete type has one printed form throughout the program. Declaring more
than one eligible inherent `format` method for a type is an error; the compiler
provides a default `format` method for other printable runtime types, including
scalars and aggregates. These methods satisfy `fmt.Formattable(T)` and support
ordinary `dyn fmt.Formattable` views. An extension in another package may
declare and call its own `format` method, but `print` does not use it.

A generated method prints:

| Type | Printed form |
| --- | --- |
| `bool` | `true` or `false` |
| integer | its digits in `Options.base`, decimal by default |
| float | the shortest decimal that reads back as the same value, never spelled as an integer: fixed notation with at least one fractional digit from `1e-4` to below `1e17`, as `1.0`, `0.1`, and `-0.0`, and a bare exponent outside it, as `1e21` and `2.5e-5`; `nan`, `inf`, or `-inf` |
| `string`, `string_view`, `cstring_view`, `rune` | its text |
| `^T`, `^mut T` | the value it points to, as for `Box(T)` |
| `rawptr`, `[^]T`, procedure | `0x` and the address in hexadecimal, or `<nil>` |
| `typeid` | the type's name, which stops at `...` past about 4 KB |
| enum | the member's name, or the number of a value no member names |
| array, slice, dynamic array, `Simd` | `[1, 2, 3]` |
| map | `[key = value, ...]` in [iteration order](design.md#maps) |
| struct | `Name{x = 1, y = 2}`, with the public fields in declaration order |
| anonymous record | `(x = 1, y = 2)`, or `(1, 2)` when unlabeled |
| union, including `Option` | `.none` or `.some(3)`: the variant, and its payload in parentheses unless it is `Unit` |
| `Box(T)` | its payload |
| `dyn fmt.Formattable`, or a view of another interface with a `format` slot of `fmt.Formattable`'s shape, composed or declared | the value it views |
| any other `dyn` view | its type's name |

A struct prints its public fields only, as reflection from another package sees
it, because one printed form serves every package. A `package main`'s fields are
[public by default](design.md#exported-names), so a program's own `Point{1, 2}` prints
`Point{x = 1, y = 2}`; one with a `@(private)` field leaves it out. A `distinct`
type prints as the type it wraps, under its own name where that form has one.

A checked pointer is never null and always names a value, so it prints that
value, as every other checked view prints what it views: a map entry lent as
`(key: ^K, value: ^V)` prints its key and value. A program that wants the
address converts to `rawptr`. Printing follows a chain of pointers, as it
follows a chain of boxes; a cycle, which only [unchecked
code](design.md#the-unsafe-package) can build, does not terminate.

A field, element, map key, or union payload whose type is a string type, `rune`,
or a box or pointer to one prints quoted, escaping the backslash, the quote,
`\n`, `\r`, `\t`, and other control characters as a literal would:
`["a b", "c"]` and `.some('x')`. Printed on its own, as `fmt.println("a b")`, it
is its text. A type with its own `format` prints by it in both places.

For ordinary member lookup, a visible local extension named `format` takes
precedence over the generated default. Interface slot selection remains
independent of the caller's extensions. An inherent `format` must match the
slot, including the writer and options parameter modes; a generic method does
not supply this concrete slot.

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

`reserve(additional)` makes room for `additional` more bytes than are written.
A builder that has to grow gets exactly that capacity, as a
[dynamic array's `reserve`](design.md#dynamic-array-container-operations) does,
so code that reserves before each append reserves ahead.

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

@(move_only) Document :: struct { /* private */ }
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

## `core:encoding/binary`

Typed fields over bytes: a bounded `Reader` over a borrowed slice, and a `Writer`
into any `io.Writer`. A format names each field's width, and the byte order lives
in the cursor, set once, because it is one fact about the format. It is a run-time
value because TIFF and ELF announce theirs in the file. Nothing here panics on
malformed input, and nothing here allocates.

### Reading fields

```loke
Reader :: struct { /* private */ }

impl Reader {
	init       :: proc(bytes: []u8, order: endian.Order, base: u64 = 0) -> Reader;

	offset     :: proc(self) -> u64;
	remaining  :: proc(self) -> int;
	order      :: proc(self) -> endian.Order;
	set_order  :: proc(self: inout, order: endian.Order);

	get        :: proc(self: inout, $T: type) -> Result(T, Error) where endian.is_fixed_width(T);
	take       :: proc(self: inout, length: $N) -> Result([]u8, Error);
	skip       :: proc(self: inout, length: $N) -> Status(Error);
	sub        :: proc(self: inout, length: $N) -> Result(Reader, Error);
	seek       :: proc(self: inout, offset: u64) -> Status(Error);
	expect     :: proc(self: inout, bytes: []u8) -> Status(Error);

	get_length :: proc(self: inout, $T: type, limit: int) -> Result(int, Error)
		where endian.is_fixed_width(T), interfaces.Integral(T);
	get_count  :: proc(self: inout, $T: type, item_size: int, limit: int) -> Result(int, Error)
		where endian.is_fixed_width(T), interfaces.Integral(T);

	finish     :: proc(self) -> Status(Error);
	read       :: proc(self: inout, destination: []mut u8) -> Result(int, io.Error);
}
```

- **A failed operation changes nothing.** Every operation validates the whole field
  before moving, so after a failure `error.offset == r.offset()`, and the caller can
  retry, report, or try another reading. `get_length` and `get_count` stay on the
  count field when the count is refused.
- **Offsets are in the source's coordinates.** `offset()` is `base` plus the
  position. Pass a record's file offset as `base` and every error names a file
  offset, from subrecords too. A `base` that would overflow `u64` at the end of
  `bytes` panics, as a programmer error.
- **Lengths passed to `take`, `skip`, and `sub` may be any integer type**, because
  they usually come straight from the input. A negative `length` is
  `Invalid_Length`, and a positive one too big for `int` is `Unexpected_End`. Neither
  traps in a conversion or wraps in an addition: the bound is compared against what
  remains, and nothing is added first.
- **Encoded lengths and counts are fixed-width integers.** `get_length` and
  `get_count` accept only `u8` through `u128` and `i8` through `i128`; floats,
  native-width integers, `bool`, `rune`, and enums do not compile. A negative value
  read is `Invalid_Length`, and a non-negative value above `limit` is
  `Limit_Exceeded`, checked before the remaining-byte bound in `get_count`.
- **`sub` bounds a subrecord.** The child sees exactly `length` bytes and cannot read
  past them, whatever the parent still holds. The parent moves past the subrecord at
  once, so a malformed child cannot desynchronize it, and the child inherits the
  order and keeps absolute offsets. A child's `seek` stays inside the child.
- **Validate before allocating.** `get_length` reads a length and refuses one above
  `limit`, for a body not yet in memory. `get_count` also refuses a count whose items
  cannot fit in what remains, given each item's minimum encoded size, so the count
  is safe to pass to `make`. It divides rather than multiplies, so it cannot
  overflow. `limit` is required: the bytes remaining bound the wire size, and only the
  caller knows what an element costs in memory. A negative `limit` or an `item_size`
  below one panics.
- **Bytes outlive the cursor.** `take` and `sub` borrow the source slice, not the
  reader, so the reader stays usable while they are live and they may outlive it.
  The compiler rejects them outliving the *source*.
- **A copy is a checkpoint.** A `Reader` is a small value. `probe := r` peeks without
  a `peek` operation, and `r = saved` backtracks. Its zero value is a usable reader
  of no bytes.
- **`seek` is absolute**, in the same coordinates as `offset()`. A format with
  back-pointers can loop, so a parser following them must count its visits.
- **`finish`** is `Trailing_Data` unless everything was consumed. A format that
  allows an unread tail for forward compatibility does not call it.
- **`read`** is the [`io.Reader`](#shared-io-contract) slot, with that protocol's
  contract and error type, so `io.copy` and `io.read_line` work over bytes in memory.

```loke
Code :: enum {
	Unexpected_End, Invalid_Length, Limit_Exceeded,
	Invalid_Offset, Mismatch, Trailing_Data,
}

Error :: struct {
	code:   Code,
	offset: u64,
	length: u64,
}
```

| Code | Raised by | `offset` | `length` |
| --- | --- | --- | --- |
| `Unexpected_End` | `get`, `take`, `skip`, `sub`, `expect`, `get_length`, `get_count` | Start of the operation | Bytes wanted, or for `get_count` the items claimed; saturated to `u64` maximum |
| `Invalid_Length` | A negative length, passed or read | Start of the operation | Its low 64 bits |
| `Limit_Exceeded` | `get_length`, `get_count` above `limit` | The count field | The value read, saturated to `u64` maximum |
| `Invalid_Offset` | `seek` | Current position | The target |
| `Mismatch` | `expect` | Start of the expected bytes | Bytes expected |
| `Trailing_Data` | `finish` | Current position | Bytes left |

For a non-negative length, `length` is the exact value when it fits `u64`, and `u64`
maximum otherwise, which then reports a lower bound. Validation uses the original
integer before this conversion, so `u128(1) << 64` neither wraps to zero nor panics.

`Error` owns scalars and has public fields and a `format` member. A loader that also
does I/O names it and `io.Error` in a union of its own, using
[`or_return` with a variant](design.md#changing-error-domains). A caller's own check
on a field it just read has a field offset to report: capture `r.offset()` before
the `get`.

### Writing fields

```loke
Writer :: struct($W: type) where io.Writer(W) { /* private */ }

writer :: proc(sink: ^mut $W, order: endian.Order, base: u64 = 0) -> Writer(W);

impl Writer($W) {
	offset     :: proc(self) -> u64;
	order      :: proc(self) -> endian.Order;
	set_order  :: proc(self: inout, order: endian.Order);

	put        :: proc(self: inout, value: $T) -> Status(io.Error) where endian.is_fixed_width(T);
	put_bytes  :: proc(self: inout, bytes: []u8) -> Status(io.Error);
	put_length :: proc(self: inout, $T: type, length: int) -> Status(io.Error)
		where endian.is_fixed_width(T), interfaces.Integral(T);
	fill       :: proc(self: inout, length: int, value: u8 = 0) -> Status(io.Error);

	write      :: proc(self: inout, source: []u8) -> Result(int, io.Error);
}
```

- **`W` is any `io.Writer`**: `io.Buffer_Writer`, `io.Slice_Writer`, `fs.File`,
  a [`checksum.Crc`](#corechecksum), another `binary.Writer`, or `dyn mut io.Writer`
  where the sink is chosen at run time. Dispatch is monomorphic unless a `dyn` is asked for.
- **The width is visible at the call.** `put` takes its type from the value, and
  `is_fixed_width` rejects an `int`, so `w.put(count)` and `w.put(7)` do not compile.
  `w.put(u32(count))` panics if the count does not fit, as `u32(count)` always does.
  Use `put_length` when the value comes from data: a length that is negative or does
  not fit `T` is `Limit_Exceeded` with operation `Write`, and nothing is written. Its
  `T` has the same fixed-width integer restriction as `get_length` and `get_count`.
- **`offset()` counts what the sink accepted**, plus `base`. A failed `put` into a
  `Buffer_Writer` or `Slice_Writer`, which take all of a write or none of it, leaves
  it unchanged. A stream may accept part of a field before failing, and then
  `offset()` is inside the field, which is exactly where the stream stopped.
- **Offset exhaustion is checked before writing.** Every output operation compares
  its entire requested byte count with `u64` maximum minus `offset()`. A request above
  that space returns `Limit_Exceeded` with operation `Write`, without calling the
  sink or changing the offset, even if the sink would accept only a prefix. Reaching
  exactly `u64` maximum is allowed. Empty `put_bytes`, `fill(0)`, and empty `write`
  succeed without calling the sink, including at that offset.
- **`fill` validates its length before writing.** A negative length returns
  `Limit_Exceeded` with operation `Write` and changes nothing. After validation,
  filling may use several writes; a later sink failure leaves accepted chunks counted
  in `offset()`, even with a `Buffer_Writer` or `Slice_Writer`.
- **Failures are `io.Error`.** Sink errors propagate unchanged; invalid lengths and
  offset exhaustion use `Limit_Exceeded` with operation `Write`. A save routine
  composes `w.put`, `file.lock`, and `fs.replace_atomic` with a bare `or_return` and
  no error conversion.
- **A writer holds its sink's mutable borrow**, so a sink is read only after the
  writer's last use. Back-patching is [`endian.store`](#fields-of-a-byte-slice) over
  [`Buffer_Writer.bytes_mut`](#byte-buffer) or the caller's slice, once that use has
  passed.

```loke
buffer: io.Buffer_Writer = {};
w := binary.writer(&mut buffer, .Big);
w.put_bytes(MAGIC) or_return;
length_at := int(w.offset());
w.put(u32(0)) or_return;                     // patched below
w.put(u16(1)) or_return;
w.put_length(u16, entries.len()) or_return;

whole := buffer.bytes_mut();
body_length := whole.len() - length_at - 4;
endian.store(&mut whole[length_at:], u32(body_length), .Big);
```

## `core:checksum`

Checksums, for finding accidental corruption. `Crc_Params` is the Rocksoft model, the
fields of the [CRC RevEng catalogue](https://reveng.sourceforge.io/crc-catalogue/all.htm),
so a format's CRC is pinned by copying its row.

```loke
Crc_Params :: struct($T: type) where interfaces.Integral(T) {
	width:       int,
	polynomial:  T,
	initial:     T,
	reflect_in:  bool,
	reflect_out: bool,
	final_xor:   T,
}

Crc :: struct($T: type, $P: Crc_Params(T)) where valid_params(T, P) { /* private */ }

impl Crc($T, $P) {
	of     :: proc(bytes: []u8) -> T;
	update :: proc(self: inout, bytes: []u8);
	sum    :: proc(self) -> T;
	write  :: proc(self: inout, source: []u8) -> Result(int, io.Error);
}

valid_params :: proc($T: type, P: Crc_Params(T)) -> bool;

CRC32_ISO_HDLC :: Crc_Params(u32){ /* the table below */ };
CRC32_ISCSI    :: Crc_Params(u32){ /* the table below */ };
CRC64_XZ       :: Crc_Params(u64){ /* the table below */ };

Crc32  :: Crc(u32, CRC32_ISO_HDLC);   // zlib, gzip, PNG, ZIP
Crc32c :: Crc(u32, CRC32_ISCSI);      // iSCSI, ext4, Btrfs
Crc64  :: Crc(u64, CRC64_XZ);         // xz
```

- **A polynomial is in normal form** with the top bit implied, whatever the
  reflection: CRC-32 is `0x04C11DB7`, never its reversed form `0xEDB88320`. `T` is an
  unsigned integer as wide as `width` or wider.
- **A parameter set is checked at compile time.** `valid_params` rejects a signed or
  too narrow `T`, an even polynomial, and a value with bits above `width`. An
  importer's literal must name its fields (`L0709`), so a parameter set is always
  self-describing.
- **The zero value is the checksum of no bytes**, so `c: checksum.Crc32 = {}` is the
  only way to start and a forgotten initialization cannot exist. `c = {}` resets.
- **`update` in any pieces gives the same sum**, an empty piece included. `sum` does
  not disturb the state, so a running checksum can be read and continued.
- **`write` is the [`io.Writer`](#shared-io-contract) slot** and never fails, so
  `io.copy(inout crc, inout file)` checksums a stream with no whole-file buffer, and
  a `binary.Writer` can write into one.
- **Tables are constants**, computed at compile time per parameter set, so a program
  pays only for the sets it names. Their layout, and any use of faster tables or
  instructions, is not part of the contract.

The check value is the CRC of the nine bytes `123456789`.

| Catalogue name | Width | Polynomial | Initial | In | Out | Final XOR | Check |
| --- | --- | --- | --- | --- | --- | --- | --- |
| CRC-32/ISO-HDLC | 32 | `0x04C11DB7` | `0xFFFFFFFF` | yes | yes | `0xFFFFFFFF` | `0xCBF43926` |
| CRC-32/ISCSI | 32 | `0x1EDC6F41` | `0xFFFFFFFF` | yes | yes | `0xFFFFFFFF` | `0xE3069283` |
| CRC-64/XZ | 64 | `0x42F0E1EBA9EA3693` | all ones | yes | yes | all ones | `0x995DC9BBDF1939FA` |

### Using a CRC in a format

A format's specification should state the catalogue name and every parameter above,
the check value, the exact byte ranges covered, and the stored field's byte order.
The library guarantees the arithmetic; these choices are the format's:

- **A CRC finds accidental corruption.** It is not an identity, since collisions are
  easy to construct, and not security, since anyone can recompute it. A stable content
  hash is a separate decision for a separate package.
- **Cover something non-empty.** CRC-32 of no bytes is `0`, so a wiped record whose
  length and stored CRC both read as zero passes a check covering only the body. Cover
  the magic and the length too.
- **Check before trusting.** Verify a body's CRC before interpreting its fields, and
  still bound-check them, because a CRC does not defend against a crafted file.

## `core:slice`

`core:slice` has the slice algorithms. A `[]mut T` also has members the compiler
contributes, which need no import, for what no procedure could return, or what
reads better as a member. [Slices](design.md#slices) themselves are part of the
language.

### Swapping elements

`values.swap(left, right)` makes two elements of a `[]mut T` trade contents, and
`slice.swap(values, left, right)` is the free spelling of the same operation. A
dynamic array has the same member, as it has `sort`. Each index is
bounds-checked like any other, so an out-of-range one panics, and two equal
indices leave the element as it is.

```loke
names := [dynamic]string{"Ada", "Bo", "Cy"};
names.swap(0, 2);   // [Cy, Bo, Ada]
```

No copy or drop hook runs on either element, so a swap works for an element type
with neither a copy nor a zero value, unlike [`exchange`](design.md#exchange).
`slice.reverse` is built on it and reaches the same element types.

A read-only `[]T` has no `swap`, exactly as it has no `sort`.

### Splitting a mutable slice

`xs.split_at_mut(mid)` divides a `[]mut T` into the two mutable slices
`xs[:mid]` and `xs[mid:]`, returned as the [anonymous
record](design.md#anonymous-records) `(left: []mut T, right: []mut T)`. `mid` is checked
like a slice bound: it may equal `xs.len()`, leaving `right` empty, and a
negative or larger one panics.

```loke
left, right := xs.split_at_mut(xs.len() / 2);
left[0] = right[0];    // both halves are usable at once
```

The halves are one mutable [reborrow](design.md#weakening-and-reborrows) of `xs`, taken
after `mid` is evaluated, so `mid` may read `xs`. While either half is in use,
`xs` is suspended as it is for any reborrow, and neither half outlives what `xs`
views. The halves never overlap, so writing through one never conflicts with the
other. A borrow of a place in a half, such as `&mut left[0]`, is a reborrow of
that half: it keeps `xs` suspended while it is in use and does not conflict
with a place in the other half, whether each is reached through the half, a
copy of it, or a further split or chunk of it. The receiver may be any place
holding a `[]mut T`, such as `halves.left`, which is suspended as `xs` is.

No other spelling gives two mutable views of one sequence: `&mut xs[:mid]` and
`&mut xs[mid:]` are two reborrows of `xs`, which cannot be live at once, and a
procedure cannot return them together either. That is why this is a contributed
member rather than a `core:slice` procedure. A read-only `[]T` needs no such
member, since two read-only reslices may be live together.

### Chunks of a mutable slice

`xs.chunks_mut(n)` on a `[]mut T` is a view that yields `xs` in consecutive
mutable chunks of `n` elements, the last one shorter when `n` does not divide
`xs.len()`. A chunk length below one panics. The view is its own iterator,
`Chunks_Mut([]mut T)`, whose `Element` is `[]mut T`.

```loke
foreach (rows in pixels.chunks_mut(4096)) {
	shade(rows, scene);
}
```

Taking the view is one mutable [reborrow](design.md#weakening-and-reborrows) of `xs`, as
[`split_at_mut`](#splitting-a-mutable-slice) is, and the chunks share it: while
the view or any chunk is in use, `xs` is suspended. Unlike an element of a
[by-reference traversal](design.md#by-reference-iteration), a chunk is an owned `[]mut T`
and stays usable after the loop advances and after it ends, since no two chunks
overlap. A copy of a chunk is an ordinary reborrow of it, so a chunk binding is
suspended by its copies for the rest of its step, and the next step binds a new
chunk. A borrow of a place in a chunk, such as `&mut rows[0]`, is a reborrow of
that chunk in the same way: it stays usable after the loop advances, keeps the
view and `xs` suspended while it is in use, and does not suspend the chunk a
later step binds. The same holds of a place in a copy of the chunk, and of a
place in a chunk taken inside it, as by `rows.chunks_mut(m)`: each is in the
chunk the step bound, whatever name it is reached through. A chunk taken by
calling `next` directly is a reborrow of the view, so it ends before the view
advances. A `chunks_mut` view has no compile-time meaning yet.

### Sorting slices

`slice.sort` sorts ascending and `slice.reverse_sort` descending according to
the element type's `Ordered` implementation. `slice.sort_by` instead takes a
comparator:

```loke
sort_by :: proc(values: []mut $T, less: $C)
	where interfaces.Callable(C, proc(left, right: T) -> bool)
```

The comparator may be a plain `proc(left, right: T) -> bool`, or a record
containing configuration or checked borrows whose [`call`
method](design.md#calling-a-value) compares. It is borrowed for the call, retained
nowhere, and sorting allocates nothing. It must define a strict weak ordering.
The sort is not stable, so elements for which neither direction is before the
other may appear in either order. A comparator that is not a strict weak
ordering leaves the elements in an unspecified order rather than reaching past
them: the sort is still a permutation of the slice, and still terminates.

All three procedures accept `[]mut T`; passing a read-only `[]T` is a
compile-time error, because a read-only slice has no mutable storage to sort.

See [Calling a value](design.md#calling-a-value) and [Capture
literals](design.md#capture-literals) for callable comparators.

### Partitioning and selection

These reorder a slice in O(n) where a sort would cost O(n log n): splitting it
by a predicate, or finding the element at one sorted position, such as a median.

```loke
partition       :: proc(values: []mut $T, keep: $P) -> int      // accepted first; returns how many
is_partitioned  :: proc(values: []$T, keep: $P) -> bool         // no accepted element after a rejected one
partition_point :: proc(values: []$T, keep: $P) -> int          // index of the first rejected, O(log n)
select_nth_by   :: proc(values: []mut $T, n: int, less: $C)     // what sort_by would put at n
select_nth      :: proc(values: []mut $T, n: int)               // the same, ascending by Ordered
```

`keep` requires `interfaces.Callable(P, proc(value: T) -> bool)`, and `less`
requires `interfaces.Callable(C, proc(left, right: T) -> bool)` as for
[`sort_by`](#sorting-slices): either may be a plain procedure or a record whose
`call` method decides, is borrowed for the call, and is retained nowhere.
Nothing allocates, and nothing copies an element: elements only move by
[`swap`](#swapping-elements), so a move-only element and one with no zero value
are fine. `select_nth` requires `interfaces.Ordered(T)`, and relates to
`select_nth_by` as `sort` does to `sort_by`; a descending selection passes
[`slice.Descending(T){}`](#heaps).

After `partition`, the slice is a permutation of what it held, and `keep`
accepts exactly the elements in `values[:k]`, where `k` is the returned count.
`keep` is called exactly once per element, in an unspecified order, so an
expensive or counting predicate costs `n` calls. The order within each side is
unspecified. It makes at most `n / 2` swaps, in O(n).

`partition_point` is a binary search on a slice that `keep` already partitions,
returning the index of the first element it rejects: the general form of
`binary_search`, by any key. A slice that is not partitioned gets a meaningless
answer, not a trap. An empty slice gives 0 for `partition_point` and true for
`is_partitioned`.

After `select_nth_by(values, n, less)`, the slice is a permutation of what it
held, and:

- `values[n]` is equivalent to what `sort_by` would leave at index `n`.
- No `values[i]` with `i < n` comes after it: `!less(values[n], values[i])`.
- No `values[j]` with `j > n` comes before it: `!less(values[j], values[n])`.

Elements equivalent to `values[n]` may end up on either side, and nothing is
stable. A caller who needs a deterministic choice among ties puts the tie
breaker in the comparator, such as a key and then an id. `n` is checked like an
index, `0 <= n < values.len()`, so an empty slice always panics. Nothing is
returned: the two sides would be two mutable views at once, which is what
[`split_at_mut`](#splitting-a-mutable-slice) is for:

```loke
mid := prims.len() / 2;
slice.select_nth_by(prims, mid, By_Centroid{axis});
left, right := prims.split_at_mut(mid);                 // a median split, no full sort

count := slice.partition(prims, Left_Of{axis, split}); // a bucketed split instead
```

For a comparator that defines a strict weak ordering, selection takes O(n)
comparisons in the worst case, not only on average, and O(log n) stack. A
comparator that does not define one, or one that panics, leaves the slice an
unspecified permutation of what it held and nothing worse, and every call
terminates; the linear bound is not promised then. A NaN under `select_nth`
leaves an unspecified permutation, as it does for `sort`.

All three reordering procedures accept `[]mut T`; passing a read-only `[]T` is a
compile-time error.

### Heaps

These keep a binary heap in a slice the caller owns: a `Small_Array`, an arena
block, a record's fixed array, or a bounded window of a stream.
[`Priority_Queue`](#priority-queues) is the owning form, and is built on them.

```loke
make_heap     :: proc(values: []mut $T, less: $C)          // order the whole slice, O(n)
push_heap     :: proc(values: []mut $T, less: $C)          // the last element joins the heap before it
pop_heap      :: proc(values: []mut $T, less: $C)          // the first element moves to the last place
sift_heap_top :: proc(values: []mut $T, less: $C)          // restore the order after the first element changed
is_heap       :: proc(values: []$T, less: $C) -> bool

Ascending  :: struct($T: type) where interfaces.Ordered(T) {}   // callable: left < right
Descending :: struct($T: type) where interfaces.Ordered(T) {}   // callable: right < left
```

Each algorithm requires `interfaces.Callable(C, proc(left, right: T) -> bool)`,
borrows its comparator for the call, retains nothing, and allocates nothing, as
[`sort_by`](#sorting-slices) does. None copies an element, so a move-only element
is fine. An empty slice is a no-op, and is a heap. `Ascending` and `Descending` are
zero-sized comparators, usable with `sort_by` too. A fixed-capacity queue needs
nothing else:

```loke
open: container.Small_Array(int, 64) = {};
less := slice.Ascending(int){};

open.try_append(value) or_return;
slice.push_heap(open.slice(), less);

slice.pop_heap(open.slice(), less);
top := open.pop();
```

The layout is specified, because the storage belongs to the caller: a binary heap
in array order, with the first element first in the comparator's order, each
element's parent at `(i - 1) / 2`, and no element `less` than its parent. This is
`sort_by`'s direction, so `make_heap` puts the smallest first, where C++'s
`std::make_heap` puts the largest first.

A comparator must define a strict weak ordering. One that does not, or one that
panics, leaves the elements in an unspecified order and nothing worse: the slice
is still a permutation of what it held, and each call terminates.

### Slice queries and copies

`core:slice` also has these procedures. Only `fill` writes, and it takes
`[]mut T`; the rest read a `[]T`. The ordering queries require
`interfaces.Ordered(T)` and the searches `interfaces.Equatable(T)`.

| Procedure | Result |
| --- | --- |
| `is_sorted(values)`, `is_reverse_sorted(values)` | whether no adjacent pair is out of order under `<` |
| `binary_search(values, wanted) -> (index: int, found: bool)` | the leftmost index at which `wanted` could be inserted keeping the slice ascending, and whether the element there `==` `wanted` |
| `index_of(values, wanted)`, `last_index_of(values, wanted)` | `Option(int)`: the first or last index whose element `==` `wanted` |
| `contains(values, wanted)` | whether `index_of` finds `wanted` |
| `equal(left, right)` | whether the lengths match and every pair of elements is `==` |
| `min(values)`, `max(values)` | `Option(T)`: `.none` for an empty slice |
| `fill(values, value)` | assigns a copy of `value` to every element |
| `try_clone(values, allocator)` | `Result([dynamic]T, Allocator_Error)`: `clone` that returns an allocation failure rather than panicking |

`binary_search` requires an ascending slice; an unsorted one yields an
unspecified index, not a panic. `min` and `max` scan left to right and replace
their candidate only with an element strictly before or after it under `<`, so
equal elements keep the earliest, and a NaN is the answer only when it is first.
`clone` and `try_clone` take `allocator := mem.default_allocator()`.

## `core:container`

`Small_Array`, `Bit_Set`, `Enum_Array`, `Priority_Queue`, and `Deque`, with the
index sets below. The exact declarations are in the package's `api.loki`.

### Choosing a container

| Need | Use |
| --- | --- |
| A sequence that grows and shrinks at its end | `[dynamic]T` |
| The same, with a small fixed bound and no allocation | [`Small_Array(T, N)`](#fixed-capacity-arrays) |
| Add at one end, remove at the other; work at both ends | [`Deque(T)`](#deques) |
| Always take the most urgent element | [`Priority_Queue(T, C)`](#priority-queues) |
| The same, with no allocation or in a caller's buffer | [`core:slice` heap algorithms](#heaps) over a `[]mut T` |
| Pass items between threads | [`thread.Channel`](#channels), [`thread.Ring`](#rings) |
| Look up by key | `map[K]V` |
| Sets of enum members or small indices | `Bit_Set(E)`, [index sets](#corecontainer-index-sets) |

### Fixed-capacity arrays

`Small_Array(T, N)` is a library container with inline capacity `N`. It supports
indexing, slicing, iteration, and the usual container methods without
allocating. Operations that exceed `N` panic; their `try_` forms leave the value
unchanged and return `Status(Capacity_Error)`. Element copying follows the
ordinary copy rules.

Its inline storage is [capacity](design.md#uninitialized-capacity) rather than `N`
values, so `T` needs no zero value: an empty `Small_Array(T, N)` imposes exactly
what an empty `[dynamic]T` does. A copy clones the live elements only, and so
does a drop.

An invalid insertion index panics in both ordinary and `try_` forms. `pop()`
returns and removes the last element, or returns `.none` for an empty array.
`x[a:b]` is a read-only `[]T` over the live prefix, with either endpoint
omittable as for [user slicing](design.md#indexing-and-slicing); `slice()` is the whole
prefix as `[]mut T`, and a writable subrange is `slice()[a:b]`.

A [move-only](design.md#lifecycle-hooks-and-resource-types) element type is held too:

- The members that copy an element (`get`, the copying members of `append` and
  `insert`, and their `try_` forms) are bound on
  [`is_copyable(T)`](design.md#built-in-procedures), so they are
  [excluded](design.md#where-clauses) from such an instance.
- `append`, `insert`, `try_append`, and `try_insert` are [procedure
  groups](design.md#explicit-procedure-overloading) whose other member consumes, so
  `values.append(move(token))` or a temporary reaches it, as on a dynamic array.
  A consuming `try_` form that fails leaves the array unchanged and drops the
  element it took, as [container insertion](design.md#container-insertion) describes; a
  caller who must keep the element checks `space()` or `is_full()` first.
- `get_mut`, `view`, `slice`, `iter_mut`, `pop`, `remove`, `clear`, and
  [`foreach`](design.md#borrowing-iteration) copy nothing and are unaffected.

```loke
x: Small_Array(int, 8) = {};
x.append(1, 2, 3);
fmt.println(x.len(), x.cap()); // 3 8
```

### Conventions of the growable containers

`Priority_Queue` and `Deque` do what a dynamic array does wherever the two can be
compared, so that a call reads the same.

- **Fallible forms.** `push`, `append`, `reserve`, and the rest follow the
  allocator's [failure policy](design.md#allocation-failure). Each `try_` form
  returns `Status(Allocator_Error)` and leaves the container unchanged, under the
  [`try_` convention](#errors-are-values).
- **Element ownership.** Insertions are procedure groups, as on
  [`Small_Array`](#fixed-capacity-arrays): a borrowed place is copied, and a
  temporary or `move(x)` transfers. Under
  [container insertion](design.md#container-insertion), a failed `try_` form drops
  an element it took. A caller who must keep the element reserves first and then
  inserts, which cannot fail for want of space. `reserve` takes its capacity
  exactly, so a loop that does this for each element reserves ahead, as on a
  [dynamic array](design.md#dynamic-array-container-operations).
- **Move-only elements.** Held in full. Members that copy an element are bound on
  `is_copyable(T)` and are absent from a move-only instance. As for every
  container, the [sequence interfaces](#standard-interface-catalogue) then do not
  apply.
- **Borrowed elements.** An element may carry a borrow, and the container then
  carries it too, under [values that contain borrows](design.md#values-that-contain-borrows).
- **Absence.** `pop` and its relatives return `Option(T)`, and a peek returns
  `Option(^T)`. An empty container is not an error.
- **Programmer errors panic.** An index out of range panics, as an array index
  does, and so does a negative capacity.
- **Capacity is reusable.** `clear` drops the elements and keeps the storage, and
  only `shrink` gives storage back. A queue reused across searches or frames stops
  allocating once it has reached its largest size.
- **Allocators.** A zero value binds the default allocator when it first needs
  storage. `init` and `try_init` select another, since
  [`via`](design.md#assignment-statements) governs a clone into the variable and
  does not bind the storage of a record's dynamic-array field.

### Priority queues

```loke
Priority_Queue :: struct($T, $C: type)
	where interfaces.Callable(C, proc(left, right: T) -> bool) { /* private */ }

Min_Queue :: Priority_Queue($T, slice.Ascending(T));
Max_Queue :: Priority_Queue($T, slice.Descending(T));
```

```loke
jobs: container.Min_Queue(int) = {};
jobs.push(5);
jobs.push(2);
jobs.pop();   // .some(2)
```

The comparator is the one [`slice.sort_by`](#sorting-slices) takes, called `less`,
and it must define a strict weak ordering of the queued elements. `pop` returns an
element that no other queued element is `less` than, so a queue drains in an order
`sort_by` could produce with the same comparator: **the smallest first**. A
largest-first queue uses `Max_Queue` or a comparator written the other way around.

**Equal elements come out in an unspecified order**, which need not be arrival
order and may change between versions. A caller who needs one writes a tie breaker
into the element, usually a sequence number. [Anonymous records compare
lexicographically](design.md#comparison-operators), so this costs no comparator
logic:

```loke
Order :: (deadline: i64, sequence: u64);

By_Deadline :: struct {}
impl By_Deadline {
	call :: proc(self, left, right: Request) -> bool {
		return Order{left.deadline, left.sequence} < Order{right.deadline, right.sequence};
	}
}
```

A comparator that is not a strict weak ordering, a NaN under `Ascending(f32)`, or a
comparator that panics gives an unspecified order and nothing worse: every element
is still in the queue exactly once, and each operation still terminates.

The comparator is part of the queue's type and is stored in it, so a queue cannot
be pushed with one ordering and popped with another, a stateless comparator takes
no space, and the borrow checker protects what a comparator reads:

```loke
cost := [4]int{9, 1, 5, 3};
less := proc(left, right: int) -> bool capture(&cost) { return cost[left] < cost[right]; };
nodes := container.priority_queue(int, move(less));
nodes.push(0);
cost[0] = 2;      // L0511: `cost` is borrowed by the queue, which is used below
nodes.push(1);
```

A program whose keys must change keeps the key in the element and pushes a new
entry, skipping a popped entry worse than the best known one.

| Comparator | Example type | Zero value of the queue | Named in a file-scope record |
| --- | --- | --- | --- |
| Library | `slice.Ascending(int)` | yes | yes |
| Named record | `By_Deadline` | when its fields have one | yes |
| Procedure | `proc(left, right: T) -> bool` | no, `init` is required | yes |
| Capture literal | `type_of(less)` | no | no: [no signature can name it](design.md#capture-literals) |
| [Borrowed view](design.md#borrowed-callable-views) | `dyn proc(left, right: T) -> bool` | no | yes, and it carries its borrow |

A queue whose comparator has no zero value has no zero value either, and `= {}` is
a compile error (`L0424`). A type that is not a comparator is rejected where the
queue type is named (`L0444`). A move-only comparator makes the queue move-only, as
for any record.

```loke
Priority_Queue(T, C).init(less: move C, capacity := 0, allocator := mem.default_allocator()) -> Priority_Queue(T, C)
Priority_Queue(T, C).try_init(less: move C, capacity := 0, allocator := mem.default_allocator())
	-> Result(Priority_Queue(T, C), Allocator_Error)
Priority_Queue(T, C).from_items(items: move [dynamic]T, less: move C) -> Priority_Queue(T, C)

container.priority_queue($T: type, less: move $C, capacity := 0, allocator := mem.default_allocator())
	-> Priority_Queue(T, C)
```

The free `priority_queue` infers the comparator type, which a capture literal has
no other way to spell without first binding `Less :: type_of(less);`. Its result
carries the comparator's borrow, as the `init` result does. A stateless comparator
is spelled `{}`, as in `container.Max_Queue(int).init({}, 64)`.

| Member | Cost | Meaning |
| --- | --- | --- |
| `len()`, `cap()`, `is_empty()` | O(1) | As on a dynamic array. |
| `peek() -> Option(^T)` | O(1) | The element `pop` would return, lent until the queue next changes. |
| `push(value)`, `try_push(value)` | O(log n) amortized | Adds an element. |
| `pop() -> Option(T)` | O(log n) | Removes and returns the first element. Never allocates. |
| `push_pop(value) -> T` | O(log n) | As `push` then `pop` with one sift. Never allocates, so it works on a full queue. Keeps the k largest with a `Min_Queue` of k elements. |
| `update_top(change) -> bool` | O(log n) | Runs `change(inout top)` and restores the order, or is false when empty. |
| `retain(keep)` | O(n) | Drops each element for which `keep(item)` is false, then restores the order. |
| `reserve(n)`, `try_reserve(n)`, `shrink(min)`, `try_shrink(min)`, `clear()` | as on a dynamic array | Capacity, as on a dynamic array. |
| `from_items(items, less)` | O(n) | Takes over an array and its allocator and orders it; much faster than pushing each element. |
| `into_items(self: move) -> [dynamic]T` | O(1) | The elements in unspecified order, with the storage. |
| `into_sorted(self: move) -> [dynamic]T` | O(n log n) | The elements in `pop` order, in place. |
| `view() -> []T`, `iter()` | O(1) | Read every element, in unspecified order. |
| `format` | O(n) | Prints as an array, in unspecified order. |

The queue is `Iterable` but not a `Sequence`, because an index into a heap means
nothing a caller could use. No member exposes an element mutably except
`update_top`, which keeps the order correct. Its layout is unspecified: it is a
binary heap today, and a measured wider one could replace it. A copy clones the
elements and the comparator. Queues have no `==`, since two equal queues can have
different layouts.

### Deques

```loke
Deque :: struct($T: type) { /* private */ }
```

```loke
frontier: container.Deque(int) = {};
frontier.append(seed);
for (;;) {
	switch (frontier.pop_front()) {
	case .none:
		return;
	case .some(at):
		foreach (next in neighbours(at)) {
			if (visit(next)) { frontier.append(next); }
		}
	}
}
```

The names extend a dynamic array's: `append` and `pop` at the end, and `prepend`
and `pop_front` at the start. Generic code that accepts `[dynamic]T` therefore
accepts a `Deque(T)`, and replacing one with the other when `remove(0)` shows up in
a profile changes only the type and that one call. For a copyable element,
`Deque(T)` satisfies `Iterable`, `Reverse_Iterable`, `Mutable_Iterable`, `Sequence`,
`Mutable_Sequence`, and `Growable_Sequence`. A move-only element leaves it the three
iteration interfaces.

`Deque` and [`thread.Ring`](#rings) are both ring buffers and share nothing else.
`Ring` is a bounded communication primitive between two threads: it is move-only,
has no zero value, uses atomics, and never grows. `Deque` is an ordinary local value
that grows, copies when its elements do, and has no thread-safety of its own.

```loke
Deque(T).init(capacity := 0, allocator := mem.default_allocator()) -> Deque(T)
Deque(T).try_init(capacity := 0, allocator := mem.default_allocator()) -> Result(Deque(T), Allocator_Error)
```

The zero value is an empty, usable deque. A capacity is a lower bound.

| Member | Cost | Meaning |
| --- | --- | --- |
| `len()`, `cap()`, `is_empty()` | O(1) | As on a dynamic array. |
| `append(values)`, `try_append(values)` | O(1) amortized | Add at the end. The copying `try_` form takes several values and adds all or none. |
| `prepend(value)`, `try_prepend(value)` | O(1) amortized | Add at the start, one at a time, so the order is never in question. |
| `pop() -> Option(T)`, `pop_front() -> Option(T)` | O(1) | Remove from either end. Never allocate or move other elements. |
| `first()`, `last() -> Option(^T)` | O(1) | Lend an end, read-only. |
| `first_mut()`, `last_mut() -> Option(^mut T)` | O(1) | Lend an end, mutably. |
| `x[i]`, `x[i] = v`, `at(i) -> ^T` | O(1) | Indexed from the first element. `x[i]` reading copies, so a move-only element reads through `at`. |
| `insert(i, value)`, `remove(i) -> T` | O(min(i, n - i)) | Moves whichever side is shorter. |
| `retain(keep)` | O(n) | Keeps order, and drops each element for which `keep(item)` is false. |
| `reserve(n)`, `try_reserve(n)`, `shrink(min)`, `try_shrink(min)`, `clear()` | as on a dynamic array | Capacity, as on a dynamic array. |
| `as_slices() -> (front, back: []T)` | O(1) | The elements in order, as up to two runs; `back` is empty unless the ring has wrapped. For bulk copies and I/O. |
| `as_slices_mut() -> (front, back: []mut T)` | O(1) | The same, writable. |
| `make_contiguous() -> []mut T` | O(n) when wrapped | Rearranges in place so that one slice holds everything. Never allocates. |
| `iter()`, `iter_reverse()`, `iter_mut()`, `iter_mut_reverse()` | O(1) | Traverse from either end. `foreach` borrows, as for an array. |
| `==` | O(n) | Equal lengths and equal elements in order, regardless of where the ring starts. |
| `format` | O(n) | Prints as an array, in order. |

There is no `x[a:b]`, because a range may not be contiguous; `as_slices` and
`make_contiguous` say what is actually available. A copy clones the elements in
order into a new ring from the destination's allocator. A grown ring is allocated
before anything moves, so a failed allocation leaves the deque exactly as it was.

Whatever a deque lends keeps it borrowed, as for any container, including through
the unchecked storage beneath it. Each of these is rejected with `L0512`:

```loke
p := q.first();     _ = q.pop_front();  use(p);    // the pointer is live
p := q.at(0);       q.clear();          use(p);
a, b := q.as_slices();   q.append(2);   use(a);
foreach (v in q) { q.append(v); }                  // the iterator is live
```

A removed element retains what it borrows, and the allocator regions it was in, but
does not borrow the deque merely because it used to be stored there. It may outlive
the deque when its own sources remain alive:

```loke
out: []int = {};
{
	local := [1]int{42};
	q: container.Deque([]int) = {};
	q.append(local[:]);
	out = q.pop_front() or_else {};
}
use(out); // L0513: `local` has ended
```

Moving `local`'s declaration outside the block makes this valid.

`clear`, and through it an explicit `drop` and a normal scope exit, drops elements
first to last. If an element's drop raises the first panic under `unwind`, the
remaining elements still drop once, in the same order, before the storage is
released. A [second panic during unwinding](design.md#panic-during-unwinding) aborts
immediately; neither that case nor the `abort` strategy promises the rest.

## `core:container` index sets

A set of the indices `0 ..< cap`, one bit each, for the sets an engine keeps
over cells, entities, or slots: what was dug, what changed this frame, and what
a search has visited. `Bit_Set(Enum)` is not one: its members are an enum's
declaration positions, fixed at compile time.

```loke
Index_Set         :: struct($N: int) where N >= 0 { /* private */ }  // inline words
Dynamic_Index_Set :: struct { /* private */ }                         // allocated words
Index_View        :: struct { /* private */ }                         // caller's words, read
Index_View_Mut    :: struct { /* private */ }                         // caller's words, written

words_for_bits :: proc(cap: int) -> int;   // cap/64, rounded up
bytes_for_bits :: proc(cap: int) -> int;   // cap/8, rounded up

Index_Set(N).of(indices: ..int) -> Index_Set(N)
Index_Set(N).all() -> Index_Set(N)
Dynamic_Index_Set.init(cap: int, allocator := mem.default_allocator()) -> Dynamic_Index_Set
Dynamic_Index_Set.try_init(cap: int, allocator := mem.default_allocator())
	-> Result(Dynamic_Index_Set, Allocator_Error)
Dynamic_Index_Set.resize(self: inout, cap: int)
Dynamic_Index_Set.try_resize(self: inout, cap: int) -> Status(Allocator_Error)
Index_View.over(words: []u64, cap: int) -> Index_View
Index_View_Mut.over(words: []mut u64, cap: int) -> Index_View_Mut
```

The three representations share one contract and differ only in where the
words are:

- **`Index_Set(N)`** holds `words_for_bits(N)` words inline. It never
  allocates, its zero value is the empty set, and it is an ordinary value: a
  chunk's dirty or excavated cells live in the chunk record.
- **`Dynamic_Index_Set`** owns words from the allocator chosen by `init`, for a
  capacity known at run time. Its zero value is the empty set of capacity `0`.
  Copying one clones its storage, which the copy-cost diagnostic reports.
  `resize` keeps the indices below the new capacity, and those it adds are
  absent. `clear` keeps the storage, so a visited set is reused without
  allocating. `init` and `resize` follow the allocator's [failure
  policy](design.md#allocation-failure); `try_init` and `try_resize` return
  the `Allocator_Error` instead, under the [`try_`
  convention](design.md#appending-to-a-dynamic-array), and a failed
  `try_resize` leaves the set unchanged. Only growing allocates, so a
  `try_resize` to a smaller capacity always succeeds.
- **`Index_View`** and **`Index_View_Mut`** read and write a set stored in the
  caller's words, such as an arena or a field of the caller's own record.
  `over` panics unless `words.len()` is exactly `words_for_bits(cap)`. A view
  borrows its words, so it cannot outlive them, and a mutable one borrows them
  exclusively. Each owner lends one with `view` and `view_mut`, and
  `Index_View_Mut.as_view` lends a read-only one, so a procedure that takes an
  `Index_View` accepts every representation.

Every representation has these members; the writing ones need a mutable
owner or an `Index_View_Mut`, and `other` is an `Index_View`:

| Member | Meaning |
| --- | --- |
| `cap()` | The number of indices the set can hold. |
| `len()`, `is_empty()` | The number of indices present, and whether it is zero. |
| `contains(i)`, `i in set` | Whether `i` is present. `in` is `contains` as an [operator](design.md#operator-declarations), so it panics for an `i` outside `0 ..< cap` as `contains` does; `!(i in set)` is its negation. |
| `count_range(low, high)` | The number of indices present in `low ..< high`. |
| `next_member(from)`, `next_absent(from)` | The smallest index at or after `from` that is present, or absent, as an `Option(int)`; `from` may be `cap`, which gives `.none`. |
| `is_subset_of(other)`, `intersects(other)` | Whether every index of the set is in `other`, and whether any is. |
| `set(i)`, `unset(i)`, `toggle(i)` | Add, remove, or flip one index. |
| `clear()`, `fill()` | Remove every index, or add every index `0 ..< cap`. |
| `set_range(low, high)`, `unset_range`, `toggle_range` | The same for `low ..< high`, a word at a time. |
| `insert_all(other)`, `retain_all(other)`, `remove_all(other)`, `toggle_all(other)` | Union, intersection, difference, and symmetric difference, in place. |
| `store_bytes(out)`, `load_bytes(bytes)` | The byte form, below. A read-only view has no `load_bytes`. |
| `iter()` | The indices present, in increasing order, one trailing-zero count each. The iterator borrows the words. |
| `==` | Equal capacities and equal members. An `Index_View_Mut` compares through `as_view()`. |

`Index_Set(N)` also has the operators of `Bit_Set`: `|`, `&`, `&~`, and `~`
make a new set, unary `~` is the complement within `0 ..< N`, and their
compound assignments, such as `|=`, assign the result. A set prints as `{1, 5, 9}`.

An index outside `0 ..< cap` panics, as an array index does; so does a range
unless `0 <= low <= high <= cap`, a search from outside `0 ..= cap`, and a
combination or comparison of two sets with different capacities, except `==`,
which is false. These are programmer errors, as the matching array operations
are.

**Word layout.** Index `i` is bit `i % 64` of word `i / 64`, counting from the
least significant bit, so the set's words are what a caller-backed view
reads. When `cap` is not a multiple of 64, the bits of the final word at or
above `cap` are not members. An owner keeps them clear, which is why its `==`
can compare words. A view ignores them when it reads and never changes them
when it writes, so a caller's words need not be clean and may keep other data
there.

**Byte form.** The words are `u64` values in the host's byte order, so they
are not a file format, and no member exposes them as bytes. `store_bytes`
writes the set to exactly `bytes_for_bits(cap)` bytes: index `i` is bit
`i % 8` of byte `i / 8`, counting from the least significant bit, on every
host, and the bits of the final byte at or above `cap` are zero. `load_bytes`
reads the same form and returns `true`; a set bit at or above `cap` in the
final byte returns `false` and leaves the set unchanged, since it is a
corrupt or mismatched save rather than a bug. Either procedure panics on a
buffer of another length, because the caller chose the length. The capacity
itself is not stored: a save format records it, as it records any other
length.

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

### Fields of a byte slice

```loke
is_fixed_width :: proc($T: type) -> bool;
load  :: proc($T: type, bytes: []u8, order: Order) -> T where is_fixed_width(T);
store :: proc(bytes: []mut u8, value: $T, order: Order) where is_fixed_width(T);
```

`is_fixed_width` accepts `u8` through `u128`, `i8` through `i128`, `f16`, `f32`,
and `f64`. It rejects `int`, `uint`, `uintptr`, `bool`, `rune`, and enums: a format
has to name a width and a representation, and these leave one of them to the
target or the compiler.

`load` and `store` use the first `size_of(T)` bytes. A shorter slice panics, and
`store` then writes nothing, because the caller has already validated the offset.
They are for back-patching and random access to validated data; untrusted input
goes through `core:encoding/binary`. A float keeps its exact encoding, as
[`math.to_bits`](#coremath) describes.

The wrappers stay integral. Their stored form is held in a `T`, and a byte-swapped
float is not a float: a struct that needs one stores `Big_Endian(u32)` and calls
`math.from_bits`.

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

design.md "Build-selected providers" says how a program selects its logger. This
is the package's surface.

```loke
Level :: enum { Debug, Info, Warning, Error, Off }   // contributed by the compiler

Sink :: interface($Self: type) {
	slot write: proc(self: inout Self, level: Level, message: string_view);
}
Logger :: dyn mut Sink;

debug(args: ..dyn fmt.Formattable)
info(args: ..dyn fmt.Formattable)
warning(args: ..dyn fmt.Formattable)
error(args: ..dyn fmt.Formattable)
at(level: Level, args: ..dyn fmt.Formattable)
enabled(level: Level) -> bool
current() -> Logger
standard_logger() -> Logger

Writer_Sink :: struct($W: type) where io.Writer(W) { /* private */ }
writer_sink(writer: move $W) -> Writer_Sink(W)
impl Writer_Sink($W) {
	write(self: inout, level: Level, message: string_view)
	dropped(self: ^) -> int
	into_writer(self: move) -> W
}
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

### Writer sink

`Writer_Sink(W)` is a sink over an `io.Writer` it owns: an `fs.File`, a pipe,
an `io.Buffer_Writer`, or a `dyn mut io.Writer` borrowing one the caller keeps.
It writes the standard logger's lines, `[Level] message` and a newline. Each
record is built in memory and handed to the writer whole, in one sequence of
writes, under a lock held for the whole record, so records from different
threads never share a line and an unbuffered file takes one write per record.
The sink keeps the buffer of its longest record for the next one.

`Sink.write` returns nothing, so a record that cannot be buffered, or that the
writer refuses in whole or in part, is dropped and counted. `dropped` answers
the count. A refusal does not stop the sink: the next record tries the writer
again. A record refused part way leaves its first bytes in the writer, and the
next record starts a new line after them rather than continuing that one.
`into_writer` consumes the sink and returns the writer, so its owner can close
a file and see what `close` answers, or read what a buffer collected.

To log to a file, a provider keeps the sink in `static` storage, zero until the
factory fills it, and falls back to the standard logger when the file does not
open:

```loke
sink: static log.Writer_Sink(fs.File) = {};

logger_factory :: proc() -> log.Logger {
	switch (fs.append("app.log")) {
	case .ok(file):
		sink = log.writer_sink(move(file));
		return (log.Logger)(&mut sink);
	case .err:
		return log.standard_logger();
	}
}
```

A `static` sink cannot be consumed where it stands, so a provider that closes
its file once every logging thread has been joined swaps in a sink over a zero
`fs.File`, which is closed and refuses every later record:
`opened := exchange(inout sink, log.writer_sink(fs.File{})).into_writer();`.

The factory chooses the path, since it takes no arguments: a constant, or one
it reads from the environment. Rotation and other file policy belong to a sink
of the program's own.

### Compiled log level

`-log-level=<level>` predeclares the constant `LOKE_LOG_LEVEL`, whose type is
`core:log`'s level enumeration and whose default is the lowest level. The
`core:log` procedures guard their own bodies with it, so a call below the
compiled level never reaches the provider.

Discarding a callee's body does not discard the caller's expressions. An
unguarded call below the level still checks and evaluates its arguments;
removing those too takes a caller-side [`when`](design.md#when-statement), which is the
ordinary rule that a discarded branch is neither checked nor emitted:

```loke
log.debug("state", expensive());                       // argument still evaluated
when (LOKE_LOG_LEVEL <= .Debug) {
	log.debug("state", expensive());                   // neither checked nor emitted
}
```

## `core:fs`

`fs.File` is the safe owning wrapper around a native file handle. Its fields are
private, its zero value is closed, it disables cloning, and its `drop` closes a
live handle.

Every operation passes its path to Windows as given: `core:fs` neither
rewrites it nor adds a `\\?\` prefix, `read_directory` only appends the
search pattern `*`, after a `\` where one is needed, and `create_directories`
asks Windows for the normalized path first and creates directories along it.
Windows normalizes an ordinary path lexically before it looks up any element
of it, as its
[path normalization](https://learn.microsoft.com/en-us/dotnet/standard/io/file-path-formats#path-normalization)
describes: a relative path is joined to the current directory's path, `/`
becomes `\`, runs of separators collapse, and each `.` element is dropped, as
is each `..` element together with the element before it, among other
rewrites. Only the elements that remain are looked up, so
`local/junction/../marker.txt` names `local/marker.txt` wherever `junction`
leads. A device path beginning `\\.\` is normalized the same way. An
extended-length path beginning `\\?\` is not normalized: it reaches the
filesystem as written, `/` is not a separator in it, and `.` and `..` are names
rather than steps, which NTFS refuses.

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

@(move_only) File :: struct { /* private handle and access */ }

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
	set_size :: proc(self: inout File, size: u64) -> Status(io.Error);
	metadata :: proc(self) -> Result(Metadata, io.Error);
	close   :: proc(self: inout File) -> Status(io.Error);
	is_open :: proc(self) -> bool;
}
```

Because structural interface satisfaction is determined by the static type,
`File` satisfies both `io.Reader` and `io.Writer`: it has both slots regardless of
the options used for a particular instance. The open mode is checked at runtime:
using an unsupported direction returns `Unsupported`, and a nonempty read or
write, a seek, a `set_size`, or a `metadata` on a closed file returns `Closed`;
`flush` and `close` on a closed file succeed. A disposition that truncates needs `Write` or
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

`set_size` makes the file exactly `size` bytes long. A smaller size discards
the bytes past it; a larger one adds bytes that read as zero. The position does
not move, so a position past the new end is where the next write begins, and
the bytes between read as zero; in append mode the next write begins at the new
end. It needs `Write` or `Read_Write` access, and `Read` answers `Unsupported`.
Append mode does not prevent it: the change is made through the file's own
write right, so a caller whose access check allows only appending gets
`Permission_Denied`. A size above `2^63 - 1`, which no signed 64-bit file
offset can hold, is `Unsupported`. Like a write, the new size is durable once
`flush` returns. Its failures carry the operation `Set_Size`.

`metadata` answers what [`fs.metadata`](#filesystem-operations) would, asked of
the open file rather than a name, so the answer follows the file through a
rename. Every access mode can ask.

Example (imports `core:fs` and `core:io`): a log of newline-ended records, open
for append, is cut back to its last whole record after a crash, so the next
record does not follow a torn one.

```loke
recover_tail :: proc(log: inout fs.File, whole: u64) -> Status(io.Error) {
	log.set_size(whole) or_return;
	return log.flush();
}
```

### Positional I/O

```loke
impl File {
	read_at       :: proc(self: inout File, destination: []mut u8, offset: u64)
		-> Result(int, io.Error);
	write_at      :: proc(self: inout File, source: []u8, offset: u64)
		-> Result(int, io.Error);
	read_exact_at :: proc(self: inout File, destination: []mut u8, offset: u64)
		-> Status(io.Error);
	write_all_at  :: proc(self: inout File, source: []u8, offset: u64)
		-> Status(io.Error);
}
```

`read_at` and `write_at` are `read` and `write` at `offset` rather than the
position, each in one system call, so no seek is made for anything to come
between. They check the access and a closed file as `read` and `write` do, and
an empty buffer answers zero. A read that reaches the end of the file is short;
one that starts at or past the end is `End_Of_Input`. A write past the end
extends the file, and the bytes between read as zero. An append handle reads
at any offset, but `write_at` on it is `Unsupported`, since it writes only at
the end. An offset above `2^63 - 1` is `Unsupported`. After either call the
position is unspecified: seek before the next `read` or `write`.

`read_exact_at` and `write_all_at` loop over short transfers, with the
contracts of `io.read_exact` and `io.write_all`: a file that ends before
`destination` is full is `Unexpected_End`, and a failure part way has already
moved the bytes before it.

Example (imports `core:fs` and `core:io`): a fixed-size page of a store,
read and written in place.

```loke
PAGE :: 4096;

read_page :: proc(store: inout fs.File, page: u64, into: []mut u8) -> Status(io.Error) {
	return store.read_exact_at(&mut into[0:PAGE], page * PAGE);
}

write_page :: proc(store: inout fs.File, page: u64, from: []u8) -> Status(io.Error) {
	return store.write_all_at(from[0:PAGE], page * PAGE);
}
```

### File locking

```loke
Lock_Mode :: enum {Shared, Exclusive}

impl File {
	lock     :: proc(self: inout File, mode: Lock_Mode) -> Status(io.Error);
	try_lock :: proc(self: inout File, mode: Lock_Mode) -> Result(bool, io.Error);
	unlock   :: proc(self: inout File) -> Status(io.Error);
}
```

A lock covers the whole file and belongs to the handle that took it, so a
second handle to the same file, in the same program or another, contends for
it like any other. A `Shared` lock admits other shared locks and keeps out an
exclusive one; an `Exclusive` lock keeps out every other lock. `lock` waits for
as long as a lock that keeps it out is held; `try_lock` answers `false` instead
and leaves the handle unlocked.

The lock is advisory: only `lock` and `try_lock` respect it, so reads, writes,
`set_size`, and every whole-file operation go on through any handle as before.
It is a way for cooperating programs to agree, such as a store that must have
one writer, not a protection against a program that does not ask.

A handle holds one lock at a time: `lock` or `try_lock` while it holds one is
`Unsupported`, so changing the mode means `unlock` first, and another handle
can take the lock in between. `unlock`
on a handle holding no lock, a closed one included, succeeds, and a failed
`unlock` leaves the handle holding its lock, so calling it again retries the
release. `close` and
`drop` release the lock, and so does the program ending however it ends, so a
crash leaves no stale lock behind. `lock` and `try_lock` on a closed file are
`Closed`. Every handle can lock except one opened `Write` with `append`, which
is `Unsupported`: Windows locks only for a handle that may read or may write
anywhere, and append mode gives up the second. Failures carry the operations
`Lock` and `Unlock`.

Example (imports `core:fs` and `core:io`): a store refuses to open while
another program has it open for writing.

```loke
open_store :: proc(path: string_view) -> Result(fs.File, io.Error) {
	store := fs.open(path, fs.Open_Options{
		access = .Read_Write, disposition = .Open_Or_Create, append = false,
	}) or_return;
	if (!(store.try_lock(.Exclusive) or_return)) {
		return .err(io.make_error(.Permission_Denied, .Lock));
	}
	return move(store);
}
```

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
existing file is `Already_Exists`. It creates the missing directories of the
path that remains after [native normalization](#corefs), so
`a/skipped/../made` makes whichever of `a` and `a/made` is missing and never
looks up `skipped`, which may be missing or a file. An extended-length path is
walked as written. A path ending in a drive's colon, such as `C:`, names that
drive's current directory for `read_directory` as for every other operation.
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
  `create_directories` succeeds through a junction. The elements are those
  that remain after [native normalization](#corefs): a link that a later `..`
  takes away is never reached, so `..` steps back along the path as written,
  not out of the link's target.
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
the handles are redirected to pipes or files. A process may have none, as a
[windowed program](compiler-guide.md#windowed-programs) started from Explorer
does; writing to an absent handle returns an error.

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
@(move_only) Raw_Mode :: struct { /* private state */ }

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

### `os.Args`

`os.args` is a constant of type `os.Args`, a stateless, read-only view of the
process-lifetime argument vector. Its zero value denotes the whole vector.

| Operation | Result |
| --- | --- |
| `os.args.len()` | the argument count, including the executable path at index 0 |
| `os.args[i]` | an owning UTF-8 `string`, copied; an index out of range panics |
| `foreach (a in os.args)` | a borrowed `string_view` per argument |
| `os.view_at(i)` | the same borrow by index; an index out of range panics |

Indexing copies an owning string; iteration borrows runtime-owned bytes valid
for the process lifetime. The executable's startup converts the native
arguments to UTF-8 before `main` runs; on Windows, an unpaired UTF-16 surrogate
becomes U+FFFD. An [object build](compiler-guide.md#building-an-object-for-a-c-host)
has no startup of its own, so its `os.args` is empty. For immediate termination
without cleanup, see
[`os.exit`](design.md#program-entry-and-exit).

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

@(move_only) Child :: struct {
	stdin:  Pipe,
	stdout: Pipe,
	stderr: Pipe,
	// and the process, private to the package
}

@(move_only) Pipe :: struct { /* private */ }

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

`Complex(T)` and `Quaternion(T)` are standard-library abstractions, not
base-language types. They are ordinary records with methods, [operator
declarations](design.md#operator-declarations), a [conversion
hook](design.md#conversion-hooks), interfaces, and a `format` method: nothing the
language reserves for itself. A scalar reaches one through the explicit conversion
`Complex(f64)(x)`, since there are no [user-defined implicit
conversions](design.md#implicit-type-conversions). Generic and third-party numeric
types use the same construction, conversion, and operator rules.

Beside what the [integer operators](design.md#integer-operators) do, integers have
these named policies:

- `math.wrap(T, value)` keeps the low bits of the two's-complement
  representation, like the [wrapping operators](design.md#integer-overflow). It
  accepts an integer, rune, or enum value and an integer or rune destination. For
  vectors of the same lane count it converts each lane. Constant inputs are
  folded.
- `math.to(T, value)` returns `Option(T)`: the value if `T` represents it
  exactly, or `.none`. It is the integer counterpart of
  [`Enum.from_int`](design.md#integer-conversion).

`math.to_bits(value)` is a float's IEEE-754 encoding, `u16` for an `f16`, `u32` for
an `f32`, and `u64` for an `f64`, and `math.from_bits(bits)` is the float with that
encoding. `to_bits(from_bits(bits)) == bits` for every pattern, a signalling NaN's
included, because [moving a float keeps its encoding](design.md#floating-point-operators)
and each width has its own overload. They replace `unsafe.transmute` wherever the
question is only what the bits are.

The floored forms of `/` and `%` are procedures for every integer type:
`math.floor_div(x, y)` rounds the quotient toward negative infinity, and
`math.floor_mod(x, y)` is the remainder that goes with it, so
`x == floor_div(x, y)*y + floor_mod(x, y)` and a non-zero `floor_mod` has the
divisor's sign. They panic where `/` and `%` do: on a zero divisor, and
`floor_div(MIN, -1)` overflows while `floor_mod(MIN, -1)` is `0`. For an
unsigned type they equal `/` and `%`.

For a divisor that is a power of two, `2^n`, a shift and a mask are already the
floored quotient and remainder, because `>>` on a signed value is arithmetic:

```loke
CHUNK_BITS :: 4;                               // chunks 16 wide
x: i32 = -1;
chunk := x >> CHUNK_BITS;                      // -1, as math.floor_div(x, 16)
local := x & ((1 << CHUNK_BITS) - 1);          // 15, as math.floor_mod(x, 16)
```

The policies of the [integer overflow](design.md#integer-overflow) operators are
procedures too, for generic code and procedure values:

| Operations | Policy |
| --- | --- |
| `math.wrapping_add`, `wrapping_sub`, `wrapping_mul` | Keep the result's low bits, as `+%`, `-%`, and `*%` do. |
| `math.checked_add`, `checked_sub`, `checked_mul` | Return `Option(T)`: `.some(result)` when the mathematical result fits `T`, otherwise `.none`. |

Each accepts two operands of one signed or unsigned integer type; an unfixed
second operand takes the first's type:

```loke
value: u8 = 255;
fmt.println(value +% 1, math.checked_add(value, 1)); // 0 .none
```

The wrapping forms also accept two vectors of one integer-lane `Simd` type and
wrap each lane.

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
- the integer bit operations `count_ones`, `leading_zeros`, `trailing_zeros`,
  `bit_width`, `rotate_left`, `rotate_right`, `reverse_bits`,
  `is_power_of_two`, `next_power_of_two`, and `checked_next_power_of_two`,
  which [Integer bit operations](#integer-bit-operations) describes;
- `floor`, `ceil`, `round`, `trunc`, `mod`, `sqrt`, `hypot`, `fma`, `pow`,
  `exp`, `log`, `log2`, `log10`, `sin`, `cos`, `tan`, `asin`, `acos`, `atan`,
  `atan2`, `to_radians`, `to_degrees`, and `fma_is_instruction`.

Floating-point functions use an unsuffixed name for `f64` and `_f32` for
`f32`, avoiding ambiguous overloads for untyped literals. There is no implicit
widening and no `f16` variant. The exceptions are the bit conversions `to_bits` and
`from_bits`, procedure groups over `f16`, `f32`, and `f64`, whose width is the whole
question; an untyped literal needs a type there.

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
which NaN a NaN operand yields, which neither promises. `fma_is_instruction()`
is true in code where `fma` is the instruction, so that an `if` can choose an
algorithm that calls `fma` only where it is fast: in a build for a level with
FMA, and in a procedure's copy for one, which
[`@(cpu_dispatch)`](design.md#cpu_dispatchstring) makes. It is not a constant,
since a procedure's copies answer differently; in a constant or a `when` it
answers for the build's level. `sqrt` is not backed
by the C library either: it is the processor's square root instruction, which
IEEE 754 makes correctly rounded, and a call with a constant argument has a
compile-time value, rounded exactly as the instruction rounds. Which NaN it
gives below zero is not promised. `floor`, `ceil`, `trunc`, and `round` are
exact and also have compile-time values: they are SSE4.1's rounding
instruction from `x86-64-v2`, and below it the C library's functions, which
give the same results. So does `mod`, whose exact remainder is the C
library's `fmod` at run time, no x86-64 level having an instruction for it.

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
the functions it implements with results that agree, and the magnitudes
`complex_abs` and `quaternion_abs`. The remaining
procedures, `sqrt` and `mod` included, are exact or correctly rounded, so
their results are the same everywhere. See
[Deterministic math functions](open-questions.md#deterministic-math-functions).

### Integer bit operations

```loke
count_ones                :: proc(value: $T) -> int;
leading_zeros             :: proc(value: $T) -> int;
trailing_zeros            :: proc(value: $T) -> int;
bit_width                 :: proc(value: $T) -> int;
rotate_left               :: proc(value: $T, count: int) -> T;
rotate_right              :: proc(value: $T, count: int) -> T;
reverse_bits              :: proc(value: $T) -> T;
is_power_of_two           :: proc(value: $T) -> bool;
next_power_of_two         :: proc(value: $T) -> T;
checked_next_power_of_two :: proc(value: $T) -> Option(T);
```

`value` has an integer type of any width, signed or unsigned, or a `distinct`
type over one; an unfixed constant is an `int`. A float, rune, enum, `bool`,
or `Simd` vector is a compilation error. The counts, the rotations, and the
reversal read the value's two's-complement bit pattern at its type's width
`W`, so a signed and an unsigned value with the same bits give the same
answer:

| Call | Result |
| --- | --- |
| `count_ones(x)` | The number of set bits, `0 ..= W`. `count_ones(i32(-1))` is `32`. |
| `leading_zeros(x)` | The number of zero bits above the highest set bit. A negative value gives `0`. |
| `trailing_zeros(x)` | The number of zero bits below the lowest set bit, which is that bit's index. |
| `bit_width(x)` | `W - leading_zeros(x)`: the highest set bit's index plus one, the number of bits `x` needs. A negative value gives `W`. |
| `rotate_left(x, count)` | `x` rotated `count` places toward the high end: the bits shifted out at the top come back in at the bottom. |
| `rotate_right(x, count)` | `x` rotated `count` places toward the low end. |
| `reverse_bits(x)` | `x` with bit `i` moved to bit `W - 1 - i`. `reverse_bits(i8(1))` is `-128`. |

Zero is defined: `leading_zeros(x)` and `trailing_zeros(x)` are both `W` for
`x == 0`, as `count_ones(x)` and `bit_width(x)` are `0`. Iterating the set bits
of a word is `trailing_zeros(word)` followed by `word &= word - 1` until the
word is zero.

A rotation takes `count` modulo `W`, floored as
[`floor_mod`](design.md#integer-operators) floors it, so every `int` count is
defined: a count past the width wraps, and a negative count rotates the other
way, `rotate_left(x, -k) == rotate_right(x, k)`. A rotation never panics.

The power-of-two operations read the value instead, so a negative value is
never a power of two:

| Call | Result |
| --- | --- |
| `is_power_of_two(x)` | Whether `x` is `2^k` for some `k >= 0`. Zero and every negative value are not, a signed minimum included, though its pattern has one set bit. |
| `next_power_of_two(x)` | The smallest power of two at least `x`. A power of two is itself, and every `x <= 1`, zero and every negative value included, gives `1`. |
| `checked_next_power_of_two(x)` | `.some(next_power_of_two(x))`, or `.none` where that power does not fit. |

The largest power of two a type holds is `2^(W-1)` unsigned and `2^(W-2)`
signed, the sign bit being no power of two. Past it, the next power of two
does not fit, and `next_power_of_two` panics, as checked arithmetic does
([Integer overflow](design.md#integer-overflow)): `next_power_of_two(u8(129))`
and `next_power_of_two(i8(65))` both panic. Where it is computed at compile
time, from a constant argument or in
[compile-time evaluation](design.md#compile-time-procedure-evaluation), the
same overflow is a compilation diagnostic. `checked_next_power_of_two` is the
form that never panics, as `checked_add` is for `+`. There is no wrapping
form: the low bits of the power that does not fit are all zero, which no
caller wants as a power of two.

A constant argument gives a constant, and each operation has a compile-time
value; `checked_next_power_of_two`, whose `Option` is not a constant, has one
by compile-time evaluation. At run time each is one LLVM intrinsic or a few
instructions around one, never a loop: `ctpop`, `ctlz`, and `cttz` with a zero
operand defined, the funnel shifts `fshl` and `fshr`, and `bitreverse`;
`bit_width` and the power-of-two round-up are `ctlz` with a subtraction, and
`is_power_of_two` is `x > 0` and `x & (x - 1) == 0`. On x86-64 a rotation is
one `rol` or `ror` at every [CPU level](compiler-guide.md#cpu-levels); a count
is one `popcnt`, `lzcnt`, or `tzcnt` from the level that has it (`x86-64-v2`
for `popcnt`, `x86-64-v3` for the other two) and a short instruction sequence
below it. No level has a bit reversal instruction, so `reverse_bits` is a byte
swap and shift-and-mask steps at every level. A result is the same at every
level.

## `core:math/repro`

Each procedure returns its exact mathematical result rounded once to the
result's width, to nearest with ties to even, with gradual underflow and
overflow to infinity. The result is therefore the same bits on every machine,
[CPU level](compiler-guide.md#cpu-levels), and optimization level, and when a
call is evaluated at compile time. No procedure calls the C library. Where
`math.fma_is_instruction()` is true, the exact products the fast paths take
come from `math.fma`, and elsewhere from Dekker's algorithm, which gives
the same exact value, so the processor's FMA changes only their speed. Each
`f64` procedure but `sqrt` is marked
[`@(cpu_dispatch="x86-64-v3")`](design.md#cpu_dispatchstring), so a build for
a lower level runs it with the instruction on a processor that has
`x86-64-v3`, 7% faster there for `exp` and 40% for `log2`, most near 20%.
The `_f32` procedures are not marked, since their usual path takes no exact
product. Every
NaN result is the positive quiet NaN with no payload (`0x7ff8000000000000`,
`0x7fc00000`), whatever NaN produced it.

The package has `exp`, `log`, `log2`, `log10`, `pow`, `sqrt`, `sin`, `cos`,
`tan`, `asin`, `acos`, `atan`, `atan2`, and `hypot`, and the magnitudes
`complex_abs` and `quaternion_abs` of `core:math`'s `Complex` and
`Quaternion`, each with the `f64` and `_f32` naming of `core:math`. A function missing here is not provided by
falling back to `core:math`. Each `_f32` procedure is rounded once to `f32`,
not the `f64` one narrowed, which could round twice.

- `exp` of NaN is NaN, of +Inf is +Inf, of -Inf is +0, and of ±0 is exactly
  1.
- `log` is the natural logarithm, and `log2` and `log10` the logarithms to
  bases 2 and 10. NaN and every argument below zero, -Inf included, give
  NaN; ±0 gives -Inf, 1 gives +0, and +Inf gives +Inf. `log2` of a power of
  two and `log10` of a power of ten are its exponent exactly.
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
- `sqrt` is the square root. NaN and every argument below zero, -Inf
  included, give NaN; ±0 gives itself, and +Inf gives +Inf. An exact root,
  such as `sqrt(2.25)`, is exact; no root is ever halfway between two floats.
- `sin`, `cos`, and `tan` take radians. Every finite argument is reduced by
  an exact multiple of pi/2, however large. NaN and ±Inf give NaN; `sin(±0)`
  and `tan(±0)` are ±0 and `cos(±0)` is exactly 1, and `sin(-x)` and
  `tan(-x)` are `-sin(x)` and `-tan(x)`. All three are proved correctly
  rounded for every `f64` argument: their slow paths are within 2^-250 of
  the result, relative, and the exhaustive searches for hard-to-round cases
  (Lefèvre, Ly, and Zimmermann, "Computing hard-to-round cases of sin, cos,
  tan in double precision", ARITH 2026, above 2^10, or 2^4 for `tan`, and
  CORE-MATH's below) leave no result within 2^-117 of a midpoint, relative
  to it, for `sin` and `cos`, and 2^-134 for `tan`. The proof is as sound
  as those searches. The functions not yet proved are in
  [Open questions](open-questions.md#deterministic-math-functions).
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
- `hypot(x, y)` is sqrt(x^2 + y^2), without overflow or underflow on the
  way. As in C17's annex F, ±Inf in either argument gives +Inf, even with a
  NaN in the other; otherwise NaN gives NaN. `hypot(x, ±0)` is |x|. An exact
  result is exact, and one exactly halfway between two floats, such as
  `hypot_f32(13013847, 13025704)`, whose exact value is 18412745, rounds to
  even.
- `complex_abs(z)` is `hypot(z.real, z.imaginary)`, the value `z.abs()`
  approximates.
- `quaternion_abs(q)` is sqrt(real^2 + i^2 + j^2 + k^2), rounded once, without
  overflow or underflow on the way; `q.abs()` nests `hypot` and rounds three
  times. Its special cases are `hypot`'s: ±Inf in any component gives +Inf,
  even with a NaN in another, otherwise NaN gives NaN, and four zeros give
  +0. An exact result is exact, and one exactly halfway between two floats
  rounds to even, so `quaternion_abs_f32` of 13013847, 13025704, 0, and 0 is
  18412744, and with a fourth component of the smallest subnormal, 18412746.

`RESULTS_VERSION`, a `u32`, is the version of these results. It changes
whenever any procedure's result for any argument does: the results are
correctly rounded, so only a fix changes one, and the
[CHANGELOG](../CHANGELOG.md) says which. A replay or a lockstep peer records it
with the other versions its values depend on and refuses a recording with
another, as [examples/lockstep.loke](../examples/lockstep.loke) does.

The reasons for the package's design are in
[Standard-library API choices](comments.md#standard-library-api-choices), and
its later work in [Future plans](future-plans.md#standard-library-maturity).

## `core:math/linalg`

Small vectors and matrices as ordinary records that never allocate, so that
two libraries can pass a point or a transform to each other as it is. The
reasons for its design are in
[Standard-library API choices](comments.md#standard-library-api-choices).

`Vector2(T)`, `Vector3(T)`, and `Vector4(T)` have the fields `x`, `y`, `z`,
and `w` as their length allows, and the layout of `[N]T`.
`Matrix(T, R, C)` is `R` rows by `C` columns of any fixed shape, stored
column-major in `columns: [C][R]T`; `m[r, c]` reads `m.columns[c][r]`, and
`Matrix(f32, 4, 4)` has the layout of `[16]f32`, the order OpenGL takes with
`transpose = GL_FALSE` and Direct3D and Vulkan shaders read as
`column_major`. Vectors are columns: `m * v` transforms `v`, there is no
`v * m`, and `a * b` applies `b` first. Each element of a product is the dot
product of a row and a column, summed in index order from the first product.
The vectors are [`@(positional)`](design.md#positional), so a literal in any
package may list its components, `linalg.Vector3(f32){1, 2, 3}`, or name them,
and `x, y, z := v` takes one apart; `from_components` builds the same value. The
package exports no short names; a program's own alias,
`Vec3 :: linalg.Vector3(f32);`, is the same type.

Arithmetic needs only `interfaces.Numeric(T)`, so integers, whose overflow
panics as for the scalar, and user number types get:

- on every vector: `from_components`, `splat`, `unit_x` to `unit_w`,
  `from_array` and `to_array`, `+`, `-`, unary `-`, component-wise `*` and
  `/`, `*` and `/` by a scalar and `*` of a scalar, exact `==`, `[]` with a
  runtime index that panics outside the components, `dot`,
  `length_squared`, `distance_squared`, component-wise `min` and `max`, and
  `project(onto)`, `reject(normal)`, and `reflect(normal)` for a unit `onto`
  or `normal`, which need no square root and are exact for integers;
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
  `angle_between(other)` in `[0, pi]`, and component-wise `abs`, `floor`,
  `ceil`, and `round`. `angle_between` is `atan2(|cross|, dot)`, and Kahan's
  `2*atan2(|a*|b| - b*|a||, |a*|b| + b*|a||)` for `Vector4`, so it stays
  accurate near 0 and pi, where the `acos` of a normalized dot product does
  not; it is 0 when either vector is zero;
- on a square matrix: `solve(b)` for any `Matrix(T, R, K)` right-hand side,
  `inverse`, and `determinant` above 4 x 4. They use Gaussian elimination
  with partial pivoting, the pivot the first element of largest magnitude in
  its column, in a fixed order;
- on `Matrix(T, 4, 4)`: `inverse_affine`, which inverts the linear part and
  takes the last row as `(0, 0, 0, 1)` unchecked; `normal_matrix`, the
  transpose of the inverse of the linear part, which keeps surface normals
  perpendicular under non-uniform scaling; and `project_point(p)`, which
  divides `self * (p, 1)` by its `w`;
- the rotations: `rotation_x`, `rotation_y`, `rotation_z`, and
  `rotation(axis, angle)` at 3 x 3 and 4 x 4, `Matrix(T, 2, 2).rotation(angle)`,
  and `Matrix(T, 3, 3).rotation_2d(angle)`; and the free procedures
  `quaternion_from_axis_angle(axis, angle)`, which takes the axis as given,
  `quaternion_normalize`, `quaternion_from_matrix`, `quaternion_between`,
  `nlerp`, `slerp`, `quaternion_from_euler`, `to_euler`,
  `quaternion_from_rotation_vector`, and `to_rotation_vector`;
- the cameras, on `Matrix(T, 4, 4)`: `perspective`, `orthographic`,
  `look_at`, `look_to`, and the `_lh` form of each.

Angles are radians, and space is right-handed: `unit_x().cross(unit_y())` is
`unit_z()`, and a positive angle turns counterclockwise seen from the
positive end of the axis. A quaternion's `real` is its scalar part; a unit
`q` rotates as `q v q*`, `q` and `-q` rotate alike, and `rotate(a * b, v)`
rotates by `b` first, as `from_quaternion(a * b)` equals
`from_quaternion(a) * from_quaternion(b)` up to rounding.

The quaternion procedures:

- `quaternion_from_matrix(m)` takes a rotation matrix, 3 x 3 or the linear
  part of a 4 x 4, to its unit quaternion with a non-negative real part, by
  Shepperd's method, which takes the square root of the largest of the four
  squared components and stays accurate at every angle.
- `quaternion_between(a, b)` is the shortest rotation turning the direction
  of `a` to that of `b`, accurate even for nearly opposite vectors. It is
  `.none` for a zero vector and for opposite ones, where every axis across
  them is as short; `quaternion_between(a, b, fallback_axis)` turns those half
  a turn about the part of `fallback_axis` across `a` instead.
- `nlerp(a, b, t)` and `slerp(a, b, t)` interpolate from the unit `a` at
  `t = 0` to the unit `b` at `t = 1` along the shorter arc, negating `b` when
  `dot(a, b) < 0`. `nlerp` normalizes the component-wise `lerp`; `slerp`
  turns at constant angular speed, is exact at both ends, and takes its
  angle as `2*atan2(|a - b|, |a + b|)`, which stays accurate for close
  rotations.
- `Euler_Order` names the six intrinsic Tait-Bryan sequences, `.XYZ` to
  `.ZYX`, and has no default. `quaternion_from_euler(.ZYX, yaw, pitch, roll)`
  is `axis_angle(Z, yaw) * axis_angle(Y, pitch) * axis_angle(X, roll)`, which
  is also the extrinsic sequence `X`, `Y`, `Z` about fixed axes.
  `to_euler(q, order)` returns `(first, second, third)` with the middle angle
  in `[-pi/2, pi/2]` and the others in `[-pi, pi]`. At gimbal lock, when the
  middle angle is within rounding of `pi/2` or `-pi/2`, the third angle is 0
  and the first takes the whole rotation about the shared axis. `q` need not
  be a unit quaternion: a finite nonzero `q` whose largest component magnitude
  `m` has an `m^4` that is not `is_normal` is first divided by `m`, so its
  squares neither overflow nor lose precision, and a unit `q` never is.
- `quaternion_from_rotation_vector(v)` turns `|v|` radians about the
  direction of `v`, and `to_rotation_vector(q)` returns the axis times the
  angle in `[0, pi]`, the same for `q` and `-q`; the zero vector is no
  rotation. At an exact half turn, the first nonzero axis component is
  positive.

`perspective(fovy, aspect, near, far, depth)` and
`orthographic(left, right, bottom, top, near, far, depth)` map a view space
looking down `-Z` with `+Y` up to clip space, with `x` and `y` in `[-1, 1]`,
`+Y` up, and `z` in the range `depth` names, the near plane at its first
value. `Depth_Range` has no default: `.Negative_One_To_One` is OpenGL's,
`.Zero_To_One` Direct3D's, Vulkan's, Metal's, and WebGPU's, and
`.One_To_Zero` reversed depth. A perspective's clip `w` is the view-space
`-z`. Its depth coefficients are computed in the order its documentation
gives from `r = far/(far - near)`, at most `2/epsilon` however close the
planes are, and `s = near/(far - near)`, never from `far*near`, so a step
overflows only where its coefficient does; an infinite `far` takes `r` as 1
and `s` as 0, the limit of the matrix as `far` grows. A
field of view outside `(0, pi)`, a non-positive or infinite `aspect` or
`near`, `far <= near`, and a NaN panic; an orthographic box needs finite,
distinct bounds with `far` beyond `near`. An orthographic matrix's
coefficients are the quotients its documentation gives, such as
`2/(right - left)` and `-(right + left)/(right - left)`, except that a row
whose difference or sum of two bounds overflows computes them from the
halves of those bounds, which are then exact, so a coefficient overflows or
underflows only where its value does and ordinary bounds keep the plain
quotients' bits. Each `_lh` form takes the same
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
`inverse_affine` and `normal_matrix` return `.none` when the linear part has
no inverse, and `project_point` when `w` is zero or the result is not finite.

`approx_equal(a, b, absolute, relative)` compares two scalars, vectors,
matrices, or quaternions with a `Real` element: every component pair has
`|a - b| <= max(absolute, relative * max(|a|, |b|))`. Both tolerances are
required, and a negative or NaN one panics. A NaN component is never equal,
and an infinity equals only itself, whatever the tolerances.

Every operation is computed in the order documented on it, with no `fma` and
no C library call: the `f32` and `f64` slots of `Real` are `math.sqrt`, which
is correctly rounded, and [`core:math/repro`](#coremathrepro). Results are
the same bits on every machine, [CPU level](compiler-guide.md#cpu-levels),
and optimization level, but for which NaN a NaN result is, which
[Floating-point operators](design.md#floating-point-operators) leaves
unspecified. Calls can also be evaluated at compile time with
the same result, including those that reach `math.sqrt`. At `f32`, `transform_point`,
`transform_direction`, and a 3 x 3 `m * v` compute in `Simd` lanes, each lane
one component in the documented order, which changes their speed and not
their bits ([Standard-library API choices](comments.md#standard-library-api-choices)).

`linalg.Scalar(T)` is a real or complex number type, the element type of
[`core:math/dense`](#coremathdense)'s factorizations: `Numeric`, `==`, unary
`-`, an associated type `T.Real` that is `Real`, a conversion `T(x)` from a
`T.Real`, and the slots `conjugate`, `real_part`, and `imaginary_part`. The
package implements it for `f32` and `f64`, each its own `Real` with no
imaginary part, and for `math.Complex(R)` of any `Real(R)`. A user real type
implements it with an inherent `Real` constant naming itself, `conjugate` and
`real_part` returning the value, and `imaginary_part` returning zero.

## `core:math/dense`

Matrices whose size is known only at run time: an owner, views of it and of
foreign buffers, products, the LU, Cholesky, and QR factorizations, least
squares, the symmetric and Hermitian eigendecomposition, and the singular
value decomposition, of real or complex elements. The reasons for its design
are in [Standard-library API choices](comments.md#standard-library-api-choices).

`Matrix(T)` owns `rows x columns` elements stored column-major in one
allocation, the order LAPACK and `linalg.Matrix` use, from the allocator it was
made with. `zeros`, `filled`, `identity`, `from_view`, `from_column_major`,
`from_rows`, which takes a nested array written as it prints, and
`from_fixed` make one; each takes an `allocator` that defaults to the
program's. `rows()`, `columns()`, `m[r, c]`, and `m[r, c] = x` read and write
it, `to_fixed(R, C)` copies it to a `linalg.Matrix`, and `format` prints it by
rows as `linalg` does. A copy clones the storage, which the
[copy-cost diagnostic](compiler-guide.md#copy-cost-diagnostics) reports; `clone(allocator)`
chooses where. There are no operators: each result of `a * b + c` would be
allocated from an allocator the expression cannot name.

`View(T)` reads, and `View_Mut(T)` writes, `rows x columns` elements of a slice:
element `(r, c)` is `data[r*row_stride + c*column_stride]`. `m.view()` and
`m.view_mut()` view a whole matrix, and `from_column_major(data, rows,
columns, leading := rows)`, `from_row_major(data, rows, columns, leading :=
columns)`, and `from_column(values)` view a foreign buffer. Every constructor
checks once that the elements are inside the slice and that the leading
dimension covers a whole column or row, so no two elements share a place;
either failure panics. `block(row, column, rows, columns)`, `transpose()`,
`row(r)`, and `column(c)` make smaller views without a copy, and so does
`adjoint()`, for a `linalg.Scalar(T)`, which reads the conjugate transpose and
is the transpose for a real `T`. A view borrows
its slice, so the [checker](design.md#capabilities-and-the-one-rule) keeps it
from outliving the storage and rejects `multiply_into(m.view_mut(), m.view(),
b)` where it is written; nothing is checked at run time.

On a `View_Mut`, the methods that make a smaller view consume a temporary or
`move(view)` and borrow a named view, so `m.view_mut().block(...)` can be
bound and `whole.block(...)` leaves `whole` usable afterwards.
`split_columns(k)` and `split_rows(k)` give two views that may be written at
once; each panics for a view whose columns, or rows, interleave in the slice,
as a column-major matrix's rows do. `as_view()` reads the same elements, and
`fill(value)`, `copy_from(view)`, `scale_by(s)`, and `add_scaled(s, view)`,
which adds `s*view` element by element, write them.

With `interfaces.Numeric(T)`, so for integers and user number types too:

- `multiply(a, b)` and `multiply_into(out, a, b)`, each element
  `(a[i, 0]*b[0, j] + a[i, 1]*b[1, j]) + ...` from the first product, the order
  `linalg.Matrix` uses, so the two agree bit for bit; and
  `multiply_add_into(out, a, b)`, which adds each term into `out` in turn;
- `add`, `subtract`, `scale(a, s)`, and `transpose`, each with an `_into`
  form;
- `dot(x, y)`, the sum of the element products in column order, conjugating
  nothing, so `x^H y` is `dot(x.adjoint().transpose(), y)`; `trace`; and
  `equal`, exact and false for different shapes.

Each `_into` form writes caller storage and never allocates; the other form
allocates its result. A shape mismatch panics.

With [`linalg.Scalar(T)`](#coremathlinalg), so for `f32`, `f64`,
`math.Complex` of either, and user number types, a transpose below being the
conjugate transpose for a complex `T`, and a norm, a tolerance, an
eigenvalue, and a singular value being `T.Real`:

- `approx_equal(a, b, absolute, relative)` by `linalg.approx_equal`'s rule,
  element by element and by modulus, false for different shapes;
- `norm_frobenius`, in one pass with a running scale so that it neither
  overflows nor underflows where the result does not, a complex element as
  its two parts; `norm_one`, the largest column sum of moduli; and
  `norm_infinity`, the largest row sum;
- `solve_lower_into(l, b, unit_diagonal)` and `solve_upper_into(u, b,
  unit_diagonal)`, which overwrite `b` and read only their triangle;
- `lu(a)` and `lu_in_place(a, pivots)`, Gaussian elimination with partial
  pivoting, the pivot the first element of largest magnitude in its column,
  `|re| + |im|` for a complex one as in LAPACK.
  `Lu` has `solve`, `solve_into`, `inverse`, `determinant`, `factors()` and
  `pivots()` in LAPACK's `getrf` form, and `reciprocal_condition()`, LAPACK's
  `gecon` estimate of `1 / (|A|_1 |A^-1|_1)`, its solves taken on vectors
  multiplied by a power of two near `|A|_1` so that multiplying `A` by a
  power of two changes no bit of it and a well-conditioned matrix of any
  scale is not reported singular;
- `cholesky(a)` and `cholesky_in_place(a)`, the `L L^H` factor of a Hermitian
  positive definite matrix from its lower triangle, with a real diagonal.
  `Cholesky`
  has `solve`, `solve_into`, `determinant`, and `lower()`;
- `qr(a)` and `qr_in_place(a, tau)`, for `rows >= columns`, by unblocked
  Householder reflectors, applied a panel of columns at a time, in LAPACK's
  `geqrf` form, `R`'s diagonal real, each reflector built at half scale
  when `larfg`'s `alpha - beta` would overflow and from its column
  multiplied by a power of two when `beta` is subnormal, which changes
  neither `tau` nor the vector. `Qr` has `q()`, the first
  `n` columns of `Q`, `r()`, `apply_q_into(b)` and
  `apply_q_adjoint_into(b)`, which apply `Q` and `Q^H` without forming it,
  `least_squares(b)`, and `least_squares_into(b)`, which leaves the
  minimizer in `b`'s first `n` rows and the residual's components, whose norm
  is the residual's, in the rest, as LAPACK's `gels` does; and `factors()`
  and `tau()`;
- `solve(a, b)`, `inverse(a)`, and `least_squares(a, b)`, which factor and
  solve in one call. `least_squares` assumes full column rank;
- `symmetric_eigen(a)`, the eigenvalues and eigenvectors of a symmetric
  matrix, or a Hermitian one for a complex `T`, from its lower triangle, the
  diagonal's imaginary parts not read, by Householder reduction to a real
  tridiagonal and implicit QL with Wilkinson shifts. `Symmetric_Eigen` has
  `values()`, real and ascending, and `vectors()`, an orthogonal, or unitary,
  matrix with eigenvector `i` as column `i`;
- `svd(a)`, the thin singular value decomposition `A = U S V^H` of any
  `m x n` matrix, by Golub and Reinsch's method as LINPACK's `dsvdc` has it.
  `Svd` has `u()` (`m x k`, `k = min(m, n)`), `singular_values()`,
  descending and not negative, `v()` (`n x k`), `rank(relative)`, and
  `solve(b, relative)` and `solve_into(out, b, relative)`, the minimum-norm
  least-squares solution with the singular values not above `relative` times
  the largest taken as zero. `relative` has no default.

`symmetric_eigen` and `svd` first multiply a matrix by `1/big` when the
largest magnitude of an element's part is above `big`, the largest power of
two whose square is finite (`2^511` for `f64` and `2^63` for `f32`), and by
`big` when it is below `1/big` but not zero, then multiply the eigenvalues or
singular values back. No step of either method then overflows, and since a
power of two changes the rounding of no value that is not subnormal, a matrix
gives the results of the unscaled method wherever that neither overflows nor
reaches a subnormal value. A successful decomposition is finite.

The signs of the vectors are part of the contract, so that two machines give
the same vectors and not only the same subspaces: each eigenvector, and each
column of `V` with its column of `U`, has its first component of largest
magnitude positive, for a complex `T` by multiplying it by a unit. The iterations decide convergence by rounding rather than
by a tolerance: an off-diagonal element is negligible when adding it to its
two diagonal neighbours' magnitudes changes nothing, in the scaled matrix,
where that sum cannot overflow.

A numerical failure is a `dense.Error`, one type for the package so that
`or_return` chains across factorizations: `.Singular` for an exact zero pivot
or zero on `R`'s diagonal, or a factor that is not finite, and
`.Not_Positive_Definite` for a Cholesky pivot that is not positive and
finite, and `.No_Convergence` for an eigenvalue or singular value iteration
that reaches its limit, an element that is read and is not finite, which it
cannot reduce, or an eigenvalue or singular value too large for `T.Real`. A
nearly singular matrix factors, with
large elements, since no tolerance decides that it is singular;
`reciprocal_condition` says how near it is. Each update in a factorization is
one subtraction per term into the running element, in increasing order, and
every operation is computed in the order its documentation gives, with no
`fma`, so results are the same bits on every machine,
[CPU level](compiler-guide.md#cpu-levels), and optimization level, but for which NaN a NaN result is, which
[Floating-point operators](design.md#floating-point-operators) leaves
unspecified.

Products of `f32` and `f64` with contiguous columns run a `Simd` kernel that
computes a tile of the output across lanes, each lane one element in its
documented order, and `lu` and `cholesky` are blocked around it, so a large
product runs at about half a reference BLAS's speed, which uses `fma`, and
gives the bits of the plain loop. `multiply`, `multiply_into`,
`multiply_add_into`, `lu`, `lu_in_place`, `cholesky`, and `cholesky_in_place`
take an optional `pool: Option(^thread.Pool)` ([Pools](#pools)): with one,
blocks of the output are computed as tasks on its workers, each element in
the same order, so the result is the same bits as without; a product too small
to share runs on the calling thread.

## `core:math/geometry`

Shapes, rays, frustums, polygons, and exact geometric predicates over
`core:math/linalg`'s vectors. The reasons for its design are in
[Standard-library API choices](comments.md#standard-library-api-choices).

`orient2d(a, b, c)`, `orient3d(a, b, c, d)`, `incircle(a, b, c, d)`, and
`insphere(a, b, c, d, e)` return a `Sign`, `.Negative`, `.Zero`, or
`.Positive`, of a determinant of their points:

- `orient2d` is `.Positive` when `a`, `b`, `c` turn counterclockwise and
  `.Zero` when they are collinear;
- `orient3d` is `.Positive` when `d` is below the plane through `a`, `b`, and
  `c`, which appear counterclockwise from above, and `.Zero` when the four are
  coplanar;
- `incircle` is `.Positive` when `d` is inside the circle through
  counterclockwise `a`, `b`, `c`, and `.Zero` on it;
- `insphere` is `.Positive` when `e` is inside the sphere through `a`, `b`,
  `c`, `d`, given so that `orient3d(a, b, c, d)` is `.Positive`, and `.Zero` on
  it.

Reversing the stated orientation swaps `.Positive` and `.Negative`, and any
odd permutation of the points does too, exactly. For `f32` and `f64`, the
sign is that of the exact determinant of the coordinates as given, as if
computed in real arithmetic, so a hull, a triangulation, or a
point-in-polygon test built on the predicates cannot contradict itself.
Each computes the determinant in floating point with Shewchuk's error bound
and recomputes it exactly, in expansion arithmetic, only when the result is
within the bound, near a degenerate configuration. `f32` coordinates are
exact over their whole finite range. `f64` coordinates are exact when each is
0 or has a magnitude in the range its predicate documents, from
`[2^-450, 2^450]` for `orient2d` to `[2^-150, 2^180]` for `insphere`; a NaN or
an infinity gives a sign that is the same everywhere but means nothing.
Integer coordinates take the plain determinant, which is exact and panics if
it overflows, and other ordered number types take its sign as computed.
`insphere`'s exact path uses about 120 KB of stack.

The shapes are records over the vectors, `Aabb2(T)` and `Aabb3(T)` with
`min` and `max`, `Circle(T)` and `Sphere(T)` with `center` and `radius`,
`Plane(T)` with `normal` and `offset`, `Segment2(T)` and `Segment3(T)` with
`a` and `b`, and `Triangle2(T)` and `Triangle3(T)` with `a`, `b`, and `c`.
Each contains its boundary, so shapes that touch intersect and `contains` is
true on a face. A literal from another package names its fields, so each has
a constructor: `from_min_max` (as given), `from_corners` (sorted),
`from_point`, and `from_points` for boxes, `from_center_radius`,
`from_normal_offset`, and `from_points` for the others.

- **Boxes** are empty when a minimum exceeds its maximum, or a corner is NaN:
  an empty box contains no point, is in every box, intersects nothing, and
  adds nothing to `union`. `Aabb3(T).empty()`, `min = +inf` and
  `max = -inf`, is where a bound accumulates from, for a `Real` `T`; an
  integer box starts from `from_point` or `from_points`, which is `.none` for
  no points. `contains` takes a point or a box, `union` a box or a point, and
  `intersection` gives an empty box for disjoint ones, and the empty one when
  either is empty. `expand(amount)` moves
  every face out, `size` is `max - min`, `doubled_center` `min + max`,
  `center` `min*0.5 + max*0.5`, which cannot overflow, `corner(index)` takes
  `max` on the axes whose bit is set, and `area`, `perimeter`, `volume`, and
  `surface_area` are 0 for an empty box. `closest_point` and
  `distance_squared` need only comparison and arithmetic, so they are exact
  for integers; they and `distance` panic for an empty box, which has no
  nearest point.
- **Circles and spheres** have `contains`, `|p - center|^2 <= radius^2`,
  exact for integers, `bounds`, and, for a `Real` `T`, `closest_point`, which
  is `p` inside, and `distance`, which is 0 inside. A negative or NaN radius
  describes no set, so every member panics on one. For `f32` and `f64`, a
  square that is not a normal number, having overflowed or underflowed,
  decides nothing: `contains`, `closest_point`, `distance`, and the circle and
  sphere tests of `intersects` then compute again in `f64` (where `f32`
  operands cannot overflow or underflow), `f64` operands scaled by a power of
  two, so their answers are those of the finite operands as given, without
  overflow or underflow.
- **Planes** come from `from_point_normal` and `from_points`, which normalize
  the normal, `from_points` toward the side from which the three points turn
  counterclockwise, and return `.none` for a normal that does not normalize.
  `signed_distance(p)` is `dot(normal, p) - offset`, positive on the normal's
  side; `project` and the distances assume a unit normal. `flip` swaps the
  sides, and `intersection_point(a, b, c)` is the one point of three planes,
  `.none` when they share a line or two are parallel.
- **Segments and triangles** have `closest_point`, `distance_squared`, and
  `distance` (Ericson's Voronoi regions, so a point on a region's boundary
  gets that boundary's answer), `bounds`, `length` or `area`, and
  `barycentric(p)`, the `(u, v, w)` of `p`, projected onto the plane in 3D,
  `.none` for a triangle of no area. A segment of no length is its point, and
  a triangle of no area is the segment its corners span. `Triangle3.normal`
  points toward the side from which `a`, `b`, `c` turn counterclockwise.
  `Triangle2.contains` is three exact `orient2d` tests, so it is exact on its
  edges for `f32`, `f64`, and integers, for either winding, and
  `Triangle2.closest_point` of a point it contains is that point.

`closest_points(a, b)` of two segments returns the parameters `s` and `t` of
their closest points, `a.at(s)` and `b.at(t)`, each in `[0, 1]` (Ericson's
method), with `s = 0` for parallel segments and for one of no length.

`intersects(a, b)` takes two boxes, two circles, two spheres, a circle and a
box, a sphere and a box, a sphere and a plane, a box and a plane, two
`Segment2`s, a segment and a box, or a `Triangle3` and an `Aabb3`, in either
order. A box and a plane intersect when the plane separates or touches the two
corners farthest apart along its normal, each corner's distance computed from
the corner itself. Every test compares the values it computes, so integer
shapes intersect exactly. The segment tests are exact for `f32` and `f64`
too: each side test is an exact `orient2d`, a 3D segment and a box are tested
in the three coordinate projections, and segments on one line overlap as their
bounds do. A triangle and a box are tested on the thirteen separating axes of
Akenine-Möller, each projection compared as computed.

`Ray2(T)` and `Ray3(T)` have `origin` and `direction`, which need not be a
unit vector; `from_origin_direction`, `from_points(from, to)`, whose
direction is `to - from`, `at(t)`, and `inverse_direction()`, `1/direction`
per component. `cast(ray, shape, t_min, t_max)` is the first `t` in the
closed range at which the ray meets the shape, or `.none`; the range is
required, since a ray tracer starts past the surface it left and a line is
`[-inf, inf]`.

- **A box**, `Aabb2` or `Aabb3`, is the slab test, with the reciprocal from
  `cast(ray, ray.inverse_direction(), box, t_min, t_max)` computed once for
  many boxes. It is conservative: the exit distance is widened by `2*gamma(4)`
  of the larger end's magnitude, which covers both ends' rounding, so a box
  the exact ray meets is never missed while the distances it computes are
  finite and normal, and a box the ray passes within a few ulps of may be
  reported. A zero direction component gives an unbounded slab when the
  origin is between its faces and an empty one otherwise, with an origin on a
  face counting as between, `-0` as well as `0`.
- **A circle or a sphere** solves the quadratic in the form of Haines et al.,
  which takes the discriminant from the center's distance to the line, so a
  small ball far away keeps its hit. A box and a ball are solids, so a ray
  starting inside one meets it at `t_min`. A ray with a zero direction is its
  origin, met at `t_min` when the origin is inside. For `f32` and `f64`, a
  square or a product of the quadratic that overflows or underflows sends it,
  as for the balls' other queries, to `f64`, the ball's offset and radius
  scaled by one power of two and the direction by another, so a ball far
  bigger or smaller than 1 is met where the finite operands as given meet it.
- **A plane** gives `(offset - dot(normal, origin))/dot(normal, direction)`,
  `.none` for a ray parallel to it.
- **A triangle** gives a `Triangle_Hit(T)`, the `t` and the `barycentric`
  coordinates of the hit point for `a`, `b`, and `c`, by the watertight test
  of Woop, Benthin, and Wald: the corners are sheared into the ray's frame,
  and an edge function that computes as zero has its sign recomputed exactly
  with `orient2d`. Where the edge functions, the determinant they sum to, or
  the distance's numerator overflow or underflow in `T`, as for a small or a
  large triangle, they are computed again from the same sheared corners in
  `f64`, where each product of `f32` coordinates is exact, after scaling
  `f64` corners by a power of two. Two triangles that share an edge so
  decide its side exactly, and a ray through the edge or a shared corner
  hits at least one of them, from either side: for `f32` while the sheared
  corners are finite, and for `f64` while each nonzero sheared coordinate is
  also at least `2^-386` of its triangle's largest. A ray in the triangle's
  plane, or a triangle of no area, gives `.none`.

`Frustum(T)` has `planes: [6]Plane(T)`, left, right, bottom, top, near, and
far, with inward normals, so `contains(p)` is every `signed_distance` at least
0. `Frustum(T).from_matrix(clip, depth)` extracts them from
`clip = projection * view` (Gribb and Hartmann) for the clip depth `depth`,
which decides which rows are the near and far planes and so has no default,
and normalizes each; a far plane at infinity is normal 0 and offset -1, which
every point is inside, and any other plane that does not normalize gives
`.none`. `intersects(frustum, sphere)` and `intersects(frustum, box)`, in
either order, are conservative culling tests: false only when the shape is
wholly behind one plane, so a shape outside the frustum near one of its edges
can be reported as intersecting.

`transform_box(m, box)` bounds the box an affine `m` moves, 4 x 4 for an
`Aabb3` and 3 x 3 for an `Aabb2`, by Arvo's method: each bound is the sum, in
`transform_point`'s order, of each element times the box's minimum or maximum,
whichever product is smaller or larger, so it is exactly the bound of the
corners as `transform_point` moves them, and exact for integers. An empty box
stays empty. `transform_plane(m, plane)` moves a plane through
`m.normal_matrix()` and renormalizes, for a normal of any length, or is
`.none` when `m`'s linear part has no inverse. Spheres and circles have no
transform, since only a similarity keeps them round.

A polygon is `[]linalg.Vector2(T)`, its vertices in order with the last edge
closing back to the first, borrowed rather than copied; it does not repeat its
first vertex at its end, as some formats write a ring. Every side test is an
exact `orient2d` and every other decision a comparison of coordinates, so the
answers are exact for `f32`, `f64`, and integers.

- `signed_area_doubled(polygon)` is twice the signed area, positive for
  counterclockwise vertices, the sum of `(v[i] - v[0]) x (v[i + 1] - v[0])`
  in vertex order, which keeps a polygon far from the origin accurate and is
  exact for integers; `signed_area` halves it. `centroid` is the center of
  the region, each part weighted by its winding number, or `.none` for an
  area that is zero or not normal.
- `winding_number(polygon, p)` is how many times the polygon winds
  counterclockwise around `p`, by Sunday's crossing test, or `.none` when `p`
  is on the boundary, where it is not defined. `contains(polygon, p, rule)`
  holds the boundary, as for every solid, and takes a required
  `Fill_Rule`: `.Nonzero`, SVG's and PostScript's default, or `.Even_Odd`, the
  PDF `f*` operator's and many GIS formats'. They differ only for a
  self-intersecting polygon.
- `is_convex` is true when every turn is the same way or straight and the
  edges' directions go around once; `is_simple` when no two edges meet except
  consecutive ones at their shared vertex. Both are false for fewer than three
  vertices, a vertex repeated next to itself, or a path turning back on itself;
  `is_simple` is quadratic.
- `convex_hull` is Andrew's monotone chain: the hull's corners
  counterclockwise from the lexicographically smallest point, with points on
  its edges and repeated points left out. `convex_hull(points, out)` sorts the
  `[]mut` points in place and writes into `out`, which needs room for every
  point, returning the count; `convex_hull(points, allocator)` sorts a copy
  and returns a `[dynamic]` array.

Everything that does not reach `math.sqrt` or sort, the predicates, the box
algebra, the planes' intersection point, the segments' and triangles' closest
points, the overlap tests, the box, plane, and triangle casts, `transform_box`,
and the polygon procedures but `convex_hull`, is evaluated at compile time with
the same result, and every result is the same bits on every machine,
[CPU level](compiler-guide.md#cpu-levels), and optimization level, but for which NaN a NaN result is, which
[Floating-point operators](design.md#floating-point-operators) leaves
unspecified. An `f32`
box cast computes its three slabs in `Simd` lanes, each lane one axis in the
documented order, which changes its speed and not its bits
([Standard-library API choices](comments.md#standard-library-api-choices)).

## `core:random`

`core:random` draws reproducible values from seeded generators, derives stable
values from a seed and a path of words without a generator, and reads secret
bytes from the operating system. Every procedure that draws takes the generator
`inout`, as `core:io` takes a stream; the package owns no generator of its own.

```loke
Source :: interface($Self: type) {
	slot next_u64: proc(self: inout Self) -> u64;
}

SEQUENCE_VERSION :: u32(1)

@(move_only) Xoshiro256 :: struct { /* private state */ }

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

@(move_only) Pcg64 :: struct { /* private state */ }

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

mix64 :: proc(value: u64) -> u64;

Seed_Path :: struct { /* private state */ }

impl Seed_Path {
	from_seed :: proc(seed: u64) -> Seed_Path;
	with      :: proc(self, word: $T) -> Seed_Path;
	value     :: proc(self) -> u64;
}
```

Each procedure taking a `source` requires `Source(G)`, so a caller's own source
and a `dyn mut random.Source` view work as well as either generator. `in_range`
accepts integer and rune endpoints of at most 64 bits, `choose` a copyable
element type, and `Seed_Path.with` an integer or rune word of at most 64 bits.

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
  passed through the SplitMix64 finalizer,
  [`mix64`](#mixing-and-derived-seeds). The child depends only on the
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
[examples/dice.loke](../examples/dice.loke) does. Do not seed from the clock or a
process ID: parallel runs started together share them.

Seeded generators, the procedures that compute on integers and floats, the
[distributions](#distributions), and `fill`, `shuffle`, and `sample` can run
during [compile-time evaluation](design.md#compile-time-procedure-evaluation),
for example to build a table of random constants, and give the values a run
would. `from_entropy`, a draw from an unseeded generator, `fill_secure`, and
`secure_u64` cannot. Neither can `Weighted.from_weights`, which allocates from
a runtime allocator.

### Reproducibility

A seeded or restored generator produces the same sequence in every release,
on every machine and [CPU level](compiler-guide.md#cpu-levels). The mapping
from draws to values is part of each procedure's contract:

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

Changing a generator's output or any of these mappings is a breaking change,
and so is a [`core:math/repro`](#coremathrepro) fix that changes a
distribution's value. Each increments `SEQUENCE_VERSION`, the version of every
value a seeded or restored generator gives here, which a replay or a lockstep
peer records with `repro.RESULTS_VERSION`, `LOKE_VERSION`, and its own
version; [examples/lockstep.loke](../examples/lockstep.loke) refuses a recording
whose versions differ. An unseeded generator is not reproducible.

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

The tables are constants in the source, computed from R and V with
`core:math/repro`, and the common path calls no `exp` or `log`. A wedge or tail
value calls `exp` or `log`, and the other distributions call `exp`, `log`,
`pow`, or `sqrt` on every value. Each of those is
[`core:math/repro`](#coremathrepro)'s, correctly rounded, so a distribution's
values are the same on every machine, not only its draws. They are slower
than the C library's where a value calls them, most for `beta` by Jöhnk's
method, which calls `pow` twice per attempt;
[Standard-library API choices](comments.md#standard-library-api-choices)
records the measurements.

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

### Mixing and derived seeds

A generator's tenth value depends on the nine drawn before it. Procedural
content usually needs the opposite: a value fixed by *where* it is, such as a
chunk's coordinates, an entity's index, or a level's number, so that it is the
same whichever order a program visits them in, on every machine, and in every
release. `mix64` and `Seed_Path` compute such values without a generator.

```loke
TERRAIN :: u64(1);
LOOT    :: u64(2);

// The same chunk, whichever order chunks are generated in.
chunk_rng :: proc(world: u64, x, y: i32) -> random.Xoshiro256 {
	path := random.Seed_Path.from_seed(world).with(TERRAIN).with(x).with(y);
	return random.Xoshiro256.from_seed(path.value());
}
```

`mix64(value)` is the SplitMix64 finalizer (Steele, Lea, and Flood, 2014),
whose constants are Stafford's Mix13. With every operation modulo 2^64:

```text
z = (z ~ (z >> 30)) *% 0xbf58476d1ce4e5b9
z = (z ~ (z >> 27)) *% 0x94d049bb133111eb
result = z ~ (z >> 31)
```

It is a bijection on 64 bits in which every input bit affects every output
bit. It is a mixer, not a hash: `mix64(0)` is 0, so a counter is first spread
out, as SplitMix64's `n`th output from `seed` is
`mix64(seed +% n *% 0x9e3779b97f4a7c15)`. `Xoshiro256` and `Pcg64` are
[seeded](#seeding) from that sequence and `split` through `mix64`.

A `Seed_Path` is a sequence of 64-bit words, the first being the seed, and its
`value()` is 64 bits that depend on those words alone:

- **Words.** `with(word)` returns the path with `word` appended. The word is
  an integer of at most 64 bits and contributes its value modulo 2^64, as
  [`math.wrap(u64, word)`](design.md#type-conversion) gives: a negative value
  is sign-extended, so `-1` is all ones as an `i8` or an `i64`, and an
  unsigned one is zero-extended, so `u32(0xFFFF_FFFF)` is
  `0x0000_0000_FFFF_FFFF`, unlike `i32(-1)`. A word depends on its value,
  not its type, so widening a coordinate type from `i32` to `i64` keeps every
  value. A rune is a word, its code point, so `'a'` and `97` are one word. A
  float, `bool`, or enum is not a word, nor is a `distinct` integer type,
  which has no arithmetic: convert it, as `i32(x)`. Nor is a 128-bit integer:
  write that as two words, in an order the program fixes.
- **Order and number.** Paths whose words differ in any position, in order,
  or in number are different paths: `(x, y)` and `(y, x)` differ, and so do
  `(a)` and `(a, 0)`.
- **Domain separation is a word.** One seed serves several uses when each
  gets its own constant at a fixed position, as `TERRAIN` and `LOOT` above,
  and their values are then unrelated. A path records words, not their types
  or meanings, so the program fixes what each position means; two schemas
  that put equal words in the same positions name the same values.
- **A path is a value.** It is copyable, and `with` leaves its receiver
  unchanged, so a prefix computed once, `terrain := root.with(TERRAIN)`,
  serves every path below it. `with` is
  [`@(require_results)`](design.md#require_results), since a bare
  `path.with(x);` changes nothing. The zero value is the empty path, and
  `from_seed(seed)` is `Seed_Path{}.with(seed)`.
- **The algorithm.** A state starts at 0, and each word `w` replaces it with
  `mix64(state ~ mix64(w +% 0x9e3779b97f4a7c15))`. `value()` takes that step
  once more, with the number of words, the seed included, as `w`, and returns
  the result without changing the path. Each step costs two `mix64`, so a
  two-coordinate value below a computed prefix costs six.

With every other word fixed, a path's value is a bijection of any one word,
since each step is one: two chunks of one row, or one chunk under two seeds,
never share a value. Otherwise distinct paths collide as random 64-bit values
do, which grows likely only among billions of values. Two paths are not
related by a shift of one word, because each word passes through `mix64`
before it meets the state; were the step `mix64(state ~ w)`, a row of one
world would equal a shifted row of another. Neither `mix64` nor a path
resists crafted inputs or keeps a seed secret, so neither is for
authentication, keys, or a table exposed to hostile keys; see
[`fill_secure`](#operating-system-entropy).

`path.value()` serves as an ID, as the seed of a generator for many values
from one place, as above, or as one value: its top 53 bits times 2^-53 are in
[0, 1), as [`unit`](#reproducibility) maps a draw. Prefer a path to `split`
when the order in which places are visited is not fixed, since `split`
depends on every draw the parent made before it.

Both are frozen: `mix64(v)` and every path's `value()` are the same in every
release, and [`SEQUENCE_VERSION`](#reproducibility) does not cover them,
because they never change. A value saved in a file or sent to a peer keeps
its meaning, and a different algorithm would be a new name. Values drawn from
a generator that a path seeds are covered by `SEQUENCE_VERSION` as any other
draw is.

These are the known answers, which
[tests/run/lib_random_mix.loke](../tests/run/lib_random_mix.loke) checks. A path
is written as its words, seed first:

| Input | Result |
| --- | --- |
| `mix64(0)` | `0x0000000000000000` |
| `mix64(1)` | `0x5692161d100b05e5` |
| `mix64(0x9e3779b97f4a7c15)` | `0xe220a8397b1dcdaf`, SplitMix64's first output from seed 0 |
| `mix64(0xffffffffffffffff)` | `0xb4d055fcf2cbbd7b` |
| `mix64(0x0123456789abcdef)` | `0xb2c058e4ebb5112c` |
| `Seed_Path{}` | `0x48218226ff3cd4bf` |
| `(0)` | `0x62bf47c30a90056f` |
| `(42)` | `0xf71946f3ba67166c` |
| `(0, 0)` | `0xe7c78d6e6cce68d8` |
| `(42, 0, 0)` | `0x435d4ff15aa50e26` |
| `(42, 1, 0)` | `0x7fc23b921bb3edaf` |
| `(42, 0, 1)` | `0xa27dd9f57aa502b6` |
| `(42, -1, 0)` | `0x4ac770b1a45bfe33` |
| `(42, 0, -1)` | `0x7b97a6102cec9903` |
| `(42, 7, -3, 5)` | `0x5035bf946152a002` |
| `(0xffffffffffffffff)` | `0xf2a0877da29e3497` |

A map key's [`hash(seed)`](design.md#maps) is not a substitute. Its algorithm
is unspecified, its result is a `uint` of the target's width, and the runtime
seeds each table itself, so its values change between runs and releases and
must never name saved content.

Both run during
[compile-time evaluation](design.md#compile-time-procedure-evaluation), so a
constant can be derived from a fixed seed and gives the value a run would.

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
fixed UTC offsets, the system's local time zone, and ISO 8601 text. Dates and
times print in the ISO 8601 extended format, in the RFC 3339 profile where one
applies, and parse back. A duration prints in a short form, `1h30m` or
`153ms`; its ISO 8601 form, `PT1H30M`, is one style away and parses too. There
is no locale, no month or weekday name in text, and no pattern language. Other
forms are built from the
[accessors](#the-calendar) with [`fmt.zero_pad`](#corefmt), as in
`fmt.concat_to(w, fmt.zero_pad(date.day(), 2), ".", fmt.zero_pad(int(date.month()), 2), ".", date.year())`
for `15.10.2026`.

Time zones chosen by name, such as `Europe/Stockholm`, are not here yet; see
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
| `Zone` | A fixed `Offset`, or the zone the system's clock shows | UTC |

Every zero value is a valid value. All of them are plain copyable data with no
resource to drop, so they cross threads freely. The four calendar types are the
four kinds of date and time ISO 8601 text distinguishes, and TOML's four:
local date, local time, local date-time, and offset date-time.

Everything except the clocks, `now`, `now_local`, `tick_now`, and `sleep`, and
the system zone, is integer arithmetic in Loke, so it also runs during
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

### Time zones

```loke
Zone :: struct { /* private: a fixed offset or the system's zone */ }
local_zone() -> Zone
fixed_zone(offset: Offset) -> Zone
now_local() -> Offset_Date_Time

Zone.offset_at(self, instant: Time) -> Offset
Zone.to_local(self, instant: Time) -> Offset_Date_Time

Resolution :: union {
	unique:  Offset,
	gap:     (before: Offset, after: Offset),     // clocks skipped this time
	overlap: (earlier: Offset, later: Offset),    // clocks showed it twice
}
Choice :: enum { Compatible, Earlier, Later, Reject }
Zone.resolve(self, local: Date_Time) -> Resolution
Zone.at(self, local: Date_Time,
	choice: Choice = .Compatible) -> Option(Offset_Date_Time)
```

A `Zone` is a fixed offset or the system zone, the one the operating system's
clock shows. It is plain copyable data like the package's other types, and its
zero value is UTC. `now_local()` is `local_zone().to_local(now())`. A zone
chosen by name is not here; see
[Named time zones](open-questions.md#named-time-zones).

A fixed zone prints as its offset does, `+05:30`, or `Z` at zero, so the zero
value and `fixed_zone(UTC)` print `Z`, and `parse_offset` reads the text back.
The system zone prints `local`, which is not a zone name, and printing it
reads nothing: no offset describes the zone at every instant, and the value
follows a change to the setting. `fmt.Options` affect neither.

The system zone's rules are Windows': `GetDynamicTimeZoneInformation` names
the zone and `GetTimeZoneInformationForYear` gives each year's standard offset
and daylight-saving rule, the rules `SystemTimeToTzSpecificLocalTimeEx`
applies. Its history is what Windows records: changes Microsoft has published,
with the earliest recorded rule standing in for the years before it and the
latest for the years after. The package owns no zone data, and Windows Update
keeps the system's current. The `TZ` environment variable, which the C runtime
reads, is not consulted.

A zone that supplies its own fixed rule has that rule every year instead, as
`SystemTimeToTzSpecificLocalTime` applies it: one with no registry key, as
`SetTimeZoneInformation` can set, or one whose dynamic daylight saving is
disabled. Daylight saving runs between the rule's transition dates each year,
unless the dates are cleared. When automatic adjustment for daylight saving
time is off in Windows' settings, Windows clears them: the clock shows
standard time all year, and so does the zone.

Each use reads the current setting, so a long-running program follows a change
to the system zone, and nothing is read at import
([No hidden process behavior](#no-hidden-process-behavior)). If Windows reports
a failure, which it does not on a supported system, the call panics, as
[`random.fill_secure`](#operating-system-entropy) does. A fixed zone reads
nothing, so it also works during compile-time evaluation. The system zone has
no name: Windows names its zones its own way, and the IANA name needs CLDR's
mapping.

A year's rule is read as `SystemTimeToTzSpecificLocalTimeEx` reads it:

- Daylight saving starts at a wall-clock time in standard time and ends at one
  in daylight saving time, both in the rule's year, each the *n*th or last
  weekday of a month or a fixed day. When it starts later in the year than it
  ends, as south of the equator, it runs from the year's start to its end and
  from its start to the year's end.
- A year's rule takes over from the year before's when the clock, under the
  year before's, shows the new year. Where the two disagree there, the clocks
  skip or repeat around midnight on January 1st.
- A transition at midnight in the first week of January stands for the state
  the year starts in, and takes effect when the year's rule takes over.
  Windows writes a year that starts in daylight saving, or one in which it
  changes on January 1st, that way.

A wall-clock time can fall in a gap, when clocks skip forward, or an overlap,
when they repeat. `resolve` says which, with the offsets on each side: a gap's
`before` and `after` are the offsets before and after the clocks skipped, and
an overlap's `earlier` and `later` the offsets of its earlier and later
instants. It tries each offset the zone uses within a day of `local` and keeps
those whose instant converts back to the same wall-clock time: one is
`unique`, two an `overlap`, and none a `gap`. Any date of the calendar can be
resolved, including those outside the range of `Time`.

`at` gives `local` with the offset the choice picks:

| Choice | In a gap | In an overlap |
| --- | --- | --- |
| `Compatible` | The offset before the gap, so the time moves forward by the gap's length, at the offset after it | The earlier instant |
| `Earlier` | The instant before the gap: the time moves back by the gap's length, at the offset before it | The earlier instant |
| `Later` | As `Compatible` | The later instant |
| `Reject` | `.none` | `.none` |

`Compatible` is what RFC 5545 and Temporal do. A time with one offset takes it
whatever the choice. In the European Union's spring change, 02:30 on
2026-03-29 falls in a gap from `+01:00` to `+02:00`: `Compatible` and `Later`
give `2026-03-29T03:30:00+02:00`, and `Earlier` gives
`2026-03-29T01:30:00+01:00`. In autumn, 02:30 on 2026-10-25 is an overlap:
`Earlier` gives `2026-10-25T02:30:00+02:00` and `Later`
`2026-10-25T02:30:00+01:00`. A time moved out of a gap past 9999-12-31 or
before 0000-01-01 panics, as `Date_Time` arithmetic does.

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
segmentation, globbing, regex, memory-mapped files, automatic serialization, or
general `core:util` package.

Planned additions and smaller gaps are listed in
[Standard-library maturity](future-plans.md#standard-library-maturity).

## Test requirements

See [Standard-library verification](compiler-architecture.md#standard-library-verification)
for required coverage and terminal checks. The checked library examples live
in [examples/](../examples/) and [tests/run/](../tests/run/).

# Loke standard library

Implemented for Windows x64. Other targets are planned; see
[More platforms](future-plans.md#more-platforms).

This is the library's API reference. Signature blocks are summaries: they may
omit generic constraints, parameter modes, or private fields. For exact
declarations, read the package source or run `lokec core/<package> -doc`
(see [Common options](compiler-guide.md#common-options)).
Examples use Loke syntax; the API summaries use Odin-style declaration sketches.

| Task | Packages |
| --- | --- |
| Read, write, or enumerate files | [`core:fs`](#corefs), [`core:path`](#corepath) |
| Work with byte streams | [Shared I/O contract](#shared-io-contract) |
| Read lines or terminal keys | [`core:term`](#coreterm) |
| Format values or log messages | [`core:fmt`](#corefmt), [`core:log`](#corelog) |
| Search and build UTF-8 text | [`core:strings`](#corestrings) |
| Parse scalar values | [`core:strconv`](#corestrconv) |
| Call foreign text APIs | [`core:cstrings`](#corecstrings), [`core:encoding/utf16`](#coreencodingutf16) |
| Store integers in a fixed byte order | [`core:endian`](#coreendian) |
| Access process state or start a child | [`core:os`](#coreos-additions), [`core:process`](#coreprocess) |
| Start threads or protect shared state | [`core:thread`](#corethread) |
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
core:sync             atomics, fences, once                   *
core:simd             cross-lane SIMD operations              *
core:thread           threads and the mutex
core:fmt              value formatting and process diagnostics
core:strconv          scalar parsing
core:strings          UTF-8 algorithms and String_Builder
core:cstrings         owned zero-terminated buffers
core:encoding/utf16   UTF-8 to UTF-16 and back
core:endian           fixed byte-order storage wrappers
core:math             elementary functions, Complex, Quaternion
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
alias. The package split is explained in [Standard-library API choices](comments.md#standard-library-api-choices).

## Shared I/O contract

`core:io` owns the error type used by `io`, `fs`, `term`, and fallible process
I/O. It is not a universal application error type.

The declarations are:

```odin
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

```odin
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

```odin
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

### Formatting bridge

Use `io.write_formatted` for fallible output. A `fmt.Sink` cannot return an
error; the bridge stops writing after the first stream failure and returns that
error after formatting. `write_formatted_line` also appends a newline.

```odin
write_formatted(writer, args: ..any_view) -> Status(Error)
write_formatted_line(writer, args: ..any_view) -> Status(Error)
```

`fmt` formats into memory with:

```odin
to_string(allocator: Allocator, args: ..any_view) -> string
```

The allocator is a required leading parameter because the variadic consumes
the remaining arguments. For another sink, format in memory and call
`io.write_string`. To append formatted text to a builder, use
`builder.append(fmt.to_string(allocator, ...))`.

## `core:thread`

`core:thread` starts threads and guards what they share. It supplies the
thread start, join, and unlock edges of design.md "Concurrency and the memory
model".

```odin
spawn(entry: proc(value: move T), arg: move T) -> Thread
spawn(entry: proc()) -> Thread
Thread.join(self: inout)
Mutex(T).lock(self: ^) -> Guard(T)
Guard(T).get(self: inout) -> inout T
processor_count() -> int
```

`spawn` runs `entry(arg)` on a new thread. The argument is moved in, and any
borrow it carries must be of process-lifetime storage, as
`@(escape=static)` requires, so a string literal travels and a slice of a local
does not. Several values travel as one record. Running out of memory or of
threads panics; there is no `try_spawn` yet.

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
mutex outright, before spawning or after joining. Locking a mutex the thread
already holds never returns. `Mutex` is move-only.

`processor_count` is how many threads can run at once: the machine's logical
processors, at least one. A program that divides work among threads, such as a
test harness running a case per thread, sizes its pool by it.

The compiler warns when a spawned entry writes file-scope or `static` storage
(design.md "Global write effects"). Storage behind a `Mutex` or an `Atomic`, and
`thread_local` storage, do not count.

## `core:fmt`

```odin
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
zero_pad(value: $T, width: int) -> Padded(T) where interfaces.Integral(T)
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
and the sign counts toward `width`. Padding formats the value twice, once to
measure it. Each wrapper holds its value as a returned `value` parameter does
(design.md "Parameter semantics and ABI lowering"), so pad a view of a
container rather than the container. They nest, as in `pad_left(fixed(x, 1), 8)`, and the call's
`Options` reach the wrapped value.

## `core:strings`

The built-in string already owns UTF-8 validation, byte/rune counts, immutable
bytes, comparisons, slicing, concatenation, rune iteration, and conversions.
`core:strings` adds algorithms and efficient construction and does not duplicate
those primitives.

### Non-allocating queries

All returned indices are byte offsets:

```odin
contains(text, needle: string_view) -> bool
starts_with(text, prefix: string_view) -> bool
ends_with(text, suffix: string_view) -> bool
index(text, needle: string_view) -> Option(int)
last_index(text, needle: string_view) -> Option(int)
index_byte(text: string_view, value: u8) -> Option(int)
index_rune(text: string_view, value: rune) -> Option(int)
count(text, needle: string_view) -> int
```

An empty needle matches at byte offset zero; `last_index` answers
`.some(text.len())` for it, and `count` returns `text.len() + 1`. `count` counts
non-overlapping occurrences.

### Borrowing transformations and iterators

These do not allocate and return `string_view`s borrowing the input:

```odin
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

```odin
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

```odin
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

```odin
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
string allocation is described in [Runtime and library boundary](compiler-architecture.md#runtime-and-library-boundary).

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

```odin
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

```odin
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

## `core:endian`

A binary format fixes each field's byte order; these wrappers put that order in
the field's type, so the swap happens at `store` and `load` rather than wherever
a caller remembers it.

```odin
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

```odin
parse_bool(text: string_view) -> Option(bool)
parse_i64(text: string_view, base := 0) -> Result(i64, Parse_Error)
parse_u64(text: string_view, base := 0) -> Result(u64, Parse_Error)
parse_int(text: string_view, base := 0) -> Result(int, Parse_Error)
parse_uint(text: string_view, base := 0) -> Result(uint, Parse_Error)
parse_f64(text: string_view) -> Result(f64, Parse_Error)
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
subnormal rounds to zero. `inf` and `nan` are not accepted. The point is
always `.`, whatever numeric locale foreign code has set for the C library. As
with formatting, failing to create the "C" numeric locale for it panics.

Formatting scalars remains in `core:fmt`; `strconv` should not grow a second
formatting system.

## `core:log`

design.md "Build-selected providers" says how a program selects its logger, and
"Compiled log level" what `-log-level` removes. This is the package's surface.

```odin
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

```odin
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

### Whole-file convenience

```odin
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
has successfully opened the target. It does not promise atomic replacement.
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

### Filesystem operations

```odin
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
time outside the range of `time.Time` saturating at its end. There is no
symlink support; when it arrives its behavior is explicit, not inherited from
what Windows does.

## `core:path`

Path operations are lexical and perform no filesystem access:

```odin
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
the filesystem. A later `fs.absolute` or `fs.canonicalize` performs actual
filesystem resolution and returns an I/O error.

`clean` returns an extended-length path unchanged because Windows uses it to
bypass normalization. There is no automatic long-path prefixing.

## `core:term`

Terminal input has two distinct levels. Line input is the default for command
line programs. Key events are an explicit terminal-only facility, not a global
keyboard hook and not GUI input.

### Standard byte streams and line input

```odin
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

```odin
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
Key releases, mouse, focus, and resize records are skipped. A held key's repeat count becomes that many events, in order.

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

Besides `os.args` and `os.exit`, `core:os` has these process-level operations:

```odin
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

```odin
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
`wrapping_sub`, `wrapping_mul`, `checked_add`, `checked_sub`, and
`checked_mul`.

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
- `floor`, `ceil`, `round`, `trunc`, `mod`, `sqrt`, `hypot`, `pow`, `exp`, `log`,
  `log2`, `log10`, `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`,
  `to_radians`, and `to_degrees`.

Floating-point functions use an unsuffixed name for `f64` and `_f32` for
`f32`, avoiding ambiguous overloads for untyped literals. There is no implicit
widening and no `f16` variant.

The procedures backed by the C library promise the classifications, signs,
poles, and domain results documented on each one. They do not promise correctly
rounded results, identical last bits across platforms, a particular NaN
payload, or `errno` contents, and they never turn a floating-point exception
into a panic.

## `core:random`

`core:random` draws reproducible values from seeded generators and secret bytes
from the operating system. Every procedure takes the generator `inout`, as
`core:io` takes a stream; the package owns no generator of its own.

```odin
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
`fill`, `shuffle`, and `sample` can run during [compile-time evaluation](design.md#compile-time-procedure-evaluation),
for example to build a table of random constants. `from_entropy`, a draw from an
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
Those functions do not promise identical last bits across platforms; see
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

```odin
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

```odin
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

A `Duration` is exact, and arithmetic that overflows panics, as signed integer
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

```odin
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

```odin
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

```odin
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

```odin
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

```odin
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

# Loke standard library

Status: implemented for Windows x64. Other targets wait on the compiler (see
[future-plans.md](future-plans.md) "More platforms"); every platform call sits
behind a `when (LOKE_OS == ...)` whose non-Windows arm is never selected yet.

This document gives the organization, conventions, and public APIs of Loke's
standard library. The `.loke` sources are the final word on exact signatures.

The library lets a small command-line program:

- read and write binary files and UTF-8 text files;
- read lines from standard input and write raw bytes to standard output;
- read terminal key events when it explicitly opts into terminal mode;
- search, split, trim, join, and efficiently build strings;
- parse the common scalar types from text;
- report and propagate I/O failures without panicking; and
- manage files and terminal modes safely through normal Loke lifecycle hooks.

The standard library is ordinary Loke code wherever possible. The compiler
should contribute only facilities that cannot be expressed in the language,
not convenience procedures or operating-system policy.

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
input silently. String indices and search results are byte offsets unless a
name explicitly says `rune` or `grapheme`.

Paths are accepted as UTF-8 `string_view`s. On Windows they are converted to
UTF-16 (through `core:encoding/utf16`) and passed to the wide operating-system
APIs. A native path that cannot be represented as valid Unicode is reported as
invalid data rather than being silently changed. A path containing U+0000 is
`Invalid_Path`, because the wide call would read it only up to the zero.

### Errors are values

Absence alone answers `Option(T)`. A failure with useful information answers
`Result(T, Error)`, whose failure variant carries the error value, so it
composes with `or_return`. Neither is a trailing status: `nil` is not a failure
and a trailing `bool` is not one either.

The `try_` prefix keeps its existing meaning: it is the fallible version of an
operation that would otherwise apply an allocation or capacity failure policy.
Operations that are inherently fallible, such as `open`, `read`, and `remove`,
do not use a `try_` prefix.

Programmer errors may panic. Missing files, denied access, invalid input data,
end of input, and a disconnected terminal are ordinary returned errors.

### Ownership is visible

An owning resource is move-only, has an inert zero value, and releases itself
with `drop`. It also has an explicit `close` operation so a caller can observe
close or flush failures. `close` is idempotent and leaves the value inert even
when it reports an error. `drop` performs a best-effort close and cannot report
the error.

`drop` is not a termination guarantee. It runs on scope exit, `return`, `break`,
and `continue`; it runs during panic unwinding only in a build using the `unwind`
strategy, and it never runs after `os.exit`. A resource whose release matters
beyond the process — a terminal mode, not a file handle the operating system
reclaims — needs a second, platform-level restore path as well. `core:term` is
the only such case so far.

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

There is no per-file target selection: the compiler has no `_windows.loke`
convention and the driver does not filter sources by target. Platform code is
selected inside one file with `when (LOKE_OS == .Windows)`, over a foreign block
per platform. `LOKE_OS` is currently a fixed `.Windows` in
`src/build_config.odin`, so other branches exist but are never taken. If a
file-selection rule is wanted later, it is a compiler and `design.md` change and
must land before non-Windows ports, not as part of them.

The existing versioned C runtime remains the last resort for startup, compiler
ABI, or unwind services. Normal file and terminal operations should be ordinary
library code over foreign operating-system calls.

## Package layout

The list is dependency-ordered: a package may import packages above it, but not
packages below it. Packages must not form import cycles.

```text
base:runtime          compiler/runtime ABI types
base:meta             compile-time descriptors
base:interfaces       structural interface catalogue

core:mem              allocators and regions                  *
core:unsafe           explicit trust boundary                 *
core:sync             atomics, fences, once                   *
core:simd             cross-lane SIMD operations              *
core:fmt              value formatting and process diagnostics
core:strconv          scalar parsing
core:strings          UTF-8 algorithms and String_Builder
core:cstrings         owned zero-terminated buffers
core:encoding/utf16   UTF-8 to UTF-16 and back
core:endian           fixed byte-order storage wrappers
core:math             elementary functions, Complex, Quaternion
core:slice            slice algorithms and sorting            *
core:container        Small_Array, Bit_Set, Enum_Array        *
core:log              logging over the selected provider      *
core:io               byte stream protocols and the I/O error
core:path             lexical path operations
core:fs               files, directories, and file metadata
core:term             standard streams and terminal key input
core:os               arguments, exit, environment, process state
```

A package marked `*` is specified by `design.md`, in the section its source
header comment cites; this document covers the unmarked packages.

Later packages follow the same pattern rather than growing the existing ones
indefinitely: `core:bytes`, `core:time`, `core:random`, `core:unicode`,
`core:encoding/base64`, `core:encoding/json`, and `core:testing`.

Nested paths are taxonomy, not inheritance. For example,
`core:encoding/json` does not automatically import `core:encoding`.

### Files are in `core:fs`, not `core:os`

`core:os` is process state, and a package that owns the argument vector should
not also own file handles. There is no `os.open` alias: one spelling for opening
a file is the point.

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
	Other,
}

Error :: struct {
	@(private) code:        Code,
	@(private) native_code: u32,
	@(private) operation:   Operation,
}

make_error(code: Code, operation: Operation,
	native_code: u32 = 0) -> Error
from_allocator_error(operation: Operation) -> Error
is(error: Error, code: Code) -> bool
code_of(error: Error) -> Code
operation_of(error: Error) -> Operation
native_code_of(error: Error) -> u32
```

`Operation` is a closed, non-owning description of the operation that failed.
It replaces a borrowed operation string so an error cannot outlive diagnostic
text. Add an enum member when a public operation needs a distinct diagnostic;
do not put paths or other caller data in the error merely for context.

The error does not borrow the caller's path and does not allocate merely to
report a failure. `native_code` is zero when there is no platform code.
`Closed` means the stream was closed before the call; `Unsupported` means a
live stream was asked for a direction it does not have.
The query procedures are `is`, `code_of`, `operation_of`, and `native_code_of`;
the reader is `code_of` rather than `code` because `Code` is the enum's own name
and a package member cannot be both. The inherent `format` is declared in
`core:io`, which is the value type's own package, so it satisfies the formatting
coherence rule.

`make_error` and `from_allocator_error` are public because Loke has package and
public visibility only: `core:fs`, `core:term`, `core:os`, and third-party
`Reader`/`Writer` implementations cannot call a package-private `core:io`
constructor. The constructors accept only owned scalar data, so exposing them
does not weaken the error's lifetime guarantee. `Error`'s fields remain
package-private; access is through the constructors and query procedures.

`Out_Of_Memory` is not a second allocation-failure vocabulary. Every `io`, `fs`,
`term`, and `os` procedure that allocates takes an allocator parameter and uses
the `try_` form internally; an `.err(mem.Allocator_Error)` is converted at that
one call site with `from_allocator_error`, after the partial result is destroyed.
No procedure's failure payload is both an `Allocator_Error` and an `io.Error`.

Streams are synchronous and blocking. Both are written with
`slot` requirements, which is what dyn-compatibility requires, and that is what
makes `dyn io.Writer` exist for the formatting adapter and for `io.copy`.

```odin
Reader :: interface($Self: type) {
	slot read: proc(self: inout Self, destination: []mut u8) -> Result(int, Error);
}

Writer :: interface($Self: type) {
	slot write: proc(self: inout Self, source: []u8) -> Result(int, Error);
}
```

The receiver must be named `self` and must be the only occurrence of the subject
in the signature; both hold here.

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

copy(destination, source, buffer: []mut u8 = nil) -> Result(u64, Error)
read_exact(reader, destination) -> Result(Unit, Error)
read_to_end(reader, allocator: Allocator = mem.default_allocator(),
	limit: int = 0) -> Result([dynamic]u8, Error)
write_all(writer, source) -> Result(Unit, Error)
write_string(writer, text: string_view) -> Result(Unit, Error)
read_line(reader, allocator: Allocator = mem.default_allocator(),
	options: Line_Options = {}) -> Result(string, Error)
```

Every default argument names a type. `{}` takes its type from context and `:=`
infers from the expression, so `options := {}` has no type at all; a parameter
default for a zero value must be written `name: T = {}`. A *slice* default is
`= nil` rather than `= {}`, because `{}` at a slice type is a slice literal and
must be written with its type.

`limit == 0` means no library-imposed limit. A nonzero limit prevents an
untrusted stream from causing unbounded allocation. An input that would make the
result exceed a nonzero limit returns `Limit_Exceeded`; the partial owning result
is destroyed and the returned value is zero. `read_line` removes `\n` and one
immediately preceding `\r` by default; `keep_ending` retains it. An unterminated
final line is returned successfully. End of input before any bytes returns
`End_Of_Input`.

There are no buffered wrappers yet. `read_to_end` plus a caller's own
`[]mut u8` covers what the file and stream APIs need, and buffering policy is worth designing
against a measured cost rather than in advance. When it arrives it is an explicit
wrapper value, never hidden global state.

### Formatting bridge

The existing `fmt.Writer` callback cannot return an error. It remains suitable
for process diagnostics and in-memory sinks, but a formatted file write must
not silently lose a disk error.

`io.write_formatted` bridges the two. Its adapter presents a `fmt.Writer`,
writes into an `io.Writer`, latches the first `io.Error`, makes later callbacks
no-ops, and returns the latched error after formatting. This preserves the
existing formatting ABI.

The adapter is not a safe construction and must not be described as one. `fmt.Writer.state`
is a `rawptr`, so the adapter holds a local latch record — a `dyn io.Writer`
borrow plus an `Error` — and converts its address through `core:unsafe`, which
discards checked provenance. The resulting `fmt.Writer` is valid only for the
enclosing call and must never be stored, returned, or handed to a callee that
retains it. `write_formatted` therefore constructs, uses, and discards the
adapter within its own body; the raw pointer is never a value a caller holds.
`dyn io.Writer` existing at all depends on `Writer` being declared with `slot`.

```odin
write_formatted(writer, args: ..any_view) -> Result(Unit, Error)
write_formatted_line(writer, args: ..any_view) -> Result(Unit, Error)
```

`fmt` formats into memory with:

```odin
to_string(allocator: Allocator, args: ..any_view) -> string
```

The allocator is a required leading parameter here, not a defaulted trailing one:
a variadic absorbs the trailing arguments, so nothing after it can be supplied
and nothing defaulted before it can be omitted. This is useful independently and
gives a simple fallback for any sink: format in memory, then call
`io.write_string`.

There is no `append_to(builder: inout strings.String_Builder, ...)`, and the
reason is measured rather than aesthetic. It would make `core:fmt` import
`core:strings`, an imported package is emitted whole, and that one import
roughly quadruples hello world's IR. The call it saves is one line —
`builder.append(fmt.to_string(allocator, ...))` — which is not worth that cost
to every program that prints. `to_string`
itself keeps its selected allocator by receiving the same compiler-contributed
`allocate_string` primitive `core:strings` gets.

## `core:fmt`

```odin
Writer :: struct {
	write: proc(state: rawptr, bytes: [^]u8, count: int),
	state: rawptr,
}
Options :: struct { base: int, uppercase: bool }
DEFAULT_OPTIONS :: Options{10, false};

print(args: ..any_view)
println(args: ..any_view)
eprint(args: ..any_view)
eprintln(args: ..any_view)
stdout() -> Writer
stderr() -> Writer
format_to(w: Writer, args: ..any_view)
format_to_with(w: Writer, options: Options, args: ..any_view)
to_string(allocator: Allocator, args: ..any_view) -> string
```

Arguments are separated by one space. `Options.base` is 2 to 36 and any other
value reads as 10; it and `uppercase` reach integers and whatever a type's
`format` passes them to. A float prints the shortest spelling that reads back
as the same value at its own width, in fixed notation from 1e-4 to below 1e17
and with an exponent outside that; NaN prints as `nan` and the infinities as
`inf` and `-inf`. A struct without its own `format` prints its public fields
only.

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

Whitespace in `trim_space` and `fields` is Unicode White_Space, not only ASCII
(`strings.is_space`: twenty-five code points tested by range).
Search compares bytes and slices only at an offset that has already matched,
which is a code-point boundary because UTF-8 is self-synchronising; slicing a
view through a code point is a runtime failure.
`lines` recognizes `\n`, `\r\n`, and a final unterminated line. General Unicode
normalization, locale rules, grapheme segmentation, and case folding belong in
a later `core:unicode` package.

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

`copy` and `try_copy` are the public face of the compiler primitive below, and
the identity case of this family. Every other string-returning procedure in the
standard library goes through them, because they are the only way a library can
create a `string` in storage the caller selected. `join` takes a slice for the
same reason `path.join` does: a variadic would absorb the allocator.

Case conversion is ASCII-only. Full Unicode case mapping needs
tables that belong in a `core:unicode`, and guessing a subset of them would be
worse than passing the rest through unchanged; the signature already returns
owned storage, so the tables can arrive without changing a caller.

The policy-following forms above panic only on allocation-policy failure.
Negative counts and other programmer mistakes panic.

No `try_` twin exists for these. `String_Builder` already
offers the fallible path — including `try_reserve`, `try_append`, and
`try_finish` — and a caller that must survive allocation failure can build the
same result there. A `try_join` or `try_replace` is added when a caller actually
needs one, not as a matching set.

Unicode case conversion, when it arrives, may change the byte and rune counts.
Locale-sensitive conversion must not be guessed from a process-global locale.

### `String_Builder`

`String_Builder` maintains valid UTF-8 at every public boundary. It is an
ordinary owning value over `[dynamic]u8`.

**Its zero value is a usable, empty, allocator-unbound builder.** `design.md`'s
string section already shows `builder: String_Builder = {};` followed by
`append`, so `= {}` compiles; it inherits the allocator-unbound
behavior of the `[dynamic]u8` it wraps and binds on first growth. `init` exists
only to select another allocator up front.

Every operation is a method in one `impl String_Builder` block, not a free
procedure. Two members of one `impl` block cannot share a name, so the two
`append`s are distinctly named members collected into a procedure group; the
call syntax is the same. That is what makes `len(builder)` resolve at all — `len` and `cap` are
ordinary shadowable names, not privileged syntax — and it is what lets the type
answer `interfaces.Sequence` later without a second spelling.

```odin
String_Builder :: struct { /* private representation */ }

init :: proc(allocator: Allocator = mem.default_allocator()) -> String_Builder

impl String_Builder {
	len          :: proc(self) -> int;
	cap          :: proc(self) -> int;
	reserve      :: proc(self: inout String_Builder, additional: int);
	try_reserve  :: proc(self: inout String_Builder, additional: int)
		-> Result(Unit, Allocator_Error);
	append_text  :: proc(self: inout String_Builder, text: string_view);
	append_rune  :: proc(self: inout String_Builder, value: rune);
	append       :: proc{append_text, append_rune};
	append_byte_ascii :: proc(self: inout String_Builder, value: u8);
	try_append_text :: proc(self: inout String_Builder, text: string_view)
		-> Result(Unit, Allocator_Error);
	try_append_rune :: proc(self: inout String_Builder, value: rune)
		-> Result(Unit, Allocator_Error);
	try_append   :: proc{try_append_text, try_append_rune};
	try_append_byte_ascii :: proc(self: inout String_Builder, value: u8)
		-> Result(Unit, Allocator_Error);
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

The current `[dynamic]u8` and `string` runtime layouts are not storage-compatible:
a dynamic array owns raw element storage, while a runtime string points past its
reference-counted allocation header. `finish` therefore performs one linear copy
into string storage and then clears the builder, retaining its allocation for
reuse. `try_finish` has the same success behavior and leaves the builder
unchanged if allocation fails; `finish` applies the builder allocator's failure
policy. `copy_string` and `try_copy_string` do not change the builder.

`view` borrows the text written so far without allocating. The borrow checker
rejects an append while the view is live, so a reader that only inspects the
result (as `path.join` does before `path.clean`) need not copy it.

The compiler contributes one package-private `core:strings` primitive that
copies a known-valid `string_view` into string storage with a supplied allocator
and answers `Result(string, Allocator_Error)`. This is the minimal unexpressible
bridge to the built-in string allocation ABI; UTF-8 algorithms and allocation
policy remain ordinary Loke. It is `allocate_string`, contributed to `core:fmt`
as well. Arbitrary byte append is deliberately absent because it
could break the UTF-8 invariant; callers validate bytes first or use a byte
buffer.

The type's public name in source is `strings.String_Builder`. A shorter
`strings.Builder` alias can be considered only after real programs show that it
improves readability.

## `core:cstrings`

`C_String` is an ordinary owning zero-terminated byte buffer for foreign APIs
that retain a string after the call. Unlike `string`, it does not promise UTF-8.
Moving it is cheap; copying follows the normal lifecycle rules and clones the
owned buffer.

`design.md` spells the accessor as a method, `value.view() -> cstring_view`, so
the whole surface is methods in one `impl` block for the same reason
`String_Builder`'s is.

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

`cstrings.Error` distinguishes `Contains_Zero` from `Out_Of_Memory`, and reaches
a caller as the failure payload of `Result`. The constructor rejects an interior
zero; a Loke `string` may legitimately contain U+0000 even though a retained C
string cannot. The package must never create a view whose apparent length is
shorter than the owned data.

There is no `from_bytes` or `bytes()` accessor. `design.md`
only owes `view()`, and the one motivating case — handing a foreign API a string
it retains — starts from a `string_view`. Add the byte-oriented pair when a
caller has bytes that are not text.

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

`base == 0` recognizes the language prefixes `0b`, `0o`, and `0x`; otherwise
the accepted range is 2 through 36, with no prefix. Underscores may separate
digits, as in a Loke literal.

Formatting scalars remains in `core:fmt`; `strconv` should not grow a second
formatting system.

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
	flush   :: proc(self: inout File) -> Result(Unit, io.Error);
	close   :: proc(self: inout File) -> Result(Unit, io.Error);
	is_open :: proc(self) -> bool;
}
```

The stream operations are methods because a `slot` requirement is satisfied by
a *member*, so `io.Reader` and `io.Writer` can only be answered by methods.
`is_open` exists because a caller that has closed explicitly has no other way
to ask.

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
write_bytes(path, data: []u8) -> Result(Unit, io.Error)
write_text(path, text: string_view) -> Result(Unit, io.Error)
append_bytes(path, data: []u8) -> Result(Unit, io.Error)
append_text(path, text: string_view) -> Result(Unit, io.Error)
```

`read_text` validates UTF-8. `write_*` truncates an existing file only after it
has successfully opened the target. It does not promise atomic replacement.
`read_bytes` and `read_text` use the same `limit` contract as `io.read_to_end`:
exceeding a nonzero limit answers `.err(Limit_Exceeded)` and destroys partial
storage.
An explicit `replace_atomic` helper may be added later with precisely documented
same-filesystem and durability guarantees.

### Filesystem operations

```odin
metadata(path) -> Result(Metadata, io.Error)
exists(path) -> Result(bool, io.Error)
remove(path) -> Result(Unit, io.Error)
rename(old_path, new_path) -> Result(Unit, io.Error)
create_directory(path) -> Result(Unit, io.Error)
create_directories(path) -> Result(Unit, io.Error)
remove_directory(path) -> Result(Unit, io.Error)
read_directory(path, allocator := mem.default_allocator())
	-> Result(Directory_Reader, io.Error)
```

`Directory_Reader.next` answers `Result(Option(Directory_Entry), io.Error)`:
presence and failure are different answers, and a directory walk has to
distinguish "no more entries" from "the enumeration broke". `read_directory`
returns a **move-only streaming reader**, not an owning array.
This is not a preference: a `[dynamic]Directory_Entry` whose entries own their
name `string` would have every step retain and release that name, and a
directory walk that only reads each name should not pay for a copy of it. The
reader borrows instead. The reader yields one entry at a time, borrows
its name into a caller-visible buffer valid until the next `next`, and closes its
platform search handle in `drop`. A caller wanting an array collects one itself.
Because `next` reports both the end and a failure, the reader is not a `foreach`
iterable; the loop that walks it is design.md "Streaming a fallible source", and
`tests/run/lib_fs` walks a directory with it.

`create_directories` succeeds when the path ends up naming a directory, so an
existing directory and a volume root such as `C:\` are not failures, while an
existing file is `Already_Exists`. A path ending in a drive's colon, such as
`C:`, names that drive's current directory for `read_directory` as for every
other operation.

`exists` answers `.ok(false)` only for a definite not-found result; permission
and I/O failures remain errors. `Metadata` holds `kind` (`File`, `Directory`,
or `Other`), `size` in bytes, and `modified` as nanoseconds since the Unix epoch
in an `i64`, until `core:time` gives it a type. There is no symlink support; when
it arrives its behavior is explicit, not inherited from what Windows does.

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

`join` and `clean` return owning storage, so they take an allocator like every
other such procedure. The allocator takes their scratch as well as their result,
so a caller sizing a `mem.Arena` around either should budget a few times the
result rather than exactly it. `join` takes a slice rather than a variadic: a variadic
absorbs every trailing argument, so a defaulted allocator before one could never
be omitted, and one after one could never be supplied. `path.join({a, b})` also
matches `strings.join`, which already takes its parts as one value.

The result follows target-platform path rules. `clean` removes redundant
separators and lexical `.`/`..` elements but does not resolve symlinks or access
the filesystem. A later `fs.absolute` or `fs.canonicalize` performs actual
filesystem resolution and returns an I/O error.

Drive-relative (`C:x`), rooted-but-drive-relative, UNC, and extended-length
paths each have a case in `tests/run/lib_path.loke`. `clean` returns an
extended-length path unchanged: such a path exists to bypass normalization, and
Windows passes it to the filesystem verbatim. There is no automatic long-path
prefixing.

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

`read_line` reads a real console through `ReadConsoleW` and a redirected handle
through `io.read_line`, so typed non-ASCII text arrives intact. The raw
`Input.read` stream is bytes through `ReadFile` either way.

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
	close    :: proc(self: inout Raw_Mode) -> Result(Unit, io.Error);
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

`Raw_Mode.drop` restores the exact previous terminal mode on ordinary return,
`break`, `continue`, and — **only in a build using the `unwind` panic strategy** —
during panic unwinding. That qualifier is not a detail to drop in the
documentation. Under the `abort` strategy no cleanup is guaranteed, and `os.exit`
runs no `defer`, no `drop`, and no thread-local cleanup on any strategy. A
program that calls `os.exit` while raw leaves the user's terminal raw.

Because a wedged terminal outlives the process that wedged it, `drop` is not the
only restore path. `begin_raw` also registers the saved console mode with a
process-level restore — a `SetConsoleCtrlHandler` handler on Windows — so
Ctrl+C, Ctrl+Break, and console close restore the mode without depending on Loke
cleanup running at all. The handler is idempotent with `drop` and with `close`.
This is the one place the library pays for a guarantee the language does not
make; the rule against hidden process behavior still holds, because
nothing is registered until a caller asks for raw mode.

`begin_raw` on redirected input answers `.err(Not_A_Terminal)`.

Only one `Raw_Mode` may be live in a process. The process-level control handler
has one authoritative saved console mode; allowing another scope to overwrite
it would make out-of-order cleanup or a control event restore the wrong mode.
A second `begin_raw` therefore answers `.err(Already_Exists)` and leaves the
terminal unchanged.

Text input is `key == .Character` with the scalar value in `value`; a named key
leaves `value` zero, and is preferred when a key such as Enter or Tab also
carries a control character. A key the decoder has no name for is `.Unknown`.
Modifiers are explicit flags. Key releases, mouse, focus, and resize records are
skipped. A held key's repeat count becomes that many events, in order.

By default Ctrl+C keeps interrupting the process; `Raw_Options{interrupt_as_key =
true}` delivers it as a key event instead, and the program then terminates
itself.
Mouse events, window resizing, colors, cursor movement, and full-screen terminal
UI belong to later terminal packages.

## `core:os` additions

Besides `os.args` and `os.exit`, `core:os` has these process-level operations:

```odin
get_environment(name: string_view,
	allocator := mem.default_allocator()) -> Result(Option(string), io.Error)
set_environment(name, value: string_view) -> Result(Unit, io.Error)
unset_environment(name: string_view) -> Result(Unit, io.Error)
working_directory(allocator := mem.default_allocator())
	-> Result(string, io.Error)
set_working_directory(path: string_view) -> Result(Unit, io.Error)
executable_path(allocator := mem.default_allocator())
	-> Result(string, io.Error)
```

The `Option` from `get_environment` distinguishes a missing variable from a
present empty value, except that on Windows setting a variable to the empty
string removes it; that is the platform's behavior, documented at the call. Its
owning result uses the supplied allocator. Environment
names and values must become valid UTF-8 or the operation returns invalid data.
A name, value, or path passed in containing U+0000 is invalid data as well.
A process-spawning API is deferred until handle inheritance, quoting, environment
replacement, and pipe ownership are designed together.

## `core:math`

`Complex(T)` and `Quaternion(T)` are specified in `design.md` "Library numeric
types", and the checked integer conversion `math.to(T, value)` in `design.md`
"Type conversion". The rest of the package is:

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

Every floating-point procedure has two spellings: the unsuffixed name works on
`f64` and the `_f32` name on `f32`. They are not a procedure group, because
`design.md` leaves an `f32`/`f64` overload ambiguous for an untyped literal and
`math.sqrt(2.0)` would stop compiling. Both widths exist because there is no
implicit widening, and `f32(math.sqrt(f64(x)))` rounds twice. `f16` has none.

The procedures backed by the C library promise the classifications, signs,
poles, and domain results documented on each one. They do not promise correctly
rounded results, identical last bits across platforms, a particular NaN
payload, or `errno` contents, and they never turn a floating-point exception
into a panic.

## What is deliberately absent

- async I/O or an event loop;
- networking and DNS;
- global keyboard hooks or GUI events;
- locale-sensitive string behavior;
- Unicode normalization and grapheme segmentation;
- globbing and regular expressions;
- memory-mapped files and file locking;
- subprocess creation;
- automatic serialization;
- a universal `Result`, `Option`, or exception hierarchy; and
- a broad `core:util` package.

These can be added after their contracts are understood. None is required to
make ordinary command-line programs useful.

Smaller omissions, each additive over what exists and waiting for a caller:
`core:bytes`, `time`, `random`, and `testing`; a buffered reader,
`fs.replace_atomic`, `fs.absolute`, and symlink support; a `try_` twin for the
allocating string transformations; Unicode case mapping (case conversion is
ASCII-only); in `core:math`, hyperbolics, `cbrt`/`fma`/`ldexp`/`frexp`/`modf`,
`erf`, `gamma`, lane-wise math over `Simd(T, N)`, and integer bit helpers; in
`core:simd`, the version-1 omissions design.md names.

## Test requirements

Library behavior is tested by the corpus programs `tests/run/lib_*.loke`, which
run at every optimization level with the rest of the corpus
([compiler-architecture.md](compiler-architecture.md) "Testing and
verification"), and by the programs in `examples/`. A new or changed public API
covers whichever of these cases apply:

- empty input, empty files, and empty strings;
- binary data containing zero bytes;
- valid multi-byte UTF-8 and deliberately invalid UTF-8;
- Unicode file names and long Windows paths;
- missing, inaccessible, read-only, and already-existing paths;
- partial reads/writes, end of input, interruption, and broken pipes;
- bounded reads one byte below, exactly at, and one byte above the limit, with
  `Limit_Exceeded` destroying partial owning results;
- allocator failure at every growing operation, with the destination unchanged
  (a deliberately small `mem.Arena` makes this deterministic);
- explicit close followed by drop, double close, and panic unwinding;
- redirected standard handles; and
- byte offsets around one-, two-, three-, and four-byte runes.

Protocol tests drive fake short readers and writers, as `lib_io` does.
Filesystem tests work in an isolated temporary directory, as `lib_fs` does, and
never depend on the repository working directory or a developer's environment.

Terminal input is not automated, because a corpus program has no console of its
own: `lib_term` covers only output and redirected handles. Raw-mode restoration
on scope exit, on `close`, and on panic in an `unwind` build, and the console
control handler's restore, are checked by hand with `examples/keys.loke`.
Testing the key decoder from synthetic console records would automate
everything but that last layer.

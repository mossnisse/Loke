# Loke standard library plan

Status: implemented for Windows x64. Stages 0 to 3 are in the tree with tests;
stage 4 remains gated on non-Windows targets. "Implementation record" at the end
of this document lists every place the shipped contract differs from the design
above, and why.

This document gives the organization, conventions, public APIs, and
implementation order of Loke's standard library. It started from the library
surface that already existed: `base:runtime`, `base:meta`, `base:interfaces`,
`core:mem`, `core:fmt`, `core:os`, and `core:unsafe`.

The first useful release should let a small command-line program:

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
UTF-16 and passed to the wide operating-system APIs. A native path that cannot
be represented as valid Unicode is reported as invalid data rather than being
silently changed.

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
the only first-release case.

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
must land before Stage 4, not as part of it.

The existing versioned C runtime remains the last resort for startup, compiler
ABI, or unwind services. Normal file and terminal operations should be ordinary
library code over foreign operating-system calls.

## Package layout

The list is dependency-ordered: a package may import packages above it, but not
packages below it. Packages must not form import cycles.

```text
base:runtime       compiler/runtime ABI types
base:meta          compile-time descriptors
base:interfaces    structural interface catalogue

core:mem           allocators and regions                       (existing)
core:unsafe        explicit trust boundary                      (existing)
core:strings       UTF-8 algorithms and String_Builder          (new)
core:cstrings      owned zero-terminated buffers                (new)
core:strconv       scalar parsing and text conversion           (new)
core:fmt           value formatting and process diagnostics     (existing, grow)
core:io            byte stream protocols and buffered helpers   (new)
core:path          lexical path operations                      (new)
core:fs            files, directories, and file metadata        (new)
core:term          standard streams and terminal key input      (new)
core:os            arguments, exit, environment, process state  (existing, grow)
```

Later packages should follow the same pattern rather than expanding the first
release packages indefinitely:

```text
core:bytes
core:sort
core:math
core:time
core:random
core:encoding/utf16
core:encoding/base64
core:encoding/json
core:log
core:testing
```

Nested paths are taxonomy, not inheritance. For example,
`core:encoding/json` does not automatically import `core:encoding`.

### Files are in `core:fs`, not `core:os`

`design.md` originally assigned `os.open`, `os.close`, and `os.Handle` to
`core:os`, in the "Library types assumed by this specification" table and in the
`defer` example. Files belong in `core:fs`: `core:os` is process state, and a
package that owns the argument vector should not also own file handles.

The first `core:fs` commit amended both `design.md` sites, and they now name
`fs.File`, `fs.open`, and `File.close`. No `os.open` alias is kept; one spelling
for opening a file is the point of moving it.

## Shared I/O contract

`core:io` owns the error type used by `io`, `fs`, `term`, and fallible process
I/O. It is not a universal application error type.

The exact declarations should be proven in Loke source before being frozen, but
the intended shape is:

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
	Copy,
	Read_Line,
	Read_To_End,
	Metadata,
	Exists,
	Remove,
	Rename,
	Create_Directory,
	Read_Directory,
	Path_Conversion,
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

The first release uses synchronous, blocking byte streams. Both are written with
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

Buffered wrappers are not in the first release. `read_to_end` plus a caller's own
`[]mut u8` covers what Stage 2 needs, and buffering policy is worth designing
against a measured cost rather than in advance. When it arrives it is an explicit
wrapper value, never hidden global state.

### Formatting bridge

The existing `fmt.Writer` callback cannot return an error. It remains suitable
for process diagnostics and in-memory sinks, but a formatted file write must
not silently lose a disk error.

The first implementation should attempt an `io.write_formatted` adapter. The
adapter presents a `fmt.Writer`, writes into an `io.Writer`, latches the first
`io.Error`, makes later callbacks no-ops, and returns the latched error after
formatting. This preserves the existing formatting ABI:

It is not a safe construction and must not be described as one. `fmt.Writer.state`
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

Both shipped as written: the latch conversion is accepted, and the adapter never
leaves the body that builds it.

`fmt` additionally gains:

```odin
to_string(allocator: Allocator, args: ..any_view) -> string
```

The allocator is a required leading parameter here, not a defaulted trailing one:
a variadic absorbs the trailing arguments, so nothing after it can be supplied
and nothing defaulted before it can be omitted. This is useful independently and
gives a simple fallback for any sink: format in memory, then call
`io.write_string`.

The planned `append_to(builder: inout strings.String_Builder, ...)` is **not**
shipped, and the reason is measured rather than aesthetic. It would make
`core:fmt` import `core:strings`, an imported package is emitted whole, and
hello world's IR went from 397 to 4923 lines with that one import in place. The
call it saves is one line — `builder.append(fmt.to_string(allocator, ...))` —
which is not worth a twelvefold cost to every program that prints. `to_string`
itself keeps its selected allocator by receiving the same compiler-contributed
`allocate_string` primitive `core:strings` gets.

## `core:strings`

The built-in string already owns UTF-8 validation, byte/rune counts, immutable
bytes, comparisons, slicing, concatenation, rune iteration, and conversions.
`core:strings` should add algorithms and efficient construction, not duplicate
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

Empty-needle behavior must be documented and tested consistently: it matches at
byte offset zero, `last_index` answers `.some(text.len())`, and `count` returns
`text.len() + 1`.

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

Whitespace in `trim_space` and `fields` is Unicode White_Space, not only ASCII.
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

Case conversion is ASCII-only in this release. Full Unicode case mapping needs
tables that belong in a `core:unicode`, and guessing a subset of them would be
worse than passing the rest through unchanged; the signature already returns
owned storage, so the tables can arrive without changing a caller.

The policy-following forms above panic only on allocation-policy failure.
Negative counts and other programmer mistakes panic.

No `try_` twin ships for these in the first release. `String_Builder` already
offers the fallible path — including `try_reserve`, `try_append`, and
`try_finish` — and a caller that must survive allocation failure can build the
same result there. A `try_join` or `try_replace` is added when a caller actually
needs one, not as a matching set.

Unicode case conversion may change the byte and rune counts. Locale-sensitive
conversion is deferred and must not be guessed from process-global locale.

### `String_Builder`

`String_Builder` maintains valid UTF-8 at every public boundary. It is an
ordinary owning value over `[dynamic]u8`.

**Its zero value is a usable, empty, allocator-unbound builder.** `design.md`'s
string section already shows `builder: String_Builder = {};` followed by
`append`, so `= {}` must keep compiling; it inherits the allocator-unbound
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
		-> Allocator_Error;
	append_text  :: proc(self: inout String_Builder, text: string_view);
	append_rune  :: proc(self: inout String_Builder, value: rune);
	append       :: proc{append_text, append_rune};
	append_byte_ascii :: proc(self: inout String_Builder, value: u8);
	try_append_text :: proc(self: inout String_Builder, text: string_view)
		-> Allocator_Error;
	try_append_rune :: proc(self: inout String_Builder, value: rune)
		-> Allocator_Error;
	try_append   :: proc{try_append_text, try_append_rune};
	try_append_byte_ascii :: proc(self: inout String_Builder, value: u8)
		-> Allocator_Error;
	clear        :: proc(self: inout String_Builder);
	finish       :: proc(self: inout String_Builder) -> string;
	try_finish   :: proc(self: inout String_Builder)
		-> Result(string, Allocator_Error);
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

The compiler contributes one package-private `core:strings` primitive that
copies a known-valid `string_view` into string storage with a supplied allocator
and answers `Result(string, Allocator_Error)`. This is the minimal unexpressible
bridge to the built-in string allocation ABI; UTF-8 algorithms and allocation
policy remain ordinary Loke. Stage 0 must prove this primitive before the
builder API is frozen. Arbitrary byte append is deliberately absent because it
could break the UTF-8 invariant; callers validate bytes first or use a byte
buffer.

The type's public name in source should be `strings.String_Builder`. A shorter
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
	view :: proc(self) -> cstring_view;
	len  :: proc(self) -> int;          // excludes the terminator
}
```

`cstrings.Error` distinguishes `Contains_Zero` from `Out_Of_Memory`, and reaches
a caller as the failure payload of `Result`. The constructor rejects an interior
zero; a Loke `string` may legitimately contain U+0000 even though a retained C
string cannot. The package must never create a view whose apparent length is
shorter than the owned data.

`from_bytes` and a `bytes()` accessor are not in the first release. `design.md`
only owes `view()`, and the one motivating case — handing a foreign API a string
it retains — starts from a `string_view`. Add the byte-oriented pair when a
caller has bytes that are not text.

## `core:strconv`

Parsing does not belong in `strings`: it interprets text as another type.

First-release procedures:

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
only one way to fail, so it answers `Option(bool)` instead. Parsing consumes the
whole string after permitted surrounding ASCII whitespace. A separate scanner
API can later parse a prefix.

`base == 0` recognizes the language prefixes `0b`, `0o`, and `0x`; otherwise
the accepted range is 2 through 36. Underscore rules should match Loke literals
unless there is a documented reason not to.

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

open(path: string_view, options: Open_Options) -> Result(File, io.Error)
open_read(path: string_view) -> Result(File, io.Error)
create(path: string_view) -> Result(File, io.Error)
append(path: string_view) -> Result(File, io.Error)

read(file: inout File, destination: []mut u8) -> Result(int, io.Error)
write(file: inout File, source: []u8) -> Result(int, io.Error)
seek(file: inout File, offset: i64, origin: Seek_Origin) -> Result(u64, io.Error)
flush(file: inout File) -> Result(Unit, io.Error)
close(file: inout File) -> Result(Unit, io.Error)
```

Because structural interface satisfaction is determined by the static type,
`File` satisfies both `io.Reader` and `io.Writer`: it has both slots regardless of
the options used for a particular instance. The open mode is checked at runtime,
and using an unsupported direction returns `Unsupported`. Append mode guarantees
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

The next slice after basic file I/O is:

These are members of `File`, reached as `file.read(...)`: a `slot` requirement
is satisfied by a *member*, so `io.Reader` and `io.Writer` can only be answered
by methods. `file.is_open()` was added alongside them, because a caller that has
closed explicitly has no other way to ask.

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
reader borrows instead. (When this was written a by-value `foreach` over a
managed element was rejected outright; that limit is gone — the loop now owns
and disposes of its copy — but the reason for streaming is the copy itself, not
the old rejection.) The reader yields one entry at a time, borrows
its name into a caller-visible buffer valid until the next `next`, and closes its
platform search handle in `drop`. A caller wanting an array collects one itself.
Because `next` reports both the end and a failure, the reader is not a `foreach`
iterable; the loop that walks it is design.md "Streaming a fallible source", and
`tests/run/lib_fs` walks a directory with it.

`exists` answers `.ok(false)` only for a definite not-found result; permission
and I/O failures remain errors. `Metadata` initially exposes kind, byte size, and
modified time. Symlink behavior must be explicit when symlink support is added;
the first Windows implementation must not accidentally claim portable symlink
semantics.

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

Windows drive-relative paths, UNC paths, and extended-length paths need dedicated
tests before `clean` and `is_absolute` are considered stable.

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

`prompt` writes the label to standard output, flushes it, and then reads a line.
It returns output failures as well as input failures. It does not print a
newline automatically.

Formatted console diagnostics remain available through `core:fmt`. Raw and
fallible stream output uses `term.stdout()` with `io.write_all` or
`io.write_formatted`.

### Raw mode and key events

```odin
Raw_Mode :: struct { /* move-only, private state */ }

begin_raw(input := stdin(), options: Raw_Options = {})
	-> Result(Raw_Mode, io.Error)
read_key(mode: inout Raw_Mode) -> Result(Key_Event, io.Error)
close(mode: inout Raw_Mode) -> Result(Unit, io.Error)
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
make; the plan's rule against hidden process behavior still holds, because
nothing is registered until a caller asks for raw mode.

`begin_raw` on redirected input answers `.err(Not_A_Terminal)`.

Only one `Raw_Mode` may be live in a process. The process-level control handler
has one authoritative saved console mode; allowing another scope to overwrite
it would make out-of-order cleanup or a control event restore the wrong mode.
A second `begin_raw` therefore answers `.err(Already_Exists)` and leaves the
terminal unchanged.

`Key_Event` contains a Unicode rune for text input, a `Key` enum for special
keys, and explicit modifier flags. The first `Key` set should cover arrows,
Home, End, Page Up/Down, Insert, Delete, Backspace, Enter, Escape, Tab, and F1
through F12. Repeats are reported as individual events unless the platform
provides a count that can be represented without changing ordering.

Ctrl+C behavior must be an option of raw mode. The default preserves the normal
process interrupt behavior; an explicit option requests it as a key event.
Mouse events, window resizing, colors, cursor movement, and full-screen terminal
UI belong to later terminal packages.

## `core:os` additions

`core:os` already owns `os.args` and `os.exit`. The next portable process-level
operations should be:

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
present empty value. Its owning result uses the supplied allocator. Environment
names and values must become valid UTF-8 or the operation returns invalid data.
A process-spawning API is deferred until handle inheritance, quoting, environment
replacement, and pipe ownership are designed together.

## What is deliberately not in the first release

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

## Implementation roadmap

### Stage 0: freeze conventions with executable API sketches — done

1. Add compile-only examples for every proposed signature.
2. Prove that `io.Error` works with `or_return`, unions, formatting, and named
   multi-results.
3. Declare `io.Reader` and `io.Writer` with `slot` requirements and prove that
   `dyn io.Writer` forms. This is a declaration-only step and does not need an
   implementation; it must precede item 4, which depends on the `dyn` type.
4. Prove the `fmt.Writer` to `io.Writer` error-latching adapter, including that
   the `core:unsafe` conversion of the latch address is accepted and that the
   adapter cannot escape its constructing call.
5. Prove the package-private `core:strings` string-allocation primitive, including
   allocator failure and the unchanged-on-failure guarantee required by
   `String_Builder.try_finish`.
6. Decide the exact default-argument and public-field spellings from compiling
   Loke, not only from this document.
7. Mark packages experimental until these proofs and tests pass.

No platform code should be written before the error and resource shapes survive
these examples.

### Stage 1: strings and conversion — done

1. Implement `String_Builder` and its allocation-failure guarantees.
2. Implement non-allocating search, cut, split, fields, lines, and trim.
3. Implement join, repeat, and replace.
4. Implement integer and Boolean parsing, then floating-point parsing.
5. Implement `C_String` for retained foreign strings.

This stage is platform-independent and exercises generics, iterators,
allocators, lifecycle hooks, UTF-8 invariants, and formatting integration.

### Stage 2: byte I/O and files — done

1. Implement `io.Error`, `Reader`, `Writer`, `read_exact`, `write_all`, and
   in-memory test readers/writers.
2. Add Windows file open/read/write/seek/flush/close using wide paths.
3. Wrap the native handle in move-only `fs.File` and test normal cleanup, plus
   panic cleanup in an `unwind` build.
4. Add whole-file byte and text helpers with allocation limits.
5. Add metadata and basic directory operations.
6. Add path operations only with the Windows edge-case matrix in place.

### Stage 3: standard input and keyboard input — done

1. Implement unbuffered standard streams and redirected-stream tests.
2. Implement buffered `read_line` and `term.prompt`.
3. Implement scoped raw mode and restoration tests.
4. Decode Unicode text, modifiers, and the initial special-key set.
5. Test interruption, end-of-input, broken pipes, and non-terminal input.

### Stage 4: portability and the next utility layer — not started

Stage 4 is gated on compiler work the library cannot do. Non-Windows targets are
deferred after M7, so there is no Linux or macOS backend to build against, and
`LOKE_OS` is a fixed `.Windows`. Items 1 and 2 start when that lands; items 3 and
4 do not depend on it and can proceed earlier.

1. Add Linux and macOS `when (LOKE_OS == ...)` branches without changing the
   public contracts.
2. Run the same filesystem and terminal conformance suite on every target.
3. Add `bytes`, sorting, time, random, testing, and logging based on concrete
   needs found while porting real programs.
4. Add higher-level encoding packages independently of core I/O.

## Test requirements

Each package needs unit tests, integration tests, and runnable examples. The
important initial matrix is:

- empty input, empty files, and empty strings;
- binary data containing zero bytes;
- valid multi-byte UTF-8 and deliberately invalid UTF-8;
- Unicode file names and long Windows paths;
- missing, inaccessible, read-only, and already-existing paths;
- partial reads/writes, end of input, interruption, and broken pipes;
- bounded reads one byte below, exactly at, and one byte above the limit, with
  `Limit_Exceeded` destroying partial owning results;
- allocator failure at every growing operation, with the destination unchanged;
- explicit close followed by drop, double close, and panic unwinding;
- redirected standard handles versus a real console;
- raw terminal mode restoration on scope exit, on explicit `close`, and — in an
  `unwind` build only — on panic; plus one test asserting that the console
  control handler restores the mode when cleanup does not run;
- byte offsets around one-, two-, three-, and four-byte runes; and
- identical behavior at every compiler optimization level.

Fake short readers and writers should drive protocol tests deterministically.
Filesystem tests must create an isolated temporary directory and never depend on
the repository working directory or a developer's environment. Terminal decoder
logic should be tested from synthetic native event records; only a thin final
layer requires an interactive/manual test.

## First-release acceptance program

The first standard-library release is useful when a program equivalent to this
can compile and run without compiler-specific I/O built-ins:

```odin
package main;

import "core:fmt";
import "core:fs";
import "core:io";
import "core:term";

run :: proc() -> Result(Unit, io.Error) {
	name := term.prompt("Name: ") or_return;

	// The file does not exist on the first run, which is not a failure here.
	old := "";
	if (fs.exists("greetings.txt") or_return) {
		old = fs.read_text("greetings.txt") or_return;
	}

	line := "Hello, " + name + "!\n";
	return fs.write_text("greetings.txt", old + line);
}

main :: proc() {
	switch (outcome in run()) {
	case .ok:
	case .err: fmt.eprintln("error:", outcome);
	}
}
```

The final examples should also show bounded reads for untrusted input, streaming
large files without whole-file allocation, explicit close error handling, and
raw key input with guaranteed terminal restoration.

## Decisions validated during Stage 0

The three narrower questions this plan left open, with the answers the
implementation produced:

1. **The `fmt.Writer` adapter works, and no ABI change is needed.** A `^Latch`
   converts to the `rawptr` state field implicitly, `(^Latch)(state)` recovers
   it inside the callback, and both `write_formatted` procedures construct, use,
   and discard the adapter inside their own bodies. `fmt.Writer` keeps its
   layout.
2. **Unicode `White_Space` lives in `core:strings`**, as `strings.is_space`. It
   is twenty-five code points tested by range, not a table, and a `core:unicode`
   that existed only to hold it would be a package with one predicate in it.
   Case *mapping* is the part that needs real tables, and that is the deferral
   marked in `to_upper`/`to_lower`.
3. **No automatic long-path prefixing.** `path.clean` returns an extended-length
   path unchanged, because such a path exists precisely to bypass normalization
   and Windows passes it to the filesystem verbatim. Drive-relative (`C:x`),
   rooted-but-drive-relative, UNC, and extended-length paths each have a case in
   `tests/run/lib_path.loke`.

## Implementation record

Everything above describes the shipped contract. This section lists what the
implementation had to change, and why, so the difference is not left implicit.

### The compiler grew one primitive, and lost five bugs

`allocate_string(text: string_view, allocator: Allocator) -> Result(string,
Allocator_Error)` is contributed package-privately to `core:strings` and to
`core:fmt`. It is the plan's "minimal unexpressible bridge": every built-in text
operation allocates from the default provider, so without it no library
procedure could honour an allocator argument and still produce a `string`.

Four compiler defects were found by writing this library, and fixed with it:

- a slot returning an aggregate result crashed the backend when called through
  `dyn`, because that lowering path had no arm for a slot call. `dyn io.Writer`
  needs one. (The stream slots returned two values when this was found; they
  answer `Result` now, and the same path carries it.);
- a generic procedure could not be called with an omitted defaulted argument,
  with a named argument, or with a variadic pack, because inference required
  exactly one written argument per written parameter. The generic helpers here —
  `read_to_end(reader, limit = 5)`, `write_formatted(writer, ..args)` — need all
  three;
- an untyped constant did not rank against an `any_view` parameter, which a
  generic `..any_view` variadic made reachable;
- `nil` was not accepted as a C pointer constant, though design.md lists
  C pointers among the nil-able types. A `[^]u16` out-parameter is how a
  Windows wide API is asked for a size.

A fifth was found by *renaming* one of those contributions: a constant's folded
value was written through a `^Symbol` taken before the compile-time evaluator
ran, and the evaluator can grow the symbol array. Whether it corrupted anything
depended on how many symbols the program had, so adding one name to `core:fmt`
was enough to make an unrelated corpus program fail.

### Language limits that shaped the API

- **Two members of one `impl` block cannot share a name.** `String_Builder`'s
  `append` and `try_append` are procedure groups over distinctly named members.
- **A parameter default must name its type.** `allocator := mem.default_allocator()`
  is rejected in a signature; `allocator: Allocator = mem.default_allocator()`
  is the spelling. A slice default is `= nil`, because `{}` at a slice type is a
  slice literal and must be written with its type.
- **Slicing a view at an offset that splits a code point is a runtime failure.**
  Search therefore compares bytes and slices only at an offset that has already
  matched — which is a boundary, because UTF-8 is self-synchronising.
- **An `impl` member must be `@(public)` for a generic in another package to
  call it.** A type in `main` implementing `io.Reader` must mark its `read`
  public, or the `where` bound passes and the instantiated body then fails to
  find the member. That asymmetry is a compiler wart worth its own fix; the
  library documents the requirement rather than working around it.
- **A by-value `foreach` over a managed element copies it per step.** The loop
  owns that copy and disposes of it at the end of the step, so the rejection this
  plan was written against is gone; what remains is the cost. It is still why
  `Directory_Reader` streams borrowed names instead of returning an owning array,
  and why `tests/run/lib_fs.loke` indexes its `[dynamic]string` rather than
  retaining each name it only reads. Borrowing iteration has since removed the
  cost from the ordinary loop: traversing a place lends each element, including a
  move-only one, and copying it out is written.

### Deviations from the plan

- `fmt.append_to` is **not** shipped; see the formatting-bridge section for the
  measurement that decided it.
- `core:encoding/utf16` was pulled forward from "later packages" into stage 2.
  `fs`, `term`, and `os` all need UTF-16 on the first target, and three copies of
  a surrogate decoder are worse than one package arriving a milestone early.
- `io`'s query procedures are `is`, `code_of`, `operation_of` and
  `native_code_of`: `code` cannot be both a procedure and the `Code` enum.
- `fs` read/write/seek/flush/close are `File` members rather than free
  procedures, because a `slot` requirement is satisfied by a member.
- `Directory_Reader.next` answers `Result(Option(Directory_Entry), io.Error)`:
  a walk has to tell "no more entries" from "the enumeration broke".
- Case conversion is ASCII-only, marked in the source with its upgrade path.
- `os.set_environment` with an empty value removes the variable on Windows. That
  is the platform's behavior, and it is documented at the call rather than
  papered over.
- `term.read_line` reads a real console through `ReadConsoleW` and a redirected
  handle through `io.read_line`, so typed non-ASCII text arrives intact. The raw
  `Input.read` stream stays bytes-through-`ReadFile` either way.

### What is still open

Stage 4 remains gated on non-Windows targets: `LOKE_OS` is a fixed `.Windows`,
so the `else` arm of every `when` in `core:fs`, `core:path`, `core:term` and
`core:os` exists and is never selected.

M8 closed four of the entries this list used to defer, because design.md's own
catalogue assumed them rather than merely allowing them: ordering-based sorting
is a contributed `sort`/`reverse_sort` member on `[dynamic]T` and `[]mut T`, and
`core:slice` adds the typed-comparator `sort_by`; `core:log` sits on a
build-selected logger;
`core:sync` supplies `Atomic(T)`, `fence`, and `Once`; and `core:simd` supplies
what the `Simd(T, N)` operators cannot spell. M8 also added `core:container`
(`Small_Array`, `Bit_Set`, `Enum_Array`), `core:math` (`Complex`,
`Quaternion`), and `core:endian`.

`core:math` then grew its scalar half: the constants, the bit-level
classification and sign procedures, the CRT-backed elementary functions over one
private foreign block into versioned seed-runtime wrappers, scalar
`min`/`max`/`clamp`, and `to`, the checked integer conversion that answers
`Option(To)` where a written `To(value)` would wrap (design.md "Type
conversion"). Each float-specific name has exactly two concrete
spellings — the unsuffixed `f64` one and an `_f32` twin — rather than a
procedure group, because design.md's own overload rules leave `f32` vs `f64`
ambiguous for an untyped literal and `math.sqrt(2.0)` would not compile.
Hyperbolics, `cbrt`/`fma`/`ldexp`/`frexp`/`modf`, `erf`, `gamma`, lane-wise math
over `Simd(T, N)`, and integer bit helpers (which want a `core:bits`) are named
omissions, additive over what now exists.

`core:bytes`, `time`, `random`, and `testing` still wait for a concrete need, as
planned. A buffered reader, `fs.replace_atomic`, `fs.absolute`, symlink support,
and a `try_` twin for the allocating string transformations are all deliberately
absent until a caller asks. Within `core:simd`, shuffles, lane-wise
`min`/`max`/`abs`, the bitwise reductions, and a mask popcount are named in
design.md as version-1 omissions: each is additive over the type that now
exists.

# Binary data and checksums: design proposal (2026-11-04)

A design for reading and writing binary formats and for detecting accidental
corruption. It is non-normative and nothing in it is implemented. When it is,
the contracts move to [standard-library.md](standard-library.md), the reasons to
[Standard-library API choices](comments.md#standard-library-api-choices), and
this file is deleted.

The design came from a save format built on region files, but it is judged as a
general facility: the same API has to serve file headers, network frames, page
stores, and media containers. The original signatures and the
[worked example](#worked-example) were compiled and run against the current
`lokec` with a scratch copy of `core` holding these additions
(see [What was checked](#what-was-checked), including the review revisions
that still need verification).

## Summary

No single new package covers this well, because three of the missing pieces are
useful well beyond binary formats. Each goes where it is general:

| Package | Addition | Who else wants it |
| --- | --- | --- |
| [`core:math`](#coremath-float-bits) | `to_bits`, `from_bits` | Anything that hashes, compares, or tests floats exactly, without `core:unsafe` |
| [`core:endian`](#coreendian-load-and-store) | `load`, `store`, `is_fixed_width` | Any code with a validated offset, such as back-patching |
| [`core:io`](#coreio-a-bounded-sink) | `Slice_Writer`, `Buffer_Writer.bytes_mut` | Any `io.Writer` client writing into caller-owned memory |
| [`core:encoding/binary`](#coreencodingbinary) | `Reader`, `Writer(W)`, `Error` | New: typed fields, bounds, and offsets |
| [`core:checksum`](#corechecksum) | `Crc(T, P)` and a parameter catalogue | New: every CRC in the catalogue, not only CRC-32 |

Two composition properties do most of the work. A `binary.Writer(W)` writes to
any `io.Writer`, so memory, a file, and a checksum are all the same call. A
`binary.Reader` and a `checksum.Crc` each satisfy an `io` protocol, so
`io.copy`, `io.read_line`, and `io.write_all` work on them without new adapters.

Nothing new allocates.

## The gap

- [`core:endian`](standard-library.md#coreendian) wraps stored integers. It has
  no operation on a byte slice, and no floats.
- [`core:io`](standard-library.md#shared-io-contract) has `read_exact`,
  `write_all`, and [`Buffer_Writer`](standard-library.md#byte-buffer), but
  nothing that reads a typed field, bounds a record, or reports where a failure
  happened. `io.Error` deliberately has no offset.
- A float's encoding is reachable only through `unsafe.transmute`.
- There is no checksum package.

## `core:math`: float bits

```loke
to_bits   :: proc{...};   // f16 -> u16, f32 -> u32, f64 -> u64
from_bits :: proc{...};   // u16 -> f16, u32 -> f32, u64 -> f64
```

`to_bits(from_bits(b)) == b` for every pattern, a signalling NaN's included. Each
width has its own overload and none goes through another width, because `f64(x)`
of an `f32` signalling NaN is a conversion and may quiet it.

**Specification change.** This contract rests on something
[Floating-point operators](design.md#floating-point-operators) does not yet say.
It leaves the NaN of an *operation* unspecified, and must add that copying,
moving, passing, and returning a float are not operations and keep its encoding.
Today's x86-64 code generation behaves that way (checked below); the sentence
makes it a promise.

## `core:endian`: load and store

```loke
is_fixed_width :: proc($T: type) -> bool;
load  :: proc($T: type, bytes: []u8, order: Order) -> T where is_fixed_width(T);
store :: proc(bytes: []mut u8, value: $T, order: Order) where is_fixed_width(T);
```

`is_fixed_width` accepts `u8` through `u128`, `i8` through `i128`, `f16`, `f32`,
and `f64`. It rejects `int`, `uint`, `uintptr`, `bool`, `rune`, and enums: a
format has to name a width and a representation, and these leave one of them to
the target or the compiler.

`load` and `store` use the first `size_of(T)` bytes, and a shorter slice panics,
because the caller has already validated the offset. They are for back-patching
and random access to validated data. Untrusted input goes through
[`binary.Reader`](#reader).

`Little_Endian(T)` and `Big_Endian(T)` stay integral. Their stored form is held
in a `T`, and a byte-swapped float is not a float; a struct that needs one stores
`Big_Endian(u32)` and calls `math.from_bits`.

## `core:io`: a bounded sink

```loke
Slice_Writer :: struct { /* private */ }
Slice_Writer.init(target: []mut u8) -> Slice_Writer
Slice_Writer.write(self: inout, source: []u8) -> Result(int, Error)
Slice_Writer.bytes(self: ^) -> []u8
Slice_Writer.len(self) -> int
Slice_Writer.space(self) -> int

Buffer_Writer.bytes_mut(self: inout) -> []mut u8
```

`Slice_Writer` is `Buffer_Writer`'s fixed-capacity peer: a write that does not
fit is `Out_Of_Space` with operation `Write` and writes nothing. An empty write
succeeds even when full. `Buffer_Writer.bytes_mut` lets a finished record be
patched in place; like `bytes`, it borrows, so no write can happen while the view
is in use.

## `core:encoding/binary`

### Reader

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

The contract:

- **A failed operation changes nothing.** Every operation validates the whole
  field before moving, so after a failure `error.offset == r.offset()`, and the
  caller can retry, report, or try another reading. `get_length` and `get_count`
  stay on the count field when the count is refused.
- **Offsets are in the source's coordinates.** `offset()` is `base` plus the
  position. Pass a record's file offset as `base` and every error names a file
  offset, from subrecords too. A `base` that would overflow `u64` at the end of
  `bytes` panics, as a programmer error.
- **Lengths passed to `take`, `skip`, and `sub` may be any integer type**,
  because they usually come straight from the input. A negative `length` is
  `Invalid_Length`, and a positive one too big for `int` is `Unexpected_End`.
  Neither traps in a conversion or wraps in an
  addition: the bound is compared against what remains, and nothing is added
  first.
- **Encoded lengths and counts are fixed-width integers.** `get_length` and
  `get_count` accept only `u8` through `u128` and `i8` through `i128`. Combining
  `endian.is_fixed_width` with `Integral` from `base:interfaces` rejects floats,
  native-width integers, `bool`, `rune`, and enums at compile time. A negative
  value read is `Invalid_Length`; a non-negative value above `limit` is
  `Limit_Exceeded`, checked before the remaining-byte bound in `get_count`.
- **`sub` bounds a subrecord.** The child sees exactly `length` bytes and cannot
  read past them, whatever the parent still holds. The parent moves past the
  subrecord at once, so a malformed child cannot desynchronize it, and the child
  inherits the order and keeps absolute offsets. A child's `seek` stays inside
  the child.
- **Validate before allocating.** `get_length` reads a length and refuses one
  above `limit`, for a body not yet in memory. `get_count` also refuses a count
  whose items cannot fit in what remains, given each item's minimum encoded size,
  so `count` is safe to pass to `make`. It divides rather than multiplies, so it
  cannot overflow. `limit` is required: the bytes remaining bound the wire size,
  and only the caller knows what an element costs in memory. A negative `limit`
  or an `item_size` below one panics.
- **Bytes outlive the cursor.** `take` and `sub` borrow the source slice, not the
  reader, so the reader stays usable while they are live and they may outlive it.
  The compiler rejects them outliving the *source*.
- **A copy is a checkpoint.** A `Reader` is a small value. `probe := r` peeks
  without a `peek` operation, and `r = saved` backtracks.
- **`seek` is absolute**, in the same coordinates as `offset()`. A format with
  back-pointers can loop, so a parser following them must count its visits.
- **`finish`** is `Trailing_Data` unless everything was consumed. A format that
  allows an unread tail for forward compatibility does not call it.
- **`read`** is the [`io.Reader`](standard-library.md#shared-io-contract) slot,
  with that protocol's contract and error type.

### Error

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

For non-negative lengths, `length` is the exact value when it fits `u64`, and
`u64` maximum otherwise. That maximum therefore reports a lower bound, not
necessarily an exact value. Validation uses the original integer before this
diagnostic conversion; reporting `u128(1) << 64` must not wrap to zero or panic.
Negative lengths keep their low 64 two's-complement bits, as specified above,
including `i128` values. Neither conversion changes the reader's position.

Like [`json.Parse_Error`](standard-library.md#parsing) it owns scalars and has
public fields, and like `io.Error` it has a `format` member. It is a separate type
from `io.Error` because it describes data rather than a stream, and it is small
because a `Result` of it is returned for every field. A loader that also does I/O names both in a union of
its own, using [`or_return` with a variant](design.md#changing-error-domains), as
the example does.

A caller's own check on a field it just read has a field offset to report:
capture `r.offset()` before the `get`.

### Writer

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

The contract:

- **`W` is any `io.Writer`**: `io.Buffer_Writer`, `io.Slice_Writer`, `fs.File`,
  a `checksum.Crc`, another `binary.Writer`, or `dyn mut io.Writer` where the sink
  is chosen at run time. Dispatch is monomorphic unless a `dyn` is asked for.
- **The width is visible at the call.** `put` takes its type from the value, and
  `is_fixed_width` rejects an `int`, so `w.put(count)` and `w.put(7)` do not
  compile. `w.put(u32(count))` panics if the count does not fit, as `u32(count)`
  always does. Use `put_length` when the value comes from data: a length that is
  negative or does not fit `T` is `Limit_Exceeded` with operation `Write`, and
  nothing is written. Its `T` has the same fixed-width integer restriction as
  `get_length` and `get_count`; floating-point length fields do not compile.
- **`offset()` counts what the sink accepted**, plus `base`. A failed `put` into
  a `Buffer_Writer` or `Slice_Writer`, which take all of a write or none of it,
  leaves it unchanged. A stream may accept part of a field before failing, and
  then `offset()` is inside the field, which is exactly where the stream stopped.
- **Offset exhaustion is checked before writing.** Every output operation
  (`put`, `put_bytes`, `put_length`, `fill`, and `write`) compares its entire
  requested byte count with `u64` maximum minus `offset()`. A request above
  that space returns `Limit_Exceeded` with operation `Write`, without calling
  the sink or changing the offset. This also applies to `write`, even if its
  sink would accept only a prefix, and to `fill` before its first chunk.
  Reaching exactly `u64` maximum is allowed. Empty `put_bytes`, `fill(0)`, and
  empty `write` succeed without calling the sink, including at that offset.
- **`fill` validates its length before writing.** A negative length returns
  `Limit_Exceeded` with operation `Write` and changes nothing. After validation,
  filling may use several writes; a later sink failure leaves accepted chunks
  counted in `offset()`, even with a `Buffer_Writer` or `Slice_Writer`.
- **Failures are `io.Error`.** Sink errors propagate unchanged; invalid lengths
  and offset exhaustion use `Limit_Exceeded` with operation `Write`. A save
  routine composes `w.put`, `file.lock`, and `fs.replace_atomic` with a bare
  `or_return` and no error conversion.
- **Back-patching** is `endian.store` over `Buffer_Writer.bytes_mut` or the
  caller's slice, once the writer's last use has passed. The compiler enforces the
  order, since the writer holds the sink's mutable borrow.

### Worked example

A record of big-endian fields: a checked header, then a body with a count.

```loke
// magic    4 bytes  "LOKR"
// version  u16      1
// flags    u16
// length   u32      bytes of body
// crc      u32      CRC-32/ISO-HDLC of the 12 bytes before it, then the body
// body     scale: f32, count: u16, then count times (id: u32, weight: f64)

MAGIC       := "LOKR".bytes();
HEADER_SIZE :: 16;
ENTRY_SIZE  :: 12;
MAX_BODY    :: 1 << 24;
MAX_ENTRIES :: 1 << 20;

Entry  :: struct { id: u32, weight: f64 }
Record :: struct { flags: u16, scale: f32, entries: [dynamic]Entry }

Load_Error :: union {
	io:          io.Error,
	data:        binary.Error,
	bad_version: u16,
	bad_crc:     u64,
}

decode_record :: proc(bytes: []u8, base: u64 = 0) -> Result(Record, Load_Error) {
	r := binary.Reader.init(bytes, .Big, base);
	r.expect(MAGIC) or_return .data;

	version := r.get(u16) or_return .data;
	if (version != 1) { return .err(.bad_version(version)); }

	flags := r.get(u16) or_return .data;
	length := r.get_count(u32, 1, MAX_BODY) or_return .data;
	crc_at := r.offset();
	stored := r.get(u32) or_return .data;

	// Check the bytes before believing anything in them.
	body := r.sub(length) or_return .data;
	r.finish() or_return .data;
	crc: checksum.Crc32 = {};
	crc.update(bytes[0:HEADER_SIZE - 4]);
	crc.update(bytes[HEADER_SIZE:]);
	if (crc.sum() != stored) { return .err(.bad_crc(crc_at)); }

	scale := body.get(f32) or_return .data;
	count := body.get_count(u16, ENTRY_SIZE, MAX_ENTRIES) or_return .data;
	entries := make([dynamic]Entry, 0, count);
	foreach (_ in 0 ..< count) {
		id := body.get(u32) or_return .data;
		weight := body.get(f64) or_return .data;
		entries.append(Entry{id, weight});
	}
	body.finish() or_return .data;
	return Record{flags, scale, move(entries)};
}

encode_record :: proc(record: Record, out: inout io.Buffer_Writer) -> Status(io.Error) {
	start := out.len();
	w := binary.writer(&mut out, .Big);
	w.put_bytes(MAGIC) or_return;
	w.put(u16(1)) or_return;
	w.put(record.flags) or_return;
	w.put(u32(0)) or_return;                 // length, patched below
	w.put(u32(0)) or_return;                 // crc, patched below
	w.put(record.scale) or_return;
	w.put_length(u16, record.entries.len()) or_return;
	foreach (entry in record.entries) {
		w.put(entry.id) or_return;
		w.put(entry.weight) or_return;
	}

	whole := &mut out.bytes_mut()[start:];
	body_length := whole.len() - HEADER_SIZE;
	endian.store(&mut whole[8:], u32(body_length), .Big);
	crc: checksum.Crc32 = {};
	crc.update(whole[0:HEADER_SIZE - 4]);
	crc.update(whole[HEADER_SIZE:]);
	endian.store(&mut whole[HEADER_SIZE - 4:], crc.sum(), .Big);
	return .ok;
}

// A record at a file offset: the header first, then a body of a validated size.
load_at :: proc(file: inout fs.File, offset: u64) -> Result(Record, Load_Error) {
	header: [HEADER_SIZE]u8 = {};
	file.read_exact_at(&mut header[:], offset) or_return .io;
	probe := binary.Reader.init(header[:], .Big, offset);
	probe.skip(8) or_return .data;
	length := probe.get_length(u32, MAX_BODY) or_return .data;

	bytes := make([dynamic]u8, HEADER_SIZE + length);
	file.read_exact_at(&mut bytes[:], offset) or_return .io;
	return decode_record(bytes[:], offset);
}
```

`load_at` is the answer to streams for framed formats: a fixed header in a stack
array, a length refused before anything is allocated, and then the exact body.

## `core:checksum`

```loke
Crc_Params :: struct($T: type) {
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

The contract:

- **`Crc_Params` is the Rocksoft model**, the fields of the
  [CRC RevEng catalogue](https://reveng.sourceforge.io/crc-catalogue/all.htm), so
  a format's CRC is pinned by copying its row. A polynomial is in normal form with
  the top bit implied, whatever the reflection: CRC-32 is `0x04C11DB7`, never its
  reversed form `0xEDB88320`. `T` is an unsigned integer as wide as `width` or
  wider.
- **A parameter set is checked at compile time.** `valid_params` rejects a width
  that does not fit, an even polynomial, and a value with bits above `width`. An
  importer's literal must name its fields (`L0709`), so a parameter set is always
  self-describing.
- **The zero value is the checksum of no bytes**, so `c: checksum.Crc32 = {}` is
  the only way to start and a forgotten initialization cannot exist. The state
  holds the register XORed with its start value, which costs one XOR at each end
  of an `update`. `c = {}` resets.
- **`update` in any pieces gives the same sum**, an empty piece included. `sum`
  does not disturb the state, so a running checksum can be read and continued.
- **`write` is the [`io.Writer`](standard-library.md#shared-io-contract) slot** and
  never fails, so `io.copy(inout crc, inout file)` checksums a stream with no
  whole-file buffer.
- **Tables are constants**, computed at compile time per parameter set. A program
  pays only for the sets it names. Their layout, and any use of faster tables or
  instructions, is not part of the contract.

### Known answers

The check value is the CRC of the nine bytes `123456789`.

| Catalogue name | Width | Polynomial | Initial | In | Out | Final XOR | Check |
| --- | --- | --- | --- | --- | --- | --- | --- |
| CRC-32/ISO-HDLC | 32 | `0x04C11DB7` | `0xFFFFFFFF` | yes | yes | `0xFFFFFFFF` | `0xCBF43926` |
| CRC-32/ISCSI | 32 | `0x1EDC6F41` | `0xFFFFFFFF` | yes | yes | `0xFFFFFFFF` | `0xE3069283` |
| CRC-64/XZ | 64 | `0x42F0E1EBA9EA3693` | all ones | yes | yes | all ones | `0x995DC9BBDF1939FA` |

These test the model and stay out of the catalogue constants until a caller wants
one, since a format can spell any of them:

| Catalogue name | Width | Polynomial | Initial | In | Out | Final XOR | Check |
| --- | --- | --- | --- | --- | --- | --- | --- |
| CRC-32/BZIP2 | 32 | `0x04C11DB7` | `0xFFFFFFFF` | no | no | `0xFFFFFFFF` | `0xFC891918` |
| CRC-32/MPEG-2 | 32 | `0x04C11DB7` | `0xFFFFFFFF` | no | no | `0` | `0x0376E6E7` |
| CRC-16/IBM-3740 | 16 | `0x1021` | `0xFFFF` | no | no | `0` | `0x29B1` |
| CRC-16/ARC | 16 | `0x8005` | `0` | yes | yes | `0` | `0xBB3D` |
| CRC-8/SMBUS | 8 | `0x07` | `0` | no | no | `0` | `0xF4` |
| CRC-5/USB | 5 | `0x05` | `0x1F` | yes | yes | `0x1F` | `0x19` |
| CRC-12/UMTS | 12 | `0x80F` | `0` | no | yes | `0` | `0xDAF` |
| CRC-24/OPENPGP | 24 | `0x864CFB` | `0xB704CE` | no | no | `0` | `0x21CF02` |
| CRC-40/GSM | 40 | `0x0004820009` | `0` | no | no | all ones | `0xD4164FC646` |

Also: CRC-32/ISO-HDLC of no bytes is `0`, and of
`The quick brown fox jumps over the lazy dog` is `0x414FA339`.

### Using a CRC in a format

A format's specification should state the catalogue name and every parameter
above, the check value, the exact byte ranges covered, and the stored field's byte
order. The library guarantees the arithmetic; these choices are the format's:

- **A CRC finds accidental corruption.** It is not an identity, since collisions
  are easy to construct, and not security, since anyone can recompute it. A stable
  content hash is a separate decision for a separate package.
- **Cover something non-empty.** CRC-32 of no bytes is `0`, so a wiped record whose
  length and stored CRC both read as zero passes a check covering only the body.
  Cover the magic and the length too, as the example does.
- **Check before trusting.** Verify a body's CRC before interpreting its fields,
  and still bound-check them, because a CRC does not defend against a crafted file.

### Measured cost

One run each over 64 MiB on the development machine, as a first estimate of the
shape, not a benchmark. The implementation measures with `perf.ps1`.

| Operation | `-opt=none` | `-opt=speed` |
| --- | --- | --- |
| `Reader.get(u32)`, 16.7 million fields, either order | 1.3 s (50 MiB/s) | 14 ms (4.6 GiB/s) |
| CRC-32, one table | 271 ms (236 MiB/s) | 134 ms (480 MiB/s) |
| CRC-32, slice-by-8 | 184 ms (349 MiB/s) | 34 ms (1.9 GiB/s) |

The cursor's bounds check and run-time byte order cost almost nothing once
optimized, so the order can stay a run-time value. Slice-by-8 is worth its 8 KiB
table for a 32-bit CRC, and should be the implementation for a reflected `u32` or
`u64` register. Carry-less multiplication and the SSE4.2 CRC-32C instruction are
later optimizations behind the same API.

## Choices

**The byte order lives in the cursor, not in each call.** A format's order is one
fact about the format, and repeating `.Big` on every field invites the one line
that says `.Little`. A run-time value is required anyway: TIFF and ELF announce
their order in the file. A mixed format calls `set_order`, or gives a subrecord its
own, as an embedded TIFF does in a JPEG.

**`get` and `put`, with a type, rather than `get_u32_be`.** Thirteen types in two
orders in two directions would be 52 members, for no gain over a single checked
generic. The names `read` and `write` are the `io` protocol's slots and are taken,
with good reason: taking them is what makes the types streams.

**Writer errors are `io.Error`, without an offset.** The brief asked for errors
with offsets throughout. A read fails because of the data, and the offset is the
diagnosis. A write fails because of the sink or a length or offset limit, and
`w.offset()` answers the question whenever a caller has one. Wrapping would also
make every save routine convert errors at each file operation. This is the one
deliberate departure from the brief.

**A writer over `io.Writer`, not over a slice.** A slice-only writer cannot grow,
which is what a serializer of unknown size needs, and a second growing type would
double the surface. A sink parameter gets memory, files, and checksums from one
type, and a future buffered stream works with no change here.

**`core:encoding/binary`, not `core:bytes`.** This is an encoding, and sits beside
`encoding/json` and `encoding/utf16`. `core:bytes` stays available for what the
name suggests: searching and comparing byte slices, as `core:strings` does for text.

**`core:checksum`, not `core:hash`.** The language's `hash` member is a table hash
with no stability promise, and a name shared with it would suggest the wrong
guarantee. The package's name states what it is for.

**The whole Rocksoft model rather than CRC-32.** A general-purpose language reads
formats it did not define. The other widths and reflections are compile-time
branches, so a parameter set pays only for the cases it uses, and the twelve
catalogue entries above all pass through one implementation.

## Left out

Each stays out until a caller establishes its contract, and each fits on top
without changing this API:

- **Buffered streams.** The brief notes their absence but does not ask for them.
  A `Reader` needs contiguous bytes, and framed formats get them with `load_at`'s
  pattern. A buffered reader and writer need their own contract, above all for a
  `drop` that cannot report a failed flush, and belong to a separate design.
  `Writer(W)` will accept a buffered sink unchanged.
- **Bulk typed arrays**, `get_all(destination: []mut T)` and its inverse. The loop
  is correct and bounded today. These would be a measured optimization, with a
  host-order fast path.
- **Variable-length integers and bit fields.** LEB128 and bit readers are common
  but are separate encodings with their own failure modes.
- **A text field operation.** `take` and then the usual validation at the
  [byte-to-text boundary](standard-library.md#utf-8-text-bytes-for-everything-else).
- **A tee adapter.** `io.copy` covers a checksum of a stream, and `update` covers a
  record in memory.
- **`combine` for CRCs**, which matters for parallel checksums.
- **Automatic struct encoding.** It stays [deliberately
  absent](standard-library.md#what-is-deliberately-absent). Padding, field order,
  and native layout are what explicit fields exist to keep out of a format.

## Verification

In addition to [Standard-library verification](compiler-architecture.md#standard-library-verification):

- **Round trips:** every `is_fixed_width` type in both orders, against hand-written
  byte vectors, so that a reader and writer sharing a bug cannot agree with
  themselves. Signalling NaN patterns in all three float widths, and at each
  optimization level.
- **The no-advance rule:** for every operation and every failure, assert
  `error.offset == r.offset()` and that `remaining` is unchanged.
- **Hostile input:** a valid record truncated at every length and with every single
  bit flipped must be an error and never a panic. Lengths and counts just below, at,
  and above each bound, and `0`, `-1`, `i64` minimum, and `u64` maximum where the
  length type can represent them. A count that passes `limit` but not `remaining`.
  Exercise all ten encoded integer types in both orders. For `i128` and `u128`,
  test positive lengths at `2^64 - 1`, `2^64`, and each type's maximum through
  `take`, `skip`, `sub`, `get_length`, and `get_count`: errors never panic, their
  diagnostic lengths saturate, and the cursor does not advance. Test `i128`
  minimum and `-1` for the negative low-64-bit rule. A count above both `limit`
  and the remaining-byte bound must report `Limit_Exceeded`.
- **Allocation:** a hostile count fails with a `mem.Arena` too small to serve it,
  proving nothing was allocated first.
- **Short I/O:** a scripted sink that accepts one byte at a time, and one that fails
  mid-field, checking `offset()` exactly. `Out_Of_Space` at and past capacity.
  For every writer output operation, test requests just below, at, and above
  the available offset space using bases near `u64` maximum. Refused requests
  must make no sink calls and change neither bytes nor offset, even with a sink
  that would accept only a prefix. Empty operations succeed at `u64` maximum;
  one byte there fails. Check invalid `put_length` and negative `fill` before
  any sink call. A `fill` exceeding offset space must fail before its first
  chunk; a valid multi-chunk fill whose sink fails later must retain an exact
  offset for its accepted bytes, including with a bounded memory sink.
- **CRCs:** all twelve known answers, every split point of the check string, an empty
  update, `sum` between updates, and the slice-by-8 path against a bitwise reference
  at every length and misalignment near its block size. Compile-time tables are
  checked against a run-time bitwise computation.
- **Diagnostics,** in `tests/err`: `get(int)`, `get(bool)`, `put(7)`, an invalid
  `Crc_Params`, a `Reader` over a returned local, and writing to a source a reader
  still borrows. Reject `f16`, `f32`, `f64`, `int`, `uint`, `uintptr`, `bool`,
  `rune`, and an enum as `T` in each of `get_length`, `get_count`, and `put_length`.
- **An example** in `examples/`, based on the worked example.

## Implementation

The steps are independent apart from the order shown, and each is one commit with
its specification, tests, regenerated `api.loki`, and `CHANGELOG.md` line.

1. `core:math`: `to_bits`, `from_bits`, and the sentence in
   [Floating-point operators](design.md#floating-point-operators).
2. `core:endian`: `is_fixed_width`, `load`, `store`.
3. `core:io`: `Slice_Writer`, `bytes_mut`.
4. `core:encoding/binary`, which needs 1 to 3.
5. `core:checksum`, which needs only `core:io`.

The library's documents change with them: new sections and task-table rows in
[standard-library.md](standard-library.md), its [package
layout](standard-library.md#package-layout), the rationale above moved to
[comments.md](comments.md#standard-library-api-choices), the line naming these
packages removed from [Standard-library maturity](future-plans.md#standard-library-maturity),
and this file deleted.

## What was checked

The original prototype was run with the current `lokec.exe`, in `-opt=none` and
`-opt=speed` where noted, with these additions in a scratch copy of `core` passed
by `-collection`. These results predate the review revisions to diagnostic
lengths, writer offset exhaustion, and length-field type constraints:

- The [worked example](#worked-example) compiles as an importer writes it, and its
  record round-trips through memory and through a file.
- A 46-byte record truncated at every length and with each of its 368 bits flipped
  gave 414 errors, no panic, and no accepted record.
- All 13 scalar types round-trip in both orders, including signalling NaNs.
- `u64` maximum and `i32(-1)` as lengths are errors and do not trap. A refused count
  of 60000 fails with the position unchanged and before any allocation.
- A slice from `take` stays valid across later reads and outlives the reader; a
  parent stays usable while children are live; a subrecord refuses to read or seek
  outside itself and reports absolute offsets.
- `Writer(W)` works over `Buffer_Writer`, `Slice_Writer`, `fs.File`,
  `dyn mut io.Writer`, and another `Writer`; `Reader` works with `io.copy`, and
  `Crc32` as its destination.
- All twelve CRC known answers, the empty and pangram cases, and updates in pieces.
- Rejected by the compiler: `get(int)`, `get(bool)`, and `put(7)` (`L0434`), an
  invalid `Crc_Params` (`L0434`), a `Reader` over a returned local (`L0526`), and
  dropping (`L0512`) or writing to (`L0511`) a source still borrowed.

Not checked: the revised contracts and boundary cases above, the slice-by-8 path
behind the generic `Crc` (measured separately, for CRC-32 only), behavior on any
target but Windows x64, and the [scripted-sink and allocation cases](#verification),
which need the real tests.

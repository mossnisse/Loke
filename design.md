# Loke language design

This document is the description of the current Loke language.
The formal syntax is defined in [grammar.md](grammar.md).

## Navigation

- [1. Source Structure](#1-source-structure)
  - [File format](#file-format)
  - [Code blocks](#code-blocks)
  - [Identifiers](#identifiers)
  - [Literals](#literals)
  - [Comments](#comments)
- [2. Types & Values](#2-types--values)
  - [Primitive types](#primitive-types)
  - [String types and views](#string-types-and-views)
  - [Pointer types](#pointer-types)
  - [Sequence types](#sequence-types)
  - [Map types](#map-types)
  - [Structured and algebraic types](#structured-and-algebraic-types)
  - [Procedure and meta types](#procedure-and-meta-types)
  - [Methods and abstractions](#methods-and-abstractions)
  - [Interfaces and polymorphism](#interfaces-and-polymorphism)
- [3. Declarations & Storage Duration](#3-declarations--storage-duration)
  - [Variable declarations](#variable-declarations)
  - [Constant declarations](#constant-declarations)
- [4. Expressions & Operators](#4-expressions--operators)
  - [Operators](#operators)
- [5. Statements & Control Flow](#5-statements--control-flow)
  - [Assignment statements](#assignment-statements)
  - [Control flow statements](#control-flow-statements)
- [6. Procedures & Functions](#6-procedures--functions)
  - [Procedures](#procedures)
  - [Generics](#generics)
- [7. Ownership & Lifetimes](#7-ownership--lifetimes)
  - [Borrows and lifetimes](#borrows-and-lifetimes)
- [8. Packages & Visibility](#8-packages--visibility)
  - [Packages](#packages)
- [9. Runtime & Interop](#9-runtime--interop)
  - [Built-in constants, values, and procedures](#built-in-constants-values-and-procedures)
  - [Error handling](#error-handling)
  - [Panics and unwinding](#panics-and-unwinding)
  - [Memory and program services](#memory-and-program-services)
  - [Concurrency and the memory model](#concurrency-and-the-memory-model)
  - [Foreign system](#foreign-system)
- [Appendices](#appendices)
  - [Conditional compilation](#conditional-compilation)
  - [Compile-time built-ins](#compile-time-built-ins)
  - [Attributes](#attributes)
  - [Library types assumed by this specification](#library-types-assumed-by-this-specification)

# 1. Source Structure

## File format

A Loke source file is UTF-8 without a byte order mark (BOM).

## Code blocks

A code block uses braces (`{}`) and creates a scope for its local variables.

### Statements

Most statements end with a semicolon (`;`). A statement omits the semicolon when its outermost form ends in a declaration or statement block, so the closing `}` terminates:

- `if`, `for`, `foreach`, `switch`, and `when`
- a block or deferred block
- procedure, record, interface, procedure-group, and brace-bodied operator definitions
- top-level `impl` and `foreign` blocks

An expression statement always needs a semicolon, including when it ends in a composite literal like `Point{1, 2}` — those braces are part of a value, not a block.

A lone `;` is an empty statement, valid anywhere including file scope. A semicolon after a brace-bodied form is thus a separate empty statement:

```odin
Foo :: struct {}
Bar :: struct {};   // the trailing `;` is a separate empty declaration
x :: Point{1, 2};   // a composite-literal expression still needs `;`
```

Newlines never terminate statements; the compiler does not insert semicolons.

### Control-flow headers

Each control-flow statement (`if`, `for`, `foreach`, `switch`, `when`) has a parenthesized header and a braced body. An unbraced body is not allowed.

```odin
if (x >= 0) { }
for (i := 0; i < 10; i += 1) { }
foreach (value in values) { }
switch (value) { }
when (LOKE_DEBUG) { }
```

## Identifiers

Identifiers are case-sensitive, ASCII only, and match `[A-Za-z_][A-Za-z0-9_]*`. The identifier `_` discards a value without creating a binding. Comments and literals may contain any Unicode.

## Literals

### String and character literals

A string literal uses double quotes, a character literal single quotes, and `\` starts an escape sequence. A raw string literal is enclosed in backticks and has no escapes.

```odin
"This is a string"
'A'
'\n'                       // newline character
"C:\\Windows\\notepad.exe"
`C:\Windows\notepad.exe`   // raw string, no escapes
```

`len(s)` returns the byte length of a string; if `s` is a compile-time constant, so is the result.

#### Escape characters

- `\a` - bell (BEL)
- `\b` - backspace (BS)
- `\e` - escape (ESC)
- `\f` - form feed (FF)
- `\n` - newline
- `\r` - carriage return
- `\t` - tab
- `\v` - vertical tab (VT)
- `\\` - backslash
- `\"` - double quote
- `\'` - single quote
- `\NNN` - octal 6-bit character (3 digits)
- `\xNN` - hexadecimal 8-bit character (2 digits)
- `\uNNNN` - hexadecimal 16-bit Unicode character, UTF-8 encoded (4 digits)
- `\UNNNNNNNN` - hexadecimal 32-bit Unicode character, UTF-8 encoded (8 digits)

### Number literals

A numeric literal may contain underscores for readability (`1_000_000_000`). A decimal point or exponent makes it floating-point (`1.0e9`). The prefixes `0b`, `0o`, and `0x` give binary, octal, and hexadecimal; a leading zero alone does not mean octal.

A numeric literal starts as an unfixed integer or unfixed floating constant, evaluated without first rounding to a runtime type. Context converts it implicitly:

- an unfixed integer constant converts to an integer type when its value is in range, or to a floating-point type under the rule below;
- an unfixed floating constant converts only to a floating-point type, never implicitly to an integer.

Converting a finite unfixed constant to a floating-point type rounds once, IEEE-754 round-to-nearest ties-to-even; it is rejected if the result would overflow to infinity, though rounding to subnormal or zero is allowed. Infinity and NaN may convert to a floating-point type but never to an integer; the IEEE class and an infinity's sign are preserved, and a NaN payload is implementation-defined.

```odin
x: int = 1.0;      // ERROR: unfixed floating constant does not convert to `int`
x: int = int(1.0); // OK: explicit floating-to-integer conversion
y: f64 = 1;        // OK: integer constant rounded to `f64`
z: f64 = 0.1;      // OK: rounded once to `f64`
```

## Comments

A line comment runs from `//` to the newline; a block comment is `/* ... */` and may nest. Comments may not appear inside a string or character literal.

```odin
// a comment
x: int; // trailing comment

/*
	block comment
	/* nested comment */
*/
```

# 2. Types & Values

## Primitive types

### Basic types

Loke's basic types are:

```odin
// booleans
bool

// integers
int  i8 i16 i32 i64 i128
uint u8 u16 u32 u64 u128 uintptr
byte // alias for u8, not a distinct type

// floating point
f16 f32 f64

rune     // a Unicode code point; a distinct 32-bit integer type
string   // immutable, valid UTF-8 text

rawptr   // untyped pointer
type     // compile-time-only type of types
typeid   // runtime type identifier
any_view // erased view of any value
```

`bool` is one byte. A foreign boolean binds as its integer type and is converted to `bool` in a wrapper (see [Foreign system](#foreign-system)).

`int` and `uint` are the natural register size and never smaller than a pointer (`size_of(uint) >= size_of(uintptr)`); `uintptr` is pointer-sized. Use `int` for a general integer, and a fixed-size or unsigned type when you need a specific range or representation. Loke `int` is not C `int` (see [Foreign-ABI-safe types](#foreign-abi-safe-types)).

`string` is immutable UTF-8 with an O(1) byte length. Foreign calls use `cstring_view` and temporary zero-terminated conversions; there is no second owning C-string type.

#### Zero values

Most runtime value types have a zero value, written `{}`. A declaration with no initializer receives it: a local variable where it is reached, and a file-scope, `static`, or `thread_local` variable before the program runs. Writing `x: T = ---;` asks for the storage without the value instead, and nothing is dropped for it.

The zero value is:

- `0` for numeric and rune types
- `false` for `bool`
- `""` for `string`
- an empty, immediately usable value for `[dynamic]T` and `map[K]V`: `len` and `cap` are 0, and appending or inserting needs no prior construction. Without a `via` declaration it is allocator-unbound until its first allocating operation
- `nil` for pointer, multi-pointer, `rawptr`, procedure, `typeid`, slice, `string_view`, `cstring_view`, `any_view`, every `dyn Interface`, `shared(T)`, and `weak(T)` type. A nil slice or view has length 0
- the variant `@(zero=name)` designates, for a [union](#unions) that designates one

Aggregate zero values are built recursively from their fields. A type with `hook(drop)` must have an inert zero value on which dropping does nothing; a resource that uses zero for a live handle must instead carry a separate validity field or forbid a zero owning value.

Compile-time-only `type` and reflection descriptors have no zero value.

##### Types with no zero value

A union has no zero value unless it writes `@(zero=name)`, and the property
propagates: a struct, a non-empty fixed array, or a distinct type that reaches a
no-zero type has none either. An empty fixed array holds no element and keeps
its own zero.

Every operation that manufactures a zero is rejected for a no-zero type:

- a declaration with no initializer, wherever its storage lives; `x: T = ---;`
  asks for the storage alone and is accepted
- a field an aggregate literal omits
- `new(T)`, which hands back zeroed storage
- a `make` **length**, which fills that many slots; a capacity, a map
  reservation, and a length written as the constant `0` are raw storage and
  fill nothing, so `make(T, 0, capacity)` reserves storage for a no-zero
  element
- growing a container with `resize`
- a map read, which answers the zero for a missing key
- an inserting map index, which starts a new entry at the zero

A map of a no-zero element is therefore not indexed at all, in either position.
It is still an ordinary map: `try_insert` writes the value, `lookup_value`,
`find` and `remove` answer an `Option`, and `in` tests for a key. A dynamic
array of one is unrestricted apart from a written length and `resize`.

The diagnostic names the operation and suggests the two ways out: give the union
a zero with `@(zero=first_variant)`, or construct the value explicitly.

#### Type conversion

`T(v)` converts `v` to type `T`:

```odin
i := 123;
f := f64(i);
u := u32(f);
```

Assigning between different types requires an explicit conversion unless an implicit conversion rule applies.

##### Implicit type conversions

The following list defines the implicit conversions. User-defined implicit
conversions apply only to unfixed constants through an inherent
[`@(implicit)` conversion hook](#implicit-conversion-from-constants).
Imported extensions cannot add other implicit conversions.

- `^mut T` -> `^T`, `[]mut T` -> `[]T`, and `dyn mut I` -> `dyn I`
- `^T` / `^mut T` -> `rawptr`
- `[^]T` -> `rawptr`
- `[^]T` <-> `^T` / `^mut T`
- Concrete values to `any_view` when an `any_view` parameter or local destination
  is expected; the result is a checked non-escaping borrow
- `dyn Derived` -> `dyn Base` when `Derived` composes `Base`; the result keeps
  the same data borrow and selects the base witness
- Any of a union's variants to that union
- A distinct procedure type <-> its underlying procedure type
- Unfixed integers -> built-in integer types when in range, and built-in
  floating-point types under the [rounding rule](#number-literals)
- Unfixed floats -> built-in floating-point types under the same rounding rule;
  never implicitly to integer types
- Unfixed booleans -> `bool`
- Unfixed rune constants -> rune types
- `string` -> `string_view`; a non-owning borrow subject to
  [Borrows and lifetimes](#borrows-and-lifetimes)
- Unfixed strings -> `string`, `string_view`, or `cstring_view` when the
  destination supplies the required lifetime
- Unfixed constants into a user type through an eligible `@(implicit)`
  conversion hook

### Unfixed constants

Some constant expressions have an unfixed type. Context implicitly converts an unfixed value to a compatible concrete type.

```odin
I :: 42;      // unfixed integer; converts to an integer or floating type
F :: 1.27;    // unfixed float; converts only to a floating type
S :: "Hello"; // unfixed string; converts to string
B :: true;    // unfixed boolean; converts to bool
```

## String types and views

### string type

`string` is an immutable, owning UTF-8 value. It behaves like a simple local variable: it can be assigned, returned, and stored with no explicit construction, cleanup, or `defer`.

```odin
first := "hello";
second := first;              // cheap value copy; backing storage may be shared
message := first + " world";
```

A string literal uses static storage; a runtime string owns a managed backing buffer. The representation (reference counting, small-string optimization, interning) is implementation-defined and does not change semantics. If backing storage is shared, its reference count is atomic and the last drop deallocates through the string's allocator; transferring such a string between threads is valid only when its allocator permits deallocation on either thread (not checked in version 1). To avoid shared ownership, pass `[]u8` or `string_view`, neither of which owns.

A `string` always holds valid UTF-8; arbitrary bytes use `[]u8` or `[dynamic]u8`, and converting bytes to a string validates and returns an error on invalid UTF-8.

String operations name their unit:

```odin
text := "Hej, världen";
byte_count := text.byte_len();   // O(1)
rune_count := text.rune_count(); // O(n)
bytes := text.bytes();           // read-only borrowed []u8
```

`len(text)` is shorthand for `text.byte_len()` (constant time). A string cannot be indexed by integer, since a code point may span several bytes; use `text.bytes()[i]`, iteration, or Unicode procedures. Grapheme clusters are handled by the Unicode library, not the core string type.

Repeated concatenation uses `String_Builder` from `core:strings`, a library type over `[dynamic]u8`. The compiler contributes one package-private primitive to that package — a copy of known-valid UTF-8 into string storage taken from a *supplied* allocator — because every built-in text operation allocates from the default provider and a library cannot otherwise honour `strings.copy(text, allocator)`. The UTF-8 algorithms, the growth policy, and the failure policy are ordinary Loke:

```odin
builder: String_Builder = {};
builder.append("hello");
builder.append(' ');
builder.append("world");
message := builder.finish(); // moves the buffer into an immutable string when possible
```

#### String iteration

String iteration yields Unicode scalar values (runes) by default; byte iteration is explicit. A string's `Element` is `rune`, so a plain loop binds exactly one name.

**A byte offset comes from `rune_offsets()`, never from a second binding.** The offset is the byte index where the yielded code point begins, so it advances by 1–4 per step and the final offset is not `len(x) - 1`. This offset can be fed back into `x.bytes()`, a slice expression, or a low-level API; a rune ordinal cannot. The two units are therefore separate [adapters](#iteration-adapters) rather than one binding whose meaning depends on the receiver.

```odin
// by runes with byte offsets: `Element` is `struct{value: rune, offset: int}`
x := "AÅ✓";
foreach (codepoint, offset in x.rune_offsets()) {
	fmt.println(offset, codepoint);
	// 0 A     (1 byte)
	// 1 Å     (2 bytes)
	// 3 ✓     (3 bytes)
}
assert(len(x) == 6);

// by bytes: `index` is an ordinary slice index
foreach (byte, index in x.bytes().indexed()) {
	fmt.println(index, byte);
}
```

Code needing a running rune ordinal asks for one; `indexed()` counts the elements it is applied to, which for a string are runes:

```odin
foreach (codepoint, ordinal in x.indexed()) {
	fmt.println(ordinal, codepoint);
	// 0 A
	// 1 Å
	// 2 ✓
}
```

Low-level string indices are byte offsets throughout; Unicode procedures state their unit in their names.

#### String format printing

Printing uses the library protocol `value.format(writer, options)`. A type may define how it is printed by declaring an inherent `format` method in the same package as the type. The standard free alias `format(value, writer, options)` selects that same method.

Each concrete type has one printed form throughout the program. Declaring more than one eligible inherent `format` method for a type is an error; the compiler provides the format for other printable types. An extension in another package may declare and call its own `format` method, but `print` does not use it.

### C string views

`cstring_view` is a non-owning, zero-terminated byte view — what C `char const *` maps to. It does not promise UTF-8, since foreign strings often use other encodings. A view from foreign code has no owner known to the compiler, so keeping it alive is the programmer's responsibility (see [foreign boundary](#what-is-not-checked)). Converting it to `string` scans for the terminator, validates UTF-8, and copies into owned storage.

A string literal may initialize a `cstring_view` (its bytes have static lifetime). A runtime `string` uses `to_c_view()`, which adds a terminator only when needed and returns a temporary valid for the enclosing expression; the temporary cannot be assigned, returned, or stored:

```odin
static_name: cstring_view = "Hellope";
text := string(static_name) or_else ""; // validates and copies, or uses the fallback
c_api(runtime_name.to_c_view());   // temporary lives through this call
```

To retain an owned zero-terminated buffer, use `C_String` from `core:cstrings`, a library type over `[dynamic]u8` exposing `view() -> cstring_view`.

### string type conversions

Safe conversions return managed values or explicit borrows; they never hide a mutable alias.

`string_view` is an immutable, validated UTF-8 borrow (a pointer and byte length). It has the same byte, rune, and iteration operations as `string` but owns nothing and does not terminate its storage. A `string_view` derived from a slice borrows that slice's owner and cannot outlive it. Creating one from a pointer with no compiler-known owner requires `unsafe.string_view`.

**A `string` converts implicitly to a `string_view`**, and to a view of any subrange by slicing. The conversion is a zero-cost borrow needing no validation, since a `string` is already valid UTF-8. String literals convert the same way, with static lifetime.

```odin
byte_count :: proc(text: string_view) -> int { return len(text); }

owned := "Hej, världen";
n := byte_count(owned);       // implicit borrow, no copy
m := byte_count(owned[5:]);   // a subrange view
```

Use `string_view` to read text and `string` to store it. The conversion runs one way only: a `string_view` becomes a `string` with `.copy()`, which allocates because the result must own its bytes.

A validating conversion answers with an [`Option`](#typed-fallibility): the
payload on valid input, `.none` on invalid. Handle it with a `switch` or with
`or_else`:

```odin
switch (text in string(bytes)) {
case .some: fmt.println(text);
case .none:
	// `bytes` was not valid UTF-8.
}
text = string(bytes) or_else "";
```

Legend:

- copy = create an independent managed value
- share = share immutable backing storage
- borrow = create a non-owning view, subject to [Borrows and lifetimes](#borrows-and-lifetimes)
- stream = get individual values from the string, without allocation
- st = the input string

The language has no `const` qualifier. **Capability is in the carrier's type, spelled `mut`, and it is the same axis for every checked borrow:**

| | read-only | mutable |
| --- | --- | --- |
| a single value | `^T` | `^mut T` |
| a sequence | `[]T` | `[]mut T` |
| an erased view | `dyn I` | `dyn mut I` |
| forming one | `&place` | `&mut place` |

A view from a `string` is thus `[]u8` and cannot become `[]mut u8`. Other read-only storage — a [materialized constant](#materialization) — is read-only by how it was declared.

`inout T` remains a distinct mode rather than a spelling of `^mut T`: it is non-null, bound to the call, marked at the call site, and may invalidate the whole owner it names. An interior `^mut T` may not.

`[^]T` stays outside this axis. It is unchecked and always mutable, and converting to it visibly crosses the `core:unsafe` boundary.

Checked provenance follows a local pointer, its copies, and the records, unions, and containers it is [stored inside](#values-that-contain-borrows). It is lost by storing the pointer in a `rawptr` or `[^]T` place or converting it through `core:unsafe`. A pointer loaded from such a place or received from foreign code is an unchecked address.

#### From string to X

| To | Action | Code |
| --- | --- | --- |
| `[]u8` | borrow | `st.bytes()` |
| `string_view` | borrow, implicit | `view: string_view = st` |
| `string_view` | borrow a subrange | `st[low:high]` |
| `string` | share | `new_string := st` |
| `string` | independent byte copy | `st.copy()` |
| `cstring_view` | temporary borrow | `st.to_c_view()` |
| `[]rune` | stream | `foreach (rune in st) { ... }` |
| `[dynamic]rune` | copy | `st.to_runes()` |
| `[^]u8` | unsafe borrow | `unsafe.raw_data(st.bytes())` |

#### From cstring_view to X

| To | Action | Code |
| --- | --- | --- |
| `Option(string)` | validate and copy | `string(st)` |
| `[^]u8` | unsafe borrow | `unsafe.raw_data(st)` |

#### From a string literal to X

| To | Action | Code |
| --- | --- | --- |
| `string` | share static storage | `newstr: string = st` |
| `cstring_view` | borrow static storage | `newstr: cstring_view = st` |

#### From []u8 to X

| To | Action | Code |
| --- | --- | --- |
| `Option(string)` | validate and copy | `string(st)` |
| `Option(string_view)` | validate and borrow | `string_view(st)` |
| `[^]u8` | unsafe borrow | `unsafe.raw_data(st)` |

#### From []rune to string

| Action | Code |
| --- | --- |
| validate and copy, `Option(string)` | `string.from_runes(st)` |

#### From [^]u8 to cstring_view

| Action | Code |
| --- | --- |
| unsafe borrow | `unsafe.cstring_view(st)` |

#### From [^]u8 and length int to string

| Action | Code |
| --- | --- |
| validate and copy, `Option(string)` | `string(ptr[0:length])` |
| unsafe validate and borrow, `Option(string_view)` | `unsafe.string_view(ptr, length)` |

## Pointer types

### Pointers

A pointer contains the memory address of a value. `^T` is a read-only pointer to `T` and `^mut T` a mutable one. The zero value of both is `nil`, and both are one machine address: the capability is static and changes no layout, no ABI, and no calling convention.

```odin
p: ^int = nil;
q: ^mut int = nil;
```

`&` returns a read-only borrow of a readable addressable operand, and `&mut` an exclusive mutable borrow of one this body may write:

```odin
i := 423;
reader := &i;      // ^int
writer := &mut i;  // ^mut int
```

`&` reaches every place that can be read: a local, a value parameter, an element of a `[]T`, and a [materialized constant](#materialization). `&mut` additionally requires that the place be assignable, so a value parameter, a `[]T` element, and a constant all reject it. Neither reaches a [packed](#packed) field or an `any_view`.

The postfix `^` operator dereferences a pointer. Dereferencing either capability yields a place with an address; only `^mut T` yields one that may be written:

```odin
fmt.println(writer^); // read `i` through the pointer
writer^ = 1337;       // write `i` through the pointer
reader^ = 1337;       // ERROR: `^int` is a read-only borrow
```

The same rule carries through implicit pointer field selection, indexing, method receivers, and nested projections: a place reached through a `^T` is readable and not assignable, and a mutating method may not be called on it.

A `^mut T` implicitly weakens to a `^T`. A `^T` never strengthens, even when the storage it names is a mutable local — see [Capabilities and the one rule](#capabilities-and-the-one-rule).

Loke uses `^` for pointer types and pointer dereference:

```odin
i := 0;
p: ^int = &i; // ^ on the left
x := p^;      // ^ on the right
```

Pointer arithmetic is not an operator. `core:mem.ptr_offset` and
`core:mem.ptr_sub` provide explicit address calculations.

### Multi-pointers

A multi-pointer describes a foreign (C-like) pointer that acts like an array. `[^]T` is a multi-pointer to `T`. Its zero value is nil.

```odin
p: [^]int = nil;
```

What multi-pointers support:

- Indexing without bounds checking.
- Slicing, with bounds checking when both low and high operands are given.
- Implicit conversions between `^T` and `[^]T`.
- Implicit conversion to `rawptr`, like all pointers.

What multi-pointers DO NOT SUPPORT:

- Dereferencing, making a multi-pointer closer to a slim slice than a pointer.

The type mainly aids foreign code, documenting intent and easing conversion of C pointers into slices.

The following are the rules for indexing and slicing for multi-pointers, and what type they produce depending on the operands given:

```odin
x: [^]T = ...;
```

x[i]   -> T
x[:]   -> [^]T
x[i:]  -> [^]T
x[:n]  -> []T
x[i:n] -> []T

Interacting with Multi-Pointers is easiest using `unsafe.raw_data`, which makes the loss of bounds and borrow capability visible at the call site.

```odin
a: [^]int = nil;
fmt.println(a); // <nil>
b := [?]int { 10, 20, 30 };
a = unsafe.raw_data(b[:]);
fmt.println(a, a[1], b); // 0x7FFCBE9FE688 20 [10, 20, 30]
```

The language name for `[^]T` is *multi-pointer*.

### unsafe.raw_data procedure

`unsafe.raw_data` is a `core:unsafe` procedure that returns the underlying data of a built-in data type as a multi-pointer. A multi-pointer carries neither a length nor a read-only capability, and its lifetime is no longer checked after conversion.

```odin
unsafe.raw_data([]$E)              -> [^]E;    // read-only slices; capability is discarded
unsafe.raw_data([]mut $E)          -> [^]E;    // mutable slices
unsafe.raw_data([dynamic]$E)       -> [^]E;    // dynamic arrays
unsafe.raw_data(^[$N]$E)           -> [^]E;    // fixed arrays
unsafe.raw_data(string)            -> [^]byte;
```

For a nested fixed array, `unsafe.raw_data` exposes one array level at a time. If `grid` has type `[Rows][Columns]T`, then `unsafe.raw_data(&grid)` has type `[^][Columns]T`, while `unsafe.raw_data(&grid[0])` has type `[^]T` and points at the first scalar element of the contiguous row-major storage.

## Sequence types

### Fixed arrays

A fixed array contains a compile-time known number of elements of one type. An array index can have an integer, character, or enumeration type.

This declaration constructs a fixed array:

```odin
x := [5]int{1, 2, 3, 4, 5};
foreach (i in 0..=4) {
	fmt.println(x[i]);
}
```

A fixed array stores its elements contiguously. Its layout is equivalent to a record with one field for each element.

`x[i]` accesses element `i` of `x`. The first element has index 0.

#### Multidimensional arrays

A multidimensional fixed array is an ordinary nested array. `[Rows][Columns]T` means an outer array of `Rows` values, each of which is an inner `[Columns]T` array:

```odin
grid := [2][3]int{
	{1, 2, 3},
	{4, 5, 6},
};

row := grid[1];       // [3]int{4, 5, 6}
x := grid[1][2];      // 6
```

Nested fixed arrays are one contiguous value; they are not arrays of pointers. Their layout is row-major in declaration order, with the rightmost index varying fastest. For `a: [D0][D1]...[Dn]T`, the scalar elements of `a[0]` precede those of `a[1]`. In two dimensions, `a[row][column]` has the flat element offset `row*Columns + column`.

**Built-in indexing takes exactly one index.** A nested container is indexed by chaining: `a[i][j][k]`. Each step is evaluated left to right and performs its own bounds check, and it is a compile-time error if an intermediate value is not indexable.

`[][]T` is a slice of slices and `[dynamic][dynamic]T` is a dynamic array of independently managed dynamic arrays; their inner containers may have different lengths and, for dynamic arrays, separate allocations. They are potentially jagged, and only nested *fixed* arrays have the single contiguous layout described above.

A fixed-array length can be inferred from its literal with a question mark (`?`):

```odin
x := [?]int{1, 2, 3, 4, 5};
```

Designated initializers set elements by index or index range:

```odin
favorite_animals := [?]string{
	// Assign by index
	0 = "Raven",
	1 = "Zebra",
	2 = "Spider",
	// Assign by range of indices
	3..=5 = "Frog",
	6..<8 = "Cat",
}
```

The built-in `len` procedure returns the array length.

```odin
x: [5]int = {};
static_assert(len(x) == 5);
```

Built-in array access is always bounds checked, at compile time for constant indices and at runtime otherwise. Unchecked access crosses the `core:unsafe` boundary and uses a multi-pointer:

```odin
p := unsafe.raw_data(&x);
p[n] = 123; // unchecked; the programmer proves that n is valid
```

### SIMD vectors

`Simd` is a reserved predeclared name and a reserved member of the public
`Type_Kind`. Version 1 does not provide SIMD types: an attempted `Simd(T, N)`
instantiation is a compile-time error identifying the feature as unavailable,
rather than the name as unknown. No current language rule, runtime facility, or
standard package depends on a SIMD value. SIMD operations, conversions, and ABI
behavior are not part of the current language contract.

### Slices

A slice is a non-owning view of a sequence. Its length is a runtime value. `[]T` has read-only elements. `[]mut T` has mutable elements. Both types have the same runtime representation. Mutability is a static capability and does not change the ABI.

A mutable slice implicitly weakens to a read-only slice. A read-only slice never converts to a mutable slice, including when its original owner happens to be mutable. Slicing a mutable, addressable array or dynamic array produces `[]mut T`; slicing an immutable parameter, a string, or an existing `[]T` produces `[]T`.

A slice expression has a low bound and a high bound separated by a colon:

a[low : high]

The range includes the low bound and excludes the high bound.

```odin
fibonaccis := [6]int{0, 1, 1, 2, 3, 5};
s: []int = fibonaccis[1:4]; // creates a slice which includes elements 1 through 3
fmt.println(s); // 1, 1, 2
```

A slice does not own element storage. Its runtime value contains a pointer and a length.

**A slice is a borrow.** It is not an owning value: it has no allocator, it is never cleaned up at scope exit, and it owns nothing. Creating a slice over a dynamic array therefore constrains that container for as long as the slice is live, and the rules in [Borrows and lifetimes](#borrows-and-lifetimes) apply in full:

```odin
numbers := [dynamic]int{1, 2, 3};
view: []int = numbers[:]; // mutable capability is weakened to read-only
numbers.append(4);   // ERROR: `numbers` may reallocate while `view` is live
fmt.println(view[0]);
```

A slice over a fixed array is a borrow of that array's storage, and so is bound by the array's scope in the same way. A slice over a string literal borrows static storage and is therefore valid for the whole program.

To keep the data after the owner expires, make an owned copy. `slice.clone(view)` returns an owned `[dynamic]T`.

The built-in `len` procedure returns the slice length. Element assignment and iteration by reference require `[]mut T`:

```odin
x: []mut int = ...;
x[0] = 10;
foreach (&value in x) {
	value += 1;
}
length_of_x := len(x);
```

#### Slice literals

A slice literal does not specify a length. This is an array literal:

[3]int{1, 6, 3}

This slice literal creates the same hidden array and returns a read-only slice of it:

[]int{1, 6, 3}

**A slice literal has the type it is written with.** `[]T{...}` produces `[]T` and `[]mut T{...}` produces `[]mut T`; the capability is never inferred. A `[]mut T` literal may still be weakened by an explicit `[]T` destination, like any other mutable slice.

```odin
readable := []int{1, 6, 3};        // []int
writable := []mut int{1, 6, 3};    // []mut int
writable[0] = 99;
readable[0] = 99;                  // ERROR: elements of `[]int` are read-only
```

The backing array of a slice literal is a hidden fixed-array owner in the surrounding lexical scope, so the slice remains valid until that scope exits. At file scope it has static lifetime. Returning a slice literal from a procedure is rejected because its hidden owner is local, just as returning a slice of a named local array is rejected.

#### Slice shorthand

For the array:

```odin
a: [6]int = {};
```

these slice expressions are equivalent:

a[0:6]
a[:6]
a[0:]
a[:]

#### Nil slices

The zero value of a slice is nil. A nil slice has a length of 0 and does not point to any underlying memory. Slices can be compared against nil and nothing else.

```odin
s: []int = nil;
if (s == nil) {
	fmt.println("s is nil!");
}
```

#### Sorting slices

A mutable slice can be sorted in ascending order as follows. The library procedures accept `[]mut T`; passing a read-only `[]T` is a compile-time error:

```odin
s := []mut int{1, 6, 3, 5 ,7, 3, 0};
slice.sort(s);
```

or in descending order

```odin
r := []mut int{1, 6, 3, 5 ,7, 3, 0};
slice.reverse_sort(r);
```

### Dynamic arrays

Dynamic arrays are mutable owning values whose length may change at runtime. The value behaves like a local variable; its variable-sized backing storage is obtained through an allocator and released automatically when the array leaves scope.

```odin
x: [dynamic]int = {};
x.append(10); // the zero value is immediately usable
```

Along with `len`, dynamic arrays provide `cap` to report their current underlying capacity. Assignment creates an independent array by recursively cloning owned elements, while `move` transfers its backing allocation:

```odin
x := [dynamic]int{1, 2, 3};
y := x;       // independent ownership-recursive clone
z := move(x); // allocation transfer; x becomes dead
```

Each array records the allocator responsible for its backing storage and cleanup:

- `via allocator` binds that allocator at the declaration.
- Without `via`, a zero-valued array is allocator-unbound until an operation
  needs an allocator; it then binds `mem.default_allocator()`.

`via` applies only to declarations. It neither introduces names nor changes
cleanup. Procedures receive allocators through ordinary parameters, with
[ordinary default-argument rules](#default-values).

Copy initialization and assignment use the destination's bound allocator,
resolving its declaration policy if it is dead or allocator-unbound.
`move` instead transfers the allocation and its allocator without relocating
the data. Explicit `clone(value, allocator)` and `try_clone(value, allocator)`
select an allocator for a new copy. See [Assignment statements](#assignment-statements)
and [Managed values and storage](#managed-values-and-storage) for the full rules.

Backing storage need not be on the heap. An arena over a local buffer provides
frame-local storage while the array's own size remains fixed by its type:

```odin
buffer: [4096]u8 = {};
arena := mem.Arena.from_buffer(buffer[:]);
data: [dynamic]int via arena.allocator() = {};
data.append(1, 2, 3); // backing storage is in buffer; no heap allocation
```

Allocator lifetime and reset requirements are specified under
[Allocators](#allocators).

A slice of a dynamic array is a borrowed view. While that view is live, operations that may reallocate the owner are rejected:

```odin
values := [dynamic]int{1, 2, 3};
middle := values[1:];
values.append(4); // error: append may invalidate `middle`
use(middle);
```

#### Appending to a dynamic array

Container operations use method syntax. These are built-in operations rather than dynamically dispatched methods.

```odin
x: [dynamic]int = {};
x.append(123);
x.append(4, 1, 74, 3); // append multiple values at once

y: [dynamic]int = {};
y.append(..x[:]); // append a slice
```

Ordinary mutating operations use the allocator's configured failure policy,
which normally reports an out-of-memory panic. Fallible variants such as
`try_append` and `try_reserve` return `Result(Unit, Allocator_Error)` so the
caller can handle failure.

The `try_` prefix is a library-wide convention: the operation reports the failure
that its ordinary form would panic on, and leaves the value unchanged on failure.
It returns a [`Result`](#typed-fallibility), never a bare `bool`:

- An operation that can fail only by allocating uses `Allocator_Error`.
- A never-allocating container such as [`Small_Array(T, N)`](#fixed-capacity-arrays)
  uses a library-declared error such as `Capacity_Error`.
- A no-payload success uses `Result(Unit, E)`.

The prefix specifies the failure contract, not a particular error type.

#### Assigning to a dynamic array

`insert` adds an element and shifts later elements upwards. Its index must be in `0..=len(x)`.

**Indexed assignment does not change the array length.** `x[i] = v` causes an out-of-range panic when `i >= len(x)`. This rule prevents an incorrect index from silently increasing the array length. To assign past the current end, first change the length and then assign:

```odin
x: [dynamic]int = {};
x.reserve(16);
x.insert(0, 10);

x.resize(4);                        // [10, 0, 0, 0]
x[3] = 10;
fmt.eprintln(x[:], len(x), cap(x)); // [10, 0, 0, 10] 4 16

x[3] = 20;
x.append(30);
fmt.eprintln(x[:], len(x), cap(x)); // [10, 0, 0, 20, 30] 5 16

x.append(40, 50, 60);
fmt.eprintln(x[:], len(x), cap(x)); // [10, 0, 0, 20, 30, 40, 50, 60] 8 16
```

Loke has no separate grow-and-assign operation. Use `resize` to grow and zero-fill an array. Use `append` to add elements at the end.

#### Removing from a dynamic array

Removing from a dynamic array can be done in several ways using the built-in procedures:

- `pop` removes and returns the last element as `Option(T)`; an empty array has nothing to pop and answers `.none`.
- `remove_unordered` removes and returns an element in O(1) by moving the last element into its location.
- `remove` removes and returns an element while preserving order.

```odin
x: [dynamic]int = {};
x.append(1, 2, 3, 4, 5); // [1, 2, 3, 4, 5]
x.pop(); // [1, 2, 3, 4]
x.remove(0); // [2, 3, 4]
x.remove_unordered(0); // [4, 3]
```

Other variants can be found in the built-in procedures documentation.

#### Slicing and sorting a dynamic array

Dynamic arrays can be sliced and sorted:

```odin
s: [dynamic]int = {};
s.append(1, 6, 3, 5, 7, 3, 0); // [1, 6, 3, 5, 7, 3, 0]
s.sort(); // [0, 1, 3, 3, 5, 6, 7]
```

#### Creating and releasing slices and dynamic arrays

Managed dynamic arrays need no explicit construction or deletion. Their zero value is usable, literals create managed values, and capacity can be reserved separately:

```odin
a: [dynamic]int = {};   // len(a) == 0, cap(a) == 0
b := [dynamic]int{1, 2, 3};
c: [dynamic]int = {};
c.resize(6);            // len(c) == 6; new elements are zero
c.reserve(32);          // capacity is at least 32

// with an explicit allocator:
scratch := mem.Scratch.init();
temporary: [dynamic]int via scratch.allocator() = {};
temporary.reserve(64);
```

`drop` releases an owner, writes its inert zero representation, and makes the binding dead. Managed code can instead use automatic scope cleanup.

```odin
drop(b);
// `b` is dead here; assign a complete new value before using it again.
b = [dynamic]int{};
assert(len(b) == 0);
```

The fallible `make` constructor returns an ordinary owning value, cleaned up at
scope exit like any other. In a procedure returning a compatible `Result`,
`or_return` propagates construction failure; moving the owner still requires
`move`:

```odin
raw := make([dynamic]int, 0, 64, my_allocator) or_return;
owned := move(raw); // `owned` is the owner now; `raw` is dead and needs no `drop`
```

Where a container must deliberately outlive its scope uncleaned, [`unsafe.forget`](#unsafeforget) suppresses the cleanup of that one value.

#### Clearing a dynamic array

`clear` removes all elements from a dynamic array. It sets `len()` to 0 and does not change `cap()`.

```odin
x: [dynamic]int = {};
x.append(1, 2, 3, 4, 5); // [1, 2, 3, 4, 5]
fmt.println(len(x)); // 5
x.clear(); // []
fmt.println(len(x)); // 0
```

#### Resizing and reserving a dynamic array

A dynamic array can change its length or reserve capacity. These operations have different effects:

- `resize` sets the length to the requested element count. It can also increase the capacity.
- `reserve` makes the capacity at least the requested element count. It does not change the length.
- `shrink` reduces the capacity to the current length or to the specified minimum capacity.

```odin
x: [dynamic]int = {};
fmt.println(len(x), cap(x)); // 0 0
x.append(1, 2, 3); // [1, 2, 3]
fmt.println(len(x), cap(x)); // 3 8 — the growth policy is implementation-defined; 8 is illustrative
x.resize(5);
fmt.println(x[:]); // [1, 2, 3, 0, 0] other values are zero'd memory
fmt.println(len(x), cap(x)); // 5 8
x.reserve(32);
fmt.println(len(x), cap(x)); // 5 32
x.shrink();
fmt.println(len(x), cap(x)); // 5 5
```

#### Fixed-capacity arrays

A growable array with inline fixed capacity is the library type `Small_Array(T, N)`, not a second built-in array form. It implements the ordinary indexing, slicing, iteration, and container procedures through the same abstraction facilities available to user code. It never allocates; operations that would exceed `N` panic, while their `try_` forms leave the value unchanged and return `.err` — `try_append` is `Result(Unit, Capacity_Error)`, with `Capacity_Error` an ordinary library union carrying `@(failure=...)`, not a compiler-known type.

```odin
x: Small_Array(int, 8) = {};
x.append(1, 2, 3);
fmt.println(len(x), cap(x)); // 3 8
```

### Ranges

The range operators [`..<` and `..=`](#other-operators) produce a value of the
compiler-provided generic type written `Range(T)` here and in diagnostics:
`a..<b` is half-open and excludes `b`, `a..=b` is closed and includes it. Both
endpoints are unified to one type under the ordinary binary-operand rule, and
`T` must be an integer or rune type. The spelling is notation for this
specification; unlike [`Simd(T, N)`](#simd-vectors) the name is not in scope,
for the reason given below.

A range is an ordinary first-class value, not a piece of loop syntax. It may be
bound to a variable, passed to a parameter, and inferred into a `$` parameter,
and it keeps its half-open or closed kind wherever it travels:

```odin
half   := 0 ..< 3;      // Range(int)
closed := 'a' ..= 'c';  // Range(rune)

foreach (i in half) { fmt.println(i); }      // 0 1 2
foreach (ch in closed) { fmt.println(ch); }  // a b c
```

`Range(T)` has three public fields — `low: T`, `high: T`, and `closed: bool` —
so code that must inspect a range rather than walk it reads them directly. It
satisfies [`Iterable`](#standard-interface-catalogue) with `Element` equal to
`T`, which is what lets a range reach generic code written against that
interface. It is not a [`Sequence`](#standard-interface-catalogue): a range
stores no elements, so it has neither `len` nor indexing.

The type is **inferred, never written**. `Range` is not a name in scope, so a
range-typed declaration takes its type from its initializer (`r := 0 ..< 3;`)
and a procedure receives one through a `$` parameter. This keeps the type an
ordinary value without committing a spelling for it in version 1.

The one thing that spelling would buy is a written result type, so a range is
returnable only where the result type is itself inferred:

```odin
clamp_span :: proc(r: $R, limit: int) -> R { ... }   // OK: R is bound by the argument
window :: proc(n: int) -> Range(int) { ... }         // ERROR: `Range` is not a name
```

A procedure that must hand a range back to a caller who did not supply one
returns its endpoints, or a record of its own, instead.

Ranges are also accepted, as syntax rather than as values, in [`switch` case
lists](#switch-statement) and in [designated array
initializers](#fixed-arrays). Those positions match endpoints against a subject
or an index and never construct a `Range(T)`.

## Map types

### Maps

A map maps keys to values. Its zero value is empty and immediately usable. Like a dynamic array, a map is managed by default and releases its backing storage automatically.

**Iteration order is unspecified.** It can differ between iterations of one unmodified map, between maps with the same entries, and between program runs. To get a stable order, collect and sort the keys. Map iteration is not valid on an executed [compile-time path](#compile-time-procedure-evaluation), because compile-time results must be reproducible.

Any type can be a map key when it satisfies `interfaces.Hashable`, with a **coherent** `==` and `value.hash(seed: uint) -> uint` (equal values produce equal hashes). The standard free alias `hash(value, seed)` selects that same method. Built-in conformances are the list under the [standard interface catalogue](#standard-interface-catalogue). For a user-defined key, both operations must be inherent to the key type; caller-local extensions do not qualify, so a `map[K]V` uses one equality and hashing policy across packages. A different policy wraps the key in a local `distinct` type with its own inherent operations, or uses a library map type with explicit hasher and equality parameters.

```odin
m: map[string]int = {};
m["Bob"] = 2;
fmt.println(m["Bob"]);
```

To insert or update an element of a map:

```odin
m[key] = elem;
```

To retrieve an element:

```odin
elem = m[key];
```

To remove an element:

```odin
m.remove(key);
```

A lookup of a missing key returns the zero value. Use `lookup_value` or the `in` operator to test whether the key exists:

```odin
elem, ok := m.lookup_value(key); // `ok` is true if the element for that key exists
```

or

```odin
ok := key in m; // `ok` is true if the element for that key exists
```

`m.lookup_value(key)` answers `Option(V)`. It never inserts, evaluates its
receiver before its key, performs exactly one lookup, and produces an
independently owned element — a managed payload is cloned once, inside the
operation, so the map keeps its own storage. Its receiver is immutable, so an
immutable parameter or a temporary map can be read through it without `inout`.

`m[key]` as a read answers the element's zero for a missing key, so a caller
that needs to tell absence apart takes `lookup_value` instead. A no-zero element
type has no zero to answer with, and `m[key]` is rejected for it entirely.

A map literal initializes a map:

```odin
m := map[string]int{
	"Bob" = 2,
	"Chloe" = 5,
}
```

Map literals create managed values using the current allocator. Low-level code that must avoid implicit allocation can use `make` with an explicit allocator, or a project-level lint that rejects implicit allocation.

A map index in a place position is a location, so a field of a stored value can be assigned directly:

```odin
Test :: struct {
	x: int,
	y: int,
}

m := map[string]Test{
	"Bob" = { 0, 0 },
	"Chloe" = { 1, 1 },
}

m["Bob"] = { 3, 3 };
m["Chloe"].x = 0;    // allowed: assigns the field of the stored value
m["Dana"].x = 7;     // inserts a zero `Test` for "Dana", then assigns `.x`
```

The two forms differ when the key is missing:

- **`m[key]` as an assignment target inserts.** If the key is absent, a zero element is inserted first and its slot is the location — the same behavior `m[key] = elem` has, extended to field and index chains. It applies to the target of an assignment or compound assignment and to an `inout` argument. Insertion may reallocate the map, so the index is a mutable borrow of `m` for the statement. This differs from [dynamic-array assignment](#assigning-to-a-dynamic-array), where an index past the end panics rather than growing the array; a map key is not positional.
- **A non-inserting lookup is `m.find(key)`,** not `&m[key]`. It answers `Option(^mut V)`, a pointer to the existing slot:

```odin
switch (value in m.find("Bob")) {
case .some: value^ = { 2, 2 };
case .none:
}
```

  `&m[key]` is not a special lookup form: `&` always returns one pointer, and a key that is not there has no address to give. Use `find` for a non-inserting lookup.

#### Map container operations

The built-in map supports these container operations:

- `len(some_map)` returns the number of entries.
- `cap(some_map)` returns the current capacity. An insertion can reallocate when it exceeds this capacity.
- `some_map.clear()` removes all entries and retains the capacity.
- `some_map.reserve(capacity)` reserves capacity for at least the requested number of entries.
- `some_map.shrink()` removes excess capacity.
- `some_map.find(key)` returns `Option(^mut V)`: a pointer to the existing value, or `.none`. It does not insert.
- `some_map.lookup_value(key)` returns `Option(V)`: an independently owned copy of the existing value, or `.none`. It does not insert, and its receiver is immutable.

## Structured and algebraic types

### Type alias

A type alias gives another name to a type:

```odin
My_Int :: int;
static_assert(My_Int == int);
```

### Distinct types

A distinct type is a new type with the same representation as its underlying type.

```odin
My_Int :: distinct int;
static_assert(My_Int != int);
```

A distinct type may define its own methods, operators, named constructors, conversion hooks, interfaces, and formatting. It does not inherit the underlying type's operations: `Meters :: distinct f64` supports no arithmetic until it is given some. Operations are brought over either one at a time, with an ordinary forwarding declaration that unwraps to the underlying type, or in bulk with the [`delegate`](#delegating-operators) form below. Copy and drop hooks are record lifecycle roles; a resource-bearing distinct type wraps a record that owns the lifecycle.

Each named aggregate type (`struct`, `enum`, or `union`) is distinct.

```odin
Foo :: struct {};
static_assert(Foo != struct{});
```

#### Delegating operators

A single forwarding overload is one line — unwrap to the underlying type, apply its operator, wrap the result back:

```odin
Meters :: distinct f64;

impl Meters {
    add :: operator(+) proc(a, b: Meters) -> Meters { return Meters(f64(a) + f64(b)); }
}
```

but a numeric newtype needs that same line for every operator it wants. `delegate` generates those forwarding overloads from a list of operator symbols, parsed exactly as [`operator(...)`](#operator-declarations), inside an `impl` block for a distinct type:

```odin
Meters :: distinct f64;

impl Meters {
    delegate(+, -, ==, !=, <, <=, >, >=);
}

a := Meters(3);
b := Meters(4);
c := a + b;      // Meters(7): generated (a, b: Meters) -> Meters
a += b;          // += follows from + by the compound-assignment fallback
ok := a < b;     // bool: a comparison result is not wrapped
```

For each listed symbol, `delegate` generates the underlying type's overloads of that operator (fixed at declaration time, so a caller's extensions cannot change them), substituting the distinct type for the underlying type in every operand and result. Each generated overload unwraps its operands, applies the underlying operator, and wraps a result *of the underlying type* back; a result of any other type — a comparison `bool`, a dot-product `f32` — passes through unchanged. Compound-assignment forms follow from their binary operators via the [fallback rule](#operator-declarations), so delegating `+` also gives `+=`.

Delegation is selective by design. `Meters` delegates `+` and `-` but not `*` or `/`: two lengths add to a length but multiply to an area, a different type. A mixed-operand operator such as `Meters * f64 -> Meters` is written by hand. Listing a symbol the underlying type does not define is an error, and delegating one already declared explicitly in the same block is a redeclaration.

`delegate` has no meaning for a non-`distinct` type. Non-operator behavior — including a `hash`, `compare`, or `format` method — is re-exported by an ordinary one-line receiver method that unwraps, calls, and where relevant wraps; these are rarer and need no bulk form.

### Structs

A struct is a record that contains named fields. The dot operator selects a field:

```odin
Vector2 :: struct {
	x: f32,
	y: f32,
}
v := Vector2{1, 2};
v.x = 4;
fmt.println(v.x);
```

The dot operator can also select a field through a struct pointer:

```odin
v := Vector2{1, 2};
p := &v;
p.x = 1335;
fmt.println(v);
```

For a pointer to a struct, `p.field` is equivalent to `p^.field`.

#### Anonymous records

`(name: Type, ...)` is a record type with no declaration site — the lightweight
product type, written wherever a type is written:

```odin
entry: (key: string_view, value: int);
Entry :: (key: string_view, value: int);   // an alias, not a new nominal type
lookup :: proc(k: string_view) -> (value: int, found: bool) { ... }
```

Its identity is **structural**: the ordered sequence of its `(field name, field
type)` pairs. Two records with the same fields in the same order are the same
type wherever they are written; the same fields in a different order are
different types. A field name is part of the type, so `(a: int, b: int)` and
`(x: int, y: int)` are unrelated.

Every field is named and public. There is no `using`, no private field, no
layout attribute, no default, and none of the parameter-only modes — a `struct`
declaration is what carries those. Copy, move, drop, equality, formatting, and
reflection derive structurally, exactly as they do for a `struct` with no user
hooks.

A record is constructed by a [contextually typed](#struct-literals) composite
literal, or through an alias used as an ordinary literal prefix. There is no
inline shape-prefixed literal:

```odin
entry: Entry = {key = "port", value = 8080};
named := Entry{key = "port", value = 8080};
return .ok({key = k, value = v});
```

A parenthesised group is a record type only when it is **labelled**. `(T)` in
expression position stays grouping and is not a type, and `Foo(x: int)` is not a
generic application.

#### Destructuring

Two or more bindings on the left of `:=` or `=`, with one record on the right,
project that record's fields positionally. A single binding takes the whole
value. `foreach`'s binding list is the same rule.

```odin
q, r := divmod(17, 5);
low, high = minmax(a, b);
foreach (key, value in table) { ... }
```

The record must have exactly as many **directly declared** fields as there are
bindings, and every one must be visible at the use site. Promoted (`using`)
fields are not flattened, private fields are not filtered out, and `_` does not
bypass visibility. Destructuring is flat: a binding takes a whole field,
whatever that field's own shape is.

Ownership follows the operand's category, exactly as every other binding does:

- A **place** clones. `x, y := point` copy-initialises each binding and `point`
  stays live and drops normally. Each retained field must be copyable, and the
  copy-cost diagnostic applies per cloned field. This projects fields; it does
  not call the containing record's copy hook.
- A **temporary** or `move(...)` consumes. Retained fields transfer without
  cloning. The containing record must have neither a custom `hook(copy)` nor a
  custom `hook(drop)` — decomposing a value whose hooks own its lifecycle is
  rejected rather than given an exception; its *fields* may have hooks of their
  own.

`_` discards. It clones nothing from a place; in a consuming form the discarded
field drops exactly once, in reverse declaration order, after every retained
binding is published.

Retained fields are prepared in declaration order before any binding is
published, and an assignment keeps the ordinary prepare-then-write rule. On the
cloning path a failed clone cleans its partial field temporaries and leaves the
source untouched.

```odin
// The temporary is consumed: nothing is cloned.
name, bytes := read_document(path) or_return;

// The place is cloned, and the copy-cost diagnostic reports it.
doc := read_document(path) or_return;
name, bytes := doc;
```

#### Struct literals

A struct literal starts with its type and a pair of braces. Elements may be
positional, named, or a mix with every positional element first. Any field the
literal omits takes its type's zero value, and a field whose type has no zero
cannot be omitted:

```odin
Vector3 :: struct {
	x, y, z: f32,
}
v: Vector3;
v = Vector3{};           // zero value
v = Vector3{1, 4, 9};
v = Vector3{1, y = 4};   // positional first, then named; `z` zero-fills
```

A named initializer list can supply a subset of fields. Field order does not matter. Omitted fields use their zero value:

```odin
v := Vector3{z=1, y=2};
assert(v.x == 0);
assert(v.y == 2);
assert(v.z == 1);
```

Elements evaluate **in source order**, whatever field each one names, and are
then placed into field-order storage.

Structs can be nested by defining a field as a struct.

```odin
Foo :: struct {
	a, b, c: int,
	
	bar_1: struct {
		x, y, z: int,
	},

	bar_2: struct {
		x, y, z: int,
	},

	_: struct {
		x, y, z: int,
	},
}
```

#### Struct layout attributes

Structs can be annotated with different memory layout and alignment requirements:

```odin
struct @(align=4)  {...} // require four-byte alignment
struct @(packed)    {...} // remove padding between fields
```

These use the same attribute syntax as declarations and statements. Foreign layout uses the target ABI rules, equality optimizations require compiler proof, and validated construction uses an ordinary named procedure.

### Promoted struct fields

A struct field declared with `using` promotes that field's members for selector lookup on the containing value.

```odin
Vector3 :: struct{x, y, z: f32};
Quaternion_F32 :: struct{x, y, z, w: f32}; // ordinary library-defined type
Entity :: struct {
	position: Vector3,
	orientation: Quaternion_F32, // library-defined type
}
```

Promoting `position` makes its fields appear as selectors on `Entity`:

```odin
Entity :: struct {
	using position: Vector3,
	orientation: Quaternion_F32, // library-defined type
}
foo :: proc(entity: ^Entity) {
	fmt.println(entity.x, entity.y, entity.z);
}
```

Promoted names are only member-lookup shorthand. An explicitly declared field on the outer struct wins over a promoted name; otherwise two promoted fields supplying the same name make that selector ambiguous. A `using` field does not make the containing struct a subtype of the field type and does not create an implicit conversion. Passing the embedded value requires explicit selection, such as `consume(value.position)`.

### Unions

A union is a discriminated union, also known as a tagged union or sum type.
Every variant is **named**, and a variant may carry a payload or carry nothing.

```odin
Value :: union {
	flag:   bool,
	number: i32,
	real:   f32,
	text:   string,
	absent:            // payloadless: the colon is written, the type is not
}

v: Value = .text("Hello");
```

The colon is mandatory. Writing a bare type is not a union variant: the name is
the variant's identity, so two variants may carry the same payload type and
remain distinct.

```odin
Pair :: union { left: i32, right: i32 }   // two arms, one payload type
```

A variant's identity is its **declaration index**, never its payload type. That
is what makes `Result(int, int)` an ordinary union rather than a contradiction,
and what a `switch` compares against.

#### Constructing a variant

`.name(payload)` builds a variant where the union type is known from context;
`U.name(payload)` names the union explicitly. A payloadless variant is written
without the call: `.name`, or `U.name`.

```odin
v = .number(7);
v = Value.number(7);
v = .absent;
```

Record-field initialization rules apply to the payload: a place argument clones
it and must be copyable; a temporary or `move(x)` transfers it.

#### Inspecting a union

A union is inspected with a `switch`, whose cases are variant names. There is no
extraction operator: `v.(T)` and `v.as(T)` belong to
[`any_view`](#any_view-type), where the set of possible types is genuinely open.

```odin
switch (p in v) {
case .text:
	// `p` is a new binding whose static type is the variant's payload type.
	static_assert(type_of(p) == string);
case .flag:
	static_assert(type_of(p) == bool);
case .number, .real:
	// Several variants cannot choose one payload type, so the binding keeps
	// the union type.
	static_assert(type_of(p) == Value);
case .absent:
	// A payloadless variant binds `Unit`, so every case binds something.
	static_assert(type_of(p) == Unit);
}
```

The switch reads the union's tag. `type_of(v)` remains `Value` everywhere, while
`type_of(p)` reflects the case binding's static narrowing.

A switch with a case for every variant is **exhaustive**, and no path reaches
the end of the statement. That is what lets an exhaustive switch be the last
statement of a value-returning procedure. A switch that omits a variant and has
no default case is rejected, and names the variants it did not cover. There is
no nil case, because a union has no nil state.

Writing `_` as the binding name acquires no binding.

#### Switch ownership

A switch over a **place** borrows it: the binding is immutable and non-owning,
and the place keeps its value.

A switch over a **temporary** — or over `move(subject)` — consumes it. The
active payload transfers into the case's own binding, which is an ordinary
managed local from there on: it can be moved out, and it drops exactly once on
every exit of its case. A case with no binding owns the whole union instead.

#### Zero values and `@(zero=)`

A union has **no zero value** unless it designates one, because there is no
variant to start at and no nil state to fall back on.

`@(zero=name)` designates one. It is valid only for the *first* declared
variant, and that variant's payload must itself be all-zero, so the union's zero
stays the all-zero representation every other zero is.

```odin
Maybe :: union @(zero=none) { none:, some: int }
m: Maybe;              // accepted: the zero is `.none`

Choice :: union { a: i32, b: bool }
c: Choice;             // rejected: `Choice` has no zero value
d: Choice = ---;       // accepted: storage, with no value in it yet
```

The property propagates: a struct, a non-empty fixed array, or a distinct type
that reaches a no-zero type has no zero either. An empty array holds no element
and keeps its own. See [Zero values](#zero-values) for the operations that
manufacture one.

#### The failure protocol and `@(failure=)`

`@(failure=name)` designates one variant of a union of **exactly two** as the
failure one. It is what [`or_else`](#or_else-expression) and
[`or_return`](#or_return-operator) recognise: they read the *shape*, never a
privileged type name, so a user-declared union participates on equal terms with
`Option` and `Result`.

```odin
Parsed :: union @(failure=bad) { value: int, bad: Parse_Error }
```

#### Required results

A union may carry [`@(require_results)`](#require_results). The attribute
reference defines its type-level handling requirement and its propagation
through aggregates and calls.

#### Representation

A union's storage is its payload region, then the tag, then whatever padding the
alignment asks for. The tag is the narrowest unsigned integer that indexes
`0 ..< variant_count`: 256 variants still fit in one byte and 257 need two. The
first declared variant has tag 0, and there is no nil tag. A union with no
variants keeps one byte. A tag wider than every payload raises the union's
alignment, as any other member would.

#### Union alignment

Unions have the `align` attribute, like structures:

```odin
Aligned :: union @(align=4) { number: i32, byte_value: u8 }
```

### Enumerations

An enumeration defines a distinct type and a fixed set of named values. Values have declaration order:

```odin
Direction :: enum{North, East, South, West};
```

The following holds:

```odin
int(Direction.North) == 0
int(Direction.East)  == 1
int(Direction.South) == 2
int(Direction.West)  == 3
```

Enum fields can be assigned an explicit value:

```odin
Foo :: enum {
	A,
	B = 4, // Holes are valid
	C = 7,
	D = 1337,
}
```

If an enumeration requires a specific size, a backing integer type can be specified. By default, int is used as the backing type for an enumeration.

```odin
Foo :: enum u8 {A, B, C}; // Foo is 8 bits
```

Enum members are named constants, not numbers with a name: they may have holes, and arithmetic on them is not defined. See [Arithmetic operators](#arithmetic-operators). Convert to the backing integer type when a numeric value is wanted, and use the library `Bit_Set(Enum)` for flag sets.

#### Non-member values

**Conversion between an enum and its backing integer type is unchecked in both
directions.** `Foo(n)` reinterprets `n` as a `Foo` and `int(f)` reads the
representation back; neither tests membership, and this holds for a constant
operand as much as a runtime one. An enum type therefore ranges over every value its backing type can hold, and a value that names no declared member is an ordinary, representable value of that type — not undefined behavior.

```odin
Foo :: enum { A, B, C }

n := 200;
f := Foo(n);          // no check: `f` is a `Foo` naming no member
assert(int(f) == 200);
```

This is deliberate: enum values arrive from foreign calls, files, and wire
formats, and a conversion that trapped would make every such boundary a fallible operation. The cost is that "covers every member" is not "covers every value", which is what the [exhaustive switch](#exhaustive-switch) rule below is stated against. Code converting an untrusted integer should validate it — by comparing against the members, or by switching with an explicit `case:` — before treating it as a member.

Compiler-provided enums such as `LOKE_ARCH` spell their members in `Capitalized_Snake_Case`, and the core library follows suit. The convention is not compiler-enforced, but the spelling of a compiler-provided member is normative.

#### Implicit selector expression

An implicit selector omits the enumeration type when context supplies that type. It has this form:

.member_name

For example:

```odin
Foo :: enum{A, B, C};
f: Foo;
f = Foo.A;
f = .A;

switch (f) {
case .A:
	fmt.println("foo");
case .B:
	fmt.println("bar");
case .C:
	fmt.println("baz");
}
```

#### Iterating an enumeration

Every enum type has a compiler-provided `values()`, a constant fixed array of its declared members in declaration order. This supports tasks such as printing every member or populating a library-defined `Enum_Array(Enum, T)`.

`values()` is the only way to iterate an enumeration. A *type* is never accepted in a `foreach` header — `foreach (x in Direction)`, `foreach (x in int)`, and `foreach (x in Some_Struct)` are all errors — so iteration always runs over a value through the ordinary [iteration protocol](#iteration-protocol), and every [adapter](#iteration-adapters) applies to an enum as it does to any other array.

```odin
Direction :: enum{North, East, South, West};

foreach (direction, index in Direction.values().indexed()) {
	fmt.println(index, direction);
	// 0 North
	// 1 East
	// 2 South
	// 3 West
}
```

`values()` is an ordinary constant expression, not a loop form: the array is a compile-time constant of type `[N]Direction`, so it also serves a static `foreach`, a `$` argument, `len`, and indexing. Its constness is what keeps this out of the iteration protocol entirely — there is nothing for the compiler to special-case in a `foreach` header.

## Procedure and meta types

### Procedure type

A procedure type is a code pointer. Its zero value is `nil`.

Examples:

```odin
proc(x: int) -> bool
proc(c: proc(x: int) -> bool) -> (i32, f32);
```

A variable can have a procedure type:

```odin
Callback :: proc() -> int;
a: Callback = nil;
assert(a == nil);
a = proc() -> int { return 0; };
fmt.println(a()); // 0
a = proc() -> int { return 100; };
fmt.println(a()); // 100
```

#### Calling conventions

Loke supports the following calling-convention names:

- `loke` — the default convention for a Loke procedure, using the target-specific parameter classification described under [Parameter semantics and ABI lowering](#parameter-semantics-and-abi-lowering). It passes only the arguments required by the source-level procedure type and ABI lowering; there is no implicit environment pointer.
- `c` — the target C ABI's default calling convention.
- `stdcall` — the Microsoft stdcall convention on targets that support it.

Compiler- or target-specific conventions use namespaced extension strings; the portable set is limited to conventions with a stable cross-toolchain meaning.

The default calling convention is `loke`, unless a declaration is within a foreign block, where it is `c`.

A procedure type with a different calling convention can be declared like the following:

```odin
proc "c" (n: i32, data: rawptr)
```

Procedure types are compatible only when the following match:

- calling convention;
- parameter and result types;
- parameter modes and variadic shape;
- type-level parameter effects, including `@(allocator_reset)` and
  [`@(escape=<level>)`](#escapelevel).

A reset-capable procedure cannot be stored in a procedure value whose type hides
that effect. The escape level likewise determines what an indirect call may keep
of each argument.

Visibility and deprecation are declaration-only attributes and do not participate
in type compatibility. Omitted-argument defaults are also declaration metadata;
every call through a procedure value supplies the full parameter list.

Result-provenance summaries are also declaration metadata rather than part of a
procedure type. A direct call can use the summary, but converting a declaration
to a procedure value erases it and activates the conservative indirect-call
rule under [Temporaries and procedure boundaries](#temporaries-and-procedure-boundaries).

### `type` and `typeid`

`type` is a compile-time-only type whose values are Loke types. It is used for
generic type parameters, compile-time reflection, and procedures that compute a
type:

```odin
Index_Type :: proc($Count: uint) -> type {
	when (Count <= 256) {
		return u8;
	} else when (Count <= 65536) {
		return u16;
	} else {
		return u32;
	}
}

Index :: Index_Type(1000);
```

A `type` value has no runtime representation or zero value. It may be bound by a
constant, used as a `$` parameter, or returned by a procedure whose every call
is evaluated at compile time. It cannot be the type of a variable, ordinary
non-`$` parameter, record field, container element, foreign declaration, or
runtime procedure value; compiler-defined reflection descriptors are the only
records allowed to carry it internally. A procedure whose signature contains `type` or a compile-time reflection descriptor is itself compile-time-only and cannot be exported or stored in a procedure value.

Two `type` values support `==` and `!=` during compilation; equality means the
same Loke type identity after aliases are resolved. They have no ordering and
cannot be elements or keys of runtime or materialized containers.

`typeid` is an ordinary runtime scalar holding the unique identifier of one concrete runtime type. It is not usable as a type and does not make a generic procedure, keeping runtime reflection from becoming a second spelling of specialization.

`typeid` is used by `any_view`, [`dyn Interface`](#borrowed-dynamic-interface-values),
and runtime reflection:

```odin
a := typeid_of(bool);
i: int = 123;
b := typeid_of(type_of(i));
```

A typeid can be mapped to relevant type information which can be used in applications such as printing types and editing data:

```odin
import "base:runtime";

main :: proc() {
	u := u8(123);
	id := typeid_of(type_of(u));
	info: ^runtime.Type_Info;
info = type_info_of(id);
}
```

`typeid_of(T)` maps a compile-time `type` value to its runtime `typeid` constant.
For a union expression, `type_of(value)` denotes the union's static type and
`typeid_of(type_of(value))` therefore identifies the union itself. A union's
active variant is not a runtime type: variants are named, two of them may share
a payload type, and the way to ask which one is active is a
[`switch`](#inspecting-a-union).
`type_info_of(id)` accepts a runtime `typeid` and returns runtime metadata. It
does not recover a compile-time `type`, because runtime information cannot flow
back into specialization. A `typeid` is an ordinary scalar and can be forged, so
the lookup is checked: the nil `typeid`, and any id this program has no entry
for, produce a nil result.

The metadata layouts are public and belong to `base:runtime`, which a program
must import to name them:

```odin
Type_Kind :: enum u8 {
	Invalid, Void, Bool, Signed_Int, Unsigned_Int, Float, Rune,
	Raw_Pointer, Pointer, Multi_Pointer, Array, Slice, Dynamic_Array, Map,
	Struct, Enum, Union, Proc, String, String_View, CString_View,
	Typeid, Any_View, Dyn, Distinct, Simd, Allocator, Allocator_Error,
}

Member_Kind :: enum u8 { Field, Enum_Value, Union_Variant, Parameter, Result }

Member_Info :: struct {
	kind:       Member_Kind,
	name:       string_view,
	type:       typeid,
	offset:     int,
	value_low:  u64,
	value_high: u64,
}

Type_Info :: struct {
	id:      typeid,
	kind:    Type_Kind,
	name:    string_view,
	size:    int,
	align:   int,
	bits:    int,
	signed:  bool,
	element: typeid,
	key:     typeid,
	count:   int,
	members: []Member_Info,
}
```

Every view and slice above points at shared static storage, so `type_info_of`
hands back a read-only `^runtime.Type_Info` and a `^Type_Info` owns
nothing and needs no cleanup. Aggregate member tables expose public fields only,
procedure entries keep written parameter and result order, union variants keep
declaration order, and unused scalar, relation, and member fields are zero. An
enum member's raw value is carried in `value_low`/`value_high` so that a signed
or unsigned 128-bit value survives; the owning type's `bits` and `signed` say how
to read them. Adding a field or an enum member to these records is a runtime ABI
change, because generated metadata tables are written against exactly this field
order.

### Compile-time reflection

The compiler exposes two typed, immutable reflection descriptors, `meta.Field`
and `meta.Enum_Value`. Their names are exported by the compiler-defined
`base:meta` package and they exist only during compilation.

`fields_of(T)` and `enum_values_of(T)` return compile-time fixed arrays of the
corresponding descriptor type. Descriptors are opaque and cannot be forged. Names
are constant `string_view` values, and a descriptor's `.type` member is a
compile-time `type` value. A `meta.Field` also carries the field's physical
declaration index.

Both preserve source declaration order, after conditional `when` selection.
Reflection observes only declarations visible from its lookup package. Thus
`fields_of(T)` contains every selected field when the lookup package declares
`T`, but only public fields when reflecting from another package. In a generic
body the reflection lookup package is the generic declaration's definition
package, so an instantiation has the same reflected shape in every caller.

Reflection is limited to these two descriptors. Adding a further descriptor in a
later version is a backward-compatible change; removing one is not.

A `meta.Field` bound by static expansion provides compiler-defined operations
whose result follows that particular field's type:

```odin
visit_fields :: proc(value: ^$T, visitor: inout $Visitor) {
	foreach ($field in fields_of(T)) {
		visitor.visit(field.pointer(value));
	}
}
```

`field.get(value)` accepts a pointer of either capability, reads the selected
field, and has type `field.type` after expansion. `field.pointer(value)` also
accepts either and projects the capability through: a `^mut T` subject yields
`^mut field.type`, a `^T` subject yields `^field.type`. Both take a pointer so that one expansion body can use
either without restructuring its parameter. The  normal visibility, packed-field, borrow, copy, and mutation rules still apply;
`pointer` is rejected for a packed field. There is no string-based field lookup.

Reflection values may be inspected, compared for identity, passed to `$`
parameters, and iterated by static `foreach`. They cannot be materialized into
runtime storage. Runtime tools instead use the less powerful
`runtime.Type_Info` reached through `type_info_of`.

### any_view type

`any_view` is a non-owning type-erased value, used for formatting, logging, reflection, and other call-oriented APIs. Internally it is a pointer plus a `typeid`, and creating one borrows its source. Its zero value is nil.

It may be a local variable or parameter, but it cannot be a result type, global, struct or union field, container element, or captured/stored value. The ordinary local borrow checker ensures a local `any_view` does not outlive or overlap an invalidating operation on its source. A temporary converted for a call remains valid through that complete call expression.

**A variadic `..any_view` parameter is the only exception to the container rule.** Formatting procedures such as `fmt.println(a, b, c)` use this form. The caller converts each argument to `any_view`. It materializes a temporary `[]any_view` for the duration of the call.

```odin
println :: proc(args: ..any_view) { ... }
```

The slice and its elements borrow the caller's temporary arguments and live only for the complete call expression. The called procedure can read, index, iterate, and forward the slice to another `..any_view` parameter, but must not store the slice or an element past the call.

No other operation produces `[]any_view`; there is no `any_view` array, dynamic array, or slice local, so this is a calling form, not a container type. [`@(c_vararg)`](#c_vararg) is separate signature notation, passing the original concrete arguments with the C default argument promotions.

Conversion from a concrete value to `any_view` is implicit when an `any_view` parameter or local destination is expected, and it never allocates. It supports runtime checked extractions and type switches.

```odin
print_value :: proc(value: any_view) { ... }
print_value(42); // the temporary lives through the call
```

`value.(T)` extracts a `T` and panics on a type mismatch. `value.as(T)` returns
`Option(T)`, which can be inspected without trapping:

```odin
print_text :: proc(value: any_view) {
	switch (text in value.as(string)) {
	case .some: fmt.println(text);
	case .none: fmt.println("not a string");
	}
}
```

`any_view` has no owning counterpart; its type erasure is call-scoped, so a procedure may inspect the erased value but not retain it. To retain a value of one of several types, use a union; for open borrowed runtime behavior, use `dyn Interface` or a record of callbacks; to retain something arbitrary, own it concretely and pass an `any_view` or `dyn` view at the point of use.

## Methods and abstractions

### General rules

User-defined types can be as convenient as built-in ones: a vector supports arithmetic, a matrix indexing, a range iteration, a resource-owning type automatic cleanup.

User-defined syntax does not change parsing. Operators keep their built-in precedence, associativity, and evaluation order; an overload supplies behavior for an existing operation and cannot invent new syntax.

### Methods and implementation blocks

An `impl` block associates procedures and constants with a type. A first parameter named `self` is the receiver, its type written explicitly or inferred from the `impl` type.

```odin
Vector2 :: struct {
	x, y: f32,
}

impl Vector2 {
	zero :: Vector2{0, 0};

	length_squared :: proc(self) -> f32 {
		return self.x*self.x + self.y*self.y;
	}

	scale :: proc(self: inout Vector2, factor: f32) {
		self.x *= factor;
		self.y *= factor;
	}
}

v := Vector2{3, 4};
length2 := v.length_squared();
v.scale(2);
origin := Vector2.zero;
```

Method-call syntax is uniform procedure-call syntax:

```odin
v.length_squared();
// equivalent to
Vector2.length_squared(v);
```

A plain `self` is an immutable borrow, `self: inout Type` a mutable borrow, and `self: move Type` consumes the receiver. Members without `self` are accessed through the type name.

The same block form adds methods or operators to a type from another package:

```odin
impl vendor.Vector2 {
	to_string :: proc(self, allocator: mem.Allocator = mem.default_allocator()) -> string {
		return fmt.to_string(allocator, "(", self.x, ", ", self.y, ")");
	}
}
```

**A block is inherent or an extension by where its subject is declared, not by a
keyword.** A block in the subject's own package contributes *inherent* members to
the type itself; a block anywhere else is an *extension*, confined to the package
that writes it. A subject no package declares — a built-in type such as `[]int`,
or a foreign one — is therefore always extended. Nothing is written either way,
and the qualified subject in `impl vendor.Vector2` already shows which case it is.

The distinction is real and every rule below turns on it; it just isn't a second
syntax.

A procedure returning an owning `string` names the allocator it builds with, by
the [ordinary parameter convention](#default-values). There is no ambient
temporary allocator to fall back on; see [Allocators](#allocators).

An extension participates in lookup only inside the package that declares it, and follows ordinary declaration visibility (package-private by default, `@(public)`/`@(private)` to opt in or out).

Inside that package, `v.to_string()` and `vendor.Vector2.to_string(v)` both name the extension. A public extension procedure is also exported under its own package, so an importer may call `format.to_string(v)`; importing `format` does not make `v.to_string()` valid in the importer or add its operators to lookup, so an unused import cannot change an existing expression.

The exported name uses the ordinary package namespace, so two public extension procedures in one package need distinct names. To offer one overloaded export, give private extensions distinct names and assemble public wrappers into a procedure group. An inherent `impl` member gets no package-level alias: outside its package it is reached through its owning type, `vendor.Vector2.length_squared(v)`.

To get method syntax for a foreign extension, declare a small local forwarding extension — an explicit opt-in, with ordinary ambiguity diagnostics.

Generic declarations use **definition-site lookup**: substituting concrete arguments may reveal inherent operations of those types but does not add the caller's extensions to the candidate set. So a generic instantiation means the same in every caller, and a caller-local extension cannot make a requirement appear satisfied.

Field lookup takes priority over method-call sugar. Otherwise methods use normal overload resolution and can be collected into procedure groups.

#### Receiver forms

There are three receiver modes:

| Receiver | Meaning |
| --- | --- |
| `self` | Immutable borrow of the value |
| `self: inout Type` | Exclusive mutable borrow of the caller's variable |
| `self: move Type` | Consumes the receiver |

The first two are reached through `value.method()`, with the `inout` marker supplied implicitly: that borrow ends with the call and leaves the source usable. A consuming method is reached through `move(value).method()`. The marker is written for the same reason it is written at any other call site (see [Parameter semantics](#parameter-semantics-and-abi-lowering)) — the call leaves the source dead, and a reader must see where a value is given away. Writing `move(...)` also selects: it reaches only `move self` overloads, and a bare receiver reaches only the other two.

A consuming method cannot be called on file-scope, `static`, or `thread_local` storage, since it would leave that storage dead; use `exchange` to install a replacement first. Nor can it consume a field or element, for the same reason `move` cannot. The immutable receiver may be written `self: Type` when clearer; it is the same mode.

```odin
counter.bump();          // `inout self`, marker implicit
total := move(counter).consume();  // `move self`, transfer written
```

A first parameter declared `self: ^Type` is **not** a receiver: it is an ordinary pointer parameter with no method-call sugar, called as `Type.method(pointer)`. Mutating methods use `inout self`, not pointer receivers.

#### Generic types

An `impl` block may name a generic type by writing its shape, binding parameters with `$` as a [specialized](#specialization) procedure parameter does. The bound names are in scope throughout the block:

```odin
Table :: struct($Key, $Value: type) {
	count:     int,
	allocator: mem.Allocator,
	slots:     []mut Table_Slot(Key, Value),
}

impl Table($Key, $Value) {
	len :: proc(self) -> int {
		return self.count;
	}

	find :: proc(self, key: Key) -> Option(Value) {
		...
	}

	insert :: proc(self: inout Table(Key, Value), key: Key, value: Value) {
		...
	}
}

table: Table(string, int) = {};
table.insert("a", 1);
switch (value in table.find("a")) {
case .some: assert(value == 1);
case .none:
}
```

Where the receiver's type is written out — `inout` and `move` receivers, and every non-receiver mention — the bound names are used without `$`, which marks a binding site, not a use.

A block may target one specialization, `impl Table(string, int) { ... }`; when both are visible the more specialized wins by tie-breaker 4 of [overload resolution](#operator-lookup-and-overload-resolution). Constraints use a `where` clause on the procedure, not the block. This is what lets a generic container satisfy an [interface](#interfaces-as-reusable-constraints), whose requirements use method syntax.

### Operator declarations

An operator implementation is an ordinary named procedure marked `operator(symbol)`. The name allows direct calls, function values, and explicit disambiguation.

```odin
impl Vector2 {
	add :: operator(+) proc(left, right: Vector2) -> Vector2 {
		return {left.x + right.x, left.y + right.y};
	}

	negate :: operator(-) proc(value: Vector2) -> Vector2 {
		return {-value.x, -value.y};
	}

	equal :: operator(==) proc(left, right: Vector2) -> bool {
		return left.x == right.x && left.y == right.y;
	}
}

a := Vector2{1, 2};
b := Vector2{3, 4};
c := a + b;
d := -c;

// The named form is always available.
e := Vector2.add(a, b);
```

Operands and the return type may have different types:

```odin
impl Matrix4 {
	transform_point :: operator(*) proc(matrix: Matrix4, point: Vector3) -> Vector3 {
		...
	}
}
```

Operator declarations may be grouped and overloaded:

```odin
add :: operator(+) proc{
	add_vector2,
	add_vector3,
	add_matrix,
};
```

The following may be overloaded:

| Category | Operators |
| --- | --- |
| Unary | `+`, `-`, `!`, `~` |
| Arithmetic | `+`, `-`, `*`, `/`, `%` |
| Bitwise and shifts | `|`, `~`, `&`, `&~`, `<<`, `>>` |
| Comparison | `==`, `!=`, `<`, `<=`, `>`, `>=` |
| Membership | `in` |
| Compound assignment | `+=`, `-=`, `*=`, `/=`, `%=`, `|=`, `~=`, `&=`, `&~=`, `<<=`, `>>=` |
| Structural syntax | `[]`, `[]=`, `[:]` |

`!=` falls back to `!(left == right)` when `==` exists and no more specific `!=` overload does. A compound assignment falls back to the binary operator plus assignment; a direct compound overload can avoid a temporary or allocation:

```odin
impl Big_Int {
	add_assign :: operator(+=) proc(left: inout Big_Int, right: Big_Int) {
		left.add_in_place(right);
	}
}
```

Assignment (`=`), declaration (`:=`), member access (`.`), address-of, dereference, `move`, and `drop` are not overloadable; they are tied to storage and lifetime rules, and user value behavior comes from the lifecycle hooks below. `&&`, `||`, `or_else`, and the conditional expression control operand evaluation and are not overloadable.

### Operator lookup and overload resolution

Operator lookup considers built-in operations, inherent implementations, and extension implementations in the current package. Operators may be defined for any operand types, including built-in types and types from other packages; imported extension packages stay reachable through their qualified names but do not alter operator lookup. Lexical scope is considered before type ranking, so a local operator set can shadow an outer one.

**Built-in operations cannot be shadowed.** When every operand is a built-in type and the language defines that operator on those operands, the built-in operation always wins: `a + b` on two `int`s is integer addition everywhere. Where no built-in operation exists (`string + []u8`), there is nothing to shadow and an ordinary overload is found normally.

A `distinct` type is not a built-in type for this rule, even when its underlying type is: `Meters :: distinct f64` is a user type with ordinary operator overloads. (It *is* grouped with built-ins in stage 1 of [Resolving `T(...)`](#resolving-t), for the separate reason given there.)

```odin
Meters :: distinct f64;

impl Meters {
	add :: operator(+) proc(left, right: Meters) -> Meters { ... }
}
```

Candidates are ranked with the same algorithm as named-procedure overloads. Candidate formation first rejects an arity mismatch, an incompatible parameter mode, an unsatisfied constraint, or a result incompatible with a known destination type. Each remaining candidate gets one conversion rank per argument:

0. Exact type and parameter-mode match.
1. Borrow, dereference, or mutable-to-read-only adjustment that creates no value.
2. Contextual conversion of a compatible unfixed constant preserving its kind (integer→integer, floating→floating, boolean→`bool`, rune→rune, string→string).
3. Any other built-in implicit conversion, including unfixed integer constant → floating type.
4. A user [`@(implicit)`](#implicit-conversion-from-constants) conversion. Reachable only for an unfixed-constant argument, so it applies at most once and cannot chain.

Rank 4 sits below every built-in conversion so a constant prefers a built-in destination: for `foo :: proc{foo_f64, foo_complex}`, `foo(2.0)` selects `foo_f64` at rank 2, not `Complex_F64` at rank 4. The default type of an unfixed constant does not participate in ranking: `foo(7)` picks an integer over a floating overload, but `i8` vs `int` overloads (or `f32` vs `f64` for `7.0`) remain ambiguous.

The ranks form a vector; they are not summed and argument order does not break ties. A is better than B when A is no worse for every argument and strictly better for at least one. Crossed vectors like `(0, 3)` and `(3, 0)` are intentionally ambiguous.

When conversion vectors are identical, tie-breakers apply in order:

1. A fixed-arity candidate beats a variadic one.
2. A candidate needing fewer omitted defaults wins.
3. A non-parametric candidate beats a parametric one.
4. Between parametric candidates, a structural specialization beats an unspecialized parameter (`Table(string, int)` beats `Table($K, $V)`); if neither is more specialized, the call is ambiguous.

**Constraints decide whether a candidate is viable, never which viable candidate wins.** `interface` applications and `where` clauses are filters; only structure orders what survives. Two candidates of identical shape differing only in constraint strength are an ambiguity error, resolved by naming the intended member or dispatching with `when`. Non-overlapping `where` filters are not ambiguous, since only one candidate is viable.

An exact generic match beats a concrete overload that needs conversion unless the tie-breakers are reached with identical vectors. Compiler-generated structural equality and comparison are fallbacks that a viable explicit overload suppresses.

Return type may filter candidates against a known destination type, but procedures cannot be overloaded by return type alone. If more than one maximal candidate remains, the call is a compile-time ambiguity, and the diagnostic must list every maximal candidate, its conversion vector, and the tie-breaker at which selection failed.

### Indexing and slicing

`operator([])` defines indexed reads. An overload returning `inout T` produces an assignable location; `operator([]=)` handles computed or proxy assignment when no location can be returned.

```odin
Grid :: struct {
	width, height: int,
	cells: [dynamic]f32,
}

impl Grid {
	index :: operator([]) proc(self: Grid, x, y: int) -> f32 {
		return self.cells[y*self.width + x];
	}

	index_mut :: operator([]) proc(self: inout Grid, x, y: int) -> inout f32 {
		return inout self.cells[y*self.width + x];
	}
}

grid[3, 2] = 1.0;
value := grid[3, 2];
```

When both a value and an `inout` overload are visible, position selects between them before ranking:

1. In a **place position** — the target of an assignment or compound assignment, the operand of `&`, or an `inout` argument — the `inout` overload is required; if none exists, `operator([]=)` is used; if neither, the expression is not assignable.
2. Everywhere else the value overload is preferred, even for a mutable receiver.

The same rule applies to built-in indexing of maps and dynamic arrays. Place position selects *which operation runs*, not whether a missing element is created — that is the container's property: a dynamic array traps on an out-of-range index, while a map inserts a zero element for an absent key. `&` is a place position but never creates an element; a container wanting a non-inserting address supplies a method, as the map does with [`m.find(key)`](#maps).

`operator([]=)` is for containers with no location to hand out — computed, compressed, proxied, or validating storage. It takes the receiver, the index list, and the new value last, and returns nothing:

```odin
Sparse_Grid :: struct {
	entries: map[[2]int]f32,
}

impl Sparse_Grid {
	get :: operator([]) proc(self: Sparse_Grid, x, y: int) -> f32 {
		return self.entries.lookup_value([2]int{x, y}) or_else 0;
	}

	// No `inout` overload exists: a zero is not stored, so there is no slot
	// whose address could be returned.
	set :: operator([]=) proc(self: inout Sparse_Grid, x, y: int, value: f32) {
		if (value == 0) {
			self.entries.remove({x, y});
		} else {
			self.entries[{x, y}] = value;
		}
	}
}

grid: Sparse_Grid = {};
grid[3, 2] = 1.0;   // calls `set`
grid[3, 2] = 0;     // calls `set`, which removes the entry
v := grid[9, 9];    // calls `get`, yielding 0
p := &grid[3, 2];   // ERROR: no `inout` overload; `[]=` cannot supply an address
```

A compound assignment on such a type reads through `operator([])` and writes back through `operator([]=)`, per the [fallback rule](#operator-declarations).

`operator([:])` defines slicing. It returns either an owning value or a borrow derived from the receiver, treated as a borrow under [Borrows and lifetimes](#borrows-and-lifetimes). A `[]mut T` result requires an `inout` receiver; an immutable receiver returns only `[]T`.

Values are not made callable through operator overloading; a callable object exposes an ordinary method like `call` or `evaluate`. Bounds checking is the overload's responsibility; libraries may provide checked and unchecked types, and tooling may warn about unchecked ones without rejecting them.

### Iteration protocol

`foreach` uses the standard [`Iterable`](#standard-interface-catalogue) and
`Iterator` interfaces. An iterable type provides:

- an `Element` type;
- an `Iterator` type;
- `iter(self) -> Iterator`;
- `next(self: inout Iterator) -> Option(Element)` on its iterator.

Each call to `next` answers `.some(element)`, or `.none` to end the loop. See
[Typed fallibility](#typed-fallibility).

The free alias `iter(source)` selects the same method as `source.iter()`. A
visible [extension block](#methods-and-implementation-blocks) can make a foreign
type iterable within the package that declares the extension.

Ranges, strings, string views, fixed arrays, slices, dynamic arrays, and maps
all follow this protocol. The compiler supplies their associated types, `iter`
method, and opaque iterator type. An enum type itself is not iterable; use
[`Enum.values()`](#iterating-an-enumeration) to visit its members.

```odin
Countdown :: struct {
	start: int,
}

Countdown_Iterator :: struct {
	current: int,
}

impl Countdown {
	Element  :: int;
	Iterator :: Countdown_Iterator;

	iter :: proc(self) -> Countdown_Iterator {
		return {self.start};
	}
}

impl Countdown_Iterator {
	next :: proc(self: inout Countdown_Iterator) -> Option(int) {
		if (self.current <= 0) {
			return .none;
		}
		value := self.current;
		self.current -= 1;
		return .some(value);
	}
}

foreach (value in Countdown{3}) {
	fmt.println(value);
}
```

Generic code refers to the yielded type as `S.Element`. An iterator over a
collection borrows that collection, so the collection cannot be mutated while
the iterator is in use; the normal [borrow rules](#borrows-and-lifetimes) apply.

#### Element bindings

One `foreach` binding receives the whole `Element`. Two or more bindings
destructure a record element by declaration order:

```odin
foreach (entry in table) {
	fmt.println(entry.key, entry.value);
}

foreach (key, value in table) {   // `Element` is a two-field record
	fmt.println(key, value);
}
```

For destructuring, the element must be a record with exactly the same number of
directly declared, visible fields. Bindings are flat and cannot nest; promoted
fields are not flattened. Any binding may be `_`. This is the language's only
destructuring form, and it appears only in a `foreach` header. Value bindings are
immutable locals.

The iterator still produces the whole element when fields are ignored.
Destructuring moves its fields into the bindings without another copy and
disposes of anything left over normally.

A value loop never invents an index, key, or byte offset. To receive that
information, use an iterable or adapter whose `Element` contains it.

#### Iteration adapters

Every iterable has one default `Element` and `Iterator`. An adapter selects a
different traversal and has its own pair. The compiler provides these adapters
for every iterable:

| Adapter | `Element` |
| --- | --- |
| `source.indexed()` | `struct{value: Element, index: int}`, zero-based |
| `source.reversed()` | the source `Element`, in reverse order |

`indexed()` starts at zero and advances only after `next` succeeds. It numbers
the traversal before it, so it may appear only once and must be last:
`source.reversed().indexed()` numbers the reversed traversal from zero.

`reversed()` requires [`Reverse_Iterable`](#standard-interface-catalogue) and a
receiver method named `iter_reverse`. A forward-only iterable is rejected;
reversal never buffers or allocates. `iter_reverse` returns the type's declared
`Iterator`. A reverse traversal that needs another iterator representation must
instead be a separate adapter with its own `Element` and `Iterator`.

Adapters preserve borrows. Iterating an adapter over a borrowed collection keeps
the same collection borrowed for the whole loop.

In version 1, adapters and the container views below are `foreach` header forms.
They cannot be stored in variables or passed to procedures. Their names are
reserved in a loop header, so `foreach` treats `x.values()` as the container view
even if `x` declares another member with that name. For built-in containers the
compiler may lower the selected traversal directly without creating an iterator
object. A traversal that must be stored or passed is an ordinary user-defined
iterable type.

Built-in containers also provide these non-copying, non-allocating views:

| Adapter | `Element` |
| --- | --- |
| `map.entries()` | `struct{key: K, value: V}` — the map's own `Element` |
| `map.keys()` | `K` |
| `map.values()` | `V` |
| `text.runes()` | `rune` — the string's own `Element` |
| `text.rune_offsets()` | `struct{value: rune, offset: int}` |
| `text.bytes()` | `u8` |

A map's default `Element` is its `{key, value}` entry. A user type gets the same
two-binding syntax by returning any visible two-field record from `next`.

#### By-reference iteration

In version 1, only built-in containers support iteration by reference. Mutable
fixed arrays, mutable slices, dynamic arrays, and map values allow:

```odin
foreach (&value in collection) { ... }
```

These loops project places from the container's storage; they do not call a
`next_ref` protocol. A user collection instead exposes a mutable slice, an
indexed `inout` operation, or a method that performs the traversal.

Place loops may also receive information supplied by the container:

```odin
foreach (&value, index in sequence) { ... }
foreach (key, &value in map) { ... }
```

These fixed forms are separate from `Element` destructuring, and adapters cannot
yield places. A value loop uses `sequence.indexed()` to request an index. If a
value loop tries `foreach (value, index in sequence)` with a non-record element,
the diagnostic points to `indexed()`.

### Compiler semantic hooks

The compiler-recognized semantic surface is a small closed set of explicit roles: `hook(convert)`, `hook(copy)`, and `hook(drop)`. The role, never the declaration name, activates compiler behavior. Hook implementations have fixed signatures, belong to the subject type's own package, and are invoked only through their language operation (`T(value)`, copying, or `drop(value)`), not by calling the implementation declaration directly.

This mechanism is intentionally not a general protocol system. Names such as `hash`, `format`, `iter`, and `next` remain ordinary members selected by their documented structural protocols; named constructors are ordinary procedures. Stable public operations such as `clone` and `try_clone` are compiler-generated wrappers over the copy role. Consequently a name like `init`, `drop`, or `try_clone` never acquires hidden behavior merely by being spelled that way.

### Construction and conversions

Construction is deliberately separate from conversion. Struct literals are the simplest construction; validated or computed construction uses ordinary named procedures:

```odin
impl Vector2 {
	from_components :: proc(x, y: f32) -> Vector2 {
		return {x, y};
	}

	splat :: proc(value: f32) -> Vector2 {
		return {value, value};
	}
}

a := Vector2{1, 2};
b := Vector2.splat(5);
```

`init` has no reserved semantic role. A procedure named `init` is an ordinary named constructor, called as `T.init(...)`; names such as `splat`, `polar`, `parse`, and `open` are preferred when they communicate the construction invariant.

Explicit user-defined conversion is a compiler semantic hook on the target type. The declaration name is descriptive and ordinary; `hook(convert)` supplies the role:

```odin
Meters :: distinct f64;
Kilometers :: distinct f64;

impl Kilometers {
	from_meters :: hook(convert) proc(value: Meters) -> Kilometers {
		return Kilometers(f64(value) / 1000.0);
	}
}

distance_m := Meters(1500);
distance_k := Kilometers(distance_m); // explicit user conversion
```

A conversion hook takes exactly one value, has no receiver, and returns its target type. It must be inherent to the target's package; an extension cannot change conversion meaning from another package. Conversion hooks may overload by source type, but a source/target pair has exactly one hook. A built-in conversion pair cannot also have a hook, so `int(x)` and other built-in conversions never change meaning based on declarations or imports. The hook implementation is reached through `Target(value)`, not called directly by its declaration name.

#### Implicit conversion from constants

Adding `@(implicit)` to a `hook(convert)` declaration lets it apply without being written, **but only when the argument is an unfixed constant**; a runtime value of the same type always requires the explicit form.

The parameter type must be a built-in numeric, boolean, rune, or string type, so an unfixed constant kind can reach it. The constant must convert to that parameter type under the ordinary [unfixed-constant rule](#unfixed-constants). So an unfixed floating constant can reach an `@(implicit)` conversion whose parameter is floating-point, but not one whose parameter is an integer.

```odin
impl Complex_F64 {
	from_components :: proc(real, imaginary: f64) -> Complex_F64 {
		return {real, imaginary};
	}

	@(implicit)
	from_scalar :: hook(convert) proc(value: f64) -> Complex_F64 {
		return {value, 0};
	}
}

z := Complex_F64.from_components(1, 2);
w := z*z + 2.0;              // OK: `2.0` is an unfixed float constant

scale: f64 = read_scale();
bad := z + scale;            // ERROR: no operator `+` for (Complex_F64, f64)
good := z + Complex_F64(scale);
```

Restricting the rule to constants keeps [library numeric types](#library-numeric-types) usable (`z*z + 2.0` means what it looks like) while giving up a general implicit-conversion facility:

- runtime conversions stay explicit and do not depend on declarations in scope;
- chains cannot form, since an unfixed constant takes at most one user conversion;
- narrowing is already caught by the constant-representability rule at compile time.

#### Resolving `T(...)`

`T(value)` means conversion only and takes exactly one plain value argument. The compiler first applies a non-overridable built-in conversion when the source/target pair has one. Otherwise it resolves the target type's inherent `hook(convert)` declarations with the ordinary overload rules. Equal-ranked hooks are ambiguous rather than ordered by declaration.

Zero- and multi-argument type calls are invalid. Construction uses a composite
literal or named constructor instead.

### Lifecycle hooks and resource types

User records get field-wise `try_clone`, `clone`, `move`, and `drop` behavior by default. An `impl` block may replace the implementation of copying or dropping with `hook(copy)` or `hook(drop)`. As with conversion hooks, the declaration's own name is descriptive and has no hidden meaning.

The hook signatures are fixed:

- `hook(drop)`: `proc(self: inout T)`
- `hook(copy)`: `proc(self, allocator: Allocator) -> Result(T, Allocator_Error)`

A custom copy hook must allocate all cloned storage through fallible operations
on the supplied allocator and return any error without publishing a partial
result. Generated field-wise cloning calls `try_clone` recursively for each
owning field. On failure it destroys the partial temporary and returns `.err`
without a partial value.

The compiler generates two public copy operations. Neither name is a hook, and
user code cannot replace either declaration:

| Operation | Signature | Failure behavior |
| --- | --- | --- |
| `try_clone` | `proc(self, allocator: Allocator = mem.default_allocator()) -> Result(T, Allocator_Error)` | Returns `.err`; delegates to `hook(copy)` when present. |
| `clone` | `proc(self, allocator: Allocator = mem.default_allocator()) -> T` | Calls `try_clone` once and invokes the allocator's failure policy on failure. |

Allocator selection follows these rules:

- `value.clone()` uses the program default; `value.clone(allocator)` uses the
  supplied allocator.
- Assignment and copy initialization use the destination's bound allocator.
  If the destination is dead or allocator-unbound, they resolve its declaration
  allocation policy instead.
- A non-allocating copy hook ignores the allocator and returns `.ok`.

Assignment and copy initialization invoke the failure policy only after cloning
fails, without first modifying the destination. Built-in immutable `string`
instead has the shared implicit-copy behavior specified under
[Assignment statements](#assignment-statements); its explicit independent
byte-copy operation is `copy`.

A custom copy hook may panic for ordinary faults but must not invoke an allocator failure policy for its own allocations; recoverable allocation inside the hook uses `try_` operations.

The compiler checks hook signatures, declaration in the owning type's package,
and coherent operation lookup: one copy hook, one drop hook, and one `==`/`hash`
pair per type across packages.

Allocator discipline, valid ownership, and equal values producing equal hashes
are programmer obligations not checked by the compiler. Violations have the
following consequences:

- A copy hook that panics follows ordinary [panic semantics](#panics-and-unwinding).
- Invalid ownership, such as a clone sharing storage it does not own or a drop hook leaving a live alias, causes undefined behavior.
- Breaking the hash laws voids the map's logical guarantees: lookups may miss, iteration may repeat or skip. It does not by itself authorize memory corruption, and an implementation must not treat it as licence for unchecked access.

```odin
// This is the shape `core:fs` uses for its own `File`.
File :: move_only struct {
	handle: int,
	valid:  bool,
}

impl File {
	release :: hook(drop) proc(self: inout File) {
		if (self.valid) {
			close_handle(self.handle);
			self.valid = false;
		}
	}
}
```

`move_only struct` removes both generated copy operations; a record containing a move-only field is also move-only. `move` and `drop` leave lexical sources inert and dead; static-duration storage requires [`exchange`](#exchange) instead. See [Storage modifiers](#storage-modifiers) for operand restrictions. Fields are dropped in reverse declaration order after the containing type's drop hook returns.

A `drop` hook runs **exactly once per completed initialization** that is not transferred or already consumed. The compiler tracks [ownership](#managed-values-and-storage), using runtime state only where control flow requires it, never by testing for zero. Hooks must accept the inert zero value: `{}` and zero-initialized static storage are completed initializations. In `File`, `valid` distinguishes an inert value from a valid zero handle.

Copy assignment of a copyable type has the following order, with self-assignment
handled by the compiler:

1. Evaluate `source.try_clone(destination_allocator)` once.
2. On `.err`, invoke the policy specified under
   [Allocation failure](#allocation-failure), leaving the destination unchanged.
3. On `.ok`, drop the previous destination value and transfer the cloned value
   into the destination.

An explicit call to `try_clone` returns the error and never invokes the policy.

### Standard customization procedures

Receiver-shaped common behavior is defined canonically as methods. The language reserves a closed set of standard free aliases for the immutable operations in this table:

| Free alias | Canonical method and purpose |
| --- | --- |
| `len(value)` | `value.len()` — number of logical elements or bytes |
| `cap(value)` | `value.cap()` — current capacity when meaningful |
| `hash(value, seed)` | `value.hash(seed)` — hashing for maps and sets |
| `format(value, writer, options)` | `value.format(writer, options)` — formatting and printing |
| `compare(left, right)` | `left.compare(right)` — three-way ordering when useful |
| `iter(value)` | `value.iter()` — forward iteration using the associated iterator |
| `iter_reverse(value)` | `value.iter_reverse()` — reverse iteration when supplied |
| `clone(value, allocator := mem.default_allocator())` | `value.clone(allocator)` — explicit ownership-recursive copy |
| `try_clone(value, allocator := mem.default_allocator())` | `value.try_clone(allocator)` — fallible ownership-recursive copy |

**A clone is ownership-recursive, not deep.** It duplicates the storage the
value *owns*, recursing into owning fields and elements. It does not follow a
non-owning pointer, slice, or view, and a component whose own documented copy
semantics share — immutable [`string`](#string-type) and
[`shared(T)`](#shared-ownership) — shares rather than duplicates. So cloning a
`[dynamic]string` produces an independent array of elements that still share
their text, and cloning a record with a `^T` field produces a second record
pointing at the same target. Independence therefore holds exactly as far as
ownership does; `string`'s separate byte-copying operation is
[`copy`](#string-type-conversions), spelled differently for this reason. This is
the same rule [assignment](#assignment-statements) follows, because assignment
of a copyable type is defined in terms of `try_clone`.

Each alias performs receiver lookup and resolves to the same declaration as its method spelling; it contributes no independent candidates and cannot disagree with the method. Built-in types receive compiler-defined receiver members for the operations they support. For lifecycle-enabled types the compiler-generated public `clone` and `try_clone` members remain the definition sites; a user customizes their implementation with `hook(copy)`, not by adding an unrelated free clone.

**Method syntax applies only to methods.** `x.f()` resolves to a `self`-receiver procedure in an `impl` block for the type of `x`, a `self`-receiver procedure in a visible extension block, or a compiler-defined receiver operation. Ordinary `f(x)` remains an ordinary lexical call. Only the closed aliases above perform receiver lookup, and only for immutable receivers; mutators such as `append`, `remove`, `reserve`, and `sort` remain method-only so their implicit receiver borrow cannot hide inside free-call syntax.

A type declares one of these customization operations as a method:

```odin
impl Ring_Buffer {
	len :: proc(self) -> int { return self.count; }
}

buffer: Ring_Buffer = {};
n := len(buffer);        // standard alias for the method below
m := buffer.len();       // selects the same declaration
```

Built-in containers receive compiler-defined `len` and `cap` methods, so their method and free-alias spellings also select one operation. Mutators such as `x.append(v)` are receiver methods and have no free aliases.

`iter` and `iter_reverse` are the two entries the [`Iterable`](#iteration-protocol) requirement states in receiver form, because every adapter that continues from them — `indexed()`, `entries()`, `bytes()` — is a method. Their standard free aliases select those methods without creating overload groups.

### Library numeric types

Complex numbers and quaternions are standard-library abstractions, not base-language types, built from ordinary structs, methods, operators, conversions, interfaces, and formatting hooks:

```odin
Complex_F64 :: struct {
	real, imaginary: f64,
}

impl Complex_F64 {
	from_components :: proc(real: f64, imaginary: f64 = 0) -> Complex_F64 {
		return {real, imaginary};
	}

	add :: operator(+) proc(left, right: Complex_F64) -> Complex_F64 {
		return {left.real + right.real, left.imaginary + right.imaginary};
	}

	multiply :: operator(*) proc(left, right: Complex_F64) -> Complex_F64 {
		return {
			left.real*right.real - left.imaginary*right.imaginary,
			left.real*right.imaginary + left.imaginary*right.real,
		};
	}

	@(implicit)
	from_scalar :: hook(convert) proc(value: f64) -> Complex_F64 {
		return {value, 0};
	}
}

z := Complex_F64.from_components(1, 2);
w := z*z + 2.0;               // `2.0` is a constant, so `from_scalar` applies
```

Library numeric types have no special compiler relationship. A scalar constant
may be converted by an `@(implicit)` conversion hook; a scalar variable requires
an explicit conversion such as `Complex_F64(x)`. Generic numeric families and
third-party numeric types use the same construction, conversion, and operator
rules as other user-defined types.

## Interfaces and polymorphism

### Interfaces as reusable constraints

An `interface` gives a name to a reusable compile-time predicate over types. An
application such as `Additive(T)` is a constant `bool`: it is true exactly when
the substituted requirements hold. It can therefore appear anywhere a
compile-time Boolean is accepted, including a [`where`](#where-clauses) clause
or `static_assert`.

Satisfaction is structural. A type satisfies an interface when its operations
and members meet the requirements; no `implements` declaration is consulted.
The interface declaration is compile-time metadata rather than a runtime value
type. Runtime polymorphism is requested explicitly with
[`dyn Interface`](#borrowed-dynamic-interface-values).

```odin
Additive :: interface($T: type) {
	T(0) -> T;
	(a, b: T) a + b -> T;
}

sum :: proc(values: []$T) -> T
	where Additive(T) {
	result := T(0);
	foreach (value in values) {
		result += value;
	}
	return result;
}
```

#### Interface bodies

An interface body is a semicolon-terminated list of requirements ([`Requirement` grammar](grammar.md#interfaces)). Every requirement denotes a compile-time proposition, but its written expression need not itself be a Boolean or be executable at compile time. A requirement may be preceded by a **binding list** introducing names for hypothetical values or explicit `inout` places. There are three forms:

- **expression form** — `expr -> Type;`
- **validity form** — `expr;`
- **named dispatch form** — `slot name: proc(...);`

A requirement beginning with `(` is always a binding list; a requirement whose own expression must start with a parenthesis needs a second pair. Inside a requirement a type name always means the type, and values come only from the binding list, so `T(0)` is unambiguously construction and `(a, b: T) a + b` is unambiguously addition.

**Expression form** `expr -> Type;` requires that `expr` compiles for the interface's parameters and bindings and that its result converts to `Type`.

A binding `name: inout T` is a hypothetical exclusive mutable place: it may be read and may select an `inout` receiver, parameter, or indexing overload. A result `-> inout T` requires the expression to denote an assignable place of exactly `T`, with no result conversion. These forms exist only during requirement checking and add no first-class reference type:

```odin
Mutable_Indexable :: interface($T: type, $Element: type) {
	(value: inout T, index: int) value[index] -> inout Element;
}
```

Only `inout` is admitted in a binding list. A consuming operation can be required as a named slot with a `move self` receiver, but there is no hypothetical `move` binding, since checking a capability must not consume the evidence used for the remaining requirements.

**Validity form** `expr;` requires only that the expression compiles. It does
not test the expression's value. In particular, `false;` is a satisfied validity
requirement because `false` is well-formed. A truth-valued restriction belongs
in the consuming declaration's `where` clause; giving reusable interfaces their
own value predicates would require a distinct truth-requirement form rather
than changing the meaning of existing validity requirements.

An associated constant is an ordinary expression requirement: `T.ZERO -> Element;` asks for a member `ZERO` on `T` whose value converts to `Element`. When the required result is `type`, the member must evaluate to a compile-time type; it is then an **associated type** usable in later requirements and in constrained generic code:

```odin
Source :: interface($T: type) {
	T.Element -> type;
	(value: T) value.read() -> T.Element;
}

Byte_Source :: struct {
	current_byte: u8,
}

impl Byte_Source {
	Element :: u8;

	read :: proc(self) -> u8 {
		return self.current_byte;
	}
}
```

Associated types need no separate grammar, since types are compile-time values and an `impl` admits constants. For a generic `T`, a selector like `T.Element` is valid only when the active constraints require that member unambiguously. Requirement order is irrelevant, and two requirements for the same selector must agree on its type.

**Named slot form** `slot name: proc(...);` declares a method requirement:

- Its first parameter must be `self` in one of the three
  [receiver modes](#receiver-forms). A pointer parameter merely named `self` is
  not a receiver.
- An interface eligible for runtime use permits only immutable `self` and
  `self: inout Subject` receivers.
- After substituting interface arguments, checking selects one matching
  inherent or same-package extension method. Modes, results, and calling
  convention must match exactly; default arguments do not participate.
- Slot names must be unique across the interface and everything it composes.
  Witness members are never overload groups.

A slot is both a static callable requirement and a potential
[witness](#runtime-polymorphism) entry. It is available through method syntax
in constrained generic code.

Method and operator requirements are written as ordinary calls on bound values; lifecycle requirements name the hook (the standard [`Cloneable`](#standard-interface-catalogue) requires the fixed `try_clone` slot). Interfaces compose by naming one another. A bare interface application in an interface body is a composition requirement: the application must evaluate to true, not merely compile. This is the deliberate exception to ordinary validity-form checking.

Requirement checking is non-recursive at the point of use and does not prove requirements about types that do not yet exist. An interface application like `Ordered(T)` is a compile-time predicate; the declaration alone is not a runtime type and cannot be a variable, field, parameter, or result type. `dyn Ordered` is a separate erased type, valid only when the interface is dyn-compatible.

Evaluating an interface application as an ordinary Boolean may simply produce
false. When the program positively requires it to hold — as a bare `where`
bound, a direct `static_assert`, or a conversion to `dyn Interface` — a failure
must report the concrete application and the specific interface-body line that
did not hold. A diagnostic reading only "constraint not satisfied" or "static
assertion failed" is a defect.

Because satisfaction is implicit, declaring a type does not cause it to be
checked against every interface in scope. A misspelled or incorrectly typed
operation is diagnosed only when some checked declaration actually requires
that interface application. The current language has no declaration-site
conformance claim.

#### Standard interface catalogue

Version 1 has a small catalogue, exported by `base:interfaces` as ordinary declarations (not compiler predicates) and written with the package qualifier outside it, e.g. `interfaces.Sequence(S)`. The compiler makes built-in operations and associated members visible to the same structural checks used for user types.

```odin
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
	slot try_clone: proc(self, allocator: Allocator) -> Result(T, Allocator_Error);
}

Iterator :: interface($Self, $Element: type) {
	slot next: proc(self: inout Self) -> Option(Element);
}

Iterable :: interface($Self: type) {
	Self.Element -> type;
	Self.Iterator -> type;
	slot iter: proc(self) -> Self.Iterator;
	Iterator(Self.Iterator, Self.Element);
}

Reverse_Iterable :: interface($Self: type) {
	Iterable(Self);
	slot iter_reverse: proc(self) -> Self.Iterator;
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
	(value: inout Self, element: Self.Element) value.append(element);
}
```

`Ordered` means the `<` operation is available; it does not promise a mathematical
total order, so floating-point types satisfy it with IEEE-754 comparisons. An
algorithm needing a total or strict-weak order states that precondition or takes
a comparator. `Numeric` does not compose `Ordered` and requires no ordering.

`Cloneable` names the fallible public `try_clone` operation, not the policy-following `clone`; it is satisfied by copyable owning built-ins and records, while `move_only struct` (including structural propagation from a field) makes it fail. `Iterable` describes by-value traversal; the built-in `foreach (&element in value)` forms stay place operations, and generic indexed mutation uses `Mutable_Sequence`.

Formatting stays the `value.format(writer, options)` protocol in `core:fmt`, with its standard free alias. Maps stay constrained by their concrete `map[K]V` shape — a map's `Element` is its `struct{key: K, value: V}` entry, so it satisfies `Iterable` but not `Sequence`, whose `value[index] -> Element` requirement an unordered keyed container cannot meet — and UTF-8 text stays its concrete `string`/`string_view` type.

Built-in satisfaction follows the operations the language already defines:

- `bool`, integers, floats, runes, `string`, `string_view`, pointers including `rawptr` and multi-pointers, enums, `typeid`, and recursively comparable fixed arrays satisfy `Equatable`; records and unions do so when their generated or inherent equality is available;
- integers, floats, runes, `string`, `string_view`, pointers on targets that support pointer ordering, and enums satisfy `Ordered`;
- `bool`, integers, floats, runes, `string`, `string_view`, pointers, enums, `typeid`, and fixed arrays of hashable elements satisfy `Hashable`. For floats, `+0` and `-0` hash identically because they compare equal. User records and unions still require the inherent coherent equality/hash pair specified under [Maps](#maps);
- built-in integer, floating-point, and rune types satisfy `Numeric`; integer and rune types satisfy `Integral`;
- copyable owning built-ins such as `string`, dynamic arrays, maps, and `shared(T)`, plus recursively copyable owning aggregates, satisfy `Cloneable`;
- runtime ranges, strings, string views, fixed arrays, slices, dynamic arrays, and maps satisfy `Iterable`. Their associated `Element` is respectively the endpoint type, `rune`, `rune`, the stored element, the stored element, the stored element, and the map's `struct{key: K, value: V}` entry. Fixed arrays, slices, dynamic arrays, and runtime ranges also satisfy `Reverse_Iterable`; a map does not, because its order is unspecified, and text does not, because a backward decoder is not part of version 1;
- fixed arrays, slices, and dynamic arrays satisfy `Sequence`; fixed arrays, mutable slices, and dynamic arrays satisfy `Mutable_Sequence` when supplied as mutable places; dynamic arrays satisfy `Growable_Sequence`. The standard `Small_Array(T, N)` library type supplies the same associated members and satisfies all three sequence interfaces.

No nominal `implements` list is involved; the catalogue records capability boundaries, not a requirement that every built-in belong to an interface.

#### Choosing between `where` constraints and specialization

Two mechanisms determine whether a generic declaration is applicable:

- **[`where` clauses](#where-clauses)** filter an otherwise matched declaration
  with compile-time Boolean expressions. `N > 2` and `Additive(T)` are the same
  kind of bound. An interface declaration does not add a third constraint
  mechanism; it defines a named, reusable Boolean predicate whose failure can
  identify an individual structural requirement.
- **[Specialization](#specialization)** matches and destructures structural
  shape in a parameter type, as in `values: []$E` or
  `table: ^Table($Key, $Value)`. Because it binds parts and participates in
  overload specificity, it is not merely another predicate.

Use an interface when a capability is reused, when constrained code needs its
members or slots, or when a per-requirement diagnostic is valuable. Use a
direct `where` expression for a local value relation such as `N > 2`.

### Runtime polymorphism

Runtime polymorphism reuses the same structural interfaces as generics. It is requested explicitly with [`dyn Interface`](#borrowed-dynamic-interface-values), the only construct that erases a concrete type behind an interface.

For runtime use, an interface's first generic parameter is its **subject** and must have type `type`; erasure substitutes the concrete implementation type for it, while any other generic parameters stay explicit arguments of the dynamic type. The catalogue's `interfaces.Iterator(Self, Element)` is one such interface:

```odin
Drawable :: interface($Self: type) {
	slot draw: proc(self, canvas: inout Canvas);
}
```

Each `(Interface, Concrete, arguments...)` tuple has exactly one **witness**: immutable evidence that the concrete type satisfies the interface's named slots. Its slot implementations must be inherent to the concrete type or declared in the interface's own package; caller-local extensions do not participate. So two packages cannot erase the same type behind the same interface and get different behavior, and no import can change what a `dyn` value does.

A witness is a mechanism, not a value: its representation (a table of procedure pointers, adapter thunks, slot order) is unobservable, there is no built-in that materializes one, and `dyn` is the only way to reach one. The only thing a program can do with a witness is call through it.

#### Dyn compatibility

An interface is **dyn-compatible** when it can be erased behind a finite set of slots and invoked without knowing the subject's size. It must meet all of these:

- its first generic parameter is `$Self: type` (the name may differ);
- every runtime operation is a named `slot`; any other expression or validity requirement (beyond interface composition) makes it static-only;
- every composed interface is dyn-compatible and uses the same subject;
- a slot is non-generic, non-variadic, uses the ordinary Loke calling convention, and has no omitted-argument defaults;
- the subject occurs exactly once in the slot signature, as the first `self` or `self: inout Self` receiver, and nowhere else.

These rules exclude constructors, `Self`-returning methods, consuming methods, generic methods, and binary operations needing another value of the same hidden type. They remain valid static requirements; the restriction applies only when forming a `dyn` type.

#### Borrowed dynamic interface values

`dyn Interface(arguments...)` is a fixed-size, non-owning view: a data pointer plus a pointer to the interface's coherent implementation for the erased type. The subject argument is omitted, being the erased type. For example, `dyn interfaces.Iterator(u8)` may hold a borrow of any concrete value for which `interfaces.Iterator(Concrete, u8)` is satisfied.

The view's capability is written, not inferred from the interface: `dyn I` is an immutable borrow and `dyn mut I` an exclusive mutable one, subject to the same use-based exclusivity rule as every other borrow. The two are distinct types with distinct names and type identities over one representation — the same data pointer and the same witness — so `dyn mut I` weakens to `dyn I` with no cast and no copy, and `dyn I` never strengthens.

For an interface mixing receiver modes, the capability decides which slots the view exposes. `dyn I` exposes only the slots taking an immutable `self`; `dyn mut I` exposes every slot. Both keep the full witness table, so calling a mutating slot through a `dyn I` is a capability error naming `dyn mut I` — never a missing member. A mutating slot may be called directly on any `dyn mut I` value, however the value itself is held: the capability belongs to the view type and the call mutates the erased referent, not the view header.

Conversion is an ordinary explicit conversion from a pointer to the concrete subject. `&` builds a read-only view and `&mut` a mutable one; a mutable view requires `^mut Concrete`, while building a `dyn I` from a `^mut Concrete` is ordinary weakening:

```odin
circle := Circle{...};
drawable := (dyn Drawable)(&circle);
drawable.draw(inout canvas); // indirect call through the witness

counter := Counter{0};
bumpable := (dyn mut Bumpable)(&mut counter);
bumpable.bump();             // a mutating slot, through a mutable view
```

The conversion allocates nothing and copies no value; it creates a compiler-recognized borrow whose provenance derives from the pointed-to source and materializes or reuses its witness. A pointer from a temporary may form a `dyn` value only for that complete expression. A local `dyn` value participates in ordinary use-based borrow analysis, and storing one is checked exactly as storing a slice is. A `dyn` parameter or result follows the same coarse root-provenance rule as a slice.

Converting a nil concrete pointer yields the nil dynamic view and retains no witness. The zero value of every `dyn Interface` is nil; copying one copies only the view when the borrow rules permit the alias, and calling a slot on nil panics. Dynamic interface values are comparable only with `nil`.

Dynamic interfaces do not support checked extractions or type switches in version 1: the view header is a data pointer and a witness pointer and carries no `typeid`, so a checked downcast would need a third word and a different representation. Add a slot for the required behavior, or pass an `any_view` for runtime type inspection.

A dyn view satisfies its own interface through compiler-provided forwarding slots — the bridge between static and runtime polymorphism. `dyn mut I` satisfies `I` whatever its receiver modes; `dyn I` satisfies `I` only when every required receiver is immutable, because those are the only slots it exposes. Converting to a composed base interface keeps the capability it was reached through.

```odin
paint :: proc(value: ^$T, canvas: inout Canvas)
	where Drawable(T) {
	value^.draw(inout canvas);
}

paint(&circle, inout canvas);   // T is Circle; specialized direct call
paint(&drawable, inout canvas); // T is dyn Drawable; witness dispatch
```

Passing a concrete value to generic code never introduces dynamic dispatch; the caller must construct a `dyn` value first, or the parameter must ask for one. A `dyn` value also converts without allocation to a composed base interface, preserving the data pointer and selecting the base interface's witness.

There is no owning erased value in the base language. Closed heterogeneous
ownership uses unions; open ownership combines an explicit allocation owner with
a record of callbacks. `shared(dyn I)` shares only the two-word view and does not
extend the payload's lifetime.

# 3. Declarations & Storage Duration

## Variable declarations

A variable declaration creates a variable in the current scope.

```odin
x: int; // declares an uninitialized `int`; `x` starts dead
y, z: int; // both variables start dead
```

A lexical local variable without an initializer starts **dead and uninitialized**. Its
declaration reserves storage but does not write a value to that storage. A full
assignment completes its initialization and makes it live. An explicit
initializer, including `{}` when the zero value is wanted, makes the variable
live at its declaration.

An ordinary expression may read, borrow, take the address of, move, or drop a
local variable only where the compiler can prove that the local is live on every path to
that expression. Otherwise the use is a compile-time error; ordinary Loke code
never evaluates an uninitialized value. A dead local may be named only as the
destination of a full assignment. Field and element assignments do not
partially initialize a dead aggregate.

Liveness is not required in an **unevaluated operand**. `type_of(expression)`,
the expression forms of `size_of` and `align_of`, and the entity operand of
`source_location` inspect only a declaration or static type. Their operands must
resolve and type-check, but they do not read storage, create a borrow, or require
the named local to be live.

Parameters start live. File-scope, `static`, and `thread_local` variables use
the constant-initialization rule under [Storage modifiers](#storage-modifiers)
and therefore still receive their zero value when they omit an initializer.

```odin
count: int;
// fmt.println(count); // ERROR: `count` is dead

if (has_count) {
	count = 1;
}
// fmt.println(count); // ERROR: `count` is not live on every path

count = 0;             // full assignment makes it definitely live
fmt.println(count);    // OK
```

Each declaration in a scope must have a unique name. A local declaration must not
shadow a local variable or parameter in an outer scope. Copying a parameter into
a mutable local requires a different name; see [Local copies of parameters](#local-copies-of-parameters).

This restriction applies only to local scopes. A local declaration may shadow a file-scope declaration, an imported package name, or a predeclared identifier such as `byte`, `nil`, or `len`. The program cannot use the shadowed name in that local scope.

```odin
x := 10;
x := 20; // Redeclaration of `x` in this scope
y, z := 20, 30;
test, z := 20, 30; // not allowed since `z` exists already
```

### Managed values and storage

Owning values such as `string`, `[dynamic]T`, and `map[K]V` have a fixed-size, implementation-defined representation and may own variable-size backing storage. The compiler releases that storage when a live managed value leaves scope. See [`string`](#string-type).

```odin
numbers := [dynamic]int{1, 4, 9};
message := string("hello");

numbers.append(16);
// `numbers` and `message` are released automatically at the end of the scope.
```

**Managed lexical storage** is cleaned up at normal scope exit, on `return`, `break`, or `continue`, and during [panic unwinding](#panics-and-unwinding).

Cleanup uses `defer` order: a managed declaration places an implicit conditional `defer drop(value)` at its declaration point, which drops the value only if it is live when the action runs. Implicit drops and explicit deferred statements run in reverse registration order, so a deferred statement can read a managed local the compiler can prove still live before that local is dropped.

A `return` evaluates and transfers its result before scope-exit actions run; a deferred statement cannot change it. Returning a non-owning parameter or borrowed place may require a clone. See [Parameter semantics](#parameter-semantics-and-abi-lowering).

#### Values that outlive every scope

File-scope and [`static`](#storage-modifiers) managed values live for the process lifetime and are not automatically dropped. The operating system reclaims their memory at process exit; leak checkers report it as reachable.

A `thread_local` owner exists for the life of its thread. The runtime initializes thread-local storage (TLS) in a deterministic order. It orders declarations by canonical package path, normalized package-relative file path, and source position. At normal thread return, the runtime drops each live managed `thread_local` value in reverse initialization order. This cleanup occurs before the thread synchronizes with a successful join.

The runtime drops every live managed TLS owner. A value that must escape that teardown is taken out first: `unsafe.forget(exchange(inout value, {}))` leaves the binding holding its zero, which the teardown then has nothing to clean up. The runtime does not guarantee TLS cleanup after `os.exit`, an aborting panic, or termination after panic unwinding. A library-created thread must enter and leave through the Loke runtime. A foreign thread must use the documented runtime attach and detach API before it calls exported Loke code.

Do not rely on implicit process cleanup for an operation with an external effect — flushing a file, closing a socket, releasing a shared-memory lock. Use an owning scope, `defer`, or an explicit `drop` in `main`:

```odin
cache: map[string]int;             // reclaimed by the OS at exit, no drop runs

main :: proc() {
	log_file := open_log();        // managed local: dropped at the end of `main`
	run(log_file);
}
```

#### Storage modifiers

Storage modifiers follow `:` and specify duration: where and how long a variable exists. `static` and `thread_local` are mutually exclusive; omitting both gives lexical storage.

- `static` creates one instance for the life of the process. The value remains available between calls.
- `thread_local` creates one instance for each thread. A live managed value is dropped at normal thread return.

```odin
counter: static int;          // keeps its value across calls
current: thread_local ^Task;  // one per thread
```

A modifier may also be written where the type is inferred:

```odin
counter: static = 0;
session: thread_local = 0;
```

Ownership and allocation lifetime are distinct:

- an **automatic owner** is a lexical value cleaned up at scope exit;
- an **allocation root** is `new`/`new_clone` storage, released by `free` or by resetting its allocator region, never by scope exit;
- a **forgotten owner** is a value whose cleanup was explicitly suppressed.

A local's inline representation lives in the stack frame; managed locals may also own allocator-supplied backing storage on the heap or elsewhere.

The compiler does not move a large fixed-size local to the heap: `big: [1_000_000]f64;` stores the whole eight-megabyte array in the stack frame and overflows the stack on most targets. Use `new`, a `[dynamic]T`, or an arena for bulk storage.

File-scope, `static`, and `thread_local` declarations use **constant initialization**. The initializer must be a compile-time constant. If there is no initializer, the declaration uses the zero value.

Static-duration bindings remain live after initialization: `move` and explicit `drop` are forbidden on them and their subplaces. Full assignment replaces the value normally; [`exchange`](#exchange) extracts it while installing a live replacement. These rules apply to each `thread_local` instance, except that the runtime drops live managed TLS values at normal thread return.

File-scope and `static` storage is ready before `main` starts. Thread-local storage is ready before its thread runs Loke code. Importing a package does not run package code. For runtime initialization, call a package procedure explicitly, use a `once` value from `core:sync`, or use state that the caller owns.

**Storage modifiers are not type constructors:** `static int` and `int` are the same type; transferring a value between them needs no conversion.

Unlike [attributes](#attributes), storage modifiers sit next to the type and determine a variable's duration, address stability, and cleanup.

The following rules also apply to `static` and `thread_local`:

- A `static` has a stable address for the life of the process. A `thread_local` has a stable address for the life of its thread. A procedure can return a borrow of either one. Storing a `thread_local` borrow in process-duration storage is rejected, because thread storage does not outlive the process; see [Retaining a borrow](#retaining-a-borrow). A program must also not send a `thread_local` borrow to another thread or keep it after its thread ends, and the borrow analysis does not check those two errors.
- An allocator-binding owner starts in the constant, allocator-unbound zero state and binds the default allocator when first needed. `via` is forbidden because its runtime allocator expression is not constant. To select another allocator, construct an owner in an explicit startup or thread-start procedure and move it into the variable. `string` and `shared(T)` retain the moved allocation's allocator.

```odin
// Within a procedure returning a compatible Result:
buffer := make([dynamic]u8, allocator=my_allocator) or_return;
drop(buffer); // or leave it to scope exit
```

`drop(value)` cleans up a definitely live lexical owning variable, writes the inert zero representation, and marks it **dead**. It is forbidden on static-duration storage and its subplaces. Scope exit drops every live managed lexical owner unless consumed by [`unsafe.forget`](#unsafeforget).

`drop` and `move` are compiler special forms operating on variables, not directly on fields, elements, or map entries. To release a field's storage while keeping its aggregate live, use [`exchange`](#exchange) to extract the old value and install a replacement:

```odin
old := exchange(inout record.buffer, {});  // `record` stays live throughout
drop(old);                                 // now an ordinary local
```

Dropping the whole aggregate, which drops its fields in reverse declaration order, remains the other option. `drop` is a predeclared identifier, not a keyword, and a declaration can shadow it.

The compiler performs dataflow analysis and classifies a lexical local as definitely live, definitely dead, or conditionally live at each program point. A use that requires a value is valid only in the definitely-live state. This analysis is a compile-time property and does not add storage to ordinary variables.

A later lifecycle operation on a conditionally live variable requires state distinguishing its live and dead paths. The representation is implementation-defined: a hidden drop flag, a register, or branch-specific cleanup. Flags are not required for every variable and need not occupy addressable bytes.

A full assignment to a dead variable completes an initialization and makes it live. A full assignment to a live variable replaces its value using the normal assignment lifecycle. If the destination is conditionally live, generated code uses the runtime state to select the live-destination or dead-destination assignment lifecycle, including allocator selection and failure behavior. A dead or conditionally-live variable cannot otherwise be read, borrowed,
addressed, moved, or explicitly dropped.

A never-initialized dead variable contains unspecified bytes. A move or `drop` writes the inert zero representation to its source, but that does not make a dead variable readable: a zero value can also be a valid live value, so liveness is never inferred from the bytes. A `drop` hook runs once per completed initialization that is not transferred or already consumed. See [Zero values](#zero-values).

An allocator-selecting declaration retains its **declaration allocation policy** while dead: the `via` expression, or the program default when absent. Copy initialization or assignment revives a dead variable using that policy; moving an owner into it instead transfers the owner's bound allocator. After a later move or drop, copy initialization again uses the declaration policy.

Built-in owners have compiler-defined cleanup. User types default to field-wise `try_clone`, policy-following `clone`, `move`, and `drop`. Customize them through [`hook(copy)` and `hook(drop)`](#lifecycle-hooks-and-resource-types), not by replacing generated copy declarations.

Structs and fixed arrays containing managed fields receive compiler-generated copy, move, and cleanup operations recursively. Self-assignment is safe. Reference cycles require explicit pointers or `shared(T)`; plain pointer cycles are non-owning, while `shared(T)` can form ownership cycles.

Multiple declarations (`y, z := 20, 30;`) differ from [destructuring](#destructuring), which takes one record on the right. Destructuring is flat: each binding takes a whole field; nested patterns are not supported.

##### `unsafe.forget`

`unsafe.forget(value)` consumes a value without cleaning up it or its owned contents, deliberately leaking or relinquishing the resource. No declaration modifier suppresses cleanup:

```odin
held := open_device();
unsafe.forget(move(held));  // the device driver owns it now
```

- The operand is consumed. A place is written `unsafe.forget(move(place))` and obeys `move`'s rules in full, including the ban on static-duration storage. A value temporary is accepted directly, which is what permits `unsafe.forget(exchange(inout value, {}))` — the way a static-duration owner is forgotten.
- The operand must own something or be provenance-free. A managed value is accepted even when it contains checked borrows: forgetting it leaks the owned resource and ends the loans inside it. An unmanaged value is accepted only when it carries no checked borrow, which rejects bare pointers, slices, views, `dyn` values, and borrow-only records. An unmanaged value that carries none — an `int`, a plain record, a raw or multi-pointer — is accepted silently, so a generic `T` that may or may not be managed can be written once. Forgetting a raw pointer releases nothing it designates.
- **`forget` does not extend a lifetime.** It performs no heap promotion, no address stabilization, and no frame preservation. A borrow of a forgotten owner is invalidated at the `forget`, exactly as it would be at a `drop`, so a borrow can never outlive the value it names.
- The source binding becomes dead. Using it again, or forgetting it twice, is the ordinary use-after-move error.
- The result is `Unit`, matching `drop`.

For foreign handoff, prefer a library-defined consuming `into_raw` that returns the handle and leaves the value inert, with an unsafe `from_raw` inverse. These need no compiler support; types without them can use `unsafe.forget`.

## Constant declarations

A constant binds a name to a value. The value must be available at compile time and cannot change.

```odin
x :: "what"; // constant `x` has the unfixed string value "what"
```

A constant declaration can specify a type:

```odin
y : int : 123;
z :: y + 7; // constant computations are possible
```

Constants may be declared in any order and may refer to constants declared later in the same package. A cycle in that dependency graph has no value and is a compile-time error; the diagnostic reports the cycle as a path of constant declarations, in the same way an [import cycle](#import-cycles) is reported.

### Materialization

A constant is a value, not a variable, and an ordinary use of one is substituted at the point of use with no storage involved. Some uses need storage anyway:

- indexing by a non-constant index
- a slice expression

**A constant used in either of those ways is materialized into read-only storage.** All uses of that constant share one backing object. A constant that is never used in one of those ways occupies no space in the program.

```odin
NUMBERS :: [?]int{7, 42, 628};

main :: proc() {
	index := read_index();
	n := NUMBERS[index];        // materialized: the index is not constant
	m := NUMBERS[0];            // not materialized: folds to 7
	all := NUMBERS[:];          // materialized: `[]int` over static storage
}
```

Materialized storage is read-only: assigning through it is rejected and a slice of it is `[]T`, never `[]mut T`. `&C` and `&C.field` are permitted and yield a `^T` addressing that shared object, so every `&C` in the program compares equal; `&mut` of it is rejected. A generic instantiation holds its own constant symbol and so gets its own object. Low-level code needing a mutable foreign pointer still takes a slice first and uses `unsafe.raw_data`, making the capability loss explicit.

Because the storage is static, a borrow of a materialized constant outlives every scope, exactly like [a slice over a string literal](#slices). It may be returned, stored in a global, or sent to another thread.

A constant table is materialized in read-only storage when runtime indexing needs storage:

```odin
NAMES :: [?]string{"north", "east", "south", "west"};

heading :: proc(category: int) -> string {
	return NAMES[category];
}
```

Placing a constant in a *particular* linker section is a toolchain concern and uses an [extension attribute](#extension-attributes) such as `@(link.section=".rodata.hot")`.

A constant value must be available at compile time. Thus, it cannot contain a managed owner, a pointer to non-static storage, or another value that needs lifecycle operations. Materialization emits bytes and does not need cleanup.

### Compile-time phases

Compile-time knowledge is a property of a binding, not a second family of value types. A compile-time `int`, `string`, enum, array, or record has the same Loke type and operations as its runtime counterpart. Information flows from compile time to runtime by constant substitution or materialization; a runtime value can never flow back into a compile-time-required context.

There are three ways to introduce compile-time information:

- `name :: expression` binds the compile-time result of an expression. Inside a
  generic declaration it is evaluated separately for each specialization that
  reaches the declaration.
- `$name` introduces a **specialization binding**. On an explicit procedure or
  type parameter the caller supplies a compile-time value. In a parameter type
  or static `foreach` binding the compiler infers one. `$` appears only where the
  name is introduced; subsequent uses write `name` normally.
- A type name is itself a compile-time value of the compile-time-only [`type`](#type-and-typeid)
  type.

Outside a compiler-evaluated call, an ordinary variable — including an immutable parameter — is a runtime binding even when a caller passes a constant; only a `$` parameter is part of specialization. During compile-time evaluation ordinary parameters are evaluator locals that may hold the supplied constants, but this creates no reusable specialization, so a constant argument in runtime code never silently generates another procedure body.

The following contexts require compile-time values:

- constant initializers and arguments supplied to `$` parameters;
- generic type and value arguments;
- fixed-array lengths, enum values, `where` clauses, and `when` conditions;
- static `foreach` iterables;
- compile-time reflection and the operands required by a compile-time built-in.

An ordinary runtime expression may consume a compile-time value. The reverse is a compile-time error and the diagnostic must identify the runtime binding that prevented evaluation.

### Compile-time procedure evaluation

A normal `proc` may be evaluated by the compiler when its result is required in a compile-time context. There is no second `comptime proc` declaration kind.
The same procedure may be called at runtime when its signature and result are runtime-representable:

```odin
hash_name :: proc(text: string_view) -> u64 {
	hash: u64 = 14695981039346656037;
	foreach (b in text.bytes()) {   // bytes, not runes: string iteration yields code points
		hash = (hash ~ u64(b))*1099511628211;
	}
	return hash;
}

CLICKED_ID :: hash_name("clicked"); // evaluated by the compiler
id := hash_name(user_text);         // ordinary runtime call
```

There is no operation that reports whether the current call is being evaluated
by the compiler. A procedure cannot choose different semantics only because
the phase changed.

A compile-time call requires every value it reads from outside its own locals to be compile-time known. Its executed path may use ordinary expressions, procedures, local variables, mutation, control flow, recursion, and temporary managed containers. It may not:

- read or modify runtime or mutable file-scope state;
- call foreign code or use volatile, atomic, thread, clock, random, environment, file-system, network, or process operations;
- observe a runtime address, convert a pointer to an integer, or retain a pointer to evaluator-owned storage;
- use a runtime allocator or transfer an evaluator-owned managed value into the generated program.

Temporary strings, arrays, maps, and other managed values use compiler-owned storage while evaluation runs. This storage has no Loke `Allocator`, cannot be observed by the program, and is reclaimed by the compiler. A final result must be a compile-time-only value or a constant that satisfies the materialization rules above. Compiler resource exhaustion is a compilation diagnostic, not an
`Allocator_Error` visible to the program.

An evaluator-produced immutable string may be frozen into static storage exactly as though its bytes had appeared in a string literal; the emitted string value must therefore have an inert `drop`. This does not generalize to mutable managed owners: a dynamic array, map, or other value that would retain an allocation at runtime is not a materializable constant. It must be converted to a fixed array,
immutable string, or ordinary record before the compile-time call returns.

Only the path actually evaluated must satisfy these execution restrictions; all branches must still parse and type-check unless discarded by `when`. A panic or failed `assert` reached during compile-time evaluation is a compilation error reported with the compile-time call stack. Implementations may impose documented step, recursion, and memory limits, but exceeding one must be diagnosed rather than silently moving the call to runtime.

Compile-time evaluation is hermetic: it receives target and project information only through language constants and [`build_config`](#build_configidentifier-default), and does not acquire ambient access to the build machine. For identical source, configuration, and target it must produce the same result. An operation whose runtime answer is deliberately unspecified is rejected on an executed compile-time path rather than approximated, so a folded constant cannot differ from the runtime computation. Map iteration is one such operation (maps remain available for keyed lookup and working storage); `cap` is another, being a property of an allocation compile-time storage lacks, while `len` is an ordinary compile-time fact.

# 4. Expressions & Operators

## Operators

Operators combine operands into expressions. For a binary operation, operand types must be identical, implicitly convertible, or accepted by a visible user-defined overload.

### Arithmetic operators

Unary:

```text
+                           is 0 + x
-    negation               is 0 - x
~    bitwise complement     is m ~ x where m = "all bits set to 1" for unsigned x
                                     and m = -1 for signed x
```

Binary:

```text
+       sum, string concatenation  integers, floats, strings
-       subtraction                integers, floats
*       multiplication             integers, floats
/       division                   integers, floats
%       remainder (truncated)      integers

|       bitwise or                 integers
~       bitwise xor                integers
&       bitwise and                integers
&~      bitwise and-not            integers
<<      left shift                 integer << unsigned integer
>>      right shift                integer >> unsigned integer
```

Except for shift operations, if one operand is an unfixed constant and the other operand is not, the constant is implicitly converted to the type of the other operand (if possible).

**`+` concatenates strings at compile time and runtime.** For two `string` operands, `a + b` returns a new owning `string`. It contains the bytes of `a` followed by the bytes of `b`. Both operands contain valid UTF-8, so the result does not need validation.

Two constant operands produce a constant without runtime storage. Otherwise, the operation allocates from `mem.default_allocator()` and follows its [failure policy](#allocation-failure). A `string` and a `string_view` can occur in either order. Two `string_view` operands also produce an owning `string`.

This is the ordinary convenient spelling and it is the right one for building a message out of two or three pieces. It is the wrong one for a loop: each `+` allocates and copies the whole accumulated result, so repeated concatenation is quadratic. Use `String_Builder` from `core:strings`, which is also how code selects an allocator other than the default. The [copy-cost diagnostic](#copy-cost-diagnostics) reports a concatenation in a loop for the same reason it reports a large copy there.

Enum values do not support arithmetic or bitwise operators. An enum's members are named constants that need not be contiguous, so `Foo.A + Foo.B` need not be a member of `Foo` and has no useful meaning; convert to the backing integer type when arithmetic is intended. Flag sets are the library type `Bit_Set(Enum)` rather than bitwise operators on the enum itself. Enums remain [comparable and ordered](#comparison-operators).

The right operand in a shift expression must have an unsigned integer type or be an unfixed constant representable by a typed unsigned integer. If the left operand of a non-constant shift expression is an unfixed constant, it is first implicitly converted to the type it would assume if the shift expression were replaced solely by the left operand alone (with type inference and hinting rules applied).

### Comparison operators

```text
==      equal
!=      not equal
<       less
<=      less or equal
>       greater
>=      greater or equal
```

In any comparison, the first operand must be assignable to the type of the second, or vice versa.

The equality operators == and != apply to operands that are comparable. The ordering operators <, <=, >, and >= apply to operands that are ordered. These terms and the result of the comparisons are defined as follows:

- `bool` values are comparable.
- Integers values are comparable and ordered.
- Floating-point values are comparable and ordered, defined by the IEEE-754 standard.
- Rune values are comparable and ordered.
- `string` and `string_view` values are comparable and ordered, lexically byte-wise.
- Pointer and multi-pointer values are comparable. Equality compares addresses. Ordering compares the addresses as unsigned `uintptr` values, producing a total order within one execution even for pointers to unrelated allocations. Address-space randomization means that this order need not be reproducible between executions. On a target where a pointer cannot be represented losslessly by `uintptr`, ordering pointers is not supported and use of `<`, `<=`, `>`, or `>=` on them is a compile-time error.
- Enum values are comparable and ordered.
- Struct values are comparable if all their fields are comparable or a visible comparison overload is provided.
- Union values are comparable if all their variants are comparable or a visible comparison overload is provided.
- Array values are comparable if values of the element type are comparable.
- typeid is comparable.
- Slices, dynamic arrays, maps, and `dyn Interface` views are **not** comparable and may be tested only against `nil`. A fixed array is therefore comparable element-wise while a slice of that same array is not. Compare contents or behavior with an explicit library procedure.

### Logical operators

Logical operators apply to boolean values. The right operand is evaluated conditionally

```text
&&      conditional AND    a && b  is "b if a else false"
||      conditional OR     a || b  is "true if a else b"
!       NOT                !a      is "not a"
```

### Compound binary operator and assign

Eager arithmetic and bitwise operations have a compound-assignment shorthand such as `x += 5`. Short-circuiting logical operations do not; write `x = x && y` explicitly.

```text
+=       sum and assign                   a += b is a = a + b
-=       subtraction and assign           a -= b is a = a - b
*=       multiplication and assign        a *= b is a = a * b
/=       division and assign              a /= b is a = a / b
%=       remainder (truncated) and assign a %= b is a = a % b

|=       bitwise or and assign            a |= b is a = a | b
~=       bitwise xor and assign           a ~= b is a = a ~ b
&=       bitwise and and assign           a &= b is a = a & b
&~=      bitwise and-not and assign       a &~= b is a = a &~ b
<<=      left shift and assign            a <<= b is a = a << b
>>=      right shift and assign           a >>= b is a = a >> b
```

### Address operator

For an operand `x` of type `T`, `&x` returns a `^T` pointer to `x` and `&mut x` a `^mut T`. The operand must be addressable. The following operands are addressable:

- a variable or pointer dereference
- an index of a slice, dynamic array, or addressable fixed array
- a visible [`operator([])` that returns `inout T`](#indexing-and-slicing)
- a field of an addressable, non-packed struct
- a trapping checked extraction `x.(T)` from an addressable `any_view`; `x.as(T)` produces a value rather than a place
- a composite literal
- a value parameter, and a [materialized constant](#materialization) or a place within one

`&mut` additionally requires that the operand be assignable, so it is rejected for a value parameter, an element reached through a `[]T` or a `^T`, and a materialized constant — each of which `&` still reaches.

An `any_view` is not addressable. An individual field of an `@(packed)` struct is not addressable.

Both forms are always single-valued: every addressable operand yields exactly one pointer. A container whose lookup may fail supplies a method instead, as the built-in map does with [`m.find(key)`](#maps).

For an operand `x` of pointer type `^T`, `x^` denotes the `T` pointed to. Explicit `x^` and implicit dereferences such as `x.field` test for nil and raise a runtime panic before accessing memory; an implementation may use a hardware fault only if it preserves the same observable behavior. Dereferencing a non-nil address that is dangling, misaligned, or otherwise invalid is undefined behavior, and can arise only through an unchecked lifetime hole, raw-pointer manipulation, or foreign code.

```odin
&x;
&a[foo(123)];
&Foo{1, 2};
p^;
pproc(a)^;

x: ^int = nil;
x^;      // causes a runtime panic
```

### Conditional expression

```odin
x if cond else y;
```

The condition may be a compile-time constant, in which case the result is also constant when the selected value is constant. Compile-time source selection that must leave the unselected branch unchecked uses a `when` statement. There is no second `when` expression or C-style `cond ? x : y` spelling.

### Other operators

- or_else
        see section on or_else
- or_return
        see section on or_return
- in - set membership (e in A, A contains element e)
        Used for map types and visible user-defined container operators
- ..= - inclusive range
- ..< - half open range

`..=` and `..<` are ordinary binary operators producing a [`Range(T)`](#ranges)
value, which may be iterated directly or stored first:

```odin
foreach (x in a..<b) {}
foreach (x in a..=b) {}

span := a..=b;          // an ordinary Range value
foreach (x in span) {}
```

Two positions accept the same spelling as *syntax* rather than as a value, matching endpoints against a subject or an index without constructing a range:

```odin
switch (x) {
case a..<b:
case c..=d:
}

foo := [?]int{0..=3 = 1};        // initialises as: [1, 1, 1, 1]
bar := [?]int{0 = 0, 1..<3 = 1}; // initialises as: [0, 1, 1]
```

The `in` in a `foreach` header separates bindings from the iterable expression. In an ordinary `for` condition, `in` retains its usual membership-operator meaning, so no contextual parsing exception is needed:

```odin
foreach (x in y) {} // iteration
for (contains(y, x)) {} // condition-only loop
```

### Evaluation order

Except for the explicitly lazy operators `&&`, `||`, `or_else`, and the conditional expressions, expression evaluation is deterministic:

- A call evaluates its receiver, if any, and then its supplied arguments from left to right. It binds those supplied values to parameters, then evaluates omitted default arguments once in parameter order. A default may read only the receiver and parameters declared to its left, so each such binding is already initialized. Each default otherwise uses the lexical scope of its procedure declaration.
- A binary expression evaluates its left operand and then its right operand. An operator overload receives those already evaluated values and does not change their order.
- Array, struct, union, map, and container literal elements are evaluated in source order. A named struct literal still uses source order rather than field declaration order.
- A simple or multiple assignment evaluates all right-hand expressions from left to right before evaluating destination place expressions from left to right. Writes then occur from left to right, but only after every value and destination has been prepared. If a required clone fails, no destination is written. This makes swaps well-defined and prevents a failed later clone from partially updating an earlier destination; side effects already performed while evaluating an earlier right-hand expression, including an explicit `move`, are not rolled back.
- A compound assignment evaluates its destination place once, then evaluates the right operand, then performs the operation and write.
- Return expressions are evaluated from left to right before being moved into result storage.

Temporaries created by a complete expression are destroyed at its end in reverse order of completed initialization. Short-circuiting and conditional expressions evaluate only the selected operands, as described by their individual rules. These rules apply equally to built-in and user-defined operations.

### Operator precedence

Postfix operators bind tightest, then unary operators, then the binary levels below.

There are seven precedence levels for binary operators and the conditional expression.

```text
Precedence    Operator
     7           *   /   %   &   &~  <<   >>
     6           +   -   |   ~
     5           ==  !=  <   >    <=  >=   in
     4           &&
     3           ||
     2           ..=    ..<
     1           or_else     if
```

`in` sits at the comparison level because it produces a `bool` and is used where a comparison would be.

Binary operators of the same precedence associate from left to right. For instance x / y * z is the same as (x / y) * z. Level 2 is **non-associative**: `a ..< b ..< c` is a syntax error rather than a nested range, because a range takes two endpoints and neither grouping means anything.

**Level 1 is the exception: it associates from right to left.** This is what makes both of its forms chain the way they read:

```odin
a if c1 else b if c2 else d   // a if c1 else (b if c2 else d)
x or_else y or_else z         // x or_else (y or_else z)
```

The conditional groups as an else-if chain. `or_else` uses the same right grouping. Its left operand must be a [fallible expression](#typed-fallibility) whose success variant carries a payload, and its result is an ordinary value. Left grouping would give the outer `or_else` an ordinary left operand and make a fallback chain invalid.

The postfix forms — call `()`, index `[]`, slice `[:]`, selector `.`, dereference `^`, trapping checked extraction `.(T)`, and `or_return` — are not in the table because they bind tighter than every unary and binary operator. They associate left to right among themselves. `-x^` is `-(x^)`, `f() or_return + 1` is `(f() or_return) + 1`, and `a.b().as(T) or_else c` is `(a.b().as(T)) or_else c`. `or_return` is postfix rather than binary because it takes no right operand; [Other operators](#other-operators) lists it alongside the binary forms only for discoverability.

### Integer operators

For two integers values x and y, the integer quotient q = x/y and remainder r = x%y satisfies the following relationships:

```odin
x = q*y + r   and |r| < |y|;
```

with x/y truncated towards zero (truncated division).

Floored remainder is the library procedure `floor_mod(x, y)`, not a second operator.

The exception to these rules is when the dividend x is the most negative value for the integer type of x, and the quotient q = x/-1 is equal to x (and r = 0) under the wrapping two’s-complement rule below.

If the divisor is a constant, it must not be zero. If the divisor is zero at runtime, a runtime panic occurs.

A shift count is an unsigned integer, so it is never negative, and has no upper limit. Shifts are arithmetic for a signed left operand and logical for an unsigned one, behaving as `n` repeated one-bit shifts. So `x<<1` equals `x*2`, and `x>>1` equals `x/2` truncated toward negative infinity.

A shift count that is equal to or greater than the width of the left operand has defined behavior. It is the limit of the repeated one-bit shift:

- `x << y` is `0` once `y >= 8*size_of(x)`, for both signed and unsigned `x`.
- `x >> y` is `0` once `y >= 8*size_of(x)` for unsigned `x` or non-negative signed `x`, and `-1` for negative signed `x`, because an arithmetic shift replicates the sign bit.

```odin
u: u32 = 1;
i: i32 = -1;
assert(u >> 32 == 0);
assert(i >> 32 == -1); // arithmetic shift saturates at the sign bit
assert(i << 32 == 0);
```

This differs from C, where such a shift count is undefined behavior.

#### Integer overflow

For unsigned integers, the operations +, -, *, and << are computed modulo 2n, where n is the bit width of the unsigned integer’s type. In a sense, these unsigned integer operations discard the high bits upon overflow, and programs may rely on “wrap around”.

Every signed integer uses two’s-complement representation. For a signed type of width `n`, `+`, `-`, `*`, and `<<` compute the mathematical result modulo `2^n` and interpret the resulting bit pattern as that two’s-complement type. Division is truncated toward zero except that `MIN / -1` produces `MIN`; its remainder is zero. These results are deterministic on every target, and overflow does not panic. A compiler may not assume signed overflow does not occur — `x < x+1` is not always true. Code wanting a no-overflow assumption states it explicitly (a sized unsigned type, a hoisted bound, a narrowed index range).

### Floating-point operators

For floating-point types:

- +x is the same as x
- -x is the negation of x

Floating-point division by zero follows IEEE-754 and does not panic: a non-zero dividend produces `+Inf` or `-Inf` according to the signs of the operands, and `0.0/0.0` produces a NaN. Integer division by zero panics. Default floating-point exception handling is non-stop; a program that wants trapping behavior installs it through the target's floating-point environment.

An implementation may combine multiple floating-point operations into a single fused operation, and produce a result that differs from the value obtained by executing and rounding the instructions individually.

# 5. Statements & Control Flow

## Assignment statements

An assignment statement writes a new value to a storage location:

```odin
x: int = 123; // declares a new variable `x` with type `int` and assigns a value to it
x = 637; // assigns a new value to `x`
```

`=` is the assignment operator.

One statement can assign multiple variables:

```odin
x, y := 1, "hello"; // declares `x` and `y` and infers the types from the assignments
y, x = "bye", 5;
```

`:=` consists of the two tokens `:` and `=`. The following declarations are equivalent:

```odin
x: int = 123;
x:     = 123; // default type for an integer literal is `int`
x := 123;
```

Assignment has value semantics. Copying a mutable owning value creates an independent value by recursively cloning its owned storage. Copying an immutable or explicitly shared owning value, such as `string` or `shared(T)`, may retain shared storage. Copying a non-owning pointer, slice, or view preserves its reference semantics.

```odin
a := [dynamic]int{1, 2, 3};
b := a; // independent clone: modifying `b` does not modify `a`
b[0] = 99;
assert(a[0] == 1);
```

`move(value)` transfers ownership without a copy. The operation writes the inert
zero representation to the lexical source and marks it dead until a later full
assignment. Applying `move` to file-scope, `static`, or `thread_local` storage,
or to a subplace rooted in such storage, is a compile-time error. Use
[`exchange`](#exchange) when the source must remain live with a replacement.

```odin
c := move(a); // transfers the allocation; `a` is now dead
a = [dynamic]int{7, 8}; // a full assignment revives `a`
```

The compiler may replace a copy with a move only for a type that has a trivial lifecycle. The replacement must not change allocator selection, call or suppress user code, or remove a possible failure.

The compiler never silently moves dynamic arrays, maps, runtime strings, `shared(T)`, or types with custom copy hooks, even at their last use. Use `move(value)` to transfer ownership. Mutable owners have no shallow aliases; sharing requires non-owning pointers, slices, or views, or an explicit shared owner such as `shared(T)`. Recursive cloning does not follow non-owning references; `shared(T)` elements and immutable strings may retain shared storage. The [copy-cost diagnostic](#copy-cost-diagnostics) flags large or allocating copies and suggests moving or sharing.

If assignment cloning needs storage, `try_clone` uses the live destination's allocator; a dead or allocator-unbound destination resolves its declaration allocation policy, loading `mem.default_allocator()` lazily when no `via` was written. On failure, the compiler invokes that allocator's [failure policy](#allocation-failure) and leaves a previously live destination unchanged. A non-allocating implicit copy that shares immutable or reference-counted storage (`string`, `shared(T)`) keeps that allocation's allocator, so those types select their allocator at construction and cannot use `via`.

### Exchange

`exchange(inout destination, replacement)` is a compiler special form that replaces a definitely live value and returns its previous value without cloning:

```odin
previous := exchange(inout current, {});
```

The destination must be a definitely live variable or addressable place. Its type supplies the context for `replacement`. The compiler evaluates the destination place once and then evaluates `replacement` completely before modifying the destination. If evaluation or construction of the replacement
fails or panics, the destination remains unchanged. Once the replacement is
ready, the compiler moves the old value into result storage and moves the
replacement into the destination as one lifecycle operation. No user code runs
between those two moves, and the destination is never observably dead.

An owning variable used as `replacement` must use `move(source)` to transfer ownership. The result follows ordinary ownership rules, including temporary cleanup if ignored.

`exchange` is permitted for lexical and static-duration destinations. It is the
only operation that can move the current value out of file-scope, `static`, or
`thread_local` storage, because it simultaneously leaves a completed live
replacement. Like any `inout` operation, it is rejected while an incompatible
borrow of the destination is live. It is not an atomic memory operation and
provides no inter-thread synchronization; concurrent code uses `Atomic(T)` or a
lock.

```odin
cache: Cache; // file-scope, always live

take_cache :: proc() -> Cache {
	return exchange(inout cache, {}); // `cache` remains a live zero value
}

clear_cache :: proc() {
	cache = {}; // drops the old value and installs a live zero value
}
```

## Control flow statements

### for statement

The language has two loop statements. `for` repeats according to control expressions, while `foreach` consumes an iterable.

#### Basic `for` loop

A basic `for` loop has three parts separated by semicolons:

- The initial statement runs before the first iteration.
- The condition is evaluated before each iteration.
- The post statement runs after each iteration.

The loop stops when the condition is false.

```odin
for (i := 0; i < 10; i += 1) {
	fmt.println(i);
}
```

The loop header is parenthesized and the body is braced, as for every control-flow statement:

```odin
for (i := 0; i < 10; i += 1) { }
```

The initial and post statements are optional:

```odin
i := 0;
for (; i < 10;) {
	i += 1;
}
```

The separators in a three-part `for` header are required. A condition-only loop is equivalent to a `while` loop in languages that have one:

```odin
i := 0;
for (i < 10) {
	i += 1;
}
```

If the condition is omitted, this produces an infinite loop:

```odin
for (;;) {
}
```

### foreach statement

`foreach` binds each value produced by an iterable. It is the only iteration-loop syntax; `for ... in` is not an alternative spelling.

An integer range is iterable, so the basic loop

```odin
for (i := 0; i < 10; i += 1) {
	fmt.println(i);
}
```

can also be written as

```odin
foreach (i in 0..<10) {
	fmt.println(i);
}
// or
foreach (i in 0..=9) {
	fmt.println(i);
}
```

`a..=b` is a closed range. It includes `a` and `b`. `a..<b` is a half-open range. It includes `a` and excludes `b`.

The built-in iterable types include strings, arrays, slices, dynamic arrays, maps, and integer ranges:

```odin
some_string := "Hello, 世界";
foreach (character in some_string) {
	fmt.println(character);
}

some_array := [3]int{1, 4, 9};
foreach (value in some_array) {
	fmt.println(value);
}

some_slice := []int{1, 4, 9};
foreach (value in some_slice) {
	fmt.println(value);
}

some_dynamic_array := [dynamic]int{1, 4, 9};
foreach (value in some_dynamic_array) {
	fmt.println(value);
}

some_map := map[string]int{"A" = 1, "C" = 9, "B" = 4};
foreach (entry in some_map) {
	fmt.println(entry.key, entry.value);
}
```

A type is never accepted in a `foreach` header; an enumeration is iterated through [`Enum.values()`](#iterating-an-enumeration).

Every binding list names the fields of one [`Element`](#element-bindings), so a second binding exists only when the element is a two-field record. An index, a key, or an offset comes from an [adapter](#iteration-adapters):

```odin
foreach (character, ordinal in some_string.indexed()) {
	fmt.println(ordinal, character);
}
foreach (character, offset in some_string.rune_offsets()) {
	fmt.println(offset, character);
}
foreach (value, index in some_array.indexed()) {
	fmt.println(index, value);
}
foreach (value, index in some_slice.indexed()) {
	fmt.println(index, value);
}
foreach (value, index in some_dynamic_array.indexed()) {
	fmt.println(index, value);
}
foreach (key, value in some_map) {         // the map's element is `{key, value}`
	fmt.println(key, value);
}
foreach (value in some_map.values()) {     // values alone, no entry record
	fmt.println(value);
}
```

`foreach (value, index in some_array)` is an error unless the array's element is a two-field record, in which case it destructures that record. Element bindings are positional and mean nothing else, so a loop over `[dynamic]Point` binds `x` and `y`, not a value and an index.

By default, each iterated value is a copy. Assignment to the copy does not modify the source.

When the iterable is a place or borrow carrier, evaluating it establishes an implicit iterator loan that lives through the whole loop and ends with the `foreach` statement. Iteration by value holds an immutable loan; by reference, an exclusive mutable loan. So competing access to or invalidation of the iterable from inside the loop is checked by the ordinary one rule. Value-only iteration such as an integer range needs no loan.

String iteration produces Unicode runes, not bytes. The string must contain valid UTF-8.

```odin
str: string = "Some text";
foreach (character in str) {
	assert(type_of(character) == rune);
	fmt.println(character);
}
```

Use the address operator to iterate by reference over a mutable array, dynamic array, or slice. A slice must have type `[]mut T`. A `[]T` slice supports only iteration by value.

```odin
mutable_slice := []mut int{1, 4, 9};

foreach (&value in some_array) {
	value = something;
}
foreach (&value in mutable_slice) {
	value = something;
}
foreach (&value in some_dynamic_array) {
	value = something;
}
// does not impact the second index value
foreach (&value, index in some_dynamic_array) {
	value = something;
}
```

Map values can be iterated by-reference, but their keys cannot since map keys are immutable:

```odin
some_map := map[string]int{"A" = 1, "C" = 9, "B" = 4};

foreach (key, &value in some_map) {
	value += 1;
}

fmt.println(some_map["A"]); // 2
fmt.println(some_map["C"]); // 10
fmt.println(some_map["B"]); // 5
```

String iteration cannot use a reference binding because strings are immutable.

#### Static `foreach` expansion

A `foreach` whose bindings carry `$` is a compile-time expansion rather than a
runtime loop:

```odin
print_record :: proc(value: ^$T) {
	foreach ($field, $index in fields_of(T).indexed()) {
		fmt.println(index, field.name, field.get(value));
	}
}
```

The iterable must be compile-time known, finite, and produce compile-time values (fixed arrays, evaluator-owned arrays and slices, `Enum.values()`, ranges, reflection descriptor arrays; not a runtime iterator). `indexed()` and `reversed()` over such an iterable are themselves compile-time evaluable, so a static expansion binds elements by the same [element rule](#element-bindings) a runtime loop uses. The compiler instantiates and type-checks one copy of the body per element, substituting constants for `field` and `index`. The copies run at runtime in iterable order, which is what lets `field.get(value)` have a different static result type in each.

Every binding uses `$`; mixing runtime and compile-time bindings in one header is an error. Static bindings are immutable and cannot use `&`. The body is parsed once but checked after substitution, and an empty iterable instantiates no body. Diagnostics inside an expansion must show the element and its source descriptor or index.

`break` and `continue` cannot target a static expansion. Ordinary runtime loops
inside its body may use them normally. Static `foreach` is a statement inside a
procedure; it does not synthesize identifiers or declarations at file scope,
and does not expose tokens or an abstract syntax tree to compile-time code.

#### Reverse iteration

Reverse traversal is an ordinary [iterator adapter](#iteration-adapters) rather than control-flow syntax. `reversed()` iterates through the type's `iter_reverse`:

```odin
array := [?]int { 10, 20, 30, 40, 50 };

foreach (x in array.reversed()) {
	fmt.println(x); // 50 40 30 20 10
}

foreach (x, i in array.reversed().indexed()) {
	fmt.println(i, x); // 0 50, 1 40, ...
}
```

Fixed arrays, slices, dynamic arrays, and ranges reverse. A map does not, because its order is unspecified, and neither does a string: walking UTF-8 backwards is `text.to_runes()` and a reversed loop over that.

Loop unrolling is an optimizer decision or a namespaced compiler-extension attribute, with no base-language directive.

### if statement

The condition is parenthesized and the body is braced.

```odin
if (x >= 0) {
	fmt.println("x is positive");
}
```

Like for, the if statement can start with an initial statement to execute before the condition. Variables declared by the initial statement are only in the scope of that if statement.

```odin
if (x := foo(); x < 0) {
	fmt.println("x is negative");
}
```

Variables declared inside an if initial statement are also available to any of the else blocks:

```odin
if (x := foo(); x < 0) {
	fmt.println("x is negative");
} else if (x == 0) {
	fmt.println("x is zero");
} else {
	fmt.println("x is positive");
}
```

### switch statement

A switch statement selects a case by comparing its required subject expression with case values. It may include an initialization statement before the subject, separated by a semicolon. The default case is denoted by `case` without a value.

```odin
switch (arch := LOKE_ARCH; arch) {
case .I386, .Wasm32, .Arm32:
	fmt.println("32 bit");
case .Amd64, .Wasm64p32, .Arm64, .Riscv64:
	fmt.println("64 bit");
case .Unknown:
	fmt.println("Unknown architecture");
}
```

Only the selected case runs, so no `break` is needed at the end of a case. Case values need not be integers or constants.

Switch cases are evaluated from top to bottom, stopping when a case succeeds. For example:

```odin
switch (i) {
case 0:
case foo():
}
```

`foo()` does not get called if `i == 0`. If all the case values are constants, the compiler may optimize the switch statement into a jump table (like C).

A switch header of the form `switch (name in expression)` is always a [variant switch](#inspecting-a-union), never a value switch whose subject is the boolean `name in expression`. The membership meaning needs a second pair of parentheses:

```odin
switch (x in set) { }     // variant switch: `x` binds the payload of `set`
switch ((x in set)) { }   // value switch on the boolean `x in set`
```

The variant switch is by far the more common reading.

A switch statement can also use the same ranges accepted by `foreach`:

```odin
switch (c) {
case 'A'..='Z', 'a'..='z', '0'..='9':
	fmt.println("c is alphanumeric");
}

switch (x) {
case 0..<10:
	fmt.println("units");
case 10..<13:
	fmt.println("pre-teens");
case 13..<20:
	fmt.println("teens");
case 20..<30:
	fmt.println("twenties");
}
```

#### Exhaustive switch

With enum values:

```odin
Foo :: enum {
	A,
	B,
	C,
	D,
}

f := Foo.A;
switch (f) {
case .A: fmt.println("A");
case .B: fmt.println("B");
case .C: fmt.println("C");
case .D: fmt.println("D");
}

// An empty default explicitly acknowledges the variants not handled here.
switch (f) {
case .A: fmt.println("A");
case .D: fmt.println("D");
case:
}
```

With union types (see [Inspecting a union](#inspecting-a-union))

```odin
Foo :: union { number: int, flag: bool }
f: Foo = .number(123);
switch (_ in f) {
case .number: fmt.println("number");
case .flag:   fmt.println("flag");
}

switch (_ in f) {
case .flag: fmt.println("flag");
case: // intentionally ignore `.number`
}
```

A switch over an enum must either list every member or include `case:`. A
variant switch must either cover every variant or include `case:`; one that
covers every variant needs no default, and no path reaches the end of it.
The default may be empty; writing it is the explicit acknowledgement that the
remaining cases are intentionally ignored.

**Exhaustiveness is a check over declared members, not over values.** Because
[conversion into an enum is unchecked](#non-member-values), a subject may hold a
value that names no member and so matches no case. A switch whose cases do not
match runs no case and falls through to the statement after it — the same thing
a value switch with no matching case and no default does. This is defined
behavior, not a gap, but it means a member-complete switch is silently a no-op
for such a value:

```odin
switch (Foo(200)) {
case .A: fmt.println("A");
case .B: fmt.println("B");
case .C: fmt.println("C");
}
// nothing runs, and control continues here
```

A switch over a value from outside the program should write `case:` and handle
the unexpected value there. A variant switch does not have this problem: a
union's tag is written only by the language, so covering every variant covers
every value.

### defer statement

A defer statement defers the execution of a statement until the end of the scope it is in. It is registered when execution reaches the `defer` statement and participates in the unified LIFO scope-exit ordering described under [Managed values and storage](#managed-values-and-storage).

Deferred code may not transfer control out of the deferred statement. A `return` or `or_return` anywhere in the deferred statement is an error. A `break` or `continue` is legal only when its target loop or switch is wholly inside the deferred statement; it cannot target a construct surrounding the original `defer`. A deferred statement also may not contain another `defer`. Procedure literals nested in the deferred syntax are checked as independent procedures and are not subject to these restrictions only because their declarations occur there.

So once scope exit begins, a deferred action runs to completion; it cannot replace the return, break, or continue that caused the exit, nor register more work in a defer stack already draining.

The following will print 4 then 234:

```odin
package main;

import "core:fmt";

main :: proc() {
	x := 123;
	defer fmt.println(x);
	{
		defer x = 4;
		x = 2;
	}
	fmt.println(x);

	x = 234;
}
```

A `defer` statement can defer a complete block or an `if` statement. For a
deferred `if`, the condition is evaluated when the deferred action runs, not
when the `defer` is registered:

```odin
{
	defer {
		foo();
		bar();
	}
	// This is equivalent to `defer { if (cond) { bar(); } }` because the `if` is
	// a statement in its own right.
	defer if (cond) {
		bar();
	}
}
```

Defer statements are executed in the reverse order that they were declared:

```odin
defer fmt.println("1");
defer fmt.println("2");
defer fmt.println("3");
```

Will print 3, 2, and then 1.

A deferred operation that returns a `Result` must handle that result within the
deferred action. It cannot propagate failure with `or_return`:

```odin
read_file :: proc() -> Result(Unit, io.Error) {
	file := fs.open_read("my_file.txt") or_return;
	defer {
		switch (error in file.close()) {
		case .ok:
		case .err: fmt.eprintln("close failed:", error);
		}
	}
	// Use `file` here.
	return .ok(Unit{});
}
```

`file` is a managed local, so its `drop` closes any still-live handle on scope
exit. The explicit close above observes a close failure; reporting that failure
does not replace the procedure's return value.

Defer cannot change a procedure's named return values, since it runs after they have been returned:

```odin
foo :: proc() -> (n: int) {
	defer {
		n = 456; // This does not change the returned value of `n`.
	}
	n = 123;
	return;
}
```

### when statement

`when` performs structural source selection: its condition decides which source branch exists and is semantically checked. It is not a compile-time `if` — an ordinary `if` already runs normally during compile-time evaluation.

- Each condition must be a constant expression because a `when` statement is evaluated at compile time.
- Statements within a branch do not create a new scope.
- The compiler checks only the branch belonging to the first true condition.
- An initial statement is not allowed in a `when` statement.
- `when` statements are allowed at file scope.

The contents of a `when` branch match its location. Inside a procedure, a selected branch contains ordinary statements. At file scope, it contains top-level items, so it may conditionally provide imports, foreign declarations, `impl` blocks, and declarations, but not executable expression statements. In either location the braces used by `when` do not introduce a scope; the selected contents behave as if they had appeared directly at the surrounding location.

Example:

```odin
print_architecture :: proc() {
	when (LOKE_ARCH == .I386) {
		fmt.println("32 bit");
	} else when (LOKE_ARCH == .Amd64) {
		fmt.println("64 bit");
	} else {
		fmt.println("Unsupported architecture");
	}
}
```

The selected branch is type-checked after selection; unselected branches are discarded after parsing. This supports platform-specific code without textual preprocessing.

See [Conditional compilation](#conditional-compilation) for built-in constants that a `when` statement can use.

### Branch statements

#### break statement

`break` exits the innermost enclosing `for`, `foreach`, or `switch`. It takes no operand, and using it outside those constructs is an error. Conditions and ordinary blocks are not breakable constructs.

```odin
for (cond) {
	switch (next_action()) {
	case .stop:
		if (cond) {
			break; // exits the innermost construct: the switch
		}
	case:
	}

	break; // exits the innermost construct: the for loop
}
```

#### continue statement

`continue` starts the next iteration of the innermost enclosing `for` or `foreach`. It takes no operand, and using it outside a loop is an error.

```odin
for (cond) {
	if (get_foo()) {
		continue;
	}
	fmt.println("Hellope");
}
```

# 6. Procedures & Functions

## Procedures

A procedure contains executable code. The `proc` keyword defines a procedure literal:

```odin
fibonacci :: proc(n: int) -> int {
	if (n < 1) {
		return 0;
	}
	if (n == 1) {
		return 1;
	}
	return fibonacci(n-1) + fibonacci(n-2);
}

fmt.println(fibonacci(3)); // 2
```

**Procedure literals do not capture local state.** A procedure literal can refer to constants, types, and file-scope declarations. It cannot refer to local variables or parameters of an enclosing procedure. Loke has no closures. A procedure value is one code pointer without an environment. Pass callback state explicitly, usually as a `rawptr` or typed user-data parameter.

This rule keeps [borrow and lifetime](#borrows-and-lifetimes) analysis local. A procedure literal cannot capture and retain a borrow.

### Parameters

A procedure can have zero or more parameters. This procedure multiplies two integers:

```odin
multiply :: proc(x: int, y: int) -> int {
	return x * y;
}
fmt.println(multiply(137, 432));
```

Consecutive parameters can share one type annotation. Thus, `x: int, y: int` can be written as `x, y: int`:

```odin
multiply :: proc(x, y: int) -> int {
	return x * y;
}
fmt.println(multiply(137, 432));
```

#### Parameter semantics and ABI lowering

By default, procedures use the `loke` calling convention. It uses the platform C ABI as a base and defines its own deterministic classification of parameters and results. It adds no implicit environment or service argument. Every caller and callee compiled for the same target ABI must use the same classification; indirect passing is not a choice they may make independently at each call.

The source-level parameter mode is decided before ABI lowering:

| Parameter form | Source-level meaning |
| --- | --- |
| `value: T` | Immutable local binding; no ownership transfer |
| `value: []T` | Immutable borrowed view with read-only elements |
| `value: []mut T` | Immutable borrowed view whose elements may be modified |
| `value: inout T` | Exclusive mutable borrow of the caller's variable |
| `value: move T` | Ownership transfer from caller to callee |

A `value: T` parameter is never made `inout` by its machine representation. A trivial value behaves as an immutable callee-local; a managed owner (including a struct or fixed array with managed fields) is a non-owning immutable borrow for the call, cloning nothing and transferring nothing, with reached storage protected by [Borrows and lifetimes](#borrows-and-lifetimes).

Returning such a borrowed parameter by value performs a logical clone, since the callee owns nothing to move out: a mutable owner clones into `mem.default_allocator()` unless the procedure constructs the result with another allocator, while `string` and `shared(T)` retain their shared allocation. Returning a borrowed value whose clone is disabled is a compile-time error. Returning a managed local, temporary, or `move` parameter instead transfers ownership without cloning. A procedure needing allocator-controlled result storage takes an allocator parameter and constructs against it.

After these rules, the ABI may pass a parameter in registers, an argument slot, or indirectly through a hidden pointer to caller-prepared temporary storage. That temporary is valid until the call completes, cannot be retained by the callee, and grants no permission to modify the caller's variable; `&value` inside the procedure addresses the callee-local binding. This lowering is an implementation detail of the `loke` convention; a foreign procedure follows its declared foreign ABI, including that ABI's aggregate-passing rules.

#### Copy-cost diagnostics

Size is never a type error, and a large type does not by itself require a warning.

An implementation should provide a configurable warning for an expensive copy or `clone`. A **copy site** is a point that duplicates a value instead of moving or borrowing it. Copy sites include:

- a trivial aggregate copied into a `value: T` parameter
- a binding such as `x := big_owner`
- an [assignment](#assignment-statements) such as `x = big_owner`
- return of a borrowed managed owner by value

An ordinary `value: T` parameter borrows a managed owner and is not a copy site. The diagnostic should identify the operation and its approximate cost:

```text
warning: this binding copies 8192 bytes from `source`
note: the copy could not be elided
help: use `move(source)` if `source` is no longer needed
help: take a pointer or `shared(T)` if the two names should share one value
```

The threshold is target-specific and not part of the language semantics. The warning must not recommend `inout` solely as an optimization, since `inout` grants mutation rights and changes which aliases are legal. Being a diagnostic and not a rule, it may also appear as an inline copy marker via [show-desugaring](#operator-lookup-and-overload-resolution).

```odin
sum :: proc(values: [dynamic]int) -> int {
	// `values` is a read-only borrow; no array copy is made.
	result := 0;
	foreach (value in values) {
		result += value;
	}
	return result;
}
```

`sum(values)` borrows, while `local := values` in the same procedure clones; both are unmarked and one character apart. A large or allocating copy at such a site is reported by the copy-cost diagnostic, not forbidden. When two names must refer to one value, take a pointer or `shared(T)`; when the source is finished, write `move`.

Use `inout` for a mutable borrow and `move` when a procedure must take ownership:

```odin
sort_in_place :: proc(values: inout [dynamic]int) {
	values.sort();
}

process_owned :: proc(values: move [dynamic]int) {
	values.sort();
	consume(values);
}

sort_in_place(inout numbers);
process_owned(move(numbers));
```

**Both non-default modes are required at the call site, not just at the declaration.** An argument to an `inout` parameter must be written `inout expr`, and an argument to a `move` parameter must be written `move(expr)`. Omitting the marker is an error naming the parameter and the mode it needs, so a reader sees at the call which arguments may be modified and which are given away.

`move(x)` is an [expression](#assignment-statements) that produces a value,
writes the inert representation to a lexical `x`, and marks it dead; it is
equally usable in an assignment or a `return`. It cannot target static-duration
storage. `inout x` is not an expression and produces no value; it selects a
parameter mode and may appear only in an argument position, in a procedure
[result](#inout-results) — of which an
[`operator([])` overload](#indexing-and-slicing) is the common case — and where
a mutable receiver is
passed. Method-call syntax supplies an `inout` marker implicitly for its
receiver: `numbers.sort()` may call an `inout self` method with no marker before
the receiver — the one place call-site mode visibility yields to method syntax,
and it yields only for a borrow that ends with the call. A [consuming
receiver](#receiver-forms) is written `move(value).method()` like any other
transfer, because it leaves the source dead. Non-receiver arguments get no
exception at all. See [Borrows and lifetimes](#borrows-and-lifetimes) for the
complete rule.

#### Local copies of parameters

An immutable parameter can be copied into a mutable local with a different name,
subject to the type's ordinary copy rules. Modifying the local binding does not
modify the caller's binding. An `inout` parameter instead permits modifying the
caller's variable directly.

```odin
foo :: proc(x: int) {
	remaining := x; // mutable local copy; x remains immutable
	for (remaining > 0) {
		fmt.println(remaining);
		remaining -= 1;
	}
}
```

#### Variadic parameters

A variadic procedure accepts a variable number of arguments:

```odin
sum :: proc(nums: ..int) -> (result: int) {
	result = 0;
	foreach (n in nums) {
		result += n;
	}
	return;
}
fmt.println(sum());              // 0
fmt.println(sum(1, 2));          // 3
fmt.println(sum(1, 2, 3, 4, 5)); // 15

odds := []int{1, 3, 5};
fmt.println(sum(..odds));        // 9, passing a slice as varargs
```

#### One result

A procedure returns at most one value. `Results` is one `Result_Type`, never a list, and the result is anonymous — there is no name to fill in and no result local to assign. A procedure with a result must `return expression;` on every path that leaves it; a bare `return;` there is an error.

To hand back several values, return one [anonymous
record](#anonymous-records) and [destructure](#destructuring) it at the call
site:

```odin
swap :: proc(x, y: int) -> (first: int, second: int) {
	return {first = y, second = x};
}
a, b := swap(1, 2);
fmt.println(a, b); // 2 1
```

The parenthesised result spelling is therefore one record type, at any arity. An unlabelled `(T, U)` result is not a type and is rejected.

#### `inout` results

A result may be declared `inout T`. The procedure then returns a **mutable borrow of a place** rather than a value, and the corresponding `return` expression is written `return inout place`. Any procedure may declare one;
[`operator([])`](#indexing-and-slicing) is the common case rather than the only one, and it is what makes `grid[3, 2] = 1.0` and `&grid[3, 2]` work.

```odin
pick :: proc(xs: inout [4]int, index: int) -> inout int {
	return inout xs[index];
}

values := [4]int{1, 2, 3, 4};
pointer := &pick(inout values, 2);
pointer^ = 99;                      // writes `values[2]`
```

The returned expression must denote an assignable place of exactly the declared type; there is no result conversion, and a value expression is rejected. A call whose result is `inout T` is itself a place: it may be assigned to, have its address taken, and be passed as an `inout` argument. It is not a first-class reference type — the mode may be written on a result, never on a variable, field, or container element.

An `inout` result is a [borrow carrier](#storage-roots-and-borrow-carriers), and
its lifetime follows exactly the rules a returned `^T` follows under
[Temporaries and procedure boundaries](#temporaries-and-procedure-boundaries):
it derives root provenance from the procedure's `inout` parameters, `inout` receiver, and other borrowed arguments, or from an allocation or static root.
An ordinary `value: T` parameter is a callee-local binding, so a place projected out of one carries no caller provenance and the result cannot outlive the call expression.

```odin
escape :: proc() -> inout int {
	local := [4]int{1, 2, 3, 4};
	return inout local[0];   // no caller root: the result ends with the call
}
```

Because the borrow is mutable, the caller's root is exclusively loaned for as long as any copy of the result is live, under [the one
rule](#capabilities-and-the-one-rule).

#### Named arguments

A call can name its arguments. Named arguments show the parameter for each value and do not depend on parameter order:

```odin
create_window :: proc(title: string, x, y: int, width, height: int, monitor: ^Monitor) -> (^Window, Window_Error) {...};

window, err := create_window(title="Hellope Title", monitor=nil, width=854, height=480, x=0, y=0);
```

One call can contain positional and named arguments. Positional arguments must occur before named arguments.

An `inout` argument may also be named, with the mode remaining visible after the `=`: `update(target=inout value)`. A named `move` argument uses the ordinary expression form, `store(value=move(source))`.

```odin
foo :: proc(value: int, name: string, x: bool, y: f32, z := 0) { };
foo(134, "hellope", x=true, y=4.5);
```

#### Default values

A parameter can have a default value. The call uses the default when it omits that argument:

```odin
create_window :: proc(title: string, x := 0, y := 0, width := 854, height := 480, monitor: ^Monitor = nil) -> (^Window, Window_Error) {...};

window1, err1 := create_window("Title1");
window2, err2 := create_window(title="Title1", width=640, height=360);
```

An input parameter's default is an ordinary expression, not necessarily a
compile-time-known value. The expression is evaluated once for each call that
omits that argument; it is not evaluated when the caller supplies the
argument. Names in the expression are resolved in the lexical scope of the
procedure declaration.

A default may additionally reference `self` and ordinary parameters declared to
its left. It may not reference its own parameter or any parameter to its right,
even when a later parameter is supplied by name at a particular call. This makes
every referenced parameter initialized before the default is evaluated and
keeps the meaning independent of the caller's argument ordering. `$` parameters
are compile-time values and may be referenced when they are declared to the
left under the same rule.

Only ordinary value parameters may have defaults. An `inout` parameter needs a caller-owned place, a `move` parameter must show the ownership transfer at the call site, and a variadic parameter is supplied by its argument sequence; defaults on any of those three forms are therefore rejected.

Defaults belong to a named declaration, not its procedure type. A call to a directly named procedure, method, or procedure group may omit arguments and uses that declaration's defaults; a call through a procedure value (a callback, or any expression typed only as a procedure type) must supply every non-variadic parameter. This is why defaults do not participate in procedure-type compatibility.

Allocator-taking procedures conventionally default to the program provider. The
provider implementation is selected once by the final build, while its returned
`Allocator` remains an ordinary runtime value:

```odin
read_file :: proc(
	path: string,
	allocator := mem.default_allocator(),
) -> ([]byte, Error) {...}

data, err := files.read_file("data.bin");
scratch_data, scratch_err := files.read_file("scratch.bin", allocator=scratch);
```

The compiler-provided [`caller_location()`](#caller_location) expression is also
valid as a default and denotes the source location of the call. Defaults exist only for parameters; a result is anonymous, so there is no result
local to give one.

#### Explicit procedure overloading

Procedure overloads are declared explicitly as named procedure groups:

```odin
bool_to_string :: proc(b: bool) -> string {...};
int_to_string  :: proc(i: int)  -> string {...};

to_string :: proc{bool_to_string, int_to_string};
```

Each member retains its ordinary name and may be called directly. A call through the group uses the [overload-resolution rules](#operator-lookup-and-overload-resolution). An unresolved tie is
a compile-time error.

```odin
foo :: proc{
	foo_bar,
	foo_baz,
	foo_baz2,
	another_thing_entirely,
}
```

## Generics

Generics let a procedure or data type bind compile-time type or value parameters and use them throughout its definition.

The `$` prefix always introduces a specialization-time input or pattern name. It
is used by explicit generic parameters, inferred type-shape parameters, and
static `foreach` bindings. It is required at the binding site and is not written
when the bound name is subsequently used. A computed local result uses the
ordinary constant spelling `name :: expression`; `$` is not a second constant
declaration operator.

Generics are compile-time constructs and are **not part of an ABI**. A generic procedure or type has no runtime representation before instantiation. It cannot have `@(export)`, use a foreign [calling convention](#calling-conventions), occur in a `foreign` block, or be stored in a procedure value.

Each concrete instantiation follows the normal ABI rules. To expose generic behavior to foreign code, create an instantiation and wrap it in a concrete [foreign-ABI-safe](#foreign-abi-safe-types) procedure. Code sharing between instantiations is an implementation detail and has no observable ABI effect.

### Explicit generic parameters

An explicit generic parameter is supplied by the caller. A parameter of type `type` receives a type; other parameter types receive compile-time constant values.

#### Procedures with explicit generic parameters

Prefix a parameter name with `$` to require a compile-time argument. The following example uses two compile-time parameters to initialize an array of known length:

```odin
make_f32_array :: proc($N: int, $val: f32) -> (res: [N]f32) {
	res = {};
	foreach (i in 0..<N) {
		res[i] = val*val;
	}
	return;
}

array := make_f32_array(3, 2);
```

Types can also be explicitly passed through a `$` parameter of compile-time-only type `type`:

```odin
my_new :: proc($T: type) -> ^mut T {
	switch (ptr in new(T)) {
	case .ok: return ptr;
	case .err: panic("allocation failed");
	}
}

ptr := my_new(int);
```

#### Generic data types

Structures and unions declare generic parameters using the same parameter-list shape as procedures. Generic struct:

Arguments whose parameter type is `type` are types; arguments to any other parameter are compile-time constant expressions. Bare names are resolved after parsing, so both `Buffer(Element, Count)` and `Buffer(u8, 4096)` use the same argument syntax. A value argument is not restricted to an identifier.

```odin
Table_Slot :: struct($Key, $Value: type) {
	occupied: bool,
	hash:    u32,
	key:     Key,
	value:   Value,
}
slot: Table_Slot(string, int);
```

Generic union:

```odin
Error :: enum {Foo0, Foo1, Foo2};
Param_Union :: union($T: type) @(failure=failed) { value: T, failed: Error }
r: Param_Union(int) = .value(123);
r = .failed(Error.Foo0);
```

Record and union generic parameters always require `$`, like compile-time procedure parameters, keeping every binding site explicit.

### Inferred generic parameters

An inferred generic parameter is bound from the type or shape of a runtime argument. In this case `$` appears at the binding position inside the parameter type.

#### Procedures with inferred generic parameters

```odin
foo :: proc($N: $I, $T: type) -> (res: [N]T) {
	// `N` is the constant value passed
	// `I` is the type of `N`
	// `T` is the type passed
	fmt.println("Generating an array of type", typeid_of(type_of(res)),
	            "from the value", N, "of type", typeid_of(I));
	res = {};
	foreach (i in 0..<N) {
		res[i] = i*i;
	}
	return;
}

T :: int;
array := foo(4, T);
foreach (v, i in array.indexed()) {
	assert(v == T(i*i));
}
```

### Specialization

A generic parameter can require a structural shape. Write the shape in the parameter type and prefix the parts to bind with `$`:

```odin
// Only allow read-only slices, binding their element type.
// A []mut E argument may call this through capability weakening.
first_slice_value :: proc(values: []$E) -> Option(E) {
	if (len(values) == 0) {
		return .none;
	}
	return .some(values[0]);
}

Table_Slot :: struct($Key, $Value: type) {
	occupied: bool,
	hash:     u32,
	key:      Key,
	value:    Value,
}
Table :: struct($Key, $Value: type) {
	count:     int,
	allocator: mem.Allocator,
	slots:     []mut Table_Slot(Key, Value),
}

// Only allow specializations of `Table`, binding its parameters.
allocate :: proc(table: ^Table($Key, $Value), capacity: int) {
	...
}

find :: proc(table: ^Table($Key, $Value), key: Key) -> Option(Value) {
	...
}
```

A parameter written this way is more specific than an unconstrained `$T`, which is what tie-breaker 4 of [overload resolution](#operator-lookup-and-overload-resolution) selects on. Specialization is therefore how a procedure group narrows one of its members to a shape.

There is no separate form binding a name to the *whole* matched type alongside its parts; where the aggregate is needed — as a result type, say — it is written out:

```odin
swapped :: proc(pair: [2]$E) -> [2]E {
	return [2]E{pair[1], pair[0]};
}
```

### where clauses

A bound on generic parameters to a procedure or record can be expressed using a `where` clause immediately before the opening `{`. Every bound is a compile-time boolean expression evaluated while the declaration is instantiated.

The clause is part of the same declaration as the signature it constrains. No semicolon separates them; the declaration is terminated by its body, exactly as it would be without the clause. Multiple bounds are separated by commas and all must hold.

Because the clause is followed immediately by the declaration's `{`, **a bound may not have a composite literal at its top level**: in `where Additive(T) {` the brace opens the body, never a literal `Additive(T){...}`. A bound that needs a composite literal parenthesises it, as in `where (Limits{0, N}).valid()`.

A bound may reference generic type and value parameters in scope from the declaration or an enclosing generic `impl`, plus constants, types, interface applications, compile-time built-ins, and ordinary procedures that can be evaluated at compile time. It may not depend on a runtime parameter, local variable, mutable global, or call that requires runtime execution. A declaration with no generic parameters in scope therefore cannot have a `where` clause. Runtime preconditions are ordinary `if` and `assert` statements in the procedure body.

Some cases that a where clause may be useful:

- Generic parameter checks for procedures. The bound here is about what `E` *can do*, so it is written as an [interface](#interfaces-as-reusable-constraints) rather than as a type predicate:

```odin
// A fixed array has no `.x`/`.y` swizzle selectors; index it.
cross_2d :: proc(a, b: [2]$E) -> E
	where interfaces.Numeric(E) {
	return a[0]*b[1] - a[1]*b[0];
}
cross_3d :: proc(a, b: [3]$E) -> [3]E
	where interfaces.Numeric(E) {
	x := a[1]*b[2] - a[2]*b[1];
	y := a[2]*b[0] - a[0]*b[2];
	z := a[0]*b[1] - a[1]*b[0];
	return [3]E{x, y, z};
}

a := [2]int{1, 2};
b := [2]int{5, -3};
fmt.println(cross_2d(a, b));

x := [3]f32{1, 4, 9};
y := [3]f32{-5, 0, 3};
fmt.println(cross_3d(x, y));

// Failure case
// i := [2]bool{true, false}
// j := [2]bool{false, true}
// fmt.println(cross_2d(i, j))
```

- Solving disambiguations with polymorphic procedures in a procedure grouping:

```odin
foo :: proc(x: [$N]int) -> bool
	where N > 2 {
	fmt.println(source_location().procedure, "was called with the parameter", x);
	return true;
}

bar :: proc(x: [$N]int) -> bool
	where 0 < N,
	      N <= 2 {
	fmt.println(source_location().procedure, "was called with the parameter", x);
	return false;
}

baz :: proc{foo, bar};

x := [3]int{1, 2, 3};
y := [2]int{4, 9};
ok_x := baz(x);
ok_y := baz(y);
assert(ok_x == true);
assert(ok_y == false);
```

- Restrictions on generic parameters for record types. Note the division of labour: `interfaces.Integral(T)` is a capability requirement, while `N > 2` is a predicate over a value and is what a `where` clause is for:

```odin
Foo :: struct($T: type, $N: int)
	where interfaces.Integral(T),
	      N > 2 {
	x: [N]T,
	y: [N-2]T,
}

T :: i32;
N :: 5;
f: Foo(T, N);
static_assert(size_of(f) == (N+N-2)*size_of(T));
```

# 7. Ownership & Lifetimes

## Borrows and lifetimes

Loke checks the lifetime of locally visible borrows. The model is based on **storage roots**, not on whether cleanup is automatic.

### Storage roots and borrow carriers

Every ordinary variable and value temporary owns its inline storage. It is a storage root for borrows of that storage. A root may additionally own a backing allocation or another resource, as a dynamic array or `File` does, but that is a separate lifecycle property. An allocator-created allocation is also a storage
root even though it is reached through a pointer.

Cleanup policy does not change which value is the root. A borrow of an
automatic owner and a borrow of one that will be forgotten are checked borrows in exactly the same way — and forgetting an owner invalidates its borrows just as dropping it would.

A **borrow carrier** is a value that refers to another root without owning that root. The built-in carriers are:

- `^T` and `^mut T`, immutable and mutable single-value pointers;
- `[]T` and `[]mut T`, immutable and mutable slices;
- `string_view`, `cstring_view`, and `any_view`;
- `dyn Interface` and `dyn mut Interface` views, and compiler-known iterators;
- default and `inout` parameter access paths for the duration of a call;
- an [`inout` result](#inout-results), a mutable borrow returned to the caller.

Copying a borrow carrier copies the view and its root provenance, never the pointee.
It creates no cleanup obligation. The carrier variable owns only its own pointer, length, or witness-table bits.

Root provenance is compile-time metadata, not part of a value's layout or ABI. It identifies the root and the capability through which it is accessed.
The following operations preserve root provenance:

- `&place` creates a checked immutable `^T` borrow of the root containing
  `place`, and `&mut place` an exclusive `^mut T` one;
- slicing creates a checked `[]T` or `[]mut T` borrow of the sliced root;
- conversion to a built-in view and compiler-known iteration preserve the source root;
- a borrow returned from a Loke procedure derives root provenance from its borrowed arguments as described below;
- `new` and `new_clone` create a new allocation root and return a checked
  `^mut T` pointer to its first value, which is the capability `free` requires.

#### How root and region provenance compose

Loke performs two distinct lifetime analyses over related values:

- **Root provenance** belongs to a non-owning pointer, slice, or other borrow carrier. It identifies the storage root whose continued existence and access rules make that borrow valid.
- **Region provenance** belongs to an owning value or allocation root whose backing storage came from an allocator region. It identifies the region that must remain valid while that owner or allocation is live. See
  [Allocators](#allocators).

These are not two names for the same property: root provenance answers "which storage does this view borrow?" and region provenance answers "which allocator region keeps this owned storage valid?" They compose transitively — if owner `value` is backed by region `R` and `view` borrows `value`, then `view` depends directly on `value` and indirectly on `R`:

```text
view --borrows--> value --backed by--> R
```

The root analysis prevents `view` from outliving, conflicting with, or surviving
invalidation of `value`. The region analysis prevents `value` from outliving or
surviving reset of `R`. Resetting `R` is rejected while either the owner or a
checked borrow transitively depending on it is live. Passing either analysis
does not waive the other.

Operations propagate the two dependencies differently:

- Borrowing an owner creates a root dependency on that owner; its region
  dependency is inherited transitively rather than copied onto the borrow as a
  second ownership claim.
- Moving an owner is forbidden while one of its checked borrows is live. The
  move transfers the owner's region dependency to the destination, but does not
  make the destination borrow the source variable.
- Cloning creates a new owner. An allocating clone receives the destination
  allocator's region provenance; a documented logical clone that retains shared
  storage retains that allocation's region provenance.
- Returning a borrow propagates root provenance from borrowed parameters.
  Returning a moved owner propagates region provenance from the moved value.
  Constructing an owning result with an allocator parameter propagates that
  allocator's region provenance. These cases are recorded separately in the
  procedure's result-provenance summary.
- Storing a borrow inside a record, union, or container preserves its root
  provenance along that value's carrier path. Converting it through
  `core:unsafe`, or storing it in a `rawptr` or `[^]T` field, loses checked root
  provenance as described under [What is not checked](#what-is-not-checked).
  Losing provenance does not extend the root or allocator region and therefore
  cannot make an otherwise invalid lifetime safe.

For example, the two rejected returns below fail for different reasons:

```odin
bad_view :: proc() -> []u8 {
	arena := mem.Arena.init();
	bytes: [dynamic]u8 via arena.allocator() = {};
	return bytes[:]; // ERROR: borrow outlives the local root `bytes`
}

bad_owner :: proc() -> [dynamic]u8 {
	arena := mem.Arena.init();
	bytes: [dynamic]u8 via arena.allocator() = {};
	return move(bytes); // ERROR: owner outlives allocator region `arena`
}
```

The pointee's cleanup policy does not decide whether a pointer is a borrow: a `&` pointer is a borrow whatever becomes of its root, and a `new` pointer designates a separate allocation root without owning it or acquiring automatic cleanup. `free` ends the allocation root and invalidates every checked pointer derived from it. To make an allocation a move-only, auto-cleaned value, wrap the pointer and allocator in a resource type with a `drop` hook.

`rawptr` and `[^]T` carry no checked provenance. A `^T` received from foreign code, reconstructed by unsafe code, or loaded from storage whose provenance the compiler does not track is also an unchecked address despite having the same machine type as a checked `^T`. Dereferencing an unchecked address is the programmer's responsibility.

#### Values that contain borrows

Putting a borrow inside a value does not discard what the borrow owes. A struct, union, fixed array, or container whose fields reach a built-in carrier *carries* those borrows: `Holder :: struct { view: []int }` is checked wherever a bare
`[]int` is, and `return Holder{local[:]}` is rejected for the same reason
`return local[:]` is. An `Option` or a `Result` is a union like any other, so
wrapping a borrow in one keeps it, and unwrapping it — a case binding,
`or_else`, `or_return` — hands the same borrow on.

The compiler enumerates a type's **carrier paths**: the projection paths from the value to each built-in carrier reachable inside it. A record contributes one path per field, a union one per alternative, a small fixed array one path per element,
a dynamic array one wildcard element path standing for every element, and a map separate key and value paths under an entry step. A map's key set is not part of its type the way an array's length is, so the type provides a small number of entries and each procedure body decides which of its constant keys uses which. Each path
keeps its own capability, so a record holding one `[]int` and one `[]mut int` has no single aggregate capability. A field that reaches no carrier contributes nothing, so a recursive type built from scalars enumerates to nothing at all.

The enumeration is bounded: it stops at a fixed depth, a fixed array longer than a small limit contributes one wildcard element path rather than one per element,
a map whose entry would be wide keeps a single wildcard entry, and a type with more paths than the limit collapses to one path for the whole value. An unknown index or key, and a constant key past the entry limit, use a wildcard step, which
overlaps every element or entry: such a read sees all of them and such a write joins into all of them rather than replacing any. A cut path stands for every carrier beneath it and joins what they hold, so a limit costs precision and
never a check.

A user record is still not a new *carrier*; it is a value that contains carriers.
Version 1 has no user-defined provenance annotation, so a record of `rawptr` or
`[^]T` fields carries nothing to check, and one reconstructed from storage the compiler does not track carries unknown provenance rather than none.

### Capabilities and the one rule

An immutable borrow permits reads only. `^T`, `[]T`, `dyn I`, `string_view`, and ordinary read-only parameter access are immutable borrows. While one is live, the root may be read through compatible paths — including through other immutable borrows of the same place, of which any number may be live at once — but it may not be written, moved, dropped, freed, or invalidated.

A mutable borrow permits reads and writes through that borrow. `^mut T`,
`[]mut T`, `dyn mut I`, and `inout` are mutable borrows. While one is live, the root cannot be accessed through a competing name or overlap another live borrow.
An `inout` borrow of the complete owner may update its header and invalidate its previous contents; an interior `^mut T` or `[]mut T` borrow cannot.

> A checked borrow may be used only while its root is live, and every access to
> the root while the borrow is live must be compatible with the borrow's
> capability.

#### Weakening and read-only reborrows

A mutable carrier implicitly weakens to the read-only carrier of the same shape.
The reverse never happens: a read-only carrier does not strengthen, whatever the storage behind it was declared as.

Where the weakening happens decides what it costs. A **fresh** borrow — `&mut x`
written straight into a `^T`, or `xs[0:2]` into a `[]T` — is simply created read-only; the destination settles a capability the borrowing expression never committed to, and nothing is suspended.

Weakening an **existing** mutable carrier is a read-only reborrow of it. While the reborrow is live, the carrier it was taken from is suspended and may not be used; after the reborrow's last use, the source is usable again. Without this a mutable alias could write behind the reborrow's back:

```odin
source := numbers[0:2];      // []mut int
reborrow: []int = source;    // a read-only reborrow of `source`
fmt.println(reborrow[0]);
source[0] = 50;              // ERROR: `source` is suspended here
fmt.println(reborrow[1]);    // ... because this keeps the reborrow live
```

Moving the last use of `reborrow` above the write makes the same program legal.
The diagnostic names both ends: where the reborrow was taken, and the later use that keeps it live.

#### Places and overlap

Borrow compatibility is decided for **places**, not only for variable names. A place consists of its storage root and a normalized projection path through fields, indices, ranges, and dereferences. Places with different roots do not overlap. Within one root, a path overlaps itself and every prefix or descendant of itself.

The compiler may prove distinct struct fields and distinct constant fixed-array indices or ranges disjoint. It composes nested slices and reslices before making that comparison. Union fields, dynamic indices or ranges, opaque dereferences, and user-defined indexing or slicing are conservative projections: they overlap every path that might designate the same storage. A checked pointer whose source
is known retains the possible root and projection paths from that source.

An operation on a complete root or container header overlaps every descendant.
Consequently, proving two element paths disjoint can permit simultaneous loans of those elements, but cannot permit moving, dropping, replacing, freeing, or otherwise invalidating their common root while either loan is live.

A value taken out of a container carries what that element held, not a borrow of the container it came from: `pop`, `remove`, `remove_unordered`, and a map's
`remove` hand back the element's own dependencies. The removal still invalidates borrows of the container's storage, which is a separate question from what the removed value refers to.

Moving, dropping, freeing, fully assigning, or exchanging a root invalidates borrows of its previous value. Container operations such as `append`, `resize`, `reserve`, `shrink`, `clear`, `remove`, map insertion, and any user operation whose `self` parameter is `inout` also invalidate element and view borrows. Reallocation is
a common reason, but changing which logical elements exist is sufficient.

A borrow is live from its creation to its last use within the procedure body.
Copies of a borrow extend the same loan to the last use of any copy. A borrow that is never used again stops constraining its root immediately.

```odin
numbers := [dynamic]int{1, 2, 3};

view := numbers[:];
fmt.println(view[0]);   // last use of `view`
numbers.append(4);      // OK: the borrow has ended

second := numbers[:];
numbers.append(5);      // ERROR: invalidates `second`
fmt.println(second[0]);
```

The diagnostic must name the root, the borrow's creation, the conflicting or invalidating operation, and the later use that keeps the borrow live.

### Temporaries and procedure boundaries

A value temporary lives until the end of its complete expression. A borrow derived from it may be used during that expression, including by a called procedure, but cannot escape it. A temporary in a `foreach` iterable, `switch` subject, or `if`, `for`, or `switch` initial statement instead lives until that complete statement ends.

A borrow derived from a local root cannot be returned:

```odin
bad :: proc() -> []int {
	local := [dynamic]int{1, 2, 3};
	return local[:]; // ERROR: `local` ends when the procedure returns
}
```

A borrow returned from storage reachable through a borrowed parameter derives root provenance from the borrowed arguments the procedure's result summary names
— every one of them at a call the compiler cannot resolve to a declaration:

```odin
first_half :: proc(values: []int) -> []int {
	return values[:len(values)/2];
}

numbers := [dynamic]int{1, 2, 3, 4};
view := first_half(numbers[:]); // borrows `numbers`

bad := first_half([dynamic]int{1, 2, 3, 4}[:]);
fmt.println(len(bad));
// ERROR: the result outlives the temporary argument, which ends with the
// statement that built it
```

Passing that same slice to something that consumes it within the statement is allowed, because the borrow never escapes the expression:

```odin
fmt.println(len([dynamic]int{1, 2, 3, 4}[:])); // fine
```

A [slice literal](#slice-literals) behaves differently, and the difference is what its backing storage is: its hidden `[N]T` is an ordinary frame owner in the surrounding lexical scope, while a `[dynamic]T` temporary owns an allocation that nothing keeps alive past the statement.

The default parameter binding itself is a callee-local read-only value. Taking `&parameter` borrows that local and cannot produce a returned pointer. An
`inout` parameter aliases the caller's root, so a borrow returned from it is derived from that root. Where a procedure has several borrowed arguments, which of them a returned borrow derives from is what the result summary below records; a call through a procedure value, which has no summary, conservatively derives
from all of them.

A checked pointer to an allocation root created by `new` or `new_clone` may be
returned because the allocation is not callee-local storage. The pointer's root
provenance and the allocation root's region provenance follow the result. This transfers release responsibility
by API convention, not by making `^T` an owning type; the compiler does not
require every manually allocated root to be freed.

For a direct call to a named Loke declaration or generic instantiation, the
compiler records a result-provenance summary with the declaration. For each
result it records two independent components when applicable:

- root provenance: borrowed parameters, static storage, `thread_local` storage,
  a fresh allocation root, or unknown root provenance;
- region provenance: allocator parameters, the region dependency of a moved or
  shared owner, a non-resettable static region, or unknown region provenance.

Where a parameter reaches a borrow through its own
[carrier paths](#values-that-contain-borrows), the summary records which of those
paths the result may name, so a helper returning one field of a record argument
substitutes that field's root rather than everything the argument holds.

At a direct call, the compiler substitutes the actual argument roots and
allocator regions into the corresponding component. The summary is compile-time
declaration metadata, is emitted for cross-package checking, and does not change
the runtime ABI. Its meaning is transitive across direct calls and independent
of declaration order, including forward and mutually recursive declarations.
Each concrete generic instantiation has its own summary.

An ordinary procedure value carries no such metadata. At a call through one, a returned pointer, slice, view, or [`inout` result](#inout-results) is conservatively derived from every borrowed argument the type does not exclude with [`@(escape=none)`](#escapelevel) (unknown root provenance if there is none), and an owning result retains the region provenance of every moved owner and allocator argument (unknown if none). Fresh-allocation root provenance is never preserved, so such a result cannot be passed to checked `free`; an API transferring allocation responsibility through indirect calls uses a move-only resource wrapper, not bare `^T`. Foreign results likewise begin with unknown provenance unless a wrapper establishes an owned resource.

Allocator-wide invalidation is the one effect propagated through arbitrary
ordinary procedure wrappers. A parameter marked
[`@(allocator_reset)`](#allocator_reset) states that a successful call may end
every allocation root in that allocator region. At the call, the compiler
rejects the reset while a value or checked borrow from the region is live.

#### Escape levels

What a call may keep of one argument is written on the parameter as
`@(escape=<level>)`, with four totally ordered levels:

| Level | The call may leave behind |
|---|---|
| `none` | nothing that depends on this argument, not even a result |
| `result` | a result may borrow it; this is the default |
| `stored` | it may also be retained in storage the caller owns |
| `static` | it may also be retained in storage that outlives the process |

An unwritten parameter is `result`, so an existing signature keeps its meaning.
The level is an upper bound on the body: a procedure whose result borrows a parameter written `@(escape=none)`, or which retains a parameter beyond its declared level, is rejected at the parameter's declaration.

The level belongs to the procedure type, as [`@(allocator_reset)`](#allocator_reset)
does, which is what makes it useful where there is no body to infer from. A `none` parameter keeps a scratch argument out of the result of a call through a procedure value, a procedure-typed parameter, or a generic instantiation.

The levels are part of the type's identity, so two procedure types differing only in a level are different types — but the difference orders one way. A callee may be assigned, passed, or returned as a procedure type whose levels are the same or
*higher* than its own, because it promises at least what that type asks; the
reverse is a type mismatch and needs no separate rule. What governs a call is always the type of the value called, so a procedure stored in a weaker type is called under the weaker promise, whatever its own body was written to keep.

`@(escape=...)` describes what a call keeps of a *borrow*. Writing it on a parameter whose type reaches no borrow carrier is an error rather than a no-op.

#### Retaining a borrow

A borrow written into storage that outlives the statement writing it is
**retained**. Three destinations are checked:

- `static` and file-scope storage, which outlives the process;
- `thread_local` storage, which outlives its thread;
- storage the caller owns, reached through an `inout` parameter, or through a
  `^mut T` or `[]mut T` the call received.

A destination is a place, not a name: a field of a global, a container element,
and a write through a pointer are all destinations. Where the place is reached
through a carrier — `p^.view`, `d[0].view` — the storage it names is whatever that
carrier borrows, so both the question and the borrow reach every root the carrier
may point at. What is written lands where the pointer points, not in the pointer,
and takes the destination's own capability as any other assignment does.

What a root proves depends on where it lives. A local, a value temporary, or a
literal's hidden array ends with the frame and satisfies none of the three.
Static and materialized storage satisfies all of them. `thread_local` storage
satisfies a thread-duration destination and not a process-duration one. An
allocation lives until it is released, which the release rules already police, so
retaining one is ordinary rather than proof of anything, and unknown provenance
proves nothing.

A parameter is answered by its written level and by nothing else, because only
the caller knows how long the storage behind it lives. Retaining one in
caller-owned storage requires `@(escape=stored)`, and in static or thread storage
`@(escape=static)`. The body is checked against the level it declares, and the
call site is checked against the argument actually supplied.

At a call, a parameter written `stored` or `static` is treated as the assignment
the callee is permitted to make: the argument's borrows reach every destination
the call can write — an `inout` parameter or receiver, or a mutable carrier whose
pointee or element could hold the borrow — and each of those asks the same
question the assignment would. A destination that cannot hold a borrow at all,
such as `inout int`, is not one. A destination in static or thread storage
needs a source that outlives it; a destination the caller merely passes on needs
the caller's own parameter to carry the contract; and a destination that is one of
the caller's own locals needs no contract at all, because the borrow simply
travels there and using it after its root has ended is already an error:

```odin
keep :: proc(destination: inout Holder, @(escape=stored) values: []int) {
	destination.view = values;
}

held: Holder;
{
	numbers := [3]int{1, 2, 3};
	keep(inout held, numbers[:]);
}
fmt.println(held.view[0]); // ERROR: `numbers` has ended
```

Writing a value into its own root, as `self.rest = self.rest[n:]` does, is not a
retention. A root outlives itself.

### What is not checked

The analysis is local to one procedure body, together with the recorded summary and declared levels of the procedures that body calls. Storing a borrow in a record field, container, global, or callback state is part of what it checks; see
[Values that contain borrows](#values-that-contain-borrows) and
[Retaining a borrow](#retaining-a-borrow). These cases remain the programmer's responsibility:

- dereferencing `rawptr`, `[^]T`, or a `^T` with unknown provenance;
- pointers or views manufactured or stripped of provenance through
  `core:unsafe`;
- aliases hidden by foreign code, and what a foreign procedure retains of a borrowed argument after it returns;
- transferring borrows or unchecked addresses between threads, and keeping a `thread_local` borrow past the end of its thread.

If a view has no locally provable lifetime, make an owned copy with `clone`, use `shared(T)`, or keep the lifetime correct as an explicit unsafe obligation.

### Debug-mode detection

When `LOKE_DEBUG` is set, an implementation is encouraged to put generation counters in managed containers and their views and trap after reallocation or logical invalidation. This is an implementation-defined debugging aid, not a language guarantee, and release builds are expected to omit it.

### The `unsafe` package

Operations that discard or manufacture provenance live in `core:unsafe`. It is an ordinary package; its visible import is the review mechanism.

```odin
import "core:unsafe"

raw := unsafe.raw_data(bytes);       // checked provenance is discarded
view := unsafe.cstring_view(raw);    // programmer promises the lifetime
```

Everything in `unsafe` is a promise by the programmer that the compiler cannot verify. It does not make the underlying storage owned or extend its lifetime.

# 8. Packages & Visibility

## Packages

A Loke program contains one or more packages. A Loke source file uses the `.loke` extension. A package is a directory of source files. Each file in the directory must have the same package declaration. An executable starts at the `main` procedure of package `main`.

### Program entry and exit

An executable is built from a package named `main` containing exactly one procedure named `main`. Its signature is `main :: proc()`: no parameters, no results, the `loke` calling convention. Command-line arguments are read from `os.args`. The exit status is 0 when `main` returns normally. `os.exit(code)` terminates the process immediately with the specified status.

Program startup has this order:

1. Runtime initialization, including the build-selected allocator and logging providers.
2. `main`.

Importing a package does not run package code. A package that needs runtime initialization must expose a procedure, and the application must call it explicitly. The application owns the returned state or explicitly shuts the package down.

Normal return from `main` runs its scope-exit actions before the process ends. Managed values at file scope are [not dropped](#values-that-outlive-every-scope). `os.exit` terminates immediately. It does not run `defer`, automatic `drop`, or thread-local cleanup. A [panic](#panics-and-unwinding) follows its selected panic strategy.

To return a nonzero status after cleanup, keep owned state in a helper procedure. Cleanup runs when the helper returns. `main` can then call `os.exit`:

```odin
run_application :: proc() -> int {
	// `initialize` returns Result(State, Error).
	switch (state in application.initialize()) {
	case .ok:
		defer application.shutdown(inout state);
		return application.run(inout state);
	case .err:
		return 1;
	}
}

main :: proc() {
	status := run_application();
	if (status != 0) { os.exit(status); }
}
```

#### Executable startup ABI

The compiler emits the executable's C entry, distinct from Loke's `main`. On Windows, `wmain(int, wchar_t **)` receives UTF-16 arguments, converts them once to process-lifetime cached UTF-8, then attaches the initial thread and calls `main`:

- `os.args` reads already-valid UTF-8; it needs no conversion or package initializer.
- An [object build](#build-configuration) emits no entry or argument conversion; `os.args` reports no arguments. Its foreign host owns startup and must supply its own argument mechanism if needed.

Unpaired surrogates in the incoming vector become U+FFFD.

#### `os.Args`

`os.args` has type `os.Args`, a stateless, read-only view of the process-lifetime argument vector. Its zero value denotes the whole vector.

| Operation | Result |
| --- | --- |
| `os.args.len()` | the argument count, including the executable path at index 0 |
| `os.args[i]` | an owning UTF-8 `string`, copied; out of range yields `""` |
| `foreach (a in os.args)` | a borrowed `string_view` per argument |
| `os.view_at(i)` | the same borrow by index; out of range yields `""` |

Indexing copies an owning string; iteration borrows runtime-owned bytes valid for the process lifetime. For immediate termination without cleanup, see [`os.exit`](#program-entry-and-exit).

### Import statement

The following program imports the fmt and os packages from the core library collection.

```odin
package main;

import "core:fmt";
import "core:os";

main :: proc() {
}
```

An import path prefix selects a library collection. For example, `core:` selects the core library collection. A path without a prefix is relative to the current file.

By convention, the package name is the last element of the import path. Thus, files in `core:fmt` normally declare `package fmt;`. The compiler does not require this convention. When possible, it uses the last path element as the default import name.

An import can specify an alias instead of the default name:

```odin
import "core:fmt";
import foo "core:fmt"; // reference a package by a different name
```

An import name is a lexical alias and nothing more. Two names for the same package refer to the same declarations, and an alias never creates a second instance of a package or of anything it owns.

Every source file must contain its package declaration. Package versions are selected by the build system or package manager and are not part of import syntax.

#### Import cycles

Import cycles between packages are rejected. The import graph must be a directed acyclic graph, and the compiler reports the cycle as a path of import statements.

The acyclic graph gives packages a deterministic dependency order for compilation and linking. Declarations *within* a package may refer to each other freely and in any order. Express a mutual dependency by merging the packages or by moving shared declarations to a third package that both packages import.

### Exported names

All declarations in a package are private to that package by default. A package's API is the set of declarations it marks public, so exporting is always a deliberate act.

The public attribute exports an entity from its package.

```odin
@(public)
my_variable: int; // visible to importers of this package
@(public)
my_other_variable: int;
```

`@(private)` names the default explicitly. It is redundant on its own, and exists so that a declaration can opt out of a file-wide `@(public)` package attribute.

**Loke has two visibility levels: package and public.** It has no file-private visibility. The package is the encapsulation boundary. Put code in a separate package when it needs a separate visibility boundary.

Struct fields use the same two levels. A field inherits the default selected by
the package declaration in its source file and may override that default with
`@(public)` or `@(private)`. Code in the declaring package may read, write, and
initialize package-visible fields; importing packages may do so only for public
fields. Positional aggregate construction does not bypass this rule: an
initializer that supplies an inaccessible field is rejected. The file-level
default chooses a field's visibility but does not create file-private access.

One predicate answers this question for reflection descriptors, field reads and
writes, `offset_of`, and both aggregate literal forms, so no path can reach a field another path hides.

#### Authoring a package

A package directory contains only one package. Each source file in that directory must have the same package name, for example `package main;`.

#### Organizing packages

Packages may be thematically organized by placing them in subdirectories of another package. For example: core:image/png and core:image/tga, as subdirectories of core:image. Nesting these packages is a helpful taxonomy. It does not imply a dependency: core:foo/bar does not need to import core:foo and reference anything from it.

Private-by-default visibility means a package that exists to export — a foreign binding, a thin wrapper — would otherwise need `@(public)` on every declaration. Apply the same attribute to the package declaration to make every declaration in that file public by default:

```odin
@(public)
package glfw;
```

This is also the one-line fix when porting a package written against a public-by-default language.

# 9. Runtime & Interop

## Built-in constants, values, and procedures

### Built-in constants

```text
false // unfixed boolean constant equivalent to the expression 0!=0
true  // unfixed boolean constant equivalent to the expression 0==0
```

### Built-in values

```text
nil   // unfixed nil value used for certain values
```

`---` is not a value or an initializer. It is declaration syntax used for a
foreign procedure with no Loke body.
Uninitialized lexical storage is requested by omitting a local initializer and
is governed by definite-initialization analysis rather than undefined behavior.

### Built-in procedures

There are two kinds of built-in procedures:

- Compiler defined
- Core library defined

For the full list, see the documentation for package `builtin`. The compiler-defined ones used by normative text in this document are:

| Procedure | Result |
| --- | --- |
| `len(value)`, `cap(value)` | Element or byte count, and capacity. Constant when the operand is constant |
| `size_of(T)`, `align_of(T)` | Size and alignment in bytes; compile-time constants. Accept a type or an expression |
| `offset_of(T, field)` | Byte offset of a field; a compile-time constant |
| `type_of(expr)` | The compile-time [`type`](#type-and-typeid) of an expression |
| `typeid_of(T)` | The runtime [`typeid`](#type-and-typeid) constant for a compile-time type |
| `type_info_of(id)` | read-only `^runtime.Type_Info` for a `typeid`; the table is shared static storage |
| `fields_of(T)`, `enum_values_of(T)` | Typed [compile-time reflection](#compile-time-reflection) descriptor arrays |
| `assert(condition, message := "")` | Phase-neutral check; failure panics at runtime or diagnoses a required compile-time evaluation |
| `panic(message)` | Panics at runtime or diagnoses the currently evaluated compile-time call |
| `new`, `new_clone`, `make`, `free`, `free_all`, `drop` | [Allocation and release](#allocators) |
| `exchange(inout destination, replacement)` | Replace a live place and return its previous value; see [Exchange](#exchange) |
| `transmute(T, value)` | Bit cast between two same-sized types with a [trivial lifecycle]|
| `move(value)` | Keyword form, not a call; see [assignment](#assignment-statements) |

`len`, `cap`, `size_of`, `align_of`, and `offset_of` all result in `int`.

`assert` and `panic` execute in the phase of the call that reaches them. In an ordinary runtime call they have their runtime behavior. In a procedure whose result is required at compile time, reaching a failed `assert` or any `panic` produces a compilation diagnostic with the evaluator call stack. `-no-assert` may remove runtime assertions, but it never removes an assertion reached during
required compile-time evaluation.

[`static_assert`](#static_assertboolean) independently requires its operand and check at compile time, even when it appears inside code that otherwise executes at runtime. `static_assert(false, message)` is therefore the compile-time unconditional-failure form. Neither spelling silently changes phase.

`move`, `drop`, and `exchange` operate on a **place** rather than only on values.
`move` is a keyword and looks like one; `drop` and `exchange` keep call
spellings but are equally compiler special forms, as described under
[Managed values and storage](#managed-values-and-storage) and
[Exchange](#exchange). Every other built-in listed here is an ordinary call.

`transmute(T, value)` is a bit cast conversion between two types of the same size. Both the source and destination must have a **trivial lifecycle**: they have no copy or drop hook, contain no managed owner, and are recursively bitwise-copyable. This prevents a bit cast from duplicating an owning representation or manufacturing a value whose cleanup invariant was never established.

```odin
f := f32(123);
u := transmute(u32, f);
```

It is an ordinary compile-time built-in, not an operator: a predeclared identifier whose first argument is a type, like `size_of(T)`.

This is akin to doing the following pointer cast manipulations:

```odin
f := f32(123);
u := (^u32)(&f)^;
```

Unlike that cast, `transmute` needs no addressable operand. It cannot reinterpret a managed or resource-owning value; low-level code manipulates such representations through raw storage in `core:unsafe` and is then responsible for establishing exactly one initialized owner.


## Error handling

### Typed fallibility

Absence and failure are **types**, not a trailing result. A procedure that may have no answer returns `Option(T)`; one that may fail returns `Result(T, E)`.
Both are ordinary [unions](#unions) declared in `base:runtime`, and both are recognised by their *shape* rather than by their names:

```odin
Unit :: struct {}

Option :: union($T: type) @(zero=none, failure=none) { none:, some: T }

@(require_results)
Result :: union($T, $E: type) @(failure=err) { ok: T, err: E }
```

`Option` designates `none` as both its zero and its failure, so an `Option` has an all-zero "absent" value and participates in the failure protocol. `Result` designates `err` as its failure and requires its results to be handled; it has no zero, because neither arm is one.

A **fallible expression** is one whose type is a union of exactly two variants with `@(failure=name)` written on it. That is the only thing
[`or_else`](#or_else-expression) and [`or_return`](#or_return-operator) look for, so a user-declared union is a first-class participant:

```odin
Parsed :: union @(failure=bad) { value: int, bad: Parse_Error }
```

There is no truthiness rule and no nil status: `nil` is not a failure, a trailing `bool` is not a status, and a procedure returning `(int, ^Node)` returns two ordinary values.

A producer's result count is its own, and a destination never changes it. Where two behaviours are wanted they are two operations: `m[key]` reads the zero for a missing key and `m.lookup_value(key)` answers `Option(V)`; `view.(T)` traps on a mismatch and `view.as(T)` answers `Option(T)`.

#### Operator ownership

Both operators read their operand once, and what they do with the payload depends on whether that operand is a place:

| operand | success payload | failure payload |
| --- | --- | --- |
| a place | copied out, source stays live | copied by `or_return`; left alone by `or_else` |
| a temporary, or `move(x)` | transferred | dropped by `or_else` before the fallback runs |

A place operand therefore requires a copyable payload: a move-only one must be written `move(x)`. `or_else` never copies the error.

### or_else expression

`or_else` is an infix binary operator that supplies a fallback for a
[fallible expression](#typed-fallibility). The left operand's success variant
must carry a payload; the fallback must be assignable to that payload type, and
is evaluated only on the failure path. The result is the payload. Ordinary
value semantics apply to the fallback: selecting a managed place clones it and
leaves the place live, while a temporary or `move(x)` transfers ownership.

```odin
m: map[string]int = {};

// `lookup_value` answers `Option(int)`.
i := m.lookup_value("hellope") or_else 123;
assert(i == 123);
```

It applies to every producer of that shape — a container read, a validating
conversion, an erased extraction, and any procedure returning `Option` or
`Result`:

```odin
n := numbers.pop() or_else 0;
text := string(bytes) or_else "";
data := files.read_bytes("data.bin") or_else no_bytes();

view: any_view = 42;
number := view.as(int) or_else 0;
```

`or_else` **discards** the failure on both paths. A managed failure payload of a
temporary is dropped before the fallback is evaluated; a place keeps its own.
There is no form that binds the failure to a name — code that needs the error
uses `or_return` or a `switch`.

### or_return operator

`or_return` propagates the failure of a [fallible expression](#typed-fallibility)
out of the enclosing procedure. The operand is evaluated exactly once.

On success it yields the success payload; a payloadless success yields `Unit`,
so `or_return` is an expression in every case and no second spelling is needed
for the no-value one.

On failure, control returns from the innermost enclosing procedure. That
procedure's result must itself be a fallible union, and the operand's failure
payload must be assignable to its failure payload. An assignable conversion that
creates a borrowed view is also subject to the ordinary return-escape rules: its
source must outlive the returned view.

The operand's temporaries are destroyed before the return completes, and the
ordinary `defer` and cleanup rules run. `or_return` cannot appear outside a
procedure or inside a deferred statement. A nested procedure propagates only
from itself, never from its lexical parent.

```odin
Error_Code :: enum { Something_Bad, Something_Worse, The_Worst }

// The two shapes a fallible procedure has. `Result(Unit, E)` is the one with
// nothing to hand back on success.
step  :: proc() -> Result(Unit, Error_Code) { return .ok(Unit{}); }
value :: proc() -> Result(int, Error_Code)  { return .ok(123); }

work :: proc() -> Result(int, Error_Code) {
	// The common idiom, written out.
	switch (n in value()) {
	case .ok:  _ = n;
	case .err: return .err(n);
	}

	// The same thing, as one operator.
	n := value() or_return;

	// A `Unit` success is used as a statement.
	step() or_return;

	return .ok(n * 2);
}
```

The failure payload is rewrapped as the enclosing procedure's failure variant, so a procedure may propagate into a different error type as long as the payloads are assignable. A place operand copies both payloads and leaves the source whole; see [Operator ownership](#operator-ownership).

## Panics and unwinding

A **panic** is an unrecoverable runtime fault. In required compile-time procedure evaluation, it produces a compilation diagnostic with the evaluator call stack. Runtime panics arise from:

- `panic(message)`
- a failed `assert`
- dereference of a nil pointer
- a call through a nil `dyn` view
- integer division or remainder by zero
- an out-of-range built-in index
- a failed trapping checked extraction, `v.(T)`
- an allocation failure when the allocator policy is [`.Panic`](#allocation-failure)

Version 1 has no `recover`, `try`, or catch construct. Loke code cannot observe or resume a panic. With the `unwind` strategy, the thread runs its registered cleanup before the program stops. The `abort` strategy does not guarantee cleanup.

### Panic strategy

The final build selects one **panic strategy** for the whole program:

- **`unwind`** — the hosted-target default. Unwinds the panicking thread's stack, running pending `defer`s and live managed owners' implicit drops in [reverse registration order](#managed-values-and-storage), as on return. After the outermost frame, the program terminates with a failure status.
- **`abort`** — the default on freestanding and embedded targets, and selectable on any target. A panic runs no cleanup and terminates the program immediately at the point of the fault.

An allocator whose failure policy is [`.Trap`](#allocation-failure) forces `abort` behavior for the failure it reports, regardless of the program's panic strategy; `.Panic` follows the program strategy.

The strategy affects cleanup, not program validity. Portable code may rely on cleanup after a panic only with `unwind`; freestanding code needing crash-time cleanup performs it explicitly.

### What the unwind runs, and what it does not

Under the `unwind` strategy:

- Scope-exit cleanup runs for every **fully initialized** managed owner and every registered `defer` in each unwound frame, newest first. A value whose initialization had not completed when the panic was raised — including a half-constructed temporary in the faulting expression — is cleaned up only as far as its construction reached, using the same drop-flag tracking that governs ordinary [conditional cleanup](#managed-values-and-storage).
- If `main` is on the panicking thread's stack, the unwind passes through it like any other frame, so a managed owner declared as a local in `main` is dropped. This is not a program-wide guarantee: a panic raised by another thread does not unwind the thread running `main`.
- File-scope, `static`, and `thread_local` values are **not** dropped during panic termination. Managed TLS is dropped only on normal thread return; see [Values that outlive every scope](#values-that-outlive-every-scope).

Loke has no automatic package shutdown hooks. Only cleanup attached to a live owner or `defer` runs during panic unwinding.

Deferred statements may not `return`, `break`, or `continue` out of an unwinding frame.

### Panic during unwinding

A panic raised by a `drop` hook or deferred statement during unwinding aborts the program immediately; remaining cleanup has no defined order. Cleanup must handle its own failures. Drop hooks are expected to be infallible, absorbing or ignoring secondary resource-release errors.

### Threads

A panic terminates the whole program; only the panicking thread can unwind. Other threads run no local drops or defers and have no guaranteed cleanup opportunity. Coordinated shutdown requires ordinary error values, worker joins, and cleanup without panicking. Resources that must survive abrupt termination need an external protocol or operating-system guarantee.

## Memory and program services

### Build-selected providers

The final build selects exactly one **default allocator provider** and one **logging provider**. Imports cannot replace providers or create differently configured copies of a package.

If none are selected, the runtime supplies the system heap allocator and standard logger. Provider implementations are fixed for the executable or library and may be devirtualized. Their runtime state is initialized before `main` and available until process exit. Packages cannot replace providers or register automatic startup or shutdown code.

`mem.default_allocator()` obtains the selected allocator handle at runtime. A zero-valued managed owner without `via` binds it lazily when first needed; an omitted allocator argument obtains it when the operation begins. Bound owners retain their allocator. See [Allocators](#allocators).

The `core:log` procedures route to the selected logging provider. The build may also select a minimum compiled log level, allowing lower-level calls to be removed entirely. A package that needs a different sink, captured test output, or
request-specific fields takes an ordinary `Logger` parameter or retains one in a
state object; there is no scoped or package-local override of the program logger.

Only provider *implementation* is selected at build time. Per-request allocators,
scratch arenas, log fields, trace spans, clocks used for simulation, deadlines,
cancellation, random-number state, and similar values have runtime identity and
are passed explicitly.

### Explicit runtime environments

Related runtime services may be grouped in an ordinary application-defined record. The record is not compiler-known and procedures name it only when they actually need it:

```odin
Request_Env :: struct {
	scratch:   mem.Scratch,
	logger:    Logger,
	span:      Trace_Span,
	deadline:  Time,
}

handle :: proc(env: inout Request_Env, request: Request) -> Response {
	...
}
```

Long-lived subsystems normally retain stable dependencies such as an allocator, logger, or clock in their own record. Short-lived state stays in a request or task environment and is moved explicitly when work is transferred to another thread.
Nothing is inherited only because one procedure called another.

Loke has no closures or implicit environment passing. Immediate callbacks take typed state explicitly:

```odin
visit_all :: proc(
	items: []Item,
	state: inout $S,
	visit: proc(state: inout S, item: Item),
) {
	foreach (item in items) {
		visit(inout state, item);
	}
}
```

A retained callback stores its state beside its procedure in an ordinary generic record:

```odin
Handler :: struct($S: type) {
	state: S,
	invoke: proc(state: inout S, event: Event),
}

dispatch :: proc(handler: inout Handler($S), event: Event) {
	handler.invoke(inout handler.state, event);
}
```

This keeps ownership and borrowing visible and leaves ordinary procedure values as one code pointer. Foreign APIs use their documented `rawptr` user-data field when they require erased callback state; that remains an unsafe interop boundary.

### Allocators

Managed owning values use deterministic lexical cleanup, not garbage collection. Explicit allocators select their backing storage.

Dynamic arrays, maps, runtime strings, and other managed containers remember the allocator responsible for their backing storage. Mutable containers and user-defined managed types whose lifecycle clone honors a destination allocator use `mem.default_allocator()` by default, binding it lazily when their allocator-unbound zero state first needs storage, and may select another allocator eagerly with `via`.

Immutable `string` and `shared(T)` are different because assignment may retain an existing shared allocation rather than create destination-owned backing storage. They select an allocator in the operation that creates that allocation: string-producing procedures accept a conventional `allocator` argument when selection is needed, and `shared` has the constructor argument described below. Applying `via` to either type is a compile-time error.

```odin
scratch := mem.Scratch.init();
bytes: [dynamic]u8 via scratch.allocator() = {};
bytes.reserve(4096);
```

The allocator affects where backing storage comes from, but does not change value semantics or whether cleanup is automatic. Cleanup is suppressed per value with [`unsafe.forget`](#unsafeforget), never by a declaration modifier.

Omitting the allocator argument selects the default provider. The following call:

```odin
allocation := new(int);
```

is equivalent to this:

```odin
allocation := new(int, mem.default_allocator());
```

The runtime default expression `allocator := mem.default_allocator()` is evaluated only when the caller omits the argument.

There is no ambient temporary allocator. Temporary storage has a reset boundary and runtime identity, so code creates a `mem.Scratch` or `mem.Arena` owner and passes its allocator explicitly. The compiler rejects `free_all`, or any call carrying the same allocator-reset effect, while a live owning value or borrow still refers to storage from that allocator.

`Arena` and `Scratch` are move-only region owners. A fixed-buffer arena borrows the supplied storage; provider-backed construction takes a parent allocator and defaults it to the program provider. Ordinary construction applies the parent's failure policy, while the `try_` procedures return a `Result` containing either the owner or an error, never a partial owner. A provider-backed child must be dropped before its parent region is reset or ended.

```odin
fixed := mem.Arena.from_buffer(buffer[:]);
arena := mem.Arena.init(parent_allocator);
scratch := mem.Scratch.init();
outcome := mem.try_scratch(parent_allocator); // Result; handle before using the owner
```

For this rule, an owner is live when it may be used later or still requires cleanup on an outgoing path. An explicitly dropped or forgotten owner is dead and no longer blocks reset; moving an owner transfers the dependency to its destination.
An unfreed allocation root whose checked carriers have no later use does not by itself block reset, because the reset is the operation that releases it. A carrier or owner that would survive and be used or cleaned up after the reset does block it.

#### Allocator regions and region provenance

An allocator value has a region identity alongside its allocation procedures and failure policy. Copying it preserves that identity and every allocation records it, letting the compiler recognize that two local allocator values refer to the same region; when it cannot prove them distinct, it conservatively treats the regions as possibly identical. Across a call the identity is propagated through an `@(allocator_reset)` parameter: a procedure that resets an allocator received as a parameter must mark it, and the compiler verifies this transitively. The attribute is part of procedure-type compatibility, so indirect calls preserve the effect.

An owning value also carries compile-time **region provenance**. This provenance
is not part of its source type or ABI, but the region that supplies its backing
storage must outlive the value. An owner backed by a region created in the
current procedure may not be returned, assigned to `static`, `thread_local`, or
file-scope storage, placed in an escaping aggregate or container, or otherwise
retained past that region. Moving the owner does not erase this dependency.

Region provenance is distinct from the root provenance carried by a borrow.
Their complete composition rule is specified under
[How root and region provenance compose](#how-root-and-region-provenance-compose).
This section defines the region half: it constrains owner escape and allocator
reset, but does not itself grant borrow capabilities or decide whether aliases
may overlap.

Procedure checking is conservatively polymorphic over an owning argument's region
provenance. Result provenance follows these rules:

- An owner received through a `move` parameter may be used locally or returned,
  but not retained in longer-lived storage. A returned owner keeps the moved
  value's region dependency.
- Returning an ordinary borrowed managed parameter follows the clone rule under
  [Parameter semantics](#parameter-semantics-and-abi-lowering). A mutable clone
  takes the result allocator's region provenance; a shared-storage logical clone
  keeps the source allocation's provenance.
- An owning result built with an allocator parameter derives its region
  provenance from that argument.

No written lifetime parameter is required. Diagnostics must identify the
allocator region, the escaping owner, and the shorter-lived region root.

For example, returning `bytes` below is rejected because moving the array into result storage would leave it live while scope cleanup destroys its allocator region:

```odin
bad_buffer :: proc() -> [dynamic]u8 {
	arena := mem.Arena.init();
	bytes: [dynamic]u8 via arena.allocator() = {};
	bytes.append(1, 2, 3);
	return bytes; // ERROR: `bytes` cannot outlive `arena`
}
```

Resetting a region is intentionally explicit. There is no zero-argument `free_all`; code must name the allocator being reset. A procedure may reset a region it created locally, because no caller-owned value can belong to it. It may not hide a reset of a global or other pre-existing allocator: such an allocator is taken through an `@(allocator_reset)` parameter instead.

```odin
release_scratch :: proc(@(allocator_reset) allocator: Allocator) {
	free_all(allocator);
}

arena := mem.Arena.init();
scratch: [dynamic]u8 via arena.allocator() = {};
view := scratch[:];
release_scratch(arena.allocator()); // ERROR while `scratch` or `view` is live
```

The following low-level procedures are built in and are also available in package `mem` with enforced allocator errors. Normal managed strings, arrays, and maps do not need them.

- `new(T, allocator=mem.default_allocator()) -> Result(^mut T, Allocator_Error)` creates a new allocation root containing a zero-initialized value, so `T` must have a [zero value](#zero-values). On success the pointer has root provenance identifying that fresh allocation, and the allocation root has region provenance identifying its allocator region; a failure carries the error alone. The result is an **allocation root**, not an automatic owner: the pointer itself has no `drop` hook and the program must eventually pass the allocation root to `free`, reset its allocator region, or transfer responsibility to an ordinary resource wrapper.

```odin
switch (ptr in new(int)) {
case .ok:
	ptr^ = 123;
	x: int = ptr^;
	free(ptr);
case .err:
	panic("integer allocation failed");
}
```

- `new_clone(value, allocator=mem.default_allocator()) -> Result(^mut T, Allocator_Error)` creates a new allocation root containing a clone of the value. Its pointer and allocation root receive the same respective root and region provenance, and the same explicit release rule, as `new`; a failure carries the error alone.

```odin
x: int = 123;
switch (ptr in new_clone(x)) {
case .ok:
	assert(ptr^ == 123);
	free(ptr);
case .err:
	panic("clone allocation failed");
}
```

- `make(Container, ..., allocator=mem.default_allocator()) -> Result(Container, Allocator_Error)` is an explicitly fallible constructor for a dynamic array or map with selected backing storage. A written *length* fills that many slots with the element's zero, so the element must have one; a capacity or a map reservation is raw storage and needs none. The result is an ordinary owning value: it is cleaned up at scope exit like any other, whatever allocator it selected. Slices are borrows and cannot be owners.

```odin
zero_length := make([dynamic]int) or_else {};
with_length := make([dynamic]int, 32) or_else {};
with_length_and_capacity := make([dynamic]int, 16, 64) or_else {};
made_map := make(map[string]int) or_else {};
made_map_with_reservation := make(map[string]int, 64) or_else {};
// Each failure must be handled or explicitly discarded.
```

- `free` ends the allocation root designated by a checked base pointer from `new` or `new_clone`. It consumes the operand binding and invalidates every locally tracked pointer or view of that allocation. `free` needs the write capability, so its operand is a `^mut T`; a `^T` weakened from an allocation may still read it but not end it. A pointer obtained with `&` or `&mut` is not an allocation root and cannot be passed to `free` at all. The program must use the allocator that created the allocation; releasing an unchecked or foreign allocation crosses the `core:unsafe` or foreign-allocator boundary.

```odin
switch (ptr in new(int)) {
case .ok: free(ptr);
case .err: panic("integer allocation failed");
}
```

- `free_all(@(allocator_reset) allocator: Allocator)` frees every allocation in the allocator's region. The explicit argument and effect annotation make the invalidation visible through wrappers and indirect calls. Compile-time acceptance proves that no tracked dependant survives the reset; it does not prove that the selected allocator supports resetting. The call invokes the provider's one region-reset operation rather than guessing a sequence of individual `free` calls. If that allocator does not support region reset, the call traps.

```odin
free_all(my_allocator);
```

- `drop` releases a live managed lexical owner, writes its inert zero representation, and marks it dead until full reassignment. Direct `drop` and `move` are forbidden on static-duration storage; use full assignment to clean up and replace its value, or `exchange` to move the old value out while installing a live replacement. Scope exit invokes `drop` automatically only for live managed lexical owners and for managed TLS at normal thread return; reading or explicitly dropping a dead lexical variable is an error.

```odin
drop(numbers);
drop(index);
```

Additional allocator APIs are documented by `core:mem`.

### Allocation failure

Managed values allocate implicitly. A dynamic array grows on `append`, a string is built by concatenation, and copying a mutable owner may clone its storage. None of these have a place to return an error, so an implicit allocation failure never continues as if it had produced a value. Copying an immutable `string` only retains its existing storage and does not allocate.

Each allocator carries one of two **failure policies**:

| Policy | Behaviour on failure |
| --- | --- |
| `.Panic` | Raise a runtime panic reporting the requested size and the allocator. The default. |
| `.Trap` | Abort the process immediately without unwinding. For freestanding and embedded targets. |

The policy is part of the allocator value and follows an explicitly supplied
allocator into a subsystem. `.Panic` raises an ordinary [panic](#panics-and-unwinding)
and therefore follows the program's panic strategy, unwinding or not accordingly;
`.Trap` aborts immediately without unwinding whatever that strategy is. In either
case a partially constructed temporary is cleaned up when unwinding permits it, and
an existing assignment destination is not modified before all required allocation
and cloning succeeds.

An explicitly fallible form returns the failure to the caller. A procedure
returning a compatible `Result` may propagate it with `or_return`:

```odin
copy := source.try_clone() or_return;
numbers.try_append(value) or_return;
```

The explicitly fallible primitives `make`, `new`, and `new_clone`, and the
`try_` forms of implicitly allocating operations return `Result(T, Allocator_Error)`
(with `Unit` for a no-payload success) and do not invoke the allocator failure
policy. There is no sticky allocation-error flag or implicit error side channel.
Deallocation operations such as `free` and
`drop` return no status. An owner records the allocator needed by `drop`; passing
`free` the wrong allocation or allocator is a programmer error detected by
debugging allocators when available.

Tracking and arena allocators are ordinary `core:mem` implementations. Their setup, diagnostics, and callbacks are library documentation rather than language rules.

## Concurrency and the memory model

Threads, mutexes, channels, and thread pools are library facilities, but reads and writes performed by them obey one language memory model.

Within one thread, evaluations are ordered by the rules under [Evaluation order](#evaluation-order). Evaluation and ownership transfer of a new thread's arguments happen before its first operation. On normal thread return, TLS destruction is sequenced before the thread's final operation; that final operation happens before a successful join returns. A mutex unlock happens before the next successful lock of that mutex. Atomic synchronization is defined below. These edges, together with ordinary sequenced-before order, form the **happens-before** relation.

Two accesses conflict when they touch overlapping bytes and at least one is a write. If conflicting non-atomic accesses from different threads are not ordered by happens-before, the program has a data race and its behavior is undefined. Ordinary variables, pointers, container headers, reference counts, and struct fields are not implicitly atomic. This rule permits conventional optimizing compilers while making synchronization requirements explicit.

The `core:sync` package provides `Atomic(T)` for booleans, integer types, enums with supported integer backing types, and pointers. Its operations are backed by compiler intrinsics and accept `.Relaxed`, `.Acquire`, `.Release`, `.Acquire_Release`, or `.Sequentially_Consistent` ordering where meaningful. `core:sync.fence(order)` provides acquire, release, acquire-release, and sequentially consistent fences; a relaxed fence is invalid because it would have no semantic effect. Unsupported type, operation, or ordering combinations are compile-time errors; the implementation may use a lock when the target lacks a lock-free instruction.

Loke adopts the C++20 atomic ordering model, excluding dependency-ordered `consume`, as the normative model for atomics. The relevant rules are restated here so ordinary code does not need another language specification:

- Every atomic object has one total **modification order** containing all atomic stores and read-modify-write operations to that object. This order is consistent with happens-before.
- An atomic load takes its value from one modification in that object's modification order, subject to the write-read, read-read, read-write, and write-write coherence requirements. A value cannot be manufactured without a contributing write; out-of-thin-air results are forbidden.
- A read-modify-write operation is one indivisible modification and reads the value written by the immediately preceding modification in that object's modification order.
- A release store or release read-modify-write synchronizes with an acquire load or acquire read-modify-write that reads from it or from its release sequence. A release sequence is the maximal contiguous suffix headed by that release and followed by atomic read-modify-write operations on the same object.
- A release fence sequenced before an atomic write synchronizes with an acquire fence sequenced after an atomic read when that read observes the write or its release sequence. This is the fence relation used by the final-reference path of `shared(T)`.
- Relaxed operations participate in atomicity, reads-from, coherence, and modification order but add no synchronizes-with edge. Sequentially consistent operations additionally participate in one total order consistent with happens-before and each affected object's modification order.

These rules intentionally match an established compiler memory model rather than defining a Loke-specific approximation. A compiler may map them to the corresponding LLVM or target atomic operations without strengthening or weakening their observable behavior.

Thread transfer follows these rules:

- Moving an ordinary owning value transfers that owner. No checked borrow may
  remain in the sending thread.
- Copying has the same semantics as within one thread. Ordinary owners create
  independent values; immutable `string` and `shared(T)` may share thread-safe
  handle state according to their documented copy semantics.
- The programmer must ensure that a transferred owner's entire lifecycle,
  including custom drop hooks, foreign resources, and allocator operations, is
  valid on the receiving thread. The compiler does not verify this obligation.
- Raw pointers, stored borrows, foreign handles, and unchecked views may be
  transferred, but the compiler does not prove their pointees remain alive or
  race-free.

There are no implicit `Send` or `Sync` interfaces.

Threads and retained tasks receive only the arguments explicitly moved or copied
into them. A request environment, logger, clock, scratch owner, or other service
handle is transferred like any other value, and transferring a handle does not
make its underlying state thread-safe.

### Shared ownership

`shared(T)` is a library type for shared ownership. It owns one stable, heap-allocated `T` payload and an atomic strong-reference count. Its zero value is `nil`.

`shared(value)` clones the value into a new allocation. `shared(move(value))` moves the value into the allocation. `try_clone` increments the strong count without a new allocation. Thus, `clone` and ordinary assignment share the control block instead of cloning `T`. `move` transfers one handle. `drop` decrements the count with release ordering. At the final reference, it performs an acquire fence and drops the payload one time.

Construction uses `mem.default_allocator()` unless the `allocator` parameter selects another, and follows that allocator's failure policy; use `try_shared` to handle a construction error locally. The control block stores the allocator, so a `shared(T)` declaration cannot use `via` — select an allocator with `shared(value, allocator=...)` or `try_shared`.

The atomic reference count makes concurrent handle accounting race-free. It does not make destruction safe on all threads. The thread that releases the final strong handle runs `T.drop` and uses the control-block allocator. Move or copy a handle to another thread only when that thread can run the destructor and allocator. The compiler does not check this requirement. A thread-affine resource must keep its final owning handle on the required thread or use an owner that schedules destruction there.

Atomic handle accounting also does **not** make concurrent access to `T` safe. `handle.get()` returns a non-owning `^T` whose root provenance derives from that handle; callers must use a mutex, atomics within `T`, immutability, or another protocol before conflicting access. The borrow may not outlive the handle used to obtain it, but the compiler does not correlate aliases obtained from different shared handles.

Strong-reference cycles are permitted and leak until explicitly broken. `weak(T)` is the non-owning companion: it keeps the control block but not the payload alive, and `upgrade` returns `Option(shared(T))`. Libraries that build cyclic graphs should use weak back-edges or explicit teardown.

Immutable `string` implementations that share backing storage use the same atomic handle-accounting principle: their reference-count operations, when present, are atomic, while the bytes themselves never change. The allocator-lifecycle obligation above still applies, and this requirement does not make mutable containers safe for concurrent access.

## Foreign system

The foreign system lets Loke code call foreign code, such as a C library. A foreign import identifies a library or object file for the linker.

### Foreign-ABI-safe types

A procedure using a foreign calling convention, a variable declared in a foreign block, or an exported foreign symbol must have a representation the target ABI can describe. The following types are foreign-ABI-safe:

- fixed-width integers, `int`, `uint`, `uintptr`, `bool`, `rune`, `f32`, and `f64`; their size and alignment follow their Loke definitions and their argument classification follows the target C ABI for a scalar of that representation. `bool` uses C `_Bool`, and `int` and `uint` use the ABI class matching their target-selected width. `f16`, 128-bit integers, and other target extensions are safe only when that target ABI defines their C-compatible classification;
- `rawptr`, `^T`, and `[^]T`, lowered as C pointers; the pointed-to type need not be foreign-ABI-safe because the foreign function receives only an address;
- procedure pointers whose declared calling convention and complete signature match the foreign declaration;
- enums with an explicit foreign-ABI-safe integer backing type;
- plain structs with a trivial lifecycle whose fields are recursively foreign-ABI-safe. Their field order, padding, alignment, and by-value argument classification follow the target C ABI for the equivalent C record. A fixed array is permitted as a record field and has the equivalent C array layout;
- `cstring_view`, lowered to `char const *`. It may be used as a parameter or result and never claims ownership.

**`int` is not C `int`.** Loke's `int` and `uint` are the natural register width, so they are `i64`/`u64` on every 64-bit target while C's `int` stays 32 bits there. They are foreign-ABI-safe in the sense that the ABI can describe them, not in the sense that they match a C declaration spelled `int`. A binding writes the fixed-width type the C header actually resolves to — `i32` for C `int`, `i64` for C `long long`, `int` only where the C side is `ptrdiff_t`, `ssize_t`, or another register-width type. This is the single most common way a hand-written binding goes wrong, and nothing at the boundary can detect it.

Managed containers, `string`, slices, dynamic arrays, maps, tagged unions, `any_view`, `dyn Interface`, and records with custom lifecycle hooks are not foreign-ABI-safe. Interface declarations and compile-time `type` values have no runtime ABI, and a [generic](#generics) procedure or type is likewise not ABI surface — only a concrete instantiation, wrapped in a procedure with a foreign calling convention, can cross the boundary. A fixed array is not permitted as a top-level C parameter because C adjusts such parameters to pointers; write `[^]T` or `^T` explicitly. A packed record is safe only when the bound C declaration uses the same target-specific packing convention; portable bindings should instead copy through an ordinary ABI record.

The base language has no overlapping-record or C-union type. Portable bindings pass a C union as `rawptr` and expose typed wrapper accessors. A binding generator may use a target-specific extension for a union passed by value, but that representation is not portable Loke source.

A default foreign parameter is passed by value. `p: inout T` lowers to `T *`, while `@(by_ptr) p: T` lowers to `T const *`. Foreign parameters cannot use the `move` mode: a C call does not implicitly acquire Loke cleanup responsibility. Exported Loke procedures follow the same restrictions and must declare the foreign calling convention expected by their callers.

At a foreign boundary the pointer capability is documentation, not enforcement: `^T` says the callee only reads through the pointer and `^mut T` that it writes, while both lower to the same address and receive no additional LLVM parameter attributes. Declare an out-parameter as `^mut T` — the Win32 `read: ^mut u32` shape in `core:fs` and `core:term` is the pattern — so a call site must write `&mut` and the intent is visible where the storage is lent.

These rules define representation, not lifetime. A pointer, `cstring_view`, or `inout` argument is borrowed only for the call as far as the compiler can see. Foreign code that retains it crosses the trust boundary described under [What is not checked](#what-is-not-checked); the programmer must keep the storage alive and synchronize access. Returning a pointer likewise transfers no ownership unless the binding wraps it in an explicitly documented Loke resource type.

This declaration creates the foreign import name `kernel32`. A foreign block uses that name to associate declarations with the library:

```odin
foreign import kernel32 "system:kernel32.lib";
foreign kernel32 {
	ExitProcess :: proc "stdcall" (exit_code: u32) ---;
}
```

The compiler can build and link an imported assembly file. It can use `clang`, `as`, or `nasm`, as applicable to the host. Recognized assembly file extensions are `.asm`, `.s`, and `.S`.

For examples, see `base/runtime/entry_*.asm`.

```odin
foreign import lowlevel "lowlevel.asm";
foreign lowlevel {
    __get_flags :: proc "c" () -> u64 ---;
}
```

```asm
bits 64

global __get_flags

section .text
__get_flags:
	pushfq
	pop rax
	ret
```

A foreign block can also declare an exported global variable:

```odin
foreign lib {
	x: i32;
}
```

Foreign procedure declarations have the `c` calling convention by default unless specified otherwise. Because a foreign procedure has no Loke body, its declaration ends with `---` to distinguish it from a procedure type.

Attributes can change properties of declarations in a foreign block:

```odin
@(default_calling_convention = "stdcall")
foreign kernel32 {
	@(link_name="GetLastError") get_last_error :: proc() -> i32 ---;
}
```

Foreign blocks use these attributes:

- default_calling_convention=<string> - The default calling convention for procedures declared within this foreign block.
- link_name=<string> - Sets the exact foreign symbol name for an individual declaration.
- public - Exports all entities declared within the block. Bindings usually want this, or `@(public)` on the package declaration.
- require_results - All procedures declared within this foreign block must have their return values used.

# Appendices

## Conditional compilation

Conditional source selection uses `when`. File selection, source generation, test discovery, and project-wide lint or feature policy are build-system responsibilities, not additional language mechanisms.

### when statements

A `when` statement includes a block only when its compile-time condition is true:

```odin
when (LOKE_OS == .Linux) {
	// Do Linux stuff
}
```

The compiler provides a small set of constants in every compilation:

| Name | Description |
| --- | --- |
| `LOKE_ARCH` | Target CPU architecture enum. |
| `LOKE_OS` | Target operating-system enum. |
| `LOKE_ENDIAN` | Target endianness enum. |
| `LOKE_BUILD_MODE` | Requested output kind. |
| `LOKE_DEBUG` | Whether debug information and debug-mode facilities are enabled. |
| `LOKE_OPTIMIZATION_MODE` | Selected optimization mode. |
| `LOKE_VENDOR` | Compiler implementation identifier; the official compiler uses `"loke"`. |
| `LOKE_VERSION` | Compiler version string. |

Additional project values are supplied by the build system and read with `build_config`.

### Build configuration

Build configuration defines compile-time values for the complete project.

The build system may provide integer, boolean, or string configuration values. Source code reads them with `build_config`, always supplying a default:

```odin
FOO :: build_config(FOO, false); // defines `FOO` as a constant with the default value of false
BAR :: build_config(BAR_DEBUG, true); // name can be different compared to the constant 

when (FOO) {
	// only evaluated when `FOO` is true
} else {
	// only evaluate when `FOO` is false
}
```

Configuration values are immutable constants. File selection, generated sources, test discovery, lint configuration, instrumentation policy, and language-feature policy are expressed in the build system rather than through source-file tags.

#### Build modes

`LOKE_BUILD_MODE` names the requested output kind.

`exe` requires a package named `main`, emits the [executable entry](#executable-startup-abi), and links the compiled module, the runtime, imported libraries, and any assembly imports into an executable.

`obj` accepts any root package, requires no `main`, and emits no entry. It produces one relocatable object from the compiled module alone. That object deliberately keeps its runtime and foreign references unresolved: its C consumer supplies the runtime and the libraries at the final link, and owns process startup, which is what makes the runtime dependency explicit rather than hidden. An assembly import cannot ride along inside a single relocatable object, so an `obj` build that contains one is an error naming the file its consumer must assemble and link separately.

A [foreign thread](#threads) that calls into an object build must attach and detach through the documented runtime API, exactly as any other non-Loke thread does.

## Compile-time built-ins

These four are **ordinary predeclared identifiers**, reached through the ordinary call suffix exactly like `size_of` and `transmute`, and shadowable by a declaration exactly like those. The language has no separate lexical category of directives: there is no `#name` form at all, and a `#` in source outside a comment or literal is an invalid character.

Each one answers entirely at compile time and leaves nothing for the backend to
emit.

### `static_assert(<boolean>)`

`static_assert` requires its condition and check at compile time regardless of the surrounding phase. It takes an optional constant message and breaks compilation if the condition is false, with no runtime cost. An ordinary `assert` instead runs in the phase of the call that reaches it — runtime normally, compile time when that call is already being evaluated for a compile-time context.

```odin
static_assert(SOME_CONST_CONDITION);
static_assert(N > 0, "N must be positive");
```

### `build_config(<identifier>, default)`

Checks if an identifier is defined through the command line, or gives a default value instead.

The reference compiler accepts values through `-define:NAME=VALUE`.

### `source_location() or source_location(<entity>)`

Returns a `runtime.Source_Code_Location`. With no argument it identifies the call site. With an entity argument it identifies that variable's or procedure's declaration.

```odin
foo :: proc() {};

main :: proc() {
    n: int;
    fmt.println(source_location());
    fmt.println(source_location(foo));
    fmt.println(source_location(n));
}
```

### `caller_location()`

`caller_location()` denotes the source location of the code calling the
procedure, as a `runtime.Source_Code_Location`. Its place is the default value of a procedure parameter, where it is evaluated at each call that omits that argument, like any other [default](#default-values). Written anywhere else it has nothing to name but its own site, and yields the same location
`source_location()` does.

`Source_Code_Location` is public, belongs to `base:runtime`, and is a constant:

```odin
Source_Code_Location :: struct {
	file:      string_view,
	procedure: string_view,
	line:      int,
	column:    int,
}
```

Line and column are one-based, and both views point at static storage.

```odin
package example_caller_location;

import "core:fmt";

print_caller_location :: proc(loc := caller_location()) {
	fmt.println(loc);
	fmt.println(source_location().procedure, "called by", loc.procedure);
}

main :: proc() {
	print_caller_location();
	// C:/some/dir/example_caller_location.loke(11:2)
	// print_caller_location called by main
}
```

These four are the complete set of compile-time built-ins. Every one is a compile-time value or compile-time procedure; none is an annotation. Annotations are [attributes](#attributes), spelled `@(...)`, and the two never overlap.

## Attributes

An attribute specifies a property of a declaration, parameter, statement, block, or type literal. Use `@(name)` for an attribute without a value. Use `@(name=value, ...)` for attributes with values. Layout and control-flow attributes use the same syntax.

### Attribute categories

The lists below identify attributes by their declaration targets. Struct and union layout attributes are specified under
[Layout and ABI attributes](#layout-and-abi-attributes).

#### Foreign blocks

```odin
    @(default_calling_convention=<string>) – foreign blocks
    @(private)– all declarations except import statements
    @(public) – all declarations except import statements
    @(require_results) – procedure declarations and foreign blocks
```

#### Procedure groups

```odin
    @(require_results)
```

#### Procedure declarations

```odin
    @(deprecated=<string>)
    @(export)
    @(implicit)
    @(link_name=<string>)
    @(require_results)
```

Optimization and code-generation annotations such as `@(compiler.no_alias)` and `@(compiler.must_tail)` are [extension attributes](#extension-attributes), not base-language ones.

#### Procedure parameters

```odin
    @(allocator_reset) – `Allocator` parameters whose region may be reset
    @(escape=<level>) – what a call may keep of a borrowed argument
    @(by_ptr) – foreign declarations only
    @(c_vararg) – final variadic parameter of a foreign declaration
```

#### Variable declaration attributes

```odin
    @(export)
    @(link_name=<string>)
    @(private) – globals and struct fields
    @(public) – globals and struct fields
```

These attributes specify linkage or visibility. They specify the symbol that a declaration produces or the code that can use the declaration. Storage duration uses [storage modifiers](#storage-modifiers), not attributes. A [constant](#constant-declarations) specifies read-only data.

#### Constant value declarations

```odin
    @(private)
    @(public)
```

#### Type declarations

```odin
    @(private)
    @(public)
```

Union declarations also support [`@(require_results)`](#require_results).
Union literals may designate a [zero variant](#zero-values-and-zero) and a
[failure variant](#the-failure-protocol-and-failure).

### Attribute reference

#### `@(implicit)`

`@(implicit)` permits an implicit use of a target type's one-argument `hook(convert)`. The argument must be an unfixed constant. The parameter type must be a built-in numeric, Boolean, rune, or string type. A runtime value requires the explicit `Target(value)` form. See [Implicit conversion from constants](#implicit-conversion-from-constants).

`@(implicit)` on a declaration that is not an appropriately typed `hook(convert)` is an error.

#### `@(default_calling_convention=<string>)`

This attribute specifies the default calling convention for all procedures in a foreign block:

```odin
@(default_calling_convention = "stdcall")
foreign kernel32 {
	@(link_name="LoadLibraryA") load_library_a  :: proc(c_str: cstring_view) -> Hmodule ---;
}
```

#### `@(deprecated=<string>)`

This attribute marks a procedure as deprecated. The compiler reports the specified message for each use of the procedure.

```odin
@(deprecated="'foo' deprecated, use 'bar' instead")
foo :: proc() {
    ...
}
```

#### `@(export)`

`@(export)` emits a variable or procedure symbol for external linking. It is independent of [`@(public)`](#public), which controls access from other Loke packages; a declaration may need both.

`@(export)` takes no argument. There is no enclosing export default. A foreign block or package clause can have `@(public)`, but it cannot have `@(export)`. To export conditionally, put the declaration in a `when` statement.

Exported procedures must declare a [foreign calling convention](#calling-conventions) and a [foreign-ABI-safe](#foreign-abi-safe-types) signature. Exported variables must also have foreign-ABI-safe types. [Generic](#generics) declarations cannot be exported.

The exported name is the declaration's name or its [`@(link_name)`](#link_namestring). Names are program-wide: duplicates produce a compile-time error identifying both declarations. The `loke_rt_` prefix is reserved for the runtime.

#### `@(link_name=<string>)`

This attribute specifies the symbol name of a variable or procedure. It can occur on an exported declaration or on a declaration in a foreign block:

```odin
foreign foo {
    @(link_name = "bar")
    testbar :: proc(baz: i32) ---;   // C `int`, not Loke `int`
}

@(export, link_name="lib_foo")
foo :: proc "c" () -> int {
	return 42;
}
```

#### `@(private)`

Names package visibility, which is already the default. It applies to top-level
declarations and struct fields, takes no argument, and does not create
file-private visibility.

In a file with a [`@(public)`](#public) package declaration, it excludes a declaration from the file-wide public default:

```odin
@(public)
package glfw;

@(private)
scratch_buffer: [64]u8;   // not part of the package API
```

#### `@(public)`

This attribute exports a top-level declaration or struct field from its package.
Without it, only code in the same package can use the declaration or field.

```odin
@(public)
my_variable: int; // visible to importers of this package
@(public)
my_other_variable: int;
```

Applying `@(public)` to the package declaration makes everything in that file public by default:

```odin
@(public)
package foo;
```

Within a public-default file, `@(private)` narrows an individual declaration back down to package visibility.

#### `@(require_results)`

`@(require_results)` requires a call's results to be used or explicitly discarded.
A bare call statement that violates the requirement is a compile-time error.
Assignment to `_` explicitly discards a result.

The requirement can originate in either a declaration or a result type:

- On a procedure declaration, it applies to that procedure's results regardless
  of their types. On a procedure group or foreign block, it applies to the
  procedures in that group or block.
- On a union declaration, it is a property of the type. It also applies when an
  aggregate contains that type, and is preserved through overloads, generic
  instances, imports, and calls through procedure values.

```odin
@(require_results)
foo :: proc() -> bool {
    return true;
}

main :: proc() {
    foo();     // ERROR: the result is not handled
    _ = foo(); // OK: the result is explicitly discarded
}
```

#### Storage duration

`static` and `thread_local` are [storage modifiers](#storage-modifiers), not
attributes. They control storage duration, address stability, initialization
time, and permitted operations on the binding:

```odin
test :: proc() -> int {
    foo: static = 0;
    foo += 1;
    return foo;
}

main :: proc() {
    fmt.println(test()); // prints 1
    fmt.println(test()); // prints 2
    fmt.println(test()); // prints 3
}
```

### Extension attributes

Target integration, linker sections and linkage strength, instrumentation, sanitizers, testing, debugger views, and optimization controls are not part of the base language. Tools may provide namespaced attributes such as `@(compiler.cold)`, `@(compiler.force_inline)`, `@(link.section=".text.hot")`, `@(link.tls_model="initial-exec")`, `@(objc.class="NSView")`, or `@(test.case)`. An unknown namespace is an error unless the corresponding toolchain extension is enabled.

A `thread_local` variable's TLS model is a toolchain/linker extension; removing the annotation preserves meaning but may reduce performance.

Other backend attributes include:

- `@(compiler.no_alias)` on a pointer parameter, the equivalent of C's `restrict`. It asserts that the parameter does not alias the others; violating it is undefined behavior, and no Loke rule depends on it.
- `@(compiler.must_tail)` requires a call in tail position to compile as a tail transfer; compilation fails if the target or ABI cannot support it.

Removing these attributes preserves meaning but may reduce performance or cause stack overflow.

Portable source must not depend on extension attributes for parsing, type identity, ownership, lifetime, or ordinary control-flow semantics. An extension that changes one of those properties is a language extension rather than a portable attribute.

### Layout and ABI attributes

Layout and ABI annotations use the same `@(...)` syntax as declaration
attributes. This is the language's only annotation syntax. The
[compile-time built-ins](#compile-time-built-ins) are predeclared identifiers,
not directives or annotations.

#### Record layout attributes

##### `@(packed)`

This attribute applies to a struct. It removes the padding normally inserted
between fields to satisfy their alignment requirements. Fields remain in source
order.

Packed-field access uses unaligned loads/stores or aligned temporaries. Individual fields are never addressable: `&value.field` is rejected even at an aligned offset. Low-level code may use `intrinsics.unaligned_load`, `intrinsics.unaligned_store`, or raw byte pointers, taking responsibility for alignment. The whole packed struct remains addressable.

```odin
Packed :: struct @(packed) { x: u8, y: i32, z: u16, w: u8 }
```

##### `@(align=N)`

This attribute can be applied to a struct or union. It specifies that the value is aligned to `N` bytes. Fields remain in source order.

```odin
Foo :: struct @(align=4) {
    b: bool,
}
Bar :: union @(align=4) {
    number: i32,
    byte_value: u8,
}
```

#### Procedure parameter attributes

[`caller_location()`](#caller_location) also appears in a parameter list, but it is a compile-time value rather than an attribute. Its definition is under
[Compile-time built-ins](#compile-time-built-ins).

##### `@(c_vararg)`

Used to interface with vararg functions in foreign procedures.

```odin
foreign foo {
    bar :: proc(n: int, @(c_vararg) args: ..any_view) ---;
}
```

`any_view` is signature notation here; the compiler passes each original concrete argument using the C default argument promotions rather than passing an `any_view` representation.

##### `@(by_ptr)`

Adapts a foreign const-reference parameter to a pointer-based ABI while keeping it read-only in Loke. It is allowed only on foreign declarations, not as a performance annotation for ordinary parameters.

```odin
foreign foo {
    bar :: proc(@(by_ptr) p: T) ---;
}
```

This represents the C signature:

```c
void bar(const T*);
```

##### `@(allocator_reset)`

Marks an `Allocator` parameter whose region may be reset by a successful call. The effect is part of the procedure type. At each call site the compiler substitutes the supplied allocator's region identity and rejects the call while an owning value or borrow from that region is live.

A Loke procedure is verified: every `free_all` operation on a region that existed before procedure entry, and every call through another reset-capable parameter, must be covered by one of the procedure's own `@(allocator_reset)` parameters. A procedure may freely reset a region it created locally. Foreign procedures carrying the attribute are programmer promises. A pre-existing allocator that may be reset must be passed explicitly; hidden resets through globals are not permitted.

##### `@(escape=<level>)`

Bounds retention of a borrowed argument: `none`, `result` (the default), `stored`, or `static`, in increasing order. The parameter's type must reach a borrow carrier. The bound is part of the procedure type and applies to bodies, indirect calls, and generic calls. See [Escape levels](#escape-levels).

```odin
pick :: proc(input: []int, @(escape=none) scratch: []int) -> []int {
	return input; // returning `scratch` instead is an error
}
```

## Library types assumed by this specification

The library supplies the following types, interfaces, and procedures used by this specification. `Atomic(T)`, built-in standard-interface implementations, and compile-time `meta` descriptors use compiler facilities; other entries use ordinary language facilities.

| Type | Used by | Status |
| --- | --- | --- |
| `os.Args`, `os.args`, `os.exit` | [program entry and exit](#program-entry-and-exit) | `core:os`: ordinary Loke over a foreign block, with no compiler-known behavior. `os.args` exposes the [Args surface](#osargs) over [startup-converted arguments](#executable-startup-abi); `os.exit` terminates immediately with the specified status. |
| `fs.File`, `fs.open`, `File.close` | the [`defer`](#defer-statement) and [lifecycle hook](#lifecycle-hooks-and-resource-types) examples | `core:fs`: an ordinary move-only resource whose `drop` closes a live handle. Files are not in `core:os`; there is no `os.open` alias. |
| `String_Builder` | [string type](#string-type) | `core:strings`, built from `[dynamic]u8`. Its zero value is a usable, allocator-unbound builder, and every operation is a method so that `len(builder)` resolves. The compiler contributes one package-private primitive to `core:strings`: `allocate_string(text: string_view, allocator: Allocator) -> Result(string, Allocator_Error)`, the only way a library can create a `string` in storage it selected. |
| `C_String` | [C string views](#c-string-views) | `core:cstrings`: an owning, zero-terminated `[dynamic]u8` buffer for foreign APIs that retain strings. UTF-8 is not guaranteed; construction rejects interior zeros. |
| `Small_Array(T, N)` | [fixed-capacity arrays](#fixed-capacity-arrays) | Inline growable container implemented through ordinary methods and operators. |
| `interfaces.Equatable`, `Ordered`, `Hashable`, `Numeric`, `Integral`, `Cloneable`, `Iterator`, `Iterable`, `Reverse_Iterable`, `Sequence`, `Mutable_Sequence`, `Growable_Sequence` | [standard interface catalogue](#standard-interface-catalogue) | Ordinary structural declarations exported by `base:interfaces`; the compiler exposes built-in operations, associated members, and opaque iterators needed to satisfy them. |
| `Little_Endian(T)`, `Big_Endian(T)` | [basic types](#basic-types) | Distinct storage wrappers supplied by binary-format libraries. |
| `meta.Field`, `meta.Enum_Value` | [compile-time reflection](#compile-time-reflection) | Opaque compile-time-only descriptors exported through `base:meta` and constructed only by compiler reflection built-ins. |
| `Allocator_Error`, `Allocator`, `mem.Scratch`, `mem.Arena` | [allocators](#allocators), fallible operations | `core:mem` / `base:runtime`. The final build selects the provider behind `mem.default_allocator()`. |
| `Logger` | [build-selected providers](#build-selected-providers) | Ordinary service handle supplied by `core:log`; the final build selects the backend used by the package-level logging procedures. |
| `Trace_Span`, `Time` | [explicit runtime environments](#explicit-runtime-environments) | Representative runtime handles supplied by tracing and time libraries; they have no compiler-known propagation. |
| `Source_Code_Location` | `caller_location()`, `source_location()` | `base:runtime`. |
| `Bit_Set(Enum)`, `Enum_Array(Enum, T)` | flag sets and [enum iteration](#iterating-an-enumeration) | Generic library containers. Hardware register layouts use integer masks and explicit accessors in version 1. |
| `Complex(T)`, `Quaternion(T)` | [library numeric types](#library-numeric-types) | Deliberately not primitive. |
| `shared(T)`, `weak(T)` | [shared ownership](#shared-ownership) | Library records with custom lifecycle hooks and an atomic control block. |
| `Atomic(T)` | [concurrency and the memory model](#concurrency-and-the-memory-model) | `core:sync` wrapper over compiler atomic intrinsics. |

The public APIs and layouts of these types belong to their packages; only the behavior required by the linked normative sections is part of the language contract.

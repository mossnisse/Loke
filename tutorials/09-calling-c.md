# Calling C

Loke calls C directly: declare the C procedures in a `foreign` block, say which
library they come from, and call them like any other procedure. This page calls
the C runtime, passes it a Loke procedure to call back, and links a C file of
your own.

## Declaring C procedures

```odin file=c_runtime.loke
package main;

import "core:fmt";
import "core:unsafe";

// The C runtime that every Loke program on Windows already links against.
foreign import libc "system:legacy_stdio_definitions.lib";

foreign libc {
	strlen :: proc(text: cstring_view) -> uint ---;
	abs :: proc(value: i32) -> i32 ---;
	@(link_name = "toupper") to_upper :: proc(character: i32) -> i32 ---;
	qsort :: proc(
		base: rawptr,
		count: uint,
		size: uint,
		compare: proc "c" (left, right: rawptr) -> i32,
	) ---;
}

// C calls this back, so it uses C's calling convention.
compare_i32 :: proc "c" (left, right: rawptr) -> i32 {
	a := (^i32)(left)^;
	b := (^i32)(right)^;
	return -1 if a < b else (1 if a > b else 0);
}

main :: proc() {
	fmt.println(strlen("hello, world"));
	fmt.println(abs(-42));
	fmt.println(rune(to_upper('q')));

	name := "Loke";
	fmt.println(strlen(name.to_c_view()));

	numbers := [5]i32{42, 7, 19, 3, 11};
	qsort(&mut numbers, 5, uint(size_of(i32)), compare_i32);
	fmt.println(numbers);
}
```

```text output=c_runtime
12
42
Q
4
[3, 7, 11, 19, 42]
```

- `foreign import libc "..."` names a library for the linker and calls it
  `libc` in this file. The `system:` prefix means a library the linker finds on
  its own, as it finds the Windows libraries.
- In the `foreign libc` block, each declaration is a C procedure's signature
  ending in `---` instead of a body. Procedures in a foreign block use C's
  calling convention.
- `@(link_name = "toupper")` gives the C procedure a different name in Loke.

## Matching C's types

The declarations must match what the C headers say, because the compiler cannot
read the headers to check. The usual pairs are:

| C | Loke |
| --- | --- |
| `int` | `i32` |
| `long long` | `i64` |
| `unsigned int` | `u32` |
| `size_t` | `uint` |
| `double`, `float` | `f64`, `f32` |
| `const char *` | `cstring_view` |
| `void *` | `rawptr` |
| `T *` | `^T`, or `^mut T` when C writes through it |
| a function pointer | `proc "c" (...) -> ...` |

**Loke's `int` is not C's `int`.** Loke's `int` is 64 bits on 64-bit Windows,
while C's `int` is 32. Use `i32` for C's `int`.

A `cstring_view` points at text ending in a zero byte, which is what C expects.
A string literal converts to one directly. A `string` made while the program
runs converts with `.to_c_view()`.

`string`, slices, dynamic arrays, maps, and unions have no C equivalent, so they
cannot appear in a foreign signature. Pass C what it understands: a pointer and
a length, a `cstring_view`, or a plain record of C-compatible fields.

## Callbacks and unchecked code

`qsort` sorts any array, so it takes the array as a `rawptr`, an address with
no type, and calls a comparison procedure with pointers to two elements. The
comparison is a Loke procedure marked `proc "c"`, so C can call it.

`&mut numbers` gives C a pointer it may write through, and converts to `rawptr`
on the way. Going back the other way, `(^i32)(left)`, is a conversion the
compiler cannot check: nothing proves that `left` points at an `i32`. Loke allows
unchecked operations like this only in a file that imports `core:unsafe`, so a
reader can find every place that relies on the programmer rather than the
compiler. Without the import, the conversion is an error that says so.

The compiler checks a Loke pointer's lifetime only as far as the call: it cannot
see what C does with a pointer afterwards. If a C library keeps a pointer you
gave it, keeping the memory alive is up to you.

## Your own C code

A C file of your own is compiled to an object file first. Save this as
`square.c`:

```c file=square.c
int square(int value) { return value * value; }
```

and compile it with Clang. `lokec -print-toolchain` shows where Clang is:

```powershell
& "C:\Program Files\LLVM\bin\clang.exe" -c square.c -o square.obj
```

A `foreign import` of a path without a prefix names a file relative to the
source file that imports it:

```odin file=squares.loke
package main;

import "core:fmt";

foreign import mine "square.obj";

foreign mine {
	square :: proc(value: i32) -> i32 ---;
}

main :: proc() {
	fmt.println(square(12));
}
```

```powershell
lokec squares.loke
.\squares.exe
```

```text output=squares
144
```

A `.lib` library file works the same way. [design.md "Foreign system"](../design.md#foreign-system)
has the full rules, including exporting Loke procedures for C to call.

## Where to go next

That is the end of the tutorials. From here:

- [examples/](../examples/README.md) has longer programs, each using one part of
  the language in more depth.
- [standard-library.md](../standard-library.md) describes every library package.
- [design.md](../design.md) is the full language specification.

# Compile-time programming

Loke can evaluate ordinary procedures during compilation. This is useful for
tables, array lengths, and checks that should fail before a program runs.
The context requiring the result decides when the procedure executes.

## One procedure, two phases

```odin file=compile_time_basics.loke
package main;

import "core:fmt";

square :: proc(value: int) -> int {
	return value * value;
}

SIDE :: 3;
CELL_COUNT :: square(SIDE);

main :: proc() {
	static_assert(CELL_COUNT == 9);
	cells: [CELL_COUNT]int = {};
	side := 4;
	fmt.println("compiled:", CELL_COUNT, "runtime:", square(side));
	fmt.println("cells:", cells.len());
}
```

```text output=compile_time_basics
compiled: 9 runtime: 16
cells: 9
```

`CELL_COUNT :: square(SIDE)` requires a constant, so the compiler evaluates
the call. `square(side)` is an ordinary runtime expression. The optimizer may
fold it too, but the language does not require that for the call to be valid.

`static_assert` also requires a compile-time answer. A false condition is a
compilation error, even if the assertion appears inside `main`. An ordinary
`assert` checks when its statement executes.

## Building a table

Compile-time procedures can use locals, mutation, and loops:

```odin file=compiled_table.loke
package main;

import "core:fmt";

make_squares :: proc() -> [5]int {
	values: [5]int = {};
	foreach (i in 0 ..< values.len()) {
		values[i] = i * i;
	}
	return values;
}

SQUARES :: make_squares();

main :: proc() {
	static_assert(SQUARES[4] == 16);
	fmt.println(SQUARES);
}
```

```text output=compiled_table
[0, 1, 4, 9, 16]
```

The loop runs in the compiler; the resulting fixed array becomes static data
in the program. Nothing allocates or fills this table at startup.

## Selecting source with `when`

`if` selects a runtime branch. `when` requires a compile-time condition and
selects which source is checked and emitted. Both branches must still parse.

```odin file=build_choice.loke
package main;

import "core:fmt";

LIMIT :: build_config(TABLE_SIZE, 4);
static_assert(LIMIT > 0);

main :: proc() {
	values: [LIMIT]int = {};
	when (LIMIT <= 4) {
		fmt.println("small table");
	} else {
		fmt.println("large table");
	}
	fmt.println("entries:", values.len());
}
```

```text output=build_choice
small table
entries: 4
```

`build_config(TABLE_SIZE, 4)` reads a project-wide build value, with `4` as the
default. Save the program as `build_choice.loke` and choose another size with:

```powershell
lokec build_choice.loke -define:TABLE_SIZE=8
if ($LASTEXITCODE -eq 0) { .\build_choice.exe }
```

This build prints `large table` and `entries: 8`. Setting the size to zero
fails the `static_assert`. `-define` supplies a value; it does not substitute
text into the program.

## What can run during compilation

A compile-time call can use ordinary control flow and temporary containers,
but it cannot read runtime state, perform file or network I/O, or call foreign
code. Its result must be representable in the generated program: a fixed
array is suitable; a dynamic array owned by the compiler cannot escape into
the executable.

Evaluation has memory and step limits. Exceeding them, or reaching a panic,
is a compilation error; the compiler does not silently defer required work to
runtime. Keep large or input-dependent computations in the running program.

[design.md "Compile-time procedure evaluation"](../design.md#compile-time-procedure-evaluation)
defines the boundary. [Reflection and formatting](15-reflection-and-formatting.md)
later uses compile-time information about types; first, the next lesson uses
compile-time parameters to write generic code.

Next: [Generics and interfaces](10-generics-and-interfaces.md).

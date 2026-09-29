# Reflection and formatting

Generics let one procedure work with several types. Compile-time reflection
lets it inspect a type's declared structure. This page combines those ideas,
then shows how a type controls its printed representation.

## Expand once per field

```odin file=reflected_fields.loke
package main;

import "core:fmt";

Settings :: struct {
	retries: int,
	enabled: bool,
}

show_fields :: proc(value: ^$T) {
	foreach ($field in fields_of(T)) {
		when (type_of(field.get(value)) == int) {
			fmt.println(field.name, field.get(value), "(integer)");
		} else {
			fmt.println(field.name, field.get(value));
		}
	}
}

main :: proc() {
	settings := Settings{3, true};
	show_fields(&settings);
}
```

```text output=reflected_fields
retries 3 (integer)
enabled true
```

`foreach ($field in ...)` is a static expansion. The compiler creates and
checks a separate body for each field. Consequently, `field.get(value)` has
that field's concrete type in each body, and `when` can select code for it.
The field descriptors exist during compilation; the settings values are read
when `show_fields` runs.

`fields_of(T)` preserves declaration order and obeys visibility. This procedure
is declared in the same package as `Settings`, so it can see both fields. A
generic reflector declared in another package sees only public fields, even
when called from `Settings`'s package.

Keep borrowed field access borrowed when no ownership is needed. Binding a
field to a new local can copy it, just as an ordinary field access can.

## Inspect enum declarations

```odin file=reflected_enum.loke
package main;

import "core:fmt";

Mode :: enum { Read = 1, Write = 2, Append = 4 }

main :: proc() {
	foreach ($member in enum_values_of(Mode)) {
		fmt.println(member.name, member.value);
	}
}
```

```text output=reflected_enum
Read 1
Write 2
Append 4
```

Use `Mode.values()` for ordinary runtime iteration over enum values. Use
`enum_values_of(Mode)` with static expansion when generated code needs the
declared names, backing values, or indices.

Descriptors cannot be stored in a runtime container or indexed with a runtime
variable. Runtime inspection has a separate `type_info_of` API; it does not
make these compile-time descriptors runtime values.

## Give a type a printed representation

A custom format method avoids exposing fields merely to make them printable.
`fmt` defines a structural interface named `Formattable`, with one slot:
`format(self: ^, writer: fmt.Writer, options: fmt.Options)`. Providing that
method satisfies the interface; no registration or explicit implementation
declaration is needed.

```odin file=custom_format.loke
package main;

import "core:fmt";

Vector :: struct { x, y: f64 }

impl Vector {
	format :: proc(self: ^, writer: fmt.Writer, options: fmt.Options) {
		fmt.concat_to(writer, "(", self.x, ", ", self.y, ")");
	}
}

main :: proc() {
	static_assert(fmt.Formattable(Vector));
	position := Vector{3, 4};
	fmt.println("position:", position);
	view := (dyn fmt.Formattable)(&position);
	fmt.println("through the interface:", view);
}
```

```text output=custom_format
position: (3, 4)
through the interface: (3, 4)
```

`self: ^` borrows the vector without copying it. Plain `self` also satisfies
this slot. The `dyn` view borrows `position`, so it cannot outlive that value.
Both calls reach the same method: `println` accepts mixed arguments as
`any_view`, then uses each concrete type's `Formattable` interface to print it.

`writer` is a borrowed output destination. Write to it so the method works
whether `fmt` targets a terminal, a string, or another sink. Calling
`fmt.println(self)` inside `format` would call the same method again.

`concat_to` inserts no separators; the method supplies its punctuation.
`format_to` would separate values with spaces. This method deliberately uses
default formatting for its coordinates and ignores `options`; a type needing
caller-controlled numeric formatting can forward those options through the
library's `*_with` procedures.

The compiler supplies default `format` methods for other printable types,
so `fmt.Formattable(int)` is true too. A default struct formatter prints only
public fields. Custom formatting belongs in the type's own package so that
every caller sees the same representation.

You can also constrain a generic procedure with `where fmt.Formattable(T)`
and call its `format` slot, just as with the interfaces in the generics lesson.
See
[standard-library.md "core:fmt"](../standard-library.md#corefmt) for the exact
signature and formatting options, and
[design.md "Compile-time reflection"](../design.md#compile-time-reflection)
for reflection's full rules.

## Where to go next

The [examples](../examples/README.md) combine these concepts in larger programs.
In particular, [compile_time.loke](../examples/compile_time.loke) builds a prime
table and reflects over types, and [arena_pipeline.loke](../examples/arena_pipeline.loke)
processes batches using explicit storage regions.

Use [standard-library.md](../standard-library.md) to find library operations,
and [design.md](../design.md) for the complete language rules.

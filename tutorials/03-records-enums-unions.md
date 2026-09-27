# Records, enums, and unions

This page declares new types: records that group values, enums that name a
fixed set of choices, and unions that hold one of several kinds of value.

## Records

A `struct` is a record with named fields. A literal lists the fields in order,
or names them; a field left out takes its zero value.

```odin file=records.loke
package main;

import "core:fmt";

Point :: struct {
	x: int,
	y: int,
}

// Fields are private to their package unless marked `@(public)`.
Size :: struct {
	@(public) width: int,
	@(public) height: int,
}

main :: proc() {
	origin := Point{0, 0};
	p := Point{x = 3, y = 4};
	q := Point{y = 9};          // `x` is left out, so it is 0

	p.x += 10;
	fmt.println(p.x, p.y, q.x, q.y);
	fmt.println(p == Point{13, 4}, p == origin);

	fmt.println(p);
	fmt.println(Size{640, 480});
}
```

```text output=records
13 4 0 9
true false
Point{}
Size{width = 640, height = 480}
```

Two records are equal when all their fields are.

The last two lines show something that surprises most people once. A field is
private to the package that declares it unless it is marked `@(public)`, and
`fmt` is a different package, so it sees none of `Point`'s fields and prints
`Point{}`. `Size` marks its fields public, so they print. The other way to
choose how a type prints is to give it a `format` method, as the next section
does. [Packages](07-packages.md) explains what else `@(public)` controls.

## Methods

An `impl` block attaches procedures and constants to a type. A procedure whose
first parameter is `self` is a *method*, called with a dot on a value. One
without `self` is called on the type itself.

```odin file=methods.loke
package main;

import "core:fmt";

Vector :: struct {
	x, y: f64,
}

impl Vector {
	// A constant that belongs to the type.
	zero :: Vector{0, 0};

	// A named constructor: no `self`, so it is called on the type.
	splat :: proc(value: f64) -> Vector {
		return {value, value};
	}

	// `self` is the value the method is called on; it cannot be changed.
	length_squared :: proc(self) -> f64 {
		return self.x * self.x + self.y * self.y;
	}

	// `self: inout` changes the caller's variable.
	scale :: proc(self: inout, factor: f64) {
		self.x *= factor;
		self.y *= factor;
	}

	// An operator is an ordinary procedure marked with the symbol it provides.
	add :: operator(+) proc(left, right: Vector) -> Vector {
		return {left.x + right.x, left.y + right.y};
	}

	// How `fmt` prints a `Vector`. Each `format_to` call writes its arguments
	// separated by spaces, so the pieces that must touch are written one by one.
	format :: proc(self, writer: fmt.Writer, options: fmt.Options) {
		fmt.format_to(writer, "(");
		fmt.format_to(writer, self.x);
		fmt.format_to(writer, ", ");
		fmt.format_to(writer, self.y);
		fmt.format_to(writer, ")");
	}
}

main :: proc() {
	v := Vector{3, 4};
	fmt.println(v, v.length_squared());

	v.scale(2);
	fmt.println(v);

	w := v + Vector.splat(1) + Vector.zero;
	fmt.println(w);
	fmt.println(Vector.length_squared(w));
}
```

```text output=methods
(3, 4) 25
(6, 8)
(7, 9)
130
```

- `self` on its own receives the value and cannot change it. `self: inout`
  receives the caller's variable, so `v.scale(2)` changes `v`. The call needs no
  `inout` marker, because the dot already shows which value is involved.
- `v.length_squared()` and `Vector.length_squared(v)` are the same call.
- `operator(+)` makes `a + b` call `add`. The operators a type may define are
  listed in [design.md "Operator declarations"](../design.md#operator-declarations).
- A `format` method with exactly this signature decides how `fmt` prints the
  type, in every package.
- The literal `{value, value}` needs no type name: the result type says it is a
  `Vector`. The same shorthand works wherever the type is already known.

## Enums

An `enum` is a type with a fixed list of named values. Inside a context that
already knows the enum's type, a value is written with a leading dot, as
`.North`.

```odin file=enums.loke
package main;

import "core:fmt";

Direction :: enum { North, East, South, West }

turn_right :: proc(facing: Direction) -> Direction {
	switch (facing) {
	case .North: return .East;
	case .East:  return .South;
	case .South: return .West;
	case .West:  return .North;
	}
}

Http_Status :: enum { Ok = 200, Not_Found = 404, Teapot = 418 }

main :: proc() {
	facing := Direction.North;
	foreach (_ in 0 ..< 3) {
		facing = turn_right(facing);
	}
	fmt.println(facing, int(facing));

	foreach (direction in Direction.values()) {
		fmt.println(direction);
	}

	fmt.println(Http_Status.from_int(404) or_else .Ok);
	fmt.println(Http_Status.from_int(500) or_else .Ok);
}
```

```text output=enums
West 3
North
East
South
West
Not_Found
Ok
```

Each value has a number, counting from 0 unless you choose one, and `int(facing)`
reads it. The other direction is checked: `Http_Status.from_int(404)` gives back
a value only if 404 is one of the enum's numbers. What it gives back, and what
`or_else` does with it, is the subject of [Errors](05-errors.md).
`Direction.values()` lists every value in order.

A `switch` over an enum must handle every value, or say that it ignores the rest
with an empty `case:`. That is why `turn_right` needs no `return` after the
switch: some case always returns. Forget one, and the compiler says which:

```odin file=missing_case.loke
package main;

import "core:fmt";

Direction :: enum { North, East, South, West }

main :: proc() {
	facing := Direction.West;
	switch (facing) {
	case .North: fmt.println("up");
	case .East:  fmt.println("right");
	case .South: fmt.println("down");
	}
}
```

```text error=missing_case
error[L0366]: this switch over `Direction` does not cover West
 --> missing_case.loke:9:2
   |
9 | 	switch (facing) {
   | 	^^^^^^^^^^^^^^^^^
```

When a value is added to an enum later, every switch that has to handle it
stops compiling until it does.

## Unions

A `union` holds exactly one of several named *variants*, and each variant may
carry a value of its own type. It is how Loke says "a shape is a circle, or a
rectangle, or nothing":

```odin file=unions.loke
package main;

import "core:fmt";

Shape :: union {
	circle: f64,                            // the radius
	rectangle: (width: f64, height: f64),
	empty:,                                 // no payload at all
}

area :: proc(shape: Shape) -> f64 {
	switch (shape) {
	case .circle(radius):   return 3.14159 * radius * radius;
	case .rectangle(sides): return sides.width * sides.height;
	case .empty:            return 0;
	}
}

main :: proc() {
	shapes := [?]Shape{
		.circle(1),
		.rectangle({width = 2, height = 3}),
		.empty,
	};
	foreach (shape in shapes) {
		fmt.println(area(shape));
	}
}
```

```text output=unions
3.14159
6
0
```

- `.circle(1)` builds a `Shape` holding the variant `circle` with the payload
  `1`. A variant without a payload is written without parentheses, `.empty`.
- `(width: f64, height: f64)` is a record written in place, without a name of
  its own. It is handy for a payload or a result with a few fields.
- A `switch` over a union picks the case for the variant it holds, and
  `case .circle(radius):` names the payload for that case. Like an enum switch,
  it must cover every variant.
- `[?]Shape{...}` is a fixed array whose length, `?`, is counted from the
  literal.

A union is the tool for a value that can be one of a known set of things. The
next pages lean on two unions the language provides: `Option`, for a value that
may be absent, and `Result`, for an operation that may fail.

Next: [Strings and containers](04-strings-and-containers.md).

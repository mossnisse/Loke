# Generics and interfaces

A generic procedure or type is written once and works for many types. An
interface names what a type must be able to do, so generic code can say what it
needs. This page covers both, and `dyn`, which chooses the type at run time
instead.

## Generic procedures

A parameter written with `$` is filled in when the program is compiled. In
`values: []$T`, the compiler reads `T` off the argument: call `largest` with a
slice of `int` and `T` is `int`.

```odin file=generic_procs.loke
package main;

import "base:interfaces";
import "core:fmt";

// `$T` is filled in from the argument: a slice of any type that has `<`.
largest :: proc(values: []$T) -> T where interfaces.Ordered(T) {
	best := values[0];
	foreach (value in values) {
		if (best < value) { best = value; }
	}
	return best;
}

// `$N` and `$T` are passed explicitly, and are known while compiling.
filled :: proc($N: int, value: $T) -> [N]T {
	result: [N]T = {};
	foreach (i in 0 ..< N) {
		result[i] = value;
	}
	return result;
}

main :: proc() {
	fmt.println(largest([]int{3, 9, 4}));
	fmt.println(largest([]f64{2.5, -1, 0.5}));
	fmt.println(largest([]string{"pear", "apple", "plum"}));
	fmt.println(filled(3, "hi"), filled(2, 7.5));
}
```

```text output=generic_procs
9
2.5
plum
[hi, hi, hi] [7.5, 7.5]
```

- `where interfaces.Ordered(T)` says `T` must have `<`. The body compares
  values, so it needs that, and the compiler checks it at every call.
- `$N: int` is a value known at compile time, which is why it can be the length
  of the array type `[N]T`. A call passes it like any argument, `filled(3, "hi")`.
- The compiler produces a separate version for each type a generic procedure is
  used with. Generic code runs as fast as code written for one type.

## Generic types

A record may take `$` parameters too. An `impl` block for it binds the same
names, and they can be used throughout:

```odin file=stack.loke
package main;

import "core:fmt";

Stack :: struct($T: type) {
	items: [dynamic]T,
}

impl Stack($T) {
	push :: proc(self: inout, item: T) {
		self.items.append(item);
	}

	pop :: proc(self: inout) -> Option(T) {
		return self.items.pop();
	}

	len :: proc(self) -> int {
		return self.items.len();
	}
}

main :: proc() {
	numbers: Stack(int) = {};
	numbers.push(1);
	numbers.push(2);
	numbers.push(3);
	fmt.println(numbers.len(), numbers.pop() or_else 0, numbers.len());

	words: Stack(string) = {};
	words.push("first");
	words.push("second");
	for (words.len() > 0) {
		fmt.println(words.pop() or_else "");
	}
}
```

```text output=stack
3 3 2
second
first
```

`Stack(int)` and `Stack(string)` are two different types made from one
declaration. `Option` and `Result` are generic unions built the same way.

## Interfaces

An interface is a named list of requirements. A type meets it by having what it
asks for; nothing needs to declare that it does. A `slot` requirement asks for a
method with a given signature:

```odin file=interfaces.loke
package main;

import "core:fmt";

// Any type with these two methods is a `Shape`; nothing has to say so.
Shape :: interface($T: type) {
	slot name: proc(self) -> string;
	slot area: proc(self) -> f64;
}

Circle :: struct { radius: f64 }
Square :: struct { side: f64 }

impl Circle {
	name :: proc(self) -> string { return "circle"; }
	area :: proc(self) -> f64 { return 3.14159 * self.radius * self.radius; }
}

impl Square {
	name :: proc(self) -> string { return "square"; }
	area :: proc(self) -> f64 { return self.side * self.side; }
}

// Generic: compiled once for each type it is called with.
describe :: proc(shape: $T) where Shape(T) {
	fmt.println("a", shape.name(), "of area", shape.area());
}

// Dynamic: one procedure that calls through a `dyn` view at run time.
total_area :: proc(shapes: []dyn Shape) -> f64 {
	total := 0.0;
	foreach (shape in shapes) {
		total += shape.area();
	}
	return total;
}

main :: proc() {
	circle := Circle{radius = 1};
	square := Square{side = 2};
	describe(circle);
	describe(square);

	shapes := []dyn Shape{(dyn Shape)(&circle), (dyn Shape)(&square)};
	fmt.println(total_area(shapes));
}
```

```text output=interfaces
a circle of area 3.14159
a square of area 4
7.14159
```

The two procedures show the two ways to use an interface:

- `describe` is generic. Each call is compiled for its own type, so the calls to
  `name` and `area` are ordinary direct calls.
- `total_area` takes `dyn Shape` values. A `dyn Shape` is a view of some value
  whose type is only known at run time, plus the methods to call on it, so one
  array can hold a circle and a square. `(dyn Shape)(&circle)` makes one from a
  pointer to a value; `&circle` is that pointer. Like a slice, a `dyn` view
  borrows the value, which must outlive it.

Prefer generics, and use `dyn` when values of different types have to be mixed
at run time.

The standard interfaces, such as `Ordered`, `Equatable`, `Hashable`, and
`Iterable`, are in `base:interfaces`; the `where` clause above uses one.

When a type does not meet an interface, the compiler says which requirement it
missed:

```odin file=unsatisfied.loke
package main;

import "core:fmt";

Shape :: interface($T: type) {
	slot name: proc(self) -> string;
	slot area: proc(self) -> f64;
}

Line :: struct { length: f64 }

impl Line {
	name :: proc(self) -> string { return "line"; }
}

describe :: proc(shape: $T) where Shape(T) {
	fmt.println("a", shape.name(), "of area", shape.area());
}

main :: proc() {
	describe(Line{length = 3});
}
```

```text error=unsatisfied
error[L0444]: `Line` does not satisfy `Shape(Line)`
  --> unsatisfied.loke:21:2
    |
21 | 	describe(Line{length = 3});
    | 	^^^^^^^^^^^^^^^^^^^^^^^^^^
  = note: unsatisfied.loke:7:2: this requirement does not hold: `Line` has no method `area` with this signature
  = note: unsatisfied.loke:21:2: while instantiating `describe(Line)`
```

[design.md "Generics"](../design.md#generics) and
[design.md "Interfaces and polymorphism"](../design.md#interfaces-and-polymorphism)
cover specialization, operator requirements, and the rest.

Next: [Packages](07-packages.md).

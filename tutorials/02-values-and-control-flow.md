# Values and control flow

This page introduces Loke's declarations, control-flow syntax, and procedure
calls, with particular attention to initialization, conversions, and mutation.

## Variables

`name := value` infers a variable's type; `name: Type = value` specifies it.

```odin file=variables.loke
package main;

import "core:fmt";

main :: proc() {
	apples := 7;            // inferred as `int`
	price: f64 = 2.5;       // the type written out
	name := "Ada";          // a `string`
	hungry := true;         // a `bool`

	apples = apples + 3;
	apples += 2;

	total := f64(apples) * price;
	fmt.println(name, "buys", apples, "apples for", total);
	fmt.println("hungry:", hungry);

	fmt.println(7 / 2, 7 % 2, 7.0 / 2.0);
	fmt.println(-7 / 2, -7 % 2);
}
```

```text output=variables
Ada buys 12 apples for 30.0
hungry: true
3 1 3.5
-3 -1
```

Loke never converts between number types behind your back: `apples * price`
would be an error, because one is an `int` and the other an `f64`. `f64(apples)`
converts explicitly. Dividing two integers gives an integer, rounded toward
zero, and `%` is the remainder that goes with it.

The common types are:

| Type | Holds |
| --- | --- |
| `int` | signed integer; 64 bits on 64-bit Windows |
| `i8`, `i16`, `i32`, `i64`, `i128` | signed integer of that many bits |
| `u8`, `u16`, `u32`, `u64`, `u128`, `uint` | unsigned integer; `uint` has the width of `int` |
| `f32`, `f64` | a floating-point number |
| `bool` | `true` or `false` |
| `string` | text, always valid UTF-8 |
| `rune` | one Unicode scalar value, written `'a'` |

[design.md "Primitive types"](../design.md#primitive-types) lists every type.

## Every variable must have a value before it is read

A variable can be declared without a value, as `message: string;`, and given
one later. Until then it has none, and the compiler rejects any read that might
happen before an assignment:

```odin file=dead.loke
package main;

import "core:fmt";

main :: proc() {
	message: string;
	if (length_of_day() > 12) {
		message = "long day";
	}
	fmt.println(message);  // error: `message` may have no value here
}

length_of_day :: proc() -> int { return 14; }
```

```text error=dead
error[L0500]: `message` cannot be used here: it is live on only some of the paths that reach this point
  --> dead.loke:10:14
    |
10 | 	fmt.println(message);  // error: `message` may have no value here
    | 	            ^^^^^^^
```

When the `if` is false, `message` never gets a value. Give it one on every path,
for example by starting from `message := "short day";`, and the program
compiles. To start from a type's zero value on purpose, write `{}`:
`count: int = {};` is `0`, and `name: string = {};` is `""`.

## Constants

`name :: value` declares a constant: a value fixed when the program is
compiled. Constants may use each other, in any order:

```odin file=constants.loke
package main;

import "core:fmt";

SECONDS_PER_MINUTE :: 60;
MINUTES_PER_HOUR :: 60;
SECONDS_PER_HOUR :: SECONDS_PER_MINUTE * MINUTES_PER_HOUR;

main :: proc() {
	hours := 3;
	fmt.println(hours, "hours is", hours * SECONDS_PER_HOUR, "seconds");

	small: u8 = 200;
	fmt.println(small + 100);
	big: i32 = 2_000_000_000;
	fmt.println(i64(big) * 2);
}
```

```text output=constants
3 hours is 10800 seconds
44
4000000000
```

A numeric constant has no fixed type until it is used, so `60` works as an
`int` here and could equally be an `f64` elsewhere. Underscores in a number are
only for reading: `2_000_000_000` is two billion.

The last two lines show what happens at the edge of a type's range. An
unsigned type wraps around: `200 + 100` in a `u8` is `300 - 256`, which is `44`.
A signed type does not wrap. When a signed result does not fit, the program
stops with a *panic* rather than carry on with a wrong number:

```odin file=overflow.loke
package main;

import "core:fmt";

main :: proc() {
	count: i8 = 126;
	count += 1;
	fmt.println(count);
	count += 1;  // panics: 128 does not fit in an `i8`
	fmt.println(count);
}
```

```text panic=overflow
127
loke: panic: signed integer overflow
loke: panicked
```

`i8` holds -128 through 127, so the second addition cannot be done. That is why
`constants.loke` converts to `i64` before doubling two billion, which is more
than an `i32` can hold. [Errors](05-errors.md) says more about panics.

## Decisions

`if`, `else if`, and `else` use mandatory parentheses around conditions and
braces around bodies, even for one statement.

```odin file=ifs.loke
package main;

import "core:fmt";

main :: proc() {
	temperature := 14;
	if (temperature < 0) {
		fmt.println("freezing");
	} else if (temperature < 15) {
		fmt.println("cold");
	} else {
		fmt.println("warm");
	}

	raining := true;
	if (raining && temperature < 20) {
		fmt.println("take a coat");
	}

	count := 3;
	noun := "apple" if count == 1 else "apples";
	fmt.println(count, noun);
}
```

```text output=ifs
cold
take a coat
3 apples
```

Comparisons and `&&`, `||`, and `!` use C-style syntax. A condition must be a
`bool`: `if (count)` is an error, where C would test for zero.
`x if condition else y` chooses between two values in the middle of an
expression.

`switch` compares one value against several cases. Only the matching case
runs, with no falling through into the next, and `case:` with nothing after it
catches the rest:

```odin file=decisions.loke
package main;

import "core:fmt";

part_of_day :: proc(hour: int) -> string {
	switch (hour) {
	case 0 ..< 6:   return "night";
	case 6 ..< 12:  return "morning";
	case 12 ..< 18: return "afternoon";
	case 18 ..< 24: return "evening";
	case:           return "not an hour";
	}
}

main :: proc() {
	fmt.println(3, part_of_day(3));
	fmt.println(14, part_of_day(14));
	fmt.println(25, part_of_day(25));
}
```

```text output=decisions
3 night
14 afternoon
25 not an hour
```

A case can list single values, `case 1, 2, 3:`, or ranges: `a ..< b` stops
before `b`, and `a ..= b` includes it.

## Loops

`foreach` iterates ranges and containers. `for` supports both a C-style
three-part header and a condition alone; there is no separate `while` keyword.

```odin file=loops.loke
package main;

import "core:fmt";

main :: proc() {
	sum := 0;
	foreach (n in 1 ..= 5) {
		sum += n;
	}
	fmt.println("sum:", sum);

	// Halve a number until it reaches 1.
	steps := 0;
	for (value := 40; value > 1; value /= 2) {
		steps += 1;
	}
	fmt.println("halvings:", steps);

	// Repeat while a condition holds.
	power := 1;
	for (power < 1000) {
		power *= 2;
	}
	fmt.println("first power of two past 1000:", power);
}
```

```text output=loops
sum: 15
halvings: 5
first power of two past 1000: 1024
```

`break` leaves the innermost loop and `continue` starts its next round.
`for (;;)` loops until a `break` or `return`. When a loop needs no name for its
value, write `_`: `foreach (_ in 0 ..< 3)` runs its body three times.

## Procedures

Procedures use `proc`. An ordinary parameter binding is immutable; copy it
into a local variable to reassign it. An `inout` parameter instead borrows the
caller's variable for mutation.

```odin file=procedures.loke
package main;

import "core:fmt";

// One parameter, one result.
square :: proc(n: int) -> int {
	return n * n;
}

// Several results come back as one record with named fields.
divide :: proc(dividend, divisor: int) -> (quotient: int, remainder: int) {
	return {dividend / divisor, dividend % divisor};
}

// A parameter with a default may be left out of a call.
greeting :: proc(name: string, punctuation := "!") -> string {
	return "Hello, " + name + punctuation;
}

// An `inout` parameter changes the caller's variable.
double_in_place :: proc(value: inout int) {
	value *= 2;
}

main :: proc() {
	fmt.println(square(12));

	q, r := divide(17, 5);
	fmt.println("17 / 5 =", q, "remainder", r);

	result := divide(100, 7);
	fmt.println(result.quotient, result.remainder);

	fmt.println(greeting("Ada"));
	fmt.println(greeting("Grace", punctuation = "?"));

	n := 21;
	double_in_place(inout n);
	fmt.println(n);
}
```

```text output=procedures
144
17 / 5 = 3 remainder 2
14 2
Hello, Ada!
Hello, Grace?
42
```

A few things to notice:

- `dividend, divisor: int` gives two parameters one type.
- A procedure returns one value. To return several, return a record with named
  fields, `(quotient: int, remainder: int)`. The caller can take it apart,
  `q, r := divide(17, 5)`, or keep it whole and read its fields. When every
  caller takes it apart, the names can go: `-> (int, int)`.
- `punctuation = "?"` names the argument it sets. Named arguments come after
  the positional ones, in any order.
- `+` joins strings.
- Procedures can be declared in any order; `main` may call one written below it.

An `inout` parameter requires `inout` at the call site too. Leaving out the
marker is an error:

```odin file=marker.loke
package main;

import "core:fmt";

double_in_place :: proc(value: inout int) {
	value *= 2;
}

main :: proc() {
	n := 21;
	double_in_place(n);  // error: the call must say `inout n`
	fmt.println(n);
}
```

```text error=marker
error[L0370]: this parameter is `inout`; write `inout` at the call site
  --> marker.loke:11:18
    |
11 | 	double_in_place(n);  // error: the call must say `inout n`
    | 	                ^
```

[design.md "Procedures"](../design.md#procedures) has the rest: variadic
parameters, procedure values, and overloading.

## Pointers and mutation

An immutable parameter binding can still hold a mutable pointer: the pointer
cannot be reassigned, but the value it points to can change. `^T` is a read-only
pointer, and `^mut T` permits writing. `&value` and `&mut value` borrow a value
with those capabilities; postfix `^` dereferences the pointer.

Both pointer types are non-null and have no zero value: neither accepts `nil`
or `{}`. Represent an absent pointer with `Option(^T)` and `.none` instead;
[Errors](05-errors.md#option-a-value-that-may-be-absent) explains `Option`.

```odin file=pointers.loke
package main;

import "core:fmt";

read :: proc(value: ^int) -> int {
	return value^;
}

increment :: proc(value: ^mut int) {
	value^ += 1;
}

main :: proc() {
	count := 4;
	fmt.println(read(&count));
	increment(&mut count);
	fmt.println(count);
}
```

```text output=pointers
4
5
```

`inout` exposes the caller's variable directly; `^mut T` exposes it through a
pointer. Both borrow existing storage without allocating it. The compiler
checks that a borrow does not outlive its owner or conflict with another use.
Mutable slices follow the same distinction for elements, as
[Arrays and slices](04-strings-and-containers.md#arrays-and-slices) shows.
[design.md "Pointers"](../design.md#pointers) gives the full pointer rules.

Next: [Records, enums, and unions](03-records-enums-unions.md).

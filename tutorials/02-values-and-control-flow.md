# Values and control flow

This page covers the everyday parts of a program: variables and their types,
constants, arithmetic, decisions, loops, and procedures.

## Variables

`name := value` declares a variable and gives it a value. The type comes from
the value; write it out with `name: Type = value` when you want a different one.

```odin file=variables.loke
package main;

import "core:fmt";

main :: proc() {
	apples := 7;            // an `int`, because 7 is a whole number
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
Ada buys 12 apples for 30
hungry: true
3 1 3.5
-3 -1
```

`=` assigns a new value to a variable that exists, and `+=`, `-=`, `*=`, and
`/=` update it in place. `//` starts a comment that runs to the end of the line.

Loke never converts between number types behind your back: `apples * price`
would be an error, because one is an `int` and the other an `f64`. `f64(apples)`
converts explicitly. Dividing two integers gives an integer, rounded toward
zero, and `%` is the remainder that goes with it.

The common types are:

| Type | Holds |
| --- | --- |
| `int` | a whole number; 64 bits on 64-bit Windows |
| `i8`, `i16`, `i32`, `i64` | a whole number of that many bits |
| `u8`, `u16`, `u32`, `u64`, `uint` | a whole number that is never negative |
| `f32`, `f64` | a floating-point number |
| `bool` | `true` or `false` |
| `string` | text, always valid UTF-8 |
| `rune` | one Unicode character, written `'a'` |

[design.md "Primitive types"](../design.md#primitive-types) lists every type.

## Every variable has a value before it is read

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
	fmt.println(message);
}

length_of_day :: proc() -> int { return 14; }
```

```text error=dead
error[L0500]: `message` cannot be used here: it is live on only some of the paths that reach this point
  --> dead.loke:10:14
    |
10 | 	fmt.println(message);
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
	count += 1;
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

`if` takes a condition in parentheses and a body in braces, and may continue
with `else if` and `else`. The braces are always written, even for one
statement.

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

The comparison operators are `==`, `!=`, `<`, `<=`, `>`, and `>=`, and
conditions combine with `&&` (and), `||` (or), and `!` (not). A condition must
be a `bool`: `if (count)` is an error, where C would test for zero.
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

`foreach` runs its body once for each value of something that can be walked
through: a range, an array, a string, and the containers on the next pages.
`for` repeats while a condition holds, with an optional first statement and a
statement to run after each round, as in C:

```odin file=loops.loke
package main;

import "core:fmt";

main :: proc() {
	// Count from 1 through 15, replacing multiples of 3 and 5.
	foreach (n in 1 ..= 15) {
		if (n % 15 == 0) {
			fmt.println("FizzBuzz");
		} else if (n % 3 == 0) {
			fmt.println("Fizz");
		} else if (n % 5 == 0) {
			fmt.println("Buzz");
		} else {
			fmt.println(n);
		}
	}

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
1
2
Fizz
4
Buzz
Fizz
7
8
Fizz
Buzz
11
Fizz
13
14
FizzBuzz
halvings: 5
first power of two past 1000: 1024
```

`break` leaves the innermost loop and `continue` starts its next round.
`for (;;)` loops until a `break` or `return`. When a loop needs no name for its
value, write `_`: `foreach (_ in 0 ..< 3)` runs its body three times.

## Procedures

A procedure takes parameters and may return a result. A parameter cannot be
changed inside the procedure; copy it into a variable when you need to.

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
  `q, r := divide(17, 5)`, or keep it whole and read its fields.
- `punctuation = "?"` names the argument it sets. Named arguments come after
  the positional ones, in any order.
- `+` joins strings.
- Procedures can be declared in any order; `main` may call one written below it.

An `inout` parameter is the one way a procedure changes a variable it was given,
and the call must say so too. Leaving out the marker is an error, so a reader of
the call can always see which arguments may change:

```odin file=marker.loke
package main;

import "core:fmt";

double_in_place :: proc(value: inout int) {
	value *= 2;
}

main :: proc() {
	n := 21;
	double_in_place(n);
	fmt.println(n);
}
```

```text error=marker
error[L0370]: this parameter is `inout`; write `inout` at the call site
  --> marker.loke:11:18
    |
11 | 	double_in_place(n);
    | 	                ^
```

[design.md "Procedures"](../design.md#procedures) has the rest: variadic
parameters, procedure values, and overloading.

Next: [Records, enums, and unions](03-records-enums-unions.md).

# Errors

Loke has no exceptions and no special error values. A procedure that may have
no answer returns an `Option`, and one that may fail returns a `Result`. Both are
ordinary unions, and two operators, `or_else` and `or_return`, make them easy to
use. A *panic* is for the other kind of failure: a bug that stops the program.

## Option: a value that may be absent

`Option(T)` is a union with two variants: `.some(value)` holds a `T`, and `.none`
holds nothing.

```odin file=options.loke
package main;

import "core:fmt";

// The position of the first negative number, if there is one.
first_negative :: proc(values: []int) -> Option(int) {
	foreach (value, index in values.indexed()) {
		if (value < 0) {
			return .some(index);
		}
	}
	return .none;
}

main :: proc() {
	readings := []int{4, 7, -2, 9, -5};

	switch (index in first_negative(readings)) {
	case .some: fmt.println("first negative at", index);
	case .none: fmt.println("all readings are positive");
	}

	none_here := first_negative([]int{1, 2, 3}) or_else -1;
	fmt.println(none_here);
}
```

```text output=options
first negative at 2
-1
```

There are two ways to get the value out:

- `switch (index in ...)` names the payload `index`, and a case for each variant
  says what to do. In the `.some` case, `index` is the `int`.
- `x or_else fallback` gives the payload when there is one, and `fallback` when
  there is not.

The library uses `Option` wherever an answer may be missing: `pop` on an empty
array, `lookup_value` for a key a map lacks, `strings.index` for text that is not
there, and `from_int` for a number that names no enum value.

## Result: an operation that may fail

`Result(T, E)` has the variants `.ok(value)` and `.err(error)`. The error type is
yours to choose; an enum is the usual start.

```odin file=results.loke
package main;

import "core:fmt";
import "core:strconv";
import "core:strings";

Time :: struct { hours, minutes: int }

Time_Error :: enum { Missing_Colon, Not_A_Number, Out_Of_Range }

// Reads a time written as "HH:MM".
parse_time :: proc(text: string_view) -> Result(Time, Time_Error) {
	parts := strings.cut(text, ":").ok_or(Time_Error.Missing_Colon) or_return;
	hours := parse_number(parts.before) or_return;
	minutes := parse_number(parts.after) or_return;
	if (hours < 0 || hours > 23 || minutes < 0 || minutes > 59) {
		return .err(.Out_Of_Range);
	}
	return .ok({hours, minutes});
}

parse_number :: proc(text: string_view) -> Result(int, Time_Error) {
	switch (value in strconv.parse_int(text)) {
	case .ok:  return .ok(value);
	case .err: return .err(.Not_A_Number);
	}
}

main :: proc() {
	foreach (text in []string_view{"09:30", "00:00", "23:59", "9.30", "25:00", "12:xx", "-1:30", "12:-1"}) {
		switch (outcome in parse_time(text)) {
		case .ok:
			fmt.println(text, "is", outcome.hours * 60 + outcome.minutes, "minutes after midnight");
		case .err:
			fmt.println(text, "is not a time:", outcome);
		}
	}
}
```

```text output=results
09:30 is 570 minutes after midnight
00:00 is 0 minutes after midnight
23:59 is 1439 minutes after midnight
9.30 is not a time: Missing_Colon
25:00 is not a time: Out_Of_Range
12:xx is not a time: Not_A_Number
-1:30 is not a time: Out_Of_Range
12:-1 is not a time: Out_Of_Range
```

`or_return` is the operator that makes this readable. `parse_number(...)
or_return` gives the number when the call succeeds. When it fails, `parse_time`
returns at once, passing the same error on to its own caller. Without it, each
call would need a `switch`.

`strings.cut` returns an `Option`, whose absence carries no error to pass on, so
`.ok_or(Time_Error.Missing_Colon)` names the error it becomes first. The enum
value is written with its type because `ok_or` learns the error type from its
argument.

`parse_number` turns the library's error into a `Time_Error`, so that
`parse_time` has one error type to report. It is also the example of a switch
where every case returns, which is why no `return` follows it.

A `Result` must not be ignored. Calling a procedure that returns one and doing
nothing with the result is an error:

```odin file=ignored.loke
package main;

import "core:strconv";

main :: proc() {
	strconv.parse_int("42");  // error: the `Result` is ignored
}
```

```text error=ignored
error[L0612]: this call produces `Result(int, Parse_Error)`, which must be used or discarded with `_ = ...`
 --> ignored.loke:6:2
   |
6 | 	strconv.parse_int("42");  // error: the `Result` is ignored
   | 	^^^^^^^^^^^^^^^^^^^^^^^
```

`_ = strconv.parse_int("42");` discards it on purpose.

[design.md "Error handling"](../design.md#error-handling) describes the rest,
including your own fallible unions and `map_error`, which changes a `Result`'s
error type in one step.

## Cleaning up with `defer`

Containers and files clean themselves up when their variables go out of scope.
For other scope-exit work, `defer` runs a statement when the enclosing block
ends, including an early `return`. Panic cleanup depends on the build's
strategy, described below.

```odin file=cleanup.loke
package main;

import "core:fmt";

work :: proc(name: string) {
	fmt.println("start", name);
	defer fmt.println("finish", name);

	if (name == "short") {
		return;
	}
	defer fmt.println("undo the second step of", name);
	fmt.println("second step of", name);
}

main :: proc() {
	work("short");
	work("long");
}
```

```text output=cleanup
start short
finish short
start long
second step of long
undo the second step of long
finish long
```

Deferred statements run in reverse order, newest first, and only those the
program reached: the early `return` skips the second one.

## Panics

Some failures are not something a caller can handle, because they mean the
program itself is wrong: an index past the end of an array, a division by zero,
the signed overflow on the [second page](02-values-and-control-flow.md#constants).
These *panic*: the program prints a report and stops with a failing exit code.

`assert(condition, message)` panics when a condition you expect to hold does
not, and `panic(message)` panics unconditionally:

```odin file=checks.loke
package main;

import "core:fmt";

average :: proc(values: []int) -> int {
	assert(values.len() > 0, "average of no values");
	total := 0;
	foreach (value in values) { total += value; }
	return total / values.len();
}

main :: proc() {
	fmt.println(average([]int{3, 4, 8}));
	fmt.println(average([]int{}));  // panics: the assert fails
	fmt.println("not reached");
}
```

```text panic=checks
5
loke: panic: average of no values
loke: panicked
```

A panic cannot be caught. With the default `-panic=unwind` build, the panicking
thread runs pending `defer` statements and drops live local owners before the
program stops. `-panic=abort` skips cleanup. A second panic during unwinding
also stops immediately, skipping the cleanup still pending; see
[design.md "Panic strategy"](../design.md#panic-strategy).

Use a `Result` for anything that can go wrong in a correct program, such as a
missing file or bad input, and keep panics for mistakes in the program itself.

Next: [Packages](06-packages.md).

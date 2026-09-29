# A command-line tool

This page puts the earlier ones together in a small, complete program: `tally`
reads a file of expenses and prints the total for each category. It takes the
file's name as an argument, reports problems on the error stream, and tells the
shell whether it succeeded through its exit code.

## The input

Each line is a category and a signed whole amount, separated by a comma;
negative amounts represent refunds. Amounts and running totals must fit in an
`int` (a signed 64-bit integer on the supported target). Blank lines and lines
starting with `#` are skipped. Save this as `expenses.csv`:

```text file=expenses.csv
# category,amount
food,120
travel,45
food,38

books,249
travel,60
food,17
```

## The program

The program has two packages. `ledger` knows the file format and knows nothing
about where the text came from. `main` deals with the command line, the file,
and the output. Keeping them apart means `ledger` could be reused by a program
that reads its text from somewhere else.

```text
tally/
    main.loke
    ledger/
        ledger.loke
```

**`tally/ledger/ledger.loke`**

```odin file=tally/ledger/ledger.loke
package ledger;

import "core:strconv";
import "core:strings";

// Where a line of input went wrong.
@(public)
Problem :: struct {
	@(public) line: int,
	@(public) reason: string,
}

// The total spent in each category and across all input lines.
@(public)
Totals :: struct {
	@(public) by_category: map[string]int,
	@(public) grand_total: int,
}

// Widen before adding, then check before converting back to `int`.
add_amount :: proc(total, amount: int) -> Option(int) {
	sum := i128(total) + i128(amount);
	if (sum < -9_223_372_036_854_775_808 || sum > 9_223_372_036_854_775_807) {
		return .none;
	}
	return .some(int(sum));
}

// Reads lines of `category,amount`. Blank lines and lines starting with `#`
// are skipped.
@(public)
parse :: proc(text: string_view) -> Result(Totals, Problem) {
	totals: Totals = {};
	foreach (line, index in strings.lines(text).indexed()) {
		entry := strings.trim_space(line);
		if (entry.len() == 0 || strings.starts_with(entry, "#")) {
			continue;
		}
		number := index + 1;
		parts: strings.Cut;
		switch (found in strings.cut(entry, ",")) {
		case .some: parts = found;
		case .none: return .err({number, "expected `category,amount`"});
		}
		category := strings.trim_space(parts.before);
		amount: int;
		switch (parsed in strconv.parse_int(strings.trim_space(parts.after))) {
		case .ok:  amount = parsed;
		case .err: return .err({number, "the amount is not a whole number"});
		}
		previous := totals.by_category.lookup_value(category) or_else 0;
		category_total := add_amount(previous, amount)
			.ok_or(Problem{number, "category total is out of range"}) or_return;
		totals.grand_total = add_amount(totals.grand_total, amount)
			.ok_or(Problem{number, "grand total is out of range"}) or_return;
		if (category in totals.by_category) {
			totals.by_category[category] += amount;  // checked above
		} else {
			totals.by_category[category.copy()] = category_total;
		}
	}
	return .ok(move(totals));
}

// The categories in alphabetical order.
@(public)
categories :: proc(totals: Totals) -> [dynamic]string {
	names: [dynamic]string = {};
	foreach (name, _ in totals.by_category) {
		names.append(name);
	}
	names.sort();
	return names;
}
```

**`tally/main.loke`**

```odin file=tally/main.loke
package main;

import "core:fmt";
import "core:fs";
import "core:os";
import "ledger";

main :: proc() -> i32 {
	// The file to read: the first argument, or `expenses.csv`.
	path: string_view = "expenses.csv";
	if (os.args.len() > 1) {
		path = os.view_at(1);
	}

	text: string;
	switch (contents in fs.read_text(path)) {
	case .ok:
		text = contents;
	case .err:
		fmt.eprintln("tally: cannot read", path, "-", contents);
		return 1;
	}

	totals: ledger.Totals;
	switch (parsed in ledger.parse(text)) {
	case .ok:
		totals = move(parsed);
	case .err:
		fmt.eprintln("tally:", path, "line", parsed.line, "-", parsed.reason);
		return 1;
	}

	foreach (category in ledger.categories(totals)) {
		amount := totals.by_category[category];
		fmt.println(category, amount);
	}
	fmt.println("total", totals.grand_total);
	return 0;
}
```

Build it and run it from the directory that holds `tally` and `expenses.csv`:

```powershell
lokec tally -o tally.exe
.\tally.exe
```

```text output=tally
books 249
food 175
travel 105
total 529
```

## How it works

**Arguments.** `os.args` holds the command line, with the program's own path
first, so `os.args.len() > 1` asks whether an argument was given.
`os.view_at(1)` is the first one, as a `string_view` that stays valid for the
whole run.

**Reading the file.** `fs.read_text` returns `Result(string, io.Error)`: the
whole file as text, or the reason it could not be read. It also checks that the
file is valid UTF-8, as every `string` must be.

**Errors in `main`.** `main` cannot use `or_return`, because it does not return
a `Result`, so it uses a `switch` for each step that can fail. It prints the
problem with `fmt.eprintln`, which writes to the error stream instead of the
output, and returns 1. `main :: proc() -> i32` makes its result the program's
exit code, so a script can tell the run failed:

```powershell
.\tally.exe missing.csv
```

```text output=tally args=missing.csv exit=1
tally: cannot read missing.csv - Open failed: Not_Found (native 2)
```

A line that is not an expense is reported with its line number. With this file
as `broken.csv`:

```text file=broken.csv
food,12
books,lots
```

```text output=tally args=broken.csv exit=1
tally: broken.csv line 2 - the amount is not a whole number
```

**Parsing.** `strings.lines` walks the text a line at a time, and `.indexed()`
numbers the lines from 0, which is why the line number is `index + 1`. Each line
is a `string_view` into `text`: nothing is copied until a new category becomes a
key of the map, with `category.copy()`.

**Totals.** `add_amount` adds two `int` values in the wider `i128` type, then
checks the result before converting back. Both running totals are checked
during parsing, so an out-of-range sum reports the input line before any report
is printed. `.ok_or(Problem{...}) or_return` turns a missing sum into the
parser's error, just as the time parser in [Errors](05-errors.md) did.

**Ownership.** `ledger.parse` builds `totals` and hands it back with
`move(totals)`, and `main` takes it out of the `Result` with `move(parsed)`.
Neither copies the map. When `main` returns, `text`, `totals`, and the list of
categories are released.

**Output.** `fmt.println` separates the category and amount with one space.
There is no fixed category width, so long names and Unicode text need no
padding calculation.

## Boundary cases

The examples below are checked with the program above. Run each file with
`.\tally.exe filename.csv`.

A category longer than ten bytes is ordinary input:

```text file=long-category.csv
subscriptions,12
```

```text output=tally args=long-category.csv
subscriptions 12
total 12
```

Both ends of the `int` range are valid amounts, and refunds subtract from the
running totals:

```text file=limits.csv
food,9223372036854775807
food,-9223372036854775808
travel,1
```

```text output=tally args=limits.csv
food -1
travel 1
total 0
```

Adding past either limit is an input error, whether it happens within one
category or across categories:

```text file=category-overflow.csv
food,9223372036854775807
food,1
```

```text output=tally args=category-overflow.csv exit=1
tally: category-overflow.csv line 2 - category total is out of range
```

```text file=category-underflow.csv
food,-9223372036854775808
food,-1
```

```text output=tally args=category-underflow.csv exit=1
tally: category-underflow.csv line 2 - category total is out of range
```

```text file=total-overflow.csv
food,9223372036854775807
travel,1
```

```text output=tally args=total-overflow.csv exit=1
tally: total-overflow.csv line 2 - grand total is out of range
```

```text file=total-underflow.csv
food,-9223372036854775808
travel,-1
```

```text output=tally args=total-underflow.csv exit=1
tally: total-underflow.csv line 2 - grand total is out of range
```

This completes the core route: a program with its own types, parsing errors,
packages, and file input. The next lessons examine storage and compile-time
behavior in more detail.

Next: [Borrowing and lifetimes](08-borrowing-and-lifetimes.md).

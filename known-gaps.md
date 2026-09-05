# Known gaps

Divergences between the specification documents and the shipped compiler, with
a minimal reproduction for each. A gap leaves this file when the compiler
accepts the program the spec describes — not when the spec is reworded to match
the compiler, unless the rewording is the intended fix.

Nothing here is checked by the test corpus: a test asserting today's behavior
would cement the wrong answer, and one asserting the right answer would be red.
Each entry carries its own repro instead, small enough to paste.

## `foreach` has no compile-time meaning

`design.md` "Compile-time procedure evaluation" says an executed compile-time
path "may use ordinary expressions, procedures, local variables, mutation,
control flow, recursion, and temporary managed containers", and the section's
own example iterates with `foreach`. The evaluator implements the three-part
`for` and rejects `foreach` over anything — an integer range, a fixed array, a
string's bytes:

```odin
package main;

sum :: proc(n: int) -> int {
	total := 0;
	foreach (i in 0 ..< n) { total += i; }
	return total;
}

TOTAL :: sum(5);
```

```
error[L0341]: this statement has no compile-time meaning
 --> repro.loke:9:10
9 | TOTAL :: sum(5);
  = note: repro.loke:5:2: evaluation stopped here      // the `foreach`
```

The same procedure written with `for (i := 0; i < n; i += 1)` folds correctly,
and the `foreach` form runs correctly at runtime, so the gap is the evaluator's
statement coverage rather than ranges, iteration adapters, or the checker.

Two consequences worth knowing while it stands:

- `design.md`'s headline compile-time example, `hash_name` folded into
  `CLICKED_ID`, does not compile as written;
- `examples/compile_time.loke` is the one example still written with counted
  `for` loops. It has to be. When this is fixed, its two sieve loops become
  `foreach (n in 2 ..= limit)` and the example gate proves the constants are
  unchanged.

Static `foreach ($x in ...)` expansion is a different mechanism and is
unaffected; `examples/compile_time.loke` exercises it.

## Not gaps

Recorded because they look like gaps and are not, and each cost an
investigation once.

- **An exhaustive enum `switch` where every arm returns still needs a return
  after it** (`error[L0365]`). Correct: `design.md` "Exhaustive switch" makes
  exhaustiveness a check over declared members, not values, and conversion into
  an enum is unchecked — so a subject holding a non-member value matches no case
  and falls out of the bottom. A *variant* switch covering every variant is the
  case where no path reaches the end, and the compiler already accepts that one
  with no trailing return.
- **Overlapping range cases are accepted.** Correct: cases are tried top to
  bottom and the first match wins (`design.md` "switch statement"). Only
  duplicate constant values are diagnosed.

# Known gaps

Divergences between the specification documents and the shipped compiler, with
a minimal reproduction for each. A gap leaves this file when the compiler
accepts the program the spec describes — not when the spec is reworded to match
the compiler, unless the rewording is the intended fix.

## Gaps

Found by the checker fuzzer (`tests/checker_fuzz_test.odin`).

- **A large fixed array is folded one element at a time.** Constant folding and
  zero values build one constant per element, so the cost of a literal follows
  the array's length rather than what the literal writes. Each line below fails
  on its own: a billion-element literal crashes the compiler (an index out of
  range once the per-element allocation fails), a zero-initialized
  `[max(i64)]int` never finishes, and the same type declared without an
  initializer is accepted although its layout is past the `MAX_LAYOUT_SIZE`
  that `layout.odin` enforces for other types (`L0364`):

  ```odin
  package main;
  main :: proc() {
  	a := [1000000000]int{1};
  	b: [9223372036854775807]int = {};
  	c: [9223372036854775807]int;
  }
  ```

## Not gaps

Recorded because they look like gaps and are not, and each cost an
investigation once.

- **Enums are closed.** An enum switch covering every variant needs no trailing
  return when every arm terminates, just like a union variant switch. Integer
  input is validated with `Enum.from_int`, and an enum without a variant
  represented by zero has no zero value (`design.md` "Enumerations").
- **Overlapping range cases are accepted.** Correct: cases are tried top to
  bottom and the first match wins (`design.md` "switch statement"). Only
  duplicate constant values are diagnosed.

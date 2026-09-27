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

Found by a review of the generics implementation.

- **Overlapping generic `impl` blocks are rejected at the instance, not at the
  call.** Tie-breaker 5 makes a call ambiguous when neither of two applicable
  blocks is more specialized (`design.md` "Generic types"), so an instance
  whose ambiguous member is never called is valid. The compiler reports the
  second block's member (`L0409`) as soon as `Pair(int, int)` exists:

  ```odin
  package main;
  Pair :: struct($A, $B: type) { a: A, b: B }
  impl Pair($A, int) { which :: proc(self) -> int { return 1; } }
  impl Pair(int, $B) { which :: proc(self) -> int { return 2; } }
  main :: proc() { p: Pair(int, int) = {1, 2}; }
  ```

- **A more specialized `impl` block declared after its instance exists does not
  win.** Members are installed when an instance is made, and a `when` condition
  can make one before a later block is registered. The later, more specialized
  block should supply `which`; the compiler reports it instead (`L0409`):

  ```odin
  package main;
  Box :: struct($T: type) { v: T }
  impl Box($T) { which :: proc(self) -> int { return 1; } }
  when (size_of(Box(int)) > 0) {
  	impl Box(int) { which :: proc(self) -> int { return 2; } }
  }
  main :: proc() { b: Box(int) = {5}; assert(b.which() == 2); }
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

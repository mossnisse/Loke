# Known gaps

Divergences between the specification documents and the shipped compiler, with
a minimal reproduction for each. A gap leaves this file when the compiler
accepts the program the spec describes — not when the spec is reworded to match
the compiler, unless the rewording is the intended fix.

## Gaps

- **Slicing has no compile-time meaning.** design.md "Compile-time procedure
  evaluation" allows ordinary expressions, but the evaluator rejects every slice
  expression with L0341, so `strconv.parse_i64`, which trims its input by
  slicing, cannot initialise a constant:

  ```odin
  tail :: proc(text: string_view) -> int { return text[1:3].len(); }
  B :: tail("xyz");   // L0341: this expression has no compile-time meaning
  ```
- **An allocation panic reports neither the size nor the allocator.** design.md
  "Allocation failure" says `.Panic` reports both; the runtime prints only
  `loke: panic: allocation failed`. The generated code reaches the policy after
  a `try_` operation or `try_clone` has failed, so no size travels with it, and
  a user `try_clone` may fail without making a request at all:

  ```odin
  arena: mem.Arena = {};
  xs: [dynamic]int via arena.allocator() = {};
  xs.append(1);   // loke: panic: allocation failed
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

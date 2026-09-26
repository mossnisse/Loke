# Known gaps

Divergences between the specification documents and the shipped compiler, with
a minimal reproduction for each. A gap leaves this file when the compiler
accepts the program the spec describes — not when the spec is reworded to match
the compiler, unless the rewording is the intended fix.

## Gaps

The first entry accepts a program that reads freed memory. It was found by a
provenance audit, and its repro builds and runs.

- **A callee's owner in an argument keeps no region at the call.** A callee
  may leave an owner built from an allocator parameter in an `inout` or
  `^mut` argument, since a received region may back what the caller owns,
  but the call does not give that argument the allocator argument's region.
  design.md "Allocator regions and region provenance" states only the result
  rule for this case:

  ```odin
  fill :: proc(dst: inout [dynamic][dynamic]int, allocator: Allocator) {
  	inner: [dynamic]int via allocator = {};
  	inner.append(1);
  	dst.append(move(inner));
  }
  arena := mem.Arena.init();
  outer: [dynamic][dynamic]int = {};
  fill(inout outer, arena.allocator());
  free_all(arena.allocator()); // accepted while `outer[0]` lives in the arena
  fmt.println(outer[0][0]);
  ```
- **Providers share region identities more than they need to.** All providers
  inside one local record or container are one region to the checker, and a
  provider replaced or removed through a pointer or slice ends the regions of
  every local holding providers, so resetting or replacing one is blocked by
  live owners of another. This rejects valid programs; it never accepts an
  invalid one.
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

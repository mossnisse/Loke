# Known gaps

Divergences between the specification documents and the shipped compiler, with
a minimal reproduction for each. A gap leaves this file when the compiler
accepts the program the spec describes — not when the spec is reworded to match
the compiler, unless the rewording is the intended fix.

## Gaps

- **A plain element returned straight out of a region-backed container is
  rejected.** design.md "Allocator regions and region provenance" gives region
  provenance to an owning value, so an `int` read from a container backed by a
  local arena may be returned. `lokec` reports `L0592` ("this result is backed
  by `arena`...") for the direct `return`, and accepts the same value bound to a
  local first:

  ```loke
  package main; import "core:mem"; import "core:fmt";
  first :: proc() -> int {
  	arena := mem.Arena.init();
  	ys: [dynamic]int via arena.allocator() = {};
  	ys.append(7);
  	return ys[0]; // L0592; `n := ys[0]; return n;` compiles
  }
  main :: proc() { fmt.println(first()); }
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

# Known gaps

Divergences between the specification documents and the shipped compiler, with
a minimal reproduction for each. A gap leaves this file when the compiler
accepts the program the spec describes — not when the spec is reworded to match
the compiler, unless the rewording is the intended fix.

## Gaps

- **Replacing a provider through a pointer is not checked.** design.md
  "Allocators" requires a region to outlive the owners it backs. Assigning
  over a provider field of a local, or removing one from a local container, is
  checked, but a write through a pointer to that local is not, so this compiles
  and then aborts in `xs`'s cleanup:

  ```odin
  holder := Holder{mem.Arena.init()};   // Holder :: struct { arena: mem.Arena }
  xs: [dynamic]int via holder.arena.allocator() = {};
  xs.append(1);
  p := &mut holder;
  p.arena = mem.Arena.init();
  fmt.println(xs.len());
  ```

  The checks key a provider's end to the local it lives in; a pointer's target
  is known only to the borrow solver.
- **Providers in one local share a region identity.** All providers inside one
  local record or container are one region to the checker, so resetting or
  replacing one is blocked by live owners of another. This rejects valid
  programs; it never accepts an invalid one.

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

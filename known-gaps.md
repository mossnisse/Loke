# Known gaps

Divergences between the specification documents and the shipped compiler, with
a minimal reproduction for each. A gap leaves this file when the compiler
accepts the program the spec describes — not when the spec is reworded to match
the compiler, unless the rewording is the intended fix.

## Gaps

- **A provider moved into existing storage ends its region.** design.md
  "Allocators" says moving an owner transfers its region dependency to the
  destination. The compiler follows a provider moved into a new local, a
  composite literal initializing one, or a result, and treats a move anywhere
  else as ending the region, so this valid program is rejected (L0537):

  ```odin
  holder: Holder = {};            // Holder :: struct { arena: mem.Arena }
  arena := mem.Arena.init();
  xs: [dynamic]int via arena.allocator() = {};
  xs.append(1);
  holder.arena = move(arena);     // also: `all.append(move(arena))`
  drop(xs);
  ```

  All providers inside one local record or container also share one region
  identity, so resetting one is blocked by owners of another.
- **A nil `Allocator` reaches a runtime abort.** design.md does not say what a
  nil handle means. A container `via` one binds the default provider, while
  `new`, `free`, `free_all`, and `strings.copy` through one abort with
  "allocator record does not match this runtime's ABI". A nil argument to an
  `@(allocator_reset)` parameter is accepted because its region set is empty,
  although design.md says checked code cannot reach a reset abort:

  ```odin
  release :: proc(@(allocator_reset) a: Allocator) { free_all(a); }
  release(nil);                   // aborts
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

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
- **A fixed-buffer arena's buffer is writable while owners in it are live.**
  design.md "Allocators" says the arena borrows the supplied storage, but the
  borrow ends at the arena's last use, not its owners' last use or cleanup:

  ```odin
  buffer: [4096]u8 = {};
  arena := mem.Arena.from_buffer(buffer[:]);
  xs: [dynamic]int via arena.allocator() = {};
  xs.append(1, 2, 3);
  for (i := 0; i < 4096; i += 1) { buffer[i] = 0; }
  fmt.println(xs[0]);             // prints 0, then cleanup aborts
  ```
- **A zero `mem.Arena` or a nil `Allocator` reaches runtime aborts.** design.md
  "Allocators" says checked code cannot reach the unsupported-reset abort, and
  does not say what either zero value means. A zero `Arena` or `Scratch` hands
  out a nil handle; a container `via` it binds the default provider, while
  `new`, `free`, `free_all`, and `strings.copy` through it, or through any nil
  `Allocator`, abort with "allocator record does not match this runtime's
  ABI". A nil argument to an `@(allocator_reset)` parameter is accepted
  because its region set is empty:

  ```odin
  a: mem.Arena = {};              // needed: a `static` provider starts here
  free_all(a.allocator());        // aborts
  ```

  Fixing it needs a decision on what the zero provider and a nil handle mean.
- **The low-level allocation procedures are not in package `mem`.** design.md
  "Allocators" says `new`, `new_clone`, `make`, `free`, `free_all`, and `drop`
  "are also available in package `mem`"; `mem.new(int)` is L0335. The
  universe names work.

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

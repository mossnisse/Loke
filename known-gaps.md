# Known gaps

Divergences between the specification documents and the shipped compiler, with
a minimal reproduction for each. A gap leaves this file when the compiler
accepts the program the spec describes — not when the spec is reworded to match
the compiler, unless the rewording is the intended fix.

## Gaps

- **Ending a region by `drop` or `move` is not checked.** design.md
  "Allocators" requires a region to outlive the owners it backs, but only a
  provider's own scope exit and `free_all` are checked against live owners.
  Each of these compiles and then aborts in `xs`'s cleanup ("allocator record
  does not match this runtime's ABI") after reading the freed control block:

  ```odin
  arena := mem.Arena.init();
  xs: [dynamic]int via arena.allocator() = {};
  xs.append(1);
  drop(arena);                    // also: { b := move(arena); }
  ```

  A record holding a provider (`Env :: struct { s: mem.Scratch }`, then
  `drop(env)`) has the same hole, as does an owner declared before the record a
  provider was moved into, since cleanup runs in reverse declaration order.
  `cfg.odin` `provider_cleanup_reset` is the one place a region end is checked;
  a moved provider also gets a fresh region token rather than its source's.
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

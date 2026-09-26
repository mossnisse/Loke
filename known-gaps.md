# Known gaps

Divergences between the specification documents and the shipped compiler, with
a minimal reproduction for each. A gap leaves this file when the compiler
accepts the program the spec describes — not when the spec is reworded to match
the compiler, unless the rewording is the intended fix.

## Gaps

- **An allocation panic can report an earlier, handled request.** design.md
  "Allocation failure" has `.Panic` report the requested size, and a failure
  that made no request reports only the allocator. The runtime keeps each
  thread's last refused request until another request is made, so a handled
  `try_` failure followed by a `try_clone` that answers `.err` on its own, or
  a size that overflows before any request, reports the handled one:

  ```odin
  switch (_ in try_new(Huge)) { case .ok: case .err: }  // handled
  other := refusing.clone();  // reports Huge's size, not "no size requested"
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

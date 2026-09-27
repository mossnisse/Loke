# Known gaps

Divergences between the specification documents and the shipped compiler, with
a minimal reproduction for each. A gap leaves this file when the compiler
accepts the program the spec describes — not when the spec is reworded to match
the compiler, unless the rewording is the intended fix.

## Gaps

A second audit of the root and region provenance analyses found the entries
below.

- **Freeing and reallocating in a loop is reported as a double release.**
  `invalid` is kept per loan, not per slot: at the loop head `p` may hold the
  first allocation (from the entry edge) and that allocation is released (on
  the back edge), so L0514 reports a second `free` no path performs:

  ```odin
  p := new(int);
  for (i := 0; i < 3; i += 1) {
  	free(p);
  	p = new(int);
  }
  free(p);
  ```
- **`unsafe.write` does not record the region of the owner it stores.**
  design.md "The `unsafe` package" stores the value the way an initialization
  takes it, and `self.items[0] = move(value)` into caller storage needs
  `@(escape=stored)` on `value` (L0536). Through `unsafe.write` it does not, so
  a caller is not told that its argument's region now backs `self`. Checking it
  needs that annotation on `try_shared_from_move` in `base/runtime/shared.loke`
  and on the `move` parameters of the containers in `tests/run`:

  ```odin
  Buffer :: struct { count: int, @(initialized = count) items: [4]string }
  push :: proc(self: inout Buffer, value: move string) {
  	unsafe.write(self.items[self.count], move(value)); // accepted
  	self.count += 1;
  }
  ```
- **L0536 names the destination, not the escaping owner.** design.md
  "Required diagnostics" asks for the owner and its region.
  `prov_region_escape_set` names the destination and calls the region "created
  in this procedure": `t := make([dynamic]int, 4, arena.allocator()); g =
  move(t);` reports "`g` is backed by an allocator region created in this
  procedure".
- **A `to_c_view()` result may be kept.** design.md "C string views" says it
  cannot be assigned, returned, or stored, but `c := s.to_c_view();` is
  accepted. It is safe today, because the emitter never builds a terminated
  temporary and the view borrows `s` (the `ponytail:` note on `.To_C_View` in
  `emit_llvm_expr.odin`), so either the spec says it borrows the string, or
  the checker rejects keeping it.

An architecture review of the checker found the two below.

- **A procedure literal in an interface requirement is analysed as part of the
  program.** A requirement is checked hypothetically (design.md "Interface
  bodies"), and a bound that does not hold only removes its candidate
  (design.md "where clauses"), so this program selects `pick_text`. It is
  rejected instead, with L0526 reported twice, once per probe: `check_proc_body`
  enrolls the literal's body in `checked_bodies` at any `speculation_depth`, and
  the whole-program provenance pass reports on it. With `{ return nil; }` as the
  literal's body the program prints `2`. The same probe also emits the literal's
  `static` locals as globals (`record_static_local` is not gated either) and the
  `clone`/`try_clone` procedures of a type the literal copies:

  ```odin
  call_with :: proc(value: int, f: proc(x: int) -> ^int) -> int { return 1; }
  Probe :: interface($T: type) {
  	(value: T) call_with(value, proc(x: int) -> ^int { y := x; return &y; }) -> int;
  }
  pick_probe :: proc(value: $T) -> int where Probe(T) { return 1; }
  pick_text :: proc(value: string) -> int { return 2; }
  choose :: proc { pick_probe, pick_text }
  main :: proc() { fmt.println(choose("text")); }
  ```
- **A `when` condition that slices a name from another `when` branch is
  answered a round early.** A selected branch's declarations behave as if
  written in its place (design.md "when statement"), so `TABLE` is a file-scope
  constant. The second condition is evaluated before that branch is declared,
  reports L0315 for `TABLE`, and selects neither branch, so `PICKED` is unknown.
  `first_unresolved_name` in `src/select.odin` does not look inside a slice, a
  range, an `or_else`, or a `.(T)` extraction, so it finds nothing to wait for;
  `TABLE[1] == 2` waits a round and selects `PICKED :: 1`:

  ```odin
  when (true) { TABLE :: [3]int{1, 2, 3}; }
  when (TABLE[0:2][1] == 2) { PICKED :: 1; } else { PICKED :: 2; }
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

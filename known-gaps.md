# Known gaps

Divergences between the specification documents and the shipped compiler, with
a minimal reproduction for each. A gap leaves this file when the compiler
accepts the program the spec describes — not when the spec is reworded to match
the compiler, unless the rewording is the intended fix.

## Gaps

A second audit of the root and region provenance analyses found the entries
below.

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

An architecture review of the checker found the one below.

- **A procedure literal in an interface requirement adds copy procedures to the
  program.** A requirement is checked hypothetically (design.md "Interface
  bodies"), but the ownership analysis of the probed literal's body still
  contributes `Tag`'s lifecycle members, so `Tag.clone` and `Tag.try_clone` are
  emitted although nothing in the program copies a `Tag`. Without the
  `static_assert` they are not:

  ```odin
  Tag :: struct { label: string }
  call_with :: proc(value: int, f: proc(x: int) -> int) -> int { return 1; }
  Probe :: interface($T: type) {
  	(value: T) call_with(value, proc(x: int) -> int { a: Tag = {}; b := a; return x; }) -> int;
  }
  main :: proc() { static_assert(Probe(int)); }
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

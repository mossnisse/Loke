# Known gaps

Divergences between the specification documents and the shipped compiler, with
a minimal reproduction for each. A gap leaves this file when the compiler
accepts the program the spec describes — not when the spec is reworded to match
the compiler, unless the rewording is the intended fix.

Nothing here is checked by the test corpus: a test asserting today's behavior
would cement the wrong answer, and one asserting the right answer would be red.
Each entry carries its own repro instead, small enough to paste.

## Gaps

- **An owner or allocation may outlive the local `mem.Arena`/`mem.Scratch` that
  backs it, inside one body.** `design.md` "Allocator regions and region
  provenance" says such an owner may not be returned, stored in `static`,
  `thread_local` or file-scope storage, "or otherwise retained past that
  region". The first three are checked (`L0592`, `L0536`); a plain scope exit is
  not, so both procedures below compile and both read released storage.
  `src/cfg.odin`'s `emit_cleanups` emits `.Root_End` for lexical roots and a
  `.Cleanup` flow event for owners, but nothing that ends a provider's region.
  Emitting a reset there is the shape of the fix, except that `prov_reset` reads
  its dead-owner set out of `reset_dead`, which is keyed by call node — with no
  call it would blame the moved-from `ys` below.

  ```loke
  package main; import "core:mem"; import "core:fmt";

  outlive_local_arena :: proc() {
	xs: [dynamic]int = {};
	{
		a := mem.Arena.init();
		ys: [dynamic]int via a.allocator() = {};
		ys.append(7);
		xs = move(ys);
	}
	fmt.println(xs[0]);
  }

  pointer_outlives_local_arena :: proc() {
	p: ^mut int = ---;
	{
		a := mem.Arena.init();
		p = new(int, a.allocator()) or_else nil;
	}
	if (p == nil) { panic("no"); }
	fmt.println(p^);
  }

  main :: proc() { outlive_local_arena(); pointer_outlives_local_arena(); }
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

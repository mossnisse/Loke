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

- **`move` out of a variant-switch binding whose subject is a live local is
  accepted, and double-frees.** `design.md` "Decomposition" says a temporary or
  `move(...)` consumes; a plain named local does not, so the binding borrows a
  payload the subject still owns. Moving out of that borrow leaves the subject
  live, and its scope-exit drop releases storage the move already transferred.
  The program below aborts with a heap corruption before it prints. Either the
  move should be rejected against an unconsumed subject, or binding should
  consume it. Consuming the subject explicitly — `switch (owned in
  move(outcome))` — is the working spelling today, and is what
  `core/fs/fs.loke`'s `read_bytes` uses.

  ```loke
  package main; import "core:fmt"; import "core:slice";

  main :: proc() {
	source := [?]int{1, 2, 3};
	outcome := slice.try_clone(source[:]);
	switch (owned in outcome) {
	case .ok:
		taken := move(owned);
		fmt.println(taken.len());
	case .err:
		fmt.println(-1);
	}
  }
  ```

- **A `return` inside a `switch` arm emits a store to a `defer` slot that block
  has not declared yet.** The generated IR names a `%deferN` alloca the early
  return's cleanup path clears, but the slot is only created where the `defer`
  statement appears — after the switch — so `clang` rejects the module with
  `use of undefined value`. The check phase reports nothing; the failure is
  `error[L0403]` from the linker step. Registering the slot at block entry, or
  skipping the clear for a `defer` the return cannot have reached, is the shape
  of the fix. Moving the `defer` above the switch is the workaround, and is what
  `core/os/process.loke` does.

  ```loke
  package main; import "core:fmt"; import "core:slice";

  f :: proc() -> int {
	a := [?]int{1};
	b: [dynamic]int = {};
	switch (made in slice.try_clone(a[:])) {
	case .ok:  b = move(made);
	case .err: return -1;
	}
	defer drop(b);
	return b.len();
  }

  main :: proc() { fmt.println(f()); }
  ```

## Not gaps

Recorded because they look like gaps and are not, and each cost an
investigation once.

- **An exhaustive enum `switch` where every arm returns still needs a return
  after it** (`error[L0365]`). Correct: `design.md` "Exhaustive switch" makes
  exhaustiveness a check over declared members, not values, and conversion into
  an enum is unchecked — so a subject holding a non-member value matches no case
  and falls out of the bottom. A *variant* switch covering every variant is the
  case where no path reaches the end, and the compiler already accepts that one
  with no trailing return. The diagnostic now says this at the switch rather
  than at the signature, so it no longer reads as a missing feature.
- **Overlapping range cases are accepted.** Correct: cases are tried top to
  bottom and the first match wins (`design.md` "switch statement"). Only
  duplicate constant values are diagnosed.

# Known gaps

Divergences between the specification documents and the shipped compiler, with
a minimal reproduction for each. A gap leaves this file when the compiler
accepts the program the spec describes — not when the spec is reworded to match
the compiler, unless the rewording is the intended fix.

## Gaps

The first four entries accept programs that read dead or freed memory. Each was
found by a provenance audit, and each repro builds and runs.

- **A conditional copies a place it should reject.** design.md "Value
  semantics and the ownership rule" rejects a place whose copy may allocate,
  and binding a conditional binds its selected arm. A `[dynamic]T` or `map`
  place in an arm is neither rejected nor cloned, so its storage is freed
  twice. A `string` arm, whose copy retains its storage, runs correctly:

  ```odin
  xs := [dynamic]int{1};
  ys := [dynamic]int{2};
  z := xs if flag else ys; // heap corruption; expected L0504
  ```
- **Some ways of storing an owner drop its region.** design.md "Allocator
  regions and region provenance" keeps a local region's owner out of
  aggregates, containers and static storage. `prov_assign` records region
  content for a direct place, but `prov_container_content` publishes only
  borrows, so `append`, `insert` and `try_insert` lose the region, and so do
  `exchange` and a write through a `^mut` or `[]mut` carrier. Appending to a
  global is not reported as a region escape either:

  ```odin
  arena := mem.Arena.init();
  outer: [dynamic][dynamic]int = {};
  inner: [dynamic]int via arena.allocator() = {};
  inner.append(1);
  outer.append(move(inner));
  free_all(arena.allocator()); // accepted while `outer[0]` lives in the arena
  fmt.println(outer[0][0]);
  ```
- **Region facts are read in walk order.** `region_of` is flow-insensitive,
  but a reset, a `return` or a global store reads it while the body is still
  being walked, so an owner that becomes arena-backed later in a loop body is
  missed on the back edge. `prov_finalize_allocation_regions` already
  re-resolves allocation roots after the walk; owners are not re-resolved:

  ```odin
  arena := mem.Arena.init();
  xs: [dynamic]int = {};
  for (i := 0; i < 2; i += 1) {
  	free_all(arena.allocator()); // accepted; `xs` is arena-backed here on the second pass
  	if (i > 0) { fmt.println(xs[0]); }
  	xs = make([dynamic]int, 4, arena.allocator());
  }
  ```
- **A `move` parameter carries no region.** `prov_bind_parameters` gives a
  region only to `Allocator` parameters, so returning a moved owner summarizes
  to no region, although design.md "Allocator regions and region provenance"
  says the result keeps the moved value's. The same section forbids retaining
  a `move` parameter in longer-lived storage, but
  `stash :: proc(dst: inout [dynamic][dynamic]int, v: move [dynamic]int) { dst.append(move(v)); }`
  is accepted. A callee can also leave an owner it built from an allocator
  parameter in a `^mut` argument; the spec states only the result rule for
  that case:

  ```odin
  id :: proc(v: move [dynamic]int) -> [dynamic]int { return move(v); }
  arena := mem.Arena.init();
  inner: [dynamic]int via arena.allocator() = {};
  inner.append(1);
  outer := id(move(inner));
  free_all(arena.allocator()); // accepted
  fmt.println(outer[0]);
  ```
- **A carrier's own loan and its elements' borrows are one set.** A carrier
  is a single path of its `carrier_shape`, so a call summary cannot say that a
  result holds only what a slice's elements borrow, not the slice itself.
  Returning an element of a `[]mut T` whose `T` carries a borrow therefore
  reborrows the slice, and a second use while that result is live is
  rejected. This rejects valid programs; it never accepts an invalid one:

  ```odin
  arr := [2]string_view{"b", "a"};
  xs: []mut string_view = arr[:];
  fmt.println(slice.min(xs), slice.max(xs)); // L0641: `xs` is suspended
  ```
- **Providers share region identities more than they need to.** All providers
  inside one local record or container are one region to the checker, and a
  provider replaced or removed through a pointer or slice ends the regions of
  every local holding providers, so resetting or replacing one is blocked by
  live owners of another. This rejects valid programs; it never accepts an
  invalid one.
- **Slicing has no compile-time meaning.** design.md "Compile-time procedure
  evaluation" allows ordinary expressions, but the evaluator rejects every slice
  expression with L0341, so `strconv.parse_i64`, which trims its input by
  slicing, cannot initialise a constant:

  ```odin
  tail :: proc(text: string_view) -> int { return text[1:3].len(); }
  B :: tail("xyz");   // L0341: this expression has no compile-time meaning
  ```
- **An allocation panic reports neither the size nor the allocator.** design.md
  "Allocation failure" says `.Panic` reports both; the runtime prints only
  `loke: panic: allocation failed`. The generated code reaches the policy after
  a `try_` operation or `try_clone` has failed, so no size travels with it, and
  a user `try_clone` may fail without making a request at all:

  ```odin
  arena: mem.Arena = {};
  xs: [dynamic]int via arena.allocator() = {};
  xs.append(1);   // loke: panic: allocation failed
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

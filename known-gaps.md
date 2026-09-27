# Known gaps

Divergences between the specification documents and the shipped compiler, with
a minimal reproduction for each. A gap leaves this file when the compiler
accepts the program the spec describes — not when the spec is reworded to match
the compiler, unless the rewording is the intended fix.

## Gaps

A second audit of the root and region provenance analyses found the entries
below. The first six accept programs that read or write dead or freed
memory; each repro builds and runs.

- **One call's arguments may alias through one carrier.** `inout p^` is no
  place to `prov_place_of`, so it takes neither a write access nor a mutable
  loan, and `prov_reborrow` records nothing for an argument (`into == -1`), so
  no argument suspends the carrier another is read through (design.md
  "Weakening and reborrows"). `f(inout p^, p^)` with a value parameter, and one
  `[]mut` passed to two `[]mut` parameters, are accepted too:

  ```odin
  grow_and_read :: proc(a: inout [dynamic]int, b: []int) {
  	for (i := 0; i < 1000; i += 1) { a.append(i); }
  	fmt.println(b[0]);
  }
  xs := [dynamic]int{1};
  p := &mut xs;
  grow_and_read(inout p^, p^[:]); // `b` views what `a` reallocates
  ```
- **`@(escape=stored)` misses destinations nested in an argument.** design.md
  "Retaining a borrow" lets a `stored` argument land in any mutable destination
  the call receives. `prov_writable_arguments` counts only an `inout` argument
  and the storage one `^mut` or `[]mut` level down, so a `^mut` inside a record
  argument, a `[]^mut T`, a `^mut ^mut T` or an `inout ^mut T` is written
  behind the caller's back:

  ```odin
  Holder :: struct { v: []int }
  Ctx :: struct { dst: ^mut Holder }
  keep :: proc(ctx: Ctx, @(escape=stored) a: []int) { ctx.dst.v = a; }
  h: Holder = {};
  {
  	arr := [3]int{1, 2, 3};
  	keep(Ctx{&mut h}, arr[:]);
  }
  fmt.println(h.v[0]); // `arr` has ended
  ```
- **Contract substitution ignores written regions.** A call through a
  `type_of` contract uses the contract declaration's written regions
  (`prov_call_written_regions`), but `result_contract_within` compares only
  result dependencies and regions, so a declaration that leaves an owner in a
  `^mut` argument converts to the type of one that does not (design.md
  "Procedure result contracts"):

  ```odin
  a :: proc(dst: ^mut [dynamic]int, alloc: Allocator) -> string { return ""; }
  b :: proc(dst: ^mut [dynamic]int, alloc: Allocator) -> string {
  	dst^ = make([dynamic]int, 4, alloc);
  	return "";
  }
  A :: type_of(a);
  f: A = b;
  xs: [dynamic]int = {};
  arena := mem.Arena.init();
  _ = f(&mut xs, arena.allocator());
  free_all(arena.allocator()); // `xs` is arena-backed
  fmt.println(xs[0]);
  ```
- **`unsafe.take` strips borrows for callers that never import `core:unsafe`.**
  `prov_call` returns no loans for `Unsafe_Take`, so `Small_Array`'s `pop`,
  `remove` and `remove_unordered` summarize to results that borrow nothing.
  design.md "What is not checked" exempts views stripped through
  `core:unsafe`, but here the file doing it is the library's, and the caller's
  view goes unchecked:

  ```odin
  sa: container.Small_Array([]int, 4) = {};
  v: []int = nil;
  {
  	arr := [3]int{1, 2, 3};
  	sa.append(arr[:]);
  	v = sa.pop() or_else nil;
  }
  fmt.println(v[0]); // `arr` has ended
  ```
- **A mutable carrier loaded through a pointer is no reborrow.** design.md
  "Weakening and reborrows" makes any copy of a mutable carrier a reborrow of
  it. A `Load` copies the loans but registers no `Prov_Reborrow`, so the
  source is not suspended:

  ```odin
  xs := [dynamic]int{1};
  p := &mut xs;
  pp := &p;
  q := pp^;     // a copy of `p` that does not suspend it
  e := &q^[0];
  p^.append(2); // may reallocate under `e`
  fmt.println(e^);
  ```
- **A bare carrier in static storage forgets what it borrows.**
  `prov_slot_for_symbol` gives a file-scope or `static` carrier no slot, citing
  an exemption design.md "What is not checked" does not state, and
  `prov_read_ident` reads it as a borrow of its own storage. The same view in a
  field of a global record is tracked, and the program below rejected:

  ```odin
  g_view: []int;
  g_arr: [dynamic]int;
  main :: proc() {
  	g_arr.append(1);
  	g_view = g_arr[:];
  	g_arr.append(2); // may reallocate under `g_view`
  	fmt.println(g_view[0]);
  }
  ```
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
- **Copying a global record that holds a borrow into another global is
  rejected.** `prov_content_slots` gives a global's existing content an
  `Unknown` root, which `root_satisfies_retention` refuses for every
  destination, although only a borrow that outlives the process can have been
  stored there (L0647):

  ```odin
  Holder :: struct { v: []int }
  a: Holder;
  b: Holder;
  main :: proc() { b = a; }
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

# `src/cfg_provenance.odin`

Reviewed at `ea622efe`. This file translates checked expressions and statement
bindings into roots, carrier slots, loans, and events. The CFG walker owns
control flow and the solver computes facts over the resulting events.
[Compiler architecture](../compiler-architecture.md#disposable-control-flow-graphs)

## Findings

### P2 · Map literals with carriers omit hash and equality effects

`prov_composite_content` walks map keys and values at lines 290–331 and returns
without recording key effects. `walk_flow_composite` returns early on that
path. Its fallback records `prov_key_effects` only when the literal has no
carrier slots. LLVM inserts an entry for both paths, and either insertion can
invoke user hash and equality code. Record these effects at the insertion point
after each entry's value in both walks, before starting the next entry. Changing
only the result shape should preserve the same implicit calls.
[Carrier literal walk](../../src/cfg_provenance.odin#L290), [fallback walk](../../src/cfg.odin#L1934), [LLVM insertion](../../src/emit_llvm_containers.odin#L326), [Global write effects](../design.md#global-write-effects)

```loke
package main;

counter: int = 1;
Key :: struct { n: int }
impl Key {
    hash :: proc(self, seed: uint) -> uint { return seed + uint(self.n + counter); }
    same :: operator(==) proc(a, b: Key) -> bool { return a.n == b.n; }
}
main :: proc() {
    held := &mut counter;
    local := 5;
    table := map[Key]^int{Key{1} = &local};
    held^ = table.len();
}
```

`-emit-ll` succeeds and the IR installs a hash thunk that calls `Key.hash`.
Replacing `map[Key]^int{Key{1} = &local}` with
`map[Key]int{Key{1} = local}` rejects the read with `L0511`.

### P3 · Preserve range information for slices reached through a carrier

`prov_borrow_named` extends the loan path with `prov_range_step` at line 1849.
`prov_borrow_through` evaluates the bounds at lines 1878–1880 and then emits its
write and loan with the path to the whole array. The through-carrier reservation
at lines 1954–1960 has the same loss. With `cells: [4]int = {}`, two live slices
`cells[mut 0:2]` and `cells[mut 2:4]` compile and can both be written. Taking the
same slices as `p^[mut 0:2]` and `p^[mut 2:4]` after `p := &mut cells` reports
`L0641`. A precision improvement would carry the range through the reservation,
read and loan paths while keeping unknown ranges conservative. The language
permits this conservative rejection.
[Named and through-carrier borrowing](../../src/cfg_provenance.odin#L1846), [reservation](../../src/cfg_provenance.odin#L1931), [Places and overlap](../design.md#places-and-overlap)

### P3 · Use a growable buffer at repeated loan-list joins

`prov_join` at line 156 allocates and copies both nonempty inputs. That suits
two branches, but the switch walker repeatedly joins a growing prefix with one
arm's loans. Across many carrier-bearing arms that copies a quadratic number
of slot IDs and retains every intermediate slice in the graph arena. Append the
arms into a graph-allocated dynamic array and expose its slice at the merge.
The complexity follows from the loop and allocation lifetimes. Its workload
impact was not measured.
[Join](../../src/cfg_provenance.odin#L156), [switch accumulation](../../src/cfg.odin#L1730)

### P3 · Keep view definition tracking with its consumers

`prov_note_view`, `prov_note_reslice`, and `prov_note_open_borrow` at lines
55–146 maintain a single view-definition representation. Co-locate those helpers
with view tracking in `provenance_views.odin`. Keep `prov_emit` responsible for
attaching the returned definition index to a graph event.
[View definition construction](../../src/cfg_provenance.odin#L55), [view tracking](../../src/provenance_views.odin)

## Verification

Inspected the event construction and its callers and ran the two focused
comparison probes with the revision-stamped compiler. The review changed only
this report. No standalone dead code was identified in the paths reviewed.

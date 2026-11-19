# `src/cfg.odin`

Reviewed at `ea622efe`. The graph builder walks the checked AST once per
analysis mode, giving ownership and provenance the same control-flow topology.
The adjacency lists and indexed blocks suit the sparse graph. The separate
forward and backward worklists serve solvers with different starting points.
[Source](../../src/cfg.odin) · [Compiler architecture](../compiler-architecture.md#disposable-control-flow-graphs)

## Findings

1. **High · Unwind edges miss moves within a statement.** At lines 711–751,
   `emit_unwind_branch` sends cleanup through the state at entry to the whole
   statement. A later argument can panic after an earlier explicit move has
   already invalidated a local read by a pending defer. The example below
   compiles, and its IR clears `item` before calling `risky`. Splitting the
   move into a preceding statement produces L0500. Evaluating `risky()`
   before the move compiles. Model the cleanup edge at the panic-capable
   operation after any preceding lifecycle changes. Keep the lifecycle and
   provenance cleanup keys aligned at those program points.
   [Unwind branch](../../src/cfg.odin) · [Evaluation order](../design.md#evaluation-order) · [Defer statement](../design.md#defer-statement)

   ```loke
   package main;
   import "core:fmt";

   Err :: enum { Bad }
   @(move_only) Item :: struct { value: int }
   risky :: proc() -> int { panic("later call"); }
   eat :: proc(item: move Item, number: int) { _ = item.value; _ = number; }

   exercise :: proc() -> Status(Err) {
       item := Item{42};
       errdefer fmt.println(item.value);
       eat(move(item), risky());
       return .ok;
   }
   main :: proc() { _ = exercise(); }
   ```

2. **Algorithm · Batch queries about later reads by block.** At lines
   2252–2283 and 2329–2337, every required result write or possible last use
   unions successor rows again and scans its remaining block events again.
   A straight-line block with one candidate per statement can do quadratic
   event visits after the fixed point has already settled. For each mode,
   compute the exit row once per queried block and walk events backward once,
   answering candidates immediately before applying their event's transfer.
   Preserve the `lent` override, the unwind setting, diagnostic order, and
   the rule that all expansions of a shared clone site must agree. Confirm
   the compile-time gain on a straight-line workload before changing the
   solver. [Read queries](../../src/cfg.odin) · [Last-use transfer](../design.md#last-use-transfer)

3. **Simplify · Collect stored-value reads only when needed.** At lines
   438–446, `walk_flow_stored` always allocates a read buffer and records
   each tracked use. It then discards the buffer for bare identifiers and
   values whose types cannot carry borrows. Check the expression shape and
   type first, then walk directly in those cases. Any enclosing read
   collector still sees emitted uses through `flow_emit`. Capture a local
   list only when the reads can mark locals as lent.
   [Stored values and event emission](../../src/cfg.odin)

4. **Boundary · Keep allocator initialization outside graph construction.**
   At lines 310–329, `use_allocator` uses Odin runtime reflection to set
   embedded container allocators. The same helper initializes normalized
   input, provenance state, and effect-program records. A shared allocation
   utility is a closer owner for this existing helper. The graph can
   continue to call the same function. [Graph initialization](../../src/cfg.odin) ·
   [Input initialization](../../src/provenance_input.odin) ·
   [Effect program initialization](../../src/provenance_effect.odin) ·
   [Provenance state initialization](../../src/provenance_state.odin)

The panic checks used the fresh compiler with `-emit-ll` and inspected the
generated IR. The rest of the review used source and caller tracing. No
standalone dead code surfaced.

# `src/callback_summary.odin`

Reviewed at `ea622efe`. This file substitutes known or possible callback targets into call-site provenance, aligns receiver and argument positions, and reads callee summaries for carrier moves and writes into allocator-backed storage. The visited set is needed to terminate cyclic callback queries.

## Findings

1. **High · Callback substitution drops possible borrow roots.** `returned_thread_local` at line 379 stops at the first thread-local global in a result summary. `procedure_left_at` and `type_left_at` likewise produce one root, which `value_left` hands to `call_callback_reads` or `call_callback_returns`. That root becomes an ordinary loan in `prov_callback_loans`, so a mutation of another possible root can pass the checker while its slice is live. Accumulate all distinct reachable roots for loan construction, retaining a per-query visited set for `(procedure, position)`. A crossing diagnostic can still use one representative. Check the related write path when changing the representation because `thread_local_writes` also retains only one concrete root per argument. [Callback resolution](../../src/callback_summary.odin), [result loans](../../src/provenance_results.odin), [write summary producer](../../src/borrow_summaries.odin), [borrows and lifetimes](../design.md#borrows-and-lifetimes)

   ```loke
   package main;

   a: thread_local [dynamic]int;
   b: thread_local [dynamic]int;

   get :: proc(pick_a: bool) -> []int {
       if (pick_a) { return a[:]; }
       return b[:];
   }
   call_get :: proc(f: proc(pick_a: bool) -> []int, pick_a: bool) -> []int {
       return f(pick_a);
   }
   main :: proc() {
       seen := call_get(get, true);
       a.append(1);
       _ = seen.len();
   }
   ```

   A fresh `ea622efe` compiler emitted IR for this program. Replacing `call_get(get, true)` with `get(true)` produced `L0512` on `a.append(1)`. Keeping the wrapped call and changing the mutation to `b.append(1)` also produced `L0512`.

2. **Simplify · Remove the singleton target copy.** `call_summary_targets` at line 122 always allocates target and stand-in buffers. Its no-value branch calls `call_thread_local_targets` at line 156, which allocates a separate singleton for a direct declaration and immediately copies it into the target buffer. Resolve the direct declaration in the caller and append it directly. Initialize the stand-in list with the temporary allocator and no capacity, since `forward = false` and direct calls never append to it. Keep the target list growable for `call_carrier_moves`, which appends members of joined contracts. [Target selection and carrier moves](../../src/callback_summary.odin)

3. **Performance hypothesis · Repeated callback argument lookup scans and copies.** `passed_values` at line 187 rescans a call site's resolved arguments and builds a temporary list for every callback summary read or write. The producer already emits resolved values in binding order. If a callback-heavy compiler profile shows meaningful cost here, store ranges per binding and return slices of the existing values. Preserve candidate order and the expression fallback for absent bindings. The current linear lookup is reasonable for small calls, and its cost was not measured in this review. [Lookup](../../src/callback_summary.odin), [argument resolution](../../src/provenance_global_effects.odin), [call-site storage](../../src/global_effects.odin)

4. **Boundary · Keep the summary insertion helper beside its callers.** `add_unique` at line 33 is used only by the two callback summary writers in `borrow_summaries.odin`. Move it there and give it file-private visibility so this file owns lookup and substitution, while the writer owns set growth and semantic allocation. [Helper](../../src/callback_summary.odin), [writer](../../src/borrow_summaries.odin)

The focused checks exercised the borrow checker through `-emit-ll`. Source code was reviewed without changes.

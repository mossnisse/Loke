# Source review of check_composite.odin

Reviewed [check_composite.odin](../../src/check_composite.odin) at
`ea622efe`. This file resolves the literal's type, associates each written
element with its destination, and records copy and constant information for
later passes. Array designators are checked as intervals. Sorting those
intervals uses space proportional to what the literal writes, so it works
even for a sparse array whose length is too large for a slot table.

## Findings

1. **P2 · A range can require an impossible copy, lines 330–359.** A
   range initializer checks the expression's first store but never checks
   the copies for later slots. With `@(move_only) Ticket :: struct { id: int }`,
   the body of `proc(n: int) -> [2]Ticket { return [2]Ticket{0..<2 = Ticket{n}}; }`
   reaches LLVM emission and reports internal error L0405 because `Ticket`
   has no clone member. The constant spelling
   `[2]Ticket{0..<2 = Ticket{1}}` compiles and duplicates the value during
   folding. Reject an interval wider than one when
   `type_clone_disabled` holds for the element, before folding or emission.
   Keep single-slot ranges valid and the single evaluation of copyable
   range values. [Fixed arrays](../design.md#fixed-arrays) ·
   [Move-only types](../design.md#move_only) ·
   [Range regression](../../tests/run/array_designated_initializers.loke) ·
   [LLVM aggregate emission](../../src/emit_llvm_expr.odin)

2. **P2 · A designator suppresses transfers of positional elements,
   lines 113–128.** `v.slot_ends` is allocated for the entire literal.
   In `a := Ticket{n}; return [2]Ticket{a, 1 = Ticket{n}};` with the same
   move-only type, L0503 wrongly requires an explicit move on `a`.
   Replacing the second element with `Ticket{n}` compiles. Test whether
   the particular element has an array designator. Share that predicate
   with the last-use transfer pass, which also skips the entire literal.
   [Returned constructions](../design.md#returned-constructions) ·
   [Last-use transfer](../design.md#last-use-transfer) ·
   [Transfer candidates](../../src/cfg.odin)

3. **P2 · Array key limits reject valid lengths,
   lines 24–33, 319–325, and 434–468.** `[?]u8{2000000 = u8(n)}` reports L0361
   for a runtime parameter `n`. The equivalent `[2000001]u8` literal
   emits IR. For an explicitly sized array of length `9223372036854775807`,
   the last index works as a scalar key, but the equivalent exclusive
   range reports L0361 at its end. Use the same length limit for inferred
   and explicit arrays and check overflow when advancing inclusive ends
   and scalar indices. Layout validation already bounds the inferred
   type and `fold_aggregate` applies the folding budget separately.
   [Fixed arrays](../design.md#fixed-arrays) · [Layout](../../src/layout.odin) ·
   [Constant budget](../../src/zero.odin)

4. **P3 · A rejected array remains available to the evaluator,
   lines 330–359.** The duplicate-slot and invalid-element exit leaves
   `v.type` set. In
   `when ([1]int{0 = 1, 0 = 2}[0] == 2) { MISSING :: unknown; }`,
   the evaluator overwrites slot 0 and the compiler reports L0315 in the
   branch as well as L0376 for the duplicate. Clear the array's type on
   this error path as the struct checker does. Add a `when` regression
   alongside the existing rejected-struct case.
   [Evaluator](../../src/eval.odin) ·
   [Rejected struct regression](../../tests/err/rejected_struct_literal_constant.loke)

5. **P3 · Bare captured array keys take the field-name diagnostic,
   lines 408–424 and 435–442.** In the body of a capture literal with
   `capture(slot = 1)`, `[2]int{slot = 10}` gives L0716, which says the
   capture cannot be read in this position. `[2]int{slot ..= 1 = 10}` gives
   L0372, which correctly says the index must be constant. The AST clone
   preserves bare keys because it cannot tell field names from value
   expressions. Resolve bare captured names as expressions once a key
   is known to designate an array slot, using the same lookup as map
   keys. [Capture literals](../design.md#capture-literals) ·
   [AST clone](../../src/ast_clone.odin) · [Capture lookup](../../src/capture.odin)

6. **Simplify · Use the first-key lookup for all three array paths,
   lines 24–32 and 305–325.** Return the first keyed element's index
   from a file-private helper, or `-1` for a positional literal.
   An inferred array already has slot metadata after its keys have been
   resolved. Use that result to skip its second designation scan. The
   SIMD rejection can use the first keyed element directly and drop its
   own loop. Keep the interval sort and source-order value checking.

7. **Simplify · Defer the positional field list and the folding cost check,
   lines 171–179 and 520–529.** The first element determines whether any
   valid positional elements are possible. Build `named_fields` only
   when that element is positional. This also avoids retaining an arena
   allocation for keyed literals of padded records. In
   `fold_aggregate`, test the written expressions for constant values
   before recursively counting the target's fields. Both changes retain
   the existing validation and constant limits.
   [Named field lookup](../../src/types.odin) ·
   [Constant element count](../../src/zero.odin)

## Verification

Ran focused probes with `loke-source-review.exe -emit-ll` at
`v0.10.0-4-gea622efe`. The runtime move-only range reached L0405.
The constant and single-slot forms emitted IR. The mixed return
produced L0503 and the all-positional control emitted IR. Only the
explicit-length sparse array emitted IR. The maximum-length bounds
probes used the unevaluated operand of `size_of`. The duplicate
designator selected the invalid `when` branch and reported L0315.
The bare capture key and range controls produced L0716 and L0372
respectively. The simplifications come from tracing callers and
allocations. All helpers have callers.

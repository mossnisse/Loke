# Source review of check_stmt.odin

Reviewed [check_stmt.odin](../../src/check_stmt.odin) at `ea622efe`. The file
checks statements and returns their control-flow summaries. It also rewrites
assignments that need a user-defined indexed setter.

## Findings

- **P1 · Correctness.** `check_user_compound` (lines 935–953) accepts an
  overload result that implicitly converts to the destination, then records
  only the selected procedure and its operands. With
  `Narrow :: (word: int | blank:)`, `Wide :: (blank: | number: int | word: int)`
  and `add :: operator(+) proc(w: Wide, x: int) -> Narrow { return .word(x); }`,
  `w: Wide = .blank; w += 5;` emits invalid LLVM IR. The call defines a
  `Narrow` SSA value and the store uses that value as `Wide`, skipping tag
  remapping. Carry a checked result conversion into compound lowering and
  apply it before storing. [Compound fallback](../design.md#operator-declarations),
  [Widening by label](../design.md#widening-by-label),
  [Compound emission](../../src/emit_llvm_stmt.odin)
- **P2 · Correctness.** `check_place_setter` (lines 498–521) represents a
  simple indexed assignment as an ordinary call with the new value last.
  `g[index()] = value();` consequently runs `index()` before `value()`.
  Evaluate and hold the value first, then prepare the receiver and indices,
  and invoke the setter with the prepared operands. Use the same ordering
  in execution and analysis. [Evaluation order](../design.md#evaluation-order),
  [LLVM emission](../../src/emit_llvm_stmt.odin), [Control-flow graph](../../src/cfg.odin)
- **P2 · Correctness.** `bind_index_place`, `needs_temporary` and
  `lower_parallel_setter_assign` (lines 574–605 and 640–660) approximate
  destination preparation from expression syntax. With a string key,
  `key, g[key] = "new", 8;` passes the newly written key to the setter.
  In `g[key] += change(inout key);`, the getter and setter both see the
  replacement key. Likewise, `p, p^, g[0] = &mut b, 8, 9;` writes through
  the newly installed pointer, and `g[0], a[i] = 7, 8;` calls the setter
  before checking the array bounds. Prepare every ordinary destination
  address and capture every mutable receiver path and key before the write
  phase. Reuse the ordinary assignment emitter's destination preparation,
  including its map-insertion handling. For compound setters capture the
  receiver and keys before evaluating the right operand.
  [Evaluation order](../design.md#evaluation-order),
  [Ordinary assignment emission](../../src/emit_llvm_stmt.odin)
- **P2 · Correctness.** `lower_parallel_setter_assign` (lines 625–638) checks
  nonconstant right operands as inferred local declarations. This loses
  destination context. Given `r := Rec{};` and a struct `Rec` with one
  `int` field, `r = {2};` succeeds but `g[0], r = 7, {1};` fails with
  L0376. Resolve targets and setter overloads with the written operands
  before building temporaries. Carry the checked types and conversions into
  assignment preparation. This also removes the need for `lowered_constant`
  (lines 735–753) to clone and speculatively check each right operand merely
  to decide whether deferring its check preserves context.
  [Assignment statements](../design.md#assignment-statements),
  [Struct literals](../design.md#struct-literals),
  [Index argument checking](../../src/check_index.odin)
- **P2 · Correctness.** `report_unread_required_bindings` (lines 80–95)
  starts from the local's type. With
  `@(require_results) Status :: union { okay, bad: int }`,
  `x: Status = .bad(1);` reports L0698 even though no call produced the
  value. The CFG's `note_required_write` already distinguishes union
  construction from a call, but excludes locals with no later name use.
  Use the same producer check for both paths, or let the CFG own the
  per-write diagnostic and remove the name-based pass once it covers
  declarations and deferred reads. [Required results](../design.md#require_results),
  [Required-write analysis](../../src/cfg.odin)
- **P2 · Correctness.** `check_stmt` (lines 226–245) only propagates a
  diverging call for expression statements. For
  `fail :: proc() -> ! { panic("end"); }`, the procedure
  `work :: proc() -> int { a := 1; a = fail(); }` reports L0365.
  The assignment has a valid expected type and cannot finish. Use checked
  expression reachability for statement fallthrough, including initializers
  and assignment operands, so reachability also respects lazy expressions.
  [Diverging procedures](../design.md#diverging-procedures),
  [Diverging expression typing](../../src/check_expr.odin)

## Verification

Focused `loke-source-review.exe -emit-ll` probes reproduced the three
diagnostics. Clang rejected the generated union store because its operand and
destination types differ. The generated IR also showed
`index()` before `value()`, the setter call before the array bounds check,
the pointer dereference after its enclosing variable's store, and the string
key loads after the earlier assignment or right-operand call. The ordinary
`r = {2};` assignment compiled as a control.

# Source review of copy_sites.odin

Reviewed [copy_sites.odin](../../src/copy_sites.odin) at `ea622efe`.
The file marks semantic copies on the typed AST and reports their cost.
It defers warnings whose operations can change during last-use analysis
or when `foreach` removes an adapter.

## Findings

1. **P2 · Returned map literals undercount key uses, lines 64–94 and
   101–107.** The name walk runs before checking the return expression.
   Its shared child walker treats an unresolved bare key as a field name
   if the literal's type is an alias or comes from context. Given
   `Names :: map[string]string` and `proc() -> Names`, the body
   `key := "alive".copy(); defer { _ = key; } return Names{key = key};`
   reports L0500 because the value occurrence moves `key`. The
   context-typed `return {key = key};` also fails. The spelled-out
   `return map[string]string{key = key};` compiles. Count references
   with the resolved key roles before deciding transfers or emitting
   copyability errors. Keep struct field labels excluded and keep both
   map uses counted. [Returned constructions](../design.md#returned-constructions) ·
   [Child traversal](../../src/ast.odin#L1549) ·
   [Map literal checking](../../src/check_composite.odin#L492)

2. **P2 · Implicit success returns disagree with written variants after
   union widening, lines 47–58 and 101–107.** Let `Narrow` be
   `(data: [dynamic]int | empty:)` and `Wide` add an alternative.
   In a procedure returning `Option(Wide)`, initialize a local
   `source: Narrow = .data([dynamic]int{1});` and defer a read of it.
   `return source;` fails with L0500 while `return .some(source);`
   compiles and clones the source. The implicit path calls the local
   transfer helper directly and bypasses the operand conversion guard.
   The same path checks cloneability at the destination. When the added alternative
   is move-only and `source` is a borrowed `Narrow` parameter,
   `return source;` reports L0502 even though a copy of `Narrow` is
   legal and the written variant compiles. Share the returned-operand
   eligibility rule, and test cloneability at `copied_type(e, payload)`
   if retaining the dedicated L0502 diagnostic.
   [Success returns](../design.md#success-returns) ·
   [Returned constructions](../design.md#returned-constructions) ·
   [Widening by label](../design.md#widening-by-label) ·
   [Implicit wrapping](../../src/optional.odin#L464)

3. **P3 · Missing inline copy warnings, lines 17–28 and 281–294.**
   Both paths gate reporting on managed types. With
   `Big :: struct { bytes: [600]u8 }` and
   `Pair :: struct { big: Big, extra: int }`, `return p.big;` from
   `proc(p: ^Pair) -> Big`, `big, _ := pair;`, and `big, _ = pair;`
   are silent at the default 512-byte threshold. `big = pair.big;`
   produces L0507. Report the byte cost of copied return places and
   retained destructured fields before selecting managed clone operations.
   Pass the actual declaration or assignment site into destructuring and
   name the projected field in any clone advice. Currently
   `xs, _ = pair;` for a dynamic-array field says the binding clones
   `pair` and suggests cloning the whole record.
   [Copy-cost diagnostics](../compiler-guide.md#copy-cost-diagnostics) ·
   [Destructuring](../design.md#destructuring)

4. **P3 · Views and splats report as inline copies, lines 168–178,
   229–231 and 268–270.** At `-copy-cost=1`, both
   `v: Simd(i32, 4) = n;` from an `i32` parameter and
   `view: []int = items;` from a `[dynamic]int` parameter report
   copying 16 bytes. The corresponding assignments do too. Use
   `classify_copy_cost` for bindings and assignments with their current
   held-report arguments. Have that shared predicate exclude views,
   splats, and erasures, while continuing to cost widening at its
   source type. Keep provenance annotations and clone selection
   independent of the warning flag.
   [Copy-cost diagnostics](../compiler-guide.md#copy-cost-diagnostics) ·
   [Conversion metadata](../../src/check_expr.odin#L1899)

## Simplification and boundaries

- Initialize assignment destination liveness with the flow analysis that
  writes it. Lines 243–248 allocate and fill a slice for every plain
  assignment, although consumers already interpret an absent slot as
  live. Allocate on the first flow update that needs a recorded state.
  Preserve joins across deferred executions when updating the slots.
  [Flow update](../../src/lifecycle.odin#L178) ·
  [Emission default](../../src/emit_llvm_stmt.odin#L501) ·
  [Provenance default](../../src/provenance_assign.odin#L269)
- Skip the span map at lines 543–545 when a body held no reports. The
  count map for return names is linear in the written expression, and the
  held list's body marks preserve nested procedure isolation. Every
  production helper has a caller.

## Verification

Focused `loke-source-review.exe <file> -emit-ll` probes at `ea622efe`
reproduced the map and widening differences, including the spelled-out
map and explicit variant controls. Probe diagnostics also confirmed the
missing return and destructuring warnings, the destructuring assignment
wording, and the view and splat warnings at `-copy-cost=1`.

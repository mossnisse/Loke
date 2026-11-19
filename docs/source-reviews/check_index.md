# Source review of check_index.odin

Reviewed [check_index.odin](../../src/check_index.odin) at `ea622efe`. It
selects built-in and user-defined indexing, slicing, and membership operations,
records place capabilities, and identifies projections into packed fields.

## Findings

- **Correctness (P1).** `check_builtin_slice` (line 481) rejects a fixed-array
  projection into a packed field, but implicit array-to-slice materialization
  bypasses the guard. With `@(packed) H :: struct { tag: u8, data: [1]int }`
  and `h := H{1, {42}}`, `h.data[:]` reports `L0614`, while
  `s: []int = h.data` and `first(h.data)` for `first :: proc(s: []int) -> int`
  compile. The latter hands the byte-offset-1 pointer directly to the callee,
  which loads it at `int` alignment. Share the packed-array check with
  `materialize` before it sets `view_from`. Keep views of independently
  allocated storage, such as packed dynamic-array fields, legal.
  [Fixed arrays](../design.md#fixed-arrays), [Packed layout](../design.md#packed),
  [Coercion](../../src/check_expr.odin), [LLVM lowering](../../src/emit_llvm_expr.odin)
- **Correctness (P2).** `check_index` (line 19) uses `underlying_info` for its
  box hop, and `check_in` (line 224) uses `type_is_map`, which also looks
  through distinct types. A `distinct Box([1]int)` inherits `[]`, and a
  `distinct map[int]int` inherits `in`. Both built-ins bypass explicitly
  declared overloads. Match the exact kind at these dispatch points. Share
  the built-in indexing classifier with `index_is_builtin` (line 117), which
  currently applies a different set of implicit dereference steps when
  assignment chooses between an index and a setter.
  [Distinct types](../design.md#distinct-types),
  [Operator lookup](../design.md#operator-lookup-and-overload-resolution),
  [Setter selection](../../src/check_stmt.odin)
- **Correctness (P2).** `agreed_index_param` (line 586) requires an exact
  parameter count before supplying an expected type. With a sole
  `operator([]) proc(t: Table, d: Direction, j: int = 7) -> int`, `t[.North]`
  fails with `L0385` even though the overload accepts the omitted argument.
  Include candidates that can fill every omitted slot with a default, using
  the same test as positional argument binding.
  [Implicit selectors](../design.md#implicit-selector-expression),
  [Overload binding](../../src/overload.odin)

## Verification

Focused `-emit-ll` probes reproduced the three findings. The packed field
reached the callee as the original field pointer. The two distinct-type probes
emitted a built-in array load and `loke_rt_v1_map_find` respectively, with no
call to the declared operator. `t[Direction.North]` and `t[.North, 7]` both
compiled as controls for the default-argument case.

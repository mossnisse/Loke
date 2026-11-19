# `src/check_expr.odin` review

Reviewed [`src/check_expr.odin`](../../src/check_expr.odin) at `ea622efe`.

## Findings

### Unfixed decimals lose precision before folding [P2]

`check_literal` at lines 331–340 parses an unfixed decimal to `f64` and keeps
its spelling. At lines 1404 and 1628, arithmetic and comparison pass the
constant to folding routines that use the rounded value. The mixed
integer/float path at lines 1682–1686 keeps the integer exact while the float
operand has already rounded. [Constant folding](../../src/const_ops.odin),
[Number literals](../design.md#number-literals),
[Comparison operators](../design.md#comparison-operators).

```loke
package main;
static_assert(9007199254740993.0 != 9007199254740992.0);
static_assert(9007199254740993 == 9007199254740993.0);
Difference: f64 : 9007199254740993.0 - 9007199254740992.0;
static_assert(Difference == 1.0);
main :: proc() {}
```

All three assertions report `L0387`. A separate multiplication of `1e-400`
by `1e300` folds to zero. Keep finite unfixed decimals exact in the constant
representation and round at the concrete destination. Share the exact
representation between checker and evaluator folding. Reuse the decimal
scanner and rounding. Cover comparisons, computed constants, and subnormal
and overflow boundaries. [Decimal rounding](../../src/const_float.odin).

## Open question

### Which compile-time `type` expressions can be conversion and selector operands?

`check_cond` at lines 1832–1835 folds a type-valued conditional to the selected
constant without setting `value_category` and `denoted_type`. The selector
dispatch at lines 600–604 and call checking use those annotations.
`(i32 if true else i64)(7)` reports `L0320`, and
`(A if true else B).member` reports `L0363` even when `A` declares `member`.
Binding `Picked :: i32 if true else i64` first allows `Picked` as a type.
[Call dispatch](../../src/check_calls.odin).

The grammar permits the postfix syntax, and the design explicitly gives
type-denoting semantics to calls that compute a type. Clarify whether other
constant `type` expressions have the same semantics in postfix position. If
so, apply `const_names_type` after successful folding. That predicate keeps
runtime `typeid` values distinct. [Expressions](../grammar.md#expressions),
[`type` and `typeid`](../design.md#type-and-typeid).

## Simplification

- Remove the unused `expected` parameter from `check_literal` at line 318.
  The literal stays unfixed until materialization. Remove the ignored boolean
  result of `select_field` at lines 782–820. Its only caller returns after any
  matching field, including an inaccessible field that reports an error.
- Share condition checking at lines 1788–1792 with `check_condition` at line
  1087. Return success
  after materialization and type validation, and retain separate handling for a
  missing `for` condition. `1 if 0 else 2` reports `L0352` once. `if (0) {}`
  reports `L0352` and `L0355` for the same operand. Check both conditional arms
  for recovery before using the condition result.
  [Statement checking](../../src/check_stmt.odin).
- Make `join_operand_types` at lines 1724–1753 the common type-only decision
  for built-in lookup and `unify_operands` at lines 1660–1721. Keep the
  expression-specific named-procedure conversion and the exact constant
  comparison rule at the point that commits conversions. Preserve diagnostics
  for failed representability when joining an unfixed operand to a fixed type.
- `first_method` and `method_candidates` at lines 1014–1036 separately filter
  a temporary member list. `select_call_method` at lines 770–776 looks up the
  same unfixed receiver method before and after materializing the receiver.
  Annotate the method already found once materialization succeeds. Keep
  candidate order and visibility in member lookup. [Member lookup](../../src/impl.odin).

## Responsibilities and verification

Expression dispatch, value categories, and conversions recorded on the typed
AST belong here. Candidate formation and ordering belong with operator and
member lookup. Constant arithmetic belongs in the shared folding layer.
The source and target types recorded for views, splats, erasure, and union
widening carry information used by LLVM emission and provenance analysis.
The ordered temporary candidate lists fit overload lookup, where the selector
checks whether any method exists and the call ranks every visible candidate.
No dispatch branch was shown to be unreachable.

Ran minimal programs with `loke-source-review.exe <file> -emit-ll` from the
repository root using scratch files under `tests/tmp`. The controls passed for
nearby decimals exactly representable in `f64`, an aliased type-valued
conditional, and a distinct boolean used in both statement and expression
conditions.

# Source review of const_ops.odin

Reviewed [const_ops.odin](../../src/const_ops.odin) at `ea622efe`.

## Findings

### P2 · Ordering null C pointers folds incorrectly

At lines 458–459, comparing two `.Nil` constants answers true only for
`==`. A null C pointer has address zero, so two null values also satisfy
`<=` and `>=`. Both assertions below fail with `L0387`. Moving the
comparison into a procedure with a local null C pointer reports `L0341`
because `eval_compare` declines ordering in its pointer branch.

```loke
package main;
P: [^]u8 : nil;
static_assert(P <= P);
static_assert(P >= P);
main :: proc() {}
```

Send the two-null case through the shared order-zero comparison and use it
for null locals too. Keep evaluator-owned addresses subject to the rules
on observing compile-time addresses. Cover all six comparisons in both
constant expressions and evaluated procedures.
[Comparison operators](../design.md#comparison-operators) ·
[Evaluator](../../src/eval.odin#L995)

### P2 · Bit casts omit the allocator error scalar

Lines 613 and 678 omit `.Allocator_Error` from the source and destination
dispatch. The type has word-sized storage and a specified zero
representation. The checker accepts the type for bit casts, and the runtime
forms compile. Both constant folds below report `L0688`.

```loke
package main;
import "core:mem";
import "core:unsafe";
No_Error: mem.Allocator_Error : {};
Bits :: unsafe.transmute(uint, No_Error);
From_Bits :: unsafe.transmute(mem.Allocator_Error, uint(0));
main :: proc() {}
```

Handle the scalar in both dispatches and in the checker's immediate fold.
Use its existing `.Nil` constant for zero and reproduce the exact
word-sized representation for nonzero errors. Test zero and the specified
all-bits-set error through both directions.
[Transmute](../design.md#unsafetransmute) ·
[Allocation failure](../design.md#allocation-failure) ·
[Zero values](../../src/zero.odin#L186) ·
[Checker](../../src/check_builtin.odin#L782)

### P2 · SIMD constant conversion can index a refused allocation

At lines 853–867, `convert_const` indexes the lane slice and calls
`aggregate_const` without checking allocation success. The latter
dereferences the result of `new` at lines 89–93. A conversion of evaluator
locals goes through this path with the bounded evaluator allocator. Odin
returns an empty slice or nil pointer on refusal, so the conversion can
fail in the host before evaluation reports its scratch limit.

Check both allocations and return failure so the evaluator can issue
`L0342`. Convert a splat's scalar once before filling its lanes. An
allocator-refusal test can exercise each allocation without filling the
evaluation budget.
[Compile-time procedure evaluation](../design.md#compile-time-procedure-evaluation) ·
[Conversion caller](../../src/eval.odin#L1843) ·
[Evaluator allocator](../../src/eval_memory.odin#L138)

### P2 · Unfixed arithmetic and comparison use rounded decimal operands

Lines 188–191 and 428–447 use the binary64 approximation of decimal
operands. The literal's exact spelling only takes effect during narrowing
at lines 822–825. As a result, `9007199254740993 == 9007199254740993.0`
folds to false, and `9007199254740993.0 - 9007199254740992.0` folds to zero.
Preserve an exact representation for finite unfixed decimals through
arithmetic and comparison, then round to the concrete destination. Carry
the exact operand through shared unary folding as well.
[Number literals](../design.md#number-literals) ·
[Comparison operators](../design.md#comparison-operators) ·
[Expression checker review](check_expr.md#unfixed-decimals-lose-precision-before-folding-p2)

### P3 · Bit cast buffers bypass the evaluation budget

Lines 575–585 allocate two dense buffers of the full source layout using
the ambient allocator, even when the caller supplies the evaluator's
allocator. The source walk rejects storage such as `Uninit(T)` only after
both allocations. Check temporary buffer allocation errors, use the
evaluator allocator when provided, and free the buffers before returning.
Reject unsupported layouts before materializing their byte images when
the source or destination makes the outcome certain.
[Compile-time procedure evaluation](../design.md#compile-time-procedure-evaluation) ·
[Transmute caller](../../src/eval.odin#L1968)

## Simplification and boundaries

- Lines 296–339 list supported integer operators in both
  `integer_operator` and `fold_integer`. Put the unsupported case in
  the folding switch and remove the classifier. Preserve the shared
  diagnostic for unsupported arithmetic and the separate failure for
  zero divisors or bad shifts.
- Lines 590–602 repeat the array stride and struct member offset logic
  used by the LLVM constant writer. Share the member layout lookup, and
  keep `Uninit(T)`, padding, and relocation policies in their respective
  callers. The existing scalar pattern and little-endian writer are
  already shared. [Layout](../../src/layout.odin) ·
  [LLVM constant writer](../../src/emit_llvm_const.odin#L276)
- Line 526 has one caller. Check the equality result inside the loop at
  lines 513–518 and accumulate the deferred state locally. Keep walking
  after an unknown comparison since a later inequality settles the
  result. Share this rule with evaluated aggregates only if pointer
  identity, user equality and diagnostic handling can stay in the
  evaluator. [Evaluator comparison](../../src/eval.odin#L995)

Shared folding belongs here. Arbitrary-precision integers preserve
unfixed integer results, and fixed-width bit operations fit in a single
`u128`. The aggregate element slice matches positional traversal.
No unused procedure was found.

## Verification

Ran small programs with `loke-source-review.exe <file> -emit-ll`.
Null equality and strict less-than checks passed. Non-strict comparisons
failed, and an evaluated procedure with a local null pointer produced
`L0341`. Runtime allocator error casts emitted LLVM, and the analogous
integer constant cast passed. The allocator error constant casts and the
two unfixed decimal assertions failed as described. A small cast from
`Uninit(u64)` reported `L0688`. Allocation-limit findings were verified
by tracing the compiler and Odin allocator calls.

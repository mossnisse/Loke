# Source review of check_types.odin

Reviewed [check_types.odin](../../src/check_types.odin) at `ea622efe`. It
resolves written types, supplies diagnostics for unresolved syntax, and checks
that value containment has finite size. The shallow lookup for `impl` subjects
serves declaration ordering and must avoid evaluating those subjects before
their dependencies are declared.

## Findings

- **Correctness (P1).** `check_finite_size` (lines 49–60 and 108–115) records
  a cycle permanently even when the diagnostic is provisional. The generic
  record caller runs the walk after its rejection check and ignores the
  result. An interface requirement can therefore encounter a by-value
  recursive record, roll back L0364, and leave the instance cached as
  successful. A later declaration of `^Bad(int)` emits the invalid LLVM
  definition `%struct.Bad.int.75 = type { %struct.Bad.int.75 }`. Include the
  finite-size result in generic record settlement before storing success.
  Preserve the rejection for a later reporting request and clear the
  rejected record's value edges before lowering. For a walk over a partially
  resolved record, retry when its fields are available.
  [Finite-size check](../../src/check_types.odin),
  [Generic record settlement](../../src/generic.odin),
  [Checking and overload resolution](../compiler-architecture.md#checking-and-overload-resolution)
- **Correctness (P2).** `resolve_call_type` (lines 617–651) only sends named
  procedures and generic procedure templates to call checking. A
  type-producing associated procedure, a procedure group, and the
  `type_of` builtin work as constant initializers but all fail with L0306
  when written directly as types. Share callee classification with expression
  checking so these calls can use the existing evaluator. Preserve the early
  exit for runtime procedures during silent type lookup.
  [Type-position calls](../../src/check_types.odin),
  [Expression calls](../../src/check_calls.odin),
  [Type and typeid](../design.md#type-and-typeid),
  [Built-in procedures](../design.md#built-in-procedures)
- **Correctness and simplification (P3).** `constant_count` (lines 483–503)
  delegates a `$N` to a helper that conflates a missing binding with a bound
  negative or noninteger constant. `Bad(-1)` for
  `Bad :: struct($N: int) { a: [$N]int }` reports that `$N` is unbound.
  `Simd(f32, $N)` has the same problem. Resolve the binding to its constant
  value and run both spellings through the shared integer and range checks.
  The unresolved-name path can then handle the missing-binding case.
  [Count checking](../../src/check_types.odin),
  [Generic binding lookup](../../src/generic.odin),
  [Fixed arrays](../design.md#fixed-arrays),
  [SIMD vectors](../design.md#simd-vectors)

## Verification

The compiler built at `ea622efe` accepted this program with `-emit-ll` and
emitted the self-containing LLVM record. Moving the pointer declaration
before the assertion reported L0364.

```loke
package main;

Bad :: struct($T: type) { a: Bad(T) }
Can_Use :: interface($T: type) {
    size_of(Bad(T)) > 0;
}

main :: proc() {
    static_assert(!Can_Use(int));
    x: ^Bad(int);
}
```

A type-producing `Record.Selected(true)`, its generic counterpart
`Record.G_Selected(int)`, and `type_of(3)` each emitted LLVM IR when assigned
to a constant and used through that name. Each failed when written
directly in the variable annotation. A separate `Choose(1)` probe using a
procedure group gave the same result. A direct runtime procedure call still
reported that it returned `int`. Focused array and SIMD probes produced
L0437 for `$N = -1`. Spelling the array length as `[N]int` produced L0384
with the expected non-negative count diagnostic.

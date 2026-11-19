# Source review of conversions.odin

Reviewed [conversions.odin](../../src/conversions.odin) at `ea622efe`.

## Findings

### P2 · A distinct wrapper cannot convert to or from the distinct type it wraps

The two-distinct rejection at lines 109–117 runs before the representation
check. The call checker repeats the rejection even for constant operands.
`Outer :: distinct Inner` is legal, and the distinct-type conversion rule
allows written conversions between a wrapper and its underlying type. Both
`Outer(inner)` and `Inner(outer)` report `L0373` in separate probes with the
following declarations.

```loke
package main;
Inner :: distinct int;
Outer :: distinct Inner;
main :: proc() {
    inner: Inner = 2;
    _ = Outer(inner);
}
```

Check the direct wrapped type on both sides before rejecting other distinct
pairs. Share the rule with the constant path in the call checker. Cover both
directions and two sibling wrappers with a common representation.
[Distinct types](../design.md#distinct-types) ·
[Call checker](../../src/check_calls.odin#L1051)

### P2 · Float-to-rune conversion works at runtime but fails on constants

The numeric test at lines 140–148 admits `rune(f)` for `f: f64`. LLVM gives the
conversion the checked signed 32-bit range and truncates toward zero.
`static_assert(rune(f64(65)) == 'A');` reports `L0373` because the constant
converter's `.Rune` branch accepts only integer and rune values. This makes
constantness change which input types a written conversion accepts.

Use the same signed 32-bit truncation check in the constant path and preserve
the result's rune kind. Cover an in-range fractional input and the signed range
boundaries in both phases. Clarify the float-to-rune rule since the float
paragraph names integer destinations.
[Type conversion](../design.md#type-conversion) ·
[Constant converter](../../src/const_ops.odin#L805) ·
[LLVM range check](../../src/emit_llvm_convert.odin#L140)

### P3 · Scalar splats implicitly create distinct vector values

Lines 38–40 inspect the underlying vector shape before checking nominal type
identity. As a result, a typed lane value implicitly becomes a distinct vector
even though the splat rule names the plain `Simd(T, N)` destination and the
distinct rule requires a written conversion for an already typed value.

```loke
package main;
Vector :: distinct Simd(i32, 4);
main :: proc() {
    lane: i32 = 2;
    value: Vector = lane;
    assert(Simd(i32, 4)(value)[0] == 2);
}
```

Limit the implicit splat to plain vector destinations and the unfixed values
eligible for distinct conversion. Keep the same check in assignment and
overload ranking. Test a typed scalar alongside an unfixed literal and an
ordinary vector destination.
[Implicit type conversions](../design.md#implicit-type-conversions) ·
[SIMD construction and conversion](../design.md#construction-and-conversion) ·
[Distinct types](../design.md#distinct-types)

## Simplification and boundaries

- Lines 49–70 intentionally defer constant representability, but their broad
  kind allowances cause `unfixed_kind_converts` to recheck the actual
  compatibility matrix. Put kind compatibility in `assignable` and keep
  value-dependent range and rounding in materialization. Preserve overload
  rejection and the diagnostics for numeric overflow during that change.
  [Call checker](../../src/check_calls.odin#L1024) ·
  [Overload ranking](../../src/overload.odin#L299)
- Lines 177–189 repeat the raw/C-pointer source test. After the existing identity
  check, one source test can handle unchecked addresses and a separate checked
  pointer case can compare pointees. Spell out the checked-pointer-to-C-pointer
  rule first. The current table accepts `([^]u64)(p)` for `p: ^u8` without an
  unsafe import, while the spec uses matching element types in describing that
  direction. [C pointers](../design.md#c-pointers) ·
  [The unsafe package](../design.md#the-unsafe-package)
- Keep the shared type-only predicate and the expression-aware procedure
  exception. Callers use both independently, and value folding is already
  separate. Interned type identities and kind dispatch are sufficient. SIMD
  recursion descends once into its scalar lane type. All seven procedures have
  callers.

## Verification

Used the fresh `loke-source-review.exe` with `-emit-ll` for assignment, cast and
constant probes. Inspected the signed range comparisons and `fptosi` in the
runtime float-to-rune IR. The plain vector splat compiled and sibling-wrapper
casts reported `L0373`. Enum literals reported `L0310` in both constant and
runtime declarations. Checked relative source and specification links by hand.
`check-citations.ps1` and `bundle.ps1` passed.

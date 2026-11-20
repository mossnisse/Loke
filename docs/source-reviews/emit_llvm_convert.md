# `src/emit_llvm_convert.odin` review

Reviewed [`src/emit_llvm_convert.odin`](../../src/emit_llvm_convert.odin) at
`e1aab600`. The checker decides whether a conversion is legal and records
operand ownership. The emitter picks an LLVM instruction and emits the
runtime checks, or dispatches a union conversion to tag and payload lowering.
The direct signedness and width tests cover all integer sizes with at most two
comparisons. The arbitrary-precision bounds handle 128-bit integers, and
reusing the scalar comparison rules for SIMD lanes gives one vector reduction
before the panic. All eight procedures have callers. [Conversion checker](../../src/check_calls.odin#L1047) ·
[Type conversion](../design.md#type-conversion)

## Findings

### Sequential union `as` calls exhaust the stack for large payloads [P2]

`emit_union_as` spills its initial `.none` with a function-entry `alloca`.
The slot holds the whole option, so repeating the call allocates one large
slot per source site even when each result is discarded and the union has a
different active variant. In the probe below, repeating the discard statement
24 times produced 27 `Option(Payload)` allocas in `probe` and ran out of
stack with Windows status `0xC00000FD`. The two-statement control produced
five allocas and exited normally. [Union `as` lowering](../../src/emit_llvm_convert.odin#L182) ·
[Spill and temporary slots](../../src/emit_llvm_place.odin#L31) ·
[Inspecting a union](../design.md#inspecting-a-union)

```loke
package main;
Payload :: [65536]u8;
Choice :: union { blob: Payload, absent }
probe :: proc(value: ^Choice) {
    _ = value^.as(.blob); // Repeat this statement 24 times total.
}
main :: proc() {
    value: Choice = .absent;
    probe(&value);
}
```

Build the result directly in a `temporary_slot` and return it with
`load_temporary`. The union emitter already writes variants into zeroed
result storage. Put the `as` lowering with that helper so it can initialize
`.none` and write `.some` into the same slot, keeping the payload read and any
clone inside the match block. For a large subject, the evaluated value already
names its storage, so payload extraction can use that address and avoid a
second copy of the entire union. Cover matching and absent variants and nested
uses with multiple live results. [Union variant writer](../../src/emit_llvm_union.odin#L170) ·
[Large value addresses](../../src/emit_llvm_place.odin#L73)

## Simplification

- L10–16 `shrink:` `emit_call` already matches `Call_Conversion`. Pass `operation.clones` to `emit_conversion` and use `emit_copied_expr` for its operand, sharing the same copy-before-widening rule the checker uses and removing the type assertion. [Call dispatch](../../src/emit_llvm_calls.odin#L58) · [Shared copy lowering](../../src/emit_llvm_expr.odin#L26) · [Copy classification](../../src/copy_sites.odin#L265)
- L124–135 `shrink:` Replace the two empty-case switches with one condition testing each underlying kind against its two allowed kinds. Keep the shared null guard for written casts and `unsafe.cstring_view`. [Null guard](../../src/emit_llvm_convert.odin#L124) · [C-string view lowering](../../src/emit_llvm_expr.odin#L978)
- L159–164 `shrink:` Use `emit_value` for both float comparisons and their `or`, as the integer guard does, removing the separate `temp` declarations and SSA formatting. [Float guard](../../src/emit_llvm_convert.odin#L159) · [SSA emission](../../src/emit_llvm.odin#L691)

`net: -11 lines possible.`

## Verification

Built and ran both `as` probes at the default optimization level with
`lokec 0.10.0 (v0.10.0-15-ge1aab600)` and counted the allocas in `-keep-temps`
IR. A separate probe passed on runtime `u8` to `i8`, `f64` to `f16` just above
a half-precision rounding tie, `f16` to `i128`, the largest finite `f32` to
`u128`, and `Simd(f16, 4)` to `Simd(i64, 4)`. The widened scalar and lane
conversions emitted comparisons that reject the infinite endpoints.
The existing union `as` and runtime float cast fixtures matched their expected
output and exit codes. [Union `as` fixture](../../tests/run/union_as.loke) ·
[Runtime float cast fixture](../../tests/trap/runtime_float_cast.loke)

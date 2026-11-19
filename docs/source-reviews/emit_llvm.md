# `src/emit_llvm.odin` review

Reviewed [`src/emit_llvm.odin`](../../src/emit_llvm.odin) at `ea622efe`.
The emitter owns LLVM names, per-function lowering state, and module text.

## Findings

### An incompatible foreign declaration can override an intrinsic signature [P2]

`declare_intrinsic` at lines 547–551 deduplicates by name alone. Foreign
declarations are emitted before bodies, so an incompatible foreign declaration
can suppress the intrinsic declaration while the built-in still emits its own
signature. For example:

```loke
package main;
import "core:math";

foreign llvm {
    @(link_name="llvm.ctpop.i64")
    population :: proc "c" (x: i32) -> i32 ---;
}

ones :: proc(n: i64) -> int { return math.count_ones(n); }
main :: proc() { _ = ones(3); }
```

`-emit-ll` succeeds with `declare i32 @llvm.ctpop.i64(i32)` and a call returning
`i64` with an `i64` argument. Clang rejects the module with a call parameter
type mismatch. Record each declaration's lowered kind and signature with its
name, and diagnose a conflict at the foreign declaration. Preserve compatible
aliases, including the existing `foreign_intrinsic_binding` regression. Use the
same registration path for preamble and on-demand intrinsics so both honor the
same compatibility rule.
[Intrinsic declaration](../../src/emit_llvm.odin#L547) ·
[Foreign declaration pass](../../src/emit_llvm_abi.odin#L27) ·
[Math lowering](../../src/emit_llvm_math.odin#L74) ·
[Compatible binding regression](../../tests/run/foreign_intrinsic_binding.loke)

## Simplification and compiler boundaries

- `loke_param_list` at lines 394–404 renders parameters and also writes
  `e.abi_sret`. The dispatcher calls it just to render a forwarding signature
  and never uses that state. Set the result address during procedure setup and
  leave the parameter renderer independent of the active function. Keep
  `returns_sret` responsible for the classification.
  [Loke parameter renderer](../../src/emit_llvm.odin#L394) ·
  [Dispatcher](../../src/emit_llvm_dispatch.odin#L87)
- `name_package_symbols` and `emit_package_items` independently walk active
  declarations, impl members, hoisted procedures, and instances. Filtering
  differs across those walks. For example, a file-scope test can claim a name
  despite being omitted, and an impl template can claim one even though it
  cannot produce a body. Share the procedure eligibility decision if unifying
  them, while preserving the up-front naming of every reachable procedure and
  the explicit handling of references omitted with tests.
  [Emission walk](../../src/emit_llvm.odin#L317) ·
  [Naming walk](../../src/emit_llvm_names.odin#L32)
- Module and procedure buffers support forward naming, entry-block allocation
  splicing, and thunks that cannot appear inside the function that asks for
  them. Keep the declaration and thunk sets keyed by LLVM name and retain
  ordered output buffers for reproducible text. The allocation splice already
  has focused coverage.
  [Function buffers](../../src/emit_llvm.odin#L268) ·
  [Allocation splice test](../../src/emit_llvm_test.odin#L741) ·
  [LLVM and toolchain](../compiler-architecture.md#llvm-and-toolchain)

## Verification

Reproduced the intrinsic mismatch with `loke-source-review.exe` at
`v0.10.0-4-gea622efe` and confirmed that clang rejects the emitted text. Clang
accepted the emitted IR for `foreign_intrinsic_binding.loke`,
`m7_conventions.loke`, `cold.loke`, and `dispatch_implicit_calls.loke`. Traced
procedure and thunk setup, declaration registration, and the two package walks
in source. Checked the report's relative links and anchors. `check-citations.ps1`
and `bundle.ps1` passed.

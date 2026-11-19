# `src/capture.odin`

Reviewed at `ea622efe`. This file lowers each capture clause to a body-local record and `call` method. Reusing checked struct fields and method bodies gives the existing type checker, ownership analysis, evaluator, and emitter a common representation. Clause order belongs in slices. The identifier map used while cloning the method and the symbol map used during checking serve different lookup scopes.

## Findings

- **P2 · Correctness.** `rewrite_capture` and `capture_call_method` (lines 236–241 and 269–275) replace a matching identifier anywhere the cloner visits an expression. This includes the field token in `offset_of(T, field)` and the configuration key in `build_config(KEY, default)`. The respective built-ins then reject the generated selector because they require the identifier as written. Preserve the written identifier when lowering a bare capture argument, then use it for name-only operands once call checking has resolved the built-in. Ordinary value arguments should still use the lowered capture place. [Capture lowering](../../src/capture.odin), [call cloning](../../src/ast_clone.odin), [built-in checks](../../src/check_builtin.odin), [built-in procedures](../design.md#built-in-procedures), [build configuration built-in](../design.md#build_configidentifier-default)
- **P3 · Simplify.** `capture_place_of` (lines 286–291) couples lookup of a capture in the current method to synthesizing a read of that capture. `check_spawn` calls it as a predicate and discards the generated selector and receiver, while `check_ident` already repeats the symbol and method test. Share the method-aware lookup by `Symbol_Id` and have the map-key checker call `capture_field_place` when it actually needs a lowered value. [Capture lookup](../../src/capture.odin), [identifier checking](../../src/check_expr.odin), [map literal checking](../../src/check_composite.odin), [spawn checking](../../src/parallel.odin)
- **P3 · Allocation lifetime.** `check_capture_values` and `capture_record_syntax` (lines 70 and 112) allocate the intermediate type and field-descriptor slices in the semantic arena. Record syntax keeps each resolved field type through its generated alias, and placeholder and rewrite maps copy each field descriptor by value. Allocate the two intermediate slices from the temporary allocator, keeping the synthesized syntax and field-name strings in semantic storage. [Capture lowering](../../src/capture.odin), [synthetic record fields](../../src/synth.odin)

## Verification

The `ea622efe` compiler rejected this program with L0386 under `-emit-ll`. Renaming the capture and its use outside the built-in to `increment` produced LLVM IR.

```loke
package main;

Pair :: struct { first: i32, second: i64 }

main :: proc() {
    f := proc() -> int capture(second = 3) {
        return second + offset_of(Pair, second);
    };
    _ = f();
}
```

A separate probe with `capture(SIZE = 3)` and `return SIZE + build_config(SIZE, 8);` reported L0388. The equivalent capture rename produced LLVM IR. The allocation and shared-lookup findings come from tracing callers. [Capture test coverage](../../tests/run/capture_literals.loke), [compile-time capture test coverage](../../tests/run/capture_literals_compile_time.loke)

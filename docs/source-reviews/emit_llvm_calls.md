# `src/emit_llvm_calls.odin` review

Reviewed [`src/emit_llvm_calls.odin`](../../src/emit_llvm_calls.odin) at
`ea622efe`. The file lowers resolved calls, variadic packs, and allocation
built-ins and supplies the internal calling convention's LLVM spellings.

## Findings

### Sequential variadic calls reserve separate large packing buffers [P2]

`emit_pack_operands` creates a function-entry `alloca` for every call site
with explicit variadic elements. Twenty-four separate `accept(r);` statements
where `accept :: proc(rest: ..R)` and `R :: struct { pad: [65536]u8 }` emit
24 distinct 64 KiB staging buffers. The program exits with Windows status
`0xC00000FD`, even though each call finishes before the next. Use the same
full-expression slot reuse as large ordinary values for large typed staging
arrays, or allocate them within the existing saved-stack scope. Add a
regression with sequential calls and verify that nested calls whose packs
are live together keep independent storage.
[Variadic staging](../../src/emit_llvm_calls.odin#L440) ·
[Large temporary slots](../../src/emit_llvm_place.odin#L31) ·
[Runtime-size stack storage](../../src/emit_llvm_cleanup.odin#L379) ·
[Variadic parameters](../design.md#variadic-parameters)

## Verification

Built and ran the sequential-pack probe with `loke-source-review.exe`
(`v0.10.0-4-gea622efe`) at default optimization and counted the packing
allocas in the retained LLVM IR.

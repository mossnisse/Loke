# `src/emit_llvm_abi.odin` review

Reviewed [`src/emit_llvm_abi.odin`](../../src/emit_llvm_abi.odin) at
`ea622efe`. The file writes LLVM type definitions and lowers Win64 foreign
declarations, calls, and entry wrappers.

## Findings

### Indirect by-value aggregate arguments use under-aligned copies [P2]

`foreign_value_operand` at lines 526–533 routes indirect aggregates through
`foreign_spill_operand` at lines 517–520. The latter uses a typed `alloca`
without an explicit alignment. Win64 requires 16-byte alignment for the
caller-owned copy of an aggregate passed indirectly. A Loke call passing
`R :: struct { bytes: [17]u8 }` to a native C helper that returns
`(int)((unsigned long long)&r & 15)` printed `8`. The equivalent MSVC C
caller and callee printed `0`. Make the argument spill request at least
16-byte alignment in the `.Indirect` case, which also covers C varargs.
Keep the storage alignment of explicit pointer parameters governed by their
pointee. Add a native interop regression with a low-alignment aggregate and
verify the call's spill alignment in the generated IR.
[By-value lowering](../../src/emit_llvm_abi.odin#L517) ·
[Spill](../../src/emit_llvm_place.odin#L74) ·
[Foreign-ABI-safe types](../design.md#foreign-abi-safe-types) ·
[Win64 parameter passing](https://learn.microsoft.com/en-us/cpp/build/x64-calling-convention?view=msvc-170#parameter-passing)

### Sequential foreign calls reserve a separate stack slot per large result [P2]

`emit_foreign_call` at lines 644–649 uses a fresh function-entry alloca for
each indirect result. Calling `make_r :: proc "c" () -> R { return R{}; }`
24 times in separate `_ = make_r();` statements with a 64 KiB `R` reserved
24 result slots and exited with Windows status `0xC00000FD` (stack overflow).
Changing the procedure to the Loke convention reused one slot and ran to
completion. Allocate the foreign result with the same `temporary_slot`
helper used by the ordinary call path. Its full-expression lifetime keeps
results from nested calls distinct while a later statement can reuse
storage. Add a regression checking both separate statements and overlapping
result lifetimes. Inspect the argument-spill path separately because its
caller-owned copies also need the Win64 alignment above.
[Foreign call lowering](../../src/emit_llvm_abi.odin#L640) ·
[Ordinary call lowering](../../src/emit_llvm_calls.odin#L1010) ·
[Temporary slots](../../src/emit_llvm_place.odin#L31)

## Simplification and compiler boundaries

- Declaration emission allocates the same link spelling in the naming
  pass, the deduplication loop, and `emit_foreign_declare` at lines 19–55.
  Use the stored name from the naming pass as the key and pass it to the
  declaration writer. Keep the separate deduplication of foreign aliases,
  which can legitimately share a link name. The existing hash lookup and
  deterministic declaration order are appropriate.
  [Naming pass](../../src/emit_llvm_names.odin#L66) ·
  [Declaration writer](../../src/emit_llvm_abi.odin#L27)
- The declaration, definition, and call paths repeat the same
  `sret(<type>) align <n>` text at lines 64, 296, and 594. Reuse the
  attributed pointer spelling and append a value or parameter name where
  required. Keep the bare `ptr` in the variadic function type, whose
  attributes belong to the actual call operands. Remove the unreachable
  `.Array` branch from C vararg promotion at lines 565–566. Its only caller
  receives checked C variadic arguments, and the checker rejects top-level
  fixed arrays before lowering.
  [Foreign result and parameters](../../src/emit_llvm_abi.odin#L288) ·
  [Variadic function type](../../src/emit_llvm_abi.odin#L571) ·
  [Variadic argument checking](../../src/check_calls.odin#L808) ·
  [ABI validation](../../src/abi.odin#L141)
- Keep target layout rules and ABI pass classification in the shared layout
  and ABI helpers. This file owns the textual representations and explicit
  spills. The `noinline` wrapper boundary keeps computations in the guarded
  body. Keep both capability variants of a carrier sharing one named LLVM
  type so weakening remains a conversion-free operation.
  [Entry guard](../../src/emit_llvm_abi.odin#L322) ·
  [Carrier names](../../src/emit_llvm_abi.odin#L162)

## Verification

Built and ran the native probe with `loke-source-review.exe`
(`v0.10.0-4-gea622efe`) and retained the emitted IR. MSVC 19.44 supplied the
aligned C caller control. Clang 22.1.8's C-to-C control also passed an
under-aligned copy on this machine. Built and ran the large-result probe
and its Loke-convention control with default optimization. Counted typed
result allocas in both modules. Checked relative links and anchors by hand.
`check-citations.ps1` and `bundle.ps1` passed.

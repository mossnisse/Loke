# `src/emit_llvm_atomics.odin` review

Reviewed [`src/emit_llvm_atomics.odin`](../../src/emit_llvm_atomics.odin) at
`ea622efe`. The emitter lowers checked atomic operations to LLVM or to the
versioned C ABI for 128-bit values.

## Findings

### The known packed-slice gap reaches native atomics [P2]

`emit_native_atomic` derives the alignment from the bit width at line 105.
This is correct for the checked address contract. Direct methods on a packed
atomic field report `L0614`, but the existing implicit slice conversion gap
can turn under-aligned packed storage into an ordinary slice. This program
compiles with `-emit-ll`:

```loke
package main;
import "core:sync";
@(packed, align=8) Holder :: struct { tag: u8, data: [1]sync.Atomic(u64) }
main :: proc() {
    h: Holder = {};
    s: []sync.Atomic(u64) = h.data;
    s[0].store(2);
    assert(s[0].load() == 2);
}
```

The IR puts the slice backing array at byte 1 of an 8-byte-aligned holder
and lowers the methods with `store atomic i64 ... align 8` and
`load atomic i64 ... align 8`. LLVM permits the optimizer to assume that
alignment. Fix the implicit conversion in the checker and extend its
regression test to an `Atomic(u64)` array. The atomic methods receive a typed
reference after the conversion, so the emitter has lost the packed-place
information by this point. [Native lowering](../../src/emit_llvm_atomics.odin#L105) ·
[Borrow check](../../src/check_calls.odin#L576) ·
[Checker review](check_index.md#findings) ·
[LLVM `store` instruction](https://llvm.org/docs/LangRef.html#store-instruction)

## Simplification and compiler boundaries

- Native storage selection at lines 99–103 repeats ordinary LLVM type
  spelling for integers, enums, runes, and pointers. Use `llvm_type` for
  these cases, with explicit storage overrides for `bool` and pointer
  `Option`. The option override should read the union's storage-head type
  from its layout rather than spelling the integer independently. Preserve
  the boolean byte conversion because LLVM atomic operands require a width of
  at least eight bits. [LLVM type spelling](../../src/emit_llvm_abi.odin#L184) ·
  [Union storage](../../src/emit_llvm_union.odin#L14) ·
  [LLVM `load` instruction](https://llvm.org/docs/LangRef.html#load-instruction)
- The native and fallback paths share the compare-exchange outcome at lines
  131 and 180. `emit_atomic_exchange_result` can take the already-decoded
  observed value. Decode the native value at its call site as the other
  native operations do, and pass the fallback's loaded value directly. The
  checked fallback type is a 128-bit integer or enum, so applying
  `atomic_from_storage` to it has no effect. Keep the native instructions and
  pointer-based calls explicit because their operands and result conventions
  differ. [Checked atomic widths](../../src/atomics.odin#L18) ·
  [C ABI](../../runtime/loke_rt.h#L423)
- The kind and order reaching the emitter have already been validated. An
  unsupported `atomic_rmw_opcode` argument yields an empty opcode at line 28,
  and `llvm_ordering` silently returns `seq_cst` at line 15 for an invalid
  enum value. Make the internal invariant explicit with an unreachable path
  or emit a backend diagnostic when it is broken. Keep validation and
  borrow effects in the checker. The emitter only needs the checked element
  type and orderings. [Atomic checker](../../src/atomics.odin#L68) ·
  [Backend diagnostics](../../src/emission_contract.odin)
- Native operations and the fallback use fixed dispatch with no per-call
  data structure. The 128-bit helpers take pointers to scratch slots and
  `alloca` adds those slots to the function prologue, so repeated operations
  in a loop reuse the same slots. Keep all 128-bit accesses behind the same
  runtime ABI so the runtime can serialize them consistently. [LLVM stack
  slots](../../src/emit_llvm.odin#L587) · [Runtime serialization](../../runtime/atomic.c#L10)

## Verification

Used `loke-source-review.exe` reporting `v0.10.0-4-gea622efe`. Every expected
[`m8_atomics` IR pattern](../../tests/ll/m8_atomics.expected) matched.
The [`lib_sync` executable](../../tests/run/lib_sync.loke) linked and matched
expected stdout, including native and 128-bit operations and a native
compare-exchange with relaxed success and sequentially consistent failure.
An `-opt=speed` probe also passed load, store, exchange, and both
compare-exchange outcomes for `Atomic(Option(^int))`. A direct packed-field
control reported `L0614`. Verified the packed-slice case through IR only.
`check-citations.ps1` and `bundle.ps1` passed, and the report's relative
links and anchors were checked.

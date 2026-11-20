# `src/emit_llvm_equality.odin` review

Reviewed [LLVM equality and hashing](../../src/emit_llvm_equality.odin) at
`e1aab600`. The file lowers scalar comparisons and walks aggregate values for
structural comparison and generated hashing. The shared scalar predicate table
also serves SIMD comparisons. The checker selects key policy and the runtime
probes the table. This file emits calls to the selected operations and folds
fields in layout order. The shared array cutoff and existing counted-loop and union
switch helpers bound emitted code size without introducing another walker.
[SIMD comparisons](../../src/emit_llvm_simd.odin#L78) ·
[Key policy](../../src/hash.odin#L171) · [Maps](../design.md#maps)

## Findings

### Structural equality disagrees with compile-time evaluation about later hooks [P2]

The unrolled and looped array paths and the record path call every part's `==`
before combining its result. The compile-time evaluator returns on the first
unequal part. This is an observable difference when a later inherent comparison
has effects. For example, comparing records whose first `int` fields differ
can skip a later panicking `==` at compile time and reach it at runtime. That
case follows from the control flow and has yet to be run. Specify when part
comparisons run and make the evaluator, LLVM lowering, and effect analysis
follow the same rule. Preserve payload-only union comparison and zero-length
arrays, which call no part comparison. [Unrolled array](../../src/emit_llvm_equality.odin#L148) ·
[Looped array](../../src/emit_llvm_equality.odin#L166) ·
[Record fields](../../src/emit_llvm_equality.odin#L221) ·
[Evaluator exit](../../src/eval.odin#L1054) ·
[Comparison operators](../design.md#comparison-operators) ·
[Zero-length fixture](../../tests/run/zero_length_equality_effects.loke)

### Wide integer hashing discards the high 64 bits [P2]

The scalar hash reduces wider integers to `i64` by truncation. The evaluator
uses the same low word. For a sequence of unsigned keys `u128(i) << 64`, every
key produces the same hash for a fixed seed, even though equality uses all
128 bits. The table mixes that already identical result, then probes linearly,
so inserting `n` distinct keys with the same low word takes quadratic probing
work. This is a static consequence of the hash and probe loops. Measure it on
wide keys before selecting a mix. Fold both halves in both phases and retain
the existing single-word path for scalars up to 64 bits. The public hash
algorithm is unspecified, and fixed-seed results must agree across phases.
[Scalar hash](../../src/emit_llvm_equality.odin#L343) ·
[Truncation](../../src/emit_llvm.odin#L736) ·
[Compile-time hash](../../src/hash.odin#L347) ·
[Table home](../../runtime/container.c#L561) ·
[Table probe](../../runtime/container.c#L833) ·
[Hash contract](../standard-library.md#mixing-and-derived-seeds)

## Simplification and boundaries

- `L116–121 delete:` Call `value_address` for each operand at the three sites and remove the forwarding `spill_equal_operands` wrapper. [Address helper](../../src/emit_llvm_place.odin#L64)
- `L243–247 yagni:` Inline `emit_byte_member_struct_equal` into its sole branch in `emit_equal`. Retain the common field loop and its two readers so the packed, over-aligned layout still uses alignment-aware field loads. [Record dispatch](../../src/emit_llvm_equality.odin#L107) · [Packed fixture](../../tests/run/m7_packed.loke)
- `L125–132, L254–261, L334–338 shrink:` Use `emit_value` for the direct equality call, direct hash call, and scalar hash arithmetic. It already assigns a temporary and writes the instruction. [Instruction helper](../../src/emit_llvm.odin#L691)

`net: -14 lines possible.`

The union equality and hash paths already share tag decoding and payload-case
dispatch. Equality first checks both tags and loads two payloads. Hashing mixes
one tag into a seed and loads one payload. Keeping those loops separate leaves
their control flow and inputs apparent. Likewise, the array paths share their
loop policy and loop primitives while keeping their different accumulators.
[Union lowering helpers](../../src/emit_llvm_union.odin#L237) ·
[Counted-loop helpers](../../src/emit_llvm_iteration.odin#L473)

## Verification

Static review of the emitter, its callers, the evaluator, and the runtime map
probe. Inspected the [structural hashing fixture](../../tests/run/structural_hash.loke),
which covers generated and inherent pairs, variant tags, and run-time versus
compile-time hashes. Also inspected the packed-field and zero-length fixtures.

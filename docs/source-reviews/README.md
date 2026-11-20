# Compiler source reviews

The review series covers production Odin sources under `src/`, including the
nested subprocess package and the compiler's test runner. Files ending in
`_test.odin` are outside its scope. See the
[earlier audit](../compiler-source-audit-2026-11-18.md#file-by-file-reviews)
for coverage before `src/build_config.odin`.

Each file has its own reviewer. Reviews start in path order and reports are
written as they finish. They cover correctness, necessity, simplification,
dead code, data structures, algorithms, duplicate logic, and responsibilities
across compiler phases. Each report describes any verification it used.

## Review reports

### Continuation at `ea622efe`

- [`src/build_config.odin`](build_config.md)
- [`src/callback_summary.odin`](callback_summary.md)
- [`src/capture.odin`](capture.md)
- [`src/carrier_shape.odin`](carrier_shape.md)
- [`src/cfg.odin`](cfg.md)
- [`src/cfg_provenance.odin`](cfg_provenance.md)
- [`src/check.odin`](check.md)
- [`src/check_builtin.odin`](check_builtin.md)
- [`src/check_calls.odin`](check_calls.md)
- [`src/check_composite.odin`](check_composite.md)
- [`src/check_expr.odin`](check_expr.md)
- [`src/check_index.odin`](check_index.md)
- [`src/check_stmt.odin`](check_stmt.md)
- [`src/check_types.odin`](check_types.md)
- [`src/compiler.odin`](compiler.md)
- [`src/const_float.odin`](const_float.md)
- [`src/const_ops.odin`](const_ops.md)
- [`src/container.odin`](container.md)
- [`src/conversions.odin`](conversions.md)
- [`src/copy_sites.odin`](copy_sites.md)
- [`src/customization.odin`](customization.md)
- [`src/doc.odin`](doc.md)
- [`src/doc_comments.odin`](doc_comments.md)
- [`src/emission_contract.odin`](emission_contract.md)
- [`src/emit_llvm.odin`](emit_llvm.md)
- [`src/emit_llvm_abi.odin`](emit_llvm_abi.md)
- [`src/emit_llvm_atomics.odin`](emit_llvm_atomics.md)
- [`src/emit_llvm_box.odin`](emit_llvm_box.md)
- [`src/emit_llvm_calls.odin`](emit_llvm_calls.md)

### Continuation at `e1aab600`

- [`src/emit_llvm_coff.odin`](emit_llvm_coff.md)
- [`src/emit_llvm_const.odin`](emit_llvm_const.md)
- [`src/emit_llvm_containers.odin`](emit_llvm_containers.md)
- [`src/emit_llvm_convert.odin`](emit_llvm_convert.md)
- [`src/emit_llvm_debug.odin`](emit_llvm_debug.md)
- [`src/emit_llvm_dispatch.odin`](emit_llvm_dispatch.md)
- [`src/emit_llvm_entry.odin`](emit_llvm_entry.md)
- [`src/emit_llvm_equality.odin`](emit_llvm_equality.md)

This batch ends at `src/emit_llvm_equality.odin`. The next file in path order
is `src/emit_llvm_erased.odin`.

## Resolution

The `ea622efe` continuation fixed the reproduced correctness findings with
regression tests, with four still in [Known gaps](../known-gaps.md#gaps):
exact unfixed decimals, `caller_location()` in a default the compiler cannot
fold, setter destinations in a multiple assignment, and compound assignment
through a view. The changelog lists each fix. The simplifications were applied
unless they asked for a measurement first or the fixing commit says why it
declined them. Questions and hypotheses are in
[Open questions](../open-questions.md#compiler-source-audit-continuation).

The `e1aab600` continuation fixed every correctness finding with a
regression test; the changelog lists each fix. Structural comparison now
stops at the first unequal part, which
[Comparison operators](../design.md#comparison-operators) specifies. The
simplifications were applied except where the fixing commit says why it
declined them. What remains, slice literal identity, partly zero union
padding, the measure-first `find_or_insert` probe, and debug records for
file-scope variables, is in
[LLVM source review follow-ups](../open-questions.md#llvm-source-review-follow-ups).

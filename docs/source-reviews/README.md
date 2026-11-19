# Compiler source reviews

This review continues from `src/build_config.odin` through `src/zero.odin` at
`ea622efe`. The range includes 171 production files, including the nested
subprocess package and the compiler's test runner. It excludes files ending
in `_test.odin`. See the [earlier audit](../compiler-source-audit-2026-11-18.md#file-by-file-reviews)
for prior coverage before this starting point.

Each file has its own reviewer. Reviews start in path order and reports are
written as they finish. They cover correctness, necessity, simplification,
dead code, data structures, algorithms, duplicate logic, and responsibilities
across compiler phases. Each report describes any verification it used.

## Review reports

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

The reviews stopped at `src/emit_llvm_calls.odin`; the files after it in path
order have not been reviewed in this continuation.

## Resolution

Every correctness finding above reproduced and was fixed, with a regression
test, except those listed in [Known gaps](../known-gaps.md#gaps): exact unfixed
decimals, `caller_location()` in a default the compiler cannot fold, setter
destinations in a multiple assignment, and compound assignment through a view.
The CHANGELOG's Unreleased section lists each fix. The simplifications were
applied unless they asked for a measurement first or the fixing commit says
why it declined them. Questions for the specification, and the hypotheses not
yet measured or reproduced, are in
[Open questions](../open-questions.md#compiler-source-audit-continuation).

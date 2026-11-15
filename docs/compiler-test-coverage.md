# Compiler test coverage

Behavioral coverage review, 2026-11-15. This maps the compiler's higher-risk
semantics to tests and their oracles; it is not a measured line or branch
coverage percentage.

| Area | Evidence and assessment |
| --- | --- |
| Borrow places and liveness | [Borrow matrix](../tests/borrow_matrix_test.odin): an independent rules model crosses place forms, copies, bindings, slices, traversals, later uses, branches, loops, and exits. The reserved-loan matrix checks argument evaluation beside mutable lending. It checks expected diagnostic codes and compiler exit status, including unexpected diagnostics outside cases. Strong systematic coverage. |
| Stored carriers and call effects | [Store matrices](../tests/carrier_store_matrix_test.odin): hand-derived verdicts cover stores, copies, overlapping places, call arguments, read-only copies, walkers, task lending, and records passed by value. Unrelated diagnostics and failed compiler processes cannot satisfy an expected borrow rejection. Two overlapping-store scenarios remain deliberately unjudged where their semantics are unsettled. |
| Precision budgets and normalized input | [Carrier tests](../src/carrier_test.odin) exercise recursive shapes, query order, depth, width, array and map boundaries, and precision explanations. [Normalization tests](../src/provenance_normalization_test.odin) inspect storage identities, projections, transfers, effects, summaries, and allocator dependencies. These supplement end-to-end rejection/acceptance tests rather than supplying their oracle. |
| Lifetime and allocator provenance | Positive and negative fixtures include [wrapped borrows](../tests/err/wrapped_borrows.loke), [record-parameter regions](../tests/err/record_carrier_parameter_regions.loke), [received providers](../tests/err/received_provider_regions.loke), and [field-specific results](../tests/run/result_field_through_carrier.loke). Region, task, conversion, reset, and payload regressions have substantial example coverage; these interactions do not yet have the borrow matrices' systematic cross-product coverage through generic operators. |
| Generic inference, specialization, and probes | [Front-end tests](../src/front_end_test.odin) check negative caching, probe commitment, semantic registries, and instantiation limits. [Specialization](../tests/run/m4b_specialization.loke), [probe then use](../tests/err/generic_probe_then_use.loke), and [inference diagnostics](../tests/err/generic_inference_reasons.loke) cover successful selection and rejection. Coverage is primarily curated programs rather than an independent generated model of overload ranking. |
| Operator selection and execution | [Generic lookup](../tests/run/generic_operator_lookup.loke), [operator cases](../tests/run/m4a_operators.loke), [user calls](../tests/run/user_operator_calls.loke), and [borrow failures](../tests/err/user_operator_borrows.loke) cover lookup, generic operators, delegation, indexing, setters, compound operations, and place results. The executable corpus also checks output, so accepting a program alone cannot establish correct dispatch. |
| Generic operators carrying borrows | [Generic provenance matrix](../src/generic_provenance_test.odin) adds 230 checked combinations: pointers, slices, and optional pointers; direct fields, named calls, indexing, forwarding, methods, and delegation; live and finished borrows, independent roots, branches, back edges, deferred uses, and local-root escape; scalar instances before and after carrier instances. Rejections require one specific diagnostic naming the borrowed root. Twenty-two sibling-root combinations are reserved for the two newly reproduced precision gaps below. |
| Rechecking after edits | [Session tests](../src/session_test.odin) compare reused checks with fresh compilations, including diagnostics and emitted IR. The body-effects test now reaches all four scenarios: global writes, returned views, global reads, and stored carriers. Its stored-carrier scenario had been unreachable behind a duplicated condition. [Incremental tests](../src/incremental_test.odin) also check prefix reuse, invalidation, and multi-file rebinding. |
| Fuzzing | [Checker mutation fuzzing](../tests/checker_fuzz_test.odin) checks crashes, hangs, internal failures, repeated diagnostics, and cascades. It runs in the full gate, with three mutants per executable fixture by default. It has no oracle for whether a changed program should be borrow-safe or which overload should win. |

The strongest coverage is the combination of independent borrow/store models,
accepted and rejected fixtures, and snapshot-versus-fresh checks. Passing these
does not establish exhaustive safety or ranking coverage.

## Remaining priorities

- The review reproduced two false rejections: [a returned mutable carrier
  keeps sibling borrows](known-gaps.md#a-returned-mutable-carrier-keeps-sibling-borrows)
  and [delegated indexing keeps sibling slice
  borrows](known-gaps.md#delegated-indexing-keeps-sibling-slice-borrows).
  Both need fixes before their reserved matrix combinations can run with the
  specification's acceptance expectation. The pre-existing [called-index
  switch gap](known-gaps.md#a-switch-over-a-place-whose-index-calls-suspends-the-whole-view)
  is also excluded from the general borrow matrix.
- Extend the interaction matrix to owner and allocator-region results,
  resets, and task joins across generic calls and delegated operators.
- Add an independent overload-selection matrix crossing candidate order,
  conversions, argument modes, bounds, and specialization. Existing curated
  cases cover these individually, but source mutation cannot detect a silent
  wrong winner without an expected semantic result.

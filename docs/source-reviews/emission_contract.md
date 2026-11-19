# `src/emission_contract.odin` review

Reviewed [`src/emission_contract.odin`](../../src/emission_contract.odin) at
`ea622efe`. The boundary checks semantic records before LLVM lowering begins.

## Findings

### A formatter can pass validation without a witness table [P2]

`validate_operation_policies` at lines 124–128 checks a formatter's single
slot target. `validate_witnesses` at lines 177–188 checks only the witnesses
present in `witness_order`. If finalization leaves a formatter in
`c.formatters` but omits it from that order, both checks succeed. The naming
pass only assigns table names to ordered witnesses, so `emit_one_format_thunk`
at line 148 uses the empty name as the pointer operand and can return malformed
LLVM text without `L0405`. Validate that each formatter's witness is in the
emission order, and reuse the ordered witness validation for its target. An
emission-contract test can check a formatted program, remove its formatter's
entry from `witness_order`, and expect `L0405` with an empty module.
[Witness enrollment](../../src/erased.odin#L604) ·
[Witness naming](../../src/emit_llvm_names.odin#L162) ·
[Formatter lowering](../../src/emit_llvm_format.odin#L140) ·
[Boundary tests](../../src/emit_llvm_test.odin#L407)

### A nil spawn entry escapes the contract diagnostic [P3]

`validate_spawns` at lines 193–196 dereferences `task.frame` before checking
the task pointer. `spawn_tasks` stores pointers, so a nil entry can crash the
compiler in validation. Include a nil task check before reading the frame and
exercise it in the existing incomplete-registry test. The producer appends an
allocated task, so this is an internal invariant failure case.
[Registry type](../../src/compiler.odin#L232) ·
[Spawn enrollment](../../src/parallel.odin#L392) ·
[Boundary tests](../../src/emit_llvm_test.odin#L407)

## Simplification and compiler boundaries

- `validate_lifecycle` at lines 135–136 builds a hash map over every
  synthesized procedure, then scans the same list at lines 162–172 for copy
  procedures. Populate the membership set for `.Clone` and `.Try_Clone` in
  that scan, then validate the records against it. This eliminates one list
  pass and keeps unrelated synthesized procedures out of the set. Preserve
  the list-membership check because `synth_enrolled` survives deletion from
  the list. `validate_typeids` at lines 69–81 already checks its dense IDs' count,
  range, and uniqueness in one pass using indexed booleans.
  [Synthesis enrollment](../../src/semantic.odin#L1144) ·
  [Lifecycle mutation test](../../src/emit_llvm_test.odin#L677)
- `semantic_extent` at lines 236–250 measures size changes. Its documentation
  should describe it as a growth guard over the counted stores. In-place
  changes and entries in omitted registries such as `typeid_values` or
  `dyn_proc_adapters` are invisible to it. Keep semantic dependency creation
  and resolution in checking and use local emission checks for operands
  whose dependencies live on the AST. [Speculation snapshot](../../src/speculation.odin#L16) ·
  [Emission orchestration](../../src/emit_llvm.odin#L84) ·
  [Closed semantic registries](../compiler-architecture.md#closed-semantic-registries)

## Verification

Traced producer and consumer paths and inspected the existing boundary tests.
The two findings describe internal registry mutations established by inspection.
Normal `-emit-ll` controls for `formattable.loke`, `parallel_tasks.loke`, and
`distinct_array_clone.loke` passed using `loke-source-review.exe` at
`v0.10.0-4-gea622efe`. Verified the report's links and anchors.
`check-citations.ps1` and `bundle.ps1` passed.

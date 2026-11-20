# `src/emit_llvm_dispatch.odin` review

Reviewed [`src/emit_llvm_dispatch.odin`](../../src/emit_llvm_dispatch.odin) at
`e1aab600`. The file emits CPU dispatchers and the higher-level copies they
reach. The checker validates the requested CPU level, the emitter owns the
call targets and target attributes, and the runtime determines whether the
processor and operating system can run the copy. The dispatcher preserves the
procedure's public identity and forwards the same parameters, including hidden
result storage, to either body. [Attribute validation](../../src/attributes.odin#L368) ·
[Dispatch contract](../design.md#cpu_dispatchstring) ·
[CPU detection](../../runtime/cpu.c#L32)

## Findings

### The dispatch cache is local to each emitted module and CPU level [P3]

`dispatch_check` emits an `internal global` for each requested level. Two
independently compiled object files in one process therefore have distinct
answers to initialize even when both dispatch to `x86-64-v3`. Within one
module, concurrent first callers can both see zero and ask the runtime before
either stores an answer. The relaxed atomics suffice to publish a standalone,
stable answer. The guide, architecture, and runtime header currently describe
the dispatch query as occurring once per process. Describe the cache as lazy,
per emitted module and level, with possible repeated first queries. Clang's
processor-detection cache is separate. [Emitted cache](../../src/emit_llvm_dispatch.odin#L122) ·
[CPU levels](../compiler-guide.md#cpu-levels) ·
[CPU dispatch](../compiler-architecture.md#cpu-dispatch) ·
[Runtime header](../../runtime/loke_rt.h#L632)

## Simplification and boundaries

- L74–76 `yagni:` Inline `symbol.dispatch_cpu > e.c.target.cpu` at its single
  caller, `emit_proc`. The emitter can decide whether a checked symbol needs a
  dispatcher next to the two possible emission calls. [Predicate](../../src/emit_llvm_dispatch.odin#L74) ·
  [Procedure emission](../../src/emit_llvm.odin#L367)
- L25–53 `shrink:` Keep one copy level in the active function state and use
  `.X86_64` to represent ordinary emission. Attribute validation excludes
  baseline copies, and the worklist can only propagate its seed's higher
  level. This removes the parallel `copying` flag and the guard in
  `copy_attributes`. The ordinary FMA query still reads the build level.
  [Copy state](../../src/emit_llvm.odin#L177) ·
  [State initialization](../../src/emit_llvm.odin#L423) ·
  [Unwind thunk state](../../src/emit_llvm_unwind.odin#L394)
- L43–45 `shrink:` Derive the suffix by trimming `x86-64-` from
  `cpu_level_name(cpu)`. The callers already restrict it to higher levels,
  so the suffixes keep their current spellings and follow the shared names.
  Keep the explicit LLVM feature sets, which describe what can be inlined
  into a copy. [Suffix](../../src/emit_llvm_dispatch.odin#L43) ·
  [CPU level names](../../src/build_config.odin#L33)
- L133–145 `shrink:` End the initialization block with `ret i1 %yes` and the
  cached block with the existing equality test on `%known`. This removes the
  join and phi and avoids reinterpreting the byte just computed on the cold
  path. [Check emission](../../src/emit_llvm_dispatch.odin#L133)

`net: -10 lines possible.` The estimate covers the predicate, copy state, and
check emission cuts.

The `(symbol, level)` map and pending stack are both needed. Claiming the name
before queuing a body deduplicates shared callees and terminates recursive call
graphs. Draining the stack after ordinary procedure emission means later
declarations are eligible for copies too. Keep canonical names for procedure
values and shared thunks, and retain direct calls in both dispatcher branches
so LLVM still sees their target-specific attributes. [Copy naming](../../src/emit_llvm_dispatch.odin#L60) ·
[Pending copies](../../src/emit_llvm_dispatch.odin#L110) ·
[Module emission order](../../src/emit_llvm.odin#L109)

## Verification

Traced the dispatcher, copy worklist, runtime query, and ABI helpers in source.
Inspected the existing checks for CPU-specific IR, implicit direct callees,
and name collisions. The per-module cache scope follows from its LLVM internal
linkage. [IR expectations](../../tests/ll/cpu_dispatch.expected) ·
[Implicit call fixture](../../tests/run/dispatch_implicit_calls.loke) ·
[Name collision fixture](../../tests/run/dispatch_names.loke)

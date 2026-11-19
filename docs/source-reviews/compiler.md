# Source review of compiler.odin

Reviewed [compiler.odin](../../src/compiler.odin) at `ea622efe`. It defines
whole-program settings and the shared state used by package discovery,
checking, analysis, emission, and incremental checkpoints.

## Findings

- **P3 · Profiling cost, line 391.** Every provenance graph build samples the
  clock and scratch usage, including ordinary CLI and language server checks.
  The standalone provenance profiler is the sole consumer of these statistics.
  Pass an opt-in setting to the session and guard the aggregate timing and
  high-water measurements. Keep the per-program replay count used by the
  normalization tests. Measure the default path before and after if the
  instrumentation is changed. [Compiler storage](../../src/compiler.odin#L391) ·
  [Unconditional measurement](../../src/provenance_effect.odin#L58) ·
  [Profiler](../../bench/provenance_profile/main.odin#L21) ·
  [Replay regression](../../src/provenance_normalization_test.odin#L928)
- **P3 · Checkpoint ownership, lines 381–395.** `Package_Checkpoint` saves the
  entire compiler value, including the live arena handles and the analysis
  allocator that points into the original compiler. Restore then replaces the
  arena watermark with the live one, clears the copied emission arena, and
  recreates the scratch arenas. Group the disposable analysis and emission
  storage under one field and zero that field on capture.
  Keep semantic allocation at the original compiler address so saved IDs and
  arena pointers remain valid. This reduces the parts of restore that need to
  change when a new scratch buffer is added. [Compiler storage](../../src/compiler.odin#L380) ·
  [Checkpoint capture](../../src/incremental.odin#L67) ·
  [Checkpoint restore](../../src/incremental.odin#L192) ·
  [Checkpoint contract](../compiler-architecture.md#incremental-checking)

## Verification

Traced reads and writers at the reviewed revision and compared checkpoint
capture, restoration, and destruction with the documented allocation domains.
The profiler is a live consumer, so its statistics should remain available.
The hash indexes serve identity lookups, while their companion slices preserve
stable discovery or emission order. Verification was static and the performance
impact remains unmeasured. [Allocation domains](../compiler-architecture.md#allocation-domains)

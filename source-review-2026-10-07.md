# Source-file review — 2026-10-07

All **168 files** in the agreed scope were individually read by three subagents:
34 frontend files, 75 backend/runtime/library files, and 59 analysis/harness/tooling
files. The review checked correctness, opportunities to delete duplicated work,
and ownership of responsibilities between modules. Small `.loke` corpus fixtures
were excluded; implementation, test harnesses, libraries, examples, benchmarks,
scripts, and CI workflows were included.

This is a review, with documentation changes only. The four earlier findings
fixed in `1a8aa53` remain closed: runtime cache contents, release-gap extraction,
cache-test failure detail, and duplicate switch-case scans. Source was reviewed at that commit; reproductions used the existing `lokec.exe`.

## Findings

There are 19 confirmed language/API finding groups below; G07 groups two
distinct exact-decimal defects. Minimal reproductions, observed behavior, and
specific correction paths are registered in [Known gaps](known-gaps.md#gaps).
P1 denotes an accepted unsafe program or silently wrong generated behavior;
P2 denotes another material correctness defect.

| ID | Priority | Source | Evidence and result |
| --- | --- | --- | --- |
| G01: Map literal keys lose their borrow when the value changes the key variable (fixed) | P1 | `src/cfg_provenance.odin · prov_composite_content` | Compile/IR reproduction. Accepted despite a map key still borrowing dropped storage; control rejected L0512. |
| G02: Parallel assignments through setters write only the final destination (fixed) | P1 | `src/check.odin; src/emit_llvm_stmt.odin · assignment setter plan` | Runtime reproduction. Prints 0 22 instead of 11 22. |
| G03: Assignment repeats a panicking drop hook (fixed) | P2 | `src/emit_llvm_stmt.odin · emit_replace_place` | Runtime reproduction. Runs drop 2 twice and aborts on double panic. |
| G04: Dynamic array clear repeats completed drops during unwinding (fixed) | P2 | `runtime/container.c · dyn_clear` | Runtime reproduction. Runs drops 1, 2, 1, 2 and skips remaining cleanup. |
| G05: Partially constructed record literals omit completed field cleanup (fixed) | P2 | `src/emit_llvm_expr.odin · emit_composite_into` | Runtime reproduction. Omits the completed field's drop before unwinding older locals. |
| G06: Packed field projections emit loads with excessive alignment (fixed) | P1 | `src/emit_llvm_iteration.odin; src/emit_llvm_calls.odin · packed projections` | IR reproduction. Packed offset-1 u64 reads omit align 1 in foreach and field.get. |
| G07: Exact decimal narrowing loses the exponent or a second negation (fixed) | P2 | `src/bigint.odin; src/check_expr.odin · exact decimal conversion` | Runtime reproduction. Minimum exponent becomes 1.0; double negation changes f32 rounding. |
| G08: Compile-time local constants require a zero before their initializer (fixed) | P2 | `src/eval.odin · eval_local_decl` | Compile/IR reproduction. Valid initialized local constant fails L0311. |
| G09: Compile-time evaluation rejects ordinary user operators (fixed) | P2 | `src/eval.odin · operator evaluation` | Compile/IR reproduction. Ordinary user operator fails L0341 during required CTFE. |
| G10: Compile-time drop silently skips user hooks (diagnosed; now a [spec rule](design.md#compile-time-procedure-evaluation)) | P2 | `src/eval.odin · explicit drop` | Compile/IR reproduction. Reached drop-hook panic silently evaluates to 1. |
| G11: A single dynamic-array spread reaches LLVM with the wrong carrier (fixed) | P2 | `src/check_calls.odin; src/emit_llvm_calls.odin · one spread` | Compile/IR reproduction. Accepted by checker, then L0403 from mismatched LLVM carrier. |
| G12: An inout result cannot return an existing map entry (fixed) | P2 | `src/check.odin · return inout` | Compile/IR reproduction. Existing map-entry place rejected L0418. |
| G13: Dyn slot calls omit required argument mode validation (fixed) | P2 | `src/erased.odin · check_dyn_slot_call` | Runtime reproduction. Missing inout marker accepted and mutates the argument. |
| G14: File-scope when treats an offset_of field token as a lexical dependency (fixed) | P2 | `src/select.odin · first_unresolved_name` | Compile/IR reproduction. Field token x incorrectly produces L0389. |
| G15: Static foreach accepts a reserved literal as its binding (fixed) | P2 | `src/expand.odin · bind_static` | Runtime reproduction. Reserved true loop binding accepted and prints 2. |
| G16: Reflection builtins accept invalid argument names and modes (fixed) | P2 | `src/check_builtin.odin · location/type-info handlers` | Compile/IR reproduction. Bogus named inout operands accepted. |
| G17: Shared allocation failure ignores the allocator Trap policy (fixed) | P2 | `base/runtime/shared.loke; allocation wrappers` | Runtime reproduction. Trap allocator unwinds and prints unwound. |
| G18: Parsing negative zero as an integer panics (fixed) | P2 | `core/strconv/strconv.loke · parse_i64` | Runtime reproduction. parse_i64("-0") panics instead of returning zero. |
| G19: Windows process wait panics on high-bit exit statuses (fixed) | P2 | `core/process/process.loke · wait_native` | Runtime reproduction. Child status 0xffffffff panics instead of returning -1. |

The most urgent fixes were G01, G02, and G06, now fixed with regression
tests; a fixed row no longer links to Known gaps. The cleanup findings G03–G05
shared an ownership obligation: completed resources need exactly one live
cleanup registration, retired before entering a user drop hook. They are
fixed; checking their sibling paths found that a container's whole drop
leaked the elements after a panicking hook, also fixed now.

## Tooling and harnesses

| ID | Priority | Location | Finding and evidence |
| --- | --- | --- | --- |
| T01 (fixed) | P2 | `src/subprocess/subprocess.odin`; manual corpus child | Process handles are never closed after start/wait. A 32-call reproduction retained 64 handles: at least 32 owned process handles, plus a separate upstream Odin thread-handle leak. |
| T02 (fixed) | P3 | `src/subprocess/subprocess.odin` | Second-pipe failure bypasses cleanup of the first writer. Confirmed by acquisition/return tracing; no injected native failure. |
| T03 (fixed) | P2 | `src/formatter.odin` | Directory glob treats brackets as syntax. Reproduced: directory fmt-check succeeds and fmt leaves bytes unchanged while direct-file fmt-check fails. |
| T04 | P3 | `tests/corpus_test.odin` | Compiler freshness check omits the compiled-in subprocess package. Confirmed from the scan and import paths. |
| T05 | P3 | `perf.ps1` | Repeat zero/negative values create extra runs through inclusive range semantics. Confirmed by evaluating the range expressions. |
| T06 | P3 | `perf.ps1` | Build/run/output failure skips temporary-directory removal. Confirmed by the throw and cleanup paths. |

These are registered with concrete next changes in
[Compiler and harness resource handling](open-questions.md#compiler-and-harness-resource-handling)
and [Performance script validation and cleanup](open-questions.md#performance-script-validation-and-cleanup).

## Simplification and structure

Six specific proposals, all since applied without a behavior change:

- S01: moved append delegates to the existing moved insertion.
- S02: delegated operators reuse the existing member append helper.
- S03: the power-of-two loop uses the existing math library operation.
- S04: general synthesized-symbol helpers move from iteration into semantics.
- S05: three C-host tests share their repeated runtime-link inputs.
- S06: corpus workers share one immutable case owner instead of cloning its array.

G06 and G17 also pointed to shared responsibilities: use the existing projection
alignment helper consistently, and route ordinary allocation failures through
one allocator-policy operation carrying the original error. Both are fixed that
way; G17's operation is the package-private `allocation_failed` built-in.

## Candidates and limits

[Candidates still needing evidence](open-questions.md#candidates-still-needing-evidence)
records ten bounded follow-ups. They cover panic cleanup of shared/boxed values,
native thread-creation failure, fallible I/O scratch allocation, an environment
race, parser depth, generic-name checks, composite-key dependency traversal,
internal type-ID ordering, and ignored subprocess wait errors.

A long selector chain did not establish a crash. Local nominal type sort-key
collisions are an internal ordering concern; the spec does not promise numeric
type IDs remain unchanged across changed builds. Neither is presented as a
confirmed spec divergence. Spec-permitted reserved field/enum member names and
foreign-call/nil-dyn false positives were excluded.

## Verification

Targeted programs were compiled, run, or inspected as described per finding.
The map-borrow reproduction was compiled only; its accepted dangling borrow was
not executed. Packed-field findings were confirmed in emitted IR, without
claiming an optimized runtime failure. Allocation policy was directly faulted
for shared construction; sibling wrapper behavior is source-traced.

The earlier quick gate, before `1a8aa53`, passed all 125 unit tests and 40 of
41 integration tests. The runtime-cache test failed once and passed its
required isolated rerun; its earlier review item is now closed. This is
historical evidence, not a current all-green result. No full gate was run for
this documentation-only continuation. Local work papers and output logs are
under ignored `tests/tmp/source-review-2026-10-07/`; the durable reproductions
are in Known gaps.

## Per-file coverage

Every row below represents a full individual reading. “No independent
actionable finding” records the review result, not a proof that the file is
bug-free. Finding IDs refer to the sections above; C IDs refer to the candidate
table in Open questions.

| File | Reviewer | Result |
| --- | --- | --- |
| `.github/workflows/ci.yml` | analysis-harness | No independent actionable finding after full reading. |
| `.github/workflows/release.yml` | analysis-harness | Earlier gap-extraction finding closed in 1a8aa53. |
| `base/interfaces/interfaces.loke` | backend-library | No independent actionable finding after full reading. |
| `base/meta/meta.loke` | backend-library | No independent actionable finding after full reading. |
| `base/runtime/runtime.loke` | backend-library | No independent actionable finding after full reading. |
| `base/runtime/shared.loke` | backend-library | G17: failure policy bypass; C01: final-release panic cleanup. |
| `bench/collections.loke` | backend-library | No independent actionable finding after full reading. |
| `bench/nbody.loke` | backend-library | No independent actionable finding after full reading. |
| `check-citations.ps1` | analysis-harness | No independent actionable finding after full reading. |
| `core/container/bit_set.loke` | backend-library | No independent actionable finding after full reading. |
| `core/container/enum_array.loke` | backend-library | No independent actionable finding after full reading. |
| `core/container/small_array.loke` | backend-library | S01: delegate moved append to moved insertion. |
| `core/cstrings/cstrings.loke` | backend-library | No independent actionable finding after full reading. |
| `core/encoding/utf16/utf16.loke` | backend-library | No independent actionable finding after full reading. |
| `core/endian/endian.loke` | backend-library | No independent actionable finding after full reading. |
| `core/fmt/fmt.loke` | backend-library | G17: final string allocation wrapper hardcodes panic. |
| `core/fs/fs.loke` | backend-library | C03: infallible scratch allocation in fallible API. |
| `core/io/io.loke` | backend-library | No independent actionable finding after full reading. |
| `core/log/log.loke` | backend-library | No independent actionable finding after full reading. |
| `core/math/complex.loke` | backend-library | No independent actionable finding after full reading. |
| `core/math/math.loke` | backend-library | No independent actionable finding after full reading. |
| `core/mem/mem.loke` | backend-library | No independent actionable finding after full reading. |
| `core/os/os.loke` | backend-library | No independent actionable finding after full reading. |
| `core/os/process.loke` | backend-library | C04: empty-variable removal race. |
| `core/path/path.loke` | backend-library | No independent actionable finding after full reading. |
| `core/process/process.loke` | backend-library | G19: high-bit exit conversion; C03: infallible scratch allocation. |
| `core/simd/simd.loke` | backend-library | No independent actionable finding after full reading. |
| `core/slice/slice.loke` | backend-library | G17: same allocation-wrapper policy pattern, source-traced. |
| `core/strconv/strconv.loke` | backend-library | G18: parse_i64 negative zero panics. |
| `core/strings/builder.loke` | backend-library | G17: same allocation-wrapper policy pattern, source-traced. |
| `core/strings/iterate.loke` | backend-library | No independent actionable finding after full reading. |
| `core/strings/strings.loke` | backend-library | G17: same allocation-wrapper policy pattern, source-traced. |
| `core/sync/sync.loke` | backend-library | No independent actionable finding after full reading. |
| `core/term/term.loke` | backend-library | No independent actionable finding after full reading. |
| `core/thread/thread.loke` | backend-library | C02: native start failure after ownership transfer. |
| `core/unsafe/unsafe.loke` | backend-library | No independent actionable finding after full reading. |
| `examples/aliasing.loke` | backend-library | No independent actionable finding after full reading. |
| `examples/arena_pipeline.loke` | backend-library | No independent actionable finding after full reading. |
| `examples/compile_time.loke` | backend-library | No independent actionable finding after full reading. |
| `examples/config_parser.loke` | backend-library | No independent actionable finding after full reading. |
| `examples/corpus_runner.loke` | backend-library | S06: share one immutable case owner across workers. |
| `examples/game_of_life.loke` | backend-library | No independent actionable finding after full reading. |
| `examples/greeting.loke` | backend-library | No independent actionable finding after full reading. |
| `examples/hello.loke` | backend-library | No independent actionable finding after full reading. |
| `examples/keys.loke` | backend-library | No independent actionable finding after full reading. |
| `examples/lexer.loke` | backend-library | No independent actionable finding after full reading. |
| `examples/shapes.loke` | backend-library | No independent actionable finding after full reading. |
| `examples/streaming.loke` | backend-library | No independent actionable finding after full reading. |
| `examples/tokens.loke` | backend-library | No independent actionable finding after full reading. |
| `examples/tour.loke` | backend-library | No independent actionable finding after full reading. |
| `examples/word_frequency.loke` | backend-library | No independent actionable finding after full reading. |
| `perf.ps1` | analysis-harness | T05, T06: invalid repeat range and failure cleanup. |
| `runtime/alloc.c` | backend-library | No independent actionable finding after full reading. |
| `runtime/arena.c` | backend-library | No independent actionable finding after full reading. |
| `runtime/args.c` | backend-library | No independent actionable finding after full reading. |
| `runtime/atomic.c` | backend-library | No independent actionable finding after full reading. |
| `runtime/container.c` | backend-library | G04: dynamic clear repeats completed drops; sibling native cleanup paths traced. |
| `runtime/fail.c` | backend-library | No independent actionable finding after full reading. |
| `runtime/format.c` | backend-library | No independent actionable finding after full reading. |
| `runtime/loke_rt.h` | backend-library | No independent actionable finding after full reading. |
| `runtime/panic.c` | backend-library | No independent actionable finding after full reading. |
| `runtime/text.c` | backend-library | No independent actionable finding after full reading. |
| `runtime/trace.c` | backend-library | No independent actionable finding after full reading. |
| `src/abi.odin` | frontend | No independent actionable finding after full reading. |
| `src/ast_clone_test.odin` | analysis-harness | No independent actionable finding after full reading. |
| `src/ast_clone.odin` | frontend | No independent actionable finding after full reading. |
| `src/ast_dump.odin` | frontend | No independent actionable finding after full reading. |
| `src/ast.odin` | frontend | No independent actionable finding after full reading. |
| `src/atomics.odin` | analysis-harness | No independent actionable finding after full reading. |
| `src/attributes.odin` | frontend | No independent actionable finding after full reading. |
| `src/bigint_test.odin` | analysis-harness | No independent actionable finding after full reading. |
| `src/bigint.odin` | frontend | G07: minimum exponent loses scaling; unnecessary extreme-exponent work. |
| `src/bootstrap.odin` | frontend | No independent actionable finding after full reading. |
| `src/borrow.odin` | analysis-harness | No independent actionable finding after full reading. |
| `src/box.odin` | analysis-harness | No independent actionable finding after full reading. |
| `src/build_config.odin` | frontend | No independent actionable finding after full reading. |
| `src/carrier_test.odin` | analysis-harness | No independent actionable finding after full reading. |
| `src/cfg_provenance.odin` | analysis-harness | G01: map key provenance must be captured before value writes. |
| `src/cfg.odin` | analysis-harness | No independent actionable finding after full reading. |
| `src/check_builtin.odin` | frontend | G16: missing shared argument-shape checks. |
| `src/check_calls.odin` | frontend | G11: one spread needs a converted variadic carrier. |
| `src/check_expr.odin` | frontend | G07: second negation discards exact decimal spelling. |
| `src/check.odin` | frontend | G02, G12, G15; C07: setter plans, inout returns, binding validation. |
| `src/const_ops.odin` | frontend | S03: use math.ldexp for power-of-two construction. |
| `src/container.odin` | analysis-harness | No independent actionable finding after full reading. |
| `src/customization.odin` | frontend | No independent actionable finding after full reading. |
| `src/doc.odin` | analysis-harness | No independent actionable finding after full reading. |
| `src/emission_contract.odin` | backend-library | No independent actionable finding after full reading. |
| `src/emit_llvm_abi.odin` | backend-library | No independent actionable finding after full reading. |
| `src/emit_llvm_adapters.odin` | backend-library | No independent actionable finding after full reading. |
| `src/emit_llvm_atomics.odin` | backend-library | No independent actionable finding after full reading. |
| `src/emit_llvm_box.odin` | backend-library | C05: remaining fields/block after payload panic. |
| `src/emit_llvm_calls.odin` | backend-library | G06, G11: descriptor alignment and variadic carrier forwarding. |
| `src/emit_llvm_cleanup.odin` | backend-library | G04 family: native callback/remaining-element cleanup paths traced. |
| `src/emit_llvm_containers.odin` | backend-library | G04 family: native callback progress and map-replacement pattern traced. |
| `src/emit_llvm_debug.odin` | backend-library | No independent actionable finding after full reading. |
| `src/emit_llvm_expr.odin` | backend-library | G05: missing partial-record cleanup; related packed equality projections need checking. |
| `src/emit_llvm_iteration.odin` | backend-library | G06: packed field projections omit alignment annotation. |
| `src/emit_llvm_runtime.odin` | backend-library | No independent actionable finding after full reading. |
| `src/emit_llvm_simd.odin` | backend-library | No independent actionable finding after full reading. |
| `src/emit_llvm_stmt.odin` | backend-library | G02, G03: final-only setter emission and repeated destination drop. |
| `src/emit_llvm_test.odin` | analysis-harness | No independent actionable finding after full reading. |
| `src/emit_llvm_toolchain.odin` | backend-library | Earlier cache finding closed in 1a8aa53; no additional confirmed defect. |
| `src/emit_llvm.odin` | backend-library | No independent actionable finding after full reading. |
| `src/enums.odin` | frontend | No independent actionable finding after full reading. |
| `src/erased.odin` | analysis-harness | G13: dyn slot arguments omit mode validation. |
| `src/eval.odin` | frontend | G08–G10: initializer zero, user operators, and custom drop evaluation. |
| `src/expand.odin` | frontend | G15: reserved static loop binding accepted. |
| `src/foreign.odin` | frontend | No independent actionable finding after full reading. |
| `src/format.odin` | analysis-harness | No independent actionable finding after full reading. |
| `src/formatter.odin` | analysis-harness | T03: bracketed directory silently skipped. |
| `src/front_end_test.odin` | analysis-harness | No independent actionable finding after full reading. |
| `src/generic.odin` | frontend | C07: written reserved generic parameter validation. |
| `src/global_effects.odin` | analysis-harness | No independent actionable finding after full reading. |
| `src/hash.odin` | analysis-harness | No independent actionable finding after full reading. |
| `src/hooks.odin` | analysis-harness | No independent actionable finding after full reading. |
| `src/impl.odin` | frontend | No independent actionable finding after full reading. |
| `src/incremental_test.odin` | analysis-harness | No independent actionable finding after full reading. |
| `src/incremental.odin` | analysis-harness | No independent actionable finding after full reading. |
| `src/install.odin` | analysis-harness | No independent actionable finding after full reading. |
| `src/interface.odin` | analysis-harness | No independent actionable finding after full reading. |
| `src/iterate.odin` | analysis-harness | S04: general semantic construction helpers live in iteration. |
| `src/iteration_adapters.odin` | analysis-harness | No independent actionable finding after full reading. |
| `src/iteration_mutable.odin` | analysis-harness | No independent actionable finding after full reading. |
| `src/iteration_yield.odin` | analysis-harness | No independent actionable finding after full reading. |
| `src/layout.odin` | analysis-harness | No independent actionable finding after full reading. |
| `src/lexer.odin` | frontend | No independent actionable finding after full reading. |
| `src/lifecycle.odin` | analysis-harness | No independent actionable finding after full reading. |
| `src/main.odin` | frontend | No independent actionable finding after full reading. |
| `src/materialize.odin` | frontend | No independent actionable finding after full reading. |
| `src/operators.odin` | frontend | S02: reuse add_members. |
| `src/optional.odin` | analysis-harness | Earlier duplicate switch scan closed in 1a8aa53; no additional finding. |
| `src/overlays.odin` | analysis-harness | No independent actionable finding after full reading. |
| `src/overload.odin` | frontend | No independent actionable finding after full reading. |
| `src/packages.odin` | frontend | No independent actionable finding after full reading. |
| `src/parser.odin` | frontend | C06: unbounded type selector spine; no reproduced crash. |
| `src/precision.odin` | analysis-harness | No independent actionable finding after full reading. |
| `src/proc_contracts.odin` | analysis-harness | No independent actionable finding after full reading. |
| `src/project.odin` | frontend | No independent actionable finding after full reading. |
| `src/providers.odin` | frontend | No independent actionable finding after full reading. |
| `src/queries.odin` | analysis-harness | No independent actionable finding after full reading. |
| `src/query_index.odin` | analysis-harness | No independent actionable finding after full reading. |
| `src/reflect.odin` | analysis-harness | C09: local nominal textual sort-key collision, no spec divergence established. |
| `src/region.odin` | analysis-harness | No independent actionable finding after full reading. |
| `src/select.odin` | frontend | G14: offset_of token dependency; C08: composite key traversal. |
| `src/semantic.odin` | frontend | No independent actionable finding after full reading. |
| `src/session_test.odin` | analysis-harness | No independent actionable finding after full reading. |
| `src/session.odin` | analysis-harness | No independent actionable finding after full reading. |
| `src/simd.odin` | analysis-harness | No independent actionable finding after full reading. |
| `src/slice.odin` | analysis-harness | No independent actionable finding after full reading. |
| `src/source.odin` | frontend | No independent actionable finding after full reading. |
| `src/stack.odin` | analysis-harness | No independent actionable finding after full reading. |
| `src/stdlib.odin` | analysis-harness | No independent actionable finding after full reading. |
| `src/subprocess/subprocess.odin` | analysis-harness | T01, T02; C10: process/pipe lifetime and discarded wait error. |
| `src/syntax_corpus_test.odin` | analysis-harness | No independent actionable finding after full reading. |
| `src/text.odin` | analysis-harness | No independent actionable finding after full reading. |
| `src/union.odin` | analysis-harness | No independent actionable finding after full reading. |
| `src/universe.odin` | frontend | No independent actionable finding after full reading. |
| `src/zero.odin` | frontend | No independent actionable finding after full reading. |
| `test-all.ps1` | analysis-harness | No independent actionable finding after full reading. |
| `tests/checker_fuzz_test.odin` | analysis-harness | No independent actionable finding after full reading. |
| `tests/corpus_test.odin` | analysis-harness | T01, T04; S05: child close, source freshness, and repeated host-link inputs. |
| `tests/obj/concurrent_host.c` | analysis-harness | No independent actionable finding after full reading. |
| `tests/obj/host.c` | analysis-harness | No independent actionable finding after full reading. |
| `tests/obj/process_output_fault.c` | analysis-harness | No independent actionable finding after full reading. |
| `tests/obj/provider_host.c` | analysis-harness | No independent actionable finding after full reading. |
| `tests/runtime_test.odin` | analysis-harness | Earlier failure-detail item closed in 1a8aa53; no additional finding. |
| `tests/tutorial_test.odin` | analysis-harness | No independent actionable finding after full reading. |

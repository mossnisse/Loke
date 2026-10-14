# Compiler review, 2026-10-14

Review of commit `3d332e4`, using a compiler rebuilt from that source with
`-vet-unused -vet-shadowing`. Separate subagent passes examine compiler stages
and subject areas; the coordinating pass checks package loading, sessions,
documentation, cross-stage evidence, and the combined findings.

The review covers correctness, simplification, optimization, and code structure.
It changes documentation only. Confirmed specification divergences have minimal
reproductions in [Known gaps](known-gaps.md#gaps); engineering follow-ups are
tracked in [Open questions](open-questions.md#compiler-review-2026-10-14).
This is focused source review and reproduction, not exhaustive path coverage or
a proof of soundness. Earlier fixed findings in the
[2026-10-07 review](source-review-2026-10-07.md#findings) were checked to avoid
reporting them again.

## Correctness findings

| ID | Priority | Subject | Finding and evidence |
| --- | --- | --- | --- |
| G01 | P2 | Package discovery (fixed) | Package spelling changes compiler-contributed members: uppercase directory spelling or a second collection alias removes library members. Compile/IR reproduction. |
| G02 | P2 | Operator selection (fixed) | Built-in priority drifts: signed shifts and mixed text expressions call user overloads. Runtime reproduction. |
| G03 | P2 | Lexical scope (fixed) | Local operators leak: a nested overload causes ambiguity inside and after its block. Compiler reproduction. |
| G04 | P2 | Assignment lowering (fixed) | Compound setters reread indices: right-hand mutation redirects the write. Runtime reproduction. |
| G05 | P2 | Contextual typing (fixed) | Parallel setters lose destination context: legal `i32` literal assignments become `int` and fail. Compiler reproduction. |
| G06 | P2 | CTFE iteration (fixed) | Borrowed bindings become copies: the same procedure returns different pointer-equality results at compile time and runtime. Runtime comparison. |
| G07 | P2 | CTFE reflection (fixed) | Field access lacks interpreter dispatch: a valid constant read fails L0344. Compile/IR reproduction and runtime control. |
| G08 | P2 | Reflection argument checks (fixed) | Descriptor calls discard labels and modes: invalid `bogus = inout` is accepted. Runtime reproduction. |
| G09 | P2 | Lifecycle tracking (fixed) | Owned scalar bindings bypass liveness: moves/drops do not invalidate some loop and case bindings. Compile/IR reproduction. |
| G10 | P2 | Return ownership (fixed) | Owned case payloads look borrowed: returning a move-only payload is rejected. Compiler reproduction. |
| G11 | P2 | Managed-type classification (fixed) | Nested excluded copy hooks are missed: a forbidden copy is accepted and fails at runtime; query order changes classification. Runtime reproduction. |
| G12 | P1 | Callback result contracts (fixed) | Named global roots are omitted: incompatible callbacks substitute an unrelated borrow root. Accepted/control compile probes. |
| G13 | P1 | Written allocator regions (fixed) | Pointer aliases hide stored owners: a reset is accepted before subsequent access to freed storage. Accepted/control compile probes. |
| G14 | P2 | Region precision (moved to [open questions](open-questions.md#does-an-unused-allocator-argument-back-an-owning-result)) | Unused allocator arguments taint results; the corpus relies on that reading. A return the review considers valid is rejected despite the precise direct-call summary. Rejected/accepted control probes. |

Priorities distinguish memory/lifetime or compilation robustness risks (P1),
ordinary wrong results and valid-program rejection (P2), and bounded cleanup
opportunities (P3). Priority is separate from confidence: observed results are
identified explicitly; source-derived cost counts are not measured speedups.

## Optimization and robustness

### E01: Complete the procedure-type hash key

Fixed after the review.

[semantic.odin](src/semantic.odin), `intern_proc_type`, lines 1042–1102, compares
`proc_contract` and effect fields but hashes only parameters, modes, and result.
Ordinary same-shape procedures returning a string, aggregate, or carrier receive
distinct contract identities and therefore collide in one bucket. Each insertion
scans the bucket and copies it to a new semantic-arena allocation, retaining old
buffers.

For 10,000 such signatures, this path performs at least 49,995,000 comparisons
and retains 50,005,000 `u32` IDs, approximately 191 MiB. These are source-derived
counts, not compiler working-set measurements. Hash all normalized equality
fields, including the contract. This avoids a guaranteed quadratic family
without introducing another representation.

### E02: Stop rescanning each formatter output line

Fixed after the review.

[formatter.odin](src/formatter.odin), `line_indent`, lines 319–327, searches back
to the last newline every time an opening bracket is emitted. Many statements
on one line produce quadratic scanning. A focused `-fmt-check` measurement for
32,000 / 64,000 / 128,000 `f();` statements took approximately
463 / 1,413 / 4,444 ms; the equivalent one-statement-per-line inputs took
259 / 452 / 882 ms.

Record the current output line's indentation in `Layout` when starting it and
remove `line_indent`. Preserve the actual emitted indentation, including flat
file-scope `when` blocks. These are individual end-to-end observations, not a
statistical benchmark or measured before/after implementation.

### E03: Start documentation lookup at the preceding comment

Fixed after the review.

[doc.odin](src/doc.odin), `doc_comment`, lines 154–173, begins at the final
comment for every declaration and skips all later comments. N documented
declarations cause roughly N(N−1)/2 skipped-comment visits.

For 16,000 / 32,000 public constants, `-doc` took 817 / 2,765 ms with comments
and 264 / 497 ms without comments. Output was discarded in both cases; the
compiler and input shape were otherwise the same. Use binary search over the
already ordered comment spans, then walk only the immediately attached comment
group. This benefits documentation generation and hover documentation.

### E04: Charge compile-time scalar sorting against its budget

Fixed after the review.

[eval.odin](src/eval.odin), `eval_sort`, lines 1391–1403, uses insertion sort
without `eval_step` in the comparison loop. Scalar comparison does not charge a
step either. Sorting 2,000 descending integers completes despite performing
1,999,000 scalar comparisons, beyond the evaluator's documented internal
1,000,000-step ceiling. The reproduction fills a dynamic array, calls `sort`,
and folds its first element to 1; compilation took approximately 459 ms.

Charge each iteration/comparison and consider an O(n log n) sort. The precise
definition of an interpreter step is internal, so this is a resource-control
follow-up rather than a claim that the language promises one step per AST node.

### E05: Bound AST depth across parenthesized expression segments

Fixed after the review.

[parser.odin](src/parser.odin), `parse_binary` and `parse_postfix`, lines
1991–2023 and 2080–2107, subtract their local spine depth on return. A
parenthesized subtree then becomes the base of another suffix chain without
carrying its accumulated AST depth. Each segment stays below `MAX_NEST`, but
the resulting tree can greatly exceed it.

A focused generated input containing 50 parenthesized segments of 1,000
selectors passes `-parse-only`; normal checking terminates with Windows stack
overflow status `0xC00000FD` and no diagnostic. Track resulting subtree depth
when composing nodes, or use bounded/iterative consumers. Apply the same rule to
binary and type selector spines; adding another parser-call guard alone does
not bound the tree handed to later recursive stages.

### E06: Apply the carrier-width cap during collection

Fixed after the review.

[borrow.odin](src/borrow.odin), lines 526–539, collects and allocates every leaf
path before collapsing a shape above `CARRIER_WIDTH` to one conservative path.
The discarded paths remain in semantic storage. Four nested record levels with
k fields can allocate k^4 paths even though only the collapsed result survives.
Stop after `CARRIER_WIDTH + 1` leaves and construct the existing truncated path.
Preserve the same reachability and precision metadata. This is source-derived
allocation analysis; no timing improvement was measured.

### E07: Schedule global-effect propagation by changed callees

Fixed after the review. A chain of 6000 bodies declared caller first took
1.3 s to compile before and 0.37 s after; declared callee first, 0.39 s
before and 0.36 s after.

[global_effects.odin](src/global_effects.odin), lines 444–453, rescans every
body's calls whenever any global-write set changes. A forward-ordered N-body
chain ending in one write requires N rounds and quadratic edge visits. Use
reverse caller edges and queue only affected callers, as the result-summary
solver already does in [borrow.odin](src/borrow.odin). No shared solver framework
is needed. Benchmark both declaration orders before implementing this change;
the cost finding here is source-derived.

### E08: Check for active defers before classifying statement panic behavior

Fixed after the review.

[cfg.odin](src/cfg.odin), `emit_unwind_branch`, line 596, recursively classifies
the statement before checking whether any `Defer` is active. Without defers,
the result is discarded. Nested panic-free statements can consequently cause
quadratic classification visits in each analysis graph. Move the existing
defer check before classification. This adds no representation and has
approximately zero code-size impact; no measured latency claim is made.

## Simplification and structure

Ranked concrete cuts, using the `ponytail-audit` skill for this part of the
review:

- `shrink:` Remove the extra whole-container buffer allocation in seven CTFE update paths. Assign the already fresh arena-owned buffer to `slot.elements` and delete `set_contents`; approximately 25 lines. [eval.odin](src/eval.odin) Done after the review.
- `shrink:` Form user binary-operator candidates once. Retain viability and the candidate set across fallback choice and ranking instead of calling `operator_viable` and then repeating formation in `resolve_operator`. Preserve ambiguity and promotion behavior. [check_expr.odin](src/check_expr.odin), [overload.odin](src/overload.odin) Done after the review.
- `shrink:` Share built-in operand joining between applicability and checking. Remove the second independently maintained unification table while fixing G02. [operators.odin](src/operators.odin), [check_expr.odin](src/check_expr.odin) Done after the review.
- `shrink:` Delete the formatter's backward indentation scan after recording current-line indentation (E02). [formatter.odin](src/formatter.odin) Done after the review.
- `shrink:` Share the small owned-binding slot/Init registration sequence while fixing G09. Keep liveness for all owned locals and cleanup for managed ones; approximately 15–20 net lines. [cfg.odin](src/cfg.odin) Done after the review.
- `shrink:` Remove the declaration-pointer requirement from owned-local return classification while fixing G10; existing borrowed-binding and duration facts carry the distinction. [lifecycle.odin](src/lifecycle.odin) Done after the review.

All seven `set_contents` callers pass fresh `kept`, `grown`, or `next` buffers
allocated with `ev.alloc`. Retaining those buffers removes one allocation and
copy per operation without changing element ownership or invalidation. Appending
600 integers folds successfully; 800 reaches the 64 MiB scratch ceiling. That
ceiling is permitted; the redundant allocation is independently removable.
Repeated append still retains quadratic arena storage after this small change,
so no claim of linear-space append follows from it.

Candidate formation currently retains three disposable arrays in the semantic
arena per ordinary candidate. In the common one-overload binary case, repeating
formation makes that six arrays. A shared retained candidate set removes real
work; a broad overload framework rewrite is unnecessary.

net: approximately -40 to -45 lines, -0 dependencies possible from the two
quantified cuts; the other cuts have no implementation-backed line estimate yet.

## Stage coverage

| Stage or subject | Scope and result |
| --- | --- |
| Driver, build configuration, packages, providers | Coordinating pass inspected `main`, `session`, `build_config`, `project`, `packages`, `providers`, `install`, and source-loading/diagnostic paths. G01; no independent confirmed provider-selection defect. |
| Lexing and source encoding | Syntax pass inspected lexer/source seams and consulted UTF-8 and syntax tests. No independent confirmed lexer defect. |
| Parsing, AST, cloning, formatting | Syntax pass inspected parser depth/recovery, AST/dump/clone seams, and formatter. E02/E05; no claim of exhaustive AST-consumer coverage. |
| Types, expressions, overloads, conversions | Separate semantic pass inspected central checker/call/builtin/semantic/overload/operator paths, enum/union/optional/zero handling and `when` seams. G02–G05 and E01. |
| Generics and interface constraints | Separate pass inspected inference, defaults, cache keys, definition-site lookup, probes/promotion, bounds, generic impl matching and interface slots/predicates. No independent confirmed specialization/constraint defect. |
| Constant folding, CTFE, expansion, reflection | Separate pass inspected evaluator values/budgets/calls/containers/control flow, shared arithmetic/bigint conversion, static expansion, reflection and materialization. G06–G08 and E04; previous exact-decimal and reserved-name fixes remain present. |
| Ownership, lifecycle, CFG, captures, Box, yields | Separate pass read lifecycle/hook/capture/Box/yield files and inspected CFG construction, scopes, loops/switches, defer/unwind paths, returns and last-use settlement. G09–G11/E08; no independent confirmed capture/Box/yield defect. |
| Root borrowing, regions, effects, callback contracts | Separate pass inspected result and written-region summaries, fixed points, substitutions, carriers, global effects, region/reset/escape logic and precision metadata. G12–G14/E06/E07. Broader unwind/provenance leads were not promoted without reproduction. |
| Sessions, overlays, incremental checkpoints, queries | Coordinating pass inspected invalidation, discovery comparison, checkpoint capture/restore, suffix reparsing, overlays and snapshot/query indexing. Existing equivalence tests pass; further service review is recorded below when complete. |
| Documentation | Coordinating pass inspected public-API rendering, comment extraction and query documentation. E03. |

## Verification

- Rebuilt `lokec-review.exe` and `loke-lsp-review.exe` with both vets.
- Compiler unit tests: 132 passed, with memory tracking enabled.
- Language-server unit tests: 39 passed, with memory tracking enabled.
- Baseline integration run used those freshly built binaries through `LOKEC`
  and `LOKE_LSP`. Odin's runner failed while stopping
  `tests.a_debugger_shows_values`, reporting an unknown signal and exception
  `0xC000001D`; it did not produce a completed suite result. An orphan compiler
  child was terminated after the runner had gone. The debugger fixture compiled
  directly with `-g -emit-ll` and with `-g` successfully afterward. The runner
  failure is unisolated and is not counted as a compiler defect.
- Individual compile/IR and compile/run probes establish the findings above.
  Unsafe lifetime examples are checked without executing invalid accesses.

No compiler fixes or new regression tests are included in this review. Each
behavior fix should add its regression and run its affected suite, following
[Testing and verification](compiler-architecture.md#testing-and-verification).

# Compiler source review (2026-11-02)

A review of the source of `lokec` at commit `92cb0d18`, one file at a time.
Besides bugs it looks for simplifications, dead code, data structures and
algorithms that do not fit their purpose, near copies, structure and boundaries,
and comments that can be shortened. It is non-normative: every item is a
proposal, and nothing here changes the specification. Line links refer to that
commit, so they drift as the source changes.

## How the review was done

Each of the 106 non-test files in `src/` went to its own agent. The six files
over 4000 lines were reviewed in parts of about 3000 lines, which made 115
reviews. A separate agent then tried to refute each high and medium severity bug
by reading the callers and the specification and by running probe programs
against `lokec.exe`. A last agent read the code behind the findings that span
files and wrote [the ranked list](#the-changes-most-worth-making) and
[the cross-file section](#findings-that-span-files).

The review did not cover the `_test.odin` files, `lsp/`, `runtime/`, or the
bundled packages.

Findings are deleted from this report as they are fixed, so every count below is
what remains; git history has the original. The rankings and the cross-file
section are revised when a fix changes them.

## How far to trust it

| Findings | Count | Checked by |
| --- | ---: | --- |
| High and medium severity bugs | 160 (36 high, 124 medium) | An independent attempt to refute each one |
| Low severity bugs | 155 | Only the reviewer that found them; marked *Not verified* |
| Simplifications | 597 | Only the reviewer |
| Dead code | 336 | The reviewer's search, and a word count over `src`, `lsp`, `tests` and `bench` for the 45 that name a symbol |
| Data structures and algorithms | 119 | Only the reviewer |
| Near copies | 388 | The reviewer; the groups under [Findings that span files](#findings-that-span-files) were also read at each site |
| Structure and boundaries | 249 | Only the reviewer |
| Comments | 457 | Only the reviewer |

Every one of the 195 refutation attempts came back confirmed, with none
refuted. That is an unusually clean result, so read it with care. Many of the
verdicts cite a reproduction, and each is quoted in italics after its bug, but a
confirmation can still rest on a misreading of the intended behavior. Three
kinds of disagreement remain open:

- **Severity.** A verifier that thought the severity wrong said so in its note
  without changing the label. Read the note, not only the label.
- **Roots.** One defect can appear under several ids, because each file was
  reviewed alone. [Roots shared by several bugs](#roots-shared-by-several-bugs)
  merges the ones found so far, so 315 overstates the number of separate
  defects.
- **Spec.** A bug here says the compiler disagrees with `design.md` or
  `grammar.md`. If the specification is what should change, that is a decision
  for the person fixing it.

Spot checks while writing this report agreed with the reviews: six saved probes
were rerun against the compiler and behaved as reported, and a few counted
claims were recounted. One of those, `.type = INVALID_TYPE`, came to 302 sites
with a slightly wider pattern than the 297 stated below. These checks are a
small sample, not a second review. The estimates of lines saved are
the reviewers' own and overlap across files. They add up to about 11,500 of the
104,000 reviewed lines, but treat that as an upper bound on what a real
clean-up would remove.

## Overall picture

The most valuable findings are the bugs: several accept unsafe programs,
miscompile, or crash the compiler, and the ranked list below starts with those
that reach users. Many of them come from code written twice. One copy gets a
check or a case and the other does not, which is why fixing the shared root
often closes several ids at once.

Near copies are real but smaller than the raw count of 388 suggests: the
cross-file groups come to about 2,000 lines, and their main value is the roughly
50 bugs they explain. The largest cheap reductions are mechanical: the failure
boilerplate in `eval.odin`, and comments that narrate the code.

## Findings that span files

Commit 92cb0d18. Every site linked below was read; a count such as "33 sites" comes from a grep of `src`, excluding tests. Savings are rough net lines. "Fixes" names a bug whose root is the divergence described. Together the groups come to about 2,000 lines of a 110,000-line tree; their larger value is the roughly 50 bug ids they explain.

### Roots shared by several bugs

#### One root behind separately reported bugs

These ids describe one defect each and need one fix. Each is also confirmed by a repro in a per-file review.

### Small idioms and misplaced code

#### One-line helpers that exist, or should

- [box.odin:45](src/box.odin#L45), [simd.odin:15](src/simd.odin#L15) and [iterate.odin:68](src/iterate.odin#L68) differ in one string. `predeclared_callee(k, callee, name)` saves about 12 lines.
- A parameter's mode with the bounds test is written at 24 sites, for example [check_calls.odin:668](src/check_calls.odin#L668) and [emit_llvm_calls.odin:1423](src/emit_llvm_calls.odin#L1423), beside [semantic.odin:1339](src/semantic.odin#L1339) `proc_parameter_mode`. A `param_mode_at(info, index)` saves no lines but shortens every site.
- `make([]Expr, 1, ...)` plus two assignments at about 15 checker sites, for example [enums.odin:51](src/enums.odin#L51), becomes `v.bound = bound_exprs(k, e)`, from `check_builtin.odin`. About 30 lines.
- Copy cost then copy classification: `classify_copy_cost` at [lifecycle.odin:589](src/lifecycle.odin#L589), [union.odin:484](src/union.odin#L484), [optional.odin:108](src/optional.odin#L108) and [check_expr.odin:2721](src/check_expr.odin#L2721) follows the same arguments' `classify_copy`. One wrapper, about 8 lines.
- Storage named by duration: [cfg_provenance.odin:5674](src/cfg_provenance.odin#L5674), [cfg_provenance.odin:7350](src/cfg_provenance.odin#L7350), [cfg_provenance.odin:10455](src/cfg_provenance.odin#L10455), `check_via_policy` in [check.odin](src/check.odin), [lifecycle.odin:109](src/lifecycle.odin#L109). About 10 lines.
- An on-demand constant that names a type: [check.odin:1888](src/check.odin#L1888), [check.odin:2230](src/check.odin#L2230), [iterate.odin:480](src/iterate.odin#L480). About 12 lines.
- Source text by span: [cfg.odin:1913](src/cfg.odin#L1913), [cfg_provenance.odin:489](src/cfg_provenance.odin#L489), [check.odin:2394](src/check.odin#L2394), [capture.odin:93](src/capture.odin#L93). Span key: [attributes.odin:150](src/attributes.odin#L150), [hooks.odin:1106](src/hooks.odin#L1106), [hooks.odin:1138](src/hooks.odin#L1138). `span_text` and `span_key` in `source.odin`.

#### Code in the wrong file

Each move below names a site with its only callers or its stated owner. Moves save no lines; they make the source-code map true.

### Looked at and left alone

- `aggregate_equal` and `aggregate_order` ([const_ops.odin:777](src/const_ops.odin#L777), [const_ops.odin:835](src/const_ops.odin#L835)) against `eval_compare` ([eval.odin:1131](src/eval.odin#L1131)): one loop would need a reader callback over `Const_Value` and `Eval_Value`, no simpler than the copies.
- `eval_hash` ([eval.odin:4112](src/eval.odin#L4112)) against `emit_hash_value` ([emit_llvm_calls.odin:397](src/emit_llvm_calls.odin#L397)): one computes and one emits, so they can only change together.
- `prints_through_method_walk` ([format.odin:78](src/format.odin#L78)) against `emit_format_body` ([emit_llvm_runtime.odin:698](src/emit_llvm_runtime.odin#L698)): the layering rules out a shared form; the checker cannot call the emitter's walk.
- `synchronized_field_walk` ([materialize.odin:119](src/materialize.odin#L119)) and `type_requires_results_walk` ([zero.odin:98](src/zero.odin#L98)): inline-only walks with no closures to share them; a visitor would be longer.
- `type_is_comparable_walk` ([semantic.odin:1976](src/semantic.odin#L1976)), `record_order_blocker_walk` ([semantic.odin:2074](src/semantic.odin#L2074)) and `type_is_hashable_walk` ([hash.odin:30](src/hash.odin#L30)): each kind has its own rule, so `type_parts` would remove little.
- Region-content find-or-grow ([cfg_provenance.odin:4394](src/cfg_provenance.odin#L4394), [cfg_provenance.odin:5835](src/cfg_provenance.odin#L5835), [borrow.odin:2974](src/borrow.odin#L2974)): differing equality tests, path truncation and allocators leave a shared form no simpler.
- `fmt.aprintf(..., allocator = c.semantic_allocator)` at 57 sites: a wrapper shortens the lines without removing any, and the checker's local failure blocks are better served by per-file helpers such as `requirement_failuref`.

## Findings per file

Counts per file, then the findings themselves in the same order.

| File | Lines | Bugs | Simplify | Dead | Data | Copies | Structure | Comments |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| [ast.odin](src/ast.odin) | 1488 | 1 | 5 | 2 | 1 | 1 | 1 | 6 |
| [attributes.odin](src/attributes.odin) | 484 | 2 | 3 | 4 | 1 | 3 | 2 | 5 |
| [bigint.odin](src/bigint.odin) | 529 | 0 | 6 | 3 | 4 | 3 | 2 | 4 |
| [bootstrap.odin](src/bootstrap.odin) | 152 | 0 | 0 | 0 | 0 | 3 | 0 | 0 |
| [borrow.odin](src/borrow.odin) | 7130 | 7 | 36 | 21 | 13 | 21 | 15 | 24 |
| [box.odin](src/box.odin) | 232 | 5 | 4 | 0 | 0 | 5 | 2 | 5 |
| [capture.odin](src/capture.odin) | 285 | 4 | 4 | 4 | 2 | 2 | 2 | 4 |
| [cfg.odin](src/cfg.odin) | 3031 | 8 | 11 | 9 | 2 | 10 | 7 | 7 |
| [cfg_provenance.odin](src/cfg_provenance.odin) | 10813 | 4 | 51 | 14 | 15 | 33 | 21 | 31 |
| [check.odin](src/check.odin) | 4915 | 20 | 26 | 7 | 6 | 15 | 13 | 16 |
| [check_builtin.odin](src/check_builtin.odin) | 1598 | 9 | 13 | 4 | 1 | 6 | 6 | 11 |
| [check_calls.odin](src/check_calls.odin) | 1336 | 6 | 7 | 5 | 1 | 8 | 5 | 7 |
| [check_expr.odin](src/check_expr.odin) | 4188 | 19 | 16 | 14 | 5 | 14 | 11 | 16 |
| [const_ops.odin](src/const_ops.odin) | 888 | 3 | 5 | 3 | 1 | 8 | 3 | 6 |
| [container.odin](src/container.odin) | 831 | 2 | 12 | 6 | 2 | 7 | 5 | 9 |
| [doc.odin](src/doc.odin) | 1375 | 7 | 9 | 4 | 1 | 6 | 5 | 5 |
| [emit_llvm.odin](src/emit_llvm.odin) | 1192 | 4 | 7 | 4 | 0 | 3 | 4 | 3 |
| [emit_llvm_abi.odin](src/emit_llvm_abi.odin) | 1227 | 2 | 13 | 3 | 2 | 5 | 4 | 7 |
| [emit_llvm_calls.odin](src/emit_llvm_calls.odin) | 1828 | 2 | 11 | 7 | 3 | 8 | 7 | 6 |
| [emit_llvm_cleanup.odin](src/emit_llvm_cleanup.odin) | 1820 | 1 | 11 | 11 | 3 | 4 | 4 | 7 |
| [emit_llvm_containers.odin](src/emit_llvm_containers.odin) | 1436 | 2 | 15 | 3 | 3 | 8 | 4 | 7 |
| [emit_llvm_expr.odin](src/emit_llvm_expr.odin) | 2549 | 4 | 13 | 8 | 3 | 11 | 4 | 6 |
| [emit_llvm_iteration.odin](src/emit_llvm_iteration.odin) | 1057 | 3 | 7 | 3 | 0 | 4 | 4 | 6 |
| [emit_llvm_runtime.odin](src/emit_llvm_runtime.odin) | 1737 | 2 | 10 | 9 | 1 | 10 | 4 | 4 |
| [emit_llvm_simd.odin](src/emit_llvm_simd.odin) | 372 | 0 | 4 | 2 | 0 | 7 | 1 | 6 |
| [emit_llvm_stmt.odin](src/emit_llvm_stmt.odin) | 1047 | 11 | 7 | 6 | 0 | 7 | 3 | 7 |
| [emit_llvm_toolchain.odin](src/emit_llvm_toolchain.odin) | 843 | 8 | 6 | 2 | 1 | 2 | 5 | 5 |
| [enums.odin](src/enums.odin) | 105 | 0 | 0 | 0 | 0 | 2 | 1 | 0 |
| [erased.odin](src/erased.odin) | 1216 | 5 | 9 | 4 | 4 | 8 | 5 | 6 |
| [eval.odin](src/eval.odin) | 4169 | 9 | 22 | 10 | 5 | 13 | 8 | 14 |
| [expand.odin](src/expand.odin) | 694 | 5 | 12 | 3 | 1 | 4 | 4 | 6 |
| [foreign.odin](src/foreign.odin) | 174 | 8 | 2 | 4 | 0 | 2 | 1 | 6 |
| [format.odin](src/format.odin) | 298 | 4 | 7 | 2 | 1 | 3 | 2 | 5 |
| [formatter.odin](src/formatter.odin) | 516 | 6 | 10 | 4 | 0 | 2 | 1 | 4 |
| [generic.odin](src/generic.odin) | 3992 | 8 | 15 | 7 | 5 | 12 | 7 | 9 |
| [global_effects.odin](src/global_effects.odin) | 2276 | 3 | 9 | 9 | 3 | 5 | 5 | 7 |
| [hash.odin](src/hash.odin) | 383 | 5 | 5 | 2 | 0 | 2 | 2 | 7 |
| [hooks.odin](src/hooks.odin) | 1260 | 2 | 8 | 5 | 2 | 6 | 4 | 8 |
| [impl.odin](src/impl.odin) | 627 | 7 | 8 | 1 | 0 | 3 | 3 | 5 |
| [incremental.odin](src/incremental.odin) | 369 | 0 | 6 | 4 | 1 | 2 | 2 | 8 |
| [interface.odin](src/interface.odin) | 1484 | 10 | 8 | 5 | 1 | 11 | 3 | 6 |
| [intrinsic.odin](src/intrinsic.odin) | 562 | 4 | 5 | 4 | 0 | 3 | 0 | 2 |
| [iterate.odin](src/iterate.odin) | 1150 | 8 | 11 | 9 | 0 | 5 | 4 | 6 |
| [lifecycle.odin](src/lifecycle.odin) | 1202 | 4 | 10 | 4 | 2 | 5 | 4 | 9 |
| [operators.odin](src/operators.odin) | 770 | 12 | 10 | 10 | 2 | 5 | 3 | 8 |
| [optional.odin](src/optional.odin) | 746 | 4 | 8 | 3 | 0 | 7 | 4 | 4 |
| [overload.odin](src/overload.odin) | 1023 | 6 | 8 | 7 | 1 | 4 | 3 | 8 |
| [parallel.odin](src/parallel.odin) | 744 | 4 | 8 | 2 | 0 | 6 | 1 | 7 |
| [parser.odin](src/parser.odin) | 4270 | 17 | 24 | 11 | 0 | 10 | 4 | 15 |
| [private_names.odin](src/private_names.odin) | 1151 | 9 | 8 | 9 | 2 | 5 | 4 | 9 |
| [provenance_effect.odin](src/provenance_effect.odin) | 369 | 0 | 4 | 3 | 1 | 2 | 1 | 7 |
| [provenance_form.odin](src/provenance_form.odin) | 145 | 0 | 1 | 0 | 0 | 2 | 0 | 0 |
| [provenance_input.odin](src/provenance_input.odin) | 368 | 0 | 4 | 5 | 2 | 1 | 2 | 3 |
| [provenance_read.odin](src/provenance_read.odin) | 64 | 0 | 1 | 0 | 0 | 1 | 2 | 0 |
| [provenance_transfer.odin](src/provenance_transfer.odin) | 303 | 0 | 4 | 3 | 2 | 2 | 4 | 3 |
| [queries.odin](src/queries.odin) | 671 | 5 | 5 | 7 | 4 | 2 | 3 | 4 |
| [query_index.odin](src/query_index.odin) | 361 | 3 | 4 | 5 | 1 | 4 | 1 | 2 |
| [reflect.odin](src/reflect.odin) | 938 | 5 | 7 | 2 | 1 | 8 | 3 | 9 |
| [region.odin](src/region.odin) | 251 | 0 | 0 | 0 | 0 | 1 | 0 | 0 |
| [select.odin](src/select.odin) | 504 | 3 | 7 | 3 | 2 | 4 | 0 | 6 |
| [semantic.odin](src/semantic.odin) | 2578 | 3 | 14 | 9 | 3 | 5 | 4 | 10 |
| [session.odin](src/session.odin) | 299 | 1 | 2 | 10 | 0 | 1 | 2 | 7 |
| [simd.odin](src/simd.odin) | 596 | 7 | 5 | 9 | 0 | 5 | 2 | 8 |
| [slice.odin](src/slice.odin) | 91 | 0 | 0 | 0 | 0 | 1 | 0 | 0 |
| [source.odin](src/source.odin) | 911 | 2 | 5 | 0 | 1 | 3 | 2 | 7 |
| [text.odin](src/text.odin) | 350 | 6 | 4 | 0 | 1 | 3 | 2 | 4 |
| [union.odin](src/union.odin) | 636 | 4 | 5 | 3 | 0 | 2 | 2 | 7 |
| [universe.odin](src/universe.odin) | 132 | 0 | 0 | 0 | 0 | 2 | 0 | 1 |

### src/attributes.odin

A compact, table-driven validator in good shape overall; the table matches `design.md`.

**Near copies**

- [attributes.odin:150](src/attributes.odin#L150), [hooks.odin:1106](src/hooks.odin#L1106) and [hooks.odin:1138](src/hooks.odin#L1138): the same `u64(file) << 32 | u64(lo)` key. Make `generic_hook_key` a shared `span_key(span)`. (about 2 lines)

### src/box.odin

What remains is the near copies shared with sibling files.

**Near copies**

- [box.odin:45](src/box.odin#L45), [simd.odin:15](src/simd.odin#L15) and [iterate.odin:68](src/iterate.odin#L68): `box_type_callee`, `simd_callee` and `range_callee` differ only in the name. Shared form: `predeclared_type_callee(k, callee, "Box")`. (about 12 lines)

### src/cfg.odin

What remains are near copies whose helper would span other files.

**Near copies**

- [cfg.odin:1913](src/cfg.odin#L1913), [cfg_provenance.odin:489](src/cfg_provenance.odin#L489), [parallel.odin:81](src/parallel.odin#L81): slicing a span out of `sources`; a span form in `source.odin` replaces them.

### src/cfg_provenance.odin (part 1 of 4)

This part is careful and I found no bugs; the reaching-places walk (Tarjan with epochs) held up when traced by hand, and every top-level declaration has a user. The cost is bulk: repeated small path and slot idioms, a few quadratic list builds, and a place-offset engine that deserves its own file.

**Near copies**

- [cfg_provenance.odin:489](src/cfg_provenance.odin#L489): span text is hand-indexed here, and at [parallel.odin:81](src/parallel.odin#L81), [cfg.odin:1913](src/cfg.odin#L1913) and [check.odin:2394](src/check.odin#L2394). A `span_text(c, span)` in `source.odin` is the shared form.

### src/cfg_provenance.odin (part 3 of 4)

Region stores, written aliases, place walking, and the statement and call hooks: the comments mostly earn their place, but `prov_assign`, `prov_call` and `prov_declare_region` do too many jobs and hold most of the local repetition.

**Near copies**

- [cfg_provenance.odin:5674](src/cfg_provenance.odin#L5674), [cfg_provenance.odin:7350](src/cfg_provenance.odin#L7350), [cfg_provenance.odin:10455](src/cfg_provenance.odin#L10455), `check_via_policy` in [check.odin](src/check.odin) and [lifecycle.odin:109](src/lifecycle.odin#L109): each names the storage of a duration by hand. One `storage_phrase(duration)` covers them.

### src/check.odin (part 1 of 2)

What remains here waits on a helper shared across files.

**Near copies**

- [check.odin:1888](src/check.odin#L1888), [check.odin:2230](src/check.odin#L2230), [iterate.odin:481](src/iterate.odin#L481): check a constant on demand, then read the type it names. Share `const_type_value(k, id, subject) -> Type_Id`. (about 8 lines)

### src/check_calls.odin

The file is readable and its comments mostly say why, and every declaration has a caller. Its weak spot is that the direct, method, and group call paths each finish a call by hand with different subsets of the same steps, which is the root of the one serious bug; the bugs below were reproduced with the `lokec.exe` built from this commit.

**Near copies**

- [check_calls.odin:668](src/check_calls.odin#L668) and [semantic.odin:1341](src/semantic.odin#L1341): `index < len(info.param_modes) ? ... : Param_Mode.Value` recurs at lines 826 and 899 and about fifteen times across the emitter, `parallel.odin`, and others. A `parameter_mode(info, index)` beside `proc_parameter_mode`, which then calls it, replaces them all.
- [check_calls.odin:78](src/check_calls.odin#L78) and [iterate.odin:68](src/iterate.odin#L68): `range_callee`, [box.odin:45](src/box.odin#L45) `box_type_callee`, and [simd.odin:15](src/simd.odin#L15) `simd_callee` differ only in one string. `unshadowed_callee(k, callee, "Range")` replaces the three. (about 15 lines)

### src/check_expr.odin (part 2 of 2)

What remains here belongs to the groups under "Findings that span files".

**Near copies**

- [check_expr.odin:2721](src/check_expr.odin#L2721), [lifecycle.odin:257](src/lifecycle.odin#L257), [lifecycle.odin:589](src/lifecycle.odin#L589), [optional.odin:108](src/optional.odin#L108): `classify_copy_cost` then `classify_copy` with the same arguments. A wrapper returning `classify_copy`'s result removes one line per pair.

### src/enums.odin

Small and correct.

**Near copies**

- [enums.odin:51](src/enums.odin#L51), [union.odin:482](src/union.odin#L482), [union.odin:611](src/union.odin#L611) and [check_calls.odin:1028](src/check_calls.odin#L1028) repeat `v.bound = make([]Expr, 1, ...)` then `v.bound[0] = x`.
  About 15 checker sites use this or the `bound :=` spelling; a `bind_single(k, v, x)` saves one line at each.

### src/hooks.odin

The classification logic is careful and its comments mostly explain why. What remains is a near copy shared with another file.

**Near copies**

- [hooks.odin:1106](src/hooks.odin#L1106), [hooks.odin:1138](src/hooks.odin#L1138) and [attributes.odin:150](src/attributes.odin#L150): the same `file << 32 | lo` position key. Line 1138 should call `generic_hook_key`; a `span_key(span)` beside `Span` would serve all three.

### src/iterate.odin

What remains are near copies that need helpers shared across files.

**Near copies**

- [iterate.odin:68](src/iterate.odin#L68), [simd.odin:15](src/simd.odin#L15) and [box.odin:45](src/box.odin#L45): identical apart from the name. Share `predeclared_callee(k, callee, "Range")`.

### src/lifecycle.odin

The dataflow core is sound and the file is readable, but `exchange` lets an owned place through unmoved (a heap-corrupting double free) and unwind paths do not vote on deferred assignments. Much of the rest is repeated error plumbing, and the file holds four loosely related jobs.

**Near copies**

- [lifecycle.odin:589](src/lifecycle.odin#L589), [union.odin:484](src/union.odin#L484), [optional.odin:108](src/optional.odin#L108) and [check_expr.odin:2721](src/check_expr.odin#L2721): `classify_copy_cost` then `classify_copy` with the same arguments. A `classify_costed_copy` returning the bool serves these; box and insertion differ and keep the two calls.
- [lifecycle.odin:38](src/lifecycle.odin#L38), [lifecycle.odin:81](src/lifecycle.odin#L81), [lifecycle.odin:199](src/lifecycle.odin#L199), and [check_builtin.odin:748](src/check_builtin.odin#L748): `make` a `[]Expr` then assign each slot. A variadic `bind_arguments(k, v, ..values)` makes each one line.

### src/select.odin

What remains is the predeclared-callee near copies, shared with `box.odin`, `simd.odin` and `iterate.odin`.

**Near copies**

- [simd.odin:15](src/simd.odin#L15), [iterate.odin:68](src/iterate.odin#L68) and [box.odin:45](src/box.odin#L45), combined at [select.odin:440](src/select.odin#L440): the same procedure but for the spelling. Share `unbound_callee(k, callee, name)`.

### src/simd.odin

What remains is the predeclared-callee near copy, shared with `box.odin` and `iterate.odin`.

**Near copies**

- [simd.odin:15](src/simd.odin#L15), [box.odin:45](src/box.odin#L45) and [iterate.odin:68](src/iterate.odin#L68): `simd_callee`, `box_type_callee` and `range_callee` differ only in the name; use `predeclared_callee(k, callee, "Simd")`.

### src/universe.odin

A small, table-driven file whose bindings match design.md "Predeclared names"; no bugs here. What remains is a builtin symbol spelled three ways.

**Near copies**

- [box.odin:45](src/box.odin#L45), [iterate.odin:68](src/iterate.odin#L68) and [simd.odin:15](src/simd.odin#L15): the predeclared names with no universe entry use one proc three times; only the string differs. Shared form: `predeclared_callee(k, callee, "Box")`. (about 14 lines)

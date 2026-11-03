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
boilerplate in `eval.odin` and the checker, and comments that narrate the code.

## The changes most worth making

6. **`nil` operands crash.** Route the nil case at [box.odin:147](src/box.odin#L147) through `check_defaulted_operand` in `check_builtin.odin`. BUG-box-1. About 10 lines.





18. **One syntax walker and one owned-parts walker.** `expr_children` replaces the descents at [ast.odin:1388](src/ast.odin#L1388), [doc.odin:578](src/doc.odin#L578), [private_names.odin:515](src/private_names.odin#L515) and [select.odin:313](src/select.odin#L313); `type_parts` serves [hooks.odin:277](src/hooks.odin#L277) and its siblings. Ends the drift behind BUG-ast-1. Removes about 250 lines; no behavior change beyond those.

19. **Mechanical removal of failure boilerplate.** Drop the `v.type = INVALID_TYPE` writes outside `check_expr.odin`, which now defaults it on entry. Low risk.

## Findings that span files

Commit 92cb0d18. Every site linked below was read; a count such as "33 sites" comes from a grep of `src`, excluding tests. Savings are rough net lines. "Fixes" names a bug whose root is the divergence described. Together the groups come to about 2,000 lines of a 110,000-line tree; their larger value is the roughly 50 bug ids they explain.

### Roots shared by several bugs

#### One root behind separately reported bugs

These ids describe one defect each and need one fix. Each is also confirmed by a repro in a per-file review.


#### Container operations classified in several tables

`CONTAINER_OP_EFFECTS` in `container.odin` is exhaustive by construction. Beside it sit `KEY_HASHING_OPS` ([global_effects.odin:493](src/global_effects.odin#L493)), the drop cases of `prov_container_drop_effects` ([global_effects.odin](src/global_effects.odin)), the insertion test at [global_effects.odin:525](src/global_effects.odin#L525), and the per-kind cases at [check_calls.odin:482](src/check_calls.odin#L482) and [emit_llvm_calls.odin:1298](src/emit_llvm_calls.odin#L1298).

Shared form: add `.Hashes_Key`, `.Drops_Element`, `.Drops_Key` and `.Inserts_Element` to `Container_Op_Effect` and drop the sets. Saves about 10 lines; the gain is that every new operation must answer every question.

### Checker and front end

#### Built-in call opening and operands

`builtin_arity_ok` in `check_builtin.odin` writes the arity report, but it is still written by hand at [atomics.odin:164](src/atomics.odin#L164), [format.odin:244](src/format.odin#L244), [simd.odin:427](src/simd.odin#L427) and [text.odin:273](src/text.odin#L273). A loop over fixed target types repeats at [check_builtin.odin:176](src/check_builtin.odin#L176), [text.odin:240](src/text.odin#L240) and [format.odin:251](src/format.odin#L251). The allocator argument repeats at [check_builtin.odin:586](src/check_builtin.odin#L586) and [box.odin:164](src/box.odin#L164).

They differ in diagnostic code (`L0322`, `L0661`, `L0687`, `L0569`, `L0738`), and atomics reports every bad argument rather than the first.

The operand path has the real divergence. `check_defaulted_operand` in `check_builtin.odin` reports `nil`, but [box.odin:147](src/box.odin#L147) calls `default_type` directly, and `materialize` then fails silently on `INVALID_TYPE`.

Shared form: `builtin_arity_ok` at those sites, `bind_typed_arguments(k, v, targets)`, `check_allocator_argument(k, e)`, and `check_defaulted_operand` shared with `box.odin`. Saves about 40 lines and fixes BUG-box-1.

#### Failure writes that the default in `check_expr` makes unnecessary

`check_expr` now sets `base.type = INVALID_TYPE` and `base.value_category = .Value` on entry, so `v.type = INVALID_TYPE` before an early return is needless in what it reaches: [check_builtin.odin](src/check_builtin.odin) 38, [check_calls.odin](src/check_calls.odin) 28, [text.odin](src/text.odin) 18. Some procedures write it once at the top ([check_builtin.odin:97](src/check_builtin.odin#L97), [simd.odin:421](src/simd.odin#L421)), which goes too.

Shared form: assign only on success. Saves about 100 lines.

#### Syntax walkers

[ast.odin:1388](src/ast.odin#L1388) `type_syntax_any_name`, [doc.odin:578](src/doc.odin#L578) `api_refs`, [private_names.odin:515](src/private_names.odin#L515) `walk` and [select.odin:313](src/select.odin#L313) `first_unresolved_name` each repeat one descent through the expression and type-syntax kinds.

| Child | ast | doc | private_names | select |
| --- | --- | --- | --- | --- |
| composite field-name key | walked | skipped unless resolved or keys are values | skipped | skipped unless keys are values |
| `or_else` exit value | walked | no | no | walked |
| composite `via` | walked | walked | no | no |
| parameter default | walked | walked | no | no |

The key difference is BUG-ast-1. The other rows are unexplained, and `private_names` and `select` simply do not look there. Shared form: `expr_children(e, data, visit) -> bool` in `ast.odin`, exhaustive over the kinds, with `data: rawptr` as `type_syntax_any_name` already takes. Each caller handles its own cases in a `#partial switch` and falls through to the children. Saves about 150 to 200 lines. `index_query_expr` ([query_index.odin:228](src/query_index.odin#L228)) reads checked fields and stays out.

#### Type-component walkers

Owned parts are walked at [hooks.odin:166](src/hooks.odin#L166), [hooks.odin:277](src/hooks.odin#L277), [hooks.odin:330](src/hooks.odin#L330), [hooks.odin:370](src/hooks.odin#L370), [region.odin:123](src/region.odin#L123), [borrow.odin:761](src/borrow.odin#L761) and `require_nested_map_key_policies_walk` in [hash.odin](src/hash.odin). They differ in:

- `Shared(T)`: only [borrow.odin:758](src/borrow.odin#L758) and `provider_reach_walk` in `region.odin` follow the payload.
- Void variants and empty arrays: skipped by the drop walk only.

All parts are walked at [semantic.odin:2204](src/semantic.odin#L2204), [semantic.odin:2262](src/semantic.odin#L2262) and [reflect.odin:149](src/reflect.odin#L149), with `Type_Walk` in all three.

Shared form: `type_parts(c, info, buf: ^[dynamic]Type_Id, follow_shared := false)`, returning element, key and element, field types or non-void variants, so each walker becomes its own test plus one loop; and one `type_any_part(c, id, seen, test)` for the second family. Saves about 60 lines in the first family and 70 in the second. A single kind list stops the next bug of this kind.

#### Synthesized syntax nodes

`Expr_Ident`: [capture.odin:102](src/capture.odin#L102), [capture.odin:137](src/capture.odin#L137), [check.odin:3889](src/check.odin#L3889), [check_calls.odin:329](src/check_calls.odin#L329), [expand.odin:636](src/expand.odin#L636), [hooks.odin:823](src/hooks.odin#L823), [parallel.odin:652](src/parallel.odin#L652).
One-name `Decl`: [capture.odin:110](src/capture.odin#L110), [capture.odin:140](src/capture.odin#L140), [check.odin:3898](src/check.odin#L3898), [parallel.odin:182](src/parallel.odin#L182), [parallel.odin:724](src/parallel.odin#L724), [parallel.odin:736](src/parallel.odin#L736).
Dereference: [check.odin:3857](src/check.odin#L3857), [parallel.odin:669](src/parallel.odin#L669), and with the place fields set, [check_expr.odin:1119](src/check_expr.odin#L1119) and `dereference_argument` in `check_calls.odin`.
Selector: [check.odin:2878](src/check.odin#L2878), [check_calls.odin:204](src/check_calls.odin#L204), [expand.odin:627](src/expand.odin#L627), [parallel.odin:660](src/parallel.odin#L660).
One-argument call: [check.odin:4796](src/check.odin#L4796), [expand.odin:640](src/expand.odin#L640), [hooks.odin:832](src/hooks.odin#L832), [optional.odin:259](src/optional.odin#L259), [optional.odin:272](src/optional.odin#L272), [parallel.odin:678](src/parallel.odin#L678).

They differ only in whether the identifier id is passed or interned and in the `Decl` kind. [parallel.odin:651](src/parallel.odin#L651) already has the complete set, with `synth_ident`, `synth_selector` and `synth_deref` package-visible and the rest file-private. Shared form: move `synth_*` to `ast_clone.odin` or a new `synth.odin`, with `synth_decl(c, kind, name, value, declared_type = nil)`, and build `variant_selector` on it. [parallel.odin:700](src/parallel.odin#L700) `synth_record` can also serve the record at [capture.odin:95](src/capture.odin#L95). Saves about 80 lines.

#### Impl member declaration

[impl.odin:209](src/impl.odin#L209) `declare_impl_member` and [generic.odin:3677](src/generic.odin#L3677) `declare_instance_impl_members` repeat the `L0409` clash checks, and [impl.odin:240](src/impl.odin#L240) and [generic.odin:3693](src/generic.odin#L3693) repeat the `Symbol` literal. The generic copy skips a non-constant member silently where [impl.odin:193](src/impl.odin#L193) reports `L0406` (BUG-impl-4), and has its own built-in member check. It also differs on purpose: it admits candidates from other blocks and takes `block.pkg`.

Shared form: `member_name_clash(k, subject, name, name_id, existing) -> bool` and `new_member_symbol(k, d, name, name_id, subject, pkg)`. Saves about 30 lines and fixes BUG-impl-4.

#### Checks on a new local name

[check.odin:560](src/check.odin#L560), [iterate.odin:1064](src/iterate.odin#L1064) and [optional.odin:607](src/optional.odin#L607) repeat `L0304`, the reserved-name test, `L0305` and `note_shadowed_capture`. They differ in which scope they search from and in whether a reserved name stops the declaration; [check.odin:573](src/check.odin#L573) also exempts `$` names. [expand.odin:173](src/expand.odin#L173) has none of the checks (BUG-expand-3), and [capture.odin:85](src/capture.odin#L85) inserts directly (BUG-capture-2).

Shared form: `check_new_local(k, name, id, span, outer_scope) -> bool`. Saves about 20 lines and fixes both.

#### Operator binding and the built-in operator table

[operators.odin:451](src/operators.odin#L451) `bind_operator_operands` repeats the slot loop of `bind_chosen_call` in `check_calls.odin`. Sharing `bind_candidate_slots(k, cand, sym, span, what)` saves about 10 lines.

The table of what a built-in operator accepts is split across [check_expr.odin:2658](src/check_expr.odin#L2658), [check.odin:4197](src/check.odin#L4197), [operators.odin:336](src/operators.odin#L336) and [operators.odin:363](src/operators.odin#L363). Shared form: one `builtin_operator_applies` with shift and SIMD cases and `compound_applies` as that minus concatenation. Saves about 30 lines.

#### Interface composition walk

[erased.odin:747](src/erased.odin#L747), [interface.odin:1356](src/interface.odin#L1356) and [interface.odin:1396](src/interface.odin#L1396) share the same 12-line loop body: skip slots, find the composed interface, clone the requirement, bind its arguments. `composed_application(k, requirement) -> (^Interface_Info, []Generic_Arg, bool)` saves about 30 lines.

In the same area, the candidate loop repeats at [erased.odin:893](src/erased.odin#L893) and [interface.odin:1018](src/interface.odin#L1018), and the constant argument conversion at [interface.odin:312](src/interface.odin#L312), [interface.odin:347](src/interface.odin#L347) and [generic.odin:3070](src/generic.odin#L3070) (`convert_generic_value`, file-private). Sharing both saves about 25 more.

#### Iterator types and synthesized members

Struct-shaped iterator types are built by hand in `iterate.odin` (`new_map_cursor_type` for the `{table, cursor}` ones), `add_mutable_sequence_members` in `iteration_mutable.odin` and `new_adapter_iterator` in `iteration_adapters.odin`. They differ in the cache key.

Shared form: `new_iterator_type(c, name, label, element, key, fields)`. Saves about 30 lines.

`synth_proc` followed by setting `has_receiver` and `receiver` repeats at [customization.odin:112](src/customization.odin#L112), [iterate.odin:398](src/iterate.odin#L398), [format.odin:34](src/format.odin#L34) and [hooks.odin:803](src/hooks.odin#L803). Have `synth_proc` take the receiver from `modes[0]` under a `has_receiver` flag: saves about 15 lines.

#### Switch checking

The union path repeats the case-flow merge of [check.odin:4390](src/check.odin#L4390) at [optional.odin:574](src/optional.odin#L574). [check.odin:4464](src/check.odin#L4464) `check_exhaustive` and [optional.odin:713](src/optional.odin#L713) `report_uncovered_variants` build the same first-three list. With a `missing_list` builder and a `Case_Flow` accumulator this saves about 45 lines.

#### Constant values

- A `Const_Aggregate` is built by hand at 14 sites, for example [check_expr.odin:3332](src/check_expr.odin#L3332), [const_ops.odin:884](src/const_ops.odin#L884), [check_builtin.odin:1378](src/check_builtin.odin#L1378), [enums.odin:83](src/enums.odin#L83), [expand.odin:99](src/expand.odin#L99), [simd.odin:291](src/simd.odin#L291) and [union.odin:618](src/union.odin#L618), while [reflect.odin:307](src/reflect.odin#L307) `aggregate_const` is file-private. Three sites use another allocator, so the shared one takes one as a default parameter. Saves about 30 lines.
- Unary folding is at [check_expr.odin:2057](src/check_expr.odin#L2057) and [eval.odin:852](src/eval.odin#L852). They differ in the allocator, in the decimal spelling kept for `-x`, and in how a failure reports. A `fold_unary(c, op, value, type, allocator) -> (Const_Value, overflowed: bool)` in `const_ops.odin` saves about 25.
- A big integer is rounded to a float at [bigint.odin:354](src/bigint.odin#L354), [bigint.odin:463](src/bigint.odin#L463) and [const_ops.odin:391](src/const_ops.odin#L391). `dyadic_to_float` is exact and general; the other two can call it once it releases its temporaries, which CTFE's charged allocator needs. Saves about 30.

#### Interface file and private-name checks

The binders [doc.odin:757](src/doc.odin#L757), [doc.odin:771](src/doc.odin#L771) and [doc.odin:781](src/doc.odin#L781) match [private_names.odin:460](src/private_names.odin#L460), [private_names.odin:473](src/private_names.odin#L473) and [private_names.odin:488](src/private_names.odin#L488), except that the doc copy also binds plain parameter names. [doc.odin:1105](src/doc.odin#L1105) `field_shown` and [private_names.odin:417](src/private_names.odin#L417) `field_is_exported` differ only in the `package main` default. Shared binders over `^[dynamic]string` and one field predicate save about 30 lines.

[foreign.odin:21](src/foreign.odin#L21) restates member-then-block-then-file visibility, which `written_is_public` ([check.odin:662](src/check.odin#L662)) can express by nesting; [foreign.odin:49](src/foreign.odin#L49) repeats the `L0332` text of [check.odin:649](src/check.odin#L649). About 15 lines.

#### Diagnostics rollback

[source.odin:660](src/source.odin#L660), [source.odin:766](src/source.odin#L766), [check.odin:3350](src/check.odin#L3350) and `prov_drop_event_diagnostics` each shrink the list and clamp `last_noted_diagnostic`, and the second also undoes `error_count` by hand. A `shrink_diagnostics(c, length)` saves about 5 lines.

#### Configuration declared three times

The same nine settings are fields of `Compilation_Config` ([session.odin:9](src/session.odin#L9)), `Options` ([main.odin:88](src/main.odin#L88)) and `Compiler` ([source.odin:278](src/source.odin#L278)), and are copied at [main.odin:174](src/main.odin#L174), [main.odin:269](src/main.odin#L269) and [session.odin:87](src/session.odin#L87). One embedded `Build_Settings` struct saves about 25 lines. [session.odin:90](src/session.odin#L90) also sets `c.target`, which [semantic.odin:937](src/semantic.odin#L937) overwrites from the same `c.cpu`.

### Provenance and borrow analysis

#### Variadic pack walk

The two-cursor walk over `variadic_order` is at [cfg.odin:2843](src/cfg.odin#L2843), [cfg_provenance.odin:8528](src/cfg_provenance.odin#L8528), [cfg_provenance.odin:10017](src/cfg_provenance.odin#L10017), [provenance_form.odin:112](src/provenance_form.odin#L112), [emit_llvm_stmt.odin:264](src/emit_llvm_stmt.odin#L264) and [emit_llvm_calls.odin:1068](src/emit_llvm_calls.odin#L1068), each with its own type or action per operand. `call_pack_next(call, &cursor) -> (operand: Expr, spread: bool, more: bool)` in `ast.odin` saves about 4 lines per site, 25 in all.

#### Worklists

The forward block queue is written out at [borrow.odin:3470](src/borrow.odin#L3470), [borrow.odin:3585](src/borrow.odin#L3585), [borrow.odin:4789](src/borrow.odin#L4789) and [lifecycle.odin:941](src/lifecycle.odin#L941). They differ only in the join each performs. `Block_Queue`, with init, pop and push-if-absent, saves about 20 lines.

#### Paths

[cfg_provenance.odin:3210](src/cfg_provenance.odin#L3210) `prov_extend`, [cfg_provenance.odin:3218](src/cfg_provenance.odin#L3218) `prov_concat_path` and [borrow.odin:949](src/borrow.odin#L949) `carrier_steps` differ only in the allocator. `path_extend` and `path_concat` beside `proj_*` save about 15 lines. The depth bound 8 is a literal at both [borrow.odin:1223](src/borrow.odin#L1223) and [cfg_provenance.odin:4616](src/cfg_provenance.odin#L4616).

#### Naming a callable value, and reset points

[borrow.odin:2574](src/borrow.odin#L2574) and [global_effects.odin:344](src/global_effects.odin#L344) unwrap a move and switch on identifier, selector and literal in the same way, then classify differently. `named_value_symbol(e) -> Symbol_Id` saves about 10 lines.

[cfg.odin:1092](src/cfg.odin#L1092) and [cfg_provenance.odin:5356](src/cfg_provenance.odin#L5356) build `Reset_Key` by hand, and the assert at the second depends on the first. [cfg.odin:2867](src/cfg.odin#L2867) and [cfg_provenance.odin:9904](src/cfg_provenance.odin#L9904) loop over `proc_param_resets` separately and must agree; a `call_reset_arguments` iterator ties them. Saves about 10 lines.

### LLVM emitter

#### Allocation failure branch

`call void @loke_rt_v1_alloc_failed`, `unreachable` and `e.terminated = true` after a branch are at [emit_llvm_calls.odin:650](src/emit_llvm_calls.odin#L650), [emit_llvm_calls.odin:962](src/emit_llvm_calls.odin#L962), [emit_llvm_cleanup.odin:1073](src/emit_llvm_cleanup.odin#L1073), [emit_llvm_cleanup.odin:1652](src/emit_llvm_cleanup.odin#L1652), [emit_llvm_containers.odin:699](src/emit_llvm_containers.odin#L699), [emit_llvm_containers.odin:800](src/emit_llvm_containers.odin#L800), [emit_llvm_expr.odin:2275](src/emit_llvm_expr.odin#L2275) and [emit_llvm_stmt.odin:176](src/emit_llvm_stmt.odin#L176). Only labels and the test (`icmp eq ptr` or `icmp eq i32`) differ; [emit_llvm_stmt.odin:178](src/emit_llvm_stmt.odin#L178) has no `terminated` write and clears it after the label instead.

Shared form: `alloc_failed_if(e, failed, provider)`, shaped like [emit_llvm_runtime.odin:532](src/emit_llvm_runtime.odin#L532) `panic_if`. Saves about 35 lines.

#### Integer lowering, scalar and lane-wise

[emit_llvm_expr.odin:1583](src/emit_llvm_expr.odin#L1583) and [emit_llvm_simd.odin:146](src/emit_llvm_simd.odin#L146) are the same division, and [emit_llvm_expr.odin:1622](src/emit_llvm_expr.odin#L1622) and [emit_llvm_simd.odin:182](src/emit_llvm_simd.odin#L182) the same defined shift. They differ in constant spelling (`0` or `zeroinitializer`, `-1` or a splat), in the mask type, in reducing to any-lane before `panic_if`, and in the scalar's count-width conversion. A small `Int_Form` with `form_const`, `form_any` and `form_select` merges each pair. Saves about 40 lines, less than the 50 the per-file review estimated, because the shift's conversion stays scalar-only.

#### Declare-once intrinsics

The block at [emit_llvm_calls.odin:201](src/emit_llvm_calls.odin#L201) repeats at [emit_llvm_calls.odin:228](src/emit_llvm_calls.odin#L228), [emit_llvm_calls.odin:254](src/emit_llvm_calls.odin#L254), [emit_llvm_calls.odin:324](src/emit_llvm_calls.odin#L324), [emit_llvm_calls.odin:348](src/emit_llvm_calls.odin#L348), [emit_llvm_calls.odin:358](src/emit_llvm_calls.odin#L358), [emit_llvm_calls.odin:376](src/emit_llvm_calls.odin#L376), [emit_llvm_simd.odin:113](src/emit_llvm_simd.odin#L113) and [emit_llvm_simd.odin:274](src/emit_llvm_simd.odin#L274), keyed on a field misnamed `simd_intrinsics` ([emit_llvm.odin:59](src/emit_llvm.odin#L59)). `declare_intrinsic(e, key, signature)` saves about 25 lines.

#### Counted IR loops

The cursor alloca, compare, branch, step and back-edge are written out at [emit_llvm_runtime.odin:902](src/emit_llvm_runtime.odin#L902), [emit_llvm_calls.odin:475](src/emit_llvm_calls.odin#L475), [emit_llvm_expr.odin:1884](src/emit_llvm_expr.odin#L1884) and [emit_llvm_cleanup.odin:1530](src/emit_llvm_cleanup.odin#L1530). `Counted_Loop` with `open_counted_loop(e, count)` and `close_counted_loop` saves about 8 lines per site, 30 in all. [emit_llvm_iteration.odin:559](src/emit_llvm_iteration.odin#L559) `step_counter` already covers the step and is also hand-written at [emit_llvm_adapters.odin:68](src/emit_llvm_adapters.odin#L68).

#### Small repeated IR shapes

- `loke_rt_v1_map_scan` and cursor store: [emit_llvm_iteration.odin:432](src/emit_llvm_iteration.odin#L432), [emit_llvm_iteration.odin:961](src/emit_llvm_iteration.odin#L961), [emit_llvm_runtime.odin:945](src/emit_llvm_runtime.odin#L945). `emit_map_scan`, about 10.
- Loop targets save and restore: [emit_llvm_stmt.odin:679](src/emit_llvm_stmt.odin#L679), [emit_llvm_iteration.odin:61](src/emit_llvm_iteration.odin#L61). A `Loop_Targets` field on `Emitter`, about 8.

### Small idioms and misplaced code

#### One-line helpers that exist, or should

- `type_of(c, type_underlying(c, x))` at 33 sites is [semantic.odin:1885](src/semantic.odin#L1885) `underlying_info`.
- `symbol_of(k.c, lookup_symbol(k.scope, identifier_of(k.c, ident)))` at 12 sites becomes `ident_symbol(k, ident)`.
- `is_package_selector(k, sel)` replaces `check_receiver`'s test in `check_calls.odin`, [check.odin:1907](src/check.odin#L1907), [check_expr.odin:695](src/check_expr.odin#L695), [check_expr.odin:755](src/check_expr.odin#L755). About 15 lines.
- [box.odin:45](src/box.odin#L45), [simd.odin:15](src/simd.odin#L15) and [iterate.odin:68](src/iterate.odin#L68) differ in one string; [box.odin:34](src/box.odin#L34) and [select.odin:293](src/select.odin#L293) in one enum. `predeclared_callee(k, callee, name)` and `callee_is_builtin` save about 25 lines.
- A parameter's mode with the bounds test is written at 24 sites, for example [check_calls.odin:668](src/check_calls.odin#L668) and [emit_llvm_calls.odin:1423](src/emit_llvm_calls.odin#L1423), beside [semantic.odin:1339](src/semantic.odin#L1339) `proc_parameter_mode`. A `param_mode_at(info, index)` saves no lines but shortens every site.
- `make([]Expr, 1, ...)` plus two assignments at about 15 checker sites, for example [box.odin:226](src/box.odin#L226) and [enums.odin:51](src/enums.odin#L51), becomes `v.bound = bound_exprs(k, e)`, from `check_builtin.odin`. About 30 lines.
- Copy cost then copy classification: `classify_copy_cost` at [lifecycle.odin:589](src/lifecycle.odin#L589), [union.odin:484](src/union.odin#L484), [optional.odin:108](src/optional.odin#L108) and [check_expr.odin:2721](src/check_expr.odin#L2721) follows the same arguments' `classify_copy`. One wrapper, about 8 lines.
- Storage named by duration: [cfg_provenance.odin:5674](src/cfg_provenance.odin#L5674), [cfg_provenance.odin:7350](src/cfg_provenance.odin#L7350), [cfg_provenance.odin:10455](src/cfg_provenance.odin#L10455), `check_via_policy` in [check.odin](src/check.odin), [lifecycle.odin:109](src/lifecycle.odin#L109). About 10 lines.
- Attributes: the string-literal decode at [attributes.odin:454](src/attributes.odin#L454), [attributes.odin:477](src/attributes.odin#L477) and [providers.odin:91](src/providers.odin#L91) becomes `attribute_string_text`; [attributes.odin:373](src/attributes.odin#L373) and [attributes.odin:473](src/attributes.odin#L473) hand-write [check.odin:759](src/check.odin#L759) `find_attribute`. About 25 lines.
- An on-demand constant that names a type: [check.odin:1888](src/check.odin#L1888), [check.odin:2230](src/check.odin#L2230), [iterate.odin:480](src/iterate.odin#L480). About 12 lines.
- Source text by span: [cfg.odin:1913](src/cfg.odin#L1913), [cfg_provenance.odin:489](src/cfg_provenance.odin#L489), [check.odin:2394](src/check.odin#L2394), [capture.odin:93](src/capture.odin#L93). Span key: [attributes.odin:150](src/attributes.odin#L150), [hooks.odin:1106](src/hooks.odin#L1106), [hooks.odin:1138](src/hooks.odin#L1138). `span_text` and `span_key` in `source.odin`.

#### Code in the wrong file

Each move below names a site with its only callers or its stated owner. Moves save no lines; they make the source-code map true.

- Layering: [box.odin:12](src/box.odin#L12) layout is used only by `emit_llvm_box.odin`.

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

### src/ast.odin

Mostly plain node definitions, in good shape: a scan of every struct field found each one still read, so there are no dead fields, and most comments earn their place. The main cost is the 122 lines of accessor switches and a syntax walker that three other files repeat by hand.

**Bugs**

- `BUG-ast-1` **low** [ast.odin:1458](src/ast.odin#L1458) `type_syntax_any_name`: a composite literal's field-name key is walked as if it named something. Scenario: `Cfg :: struct { Vec: int }; Vec :: [size_of(Cfg{Vec = 2})]$T;` fails with L0745 "defined in terms of itself", and renaming the field compiles (run with the built `lokec.exe`). Fix: skip a bare `^Expr_Ident` key as [doc.odin:640](src/doc.odin#L640) does, keeping it when `type_expr` is array syntax, where `[2]int{N = x}` does name `N`. *Not verified.*

**Simplification**

- [ast.odin:694](src/ast.odin#L694), [ast.odin:1074](src/ast.odin#L1074), [ast.odin:1312](src/ast.odin#L1312) `expr_base`, `stmt_base`, `item_base`: put each of the 61 arms on one line, `case ^Expr_Error: return &v.base`, as `hook_name` already does. Layout only, and the exhaustive switch stays. (about 61 lines)
- [ast.odin:1182](src/ast.odin#L1182) `decl_proc`, `decl_proc_literal`, `decl_hook_kind`: each repeats the `.Const`, one-value guard. Add `decl_value(d) -> Expr` for it and use the two-value assertion: `literal, _ := decl_value(d).(^Expr_Proc); return literal`. `decl_proc_literal` then unwraps one `^Expr_Operator` before the same assertion. (about 14 lines)
- [ast.odin:14](src/ast.odin#L14) `Expr_Base.is_const`: looks redundant with `const_value.kind != .Invalid`. All 51 `is_const = true` writes set `const_value` beside them and the one reset ([check_expr.odin:2861](src/check_expr.odin#L2861)) clears both. Not proven: [check_builtin.odin:1425](src/check_builtin.odin#L1425) writes `const_value` alone on a copied call. If it holds, use a small `expr_is_const` helper. (about 50 lines across the checker)
- [ast.odin:905](src/ast.odin#L905) `Foreach_Adapter`: a two-member enum beside the `indexed` bool, written in one place from a local `reversed` bool ([iteration_adapters.odin:40](src/iteration_adapters.odin#L40)). Replace it with `reversed: bool`. (about 6 lines)
- [ast.odin:461](src/ast.odin#L461) `Type_Array.inferred`: true exactly when `length` is nil ([parser.odin:3270](src/parser.odin#L3270) is its one writer), and [check.odin:1956](src/check.odin#L1956) tests both. Use `length == nil`. (about 3 lines)

**Dead code**

- (branch) [ast.odin:1210](src/ast.odin#L1210): the `d == nil` test in `decl_hook_kind`. Every caller has passed an `is_decl` test or dereferences `d` around the call, and the sibling helpers have no such test.
- (branch) [ast.odin:376](src/ast.odin#L376): `index < len(v.field_indices)` in `composite_element_slots`. `slot_ends` is only allocated beside `field_indices` at the same length ([check_expr.odin:3160](src/check_expr.odin#L3160)), so the `slot_ends` test decides alone.

**Data structures and algorithms**

- [ast.odin:9](src/ast.odin#L9) `Expr_Base`: about 220 bytes per node by my reading of the field types (not measured), about 128 of them an embedded `Const_Value` that most nodes never use. It scales with source size times generic instances, as type syntax and clones carry it too. `enum u8` on `Value_Category`, `Immutable_Reason`, and `Resolution_Kind` is cheap; a union payload for `Const_Value` is the larger win. Measure with `perf.ps1` first.

**Near copies**

- [ast.odin:1388](src/ast.odin#L1388), [doc.odin:578](src/doc.odin#L578), [private_names.odin:515](src/private_names.odin#L515), and [select.odin:313](src/select.odin#L313): the same child traversal four times, and they have drifted: only this walker and `select` visit an `or_else` exit, and only `doc` and `private_names` skip field keys, which is BUG-ast-1. Shared form: an `expr_children(e, data, visit) -> bool` here, each walker keeping only its special cases. (about 150 lines)

**Structure and boundaries**

- [ast.odin:375](src/ast.odin#L375), [ast.odin:570](src/ast.odin#L570), [ast.odin:1030](src/ast.odin#L1030): `composite_element_slots` sits above the type it reads, and `hook_name` and `or_else_exit_value` split type definitions. Move them beside the accessors at `expr_base` so the file reads as types, then helpers.

**Comments**

- [ast.odin:382](src/ast.odin#L382): wrong field. `type` is the checker's base field; say "when `type_expr` is nil".
- [ast.odin:257](src/ast.odin#L257): "or -1" is stale. The only writers store a real slot ([check_calls.odin:1201](src/check_calls.odin#L1201), [check_calls.odin:1268](src/check_calls.odin#L1268)) and the default is 0. Say "`variadic_slot`, when `is_variadic`, is the packed parameter."
- [ast.odin:2](src/ast.odin#L2): "decision A1" points nowhere; the only A1 in `comments.md` is about compile-time element budgets. Cite `compiler-architecture.md "One annotated AST"`, here and in `ast_clone.odin:1`.
- [ast.odin:69](src/ast.odin#L69): cut to "Named types are `Expr_Ident` / `Expr_Selector`; a generic application is an `Expr_Call`." The header already gives the reason.
- [ast.odin:652](src/ast.odin#L652): "`fields` for a struct, `variants` for a union. A generic instance clones the record alone, so `attributes` repeats the declaration's list to keep `@(align=N)` reachable."
- [ast.odin:495](src/ast.odin#L495): "`Borrow` is a `self: ^` receiver or a synthesized read-only one, passed by address. It is last because a mode number reaches the type identity key (`typeid_sort_key_walk`)."

### src/attributes.odin

A compact, table-driven validator in good shape overall; the table matches `design.md` apart from which scope an attribute may sit in. That scope rule is spread over four mechanisms, and two silently accepted misuses slip through the gaps.

**Bugs**

- `BUG-attributes-1` **medium** [attributes.odin:295](src/attributes.odin#L295) `validate_impl_attributes`: it validates members with the default `.Global` scope even when called for a local `impl` ([impl.odin:118](src/impl.odin#L118)), so `global_only` never fires and `check_test_procedures` never walks them. Scenario: `main :: proc() { L :: struct {a: int} impl L { @(test) t :: proc() {} } }` compiles and `-test` says "no tests", though design.md "Test procedures" excludes `impl` blocks; `@(public)` and `@(export)` pass the same way. Fix: pass the scope through from `check_local_impl`. *Confirmed: Reproduced: in a local impl, @(test) compiles and -test says 'no tests' (exit 0); @(public) passes; @(export, link_name) passes yet emits no symbol. File-scope impl members and plain locals get L0607. Not in the gaps docs; severity is closer to low.*
- `BUG-attributes-2` **medium** [attributes.odin:72](src/attributes.odin#L72) `attribute_spec`: `@(export)` is accepted on an `impl` member and on a foreign block member, and emits no symbol ([check.odin:503](src/check.odin#L503) skips foreign ones on purpose). Scenario: `impl T { @(export) m :: proc "c" (self: T) -> int {...} }` compiles to `define internal @loke.p.T.m`, while a file-scope `@(export)` gives `define @top_level`, so a C host fails at link. Fix: reject both like `@(test)` and `@(cold)`, or emit the `impl` symbol. *Confirmed: Reproduced with -emit-ll: impl member gives 'define internal @loke.p.T.m', top-level gives 'define @top_level'; a foreign member is accepted silently. design.md "@(export)" promises a symbol. An impl m also clashes falsely with a top-level m (L0634). Medium fits.*

**Simplification**

- [attributes.odin:219](src/attributes.odin#L219) `validate_attribute_list`: replace the rescan at lines 220-227 with `find_attribute(attributes, "link_name")`. This also stops a duplicated `@(link_name)` getting a second L0607 beside its L0609. (about 3 lines)
- [attributes.odin:373](src/attributes.odin#L373) `validate_cpu_dispatch`: the `for`, `continue` and trailing `return`s only find one attribute; open with `attribute, written := find_attribute(d.attributes, "cpu_dispatch")`. Line 396 then decodes that attribute rather than rescanning the list. (about 5 lines)
- [attributes.odin:473](src/attributes.odin#L473) `attribute_string_value`: its loop is `find_attribute` by hand ([check.odin:759](src/check.odin#L759)); call that and decode the result. (about 4 lines)

**Dead code**

- (branch) [attributes.odin:105](src/attributes.odin#L105): the `intrinsic` entry's positions and `global_only` are never read: line 185 reports and continues before lines 192 and 196, and [intrinsic.odin:254](src/intrinsic.odin#L254) only asks whether the name is known. Return `{}, true`.
- (branch) [attributes.odin:445](src/attributes.odin#L445): `sym == nil` cannot happen: all three callers have already resolved the id, and [check.odin:944](src/check.odin#L944) and [hooks.odin:855](src/hooks.odin#L855) write through the symbol first.
- (branch) [attributes.odin:389](src/attributes.odin#L389): `literal.signature != nil` never fails: the parser ([parser.odin:3440](src/parser.odin#L3440)) always sets it, and line 323 on the same literal dereferences it unguarded.
- (branch) [attributes.odin:433](src/attributes.odin#L433): `case .Const` repeats the fallback at line 436, since [check.odin:593](src/check.odin#L593) gives a declaration's symbol `.Const` only when `d.kind == .Const`.

**Data structures and algorithms**

- [attributes.odin:156](src/attributes.odin#L156) `validate_attribute_list`: a temp-allocated map per list, for lists that hold one to three attributes. Use `has_attribute(attributes[:index], name)` for L0609 and `has_attribute(attributes, "export")` at line 219; it needs no allocation and drops the `seen` bookkeeping. (about 2 lines)

**Near copies**

- [attributes.odin:454](src/attributes.odin#L454), [attributes.odin:477](src/attributes.odin#L477) and [providers.odin:91](src/providers.odin#L91): all three check for a string literal and decode it. Share one `attribute_string_text(c, attribute) -> (string, bool)` that replaces `source_provider_target` and serves lines 396 and 464. (about 8 lines)
- [attributes.odin:150](src/attributes.odin#L150), [hooks.odin:1106](src/hooks.odin#L1106) and [hooks.odin:1138](src/hooks.odin#L1138): the same `u64(file) << 32 | u64(lo)` key. Make `generic_hook_key` a shared `span_key(span)`. (about 2 lines)

**Structure and boundaries**

- [attributes.odin:44](src/attributes.odin#L44): scope rules live in `global_only`, the `@(cold)` block (line 312), the first two reasons in `validate_cpu_dispatch` (lines 383-386) and `reject_test_attribute` ([test_procedures.odin:62](src/test_procedures.odin#L62)). Make `global_only` a `bit_set[Attr_Scope]` with a new `.Member`, dropping the `member` parameter. This closes both bugs but moves those L0739 cases to L0607, so expected files change. (about 25 lines)
- [attributes.odin:237](src/attributes.odin#L237) `validate_attributes`: the L0613 root-only rule belongs in `providers.odin`, which already owns the other rules over these attributes (L0657) and `source_provider_slot`; a one-line call remains here.

**Comments**

- [attributes.odin:218](src/attributes.odin#L218): cite the heading, as the project requires: `// design.md "@(link_name=<string>)": it names an exported or foreign symbol.`
- [attributes.odin:332](src/attributes.odin#L332): the last two lines restate the reason strings below; keep `// design.md "@(synchronized)".` (about 2 lines)
- [attributes.odin:368](src/attributes.odin#L368): same pattern; keep `// design.md "@(cpu_dispatch=<string>)".` (about 2 lines)
- [attributes.odin:439](src/attributes.odin#L439): the attribute list repeats the switch below and is badly wrapped; use `// Runs while the signature resolves, so a use in another package already sees these.` (about 2 lines)
- [attributes.odin:471](src/attributes.odin#L471): delete; it restates the signature.

### src/bigint.odin

No bugs found: the rounding, shift, wrap and range logic held up against `core:math/big`. The main gains are one integer-to-float rounding path in place of three, and an early out in `bi_wrap`, which runs on every typed constant operation.

**Simplification**

- [bigint.odin:495](src/bigint.odin#L495) `bi_from_f64_trunc`: merge the subnormal and below-one branches into `if abs(value) < 1 { return bi_zero(c), value == 0 }`
  and replace the mask at lines 520-522 with `exact = math.trunc(value) == value`. (about 15 lines, with the dead branches below)
- [bigint.odin:217](src/bigint.odin#L217) `bi_quo`, `bi_rem`: `bi_quo` becomes `bi_binary(c, a, b, big.int_div)`; `bi_rem` passes `nil` as the quotient to `int_divmod`,
  which documents both results as optional. Neither allocates a result only to release it. (about 8 lines)
- [bigint.odin:283](src/bigint.odin#L283) `bi_fits`: the unsigned case is `return bi_sign(v) >= 0 && magnitude <= bits`; the boundary case is
  `return bi_sign(v) < 0 && big.internal_int_is_power_of_two(&v)`, with no `bi_pow2`, `bi_neg` or release. (about 6 lines)
- [bigint.odin:156](src/bigint.odin#L156) `bi_cmp`, [bigint.odin:275](src/bigint.odin#L275) `bi_magnitude_bits`: storage only serves big's clear-if-uninitialized, but `internal_cmp` and `internal_count_bits`
  read an uninitialized value as zero. Drop the parameter, and from `bi_fits` once it stops allocating. (about 6 lines plus the call sites)
- [bigint.odin:44](src/bigint.odin#L44) `bi_release`: the per-value allocator check already rejects non-evaluator values, so drop the `c` parameter and its guard;
  `for &value in values` replaces `value := value`. (about 4 lines, and every call site shortens)
- [bigint.odin:35](src/bigint.odin#L35) `bi_settle`: `internal_int_grow` already applies the same `max` and the `cap >` test, so the body is
  `if is_eval_storage(c) { big.internal_int_grow(r, r.used, allow_shrink = true) }`. (about 4 lines)

**Dead code**

- (branch) [bigint.odin:525](src/bigint.odin#L525): `!bi_is_zero(magnitude)` is always true here. `unbiased >= 0` means bit 52 is set and the shift is at most 52, so the magnitude is at least 1.
- (branch) [bigint.odin:501](src/bigint.odin#L501): the `ok` result is false only for NaN or infinity. [check_expr.odin:3763](src/check_expr.odin#L3763) range-checks first and `bi_cmp_float` excludes both;
  only [bigint_test.odin:274](src/bigint_test.odin#L274) sees it. Remove `ok`, this branch, and the check at [check_expr.odin:3767](src/check_expr.odin#L3767).
- `bi_eq_i64` ([bigint.odin:163](src/bigint.odin#L163)): its only callers are in `bigint_test.odin` and `emit_llvm_test.odin`, so it exists only for tests. Move it to `bigint_test.odin`, visible to both.

**Data structures and algorithms**

- [bigint.odin:309](src/bigint.odin#L309) `bi_wrap`: builds up to five integers even when `v` is already in range, as it nearly always is. Add `if bi_fits(c, v, bits, signed) { return v }`.
  Every emitted integer constant ([emit_llvm_expr.odin:127](src/emit_llvm_expr.odin#L127)) and CTFE operation benefits; a CTFE typed operation then keeps one charged value, not two, against the 64 MB limit.
- [bigint.odin:66](src/bigint.odin#L66) `bi_clone`: `minimize` is on only for evaluator storage, so `freeze` ([eval.odin:378](src/eval.odin#L378)) gives each integer 32 digits (256 bytes) in the semantic arena.
  Frozen values are immutable, so pass `minimize = true` always; a large CTFE-built table shrinks about tenfold.
- [bigint.odin:451](src/bigint.odin#L451) `decimal_to_float`: builds `10^|exponent|` one multiply at a time, keeping each product in the arena: quadratic time and bytes in the literal's digits (about 90 MB at 20,000).
  Only generated literals get that long, but `big.int_pow_int(&power, 10, abs(exponent))` is square-and-multiply and shorter. (about 2 lines)
- [bigint.odin:515](src/bigint.odin#L515) `bi_from_f64_trunc`, and `decimal_to_float` throughout: temporaries are not passed to `bi_release`, unlike `bi_to_float`, so in evaluator storage they stay charged.
  Each float-to-int conversion in a CTFE loop keeps one extra block; release them.

**Near copies**

- [bigint.odin:354](src/bigint.odin#L354), [bigint.odin:463](src/bigint.odin#L463) and [const_ops.odin:391](src/const_ops.odin#L391): three ways to round a big integer to a float once. `dyadic_to_float` is the general one, so `bi_to_float` becomes
  `dyadic_to_float(c, v, 0, bits)` plus an `is_inf` test, and the division branch passes the quotient with a sticky bit appended. It needs `bi_release` added. (about 30 lines; `keep` also goes)
- [bigint.odin:496](src/bigint.odin#L496) and [const_ops.odin:372](src/const_ops.odin#L372): both split an `f64` into significand and exponent. Make `dyadic_of` package-visible and call `dyadic_of(c, abs(value))` here,
  then shift left or right by its exponent. (about 5 lines)
- [bigint.odin:190](src/bigint.odin#L190) and [bigint.odin:200](src/bigint.odin#L200): `bi_neg` and `bi_not` differ only in the `big` call. Add `bi_unary` beside `bi_binary` and make both one-liners. (about 10 lines)

**Structure and boundaries**

- [bigint.odin:384](src/bigint.odin#L384) `decimal_to_float`: 95 lines doing two jobs. Split at line 430 into scanning the spelling into digits and exponent, then rounding.
- [bigint.odin:351](src/bigint.odin#L351): `bi_to_float` and `decimal_to_float` are float rounding in the integer file, calling `round_float` back in `const_ops.odin`.
  Move both to `const_float.odin`, next to `dyadic_to_float`, and make `bi_release` package-visible. `decimal_to_float` has one caller, [check_expr.odin:3793](src/check_expr.odin#L3793).

**Comments**

- [bigint.odin:274](src/bigint.odin#L274): delete; the name says it and 0 bits for zero follows.
- [bigint.odin:282](src/bigint.odin#L282): delete; it restates the name and parameters.
- [bigint.odin:330](src/bigint.odin#L330): delete; it restates the signature.
- [bigint.odin:494](src/bigint.odin#L494): end at "fraction was dropped."; the `1.0` and `1.5` examples add nothing.

### src/bootstrap.odin

Small and sound, with no behavior bugs found. What remains is shared with sibling files.

**Near copies**

- [bootstrap.odin:121](src/bootstrap.odin#L121), [check_expr.odin:2935](src/check_expr.odin#L2935), [union.odin:344](src/union.odin#L344) and [zero.odin:46](src/zero.odin#L46): the last three spell `instance_of != INVALID_SYMBOL && instance_of == shared_symbol`. A small `type_info_is_shared(c, info)` here would give them one form.
- [bootstrap.odin:58](src/bootstrap.odin#L58), [atomics.odin:25](src/atomics.odin#L25) and [check_builtin.odin:1492](src/check_builtin.odin#L1492): only this site has `base:runtime` in hand; the others scan `c.packages` for its key on a lookup. Recording the id in `load_runtime_bootstrap` (`packages.odin:98`) would remove both loops.

### src/borrow.odin (part 1 of 3)

Lines 1-2376 hold the shared vocabulary (roots, paths, carrier shapes, region sets, summaries) and the summary pass. The logic is careful but repeats small patterns, and two walks over types have no bound; three bugs were reproduced with the built `lokec.exe`.

**Near copies**

- [borrow.odin:949](src/borrow.odin#L949), [borrow.odin:1266](src/borrow.odin#L1266) and [cfg_provenance.odin:3218](src/cfg_provenance.odin#L3218), plus lines 1245 and 1255: "copy a path and add steps" with different allocators. One `path_concat(prefix, extra, allocator)` replaces them. (about 15 lines)

### src/borrow.odin (part 2 of 3)

The solvers and the view-start fixed point are carefully reasoned, but this stretch holds three separate subsystems, repeats its worklist, block-entry and bit-scan shapes, and carries long prose comments. One real soundness bug sits in the callback substitution, and no procedure is dead.

**Near copies**

- [borrow.odin:2573](src/borrow.odin#L2573) and [global_effects.odin:343](src/global_effects.odin#L343) `passed_values`/`effect_value`: same move unwrap and ident/selector/literal switch to a symbol. Share `named_value_symbol(e: Expr) -> Symbol_Id` from global_effects.odin; each keeps its own classification. (about 10 lines)
- [borrow.odin:3470](src/borrow.odin#L3470), [borrow.odin:3583](src/borrow.odin#L3583), [borrow.odin:4789](src/borrow.odin#L4789) and [lifecycle.odin:941](src/lifecycle.odin#L941): the same forward worklist setup and successor push. A small `Block_Queue` with `block_queue_make` and `block_queue_push_succs` serves all four. (about 20 lines)

### src/borrow.odin (part 3 of 3)

The checks are sound in intent and well cited, but overlapping place loans make `check_place_loans` cubic, the per-event liveness snapshots make memory quadratic in a long body, and task diagnostics drop the precision the spec requires them to name. The reporting half repeats its loan-scan and message shapes, and the task code is split across sections.

**Near copies**

- [borrow.odin:4931](src/borrow.odin#L4931): the backward worklist of `solve_loan_liveness` repeats the setup and push that the part 2 forward `Block_Queue` finding covers; give that type a predecessor push too. (about 6 lines)

### src/box.odin

Small and readable, with no dead code and no algorithmic concerns. The untyped-payload path in `check_box_builtin` is wrong in two reproduced ways, including a compiler crash, and most of the shortening available is shared with sibling files.

**Bugs**

- `BUG-box-1` **high** [box.odin:148](src/box.odin#L148) `check_box_builtin`: `default_type` of untyped `nil` is `INVALID_TYPE`, and this returns with no diagnostic. Scenario: `box(nil);`, `try_box(nil)`, `unsafe.new(nil)` or `b: Box(^int) = box(nil)` panics at emit_llvm_box.odin:15, exit 132. Fix: report as check_builtin.odin:258 does for `nil`, or materialize to the expected payload. *Confirmed: Reproduced: box(nil), try_box(nil), unsafe.new(nil) and b: Box(^int) = box(nil) each panic at emit_llvm_box.odin:15, exit 132, while x := nil gives L0310. Not recorded in the docs. An internal crash with no output, on unusual code: medium rather than high.*
- `BUG-box-2` **medium** [box.odin:146](src/box.odin#L146) `check_box_builtin`: an untyped payload always takes its default type, ignoring `payload_expected`, though an initialization would use it. Scenario: `b: Box(u8) = box(1)`, `Box(f32) = box(1.5)` and `Box(string_view) = box("abc")` get L0310. Fix: materialize to `payload_expected` when set, as enums.odin:41 does. *Confirmed: Reproduced L0310 on b: Box(u8) = box(1), while box({1, 2}) and box(.a) take the payload type; no spec text or decision covers it. Severity is low: a clean error, box(u8(1)) works, and shared(1) and id(1) reject alike; "as an initialization does" defines only ownership.*
- `BUG-box-4` **low** [box.odin:138](src/box.odin#L138) `check_box_builtin`: only `box` passes an expected payload type, though design.md "Owned values" says `try_box` takes the same arguments. Scenario: `r: Result(Box(N), Allocator_Error) = try_box({1, 2})` gets L0376 where `box({1, 2})` compiles. Fix: read the box from the success variant through `fallible_of`. *Not verified.*
- `BUG-box-5` **low** [box.odin:153](src/box.odin#L153) `check_box_builtin`: diagnostics name a box when the call is `unsafe.new`. Scenario: `unsafe.new(int)` says "a box holds a runtime value", and `unsafe.new(m)` with a move-only `m` says "this box cannot copy it" (the `.Box` site, line 156). Fix: word line 153 with `ident.name` and add a `Copy_Site` for it. *Not verified.*

**Simplification**

- [box.odin:34](src/box.odin#L34) `box_callee`: its only caller is line 67, which already holds the lookup in `named`. Delete it and test `sym := symbol_of(k.c, named)` in that case. (about 8 lines)
- [box.odin:137](src/box.odin#L137) `check_box_builtin`: `box_element` already answers `INVALID_TYPE` for a non-box, so write `payload_expected := kind == .Box_New ? box_element(k.c, expected) : INVALID_TYPE`. (about 3 lines)
- [box.odin:180](src/box.odin#L180) `check_box_builtin`: this interns an unused `[^]T` for every boxed type. Use `is_box := base == .Box_New`, `made := is_box ? box_of(k.c, payload) : c_pointer_to(k.c, payload)`, `contribute_lifecycle_members(k, is_box ? made : payload)`. (about 3 lines)
- [box.odin:124](src/box.odin#L124) and [box.odin:215](src/box.odin#L215): `check_call` sets `v.value_category = .Value` at check_calls.odin:36 before either procedure can run, and both builtin dispatches are after it. Delete both assignments. (2 lines)

**Near copies**

- [box.odin:45](src/box.odin#L45), [simd.odin:15](src/simd.odin#L15) and [iterate.odin:68](src/iterate.odin#L68): `box_type_callee`, `simd_callee` and `range_callee` differ only in the name. Shared form: `predeclared_type_callee(k, callee, "Box")`. (about 12 lines)
- [box.odin:164](src/box.odin#L164) and [check_builtin.odin:586](src/check_builtin.odin#L586): the same optional allocator check with the same L0490 text. Shared form: `check_allocator_argument(k, e) -> bool`. (about 8 lines)
- [box.odin:226](src/box.odin#L226): the three-line one-element `v.bound` also appears at lifecycle.odin:38, 81 and reflect.odin:900. Shared form: `bound_exprs(k, e)`, from `check_builtin.odin`. (about 12 lines)

**Structure and boundaries**

- [box.odin:12](src/box.odin#L12): `box_payload_offset`, `box_block_size` and `box_block_align` are called only from emit_llvm_box.odin, so the layout belongs there, beside the only code that reads the header.
- [box.odin:1](src/box.odin#L1): the `box.odin` row in compiler-architecture.md "Source-code map" lists "dereference projections", and nothing here does that. Correct the row; it also needs "shared allocation layout" changed if the layout moves.

**Comments**

- [box.odin:3](src/box.odin#L3): lines 3-7 restate design.md "Owned values". Delete them, keeping the line 1 citation; lines 10-11 already describe the allocation.
- [box.odin:11](src/box.odin#L11): delete "Shared by the checker's size questions and the emitter."; no checker code calls these procedures.
- [box.odin:53](src/box.odin#L53): shorten to `// design.md "Owned values", "Shared ownership": reports `box(T)`, `shared(T)`, or `weak(T)` written for the handle type, in type position or with a type argument. `weak` names nothing.` (about 1 line)
- [box.odin:116](src/box.odin#L116): the first sentence restates the signature, and the second repeats the spec. Replace lines 116-118 with `// design.md "Owned values": the value is taken as an initialization takes it.` (about 2 lines)
- [box.odin:199](src/box.odin#L199): repeats the design.md paragraph on `unbox`. Replace lines 199-201 with `// design.md "Owned values": `move(b).unbox()`.` (about 2 lines)

### src/capture.odin

The lowering design is sound and its comments mostly explain why, but the record's source-text name and the direct scope insert of placeholders each skip a check that ordinary declarations get. `lower_capture_literal` is also one 140-line procedure with clear seams. All four bugs were reproduced with the `lokec.exe` built from this commit.

**Bugs**

- `BUG-capture-1` **medium** [capture.odin:94](src/capture.odin#L94) `lower_capture_literal`: the record is named by its header text, and `declare_all` shadow-checks it against the enclosing lowering scope. Scenario: `proc() capture(x) { g := proc() capture(x) {...}; }` reports L0305 "`proc() capture(x)` shadows an outer declaration" on a valid program. Fix: exempt the record from the shadow check, as `$` names are at [check.odin:572](src/check.odin#L572). *Confirmed: Reproduced: nested `proc() capture(x)` inside the same header gives L0305 naming the header text. Adding one space to the inner header (or writing `capture(y = x)`) compiles and prints 1, so the program is valid. Spacing should not matter; medium is fair.*
- `BUG-capture-2` **medium** [capture.odin:85](src/capture.odin#L85) `lower_capture_literal`: the placeholder goes straight into `k.scope.names`, skipping `reject_reserved_name`, against design.md "Predeclared names". Scenario: `capture(true = 1) { fmt.println(true); }` compiles and prints 1; `capture(nil = 7)` too; `true := 1` and `proc(true: int)` give L0700. Fix: call `reject_reserved_name` in `capture_literal_shape_ok`. *Confirmed: Reproduced: capture(true = 1) prints 1, capture(nil = 7) prints 7, capture(false = 9) prints 9, and `x: bool = true` in the body gives L0310; true := 1 and proc(true: int) give L0700. Not recorded in known-gaps, open-questions or comments.*
- `BUG-capture-3` **low** [capture.odin:85](src/capture.odin#L85) `lower_capture_literal`: a capture named `_` becomes a real binding, against design.md "Identifiers" (`_` creates none). Scenario: `capture(_ = 41) { fmt.println(_ + 1); }` prints 42 instead of L0314, and `_ = 3;` in that body gets L0358 instead of discarding. Fix: reject `_` as a capture name in `capture_literal_shape_ok`. *Not verified.*
- `BUG-capture-4` **low** [capture.odin:62](src/capture.odin#L62) `lower_capture_literal`: `default_type` of untyped nil is INVALID_TYPE, which goes unnoticed into the alias. Scenario: `capture(n = nil)` reports L0306 "unknown type `n`", where `x := nil` reports L0310 "`nil` has no type to infer here". Fix: report L0310 when `default_type` is INVALID_TYPE and set `checked = false`. *Not verified.*

**Simplification**

- [capture.odin:76](src/capture.odin#L76) `lower_capture_literal`: `capture_call_method` only clones syntax and needs just `fields`, so call it once they are built; one loop then creates each placeholder and registers it with `method`, and the `placeholders` slice and the loop at 125-127 go. (about 4 lines)
- [capture.odin:99](src/capture.odin#L99) `lower_capture_literal`: the field parts of the loops at 77 and 99 walk the same entries in the same scope; allocate `record` first and fill `fields`, the alias and `record.fields` in one loop. (about 3 lines)
- [capture.odin:93](src/capture.odin#L93) `lower_capture_literal`: drop `strings.clone`; `Name.text` from the parser is already a slice of the same source text ([parser.odin:200](src/parser.odin#L200)). (under 1 line)
- [capture.odin:232](src/capture.odin#L232) `capture_call_method`: the save and restore is unneeded, since checking never runs inside a clone and `capture_rewrite` is nil here; assign `&rewrite`, clone, assign nil. The map at 228 only lives for that clone, so it can use `context.temp_allocator`. (about 1 line)

**Dead code**

- (branch) [capture.odin:178](src/capture.odin#L178): `literal.signature != nil` here and at line 196 is always true, because `proc_shape_ok` ([check.odin:2747](src/check.odin#L2747)) returns false for a nil signature first at line 28. Line 219 already relies on it.
- (branch) [capture.odin:281](src/capture.odin#L281): `outer` is a key of `capture_placeholders`, created by `new_symbol` at line 84, so `symbol_of` is never nil and the guard can go.
- (branch) [capture.odin:227](src/capture.odin#L227): `Capture_Rewrite.receiver` is always `intern_identifier(CAPTURE_RECEIVER)`, as is the `receiver_id` parameter of `capture_field_place` from both callers; intern it inside `capture_field_place` and drop the field and parameter.

**Data structures and algorithms**

- [capture.odin:186](src/capture.odin#L186) `capture_literal_shape_ok`: `seen` stores a span that nothing reads; `map[Identifier_Id]bool` with `id in seen` at lines 189 and 199 states the set it is.
- [capture.odin:270](src/capture.odin#L270) `capture_field_visible`: it probes `capture_records` before the cheap `sym.kind` test, for each member visibility check; test the kind first at no extra length. [check_expr.odin:506](src/check_expr.odin#L506) likewise probes `capture_placeholders` once per checked identifier; a flag on `Symbol` would avoid that, though one hash per name is unmeasured and likely small.

**Near copies**

- [capture.odin:110](src/capture.odin#L110), [capture.odin:140](src/capture.odin#L140) and [parallel.odin:736](src/parallel.odin#L736) `synth_const`, with `.Var` variants at [parallel.odin:724](src/parallel.odin#L724), [parallel.odin:182](src/parallel.odin#L182) and [check.odin:3897](src/check.odin#L3897): each allocates a one-name, one-value `Decl`. A shared `single_declaration(c, kind, name, value, span)` makes each call one line. (about 10 lines here)
- [check.odin:572](src/check.odin#L572), [iterate.odin:1071](src/iterate.odin#L1071) and [optional.odin:611](src/optional.odin#L611): the same lookup, L0305 report and `note_shadowed_capture` call. A `report_local_shadow(k, scope, id, span, text)` replaces all three and absorbs `note_shadowed_capture` at line 279; only check.odin adds its `$` test before the call.

**Structure and boundaries**

- [capture.odin:21](src/capture.odin#L21) `lower_capture_literal`: four jobs in 140 lines. Natural seams: the entry values and their types (36-66), the fields and placeholders (75-87), declaring the record (92-134), and declaring `call` (137-153). The procedure then reads as those four calls.
- [capture.odin:78](src/capture.odin#L78): the `"capture$"` field prefix is spelled here and again in `trim_prefix` at [impl.odin:522](src/impl.odin#L522); make it a constant beside `CAPTURE_RECEIVER`, so the two cannot drift.

**Comments**

- [capture.odin:122](src/capture.odin#L122): delete; `capture_field_visible`'s comment at line 267 says it.
- [capture.odin:136](src/capture.odin#L136): delete; it repeats the comment on `capture_call_method` at line 213.
- [capture.odin:244](src/capture.odin#L244): shorter and more specific: "What a reserved capture name reads where the rewrite left it alone, a map literal's bare key; nil for any other name."
- [capture.odin:255](src/capture.odin#L255): delete; it restates the type's name and the comment on `capture_placeholders` at [source.odin:219](src/source.odin#L219).

### src/cfg.odin

What remains are near copies whose helper would span other files.

**Near copies**

- [cfg.odin:1092](src/cfg.odin#L1092), [1116](src/cfg.odin#L1116), [1253](src/cfg.odin#L1253), [1370](src/cfg.odin#L1370), [2881](src/cfg.odin#L2881) and [cfg_provenance.odin:5356](src/cfg_provenance.odin#L5356): build a `Reset_Key`, register in lifecycle, look up and assert in provenance. `reset_point(graph, node, id, span) -> (live, ok)` saves about 15 lines.
- [cfg.odin:2863](src/cfg.odin#L2863) and [cfg_provenance.odin:9899](src/cfg_provenance.odin#L9899): the same loop over `proc_param_resets`, one as a test and one acting. They must agree, or the assert in `prov_reset` fires; an index-yielding helper would tie them together.
- [cfg.odin:2843](src/cfg.odin#L2843), [cfg_provenance.odin:8528](src/cfg_provenance.odin#L8528), [cfg_provenance.odin:10017](src/cfg_provenance.odin#L10017): the same two-cursor merge of `variadic_order`. `call_pack_operands(v, allocator) -> []Expr` in written order saves about 4 lines per site.
- [cfg.odin:1913](src/cfg.odin#L1913), [cfg_provenance.odin:489](src/cfg_provenance.odin#L489), [parallel.odin:81](src/parallel.odin#L81): slicing a span out of `sources`; a span form in `source.odin` replaces them.

### src/cfg_provenance.odin (part 1 of 4)

This part is careful and I found no bugs; the reaching-places walk (Tarjan with epochs) held up when traced by hand, and every top-level declaration has a user. The cost is bulk: repeated small path and slot idioms, a few quadratic list builds, and a place-offset engine that deserves its own file.

**Near copies**

- [cfg_provenance.odin:489](src/cfg_provenance.odin#L489): span text is hand-indexed here, and at [parallel.odin:81](src/parallel.odin#L81), [cfg.odin:1913](src/cfg.odin#L1913) and [check.odin:2394](src/check.odin#L2394). A `span_text(c, span)` in `source.odin` is the shared form.

### src/cfg_provenance.odin (part 2 of 4)

This range holds reborrows, parameter loans and caller slots, read-only views, and the allocator-region section; the logic is careful but repeats its predicates and region idioms, and 384 of its 2770 lines are comments, many of them long restatements of the spec.

**Simplification**

- [cfg_provenance.odin:4616](src/cfg_provenance.odin#L4616): the literal depth 8 here and at [:4647](src/cfg_provenance.odin#L4647), [:5207](src/cfg_provenance.odin#L5207) and [borrow.odin:1222](src/borrow.odin#L1222) is one limit on one shape walk; name it beside `CARRIER_DEPTH`.

### src/cfg_provenance.odin (part 3 of 4)

Region stores, written aliases, place walking, and the statement and call hooks: the comments mostly earn their place, but `prov_assign`, `prov_call` and `prov_declare_region` do too many jobs and hold most of the local repetition.

**Near copies**

- [cfg_provenance.odin:5674](src/cfg_provenance.odin#L5674), [cfg_provenance.odin:7350](src/cfg_provenance.odin#L7350), [cfg_provenance.odin:10455](src/cfg_provenance.odin#L10455), `check_via_policy` in [check.odin](src/check.odin) and [lifecycle.odin:109](src/lifecycle.odin#L109): each names the storage of a duration by hand. One `storage_phrase(duration)` covers them.

### src/cfg_provenance.odin (part 4 of 4)

The logic holds up and every declaration here has a caller in `src/`, with none existing only for tests; I found no bug I could demonstrate. The cost is near copies in call-result and retention code, a few never-varying parameters, and about 2,600 lines with no section header covering nine separate concerns.

**Near copies**

- [cfg_provenance.odin:8528](src/cfg_provenance.odin#L8528), [cfg_provenance.odin:10017](src/cfg_provenance.odin#L10017), [cfg.odin:2843](src/cfg.odin#L2843), [provenance_form.odin:112](src/provenance_form.odin#L112): the same two-cursor walk of `variadic_order`. A `call_next_variadic(call, is_spread, &next_element, &next_spread)` beside `call_packs` covers these. (about 12 lines)

### src/check.odin (part 1 of 2)

What remains here waits on a helper shared across files.

**Near copies**

- [check.odin:1888](src/check.odin#L1888), [check.odin:2230](src/check.odin#L2230), [iterate.odin:481](src/iterate.odin#L481): check a constant on demand, then read the type it names. Share `const_type_value(k, id, subject) -> Type_Id`. (about 8 lines)

### src/check.odin (part 2 of 2)

What remains here waits on helpers shared across files.

**Near copies**

- [check.odin:3888](src/check.odin#L3888) and [parallel.odin:652](src/parallel.odin#L652): `lowered_name`, `lowered_deref` and `lowered_temporary` match `synth_ident`, `synth_deref` and `synth_var`, with `synth_const` and `hidden_declaration` as further `Decl` copies. Use the package-visible `synth_ident` and `synth_deref`, and promote the rest. (about 25 lines)
- [check.odin:4796](src/check.odin#L4796): the one-argument call repeats [optional.odin:272](src/optional.odin#L272). Share `synth_call`. (about 5 lines)
- [check.odin:4376](src/check.odin#L4376) and [optional.odin:574](src/optional.odin#L574): the same per-case flow merge and result; `flow_either(&flow, case_flow)` also serves `check_if` (4243). [check.odin:3138](src/check.odin#L3138) and [expand.odin:36](src/expand.odin#L36) share the sequential merge as `flow_then`. (about 15 lines)

**Structure and boundaries**

- [check.odin:3349](src/check.odin#L3349): `check_partial_statement` filters `diagnostics` and clamps `last_noted_diagnostic` directly, as `prov_drop_event_diagnostics` does. Give `source.odin`, which owns `truncate_diagnostics`, a drop-by-predicate helper for both.

### src/check_builtin.odin

**Near copies**

- [check_builtin.odin:175](src/check_builtin.odin#L175), [text.odin:241](src/text.odin#L241) and [format.odin:258](src/format.odin#L258): the same loop over fixed target types with `check_argument_value`. Shared form: `bind_typed_arguments(k, v, targets) -> bool`, which sets `v.bound`.
- [check_builtin.odin:586](src/check_builtin.odin#L586) and [box.odin:164](src/box.odin#L164), with a variant at line 570: check against `TYPE_ALLOCATOR` and report "an allocator argument is an `Allocator`". Shared form: `check_allocator_argument(k, e) -> bool`; line 570 keeps its own wording only if tests pin it.
- [check_builtin.odin:1378](src/check_builtin.odin#L1378), [check_builtin.odin:1246](src/check_builtin.odin#L1246) and [reflect.odin:308](src/reflect.odin#L308): `new(Const_Aggregate)` plus two field writes, in 15 sites across 9 files. Shared form: `aggregate_const(c, type, elements)`; it would also settle why only some sites set `type_value`.

### src/check_calls.odin

The file is readable and its comments mostly say why, and every declaration has a caller. Its weak spot is that the direct, method, and group call paths each finish a call by hand with different subsets of the same steps, which is the root of the one serious bug; the bugs below were reproduced with the `lokec.exe` built from this commit.

**Near copies**

- [check_calls.odin:668](src/check_calls.odin#L668) and [semantic.odin:1341](src/semantic.odin#L1341): `index < len(info.param_modes) ? ... : Param_Mode.Value` recurs at lines 826 and 899 and about fifteen times across the emitter, `parallel.odin`, and others. A `parameter_mode(info, index)` beside `proc_parameter_mode`, which then calls it, replaces them all.
- [check_calls.odin:78](src/check_calls.odin#L78) and [iterate.odin:68](src/iterate.odin#L68): `range_callee`, [box.odin:45](src/box.odin#L45) `box_type_callee`, and [simd.odin:15](src/simd.odin#L15) `simd_callee` differ only in one string. `unshadowed_callee(k, callee, "Range")` replaces the three. (about 15 lines)

### src/check_expr.odin (part 1 of 2)

What remains here belongs to the groups under "Findings that span files".

**Near copies**

- [check_expr.odin:1112](src/check_expr.odin#L1112) and [overload.odin:1009](src/overload.odin#L1009): `implicit_pointer_deref` and `dereference_argument` build the same node. Make the first package-visible and have the second call it with `info.element, info.mutable`. (about 8 lines)
- [check_expr.odin:693](src/check_expr.odin#L693), [check_expr.odin:753](src/check_expr.odin#L753) and [check.odin:1905](src/check.odin#L1905): the same "operand is an identifier naming a package alias" test. Use a `selector_package_alias(k, v) -> (ident, alias, ok)`. (about 6 lines)
- [check_expr.odin:2057](src/check_expr.odin#L2057) and [eval.odin:852](src/eval.odin#L852): scalar unary folding is the same switch and the same overflow and wrap step, differing in allocator, failure reporting, and the float's decimal text. Move it to `const_ops.odin` as `fold_unary`. (about 20 lines)

### src/check_expr.odin (part 2 of 2)

What remains here belongs to the groups under "Findings that span files".

**Near copies**

- [check_expr.odin:3332](src/check_expr.odin#L3332), [3345](src/check_expr.odin#L3345), [3437](src/check_expr.odin#L3437), [3474](src/check_expr.odin#L3474), [3837](src/check_expr.odin#L3837) and [reflect.odin:307](src/reflect.odin#L307): each wraps a type and elements in a `Const_Aggregate`. Move `aggregate_const` to `const_ops.odin` with an allocator argument and use it here, in [check_builtin.odin:1378](src/check_builtin.odin#L1378) and [const_ops.odin:884](src/const_ops.odin#L884); first confirm its `type_value` is harmless. (about 15 lines)
- [check_expr.odin:2721](src/check_expr.odin#L2721), [lifecycle.odin:257](src/lifecycle.odin#L257), [lifecycle.odin:589](src/lifecycle.odin#L589), [optional.odin:108](src/optional.odin#L108): `classify_copy_cost` then `classify_copy` with the same arguments. A wrapper returning `classify_copy`'s result removes one line per pair.

### src/const_ops.odin

The exact float algorithms hold up on reading. What remains is around the file: the unary fold, bigint-to-float rounding, and constant equality each exist more than once.

**Near copies**

- [const_ops.odin:664](src/const_ops.odin#L664), [check_expr.odin:2059](src/check_expr.odin#L2059), and [eval.odin:854](src/eval.odin#L854): the unary `+ - ~ !` fold with its overflow check and wrap is written three times, despite this file's promise that both sides "fold identically". Add `fold_unary(c, op, span, value, type, allocator) -> (Const_Value, bool)` here, including the checker's literal-text sign handling. (about 40 lines)
- [const_ops.odin:391](src/const_ops.odin#L391) and [bigint.odin:354](src/bigint.odin#L354): `dyadic_to_float` and `bi_to_float` both round a big integer to a float, one exactly, one via a sticky bit. `bi_to_float` becomes `dyadic_to_float(c, v, 0, bits)` plus its `is_inf` test; move the helper to `bigint.odin`, where `bi_release` is visible. (about 20 lines)
- [const_ops.odin:884](src/const_ops.odin#L884) and [reflect.odin:307](src/reflect.odin#L307): 15 sites across `src/` hand-build a `Const_Aggregate`, and `reflect.odin` already has a file-private `aggregate_const`. Promote it to the constructors at line 53, with an allocator parameter. (about 3 lines per site)

### src/container.odin

**Near copies**

- `require_nested_map_key_policies_walk` in [hash.odin](src/hash.odin) and [semantic.odin:2224](src/semantic.odin#L2224): this walk and `type_contains_invalid` enumerate the same components by kind; the latter is exhaustive on purpose and handles `.Box`. A shared `type_components` would serve both.

### src/doc.odin

What remains here belongs to the groups under "Findings that span files".

**Near copies**

- [doc.odin:578](src/doc.odin#L578) and [private_names.odin:515](src/private_names.odin#L515) and [ast.odin:1388](src/ast.odin#L1388): the same descent through index, call, unary, binary, and pointer, array, and map syntax, three times.
  A child-visiting helper in `ast.odin` leaves `api_refs` only its Ident, Selector, Composite, Proc, Proc_Group, Record, Enum, and Interface cases. (about 60 lines here)
- [doc.odin:781](src/doc.odin#L781), [771](src/doc.odin#L771), [757](src/doc.odin#L757) and [private_names.odin:488](src/private_names.odin#L488), [473](src/private_names.odin#L473), [460](src/private_names.odin#L460): `$`-name and generic binders are identical, and the signature binder differs only in binding plain parameter names.
  Share them over `^[dynamic]string`; the two rules on plain names need one decision. (about 20 lines)
- [doc.odin:1105](src/doc.odin#L1105) and [private_names.odin:417](src/private_names.odin#L417): `field_shown` and `field_is_exported` differ only in the `package main` default, a case `private_names` never reads.
  Share one predicate, which also serves the padding test repeated at 1140. (about 10 lines)

### src/emit_llvm_calls.odin

Only near copies shared with other emitter files remain.

**Near copies**

- [emit_llvm_calls.odin:201](src/emit_llvm_calls.odin#L201) and [emit_llvm_simd.odin:113](src/emit_llvm_simd.odin#L113): the four-line "declare once" block appears at 201, 227, 254, 324, 348, 358, 376 and simd:274. Share `declare_intrinsic(e, key, text)`, and rename `simd_intrinsics`, which now holds every intrinsic. (about 20 lines)
- [emit_llvm_calls.odin:647](src/emit_llvm_calls.odin#L647): branch on failure, call `loke_rt_v1_alloc_failed`, `unreachable`, continue. Also emit_llvm_containers.odin:798, emit_llvm_expr.odin:2273, emit_llvm_stmt.odin:174. Share `emit_alloc_policy_if(e, failed, allocator)`. (about 15 lines)

### src/emit_llvm_cleanup.odin

What remains here belongs to the groups under "Findings that span files".

**Near copies**

- [emit_llvm_cleanup.odin:1073](src/emit_llvm_cleanup.odin#L1073) and [:1652](src/emit_llvm_cleanup.odin#L1652), plus sites in `emit_llvm_calls`, `_containers`, `_expr` and `_stmt`: eight copies of the `alloc_failed` call and `unreachable`, most also setting `terminated`. Add `emit_alloc_failed(e, allocator)`. (about 13 lines)

### src/emit_llvm_containers.odin

What remains is the allocation failure branch shared with other files.

**Near copies**

- [emit_llvm_containers.odin:699](src/emit_llvm_containers.odin#L699), [emit_llvm_containers.odin:800](src/emit_llvm_containers.odin#L800), [emit_llvm_expr.odin:2275](src/emit_llvm_expr.odin#L2275), [emit_llvm_calls.odin:650](src/emit_llvm_calls.odin#L650), [emit_llvm_cleanup.odin:1652](src/emit_llvm_cleanup.odin#L1652) and [emit_llvm_stmt.odin:176](src/emit_llvm_stmt.odin#L176): the `alloc_failed` call, `unreachable`, `terminated`.
  Shared as `emit_alloc_failed(e, provider)`; `emit_alloc_check` at `emit_llvm_expr.odin:2268` also matches `emit_container_policy_failure` once the provider is loaded.

### src/emit_llvm_expr.odin

What remains is the allocation-failure branch it shares with the other emitter files.

**Near copies**

- [emit_llvm_expr.odin:2272](src/emit_llvm_expr.odin#L2272) and [emit_llvm_calls.odin:650](src/emit_llvm_calls.odin#L650), plus [emit_llvm_containers.odin:800](src/emit_llvm_containers.odin#L800), [emit_llvm_stmt.odin:176](src/emit_llvm_stmt.odin#L176), [emit_llvm_cleanup.odin:1073](src/emit_llvm_cleanup.odin#L1073): the same branch to `alloc_failed`. Share `emit_alloc_failed_if(e, failed, provider, label)`. (about 25 lines overall)

### src/emit_llvm_iteration.odin

What remains is two near copies that belong to the cross-file groups.

**Near copies**

- [emit_llvm_iteration.odin:432](src/emit_llvm_iteration.odin#L432), [961](src/emit_llvm_iteration.odin#L961) and [emit_llvm_runtime.odin:945](src/emit_llvm_runtime.odin#L945): the `loke_rt_v1_map_scan` call plus cursor store are identical; share `emit_map_scan(e, table, ops, cursor, cursor_slot, key_out, value_out) -> string`. (about 8 lines)
- [emit_llvm_iteration.odin:61](src/emit_llvm_iteration.odin#L61) and [emit_llvm_stmt.odin:679](src/emit_llvm_stmt.odin#L679): the same six-line save and restore of four loop targets; group them as one `Loop_Targets` field on `Emitter`, then `outer := e.loop; defer e.loop = outer`. (about 8 lines)

### src/emit_llvm_runtime.odin

What remains is the cursor loop shared with three other files; `emit_format_sequence` is now in `emit_llvm_format.odin`.

**Near copies**

- [emit_llvm_runtime.odin:902](src/emit_llvm_runtime.odin#L902), [emit_llvm_calls.odin:477](src/emit_llvm_calls.odin#L477), [emit_llvm_expr.odin:1886](src/emit_llvm_expr.odin#L1886) and [emit_llvm_cleanup.odin:1532](src/emit_llvm_cleanup.odin#L1532): the same cursor loop (zero, head, compare, body, add, store, branch); `open_counted_loop`/`close_counted_loop` would serve all four, with the label prefix as a parameter. (about 10 lines per site)

### src/emit_llvm_simd.odin

Correct and compact: probes of masks, splats, shifts, and array casts at `-opt=none` and `-opt=speed` found no bug. Its main weight is integer lowering that repeats the scalar procedures in `emit_llvm_expr.odin` almost line for line.

**Simplification**

- [emit_llvm_simd.odin:63](src/emit_llvm_simd.odin#L63) `emit_simd_binary_values`: use one switch for the special cases, then `arith_mnemonic(op)` from `emit_llvm_expr.odin:1505` (drop its file privacy) instead of retyping the table at lines 77 and 85-93. `&~` falls through as `.Amp`; float `%` still reaches the `""` failure. (about 12 lines)
- [emit_llvm_simd.odin:11](src/emit_llvm_simd.odin#L11) `simd_operand`: the checker admits only one vector type or a lane, so the underlying-type comparison is just `type_is_simd(e.c, written)`, the test line 41 already uses. (about 1 line, and a simpler condition)
- [emit_llvm_simd.odin:127](src/emit_llvm_simd.odin#L127) `emit_simd_compare`, `emit_simd_divrem`, `emit_simd_shift`: pass the `llvm` the caller already computed in place of `vector`, as `emit_simd_checked` and `simd_select` do; `vector` is used for nothing else. (about 3 lines)
- [emit_llvm_simd.odin:334](src/emit_llvm_simd.odin#L334) `emit_simd_reduce`: `name` is computed before the checked fold, which ignores it, and `fold` is then retested three times. Give each case of one switch its own whole lowering: `.Any, .All`, `.Add, .Mul`, `.Min`, `.Max`. (about 5 lines)

**Dead code**

- (branch) [emit_llvm_simd.odin:221](src/emit_llvm_simd.odin#L221): `v.op == .Plus` is unreachable, because `check_simd_unary` (`simd.odin:362`) admits only `-` and `~`; `+v` gives L0686, confirmed with `lokec.exe`. Delete it and test `.Tilde` in place of `v.op != .Minus`.
- (branch) [emit_llvm_simd.odin:295](src/emit_llvm_simd.odin#L295): the only caller, `emit_llvm_calls.odin:174`, dispatches exactly the three kinds handled here, so this failure cannot fire. Dispatch directly there and delete the 12-line `emit_simd_builtin`, which only forwards.

**Near copies**

- [emit_llvm_simd.odin:146](src/emit_llvm_simd.odin#L146) and [emit_llvm_expr.odin:1583](src/emit_llvm_expr.odin#L1583): `emit_simd_divrem` and `emit_divrem` differ only in constant spelling, `i1` versus `<N x i1>`, and reducing before `panic_if`. Make `emit_divrem` lane-generic with one constant helper and one any-lane helper, the shape at `emit_llvm_calls.odin:1707` and `:1729`. (about 30 lines)
- [emit_llvm_simd.odin:182](src/emit_llvm_simd.odin#L182) and [emit_llvm_expr.odin:1622](src/emit_llvm_expr.odin#L1622): the same shift sequence; the scalar adds only count-width conversion, which a vector skips because its count has the lane width. The same helpers merge them, taking `bits` from the lane. (about 20 lines)
- [emit_llvm_simd.odin:108](src/emit_llvm_simd.odin#L108) and [emit_llvm_expr.odin:1553](src/emit_llvm_expr.odin#L1553), with [emit_llvm_simd.odin:217](src/emit_llvm_simd.odin#L217) and [emit_llvm_expr.odin:1421](src/emit_llvm_expr.odin#L1421): checked call and unary operators, differing in declaration, mask type, and any-lane reduction. Once merged, `emit_simd_binary_values` is little more than splatting, compares, and `emit_binary_op`. (about 15 lines)
- [emit_llvm_simd.odin:129](src/emit_llvm_simd.odin#L129) and [emit_llvm_expr.odin:1712](src/emit_llvm_expr.odin#L1712): both choose `fcmp`/`icmp` and the predicate from a lane type. A helper returning the text such as `"icmp slt"`, using `type_signed`, serves both. (about 6 lines)
- [emit_llvm_simd.odin:113](src/emit_llvm_simd.odin#L113), [emit_llvm_simd.odin:274](src/emit_llvm_simd.odin#L274) and [emit_llvm_calls.odin:201](src/emit_llvm_calls.odin#L201) (also `:228`, `:254`, `:324`, `:348`, `:358`, `:376`): the same declare-once block, nine times. Add `declare_intrinsic(e, key, declaration)` and rename `simd_intrinsics` (`emit_llvm.odin:59`), which also holds `llvm.ctpop` and `llvm.trap`. (about 18 lines)
- [emit_llvm_simd.odin:36](src/emit_llvm_simd.odin#L36), [emit_llvm_abi.odin:1223](src/emit_llvm_abi.odin#L1223) and [emit_llvm_expr.odin:146](src/emit_llvm_expr.odin#L146): the mask test written out three times. Keep one unprivate `simd_is_mask` with body `type_is_boolean(e.c, info.element)` and call it from the other two.
- [emit_llvm_simd.odin:260](src/emit_llvm_simd.odin#L260) and [emit_llvm_calls.odin:357](src/emit_llvm_calls.odin#L357) (also `:375`): both mangle a float spelling for an overloaded intrinsic. Rename `simd_mangled_lane` to a general name, make it package-visible, and use it at all three sites.

**Structure and boundaries**

- [emit_llvm_simd.odin:10](src/emit_llvm_simd.odin#L10): file-private `simd_operand` shadows the package-level `simd_operand` at `simd.odin:133`, which answers a different question. Rename it, for example `simd_splat_scalar`. Likewise [line 209](src/emit_llvm_simd.odin#L209)'s `simd_select` emits a raw `select` but shares the built-in's name that `emit_simd_select` lowers; `emit_mask_select` would separate them.

**Comments**

- [emit_llvm_simd.odin:104](src/emit_llvm_simd.odin#L104): keep the citation and first sentence; delete the sentence on the `*.with.overflow` intrinsics, which `emit_llvm_expr.odin:1551` already explains.
- [emit_llvm_simd.odin:124](src/emit_llvm_simd.odin#L124): delete; the file header at line 2 says a mask lane is `i8` where `icmp` gives `i1`.
- [emit_llvm_simd.odin:143](src/emit_llvm_simd.odin#L143): shorten to "Any zero lane faults the whole operation; otherwise lane by lane as `emit_divrem`."
- [emit_llvm_simd.odin:178](src/emit_llvm_simd.odin#L178): shorten to "A negative count lane panics the whole operation; otherwise lane by lane as `emit_shift`."
- [emit_llvm_simd.odin:235](src/emit_llvm_simd.odin#L235): delete; it restates the name and parameters.
- [emit_llvm_simd.odin:269](src/emit_llvm_simd.odin#L269): keep only "`start` is the `type value, ` prefix of an ordered float fold, or empty."

### src/emit_llvm_stmt.odin

What remains is two near copies that belong to the cross-file groups.

**Near copies**

- [emit_llvm_stmt.odin:173](src/emit_llvm_stmt.odin#L173), [emit_llvm_calls.odin:647](src/emit_llvm_calls.odin#L647), [emit_llvm_containers.odin:800](src/emit_llvm_containers.odin#L800) and [emit_llvm_expr.odin:2275](src/emit_llvm_expr.odin#L2275): branch on failure, call `loke_rt_v1_alloc_failed`, `unreachable`, continue. Shared form: `emit_alloc_failed_if(e, failed, allocator)`, shaped like `panic_if`. (about 5 lines per site)
- [emit_llvm_stmt.odin:679](src/emit_llvm_stmt.odin#L679) and [emit_llvm_iteration.odin:62](src/emit_llvm_iteration.odin#L62): the same save and restore of four loop fields. Group them in a `Loop_Targets` on `Emitter` (`outer := e.loop; defer e.loop = outer`), which is also where the frame depth from BUG-1 belongs. (about 8 lines)

### src/enums.odin

Small and correct. The enum declaration logic lives in `check.odin`.

**Near copies**

- [enums.odin:83](src/enums.odin#L83), [simd.odin:291](src/simd.odin#L291), [check_expr.odin:3332](src/check_expr.odin#L3332) and [const_ops.odin:884](src/const_ops.odin#L884) hand-build what the file-private `aggregate_const` at [reflect.odin:307](src/reflect.odin#L307) builds.
  Promote it to `const_ops.odin` (about 3 lines per site). It also sets `type_value`, which these omit; confirm no reader depends on the difference.
- [enums.odin:51](src/enums.odin#L51), [union.odin:482](src/union.odin#L482), [union.odin:611](src/union.odin#L611), [text.odin:71](src/text.odin#L71) and [check_calls.odin:1028](src/check_calls.odin#L1028) repeat `v.bound = make([]Expr, 1, ...)` then `v.bound[0] = x`.
  About 15 checker sites use this or the `bound :=` spelling; a `bind_single(k, v, x)` saves one line at each.

**Structure and boundaries**

- [check.odin:4497](src/check.odin#L4497) `enum_member_by_value` and [check.odin:1250](src/check.odin#L1250) `resolve_enum_members` belong here: "Source-code map" gives this file "Enums", yet it holds only the two built-in calls. Moving them gives enums one owner and shortens `check.odin` by about 100 lines.

### src/erased.odin

What remains here belongs to the groups under "Findings that span files".

**Near copies**

- [erased.odin:747](src/erased.odin#L747) and [interface.odin:1396](src/interface.odin#L1396), [interface.odin:1356](src/interface.odin#L1356): all do `composed_interface_of`, clone, cast, `bound_arguments`. Shared form: `composed_application(k, requirement) -> (^Interface_Info, []Generic_Arg, bool)`.
- [erased.odin:893](src/erased.odin#L893) and [interface.odin:1018](src/interface.odin#L1018): same loop over `slot_candidates` and `slot_matches`, differing only in `result_inout` and the returned value. One `matching_slot` returning the symbol replaces `find_witness_slot`.

### src/eval.odin

The one finding left waits for the multi-file group it belongs to.

**Near copies**

- [eval.odin:853](src/eval.odin#L853) and [check_expr.odin:2064](src/check_expr.odin#L2064): the same unary fold and overflow rule. Move it to `const_ops.odin` as `fold_unary`, a sibling of `fold_arithmetic`; the checker keeps only its decimal-spelling fix-up afterwards. (about 20 lines)

### src/expand.odin

Readable and well commented, but the static `foreach` half re-implements binding rules the runtime `foreach` gets from helpers, and has drifted from them (BUG-expand-2 and BUG-expand-3). Each bug's scenario was run on the repository's `lokec.exe`; the proposed fixes are untested.

**Bugs**

- `BUG-expand-2` **medium** [expand.odin:146](src/expand.odin#L146) `bind_static_pattern`: counts raw `info.fields` and skips `destructure_fields`, against design.md "Destructuring". *Confirmed: Probes reproduce: $a, $b over padded struct gets L0454 'has 3 fields' (runtime prints 1 2); over geom.Point it compiles and runs (runtime gets L0708), against design.md Destructuring. The int wording also occurs, but the runtime form says the same.*
  Scenario: `struct { a: int, _: [4]u8, b: int }` with `$a, $b` gets L0454 "has 3 fields" (runtime form accepts); `$a, $b` over another package's record is accepted (runtime gets L0708); an `int` says "binds 1 or 0 names".
  Fix: call `destructure_fields(k, type, len(bindings), span, "L0454", "bound by a `foreach`")` and index the aggregate by `field.index`.
- `BUG-expand-3` **medium** [expand.odin:181](src/expand.odin#L181) `bind_static`: writes `k.scope.names` with none of the checks of design.md "Variable declarations" that `bind_loop_name` makes. *Confirmed: Reproduced: foreach ($x) over local or param x compiles (runtime form L0305, local x :: 5 L0305); $a, $a binds last, printing 2 4 (runtime L0304); case $variant(p) with local variant and $s(s) on a payloadless union compile. Not recorded in the gap docs.*
  Scenario: `x := 7; foreach ($x in 0..<2) {...}` compiles (runtime gets L0305); `foreach ($a, $a in R)` silently binds the last (runtime gets L0304); so do `variant := 7; ... case $variant(p):` and `case $s(s):` over a payloadless union.
  Fix: share the L0304/L0305 checks with `bind_loop_name`, reporting them once from `check_static_pattern_markers`, or per copy.
- `BUG-expand-4` **medium** [expand.odin:306](src/expand.odin#L306) `fold_static_iterable`: design.md "Static `foreach` expansion" says compile-time slices qualify, but a slice is accepted only as a written `a[i:j]`. *Confirmed: Reproduced: K :: ARR[:], K :: []int{1,2} and a []int{1,2} literal each give L0454 found `[]int`, while written ARR[:] expands; design.md lists compile-time slices and no gap or decision records this. Severity is low-medium: a clear error, workaround exists.*
  Scenario: `K :: ARR[:]; foreach ($a in K)` and `foreach ($a in []int{1,2})` get L0454 "needs a compile-time array ... found `[]int`".
  Fix: send `.Slice` down the `evaluate_static_elements` path with `.Dynamic_Array`.
- `BUG-expand-5` **low** [expand.odin:237](src/expand.odin#L237) `stmt_has_branch`: does not descend into `Stmt_Defer`, so a deferred branch escapes the L0455 walk. *Not verified.*
  Scenario: `foreach ($a in [0]int{}) { defer break; }` compiles while `{ break; }` gets L0455; with elements it gets L0368 "only valid inside a loop", even inside a runtime loop.
  Fix: add `case ^Stmt_Defer: return stmt_has_branch(k, v.stmt)`.
- `BUG-expand-6` **low** [expand.odin:200](src/expand.odin#L200) `static_element_text`: the spec says a diagnostic must show the element, but the note cannot for pairs or runes. *Not verified.*
  Scenario: the spec's own `fields_of(T).indexed()` gives "in static expansion 0, for `<value>`", any aggregate element likewise, and rune `'a'` gives "for `97`".
  Fix: unwrap an indexed pair before the descriptor test, and print a rune as a rune.

**Simplification**

- [expand.odin:305](src/expand.odin#L305) `fold_static_iterable`: test the kind first (`.Array`, `.Dynamic_Array`, `.Slice`), then one `evaluate_static_elements` call replaces `require_const`
  plus the hand copy at 324-331. Needs a run of the suite, since a runtime array's message moves to the evaluator's. (about 14 lines)
- [expand.odin:222](src/expand.odin#L222) `block_has_branch`, `stmts_have_branch`, `stmt_has_branch`: a predicate that also reports. Make them a void walk and set `k.branches_reported = k.c.error_count > before`;
  the `found` juggling goes, and `v.otherwise != nil` too, since a nil `Stmt` reaches the final `return`. (about 12 lines)
- [expand.odin:286](src/expand.odin#L286) `fold_static_iterable`: every fold returns a fresh slice, so transform in place: `slice.reverse(elements)` or an `indexed_pair` loop, with no `out`. (about 3 lines)
- [expand.odin:380](src/expand.odin#L380) `fold_static_slice`: return `elements[int(lo):int(hi)]` with the element type from the operand's fold; `out`, `copy` and the `type` parameter go. (about 3 lines)
- [expand.odin:98](src/expand.odin#L98) `indexed_pair` and [expand.odin:546](src/expand.odin#L546) `bind_expanded_case`: `aggregate_const` (reflect.odin:307) builds both; the Unit becomes `aggregate_const(k.c, k.c.unit_type, nil)`. (about 6 lines)
- [expand.odin:173](src/expand.odin#L173) `bind_static`: takes a `Foreach_Binding` but reads only `.name`; take a `Name`, which drops the wrappers at 542 and 548, and use `name_identifier` for lines 177-180. (about 3 lines)
- [expand.odin:192](src/expand.odin#L192) `static_element_text`: put the backticks in the format at line 73 and return the plain text, so neither `aprintf` is needed for quoting. (about 4 lines)
- [expand.odin:55](src/expand.odin#L55) `expand_one_element`: bind before cloning, since a failed bind wastes the clone, and return a nil block instead of the `bool`. (about 3 lines)
- [expand.odin:475](src/expand.odin#L475) `expand_variant_cases`: the temporary `Block` only works around `clone_stmts` being file-private in ast_clone.odin; make it package-visible and call it. (about 1 line)
- [expand.odin:127](src/expand.odin#L127) and [expand.odin:511](src/expand.odin#L511): the `!= "_"` guard is unneeded, because `reject_reserved_name` rejects only universe symbols marked `reserved`. (no lines, shorter conditions)
- [expand.odin:342](src/expand.odin#L342) `fold_static_range`: `distance` is used once; start `count` from the `bi_sub`. (about 1 line)
- [expand.odin:307](src/expand.odin#L307) `fold_static_iterable`: `"L0454"` repeats the default of `code`, and this is the only caller, so the parameter at eval.odin:107 can go. (no lines here)

**Dead code**

- (branch) [expand.odin:32](src/expand.odin#L32): `s.adapter` is only set by `peel_resolved_adapter`, reached only from `check_runtime_foreach` (iterate.odin:507), so it is always `.None` here; `at` is `index`.
- (branch) [expand.odin:89](src/expand.odin#L89): `s.indexed` is false here for the same reason (`.indexed()` arrives through the adapter branch at 283), so `bind_static_element` reduces to a call to `bind_static_pattern` and can go.
- (branch) [expand.odin:37](src/expand.odin#L37): `copy_flow.breaks` and `.continues` are never true: a copy runs at `loop_depth` 0, where `check_branch` returns `FLOWS`, and nested loops do not pass them on.

**Data structures and algorithms**

- [expand.odin:360](src/expand.odin#L360) `fold_static_range`: `bi_from_i64(k.c, 1)` allocates on the arena once per element, and a range may reach `EVAL_MAX_STEPS` (1,000,000) elements; compute `one` once before the loop.

**Near copies**

- [expand.odin:146](src/expand.odin#L146) and [check.odin:1152](src/check.odin#L1152): `bind_static_pattern` has a weaker copy of `destructure_fields` (arity, visibility); calling it fixes BUG-expand-2 and drops lines 145-159 to about 5.
- [expand.odin:173](src/expand.odin#L173), [iterate.odin:1056](src/iterate.odin#L1056) and [optional.odin:600](src/optional.odin#L600): `bind_static`, `bind_loop_name` and `bind_case_name` share the skip of `_`, the name lookup and the L0304/L0305/reserved checks.
  The last two are almost line for line; a shared `check_binding_name(k, name, outer) -> Identifier_Id` serves all three and fixes BUG-expand-3.
- [expand.odin:470](src/expand.odin#L470) and [expand.odin:627](src/expand.odin#L627): both build a one-element `[]Expr` holding a `.label` selector; a `variant_case_values(c, label, span)` covers them. Line 633 also interns the same name per variant; hoist that `Name`.
- [expand.odin:36](src/expand.odin#L36) and [check.odin:3138](src/check.odin#L3138): the same sequence-composition of `Flow_Info`; a `flow_then(&flow, next)` in check.odin serves both.

**Structure and boundaries**

- [expand.odin:203](src/expand.odin#L203): `const_display_text` has nothing to do with expansion and is also used by eval.odin and generic.odin; it belongs in const_ops.odin.
- [expand.odin:578](src/expand.odin#L578) `check_union_argument_expansion`: 117 lines doing three jobs. Seams: finding and classifying the spread (579-613), building the `dispatch` switch (618-655), and deciding the common result (658-692).
- [expand.odin:409](src/expand.odin#L409) `expand_variant_cases`: 80 lines; the seam is at 449, between finding and validating the case (410-448) and making the copies (454-486).
- [expand.odin:173](src/expand.odin#L173): `bind_static` has no caller outside this file but lacks `@(private = "file")`, unlike its siblings.

**Comments**

- [expand.odin:219](src/expand.odin#L219): cite the exact heading: `design.md "Static `foreach` expansion": loops in the body own their branches, so they are not walked.`
- [expand.odin:385](src/expand.odin#L385): delete; the signature and two-line body say it.
- [expand.odin:404](src/expand.odin#L404): the first sentence restates the spec. `design.md "Per-variant switch cases": each copy is an ordinary case with its own clone of the body, so nothing after the checker sees an expanded case. False after a diagnostic.`
- [expand.odin:589](src/expand.odin#L589): six lines; keep the reasons only. `A union needing a destination type has none here, so it is left to the variadic path. Any other operand is checked once: a recheck would double per level of nested spreads.`
- [expand.odin:658](src/expand.odin#L658): restates the spec bullet; reduce to `design.md "Union argument expansion": a call that never returns stands in for either.`

### src/foreign.odin

Small and readable, but the foreign-global path has real gaps: an unknown type reaches the backend, and link-name agreement rejects legal bindings. Every bug scenario below was run against the existing `lokec.exe` with `-emit-ll`.

**Bugs**

- `BUG-foreign-1` **medium** [foreign.odin:144](src/foreign.odin#L144) `resolve_foreign_global`: `resolve_type_syntax` can return `INVALID_TYPE` without reporting, and this returns silently. Scenario: `foreign lib { x: Nope; }` (or a generic `x: G;`) exits 2 with L0405 "`<invalid>` has no backend representation", no source location. Fix: use `resolve_type_name` ([check.odin:2304](src/check.odin#L2304)), made package-visible. *Confirmed: Reproduced: `foreign lib { x: Nope; }` and generic `x: G;` exit 2 with spanless L0405 `<invalid>`, while `x: i32;` builds and file-scope `x: Nope;` gives L0306. Line 144 returns without report_unresolved_type; no gap is recorded.*
- `BUG-foreign-2` **medium** [foreign.odin:129](src/foreign.odin#L129) `foreign_links_agree`: compares interned proc types, but a defined procedure with a struct or `^mut` result carries a `proc_contract` ([check.odin:1598](src/check.odin#L1598)) and a foreign one never does. Scenario: `foreign lib { @(link_name="z") f :: proc(a: i32) -> P ---; }` with `@(export, link_name="z") g :: proc "c" (a: i32) -> P {...}` gives a false L0600. Fix: compare `erase_proc_contract(c, a.proc_type)` on both sides. *Confirmed: lokec gives L0600 for identical foreign/exported signatures with a struct, ^P or ^mut result; an i32 result compiles. check.odin:1598 sets proc_contract only on defined procs, and foreign_links_agree compares it, against design.md "@(export)".*
- `BUG-foreign-3` **low** [foreign.odin:135](src/foreign.odin#L135) `resolve_foreign_global`: `d.values[0] != nil` lets `---` through, which parses to a nil value, against grammar.md's "a variable with no initializer". Scenario: `foreign lib { a, b: i32 = ---, 1; }` compiles and the `1` is dropped. Fix: `if len(d.values) > 0`. *Not verified.*
- `BUG-foreign-4` **low** [foreign.odin:171](src/foreign.odin#L171) `check_c_vararg_param`: checks the parameter's position but not its name count, and the caller skips the L0574 path. Scenario: `f :: proc(@(c_vararg) a, b: ..) ---;` compiles, while `a, b: ..int` is L0574. Fix: also reject `len(parameter.names) != 1`. *Not verified.*
- `BUG-foreign-5` **low** [foreign.odin:110](src/foreign.odin#L110) `check_foreign_links`: an empty link name skips the agreement check, and nothing rejects `@(link_name="")`. Scenario: two members with `@(link_name="")` and different signatures compile and emit one `declare void @""()`. Fix: reject the empty name in attribute validation. *Not verified.*
- `BUG-foreign-6` **low** [foreign.odin:6](src/foreign.odin#L6) `foreign_default_convention`: the block's value is only validated through each member's `check_signature_convention`. Scenario: `@(default_calling_convention="bogus") foreign lib { x: i32; }` compiles; with three procedures it reports L0618 three times, at the members. Fix: validate once here at the attribute and fall back to `"c"`. *Not verified.*
- `BUG-foreign-7` **low** [foreign.odin:136](src/foreign.odin#L136) `resolve_foreign_global`: every non-procedure member with a value is treated as a global. Scenario: `foreign lib { X :: 1; }` or a member struct reports "a foreign global is declared without an initializer", which names neither the construct nor the rule. Fix: for `d.kind != .Var`, say a foreign block declares only `---` procedures and `x: T;` variables. *Not verified.*
- `BUG-foreign-8` **low** [foreign.odin:76](src/foreign.odin#L76) `check_foreign_block`: `@(export)` on a member passes validation and `check_exports` never visits it, so it silently does nothing. Scenario: `foreign lib { @(export) f :: proc() ---; }` compiles and emits only a `declare`, though design.md "`@(export)`" says it emits a symbol. Fix: L0607 under the `.Foreign` scope in `validate_decl_attributes`. *Not verified.*

**Simplification**

- [foreign.odin:21](src/foreign.odin#L21) `declare_foreign_block`: drop `foreign_block_visibility` and `own_visibility`. `block_default := attributes_are_public(k, block.attributes, block.span, "foreign block")` ([check.odin:649](src/check.odin#L649), made package-visible) reports L0332 with the same text; then `if sym.kind != .Var { sym.public = written_is_public(d.attributes, nil, block_default) }`. (about 12 lines)
- [foreign.odin:5](src/foreign.odin#L5) `foreign_default_convention`: one caller and five lines; inline as `convention, has := attribute_string_value(...)` plus `if !has { convention = "c" }`, unless the default-convention bug's validation lands here. (about 4 lines)

**Dead code**

- (branch) [foreign.odin:29](src/foreign.odin#L29): `literal.signature != nil` is always true: [parser.odin:3440](src/parser.odin#L3440) always sets it and [check.odin:1459](src/check.odin#L1459) reads it unguarded. Merge lines 29 and 30 into one `if`.
- (branch) [foreign.odin:139](src/foreign.odin#L139): `d.declared_type == nil` is reachable only from `x := ---;`, which the parser already rejects as L0235, so L0625 here is a cascade. With `len(d.values) > 0` at line 135 the branch can never run; no expected file pins this message.
- (branch) [foreign.odin:110](src/foreign.odin#L110): `sym.link_name == ""` cannot hold for a normal member, since `check_foreign_block` sets a name on every symbol at line 87. It only serves the `@(link_name="")` bug above and goes away with that fix.

**Near copies**

- [foreign.odin:24](src/foreign.odin#L24), [foreign.odin:64](src/foreign.odin#L64), [foreign.odin:104](src/foreign.odin#L104), [attributes.odin:258](src/attributes.odin#L258), [doc.odin:312](src/doc.odin#L312), [doc.odin:351](src/doc.odin#L351), [private_names.odin:48](src/private_names.odin#L48), [emit_llvm.odin:353](src/emit_llvm.odin#L353): all filter `member.(^Decl)`. Only `^Decl` or an already reported `^Item_Error` occurs, so `parse_foreign` could drop errors and `Item_Foreign_Block.members` become `[]^Decl`. (about 15 lines)
- [foreign.odin:41](src/foreign.odin#L41): states "member, then block, then file" for visibility. `written_is_public` already composes, as `decl_is_public` now uses it. (about 5 lines)

**Structure and boundaries**


**Comments**

- [foreign.odin:1](src/foreign.odin#L1): drop "`foreign import` and": nothing here handles imports, which [emit_llvm_toolchain.odin:615](src/emit_llvm_toolchain.odin#L615) reads.
- [foreign.odin:15](src/foreign.odin#L15): delete; [ast.odin:1258](src/ast.odin#L1258) says the same on the `declared` field.
- [foreign.odin:59](src/foreign.odin#L59): wrong as written, since it runs inside the signature loop ([check.odin:250](src/check.odin#L250)), not after it. Use "Runs in Phase 2b of `check_package_bodies`, among the signatures."
- [foreign.odin:92](src/foreign.odin#L92): delete; it restates the four-line body.
- [foreign.odin:127](src/foreign.odin#L127): repeats lines 100 and 101. Replace with the rule's source: `// design.md "`@(export)`": same kind and type.`
- [foreign.odin:157](src/foreign.odin#L157): the second clause restates the three checks below; keep only `// design.md "`@(c_vararg)`".`

### src/format.odin

Small and readable, with no dead procedures. `ensure_format_member` lets a `where`-excluded `format` block the default, and `type_prints_through_method` claims more than the emitter prints, so valid programs are rejected. `Writer` and `Options` are fetched and recorded in several ways, which is most of what can be shortened.

**Bugs**

- `BUG-format-1` **medium** [format.odin:26](src/format.odin#L26) `ensure_format_member`: the member loop ignores `bound_excluded`, so a `format` whose `where` failed blocks the default. Scenario: `impl G($T) { format :: proc(self, w: fmt.Writer, o: fmt.Options) where T == string {...} }`, then `fmt.println(G(int){1})` gives L0444 rather than the default form. Fix: the first Simplification bullet. *Confirmed: Probe: G(int) with `format ... where T == string` gets L0444 from fmt.println; G(string) prints custom, no-format G(int) prints the default. The spec gives an excluded method no presence; no doc records it. Rejects a valid program, no miscompile.*
- `BUG-format-2` **low** [format.odin:88](src/format.odin#L88) `prints_through_method_walk`: asks about the wrapped type's `format`, but a distinct type prints by its own default and never calls it (design.md "Delegating operators"). Scenario: `D :: distinct Own`, where `Own.format` writes `data`; `panic("stop", data[0], D{1})` gives a false L0512. Fix: delete lines 88-90. *Not verified.*
- `BUG-format-3` **low** [format.odin:101](src/format.odin#L101) `prints_through_method_walk`: walks every field, but a generated form prints public fields only (standard-library.md "Printed forms"). Scenario: in a library, a private `own: Own` field makes `panic("stop", data[0], holder)` a false L0512. Fix: require `sym.public`, and make the fields public in tests/err/private_formatter_effects.loke, which pins this at lines 59, 63 and 67. *Not verified.*
- `BUG-format-4` **low** [format.odin:93](src/format.odin#L93) `prints_through_method_walk`: treats every `dyn` as running code, but any view other than `dyn fmt.Formattable` prints its type's name (standard-library.md "Printed forms"). Scenario: `a :: proc(v: dyn Sz) { data.append(7); panic("stop", data[0], v); }` gives a false L0512 when a `format` writes `data`. Fix: `return dyn_views_printing(c, under)`. *Not verified.*

**Simplification**

- [format.odin:20](src/format.odin#L20) `ensure_format_member`: replace lines 20-32 with `if type_has_written_format(k.c, type) { return }` and a loop finding the `.Standard_Format` member. This fixes BUG-format-1 and drops `hidden`, whose test restates `format_meets_slot`. (about 5 lines)
- [format.odin:11](src/format.odin#L11) `ensure_format_member`: move the `Writer` and `Options` lookup inside `if id == INVALID_SYMBOL`, the only place that needs them, so a repeat `format` lookup skips the package scan and two interns. (no lines saved)
- [format.odin:155](src/format.odin#L155) `discover_formatters`: [check.odin:322](src/check.odin#L322) already records `Format_View` once `core:fmt` is checked. Read it at the top, take the package from its interface's `sym.pkg`, and drop the loop, lookup and second write at 167-172. (about 8 lines)
- [format.odin:135](src/format.odin#L135) `check_formatter`: start from `format_misdeclared(c, type)`, dropping the `writer` and `options` parameters and lines 156-160, since the same pair is read at 196-197. `formatter_signature_ok` then has one caller. (about 6 lines)
- [format.odin:19](src/format.odin#L19) and [format.odin:230](src/format.odin#L230): both record `Writer` and `Options`. Record them once beside `Format_View` at [check.odin:321](src/check.odin#L321); only `format_misdeclared` reads them earlier, and it can answer false inside `core:fmt`. `check_fmt_builtin` then needs no `options`. (about 4 lines)
- [format.odin:253](src/format.odin#L253) `check_fmt_builtin`: call `builtin_arguments_ok` ([check_builtin.odin:198](src/check_builtin.odin#L198)) in place of this shape check, which reports L0371 for a mode where the shared one reports L0370. Setting `v.type = INVALID_TYPE` first, as `check_layout_builtin` does, removes three more assignments. (about 8 lines)
- [format.odin:271](src/format.odin#L271) `local_type_named`: a one-line wrapper with two callers in one procedure; call `package_type_named` directly. (about 5 lines)

**Dead code**

- (branch) [format.odin:108](src/format.odin#L108): `variant != TYPE_VOID` guards nothing; the walk answers false for void, which has no written `format` and no case in the switch.
- (branch) [format.odin:53](src/format.odin#L53): `type != INVALID_TYPE` repeats `type_is_supported`, which answers false for that id.

**Data structures and algorithms**

- [format.odin:73](src/format.odin#L73) `type_prints_through_method`: hand-rolls a `map[Type_Id]bool` visited set where `Type_Walk` and `type_walk_enter` ([semantic.odin:2189](src/semantic.odin#L2189)) are the shared form. It would enter on `type`, not `under`, so `P :: distinct ^P` still stops. The input is one printed type, so this is consistency, not speed.

**Near copies**

- [format.odin:184](src/format.odin#L184), [hooks.odin:559](src/hooks.odin#L559) and [global_effects.odin:1658](src/global_effects.odin#L1658): three tests for "this `dyn` is printing's", the first by name and the others by the recorded view. Share one predicate on the interface symbol; the name form also works while `core:fmt` is being checked.
- [format.odin:241](src/format.odin#L241), [atomics.odin:164](src/atomics.odin#L164), [simd.odin:427](src/simd.odin#L427) and [text.odin:273](src/text.odin#L273): the same plural-aware arity error with different codes. A `report_builtin_arity(k, v, code, name, wanted)` turns each five-line call into one.

**Structure and boundaries**

- [format.odin:150](src/format.odin#L150) `discover_formatters`: does two jobs under one name, reporting L0572 for every type (161-165) and building witnesses for typeids (166-180). Split at line 166, or name the first job in the procedure's name.
- [format.odin:91](src/format.odin#L91) `prints_through_method_walk`: restates by hand what `emit_format_body` ([emit_llvm_runtime.odin:698](src/emit_llvm_runtime.odin#L698)) reaches, and the layering forbids sharing code, which is how BUG-format-2 to 4 arose. Say in its comment which emitter procedure it mirrors.

**Comments**

- [format.odin:20](src/format.odin#L20): delete with the first Simplification; it repeats lines 58-59.
- [format.odin:57](src/format.odin#L57): shorten to "Whether a type's own `format` is what printing uses." Move the citation and the private-method sentence to `format_meets_slot` at line 65, where the rule is coded.
- [format.odin:131](src/format.odin#L131): "design.md gives the name to the protocol" is no citation, and that text now lives in standard-library.md. Use `standard-library.md "Printed forms": a `format` that cannot serve the slot is a mistake, not an unrelated procedure.`
- [format.odin:202](src/format.odin#L202): wrong, since line 206 also accepts `.Value`. Use "The thunk passes the caller's own storage, so the receiver cannot be `move` or `inout`, and nothing is given back."
- [format.odin:269](src/format.odin#L269): delete with `local_type_named`.

### src/formatter.odin

A compact, linear token layout pass whose token-preservation check holds up, and every declared symbol is live. The real issues are indentation rules in `continues` that misfire on wrapped lists and comments, a command driver duplicated in `migrate.odin`, and output tracking that a stored indent would replace. The bugs were observed by running the built `lokec.exe -fmt` on scratch files.

**Bugs**

- `BUG-formatter-1` **medium** [formatter.odin:263](src/formatter.odin#L263) `continues`: a continued list item makes every later item of a `{` list continue too. Scenario: `T :: enum {\n A = 1 +\n 2,\n B,\n C,\n}` puts `B` and `C` at two tabs; slice literals do the same. Fix: key the comma rule on being inside a `where` clause, replacing `last_continued`. *Confirmed: Reproduced: -fmt moves B and C after a wrapped `A = 1 +`/`2,` to two tabs, and slice literal items likewise; no recorded decision covers it (the comment names `where` clauses). Whitespace-only and stable, so low rather than medium severity.*
- `BUG-formatter-2` **low** [formatter.odin:260](src/formatter.odin#L260) `continues`: the `case` colon test reads only the last line's first token. Scenario: in `case .a,\n .b:\n y := 1;\n z := 2;` the `y` line gets one tab more than `z`. Fix: remember an open `case` header until its colon rather than testing `line_first`. *Not verified.*
- `BUG-formatter-3` **low** [formatter.odin:160](src/formatter.odin#L160) `layout`: spacing treats an inline comment as absent, yet forces a space before it. Scenario: `f(/* name */ x)` becomes `f( /* name */x)`. Fix: keep the written gap after a comment (see line 175 under Simplification), and force no space after `(` or `[`. *Not verified.*
- `BUG-formatter-4` **low** [formatter.odin:269](src/formatter.odin#L269) `continues`: the attribute test only sees the line the attribute ends on. Scenario: `@(a,\n b)\ng :: proc() {}` indents `g` one tab. Fix: when the `)` of an `Open` with `attribute` set pops, make `line_first` count as `.At`. *Not verified.*
- `BUG-formatter-5` **low** [formatter.odin:256](src/formatter.odin#L256) `continues`: a `{` that starts a line counts as continuing its header. Scenario: `if (x)\n{\n y;\n}` in a body puts `{` at two tabs, `y` at two and `}` at one, so the braces do not align. Fix: in `indent`, a line starting with `.Lbrace` never continues. *Not verified.*
- `BUG-formatter-6` **low** [formatter.odin:336](src/formatter.odin#L336) `line_indent`: a bracket after a multi-line raw string or block comment indents from that literal's last line. Scenario: in a proc body, a raw string ending at column zero followed by `+ g(\n a,\n);` writes `a` at one tab and `);` at column zero. Fix: the stored indent under Simplification. *Not verified.*

**Simplification**

- [formatter.odin:327](src/formatter.odin#L327) `write_out`, `line_indent`: every line start goes through `indent`, so set `l.indent = max(depth, 0)` there and read it at line 285. This drops `write_out`, `line_indent` and `line_start` for plain `write_string`, and fixes BUG-formatter-6. (about 19 lines)
- [formatter.odin:206](src/formatter.odin#L206) `horizontal`: it is the identity. Each call is on a gap `break_line` just found free of `\n`, and a lone `\r` is L0115, refused before layout. Use `gap` directly. (about 5 lines)
- [formatter.odin:195](src/formatter.odin#L195) `would_merge`: only the prefix rule at line 504 can drop a space between operator characters, so test there instead of patching at lines 177-179; only `&&`, `&~`, `--` can occur after a prefix operator. (about 8 lines)
- [formatter.odin:380](src/formatter.odin#L380) `written_tight`: its list is exactly the enum range `.Plus ..= .Shr`, so use a range test as `any_keyword` does. `binary_operator` (line 363) likewise is `.Plus ..= .Shr_Eq` minus `.Not`, plus six named kinds. (about 5 lines)
- [formatter.odin:151](src/formatter.odin#L151) `layout`: pass the tokens with their EOF, whose `lo` is `len(text)`. `for token in tokens` then drops the ternaries at lines 153 and 162 and the `index == len(tokens)` exit. (about 4 lines)
- [formatter.odin:149](src/formatter.odin#L149) `layout`: `started` is `strings.builder_len(l.out) > 0`, since no comment or token is empty. (about 3 lines)
- [formatter.odin:175](src/formatter.odin#L175) `layout`: `previous_hi == l.last.hi` replaces `l.last.kind != .EOF && l.last_line == l.line`, sending only a token right after a token to `spacing`; this is also half of the BUG-formatter-3 fix. (about 1 line)
- [formatter.odin:303](src/formatter.odin#L303) `write_token`: this predicate and the one at line 506 are the same, `binary_operator(k) && (operand || !maybe_prefix(k))`; name it once as `used_as_binary(kind, operand)`. (about 1 line)
- [formatter.odin:448](src/formatter.odin#L448) `spacing`: the `.Rbrace` and `.Lbrace` cases have one body, so `case .Rbrace, .Lbrace:`. (about 2 lines)

**Dead code**

- (branch) [formatter.odin:297](src/formatter.odin#L297): `len(l.opens) > 0` before `pop`; `format_source` only lays out text that parsed, so every closer has an opener. (about 2 lines)
- (branch) [formatter.odin:385](src/formatter.odin#L385): `token.lo > 0 && token.hi < u32(len(l.text))`; a parsed file neither starts nor ends with an arithmetic operator.
- (branch) [formatter.odin:322](src/formatter.odin#L322): `at > int(brace.hi)`; when equal, `l.text[at - 1]` is the `{` itself, which already fails the `'\n'` test.
- (branch) [formatter.odin:405](src/formatter.odin#L405): `.At` in `maybe_prefix`; line 496 returns first for `last == .At`, `binary_operator(.At)` is false, and no prefix operator can precede an attribute now that a type holds none.

**Structure and boundaries**

- [formatter.odin:49](src/formatter.odin#L49): `input_sources` serves `-migrate` as well and only wraps `package_sources`, so it belongs beside that in `packages.odin`.

**Comments**

- [formatter.odin:3](src/formatter.odin#L3): lines 3-9 repeat comments.md "Formatting". Shorten to: "Changes whitespace only and refuses a file that does not parse; a result whose tokens differ is reported, not written (comments.md "Formatting")." (about 5 lines)
- [formatter.odin:225](src/formatter.odin#L225): lines 225-227 narrate the switch below, and the rule is in comments.md. Shorten to: "Tabs for a line that starts with `first` (comments.md "Formatting")." (about 2 lines)
- [formatter.odin:119](src/formatter.odin#L119): restates the field name. Say why it exists: "Recognizes the operator spelled `[]=`." Lines 152 and 325 narrate the code; delete those. (about 2 lines)
- [formatter.odin:65](src/formatter.odin#L65): restates the signature and misses the internal-error refusal. Shorten to: "False, with `c`'s diagnostics saying why, where it refuses."

### src/generic.odin

What remains needs a helper shared with `impl.odin`.

**Near copies**

- [generic.odin:3677](src/generic.odin#L3677) and [impl.odin:209](src/impl.odin#L209): the L0409 name checks and the 14-line member `Symbol` literal (line 3693, impl.odin:240) differ only in package and subject. A `reject_impl_member_name` plus `new_impl_member_symbol` removes the copy. (about 25 lines)

### src/global_effects.odin

The solvers are sound in how they iterate and deterministic, and the comments are mostly about why.

**Near copies**

- [global_effects.odin:144](src/global_effects.odin#L144), L275, L359, L713 and [borrow.odin:2578](src/borrow.odin#L2578): the same `Ident`/`Selector`/`Proc` switch; share `expr_named_symbol(e) -> Symbol_Id`. L713 omits `Expr_Proc` since the race warning covers named procedures only, so keep that check at its caller. The tail of `effect_value` at L369-374 and borrow.odin:2587-2591 also match.

### src/hooks.odin

The classification logic is careful and its comments mostly explain why. What remains is two near copies shared with other files.

**Near copies**

- [hooks.odin:166](src/hooks.odin#L166), [hooks.odin:277](src/hooks.odin#L277), [hooks.odin:330](src/hooks.odin#L330), [hooks.odin:370](src/hooks.odin#L370) and [region.odin:136](src/region.odin#L136): the same element, key, field and non-void variant dispatch. A helper `owned_parts(c, info) -> []Type_Id` reduces each walker to one loop. (about 35 lines here)
- [hooks.odin:1106](src/hooks.odin#L1106), [hooks.odin:1138](src/hooks.odin#L1138) and [attributes.odin:150](src/attributes.odin#L150): the same `file << 32 | lo` position key. Line 1138 should call `generic_hook_key`; a `span_key(span)` beside `Span` would serve all three.

### src/impl.odin

A compact file with mostly useful comments, and member-table scans that stay small enough to leave alone. Its weak points are that the generic copy of member declaration has drifted from it, and that hook and `where`-exclusion lookups skip paths the ordinary lookup covers. Every bug below was reproduced with `lokec.exe` built at this commit.

**Bugs**

- `BUG-impl-1` **medium** [impl.odin:622](src/impl.odin#L622) `conversion_hooks`: ignores `bound_excluded`, unlike `member_is_visible` and every other reader. Scenario: `impl V($T) { from_int :: hook(convert) proc(v: int) -> V(T) where T == int {...} }` with `V(string)(3)` stops with L0405 "internal backend contract violation"; an added unbound `i8` hook makes it L0391 ambiguous, naming the excluded hook. Fix: add `&& !sym.bound_excluded`. *Confirmed: Reproduced: V(string)(3) with a `where T == int` convert hook exits 2 with L0405; adding an unbound i8 hook gives L0391 naming from_int. design.md "where clauses" says lookup cannot find an excluded method; V(int)(3) compiles. No record found; medium is fair.*
- `BUG-impl-2` **medium** [impl.odin:93](src/impl.odin#L93) `check_local_impl`: returns silently when the subject does not resolve, since `resolve_type_syntax` reports nothing for these. Scenario: `main :: proc() { x := 1; impl x { f :: proc() { undefined_thing(); } } }` and `impl nope { }` both compile and run, while file scope reports L0406. Fix: the `error_count` guard from lines 53-55, in a helper both paths share. *Confirmed: Reproduced: body-local `impl x {f :: proc() {undefined_thing();}}` and `impl nope {}` exit 0 and run, members unchecked; file scope gives L0406. grammar.md requires a subject declared in this body; no gap or decision is recorded.*
- `BUG-impl-3` **medium** [impl.odin:456](src/impl.odin#L456) `excluded_member`: scans only `info.members`, so a failed bound on a generic extension is not seen. Scenario: `impl Option($T) { f :: proc(self, x: int) -> int where T == int {...}; g :: proc(self, x: string) -> int {...}; h :: proc{f, g}; }` on `Option(string)` is L0395 at [overload.odin:79](src/overload.odin#L79), and an inherent block compiles; `o.f()` also loses its note. Fix: also scan `pkg.extensions[type]` for `lookup_package(k)`. *Confirmed: Reproduced: extension impl Option($T) group on Option(string) gives L0395, and o.f(1) gives L0363 with no note; the same code on an inherent Box($T) compiles and gets the note. design.md "where clauses" requires both; Option(int) compiles. Medium is fair.*
- `BUG-impl-4` **medium** [impl.odin:193](src/impl.odin#L193) `declare_impl_member`: reports L0406 for a non-constant member, but its generic copy at [generic.odin:3656](src/generic.odin#L3656) skips one silently. Scenario: `impl G($T) { x: int = 0; }` compiles and `x` is dropped; `impl G { x: int = 0; }` is L0406. Fix: report it for the generic block once, in `check_generic_impl_subject` or registration. *Confirmed: Reproduced: impl G($T) { x: int = 0; } builds and runs (rc 0, prints 7) with G(int) instantiated, and g.x then gives L0363; the non-generic impl G gives L0406. generic.odin:3656 skips non-Const silently; no gap is recorded. Accepts-invalid, so low-medium.*
- `BUG-impl-6` **low** [impl.odin:209](src/impl.odin#L209) `declare_impl_member`: `existing` includes compiler-contributed members, which a body-local `impl` can meet because it declares its other members at its own statement. Scenario: `R :: struct {x: int}; r := R{1}; fmt.println(r); impl R { format :: proc(self, w: ^fmt.Writer, opt: fmt.Options) {...} }` is L0409 "already has a member `format`"; moving the `impl` up compiles. Fix: ignore `sym.synth != .None` in this check. *Not verified.*
- `BUG-impl-7` **low** [impl.odin:622](src/impl.odin#L622) `conversion_hooks`: tests `sym.hook` on table entries, but crossed generic blocks replace a same-named member with a `.Proc_Group` whose `hook` is `.None`. Scenario: `impl G(int, $U) { conv :: hook(convert) proc(x: int) -> G(int, U) {...} }` and `impl G($T, int) { conv :: hook(convert) proc(x: string) -> G(T, int) {...} }`: `G(int, int)(3)` is L0373; naming the second `c2` compiles and prints 3. Fix: expand groups, as `expand_visible_members` does. *Not verified.*

**Simplification**

- [impl.odin:209](src/impl.odin#L209) `declare_impl_member`: the three L0409 branches differ only in a noun. Pick `clash := "member" | "field" | "built-in member"` in one `switch`, then one `errorf("`%s` already has a %s `%s`")`, `append`, `continue`. (about 15 lines)
- [impl.odin:205](src/impl.odin#L205) `declare_impl_member`: the four lines are `name_id := name_identifier(k.c, name)` ([check.odin:1727](src/check.odin#L1727)). (about 3 lines)
- [impl.odin:389](src/impl.odin#L389) `check_associated_member`: a loop around one call with one caller; inline it in the `^Decl` case of `check_impl_block`. (about 8 lines)
- [impl.odin:433](src/impl.odin#L433) `member_candidates` and [impl.odin:572](src/impl.odin#L572) `find_member`: a missing map key already gives a nil slice, which both scanners handle, so drop the `found`/`present` test, or read both tables through `impl_member_table`. (about 8 lines)
- [impl.odin:476](src/impl.odin#L476) `member_is_visible`: the `looked_up` write is redundant, because the only callers that can pass a `.Standard_Format` symbol scan `pkg.extensions` next and mark the same extension. Remove it and `standard_format_hidden`'s second result, which ends in `return local != nil && !local.bound_excluded && (local.pkg == observer || local.public)`. (about 10 lines)
- [impl.odin:468](src/impl.odin#L468) `member_is_visible`: join the early exits into `if sym == nil || sym.bound_excluded` and `if hidden || !capture_field_visible(k, sym)`. (about 6 lines)
- [impl.odin:616](src/impl.odin#L616) `conversion_hooks`: resolves every member's signature although only hooks can match. `sym.hook` is set at declaration (line 251), so test it first and resolve only matches; `info == nil` can `return nil`. (about 5 lines)

**Dead code**

- (branch) [impl.odin:195](src/impl.odin#L195): assigning an empty `d.symbols` does nothing, since every reader uses `len` or `for` and a repeat declaration is barred by `item.declared`.

**Near copies**

- [impl.odin:209](src/impl.odin#L209) and [generic.odin:3677](src/generic.odin#L3677): duplicate and field checks, plus the `Symbol` literal at [impl.odin:240](src/impl.odin#L240) and [generic.odin:3693](src/generic.odin#L3693), differ only in `pkg` and subject. Share `impl_member_clash(k, subject, name)` and `new_impl_member(k, d, name, subject, pkg)`. (about 25 lines)
- [impl.odin:68](src/impl.odin#L68) and [impl.odin:136](src/impl.odin#L136): the same make, read table, declare, install sequence, one filtered to lifecycle hooks. Share `declare_impl_members(k, item, hooks_only := false)`. (about 6 lines)

**Structure and boundaries**

- [impl.odin:494](src/impl.odin#L494) `standard_format_hidden`: formatting policy, also called by [queries.odin:334](src/queries.odin#L334); move it to `format.odin` beside `written_format_member`, its first dependency.
- [impl.odin:607](src/impl.odin#L607) `conversion_hooks` and its banner: `hooks.odin` owns hook roles and validation, and the only caller is in `check_calls.odin`. Move it to either, and drop "semantic hooks" from the header on line 1.
- [impl.odin:146](src/impl.odin#L146) `decl_is_lifecycle_hook`: a pure syntax query also used by [generic.odin:3524](src/generic.odin#L3524); it belongs beside `decl_hook_kind` at [ast.odin:1209](src/ast.odin#L1209).

**Comments**

- [impl.odin:325](src/impl.odin#L325): delete; it is stale, as `generic.odin` passes `k.c` and the callers without a checker are [intrinsic.odin:151](src/intrinsic.odin#L151) and [parallel.odin:219](src/parallel.odin#L219).
- [impl.odin:73](src/impl.odin#L73): wrong phase, since delegates resolve in `resolve_impl_signatures`; write `// handled by later phases`.
- [impl.odin:170](src/impl.odin#L170): delete; it restates `type_declared_in_this_body`.
- [impl.odin:408](src/impl.odin#L408): delete the sentence naming the two callers, which `grep` answers.
- [impl.odin:488](src/impl.odin#L488): cut to `Whether a generated format is hidden from observer: a written or visible local format takes the name (design.md "Interface bodies"); interface slots bypass this.` (about 4 lines)

### src/incremental.odin

Sound: tracing rewinds, eviction, boundary contents across repeated edits and the arena watermark logic turned up no bug. The room is in three item walkers for facts the parser could record, one 123-line procedure with clear seams, and comments that restate `compiler-architecture.md`.

**Simplification**

- [incremental.odin:70](src/incremental.odin#L70) `selects_imports`, `selects_parallel_by_when`, `collect_file_imports`: three walkers, called as a pair at lines 63-64 and 180-182. Have the parser record `File.imports` as it does `File.parallels` ([parser.odin:1928](src/parser.odin#L1928)); one loop over top-level `Item_When`s tests both lists against its span, and lines 189-192 and 350-352 read the list. (about 25 lines)
- [incremental.odin:79](src/incremental.odin#L79) `selects_imports`: if the walker stays, pass `branches[:]` alone. A nil `Item` matches no case of the `#partial switch`, as `validate_item_attributes` already relies on ([attributes.odin:282](src/attributes.odin#L282)).
- [incremental.odin:105](src/incremental.odin#L105) `check_static_packages`: `cache` is bound only for its nil test and line 124 fetches it again. Write `if k.c.package_cache != nil && k.c.error_count == 0`.
- [incremental.odin:294](src/incremental.odin#L294) `try_incremental_check`: the reverse index loop can be `for &entry in cache.entries[checkpoint_index + 1:] { discard_checkpoint(cache, &entry) }`; discarding only decrements the arena's temp count, so order does not matter. (about 2 lines)
- [incremental.odin:331](src/incremental.odin#L331) `try_incremental_check`: `add_source`, copy, `pop` exists only to reuse the line-start scan. Split that scan out of [source.odin:530](src/source.odin#L530) as `make_source` returning a `Source`, then `c.sources[file.file] = make_source(c, path, text)`. (about 2 lines)
- [incremental.odin:343](src/incremental.odin#L343) `try_incremental_check`: the second loop and the `edited` map go away if the first loop (line 319) resets the package's edges and bound flags, and the reparse loop calls `rebuild_active_items(c, entry.pkg)`, which keeps an unchanged view. Both are idempotent. (about 5 lines)

**Dead code**

- (branch) [incremental.odin:347](src/incremental.odin#L347): `pkg.bound_aliases = 0` is a no-op. Only `prepare_package` sets it ([check.odin:203](src/check.odin#L203)), a boundary is taken before its package is prepared, and every edited package lies at or after the boundary, so the restored value is already 0.
- (branch) [incremental.odin:91](src/incremental.odin#L91): `selects_parallel_by_when` is only ever given `File.items`, and `parse_top_level_item` ([parser.odin:561](src/parser.odin#L561)) never returns an `Item_Block`; one exists only as a `when` branch, which this procedure does not enter.
- (branch) [incremental.odin:206](src/incremental.odin#L206): `collect_file_imports` is unreachable on `Item_Block` for the same reason, since it does not descend into `Item_When`.
- `session_check_stats` ([incremental.odin:17](src/incremental.odin#L17)): not dead, but its only callers are `incremental_test.odin`, `session_test.odin` and `lsp/server_test.odin`. It is documented API; `Compilation_Check_Stats`, `stats_arena` and lines 365-367 exist solely to serve it.

**Data structures and algorithms**

- [incremental.odin:258](src/incremental.odin#L258) `try_incremental_check`: `texts` is a map keyed by dense source indices. `make([]string, len(c.sources), context.temp_allocator)` indexes directly, once per loaded file per check, with no hashing and no extra lines. Minor.

**Near copies**

- [incremental.odin:334](src/incremental.odin#L334) and [packages.odin:232](src/packages.odin#L232): both lex, allocate a `File`, parse into the semantic allocator and delete the tokens. Extract `parse_source(c, index) -> ^File` from `parse_file`; the replacement becomes one call. (about 3 lines)
- [incremental.odin:94](src/incremental.odin#L94) and [packages.odin:331](src/packages.odin#L331): the same test of `parallels` offsets against a span. Share `parallel_within(parallels, span)`.

**Structure and boundaries**

- [incremental.odin:247](src/incremental.odin#L247) `try_incremental_check`: 123 lines doing four jobs with seams already marked by blank lines and comments: compare inputs (251-279), `restore_checkpoint` (291-310), `reparse_edited_files` (312-342), `rebind_edited_packages` (343-357). The function that remains reads as the pipeline.
- [incremental.odin:60](src/incremental.odin#L60) and [incremental.odin:103](src/incremental.odin#L103): `static_package_graph` and `check_static_packages` are the batch pipeline too, called from `compile_program` ([packages.odin:34](src/packages.odin#L34)); only the checkpoint hook at line 105 is incremental. They belong in `packages.odin`, leaving this file what the source-code map says it owns.

**Comments**

About 12 lines can go across the file, mostly text repeating `compiler-architecture.md` "Incremental checking".

- [incremental.odin:54](src/incremental.odin#L54): shorten to: a file-scope `when` changes the graph only if it selects an `import` or a `parallel` (hence `core:thread`); one selecting declarations settles with its own package.
- [incremental.odin:177](src/incremental.odin#L177): delete; the parameter names and the one call say it.
- [incremental.odin:181](src/incremental.odin#L181) and [incremental.odin:188](src/incremental.odin#L188): delete; the first repeats lines 85-86 and the second narrates the loop below it.
- [incremental.odin:280](src/incremental.odin#L280): `// Checkpoints stop at errors, so an edit after one restarts there.`
- [incremental.odin:286](src/incremental.odin#L286): `// A batch reports syntax errors before any warning (compiler-architecture.md "Incremental checking").`
- [incremental.odin:291](src/incremental.odin#L291): drop the last clause's restatement of [session.odin:29](src/session.odin#L29): keep `Rewind exactly, including mutations to earlier types, generic templates, registries and syntax.`
- [incremental.odin:323](src/incremental.odin#L323): `// In loading order (source indices), as a batch reports syntax diagnostics.`
- [incremental.odin:360](src/incremental.odin#L360): move to the early return at line 126 as `// A rewind keeps its pre-edit boundary: recapturing after reparsing would accumulate obsolete syntax.` The middle sentence narrates lines 315-318.

### src/interface.odin

What remains is the part shared with `erased.odin` and `generic.odin`.

**Near copies**

- [interface.odin:1352](src/interface.odin#L1352), [interface.odin:1392](src/interface.odin#L1392) and [erased.odin:747](src/erased.odin#L747): the same steps from requirement to `composed`, clone and `bound_arguments`. Share `composed_application(k, requirement) -> (^Interface_Info, []Generic_Arg, bool)`.
- [interface.odin:312](src/interface.odin#L312), [interface.odin:347](src/interface.odin#L347) and [generic.odin:3070](src/generic.odin#L3070): the enum, `convert_const` and `nil_converts` test. Find the value and its type once, then call a shared `convert_generic_value`; `report_unrepresentable_argument` goes.
- [interface.odin:1018](src/interface.odin#L1018) and [erased.odin:893](src/erased.odin#L893): both loop over candidates, filter for a method, and test `slot_matches`. With a plain-`bool` `result_inout`, `check_slot_requirement` can call `find_witness_slot`, moved here.

### src/intrinsic.odin

Well-commented and cleanly owned; its linear scans run over a per-package, compiler-fixed list, so they are fine. It accepts several written forms it should reject (each reproduced against `lokec.exe` with a vendored `core:mem`), and about 55 lines can go, mainly filtering that `validate_attribute_list` could do and defensive checks the contribution order makes unnecessary.

**Bugs**

- `BUG-intrinsic-1` **medium** [intrinsic.odin:407](src/intrinsic.odin#L407) `check_intrinsic_signature`: any untyped first parameter of a member passes, not only `self`; `slot_signature` then yields `INVALID_TYPE` and line 413 returns with no report. *Confirmed: Reproduced: in a -collection core:mem, `allocator :: proc(this)` and `proc(self, other)` build with exit 0 and -doc prints them; `proc(this: int)` gets L0736, ordinary members L0408. Severity is low, not medium: only core-package authors reach it.*
  Scenario: `allocator :: proc(this) -> Allocator ---;` or `proc(self, other)` in `impl Arena` compiles, unchecked, and `-doc` shows it. Fix: test `parameter_is_bare_self(parameter, position)` in place of `position == 0`.
- `BUG-intrinsic-2` **low** [intrinsic.odin:78](src/intrinsic.odin#L78) `bind_intrinsic_impl`: the impl's own attributes are never validated, since `flatten_item` drops the impl and `validate_impl_attributes` reads only `active_items`. *Not verified.*
  Scenario: `@(bogus) impl Arena { @(intrinsic) ... }` gives no L0606. Fix: call `validate_attribute_list(k, v.attributes, .Impl)` first.
- `BUG-intrinsic-3` **low** [intrinsic.odin:122](src/intrinsic.odin#L122) `bind_intrinsic`: the shape check ignores `d.declared_type` and `literal.where_clauses`, though a struct's `where` is rejected at line 499. *Not verified.*
  Scenario: `Arena: int : ---;`, `Failure_Policy: int : enum { Panic, Trap }` and `try_arena :: proc(...) -> ... where 1 == 2 ---;` all compile. Fix: require both empty in `shape_ok`.
- `BUG-intrinsic-4` **low** [intrinsic.odin:121](src/intrinsic.odin#L121) `bind_intrinsic`: `decl_proc_literal` looks through `operator(...)` and `hook(...)`, so a wrapper passes as a procedure and states a role nothing checks. *Not verified.*
  Scenario: `init :: hook(drop) proc(...) -> Arena ---;` and `init :: operator(+) proc(...) -> Arena ---;` compile. Fix: use `decl_proc` at lines 121, 220 and 373; line 129 then reports L0734.

**Simplification**

- [intrinsic.odin:206](src/intrinsic.odin#L206) `validate_intrinsic_attributes`: lines 206-219 filter `intrinsic` out only because `validate_attribute_list` rejects it, then re-implement its L0608 and L0609 with the same text. Add `allow_intrinsic := false` to it and pass `d.attributes` directly. (about 12 lines)
- [intrinsic.odin:269](src/intrinsic.odin#L269) `contributed_here`: at bind time `pkg.scope.names` holds only contributions, since line 133 of `check.odin` runs before any declaration is collected. Drop it and its tests at lines 83 and 147. (about 12 lines)
- [intrinsic.odin:417](src/intrinsic.odin#L417) `check_intrinsic_signature`: replace the flag loop at lines 417-424 with `same := slice.equal(params, sym.params) && slice.equal(modes, info.param_modes) && result == sym.result && result_inout == sym.result_inout`. `info` is never nil for a `.Proc` here. (about 7 lines)
- [intrinsic.odin:222](src/intrinsic.odin#L222) `validate_intrinsic_attributes`: the record is looked up twice (lines 222-226 and 235-242). Bind `record` once at the top, with `literal`. (about 4 lines)
- [intrinsic.odin:60](src/intrinsic.odin#L60) `bind_intrinsic_items`: the `file` parameter here and on `bind_intrinsic_impl` and `bind_intrinsic` is always `k.file_node` (set at line 51). Drop it and read `k.file_node` at line 197. (3 signatures, no lines)

**Dead code**

- (branch) [intrinsic.odin:448](src/intrinsic.odin#L448): `existing == nil` cannot happen. `.Proc` contributions come only from `provider_constructor`, which names every parameter, and `allocator`, whose only parameter is the skipped receiver. Lines 448-451 can go, and the check no longer mutates a contributed symbol.
- (branch) [intrinsic.odin:440](src/intrinsic.odin#L440): `flat < len(sym.param_defaults)` here and `flat < len(sym.param_symbols)` at line 446 are always true: `synth_proc` sizes both to `len(params)`, and lines 417-424 proved the lengths equal.
- (branch) [intrinsic.odin:192](src/intrinsic.odin#L192): `d.top_level = true` is never read. Readers reach a `Decl` through `active_items`, a statement or `sym.decl`; an intrinsic declaration is in none of these, and `doc.odin` reads `d.symbols`, not `top_level`.
- (branch) [intrinsic.odin:346](src/intrinsic.odin#L346): `len(v.names) > 0` is always true: `parse_declaration` returns a `Decl` only with at least one name, there is no file-scope destructuring, and lines 116 and 134 already assume it.

**Near copies**

- [intrinsic.odin:535](src/intrinsic.odin#L535) and [intrinsic.odin:549](src/intrinsic.odin#L549): `member_list` and `field_list` differ only in appending `: type`. Keep `public` as `[]Symbol_Id` and write one `symbol_list(c, symbols, typed: bool)` using `fmt.sbprintf`. (about 12 lines)
- [intrinsic.odin:182](src/intrinsic.odin#L182) and [intrinsic.odin:279](src/intrinsic.odin#L279): the duplicate check and `described` scan `pkg.intrinsics` for the same symbol. One `description_of(pkg, symbol_id) -> ^Intrinsic_Decl`, nil when absent, serves both. (about 3 lines)
- [intrinsic.odin:347](src/intrinsic.odin#L347) and [intrinsic.odin:351](src/intrinsic.odin#L351): one L0734 message, spelled out twice. Give it a constant here.

**Comments**

- [intrinsic.odin:15](src/intrinsic.odin#L15): the first sentence restates the struct. Keep only "`subject` is the type an `impl` member belongs to."
- [intrinsic.odin:57](src/intrinsic.odin#L57): delete "File scope and top-level blocks."; the switch shows it. Keep the sentence about `when`.

### src/iterate.odin

What remains are near copies that need helpers shared across files.

**Near copies**

- [iterate.odin:49](src/iterate.odin#L49) and [iteration_mutable.odin:41](src/iteration_mutable.odin#L41), [container.odin:313](src/container.odin#L313): name, `new_type`, fields, label. Share `new_compiler_struct(c, proto, name, label, ..fields)`; about 30 lines here on top of the literal change.
- [iterate.odin:68](src/iterate.odin#L68), [simd.odin:15](src/simd.odin#L15) and [box.odin:45](src/box.odin#L45): identical apart from the name. Share `predeclared_callee(k, callee, "Range")`.
- [iterate.odin:1064](src/iterate.odin#L1064), [optional.odin:607](src/optional.odin#L607) and [check.odin:560](src/check.odin#L560): the L0304, reserved-name and L0305 checks for a new local. Share one proc taking the identifier, span and shadow-lookup scope.

### src/lifecycle.odin

The dataflow core is sound and the file is readable, but `exchange` lets an owned place through unmoved (a heap-corrupting double free) and unwind paths do not vote on deferred assignments. Much of the rest is repeated error plumbing, and the file holds four loosely related jobs.

**Near copies**

- [lifecycle.odin:589](src/lifecycle.odin#L589), [union.odin:484](src/union.odin#L484), [optional.odin:108](src/optional.odin#L108) and [check_expr.odin:2721](src/check_expr.odin#L2721): `classify_copy_cost` then `classify_copy` with the same arguments. A `classify_costed_copy` returning the bool serves these; box and insertion differ and keep the two calls.
- [lifecycle.odin:38](src/lifecycle.odin#L38), [lifecycle.odin:81](src/lifecycle.odin#L81), [lifecycle.odin:199](src/lifecycle.odin#L199), [check_builtin.odin:748](src/check_builtin.odin#L748) and [box.odin:226](src/box.odin#L226): `make` a `[]Expr` then assign each slot. A variadic `bind_arguments(k, v, ..values)` makes each one line.

### src/operators.odin

What is left restates the group "Operator binding and the built-in operator table" under "Findings that span files".

**Near copies**

- [operators.odin:451](src/operators.odin#L451) and [overload.odin:902](src/overload.odin#L902): both bind arguments to slots and fill defaults. Shared form: one `bind_candidate_slots(k, cand, span, subject) -> ([]Expr, bool)`; the call path adds its order tracking around it.

**Structure and boundaries**

- [operators.odin:325](src/operators.odin#L325): the built-in operator table is split between this section, `builtin_operator_applies` (check_expr.odin:2658) and `compound_applies` (check.odin:4197), which is how shifts and SIMD fell out of some paths and not others. Move all of them under this file's "the built-in priority" section.

### src/optional.odin

What remains here waits on helpers shared across files.

**Near copies**

- [optional.odin:713](src/optional.odin#L713) and [check.odin:4464](src/check.odin#L4464): the same "first three, then `, ...`" list and "does not cover" message, differing in the name source and the code. Each collects names into a temp slice and calls one `report_uncovered(k, s, subject, code, names)`. (about 12 lines)
- [optional.odin:603](src/optional.odin#L603), [iterate.odin:1062](src/iterate.odin#L1062) and [check.odin:560](src/check.odin#L560): the L0304, reserved-name and L0305 checks for a new local. Share `check_local_name(k, name, id, span) -> bool`; they differ in `check.odin`'s synthesized-name exemption and in whether a reserved name still binds. (about 14 lines)
- [optional.odin:574](src/optional.odin#L574), [check.odin:4390](src/check.odin#L4390) and [expand.odin:36](src/expand.odin#L36): the same `||=` merge of `Flow_Info` fields. Share `merge_flow(&flow, other)` beside `Flow_Info`. (about 6 lines)
- [optional.odin:259](src/optional.odin#L259), [optional.odin:272](src/optional.odin#L272), [check.odin:4796](src/check.odin#L4796) and [expand.odin:640](src/expand.odin#L640): a synthesized one-argument `Expr_Call`, five lines each. Share `new_call(c, span, callee, argument)`. (about 10 lines)

### src/parallel.odin

What remains here belongs to the groups under "Findings that span files".

**Near copies**

- [parallel.odin:651](src/parallel.odin#L651), [parallel.odin:668](src/parallel.odin#L668), [parallel.odin:723](src/parallel.odin#L723) and [check.odin:3888](src/check.odin#L3888), [check.odin:3856](src/check.odin#L3856), [check.odin:3897](src/check.odin#L3897): the same file-private ident, deref, and local builders under two names; [capture.odin:137](src/capture.odin#L137), [check_calls.odin:204](src/check_calls.odin#L204) hand-build these nodes too. Share one set of `synth_*`, of which the ident, selector and deref builders are already package-visible.
- [parallel.odin:181](src/parallel.odin#L181), [parallel.odin:723](src/parallel.odin#L723), [parallel.odin:735](src/parallel.odin#L735) and [capture.odin:110](src/capture.odin#L110), [capture.odin:140](src/capture.odin#L140): one-name `Decl` builders differing only in `kind` and type. Use one `synth_decl(c, kind, name, type, value, span)` built on `synth_name`, which interns, so callers drop their `id`. (about 20 lines here)
- [parallel.odin:700](src/parallel.odin#L700) and [capture.odin:95](src/capture.odin#L95): a local struct whose field types are aliases only its scope binds. They differ in field names and spans; `synth_record` taking `[]Name`, with each field's span from its `Name`, serves both, moving capture fields from `entry.span` to `entry.name.span`. (about 15 lines)

### src/private_names.odin

Coherent and well tested on its main paths, but three drivers have grown around one by-name walk, so setup and guards repeat and the by-name model has gaps. Every bug below was reproduced with the `lokec.exe` built at this commit; roughly a sixth of the file could go.

**Near copies**

- [private_names.odin:515](src/private_names.odin#L515) `walk`, [doc.odin:578](src/doc.odin#L578) `api_refs` and [ast.odin:1388](src/ast.odin#L1388) `type_syntax_any_name` repeat one recursion and have drifted: the other two visit a composite's `via`, `walk` does not. A shared `syntax_children(e, out)`, like the `parts` in `pattern_shape`, leaves `walk` the Ident, Selector, `Type_Proc` and Composite arms. (about 60 lines here)
- [private_names.odin:488](src/private_names.odin#L488) `poly_names` and [doc.odin:781](src/doc.odin#L781) `bind_poly_names` are identical; so are [private_names.odin:473](src/private_names.odin#L473) `bind_generic` and [doc.odin:771](src/doc.odin#L771) `bind_generic_params`. Keep one of each, not file-private. (about 15 lines)
- [private_names.odin:417](src/private_names.odin#L417) `field_is_exported` and [doc.odin:1106](src/doc.odin#L1106) `field_shown` have one body; doc's `package_name == "main"` is always false here, since this pass skips `main`. Share `field_exported(c, file, field)`. (about 9 lines)

### src/provenance_effect.odin

Sound and readable: the saturation loop, arena handling, and recording discipline held up under checking, and no bug was found. What can go is bookkeeping: statistics fields and a topology struct that restate what is already at hand, plus two near-identical fact writers.

**Simplification**

- [provenance_effect.odin:155](src/provenance_effect.odin#L155) `prov_note_replay_statistics`: the time and peak fields on `Prov_Effect_Program` (lines 79-80) are only copied into `c.provenance_stats`. Add to `stats := &k.c.provenance_stats` where measured, drop the proc and fields; keep `replays`, which tests read. (about 12 lines)
- [provenance_effect.odin:181](src/provenance_effect.odin#L181) `prov_finish_effect_program`: `Prov_Topology` is a field-by-field view of the construction graph, which outlives every round in the same arena. Hold `construction: ^Flow_Graph` on the program and have `prov_fact_graph` read it; keep `program.input`, as a later query can replace `graph.input`. (about 24 lines)
- [provenance_effect.odin:69](src/provenance_effect.odin#L69) `Prov_Effect_Program.alloc`: always equals the recording graph's `alloc`, since `effect_program` is set only at [cfg.odin:528](src/cfg.odin#L528) on the graph built with it. Use `graph.alloc` at line 250, [cfg_provenance.odin:625](src/cfg_provenance.odin#L625) and [cfg_provenance.odin:7801](src/cfg_provenance.odin#L7801), whose ternary then goes. (about 3 lines)
- [provenance_effect.odin:101](src/provenance_effect.odin#L101) `build_provenance_replay`: `program.input` is assigned on both paths (also line 179); set it once after the walk at line 96. `initial.normalized_effects` (lines 104, 149) can move there too, as it is only a pointer. (about 4 lines)

**Dead code**

- (branch) [provenance_effect.odin:265](src/provenance_effect.odin#L265): `if value == 0` here and at line 276 cannot fire: the only callers ([cfg_provenance.odin:7515](src/cfg_provenance.odin#L7515), [cfg_provenance.odin:7519](src/cfg_provenance.odin#L7519)) guard `value != nil`, so `prov_input_value` is non-zero, and replay passes the recorded id.
- (branch) [provenance_effect.odin:261](src/provenance_effect.odin#L261): the defaults `source = nil` and `storage := false` on `prov_merge_provider_parent` are never used; its one caller and the replay pass both.
- `normalized_effects` ([cfg.odin:169](src/cfg.odin#L169)): set at lines 104 and 149 but read only by `provenance_normalization_test.odin`. Not dead, but it exists only for tests.

**Data structures and algorithms**

- [provenance_effect.odin:205](src/provenance_effect.odin#L205) `prov_fact_graph`: six maps are re-inserted key by key into fresh maps every round, growing with a body's locals and operators times its rounds. `operator_calls` should never be written in a round (a new entry means a node missing from the frozen input), so share it; `reserve` the rest. Performance only; measure with `perf.ps1`.

**Near copies**

- [provenance_effect.odin:261](src/provenance_effect.odin#L261) and [provenance_effect.odin:272](src/provenance_effect.odin#L272): `prov_merge_provider_parent` and `prov_assign_value_region` differ only in the final merge, and `Prov_Effect_Parent` and `Prov_Effect_Assign` are the same struct. One proc and operation with a `provider: bool` serves both, passed at [cfg_provenance.odin:7518](src/cfg_provenance.odin#L7518) and [cfg_provenance.odin:7525](src/cfg_provenance.odin#L7525). (about 12 lines)
- [provenance_effect.odin:267](src/provenance_effect.odin#L267) and [cfg_provenance.odin:4019](src/cfg_provenance.odin#L4019): the same three lines merge a region into `provider_parents`. A small `prov_merge_parent(graph, symbol, set)` serves both, since the seed must not call the recording proc. (about 2 lines)

**Structure and boundaries**

- [provenance_effect.odin:253](src/provenance_effect.odin#L253): the six fact writers on lines 253-312 sit here while their siblings (`prov_store_region`, `prov_declare_region`, `prov_merge_moved_bits`, and others) live in `cfg_provenance.odin`, using helpers defined there. Move them beside those, leaving this file the operation types, recording, replay, and driver.

**Comments**

- [provenance_effect.odin:99](src/provenance_effect.odin#L99): "The walk recorded no carried fact, so replay could change nothing: this graph is final." The current text misstates the test (weight zero, not "changed") and records history ("the former fixed point").
- [provenance_effect.odin:167](src/provenance_effect.odin#L167): drop "before reclaiming construction scratch", which is stale: nothing is reclaimed here and the construction graph is returned. Start at "Describe every value: no later fact round may add values, ...".
- [provenance_effect.odin:177](src/provenance_effect.odin#L177): "These tables share the construction graph's arena, so a round reuses them." The second sentence argues against a second copy no one proposes.
- [provenance_effect.odin:195](src/provenance_effect.odin#L195): "The caller seeds its facts; its loan and lifecycle buffers stay empty." The "event buffers" claim is false: materialization reads what replay emitted into `block.prov` ([provenance_event.odin:295](src/provenance_event.odin#L295)).
- [provenance_effect.odin:46](src/provenance_effect.odin#L46): "The walk state materialization restores." Saturation rounds (lines 315-318) never restore it, so "its replay reads" misleads.
- [provenance_effect.odin:322](src/provenance_effect.odin#L322): one line is enough, citing `compiler-architecture.md "Normalized provenance input"`, which states this rule; `assert`s enforce it.
- [provenance_effect.odin:139](src/provenance_effect.odin#L139): "Only fact-dependent events change once the facts settle; they are materialized again, interleaved with one more replay."

### src/provenance_form.odin

Small, focused and in good shape: every form, field and accessor has a reader, and no bugs turned up. What remains is one accessor that leaves its sibling hand-written and a pack walk copied across the compiler.

**Simplification**

- [provenance_form.odin:143](src/provenance_form.odin#L143) `prov_call_values`: [cfg_provenance.odin:10704](src/cfg_provenance.odin#L10704) spells out the same lookup because it needs `.pack`, in a procedure that already called this at 10683. Return the form as `prov_call_form`; 10683 keeps it, 10704 goes, and `prov_operand_value` can become file-private. (about 1 line)

**Near copies**

- [provenance_form.odin:111](src/provenance_form.odin#L111), [cfg.odin:2843](src/cfg.odin#L2843), [cfg_provenance.odin:8528](src/cfg_provenance.odin#L8528), [:10017](src/cfg_provenance.odin#L10017), [emit_llvm_stmt.odin:264](src/emit_llvm_stmt.odin#L264): each keeps `next_element`/`next_spread` to pick the next pack operand. Shared form in `ast.odin`: `call_pack_next(call, is_spread, &cursor) -> Expr`, about 6 lines off each of the first two.
- [provenance_form.odin:57](src/provenance_form.odin#L57), [provenance_input.odin:334](src/provenance_input.odin#L334), [cfg.odin:2434](src/cfg.odin#L2434), [cfg_provenance.odin:2131](src/cfg_provenance.odin#L2131): all recompute box-ness of a `^` operand, while [cfg.odin:870](src/cfg.odin#L870) and [cfg_provenance.odin:6707](src/cfg_provenance.odin#L6707) read `v.boxed`. Read `v.boxed` everywhere.

### src/provenance_input.odin

Compact and well ordered, with no bug found. The weight is in two mechanisms that outlive their need: a deep copy-on-write of the whole input, and a `places` map that repeats what each value already records.

**Simplification**

- [provenance_input.odin:93](src/provenance_input.odin#L93) `prov_writable_input`: production reads `program.input` only during `build_provenance_replay`; `normalized_effects` is read only by tests, and the `weight == 0` path already lets a finished graph write it directly. Clear `frozen` as the build returns, or reduce this to the assert; drop `seed` and `prov_clone_transfer`. `normalization_parameter_seed` and two test checks need adjusting. (about 60 lines)
- [provenance_input.odin:120](src/provenance_input.odin#L120) `new_prov_input`: if the copy stays, it can be shallow. Seed and copy share the analysis arena, no recorded path is written in place, and `Prov_Value.form` slices are already shared at L122. Keep the map loops; drop the clones at L123, L125-129, L130, L132 and L134. (about 45 lines)
- [provenance_input.odin:75](src/provenance_input.odin#L75) `Prov_Input.alloc`: its one reader is `strings.clone(name, graph.input.alloc)` at [cfg_provenance.odin:6808](src/cfg_provenance.odin#L6808), where it equals `graph.alloc`, which already holds `name`; replay asserts first. Store `name` and delete the field and L104. (about 3 lines)
- [provenance_input.odin:242](src/provenance_input.odin#L242) `prov_input_key`: its only caller is `prov_input_place`; build the key there, or lose both with the `places` change below. (about 6 lines)

**Dead code**

- `Prov_Place.type` ([provenance_input.odin:35](src/provenance_input.odin#L35)): written at L304, L305 and L309; no production code reads it, only the check at [provenance_normalization_test.odin:460](src/provenance_normalization_test.odin#L460). Removing it also frees `prov_place_as` from `key.repr` and makes L305 `return {}`.
- (branch) [provenance_input.odin:208](src/provenance_input.odin#L208): `graph.prov != nil && base != nil` is redundant. A Lifecycle graph never pushes onto `converting`, and all three push sites pass real nodes. Replace L208-212 with `#reverse for open in graph.converting { if open.node == base { return open.repr } }`.
- (branch) [provenance_input.odin:358](src/provenance_input.odin#L358): `.String_View, .CString_View` never reach a built-in `Expr_Index`. `check_index` rejects a view with L0563 and a C string with L0362; a user operator already returned at L342. The same labels at [cfg_provenance.odin:6508](src/cfg_provenance.odin#L6508) go too.
- (branch) [provenance_input.odin:354](src/provenance_input.odin#L354): `info != nil` always holds, since `underlying_kind` just returned `.Pointer`. Use `path := prov_index_path_in(graph, v, underlying_info(c, operand).element)`.
- (branch) [provenance_input.odin:342](src/provenance_input.odin#L342): `v.operand == nil` cannot hold; the parser ([parser.odin:2564](src/parser.odin#L2564)) and `lowered_index` ([check.odin:3915](src/check.odin#L3915)) always set it, and the sibling case at L334 has no such check.

**Data structures and algorithms**

- [provenance_input.odin:81](src/provenance_input.odin#L81) `places`: repeats `Prov_Value.place` under the same key, and every non-identifier value hashes it once more, even a call that has no place. Let `prov_input_place` return `prov_value(graph, prov_input_value(graph, e)).place` and fold `prov_place_as` into `prov_describe_place`. Caveat: a replay query of a value never interned would now assert. (about 20 lines)
- [provenance_input.odin:84](src/provenance_input.odin#L84) `calls`: keyed by the 72-byte `Prov_Input_Key`, but [provenance_call.odin:237](src/provenance_call.odin#L237) always leaves `repr` zero and `capture` false, so only node and expansion (24 bytes) vary. A smaller key, with captures in their own map, drops `capture` from L66 and cuts hashing on each call lookup.

**Near copies**

- [provenance_input.odin:358](src/provenance_input.odin#L358) and [cfg_provenance.odin:6508](src/cfg_provenance.odin#L6508): one kind list, where this site prepends a wildcard step for an element behind a view and `prov_place_hops` strips it again. Nothing ties the two together; a shared predicate such as `type_indexes_through_view` would.

**Structure and boundaries**

- [provenance_input.odin:254](src/provenance_input.odin#L254) `prov_intern_value`: `expansion` and `graph.expansion` are two sources for one fact. `prov_describe_form` uses the parameter, but `prov_describe_place` (via `prov_input_value`, L325) and `prov_storage_id` (L143) use the graph, so a mismatch caches a place under one expansion with operands from another. Assert equality and drop the parameter from the form helpers, or thread it through.
- [provenance_input.odin:348](src/provenance_input.odin#L348): the syntax-to-path helpers this walk needs (`prov_field_step`, `prov_index_path`, `prov_index_path_in`, `prov_map_entry_step`, about [cfg_provenance.odin:6445](src/cfg_provenance.odin#L6445) and [6770](src/cfg_provenance.odin#L6770)) live in `cfg_provenance.odin`, and the latter writes `map_key_entries` directly. They belong here with the table they fill.

**Comments**

- [provenance_input.odin:9](src/provenance_input.odin#L9): L9-10 and L14-15 both explain zero, and L14-15 sits on `Written_Storage` though it is about the IDs. Merge above `Storage_Id`: "Body-local identities in `Prov_Input`; zero is unresolved storage or no value. Keys, not IDs, correspond across rebuilds." (about 2 lines)
- [provenance_input.odin:99](src/provenance_input.odin#L99): L99-101 repeat L90-92, and "The copy owns its slices" is untrue of `Prov_Value.form`, shared at L122. Replace with: "`seed` is the frozen input `prov_writable_input` copies." (about 2 lines)
- [provenance_input.odin:86](src/provenance_input.odin#L86): "Preserve the bounded constant-map-key assignment along with cached paths." does not say what the map is. Use: "A constant map key's entry slot, at most `MAP_KEY_SLOTS` of them; cached paths name these."

### src/provenance_read.odin

Small and readable, with no confirmed bugs. Its main costs are a two-field struct that mostly repeats `Prov_Value`, and a dispatch that nearly duplicates `prov_written_aliases_at`.

**Simplification**

- [provenance_read.odin:5](src/provenance_read.odin#L5) `Prov_Read_Input`, `prov_input_read`: `unknown_alias` only copies `value.unknown_alias`, and every caller has the value or reads one field. Replace both with `prov_read_fallback(form: Prov_Form) -> Value_Id`. (about 9 lines)

**Near copies**

- [provenance_read.odin:47](src/provenance_read.odin#L47) and [cfg_provenance.odin:6046](src/cfg_provenance.odin#L6046): both dispatch on direct place, carrier load, then operand fallback. They differ in whether a read that finds nothing is unresolved. Shared form: one place-dispatch proc with an `unresolved: bool`, after checking the storage-to-root round trip at 6052 is not needed. (about 10 lines)

**Structure and boundaries**

- [provenance_read.odin:37](src/provenance_read.odin#L37): the read logic crosses three files: `prov_value_aliases` here, this file, then `prov_written_aliases_of` and back. Move `Written_Alias`, `prov_written_aliases_at` and `prov_written_aliases_of` ([cfg_provenance.odin:5996](src/cfg_provenance.odin#L5996), [6046](src/cfg_provenance.odin#L6046), [6066](src/cfg_provenance.odin#L6066)) here.
- [provenance_read.odin:16](src/provenance_read.odin#L16): a user `operator([])` value forwards its receiver's targets, while `prov_region_of` follows the operator call ([cfg_provenance.odin:4700](src/cfg_provenance.odin#L4700)) and a plain call is unresolved. Probes with known receiver targets rejected the same as a plain call, so align them or say why they differ.

### src/provenance_transfer.odin

The logic holds up and its comments are already terse; I found no bug, and probes of the two suspect spots below gave no wrong result. The representation is richer than its consumers: three transfer variants, a mode, a type, and a copy-operation table all carry distinctions that nothing outside a test reads.

**Simplification**

- [provenance_transfer.odin:29](src/provenance_transfer.odin#L29) `Prov_Transfer_Forward`/`Join`/`Aggregate`: all three consumers treat them alike (`prov_transfer_parts` twice, `prov_clone_transfer`), and Forward needs the `single: [1]` workaround in `prov_transfer_parts`.
  Merge into one `Prov_Transfer_Parts{components, backing}` with a one-component constructor helper; the facts file loses its arm splits and the clone two arms.
  (about 20 lines across files; tests at provenance_normalization_test.odin:358, 374, 712 change)
- [provenance_transfer.odin:19](src/provenance_transfer.odin#L19) `Prov_Component.type`/`mode`: `type` is read only at line 60 and in `prov_value_aliases`, both for clones, and every clone call passes it, so the `prov_type_at` default at line 57 is computed only to go unread.
  `mode` is only tested for clone-or-not, so `copy_type: Type_Id`, set only for a clone, replaces both and the `mode :=` locals (160, 193, 207, 219).
  `.Move` is then pinned only by the test at provenance_normalization_test.odin:377. (about 12 lines)
- [provenance_transfer.odin:64](src/provenance_transfer.odin#L64) `prov_component`: the `_ = prov_value_transfer` here and at 104, 147, and [provenance_effect.odin:245](src/provenance_effect.odin#L245) may be redundant now that `prov_value_aliases` describes what it reads. They also describe a value before the input freezes, where replay asserts, so remove them only with a replay run to check.
  Have the facts file call `prov_value_transfer` (lines 20, 75, 87) and delete those calls; the freeze loop describes the rest. (about 6 lines, and no site can forget it)
- [provenance_transfer.odin:134](src/provenance_transfer.odin#L134) `prov_describe_transfer`: `fallible_of` then `prov_extend(graph, nil, proj_field(shape.success))` repeats at 134, 201-202, and 234-235.
  A file-private `prov_success_path(graph, type) -> []Proj_Step`, nil when not fallible, turns the two five-line `prefix` blocks into one line each. (about 8 lines)

**Dead code**

- (branch) [provenance_transfer.odin:269](src/provenance_transfer.odin#L269): `mode` and `type` (line 270) of the returned component are never read: its only consumers, `prov_stored_region_at` and `prov_copy_component_region`, read `source`, `from`, `copy_from`, and `copy.type`. Line 270's `prov_type_at` is wasted work.
- (branch) [provenance_transfer.odin:249](src/provenance_transfer.odin#L249): `as_type` of `prov_input_stored_copy` always resolves to `value.type`: copying callers pass nothing ([cfg_provenance.odin:4261](src/cfg_provenance.odin#L4261)) or `prov_value(value).type` ([:4272](src/cfg_provenance.odin#L4272), [:5595](src/cfg_provenance.odin#L5595) through `prov_result_region_fields`). Drop the parameter; `type := value.type`.
- (branch) [provenance_transfer.odin:70](src/provenance_transfer.odin#L70): `index >= 0` cannot fail. Line 212 is the only non-default `index`, reached only by `make`, whose `bound` always has `max_counts + 1 >= 2` slots ([check_builtin.odin:677](src/check_builtin.odin#L677)). Write `v.bound[len(v.bound) - 1]` at 212 and drop the parameter.

**Data structures and algorithms**

- [provenance_transfer.odin:44](src/provenance_transfer.odin#L44) `prov_input_copy_operation`: a per-body map caches `lifecycle_of(c, type).custom_try_clone`, itself a map lookup on settled annotations; its two query callers read only `.hook` ([cfg_provenance.odin:5135](src/cfg_provenance.odin#L5135), [:5215](src/cfg_provenance.odin#L5215)).
  A direct lookup removes the struct, the table, its seed loop, and a replay assert a query could trip on an unrecorded type; compiler-architecture.md:204 loses an item. (about 14 lines across files)
- [provenance_transfer.odin:83](src/provenance_transfer.odin#L83) `prov_value_transfer`: `transfers` is a `map[Value_Id]Prov_Transfer` over dense IDs, growing with a body's expressions and read on every alias and region query, each read hashing and copying a union of about 100 bytes.
  A `Prov_Value` field with a `described` bit, or a slice parallel to `values`, fits. Smaller than the interning cost open-questions.md records, but a local change.

**Near copies**

- [provenance_transfer.odin:257](src/provenance_transfer.odin#L257) and [cfg_provenance.odin:1461](src/cfg_provenance.odin#L1461): both map a widened path's first field step back to the source variant. Make `prov_widened_region_path` package-visible and use it with `source = prov_value_beneath(graph, id, .Widening)`.
  This drops the `.(Prov_Transfer_Aggregate)` assertion at 253 and the search through components; a void variant then yields an empty query rather than `{}`, with the same result. (about 10 lines)
- [provenance_transfer.odin:110](src/provenance_transfer.odin#L110) and [provenance_transfer.odin:218](src/provenance_transfer.odin#L218): the same per-variant widening loop, differing in mode, allocator, and the `copy` override. `prov_widening_transfer(graph, source, from, to, clones := false, allocator: Expr = nil)` serves both, and line 108's `to` goes. (about 7 lines)

**Structure and boundaries**

- [provenance_transfer.odin:93](src/provenance_transfer.odin#L93) `prov_describe_transfer`: 150 lines, the call arm 73 of them. Seams: `prov_call_transfer` for 167-239 and `prov_composite_transfer` for 144-165, leaving a short dispatch over the node.
- [provenance_transfer.odin:119](src/provenance_transfer.odin#L119): operands go through `prov_input_value`, which reads the walk's open conversions and `graph.expansion`, while forms use `prov_operand_value`. `prov_storage_id` at 101 also keys on `graph.expansion`, a precondition only the freeze loop ([provenance_effect.odin:171](src/provenance_effect.odin#L171)) arranges.
  Have `prov_value_transfer` set the value's expansion around the describe and use `prov_operand_value`. I found no failing input.
- [provenance_transfer.odin:101](src/provenance_transfer.odin#L101): `materialized = !direct` also covers a named owner reached through a pointer, whose `place.path` is relative to the carrier's pointee yet is used at the hidden temporary.
  A probe viewing `pointer.items` as `[]Elem` was still rejected (L0526 naming `bag`), so no wrong result is shown; `direct ? place.path : nil` states the intent.
- [provenance_transfer.odin:25](src/provenance_transfer.odin#L25): `uncertain_copy` is set for four clones (191, 197, 211, 238) but not for composite elements (162) or widening conversions (224), though the comment's reason applies to all.
  Probes with a field-swapping hook were all rejected (L0536), so no wrong result is shown; say why they differ, or set it.

**Comments**

- [provenance_transfer.odin:62](src/provenance_transfer.odin#L62): "Queries read `transfers` directly, so describe the source first." The hidden-array sentence does not explain the call. Delete if the map reads above are replaced.
- [provenance_transfer.odin:90](src/provenance_transfer.odin#L90): says operands are read at their checked representation, but `prov_input_value` honors open conversions. Keep it only with the `prov_operand_value` change above; otherwise "at the representation the walk currently evaluates them".
- [provenance_transfer.odin:32](src/provenance_transfer.odin#L32): "A named owner's storage holds its carriers; any other owner's, including one reached through a pointer, move into the hidden storage the view borrows."

### src/queries.odin

A sound snapshot layer whose comments mostly earn their place. The real problems are in `query_members` (two bugs), the unread fields carried for an API nobody uses, the copied `query_at`/`query_selector_operand` pair, and a 135-line builder with obvious seams.

**Bugs**

- `BUG-queries-1` **medium** [queries.odin:333](src/queries.odin#L333) `query_members`: `add` hides members with `public == false` from other packages, but `new_binding_symbol` never sets it on enum members (check.odin:1319). Scenario: `other.Color.` completes to nothing, though design.md "Compile-time reflection" says enum members have no visibility of their own. Fix: exempt `.Enum_Member` from the test. *Confirmed: Reproduced via loke-lsp: with AC :: other.Color, `AC.` lists nothing, yet a local enum and alias AS of a union list members. `other.Shape.` is empty too, so `other.Color.` has a second cause in the operand. Editor completion only, so low rather than medium.*
- `BUG-queries-2` **medium** [queries.odin:346](src/queries.odin#L346) `add_fields`: the only cycle guard is `depth > len(c.types)`, and L0364 programs still reach here (semantic.odin:1973). Scenario: `A :: struct { using a: A, using b: A }`, then `x.` branches 2^(types) times and hangs the language server. Fix: `m.walked: Type_Walk` with `type_walk_enter` replaces `depth`; a revisit adds no new name anyway. *Confirmed: `A :: struct { using a: A, using b: A, v: int }`: loke-lsp gave no reply to `x.` completion in 60s, using a full core; one-using and non-recursive controls replied at once. Not recorded in the gap docs. lokec also timed out at 30s on `x.nope`, probably promoted_field_path.*
- `BUG-queries-3` **low** [queries.odin:347](src/queries.odin#L347) `add_fields`: a name two `using` fields supply is ambiguous (design.md "Promoted struct fields"), yet the walk lists it with the first branch's symbol. Scenario: `struct { using a: A, using b: B }` with `x` in both: completion offers `.x` with `a.x`'s type, and the selector is an error. Fix: mark or omit it, keeping the name visible to the rename checks that compare names. *Not verified.*
- `BUG-queries-4` **low** [queries.odin:408](src/queries.odin#L408) `IMPLICIT_MEMBER_NAMES`: omits the associated types the compiler looks up by name (iterate.odin:744), and the slot walk at line 439 never reads `Self.Iterator` in a slot type. Scenario: renaming a written `Element` meets no refusal, then `foreach` over the type fails L0456. Fix: add `Element`, `Iterator`, `Mut_Iterator`, `Item`, and drop the `.Proc` gate at lsp/rename.odin:200. *Not verified.*
- `BUG-queries-5` **low** [queries.odin:420](src/queries.odin#L420) `query_implicit_names`: `selected` stops at forms it does not list: `Expr_Postfix`, `Expr_Slice`, `Expr_Propagated_Error`, `Expr_Or_Else`, `Expr_Cond`, `Expr_Move`. Scenario: for `(x: T) x.get()^ -> int;` the name `get` is missing, so renaming another method to `get` is not refused. Fix: add those cases (no bundled interface hits this today). *Not verified.*

**Simplification**

- [queries.odin:123](src/queries.odin#L123) `query_file`: `dir_key` lowercases and `equal_fold` folds again; use `strings.equal_fold(canonical_dir(source.path), canonical_dir(path))` with no `key`, unless the map below replaces it. (about 1 line)
- [queries.odin:499](src/queries.odin#L499) `build_snapshot_queries`: write `definition` as `written ? symbol.span : NO_SPAN` and nest the document append under one `if written`, removing the `else` at line 509. (about 3 lines)
- [queries.odin:558](src/queries.odin#L558) `build_snapshot_queries`: `if symbol == nil || symbol.kind != .Proc_Group { continue }` replaces the index test plus nested `if`. (about 2 lines)
- [queries.odin:581](src/queries.odin#L581) `build_snapshot_queries`: sort `regions` first, then one `for handles, file in q.documents` fills extents, nests, and scopes; passing `file` also removes lines 608-609 of `scope_query_locals`. (about 6 lines)
- [queries.odin:654](src/queries.odin#L654) `nest_query_bindings`: seed `open` with `Nest{hi = max(u32)}` (id 0 is `INVALID_SYMBOL`); it never pops, so `parent`, the `len(open) > 0` tests, and the last `else` all go. (about 5 lines)

**Dead code**

- `Query_Type.key` ([queries.odin:46](src/queries.odin#L46)): no reader in `src/`, `lsp/`, or `tests/`, like `result`, `count`, `bits`, `signed`, `mutable`, `result_inout`, `members`, `parameters`, `param_modes`, `handle`. Removing them drops per-type allocations at lines 520-525; update the `query_type` row in compiler-architecture.md.
- `Query_Signature.result_inout` ([queries.odin:60](src/queries.odin#L60)): no reader, nor `diverges`. `result` and `complete` are read only by session_test.odin:434-450, so they look test-only.
- `Query_Parameter.type` ([queries.odin:54](src/queries.odin#L54)): no reader, nor `mode`. `has_default` is read only by session_test.odin:434.
- `Query_Symbol.public` ([queries.odin:38](src/queries.odin#L38)): no reader, nor `generic`; `add` and the LSP use other sources.
- (branch) [queries.odin:364](src/queries.odin#L364): `operand.symbol.id != INVALID_SYMBOL` is implied, since `symbol_of` returns nil for id 0 and `alias != nil` follows.
- (branch) [queries.odin:383](src/queries.odin#L383): `index < len(info.variants)` cannot fail; union.odin:36 and semantic.odin:1639 fill both slices in parallel, and semantic.odin:1606 indexes both directly.
- (branch) [queries.odin:108](src/queries.odin#L108): `id != 0` is implied, since `queries_ready` is set only with a non-zero `s.snapshot` and invalidation clears both.

**Data structures and algorithms**

- [queries.odin:208](src/queries.odin#L208) `query_at`: scans every occurrence of the whole program, bundled library included, to answer for one file, and rename calls it per matching token (lsp/rename.odin:232). Bucket `occurrences` and `operands` by file so the cost follows the file, not the program; sort for binary search only if that is still slow.
- [queries.odin:124](src/queries.odin#L124) `query_file`: re-canonicalizes every loaded source path (a `filepath.abs` call and temp allocations each) per request. A `map[string]u32` of `dir_key(canonical_dir(path))` built once in `build_snapshot_queries` is a shorter lookup.
- [queries.odin:473](src/queries.odin#L473) `build_snapshot_queries`: `[][dynamic]Query_Signature` costs 40 bytes per symbol, and the first `append` reserves 8 signatures per procedure in an arena that cannot shrink. `[][]Query_Signature` fits: one element for a procedure, a counted `make` for a group.
- [queries.odin:572](src/queries.odin#L572) `build_snapshot_queries`: `visited`, `bindings` (line 484), and the sort and sweep arrays are scratch, but live in `query_arena` until invalidation, with every abandoned map table. `visited` holds one entry per AST node of the program; a scratch arena destroyed on return avoids keeping it.

**Near copies**

- [queries.odin:204](src/queries.odin#L204) and [queries.odin:248](src/queries.odin#L248): the same scan and an identical result block; they differ in the list and in narrowing, which is a no-op for `operands` because their spans are names that never nest. One `occurrence_at(s, snapshot, list, file, offset)` makes both one-liners. (about 15 lines)

**Structure and boundaries**

- [queries.odin:465](src/queries.odin#L465) `build_snapshot_queries`: 135 lines doing six jobs in sequence. The loops are the seams: packages, symbols and canonical ids (485-513), types (514-527), signatures (528-563), diagnostics (564-571), index and nesting (572-599).
- [queries.odin:324](src/queries.odin#L324) `query_members`: 78 lines with three nested procedures that capture nothing. Move `Members`, `add`, `add_fields`, `add_members` to file scope and split out the union listing, leaving the `switch` as the visible flow.
- [queries.odin:419](src/queries.odin#L419) `query_implicit_names`: `selected` is an AST walk, and query_index.odin owns those; it belongs beside the walkers there.

**Comments**

- [queries.odin:93](src/queries.odin#L93): the lifetime and emission sentences repeat the compiler-architecture.md table; keep `Returned strings/slices are borrowed and read-only until invalidation.` and the citation at line 92.
- [queries.odin:159](src/queries.odin#L159): `Exact binding identity, not matching spelling. The caller owns the array.`; the rest restates the parameter.
- [queries.odin:268](src/queries.odin#L268): `Innermost first; a shadowed binding is omitted. A local is reachable from the end of its name, so its own initializer counts. The caller owns the array.`; the list is in compiler-architecture.md.
- [queries.odin:316](src/queries.odin#L316): badly wrapped and repeats the table. `What may follow operand., as compiler-architecture.md "Snapshots and queries" lists. One the checker contributes on demand appears once a lookup created it. Sorted by name; the caller owns the array.`

### src/query_index.odin

A compact, readable AST walk with useful comments and no dead procedures. Its weak spot is coverage: three kinds of checked syntax are never reached, so editor queries lose those names. The rest is small guards and repeated expressions.

**Bugs**

- `BUG-query_index-1` **medium** [query_index.odin:131](src/query_index.odin#L131) `index_query_stmt`: `Stmt_Assign.lowered` is not walked, yet `lower_compound_setter` checks only clones there. Scenario: `box[i] += v` through `operator([]=)`; `v` gets no temporary, so it has no symbol: no hover or definition, missing from `query_references`, and rename refuses. Fix: also walk `v.lowered`. *Confirmed: LSP on `box[idx] += val` via operator([]=): hover, definition, references null at `val`; references from its declaration omit it; rename refuses (no recorded binding). Control `box[idx] = ctl` works. The clone sits only in unwalked s.lowered. Not recorded in the docs.*
- `BUG-query_index-2` **medium** [query_index.odin:80](src/query_index.odin#L80) `index_query_decl`: only a bare `Expr_Proc_Group` value has its names indexed, though grammar.md allows `operator(<) proc { reversed }` and `resolve_operator_declaration` resolves it. Scenario: `reversed` there has no reference, so references omit it and rename refuses. Fix: look through `Expr_Operator`. *Confirmed: Reproduced with loke-lsp: for `less :: operator(<) proc { reversed }` (compiles clean), definition and hover return null, references omit the use, rename refuses; bare `proc { reversed }` works in all four. Unrecorded. Rename fails safe, so closer to low than medium.*
- `BUG-query_index-3` **medium** [query_index.odin:151](src/query_index.odin#L151) `index_query_stmt`: only the first `Stmt_When`'s `cond` is walked, but `check_when_stmt` checks each `else when` condition; `Item_When` at line 110 does recurse. Scenario: `when A {} else when B {}` with `A` false: `B` has no symbol, no references, and rename refuses. Fix: also walk `v.otherwise` when it is a `^Stmt_When`. *Confirmed: loke-lsp probe: for a procedure-scope `when (A) {} else when (B) {...}`, hover and definition on B are null, references omit that use, rename refuses; file-scope form and first condition work. Silent missed reference; rename refusal is safe, so low-to-medium.*

**Simplification**

- [query_index.odin:95](src/query_index.odin#L95) `index_query_item`, and lines 118 and 220: delete the `== nil` guards. `item_base`, `stmt_base` and `expr_base` return nil for a nil union and `query_index_enter` rejects nil, a check that typed nil pointers need anyway. (about 3 lines)
- [query_index.odin:229](src/query_index.odin#L229) `index_query_expr`: merge the empty `^Expr_Propagated_Error` (line 270) and `^Expr_Proc_Group` (line 307) cases into this one. (about 2 lines)
- [query_index.odin:299](src/query_index.odin#L299) `index_query_expr`: `if v.capture != nil { index_query_expr(index, v.capture.method) }`, since a nil `method` is already rejected on entry. (about 2 lines)
- [query_index.odin:52](src/query_index.odin#L52) `index_query_binding`: `lo` and `hi` are each read once; use `written.lo` and `written.hi` directly. (about 1 line)

**Dead code**

- (branch) [query_index.odin:48](src/query_index.odin#L48): `int(id) >= len(index.q.symbols)` cannot hold: `q.symbols` has `len(c.symbols)` entries, `c.symbols` only grows, and this walk adds none. `index_query_name` has no such check.
- (branch) [query_index.odin:55](src/query_index.odin#L55): `int(extent.hi) > len(text)` cannot hold: `hi` is the larger of two spans the same file's source produced, and the `definition` span was validated by `written_query_binding`.
- (branch) [query_index.odin:73](src/query_index.odin#L73): `len(decl.names) > 0` adds nothing, since `decl.symbols` holds one entry per name; an empty `names` means the loop does not run.
- (branch) [query_index.odin:154](src/query_index.odin#L154): `v.selected != nil &&` repeats the nil check inside `query_index_enter`.

**Data structures and algorithms**

- [query_index.odin:33](src/query_index.odin#L33) `query_index_enter`: `visited` is built in the query arena ([queries.odin:572](src/queries.odin#L572)), so it and its outgrown tables stay for the snapshot's life, in proportion to the AST, though only the build reads it. Allocate it on the heap and delete it after the walk.

**Near copies**

- [query_index.odin:202](src/query_index.odin#L202) and [query_index.odin:223](src/query_index.odin#L223): the same two lines choose a node's reported type, `INVALID_TYPE` for a package. Shared form: `query_node_type(base: ^Expr_Base) -> Type_Id`. (about 2 lines)
- [query_index.odin:18](src/query_index.odin#L18), [query_index.odin:40](src/query_index.odin#L40) and [query_index.odin:192](src/query_index.odin#L192): each validates a span and compares its text with a name. Shared form: `query_span_spells(c, span, name) -> bool`, which also shortens the two longest guards.
- [query_index.odin:82](src/query_index.odin#L82) and [query_index.odin:259](src/query_index.odin#L259): both find a symbol by name among candidates and record the written name; only the type differs. Shared form: `index_query_bound_name(index, name, candidates)`, typing a `.Proc` by `proc_type`, which removes the deepest nesting. (about 4 lines)

**Structure and boundaries**

- [query_index.odin:6](src/query_index.odin#L6): the walk's driver is at [queries.odin:572](src/queries.odin#L572), so `index_query_item`, `_decl` and `_expr` are package-wide and visible to `lsp`, as are `valid_query_span` and `written_query_binding`. Move the driver here as one `@(private)` entry point and make the rest file-private, except `written_query_binding`, which is `@(private)`.

**Comments**

- [query_index.odin:182](src/query_index.odin#L182): shorten to: `design.md "Promoted struct fields": a promoted selector's added links carry the name's span, so the written operand is below them, and below any implicit `p^`, since the pointer's own members come first (design.md "Methods and implementation blocks").` (about 2 lines)
- [query_index.odin:59](src/query_index.odin#L59): delete; [queries.odin:458](src/queries.odin#L458) already says what `regions` holds and this proc is one line.

### src/reflect.odin

**Near copies**

- [reflect.odin:307](src/reflect.odin#L307) and [simd.odin:291](src/simd.odin#L291), [check_builtin.odin:1378](src/check_builtin.odin#L1378), [enums.odin:83](src/enums.odin#L83), [check_expr.odin:3332](src/check_expr.odin#L3332): `aggregate_const` is the 3-line form these write by hand. Move it to const_ops.odin; only its `type_value = type` differs, and I found no reader of that on an aggregate.

### src/region.odin

Small and well scoped; what is left is the walk over owned parts it shares with several files.

**Near copies**

- [region.odin:123](src/region.odin#L123), [hooks.odin:370](src/hooks.odin#L370), [hooks.odin:330](src/hooks.odin#L330), [hooks.odin:165](src/hooks.odin#L165) and [borrow.odin:761](src/borrow.odin#L761): the same switch over owned parts (element, key, field types, variants). A `type_owned_part_next(c, info, &i)` iterator would reduce each to a `for` over parts and give one place to define what is owned, which is where the `Shared` bug above sits.

### src/select.odin

What remains is the predeclared-callee near copies, shared with `box.odin`, `simd.odin` and `iterate.odin`.

**Near copies**

- [select.odin:293](src/select.odin#L293) and [box.odin:34](src/box.odin#L34): `callee_is_builtin` and `box_callee` differ only in the kind. Drop the `file` privacy and make `box_callee` call it with `.Box_New`. (about 5 lines)
- [simd.odin:15](src/simd.odin#L15), [iterate.odin:68](src/iterate.odin#L68) and [box.odin:45](src/box.odin#L45), combined at [select.odin:440](src/select.odin#L440): the same procedure but for the spelling. Share `unbound_callee(k, callee, name)`.

### src/semantic.odin

The stores and interning are sound, and the `Symbol` and `Type_Info` definitions are mostly justified "why" comments. What remains is merging the type walks, now in `types.odin`.

**Near copies**

- [semantic.odin:2204](src/semantic.odin#L2204), [semantic.odin:2262](src/semantic.odin#L2262) and [reflect.odin:149](src/reflect.odin#L149): the same component walk. "Supported" is "no component is Invalid, Interface or a descriptor"; "contains invalid" is the Invalid part. One walk taking a predicate serves all three. (about 70 lines)

### src/session.odin

A compact, sound orchestrator whose lifecycle ordering holds up. It carries about ten redundant checks and assignments, its contract comments repeat the architecture document, and a third of it is configuration parsing that the source map assigns elsewhere.

**Bugs**

- `BUG-session-1` **low** [session.odin:125](src/session.odin#L125) `check_session_impl`: `finish_session_check` on the incremental path runs on the caller's `temp_allocator`, because line 134 is reached only by a full check. Scenario: a host that never frees temp grows its thread temp arena on each incremental check; the retained data I traced is not temp, so nothing dangles. Fix: move line 134 up beside line 116. *Not verified.*

**Simplification**

- [session.odin:93](src/session.odin#L93) `configure_session`: `seed_defines`, `register_collections` and `configure_session` only return `error_count == 0`. Drop the bools, call both, and set `s.configured = s.compiler.error_count == 0` at line 66; a bad `-define` then no longer hides a bad `-collection` behind `&&`. (about 5 lines)
- [session.odin:154](src/session.odin#L154) `finish_session_check`: `root` is `c.root_package` whenever it is read, and `compiled` is false only after a reported error (`load_source`, `load_package_dir`, `check_import_cycles`). Reduce to `finish_session_check(s, documentation)` with `if c.error_count == 0`. (2 parameters, about 1 line)

**Dead code**

- (branch) [session.odin:115](src/session.odin#L115): `provenance_stats = {}` has no effect on any path. A first check is already zero, a fallback hits `c^ = {}` in `destroy_compilation`, and a reuse hits `c^ = checkpoint.state`, captured before the analysis writes it. Delete it.
- (branch) [session.odin:114](src/session.odin#L114): `!s.initialized` is implied by `!s.configured`, which is set only at line 66 and cleared by `s^ = {}`. Keep only the second test.
- (branch) [session.odin:133](src/session.odin#L133): `s.ready` is already false from `invalidate_session_snapshot` at line 120. Write `s.started = true`.
- (branch) [session.odin:90](src/session.odin#L90): `c.target` is overwritten by [semantic.odin:937](src/semantic.odin#L937) when `seed_defines` initializes the stores three lines later, always from a zeroed compiler. Assign only `c.cpu`.
- (branch) [session.odin:131](src/session.odin#L131): this `configure_session` cannot fail, since it re-parses the copied strings that line 114 proved valid at initialization. The `return false` is unreachable.
- (branch) [session.odin:147](src/session.odin#L147): `c.package_cache != nil` always equals `incremental` here: only line 138 sets it, and every earlier path leaves a zeroed compiler. Test `incremental`.
- (branch) [session.odin:190](src/session.odin#L190): `context.allocator = s.allocator` has no effect, since `emit_session` allocates nothing and [emit_llvm_toolchain.odin:28](src/emit_llvm_toolchain.odin#L28) replaces it on entry. `emit_session_ir` already omits it. Delete it.
- (branch) [session.odin:258](src/session.odin#L258): `len(name) > 0` is always true; the only caller rejects `split <= 0` at line 219. Return `true`.
- (branch) [session.odin:264](src/session.odin#L264): `init_semantic_stores` is redundant, since the one caller always runs `seed_defines` first and that call initializes the stores. Delete it, or move the single call to `configure_session`.
- `emit_session_ir` ([session.odin:179](src/session.odin#L179)): not dead, but only `session_test.odin` calls it; neither the CLI nor `lsp/` does. It is a documented API that the tests use to compare IR against fresh sessions.

**Near copies**

- [session.odin:9](src/session.odin#L9), [main.odin:110](src/main.odin#L110) and [source.odin:278](src/source.odin#L278): the same nine settings are declared three times, then copied at [main.odin:174](src/main.odin#L174), [main.odin:269](src/main.odin#L269) and session.odin:87-92. One embedded `Compilation_Settings` struct with its default replaces those copies. (about 25 lines)

**Structure and boundaries**

- [session.odin:156](src/session.odin#L156): `finish_session_check` infers "this was a full check" from an empty `rechecked_packages`. Move the block to the full path after line 146, so the shared finish step only finishes and the two paths each record their own stats.
- [session.odin:213](src/session.odin#L213): lines 213-299 parse `-define` and `-collection`, while the source map gives this file orchestration and `build_config.odin` build configuration. Move `seed_defines` to `build_config.odin`, and `register_collections` to `project.odin`, whose comment already states the `-collection` precedence.

**Comments**

- [session.odin:29](src/session.odin#L29): shorten to `// Never copy a live session: its allocators point into it (compiler-architecture.md "Reusable batch sessions").` The lifetime list repeats that section.
- [session.odin:70](src/session.odin#L70): shorten to `// Expires the checked result after an external change, which the caller reports (compiler-architecture.md "Invalidation rules").`
- [session.odin:139](src/session.odin#L139): the wording does not give the reason. Use `// Checkpoint images cover sources, syntax and diagnostics only in the semantic arena.`
- [session.odin:143](src/session.odin#L143): names the wrong owner, since `input_copy` is what dies here. Use `// The compiler keeps its path; input_copy is freed on return.`
- [session.odin:174](src/session.odin#L174): delete the first sentence and shorten the second to `// Rejects an unchecked, failed or documentation session.` Keep the `ponytail:` note.
- [session.odin:185](src/session.odin#L185): delete this sentence; the `Emission_Options` parameter says it. Keep the two lines on the missing output path.
- [session.odin:267](src/session.odin#L267): shorten to `// The map owns its values, as for an explicit entry.`

### src/simd.odin

Readable and well scoped, with no dead symbols, but `check_simd_binary` skips operator overloads, and much of the intrinsic validation guards a caller that cannot get it wrong. Several helpers copy procedures that already exist in `check_expr.odin`, `check.odin`, and `const_ops.odin`. Bugs below were reproduced with the built `lokec.exe`.

**Bugs**

- `BUG-simd-1` **medium** [simd.odin:199](src/simd.odin#L199) `check_simd_binary`: any operand that is a vector ends here (dispatch at [check_expr.odin:2238](src/check_expr.odin#L2238)), so no user overload is tried; design.md "Operator lookup and overload resolution" says one is found where no built-in exists. *Confirmed: Reproduced: `m * v` and `v + m` give L0686 with matching operator overloads, while `v += m` compiles and runs (prints 3.0). check_binary sends any vector operand to check_simd_binary; design.md says an overload is found where no built-in exists. Nothing recorded.*
  Scenario: with `operator(*) proc(m: Mat, v: Simd(f32, 4))`, `m * v` gives L0686, as does `v + m`, while `v += m` compiles through the same overload; float `v % v` is also closed to overloads.
  Fix: enter only when the built-in is defined for these operands; otherwise call `check_user_binary`, then report L0686.
  Scenario: `f32_vec + i32(1)`, `f32_vec + f64(0.1)`, `i32_vec + i64(5)` and `a: Simd(f32, 4) = i32(1)` compile, though `x: f32 = i32(1)` is L0310.
  Fix: in `materialize`, require a typed constant to be assignable to the lane type before converting it.
- `BUG-simd-3` **low** [simd.odin:362](src/simd.odin#L362) `check_simd_unary`: it never folds, so `-C` on a constant vector is not `is_const` and `reject_negative_count_lanes` cannot see it; design.md "Lane-wise operators" makes a constant negative lane an error. *Not verified.*
  Scenario: `C :: Simd(i32, 4){1, 1, 1, 1}; w := v << -C;` compiles and panics at runtime with "negative shift count". Fix: fold constant operands lane by lane, as the binary path does.
- `BUG-simd-4` **low** [simd.odin:226](src/simd.odin#L226) `check_simd_binary`: `constant_zero_divisor` is never applied, and the compound path returns before [check.odin:4029](src/check.odin#L4029); design.md "Integer operators" forbids a constant zero divisor, and lanes obey the scalar rule "unchanged". *Not verified.*
  Scenario: runtime `a := simd.from_array([4]i32{1, 2, 3, 4}); q := a / 0;` compiles and panics, where scalar `x / 0` is L0319. Fix: reject a constant divisor with a zero lane on integer lanes in both paths.
- `BUG-simd-5` **low** [simd.odin:29](src/simd.odin#L29) `resolve_simd_application`: the shape test omits `mode != .Value`, which [box.odin:97](src/box.odin#L97) includes; type position rejects this in the parser (L0253), but value position does not. *Not verified.*
  Scenario: `size_of(Simd(inout f32, 4))` compiles and answers 16. Fix: add the mode test to both arguments; `resolve_range_application` ([iterate.odin:81](src/iterate.odin#L81)) has the same gap.
- `BUG-simd-6` **low** [simd.odin:79](src/simd.odin#L79) `simd_lane_count`: an unbound `$N` returns false with no diagnostic, so `report_unresolved_type` blames the wrong name. *Not verified.*
  Scenario: `y: Simd(f32, $M);` in a plain procedure reports L0306 "unknown type `Simd`". Fix: report L0683 here, saying `$M` is not bound.
- `BUG-simd-7` **low** [check.odin:4001](src/check.odin#L4001) (calling [simd.odin:255](src/simd.odin#L255)): the result of `materialize_value_expr` is ignored, so `reject_negative_count_lanes` runs on the unconverted scalar, and `simd_lane_const` reads it as a splat. *Not verified.*
  Scenario: `v <<= -1` on `Simd(u32, 4)` reports both L0352 and L0356; `v << -1` reports only L0352. Fix: return when materialization fails.

**Simplification**

- [simd.odin:576](src/simd.odin#L576) `simd_written_fold`: lines 576-593 become `enum_member_by_value` ([check.odin:4497](src/check.odin#L4497)) for the name, then `reflect.enum_from_name(Simd_Fold, name)` for the fold. (about 14 lines)
- [simd.odin:438](src/simd.odin#L438) `check_simd_builtin`: the `[dynamic]Expr` threaded through three procedures only ever holds `args[0]`, or all three for select; build the slice once after the switch and drop the `bound` parameters. (about 6 lines)
- [simd.odin:324](src/simd.odin#L324) `simd_splat_operands`: materialize a runtime scalar at `vector` as well, so [check_expr.odin:3510](src/check_expr.odin#L3510) records `splat_from`; the separate "left at the element type" convention goes, along with the emitter's `simd_operand` and its type parameters ([emit_llvm_simd.odin:10](src/emit_llvm_simd.odin#L10)). (about 5 lines here, 10 in the emitter)

**Dead code**

- (branch) [simd.odin:425](src/simd.odin#L425): the arity and argument-shape errors cannot fire: the builtins are private to `core:simd` ([stdlib.odin:151](src/stdlib.odin#L151)), and each call in `core/simd/simd.loke` is written correctly.
- (branch) [simd.odin:467](src/simd.odin#L467): L0682 and the default case at line 475 are unreachable: the operand is a parameter typed `[$N]$T` or `Simd($T, $N)`, and `from_array`'s signature `-> Simd(T, N)` rejects a bad element or count first (L0682/L0683 "in the signature of").
- (branch) [simd.odin:493](src/simd.odin#L493): every error in `check_simd_select` (lines 493-515) is unreachable, because `select` declares `mask: Simd(bool, $N), when_true: Simd($T, N), when_false: Simd(T, N)`; the checks reduce to the `append` and `v.type = left`.
- (branch) [simd.odin:528](src/simd.odin#L528): the not-a-vector error, and the `Any`/`All` mask error at line 540, are unreachable because the parameter is a vector and `any`/`all` take `Simd(bool, $N)`. The `Add`..`Max` mask error at line 550 is live and tested.
- (branch) [simd.odin:572](src/simd.odin#L572): the errors at lines 572-575 and 594 are unreachable, since every call writes a `Fold` member; `base == nil` also cannot follow a valid `check_single_expr`.
- (branch) [simd.odin:149](src/simd.odin#L149): `index == nil` cannot be true, because `materialize` at line 147 returns false for a nil base.
- (branch) [simd.odin:277](src/simd.odin#L277): `v.type == INVALID_TYPE` cannot be true, because the only caller sets `v.type` from `simd_of` on the line before.
- (branch) [simd.odin:459](src/simd.odin#L459): `info == nil` cannot be true, because `operand` was just checked against `INVALID_TYPE`.
- (branch) [simd.odin:304](src/simd.odin#L304): the out-of-range arm is unreachable, because a constant vector always has `count` elements: the literal path pads ([check_expr.odin:3305](src/check_expr.odin#L3305)) and `convert_const` refuses other lengths ([check_expr.odin:3818](src/check_expr.odin#L3818)). The length test at line 187 is unneeded for the same reason.

**Near copies**

- [simd.odin:76](src/simd.odin#L76) and [check.odin:1965](src/check.odin#L1965): lane count and array length run the same poly lookup, `check_single_expr`, `require_const`, integer test, and `bi_to_i64`; they differ in wording and code. A shared `constant_count(k, written, what, code) -> (u64, bool)` removes about 20 lines here, and `simd_lane_count_permitted` already rejects 0.
- [simd.odin:15](src/simd.odin#L15), [box.odin:45](src/box.odin#L45) and [iterate.odin:68](src/iterate.odin#L68): `simd_callee`, `box_type_callee` and `range_callee` differ only in the name; use `predeclared_callee(k, callee, "Simd")`.
- [simd.odin:185](src/simd.odin#L185) and [check_expr.odin:1432](src/check_expr.odin#L1432): the same constant-element fold, except that the array path also sets `v.immutable = .Constant`; a small shared helper keeps the two from drifting further.

**Structure and boundaries**

- [simd.odin:133](src/simd.odin#L133) and [emit_llvm_simd.odin:10](src/emit_llvm_simd.odin#L10): two procedures named `simd_operand`, one a nominal type test and one that splats a value; rename the emitter's (`simd_splat_scalar`), unless the simplification above removes it.
- [simd.odin:311](src/simd.odin#L311) and [check.odin:3995](src/check.odin#L3995): binary and compound assignment each decide whether an operand is the vector or one of its lanes, which is how they came to disagree in BUG-simd-1; give both one predicate here, such as `simd_operand_is_builtin(c, vector, other)`.

**Comments**

- [simd.odin:73](src/simd.odin#L73): delete; it sits on the wrong procedure and is inaccurate, since two of the three bounds share one diagnostic.
- [simd.odin:405](src/simd.odin#L405), [simd.odin:564](src/simd.odin#L564) and [stdlib.odin:148](src/stdlib.odin#L148): the same "matched by name, no second identity" note appears three times; keep line 405 and delete the sentence at 565.
- [simd.odin:417](src/simd.odin#L417): cites a "design.md entry" that does not exist (the intrinsics are not in design.md); shorten to "A built-in has no signature, so the shapes are checked here."
- [simd.odin:56](src/simd.odin#L56), [simd.odin:273](src/simd.odin#L273), [simd.odin:389](src/simd.odin#L389) and [simd.odin:484](src/simd.odin#L484): delete; each repeats the procedure name, the code, or the diagnostic beneath it.
- [simd.odin:520](src/simd.odin#L520): delete the second sentence, which `core/simd/simd.loke` and `stdlib.odin` already state.
- [simd.odin:252](src/simd.odin#L252): shorten to `design.md "Lane-wise operators": also serves `v <<= c`.`
- [simd.odin:4](src/simd.odin#L4): shorten to "`Simd` is predeclared, so it needs no import and can be shadowed." (about 15 lines across the file)

### src/slice.odin

A small, focused file. What remains is the emitter's slice unpacking around it.

**Near copies**

- [emit_llvm_iteration.odin:493](src/emit_llvm_iteration.odin#L493), [emit_llvm_calls.odin:1073](src/emit_llvm_calls.odin#L1073), [emit_llvm_expr.odin:2410](src/emit_llvm_expr.odin#L2410), and [emit_llvm_containers.odin:128](src/emit_llvm_containers.odin#L128), 287, 322, 755, 896, 1413: each extracts data then length.
  Shared form: `ptr_len_parts(e, storage, value) -> (data, length)` beside `emit_ptr_len`, its inverse; `#assert` at emit_llvm_runtime.odin:116 already ties `SLICE_*` to `VIEW_*`. (about 12 lines net)

### src/source.odin

Small, sound procedures for loading and diagnostics.

**Near copies**

- [source.odin:660](src/source.odin#L660), [source.odin:766](src/source.odin#L766), [check.odin:3355](src/check.odin#L3355) and `prov_drop_event_diagnostics`: each shrinks and clamps `last_noted_diagnostic`, and `hold_diagnostics` also undoes `error_count` by hand. Add one helper for `resize` plus the clamp. (about 5 lines)

### src/text.odin

Short and readable, with why-comments that mostly earn their place. The main issues are the receiver pre-check in `check_text_operation`, a from_runes/from_utf8 pair that drifted apart, repeated error boilerplate, and non-text `unsafe` built-ins living here. Probes ran against the current `lokec.exe`.

**Bugs**

  Scenario: `N :: f(false); f :: proc(use: bool) -> int { if (use) { return s.byte_len(); } return 3; } s := "hello";` gives L0363 "`string` has no field or member `byte_len`"; `s.len()` compiles.
  Fix: do not take the shortcut for a variable whose type is still `INVALID_TYPE`.
  Scenario: `make_s(proc() -> int { y := 4; return y; }).copy()` on a struct method fails in clang: "invalid redefinition of function 'loke.p.lambda.2'". `.other()` also fails (`lambda.1`), so another path, not traced, re-checks too; plain `make_s(lit)` works.
  Fix: hoist each literal once, and stop re-checking (see Data structures).
- `BUG-text-3` **low** [text.odin:150](src/text.odin#L150) `check_from_runes`: checks only the argument count, not its name or mode, unlike `check_from_utf8` at line 187. *Not verified.*
  Scenario: `string.from_runes(wrong = r[:])`, `string.from_runes(..r[:])` and `string.from_runes(inout y)` all compile; the named and `inout` shapes on `from_utf8` report L0561.
  Fix: apply the shape check at line 187 here (see Near copies).
- `BUG-text-4` **low** [text.odin:201](src/text.odin#L201) `check_from_utf8`: the argument is never materialized, so the implicit view conversion of design.md "Fixed arrays" does not apply; line 160 in `check_from_runes` has the same gap. *Not verified.*
  Scenario: with `b := [3]u8{65, 66, 0}`, `string.from_utf8(b)` gives L0561 "found `[3]u8`", though `array_views_as` lets a `[]u8` parameter take `b`; `[dynamic]u8` and `[2]rune` are rejected too.
  Fix: when `array_views_as` holds for the expected slice, `materialize` before testing the kind.
- `BUG-text-5` **low** [text.odin:329](src/text.odin#L329) `check_unsafe_builtin`: the result of `materialize` is ignored, so a length it has already rejected gets a second error. *Not verified.*
  Scenario: `unsafe.string_view(p, 1.5)` reports both L0353 and L0569 for the one argument.
  Fix: on a false result set `INVALID_TYPE` and return, as `check_enum_from_int` does in [enums.odin](src/enums.odin#L27).
- `BUG-text-6` **low** [text.odin:330](src/text.odin#L330) `check_unsafe_builtin`: any integer type is accepted as a length, but `widen_to_i64` ([emit_llvm_expr.odin:1079](src/emit_llvm_expr.odin#L1079)) truncates 128-bit values. *Not verified.*
  Scenario: `neg: i128 = -18446744073709551616; unsafe.string_view(p, neg)` gives an empty view instead of the negative-length panic of design.md "string type conversions". `p[0:big]` wraps the same way.
  Fix: range-check 128-bit values in the emitter, for both forms, or reject them here.

**Simplification**

- [text.odin:152](src/text.odin#L152) `check_from_runes`, `check_from_utf8`, `check_strings_allocate`, `check_unsafe_builtin`: open each with `v.type = INVALID_TYPE`, as line 73 and `check_allocation_failed` do, and delete the assignment before every error return. (about 17 lines)
- [text.odin:116](src/text.odin#L116) `fix_string_receiver`: its only caller is line 48; inline the one expression there and move the design.md "string type" citation with it. (about 3 lines)
- [text.odin:198](src/text.odin#L198) `check_from_utf8`: replace the three-arm `switch` over a `.None` placeholder with `op := from_bytes`, an `if` for the C view case, and an `else if` for the error. (about 3 lines)
- [text.odin:71](src/text.odin#L71), [168](src/text.odin#L168), [213](src/text.odin#L213): `make([]Expr, 1, ...)` then `[0] =` also appears at about a dozen sites such as [enums.odin:51](src/enums.odin#L51) and [union.odin:482](src/union.odin#L482); a small `single_bound(k, e)` helper takes one line per site. (about 15 lines)

**Data structures and algorithms**


**Near copies**

- [text.odin:146](src/text.odin#L146) and [text.odin:174](src/text.odin#L174): `check_from_runes` and `check_from_utf8` share category, arity, shape and expected-slice checks, differing in name, element and result. `text_constructor_source(k, v, name, parameter, element) -> Type_Id` would hold them and fix BUG-text-3. (about 8 lines)
- [text.odin:223](src/text.odin#L223) and [check_builtin.odin:162](src/check_builtin.odin#L162): `check_strings_allocate` and `check_allocation_failed` are the same shape, arity, typed-loop sequence, differing in error code, wording, targets and result. `check_typed_builtin_args(k, v, ident, code, wanted, targets) -> bool` fits both. (about 12 lines)
- [text.odin:319](src/text.odin#L319) and [text.odin:340](src/text.odin#L340): the same byte-pointer error twice. One check before the `#partial switch`, guarded by `kind != .Unsafe_Raw_Data` and using `ident.name`, replaces both. (about 7 lines)

**Structure and boundaries**

- [text.odin:262](src/text.odin#L262): `check_unsafe_builtin` mostly is not text, since `raw_data` takes slices, dynamic arrays and array pointers. It belongs in `check_builtin.odin` beside the other `.Unsafe_*` checkers, and `check_strings_allocate` belongs beside `check_allocation_failed`, its near copy. Both section banners then go.
- [text.odin:148](src/text.odin#L148): `.From_Runes` is a validating constructor filed in `Text_Op` ([ast.odin:179](src/ast.odin#L179)), while `Text_Conversion` claims "the named text constructors". Making it a `Text_Conversion` member removes the early return in `emit_text_operation` and the dual test at [cfg_provenance.odin:9861](src/cfg_provenance.odin#L9861).

**Comments**

- [text.odin:78](src/text.odin#L78): misleading, since `cstring_view` answers to none of these ops (line 81 rejects them all). Write: "A `cstring_view` is terminated, not measured, so it has none of these; `to_c_view` needs a `string`'s terminator."
- [text.odin:254](src/text.odin#L254): delete the signature table, which copies design.md and adds `string_view`, a form its list omits. Write: `design.md "unsafe.raw_data procedure", and the two view constructors whose operands the compiler cannot trace to an owner.` (about 5 lines)
- [text.odin:90](src/text.odin#L90): delete; `mutable = false` on the next line says it.
- [text.odin:143](src/text.odin#L143): this covers `check_from_utf8` too but sits on `check_from_runes` alone; keep one copy above the shared helper once the two are merged.

### src/universe.odin

A small, table-driven file whose bindings match design.md "Predeclared names"; no bugs here. What remains is a builtin symbol spelled three ways.

**Near copies**

- [box.odin:45](src/box.odin#L45), [iterate.odin:68](src/iterate.odin#L68) and [simd.odin:15](src/simd.odin#L15): the predeclared names with no universe entry use one proc three times; only the string differs. Shared form: `predeclared_callee(k, callee, "Box")`. (about 14 lines)
- [check.odin:2330](src/check.odin#L2330) and [check.odin:2334](src/check.odin#L2334): `Simd` compares the name alone where `Box` uses `box_type_callee`, so a bare `x: Simd` naming a program's own generic `Simd` gets the `Simd(f32, 4)` message instead of L0431. Use `simd_callee` here too.

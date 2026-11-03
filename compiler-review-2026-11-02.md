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
The largest file, `cfg_provenance.odin`, has natural seams and would be easier
to work in if split, though that shortens nothing.

## The changes most worth making

4. **Five small independent fixes.** Probe path that deletes the real output, [emit_llvm_toolchain.odin:209](src/emit_llvm_toolchain.odin#L209) (BUG-emit_llvm_toolchain-1). Split-receiver `dyn` slot, [erased.odin:671](src/erased.odin#L671) (BUG-erased-1). 1 to 2 lines each.

6. **`nil` operands crash.** Route the nil case at [box.odin:147](src/box.odin#L147) through `check_defaulted_operand` in `check_builtin.odin`. BUG-box-1. About 10 lines.

7. **Holes in `foreach` safety.** The `indexed()` counter and a per-step projected record are marked lent ([iterate.odin:856](src/iterate.odin#L856), [iterate.odin:990](src/iterate.odin#L990)), so `return &e` compiles; public iterator fields let safe code segfault ([iterate.odin:172](src/iterate.odin#L172)). BUG-iterate-1, -3, -2. About 25 lines.

8. **Safe code the checker accepts and then corrupts.** `exchange` of an unmoved owned place ([lifecycle.odin:194](src/lifecycle.odin#L194)). BUG-lifecycle-1. About 20 lines.

10. **Spawn lends storage that does not last.** [parallel.odin:608](src/parallel.odin#L608) gives `.Address` to a place rooted in a temporary and to a widened place, so tasks read dropped or overwritten slots; [emit_llvm_stmt.odin:217](src/emit_llvm_stmt.odin#L217) then needs its `.Owned` arm to copy a place. BUG-parallel-1, -2. About 35 lines.

11. **Wrong inferred effects.** Implicit drops, `operator(<)` and `switch` equality escape the effects ([global_effects.odin:1069](src/global_effects.odin#L1069), [global_effects.odin:515](src/global_effects.odin#L515), [global_effects.odin:676](src/global_effects.odin#L676)). BUG-global_effects-1, -2, -3. Merge the op sets into `CONTAINER_OP_EFFECTS`. About 40 lines.


13. **Wrong constant values.** A lone spread appends nothing at compile time ([eval.odin:1516](src/eval.odin#L1516)). BUG-eval.part1-1. About 35 lines.

15. **`when` conditions evaluated too early.** [select.odin:176](src/select.odin#L176) tests only names written in the condition, so `N :: size_of(Handle); when (N == 8)` fails when `Handle` comes from an earlier `when`, a natural pattern for platform code. Follow resolved package-scope declarations with a seen set. BUG-select-1. About 30 lines, with fixed-point risk.

16. **Compiler crashes and hangs on simple input.** `if (case 1 = x) y;` stores a nil block ([parser.odin:1623](src/parser.odin#L1623)); mutual aliases go exponential ([generic.odin:1308](src/generic.odin#L1308)). BUG-parser.part1-1, BUG-generic-1. About 10 lines.

18. **One syntax walker and one owned-parts walker.** `expr_children` replaces the descents at [ast.odin:1388](src/ast.odin#L1388), [doc.odin:578](src/doc.odin#L578), [private_names.odin:515](src/private_names.odin#L515) and [select.odin:313](src/select.odin#L313); `type_parts` serves [hooks.odin:277](src/hooks.odin#L277) and its siblings. Ends the drift behind BUG-ast-1, and the exponential guard at [hooks.odin:413](src/hooks.odin#L413). Removes about 250 lines; no behavior change beyond those.

19. **Mechanical removal of failure boilerplate.** Replace the 101 three-line guards in `eval.odin` part 1 with `or_return` ([eval.odin:662](src/eval.odin#L662) onward; about 300 lines), and drop the `v.type = INVALID_TYPE` writes outside `check_expr.odin`, which now defaults it on entry. Low risk.

## Findings that span files

Commit 92cb0d18. Every site linked below was read; a count such as "33 sites" comes from a grep of `src`, excluding tests. Savings are rough net lines. "Fixes" names a bug whose root is the divergence described. Together the groups come to about 2,000 lines of a 110,000-line tree; their larger value is the roughly 50 bug ids they explain.

### Roots shared by several bugs

#### One root behind separately reported bugs

These ids describe one defect each and need one fix. Each is also confirmed by a repro in a per-file review.


#### Container operations classified in several tables

`CONTAINER_OP_EFFECTS` in `container.odin` is exhaustive by construction. Beside it sit `KEY_HASHING_OPS` ([global_effects.odin:493](src/global_effects.odin#L493)), `ELEMENT_DROPPING_OPS` ([global_effects.odin:1069](src/global_effects.odin#L1069)), the insertion test at [global_effects.odin:525](src/global_effects.odin#L525), and the per-kind cases at [check_calls.odin:482](src/check_calls.odin#L482) and [emit_llvm_calls.odin:1298](src/emit_llvm_calls.odin#L1298). The partial sets are where the gaps are: `find_or_insert`, `try_insert` and map `remove` are missing from dropping.

Shared form: add `.Hashes_Key`, `.Drops_Element`, `.Drops_Key` and `.Inserts_Element` to `Container_Op_Effect` and drop the sets. Saves about 10 lines; the gain is that every new operation must answer every question. Fixes BUG-global_effects-1.

### Checker and front end

#### Built-in call opening and operands

`builtin_arity_ok` in `check_builtin.odin` writes the arity report, but it is still written by hand at [atomics.odin:164](src/atomics.odin#L164), [format.odin:244](src/format.odin#L244), [simd.odin:427](src/simd.odin#L427) and [text.odin:273](src/text.odin#L273). A loop over fixed target types repeats at [check_builtin.odin:176](src/check_builtin.odin#L176), [text.odin:240](src/text.odin#L240) and [format.odin:251](src/format.odin#L251). The allocator argument repeats at [check_builtin.odin:586](src/check_builtin.odin#L586) and [box.odin:164](src/box.odin#L164).

They differ in diagnostic code (`L0322`, `L0661`, `L0687`, `L0569`, `L0738`), and atomics reports every bad argument rather than the first.

The operand path has the real divergence. `check_defaulted_operand` in `check_builtin.odin` reports `nil`, but [box.odin:147](src/box.odin#L147) calls `default_type` directly, and `materialize` then fails silently on `INVALID_TYPE`.

Shared form: `builtin_arity_ok` at those sites, `bind_typed_arguments(k, v, targets)`, `check_allocator_argument(k, e)`, and `check_defaulted_operand` shared with `box.odin`. Saves about 40 lines and fixes BUG-box-1.

#### Failure writes that the default in `check_expr` makes unnecessary

`check_expr` now sets `base.type = INVALID_TYPE` and `base.value_category = .Value` on entry, so `v.type = INVALID_TYPE` before an early return is needless in what it reaches: [check_builtin.odin](src/check_builtin.odin) 38, [check_calls.odin](src/check_calls.odin) 28, [lifecycle.odin](src/lifecycle.odin) 22, [text.odin](src/text.odin) 18, [erased.odin](src/erased.odin) 15, [reflect.odin](src/reflect.odin) 14, [optional.odin](src/optional.odin) 13. Some procedures write it once at the top ([check_builtin.odin:97](src/check_builtin.odin#L97), [simd.odin:421](src/simd.odin#L421)), which goes too.

Shared form: assign only on success. Saves about 100 lines.

#### Syntax walkers

[ast.odin:1388](src/ast.odin#L1388) `type_syntax_any_name`, [doc.odin:578](src/doc.odin#L578) `api_refs`, [private_names.odin:515](src/private_names.odin#L515) `walk` and [select.odin:313](src/select.odin#L313) `first_unresolved_name` each repeat one descent through the expression and type-syntax kinds.

| Child | ast | doc | private_names | select |
| --- | --- | --- | --- | --- |
| composite field-name key | walked | skipped | skipped | skipped unless keys are values |
| `or_else` exit value | walked | no | no | walked |
| composite `via` | walked | walked | no | no |
| parameter default | walked | walked | no | no |

The key difference is BUG-ast-1. The other rows are unexplained, and `private_names` and `select` simply do not look there. Shared form: `expr_children(e, data, visit) -> bool` in `ast.odin`, exhaustive over the kinds, with `data: rawptr` as `type_syntax_any_name` already takes. Each caller handles its own cases in a `#partial switch` and falls through to the children. Saves about 150 to 200 lines. `index_query_expr` ([query_index.odin:228](src/query_index.odin#L228)) reads checked fields and stays out.

#### Type-component walkers

Owned parts are walked at [hooks.odin:166](src/hooks.odin#L166), [hooks.odin:277](src/hooks.odin#L277), [hooks.odin:330](src/hooks.odin#L330), [hooks.odin:370](src/hooks.odin#L370), [region.odin:123](src/region.odin#L123), [borrow.odin:761](src/borrow.odin#L761) and `require_nested_map_key_policies_walk` in [hash.odin](src/hash.odin). They differ in:

- `Shared(T)`: only [borrow.odin:758](src/borrow.odin#L758) and `provider_reach_walk` in `region.odin` follow the payload.
- Void variants and empty arrays: skipped by the drop walk only.
- The recursion guard: a path-based one in [hooks.odin:413](src/hooks.odin#L413) makes that walk exponential (58 s measured), a visited map elsewhere.

All parts are walked at [semantic.odin:2204](src/semantic.odin#L2204), [semantic.odin:2262](src/semantic.odin#L2262) and [reflect.odin:149](src/reflect.odin#L149), with `Type_Walk` in all three.

Shared form: `type_parts(c, info, buf: ^[dynamic]Type_Id, follow_shared := false)`, returning element, key and element, field types or non-void variants, so each walker becomes its own test plus one loop; and one `type_any_part(c, id, seen, test)` for the second family. Saves about 60 lines in the first family and 70 in the second. A single kind list stops the next bug of this kind.

#### Synthesized syntax nodes

`Expr_Ident`: [capture.odin:102](src/capture.odin#L102), [capture.odin:137](src/capture.odin#L137), [check.odin:3889](src/check.odin#L3889), [check_calls.odin:329](src/check_calls.odin#L329), [expand.odin:636](src/expand.odin#L636), [hooks.odin:823](src/hooks.odin#L823), [parallel.odin:652](src/parallel.odin#L652).
One-name `Decl`: [capture.odin:110](src/capture.odin#L110), [capture.odin:140](src/capture.odin#L140), [check.odin:3898](src/check.odin#L3898), [parallel.odin:182](src/parallel.odin#L182), [parallel.odin:724](src/parallel.odin#L724), [parallel.odin:736](src/parallel.odin#L736).
Dereference: [check.odin:3857](src/check.odin#L3857), [parallel.odin:669](src/parallel.odin#L669), and with the place fields set, [check_expr.odin:1119](src/check_expr.odin#L1119) and [overload.odin:1011](src/overload.odin#L1011).
Selector: [check.odin:2878](src/check.odin#L2878), [check_calls.odin:204](src/check_calls.odin#L204), [expand.odin:627](src/expand.odin#L627), [optional.odin:269](src/optional.odin#L269), [parallel.odin:660](src/parallel.odin#L660).
One-argument call: [check.odin:4796](src/check.odin#L4796), [expand.odin:640](src/expand.odin#L640), [hooks.odin:832](src/hooks.odin#L832), [optional.odin:259](src/optional.odin#L259), [optional.odin:272](src/optional.odin#L272), [parallel.odin:678](src/parallel.odin#L678).

They differ only in whether the identifier id is passed or interned and in the `Decl` kind. [parallel.odin:651](src/parallel.odin#L651) already has the complete set, with `synth_ident`, `synth_selector` and `synth_deref` package-visible and the rest file-private. Shared form: move `synth_*` to `ast_clone.odin` or a new `synth.odin`, with `synth_decl(c, kind, name, value, declared_type = nil)`, and build `success_selector` and the failure selector on it. [parallel.odin:700](src/parallel.odin#L700) `synth_record` can also serve the record at [capture.odin:95](src/capture.odin#L95). Saves about 80 lines.

#### Impl member declaration

[impl.odin:209](src/impl.odin#L209) `declare_impl_member` and [generic.odin:3677](src/generic.odin#L3677) `declare_instance_impl_members` repeat the `L0409` clash checks, and [impl.odin:240](src/impl.odin#L240) and [generic.odin:3693](src/generic.odin#L3693) repeat the `Symbol` literal. The generic copy has lost the built-in member check (BUG-generic-5) and skips a non-constant member silently where [impl.odin:193](src/impl.odin#L193) reports `L0406` (BUG-impl-4). It also differs on purpose: it admits candidates from other blocks and takes `block.pkg`.

Shared form: `member_name_clash(k, subject, name, name_id, existing) -> bool` and `new_member_symbol(k, d, name, name_id, subject, pkg)`. Saves about 30 lines and fixes both bugs.

#### Checks on a new local name

[check.odin:560](src/check.odin#L560), [iterate.odin:1064](src/iterate.odin#L1064) and [optional.odin:607](src/optional.odin#L607) repeat `L0304`, the reserved-name test, `L0305` and `note_shadowed_capture`. They differ in which scope they search from and in whether a reserved name stops the declaration; [check.odin:573](src/check.odin#L573) also exempts `$` names. [expand.odin:173](src/expand.odin#L173) has none of the checks (BUG-expand-3), and [capture.odin:85](src/capture.odin#L85) inserts directly (BUG-capture-2).

Shared form: `check_new_local(k, name, id, span, outer_scope) -> bool`. Saves about 20 lines and fixes both.

#### Operator binding and the built-in operator table

[operators.odin:451](src/operators.odin#L451) `bind_operator_operands` with [operators.odin:480](src/operators.odin#L480) `check_operator_modes` is a cut-down copy of [overload.odin:902](src/overload.odin#L902). It has lost `substitute_caller_location` (BUG-operators-8) and the pointer dereference. Sharing `bind_candidate_slots(k, cand, sym, span, what)` saves about 25 lines.

The table of what a built-in operator accepts is split across [check_expr.odin:2658](src/check_expr.odin#L2658), [check.odin:4197](src/check.odin#L4197), [operators.odin:336](src/operators.odin#L336) and [operators.odin:363](src/operators.odin#L363). Shifts are only in the second and third, SIMD only in the second, which is BUG-operators-2 and BUG-operators-7. Shared form: one `builtin_operator_applies` with shift and SIMD cases and `compound_applies` as that minus concatenation. Saves about 30 lines.

[operators.odin:724](src/operators.odin#L724) `operator_token` is `operator_spelling` ([lexer.odin:745](src/lexer.odin#L745)) reversed: a loop over `operator_table` ([lexer.odin:682](src/lexer.odin#L682)) saves 40 lines.

#### Interface composition walk

[erased.odin:747](src/erased.odin#L747), [interface.odin:1356](src/interface.odin#L1356) and [interface.odin:1396](src/interface.odin#L1396) share the same 12-line loop body: skip slots, find the composed interface, clone the requirement, bind its arguments. They disagree on guards and context, which BUG-interface-1 to -4 report. `composed_application(k, requirement) -> (^Interface_Info, []Generic_Arg, bool)` saves about 30 lines and gives the guards one place to live.

In the same area, the candidate loop repeats at [erased.odin:893](src/erased.odin#L893) and [interface.odin:1018](src/interface.odin#L1018), and the constant argument conversion at [interface.odin:312](src/interface.odin#L312), [interface.odin:347](src/interface.odin#L347) and [generic.odin:3070](src/generic.odin#L3070) (`convert_generic_value`, file-private). Sharing both saves about 25 more.

#### Iterator types and synthesized members

Struct-shaped iterator types are built by hand in `iterate.odin` (`new_map_cursor_type` for the `{table, cursor}` ones), `add_mutable_sequence_members` in `iteration_mutable.odin` and `new_adapter_iterator` in `iteration_adapters.odin`. They differ in the `public` flag (the cause of BUG-iterate-2) and in the cache key.

Shared form: `new_iterator_type(c, name, label, element, key, fields)`. Saves about 30 lines.

`synth_proc` followed by setting `has_receiver` and `receiver` repeats at [customization.odin:112](src/customization.odin#L112), [iterate.odin:398](src/iterate.odin#L398), [format.odin:34](src/format.odin#L34) and [hooks.odin:803](src/hooks.odin#L803). Have `synth_proc` take the receiver from `modes[0]` under a `has_receiver` flag: saves about 15 lines.

#### Switch checking

The union path repeats the case-flow merge of [check.odin:4390](src/check.odin#L4390) at [optional.odin:574](src/optional.odin#L574). [check.odin:4464](src/check.odin#L4464) `check_exhaustive` and [optional.odin:713](src/optional.odin#L713) `report_uncovered_variants` build the same first-three list. `check_type_switch` is reached only by a switch already marked `.Pattern`, written at [optional.odin:377](src/optional.odin#L377) and [expand.odin:620](src/expand.odin#L620). Its subject is a union there, so `check_switch`'s own path serves it and the reviewer's route of deleting it and the dispatch at [check.odin:4324](src/check.odin#L4324) looks right, though a clone's subject should be tested first. With a `missing_list` builder and a `Case_Flow` accumulator this saves about 45 lines.

#### Constant values

- A `Const_Aggregate` is built by hand at 14 sites, for example [check_expr.odin:3332](src/check_expr.odin#L3332), [const_ops.odin:884](src/const_ops.odin#L884), [check_builtin.odin:1378](src/check_builtin.odin#L1378), [enums.odin:83](src/enums.odin#L83), [expand.odin:99](src/expand.odin#L99), [simd.odin:291](src/simd.odin#L291) and [union.odin:618](src/union.odin#L618), while [reflect.odin:307](src/reflect.odin#L307) `aggregate_const` is file-private. Three sites use another allocator, so the shared one takes one as a default parameter. Saves about 30 lines.
- [reflect.odin:317](src/reflect.odin#L317) `typeid_const` is [const_ops.odin:73](src/const_ops.odin#L73) `type_const`. Saves about 25.
- Unary folding is at [check_expr.odin:2057](src/check_expr.odin#L2057) and [eval.odin:852](src/eval.odin#L852). They differ in the allocator, in the decimal spelling kept for `-x`, and in how a failure reports. A `fold_unary(c, op, value, type, allocator) -> (Const_Value, overflowed: bool)` in `const_ops.odin` saves about 25.
- A big integer is rounded to a float at [bigint.odin:354](src/bigint.odin#L354), [bigint.odin:463](src/bigint.odin#L463) and [const_ops.odin:391](src/const_ops.odin#L391). `dyadic_to_float` is exact and general; the other two can call it once it releases its temporaries, which CTFE's charged allocator needs. Saves about 30.

#### Interface file and private-name checks

The binders [doc.odin:757](src/doc.odin#L757), [doc.odin:771](src/doc.odin#L771) and [doc.odin:781](src/doc.odin#L781) match [private_names.odin:460](src/private_names.odin#L460), [private_names.odin:473](src/private_names.odin#L473) and [private_names.odin:488](src/private_names.odin#L488), except that the doc copy also binds plain parameter names. [doc.odin:1105](src/doc.odin#L1105) `field_shown` and [private_names.odin:417](src/private_names.odin#L417) `field_is_exported` differ only in the `package main` default, and the second is also the site of BUG-private_names-6. Shared binders over `^[dynamic]string` and one field predicate save about 30 lines.

[foreign.odin:21](src/foreign.odin#L21) and [doc.odin:544](src/doc.odin#L544) restate member-then-block-then-file visibility, which `written_is_public` ([check.odin:662](src/check.odin#L662)) can express by nesting; [foreign.odin:49](src/foreign.odin#L49) repeats the `L0332` text of [check.odin:649](src/check.odin#L649). About 15 lines.

#### Diagnostics rollback

[source.odin:660](src/source.odin#L660), [source.odin:766](src/source.odin#L766), [check.odin:3350](src/check.odin#L3350) and `prov_drop_event_diagnostics` each shrink the list and clamp `last_noted_diagnostic`, and the second also undoes `error_count` by hand. A `shrink_diagnostics(c, length)` saves about 5 lines.

#### Configuration declared three times

The same nine settings are fields of `Compilation_Config` ([session.odin:9](src/session.odin#L9)), `Options` ([main.odin:88](src/main.odin#L88)) and `Compiler` ([source.odin:278](src/source.odin#L278)), and are copied at [main.odin:174](src/main.odin#L174), [main.odin:269](src/main.odin#L269) and [session.odin:87](src/session.odin#L87). One embedded `Build_Settings` struct saves about 25 lines. [session.odin:90](src/session.odin#L90) also sets `c.target`, which [semantic.odin:937](src/semantic.odin#L937) overwrites from the same `c.cpu`.

#### File rewriting and scratch lexing

[doc.odin:134](src/doc.odin#L134) repeats [formatter.odin:60](src/formatter.odin#L60) `format_text`.

### Provenance and borrow analysis

#### Variadic pack walk

The two-cursor walk over `variadic_order` is at [cfg.odin:2843](src/cfg.odin#L2843), [cfg_provenance.odin:8528](src/cfg_provenance.odin#L8528), [cfg_provenance.odin:10017](src/cfg_provenance.odin#L10017), [provenance_form.odin:112](src/provenance_form.odin#L112), [emit_llvm_stmt.odin:264](src/emit_llvm_stmt.odin#L264) and [emit_llvm_calls.odin:1068](src/emit_llvm_calls.odin#L1068), each with its own type or action per operand. `call_pack_next(call, &cursor) -> (operand: Expr, spread: bool, more: bool)` in `ast.odin` saves about 4 lines per site, 25 in all.

#### Worklists

The forward block queue is written out at [borrow.odin:3470](src/borrow.odin#L3470), [borrow.odin:3585](src/borrow.odin#L3585), [borrow.odin:4789](src/borrow.odin#L4789) and [lifecycle.odin:941](src/lifecycle.odin#L941). The body stack with `queued` is at [global_effects.odin:955](src/global_effects.odin#L955), [global_effects.odin:1528](src/global_effects.odin#L1528) and [global_effects.odin:1987](src/global_effects.odin#L1987). They differ only in the join each performs. `Block_Queue` and `Body_Queue`, each with init, pop and push-if-absent, save about 45 lines.

#### Paths

[cfg_provenance.odin:3210](src/cfg_provenance.odin#L3210) `prov_extend`, [cfg_provenance.odin:3218](src/cfg_provenance.odin#L3218) `prov_concat_path` and [borrow.odin:949](src/borrow.odin#L949) `carrier_steps` differ only in the allocator. `path_extend` and `path_concat` beside `proj_*` save about 15 lines. The depth bound 8 is a literal at both [borrow.odin:1223](src/borrow.odin#L1223) and [cfg_provenance.odin:4616](src/cfg_provenance.odin#L4616).

#### Naming a callable value, and reset points

[borrow.odin:2574](src/borrow.odin#L2574) and [global_effects.odin:344](src/global_effects.odin#L344) unwrap a move and switch on identifier, selector and literal in the same way, then classify differently. `named_value_symbol(e) -> Symbol_Id` saves about 10 lines.

[cfg.odin:1092](src/cfg.odin#L1092) and [cfg_provenance.odin:5356](src/cfg_provenance.odin#L5356) build `Reset_Key` by hand, and the assert at the second depends on the first. [cfg.odin:2867](src/cfg.odin#L2867) and [cfg_provenance.odin:9904](src/cfg_provenance.odin#L9904) loop over `proc_param_resets` separately and must agree; a `call_reset_arguments` iterator ties them. Saves about 10 lines.

### LLVM emitter

#### Foreign result and parameter spelling

The parameter switch is at [emit_llvm_abi.odin:882](src/emit_llvm_abi.odin#L882) and [emit_llvm_abi.odin:1043](src/emit_llvm_abi.odin#L1043), which differ in the `zeroext` attribute.

Shared form: one `foreign_param_llvm(e, info, parameter, index, attributes: bool)`. Saves about 15 lines.

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
- Frame finish: [emit_llvm.odin:727](src/emit_llvm.odin#L727) and [emit_llvm_cleanup.odin:406](src/emit_llvm_cleanup.odin#L406) are the same sequence, except that one writes `e.pending` straight out. About 8.
- Union storage head: [emit_llvm_abi.odin:410](src/emit_llvm_abi.odin#L410) and [emit_llvm_expr.odin:42](src/emit_llvm_expr.odin#L42) spell the same `i%d`, so the BUG-emit_llvm_abi-1 fix must change both. Share the head spelling.
- Slice from data and length: [emit_llvm_containers.odin:236](src/emit_llvm_containers.odin#L236) open-codes [emit_llvm_expr.odin:2159](src/emit_llvm_expr.odin#L2159) `emit_ptr_len` twice.

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
- Source text by span: [cfg.odin:1913](src/cfg.odin#L1913), [cfg_provenance.odin:489](src/cfg_provenance.odin#L489), [check.odin:2394](src/check.odin#L2394), [capture.odin:93](src/capture.odin#L93), with [doc.odin:1374](src/doc.odin#L1374) file-private. Span key: [attributes.odin:150](src/attributes.odin#L150), [hooks.odin:1106](src/hooks.odin#L1106), [hooks.odin:1138](src/hooks.odin#L1138). `span_text` and `span_key` in `source.odin`.

#### Code in the wrong file

Each move below names a site with its only callers or its stated owner. Moves save no lines; they make the source-code map true.

- Equality helpers are in the hash file: [hash.odin:258](src/hash.odin#L258) to line 339 belongs near `type_is_comparable` in `semantic.odin`.
- Argument binding is in the overload file: [overload.odin:876](src/overload.odin#L876) to line 1023 belongs in `check_calls.odin`.
- Interface logic is in the erasure file: [erased.odin:402](src/erased.odin#L402) `interface_scope`, [erased.odin:620](src/erased.odin#L620) `composed_interface_of` and [erased.odin:722](src/erased.odin#L722) `interface_slots` belong in `interface.odin`, and [erased.odin:1075](src/erased.odin#L1075) `check_as_call` in `union.odin`.
- Layering: [box.odin:12](src/box.odin#L12) layout is used only by `emit_llvm_box.odin`. [doc.odin:533](src/doc.odin#L533) `decl_is_public` is called from a checker pass and belongs beside `written_is_public`. [cfg_provenance.odin:7854](src/cfg_provenance.odin#L7854) `call_proc_type` and [cfg_provenance.odin:1597](src/cfg_provenance.odin#L1597) `symbol_outlives_bodies` serve other subsystems and belong by [semantic.odin:1339](src/semantic.odin#L1339).
- Transfer wording and type reach: [cfg_provenance.odin:9950](src/cfg_provenance.odin#L9950) belongs beside [hooks.odin:474](src/hooks.odin#L474) and [hooks.odin:565](src/hooks.odin#L565), in a `transfer_facts.odin` split from `hooks.odin` lines 430-567.
- Records and subsystems that have outgrown their files: `Compiler`, 380 of 911 lines of `source.odin` from [source.odin:78](src/source.odin#L78). Formatting in [emit_llvm_runtime.odin:541](src/emit_llvm_runtime.odin#L541) onward. Program entry at [emit_llvm.odin:738](src/emit_llvm.odin#L738). The doc-comment reader at [doc.odin:1151](src/doc.odin#L1151).
- Seams in the largest file: `cfg_provenance.odin` (10,813 lines) splits at the offset engine ([cfg_provenance.odin:846](src/cfg_provenance.odin#L846)) and the regions ([cfg_provenance.odin:3986](src/cfg_provenance.odin#L3986)).

### Looked at and left alone

- `aggregate_equal` and `aggregate_order` ([const_ops.odin:777](src/const_ops.odin#L777), [const_ops.odin:835](src/const_ops.odin#L835)) against `eval_compare` ([eval.odin:1131](src/eval.odin#L1131)): one loop would need a reader callback over `Const_Value` and `Eval_Value`, no simpler than the copies. Fix BUG-eval.part1-3 in place.
- `eval_hash` ([eval.odin:4112](src/eval.odin#L4112)) against `emit_hash_value` ([emit_llvm_calls.odin:397](src/emit_llvm_calls.odin#L397)): one computes and one emits, so they can only change together.
- `prints_through_method_walk` ([format.odin:78](src/format.odin#L78)) against `emit_format_body` ([emit_llvm_runtime.odin:698](src/emit_llvm_runtime.odin#L698)): the layering rules out a shared form; the checker cannot call the emitter's walk.
- `synchronized_field_walk` ([materialize.odin:119](src/materialize.odin#L119)) and `type_requires_results_walk` ([zero.odin:98](src/zero.odin#L98)): inline-only walks with no closures to share them; a visitor would be longer.
- `type_is_comparable_walk` ([semantic.odin:1976](src/semantic.odin#L1976)), `record_order_blocker_walk` ([semantic.odin:2074](src/semantic.odin#L2074)) and `type_is_hashable_walk` ([hash.odin:30](src/hash.odin#L30)): each kind has its own rule, so `type_parts` would remove little.
- Region-content find-or-grow ([cfg_provenance.odin:4394](src/cfg_provenance.odin#L4394), [cfg_provenance.odin:5835](src/cfg_provenance.odin#L5835), [borrow.odin:2974](src/borrow.odin#L2974)): differing equality tests, path truncation and allocators leave a shared form no simpler.
- `fmt.aprintf(..., allocator = c.semantic_allocator)` at 57 sites and the FNV step at about 20: a wrapper shortens the lines without removing any, and the checker's local failure blocks are better served by per-file helpers such as `requirement_failuref`.

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

- [bootstrap.odin:71](src/bootstrap.odin#L71) and [generic.odin:3603](src/generic.odin#L3603): both test for one `^Expr_Proc_Group` value, and `decl_is_proc_group` is file-private. Export it; this case becomes `if sym.decl != nil && decl_is_proc_group(sym.decl) { return id }`. (about 3 lines)
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
- [box.odin:226](src/box.odin#L226): the three-line one-element `v.bound` also appears at erased.odin:1014, lifecycle.odin:38, 81 and reflect.odin:900. Shared form: `bound_exprs(k, e)`, from `check_builtin.odin`. (about 12 lines)
- [box.odin:97](src/box.odin#L97) and [check_calls.odin:561](src/check_calls.odin#L561): the "one positional value" test is repeated at check_calls.odin:947, enums.odin:32 and lifecycle.odin:25, 47. Shared form: `has_one_plain_argument(v)`.

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
- (branch) [capture.odin:124](src/capture.odin#L124): this is the only write to `capture_records`, and `method` is never nil, so `method != nil` at [erased.odin:336](src/erased.odin#L336), [erased.odin:347](src/erased.odin#L347) and [global_effects.odin:271](src/global_effects.odin#L271) is always true.
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
- [cfg.odin:1913](src/cfg.odin#L1913), [cfg_provenance.odin:489](src/cfg_provenance.odin#L489), [parallel.odin:81](src/parallel.odin#L81), [doc.odin:1374](src/doc.odin#L1374): slicing a span out of `sources`; `source_text` is file-private to `doc.odin`, and exporting a span form replaces them.

### src/cfg_provenance.odin (part 1 of 4)

This part is careful and I found no bugs; the reaching-places walk (Tarjan with epochs) held up when traced by hand, and every top-level declaration has a user. The cost is bulk: repeated small path and slot idioms, a few quadratic list builds, and a place-offset engine that deserves its own file.

**Simplification**


**Dead code**


**Data structures and algorithms**

- [cfg_provenance.odin:2618](src/cfg_provenance.odin#L2618) `prov_capture`: scans all of `graph.reborrows` per captured slot, so it grows with captures times the body's reborrows. Only large generated bodies would notice, so a `derived`-to-reborrows index is worth adding only if `perf.ps1` shows it.
- [cfg_provenance.odin:133](src/cfg_provenance.odin#L133) `Prov_Event`: about 540 bytes by hand count (not measured), and `borrow.odin` has a dozen by-value `for event in block.prov` loops, though each kind reads few fields. The "`Publish`:" and "`Reset`:" comments mark natural sub-structs; a pointer for Publish-only fields would save about 140 bytes per event.

**Near copies**

- [cfg_provenance.odin:2670](src/cfg_provenance.odin#L2670) and [cfg_provenance.odin:3948](src/cfg_provenance.odin#L3948): `prov_plain_slice_local` and `prov_plain_view_local` share all but the last test, and L2677, L2715 and L3954 repeat the erased-type choice. Share `prov_view_local(graph, e) -> (ident, type, ok)`. (about 8 lines)
- [cfg_provenance.odin:489](src/cfg_provenance.odin#L489) and [doc.odin:1372](src/doc.odin#L1372): span text is hand-indexed here, in a file-private `source_text`, and at [parallel.odin:81](src/parallel.odin#L81), [cfg.odin:1913](src/cfg.odin#L1913) and [check.odin:2394](src/check.odin#L2394). A `span_text(c, span)` in `source.odin` is the shared form.

**Structure and boundaries**

- [cfg_provenance.odin:846](src/cfg_provenance.odin#L846): lines 846-1329 are a self-contained engine (offsets, merging, reaching walk) with a small interface: `prov_value_offset`, `prov_note_offset`, `prov_carrier_offsets`, `prov_offset_paths`, `prov_offset_precision`, `prov_reach_invalidate`. Move them to `provenance_offsets.odin`, with `Prov_Reach*` and `Prov_Offset` from borrow.odin.
- [cfg_provenance.odin:300](src/cfg_provenance.odin#L300): lines 300-702 are construction procedures sitting under the "provenance events" banner, above the "provenance construction" banner at L704, which hides where the vocabulary ends. Move them below that banner.
- [cfg_provenance.odin:2351](src/cfg_provenance.odin#L2351): path helpers are scattered (L1323, L2351-2384, L3210-3223, L6037) with mixed `path_`/`prov_` prefixes, while `paths_overlap` and `proj_*` live at borrow.odin:175-194. Gather the graph-free ones beside those.

**Comments**


### src/cfg_provenance.odin (part 2 of 4)

This range holds reborrows, parameter loans and caller slots, read-only views, and the allocator-region section; the logic is careful but repeats its predicates and region idioms, and 384 of its 2770 lines are comments, many of them long restatements of the spec.

**Simplification**

- [cfg_provenance.odin:5415](src/cfg_provenance.odin#L5415) `prov_materialize_reset`: the provider and non-provider owner branches differ only in the region tested. Pick the region first (`provider_parents[id]`, else the `provider_end` choice between `prov_region_for_symbol` and `prov_reset_symbol_region`), then one empty-and-overlap test and one `verb`/`owner_span`/`break`; this also stops computing `owner_region` twice at [:5434](src/cfg_provenance.odin#L5434). (about 12 lines)
- [cfg_provenance.odin:5397](src/cfg_provenance.odin#L5397) `prov_materialize_reset`: `prov_reset_promise` never returns `covered` true with a name, so `reset_covered = unmarked == "" && covered` is just `covered`. Write `covered, unmarked := true, ""; if !region_is_local_only(set) { covered, unmarked = prov_reset_promise(graph, set) }`. (about 3 lines)
- [cfg_provenance.odin:4901](src/cfg_provenance.odin#L4901) `prov_handle_region`: three exits build the same unknown set. Use `if is_ident { region_of lookup } else if receiver.temporary { ... } else if local place { ... }` and one unknown fallthrough. (about 5 lines)
- [cfg_provenance.odin:5069](src/cfg_provenance.odin#L5069) `prov_call_region`: every effective branch of the argument loop tests `!direct`. Wrap the loop and the `unknown` fallback in one `if !direct`, compute `info` there, and merge the allocator and `.Move` branches, which do the same thing. (about 6 lines)
- [cfg_provenance.odin:4172](src/cfg_provenance.odin#L4172) `prov_written_parameter_content`: the deep copy is needless, since `add` with `written = true` only edits by-value fields and the one caller ([borrow.odin:2946](src/borrow.odin#L2946)) only reads. Pass `content` directly; the `if len(aliases) > 0` around the loop at [:4158](src/cfg_provenance.odin#L4158) is needless too. (about 5 lines)
- [cfg_provenance.odin:4395](src/cfg_provenance.odin#L4395) `prov_define_region_content`: `len(...) == len(...) && path_has_exact_prefix` is `prov_same_path`; the store at [:4397](src/cfg_provenance.odin#L4397) rewrites an unchanged slice; and [:4401](src/cfg_provenance.odin#L4401) is `slice.clone`. (about 3 lines)
- [cfg_provenance.odin:5283](src/cfg_provenance.odin#L5283) `prov_call_region_content`: `make` plus `copy` is `slice.clone(content.path, graph.alloc)`, inline in the literal. (about 3 lines)
- [cfg_provenance.odin:3823](src/cfg_provenance.odin#L3823) `prov_view_through_carrier`: one caller ([:3740](src/cfg_provenance.odin#L3740)); join the parts there and move its comment onto `prov_view_parts_through_carrier`. `prov_hidden_root` ([:3901](src/cfg_provenance.odin#L3901)) likewise has one caller and two statements. (about 12 lines)
- [cfg_provenance.odin:4768](src/cfg_provenance.odin#L4768) `prov_storage_region`: the allocator test only bypasses the carrier test. Use `if id != 0 && <view carrier, see Near copies> { return prov_viewed_region(graph, id) }; return prov_region_of(graph, id)`. (about 3 lines)
- [cfg_provenance.odin:4737](src/cfg_provenance.odin#L4737) `prov_region_of`: the `Default_Allocator` case is redundant, because both remaining paths reach the same test at [:5050](src/cfg_provenance.odin#L5050) (`call_results` is only filled by `prov_call_region`). (about 5 lines)
- [cfg_provenance.odin:5483](src/cfg_provenance.odin#L5483) `prov_reset_temporary`: the two "join all, or the reset-relevant fields" branches can be one local proc taking `type` and `fields`, with `prov_storage(graph, temporary.storage)` read once. (about 4 lines)
- [cfg_provenance.odin:3704](src/cfg_provenance.odin#L3704) `prov_erase` and [:3954](src/cfg_provenance.odin#L3954) `prov_plain_view_local`: `prov_repr` is called two and three times; hoist `repr :=` as `prov_argument_only_read` does at [:2710](src/cfg_provenance.odin#L2710). (about 1 line)
- [cfg_provenance.odin:4616](src/cfg_provenance.odin#L4616): the literal depth 8 here and at [:4647](src/cfg_provenance.odin#L4647), [:5207](src/cfg_provenance.odin#L5207) and [borrow.odin:1222](src/borrow.odin#L1222) is one limit on one shape walk; name it beside `CARRIER_DEPTH`.

**Dead code**

- (branch) [cfg_provenance.odin:3727](src/cfg_provenance.odin#L3727): `prov_read_only_view` has one caller ([:3710](src/cfg_provenance.odin#L3710)), which always passes `erasing = true` and `erased_from`; drop `erasing` and its two `if` guards, and `type` can be computed inside.
- (branch) [cfg_provenance.odin:5129](src/cfg_provenance.odin#L5129): the `query` default on `prov_copied_region_at` is unused, since all three callers pass it.

**Data structures and algorithms**

- [cfg_provenance.odin:3075](src/cfg_provenance.odin#L3075) `prov_slot_is_reborrow`, [:3025](src/cfg_provenance.odin#L3025) `prov_slot_is_pending`, [:2799](src/cfg_provenance.odin#L2799) and [:2946](src/cfg_provenance.odin#L2946): each scans all of `graph.reborrows`, once per stored slot or per solved load, and the list grows with carrier copies in the body, so long bodies go quadratic. Index by `derived` and by `source` (per-slot lists), rebuilt after `prov_settle_pending_reborrows`.
- [cfg_provenance.odin:2748](src/cfg_provenance.odin#L2748) `prov_reborrow`: scans every place loan per weakened slot, which also grows with the body; a slot-to-place-loans index fits.
- [cfg_provenance.odin:4403](src/cfg_provenance.odin#L4403) `prov_define_region_content`: copies the whole entry list into a new arena array for each new path, plus a linear scan per define, so a record of k region fields costs O(k^2) time and arena per whole store, per round. Matters only for wide records; a `[dynamic]` value in `region_content` removes the copying.
- [cfg_provenance.odin:3218](src/cfg_provenance.odin#L3218) `prov_concat_path`: allocates even when one side is empty, which is usual at [:5107](src/cfg_provenance.odin#L5107), [:4194](src/cfg_provenance.odin#L4194) and [:4814](src/cfg_provenance.odin#L4814). Paths are not edited in place (`prov_region_path` clones first), so return the other side when one is empty.

**Near copies**

- [cfg_provenance.odin:3433](src/cfg_provenance.odin#L3433) and [cfg_provenance.odin:3463](src/cfg_provenance.odin#L3463): `prov_pointers_below` and `prov_carrier_below` walk the same one-carrier chain, the first also requiring pointers. One `prov_carrier_below(c, type, depth) -> (carrier, all_pointers)` serves both sites in `prov_caller_slots`, and `prov_pointers_below(c, t, 0)` is just `.Pointer`. (about 15 lines)
- [cfg_provenance.odin:2670](src/cfg_provenance.odin#L2670) and [cfg_provenance.odin:3948](src/cfg_provenance.odin#L3948): `prov_plain_slice_local` is `prov_plain_view_local` plus "is a slice"; even the type line is identical ([:2677](src/cfg_provenance.odin#L2677), [:3954](src/cfg_provenance.odin#L3954)). Keep the view form and test the kind at the slice callers. (about 12 lines)
- [cfg_provenance.odin:5182](src/cfg_provenance.odin#L5182) and [cfg_provenance.odin:1412](src/cfg_provenance.odin#L1412): the same "own query, own depth, overlap, matched" loop over `region_content`. Share `prov_merge_matching_content(out: ^Region_Set, contents, path, query) -> bool`; `out` stays the caller's because the hook's set has the callee's parameter count. (about 8 lines)
- [cfg_provenance.odin:3996](src/cfg_provenance.odin#L3996) and [:4113](src/cfg_provenance.odin#L4113), [:4158](src/cfg_provenance.odin#L4158), [:4192](src/cfg_provenance.odin#L4192), [:4384](src/cfg_provenance.odin#L4384): each spells the rule that a final `NO_ROOT` alias means targets are not all known. A `prov_aliases_settle(aliases) -> bool` (non-empty, last root known) states `Prov_Region_Alias`'s rule once. (about 5 lines)
- [cfg_provenance.odin:4122](src/cfg_provenance.odin#L4122) and [cfg_provenance.odin:4166](src/cfg_provenance.odin#L4166): an identical three-part "view carrier" test, also inside [:3042](src/cfg_provenance.odin#L3042) and split at [:4768](src/cfg_provenance.odin#L4768). Add `prov_type_is_view_carrier(c, type)`. (about 4 lines)
- [cfg_provenance.odin:3248](src/cfg_provenance.odin#L3248) and [cfg_provenance.odin:1453](src/cfg_provenance.odin#L1453): the test for a parameter that gets a region of its own appears twice, and the second depends on matching the first. Share one predicate. (about 2 lines)
- [cfg_provenance.odin:4046](src/cfg_provenance.odin#L4046) and [:4034](src/cfg_provenance.odin#L4034), [:4173](src/cfg_provenance.odin#L4173), [:4204](src/cfg_provenance.odin#L4204), [:4414](src/cfg_provenance.odin#L4414): "empty set, then merge" is a clone. Add `region_clone(set, params, allocator)` beside `region_merge`; the BUG-1 fix uses it too. (about 6 lines)
- [cfg_provenance.odin:4687](src/cfg_provenance.odin#L4687) and [:4738](src/cfg_provenance.odin#L4738), [:4752](src/cfg_provenance.odin#L4752), [:4913](src/cfg_provenance.odin#L4913), [:4920](src/cfg_provenance.odin#L4920), [:5146](src/cfg_provenance.odin#L5146): the empty-set-then-flag triple. `prov_default_region` and `prov_unknown_region` make each one line. (about 8 lines)
- [cfg_provenance.odin:3275](src/cfg_provenance.odin#L3275) and [:3283](src/cfg_provenance.odin#L3283), [:3309](src/cfg_provenance.odin#L3309), [:3417](src/cfg_provenance.odin#L3417): new loan, then set `content`, `depth`, `pointee`. A `prov_new_content_loan(..., depth, pointee)` plus `carrier_path_noun(c, path)` for the `truncated ? "borrow"` choice (also at [:1939](src/cfg_provenance.odin#L1939)) shortens all four. (about 8 lines)
- [cfg_provenance.odin:3232](src/cfg_provenance.odin#L3232) and [:4291](src/cfg_provenance.odin#L4291), [:5327](src/cfg_provenance.odin#L5327), [:6397](src/cfg_provenance.odin#L6397), [:10142](src/cfg_provenance.odin#L10142): hand-counted walks of `signature.params`. A flat `graph.param_symbols: []Symbol_Id` built with the graph replaces `param_count`, `prov_parameter_symbol` and the search in `prov_self_reads_begin`. (about 15 lines)
- [cfg_provenance.odin:4977](src/cfg_provenance.odin#L4977) and [cfg_provenance.odin:5040](src/cfg_provenance.odin#L5040): the same "strong copy, weak handle, or upgrade" test. Share `prov_call_keeps_shared_handle(graph, v, type)`. (about 2 lines)

**Structure and boundaries**

- [cfg_provenance.odin:3986](src/cfg_provenance.odin#L3986): the regions section (to about line 5503) and its other half at [:1353](src/cfg_provenance.odin#L1353) to [:1574](src/cfg_provenance.odin#L1574) are about 1700 lines of one subsystem separated by unrelated carrier code. Move both to their own file beside `provenance_transfer_facts.odin`; the seam is the `prov_region_*`, `prov_provider_*` and `prov_copied_*` procedures, at the cost of widening some `@(private = "file")`.
- [cfg_provenance.odin:5380](src/cfg_provenance.odin#L5380): `prov_materialize_reset`, `prov_reset_temporary`, `prov_reset_promise` and `prov_parameter_symbol` are event materialization and belong in `provenance_event.odin`, with `prov_returning_region`, since that file owns the replacement of fact-dependent events. Within it, the blocker search from [:5415](src/cfg_provenance.odin#L5415) to [:5471](src/cfg_provenance.odin#L5471) is a natural `prov_reset_blocker`.
- [cfg_provenance.odin:3227](src/cfg_provenance.odin#L3227) `prov_bind_parameters`: about 95 lines at five nesting levels. Extract the region seed ([:3248](src/cfg_provenance.odin#L3248)), the aggregate shape loans ([:3281](src/cfg_provenance.odin#L3281)) and the pointee loans ([:3303](src/cfg_provenance.odin#L3303)).

**Comments**

- [cfg_provenance.odin:3325](src/cfg_provenance.odin#L3325): 22 lines before `prov_caller_slots`, the second half narrating `borrow.odin`'s publication. Keep up to "reads these slots" plus the "slots of different loans name different storage" assumption, and point at `publish_into_caller` for stores. (about 12 lines)
- [cfg_provenance.odin:5119](src/cfg_provenance.odin#L5119): 9 lines listing cases the body shows. Shorten to "The regions at `path` of a copy of `source` as `type`: new storage in the copy's allocator, logical copies keep the source's." Also delete the last two sentences at [:5111](src/cfg_provenance.odin#L5111). (about 9 lines)
- [cfg_provenance.odin:3720](src/cfg_provenance.odin#L3720): stale, since printed arguments do not call this proc. Delete "or an argument a report prints does" and line 3725, the `erasing` note. (about 2 lines)
- [cfg_provenance.odin:3225](src/cfg_provenance.odin#L3225), [:5338](src/cfg_provenance.odin#L5338), [:5398](src/cfg_provenance.odin#L5398) and [:5414](src/cfg_provenance.odin#L5414): bare `design.md` breaks the exact-heading rule. Cite `design.md "Procedure result contracts"`, `design.md "@(allocator_reset)"` twice, and `design.md "Allocator regions and region provenance"`.
- [cfg_provenance.odin:3619](src/cfg_provenance.odin#L3619): delete the "Shared by ..." sentence, which only names the callers. Same for [:4959](src/cfg_provenance.odin#L4959), [:2905](src/cfg_provenance.odin#L2905), [:2912](src/cfg_provenance.odin#L2912) and [:3023](src/cfg_provenance.odin#L3023), which restate the name; keep the backticked type where it helps. (about 7 lines)
- [cfg_provenance.odin:4141](src/cfg_provenance.odin#L4141): 7 lines; keep "kept apart by field; the argument's prior value and the body's own regions say nothing new", and drop the rest, which the body and `Prov_Region_Content.from` say. (about 4 lines)
- [cfg_provenance.odin:2921](src/cfg_provenance.odin#L2921): 9 lines, mostly the two branches read aloud, and similar paragraphs at [:2725](src/cfg_provenance.odin#L2725), [:3506](src/cfg_provenance.odin#L3506) and [:3597](src/cfg_provenance.odin#L3597). Cut each to the rule and the citation. (about 60 lines across this part)

### src/cfg_provenance.odin (part 3 of 4)

Region stores, written aliases, place walking, and the statement and call hooks: the comments mostly earn their place, but `prov_assign`, `prov_call` and `prov_declare_region` do too many jobs and hold most of the local repetition. The three bugs below were reproduced with the repository's `lokec.exe`, built a minute after this commit.

**Bugs**


**Simplification**

- [cfg_provenance.odin:7594](src/cfg_provenance.odin#L7594) `prov_assign`: `permutes = prov_assign_permutes(graph, s)` recomputes, with an allocation, the local `permutes` from 7457. Use `permutes = permutes`.
- [cfg_provenance.odin:7612](src/cfg_provenance.odin#L7612) `prov_assign`: both branches repeat `len(paths) == 1 && prov_offsets_agree(...) && prov_path_names_one_place(paths[0])`. Test that once, set `path` and `place_path`, then branch on `prov_path_names_one_place(below)` versus `lands == nil && publish.linked`. (about 3 lines)
- [cfg_provenance.odin:7582](src/cfg_provenance.odin#L7582) `prov_assign`: `linked_sources` is only ever measured; use `links := !replaces_read && len(sources) > 0` at 7587 and 7593. Also `stored` (7580) and the `prov_type` at 7647 are `target_type`, `!place_ok` at 7652 is always true, and the `value_loans != nil` at 7467 and 7474 add nothing to the length tests. (about 4 lines)
- [cfg_provenance.odin:6972](src/cfg_provenance.odin#L6972) `prov_slice`: the `lo`/`hi` walk is written three times (6972, 6989, 7005) and the tail at 7014-7021 has two returns of `source`. A `prov_walk_slice_bounds` helper and `if array && prov_expr_is_temporary(v.operand) {...}; return source` do it. (about 11 lines)
- [cfg_provenance.odin:8004](src/cfg_provenance.odin#L8004) `prov_call`: `explicit_view_operand` already rejects anything but `Call_Conversion`, so `case Call_Conversion, Call_Dyn_Conversion:` can hold both tests. (about 4 lines)
- [cfg_provenance.odin:8000](src/cfg_provenance.odin#L8000) `prov_call`: `v == graph.spawning && !thread_facts_pending` is computed at 8000, 8089 and 8126, and nothing in the walk changes either side; one `spawned` at the top serves all three. (about 2 lines)
- [cfg_provenance.odin:8135](src/cfg_provenance.odin#L8135) `prov_call`: `proc_parameter_mode(c, call_proc_type(c, v), index)` re-resolves what `input.arguments[index].mode` holds, as `prov_argument_is_inout` reads it. (about 1 line)
- [cfg_provenance.odin:7273](src/cfg_provenance.odin#L7273) `prov_declare_region`: `source` is built from `projected` at 7274, 7325 and 7345; hoist it to the top, then `prov_result_region_at(graph, value, source)` also covers the branch at 7273. (about 7 lines)
- [cfg_provenance.odin:7299](src/cfg_provenance.odin#L7299) `prov_declare_region`: `type_is_carrier` is already true of `TYPE_ALLOCATOR` (borrow.odin:529), so the test is just `type_is_carrier`; the same makes the `!= TYPE_ALLOCATOR` at 7522 redundant. (about 1 line)
- [cfg_provenance.odin:7308](src/cfg_provenance.odin#L7308) `prov_declare_region`: `prov_type_has_region` already answers true for managed types, so `managed` goes and the test is `!prov_type_has_region`; likewise 7520-7521 reduce to `prov_type_has_region(c, target_type)`. (about 3 lines)
- [cfg_provenance.odin:6111](src/cfg_provenance.odin#L6111) `prov_note_written_alias`: `type_carries_borrow(...).any` is already true of a carrier (borrow.odin:748), so `type_is_carrier ||` is redundant here, at 6123 and at 6136. Also at 10181.
- [cfg_provenance.odin:6071](src/cfg_provenance.odin#L6071) `prov_written_aliases_of`: the `len(aliases) > 0` guard only wraps a `for` that handles empty. (about 2 lines)
- [cfg_provenance.odin:6778](src/cfg_provenance.odin#L6778) `prov_map_entry_step`: `.Integer` and `.Rune` differ by one letter; one case with the prefix picked by `kind` does both. (about 5 lines)
- [cfg_provenance.odin:6720](src/cfg_provenance.odin#L6720) `prov_walk_subscripts`: compute `is_map := len(v.bound) == 0 && underlying_kind(...) == .Map` once for 6720 and 6723; the `info == nil` test at 6728 cannot fire once the kind is `.Map`. (about 4 lines)
- [cfg_provenance.odin:7717](src/cfg_provenance.odin#L7717) `prov_names_same_place`: the comparison runs even when only one side is constant. Use `if x.is_const != y.is_const { return false }`, then compare both. (about 1 line)
- [cfg_provenance.odin:5981](src/cfg_provenance.odin#L5981) `prov_written_storage_type`: a one-call wrapper for `prov_storage(graph, storage).type`; `prov_address_of` (6876) is the same for `prov_borrow_place` from cfg.odin:2424. Inline both. (about 8 lines)

**Dead code**

- (branch) [cfg_provenance.odin:7341](src/cfg_provenance.odin#L7341): `set` is only filled under `type_is_container` at 7320, which is `.Dynamic_Array` or `.Map`, so this else branch and the `.Box` test at 7338 cannot run. Keep only the `prov_define_region_content` call.
- (branch) [cfg_provenance.odin:5585](src/cfg_provenance.odin#L5585): `prov_region_escape`'s defaults are never used by its one caller (7479), which passes every argument; the same holds for `prov_declare_region`'s defaults at 7262-7263.

**Near copies**

- [cfg_provenance.odin:5918](src/cfg_provenance.odin#L5918) and [cfg_provenance.odin:6251](src/cfg_provenance.odin#L6251): the same bound-the-path, scan `seen`, append visit. A `prov_first_alias_visit(seen, target, path, writable) -> (bounded, ok)` replaces both, beside `Written_Alias_Visit`.
- [cfg_provenance.odin:5674](src/cfg_provenance.odin#L5674), [cfg_provenance.odin:7350](src/cfg_provenance.odin#L7350), [cfg_provenance.odin:10455](src/cfg_provenance.odin#L10455), `check_via_policy` in [check.odin](src/check.odin) and [lifecycle.odin:109](src/lifecycle.odin#L109): each names the storage of a duration by hand. One `storage_phrase(duration)` covers them.
- [cfg_provenance.odin:5737](src/cfg_provenance.odin#L5737) and [cfg_provenance.odin:7636](src/cfg_provenance.odin#L7636): the same test (managed, allocator, or a non-carrier with a region), written inverted at one site. Name it `prov_store_keeps_region(c, type)`.
- [cfg_provenance.odin:5835](src/cfg_provenance.odin#L5835), [cfg_provenance.odin:4394](src/cfg_provenance.odin#L4394) and [borrow.odin:2974](src/borrow.odin#L2974): find an equal content entry, else grow a fresh slice with a cloned entry. `prov_define_region_content` still compares by hand and could use `prov_same_region_content` and `prov_clone_region_content`.

**Structure and boundaries**

- [cfg_provenance.odin:7397](src/cfg_provenance.odin#L7397) `prov_assign`: 260 lines. Seams: capture of values a target redefines (7404-7424), early destination reads (7433-7456), the store through a carrier (7549-7632), and within that building the publish event (7591-7624).
- [cfg_provenance.odin:7993](src/cfg_provenance.odin#L7993) `prov_call`: 170 lines. Seams: the allocator handle case as `prov_handle_call` (8025-8057), the unbound path (8081-8103), and evaluating bound arguments (8104-8123). The handle case's `held` also hides the `held` count from 7997.
- [cfg_provenance.odin:7257](src/cfg_provenance.odin#L7257) `prov_declare_region`: 100 lines with a provider path and a storage check. Split out the provider part (7288-7298) and the `static`/`thread_local` check (7344-7359).
- [cfg_provenance.odin:6702](src/cfg_provenance.odin#L6702) `prov_walk_subscripts`: lines 6727-6753 are not walking; they publish an inserted map key. Extract `prov_publish_map_key`.
- [cfg_provenance.odin:7854](src/cfg_provenance.odin#L7854) `call_proc_type`: used by the checker (check_calls.odin:656), the emitter (emit_llvm_stmt.odin:154) and parallel.odin, and has nothing to do with provenance. It belongs beside `proc_parameter_mode` in semantic.odin.
- [cfg_provenance.odin:5962](src/cfg_provenance.odin#L5962): the written-alias code (5962-6272) is self-contained and already split from its readers in provenance_read.odin and provenance_transfer_facts.odin. Moving it to its own `provenance_*` file is the natural first cut of this file. `Written_Alias_Visit` (6221) also sits between its users.

**Comments**

- [cfg_provenance.odin:7425](src/cfg_provenance.odin#L7425): keep the rule, the first example and the citation; drop the `holder.pointer` and `p^.inner` examples. (about 4 lines)
- [cfg_provenance.odin:6094](src/cfg_provenance.odin#L6094): nine lines listing spellings. Keep the citation, "a local set from a writable parameter's storage or from `&mut place` reaches it, through whichever operand supplies it", and the `path`/`type` sentence. (about 4 lines)
- [cfg_provenance.odin:5905](src/cfg_provenance.odin#L5905): repeats 5741-5743. Shorten to `// design.md "Allocator regions and region provenance": only owners are checked, as in prov_store_region.` (about 2 lines)
- [cfg_provenance.odin:5879](src/cfg_provenance.odin#L5879): cut to the two facts `checked` encodes: a write through a carrier reaches the caller or the local place, and a static place rejects only where an owner is stored. (about 2 lines)
- [cfg_provenance.odin:5985](src/cfg_provenance.odin#L5985): the last three sentences on `Written_Alias` describe `prov_add_written_alias`; keep only the meaning of the fields and of a zero target. (about 4 lines)
- [cfg_provenance.odin:7530](src/cfg_provenance.odin#L7530), [cfg_provenance.odin:6553](src/cfg_provenance.odin#L6553), [cfg_provenance.odin:6461](src/cfg_provenance.odin#L6461), [cfg_provenance.odin:7844](src/cfg_provenance.odin#L7844): delete; each restates the next line or the name.
- [cfg_provenance.odin:6933](src/cfg_provenance.odin#L6933): rewrap, and shorten the stacked comments at 8007-8010 into one. Across this part, about 40 of the 368 comment lines could go in the same way.

### src/cfg_provenance.odin (part 4 of 4)

The logic holds up and every declaration here has a caller in `src/`, with none existing only for tests; I found no bug I could demonstrate. The cost is near copies in call-result and retention code, a few never-varying parameters, and about 2,600 lines with no section header covering nine separate concerns.

**Simplification**

- [cfg_provenance.odin:9685](src/cfg_provenance.odin#L9685) `prov_container_content`: three switches on `op` (9737, 9762, 9775) pick the same key and value. Fill one `parts` list of actual, type and path step, then loop it in the publish and define branches; hoist `c` and the receiver type. (about 12 lines)
- [cfg_provenance.odin:8512](src/cfg_provenance.odin#L8512) `prov_call_argument`: name `is_receiver` for `index == 0 && has_receiver` (8715, 8718, 8738, 8760, 8762), and hoist `param_type` from `input.arguments[index]` in place of six `prov_parameter_type` map lookups (8525 to 8753). (about 4 lines)
- [cfg_provenance.odin:8625](src/cfg_provenance.odin#L8625) `prov_call_argument`, `.Inout_Place`: delete this join. `actual` at 8628 contains the same carrier slots and 8630 joins it to `borrowed`; nothing reads `borrowed` in between. (1 line)
- [cfg_provenance.odin:8385](src/cfg_provenance.odin#L8385) `prov_builtin_call`, `.Assert`: name `reports := v.bound[min(printed, len(v.bound)):]` once, for 8395 and 8403, and walk the printed prefix and the reports as two plain loops. (about 2 lines)
- [cfg_provenance.odin:8845](src/cfg_provenance.odin#L8845) `prov_call_may_use_reach`: its `container_op` parameter equals `callee.container_op` in the one arm that reads it. Read that field and drop the parameter here, from `prov_use_reached_in_record` and from `prov_use_reached_at_once`. (3 signatures)
- [cfg_provenance.odin:9641](src/cfg_provenance.odin#L9641) `prov_parameter_label`: nest the two guards around the `aprintf` and fall through to one fallback string, not two. (about 2 lines)
- [cfg_provenance.odin:9857](src/cfg_provenance.odin#L9857) `text_result_borrows`: inline `prov_carries_borrow` (9869), whose only caller this is, and drop the `type` parameter, always `prov_type(graph, v)`. (about 4 lines)
- [cfg_provenance.odin:9950](src/cfg_provenance.odin#L9950) `report_transfer_facts`: rename the parameter to `base_type` and delete the alias at 9951, which also removes the stray extra indent on the whole body. (1 line)
- [cfg_provenance.odin:10174](src/cfg_provenance.odin#L10174) `prov_call_result`: write this as the same one-line ternary as 10170 and 10232. (3 lines)
- [cfg_provenance.odin:10334](src/cfg_provenance.odin#L10334) `prov_substitute_result`: compute `shape` once per parameter, outside the depth loop (10341). Only one of `through` and `held` is ever non-empty, so a local load helper replaces the paired lines at 10343 and 10349. (about 3 lines)

**Dead code**

- `mutable_only` ([cfg_provenance.odin:9435](src/cfg_provenance.odin#L9435)): always `!retained`; the three callers (9115, 9205, 9612) set exactly one of the two. Branch on `retained`, then inline the one-line wrapper `prov_write_back_into_argument` (9204) and keep its comment at that branch.
- (branch) [cfg_provenance.odin:10540](src/cfg_provenance.odin#L10540): `used.default = true` has no effect, because `prov_note_window_allocator_use` clears `default` on both paths (10579, 10583). Delete it and the `used` local.
- (branch) [cfg_provenance.odin:9012](src/cfg_provenance.odin#L9012): `index >= len(actuals)` never holds; `moves` is nil or `len(actuals)` long (9003, [borrow.odin:2119](src/borrow.odin#L2119)).
- (branch) [cfg_provenance.odin:8821](src/cfg_provenance.odin#L8821): `type == INVALID_TYPE` is covered by the next clause; `type_is_carrier` is false for it ([borrow.odin:526](src/borrow.odin#L526)).
- (branch) [cfg_provenance.odin:10181](src/cfg_provenance.odin#L10181): `!type_is_carrier(...) &&` is redundant; `type_carries_borrow(...).any` is already true for every carrier ([borrow.odin:748](src/borrow.odin#L748)).
- (branch) [cfg_provenance.odin:9507](src/cfg_provenance.odin#L9507): the `:= false` defaults of `retained` and `retained_mutable` are never used; both callers (9453, 9465) pass both.

**Data structures and algorithms**

- [cfg_provenance.odin:10198](src/cfg_provenance.odin#L10198) `prov_call_result`: allocates a map in the graph arena for every call with a summary, and it holds at most three keys. A `[3]Root_Id` of `NO_ROOT`, indexed like `kinds` at 10380, replaces the map, its lookups and the allocation.
- [cfg_provenance.odin:9322](src/cfg_provenance.odin#L9322) `prov_type_reaches_destination`, `prov_type_reaches_mutable`: a fresh map and type walk per query, and queries run per call and parameter ([provenance_call.odin:264](src/provenance_call.odin#L264), [borrow.odin:2889](src/borrow.odin#L2889)), so they grow with the program. Memoize per type as `type_carries_borrow` does; check with `perf.ps1`.
- [cfg_provenance.odin:9553](src/cfg_provenance.odin#L9553) `prov_link_retained`: scans all of `graph.reborrows` per temporary source, per retained store, so it is quadratic in one body's size and only large bodies with many `stored` calls feel it. [cfg_provenance.odin:8318](src/cfg_provenance.odin#L8318) has the same scan; the solver's `reborrows_of` index would fit, were it reachable from `graph`.
- [cfg_provenance.odin:9124](src/cfg_provenance.odin#L9124) `WRITTEN_BACK_BORROW`: a diagnostic word doubles as a flag, compared by string at [borrow.odin:6222](src/borrow.odin#L6222) for each loan. A `written_back` bool on the loan says it directly.
- [cfg_provenance.odin:8257](src/cfg_provenance.odin#L8257) `prov_enter_parallel`: `holds` and `tasks` are never appended to after this procedure, so `task_holds` and `pool_tasks` ([cfg.odin:298](src/cfg.odin#L298), [cfg.odin:301](src/cfg.odin#L301)) can store slices.

**Near copies**

- [cfg_provenance.odin:10240](src/cfg_provenance.odin#L10240) and [cfg_provenance.odin:10267](src/cfg_provenance.odin#L10267): `prov_callback_result` and `prov_callback_returned` differ only in which `call_callback_*` they call, and both get `[]Thread_Local_Left`. Share `prov_callback_loans(graph, v, lefts, result_type)`. (about 12 lines)
- [cfg_provenance.odin:8998](src/cfg_provenance.odin#L8998), [cfg_provenance.odin:9178](src/cfg_provenance.odin#L9178), [cfg_provenance.odin:10244](src/cfg_provenance.odin#L10244), [cfg_provenance.odin:10271](src/cfg_provenance.odin#L10271): one loop noting consulted targets. Make `prov_note_summary_dependencies(graph, targets)` and test `prov_has_direct_body` inside, dropping the `direct` parameter of 10432. (about 10 lines)
- [cfg_provenance.odin:10256](src/cfg_provenance.odin#L10256), [cfg_provenance.odin:10283](src/cfg_provenance.odin#L10283), [cfg_provenance.odin:10375](src/cfg_provenance.odin#L10375), [cfg_provenance.odin:10392](src/cfg_provenance.odin#L10392): one `prov_borrow` of a whole root at a type's capability and noun. Share `prov_root_borrow(graph, root, type, span)`; [cfg_provenance.odin:10464](src/cfg_provenance.odin#L10464) differs only in `carrier_is_mutable`, so check that before merging it. (about 10 lines)
- [cfg_provenance.odin:9447](src/cfg_provenance.odin#L9447) and [cfg_provenance.odin:9459](src/cfg_provenance.odin#L9459): the same `through` choice and publish, differing only in carriers and type. Share `prov_retain_through(graph, carriers, type, sources, span, retained, retained_mutable)`. (about 8 lines)
- [cfg_provenance.odin:8368](src/cfg_provenance.odin#L8368) and [cfg_provenance.odin:8421](src/cfg_provenance.odin#L8421): the shared-constructor and box content loops differ only in payload type and `fallible`. Share `prov_boxed_content(graph, v, loans, payload, fallible)`. (about 6 lines)
- [cfg_provenance.odin:8961](src/cfg_provenance.odin#L8961) and [cfg_provenance.odin:8946](src/cfg_provenance.odin#L8946): `prov_lend_split_receiver` is `prov_snapshot` plus the reborrow loop, so call it. The same `.Def` copy event also appears at 2663, 3066, 6659 and 8300; a `prov_def_copy(graph, into, slot, span)` would cover all of them. (about 6 lines)
- [cfg_provenance.odin:8196](src/cfg_provenance.odin#L8196), [cfg_provenance.odin:8464](src/cfg_provenance.odin#L8464), [cfg_provenance.odin:8494](src/cfg_provenance.odin#L8494): `prov_store_region` then `prov_store_loans` on the same pair; share `prov_store_value(graph, target, value, sources, span)`. `.Exchange` and `.Unsafe_Take` also share their read-out (8460, 8483). (about 5 lines)
- [cfg_provenance.odin:8528](src/cfg_provenance.odin#L8528), [cfg_provenance.odin:10017](src/cfg_provenance.odin#L10017), [cfg.odin:2843](src/cfg.odin#L2843), [provenance_form.odin:112](src/provenance_form.odin#L112): the same two-cursor walk of `variadic_order`. A `call_next_variadic(call, is_spread, &next_element, &next_spread)` beside `call_packs` covers these. (about 12 lines)
- [cfg_provenance.odin:10539](src/cfg_provenance.odin#L10539), [cfg_provenance.odin:10546](src/cfg_provenance.odin#L10546), [cfg_provenance.odin:10691](src/cfg_provenance.odin#L10691), [cfg_provenance.odin:10711](src/cfg_provenance.odin#L10711): the choice between `prov_caller_region` and `prov_region_closure` on `thread_facts_pending`. Name it `prov_visible_region(graph, set)`. (about 3 lines)
- [cfg_provenance.odin:9976](src/cfg_provenance.odin#L9976) and [cfg_provenance.odin:10071](src/cfg_provenance.odin#L10071): one note text five times (also 9983, 9990, 10082). Use a constant, and hoist the three L0725 copies below the switch.

**Structure and boundaries**

- [cfg_provenance.odin:8165](src/cfg_provenance.odin#L8165): no section header between 6843 and 10501, over spawn, builtins, arguments, retention, containers, text, transfer checks, results and allocator use. Split at those seams into `provenance_*` files, or at least add headers; moving means widening file-private helpers such as `prov_one`.
- [cfg_provenance.odin:9322](src/cfg_provenance.odin#L9322): the 100 lines from here to `carrier_leaves` are pure type queries taking only `c`, called from `borrow.odin`, `provenance_call.odin` and `provenance_transfer_facts.odin`. They belong beside `type_carries_borrow` in `borrow.odin`.
- [cfg_provenance.odin:9950](src/cfg_provenance.odin#L9950): `report_transfer_facts`, `prov_transfer_argument`, `viewed_subject` and `prov_transferred_type` need no graph and only report errors. Move them beside `transfer_facts` and `view_chain_text` in `hooks.odin`; the walk then only decides when to call them.
- [cfg_provenance.odin:8512](src/cfg_provenance.odin#L8512) `prov_call_argument`: 260 lines in one switch, while its `Prov_Argument_Kind` lives in `provenance_call.odin`. Extract the longest arms, `.Inout_Receiver` (8559) and `.Borrowed` (8685), and keep the shared tail for the arms that fall out of the switch.
- [cfg_provenance.odin:10810](src/cfg_provenance.odin#L10810) `prov_root_is_parameter`: its one caller is at 1449, yet it sits at the end of the thread-summaries section. Move it next to that caller.
- [cfg_provenance.odin:10137](src/cfg_provenance.odin#L10137) `prov_has_received_region`, with `prov_argument_regions` (10681) and `prov_call_allocator_use` (10727): their only callers are in `provenance_event.odin`, which can own them.

**Comments**

- [cfg_provenance.odin:10502](src/cfg_provenance.odin#L10502): stale, since `prov_reach` and `prov_tracks_allocator_use` also record inside `parallel` blocks. Say "recorded while thread summaries collect, and inside a `parallel` block".
- [cfg_provenance.odin:10660](src/cfg_provenance.odin#L10660): stale in the same way; say "nil unless `prov_tracks_allocator_use`". [cfg_provenance.odin:10648](src/cfg_provenance.odin#L10648): says "given `e`", but the parameter is `id`.
- [cfg_provenance.odin:8560](src/cfg_provenance.odin#L8560) and [cfg_provenance.odin:9897](src/cfg_provenance.odin#L9897): bare "(design.md)" breaks the citation rule; add the exact heading.
- [cfg_provenance.odin:9289](src/cfg_provenance.odin#L9289): "Matches the body check." names nothing; name the procedure or delete it.
- [cfg_provenance.odin:9813](src/cfg_provenance.odin#L9813): the comment is split by the attribute at 9815; put both parts above it.
- [cfg_provenance.odin:9912](src/cfg_provenance.odin#L9912): shorten to `design.md "@(cross_thread)": @(escape=static) already rules out a thread_local borrow; this checks thread affinity, erasure, and the allocator region.`
- [cfg_provenance.odin:9994](src/cfg_provenance.odin#L9994): shorten to `design.md "Sharing with tasks", "Borrows crossing between tasks": the argument and result checks at a spawn; the solver checks thread_local borrows on crossing.`
- [cfg_provenance.odin:9524](src/cfg_provenance.odin#L9524): 12 lines; keep the citations, the two exclusions (parameter binding, lent carrier) and why, and drop the restated list of `landed` and `places`. Likewise [cfg_provenance.odin:8306](src/cfg_provenance.odin#L8306), [cfg_provenance.odin:8888](src/cfg_provenance.odin#L8888), [cfg_provenance.odin:8986](src/cfg_provenance.odin#L8986). (about 40 lines across the part)

### src/check.odin (part 1 of 2)

What remains here waits on a helper shared across files.

**Near copies**

- [check.odin:1888](src/check.odin#L1888), [check.odin:2230](src/check.odin#L2230), [iterate.odin:481](src/iterate.odin#L481): check a constant on demand, then read the type it names. Share `const_type_value(k, id, subject) -> Type_Id`. (about 8 lines)

### src/check.odin (part 2 of 2)

What remains here waits on helpers shared across files.

**Simplification**

- [check.odin:4323](src/check.odin#L4323) `check_switch`: open the scope and check `init` before testing `s.kind`, so `check_type_switch` ([optional.odin:448](src/optional.odin#L448)) reduces to the subject check and `check_variant_cases`, or inlines. (about 14 lines)

**Near copies**

- [check.odin:3888](src/check.odin#L3888) and [parallel.odin:652](src/parallel.odin#L652): `lowered_name`, `lowered_deref` and `lowered_temporary` match `synth_ident`, `synth_deref` and `synth_var`, with `synth_const` and `hidden_declaration` as further `Decl` copies. Use the package-visible `synth_ident` and `synth_deref`, and promote the rest. (about 25 lines)
- [check.odin:2876](src/check.odin#L2876) and [optional.odin:269](src/optional.odin#L269): `success_selector` and the `or_return` failure selector are the same builder for a variant index; the one-argument call at 4796 repeats [optional.odin:272](src/optional.odin#L272). Share `variant_selector` and `synth_call`. (about 10 lines)
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

- [const_ops.odin:664](src/const_ops.odin#L664), [check_expr.odin:2059](src/check_expr.odin#L2059), [eval.odin:854](src/eval.odin#L854), and [eval.odin:966](src/eval.odin#L966): the unary `+ - ~ !` fold with its overflow check and wrap is written three times, despite this file's promise that both sides "fold identically". Add `fold_unary(c, op, span, value, type, allocator) -> (Const_Value, bool)` here, including the checker's literal-text sign handling. (about 40 lines)
- [const_ops.odin:391](src/const_ops.odin#L391) and [bigint.odin:354](src/bigint.odin#L354): `dyadic_to_float` and `bi_to_float` both round a big integer to a float, one exactly, one via a sticky bit. `bi_to_float` becomes `dyadic_to_float(c, v, 0, bits)` plus its `is_inf` test; move the helper to `bigint.odin`, where `bi_release` is visible. (about 20 lines)
- [const_ops.odin:884](src/const_ops.odin#L884) and [reflect.odin:307](src/reflect.odin#L307): 15 sites across `src/` hand-build a `Const_Aggregate`, and `reflect.odin` already has a file-private `aggregate_const`. Promote it to the constructors at line 53, with an allocator parameter. (about 3 lines per site)

### src/container.odin

**Near copies**

- `require_nested_map_key_policies_walk` in [hash.odin](src/hash.odin) and [semantic.odin:2224](src/semantic.odin#L2224): this walk and `type_contains_invalid` enumerate the same components by kind; the latter is exhaustive on purpose and handles `.Box`. A shared `type_components` would serve both.

### src/doc.odin

The API model and its two renderers work and are well commented, but the file also holds the doc-comment
reader and the L0260 check, and copies much of `private_names.odin`. Seven bugs, each reproduced with `lokec.exe`.

**Bugs**

- `BUG-doc-1` **medium** [doc.odin:382](src/doc.odin#L382) `api_impl`: a block written through a private alias of a public type is hidden. *Confirmed: Probe: `@(private) Al :: Pub; impl Al { get }` builds and an importer's p.get() runs, but -api and -doc show only impl Pub's direct. doc.odin keys private_subject on the written name, against design.md "Private names in public declarations"; no recorded gap.*
  Scenario: `@(private) Al :: Pub; impl Al { get :: ... }`: an importer calls `p.get()`, but `api.loki` and `-doc` omit it (design.md "Private names in public declarations").
  Fix: set `private_subject` only when `subject_type_is_public` ([private_names.odin:248](src/private_names.odin#L248), made shared) is false.
- `BUG-doc-2` **medium** [doc.odin:1124](src/doc.odin#L1124) `public_struct`: the head is cut at the first `{`, which may be in a `where` clause. *Confirmed: Reproduced: the program builds and runs, but -api exits 1 with L0405, while -doc silently prints the cut head `where size_of(Cfg{`. A where clause without braces works. Grammar allows a nested literal; not recorded as a gap.*
  Scenario: `Wh :: struct($T: type) where size_of(Cfg{n = 1}) > 0 { a: T }` checks, but `-api` fails with internal error L0405, status 1.
  Fix: have the parser record the body's opening brace on `Type_Record` and cut there.
- `BUG-doc-3` **low** [doc.odin:525](src/doc.odin#L525) `api_decl`: `text_qualifiers` reads `item.text`, which excludes the attributes. *Not verified.*
  Scenario: `@(align=sub.N) A :: struct {...}` with no other use of `sub` writes no `import "sub";`, against compiler-guide.md "Interface files".
  Fix: also collect qualifiers from each entry of `item.attributes`.
- `BUG-doc-4` **low** [doc.odin:641](src/doc.odin#L641) `api_refs`: every identifier key counts as a field name, but an array key can be a constant. *Not verified.*
  Scenario: `@(private) KEY :: 1; TABLE :: [3]int{KEY = 5};` shows `TABLE` and not `KEY`, so the file names an undeclared constant.
  Fix: follow an identifier key that resolved to a symbol; skip only unresolved ones.
- `BUG-doc-5` **low** [doc.odin:1335](src/doc.odin#L1335) `walk_documented_type`: it stops at the first type wrapper, so false L0260 warnings result. *Not verified.*
  Scenario: a `///` on a field in `Grid :: [4](x: int)`, `Ptr :: ^(y: int)`, or `proc(p: (z: int))` warns; design.md "Doc comments" says "wherever the type is written".
  Fix: descend through pointer, array, slice, map, and signature syntax.
- `BUG-doc-6` **low** [doc.odin:1136](src/doc.odin#L1136) `public_struct`: visibility is stripped only as a leading, lone `@(public)` or `@(private)`. *Not verified.*
  Scenario: `@(required) @(public) w: int` and `@(public, required) v: int` keep `@(public)` in the file, though `api_decl` drops it for a declaration.
  Fix: filter `field.attributes` as lines 458-463 do (a shared helper) and copy text from `field.names[0]`, plus `using`.
- `BUG-doc-7` **low** [doc.odin:953](src/doc.odin#L953) `text_qualifiers`: a member named like an import counts as a qualifier. *Not verified.*
  Scenario: `V :: Wrapper{}.sub.n;` writes `import "sub";` though nothing qualifies a name with `sub`.
  Fix: skip an identifier whose previous token is `.Period`.

**Simplification**

- [doc.odin:88](src/doc.odin#L88) `interface_of_source`: replace the nested search, which canonicalizes every source path, with
  `c.package_by_dir[dir_key(canonical_dir(path_dir(path)))]`, falling back to the root package. (about 8 lines)
- [doc.odin:503](src/doc.odin#L503) `api_decl`: make the `^Type_Record` case of `api_refs` filter by `field_shown`; a struct then takes the
  `d.values` loop like everything else, and lines 503-514 go. (about 10 lines)
- [doc.odin:133](src/doc.odin#L133) `interface_text`: `formatted, ok := format_text(&scratch, INTERFACE_FILE, raw)` ([formatter.odin:60](src/formatter.odin#L60)) already does this. (about 3 lines)
- [doc.odin:526](src/doc.odin#L526): `Decl` and `Field` spans already start at the first `@`, so `written_start` is a no-op here and at 1308 and 1358:
  use `doc_comment(c, d.span)`, `document_block(w, v.span.lo)`, and `document_block(w, field.span.lo)`. Only the package clause needs it. (about 3 lines shorter)
- [doc.odin:1095](src/doc.odin#L1095) `written_start`: attributes are in source order, so the `min` loop only ever keeps `attributes[0]`; test that one. (about 2 lines)
- [doc.odin:541](src/doc.odin#L541) `decl_is_public`: `written_is_public(d.attributes, has_attribute(block, "private") ? nil : file.attributes, has_attribute(block, "public"))`
  states lines 544-550. (about 5 lines)
- [doc.odin:897](src/doc.odin#L897) `shown_text`: every caller trims the result; trim inside it and drop the `strings.trim_space` wrappers at 378, 396, 413, 481, 499, 1124, 1134.
- [doc.odin:914](src/doc.odin#L914): use `strings.is_space(rune(...))`, as [formatter.odin:386](src/formatter.odin#L386) does, and delete `is_space_byte`. (about 4 lines)
- [doc.odin:56](src/doc.odin#L56) `write_interfaces`: `join_path({path_dir(...), INTERFACE_FILE})` ([packages.odin:641](src/packages.odin#L641)) drops the `_` and the `core:path/filepath` import. (about 2 lines)

**Dead code**

- (branch) [doc.odin:305](src/doc.odin#L305): `len(names) > 0` here and at 313, 320, 445, 534, 1307 is always true for an item: `parse_declaration` returns nil without a name and only body statements destructure.
- (branch) [doc.odin:365](src/doc.odin#L365): `case ^Item_Block` in `api_items` is unreachable: `parse_top_level_block` is called only for a `when`'s branches ([parser.odin:809](src/parser.odin#L809), 817), and `api_when` unwraps both itself.
- (branch) [doc.odin:758](src/doc.odin#L758): `signature == nil` never holds: the parser always sets it ([parser.odin:3440](src/parser.odin#L3440)), and `api_refs` at 649 would dereference a nil one right after.
- (branch) [doc.odin:1139](src/doc.odin#L1139): `strings.trim_right(field_text, ",")` removes nothing: `field.span` ends at the type, before the comma ([parser.odin:3901](src/parser.odin#L3901)).

**Data structures and algorithms**

- [doc.odin:901](src/doc.odin#L901) `shown_text`: each call scans all of the file's comments, so a file costs declarations and fields times comments, while `comment_block` bisects the same sorted list.
  Extract that bisection, start there, and stop at `comment.lo >= hi`. Minor: the largest bundled file (`core/fs/fs.loke`, 1347 lines) is far from slow; only generated bindings would notice.

**Near copies**

- [doc.odin:578](src/doc.odin#L578) and [private_names.odin:515](src/private_names.odin#L515) and [ast.odin:1388](src/ast.odin#L1388): the same descent through index, call, unary, binary, and pointer, array, and map syntax, three times.
  A child-visiting helper in `ast.odin` leaves `api_refs` only its Ident, Selector, Composite, Proc, Proc_Group, Record, Enum, and Interface cases. (about 60 lines here)
- [doc.odin:781](src/doc.odin#L781), [771](src/doc.odin#L771), [757](src/doc.odin#L757) and [private_names.odin:488](src/private_names.odin#L488), [473](src/private_names.odin#L473), [460](src/private_names.odin#L460): `$`-name and generic binders are identical, and the signature binder differs only in binding plain parameter names.
  Share them over `^[dynamic]string`; the two rules on plain names need one decision. (about 20 lines)
- [doc.odin:1105](src/doc.odin#L1105) and [private_names.odin:417](src/private_names.odin#L417): `field_shown` and `field_is_exported` differ only in the `package main` default, a case `private_names` never reads.
  Share one predicate, which also serves the padding test repeated at 1140. (about 10 lines)
- [doc.odin:879](src/doc.odin#L879) and [private_names.odin:201](src/private_names.odin#L201): `leading_name` reads the subject's name from text, `subject_name` from syntax. At least replace `is_alnum_ascii` with `is_ident_part` in `lexer.odin`.
  Using `subject_name` throughout would also stop `impl a.X` and `impl a.Y` sharing the key prefix `a`. (about 9 lines)
- [doc.odin:945](src/doc.odin#L945) and [963](src/doc.odin#L963) and [formatter.odin:81](src/formatter.odin#L81): a scratch compiler lexes a text. A `lex_text(text) -> []Token` serves `text_qualifiers` and `token_texts`.
  `line_starts = {}` at 151, 947, 965 is the zero value and can go. (about 8 lines)
- [doc.odin:280](src/doc.odin#L280) and [doc.odin:1272](src/doc.odin#L1272): both find the clause by searching backward for the text `package`, which `package /* package */ x;` fools. Have `parse_package_clause` record the clause's start on `File`. (about 4 lines)

**Structure and boundaries**

- [doc.odin:1151](src/doc.odin#L1151): lines 1151-1369, the doc-comment reader and the L0260 check, serve [check.odin:238](src/check.odin#L238) and [queries.odin:189](src/queries.odin#L189), not `-doc` or `-api`, and the source map's row omits them. Their seam is a `doc_comments.odin`.
- [doc.odin:533](src/doc.odin#L533): `decl_is_public` is a visibility rule used mostly by `private_names.odin`; it belongs beside `written_is_public` at [check.odin:662](src/check.odin#L662).
- [doc.odin:1105](src/doc.odin#L1105): `field_shown` and `public_struct` build the model but sit after both renderers; move them next to `api_decl`, so the file reads model, then rendering.
- [doc.odin:439](src/doc.odin#L439) `api_decl`: about 90 lines; the seam is lines 476-497, the procedure's text with its block convention, as `proc_interface_text`.
- [doc.odin:19](src/doc.odin#L19): `INTERFACE_FILE`, `documented_packages` (23), and `interface_text` (104) are used only in this file, so per the source map they should be `@(private = "file")`.

**Comments**

- [doc.odin:1092](src/doc.odin#L1092): wrong: an attribute's span covers `name=value`. Write: `each one's span starts after the "@(".`
- [doc.odin:260](src/doc.odin#L260): keep the citation, drop the list of cases that section gives: "An importer cannot name such a declaration but does reach it, so it is shown, marked private, once a shown item refers to it. A reference follows what the checker resolved, and only in syntax it never resolved goes by written name."
- [doc.odin:99](src/doc.odin#L99): the layout is compiler-guide.md "Interface files"'s. Keep: "False, with a diagnostic, when the text would not parse or a copied declaration lost a token, either a compiler bug."
- [doc.odin:1182](src/doc.odin#L1182): the rules are listed in the cited section: `// design.md "Doc comments": a block doc comment's lines.`
- [doc.odin:18](src/doc.odin#L18), [34](src/doc.odin#L34), [298](src/doc.odin#L298), [843](src/doc.odin#L843), [960](src/doc.odin#L960), [975](src/doc.odin#L975): delete; each restates the name below it. At [990](src/doc.odin#L990) keep only the second sentence. (about 20 lines across the file)

### src/emit_llvm.odin

Comments and instruction helpers are in good shape, but the file holds three jobs (module orchestration, name mangling, program entry) and the naming pass has real gaps around exports that spell `loke.`. Most of the removable text is the redundant `make` list and the duplicated entry code.

**Bugs**

- `BUG-emit_llvm-1` **medium** [emit_llvm.odin:293](src/emit_llvm.odin#L293) `llvm_linkage`: it classifies by text prefix, so a plain export name that starts with `loke.` turns internal. Scenario: `@(export, link_name = "loke.host_api") f :: proc "c" ...` emits `define internal i32 @loke.host_api()`, so the host cannot link it, though design.md "@(export)" reserves only `loke_rt_`. Fix: have `llvm_external_name` quote such a name, or pass exportedness to `llvm_linkage`. *Confirmed: Reproduced: in the -build-mode=obj COFF, loke.host_api is static and plain_host_api external; IR says `define internal`. L0635 reserves only `loke_rt_` (design.md "@(export)"); no doc records this. Exported variables stay external, so only procedures are hit. Medium is fair.*
- `BUG-emit_llvm-2` **low** [emit_llvm.odin:123](src/emit_llvm.odin#L123) `emit_llvm_module`: `reserve_link_names` runs after every naming pass, and global names (line 328) never go through `claim_name`. Scenario: `@(export, link_name = "loke.p.helper")` beside `helper :: proc()`, or `"loke.g.counter"` beside global `counter`, gives clang's raw "invalid redefinition" (L0403). Fix: reserve first and claim global names. *Not verified.*
- `BUG-emit_llvm-3` **low** [emit_llvm.odin:781](src/emit_llvm.odin#L781) `emit_entry`: `@wmain` is written unconditionally and no check reserves it. Scenario: `@(export, link_name = "wmain")` in an exe or test build gives clang's "invalid redefinition of function 'wmain'" (L0403) instead of a diagnostic like L0634. Fix: reject that export in `check_exports` for those build modes. *Not verified.*
- `BUG-emit_llvm-4` **low** [emit_llvm.odin:388](src/emit_llvm.odin#L388) `name_package_symbols`: already-escaped spellings are escaped again (also 349, 427, 481), while `debug_proc_name` undoes one layer. Scenario: under `-g`, `wrap([]int{})` shows as `wrap.$5b$5dint`, not `wrap.[]int`; IR has `$245b`. Fix: `qualified_member_name` escapes its `type_name` fallback and callers drop the outer `llvm_safe`; update `tests/ll/container_views.expected`. *Not verified.*

**Simplification**

- [emit_llvm.odin:71](src/emit_llvm.odin#L71) `make_emitter`: Odin allocates a zero map or dynamic array on first insert, and `begin_function_emission` already relies on that by clearing `cleanups` and `param_values` with `e.fn = {}`. Use `Emitter{c = c, b = strings.builder_make()}`. (about 24 lines)
- [emit_llvm.odin:447](src/emit_llvm.odin#L447) `name_witnesses`: the hand-written repeat check is `claim_name`. Use `e.witness_names[witness] = claim_name(e, strings.to_string(b))`, which also stops the suffix shifting with commit order. (about 4 lines)
- [emit_llvm.odin:460](src/emit_llvm.odin#L460) `type_spelling`: `llvm_safe("")` is `""`, so after an `info == nil` return and the instance case, the rest is `return llvm_safe(info.backend_label)`. (about 4 lines)
- [emit_llvm.odin:580](src/emit_llvm.odin#L580) `emit_proc` and [emit_llvm.odin:840](src/emit_llvm.odin#L840) `emit_test_entry`: both repeat `symbol_name`'s lookup and failure; use `symbol_name(e, id)`, since a failed emission's text is discarded. Line 782 keeps its message, which `emit_llvm_test.odin:274` pins. (about 8 lines)
- [emit_llvm.odin:523](src/emit_llvm.odin#L523) `emit_package_items`: order does not matter in LLVM text, so globals can move into the second walk's `^Decl` case, and lines 545-550 fold into one `continue` condition. Check `tests/ll` expected order. (about 8 lines)
- [emit_llvm.odin:1067](src/emit_llvm.odin#L1067) `element_address`: the struct branch's GEP is `gep_field`; write `out := gep_field(e, llvm_type(e, owner), base, index)`, keeping a temp only for the array branch. (about 3 lines)
- [emit_llvm.odin:1094](src/emit_llvm.odin#L1094) `place_label`: its first three lines are `branch(e, label)`. (about 2 lines)

**Dead code**

- (branch) [emit_llvm.odin:317](src/emit_llvm.odin#L317): `pkg == nil` here, at line 520, and at line 1188 cannot hold. `package_order` yields only valid ids, and `visit_for_order` already dereferences `package_of(c, id)` unguarded.
- (branch) [emit_llvm.odin:577](src/emit_llvm.odin#L577): `literal == nil` cannot hold, because all four callers pass a literal they have checked or iterated.
- (branch) [emit_llvm.odin:244](src/emit_llvm.odin#L244): `e.result_type = INVALID_TYPE` follows `e.fn = {}`, and `INVALID_TYPE` is `Type_Id(0)` (`semantic.odin:18`).
- (branch) [emit_llvm.odin:783](src/emit_llvm.odin#L783): `entry == ""` here and `name == ""` at line 841 cannot hold; no name in `e.names` is written empty, and the `!found` test covers the rest.

**Near copies**

- [emit_llvm.odin:790](src/emit_llvm.odin#L790) and [emit_llvm.odin:868](src/emit_llvm.odin#L868): the same eight startup lines (args, thread, panic trace, providers) after `open_entry`. Make one `open_program_entry(e)`; the `noinline` choice at 802 and 835 can be one `entry_call_attributes(e)`. (about 8 lines)
- [emit_llvm.odin:807](src/emit_llvm.odin#L807) and [emit_llvm.odin:909](src/emit_llvm.odin#L909): a fallible `main` and a fallible test both frame, report, and pop. Have `emit_entry` call an `emit_test_report`-style private wrapper returning `i32`, which removes `header` and its three `if fallible`. (about 10 lines)
- [emit_llvm.odin:727](src/emit_llvm.odin#L727) and [emit_llvm_cleanup.odin:418](src/emit_llvm_cleanup.odin#L418): the same thunk, strip, and prologue sequence, differing only in where `e.pending` goes. Use `begin_generated_frame` at 656 and `end_generated_frame` at 727, dropping 633; thunks then land at module end, so check expected IR. (about 8 lines)

**Structure and boundaries**

- [emit_llvm.odin:738](src/emit_llvm.odin#L738): program entry (lines 738-972) is a separate job from orchestration. Move it to `emit_llvm_runtime.odin`, beside `emit_entry_failure_report`, or a new `emit_llvm_entry.odin`; update `compiler-architecture.md` "LLVM and toolchain", which also credits this file with globals though `emit_global` is in the runtime file.
- [emit_llvm.odin:1142](src/emit_llvm.odin#L1142): the mangling helpers (lines 1142-1192) are separated from the naming pass they serve (lines 315-502) by entry code and instruction plumbing. Group naming, mangling, and `llvm_linkage` as one section, or one `emit_llvm_names.odin`.
- [emit_llvm.odin:622](src/emit_llvm.odin#L622) `emit_proc_definition`: 115 lines with natural seams at the plain signature (638-650), parameter binding (659-686), and the result slot (688-702). Extract those three.
- [emit_llvm.odin:1138](src/emit_llvm.odin#L1138): `FAILURE_ATTRIBUTES` is not used in this file; its uses are four in `emit_llvm_runtime.odin` and one in `emit_llvm_containers.odin`. Move it to the runtime file, which owns runtime declarations.

**Comments**

- [emit_llvm.odin:231](src/emit_llvm.odin#L231): the reason is wrong, since lines 650 and 772 write `{{` in a format string. Shorten to "`define <signature> {` and the entry label."
- [emit_llvm.odin:268](src/emit_llvm.odin#L268): delete; it restates `splice_prologue`'s name and code. Line 70 also goes with the `make` list, as nothing is left uninitialized.
- [emit_llvm.odin:392](src/emit_llvm.odin#L392): shorten to "`base`, or the first free `base.<n>`. Spellings alone collide: `f(alpha.Item)` and `f(beta.Item)` read alike, and an impl member spells its owner unqualified." (about 2 lines)

### src/emit_llvm_abi.odin

Mostly correct, with one confirmed layout miscompile for unions holding wide vectors. The foreign lowering repeats its classification switches four times, `struct_body` repeats one loop four times, and about a third of the file (union values, the Loke calling convention) is not what the source-code map says it owns.

**Bugs**

- `BUG-emit_llvm_abi-1` **high** [emit_llvm_abi.odin:410](src/emit_llvm_abi.odin#L410) `union_storage_definition`: the `i%d` head does not carry alignment above 16: LLVM aligns `i256`/`i512` to 16, the largest integer in the target layout. Scenario: `@(zero=n) U :: union { n: i32, v: Simd(f32, 8) }` in `S :: struct { x: u8, u: U, tail: u8 }`, then `a: [100]S = {}; b := a;`: `-check-layout` says `align_of(U)` 32 vs 16 and `size_of` of a struct `{ x: u8, u: U }` 96 vs 80, and the 12800-byte memcpy overruns a 9600-byte alloca, so it segfaults at `-opt=none` (`Simd(f32, 4)` runs correctly). Fix: spell the head `<N x i8>` above 16 bytes, here and in the constant at [emit_llvm_expr.odin:42](src/emit_llvm_expr.odin#L42), and add such a union to `tests/layout`. *Confirmed: Reproduced: IR has %union.U = type { i256, i8, [31 x i8] }; -check-layout reports align_of(U) 32 vs 16 and size_of(T) 96 vs 80; [100]S copy segfaults (rc 139). Simd(f32, 4) and a plain-struct Simd(f32, 8) both run fine. Not recorded in the docs; high severity is fair.*
- `BUG-emit_llvm_abi-2` **low** [emit_llvm_abi.odin:37](src/emit_llvm_abi.odin#L37) `emit_foreign_declarations`: the hand-kept `seen` list covers only a few of the names `emit_runtime_declarations` declares. Scenario: `foreign rt { loke_rt_v1_frame_pop :: proc(frame: rawptr) ---; }` fails with L0403, clang's "invalid redefinition of function", instead of compiling or a diagnostic. Fix: record each runtime declaration in a set this loop consults, which also removes lines 31-44. *Not verified.*

**Simplification**

- [emit_llvm_abi.odin:143](src/emit_llvm_abi.odin#L143) `define_struct`: LLVM text allows forward references to named types (checked with clang 22: an outer struct before its by-value inner one gets the right size), and no `*_abi_type` interns during emission. Visit each `Type_Id` once and print it, dropping recursion, the `emitted` map and `struct_dependency`. (about 30 lines)
- [emit_llvm_abi.odin:203](src/emit_llvm_abi.odin#L203) `struct_body`: four copies of one loop. One loop picks `[N x i8]` when packed and over-aligned, else the field type; `<{`/`}>` only for packed-alone; the `[0 x iN]` tail only when over-aligned. (about 40 lines)
- [emit_llvm_abi.odin:192](src/emit_llvm_abi.odin#L192) `define_struct`: the brace only matters in a format string, not an argument. Use `fmt.sbprintfln(&e.b, "%s = type %s", name, struct_body(...))`, as line 165 does, and drop the comment. (3 lines)
- [emit_llvm_abi.odin:309](src/emit_llvm_abi.odin#L309) `struct_name`: `llvm_safe` already leaves a plain name unchanged, and the id makes names unique. `text := type_spelling(e, type)`, fall back to `llvm_safe(identifier_text(...))`, then one `aprintf` with `text == "" ? "anon" : text`. (about 8 lines)
- [emit_llvm_abi.odin:526](src/emit_llvm_abi.odin#L526) `emit_union_choice`: its only caller is `emit_option_value` at line 1187. Call `emit_union_either` there directly. (about 9 lines)
- [emit_llvm_abi.odin:477](src/emit_llvm_abi.odin#L477) `emit_union_widen`, and line 521 in `emit_union_either`: `e.terminated = false` repeats what `place_label` just did. Delete both. (2 lines)
- [emit_llvm_abi.odin:552](src/emit_llvm_abi.odin#L552) `emit_union_tag`: fetch `shape` once and put the "large means GEP and load, else extract" read in one local helper used by both the niche and tag paths; lines 572-573 and 587-588 can return directly. (about 8 lines)
- [emit_llvm_abi.odin:754](src/emit_llvm_abi.odin#L754) `foreign_signature`: writing `e.abi_sret` as a side effect is the only reason `emit_foreign_entry_guard` saves and restores it (lines 788-790). Return the sret name and let `emit_foreign_signature` store it. (about 3 lines)
- [emit_llvm_abi.odin:901](src/emit_llvm_abi.odin#L901) `emit_foreign_param_slot`: return early for `.Indirect`, then share the slot and alloca, branching only on the store. (about 5 lines)
- [emit_llvm_abi.odin:947](src/emit_llvm_abi.odin#L947) `emit_foreign_return`: `.Bool_I1` is `.Direct` with the same result, since `llvm_type(bool)` is `i1`; merge the cases, as line 1177 already does. (3 lines)
- [emit_llvm_abi.odin:814](src/emit_llvm_abi.odin#L814) `emit_entry_guard`: the void-or-value call and return are written twice. A nested proc taking the result name holds both. (about 5 lines)
- [emit_llvm_abi.odin:1142](src/emit_llvm_abi.odin#L1142) `emit_foreign_call`: `strings.join(args[:], ", ")` and one print replace the comma loop; `result_type` (line 1068), `fixed` and `c_vararg` (lines 1090-1091) only alias `callee_type` fields. (about 12 lines)

**Dead code**

- (branch) [emit_llvm_abi.odin:288](src/emit_llvm_abi.odin#L288): the bound of 32 in `struct_dependency` guards nothing, since array nesting cannot cycle; it also goes with the `define_struct` simplification above.

**Data structures and algorithms**

- [emit_llvm_abi.odin:348](src/emit_llvm_abi.odin#L348) `llvm_type`: called for nearly every emitted instruction (about 260 call sites), and each integer `aprintf`s a fresh string and each array re-spells its element, into an arena freed only after emission. A cache keyed by `Type_Id` would pay once per type. Unmeasured; check with `perf.ps1`.
- [emit_llvm_abi.odin:45](src/emit_llvm_abi.odin#L45) `emit_foreign_declarations`: walks every package's items again, six levels deep, though [emit_llvm.odin:360](src/emit_llvm.odin#L360) has just visited the same foreign members to name them. Appending to a `foreign_symbols` list there leaves one loop here. (about 20 lines)

**Near copies**

- [emit_llvm_abi.odin:1036](src/emit_llvm_abi.odin#L1036) and [line 876](src/emit_llvm_abi.odin#L876): `foreign_call_type` re-classifies parameters as `foreign_param_type` does, differing only in dropping `zeroext`. Take `^Type_Info` in `foreign_param_type` and trim the attribute. The `mode` lookup at line 1105 also repeats `foreign_param_is_pointer`. (about 15 lines)
- [emit_llvm_abi.odin:991](src/emit_llvm_abi.odin#L991) and [line 1121](src/emit_llvm_abi.odin#L1121): the same spill and reload through `iN`; lines 998, 1112 and 1128 are the same spill to a pointer. A `foreign_value_operand(e, type, operand)` serves the promotion's aggregate case and the fixed-argument switch. (about 12 lines)
- [emit_llvm_abi.odin:441](src/emit_llvm_abi.odin#L441), [line 467](src/emit_llvm_abi.odin#L467) and [line 505](src/emit_llvm_abi.odin#L505): write the payload at member 0, then the tag. Hoist the nested `arm` to file scope and use it in all three. (about 6 lines)
- [emit_llvm_abi.odin:208](src/emit_llvm_abi.odin#L208) and [emit_llvm_expr.odin:180](src/emit_llvm_expr.odin#L180): the type's and the constant's spelling of a record each derive packed, over-aligned and byte-member form. With the flag above, both read the same two facts.

**Structure and boundaries**

- [emit_llvm_abi.odin:433](src/emit_llvm_abi.odin#L433): union construction, widening, tag and payload reads (to line 606), plus `emit_option_value`, `emit_alloc_result` and `emit_restore_refusal` (lines 1183-1217), are not ABI and not in the source-code map's entry. Move them to an `emit_llvm_union.odin`.
- [emit_llvm_abi.odin:608](src/emit_llvm_abi.odin#L608): the Loke convention (`sret_param`, `emit_ret`, `emit_call_result`, `param_llvm`, the `synth_*` helpers, to line 726) sits between union code and the foreign signature. It belongs with `emit_llvm_calls.odin`, or the map entry should name it.
- [emit_llvm_abi.odin:1062](src/emit_llvm_abi.odin#L1062) `emit_foreign_call`: 120 lines with seams at result classification, argument lowering, the call, and result recovery; the near-copy fixes leave it about half that.

**Comments**

- [emit_llvm_abi.odin:343](src/emit_llvm_abi.odin#L343): stale history: the foreign ABI landed, and LLVM already gives `i1` one byte of storage. Delete, or "`i1` everywhere; LLVM stores it in one byte."
- [emit_llvm_abi.odin:197](src/emit_llvm_abi.odin#L197): shorten to "A `@(packed)`/`@(align=N)` record is spelled so LLVM's layout matches the checker's; GEP indices equal field indices in every form."
- [emit_llvm_abi.odin:366](src/emit_llvm_abi.odin#L366): delete; the case label already lists the kinds.
- [emit_llvm_abi.odin:660](src/emit_llvm_abi.odin#L660), [line 784](src/emit_llvm_abi.odin#L784), [line 874](src/emit_llvm_abi.odin#L874) and [line 576](src/emit_llvm_abi.odin#L576): restate the code. Delete.
- [emit_llvm_abi.odin:591](src/emit_llvm_abi.odin#L591): "that storage type" points at a definition 190 lines up. "The storage member of `union_storage_definition` that holds the tag."
- [emit_llvm_abi.odin:1183](src/emit_llvm_abi.odin#L1183): repeats lines 481-483. Keep "`Option(T)` from a runtime presence flag."
- [emit_llvm_abi.odin:956](src/emit_llvm_abi.odin#L956): keep the citation; the promotion list can go, since the switch spells it out. (about 25 lines across the file)

### src/emit_llvm_calls.odin

Only near copies shared with other emitter files remain.

**Near copies**

- [emit_llvm_calls.odin:201](src/emit_llvm_calls.odin#L201) and [emit_llvm_simd.odin:113](src/emit_llvm_simd.odin#L113): the four-line "declare once" block appears at 201, 227, 254, 324, 348, 358, 376 and simd:274. Share `declare_intrinsic(e, key, text)`, and rename `simd_intrinsics`, which now holds every intrinsic. (about 20 lines)
- [emit_llvm_calls.odin:647](src/emit_llvm_calls.odin#L647): branch on failure, call `loke_rt_v1_alloc_failed`, `unreachable`, continue. Also emit_llvm_containers.odin:798, emit_llvm_expr.odin:2273, emit_llvm_stmt.odin:174. Share `emit_alloc_policy_if(e, failed, allocator)`. (about 15 lines)

### src/emit_llvm_cleanup.odin

What remains here belongs to the groups under "Findings that span files".

**Near copies**

- [emit_llvm_cleanup.odin:406](src/emit_llvm_cleanup.odin#L406) and [emit_llvm.odin:727](src/emit_llvm.odin#L727): the same thunk, strip, prologue and write sequence, differing only in where the thunk's text goes. Send it to `pending_thunks` in both, remove `e.pending`, and call `end_generated_frame` from `emit_proc_definition`; check that `tests/ll` tolerates the new order. (about 8 lines)
- [emit_llvm_cleanup.odin:1073](src/emit_llvm_cleanup.odin#L1073) and [:1652](src/emit_llvm_cleanup.odin#L1652), plus sites in `emit_llvm_calls`, `_containers`, `_expr` and `_stmt`: eight copies of the `alloc_failed` call and `unreachable`, most also setting `terminated`. Add `emit_alloc_failed(e, allocator)`. (about 13 lines)

### src/emit_llvm_containers.odin

The lowering is careful about ownership and panics, and its comments are mostly good; one key test is too broad and breaks valid programs.
Most of the removable bulk is hand-written IR that existing helpers already cover, plus the 397-line `emit_synth_container_op`.

**Bugs**

- `BUG-emit_llvm_containers-1` **medium** [emit_llvm_containers.odin:1396](src/emit_llvm_containers.odin#L1396) `emit_map_key_slot`: any key whose type differs from `K` is treated as a `string_view`, but `^mut T` reaches `map[^T]V` with no conversion node. *Confirmed: Reproduced: with p: ^mut int, m: map[^int]int, the forms p in m, m[p] = 1, m[p] and map[^int]int{ p = 1 } all fail with L0403 (extractvalue %loke.string_view of ptr); the same code with a ^int key compiles. Not recorded in known-gaps or open-questions.*
  Scenario: `p: ^mut int; m: map[^int]int; p in m` (also `m[p] = 1`, `map[^int]int{ p = 1 }`) ends in L0403, clang rejecting `extractvalue %loke.string_view` of a `ptr`.
  Fix: test `key == TYPE_STRING && given == TYPE_STRING_VIEW`, the same pair `check_map_key` accepts.
- `BUG-emit_llvm_containers-2` **low** [emit_llvm_containers.odin:644](src/emit_llvm_containers.odin#L644) `emit_map_literal_into`: every entry hoists its own key, held-value, `old` and `inserted` allocas, so the frame grows with the literal. *Not verified.*
  Scenario: at `-opt=none`, a 300-entry `map[int]L` with a 5 KB `L` or a 30000-entry `map[string]string` dies with 0xC00000FD; same-size `[dynamic]` literals run.
  Fix: make those slots once before the loop, as `emit_dynamic_literal_into` does at line 600.

**Simplification**

- [emit_llvm_containers.odin:892](src/emit_llvm_containers.odin#L892) `emit_synth_container_op`: 11 cases end in `}` plus `return`; skip the tail when `status == ""` and write one `}` after it. (about 22 lines)
- [emit_llvm_containers.odin:978](src/emit_llvm_containers.odin#L978) `emit_synth_container_op`: `.Resize`, `.Reserve`, `.Shrink`, `.Map_Reserve`, `.Map_Shrink` repeat one call; use a local `status_call(e, "dyn_resize", ops)`.
  `.Clear` and `.Map_Clear` (lines 972, 1171) can share a case the same way. (about 15 lines)
- [emit_llvm_containers.odin:111](src/emit_llvm_containers.odin#L111) `synth_sequence_storage`: the header branch is `load(e, "ptr", gep_field(...))` and `load(e, "i64", gep_field(...))`; the slice branch is two `extract` calls. (about 10 lines)
- [emit_llvm_containers.odin:46](src/emit_llvm_containers.odin#L46) `declare_dyn_append_owned`: add the declaration to `emit_container_declarations`, like the other 27. `tests/ll` checks shapes rather than whole-IR goldens, and this stops a thunk map doubling as a flag. (about 8 lines)
- [emit_llvm_containers.odin:91](src/emit_llvm_containers.odin#L91) `container_ops_global`: `{{` escapes the brace, as `emit_llvm.odin:772` does, so one `fmt.aprintf` replaces the builder and the separate `{` write. (about 4 lines)
- [emit_llvm_containers.odin:1023](src/emit_llvm_containers.odin#L1023) `.Map_Lookup_Value`: `emit_union_either` writes the payload only on the present branch, so zeroing `out` first does nothing for the answer and is a memset for a large `V`; delete it. (about 5 lines)
- [emit_llvm_containers.odin:745](src/emit_llvm_containers.odin#L745) `.Open`: temporaries are named `%tN`, so reserving `out` early serves nothing; write `opened := temp(e)` and `out := insert(...)` as `.Open_Fixed` does. (about 3 lines)
- [emit_llvm_containers.odin:706](src/emit_llvm_containers.odin#L706) `emit_container_policy_failure`: its body is `kept := branch_on_failure(e, status); emit_alloc_failure(e, header); rejoin(e, kept)`. (about 3 lines)
- [emit_llvm_containers.odin:673](src/emit_llvm_containers.odin#L673) `emit_store_entry`: `prefix` only decorates labels and no test pins them; drop it with its three `tprintf` calls and fix the labels. (about 3 lines)
- [emit_llvm_containers.odin:894](src/emit_llvm_containers.odin#L894) `.Append`: use `extract` for the pack, and put the `moves` drop inside the `else` arm, where `masked` is already false, so `moves && !masked` becomes `moves`. (about 3 lines)
- [emit_llvm_containers.odin:1109](src/emit_llvm_containers.odin#L1109) `.Map_Try_Insert`: the allocator is computed for every element, and `moves` and unmanaged both store; `if moves || !managed { store } else { clone }`, with the allocator inside. (about 3 lines)
- [emit_llvm_containers.odin:1242](src/emit_llvm_containers.odin#L1242) `emit_drop_run`: `at := gep_at(e, llvm_type(e, element), data, index)`. (about 3 lines)
- [emit_llvm_containers.odin:302](src/emit_llvm_containers.odin#L302) `emit_synth_chunks_next`: `emit_ret` leaves `terminated` false, so `place_label` writes a `br` after the `ret` (LLVM reads it as a dead block). Set the flag in `emit_ret`, `emit_llvm_abi.odin:636`, and lines 1124, 1139 go. (about 2 lines)
- [emit_llvm_containers.odin:524](src/emit_llvm_containers.odin#L524) `key_policy_member`: return the policy and let the thunks read `.hash` or `.equal`, which removes the `want_equal` flag. (about 1 line)
- [emit_llvm_containers.odin:835](src/emit_llvm_containers.odin#L835) `emit_synth_container_op`: `emit_lifecycle(e, element)` is called at lines 835, 840, 1032, 1071 and 1114; hold it in one local at the top. (about 1 line)

**Dead code**

- (branch) [emit_llvm_containers.odin:146](src/emit_llvm_containers.odin#L146): `e.terminated = false` here and at lines 188, 224, 260, 284, 739, 855 is dead; `begin_function_emission` already reset it through `e.fn = {}`.
- (branch) [emit_llvm_containers.odin:783](src/emit_llvm_containers.odin#L783): `e.terminated = true` here and at line 1145 is dead; `finish_function_emission` restores `e.fn` straight after.
- (branch) [emit_llvm_containers.odin:64](src/emit_llvm_containers.odin#L64): the `INVALID_TYPE` tests here and at lines 439, 459 are redundant; `emit_lifecycle` answers all-false for it, and every caller passes a container.

**Data structures and algorithms**

- [emit_llvm_containers.odin:1085](src/emit_llvm_containers.odin#L1085) `.Map_Find_Or_Insert`: `begin_temporary_drop` registers even an unmanaged element, so `map[int]int.find_or_insert` pays a `frame_push` and `frame_pop` on every call, in the design's counting idiom.
  `guard_built_element` at lines 936, 1053, 1085, 1129 returns no action, and `emit_unwind_prologue` then omits the frame; `try_insert` gains the same.
- [emit_llvm_containers.odin:64](src/emit_llvm_containers.odin#L64) `container_ops_global`: an unmanaged element gets byte-identical `.move` and plain tables, as `@.loke.ops.143` shows for `[dynamic]int`; clear `relocating` unless the element is managed too.
- [emit_llvm_containers.odin:967](src/emit_llvm_containers.odin#L967) `.Remove`: `load_place` here and at lines 1039, 1164 snapshots compiler-owned slots, adding a memcpy for a large element; `load_temporary`, as `.Pop` uses at line 955, names the slot.

**Near copies**

- [emit_llvm_containers.odin:652](src/emit_llvm_containers.odin#L652) and [emit_llvm_containers.odin:1350](src/emit_llvm_containers.odin#L1350): map entry, null check, failure, store, key cleanup; only labels differ.
  The literal can call `emit_map_insert_store(e, {as_type, address, key_slot, key_cleanup}, value, guard)`. (about 8 lines)
- [emit_llvm_containers.odin:1003](src/emit_llvm_containers.odin#L1003), [emit_llvm_containers.odin:1017](src/emit_llvm_containers.odin#L1017), [emit_llvm_containers.odin:1057](src/emit_llvm_containers.odin#L1057), [emit_llvm_containers.odin:1263](src/emit_llvm_containers.odin#L1263) and [emit_llvm_containers.odin:1374](src/emit_llvm_containers.odin#L1374): the same `map_find` call; shared as `emit_map_find(e, header, ops, key_slot) -> string`. (about 10 lines)
- [emit_llvm_containers.odin:584](src/emit_llvm_containers.odin#L584) and [emit_llvm_containers.odin:629](src/emit_llvm_containers.odin#L629): store `via`, bind, reserve, check, begin the drop; only helper names differ. Shared as `begin_container_literal(e, v, address, as_type) -> (ops, cleanup)`, choosing by `type_is_map`. (about 8 lines)
- [emit_llvm_containers.odin:145](src/emit_llvm_containers.odin#L145), [emit_llvm_containers.odin:183](src/emit_llvm_containers.odin#L183), [emit_llvm_containers.odin:219](src/emit_llvm_containers.odin#L219), [emit_llvm_containers.odin:255](src/emit_llvm_containers.odin#L255), [emit_llvm_containers.odin:843](src/emit_llvm_containers.odin#L843) and [emit_llvm_runtime.odin:1476](src/emit_llvm_runtime.odin#L1476): the `define` line.
  One `open_synth_function(e, symbol, name, extra = "")` writes linkage, result, `sret` and the `%argN` list; `llvm_result_type` already answers `void`. (about 20 lines)
- [emit_llvm_containers.odin:335](src/emit_llvm_containers.odin#L335) and [emit_llvm_containers.odin:404](src/emit_llvm_containers.odin#L404): memoising, the `synth_bodies` save and the pending-thunk finish.
  `sort_by_thunk` differs only by needing a `Symbol_Id`; split out `begin_thunk`/`end_thunk` and build `container_thunk` on them. (about 6 lines)
- [emit_llvm_containers.odin:354](src/emit_llvm_containers.odin#L354), [emit_llvm_containers.odin:382](src/emit_llvm_containers.odin#L382), [emit_llvm_containers.odin:467](src/emit_llvm_containers.odin#L467) and [emit_llvm_containers.odin:514](src/emit_llvm_containers.odin#L514): `zext i1` and `ret i32`; shared as `emit_ret_flag(e, value)`. (about 6 lines)
- [emit_llvm_containers.odin:699](src/emit_llvm_containers.odin#L699), [emit_llvm_containers.odin:800](src/emit_llvm_containers.odin#L800), [emit_llvm_expr.odin:2275](src/emit_llvm_expr.odin#L2275), [emit_llvm_calls.odin:650](src/emit_llvm_calls.odin#L650), [emit_llvm_cleanup.odin:1652](src/emit_llvm_cleanup.odin#L1652) and [emit_llvm_stmt.odin:176](src/emit_llvm_stmt.odin#L176): the `alloc_failed` call, `unreachable`, `terminated`.
  Shared as `emit_alloc_failed(e, provider)`; `emit_alloc_check` at `emit_llvm_expr.odin:2268` also matches `emit_container_policy_failure` once the provider is loaded.
- [emit_llvm_containers.odin:138](src/emit_llvm_containers.odin#L138) and [emit_llvm_containers.odin:175](src/emit_llvm_containers.odin#L175): the same "element, through a header or a slice" resolution; a file-private helper returning `(element, through_header)` serves both. (about 4 lines)

**Structure and boundaries**

- [emit_llvm_containers.odin:812](src/emit_llvm_containers.odin#L812): `emit_synth_container_op` is 397 lines. The seams are `.Append`, `.Map_Lookup_Value`, `.Map_Find_Or_Insert` and `.Map_Try_Insert` as their own procedures, with the three nested helpers (lines 865, 872, 882) file-private.
- [emit_llvm_containers.odin:716](src/emit_llvm_containers.odin#L716): the provider bodies are not containers, and the source-code map's entry for this file omits them, as it does the `[]mut T` bodies at lines 209-307. Move them or name them in the map.
- [emit_llvm_containers.odin:571](src/emit_llvm_containers.odin#L571): `emit_region_reset` and `emit_allocator_operand` serve `free_all` and allocating built-ins, which the map assigns to `emit_llvm_calls.odin`; its only `emit_region_reset` caller is at `emit_llvm_calls.odin:180`.
- [emit_llvm_containers.odin:1410](src/emit_llvm_containers.odin#L1410): `emit_borrowed_key_slot` is `@(private)`, but only this file uses it; make it `@(private = "file")`.

**Comments**

- [emit_llvm_containers.odin:569](src/emit_llvm_containers.odin#L569): the bare `(design.md)` breaks the citation rule; write `design.md "Allocator regions and region provenance"`.
- [emit_llvm_containers.odin:44](src/emit_llvm_containers.odin#L44): records history; delete it along with `declare_dyn_append_owned`.
- [emit_llvm_containers.odin:91](src/emit_llvm_containers.odin#L91): delete once `{{` is used.
- [emit_llvm_containers.odin:744](src/emit_llvm_containers.odin#L744): delete; the order it describes does not matter for `%tN` names.
- [emit_llvm_containers.odin:341](src/emit_llvm_containers.odin#L341): repeats line 416 word for word; keep one, in the shared `begin_thunk`.
- [emit_llvm_containers.odin:998](src/emit_llvm_containers.odin#L998): delete; design.md "Map container operations" and the call say it.
- [emit_llvm_containers.odin:864](src/emit_llvm_containers.odin#L864): delete; `value_storage` shows the spill.

### src/emit_llvm_expr.odin

What remains is the allocation-failure branch it shares with the other emitter files.

**Near copies**

- [emit_llvm_expr.odin:2272](src/emit_llvm_expr.odin#L2272) and [emit_llvm_calls.odin:650](src/emit_llvm_calls.odin#L650), plus [emit_llvm_containers.odin:800](src/emit_llvm_containers.odin#L800), [emit_llvm_stmt.odin:176](src/emit_llvm_stmt.odin#L176), [emit_llvm_cleanup.odin:1073](src/emit_llvm_cleanup.odin#L1073): the same branch to `alloc_failed`. Share `emit_alloc_failed_if(e, failed, provider, label)`. (about 25 lines overall)

### src/emit_llvm_iteration.odin

Comments are mostly tight and the range arithmetic checks out, but protocol-loop binding has four branches that differ by accident, and one of them miscompiles. Two synthesized paths the dispatcher can never reach remain, and the `next` bodies repeat their framing.

**Bugs**

- `BUG-emit_llvm_iteration-2` **medium** [emit_llvm_iteration.odin:631](src/emit_llvm_iteration.odin#L631) `emit_protocol_foreach`: a value-mode `iter` receiver takes `emit_expr` and nothing registers the temporary, so an owned source is never dropped. Scenario: with `iter :: proc(self) -> It`, `foreach (v in make_source(7))` never runs `drop 7`, while `make_source(6).iter()` does. Fix: spill through `spill_foreach_iterable_at` and pass `load_place` of the slot. *Confirmed: Probe: with iter :: proc(self) -> It, foreach (v in make_source(7)) never prints drop 7, while make_source(6).iter() prints drop 6. design.md "Temporaries and procedure boundaries" says it lives to statement end, then drops; not in known-gaps. Medium fits.*
- `BUG-emit_llvm_iteration-4` **low** [emit_llvm_iteration.odin:373](src/emit_llvm_iteration.odin#L373) `emit_text_foreach`, also [417](src/emit_llvm_iteration.odin#L417) and [499](src/emit_llvm_iteration.odin#L499)-[500](src/emit_llvm_iteration.odin#L500): plain `load` ignores `e.place_align`, so a header in a packed field gets natural alignment, which is LLVM UB. Scenario: `@(packed) P :: struct { tag: u8, name: string }`, `foreach (c in p.name)` emits `load %loke.string, ptr %t458` at offset 1 with no `align 1`. Fix: use `load_place` or `align_suffix`. *Not verified.*

**Simplification**

- [emit_llvm_iteration.odin:664](src/emit_llvm_iteration.odin#L664) `emit_protocol_foreach`: `lent_yield_field` already covers all four branches (owned, pointer, record), so lines 662-685 become `field := lent_yield_field(e, yielded, payload, emit_union_payload(e, option, payload, slot))` plus one bind call. (about 18 lines)
- [emit_llvm_iteration.odin:153](src/emit_llvm_iteration.odin#L153) `bind_foreach_fields`, [with_index](src/emit_llvm_iteration.odin#L306), [lent_record_fields](src/emit_llvm_iteration.odin#L993): let each traversal pass one root field (a map's is `{entry, children}`); one `bind_foreach_element` adds the counter pair when `s.indexed`. This also removes `with_index`'s mistyped one-field record case. (about 25 lines)
- [emit_llvm_iteration.odin:194](src/emit_llvm_iteration.odin#L194) `bind_foreach_pattern`: the group/projected/leaf chain repeats the single-binding cases at the top, so call `bind_foreach_pattern(e, bindings[position:position+1], field.type, projected, parts[index])`. Line 169's second condition is also always true. (about 8 lines)
- [emit_llvm_iteration.odin:602](src/emit_llvm_iteration.odin#L602) `bind_indexed_value`: both GEP spellings compute the same address, so `address := gep_at(e, element, array_slot, at)` serves all three kinds and carries `place_align`. (about 11 lines)
- [emit_llvm_iteration.odin:377](src/emit_llvm_iteration.odin#L377) `emit_text_foreach` and [465](src/emit_llvm_iteration.odin#L465)/[507](src/emit_llvm_iteration.odin#L507) `emit_indexed_foreach`: `temp` then `alloca_named` has no use for the early name; write `decoded := alloca(e, "i32")` and `cursor := alloca(e, counter_type)`. (about 4 lines)
- [emit_llvm_iteration.odin:423](src/emit_llvm_iteration.odin#L423) and the sites at 382, 519, 640: the optional counter repeats alloca, zero store, load and step. A `new_counter` helper plus a `counter` field on `Loop_Labels`, stepped by `close_loop`, removes them. (about 15 lines)
- [emit_llvm_iteration.odin:182](src/emit_llvm_iteration.odin#L182), also 183, 215, 238, 239, 326, 1006, 1007: `type_of(e.c, type_underlying(e.c, x))` is `underlying_info(e.c, x)`. (no lines, shorter expressions)

**Dead code**

- (branch) [emit_llvm_iteration.odin:640](src/emit_llvm_iteration.odin#L640): `|| (foreach_is_place_loop(s) && len(s.bindings) == 2)` makes a counter only `with_index` could read, and that returns early unless `s.indexed`; test `s.indexed` alone.
- (branch) [emit_llvm_iteration.odin:874](src/emit_llvm_iteration.odin#L874) `emit_synth_indexed_next`, `slice = false`: `.Array_Next` exists only for compile-time-only elements, whose iterator is a descriptor, and [emit_llvm_runtime.odin:1387](src/emit_llvm_runtime.odin#L1387) skips those. Without it `slice` and `by_ref` are always true, and the array paths and clone (lines 924-928) go; about 25 lines.
- (branch) [emit_llvm_iteration.odin:764](src/emit_llvm_iteration.odin#L764) `emit_synth_iter`: the same skip makes the compile-time-only array `else` unreachable, and line 769's `view_type = source` restates the field's LLVM type, so `view_type` need never change. (about 5 lines)

**Near copies**

- [emit_llvm_iteration.odin:432](src/emit_llvm_iteration.odin#L432), [961](src/emit_llvm_iteration.odin#L961) and [emit_llvm_runtime.odin:945](src/emit_llvm_runtime.odin#L945): the `loke_rt_v1_map_scan` call plus cursor store are identical; share `emit_map_scan(e, table, ops, cursor, cursor_slot, key_out, value_out) -> string`. (about 8 lines)
- [emit_llvm_iteration.odin:821](src/emit_llvm_iteration.odin#L821), [886](src/emit_llvm_iteration.odin#L886), [953](src/emit_llvm_iteration.odin#L953), [1028](src/emit_llvm_iteration.odin#L1028) and [emit_llvm_containers.odin:283](src/emit_llvm_containers.odin#L283): the same stop block (lines 866-868, 935-937, 985-987, 1054-1056); share `close_synth_next(e, option, stop_label)`, and use `branch_if` for the raw `br i1`. (about 10 lines)
- [emit_llvm_iteration.odin:61](src/emit_llvm_iteration.odin#L61) and [emit_llvm_stmt.odin:679](src/emit_llvm_stmt.odin#L679): the same six-line save and restore of four loop targets; group them as one `Loop_Targets` field on `Emitter`, then `outer := e.loop; defer e.loop = outer`. (about 8 lines)
- [emit_llvm_iteration.odin:206](src/emit_llvm_iteration.odin#L206) and [iterate.odin:982](src/iterate.odin#L982); [emit_llvm_iteration.odin:188](src/emit_llvm_iteration.odin#L188) and [iterate.odin:899](src/iterate.odin#L899): the projected-record test and projected-field lookup are written twice. Both take only `^Compiler`, so they belong in `iterate.odin`, shared. (about 10 lines)

**Structure and boundaries**

- [emit_llvm_iteration.odin:696](src/emit_llvm_iteration.odin#L696) `spill_iterable_at`: its only callers are [emit_viewed_address](src/emit_llvm_expr.odin#L1133) and [emit_dyn_proc_value](src/emit_llvm_runtime.odin#L1553), neither of which iterates. Move it to `emit_llvm_expr.odin` under a name such as `spill_viewed_at`.
- [emit_llvm_iteration.odin:462](src/emit_llvm_iteration.odin#L462) `emit_indexed_foreach`, [bind_indexed_value](src/emit_llvm_iteration.odin#L567): `is_range` is tested repeatedly to weave two loops together, which forces seven string parameters. Split them into `emit_range_foreach` and `emit_sequence_foreach`, each binding inline.
- [emit_llvm_iteration.odin:993](src/emit_llvm_iteration.odin#L993) `lent_record_fields`, `lent_yield_field`: these serve only `emit_protocol_foreach` but sit among the synthesized `next` bodies; move them beside it, keeping lowering (51-730) and synthesized bodies (732 on) apart.
- [emit_llvm_iteration.odin:11](src/emit_llvm_iteration.odin#L11) `emit_option_some`: used across the backend and unrelated to iteration, and [emit_llvm_calls.odin:1824](src/emit_llvm_calls.odin#L1824) spells it out by hand. Move it beside `emit_union_value` and use it there.

**Comments**

- [emit_llvm_iteration.odin:8](src/emit_llvm_iteration.odin#L8): delete; the banner repeats the file header, and no other section has one.
- [emit_llvm_iteration.odin:28](src/emit_llvm_iteration.odin#L28): shorten to `// design.md "Ranges": evaluates x, then r, once each.`; the rest restates the spec and the code below.
- [emit_llvm_iteration.odin:90](src/emit_llvm_iteration.odin#L90): delete; the body says it.
- [emit_llvm_iteration.odin:110](src/emit_llvm_iteration.odin#L110): delete; it narrates the four lines below.
- [emit_llvm_iteration.odin:352](src/emit_llvm_iteration.odin#L352): shorten to `// Whether the cursor is live, by the run-time closed flag.`
- [emit_llvm_iteration.odin:367](src/emit_llvm_iteration.odin#L367): wrong as well as long, since `rune_offsets()` is a view that takes the protocol path. Use `// Decoded code points; indexed() adds the ordinal (design.md "String iteration").`

### src/emit_llvm_runtime.odin

Correct on the paths exercised, with two low-severity printing divergences. It holds five subsystems in one file, and its main costs are repeated IR-building shapes, a map-per-record metadata builder the checker has made unnecessary, and defensive branches the emission contract already rules out.

**Bugs**

- `BUG-emit_llvm_runtime-1` **low** [emit_llvm_runtime.odin:893](src/emit_llvm_runtime.odin#L893) `emit_format_enum`: an unnamed value always goes through `widen_to_i64` and `fmt_i64`, ignoring signedness and 128-bit backing, unlike the `.Int` case at line 718. *Not verified.*
  Scenario: an unsafe-built `enum u64` value `0xFFFFFFFFFFFFFFFF` prints `-1`, and an `enum i128` value prints its low word (`trunc i128` seen in `-emit-ll`), against standard-library.md "Printed forms"; such a value is already an invalid representation.
  Fix: extract lines 715-732 as `emit_format_integer(e, under, value)` and call it from both.
- `BUG-emit_llvm_runtime-2` **low** [emit_llvm_runtime.odin:751](src/emit_llvm_runtime.odin#L751) `emit_format_body`: `f16` prints through `fmt_f32`, a divergence recorded only in a `ponytail:` source comment, not in `known-gaps.md`. *Not verified.*
  Scenario: `fmt.println(f16(0.1))` prints `0.099975586`, where standard-library.md "Printed forms" requires the shortest decimal that reads back, `0.1`.
  Fix: add a runtime `fmt_f16` entry, or record the gap with this reproduction and cut the comment.

**Simplification**

- [emit_llvm_runtime.odin:179](src/emit_llvm_runtime.odin#L179) `slice_constant` (also lines 452, 492, 576, 588): these concatenate because of `{`, yet line 79 already escapes it. Use `fmt.aprintf("{{ ptr %s, i64 %d }}", name, count)` and `sbprintfln` with `{{`, and delete the comments at 179 and 451. (about 8 lines)
- [emit_llvm_runtime.odin:1364](src/emit_llvm_runtime.odin#L1364) `typeid_index`: the `zero` test is redundant because `select` already maps 0 to 0. Typeids are frozen before emission (`validate_emission_dependencies`), so take `len(e.c.typeid_order)` as an immediate and drop `TYPE_NAME_COUNT`, `TYPE_INFO_COUNT` and their globals (575, 1157). (about 12 lines)
- [emit_llvm_runtime.odin:584](src/emit_llvm_runtime.odin#L584) `emit_format_thunks`: the name-table entry repeats `text_constant`, including the zero case for an empty name; call `text_constant(e, Const_Value{kind = .String, text = name}, false)`. (about 7 lines)
- [emit_llvm_runtime.odin:558](src/emit_llvm_runtime.odin#L558) `emit_format_thunks`: merge the `typeid_order` loops at 558 and 567 into one that sets `names[id]` and emits the thunk when printable. (about 5 lines)
- [emit_llvm_runtime.odin:1134](src/emit_llvm_runtime.odin#L1134) `emit_type_info_tables`: drop the `entries[0]` assignment and the fill loop at 1142; write `entry == "" ? "zeroinitializer" : entry` in the print loop at 1154. (about 5 lines)
- [emit_llvm_runtime.odin:1067](src/emit_llvm_runtime.odin#L1067) `emit_fmt_builtin`: the call site passes only the three handled kinds ([emit_llvm_calls.odin:164](src/emit_llvm_calls.odin#L164)), so the trailing `return "0"` can go; move `writer_type` into its case and use `insert` as `emit_dyn_value` does. (about 5 lines)
- [emit_llvm_runtime.odin:850](src/emit_llvm_runtime.odin#L850) `emit_format_type_name`: `data, length := load_pair(e, STRING_VIEW_TYPE, view, VIEW_DATA, VIEW_LEN)` replaces three lines and the misnamed `stride`. (about 3 lines)
- [emit_llvm_runtime.odin:443](src/emit_llvm_runtime.odin#L443) `emit_formatted_panic`: `types` parallels `addresses` and is `expr_base(arg).type` of the same `v.bound[message_index + 1:]`; keep one array and read the other from `v.bound`. (about 3 lines)
- [emit_llvm_runtime.odin:412](src/emit_llvm_runtime.odin#L412) `panic_message_text`: `check_message_arg` already rejects a non-constant message ([check_builtin.odin:1299](src/check_builtin.odin#L1299)), so return `expr_base(v.bound[index]).const_value.text` once the argument is present. (about 2 lines)
- [emit_llvm_runtime.odin:728](src/emit_llvm_runtime.odin#L728) `emit_format_body`: use a `signed ? ... : ...` callee as line 723 does instead of two `sbprintfln` branches. (about 3 lines)

**Dead code**

- `RT_DEFAULT_ALLOCATOR` ([emit_llvm_runtime.odin:23](src/emit_llvm_runtime.odin#L23)): no emitted IR references this global; `-emit-ll` shows only its declaration from line 36. It exists only for the ABI check at [runtime_test.odin:97](tests/runtime_test.odin#L97), so removal must move that record check.
- `RT_ALLOCATOR_RECORD` ([emit_llvm_runtime.odin:32](src/emit_llvm_runtime.odin#L32)): used only by that declaration, and the record shape appears nowhere else in `src/`; the same test-only status.
- (branch) [emit_llvm_runtime.odin:1092](src/emit_llvm_runtime.odin#L1092): `emit_format_witness_call`'s `data`, `writer` and `options` are always `%data`, `%w` and `%o` from its one caller at line 606; fold it into `emit_one_format_thunk`.
- (branch) [emit_llvm_runtime.odin:560](src/emit_llvm_runtime.odin#L560): `id != 0 && int(id) <= count`, here and at 569 and 1137, holds for every `typeid_order` entry by `validate_typeids`.
- (branch) [emit_llvm_runtime.odin:1178](src/emit_llvm_runtime.odin#L1178): the five `shape == nil ?` tests at 1178-1182 and the check at 1227 cannot fire, since the contract requires `type_of` to be non-nil for each requested type.
- (branch) [emit_llvm_runtime.odin:1626](src/emit_llvm_runtime.odin#L1626): `target == nil` in `emit_witness_thunk` is excluded by `validate_witnesses` in `emission_contract.odin`; were it reachable, line 1611 would name a thunk never defined.
- (branch) [emit_llvm_runtime.odin:1320](src/emit_llvm_runtime.odin#L1320): both words are masked to 64 bits just above, as its own comment admits, so `bi_to_u64` cannot report failure.
- (branch) [emit_llvm_runtime.odin:1503](src/emit_llvm_runtime.odin#L1503): the default case is unreachable; `emit_synth_procs` dispatches only the three handled kinds at line 1393.
- (branch) [emit_llvm_runtime.odin:1464](src/emit_llvm_runtime.odin#L1464): `e.terminated = false` here and at 1631 repeats `begin_function_emission`'s `e.fn = {}`, since `terminated` lives in `Function_State` ([emit_llvm.odin:176](src/emit_llvm.odin#L176)).

**Data structures and algorithms**

- [emit_llvm_runtime.odin:1163](src/emit_llvm_runtime.odin#L1163) `type_info_entry`, `type_info_members`, `named_field_constant`: each record builds a `map[string]string` by field name "so the layout stays authoritative", but `runtime_layout_matches` ([check_builtin.odin:1562](src/check_builtin.odin#L1562)) already pins names, order and types. Pass a positional `[]string` with `""` as zero, and each `make`/`defer delete`/assign block in lines 1238-1289 becomes one call. (about 30 lines)

**Near copies**

- [emit_llvm_runtime.odin:124](src/emit_llvm_runtime.odin#L124) and [emit_llvm_runtime.odin:381](src/emit_llvm_runtime.odin#L381): `text_literal_global` and `message_global` emit the same global, differing only in map and name prefix. Use the former everywhere and delete `e.messages` ([emit_llvm.odin:56](src/emit_llvm.odin#L56)); no test names `@.msg.`. (about 12 lines)
- [emit_llvm_runtime.odin:450](src/emit_llvm_runtime.odin#L450) and [emit_llvm_runtime.odin:491](src/emit_llvm_runtime.odin#L491): the same stderr writer `alloca` and `store`; share `emit_stderr_writer(e) -> string`. (about 5 lines)
- [emit_llvm_runtime.odin:458](src/emit_llvm_runtime.odin#L458) and [emit_llvm_runtime.odin:618](src/emit_llvm_runtime.odin#L618), also lines 496, 508 and 632: `fmt_bytes` of a literal, three with a hand-counted length (1, 7, 1); give `emit_format_literal` a `writer` parameter. (about 6 lines)
- [emit_llvm_runtime.odin:651](src/emit_llvm_runtime.odin#L651) and [emit_llvm_runtime.odin:771](src/emit_llvm_runtime.odin#L771): the string and `cstring_view` arms differ only in `fmt_quoted` against `fmt_bytes`; share `emit_format_text(e, under, address, callee)`. (about 7 lines)
- [emit_llvm_runtime.odin:911](src/emit_llvm_runtime.odin#L911) and [emit_llvm_runtime.odin:955](src/emit_llvm_runtime.odin#L955): the same "first element, else `, `" blocks; share `emit_format_separator(e, index)`. (about 7 lines)
- [emit_llvm_runtime.odin:902](src/emit_llvm_runtime.odin#L902), [emit_llvm_calls.odin:477](src/emit_llvm_calls.odin#L477), [emit_llvm_expr.odin:1886](src/emit_llvm_expr.odin#L1886) and [emit_llvm_cleanup.odin:1532](src/emit_llvm_cleanup.odin#L1532): the same cursor loop (zero, head, compare, body, add, store, branch); `open_counted_loop`/`close_counted_loop` would serve all four, with the label prefix as a parameter. (about 10 lines per site)
- [emit_llvm_runtime.odin:239](src/emit_llvm_runtime.odin#L239) and [emit_llvm_runtime.odin:353](src/emit_llvm_runtime.odin#L353): `emit_static_locals` and `emit_global` both pick an initial value and print the same definition; share `emit_var_global(e, name, sym, decl, position)` and find the position with `slice.linear_search`. (about 8 lines)
- [emit_llvm_runtime.odin:1149](src/emit_llvm_runtime.odin#L1149), [emit_llvm_runtime.odin:1297](src/emit_llvm_runtime.odin#L1297), [emit_llvm_runtime.odin:579](src/emit_llvm_runtime.odin#L579) and [emit_llvm.odin:855](src/emit_llvm.odin#L855): a private constant array written element by element to `e.globals`; share `append_constant_array(e, name, element, entries)`. (about 15 lines)
- [emit_llvm_runtime.odin:1634](src/emit_llvm_runtime.odin#L1634), [emit_llvm_runtime.odin:1662](src/emit_llvm_runtime.odin#L1662) and [emit_llvm_runtime.odin:1686](src/emit_llvm_runtime.odin#L1686): the same forwarding header, differing in linkage and receiver type; share `open_forwarding_function(e, linkage, name, symbol, signature, receiver_type)`. (about 10 lines)
- [emit_llvm_runtime.odin:1523](src/emit_llvm_runtime.odin#L1523) and [emit_llvm_runtime.odin:1538](src/emit_llvm_runtime.odin#L1538), also lines 1562 and 1072: the two `insert`s that build a view; share `dyn_view_value(e, storage, data, second)`. (about 5 lines)

**Structure and boundaries**

- [emit_llvm_runtime.odin:541](src/emit_llvm_runtime.odin#L541): formatting (541-1111, plus `emit_formatted_panic`, `emit_entry_failure_report` and `emit_synth_format`) is a third of the file with few entry points; it belongs in its own `emit_llvm_format.odin`.
- [emit_llvm_runtime.odin:1510](src/emit_llvm_runtime.odin#L1510): the source-code map gives "erased dispatch" to `emit_llvm_calls.odin` and witnesses to this file, yet `emit_dyn_slot_call` and the views live here. Lines 1510-1737, minus `emit_materialized_constants`, form a natural `emit_llvm_erased.odin`.
- [emit_llvm_runtime.odin:1585](src/emit_llvm_runtime.odin#L1585): `emit_materialized_constants` sits among erased views; it belongs with the globals section at line 235.
- [emit_llvm_runtime.odin:139](src/emit_llvm_runtime.odin#L139): `slice_literal_constant`, `slice_literal_storage` and `text_constant` are called from `emit_llvm_expr.odin` (lines 136, 177, 369), and the source-code map gives constants to that file; they belong there, with `text_constant` still visible to the metadata code.

**Comments**

- [emit_llvm_runtime.odin:1064](src/emit_llvm_runtime.odin#L1064): wrong; there are three kinds ([semantic.odin:556](src/semantic.odin#L556)). Use "The compiler-owned `core:fmt` entry points."
- [emit_llvm_runtime.odin:1652](src/emit_llvm_runtime.odin#L1652): "trap on a nil witness" describes no code here, and a `dyn` has no nil value (design.md "Comparison operators"). Use "`dyn I` satisfies `I` through slots that take the view and call its thunk with the data pointer."
- [emit_llvm_runtime.odin:237](src/emit_llvm_runtime.odin#L237): misleading; `c.static_locals` is in checking order ([lifecycle.odin:720](src/lifecycle.odin#L720)), and teardown order is sorted at line 341. Delete "in design.md's teardown order".
- [emit_llvm_runtime.odin:1566](src/emit_llvm_runtime.odin#L1566): narrates the body; delete. The same goes for lines 1583, 1459, 530 and 442. (about 7 lines across the file)

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

### src/emit_llvm_toolchain.odin

Careful code whose comments mostly explain why, with real failure handling for the cache and the linker. The main problems are `-check-layout` deleting the program's real output, a 2-second wait for every loser of a cache-install race, and a section order that hides the flow.

**Bugs**

- `BUG-emit_llvm_toolchain-1` **medium** [emit_llvm_toolchain.odin:209](src/emit_llvm_toolchain.odin#L209) `check_layout_agreement`: the probe links to `opts.output`, the path of the real build, then removes it at line 213. Scenario: `lokec hello.loke`, then `lokec hello.loke -check-layout`: `hello.exe` is overwritten and deleted. Fix: link the probe to `replace_ext(opts.output, ".layout.exe")`. *Confirmed: Reproduced: `lokec hello.loke -check-layout` deleted the built hello.exe (and failed L0405 on the bare path); `-o ./a.exe` exits 0 and also deletes a.exe; -keep-temps leaves it overwritten (md5 differs). Not recorded. Output is rebuildable, so low-medium.*
- `BUG-emit_llvm_toolchain-2` **low** [emit_llvm_toolchain.odin:217](src/emit_llvm_toolchain.odin#L217) `check_layout_agreement`: runs `opts.output` as given, and `CreateProcessW` with a bare name searches the compiler's directory before the working directory. Scenario: `foo.exe` beside `lokec.exe`; `lokec foo.loke -check-layout` from elsewhere runs that one and reports L0405. Fix: `filepath.abs`, as [test_runner.odin:16](src/test_runner.odin#L16) does. *Not verified.*
- `BUG-emit_llvm_toolchain-3` **low** [emit_llvm_toolchain.odin:350](src/emit_llvm_toolchain.odin#L350) `rename_directory`: renaming onto an existing directory also gives `Permission_Denied` (confirmed with `os.rename`), so a loser of the race at line 334 retries for 2 s. Scenario: 8 parallel links after a runtime edit: 7 wait 2 s for nothing; a damaged set costs that on every link. Fix: stop retrying once `to` exists. *Not verified.*
- `BUG-emit_llvm_toolchain-4` **low** [emit_llvm_toolchain.odin:393](src/emit_llvm_toolchain.odin#L393) `runtime_build_manifest`: "everything that decides the objects" omits two inputs: the discarded stamp is zero for a bare `clang`, and INCLUDE's value is unrecorded (lines 790-792). Scenario: upgrade a PATH clang, or switch VS developer prompts: the old set is reused. Fix: record INCLUDE and the resolved clang's stamp or `--version`. *Not verified.*
- `BUG-emit_llvm_toolchain-5` **low** [emit_llvm_toolchain.odin:543](src/emit_llvm_toolchain.odin#L543) `link`: `-Wl,` splits its argument at commas, so a natvis path with a comma reaches the linker in pieces. Scenario: `lokec x.loke -g -o "a,b.exe"` fails at the link with L0403. Fix: `append(&command, "-Xlinker", fmt.aprintf("/NATVIS:%s", natvis_path))`. *Not verified.*
- `BUG-emit_llvm_toolchain-6` **low** [emit_llvm_toolchain.odin:655](src/emit_llvm_toolchain.odin#L655) `collect_foreign_link_inputs`: the `.lib` trim is case-sensitive, though the file treats paths as case-insensitive elsewhere. Scenario: `foreign import k "system:kernel32.LIB"` gives `-lkernel32.LIB`, which clang turns into `kernel32.LIB.lib` (checked with `clang -###`), so the link fails. Fix: compare the suffix with `strings.equal_fold`. *Not verified.*
- `BUG-emit_llvm_toolchain-7` **low** [emit_llvm_toolchain.odin:39](src/emit_llvm_toolchain.odin#L39) `emit_package`: natvis is written before the `-emit-ll` return at line 52, and its removal is registered after it. Scenario: `lokec x.loke -g -emit-ll` prints only `wrote x.ll` and leaves `x.natvis`, against compiler-guide.md's `-emit-ll` and `-keep-temps` rows. Fix: write it after that return. *Not verified.*
- `BUG-emit_llvm_toolchain-8` **low** [emit_llvm_toolchain.odin:265](src/emit_llvm_toolchain.odin#L265) `layout_probeable`: the allowlist omits `String`, `String_View`, `CString_View`, `C_Pointer`, `Typeid`, `Simd` and `Dyn`, which `llvm_type` lowers, though line 140 says "every type". Scenario: a wrong `size_of(Simd(f32, 3))` with no field after it passes. Fix: add them, or say why they are skipped. *Not verified.*

**Simplification**

- [emit_llvm_toolchain.odin:273](src/emit_llvm_toolchain.odin#L273) `replace_ext`: `filepath.ext` already stops at either separator, so the body is `return strings.concatenate({strings.trim_suffix(path, filepath.ext(path)), ext})`, the shape [main.odin:455](src/main.odin#L455) uses. The comment goes too. (about 5 lines)
- [emit_llvm_toolchain.odin:439](src/emit_llvm_toolchain.odin#L439) and [emit_llvm_toolchain.odin:557](src/emit_llvm_toolchain.odin#L557): the three copy loops become `append(&command, ..sources)`, `..runtime_inputs` and `..foreign_inputs`; line 828 already uses the spread. (about 6 lines)
- [emit_llvm_toolchain.odin:450](src/emit_llvm_toolchain.odin#L450) `runtime_compile_commands`: drop the `!bitcode` early return. Partition with `bitcode && base != CPU_CHECK_SOURCE ? &optimized : &native`, then append each non-empty group's command; plain builds become the all-native case. (about 4 lines)
- [emit_llvm_toolchain.odin:301](src/emit_llvm_toolchain.odin#L301) `prebuilt_runtime_objects`: `custom_runtime` has one caller, which holds it as a local. Test that at line 549 and drop the parameter and the guard. (about 3 lines)
- [emit_llvm_toolchain.odin:802](src/emit_llvm_toolchain.odin#L802) `msvc_include_dirs`: `ucrt` restates `sdk != ""`. Write `if sdk != "" { append(&out, join_path({sdk, "ucrt"})) }` and return `root != "" && sdk != ""`. (about 2 lines)
- [emit_llvm_toolchain.odin:679](src/emit_llvm_toolchain.odin#L679) `collect_foreign_link_inputs`: compares the message text `NASM` to choose behaviour, and line 701 spells the same flags again. Test `strings.equal_fold(filepath.ext(resolved), ".asm")` here and inline the constant into `assembler_for`. (about 3 lines)

**Dead code**

- (branch) [emit_llvm_toolchain.odin:619](src/emit_llvm_toolchain.odin#L619): `package_order` yields only ids in `1 ..< len(c.packages)` and dereferences `package_of` unchecked itself, so this `nil` test cannot fire. The same dead test is at [check.odin:460](src/check.odin#L460) and [emit_llvm_abi.odin:47](src/emit_llvm_abi.odin#L47).
- (branch) [emit_llvm_toolchain.odin:504](src/emit_llvm_toolchain.odin#L504): `link`'s `exe_path` is `opts.output` at both call sites (lines 67 and 209), beside `opts` itself. Drop it, unless the fix for bug 1 above makes the probe's path differ.

**Data structures and algorithms**

- [emit_llvm_toolchain.odin:607](src/emit_llvm_toolchain.odin#L607) `append_c_includes`: outside a developer prompt an LTO link runs `newest_containing` 7 times (4 toolset, 3 SDK, two globs each), cache hit or not. The count is constant and small beside clang, so do this only for clarity: discover once in `link` and pass `includes` down.

**Near copies**

- [emit_llvm_toolchain.odin:739](src/emit_llvm_toolchain.odin#L739) and [emit_llvm_toolchain.odin:110](src/emit_llvm_toolchain.odin#L110), [emit_llvm_toolchain.odin:607](src/emit_llvm_toolchain.odin#L607), [emit_llvm_toolchain.odin:568](src/emit_llvm_toolchain.odin#L568): `print_toolchain` respells the flags a link passes, the drift line 102 guards against. Shared form: split `-march`/`-ffp-contract` from the `-O` flag, build one `[dynamic]string`, print each as `flag=`. (about 6 lines)
- [emit_llvm_toolchain.odin:34](src/emit_llvm_toolchain.odin#L34), [emit_llvm_toolchain.odin:47](src/emit_llvm_toolchain.odin#L47) and [emit_llvm_toolchain.odin:202](src/emit_llvm_toolchain.odin#L202): the same write-or-L0401 block with only the path and text differing. Shared form: `write_artifact(c, path, text) -> bool`. (about 4 lines net)

**Structure and boundaries**

- [emit_llvm_toolchain.odin:130](src/emit_llvm_toolchain.odin#L130): the only banner, "layout agreement", appears to cover everything after it, and `link` sits far below its caller `emit_package`. Seams: `check_layout_agreement` and `layout_probeable` to an `emit_llvm_layout_probe.odin`; lines 282-498 to a runtime-cache file; banners for artifacts, foreign inputs and discovery.
- [emit_llvm_toolchain.odin:282](src/emit_llvm_toolchain.odin#L282): the runtime-object cache is about a quarter of the file, yet this file's row in compiler-architecture.md "Source-code map" does not mention it. Add it there, or give the cache its own row with the split above.
- [emit_llvm_toolchain.odin:273](src/emit_llvm_toolchain.odin#L273) `replace_ext`: a general path helper between the layout probe and the cache; it belongs with `path_dir` and `join_path` in `paths.odin`.
- [emit_llvm_toolchain.odin:545](src/emit_llvm_toolchain.odin#L545) `link`: 98 lines doing input collection, cache choice, command assembly and failure classification. Natural seam: `runtime_link_inputs(...) -> (inputs: []string, bitcode: bool)` for lines 545-553, which also isolates the fallback rule.
- [emit_llvm_toolchain.odin:360](src/emit_llvm_toolchain.odin#L360), [emit_llvm_toolchain.odin:364](src/emit_llvm_toolchain.odin#L364), [emit_llvm_toolchain.odin:18](src/emit_llvm_toolchain.odin#L18) and [emit_llvm_toolchain.odin:468](src/emit_llvm_toolchain.odin#L468): `RUNTIME_MANIFEST`, `RUNTIME_CACHE_FAILURE`, `CLANG_MISSING` and `CPU_CHECK_SOURCE` are named nowhere else in the repository; mark them `@(private = "file")`.

**Comments**

- [emit_llvm_toolchain.odin:501](src/emit_llvm_toolchain.odin#L501): delete "(decisions A5, A7)". comments.md's A5 is about speculative checks and no A7 is recorded, so the reference misleads.
- [emit_llvm_toolchain.odin:282](src/emit_llvm_toolchain.odin#L282): compiler-architecture.md "Runtime and library boundary" says most of this. Shorten to: "Cached objects; see that section. A set's directory is named by its manifest's hash and never modified, so concurrent links can share it. nil: the link compiles the sources." Keep the `ponytail`. (about 4 lines)
- [emit_llvm_toolchain.odin:376](src/emit_llvm_toolchain.odin#L376): the same section lists the key. Keep only the why: "Contents are hashed because an edit can keep both size and modification time; a reinstall changes clang's modification time." (about 2 lines)
- [emit_llvm_toolchain.odin:721](src/emit_llvm_toolchain.odin#L721): compiler-guide.md's `-print-toolchain` row covers the output. Shorten to: "One `flag=` line per word, in command order. The test harness reads this instead of repeating the discovery." (about 3 lines)
- [emit_llvm_toolchain.odin:736](src/emit_llvm_toolchain.odin#L736), [emit_llvm_toolchain.odin:412](src/emit_llvm_toolchain.odin#L412), [emit_llvm_toolchain.odin:603](src/emit_llvm_toolchain.odin#L603) and [emit_llvm_toolchain.odin:613](src/emit_llvm_toolchain.odin#L613): delete; each restates the name or the code below it. (4 lines)

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

The view and witness logic reads well, but `dyn_slot_is_compatible` lets three invalid slot shapes through, and an implicit `dyn proc` conversion breaks when its call is checked twice. Each slot call re-derives what `install_dyn_forwarding_slots` already computed, and interface walking and `check_as_call` belong to other owners.

**Bugs**

- `BUG-erased-1` **high** [erased.odin:671](src/erased.odin#L671) `dyn_slot_is_compatible`: `!split &&` skips the group type of `proc(self, other: Self)`, though line 651 says that type belongs to `other`. Scenario (run): `slot same: proc(self, other: Self) -> bool` with `v.same(v)` compiles and `other.r` prints garbage (917046360800) instead of L0463. Fix: test `parameter.type` whenever `position > 0 || split`. *Confirmed: Reproduced: `slot show: proc(self, other: Self) -> int` compiles and `v.show(v)` prints garbage (783195044624), while `proc(self: Self, other: Self)` reports L0463. design.md "Dyn compatibility" forbids this; no gap is recorded. High severity fits: silent memory misread.*
- `BUG-erased-3` **medium** [erased.odin:235](src/erased.odin#L235) `install_dyn_forwarding_slots`: `modes[0]` is unguarded (line 208 guards it) and `dyn_slot_is_compatible` accepts a slot with no parameters. Scenario (run): `slot nothing: proc() -> int;` plus `v: dyn I;` panics "Index 0 is out of range" before the queued L0442 prints. Fix: reject an empty parameter list in `dyn_slot_is_compatible`. *Confirmed: Reproduced: `slot nothing: proc() -> int;` plus `v: dyn I;` panics at erased.odin(235:27), Index 0 out of range; without the dyn local L0442 prints. Invalid input only, so the harm is a lost diagnostic: low-to-medium. Not recorded in the gap docs.*
- `BUG-erased-4` **medium** [erased.odin:662](src/erased.odin#L662) `dyn_slot_is_compatible`: the receiver check asks only whether the type mentions the subject, but design.md "Dyn compatibility" allows only `self`, `self: ^`, or `self: inout Self`. Scenario (run): `slot b: proc(self: ^^Self) -> int` with a parameter `v: dyn J` fails in clang (L0403) instead of L0463. Fix: match the receiver syntax against those forms. *Confirmed: Reproduced: slot proc(self: ^^Self) (also []Self, Option(Self)) with v: dyn J gives L0403 clang IR errors; self: int gives L0463. Unrecorded; design.md allows only three receivers. Severity low: invalid code is still rejected, and a ^^T method fails L0444.*
- `BUG-erased-5` **low** [erased.odin:511](src/erased.odin#L511) `dyn_compatible`: the in-progress mark leaves `dyn_reason` empty. Scenario (run): `A` composes `B` composes `A` reports "the composed interface `A` is not dyn-compatible: " with nothing after the colon. Fix: set `info.dyn_reason = "it composes itself"` with the mark. *Not verified.*

**Simplification**

- [erased.odin:1132](src/erased.odin#L1132) `check_dyn_slot_call`: flattens twice and resolves the signature twice via `report_missing_dyn_slot`, then line 1171 re-derives names. The forwarding member `members[index]` already holds params, `proc_type`, and `param_symbols`: read those, use `parameter_slot_named`, and test `.Inout` directly for L0643. (about 20 lines)
- [erased.odin:765](src/erased.odin#L765) `request_witness`: the callable branch duplicates the commit tail (789-793, 817-821) and flattens slots it never reads (771-772). Pick `slots` by branch, flatten only in the other branch, then build and commit once. (about 10 lines)
- [erased.odin:531](src/erased.odin#L531) `dyn_compatible`, `dyn_slot_is_compatible`: ten `fmt.aprintf(..., allocator = k.c.semantic_allocator)` calls take five lines each; a one-line `semantic_printf(c, format, args)` helper also serves some 30 other lines in `src/`. (about 30 lines here)
- [erased.odin:1003](src/erased.odin#L1003) `check_dyn_conversion` and [erased.odin:1133](src/erased.odin#L1133) `check_dyn_slot_call`: repeat `v.type = INVALID_TYPE` before each return. Set it once on entry (after the `found` test in the slot call) and assign the type only at the success exits. (about 16 lines)
- [erased.odin:112](src/erased.odin#L112) `pass_variadic_element`: both branches do the same two assignments. Write `if !(dyn_views_printing(...) && format_misdeclared(...)) && dyn_view_witness(...) == nil { return e, false }`. (about 4 lines)
- [erased.odin:352](src/erased.odin#L352) `dyn_proc_source_signature`: three identical guarded `[1:]` blocks become one file-private parapoly `after_first(s)` returning `s[1:]` or nil. (about 6 lines)
- [erased.odin:395](src/erased.odin#L395) `interface_application`: the loop is `copy(full[1:], rest)` inside the `len(full) > 0` block, since `copy` stops at the shorter slice. (about 3 lines)
- [erased.odin:906](src/erased.odin#L906) `dyn_slot_index`: named results `(index: int, entry: Interface_Slot, found: bool)` with bare `return` replace three `return 0, Interface_Slot{}, false`.
- [erased.odin:962](src/erased.odin#L962) `resolve_dyn_type`: `bound, ok := interface_arguments_for(..., make([]Generic_Arg, len(args), k.c.semantic_allocator))` replaces the separate `make` and `ok: bool`. (2 lines)

**Dead code**

- (branch) [erased.odin:753](src/erased.odin#L753): `is_call` cannot be false, because `composed_interface_of` returned non-nil only for an `Expr_Call` and a clone keeps the node kind.
- (branch) [erased.odin:179](src/erased.odin#L179): `stored != nil` cannot fail for a type `new_type` just returned; the same at 241 and 307, whose `dyn` comes from that call.
- (branch) [erased.odin:783](src/erased.odin#L783): `found` and `len(members) > 0` always hold, because a callable witness is requested only for a read-only view, whose member was installed with it (`format.odin` requests a non-callable interface).
- (branch) [erased.odin:511](src/erased.odin#L511): `info.dyn_ok = false` restates the zero value of a field computed once.

**Data structures and algorithms**

- [erased.odin:915](src/erased.odin#L915) `dyn_slot_index`: reruns `interface_slots` twice per slot call site, allocating a scope, cloned composition syntax, and bound arguments on the semantic allocator. Cost grows with dyn call sites times interface size, and line 197 computes the same list. Keep it per view type, for example `c.dyn_slots: map[Type_Id][]Interface_Slot`.
- [erased.odin:469](src/erased.odin#L469) `dyn_abi_type`: builds and retains a string key on every query for a `dyn mut` type, and [emit_llvm_abi.odin:303](src/emit_llvm_abi.odin#L303) `struct_name` asks per use during emission. Store the read-only `Type_Id` on the mutable `Type_Info` at line 169.
- [erased.odin:847](src/erased.odin#L847) `witness_key`, [erased.odin:425](src/erased.odin#L425) `dyn_key`: every lookup, including each written `dyn I` and each conversion, keeps its key on the semantic allocator. Build in `context.temp_allocator` and clone only on insert.
- [erased.odin:491](src/erased.odin#L491) `view_witness_types`: scans all witnesses for each view a transfer walk reaches, and witnesses grow with distinct (interface, concrete) pairs; [global_effects.odin:1628](src/global_effects.odin#L1628) scans the same list. An index by `interface_symbol` serves both. Low priority.

**Near copies**

- [erased.odin:747](src/erased.odin#L747) and [interface.odin:1396](src/interface.odin#L1396), [interface.odin:1356](src/interface.odin#L1356): all do `composed_interface_of`, clone, cast, `bound_arguments`. Shared form: `composed_application(k, requirement) -> (^Interface_Info, []Generic_Arg, bool)`.
- [erased.odin:725](src/erased.odin#L725) and [interface.odin:1326](src/interface.odin#L1326), [interface.odin:1388](src/interface.odin#L1388), [interface.odin:583](src/interface.odin#L583): same scope, package, and file setup for an application. Shared form: `enter_interface(k, info, args)`.
- [erased.odin:893](src/erased.odin#L893) and [interface.odin:1018](src/interface.odin#L1018): same loop over `slot_candidates` and `slot_matches`, differing only in `result_inout` and the returned value. One `matching_slot` returning the symbol replaces `find_witness_slot`.
- [erased.odin:475](src/erased.odin#L475) `dyn_same_application` and [erased.odin:492](src/erased.odin#L492) `view_witness_types`: same argument-list comparison. Shared form: `generic_args_equal(c, a, b: []Generic_Arg)`.
- [erased.odin:415](src/erased.odin#L415) and [generic.odin:1536](src/generic.odin#L1536): same type-or-length-prefixed-constant key text. Shared form: `write_generic_arg_key(c, b, arg)`.
- [erased.odin:47](src/erased.odin#L47) and [erased.odin:57](src/erased.odin#L57): `variadic_view_satisfied` and `dyn_view_witness` open identically, differing only in `report`. One helper taking `report` serves both.

**Structure and boundaries**

- [erased.odin:1075](src/erased.odin#L1075): `check_as_call` has nothing to do with erased views; it only dispatches to `check_union_as`, so it belongs in `union.odin` beside it.
- [erased.odin:402](src/erased.odin#L402), [erased.odin:620](src/erased.odin#L620), [erased.odin:722](src/erased.odin#L722): `interface_scope`, `composed_interface_of`, and `interface_slots` are general interface walking that `interface.odin` calls, and it declares `Interface_Slot`. Move them to that file, the owner of "slot lookup contexts".
- [erased.odin:23](src/erased.odin#L23): `variadic_view_element`, `dyn_view_witness`, `dyn_type`, `dyn_is_callable`, `dyn_key`, `dyn_is_mutable`, `dyn_compatible`, and `dyn_slot_index` have no users outside this file, so "Source-code map" asks for `@(private = "file")`.
- [erased.odin:550](src/erased.odin#L550) `dyn_compatible`: the composition branch (558-605) is the natural seam; extract `dyn_composition_is_compatible` returning `(reason, ok)`, matching `dyn_slot_is_compatible`.
- [erased.odin:1158](src/erased.odin#L1158) `check_dyn_slot_call`: argument binding (1158-1211) is a separate job from slot lookup; split it at that line.

**Comments**

- [erased.odin:505](src/erased.odin#L505): "five rules" is stale (the section lists six) and has no heading; write `// design.md "Dyn compatibility", computed once per declaration.`
- [erased.odin:631](src/erased.odin#L631): restates the spec with no heading; write `// design.md "Dyn compatibility": the rules on one slot.` (2 lines)
- [erased.odin:188](src/erased.odin#L188) and [erased.odin:999](src/erased.odin#L999): `design.md:` lacks the required heading; cite `design.md "Borrowed dynamic interface values"`.
- [erased.odin:54](src/erased.odin#L54): delete "An explicit conversion and a pack element differ in their operands and agree on this."
- [erased.odin:1093](src/erased.odin#L1093): shorten to: L0467 for no such slot, L0643 for a mutating slot through `dyn I` (design.md "Borrowed dynamic interface values"); a callable view's member is not a slot. (1 line)
- [erased.odin:558](src/erased.odin#L558), [erased.odin:654](src/erased.odin#L654), [erased.odin:1052](src/erased.odin#L1052): delete; each restates the check or error message beside it.

### src/eval.odin (part 1 of 2)

The semantics are careful and the comments mostly explain why, but the code is long-winded: about 100 hand-written failure guards, a 337-line container dispatcher, and whole-array copies that make containers quadratic in memory. Two wrong results were confirmed by running `lokec.exe` on small programs: a lone `..` spread in `append`, and zero-valued unions.

**Bugs**

- `BUG-eval.part1-1` **high** [eval.odin:1516](src/eval.odin#L1516) `eval_container_op`: `.Append` ignores `v.variadic_forwards`, where the checker binds a lone spread to `v.bound[v.variadic_slot]` and leaves both pack lists empty. Scenario: `a := [dynamic]int{}; a.append(..[]int{1,2}); return a.len();` folds to 0 and `static_assert(X == 0)` passes; at run time it is 2. Fix: append copies of the forwarded slice's elements; `a.append(9, ..b)` (L0341 at 1517) can use `variadic_order`. *Confirmed: Reproduced: X :: f() with a.append(..[]int{1,2}) passes static_assert(X == 0) and prints 0 vs runtime 2. A lone spread sets only variadic_forwards (check_calls.odin:1196), so the L0341 guard misses it; a mixed spread gets L0341. Not recorded in the docs.*
- `BUG-eval.part1-3` **low** [eval.odin:1168](src/eval.odin#L1168) `eval_compare`: `equal = ok && same` (and 1181) turns a pair that cannot be compared into "different", while the same pair at top level reports L0341 (929). Scenario: a part with no compile-time comparison held in a record folds to false, so a `static_assert` fails with no hint of why; `T{} == T{o = .none}` no longer shows it, since a zero union now compares. Fix: return `false, false` when `!ok`. *Not verified.*

**Simplification**

- [eval.odin:662](src/eval.odin#L662) throughout: `x, ok := f(); if !ok { return Eval_Value{}, false }` is 101 three-line guards in part 1. With named results it is `x := f() or_return`, already used at 603-606 and 616; `eval_container_op` (1453) has named results yet writes every guard out. (about 300 lines in part 1)
- [eval.odin:1453](src/eval.odin#L1453) `eval_container_op`: returns `[]Eval_Value`, but no arm yields more than one value and the only caller reads `results[0]` (2351-2354). Return `(Eval_Value, bool)` and delete `eval_one` (2252), `results` (1478), `none` (1476) and a one-element allocation per operation. (about 25 lines)
- [eval.odin:1695](src/eval.odin#L1695) `eval_container_op`: `.Map_Lookup_Value`, `.Map_Find` and `.Map_Remove` open with the same key, `map_find`, and `.none` steps; `.Map_Find_Or_Insert` and `.Map_Try_Insert` share key, value, and slot. Use one arm each with an inner branch. (about 30 lines)
- [eval.odin:1485](src/eval.odin#L1485) `argument`: promote "evaluate, then copy" to a file-level `eval_copied(ev, e)` and use it at 1264-1272, 1274-1281, 1525-1532 and 2270-2277. (about 15 lines)
- [eval.odin:1250](src/eval.odin#L1250) `eval_container_literal`: `written` always ends equal to `count`, so `elements[:written]` is `elements`. Index by entry and use `eval_copied`; the procedure halves. (about 20 lines)
- [eval.odin:1304](src/eval.odin#L1304) `map_deduplicate`: the inner loop is `map_find` over a value holding `kept[:]`. (about 10 lines)
- [eval.odin:261](src/eval.odin#L261) `eval_elements`: the memory message is written out at 194, 247 and 265, and `eval_fail` already swaps it in when `storage.exhausted` is set. Here set `ev.storage.exhausted = true` and `return nil, eval_memory_ok(ev)`. (about 6 lines)
- [eval.odin:1536](src/eval.odin#L1536) `eval_container_op`: `if !fallible {...}; return eval_one(ev, eval_alloc_ok(...))` repeats at 1617, 1679 and 1688; a nested `finished()` covers them. (about 4 lines)
- [eval.odin:591](src/eval.odin#L591) `eval_expr`: this hot path computes `expr_base(e)` three times (591, 599, 615); compute it once. Also 892: `const_of(result).boolean` is `result.boolean`; 400-401: `return zero_const(...)`; 1669: check hooks once before the loop, not per element. (about 5 lines)

**Dead code**

- `result_slot` ([eval.odin:55](src/eval.odin#L55)): its value is never read; 2161, 2192, 2211, 3143 and 3144 use only nil-ness and `.type`. Replace it with a `Type_Id` and drop the slot allocated per call at 2607, which is never released.
- (branch) [eval.odin:942](src/eval.odin#L942): `fold_arithmetic` answers `.Aggregate` only for a SIMD type, and a SIMD `v.type` already left at 925.
- (branch) [eval.odin:924](src/eval.odin#L924): `|| type_is_simd(ev.k.c, left.type)` adds nothing, since design.md "SIMD vectors" makes every vector operator's result a vector, comparisons included.
- (branch) [eval.odin:290](src/eval.odin#L290): the `.Union` arm of `element_type_at`; both callers test for a union first, and the fall-through returns the same value.

**Data structures and algorithms**

- [eval.odin:1521](src/eval.odin#L1521) `.Append`, also `.Insert` (1611) and `map_entry_place` (1386): each insertion copies all elements to a new block and the old block stays charged, so memory grows with n². Measured: 800 appends pass and 1100 hit the 64 MiB limit; 500 map inserts pass and 800 fail. Fit: amortized capacity on the value, so appending in place also keeps slice views valid.
- [eval.odin:649](src/eval.odin#L649) `eval_value_unviewed`: every read of a folded constant rebuilds it whole, so `T[i]` in a loop costs table size times reads, all still charged. Measured: an 800-element table read 800 times hits the limit; 500 passes. Fit: in the `Expr_Index` and `Expr_Selector` arms, convert only the selected element of a constant operand.
- [eval.odin:1331](src/eval.odin#L1331) `map_find`: the comment credits the step limit, but the memory cost above stops a map first. A linear scan is acceptable once growth is fixed, about 1400 keys under one million steps; say so rather than add a hash index now.
- [eval.odin:1696](src/eval.odin#L1696) `eval_container_op`: `argument` deep-copies the key for lookups that only compare it (1696, 1714, 1769), and `map_entry_place` copies it again (1382) after 1734 and 1753. An aggregate key is charged each time and never released; use plain `eval_expr` on reads and copy once on insert.

**Near copies**

- [eval.odin:966](src/eval.odin#L966) and [eval.odin:854](src/eval.odin#L854): `eval_simd_unary`'s lane body is `eval_unary_value` at the element type, plus `~` on bool lanes. The checker already rejects `!` on lanes (L0686). Add the bool case and call it per lane. (about 25 lines)
- [eval.odin:853](src/eval.odin#L853) and [check_expr.odin:2064](src/check_expr.odin#L2064): the same unary fold and overflow rule. Move it to `const_ops.odin` as `fold_unary`, a sibling of `fold_arithmetic`; the checker keeps only its decimal-spelling fix-up afterwards. (about 20 lines)
- [eval.odin:601](src/eval.odin#L601), [eval.odin:1925](src/eval.odin#L1925), [eval.odin:701](src/eval.odin#L701) and [eval.odin:2304](src/eval.odin#L2304): all reach a box's payload; the last two report nothing for an empty box, so a moved box gets the generic fallback rather than "this box holds no value". Share `eval_box_payload(ev, operand, span) -> ^Eval_Value`. (about 15 lines)
- [eval.odin:1521](src/eval.odin#L1521), [eval.odin:1611](src/eval.odin#L1611), [eval.odin:1638](src/eval.odin#L1638), [eval.odin:1781](src/eval.odin#L1781) and [eval.odin:1386](src/eval.odin#L1386): make, append prefix, append suffix. Share `eval_splice(ev, self, at, removed, inserted: ..Eval_Value)`, which is also the one place to add growth. (about 15 lines)
- [eval.odin:929](src/eval.odin#L929), [eval.odin:1019](src/eval.odin#L1019), [eval.odin:1080](src/eval.odin#L1080) and [eval.odin:2676](src/eval.odin#L2676): the same compare and L0341 report. Wrap them as `eval_compare_at(ev, op, a, b, span)`. (about 12 lines)
- [eval.odin:686](src/eval.odin#L686) and [eval.odin:1911](src/eval.odin#L1911): the same index evaluation and bounds report. Return `^Eval_Value` from a helper, as `eval_field` does. (about 10 lines)
- [eval.odin:1793](src/eval.odin#L1793) and [eval.odin:1894](src/eval.odin#L1894): key, `map_find`, and "this key is not in the map". Keep one helper returning the place; the read dereferences it. (about 10 lines)
- [eval.odin:315](src/eval.odin#L315) and [eval.odin:560](src/eval.odin#L560): `is_union ? union_variant_payload(...) : element_type_at(...)`. Give `element_type_at` a `variant` parameter and let its union arm answer. (about 4 lines)

**Structure and boundaries**

- [eval.odin:1453](src/eval.odin#L1453) `eval_container_op`: 337 lines holding two families. Split out `eval_map_op` at the `.Map_*` arms. Lines 1239-1807 (containers, sort, maps) could also be their own file, at the cost of unprivatizing a few helpers.
- [eval.odin:143](src/eval.odin#L143), [eval.odin:187](src/eval.odin#L187), [eval.odin:378](src/eval.odin#L378), [eval.odin:588](src/eval.odin#L588), [eval.odin:1453](src/eval.odin#L1453) and [eval.odin:1842](src/eval.odin#L1842): `ensure_proc_typed_for_eval`, `eval_fail`, `freeze`, `eval_expr`, `eval_container_op` and `eval_place` have no callers outside this file; compiler-architecture.md "Source-code map" says such helpers are file-private.
- [eval.odin:652](src/eval.odin#L652) `eval_value_unviewed`: most arms delegate, but `Expr_Selector`, `Expr_Index`, `Expr_Postfix`, `Expr_Range` and `Expr_Move` are inline, making a 140-line switch. Extracting them (`eval_index`, `eval_postfix` and so on) leaves the switch as a plain dispatch.
- [eval.odin:1811](src/eval.odin#L1811) `eval_map_membership`: also implements `x in r` for ranges. Name the proc `eval_in` and move the range test (1822-1832) into `eval_range_contains`.

**Comments**

- [eval.odin:274](src/eval.odin#L274): delete; it restates `element_type_at`. Likewise [eval.odin:2038](src/eval.odin#L2038) for `eval_field`.
- [eval.odin:519](src/eval.odin#L519): shorten to `design.md "Compile-time procedure evaluation": such a record is rejected where it is made. A zero holds one only in a record or fixed array.` (about 3 lines)
- [eval.odin:745](src/eval.odin#L745): move this to `eval_composite` with its citation; it does not explain a one-line delegation.
- [eval.odin:1405](src/eval.odin#L1405): shorten to `A stable merge sort; each comparison costs a step.` The rest records what it replaced.
- [eval.odin:1809](src/eval.odin#L1809): delete; it restates line 894 and is incomplete, since ranges come here too.

### src/eval.odin (part 2 of 2)

Readable and tightly commented, with three valid programs rejected at compile time (all reproduced against `lokec.exe`). Most of the shortening is in repeated operand and failure boilerplate, two pairs of near-identical binders and assignment phases, and frame guards that cannot fire.

**Bugs**

- `BUG-eval.part2-1` **medium** [eval.odin:3750](src/eval.odin#L3750) `bind_foreach_element`: a single name over a lent `indexed()` record gets the element by value, but its `value` field is a pointer (design.md "Element bindings"). Scenario: `foreach (r in arr.indexed()) { t += r.value^; }` in `K :: f()` reports L0343 nil dereference; a run works. Fix: when `s.borrows`, store a pointer to `element` in `pair[ELEMENT_FIRST]`. *Confirmed: Reproduced: K :: f() with foreach (r in arr.indexed()) { t += r.value^; } gives L0343 nil dereference, while f() at run time prints 6. design.md "Element bindings" specifies r.value^; no recorded gap. It fails loudly, so medium at most.*
- `BUG-eval.part2-2` **medium** [eval.odin:3295](src/eval.odin#L3295) `eval_local_decl`: a body-local type declaration evaluates its type expression, whose base type is invalid, so it fails with no diagnostic. Scenario: `P :: struct { x: int }`, an enum, or `P :: distinct int` in an evaluated body gives only L0311 "must be a compile-time constant"; a run works. Fix: skip a symbol of kind `.Type`. *Confirmed: Reproduced: an evaluated body with a local struct, enum or distinct gives only L0311, even when unused; the same run-time call and a file-scope type work. eval_value_unviewed returns false silently on the INVALID_TYPE node. design.md allows body-local types; no gap recorded.*
- `BUG-eval.part2-3` **medium** [eval.odin:3599](src/eval.odin#L3599) `eval_foreach`: a `&mut` loop always calls `eval_place`, which has no case for a slice expression. Scenario: `foreach (&mut x, i in (&mut arr[:]).indexed())`, the form L0457's own note recommends, reports L0341 "not compile-time storage"; a run works. Fix: use `eval_expr` for `.Slice`, whose view shares its elements. *Confirmed: Reproduced: N :: total() with foreach (&mut x, i in (&mut arr[:]).indexed()) gives L0341 'not compile-time storage'; the body runs at run time (9) and a named slice evaluates. No spec restriction. Severity is low: a spurious error with a one-line workaround.*
- `BUG-eval.part2-4` **low** [eval.odin:3104](src/eval.odin#L3104) `eval_message`: `freeze` reports through `eval_fail`, setting `ev.failed` before the assertion's own `eval_fail` runs, so the `<value>` fallback never appears. Scenario: `assert(false, "bad thing", p)` with pointer `p` reports L0341 "a pointer cannot escape" instead of L0343. Fix: test for a pointer, box, or non-empty container before freezing. *Not verified.*
- `BUG-eval.part2-5` **low** [eval.odin:3307](src/eval.odin#L3307) `eval_local_decl`: `_: int;` has `symbol_id == INVALID_SYMBOL`, so `zero_value(ev, INVALID_TYPE)` fails silently. Scenario: that declaration in an evaluated body gives only the generic L0311; a run accepts it. Fix: `continue` on `INVALID_SYMBOL` when there is no initializer. *Not verified.*
- `BUG-eval.part2-6` **low** [eval.odin:2447](src/eval.odin#L2447) `eval_standard_customization`: the `hash` seed is evaluated even after the receiver's `or_return` left. Scenario: `(g() or_return).hash(bump())` where `g` returns `.none` runs `bump`, whose `panic` becomes L0343 though a run never calls it. Fix: stop at the first failure. ([eval.odin:3055](src/eval.odin#L3055) has the same shape, but `simd.select` forwards locals.) *Not verified.*

**Simplification**

- [eval.odin:2137](src/eval.odin#L2137) `eval_or_else`: `frame.returning` is `frame.exiting == .Return`. Drop the field; `or_else` sets `frame.exiting = flow`, `or_return` sets `.Return`, and `eval_stmt` keeps one branch ([eval.odin:3168](src/eval.odin#L3168)). (about 10 lines)
- [eval.odin:2252](src/eval.odin#L2252) `eval_one`: `eval_container_op` returns a slice of 0 or 1 values and its only caller ([eval.odin:2347](src/eval.odin#L2347)) reads `results[0]`. Return `(Eval_Value, bool)` with the void value instead; `eval_one` goes and its call sites shrink. (about 20 lines)
- [eval.odin:2342](src/eval.odin#L2342) `eval_call`: two `symbol_of(chosen_overload)` tests become one `#partial switch chosen.synth`; likewise the two `symbol_of(target)` at 2363 and 2371. (about 4 lines)
- [eval.odin:2478](src/eval.odin#L2478) `eval_call_target`: repeats `eval_invoke`'s `ensure_proc_typed_for_eval` check and diagnostic ([eval.odin:2502](src/eval.odin#L2502)), and clone and variant constructors have no body to check. Drop it, and the one at [eval.odin:4115](src/eval.odin#L4115). (about 13 lines)
- [eval.odin:2540](src/eval.odin#L2540) `eval_invoke`: `defer pop(&ev.frames)` right after the first append replaces the pops at 2588, 2599, 2604, 2609, and 2617. Defers run last-in-first-out, so the memory check at 2498 still sees the popped stack. (about 8 lines)
- [eval.odin:2299](src/eval.odin#L2299) `eval_call`: use `eval_option` in `Call_Enum_From_Int` and `Call_Union_As` rather than naming `"none"` and `"some"`. (about 4 lines)
- [eval.odin:2878](src/eval.odin#L2878) `eval_builtin`: the `^Expr_Move` branches of `Unsafe_Forget` and `Unsafe_Write` (2852) redo what `eval_expr` does for `^Expr_Move` ([eval.odin:772](src/eval.odin#L772)). Forget becomes one `eval_expr`; Write becomes `eval_expr` plus the borrowed-place copy. (about 20 lines)
- [eval.odin:2928](src/eval.odin#L2928) `eval_builtin`: seven math arms open with the same evaluate-and-check of 1 to 3 operands. A helper `eval_operands(ev, v.bound, out[:]) -> bool` that stops at the first failure replaces them. (about 25 lines)
- [eval.odin:3393](src/eval.odin#L3393) `eval_assign`: the destination and write phases appear twice (3393-3416, 3434-3454). `eval_place` already gives `_` a throwaway slot, so `is_discard` and `slot != nil` are unnecessary and one `eval_write_targets(ev, s.lhs, values)` serves both. (about 20 lines)
- [eval.odin:3767](src/eval.odin#L3767) `bind_eval_value_pattern`: the value is always a fresh copy, so binding its parts in place is equivalent. Put it in one `eval_slot` and call the place version, which gains a `span` in place of `no_span()` at 3802 and recurses on `bindings[slot:][:1]`. (about 30 lines)
- [eval.odin:3876](src/eval.odin#L3876) `eval_variant_switch`: the inner search and double break become `if slice.contains(entry.variant_indices, subject.variant) { chosen = index; break }`. (about 5 lines)
- [eval.odin:2450](src/eval.odin#L2450) `eval_standard_customization`: the seed is a `uint` scalar, so freezing it adds nothing; use `seed.integer`. (about 3 lines)
- [eval.odin:4028](src/eval.odin#L4028) `eval_case_fields`: `payload` and `record` are recomputed per field; compute both once before the loop. (about 2 lines)

**Dead code**

- (branch) [eval.odin:2510](src/eval.odin#L2510) `eval_invoke`: `symbol == nil` cannot hold, since `ensure_proc_typed_for_eval` returned false for a nil symbol at 2502.
- (branch) [eval.odin:2457](src/eval.odin#L2457) `eval_standard_customization`: `case:` is unreachable; the only caller ([eval.odin:2343](src/eval.odin#L2343)) admits exactly the three named synths.
- (branch) [eval.odin:2285](src/eval.odin#L2285) `eval_union_payload`: `binding_type == value.type` never holds. A grouped or default case binds nothing (design.md "Inspecting a union"; `.a(x), .b(x)` is L0426) and no variant holds its own union by value, so the parameter can go.
- (branch) [eval.odin:3449](src/eval.odin#L3449) `eval_assign`: `index < len(values)` is always true; a count mismatch is a checker error ([check.odin:3587](src/check.odin#L3587)) and `eval_invoke` refuses a failed body.
- (branch) [eval.odin:3841](src/eval.odin#L3841) `eval_switch`: `.Pattern` is set only for a union (a `dyn` subject is an error) or by union argument expansion, so the test is just `s.kind == .Pattern`.
- (branch) [eval.odin:3123](src/eval.odin#L3123) statement evaluation: a nil frame is impossible except for an `or_else` exit, since `eval_block` starts from `eval_invoke`. Guard once before 2131; the checks at 3123, 3131, 3233, 3270, 3739, 3898, 4020, and 4078 go. (about 25 lines)

**Data structures and algorithms**

- [eval.odin:2607](src/eval.odin#L2607) `eval_invoke`: every call with a result allocates a slot, yet `frame.result_slot` is only read for `.type` or a nil test (2161, 2192, 2211, 3143). Store `result_type: Type_Id` in the frame: one allocation less per call. (about 8 lines)

**Near copies**

- [eval.odin:2145](src/eval.odin#L2145) and [eval.odin:2166](src/eval.odin#L2166): `or_else` and `or_return` yield success identically (`Unit` when the success is void, else the payload). Share `eval_success_payload(ev, value, shape)`.
- [eval.odin:2265](src/eval.odin#L2265) and [eval.odin:2371](src/eval.odin#L2371): a union construction and an indirect variant constructor both evaluate `bound[0]` and call `eval_union`; only the copy differs, and every sink copies again. Share one helper taking type and index.
- [eval.odin:2529](src/eval.odin#L2529) and [eval.odin:3953](src/eval.odin#L3953): `eval_invoke` and `eval_dispatch` build a frame the same way. Share `eval_push_frame(ev, symbol, site)`.
- [eval.odin:2440](src/eval.odin#L2440) and [eval.odin:3818](src/eval.odin#L3818): the first should call `eval_count_value`. [eval.odin:2455](src/eval.odin#L2455) and [eval.odin:4118](src/eval.odin#L4118) build the same `uint` value, and [eval.odin:2452](src/eval.odin#L2452) and [eval.odin:4123](src/eval.odin#L4123) the same wrap to `u64`.
- [eval.odin:2303](src/eval.odin#L2303) and [eval.odin:701](src/eval.odin#L701): `Call_Box_Unbox` and a boxed `^` read the single element identically; share a small `eval_unbox`.

**Structure and boundaries**

- [eval.odin:2774](src/eval.odin#L2774) `eval_builtin`: 310 lines with natural seams: `eval_math_builtin` (2893-3006), `eval_unsafe_builtin` (2837-2891, 3008-3041), and the SIMD arms (3045-3073), leaving a short dispatcher.
- [eval.odin:2494](src/eval.odin#L2494) `eval_invoke`: 134 lines; argument binding (2544-2594) is its own step, `eval_bind_arguments`, and holds all the frame-stack juggling.
- [eval.odin:2220](src/eval.odin#L2220): `eval_alloc_ok`, `eval_map_slot`, and `eval_one` serve only `eval_container_op` ([eval.odin:1453](src/eval.odin#L1453)), and `eval_hash` ([eval.odin:4112](src/eval.odin#L4112)) follows the statements though only `eval_standard_customization` calls it from outside. Move each next to its user.
- [eval.odin:3114](src/eval.odin#L3114): the statement interpreter (3114-4106) is a self-contained 1000 lines that could be `eval_stmt.odin`. `eval_block` and `eval_stmt` lack the file-private attribute though nothing outside uses them, and `bind_local` shares its name with the emitter's; prefer `eval_bind_local`.

**Comments**

- [eval.odin:3085](src/eval.odin#L3085): two stacked comments split by the attribute; merge above it as "The constant message of `assert`/`panic` and its arguments; a non-scalar prints as `<value>`."
- [eval.odin:2281](src/eval.odin#L2281): shorten to "The payload of `value`, if it has one"; the whole-union clause describes the dead branch.
- [eval.odin:2361](src/eval.odin#L2361): history; "A generated `clone` is the evaluator's own deep copy."
- [eval.odin:2491](src/eval.odin#L2491): keep only "Hands back the one declared result, or an invalid value when the procedure has none."
- [eval.odin:2596](src/eval.odin#L2596): misleading, since `or_return` publishes into `frame.result`, not this slot; "Zero until a `return` or `or_return` sets it."
- [eval.odin:2940](src/eval.odin#L2940): delete; it repeats 2925.
- [eval.odin:3524](src/eval.odin#L3524): `design.md:` names no heading; write `design.md "Evaluation order"`.
- [eval.odin:3720](src/eval.odin#L3720): narrates; delete "One step: bind the element, run the body." and keep the `continue` clause.
- [eval.odin:3971](src/eval.odin#L3971): says "switch subject" though `eval_foreach` calls it too; write "Whether `subject` is a place rooted in this frame's storage, which a binding then names rather than copies."

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

- [expand.odin:193](src/expand.odin#L193): stale, reflect.odin defines three descriptor types. "Every descriptor puts its name first."
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

- [foreign.odin:24](src/foreign.odin#L24), [foreign.odin:64](src/foreign.odin#L64), [foreign.odin:104](src/foreign.odin#L104), [attributes.odin:258](src/attributes.odin#L258), [doc.odin:312](src/doc.odin#L312), [doc.odin:351](src/doc.odin#L351), [private_names.odin:48](src/private_names.odin#L48), [emit_llvm.odin:353](src/emit_llvm.odin#L353), [emit_llvm_abi.odin:56](src/emit_llvm_abi.odin#L56): all filter `member.(^Decl)`. Only `^Decl` or an already reported `^Item_Error` occurs, so `parse_foreign` could drop errors and `Item_Foreign_Block.members` become `[]^Decl`. (about 15 lines)
- [foreign.odin:41](src/foreign.odin#L41) and [doc.odin:544](src/doc.odin#L544): both state "member, then block, then file" for visibility, doc.odin for declarations no symbol records. `written_is_public` already composes: `written_is_public(d.attributes, nil, written_is_public(block, file.attributes))` replaces lines 544 to 550. (about 5 lines)

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
- [formatter.odin:83](src/formatter.odin#L83) `format_source`: scratch diagnostics are never shown and `line_starts = {}` is the zero value, so write `Source{text = formatted}`, as `lsp/editing.odin` does. (part of a line)
- [formatter.odin:448](src/formatter.odin#L448) `spacing`: the `.Rbrace` and `.Lbrace` cases have one body, so `case .Rbrace, .Lbrace:`. (about 2 lines)

**Dead code**

- (branch) [formatter.odin:297](src/formatter.odin#L297): `len(l.opens) > 0` before `pop`; `format_source` only lays out text that parsed, so every closer has an opener. (about 2 lines)
- (branch) [formatter.odin:385](src/formatter.odin#L385): `token.lo > 0 && token.hi < u32(len(l.text))`; a parsed file neither starts nor ends with an arithmetic operator.
- (branch) [formatter.odin:322](src/formatter.odin#L322): `at > int(brace.hi)`; when equal, `l.text[at - 1]` is the `{` itself, which already fails the `'\n'` test.
- (branch) [formatter.odin:405](src/formatter.odin#L405): `.At` in `maybe_prefix`; line 496 returns first for `last == .At`, `binary_operator(.At)` is false, and no prefix operator can precede an attribute now that a type holds none.

**Near copies**

- [formatter.odin:60](src/formatter.odin#L60) and [doc.odin:133](src/doc.odin#L133): lines 133-136 of `doc.odin` are the body of `format_text`. Write `formatted, ok := format_text(&scratch, INTERFACE_FILE, raw)`. (about 3 lines)
- [formatter.odin:81](src/formatter.odin#L81) and [doc.odin:149](src/doc.odin#L149): a scratch `Compiler`, one bare `Source` and `lex` recur at doc.odin:947, doc.odin:965, lsp/editing.odin:337, lsp/editing.odin:349 and lsp/roots.odin:188. A lexer helper taking `(scratch, text)` and returning tokens removes a line or two at each.

**Structure and boundaries**

- [formatter.odin:49](src/formatter.odin#L49): `input_sources` serves `-migrate` as well and only wraps `package_sources`, so it belongs beside that in `packages.odin`.

**Comments**

- [formatter.odin:3](src/formatter.odin#L3): lines 3-9 repeat comments.md "Formatting". Shorten to: "Changes whitespace only and refuses a file that does not parse; a result whose tokens differ is reported, not written (comments.md "Formatting")." (about 5 lines)
- [formatter.odin:225](src/formatter.odin#L225): lines 225-227 narrate the switch below, and the rule is in comments.md. Shorten to: "Tabs for a line that starts with `first` (comments.md "Formatting")." (about 2 lines)
- [formatter.odin:119](src/formatter.odin#L119): restates the field name. Say why it exists: "Recognizes the operator spelled `[]=`." Lines 152 and 325 narrate the code; delete those. (about 2 lines)
- [formatter.odin:65](src/formatter.odin#L65): restates the signature and misses the internal-error refusal. Shorten to: "False, with `c`'s diagnostics saying why, where it refuses."

### src/generic.odin

Sound in design and mostly well commented, but large: parametric aliases and generic `impl` blocks are each 600-line subsystems, inference is one 220-line procedure, and several small copies remain. Every bug below was reproduced with the prebuilt `lokec.exe`.

**Bugs**

- `BUG-generic-1` **high** [generic.odin:1308](src/generic.odin#L1308) `alias_refers_to`: the walk has no visited set, and the depth limit bounds depth, not breadth, so it is exponential. Scenario: `A :: B($T); B :: Pair(C($T), C($T)); C :: Pair(B($T), B($T));` hangs (killed at 25 s) instead of reporting L0745; a valid chain `Ai :: Pair(Aj($T), Aj($T))` takes 2.5 s at 22 levels, 9.8 s at 24 (0.3 s at one). Fix: one `map[Symbol_Id]bool` per query. *Confirmed: Reproduced: the 3-alias cycle was killed at 30 s with no L0745; the same cycle with one reference per body reports at once. Valid chains grow about 3x per 2 levels (22: 3.9 s, 24: 12.5 s). Severity is medium: a compile hang on unusual input, no wrong code.*
- `BUG-generic-2` **medium** [generic.odin:2488](src/generic.odin#L2488) `bind_default_compile_time_argument`: resolves the template's own `declared` without the copy line 2338 makes, and `Type_Array` caches `denoted_type`. Scenario: `f :: proc($N: int, $A: [N]int = [N]int{})`, then `f(2); f(3);` rejects the second: "`[3]int{0, 0, 0}` is not representable by the generic parameter's type `[2]int`". Fix: `clone_expr(k.c, declared)`. *Confirmed: Reproduced: f(2); f(3) gives L0392 `[3]int{0, 0, 0}` is not representable by `[2]int`; either call alone or written args compile. Line 2488 lacks the clone_expr line 2338 uses, so Type_Array caches; design.md "Default values" says per call. Medium fits.*
- `BUG-generic-3` **medium** [generic.odin:3038](src/generic.odin#L3038) `bind_record_argument`: an unbound or type-bound `$` in a constant parameter's argument returns `"", false`, which every caller treats as already reported. Scenario: `Vec :: struct($N: int) { x: int }` and `main :: proc() { v: Vec($N); }` exits 2 with L0405 "`<invalid>` has no backend representation", no user diagnostic. `[]$T` there gets L0437. Fix: report L0437 here. *Confirmed: Reproduced: v: Vec($N) and type-bound Vec($T) in a generic proc exit 2 with spanless L0405 <invalid>, while []$T gets L0437; design.md says $ appears only where bound. Not recorded. Invalid programs only, no wrong code, so low-to-medium.*
- `BUG-generic-4` **medium** [generic.odin:2659](src/generic.odin#L2659) `instantiate_generic`: the rejection keeps diagnostic number one of the probe even if it is a warning; line 2861 looks for the first error. Scenario: `@(deprecated="old") N :: proc() -> int {...}` and `f :: proc($T: type, a: [N()]int, b: Unknown) {}` reports `error[L0611]: N is deprecated`, and `Unknown` never appears. Fix: take the first `.Error`, shared with line 2861. *Confirmed: Reproduced: the probe prints error[L0611] N is deprecated and hides L0306 Unknown; with `where false` L0611 is the only rejection. Line 2659 takes the head without checking severity. Severity is low: only already invalid programs get a wrong diagnostic.*
- `BUG-generic-5` **medium** [generic.odin:3685](src/generic.odin#L3685) `declare_instance_impl_members`: has the member and field checks of `declare_impl_member` but not its built-in one, against design.md "Inspecting a union". Scenario: `U :: union($T: type) { a: T, b }` with `impl U($T) { as :: proc(self) -> int {...} }` is accepted, and fails only at a use with L0425; the non-generic form gets L0409. Fix: share the check (see Near copies). *Confirmed: Reproduced: impl U($T) { as :: ... } on a generic union compiles with U(int) instantiated, while the plain form gets L0409; design.md forbids it and only a use fails, with L0425. Severity is low rather than medium: the member is just unreachable.*
- `BUG-generic-6` **medium** [generic.odin:3716](src/generic.odin#L3716) `declare_instance_impl_members`: a public non-procedure member of a generic extension takes the plain package name from the first instance; later instances are dropped at line 3865. Scenario: package `ext` with `impl lib.Holder($T) { K :: size_of(T); }`, instantiated with `u8` then `i64`: `ext.K` compiles and prints 1, decided by instantiation order. Fix: export procedures only, as the comment at line 3714 says. *Confirmed: Probe: public K :: size_of(T) in impl lib.Holder($T); ext.K prints 1 with Holder(u8) declared first, 8 with Holder(i64) first, and is L0335 with no instance. Only procedures get a group; a Const is kept by the first instance. Unrecorded; medium fits.*
- `BUG-generic-7` **low** [generic.odin:2331](src/generic.odin#L2331) `infer_generic_arguments`: `default_type` of `nil` is INVALID_TYPE and is bound anyway, here and at line 2509, though `match_type_pattern` refuses it at line 1769. Scenario: `f :: proc($v: $I) {}` with `f(nil)` reports "`$I` is not bound here" for `f(nil, <invalid>)`. Fix: fail with the "`nil` has no type to infer" reason. *Not verified.*
- `BUG-generic-8` **low** [generic.odin:2351](src/generic.odin#L2351) `infer_generic_arguments`: `position` skips a variadic pack, so the count is wrong. Scenario: `f :: proc(xs: ..$T) {}` with `f(xs = 1)` says "it takes 0 arguments, found 1"; the non-generic form says L0371 "no parameter named `xs`". Fix: report the unclaimed named argument by name. *Not verified.*

**Simplification**

- [generic.odin:2184](src/generic.odin#L2184) `infer_generic_arguments`: eight `result.reason = fmt.aprintf(..., allocator = k.c.semantic_allocator); return result` blocks. A local `refuse(k, format, args)` returning the `Inference` makes each one line. (about 35 lines)
- [generic.odin:3011](src/generic.odin#L3011) `bind_record_argument`: it already takes `report`, yet its three callers (lines 1112, 1392, 2933) each do `if report && problem != "" { errorf L0432 }`. Report inside and return `bool`; have both constant paths fall into one convert-then-bind tail. (about 15 lines)
- [generic.odin:1719](src/generic.odin#L1719) `match_array_as_view`: the `before`/`resize` pairs serve nothing, as its only caller (line 2306) aborts inference on false. Pick the view type by case, then `return match_type_pattern(k, pattern, view, scope, out)`. (about 10 lines)
- [generic.odin:3424](src/generic.odin#L3424) `install_generic_impls`: copy loop and hand-written insertion sort become `slice.clone` and `slice.stable_sort_by` on descending `specificity`. (about 10 lines)
- [generic.odin:3550](src/generic.odin#L3550) `declare_generic_impl_block`: the probe, resolve and compare at lines 3557-3564 and 3567-3574 are one block; run `match_generic_arg` first when the argument has a `$`, then share the comparison, then `continue` if it has a `$`. (about 8 lines)
- [generic.odin:3707](src/generic.odin#L3707) `declare_instance_impl_members`: reacquiring the symbol to read `public` and set `type` is needless; compute `public` and `is_proc` first and put both in the literal at line 3693. (about 6 lines)
- [generic.odin:3917](src/generic.odin#L3917) `check_pending_impl_instances`: the tail recursion at line 3991 is an outer loop, and a `next_pending_impl` cursor on `Compiler` replaces `Pending_Impl.checked` and the walk from 0 on every call. (about 5 lines)
- [generic.odin:3245](src/generic.odin#L3245) `check_where_clauses`: three `note_instantiation_stack(k); return false` endings become `if failed {...} else if !report_failed_interface_bound(...) {...}` with one ending. (about 4 lines)
- [generic.odin:3440](src/generic.odin#L3440) `install_one_generic_impl`: a one-call wrapper; line 3324 can pass `[]^Generic_Impl{block}` itself. (about 4 lines)
- [generic.odin:1600](src/generic.odin#L1600) `generic_instance_name`: both arms write the name; only the owner prefix is conditional. (about 3 lines)
- [generic.odin:949](src/generic.odin#L949) `alias_binding_uses`: `value_use` is passed a known `Type_Poly` here and its result is ignored elsewhere; test `kind != TYPE_TYPE` alone, and the helper needs no result. (about 3 lines)
- [generic.odin:784](src/generic.odin#L784) `success_parameters`: `for &mark in marks { mark = true }` here and at lines 797 and 825 is `slice.fill(marks, true)`. (about 3 lines)
- [generic.odin:261](src/generic.odin#L261) `reject_uninstantiated_generic`: `make([dynamic]Name, temp)` then `pattern_shape(x, &names)` recurs at lines 330, 881, 2417 and 3338; a `pattern_names(e) -> []Name` drops a line at each. (about 5 lines)
- [generic.odin:3508](src/generic.odin#L3508) `enter_impl_install`: passes INVALID_TYPE and then assigns `k.impl_type`; pass `instance.type` as the argument. (about 1 line)
- [generic.odin:3175](src/generic.odin#L3175) `promote_generic_instance`: `symbol_of(k.c, instance.symbol)` is repeated at lines 3165, 3175, 3180 and 3181; a local `sym` reads better. (about 2 lines)

**Dead code**

- `instance_template_of` ([generic.odin:3884](src/generic.odin#L3884)): its only use is the unreachable branch at line 3865, described next.
- (branch) [generic.odin:3864](src/generic.odin#L3864): "the two become a group" needs a public procedure in the package scope with no group there, but `register_generic_extension_groups` (added by 44b118cc, after this path) always registers one first; line 3845 now installs only non-procedures.
- (branch) [generic.odin:3853](src/generic.odin#L3853): the already-a-member scan never matches, as the only caller (line 3717) passes a symbol created at line 3693.
- (branch) [generic.odin:3295](src/generic.odin#L3295): the "earlier discovery round" scan never matches: the only caller, `declare_impl_block`, returns early on `item.declared`, which line 3320 sets. The `blocks` setup above it simplifies too.
- (branch) [generic.odin:894](src/generic.odin#L894): `pattern_shape` visits every arm in source order, so names arrive in written order; the earlier-span update and the insertion sort at lines 898-903 never act (0ae279da added them). Keep first-appearance dedup only.
- (branch) [generic.odin:2673](src/generic.odin#L2673): `instance == nil` cannot hold, since the only caller passes a cached non-nil entry. `case .None:` at line 2701 is needless in a `#partial switch`.
- (branch) [generic.odin:3095](src/generic.odin#L3095): `.Procedure` means `decl_proc_literal` was non-nil (line 392) and the clone keeps it, so this branch and `instance.decl == nil` at line 2689 cannot hold.

**Data structures and algorithms**

- [generic.odin:3892](src/generic.odin#L3892) `enter_pending_impl_member`: eval.odin:175 calls it for each unchecked procedure evaluated, generic or not, and it scans every instantiated block's members; that list only grows. The member's symbol already holds scope, package, file and owner (line 3693), so `enter_symbol_location(k, sym, sym.owner_type)` could replace the scan; check `generic_depth`.
- [generic.odin:1529](src/generic.odin#L1529) `instance_key`: builds into the semantic arena on every request, cache hits included, so it grows with each spelled `Table(int)` and each overload probe. Build in `context.temp_allocator` and clone only when inserting (lines 1429 and 2630).
- [generic.odin:2192](src/generic.odin#L2192) `infer_generic_arguments`: each candidate of each call, and each application (lines 1369, 2908), makes a scope and one permanent symbol per binding before the cache is asked. Growth is uses times candidates; dependent parameters need the scope, but a record whose parameters are all `type` could ask the cache first.
- [generic.odin:1336](src/generic.odin#L1336) `push_application_frame`: formats the full instance name, type names included, for each counted constant parameter of each application, though a name is read only if a note is written. Store symbol and bindings in `Instantiation_Frame` and format in `note_instantiation_stack`.
- [generic.odin:2100](src/generic.odin#L2100) `template_poly_names`: scratch in the semantic arena, on every argument-context query and waiting inference; nothing keeps it. Use `context.temp_allocator`. `Poly_Names` wraps one field and can be the `[dynamic]string` itself.

**Near copies**

- [generic.odin:3677](src/generic.odin#L3677) and [impl.odin:209](src/impl.odin#L209): the L0409 name checks and the 14-line member `Symbol` literal (line 3693, impl.odin:240) differ only in package and subject. A `reject_impl_member_name` plus `new_impl_member_symbol` removes the copy and fixes BUG-5. (about 25 lines)
- [generic.odin:669](src/generic.odin#L669) and [generic.odin:959](src/generic.odin#L959): `pattern_shape` and `alias_binding_uses` spell the same arms for pointer, C pointer, slice, dynamic array, distinct, map, proc and structural types. A `type_pattern_parts(e) -> []Expr` leaves the second with a default loop plus its Dyn, Array and Call arms. (about 20 lines)
- [generic.odin:520](src/generic.odin#L520), [generic.odin:642](src/generic.odin#L642) and [generic.odin:3825](src/generic.odin#L3825): the same merge loop, with parameter flattening copied at lines 530-537 and 629-638. `pattern_relations(left, right: []Expr)` and `flat_parameter_types(params)` make `impl_block_relation` one call. (about 20 lines)
- [generic.odin:1357](src/generic.odin#L1357) and [generic.odin:2895](src/generic.odin#L2895): the same rejected, positional and arity prologue, with a reporting form at line 3348. Share `generic_application_fits(k, args, span, template, report)`. (about 10 lines)
- [generic.odin:814](src/generic.odin#L814), [generic.odin:2127](src/generic.odin#L2127) and [generic.odin:2162](src/generic.odin#L2162): three `Name_Match` callbacks with one classification (a name, walk on for a selector or distinct, otherwise an inline definition). A shared classifier leaves each with its own reaction. (about 10 lines)
- [generic.odin:2099](src/generic.odin#L2099) and [generic.odin:2417](src/generic.odin#L2417): two walks collect a signature's `$` names, by `collect_poly_name` and by `pattern_shape`, and lines 254-266 and 326-335 are a third and fourth. One `signature_poly_names(literal)` serves them; only a `$` inside an expression length would differ, so check that. (about 12 lines)
- [generic.odin:2330](src/generic.odin#L2330) and [generic.odin:2508](src/generic.odin#L2508): both bind `$I` from the argument's type, resolve the parameter type, then call `bind_compile_time_argument`. One helper returning `wanted` avoids a repeat of BUG-2. (about 6 lines)
- [generic.odin:1848](src/generic.odin#L1848) and [generic.odin:1874](src/generic.odin#L1874): `[$N]` and `Simd(_, $N)` bind a count the same way; `bind_count_pattern(k, e, count, scope, out)`. (about 8 lines)
- [generic.odin:1151](src/generic.odin#L1151) and [generic.odin:1194](src/generic.odin#L1194): `find_distinct` and `collect_poly` both descend into a record's fields and variants and a proc's signature. One helper taking the callback serves both. (about 8 lines)
- [generic.odin:2659](src/generic.odin#L2659) and [generic.odin:2861](src/generic.odin#L2861): both capture an `Instance_Rejection` by hand. `instance_rejection_since(c, mark)` serves both and fixes BUG-4. (about 6 lines)
- [generic.odin:1337](src/generic.odin#L1337) and [generic.odin:2607](src/generic.odin#L2607): the report-once limit diagnostic, differing only in wording. A `report_instantiation_limit` takes the text. (about 5 lines)
- [generic.odin:3272](src/generic.odin#L3272) and [doc.odin:1372](src/doc.odin#L1372): `where_bound_text` and `source_text` both read an expression's span from its source; check.odin:2394 inlines it too. Move `source_text` beside the sources and call it. (about 5 lines)

**Structure and boundaries**

- [generic.odin:874](src/generic.odin#L874) and [generic.odin:3285](src/generic.odin#L3285): parametric aliases (lines 874-1524) and generic `impl` blocks (lines 3285-3912) are about 640 lines each and already have banners; `generic_alias.odin` and `generic_impl.odin` are the seams, with `enter_generic_location` and `pattern_relation` losing file privacy, and the source map updated.
- [generic.odin:2184](src/generic.odin#L2184) `infer_generic_arguments`: 222 lines. Seams: the variadic pack (lines 2230-2265), the `$` parameter's binding (lines 2326-2344), and the unbound-wait check (lines 2360-2392).
- [generic.odin:1140](src/generic.odin#L1140) `check_alias_template`: 139 lines of three separable rules: no `distinct` (lines 1148-1179), every `$` bindable (lines 1191-1228), and settling parameter kinds (lines 1229-1267).
- [generic.odin:3917](src/generic.odin#L3917) `check_pending_impl_instances`: reports conflicts (lines 3929-3947), enrolls members for emission (lines 3957-3975), and drains private reads; the first two are named procedures waiting to be extracted.
- [generic.odin:39](src/generic.odin#L39): `Generic_Template`, `Generic_Impl`, `Pending_Impl` and `Pending_Private_Read` repeat scope, package, file and file node, and `enter_generic_location` takes them as six parameters. A location struct, or `Checker_Location` (check.odin:819), shortens all of them and `pend_template_private_read`.
- [generic.odin:428](src/generic.odin#L428), [generic.odin:3440](src/generic.odin#L3440), [generic.odin:1597](src/generic.odin#L1597) and [generic.odin:1746](src/generic.odin#L1746): `pattern_specificity`, `install_one_generic_impl`, `generic_instance_name` and `match_type_pattern` are used only in this file, so per the source map they should be `@(private = "file")`.
- [generic.odin:1514](src/generic.odin#L1514): `poly_array_length` sits in the alias section but serves `[$N]E` inside any instance; it belongs near `bind_generic_name`.

**Comments**

- [generic.odin:1711](src/generic.odin#L1711): lines 1711-1714 describe `match_type_pattern` but sit on `match_array_as_view`; move them to line 1746. "A failed attempt leaves no binding behind" (line 1717) is untrue of `scope` (line 2011); delete it.
- [generic.odin:426](src/generic.odin#L426): misleading, since tie-breaker 5 is `compare_generic_specificity` and this value only orders installation (line 3308). Write: "Orders `impl` blocks for installation: every written layer counts; `$T` none."
- [generic.odin:315](src/generic.odin#L315): eight lines to four: "A `$` default naming no parameter means the same in every instance, so it is checked here; one naming a parameter waits for the call. A speculative check against stand-ins for every parameter name tells them apart."
- [generic.odin:1408](src/generic.odin#L1408): five lines to two: "No cycle check: an alias reaches itself only through a record (L0745), whose instance already exists. New arguments each time hit this limit."
- [generic.odin:2489](src/generic.odin#L2489): six lines to two: "Checked per call on a copy, as `twice(size_of(T))` resolves per `T`. A failure only makes the candidate inapplicable, so this is a speculation."
- [generic.odin:2928](src/generic.odin#L2928): too cryptic; write "At the limit `wanted` is invalid, and the argument must not then be read as a type."
- [generic.odin:1796](src/generic.odin#L1796): delete; lines 1778-1780 already say slices follow the same rule.
- [generic.odin:2464](src/generic.odin#L2464): delete; repeats lines 2442-2445.
- [generic.odin:3504](src/generic.odin#L3504): delete; narrates. Likewise lines 868, 3445 and 3531, which restate the name or signature, and line 838, which repeats line 837. (about 30 lines across the file; the rest mostly explain why)

### src/global_effects.odin

The solvers are sound in how they iterate and deterministic, and the comments are mostly about why; three kinds of implicit user-code call are missing from the effects. Allocator-use source plumbing and `Effect_Source.precision` carry data nothing reads, and three worklists plus two region substitutions are copies.

**Bugs**

- `BUG-global_effects-1` **high** [global_effects.odin:1069](src/global_effects.odin#L1069) `ELEMENT_DROPPING_OPS`: `find_or_insert` and `try_insert` drop a value and map `remove` drops the stored key, but no effect is counted (design.md "Inferred effects": container element removal). *Confirmed: Reproduced: find_or_insert, try_insert and remove (stored key) run the hook under a live borrow with no L0512, though design.md counts removal drops. A hook clearing a global made a live view read freed memory (7777), so high is fair. Not recorded as a gap.*
  Scenario: `p := &mut counter; _ = m.find_or_insert(1, Res{2}); p^ = 100;` with a `hook(drop)` writing `counter` compiles and runs the hook; `m[1] = Res{2}` gets L0512. A hook clearing a global array leaves a live view dangling.
  Fix: in `prov_container_drop_effects`, drop `container_element` for `.Map_Find_Or_Insert` and `.Map_Try_Insert`, and `container_key` for `.Map_Remove`; the comment at L1066 is wrong about keys.
- `BUG-global_effects-2` **medium** [global_effects.odin:515](src/global_effects.odin#L515) `prov_implicit_call_effects`: `sort` and `reverse_sort` call an element's inherent `operator(<)`, and no effect is counted. *Confirmed: Reproduced: with `p := &mut counter` live, `xs.sort()`, `reverse_sort` and `slice.sort` compile and run the writing `operator(<)`, printing `less 1` then `100`. A direct `xs[0] < xs[1]` gets L0512. No gap or decision is recorded; medium fits.*
  Scenario: `p := &mut counter; xs.sort(); p^ = 100;` where `less` writes `counter` compiles, and the run prints `less` then `100`, so the operator wrote while the borrow was live.
  Fix: for `.Sort, .Reverse_Sort`, call `prov_effect_call` on the policy's `Order_Policy.less` ([container.odin:446](src/container.odin#L446)) when its kind is `.Inherent`.
- `BUG-global_effects-3` **medium** [global_effects.odin:676](src/global_effects.odin#L676) `prov_operator_effects`: only `Expr_Binary` reaches `prov_equality_effects`, but a `switch` on a record with own `==` also runs it per case. *Confirmed: Probe: with `p := &mut counter` live, `switch (x) { case K{1}: }` whose `==` writes `counter` compiles and runs, printing hit/100, while `if (x == K{1})` gets L0512. walk_flow_switch only walks case values and emits no equality effect. Not recorded in any doc.*
  Scenario: `p := &mut counter; switch (x) { case K{1}: ... } p^ = 100;` where `==` writes `counter` compiles and runs `==`; `x == K{1}` in the same position gets L0512.
  Fix: call `prov_equality_effects` on the subject's type from `walk_flow_switch` ([cfg.odin:2198](src/cfg.odin#L2198)) for each value case.

**Simplification**

- [global_effects.odin:1709](src/global_effects.odin#L1709) `clone_effect_args`, `clone_symbols`: both are `slice.clone(x, c.semantic_allocator)`, which this file already uses at L1462 and L2045. Delete them. (about 12 lines)
- [global_effects.odin:1458](src/global_effects.odin#L1458) `compute_global_writes`: `make` plus `append`/`copy` pairs at L1458-1464, L1501-1502 and L1960-1961 are `slice.clone_to_dynamic` and `slice.clone`. (about 6 lines)
- [global_effects.odin:1648](src/global_effects.odin#L1648) `effect_targets`: this loop repeats L1670-1674 with the same predicate; replace it with `append(&out, ..effect_targets(c, Effect_Call{type = call.type}, program, visited))`, which also uses `type_unions`. (about 4 lines)
- [global_effects.odin:2193](src/global_effects.odin#L2193) `collect_thread_exit_drops`: `call := callback_call(sym.span, owner)` replaces three lines, since `substitute_allocator_use` reads only `span` and `regions`. One-element slices at L802, L1220, L1780 are likewise `slice.clone([]T{x}, temp)`. (about 8 lines)
- [global_effects.odin:1299](src/global_effects.odin#L1299) `effect_call_description`: return from a `switch` (`described`, no symbol, no `dropped`, `unnamed`, else) instead of `name := ""` and an else-if chain. (about 4 lines)
- [global_effects.odin:1108](src/global_effects.odin#L1108) `prov_effect_call`: `regions_of != nil || drops` is tested twice; name it once as `deferred`. (about 1 line)
- [global_effects.odin:1480](src/global_effects.odin#L1480) `compute_global_writes`: make `c.thread_spawns` with the other maps at L1439 and just `append`; the guards go. (about 4 lines)
- [global_effects.odin:1564](src/global_effects.odin#L1564) `compute_global_writes`: `own` exists only for `warn_thread_races`, which is file-private like `Body_Effects`; pass `bodies[:]`. (about 3 lines)
- [global_effects.odin:112](src/global_effects.odin#L112) `prov_note_static_write`, `prov_note_static_read`: share a `prov_root_global(graph, root) -> Symbol_Id`. The write also adds to `effect_writes` after the effects settle, where nothing reads it; gate it as the read is. (about 5 lines)

**Dead code**

- `param_sources` ([borrow.odin:1059](src/borrow.odin#L1059)): with `default_source` and `unknown_source`, read only by `thread_summaries_test.odin`. Removing them removes the `via` and `source` plumbing in `substitute_allocator_use`, L1936-1937, and most of `clone_allocator_use`.
- `use` ([global_effects.odin:1753](src/global_effects.odin#L1753)): `Thread_Exit_Drop.use` is read only by tests, and [borrow.odin:6143](src/borrow.odin#L6143) skips every `hook == INVALID_SYMBOL` entry, so the `owns` branch at L2179-2183 and L2191-2197 serve tests alone. Consume it for the window check or remove it.
- (branch) [global_effects.odin:1623](src/global_effects.odin#L1623): the `call.callee` case of `effect_targets` is unreachable; `call_parts`, `effect_call_globals` and `indirect_call_targets` all handle a callee first, and `forwarding_effect` and `any_value_call` set none.
- (branch) [global_effects.odin:1924](src/global_effects.odin#L1924): `graph == nil` is unreachable: `check_proc_body` always checks a body and returns on a nil symbol, and L1453 has no such check. So are the `sym != nil` guards at L1455 and L1912.
- (branch) [global_effects.odin:1161](src/global_effects.odin#L1161): `new_flow_graph` is the only creator and returns nil for a nil literal, so `graph.literal` is never nil here or at L565; `graph_body` is `graph.literal.symbol`.
- (branch) [global_effects.odin:950](src/global_effects.odin#L950): `&& call.callee != INVALID_SYMBOL` here and at L967 and L2080 adds nothing to `found`: every body has a symbol, so `INVALID_SYMBOL` is never in `index_of`.
- (branch) [global_effects.odin:1272](src/global_effects.odin#L1272): `callback_region` is reached only from `prov_window_effect_use`, which needs `parallel_depth > 0`, and `check_parallel` sets `thread_summaries_wanted`, so the regions are always settled. The fallback and its comment can go.
- (branch) [global_effects.odin:1444](src/global_effects.odin#L1444): `c.type_unions = nil` is a no-op; the field is nil until L1495 and this procedure runs once per program.

**Data structures and algorithms**

- [global_effects.odin:1423](src/global_effects.odin#L1423) `effect_key`: formats a string with `fmt.aprintf` for each indirect call in each graph pass and for each `effect_targets` call, to key `indirect_writes`, `indirect_reads` and `visited`. A comparable struct `{interface, slot, type}` needs no formatting or allocation.
- [global_effects.odin:1628](src/global_effects.odin#L1628) `effect_targets`: the `dyn` case scans all of `witness_order` and up to all bodies twice, uncached, per `dyn` call in `call_parts`, in both solvers; cost is `dyn` calls times (witnesses + bodies). Only type unions are cached. Cache by the struct key above when `seen == nil`.
- [global_effects.odin:1685](src/global_effects.odin#L1685) `add_global_symbol`: a linear scan, so a revisit costs `|from| * |into|` per part, and a body near `main` can reach most globals. Small today since programs have few globals; if `perf.ps1` shows it, use a per-body bit row indexed by a dense global number, as `borrow.odin` does for loans.

**Near copies**

- [global_effects.odin:144](src/global_effects.odin#L144), L275, L359, L713 and [borrow.odin:2578](src/borrow.odin#L2578): the same `Ident`/`Selector`/`Proc` switch; share `expr_named_symbol(e) -> Symbol_Id`. L713 omits `Expr_Proc` since the race warning covers named procedures only, so keep that check at its caller. The tail of `effect_value` at L369-374 and borrow.odin:2587-2591 also match.
- [global_effects.odin:955](src/global_effects.odin#L955), [L1528](src/global_effects.odin#L1528) and [L1987](src/global_effects.odin#L1987): the same `queued`/`pending` setup, pop and wake-readers code, at L961-991, L1534-1562 and L1993-2040. A small `Body_Queue` with `make`, `pop` and `wake(list)` saves about 25 lines.
- [global_effects.odin:1351](src/global_effects.odin#L1351) `substituted_region` and [L2129](src/global_effects.odin#L2129) `substitute_allocator_use`: identical parameter switch. Once the sources above go, the second is `merge` of the first's result; [L1283](src/global_effects.odin#L1283) `region_through` differs only by having no `direct` case. (about 20 lines)
- [global_effects.odin:534](src/global_effects.odin#L534) `prov_hash_effects` and [L547](src/global_effects.odin#L547) `prov_equality_effects`: differ only in `part_own_hash` versus `type_own_equality`, which share a signature; one body taking that proc saves about 8 lines.
- [global_effects.odin:593](src/global_effects.odin#L593), L664, L1658 and [hooks.odin:560](src/hooks.odin#L560): each looks up `runtime_types["Format_View"]` and takes its `dyn_interface`; a `format_view_interface(c) -> Symbol_Id` shortens all four. (about 6 lines)

**Structure and boundaries**

- [global_effects.odin:2233](src/global_effects.odin#L2233): `clone_allocator_use`, `resize_allocator_use`, `merge_allocator_use_from`, with `clone_regions` at L2216 and `region_through` at L1283, are operations on types owned by [borrow.odin:981](src/borrow.odin#L981); they belong beside `region_merge` and `merge_allocator_use`.
- [global_effects.odin:1437](src/global_effects.odin#L1437) `compute_global_writes`: 145 lines with natural seams: collecting a body (L1449-1488), building parts (L1506-1520), the fixed point (L1524-1563), publishing (L1564-1577).
- [global_effects.odin:1902](src/global_effects.odin#L1902) `compute_thread_summaries`: 155 lines; the seams are collecting facts (L1907-1967, with the handle rule at L1945-1957 as its own helper), the fixed point (L1993-2041), publishing (L2042-2055).
- [global_effects.odin:1770](src/global_effects.odin#L1770): `indirect_call_targets`, `call_effect_origins` and `callable_type_targets` sit under the thread-summaries header, but result summaries and diagnostics use them; move them to the per-call section. `prov_drop_effects` and its family (L1044-1086) interrupt that section's solver helpers and belong with the other `prov_*` hooks above L755.
- [global_effects.odin:1722](src/global_effects.odin#L1722): this header is a natural file seam, about 550 lines of thread summaries, at the cost of making `call_parts`, `closing_parts`, `part_readers` and `call_values` `@(private)` rather than file-private. It would need the source-code map updated.

**Comments**

- [global_effects.odin:725](src/global_effects.odin#L725): restates the spec's bullets; shorten to `design.md "Global write effects"` plus: "`own` leaves out what received callbacks run, which is reported where the crossing call passes them." (about 5 lines)
- [global_effects.odin:1176](src/global_effects.odin#L1176): keep the citation and "a helping join may run the block's pooled tasks and their descendants, so it writes and reads their `thread_local` storage." (about 4 lines)
- [global_effects.odin:1136](src/global_effects.odin#L1136): repeats L39-42 and L1695; use "Not the parent's at the spawn; a pooled join counts them (`prov_pool_join_effects`)." (about 2 lines)
- [global_effects.odin:1430](src/global_effects.odin#L1430): repeats the file header and `call_parts`, and has a stray line break; "Gathers every clean body's effects, then settles them; `call_parts` says what a call takes in." (about 5 lines)
- [global_effects.odin:1375](src/global_effects.odin#L1375): repeats L828-833; "A union is settled once per key." Delete L1383. (about 3 lines)
- [global_effects.odin:1606](src/global_effects.odin#L1606): delete, as it restates the name; likewise L2242. (about 2 lines; about 25 lines across the file with those above and similar overlap at L1328 and L2123)
- [global_effects.odin:1066](src/global_effects.odin#L1066): "`pop` and `remove` hand theirs back" is false for a map's key; rewrite with the fix for the first bug above.

### src/hash.odin

Small and readable, but it holds four jobs, and its distinct-type handling and compile-time mix have real errors, all reproduced with scratch programs on the current `lokec.exe`. Most of the shortening is in the hashability walk and the compile-time leaf.

**Bugs**

- `BUG-hash-1` **medium** [hash.odin:122](src/hash.odin#L122) `part_hash_member`: looks for `hash` on the part, then its underlying type, without regard to where `==` came from, so a part can pair one type's `==` with another's `hash`. Scenario: `S` declares `==` and `hash`, `D :: distinct S` declares only a coarser `==`, and `map[struct { d: D }]int` is accepted using `S.hash`; two keys that compare equal hash apart and the map holds both (`len` 2, `x == y` true). Fix: read `hash` from the type that supplied `==`, so this `D` has no `hash` and is rejected. *Confirmed: Reproduced: map[struct-with-D]int prints len 2, x == y true, hashes differ, using S.hash beside D's own coarser ==. map[D]int gets L0586, and design.md "Maps" requires a component with custom equality to supply its own hash; unrecorded in the gap documents.*
- `BUG-hash-3` **medium** [hash.odin:353](src/hash.odin#L353) `hash_scalar_bits`: a `typeid_of(T)` constant has no number yet (design.md "`type` and `typeid`") and `value.integer` is zero, so it hashes like the nil `typeid`. Scenario: `typeid_of(int).hash(uint(7)) == typeid_of(string).hash(uint(7))` folds true, and neither matches the runtime hash, against the file's "must agree exactly". Fix: `eval_hash` fails with L0341 for a `.Type` value naming a type, as bit-casting one does. *Confirmed: Probe: H :: typeid_of(int).hash(uint(7)) and the string form both give 7696581397477, the nil id's runtime hash, while runtime gives other values for each. design.md says such a number has no compile-time meaning; no gap recorded.*
- `BUG-hash-4` **low** [hash.odin:98](src/hash.odin#L98) `record_hashes_structurally`: checks for a `hash` on `under` only, and `part_is_hashable` never checks a scalar part, so a nested `distinct` declaring only `hash` is accepted and its `hash` ignored. Scenario: with `Ds :: distinct S` declaring `hash`, `map[Ds]int` is rejected as half a pair but `map[struct { d: Ds }]int` compiles and hashes `d` structurally. Fix: in `part_is_hashable`, a part with no own `==` and an inherent `hash` is not hashable. *Not verified.*
- `BUG-hash-5` **low** [hash.odin:98](src/hash.odin#L98) `record_hashes_structurally`: `type_own_equality(c, id)` also sees the underlying type's `==`, so a `distinct` declaring neither half is rejected as a key, against the comment at [customization.odin:55](src/customization.odin#L55). Scenario: `D :: distinct S` with `S` holding the pair gives L0586 for `map[D]int`, while `map[struct { d: D }]int` compiles using `S.hash`. Fix: settle which design.md "Maps" means; then key `D` by `S`'s pair or correct that comment. *Not verified.*

**Simplification**

- [hash.odin:52](src/hash.odin#L52) `type_is_hashable_walk`: the temporary `parts` array exists only to be looped over; check each field or variant in place with `part_is_hashable`. Inline `record_hashes_structurally` (one caller) as one condition too. (about 12 lines)
- [hash.odin:276](src/hash.odin#L276) `own_equality`: the `under == type` guard only saves rescanning a member list that just failed; `return inherent_equality(c, type_underlying(c, type))` covers it. (about 3 lines)
- [hash.odin:344](src/hash.odin#L344) `hash_scalar_bits`: its one caller is `hash_const` and only `eval_hash` calls that, always with `ev.alloc`; inline it, use `underlying_kind`, make `allocator` required, and drop `value_allocator`. (about 8 lines)
- [hash.odin:265](src/hash.odin#L265) `type_own_equality_declared`: one caller, [check_expr.odin:2519](src/check_expr.odin#L2519); make `own_equality` file-visible and write `_, declared := own_equality(...)` there. (about 5 lines)
- [hash.odin:148](src/hash.odin#L148) `first_unhashable_part`: the `bool` result always equals `part_type != INVALID_TYPE`, and `type_underlying` is computed twice; drop the one and name the other. (about 3 lines)

**Dead code**

- (branch) [hash.odin:371](src/hash.odin#L371): `hash_const`'s array branch; `eval_hash` handles every `.Aggregate` array first, so `value.aggregate` is never set here, and `zero_value` and `value_from_const` gave no non-aggregate array on any path read. Remove it. (about 11 lines)
- (branch) [hash.odin:40](src/hash.odin#L40): the `.Untyped_*` arms here and at lines 137, 347 and 362; `map[K]` cannot name an untyped type, parts are typed, [customization.odin:44](src/customization.odin#L44) excludes untyped, and literal receivers arrive converted.

**Near copies**

- [hash.odin:154](src/hash.odin#L154) and [hash.odin:83](src/hash.odin#L83): the nested `unhashable` is `part_is_hashable` negated plus a void check. Move the void check into `part_is_hashable`, which also removes the filter at line 65, and call that with one shared `seen`. (about 8 lines)
- [hash.odin:382](src/hash.odin#L382), [eval.odin:4153](src/eval.odin#L4153) and [semantic.odin:1214](src/semantic.odin#L1214) (about 18 sites there): the same `(h ~ v) * HASH_MULTIPLIER`; a `hash_mix(h, v)` beside the constant gives the step one name.

**Structure and boundaries**

- [hash.odin:255](src/hash.odin#L255): lines 255-339 are equality, not hashing, and most callers are comparison code such as `type_is_comparable` and [check_expr.odin:2494](src/check_expr.odin#L2494). They belong beside `type_is_comparable` in `semantic.odin`.
- [hash.odin:200](src/hash.odin#L200) `resolve_map_key_policy`: selecting a policy and wording a rejection are mixed; the seam is lines 204-219, an `unhashable_key_reason(c, key) -> string`, which also gives the sentence repeated at lines 215 and 219 one home.

**Comments**

- [hash.odin:16](src/hash.odin#L16): the catalogue is in standard-library.md, also misattributed on line 1. Shorten to: `standard-library.md "Standard interface catalogue" lists the hashable scalars; a record or union keeping its generated == hashes structurally (design.md "Maps").` The NaN rationale is there and in the message at line 205. (about 2 lines)
- [hash.odin:48](src/hash.odin#L48): delete; `Type_Walk`'s comment at [semantic.odin:2185](src/semantic.odin#L2185) says this.
- [hash.odin:27](src/hash.odin#L27) and [hash.odin:299](src/hash.odin#L299): the same two lines, also at [semantic.odin:1973](src/semantic.odin#L1973); say it once on `Type_Walk` and delete these. (about 4 lines)
- [hash.odin:149](src/hash.odin#L149): the array remark does not match the filter below it, which rejects arrays; delete it or write `An array has no named part.`
- [hash.odin:90](src/hash.odin#L90): the list narrates the conditions below it; keep only `Packed fields are read in place.` (about 2 lines)
- [hash.odin:129](src/hash.odin#L129): delete; the name says it.

### src/hooks.odin

The classification logic is careful and its comments mostly explain why, but the file repeats one kind dispatch in four walkers and generates the copy pair in three places. It also holds transfer facts and declaration validation, which are separate jobs. Two wrongly rejected programs and one exponential walk were reproduced with the `lokec.exe` built at this commit.

**Bugs**

- `BUG-hooks-1` **medium** [hooks.odin:944](src/hooks.odin#L944) `validate_semantic_hook`: duplicate detection reads `underlying_info`, but a `distinct` subject's conversions live on its own info, as `conversion_hooks` reads them. *Confirmed: Reproduced: R and D :: distinct R, each with hook(convert) from bool, give false L0488 on D, though design.md "Conversion hooks" limits per source/target pair. Two bool hooks on distinct int pass with no use, L0391 only at D(true); struct gets L0488. Not recorded.*
  Scenario: `R` and `D :: distinct R` each with `hook(convert) proc(v: bool)` gives a false `L0488` on `D`, and two same-source hooks on `D :: distinct int` go unreported until a use gives `L0391`. Fix: use `type_of(k.c, subject)`; lifecycle roles only reach here on a plain struct.
- `BUG-hooks-2` **low** [hooks.odin:610](src/hooks.odin#L610) `contribute_distinct_copy_members`: a `distinct` array gets `try_clone` but no `clone`, against design.md "Distinct types". Commit 0ce949cc removed this exclusion from the underlying path only. *Not verified.*
  Scenario: `A :: distinct [2]int; a.clone()` is `L0363`, while `[2]int` has `clone`. Fix: drop the condition.

**Simplification**

- [hooks.odin:22](src/hooks.odin#L22) `Lifecycle.copy_excluded`: read only at line 140, and it always equals `has_excluded_copy_hook(c, info)`. Drop the field and the branch at line 204, and share `provider || move_only || has_excluded_copy_hook` between lines 140 and 409. (about 8 lines)
- [hooks.odin:668](src/hooks.odin#L668) `contribute_underlying_lifecycle_members`: both branches start with `if !entry.clone_disabled && !created { add pair }` and `enroll_lifecycle_members`. Hoist those above the switch, leaving only the choice of parts in the branches. (about 6 lines)
- [hooks.odin:800](src/hooks.odin#L800) `generated_hook`: `name` and `fallible` always follow `kind`, since the only calls pair `"try_clone", .Try_Clone, true` and `"clone", .Clone, false`. Derive both from `kind`. (about 2 lines, plus shorter calls)
- [hooks.odin:491](src/hooks.odin#L491) `transfer_facts_walk`: the early exit needs all four or five facts found at once, which is rare, and `visited` already bounds the walk. Keep `type == INVALID_TYPE || visited[visit]`. (about 3 lines)
- [hooks.odin:82](src/hooks.odin#L82) `lifecycle_parts`: fetches the info twice and asks for the kind a third way. Take `underlying_info` once, return on nil or `.Cyclic`, then switch on `.Array`, `.Struct`, `.Union`. (about 5 lines)
- [hooks.odin:953](src/hooks.odin#L953) `validate_semantic_hook`: `conflict := sym.hook != .Convert || (len(sym.params) == 1 && len(other.params) == 1 && sym.params[0] == other.params[0])`. (about 3 lines)
- [hooks.odin:1048](src/hooks.odin#L1048) `check_generic_impl_hooks`: `validate_instance_hooks` returns early for `.Extend`, so only the drop-shape case needs `reported_generic_hooks`. Two plain `if`s replace the switch, its two `continue` cases and the shared line 1065. (about 5 lines)
- [hooks.odin:246](src/hooks.odin#L246) `type_drop_runs_hook`: [cfg.odin:940](src/cfg.odin#L940) and [cfg.odin:1085](src/cfg.odin#L1085) spell it `len(type_drop_hooks(...)) == 0`. Use the helper there.

**Dead code**

- `type_clone_is_fallible` ([hooks.odin:783](src/hooks.odin#L783)): its only caller is the assertion at [emit_llvm_test.odin:604](src/emit_llvm_test.odin#L604), which compares `finalize_type_lifecycle`'s rule with a second copy of that rule. It exists only for that test.
- (branch) [hooks.odin:520](src/hooks.odin#L520): `info.kind == .Dyn` is always true inside `case .Dyn`.
- (branch) [hooks.odin:745](src/hooks.odin#L745): `type == INVALID_TYPE ||` here and at line 765 is already covered by `!type_is_managed`, which answers false for it at line 237.
- (branch) [hooks.odin:847](src/hooks.odin#L847): the only caller, in [check.odin](src/check.odin#L949), has already returned on `len(d.symbols) != 1 || d.symbols[0] == INVALID_SYMBOL`.
- (branch) [hooks.odin:1035](src/hooks.odin#L1035): the caller got `template` with `.Record` kind, and `declaration_generic_kind` gives that only for a single `Type_Record` value, so both guards cannot fire.

**Data structures and algorithms**

- [hooks.odin:413](src/hooks.odin#L413) `type_clone_disabled_walk`: `defer delete_key` makes the guard path-based, so a type reached by two routes is rewalked, exponentially in nesting. The query is reachability and caches nothing, so a plain visited set is exact. Measured with `Tn :: struct { a, b: Tn-1 }`: `is_copyable(T26)` took 58 s top-down, 0.18 s bottom-up.
- [hooks.odin:744](src/hooks.odin#L744) `clone_may_allocate`: recurses over `lifecycle_parts` with no visited set or cache, so a managed record with no allocating part costs one visit per field path, at each copy site. Compiling the same nesting with `string` leaves and copies took 2.3 s at depth 14 and 41 s at 18, not isolated from other walkers. Pass a visited set.

**Near copies**

- [hooks.odin:264](src/hooks.odin#L264) and [hooks.odin:316](src/hooks.odin#L316): `drop_hooks_walk` and `copy_hooks_walk` differ in the field read, the stop after a copy hook, and the zero-length check. Merge them into one walker taking the `Hook_Kind`, which also ends the difference known-gaps.md records for `[0]T`.
- [hooks.odin:166](src/hooks.odin#L166), [hooks.odin:277](src/hooks.odin#L277), [hooks.odin:330](src/hooks.odin#L330), [hooks.odin:370](src/hooks.odin#L370) and [region.odin:136](src/region.odin#L136): the same element, key, field and non-void variant dispatch. A helper `owned_parts(c, info) -> []Type_Id` reduces each walker to one loop. (about 35 lines here)
- [hooks.odin:608](src/hooks.odin#L608), [hooks.odin:687](src/hooks.odin#L687) and [hooks.odin:704](src/hooks.odin#L704): three ways to generate and add the `try_clone`/`clone` pair. With BUG-hooks-2 fixed they are identical; rename `contribute_intrinsic_copy_members` and use it at all three. (about 8 lines)
- [hooks.odin:68](src/hooks.odin#L68), [hooks.odin:749](src/hooks.odin#L749) and [hooks.odin:788](src/hooks.odin#L788): `custom_try_clone != INVALID_SYMBOL || container || boxed` three times, and `clone_may_allocate` nearly repeats `type_clone_is_fallible`. Name the predicate, and drop the second recursion with its test-only caller.
- [hooks.odin:1106](src/hooks.odin#L1106), [hooks.odin:1138](src/hooks.odin#L1138) and [attributes.odin:150](src/attributes.odin#L150): the same `file << 32 | lo` position key. Line 1138 should call `generic_hook_key`; a `span_key(span)` beside `Span` would serve all three.
- [hooks.odin:928](src/hooks.odin#L928) and [hooks.odin:1052](src/hooks.odin#L1052): the same `L0486` message, written twice and differing only in how the type is named. Share `report_extension_hook(k, span, type_text, role)`.

**Structure and boundaries**

- [hooks.odin:430](src/hooks.odin#L430): transfer facts (lines 430-567) concern what crosses threads, not lifecycles, and their readers are `borrow.odin` and `cfg_provenance.odin`. Move them to their own file. The header at line 1 does not mention them.
- [hooks.odin:843](src/hooks.odin#L843): declaration validation (lines 843-1260, a third of the file) touches classification only through `type_clone_disabled` and `default_allocator_arg`, both already public. It is a natural separate file, `hook_validation.odin`.
- [hooks.odin:1152](src/hooks.odin#L1152) `check_copy_decision`: 108 lines doing two jobs. Seams: gathering written hooks (lines 1174-1223, returning a small struct, with one reader for templates and one for declared records), and `@(fieldwise_copy)` misuse (lines 1225-1246).
- [hooks.odin:894](src/hooks.odin#L894) `validate_semantic_hook`: 104 lines with three stages. Seams: whether a hook may be declared on this subject (lines 902-941), the duplicate check (lines 942-970), and the role's shape (lines 971-996).

**Comments**

- [hooks.odin:1](src/hooks.odin#L1): the signatures repeat lines 1004 and 1007 and the default sentence repeats line 1021. Shorten to the first sentence with its citation. (about 6 lines)
- [hooks.odin:432](src/hooks.odin#L432): the 20-line block describes each field in prose. Move each sentence, with its citation, onto the field in `Transfer_Facts`, and drop the restated names. (about 6 lines)
- [hooks.odin:594](src/hooks.odin#L594): `design.md "Distinct types": a copyable `distinct` name has its own pair, typed in the name; the lifecycle entry stays the underlying type's.` (about 2 lines)
- [hooks.odin:710](src/hooks.odin#L710): repeats line 79. Shorten to `Emission indexes these; `lifecycle_parts` keeps one array element.` (about 1 line)
- [hooks.odin:769](src/hooks.odin#L769): delete; line 25 already says it.
- [hooks.odin:781](src/hooks.odin#L781): omits the box the code tests, and narrates the loop. Delete, or keep only `A generated clone fails when some part's can.`
- [hooks.odin:845](src/hooks.odin#L845): delete; it restates the name and the first lines of the body.
- [hooks.odin:893](src/hooks.odin#L893): covers only part of the procedure, which also checks the subject and duplicates. `Checked where each inherent declaration is written.`

### src/impl.odin

A compact file with mostly useful comments, and member-table scans that stay small enough to leave alone. Its weak points are that the generic copy of member declaration has drifted from it, and that hook and `where`-exclusion lookups skip paths the ordinary lookup covers. Every bug below was reproduced with `lokec.exe` built at this commit.

**Bugs**

- `BUG-impl-1` **medium** [impl.odin:622](src/impl.odin#L622) `conversion_hooks`: ignores `bound_excluded`, unlike `member_is_visible` and every other reader. Scenario: `impl V($T) { from_int :: hook(convert) proc(v: int) -> V(T) where T == int {...} }` with `V(string)(3)` stops with L0405 "internal backend contract violation"; an added unbound `i8` hook makes it L0391 ambiguous, naming the excluded hook. Fix: add `&& !sym.bound_excluded`. *Confirmed: Reproduced: V(string)(3) with a `where T == int` convert hook exits 2 with L0405; adding an unbound i8 hook gives L0391 naming from_int. design.md "where clauses" says lookup cannot find an excluded method; V(int)(3) compiles. No record found; medium is fair.*
- `BUG-impl-2` **medium** [impl.odin:93](src/impl.odin#L93) `check_local_impl`: returns silently when the subject does not resolve, since `resolve_type_syntax` reports nothing for these. Scenario: `main :: proc() { x := 1; impl x { f :: proc() { undefined_thing(); } } }` and `impl nope { }` both compile and run, while file scope reports L0406. Fix: the `error_count` guard from lines 53-55, in a helper both paths share. *Confirmed: Reproduced: body-local `impl x {f :: proc() {undefined_thing();}}` and `impl nope {}` exit 0 and run, members unchecked; file scope gives L0406. grammar.md requires a subject declared in this body; no gap or decision is recorded.*
- `BUG-impl-3` **medium** [impl.odin:456](src/impl.odin#L456) `excluded_member`: scans only `info.members`, so a failed bound on a generic extension is not seen. Scenario: `impl Option($T) { f :: proc(self, x: int) -> int where T == int {...}; g :: proc(self, x: string) -> int {...}; h :: proc{f, g}; }` on `Option(string)` is L0395 at [overload.odin:79](src/overload.odin#L79), and an inherent block compiles; `o.f()` also loses its note. Fix: also scan `pkg.extensions[type]` for `lookup_package(k)`. *Confirmed: Reproduced: extension impl Option($T) group on Option(string) gives L0395, and o.f(1) gives L0363 with no note; the same code on an inherent Box($T) compiles and gets the note. design.md "where clauses" requires both; Option(int) compiles. Medium is fair.*
- `BUG-impl-4` **medium** [impl.odin:193](src/impl.odin#L193) `declare_impl_member`: reports L0406 for a non-constant member, but its generic copy at [generic.odin:3656](src/generic.odin#L3656) skips one silently. Scenario: `impl G($T) { x: int = 0; }` compiles and `x` is dropped; `impl G { x: int = 0; }` is L0406. Fix: report it for the generic block once, in `check_generic_impl_subject` or registration. *Confirmed: Reproduced: impl G($T) { x: int = 0; } builds and runs (rc 0, prints 7) with G(int) instantiated, and g.x then gives L0363; the non-generic impl G gives L0406. generic.odin:3656 skips non-Const silently; no gap is recorded. Accepts-invalid, so low-medium.*
- `BUG-impl-5` **low** [impl.odin:231](src/impl.odin#L231) `declare_impl_member`: the built-in member check has no counterpart in the generic copy ([generic.odin:3685](src/generic.odin#L3685)). Scenario: `impl U($T) { as :: proc(self) -> int {...} }` on a generic union is accepted, and `u.as(.a)` reaches the built-in, so the member is unreachable; the non-generic form is L0409. Fix: share the clash check (see Near copies). *Not verified.*
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
- [impl.odin:549](src/impl.odin#L549) `expand_visible_members`: the `sig_state` test repeats the guard inside `resolve_symbol_signature_in_place` ([check.odin:852](src/check.odin#L852)), so call it unconditionally. (about 2 lines)

**Dead code**

- (branch) [impl.odin:195](src/impl.odin#L195): assigning an empty `d.symbols` does nothing, since every reader uses `len` or `for` and a repeat declaration is barred by `item.declared`.

**Near copies**

- [impl.odin:209](src/impl.odin#L209) and [generic.odin:3677](src/generic.odin#L3677): duplicate and field checks, plus the `Symbol` literal at [impl.odin:240](src/impl.odin#L240) and [generic.odin:3693](src/generic.odin#L3693), differ only in `pkg` and subject. Share `impl_member_clash(k, subject, name)` and `new_impl_member(k, d, name, subject, pkg)`, which also ends the drift in BUG-impl-5. (about 25 lines)
- [impl.odin:68](src/impl.odin#L68) and [impl.odin:136](src/impl.odin#L136): the same make, read table, declare, install sequence, one filtered to lifecycle hooks. Share `declare_impl_members(k, item, hooks_only := false)`. (about 6 lines)
- [impl.odin:301](src/impl.odin#L301) and [semantic.odin:1120](src/semantic.odin#L1120): the same three lines concatenate two member slices. Share one helper taking both slices.

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

The satisfaction path is sound for ordinary programs, but the composition walks disagree on scope, grant context and recursion guard; every bug below was reproduced with `lokec.exe` built at this commit. Most of the shortening is in failure construction and three copies of the composed-application loop.

**Bugs**

- `BUG-interface-1` **medium** [interface.odin:646](src/interface.odin#L646) `check_one_requirement`: a composition's `bound_arguments` runs before the `mark` at line 677, so its errors stay, and `report = false` gates only some of them. Scenario: `Outer :: interface($T: type) { Inner(T, T.N); }`, then `static_assert(!Outer(int))` gives L0408, not false; `Callable(C, proc(n: C.Arg) -> int)` gives L0306. Fix: mark and truncate inside `bound_arguments`, always quiet. *Confirmed: Reproduced: Val(T, T.N) with `$N: int` gives L0408, even in `when (Outer(T))`, where plain `T.N -> int` is false; Callable(C, proc(n: C.Arg) -> int) gives L0306. A `$U: type` Inner correctly gives false. design.md says an application may simply produce false.*
- `BUG-interface-2` **medium** [interface.odin:1308](src/interface.odin#L1308) `interface_names_constant`: looks up composed callee names in the caller's `k.scope`, not the interface's. Scenario: `shape.Outer` composes `Measured(T)` by its local name; `where shape.Outer(T)` in `main` then rejects `T.Unit` with L0306 though the bound holds. Fix: enter `info.scope` for the walk, as `add_slot_owners` does. *Confirmed: Reproduced: where shape.Outer(T) gives L0306 on T.Unit; shape.Measured(T) runs and static_assert(shape.Outer(Rod)) holds. A same-named Measured in main makes it compile, so lookup uses the caller's scope. Violates design.md "Interface bodies". Medium fits.*
- `BUG-interface-3` **medium** [interface.odin:1369](src/interface.odin#L1369) `application_constant`: recursion on composed applications has no guard; `grant_depth` counts only entries through `required_associated_constant`. Scenario: `A :: interface($T: type) { T.X -> type; A(T); }` with `static_assert(!A(int))` overflows the stack (0xC00000FD). Fix: a depth limit or visited set. *Confirmed: Reproduced: the scenario and an A->B->A cycle exit 0xC00000FD; with no T.X, a found X, or no cycle, the same probe exits 0, so the unguarded line 1369 path is the cause. Severity is low to medium: a crash on an unusual program, no miscompile.*
- `BUG-interface-4` **medium** [interface.odin:1226](src/interface.odin#L1226) `required_slot_candidates`: a bound not yet evaluated reaches the unguarded `interface_slots`. Scenario: `A :: interface($T: type) { A(T); }` and `f :: proc(x: $T) -> int where T.q == 1, A(T)`, called, overflows the stack. Fix: bound the recursion in `interface_slots` ([erased.odin:722](src/erased.odin#L722)). *Confirmed: Reproduced: the probe with where T.q == 1, A(T) exits 0xC00000FD, while where A(T) or A(T), T.q == 1 gives L0444 "composes itself". interface_slots has no depth guard. Unrecorded; only invalid programs hit it, so medium is a bit high.*
- `BUG-interface-5` **low** [interface.odin:1215](src/interface.odin#L1215) `required_slot_candidates`: `args[0].type == type` blocks `Callable` composed on another subject, against `composed_callable`'s own subject test and design.md "Interface bodies". Scenario: `Has_Fn(T)` composing `Callable(T.Fn, sig)` gives "`f` is not callable" on a `T.Fn`; a direct `Callable(T.Fn, sig)` bound compiles. Fix: drop that test. *Not verified.*
- `BUG-interface-6` **low** [interface.odin:1388](src/interface.odin#L1388) `composed_callable`: omits `k.body = {requiring = info, requiring_args = args}`, which `application_constant` and `interface_slots` set. Scenario: `C.Arg -> type; Callable(C, proc(n: C.Arg) -> int);` where `Arg` is private on an unexported type: the bound holds, then `f(7)` in the body fails with L0306. Fix: set it. *Not verified.*
- `BUG-interface-7` **low** [interface.odin:506](src/interface.odin#L506) `interface_check`: the depth cap bounds depth but not breadth, and non-composition requirements do not stop at the first failure. Scenario: `Bad :: interface($T: type) { Bad(T) || Bad(T); }` with `static_assert(!Bad(int))` runs about 2^32 checks; still running after 25 s. Fix: an in-progress set of (interface, args) that fails on re-entry. *Not verified.*
- `BUG-interface-8` **low** [interface.odin:1294](src/interface.odin#L1294) `interface_names_constant`: revisits interfaces with only a depth limit, unlike `add_slot_owners`. Scenario: `A` has `T.Missing == 1; B(T); B(T);` and `B` has `A(T); A(T);`: `static_assert(!A(int))` still runs after 25 s (without the `T.Missing` line it returns at once). Fix: a visited set in place of `depth`. *Not verified.*
- `BUG-interface-9` **low** [interface.odin:1465](src/interface.odin#L1465) `slot_matches`: never compares the slot's written convention, which `slot_signature` drops, though design.md "Interface bodies" says it must match exactly. Scenario: `slot f: proc "c" (self) -> int;` is met by a Loke-convention `f`, so `I(S)` is true. Fix: reject a convention at declaration, or carry it into the match. *Not verified.*
- `BUG-interface-10` **low** [interface.odin:128](src/interface.odin#L128) `check_interface_declaration`: tests only the name `self`, though design.md "Interface bodies" requires a receiver mode and says a pointer merely named `self` is not one. Scenario: `slot f: proc(self: int) -> int;` in `interface($T: type)` draws no L0442 and is silently false. Fix: also require the absent or subject type. *Not verified.*

**Simplification**

- [interface.odin:610](src/interface.odin#L610) `Requirement_Failure` literals: the 10 `{span, fmt.aprintf(..., allocator = ...)}` blocks at 610, 704, 736, 748, 762, 812, 825, 842, 1030, 1106 become `return requirement_failuref(k, span, "...", args)`; `return {}, true` replaces the rest. (about 45 lines)
- [interface.odin:232](src/interface.odin#L232) `interface_arguments_for`: nine parameters encode one choice. `first`, `erased_subject`, `code` and `description` all follow from a `dyn_view: bool`; `out` is always a fresh `len(written)` slice, so allocate it here. (about 10 lines)
- [interface.odin:867](src/interface.odin#L867) `call_method_matches`: `call_effects_match` (952) and `call_escapes_weaken_to` (978) have this one caller and each loop over the same parameters with the same `index + 1` offset; fold both into the loop at 878. (about 15 lines)
- [interface.odin:1463](src/interface.odin#L1463) `slot_matches`: `Maybe(bool)` exists only for [erased.odin:898](src/erased.odin#L898), whose caller discards the value at [erased.odin:802](src/erased.odin#L802) after satisfaction already compared it. Pass it and take a plain `bool`. (about 3 lines)
- [interface.odin:1476](src/interface.odin#L1476) `slot_matches`: `proc_parameter_mode(k.c, sym.proc_type, index)` is this expression, as line 874 already uses. (about 1 line)
- [interface.odin:249](src/interface.odin#L249) `interface_arguments_for`: `interface_scope(k, info, nil)` is the same scope. (about 1 line)
- [interface.odin:1263](src/interface.odin#L1263) `required_associated_constant`: the empty test before the loop does nothing the loop does not. (about 3 lines)
- [interface.odin:553](src/interface.odin#L553) `interface_check`: `declared != nil && declared.decl != nil` holds for any `info`, since `interface_info_for` returned one. (about 2 lines)

**Dead code**

- (branch) [interface.odin:501](src/interface.odin#L501): `span` in `interface_check` and `check_one_requirement` (636) is only forwarded to each other, never read; `failed_bound_text` computes one at 447 for nothing.
- (branch) [interface.odin:634](src/interface.odin#L634): `scope` in `check_one_requirement` always equals `k.scope`, set at 539.
- (branch) [interface.odin:1362](src/interface.odin#L1362): `is_call` here and at 1402 cannot fail: `composed_interface_of` has already seen an `Expr_Call`, and a clone keeps its kind.
- (branch) [interface.odin:503](src/interface.odin#L503): the argument-count guards here, at 573 and at 1321 cannot fire: arguments come from `bound_arguments`, `interface_arguments` or `interface_application`, which all fix the length.
- (branch) [interface.odin:243](src/interface.odin#L243): this guard and the one at 251 cannot fire: all three callers check the length and size `out` first, and the only `first > 0` caller passes `TYPE_RAWPTR`.

**Data structures and algorithms**

- [interface.odin:406](src/interface.odin#L406) `interface_satisfied`: no memo, so every evaluation clones all requirements and appends to `pending_private_reads` (554, once per composed level); both grow with applications, not interfaces. A cache on (interface, args, lookup package) would also serve BUG-interface-7. Not measured.

**Near copies**

- [interface.odin:1352](src/interface.odin#L1352), [interface.odin:1392](src/interface.odin#L1392) and [erased.odin:747](src/erased.odin#L747): the same steps from requirement to `composed`, clone and `bound_arguments`. Share `composed_application(k, requirement) -> (^Interface_Info, []Generic_Arg, bool)`.
- [interface.odin:583](src/interface.odin#L583), [interface.odin:1326](src/interface.odin#L1326), [interface.odin:1388](src/interface.odin#L1388) and [erased.odin:725](src/erased.odin#L725): identical entry into an interface's scope, package and file. Share `enter_interface(k, info, args)` after saving `k.location`.
- [interface.odin:312](src/interface.odin#L312), [interface.odin:347](src/interface.odin#L347) and [generic.odin:3070](src/generic.odin#L3070): the enum, `convert_const` and `nil_converts` test. Find the value and its type once, then call a shared `convert_generic_value`; `report_unrepresentable_argument` goes.
- [interface.odin:594](src/interface.odin#L594) and [interface.odin:677](src/interface.odin#L677): check, capture the first message, truncate. Share `captured_reason(k, mark, fallback)` using `errors_since`. Also [interface.odin:610](src/interface.odin#L610) and [interface.odin:704](src/interface.odin#L704): the same "evaluates to false" failure.
- [interface.odin:903](src/interface.odin#L903) and [interface.odin:929](src/interface.odin#L929): the same walk over `call` methods. One `callable_method_results(k, type) -> (result, conflicting)` serves both `ensure_callable_result_member` and the note.
- [interface.odin:1018](src/interface.odin#L1018) and [erased.odin:893](src/erased.odin#L893): both loop over candidates, filter for a method, and test `slot_matches`. With a plain-`bool` `result_inout`, `check_slot_requirement` can call `find_witness_slot`, moved here.
- [interface.odin:211](src/interface.odin#L211) and [interface.odin:381](src/interface.odin#L381): the same call apart from reporting the arity. `check_interface_application` can report the arity itself and share one proc.
- [interface.odin:420](src/interface.odin#L420) and [interface.odin:448](src/interface.odin#L448): the same subject choice and "does not satisfy" headline. `failed_bound_text` can format what `report_interface_failure` passes to `errorf`.
- [interface.odin:477](src/interface.odin#L477) and [erased.odin:442](src/erased.odin#L442): both write `I(a, b)`, one by `concat`, one by builder. `dyn_display_name` can call `interface_application_text` if that omits empty parentheses.
- [interface.odin:465](src/interface.odin#L465), [interface.odin:644](src/interface.odin#L644), [interface.odin:1200](src/interface.odin#L1200), [interface.odin:1268](src/interface.odin#L1268) and [erased.odin:620](src/erased.odin#L620): an expression, its call, its interface. Share `interface_call_of(k, expr) -> (^Expr_Call, ^Interface_Info)`.
- [interface.odin:1151](src/interface.odin#L1151), [interface.odin:1089](src/interface.odin#L1089), [impl.odin:549](src/impl.odin#L549) and [impl.odin:618](src/impl.odin#L618): resolve an unchecked signature and refetch the symbol. Share `member_with_signature(k, member, subject) -> ^Symbol`.

**Structure and boundaries**

- [erased.odin:402](src/erased.odin#L402): `interface_scope`, `interface_application` (390), `composed_interface_of` (620) and `interface_slots` (722) are not about erasure, and this file calls them throughout. They belong here, leaving erased.odin views and witnesses.
- [interface.odin:232](src/interface.odin#L232) `interface_arguments_for` (135 lines) and [interface.odin:630](src/interface.odin#L630) `check_one_requirement` (143 lines): seams are the constant argument at 308-357, and the bindings at 659 and result checks at 720-771.
- [interface.odin:774](src/interface.odin#L774): `Callable` (774-986) and the grants (1166-1414) sit under the "satisfaction" banner, and the map in compiler-architecture.md "Source-code map" names neither. Give each a banner and a mention, and move `composed_callable` beside `Callable`.

**Comments**

- [interface.odin:799](src/interface.odin#L799): `// standard-library.md "Standard interface catalogue". A field named `call` is not a method.` Likewise cut 863-866 and 887-890 to the citation plus what the catalogue does not say. (about 6 lines)
- [interface.odin:1245](src/interface.odin#L1245): `// design.md "Interface bodies": the associated constant `type.name` that the application being checked, or a bare bound of this declaration, requires. Ordinary lookup has already failed.` (about 3 lines)
- [interface.odin:1041](src/interface.odin#L1041): `// A slot's candidates (design.md "Interface bodies"), shared with witness construction so `dyn` selects what satisfaction promised.` The middle restates the spec. (about 2 lines)
- [interface.odin:946](src/interface.odin#L946): this block and 974-976 go with the merge into `call_method_matches`, leaving the two citations on the checks. (about 6 lines)
- [interface.odin:518](src/interface.odin#L518): "Each requirement rolls back its own diagnostics" is untrue of composition until BUG-interface-1 is fixed; line 683 narrates the code, so delete it.
- [interface.odin:209](src/interface.odin#L209): delete; it restates the signature, as does line 81. (about 2 lines)

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

The value-loop path is sound for elements but mishandles parts a traversal owns: probes returned dangling pointers or crashed from safe code. Beyond that the file is readable but repetitive, with seven hand-written struct constructors and a place-loop checker that repeats the common path.

**Bugs**

- `BUG-iterate-1` **high** [iterate.odin:856](src/iterate.odin#L856) `check_foreach_body`: built-in loops bind with the default `Borrowed`, ignoring the exact desc from `foreach_record_yield`, so the `indexed()` counter is "lent". *Confirmed: Reproduced: returning &i from foreach over xs.indexed() compiles and later reads garbage (2, then 140694871556112); a range's &x gets L0526, not L0513. move(i) gets L0690, though design.md says indexed() owns its counter; over a range it compiles.*
  Scenario: `foreach (x, i in xs.indexed()) { return &i; }` compiles and prints garbage (a range's `&x` gets L0513); `move(i)` gets L0690. Fix: pass that desc to the pattern.
- `BUG-iterate-2` **high** [iterate.odin:172](src/iterate.odin#L172) `array_iterator_type`: `public = true` lets safe code write the cursor (also [148](src/iterate.odin#L148), [195](src/iterate.odin#L195)); `next` tests only `index < len`. *Confirmed: Probes with no unsafe: it.index = -4000000 then it.next() segfaults on arrays and slices; index = -1 reads garbage. next tests only index < bound. Not recorded in the docs. Map cursor probes returned none, and range fields hold no pointer, so only array iterators reproduce.*
  Scenario: `it := x.iter(); it.index = -4000000; it.next()` then `p^` segfaults. Fix: make these fields private like the text and map-view iterators; a grep of tests and core found no reader.
- `BUG-iterate-3` **high** [iterate.odin:990](src/iterate.odin#L990) `bind_pattern_leaf`: a single name bound to the projected record (`bound == item`) is marked lent, yet that record is a per-step slot, not source storage. *Confirmed: `foreach (e in xs.indexed()) { return &e; }` compiles; after another call p^.index printed 140696012795928 and p^.value^ segfaulted. The same return over `.copied()` gets L0526. `return &entry` over a map also compiles. No recorded gap or decision.*
  Scenario: `foreach (e in xs.indexed()) { return &e; }` and `p = .some(&entry)` over a map compile, leaving a dangling pointer. Fix: treat a leaf with `bound == item` as owned.
- `BUG-iterate-4` **medium** [iterate.odin:891](src/iterate.odin#L891) `check_foreach_pattern`: `!foreach_is_place_loop(s)` skips the hooked-destructure check for an owned part of a mutable traversal. *Confirmed: Reproduced: foreach ((p, q), &mut c in t) over an owned hooked part compiles and never prints the hook(drop) line; binding the part whole does run it, and the same split in a value loop gets L0508. design.md "Destructuring" forbids it; no recorded gap.*
  Scenario: `foreach ((p, q), &mut c in t)` with an owned `h: Hooked` part compiles and `hook(drop)` never runs; the value loop gets L0508. Fix: drop that condition.
- `BUG-iterate-5` **medium** [iterate.odin:990](src/iterate.odin#L990) `bind_pattern_leaf`: `!foreach_is_place_loop(s) &&` makes every place-loop leaf lent, against design.md "Element bindings" and the comment at line 974. *Confirmed: Probe a: foreach (&mut a, s in t) with s owned by next gives L0690 on move(s); the same record lent read-only (probe c) compiles and runs. No recorded decision. Drop still runs once (probe e), so only valid moves are rejected, as is move(i) of an indexed() counter.*
  Scenario: `foreach (&mut a, s in t) { take(move(s)); }` with `next` handing `s` over owned gets L0690. Fix: `owned := part.kind == .Owned || (!place && !s.borrows)`.
- `BUG-iterate-7` **low** [iterate.odin:654](src/iterate.odin#L654) `check_adapter_applies`: rejects `reversed()` over a map or text even when the program supplies the `iter_reverse` that design.md "Iteration adapters" asks for. *Not verified.*
  Scenario: `impl M { iter_reverse :: proc(self: ^) -> M.Iterator {...} }`, `foreach (e in t.reversed())` gets L0460. Fix: do not peel `reversed()` there, so it takes the protocol path.
- `BUG-iterate-8` **low** [iterate.odin:1024](src/iterate.odin#L1024) `report_pattern_arity`: a non-record element reports a nonsense count. *Not verified.*
  Scenario: `foreach (a, b in ints)` prints "`int` has 0 fields, so this `foreach` pattern needs 1 or 0 parts, not 2". Fix: use `destructure_fields`' "is not a record" wording (see Simplification).
- `BUG-iterate-9` **low** [iterate.odin:908](src/iterate.odin#L908) `check_foreach_pattern`: indexes `desc.fields` by binding position, while `desc` and the emitter's `bind_foreach_pattern` count slots including padding. *Not verified.*
  Scenario: latent; a padded record `Item` cannot be spelled today, since `yield_of` compares the padding's names. Once it can, the wrong part's mode applies. Fix: `desc.fields[slot]`.

**Simplification**

- [iterate.odin:721](src/iterate.odin#L721) `check_range_foreach`: delete it and the branch at line 510. In the `info.is_range` arm set `s.kind` to `.Range` or `.Stored_Range` by the expr's form; the rest of the path is identical, and a peeled range is no longer checked twice. (about 20 lines)
- [iterate.odin:665](src/iterate.odin#L665) `check_place_foreach`: join `.Map` with `.Array, .Dynamic` for the one assignable check, and replace both tails with `s.element_type = foreach_element_type(...)`, one `gate_type` and one pattern call. Use `#partial switch`. (about 15 lines)
- [iterate.odin:881](src/iterate.odin#L881) `check_foreach_pattern`: delete the arity check and `report_pattern_arity`; `destructure_fields` at line 885 already reports non-records and wrong counts under the same L0459. Keep only the "never invents an index" note, added on failure. (about 15 lines)
- [iterate.odin:917](src/iterate.odin#L917) `check_foreach_pattern`: the group and leaf dispatch repeats lines 869-878. Replace lines 917-925 with one recursive call on `bindings[index:index+1]`. (about 6 lines)
- [iterate.odin:835](src/iterate.odin#L835) `check_foreach_body`: inline `foreach_lends_elements` and `foreach_builds_lent_record` into one `if s.kind != .Protocol` block that sets `s.borrows`, `yield` and `s.item_type` together, which also fixes BUG-iterate-1. (about 12 lines)
- [iterate.odin:59](src/iterate.odin#L59) `range_type` and six siblings: `new_type` only clones its argument, so build `fields` and the label first and pass them in the `Type_Info` literal, dropping each `if info := type_of(...); info != nil` block (also at lines 152, 175, 197, 237, 260, 281). (about 20 lines)
- [iterate.odin:300](src/iterate.odin#L300) `ensure_iteration_members`: start with `element := info.element` and drop five arm assignments; drop `lends_halves` by naming `.Map_Keys_Next, .Map_Values_Next` at line 368. (about 8 lines)
- [iterate.odin:798](src/iterate.odin#L798) `check_protocol_foreach`: the `effective_*` copies add nothing; reassign `yield`, `element` and `item` inside `if s.indexed`. (about 5 lines)
- [iterate.odin:679](src/iterate.odin#L679) `check_place_foreach`: lines 679, 716, 856 and [iteration_mutable.odin:114](src/iteration_mutable.odin#L114) all pass `s.bindings, s.element_type, foreach_packed_source(k, s)` and then call `check_foreach_block`. One helper taking `item` and `desc` folds them. (about 4 lines)
- [iterate.odin:993](src/iterate.odin#L993) `bind_pattern_leaf`: `!owned` is implied by `binding.is_ref`, which makes the loop a place loop; write `packed != "" && binding.is_ref`. (1 line)
- [iterate.odin:163](src/iterate.odin#L163) `array_iterator_type`: only the slice arm omits `holds`; have it pass `under` and drop the default and `stored`. (about 2 lines)

**Dead code**

- (branch) [iterate.odin:601](src/iterate.odin#L601): `foreach_lends_elements` never sees a place loop; its only caller, `check_foreach_body`, is reached only after all three paths have dispatched place loops elsewhere.
- (branch) [iterate.odin:669](src/iterate.odin#L669): `indexed()` over a map in a place loop is unreachable. A map's `iter_mut` takes `inout`, so its adapter has no `iter_mut`, `peel_resolved_adapter` stops, and the protocol path reports it (probed). No test holds this message.
- (branch) [iterate.odin:694](src/iterate.odin#L694): `.Range` never reaches `check_place_foreach`, since line 510 returns first; only `.Stored_Range` does.
- (branch) [iterate.odin:708](src/iterate.odin#L708): `.Unresolved, .Static, .Protocol` cannot occur here; the same holds for `.None` at lines 217 and 359. They exist only for exhaustiveness; use `#partial switch`.
- (branch) [iterate.odin:595](src/iterate.odin#L595): the `ref_span` fallback is unreachable, because every caller runs on a place loop, so `first_ref_binding` finds a leaf.
- (branch) [iterate.odin:908](src/iterate.odin#L908): `index < len(desc.fields)` is always true; `yield_item_type` already required `len(desc.fields) == len(info.fields)`, and bindings equal the named fields.
- (branch) [iterate.odin:1057](src/iterate.odin#L1057): `bind_loop_name`'s `mutable` is always `binding.is_ref`, and `borrows`' default is never used. `binding.is_ref ||` at line 1084 is implied too. Take `(k, binding, type, borrows)`.
- (branch) [iterate.odin:867](src/iterate.odin#L867): the `packed := ""` defaults here and at line 979 are never used; every call passes `packed`.
- (branch) [iterate.odin:402](src/iterate.odin#L402): `sym != nil` right after `synth_proc`, here and at line 415, cannot fail; so too `field == nil` at line 898 on a field `destructure_fields` just returned.

**Near copies**

- [iterate.odin:49](src/iterate.odin#L49) and [iteration_mutable.odin:41](src/iteration_mutable.odin#L41), [container.odin:313](src/container.odin#L313): name, `new_type`, fields, label. Share `new_compiler_struct(c, proto, name, label, ..fields)`; about 30 lines here on top of the literal change.
- [iterate.odin:68](src/iterate.odin#L68), [simd.odin:15](src/simd.odin#L15) and [box.odin:45](src/box.odin#L45): identical apart from the name. Share `predeclared_callee(k, callee, "Range")`.
- [iterate.odin:614](src/iterate.odin#L614) and [iterate.odin:957](src/iterate.odin#L957): the yield builders differ only in the stored part's kind. Share `builtin_yield(k, s, stored: Yield_Kind)`, and with it the `indexed()` wrap also at line 801 and [iteration_mutable.odin:100](src/iteration_mutable.odin#L100).
- [iterate.odin:90](src/iterate.odin#L90) and [iterate.odin:1111](src/iterate.odin#L1111): the same endpoint test and L0458 text, differing only in span. Share `require_range_endpoint(k, type, span) -> bool`.
- [iterate.odin:1064](src/iterate.odin#L1064), [optional.odin:607](src/optional.odin#L607) and [check.odin:560](src/check.odin#L560): the L0304, reserved-name and L0305 checks for a new local. Share one proc taking the identifier, span and shadow-lookup scope.

**Structure and boundaries**

- [iterate.odin:293](src/iterate.odin#L293) `ensure_iteration_members`: 115 lines doing two jobs. The seam is line 365: a `switch` choosing element, iterator and kinds, then installing members. Return the choice in a small struct from a separate proc.
- [iterate.odin:492](src/iterate.odin#L492): the file holds type constructors and contributions (lines 47-490) and the `foreach` checker and binder (492-1088). The checker could be its own file next to `iteration_mutable.odin`, whose foreach path shares its binder.
- [iterate.odin:1094](src/iterate.odin#L1094): `check_range` and `unify_range_endpoints` sit at the far end from `range_type` and `resolve_range_application` (lines 49-103), though all are the same concern. Keep them together.
- [iterate.odin:130](src/iterate.odin#L130): `rune_offset_type`, `foreach_lends_elements`, `place_loop_yield` and `bind_loop_name` are used only in this file, so `compiler-architecture.md` "Source-code map" wants them file-private.

**Comments**

- [iterate.odin:323](src/iterate.odin#L323): stale; an array's `next` is usually `.Slice_Ref_Next` too. Write "An array's `iter`, holding the slice itself."
- [iterate.odin:333](src/iterate.odin#L333): delete; `map_entry_type` on the next line says it.
- [iterate.odin:576](src/iterate.odin#L576): delete; the name and body say it. Likewise line 930.
- [iterate.odin:855](src/iterate.odin#L855): delete; misleading, since the call does reach the `&mut` leaf check and nothing near it depends on the claim.
- [iterate.odin:972](src/iterate.odin#L972): the "except a part `next` hands over owned" sentence is not what line 990 does for a place loop; keep it and fix the code (BUG-iterate-5).
- [iterate.odin:1027](src/iterate.odin#L1027): keep only `// design.md "Element bindings"`; the note below states the rest. (about 8 lines across the file)

### src/lifecycle.odin

The dataflow core is sound and the file is readable, but `exchange` lets an owned place through unmoved (a heap-corrupting double free) and unwind paths do not vote on deferred assignments. Much of the rest is repeated error plumbing, and the file holds four loosely related jobs.

**Bugs**

- `BUG-lifecycle-1` **high** [lifecycle.odin:194](src/lifecycle.odin#L194) `check_exchange_builtin`: a place replacement is neither rejected nor classified, and `emit_exchange` stores its bits, against design.md "Exchange" ("must use `move(source)`"). Scenario: `a, b: [dynamic]int; b.append(1); old := exchange(inout a, b);` compiles and dies with STATUS_HEAP_CORRUPTION; a move-only `b` drops twice. Fix: after line 194, report L0501 for a managed place replacement. *Confirmed: Reproduced: exchange(inout a, b) on [dynamic]int compiles, then exits 0xC0000374; a move-only Res prints drop 2 twice, while a = b gives L0503. No classify_copy on the replacement and no known-gaps entry; high is fair.*
- `BUG-lifecycle-2` **medium** [lifecycle.odin:1043](src/lifecycle.odin#L1043) `report_events`: an unwind block skips the `.Assign` case, so a deferred assignment's `destination_live` omits unwind expansions, though line 1074 says it joins every expansion. Scenario: `x := Res{1}; defer x = Res{3}; may_panic(true); drop(x);` overwrites `Res{1}` on the unwind and its hook never runs (run: only `drop 3`). Fix: record the destination vote before the unwind `continue`. *Confirmed: Reproduced: the scenario prints only `drop 3` on panic, and Res{1}'s hook never runs; without drop(x) it prints drop 1, drop 3. Report_events skips .Assign in unwind blocks. Not in known-gaps or open-questions. Leak is panic-path only, so medium is at most fair.*
- `BUG-lifecycle-3` **low** [lifecycle.odin:805](src/lifecycle.odin#L805) `report_copy_cost`: `clone_may_allocate` ignores `@(move_only)`, and `classify_copy_cost` and `classify_destructure` (line 685) report before L0503. Scenario: `Box2{o = a}` with a move-only `a` holding a `[dynamic]int` warns "write `a.clone()`" beside the error saying it cannot be copied. Fix: return from `report_copy_cost` for a `type_clone_disabled` type, after setting `copied_as`. *Not verified.*
- `BUG-lifecycle-4` **low** [lifecycle.odin:818](src/lifecycle.odin#L818) `report_copy_cost`: the byte check also measures `string` and `Shared(T)`, which design.md "Copy-cost diagnostics" and the comment at line 793 say are not costly. Scenario: under `-copy-cost=8`, `t := s` with `s: Shared(int)` warns "copies 8 bytes" and advises a `Shared(T)`; `b := a` on a string warns 24 bytes. Fix: return for those two types before line 818. *Not verified.*

**Simplification**

- [lifecycle.odin:22](src/lifecycle.odin#L22) `check_drop_builtin`, `check_forget_builtin`, `check_exchange_builtin`, `check_capacity_builtin`, `check_move`: set `v.type = INVALID_TYPE` first and assign the real type only on the success path; nothing reads `v.type` midway, so every failure block drops that line. (about 25 lines)
- [lifecycle.odin:1151](src/lifecycle.odin#L1151) `report_not_live`: pick the reason with one ternary and make one `errorf` with "`%s` cannot be %s here: %s"; the two-message `.Spawn_Result` report at line 1063 shrinks the same way. (about 14 lines)
- [lifecycle.odin:116](src/lifecycle.odin#L116) `require_lexical_owner`: the two L0690 reports differ only in the format string; use one `errorf` with a ternary. (about 7 lines)
- [lifecycle.odin:329](src/lifecycle.odin#L329) `classify_return_value`: replace lines 329-339 with `!expression_is_borrowed_place(value.expr)` plus one ident test. The only non-place with a root symbol is a constant, which behaves as a literal does. Line 357 can use `copied`. (about 6 lines)
- [lifecycle.odin:1011](src/lifecycle.odin#L1011) `states_equal`: delete it and use `slice.equal`, as `settle_last_uses` does at cfg.odin:2915. (about 9 lines)
- [lifecycle.odin:758](src/lifecycle.odin#L758) `copy_site_text`: a `[Copy_Site]string` table replaces the switch and the unreachable `return "copy"`, and the compiler still checks that every member is present. (about 4 lines)
- [lifecycle.odin:850](src/lifecycle.odin#L850) `report_allocating_copy`: three branches each issue a warning, a loop note and a hint. Compute the object text and hint, then emit one `warnf` and the notes once. (about 6 lines)
- [lifecycle.odin:913](src/lifecycle.odin#L913) `analyze_ownership`: the two `defer`s guard a single early return; `if graph != nil { ... }` followed by flush and `free_all` reads in order. (about 2 lines)
- [lifecycle.odin:1143](src/lifecycle.odin#L1143) `record_reset_liveness`: choose the map once, `table := event.call != nil ? &k.c.reset_dead : &k.c.cleanup_reset_dead`, and insert once. (about 3 lines)
- [lifecycle.odin:1181](src/lifecycle.odin#L1181) `assign_cleanup_slots`: merge the two `continue` guards and turn the last into `if sym.drop_conditional { ... }`. (about 4 lines)

**Dead code**

- (branch) [lifecycle.odin:951](src/lifecycle.odin#L951): both `mem.zero_slice(state)` calls (also line 997) are overwritten before any read, since every slot is assigned or `copy` follows. They are the only `mem.` uses, so `import "core:mem"` goes too.
- (branch) [lifecycle.odin:970](src/lifecycle.odin#L970): `if first { continue }` is unreachable. Only block 0 and successors of a visited block enter the queue, and `link` keeps `preds` and `succs` symmetric, so a dequeued block always has a visited predecessor.
- (branch) [lifecycle.odin:1131](src/lifecycle.odin#L1131): `event.reset.body == nil` cannot hold. All five `.Reset_Point` emit sites key on `graph.literal`, and `new_flow_graph` returns nil for a nil literal.
- (branch) [lifecycle.odin:581](src/lifecycle.odin#L581): `base == nil` follows `expression_is_borrowed_place`, which already implies non-nil; likewise `value == nil` at lines 548 and 575 and `value != nil` at line 613, since `expr_base(nil)` returns nil.

**Data structures and algorithms**

- [lifecycle.odin:1134](src/lifecycle.odin#L1134) `record_reset_liveness`: every point stores `dead` and `owners` lists over all tracked locals in the semantic arena. Unwind drops emit one per hooked local per panicking statement, so a body with a `defer` grows as statements x hooked x tracked, and cfg.odin:1100 only asks whether one symbol is dead; a single bool fits there. Not measured.
- [lifecycle.odin:400](src/lifecycle.odin#L400) `mark_extended_temporaries`: cfg.odin:1399 and emit_llvm_stmt.odin:49 each re-derive the same fact from settled AST into their own `map[^Expr_Base]bool`. Marking once in the lifecycle walk and storing a bool on `Expr_Base` removes both maps and both lookups by pointer.

**Near copies**

- [lifecycle.odin:1023](src/lifecycle.odin#L1023) and [lifecycle.odin:1044](src/lifecycle.odin#L1044): identical event-to-state switches, and `report_events` repeats the same writes case by case. Extract `apply_event(state, event)`, run the diagnostics only when `!block.unwind`, and apply once at the bottom of the loop. (about 14 lines)
- [lifecycle.odin:593](src/lifecycle.odin#L593), [lifecycle.odin:619](src/lifecycle.odin#L619), [lifecycle.odin:662](src/lifecycle.odin#L662) and [lifecycle.odin:695](src/lifecycle.odin#L695): the same lazy `clones` allocation and set. A `mark_clone(k, &clones, count, index)` helper replaces each. (about 8 lines)
- [lifecycle.odin:589](src/lifecycle.odin#L589), [union.odin:484](src/union.odin#L484), [optional.odin:108](src/optional.odin#L108) and [check_expr.odin:2721](src/check_expr.odin#L2721): `classify_copy_cost` then `classify_copy` with the same arguments. A `classify_costed_copy` returning the bool serves these; box and insertion differ and keep the two calls.
- [lifecycle.odin:25](src/lifecycle.odin#L25), [lifecycle.odin:47](src/lifecycle.odin#L47), [box.odin:97](src/box.odin#L97), [check_calls.odin:561](src/check_calls.odin#L561), [check_calls.odin:947](src/check_calls.odin#L947) and [enums.odin:32](src/enums.odin#L32): the same one-positional-value test. A `has_one_plain_argument(v)` predicate shortens each.
- [lifecycle.odin:38](src/lifecycle.odin#L38), [lifecycle.odin:81](src/lifecycle.odin#L81), [lifecycle.odin:199](src/lifecycle.odin#L199), [check_builtin.odin:748](src/check_builtin.odin#L748) and [box.odin:226](src/box.odin#L226): `make` a `[]Expr` then assign each slot. A variadic `bind_arguments(k, v, ..values)` makes each one line.

**Structure and boundaries**

- [lifecycle.odin:799](src/lifecycle.odin#L799) `report_copy_cost`: a proc named as a diagnostic writes `copied_as`, which provenance reads (cfg.odin:2341), and `classify_destructure` must undo it at line 703. Split out the warning half, have the destructure call only that, and delete lines 701-703.
- [lifecycle.odin:393](src/lifecycle.odin#L393): extended temporaries read neither liveness nor `Checker`, and their callers are cfg.odin and emit_llvm_stmt.odin. The section belongs with temporaries handling, not with lifecycle checking, and compiler-architecture.md "Source-code map" does not list it here.
- [lifecycle.odin:709](src/lifecycle.odin#L709) `record_static_local`: not ownership. It has one caller at check.odin:2447 and only appends to `static_locals`; move it there and drop its one-proc section.
- [lifecycle.odin:524](src/lifecycle.odin#L524): copy sites and the copy-cost report (lines 524-704 and 725-890) share only the held reports with the liveness solver (from line 892). If the file is split, this is the seam: a copy-site file and a solver file.

**Comments**

- [lifecycle.odin:727](src/lifecycle.odin#L727): the nine lines repeat the spec and list 4 of 15 sites. Use `// A point that duplicates a value instead of moving or borrowing it (design.md "Copy-cost diagnostics").` (about 8 lines)
- [lifecycle.odin:743](src/lifecycle.odin#L743): shorten to `// Inside a larger expression, where a copy is easy to miss.` (about 2 lines)
- [lifecycle.odin:939](src/lifecycle.odin#L939): delete; lines 924-926 already explain the worklist and the rest is history. (about 2 lines)
- [lifecycle.odin:1122](src/lifecycle.odin#L1122): keep why only `.Dead` unblocks a reset and why the arena is the compilation's; drop the restatement of the design text, the citation kept. (about 3 lines)
- [lifecycle.odin:551](src/lifecycle.odin#L551): `copied_type` already explains the widening at line 532; keep `// design.md "Widening by label"`. (about 1 line)
- [lifecycle.odin:375](src/lifecycle.odin#L375): inaccurate as well as long, since a `p^` place also yields INVALID_SYMBOL. Use `// The variable a place is rooted in; INVALID_SYMBOL for a temporary or through a dereference.` (about 1 line)
- [lifecycle.odin:467](src/lifecycle.odin#L467): shorten to `// The erased operand of an explicit dyn proc conversion, through identity conversions.` (about 2 lines)
- [lifecycle.odin:840](src/lifecycle.odin#L840): shorten to `// Never advise inout: it grants mutation and changes which aliases are legal (design.md).` (about 1 line)
- [lifecycle.odin:587](src/lifecycle.odin#L587): delete; lines 101, 115 and 137 likewise narrate the check or message that follows. (about 4 lines)

### src/operators.odin

Lookup and shape tables read well, but the file has real gaps at its edges: delegation misses whole classes of overloads and the built-in-priority predicates disagree with the spec on enums and SIMD (every bug below was reproduced with `lokec.exe` at this commit). The delegate section carries the most removable code: seven parameters threaded through five procedures and a predicate evaluated twice.

**Bugs**

- `BUG-operators-1` **high** [operators.odin:559](src/operators.odin#L559) `delegate_one`: `delegate(+)` on distinct text passes the built-in check, but `emit_delegated` only emits arithmetic. Scenario: `S :: distinct string; impl S { delegate(+); }` then `S("x") + S("y")` fails L0403 with invalid IR `@llvm.uadd.with.overflow.%loke.string`; `distinct string_view` too. Fix: lower concatenation, or reject it here. *Confirmed: Reproduced: delegate(+) on distinct string and string_view passes the checker, then lokec fails L0403 with invalid IR @llvm.uadd.with.overflow.%loke.string. Not recorded in the docs. Severity is overstated: it is a loud build failure, not a miscompile, so medium.*
- `BUG-operators-2` **medium** [operators.odin:639](src/operators.odin#L639) `builtin_delegation_applies_binary`: `builtin_operator_applies` has no shift case, so shifts always fail. Scenario: `Bits :: distinct u32; impl Bits { delegate(<<, >>); }` gives L0420 "`<<` is not defined for `u32`". Fix: ask `builtin_binary_defined(k, op, underlying, underlying)`, which handles shifts. *Confirmed: Probe: `Bits :: distinct u32; impl Bits { delegate(<<, >>); }` gives L0420 '<< is not defined for u32', while `u32 << u32` and delegate(&, |) compile. design.md and grammar.md allow it; builtin_operator_applies has no shift case; no gap is recorded.*
- `BUG-operators-3` **medium** [operators.odin:552](src/operators.odin#L552) `delegate_one`: the receiver filter (`params[0] == underlying`) applies to every symbol, against design.md "Delegating operators". Scenario: `delegate(in)` over `operator(in) proc(item: int, bag: Bag)` gives L0420; `f64 * V` is silently not forwarded, so `2.0 * w` gives L0392. Fix: filter on `slice.contains(sym.params, underlying)`, also at line 544. *Confirmed: Reproduced: delegate(in) over operator(in) proc(item: int, bag: Bag) gives L0420, and delegate(*) forwards V*f64 but not f64*V, so 2.0*w gives L0392. design.md "Delegating operators" substitutes in every operand; no gap is recorded.*
- `BUG-operators-4` **medium** [operators.odin:273](src/operators.odin#L273) `operator_candidates_for_receiver`: a generic template has empty `params`, so the filter drops what `mark_template_operator` recorded for lookup. Scenario: `at :: operator([]) proc(v: V($T), i: int) -> T` then `a[0]` gives L0362 "`V(int)` cannot be indexed"; `delegate(+)` over a generic `+` gives L0420. Fix: keep `sym.generic` candidates, as `operator_exists` does. *Confirmed: Reproduced: file-scope generic operator([]) gives L0362 on a[0], [:] likewise, and delegate(+) over a generic + gives L0420; the concrete twins, generic + and at(a, 0) all work. No spec rule or recorded decision excludes templates.*
- `BUG-operators-5` **medium** [operators.odin:84](src/operators.odin#L84) `mark_template_operator`: "Each instance's shape is checked when it is made" is false: the instance path (generic.odin:3127) calls only `resolve_proc_signature`, never `validate_operator_shape`. Scenario: `bad :: operator(==) proc(a, b: V($T)) -> int` is accepted and `a == b` is an `int`. Fix: validate instances of a template that has `operator` set. *Confirmed: Probe: operator(==) proc(a, b: V($T)) -> int compiles, and a == b has type int (c + 1 prints 2); the concrete form gets L0416. instantiate_procedure_signature calls only resolve_proc_signature, so the comment at line 84 is false.*
- `BUG-operators-7` **medium** [operators.odin:363](src/operators.odin#L363) `builtin_unary_defined`: it has no SIMD case, so check_expr.odin:2013 tries user overloads first, though binary operators check SIMD first (check_expr.odin:2238). Scenario: `impl Simd(f32, 4) { neg :: operator(-) proc(a: F4) -> F4 { return a; } }` makes `-a` run the overload, shadowing a built-in. Fix: answer SIMD here. *Confirmed: Probe: impl F4 operator(-)/I4 operator(~) overloads run for -a and ~i (a[0] stays 1.0), while binary a - a ignores its overload (0.0). design.md "Operator lookup": built-ins cannot be shadowed; check_unary tests SIMD after the user lookup. Not recorded.*
- `BUG-operators-8` **medium** [operators.odin:469](src/operators.odin#L469) `bind_operator_operands`: it binds a default without `substitute_caller_location`, unlike overload.odin:922. Scenario: `operator([]) proc(v: V, i: int, loc: runtime.Source_Code_Location = caller_location())`: `v[1]` on line 10 reports the declaration's line 5; the same default on a named call reports its call. Fix: pass the span and substitute. *Confirmed: Probe q.loke: v[1] on line 14 reports line 7 and procedure `at` (the declaration), while V.at(v, 1) on line 15 reports 15 and `main`. design.md "caller_location()" says each omitting call; nothing recorded. Narrow case: low-to-medium.*
- `BUG-operators-9` **medium** [operators.odin:45](src/operators.odin#L45) `resolve_operator_declaration`: never calls `apply_proc_metadata`, unlike plain procedures, groups (check.odin:915, 946) and hooks (hooks.odin:863). Scenario: `@(deprecated="no") plus :: operator(+) proc(a, b: V) -> int` then `plus(v, v)` gives no L0611, while the same on a named proc warns; `@(require_results)` is lost too. Fix: call it after the signature resolves. *Confirmed: Probe: @(deprecated) on operator(+) proc gives no L0611 on a direct call (named proc warns), and @(require_results) gives no L0612. Hooks and groups call apply_proc_metadata; operators do not. design.md calls these ordinary named procedures; no recorded gap.*
- `BUG-operators-10` **medium** [operators.odin:611](src/operators.odin#L611) `register_forwarded_operator`: the generated symbol has no `param_defaults`, so forwarding loses an optional parameter. Scenario: `at :: operator([]) proc(v: V, i: int, j: int = 7) -> int`: `v[1]` works but `W(v)[1]` after `delegate([])` gives L0392 "it takes 3 arguments, found 2". Fix: copy `source.param_defaults` to the new symbol. *Confirmed: Probe: v[1] gives 108, but w[1] on a distinct with delegate([]) gives L0392 'takes 3 arguments, found 2'; install_delegated_operator sets no param_defaults, and the spec says the overload is generated. Severity is low: a narrow case, rejected at compile time, passing the argument works.*
- `BUG-operators-11` **low** [operators.odin:461](src/operators.odin#L461) `bind_operator_operands`: `argument_rank` makes a `^T` viable for a borrowing parameter (overload.odin:338), but only the call binder dereferences it (overload.odin:908). Scenario: `add :: operator(+) proc(self: ^, o: V) -> int`, `p := &v; p + v` is selected, then fails L0310 "cannot pass `V` with `^V`". Fix: share the call binder's step. *Not verified.*
- `BUG-operators-12` **low** [operators.odin:559](src/operators.odin#L559) `delegate_one`: a distinct SIMD type counts as defining nothing, because `builtin_operator_applies` has no SIMD case. Scenario: `D :: distinct Simd(f32, 4); impl D { delegate(+); }` gives L0420 "`+` is not defined for `Simd(f32, 4)`", though design.md "Lane-wise operators" defines it. Fix: consult `simd_operator_applies`, with lowering behind it. *Not verified.*
- `BUG-operators-13` **low** [operators.odin:295](src/operators.odin#L295) `hidden_inherent_operator`: a `Proc_Group` has no `params`, so a hidden inherent group is never found. Scenario: a private `eq :: operator(==) proc{eq1, eq2}` imported and compared says "`B` holds `B`, whose inherent `==` is not `@(public)`" rather than the message a single overload gets. Fix: walk `sym.members` for a group. *Not verified.*

**Simplification**

- [operators.odin:724](src/operators.odin#L724) `operator_token`: replace the switch with a loop over lexer.odin's `operator_table`, the inverse of `operator_spelling`. All 21 spellings are in it; compound spellings then return their own kinds, which every caller's predicate already refuses. (about 40 lines)
- [operators.odin:574](src/operators.odin#L574) `builtin_delegation_applies`, `register_builtin_delegation`, `register_builtin_arity`, `builtin_delegation_applies_binary`: merge into one `delegate_builtin -> bool` that tries arity 1 and 2 and reports whether it installed any. `result := shape.boolean ? TYPE_BOOL : subject` replaces the switch at 653. (about 30 lines)
- [operators.odin:537](src/operators.odin#L537) `delegate_one` and its four callees: `k, item, kind, in_pkg, subject, underlying, symbol` is passed unchanged through five signatures. A `Delegation` struct with those fields shrinks every signature and the multi-line ones to one line. (about 12 lines)
- [operators.odin:390](src/operators.odin#L390) `form_operator_set`, `resolve_operator`: drop `among` and `operands`: make `resolve_operator` take `members`. Three of four callers pass `among` and an unused `operands`; check_expr.odin:2094 already computed the set line 393 recomputes for it at 2099. (about 6 lines, one lookup per user unary)
- [operators.odin:295](src/operators.odin#L295) `hidden_inherent_operator`: replace the length check and `applies` loop with `if !sym.delegated && !member_is_visible(k, sym) && slice.equal(sym.params, operands) { return true }`. (about 10 lines)
- [operators.odin:480](src/operators.odin#L480) `check_operator_modes`: fold into the argument loop of `bind_operator_operands`, which has the symbol and slot already, as overload.odin:915 does. The nil-sym and bounds guards go with it. (about 15 lines)
- [operators.odin:123](src/operators.odin#L123) `join_package_operators`: `Package.operators` (semantic.odin:882) needs no pointer value and only this file reads it: fetch, `make` if absent, `append_unique(&set, id)`, store back. (about 2 lines)
- [operators.odin:398](src/operators.odin#L398) `operator_viable`: a one-line wrapper over `candidates_viable(set.formed)`; call that directly at its four call sites. (about 4 lines)
- [operators.odin:608](src/operators.odin#L608) `register_forwarded_operator`: `result := substitute(source.result, underlying, subject)` is enough, since `underlying` is never `INVALID_TYPE` once `found` is non-empty. `modes` at 609 can be `shape.param_modes`, shared rather than copied. (about 3 lines)
- [operators.odin:71](src/operators.odin#L71) `resolve_operator_declaration`: `validate_operator_shape` already ignores non-procs, so the `kind == .Proc` split can become one call for the symbol and a loop over `symbol.members`, which is empty for a proc. (about 2 lines)

**Dead code**

- (branch) [operators.odin:57](src/operators.odin#L57): the second `symbol.operator = value.symbol`; line 51 set it, nothing clears it (`.operator =` occurs only in this file and no code overwrites a whole symbol), and a grown store copies it.
- (branch) [operators.odin:62](src/operators.odin#L62): `case: return`; the parser rejects any other operator value with L0243, so the value is always a proc or a group.
- (branch) [operators.odin:161](src/operators.odin#L161): `shape.results >= 0` is always true; every `operator_shape` entry sets 0 or 1.
- (branch) [operators.odin:173](src/operators.odin#L173): `sym.result == INVALID_TYPE ||` cannot hold; boolean shapes have `results = 1`, so line 161 already returned.
- (branch) [operators.odin:178](src/operators.odin#L178): `info == nil || len(info.param_modes) == 0` cannot hold; `params` and `proc_type` are set together (check.odin:1602, 1608) and assign shapes passed `count >= 2`.
- (branch) [operators.odin:416](src/operators.odin#L416): the empty-members return; every caller has established a non-empty set (`operator_exists`, a viable set, or its own `len` check).
- (branch) [operators.odin:472](src/operators.odin#L472): `ok = false`; `build_candidate` rejects a missing argument without a default, so a chosen candidate always fills the slot. The loop reduces to filling defaults for unfilled slots.
- (branch) [operators.odin:488](src/operators.odin#L488): `index >= len(bound) || bound[index] == nil`; the caller returned early unless every slot is bound, and `param_modes` has one entry per parameter.
- (branch) [operators.odin:576](src/operators.odin#L576): the `.EOF` guard; `builtin_unary_defined` and `builtin_operator_applies` both answer false for it.
- (branch) [operators.odin:579](src/operators.odin#L579): `op != .Not`, repeated at 626; `builtin_operator_applies` and the comparison switch have no `.Not` case, so the binary predicate is already false.

**Data structures and algorithms**

- [operators.odin:235](src/operators.odin#L235) `local_operator_set`: each user-operator expression (twice for `+=` and `!=` fallbacks) iterates every name of every enclosing local scope, and nearly always finds nothing, so cost is locals times uses in operator-heavy procedures. A `declares_operator` flag on `Scope`, set when a local operator resolves, skips the scan. Low priority.
- [operators.odin:419](src/operators.odin#L419) `resolve_operator_set`: `aprintf` into the semantic arena leaves a permanent string per user-operator expression, only read when reporting a diagnostic. `fmt.tprintf` is enough; `form_candidates` already relies on the temp allocator across this call.

**Near copies**

- [operators.odin:451](src/operators.odin#L451) and [overload.odin:902](src/overload.odin#L902): both bind arguments to slots, materialize, check modes, and fill defaults. They have already drifted (BUG-operators-8, BUG-operators-11). Shared form: one `bind_candidate_slots(k, cand, span, subject) -> ([]Expr, bool)`; the call path adds its order tracking around it.
- [operators.odin:632](src/operators.odin#L632) and [operators.odin:354](src/operators.odin#L354): the same comparable/ordered/table switch, on `underlying` and on `unified`. `builtin_binary_defined(k, op, underlying, underlying)` serves delegation with the same answers, plus shifts (BUG-operators-2).
- [operators.odin:97](src/operators.odin#L97) and [operators.odin:66](src/operators.odin#L66), [operators.odin:144](src/operators.odin#L144): the same shape lookup with L0416, and the same arity test and message. Shared form: `check_operator_arity(k, value, shape, count) -> bool` and one helper for the lookup.
- [operators.odin:574](src/operators.odin#L574) and [operators.odin:622](src/operators.odin#L622): the same unary and binary predicates are evaluated once to decide and again to register; the merge under Simplification removes the first.
- [operators.odin:363](src/operators.odin#L363) and [check_expr.odin:2028](src/check_expr.odin#L2028): `check_unary`'s operator switch restates `builtin_unary_defined` case by case after the distinct and SIMD exits; a single `if !builtin_unary_defined(...)` mismatch check replaces about 20 lines there.

**Structure and boundaries**

- [operators.odin:702](src/operators.odin#L702): `compound_operator` and `operator_token` are token tables with no checker state, yet parser.odin:1413, emit_llvm_stmt.odin:619, emit_llvm_calls.odin:574 and eval.odin:2666 reach into this checker file for them. They belong beside `operator_table` and `operator_spelling` in lexer.odin.
- [operators.odin:325](src/operators.odin#L325): the built-in operator table is split between this section, `builtin_operator_applies` (check_expr.odin:2658) and `compound_applies` (check.odin:4197), which is how shifts and SIMD fell out of some paths and not others (BUG-operators-2, BUG-operators-7, BUG-operators-12). Move all of them under this file's "the built-in priority" section.
- [operators.odin:265](src/operators.odin#L265): `operator_candidates_for_receiver` is documented for `[]`, `[]=`, `[:]` but `delegate_one` uses it for every symbol, which is the root of BUG-operators-3. Delegation needs its own "overloads mentioning this type" query.

**Comments**

- [operators.odin:42](src/operators.odin#L42): restates the spec's exclusion list, and those symbols are simply absent from the table above. Replace with `// design.md "Operator declarations".` so the citation names a heading.
- [operators.odin:511](src/operators.odin#L511): seven lines paraphrase the spec, then [operators.odin:582](src/operators.odin#L582) repeats it in four more. Keep `// design.md "Delegating operators".` plus "the overloads go where the block's other members do, per `kind`", and delete the second block down to its citation.
- [operators.odin:542](src/operators.odin#L542): delete; it restates the `errorf` below, and "in the same block" is narrower than the check, which sees every visible overload.
- [operators.odin:548](src/operators.odin#L548): shorten to "Each keeps its own signature, so `[]` forwards its index parameter unchanged."; the first sentence repeats the spec.
- [operators.odin:614](src/operators.odin#L614): keep the first sentence; the `-`, `+`, `~` and `!` examples are read off `builtin_unary_defined` and tests/run/delegate_unary.loke.
- [operators.odin:697](src/operators.odin#L697): shorten to "The binary operator a compound assignment applies, or `.EOF`; the parser recognizes a compound assignment by this answer."
- [operators.odin:722](src/operators.odin#L722): wrong rather than long: `.EOF` also covers `in` and every compound spelling. Write "or `.EOF` for a symbol with no built-in delegation", or drop it with the table move.
- [operators.odin:402](src/operators.odin#L402): delete, along with [operators.odin:414](src/operators.odin#L414); both restate the procedure name. (about 20 comment lines across the file)

### src/optional.odin

Sound logic and mostly good comments, but it holds two unrelated subsystems, an exact copy in the `or_return` checks, and a redundant second entry to the union switch. The bugs below were reproduced with the `lokec.exe` in the repository root, built just after this commit.

**Bugs**

- `BUG-optional-1` **medium** [optional.odin:184](src/optional.odin#L184) `check_or_return`: the copy report names the whole union even for a replacement, which design.md "Operator ownership" says leaves the error alone. Scenario: `r: Result(int, map[string]int)`, `x := r or_return .Bad;` warns by default L0507 "this `or_return` clones `r`, which may allocate", though only an `int` is copied. Fix: report the success payload when `v.failure != nil && !v.failure_maps`. *Confirmed: Reproduced: `r or_return .Bad` warns L0507 "clones `r`, which may allocate", yet f's IR has no map_clone (the mapper form does) and or_else stays silent. Only a false warning with no codegen effect, so low severity rather than medium.*
- `BUG-optional-2` **low** [optional.odin:248](src/optional.odin#L248) `check_or_return_failure`: a replacement that fails the probe is taken for a mapper, and a failure with no error then hides the real diagnostic. Scenario: `opt() or_return undefined_name;` reports "`Option(int).none` carries no error to map", never the undefined name. Fix: with `from == TYPE_VOID`, check the operand as a replacement and make this text a note. *Not verified.*
- `BUG-optional-3` **low** [optional.odin:319](src/optional.odin#L319) `or_return_replaces`: a proc literal is always a mapper, against design.md "The failure operand": "A value assignable to `F` replaces". Scenario: with `F :: proc() -> int`, `res() or_return proc() -> int { return 1; };` is rejected L0322 "takes 0 arguments, found 1". Fix: drop the `^Expr_Proc` case so the probe decides. *Not verified.*
- `BUG-optional-4` **low** [optional.odin:501](src/optional.odin#L501) `check_variant_cases`: a rejected single-binding case binds its name at the union type, so its body reports again. Scenario: a duplicate `case .a(y): return y + 1;` or `case .nope(z): return z + 1;` adds L0352 "1 is not representable by `U`". Fix: bind `INVALID_TYPE` when `entry.values` is non-empty and no index survived, as unresolved fields already are (line 541). *Not verified.*

**Simplification**

- [optional.odin:448](src/optional.odin#L448) `check_type_switch`: delete it and the `s.kind != .Value` dispatch at [check.odin:4324](src/check.odin#L4324). `check_switch` repeats its head and `adopt_branch_patterns` is a no-op on selector cases, so a recloned `.Pattern` switch takes the ordinary path. (about 22 lines)
- [optional.odin:9](src/optional.odin#L9) `Fallible`: `info` is only ever read as `shape.info.variants[shape.success or failure]`, at 25 sites across the checker, CFG and evaluator. Store `success_type` and `failure_type` instead of `info`, which also removes the local aliases at lines 75 and 187.
- [optional.odin:54](src/optional.odin#L54) `check_or_else`, [optional.odin:125](src/optional.odin#L125) `check_or_return`: set `v.type = INVALID_TYPE` once on entry and assign the real type only on the success path, replacing 13 repeats on the early returns. (about 12 lines)
- [optional.odin:93](src/optional.odin#L93) `check_or_else`: make the exit and the fallback the two arms of an `if`/`else`, followed by one `if v.borrows { report_copy_cost }` and `v.type = payload`, in place of the copy at lines 98-102. (about 4 lines)
- [optional.odin:225](src/optional.odin#L225) `check_or_return_failure`: let `or_return_constructs` return `(payload, ok)`, dropping line 230's lookup, and replace the `switch` with `maps := constructs || !or_return_replaces(k, v.failure, into)`. (about 7 lines)
- [optional.odin:580](src/optional.odin#L580) `check_variant_cases`: `s.exhaustive = has_default || variant_count(...) == len(seen_variants)` with one `if !s.exhaustive` report; drop `any_case_falls` by accumulating into `flow`, and return `flow`. (about 10 lines)
- [optional.odin:652](src/optional.odin#L652) `field_name_at`: one caller, whose `slot` was read from this same record by `resolve_case_fields`, so its bounds and nil checks cannot fire. Inline it as `identifier_text(k.c, symbol_of(k.c, underlying_info(k.c, binding_type).fields[field.slot]).name)`. (about 7 lines)
- [optional.odin:45](src/optional.odin#L45) `note_optional_replacement`: a `#partial switch` with one case; write `if index, is_index := e.(^Expr_Index); is_index && ...`. (about 2 lines)

**Dead code**

- (branch) [optional.odin:715](src/optional.odin#L715): `info == nil` cannot hold, because `variant_count` then returns 0, which equals the empty `seen_variants`, so the only caller never reports.
- (branch) [optional.odin:732](src/optional.odin#L732): `count == 0` cannot hold, because the caller ran only when `seen_variants`, whose valid indices are distinct, is shorter than the variant count.
- (branch) [optional.odin:601](src/optional.odin#L601): the `case_scope` parameter never varies; it is always `k.scope.parent` (line 546). Drop it and look up in `k.scope.parent`, as [iterate.odin:1071](src/iterate.odin#L1071) does.

**Near copies**

- [optional.odin:197](src/optional.odin#L197) and [optional.odin:338](src/optional.odin#L338): identical 15 lines rejecting a procedure result that is absent or not fallible. Share `or_return_target(k, v) -> (Fallible, bool)`. (about 14 lines)
- [optional.odin:713](src/optional.odin#L713) and [check.odin:4464](src/check.odin#L4464): the same "first three, then `, ...`" list and "does not cover" message, differing in the name source and the code. Each collects names into a temp slice and calls one `report_uncovered(k, s, subject, code, names)`. (about 12 lines)
- [optional.odin:603](src/optional.odin#L603), [iterate.odin:1062](src/iterate.odin#L1062) and [check.odin:560](src/check.odin#L560): the L0304, reserved-name and L0305 checks for a new local. Share `check_local_name(k, name, id, span) -> bool`; they differ in `check.odin`'s synthesized-name exemption and in whether a reserved name still binds. (about 14 lines)
- [optional.odin:574](src/optional.odin#L574), [check.odin:4390](src/check.odin#L4390) and [expand.odin:36](src/expand.odin#L36): the same `||=` merge of `Flow_Info` fields. Share `merge_flow(&flow, other)` beside `Flow_Info`. (about 6 lines)
- [optional.odin:259](src/optional.odin#L259), [optional.odin:272](src/optional.odin#L272), [check.odin:4796](src/check.odin#L4796) and [expand.odin:640](src/expand.odin#L640): a synthesized one-argument `Expr_Call`, five lines each. Share `new_call(c, span, callee, argument)`. (about 10 lines)
- [optional.odin:20](src/optional.odin#L20), [check.odin:442](src/check.odin#L442) and [emit_llvm_calls.odin:777](src/emit_llvm_calls.odin#L777): `fallible_of` reads only `k.c`, yet taking `^Checker` keeps the emitter and `entry_failure_type` hand-rolling the shape. Take `^Compiler`; [union.odin:253](src/union.odin#L253) already guarantees the two variants `check.odin` retests.
- [optional.odin:75](src/optional.odin#L75), [optional.odin:188](src/optional.odin#L188), [optional.odin:529](src/optional.odin#L529), [reflect.odin:294](src/reflect.odin#L294) and [emit_llvm_runtime.odin:1267](src/emit_llvm_runtime.odin#L1267): a payloadless variant reads as `Unit`. Share `payload_value_type(c, payload)`. (about 3 lines)

**Structure and boundaries**

- [optional.odin:372](src/optional.odin#L372): the second half is union switching and shares nothing with the failure protocol, and the name `optional.odin` covers neither. Move it, with `check_switch`, `check_case_value` and `check_exhaustive` from `check.odin`, to a switch file, and update the source map.
- [optional.odin:35](src/optional.odin#L35): `note_anonymous_union_is_data` is used only in this file, so the source map's rule makes it `@(private = "file")`.
- [optional.odin:468](src/optional.odin#L468) `check_variant_cases` is 127 lines: lift lines 509-525 to `case_variants` and lines 526-565 to `bind_case`. [optional.odin:196](src/optional.odin#L196) `check_or_return_failure` is 100 lines: lift lines 268-282 to `failure_return`.

**Comments**

- [optional.odin:7](src/optional.odin#L7), [optional.odin:372](src/optional.odin#L372): stale banners: nothing here is "optional-ok" and no switch matches types. Use `failure operators` and `union switches`.
- [optional.odin:191](src/optional.odin#L191): shorten to `// design.md "The failure operand": builds `v.failure_exit`, the `return` a failure takes.`; the prose repeats the spec, and that heading is the exact one. (about 2 lines)
- [optional.odin:73](src/optional.odin#L73): shorten to `// design.md "or_else expression": a payloadless success yields `Unit`.` (1 line)
- [optional.odin:403](src/optional.odin#L403): delete; the next line says it.

### src/overload.odin

Ranking itself is sound and matches the spec's vector and tie-breaker order, but the candidate and context-typing paths have several wrong-selection or wrongly rejected cases (each reproduced with the `lokec.exe` built at this commit). The file also holds a dead layer of defensive guards and about 150 lines of argument binding that belong beside `bind_arguments`.

**Bugs**

- `BUG-overload-1` **medium** [overload.odin:525](src/overload.odin#L525) `build_candidate`: `unconsumed` skips a generic's `$` arguments, since only runtime arguments reach it, so tie-breaker 1 favors the generic. Scenario: `pick :: proc{plain, gen}` with `plain(x: int)`, `gen($x: int)`; `pick(1)` calls `gen`, against tie-breaker 4. *Confirmed: Probe: `pick :: proc{plain, gen}` with `gen($x: int)` prints 2 for `pick(1)` in either member order; with `gen(x: $T)` it prints 1. `$x` is not a `move` parameter, so tie-breaker 1 should tie and tie-breaker 4 pick `plain`. No recorded decision found.*
  Fix: count `consumed` (`if mode == .Move`; `argument_rank` already requires ownership) and prefer more in `tie_break`.
- `BUG-overload-2` **medium** [overload.odin:223](src/overload.odin#L223) `common_argument_type`: a generic member with no parameter at this position or name returns `INVALID_TYPE` for all, where a non-generic is skipped (line 249). Scenario: `f(x: int, m: Mode)`, `h(x: $T)`, `g :: proc{f, h}`; `g(1, .A)` gives L0385, yet it compiles with a non-generic `h(x: int)`. *Confirmed: Reproduced: g(1, .A) and g(1, m = .A) give L0385 with h(x: $T), but compile with h(x: int); line 223 bails on a missing generic parameter. Unrecorded and unpinned; design.md gives no reason. Severity is low-medium: rejected code, Mode.A works.*
  Fix: have `generic_parameter_context_type` distinguish "no such parameter" and `continue`.
- `BUG-overload-3` **medium** [overload.odin:172](src/overload.odin#L172) `argument_needs_context`: misses `^Expr_Cond`, though `check_cond` passes the expected type to its branches. Scenario: `f(.A if c else .B)` compiles for a plain call but gives L0385 through a group, generic, or method (`obj.m(.none if c else .some(5))`). *Confirmed: Reproduced: f(.A if c else .B) compiles for a plain call but gives L0385 via a group, a generic and a method, while bare .A/.none pass all three. Not recorded in the docs. Over-rejection with a workaround (name the type), so low rather than medium.*
  Fix: add `case ^Expr_Cond:` returning whether either branch needs context; it then also waits correctly for `$` parameters.
- `BUG-overload-4` **low** [overload.odin:355](src/overload.odin#L355) `argument_rank`: an `inout` parameter ranks a merely assignable type as viable, though `check_bound_argument_mode` always rejects it. Scenario: `a(x: inout []int, z: int)`, `b(x: inout []mut int, z: f64)`, `y: []mut int`; `g(inout y, 1)` gives L0391 ambiguity although only `b` can bind. *Not verified.*
  Fix: return `RANK_NONE` for a non-receiver `mode == .Inout` when `arg.type != param`, and check that `tests/err` pins stay right.
- `BUG-overload-5` **low** [overload.odin:514](src/overload.odin#L514) `build_candidate`: an `inout` mismatch falls through to the type message. Scenario: `a(x: inout int)` in a group, `g(y)` with `y: int` notes "argument 1 is `int` where `int` is wanted"; `h(inout y)` against `c(x: int)` says the same. *Not verified.*
  Fix: test `(mode == .Inout) != (arg.mode == .Inout)` first and name the missing or extra `inout`.
- `BUG-overload-6` **low** [overload.odin:497](src/overload.odin#L497) `build_candidate`: the move advice assumes a place, but a temporary of the wrong type also reaches it. Scenario: `a(x: move Foo)`, `g(mk())` with `mk() -> Bar` notes "which is written `move(...)`", and writing that still fails. *Not verified.*
  Fix: give the move reason only when the argument is not owned, as line 493 does; a wrong-typed temporary takes the type message.

**Simplification**

- [overload.odin:35](src/overload.odin#L35) `ordering_ranks`: nothing reads `.ranks` after building, so `build_generic_candidate` can assign `cand.ranks = ordering`; drop the field and `candidate_ranks`. (about 7 lines)
- [overload.odin:723](src/overload.odin#L723) `choose_candidate`: test `candidates_viable(all)`, then loop over `all` skipping non-viable ones; the `viable` index list and the `other != index` test go, since `candidate_better(a, a)` is false. (about 6 lines)
- [overload.odin:311](src/overload.odin#L311) `argument_rank`: move `moved` into the receiver branch and make the other branch one condition: `(mode == .Inout) != (arg.mode == .Inout) || (mode == .Move && !expression_is_owned_argument(arg.expr))`. (about 6 lines)
- [overload.odin:662](src/overload.odin#L662) `tie_break`: `parametric` is equal here and the inner `if` returns what falls through, so end with `return a.parametric ? compare_generic_specificity(k, a.template, b.template) : 0`. (about 5 lines)
- [overload.odin:982](src/overload.odin#L982) `candidate_arguments`: a receiver is only ever first, so slice it off once (`args = cand.args[1:]`) instead of adjusting `count` and also skipping in the loop; `bind_chosen_call` line 886 tests the same thing. (about 4 lines)
- [overload.odin:341](src/overload.odin#L341) `argument_rank`: test `!assignable` once before the untyped branch, since both paths end in `RANK_NONE` without it. (about 3 lines)
- [overload.odin:530](src/overload.odin#L530) `build_candidate`: `if cand.filled[slot] || slot == pack { continue }`; line 462 is `proc_parameter_mode(k.c, sym.proc_type, slot)`. (about 3 lines)

**Dead code**

- (branch) [overload.odin:612](src/overload.odin#L612): every non-viable return of `build_candidate` sets `reason`, and line 589 does too, so the fallback reason never applies.
- (branch) [overload.odin:623](src/overload.odin#L623): `compare_vectors` compares only viable candidates over one argument list, each vector `len(args)` long, so the lengths never differ.
- (branch) [overload.odin:837](src/overload.odin#L837): `maximal` holds viable candidates, for which `build_candidate` proved `sym` non-nil and `proc_type` a procedure, so the checks at 837 and 843 never fire.
- (branch) [overload.odin:785](src/overload.odin#L785): `waiting_arg` indexes the same `args`, so `all[0].waiting_arg < len(args)` is always true.
- (branch) [overload.odin:949](src/overload.odin#L949): `slots` of a viable candidate are always in range, since `build_candidate` indexed `sym.params` with them.
- (branch) [overload.odin:921](src/overload.odin#L921): an unfilled slot of a viable non-variadic candidate passed the check at line 537, so `slot < len(sym.param_defaults)` always holds.
- (branch) [overload.odin:957](src/overload.odin#L957): `arg.waiting = false` and the `is_const`/`const_value` writes at 971-974 are never read; after this point only `expr`, `type`, `name`, `span`, `mode` and `is_receiver` are.

**Data structures and algorithms**

- [overload.odin:436](src/overload.odin#L436) `build_candidate`: every rejected member formats a `reason` (`fmt.aprintf` plus `type_name`) into the semantic arena even when another member is chosen; only `report_no_match` reads them. Cost grows as members times call sites, so it matters only for wide groups and operator sets. Measure first; with the seam below, re-form on failure with an `explain` flag.

**Near copies**

- [overload.odin:383](src/overload.odin#L383) and [generic.odin:2351](src/generic.odin#L2351): the same "it takes %d argument%s, found %d" reason. Remove `@(private = "file")` from `arity_reason` and call it from `infer_generic_arguments`.
- [overload.odin:514](src/overload.odin#L514) and [overload.odin:589](src/overload.odin#L589): the same "argument %d is `%s` where `%s` is wanted" formatting; a small `argument_mismatch_reason(k, index, found, want)` serves both.

**Structure and boundaries**

- [overload.odin:876](src/overload.odin#L876): lines 873-1023 (`bind_chosen_call`, `type_waiting_arguments`, `candidate_arguments`, `dereference_argument`, `materialize_argument`) bind arguments rather than select; the source map gives that to `check_calls.odin`, which holds their sibling `bind_arguments`. `pointer_to_element` fits beside `slice_element` in `slice.odin`.
- [overload.odin:487](src/overload.odin#L487) `build_candidate`: the 150-line procedure spends about 45 lines on rejection wording (lines 479-522). Extract `rejection_reason(k, arg, index, want, mode) -> string`, leaving placement and ranking readable; bugs 5 and 6 are fixed there.
- [overload.odin:68](src/overload.odin#L68) `resolve_group_members`: declaration checking called from `check.odin` and `operators.odin`, sharing nothing with ranking; `check.odin` is its natural owner.

**Comments**

- [overload.odin:280](src/overload.odin#L280): sits on `constant_conversion_preserves_kind` but describes `argument_rank`; move it there or delete it.
- [overload.odin:310](src/overload.odin#L310): "Modes decide viability and ties, not conversion rank" is contradicted by `adjusted` at line 322; shorten to "A receiver's mode is implicit, so it costs `RANK_ADJUST` instead of needing a match."
- [overload.odin:24](src/overload.odin#L24): `// design.md "Arguments typed after inference": unchecked until `bind_chosen_call` types it against the chosen parameter.`
- [overload.odin:707](src/overload.odin#L707): delete; it restates the signature.
- [overload.odin:782](src/overload.odin#L782): `// design.md "Arguments typed after inference": a sole generic reports at the waiting argument that alone could bind a `$` name.`
- [overload.odin:840](src/overload.odin#L840): `// design.md "Operator lookup and overload resolution": signatures, not rank vectors.`
- [overload.odin:935](src/overload.odin#L935): keep the citation and the first clause; the evaluation-order sentence repeats the spec.
- [overload.odin:1001](src/overload.odin#L1001): delete; the one-line body says the same.

### src/parallel.odin

The checks read well and match the spec, but `spawn_field_kind` lends the task storage that does not last until the join: two miscompiles, both reproduced with the built compiler. `lower_spawn` is long, and much of the file's synthesized-syntax code repeats other files or itself.

**Bugs**

- `BUG-parallel-1` **high** [parallel.odin:608](src/parallel.odin#L608) `spawn_field_kind`: a place rooted in a temporary counts as lendable, so `.Address` points into a temporary the parent drops at the statement's end (also line 602, `self: ^`). Against design.md "Spawn statements" on temporaries. *Confirmed: Reproduced: spawn read(mkw().items) printed sum 0 (expected 64512), spawn show(mk()[0]) printed empty, and spawn mkh().t.read() ran drop before read; spawn read(mkw()) is correct. Contradicts design.md "Spawn statements"; not recorded. High is fair: silent use-after-drop.*
  Scenario: `spawn read(mkw().items);` printed `sum 0 expected 66016`, and `spawn show(mk()[0]);` printed an empty string; a `hook(drop)` printed before the task read. Fix: lend only a place with a lasting root; otherwise copy the projected value into the frame as `.Owned`, and report L0728 for a move-only type.
- `BUG-parallel-2` **high** [parallel.odin:608](src/parallel.odin#L608) `spawn_field_kind`: a widened managed place gets `.Address`, but `emit_address` ([emit_llvm_expr.odin:694](src/emit_llvm_expr.odin#L694)) widens it into one temporary slot per site, which a loop's next spawn overwrites while earlier tasks read it. *Confirmed: Reproduced: [6]Small of hook-copy payloads, foreach { spawn show(items[i]); } with show(v: Big) prints 6 six times; the same program without widening prints 1 to 6. emit_address hands every frame the one temporary slot; design.md allows no such overwrite.*
  Scenario: `foreach (i in 0..<items.len()) { spawn show(items[i]); }`, with `Small` elements and `show(v: Big)`, printed `sixth sixth sixth sixth sixth sixth`. Fix: test `expression_converts_storage` here and make it `.Owned`, with the `.Owned` arm of `emit_spawn` copying the place as design.md "Widening by label" says.
- `BUG-parallel-4` **low** [parallel.odin:119](src/parallel.odin#L119) `check_parallel`: counts `len(diagnostics)`, so a warning from the executor expression gets the executor-type note. *Not verified.*
  Scenario: `parallel (pick(pool, big2))` under `-copy-cost=1` attaches "a `parallel` block's executor is a `^thread.Pool`" to the L0507 warning. Fix: compare `c.error_count`, as line 523 does.
- `BUG-parallel-5` **low** [parallel.odin:367](src/parallel.odin#L367) `lower_spawn`: a missing `unsafe` builtin (line 367) or `Task_Scope.start` (line 379) returns with no diagnostic, unlike `thread_type`'s L0727 at line 208, and the spawn then fails in the backend. *Not verified.*
  Scenario: `-collection core=<dir>` whose `thread` package declares only `Task_Scope` gives `L0405 internal backend contract violation: an unchecked spawn reached emission`. Fix: report L0727 on both paths.

**Simplification**

- [parallel.odin:423](src/parallel.odin#L423) `lower_spawn`, `frame_field_name`: names are decoded from an index, then rebuilt with `aprintf`. Append `(name, type)` in layout order instead, and use `field_names[...]`, `"result"`, and `"callee"` at lines 449, 487, 497; `frame_field_name` goes. (about 14 lines)
- [parallel.odin:396](src/parallel.odin#L396) `lower_spawn`: the two loops over `call.bound` (396 and 447) repeat the mode lookup and pack and spread tests. The frame is only named in the synthesized body, so one loop can build each field and argument, with the record declared after it. (about 8 lines)
- [parallel.odin:406](src/parallel.odin#L406) `lower_spawn`: `mode == .Variadic` is the same test as `call.is_variadic && index == call.variadic_slot` (see [check_calls.odin:1085](src/check_calls.odin#L1085)). Make `.Variadic` return `.Copy` in `spawn_field_kind`, drop 406-409, and test the mode at 454. (about 4 lines)
- [parallel.odin:437](src/parallel.odin#L437) `unsafe_builtins`: returns a `[3]Symbol_Id` that lines 437-439 bind through a second parallel list of names. One `bind_unsafe_builtins(k) -> bool` looping over `{take, write, free}` removes the array. (about 8 lines)
- [parallel.odin:471](src/parallel.odin#L471) `lower_spawn`: `synth_ident(k, "spawn$take", intern_identifier(c, "spawn$take"), span)` and its `write` and `free` forms recur at 471, 498, 501, 581. Add `spawn_builtin_call(k, name, args, span)`; also fold `frame_of` plus `synth_selector` (449, 487, 497) into `frame_select`. (about 6 lines)
- [parallel.odin:427](src/parallel.odin#L427) `lower_spawn`, `spawn_pack_record`: the `span.lo` suffixes on `spawn$frame$`, `spawn$run$`, `spawn$pack$` are not needed. Each lives in a fresh scope, generic instances already repeat them, and [emit_llvm.odin:376](src/emit_llvm.odin#L376) makes run names unique. Use fixed names; `spawn$type$frame` keeps the type apart from the parameter. (about 3 lines)
- [parallel.odin:305](src/parallel.odin#L305) `spawn_result_symbol`: takes `s`, then asserts `s.call.(^Expr_Call)` three times (328, 333, 340). Pass `result: ^Expr_Ident` and `call: ^Expr_Call`, which `check_spawn` already holds. (about 2 lines)
- [parallel.odin:214](src/parallel.odin#L214) `task_scope_start`: one caller, and it is public. Inline it at line 377, and mark `spawn_pack_field_name` ([parallel.odin:557](src/parallel.odin#L557)) `@(private = "file")`, since the emitter finds pack fields by position. (about 5 lines)

**Dead code**

- (branch) [parallel.odin:397](src/parallel.odin#L397): `index < len(info.parameters)` is always true, since `call.bound` has one slot per parameter and [emit_llvm_stmt.odin:198](src/emit_llvm_stmt.odin#L198) indexes the same array unguarded. The `INVALID_TYPE` arm never runs.
- (branch) [parallel.odin:376](src/parallel.odin#L376): `scope != nil` always holds, because `check_spawn` returns at line 253 when `block.scope` is invalid, and `symbol_of` is nil only for an out-of-range id.

**Near copies**

- [parallel.odin:651](src/parallel.odin#L651), [parallel.odin:668](src/parallel.odin#L668), [parallel.odin:723](src/parallel.odin#L723) and [check.odin:3888](src/check.odin#L3888), [check.odin:3856](src/check.odin#L3856), [check.odin:3897](src/check.odin#L3897): the same file-private ident, deref, and local builders under two names; [capture.odin:137](src/capture.odin#L137), [check_calls.odin:204](src/check_calls.odin#L204) hand-build these nodes too. Share one set of `synth_*`, of which the ident, selector and deref builders are already package-visible.
- [parallel.odin:181](src/parallel.odin#L181), [parallel.odin:723](src/parallel.odin#L723), [parallel.odin:735](src/parallel.odin#L735) and [capture.odin:110](src/capture.odin#L110), [capture.odin:140](src/capture.odin#L140): one-name `Decl` builders differing only in `kind` and type. Use one `synth_decl(c, kind, name, type, value, span)` built on `synth_name`, which interns, so callers drop their `id`. (about 20 lines here)
- [parallel.odin:700](src/parallel.odin#L700) and [capture.odin:95](src/capture.odin#L95): a local struct whose field types are aliases only its scope binds. They differ in field names and spans; `synth_record` taking `[]Name`, with each field's span from its `Name`, serves both, moving capture fields from `entry.span` to `entry.name.span`. (about 15 lines)
- [parallel.odin:469](src/parallel.odin#L469) and [parallel.odin:579](src/parallel.odin#L579): `local := aprintf(...)`, take into a new local, then name or `move` it. Extract `spawn_take_local(k, stmts, name, field, span) -> Expr`, with a `synth_move` that [capture.odin:51](src/capture.odin#L51) and [lifecycle.odin:368](src/lifecycle.odin#L368) can also use. (about 8 lines)
- [parallel.odin:206](src/parallel.odin#L206), [parallel.odin:635](src/parallel.odin#L635) and [format.odin:281](src/format.odin#L281), [bootstrap.odin:58](src/bootstrap.odin#L58), [atomics.odin:28](src/atomics.odin#L28): `pkg.scope.names[intern_identifier(c, name)]`. Add `package_member(c, pkg, name)`.
- [parallel.odin:398](src/parallel.odin#L398), [parallel.odin:448](src/parallel.odin#L448): `index < len(info.param_modes) ? info.param_modes[index] : .Value`, 20 lines across `src/`. Add `param_mode_at(info, index)` next to `proc_parameter_mode` in `semantic.odin`.

**Structure and boundaries**

- [parallel.odin:363](src/parallel.odin#L363) `lower_spawn` is 172 lines with three seams: the frame layout and record (393-431), the run body (445-502), and the run procedure's declaration (505-528, a `synth_proc` of about 20 lines of plain node building). Split them, leaving `lower_spawn` to set up the task and commit it.

**Comments**

- [parallel.odin:352](src/parallel.odin#L352): the sketch spells fields `arg$0` and `arg$1`, but `frame_field_name` makes `arg0`, and locals are `spawn$owned$N`, not `owned$1`. Correct the spelling, and add the `callee` field it omits.
- [parallel.odin:4](src/parallel.odin#L4): lines 4-12 repeat compiler-architecture.md "Lowering parallel blocks", with line 7 unwrapped. Shorten to: "Checked as ordinary code: a block gains a hidden `Task_Scope` local, and a spawn a frame record and `run` procedure (compiler-architecture.md "Lowering parallel blocks")." (about 5 lines)
- [parallel.odin:590](src/parallel.odin#L590): restates the spec's paragraphs on copied, borrowed, and temporary arguments. Shorten to: `// design.md "Spawn statements": which arguments are copied, lent, or owned.` (about 3 lines)
- [parallel.odin:537](src/parallel.odin#L537): lines 538-540 repeat the spec's pack rules. Keep: `// design.md "Spawn statements": the record holding a pack's operands until the worker packs them again.` (about 2 lines)
- [parallel.odin:561](src/parallel.odin#L561): narrates the three branches below it. Keep only "The worker's arguments for a held pack, in written order." (about 1 line)
- [parallel.odin:416](src/parallel.odin#L416): repeats the spec's sentence. Shorten to: `// design.md "Spawn statements": the task's own copy of a procedure value.` (about 1 line)
- [ast.odin:1048](src/ast.odin#L1048): the `Stmt_Parallel` comment calls the executor "the later pool form, parsed so the syntax is reserved", but this file implements it. Delete those two lines.

### src/parser.odin (part 1 of 2)

The statement and item parser is readable and its look-ahead scans are bounded by the statement or by `MAX_NEST`, so there is nothing to report on data structures. One missing-brace input crashes the compiler; the largest saving is `has_error` bookkeeping that nothing outside the tests reads.

**Bugs**

- `BUG-parser.part1-1` **high** [parser.odin:1623](src/parser.odin#L1623) `case_switch`: a failed `parse_block` stores a nil `^Block` in a `Stmt`, which is then a non-nil union that later walks enter. *Confirmed: Reproduced: `if (case 1 = x) y;` and the `for` form exit 139 with no output; -parse-only gives L0213 and plain `if` reports it. Not in known-gaps. Invalid input only, no miscompile, so medium rather than high.*
  Scenario: `if (case 1 = x) y;` or `for (case 1 = x) y;` exits 139 with no diagnostic; plain `if (x > 0) y;` reports L0213. Fix: leave `stmts` empty when `matched == nil`.
- `BUG-parser.part1-2` **low** [parser.odin:671](src/parser.odin#L671) `parse_foreign`: the library path is a slice of the raw literal, so escapes stay encoded, though `import` decodes its path ([packages.odin:275](src/packages.odin#L275)). *Not verified.*
  Scenario: `foreign import k "sys\x74em:kernel32.lib";` keeps the escape and misses the `system:` test at [emit_llvm_toolchain.odin:653](src/emit_llvm_toolchain.odin#L653). Fix: decode it with `decode_string_literal`.
- `BUG-parser.part1-3` **low** [parser.odin:1324](src/parser.odin#L1324) `parse_statement`: the `.Semicolon` arm drops attributes parsed just above; grammar.md "Statements" gives `";"` no `Attributes?`. *Not verified.*
  Scenario: `@(whatever) ;` in a body exits 0, while the same text at file scope reports L0206. Fix: report L0206 when `len(attributes) > 0`.
- `BUG-parser.part1-4` **low** [parser.odin:1479](src/parser.odin#L1479) `parse_init_declaration`: `Init_Statement` admits `Variable_Decl`, which takes `Attributes?` (grammar.md "Declarations"), but callers test `starts_declaration` at the `@`. *Not verified.*
  Scenario: `if (@(foo) y := 1; y > 0) { }` is rejected with L0220 and four more errors. Fix: parse attributes first and pass them on, or change the spec deliberately.
- `BUG-parser.part1-5` **low** [parser.odin:1703](src/parser.odin#L1703) `parse_for`: the empty-header arm reports its error and then falls into the three-part path. *Not verified.*
  Scenario: `for () { }` reports L0245, L0220 and a second L0245 for one mistake. Fix: set `condition_only = true` in that arm.
- `BUG-parser.part1-6` **low** [parser.odin:2027](src/parser.odin#L2027) `parse_return`: unlike `parse_statement` and `finish_constant`, it demands `;` after a malformed value and does not resynchronise. *Not verified.*
  Scenario: `return );` reports L0220, L0215, L0220, while `x = );` reports one L0220. Fix: `if bad { sync_to_statement(p) }`, else expect `;`.
- `BUG-parser.part1-7` **low** [parser.odin:1480](src/parser.odin#L1480) `parse_init_declaration`: a failed declaration has already run `sync_to_item`, which swallows the body, and the header then parses what follows as its condition. *Not verified.*
  Scenario: `for (x: ) { a(); } b();` reports L0210, L0220, L0245, L0213. Fix: leave recovery to `parse_declaration`'s callers, and have a header skip to its `)`.
- `BUG-parser.part1-8` **low** [parser.odin:1314](src/parser.odin#L1314) `parse_statement`: the depth guard returns without resynchronising, unlike `parse_if`, so skipped `{` leave surplus `}` that close outer blocks, against "then silence the unwind". *Not verified.*
  Scenario: 3000 nested bare `{` report L0222 and 953 L0206; nested `if` reports L0222 alone. Fix: `sync_to_statement(p, true)`, as `parse_if` does.

**Simplification**

- [parser.odin:630](src/parser.odin#L630) (and 650-838, 1579-2116) `has_error` on non-`Decl` items and compound statements is write-only outside two test assertions ([front_end_test.odin:1116](src/front_end_test.odin#L1116), 1150).
  Readers are expressions, `Decl` (1483), simple statements (1381) and `parse_expr`'s exit. Drop the other writes and the `opened`/`closed`/`terminated` locals they alone need. (about 30 lines)
- [parser.odin:1030](src/parser.odin#L1030) `parse_declaration`, `finish_constant`, `finish_variable`: the tail "expect `;`, set span, set has_error, return" appears at 1030, 1112, 1139 and 1184. Use `end_declaration(p, d, start) -> ^Decl`. (about 9 lines)
- [parser.odin:1074](src/parser.odin#L1074) `finish_constant`, `finish_variable`: both always return `ok == true`, and `ok` from `parse_declaration` only ever means `d != nil`. Return `^Decl` alone; `parse_block`'s bool is the same. (about 4 lines)
- [parser.odin:1111](src/parser.odin#L1111) (also 1122, 1420, 1575, 1620, 1622, 1686, 1690, 2992): a one-element slice takes `make` plus an index assignment. A generic `one(p, value) -> []T` makes each one line. (about 9 lines)
- [parser.odin:1925](src/parser.odin#L1925) and [parser.odin:1227](src/parser.odin#L1227): the nil check before `make` is lazy init of two lists. Make both in `parse`, as every other list is made, since a zero-capacity `make` costs nothing. (about 6 lines)
- [parser.odin:1962](src/parser.odin#L1962) `parse_spawn`: the early branch builds a second `Stmt_Spawn`. Set `ok = false` and fall through, with the later test as `if !ok { sync_to_statement(p) }`. (about 6 lines)
- [parser.odin:1430](src/parser.odin#L1430) `parse_simple_statement`: three identical error loops. An `exprs_have_error(list)` helper gives `s.has_error = exprs_have_error(lhs) || exprs_have_error(rhs)`. (about 6 lines)
- [parser.odin:849](src/parser.odin#L849) `scans_name_list_colon`: its only caller is `starts_declaration`, with offset 0. Have `starts_declaration` call `scans_list_colon(p, 0, false)`. (about 4 lines)
- [parser.odin:2139](src/parser.odin#L2139) `parse_switch_case`: `new_expr` runs before the name is read, so `poly.span.hi` needs a fix-up. Read the name first, as the rule at line 111 asks, and drop line 2141. (1 line)
- [parser.odin:1909](src/parser.odin#L1909) `parse_parallel`: call `take_as` once at the top with the offsets one lower, removing the second call at 1924; `span_of(p, start).lo` at 1928 is `start.lo`. (about 2 lines)

**Dead code**

- (branch) [parser.odin:345](src/parser.odin#L345): `close` in `resync_list` and `next_element` is redundant. Every call passes `.Rparen` or `.Rbrace`, which lines 350, 362 and 400 already stop at, so it can leave the two signatures and 15 calls.
- (branch) [parser.odin:983](src/parser.odin#L983) and [parser.odin:995](src/parser.odin#L995): all callers pass `starts_declaration` first, so these `expect` failures cannot happen, as [corpus_test.odin:791](tests/corpus_test.odin#L791) records. Use `advance`, and drop L0208 from `UNPINNED`.
- (branch) [parser.odin:1332](src/parser.odin#L1332): the arm is entered at `{`, so `parse_block` cannot fail and `return nil, false` is unreachable.
- (branch) [parser.odin:630](src/parser.odin#L630): `item.call == nil` is redundant, since a nil call already leaves `exact_call` false.
- (branch) [parser.odin:671](src/parser.odin#L671): `len(raw) >= 2` always holds, because the lexer yields `.String` only after the closing quote ([lexer.odin:584](src/lexer.odin#L584)).

**Near copies**

- [parser.odin:1545](src/parser.odin#L1545) and [parser.odin:2088](src/parser.odin#L2088): `parse_if` and `parse_switch` read "init, then one expression" identically. Share `parse_init_and_expr(p) -> (Stmt, Expr)`. (about 10 lines)
- [parser.odin:2005](src/parser.odin#L2005) and [parser.odin:2049](src/parser.odin#L2049): both build a `Return_Value` with `value`/`has_value` and copy it to the heap. `parse_return_value(p) -> ^Return_Value` removes the flag from both. (about 12 lines)
- [parser.odin:1288](src/parser.odin#L1288) and [parser.odin:2168](src/parser.odin#L2168): the statement loop with its progress guard differs only in also stopping at `case`/`default`. Share `parse_statement_list(p, in_switch: bool) -> []Stmt`. (about 6 lines)
- [parser.odin:1775](src/parser.odin#L1775) and [parser.odin:1815](src/parser.odin#L1815): the same comma loop over `parse_foreach_binding`. Share `parse_binding_list(p) -> ([]Foreach_Binding, bool)`. (about 7 lines)
- [parser.odin:1562](src/parser.odin#L1562) and [parser.odin:1649](src/parser.odin#L1649): the `else` chain of `parse_if` and `parse_when` differs in keyword and recursion target. `parse_else(p, keyword, chain)` fits; so do their depth-guard bodies, 1529 and 1636. (about 8 lines)

**Structure and boundaries**

- [parser.odin:1668](src/parser.odin#L1668) `parse_for`: at 90 lines it holds two side jobs with natural seams: lowering the `case` header (1678-1697) as `parse_for_case`, and the bare-`in` rejection, five levels deep (1707-1733), as `reject_bare_in`.
- [parser.odin:1101](src/parser.odin#L1101) `has_attribute` lives at [check.odin:754](src/check.odin#L754) but reads only syntax, and the parser and nine other files call it. It belongs beside `Attribute` in `ast.odin`.

**Comments**

- [parser.odin:49](src/parser.odin#L49): delete; it is a stale fragment above a field whose trailing comment says what it holds.
- [parser.odin:36](src/parser.odin#L36): too narrow, since `open_header` sets it too. "The next `{` opens a body, not a composite literal: a `where` declaration's, or a header's that lost its `(`."
- [parser.odin:56](src/parser.odin#L56): drop "as before", which records history.
- [parser.odin:62](src/parser.odin#L62): "Not `mem.Dynamic_Arena`: it refuses allocations over its block size, and `append` drops that error."
- [parser.odin:220](src/parser.odin#L220): delete; it repeats line 40.
- [parser.odin:1077](src/parser.odin#L1077), [1155](src/parser.odin#L1155), [2015](src/parser.odin#L2015): delete; each restates the diagnostic directly below it.
- [parser.odin:1906](src/parser.odin#L1906): "`parallel{...}.run();` at statement start is this statement; one followed by a selector or adjacent call is reported as that literal." "now parses" records history.
- [parser.odin:980](src/parser.odin#L980): delete with the dead `expect` failures beneath it.

### src/parser.odin (part 2 of 2)

The expression and type grammar is sound and readable, and its comments are mostly good, but `proc` handling wrongly accepts two shapes and the argument probe can go exponential. The largest saving is boilerplate: the same list-loop and name-list tails repeat across some fifteen sites.

**Bugs**

- `BUG-parser.part2-1` **medium** [parser.odin:3426](src/parser.odin#L3426) `parse_proc`: a capture clause with no body returns the bare signature and drops the clause; grammar.md says such a header is a `Proc_Definition`. *Confirmed: `T :: proc() capture(y);` with undeclared y compiled with rc=0, and T worked as a type; grammar.md requires a Block after a clause and known-gaps has no entry. Severity is closer to low: accepts invalid code, no miscompile; in a local it gives a misleading L0378.*
  Scenario: `T :: proc() capture(y);` compiles with no diagnostic, and `y` need not exist.
  Fix: before the `switch`, report L0259 when `capture != nil` and no body follows; this also replaces the `bodiless` check at 3451.
- `BUG-parser.part2-2` **medium** [parser.odin:3392](src/parser.odin#L3392) `parse_proc`: the `signature_only` return skips the L0257 check at 3429, so a procedure type in result position may diverge. *Confirmed: Reproduced: `f :: proc() -> proc() -> ! { return g; }` builds with no L0257, even with non-diverging g, and the program runs. `!` is ignored: calls through it do not diverge (L0365), so this is accepts-invalid and severity is low, not medium.*
  Scenario: `f :: proc() -> proc() -> ! { return g; }` compiles; grammar.md "Procedures" allows `!` on declarations only.
  Fix: run the `result.diverges` check before this return as well.
- `BUG-parser.part2-3` **medium** [parser.odin:2751](src/parser.odin#L2751) `parse_argument_value`: a composite candidate is parsed twice, so array lengths holding such arguments double per level. *Confirmed: Reproduced on a valid 250-byte file: -parse-only took 0.34, 0.98, 3.6, 21.9 s at 16, 18, 20, 22 levels, since only proc literals are reused (line 2751). Not recorded in the docs. Severity is low rather than medium: only contrived nesting triggers it.*
  Scenario: `[g([g(...[1]int{}...)]int{})]int{}` nested 22 times, 250 bytes, takes 18 s under `-parse-only`, and grows about fourfold every two levels.
  Fix: reuse composite types as procedure literals are, `reuse := p.suppress == suppress && p.depth_reported == depth_reported`; `parse_postfix` then parses the body.
- `BUG-parser.part2-4` **low** [parser.odin:2377](src/parser.odin#L2377) `parse_unary`: parentheses leave no node, so a parenthesized slice counts as mutable slicing; grammar.md requires the slice to be the last suffix. *Not verified.*
  Scenario: `&mut (a[1:2])` compiles as a `[]mut T` while `&(a[1:2])` is L0357 (needs an addressable operand).
  Fix: also require `p.last.kind == .Rbracket`, which a closing `)` fails.
- `BUG-parser.part2-5` **low** [parser.odin:3704](src/parser.odin#L3704) `parse_results`: `signature_only` stays set inside expressions nested in the result type; only parameter defaults reset it (3380). *Not verified.*
  Scenario: `f :: proc() -> [g(proc() -> int { return 2; })]int { }` reports L0253 at the literal's `{`.
  Fix: clear it in `parse_argument_list`, as that proc already does for `no_composite`, and for the array length.
- `BUG-parser.part2-6` **low** [parser.odin:2841](src/parser.odin#L2841) `parse_primary`: the `)` expects here and at 2808 (`move`) do not mark the node, so statement recovery does not run and errors cascade. *Not verified.*
  Scenario: `x := (1 2);` reports L0219, L0209, L0216 and L0220 for one missing `)`.
  Fix: set `has_error` on `inner` and on the `Expr_Move` when the close is missing, as `parse_index_or_slice` does.
- `BUG-parser.part2-7` **low** [parser.odin:3204](src/parser.odin#L3204) `parse_anon_record_field`: this hint and those at 3217-3221 say "declare a `struct` for that", but a struct field has no default, mode or variadic (grammar.md `Field`). *Not verified.*
  Scenario: following the hint, `struct { a: int = 3 }` is L0253 and `struct { a: inout int }` is L0210.
  Fix: drop the advice from these four; it holds only for attributes (3223).
- `BUG-parser.part2-8` **low** [parser.odin:3752](src/parser.odin#L3752) `parse_generic_params`: a failed `$` expect falls through to the name expect, despite the "Avoid follow-up errors" comment at 3763. *Not verified.*
  Scenario: `S :: struct(1) { }` reports L0240 twice at the same token.
  Fix: only expect the name when the `$` was found.
- `BUG-parser.part2-9` **low** [parser.odin:2982](src/parser.odin#L2982) `parse_type`: `.Proc` may return a literal or group where only a `Proc_Type` is grammatical, and the checker then calls the user's error a compiler defect. *Not verified.*
  Scenario: `x: proc { a };` and `struct { a: proc() { } }` report L0350 "this is a compiler defect".
  Fix: report these shapes as ordinary errors and mark the node, which `report_unresolved_type` already honors.

**Simplification**

- [parser.odin:2198](src/parser.odin#L2198) `parse_expr`: the `or_else` arm builds the node twice. Parse into `exit` or `fallback`, then build once with `has_error` over all three. (about 6 lines)
- [parser.odin:2257](src/parser.odin#L2257) `parse_range`: replace the `reported` flag with `if` at a range op: report once, loop over the extras, then set `has_error` and `e.span.hi`. (about 4 lines)
- [parser.odin:2453](src/parser.odin#L2453) `parse_postfix`: `parse_argument_list` already folds each `expr_has_error(arg.value)` into `args_ok`, so delete this loop and the line at 3345. `parse_composite_body` does the same, so delete 2643-2645. (about 7 lines)
- [parser.odin:2506](src/parser.odin#L2506) `finish_postfix`: two call sites with the same arguments. Label the loop, `break` from both arms, and put the check once after the loop. (about 8 lines)
- [parser.odin:2698](src/parser.odin#L2698) `parse_argument`: `a.value = a.mode == .Value ? parse_argument_value(p) : parse_expr(p)`. (about 4 lines)
- [parser.odin:3058](src/parser.odin#L3058) `parse_anon_record_type`: `new_expr` already sets this span, as it does for 3147 in `parse_anon_union_type`. Delete both, and pass `open.lo` directly here. (about 3 lines)
- [parser.odin:3277](src/parser.odin#L3277) `parse_bracket_type`: `length := at(p, .Dollar) ? parse_type(p) : parse_expr(p)` as at 2949, and `_, closed := expect(...)` as at 3248. (about 7 lines)
- [parser.odin:3549](src/parser.odin#L3549) `parse_capture_entry`: use the existing `source_text_of(p, expr_span(path))`.
- [parser.odin:3602](src/parser.odin#L3602) `parse_parameter_list`: `ok` implies a name was appended, so the condition is just `len(param.names) > 0`.
- [parser.odin:3650](src/parser.odin#L3650) `parse_parameter`: test `at(p, .Caret) && receiver_type_omitted` before the switch so the pointer arm merges with `case:`, and share the `if !receiver_type_omitted` tail of the three mode arms. (about 10 lines)
- [parser.odin:3738](src/parser.odin#L3738) `parse_generic_params`: `if !allow(p, .Lparen) { return nil, true }`. (1 line)
- [parser.odin:3797](src/parser.odin#L3797) `parse_record`: `at := current(p); attributes := parse_attributes(p); groups := span_to_here(p, at)`, since `groups` is read only when attributes exist. (about 3 lines)
- [parser.odin:4014](src/parser.odin#L4014) `parse_requirement`: both paths end with the same `;` expect, sync and span. Parse the slot or expression form, then share that tail. (about 5 lines)
- [parser.odin:3365](src/parser.odin#L3365) `parse_proc`: `lo := advance(p).lo` where the token is otherwise unused, also at 3231, 3918, 3961, 4146 and 4187. (6 lines)

**Dead code**

- (branch) [parser.odin:4189](src/parser.odin#L4189) `parse_hook`: its only caller (1248) has passed `starts_hook`, which proves `(`, an identifier, `)` and `proc`. Delete the `opened`, `has_role` and `closed` handling and the non-`proc` arm at 4209. (about 10 lines)
- (branch) [parser.odin:4245](src/parser.odin#L4245) `parse_operator_symbol`: its only caller (1247) has passed `starts_operator`, so the final error, the `]` expects at 4230 and 4233, and `opened` at 4149 cannot fail. Only `closed` can, on `[:]=`. (about 10 lines)
- (branch) [parser.odin:2734](src/parser.odin#L2734) `parse_argument_value`: `!p.no_composite` is always true, because the only route here is `parse_argument_list`, which clears it at 2654.
- (branch) [parser.odin:2990](src/parser.odin#L2990) `parse_type`: `parse_record` has one return, a `^Type_Record`. Return that type and drop this test. (about 2 lines)
- (branch) [parser.odin:3183](src/parser.odin#L3183) `parse_anon_record_field`: `scans_label_list_colon` at 3166 already proved the list and its colon, so this `!ok` and the expect at 3192 cannot fail. (about 3 lines)
- (branch) [parser.odin:3376](src/parser.odin#L3376) `parse_proc`: a `.String` token always has both quotes, since the lexer returns `.Error` when unterminated (lexer.odin:579), so `len(raw) >= 2` is always true.

**Near copies**

- [parser.odin:3779](src/parser.odin#L3779), and 2629, 2663, 3476, 3572, 3605, 3832, 3905, 3943, 4095: the same four-line tail folds `malformed` and `separated` and breaks. Give `next_element` a `bad: ^bool` and return `more`: `if !next_element(p, .Rparen, malformed, "...", &bad) { break }`; the sites at 3766, 3817, 3880 and 4081 shrink too. (about 45 lines)
- [parser.odin:3751](src/parser.odin#L3751), 3181, 3888, 4067 and [parser.odin:982](src/parser.odin#L982): the same name-list loop. Share `parse_name_list(p, code, what, members: bool) -> ([]Name, bool)`; `$` at 3752 stays with its caller. `parse_generic_params` and `parse_bindings` then differ by a few lines; keep them separate. (about 25 lines)
- [parser.odin:2786](src/parser.odin#L2786), 2613, 3305, 3512, 3553: each builds an `Expr_Ident` by hand. Share `ident_expr(p, t: Token) -> ^Expr_Ident`; the `value.span =` lines at 3514 and 3555 repeat what `new_expr` computes, and the two capture sites merge. (about 10 lines)
- [parser.odin:2400](src/parser.odin#L2400) and [parser.odin:2730](src/parser.odin#L2730): both ask whether an expression is a procedure or capture literal. Share `is_proc_literal(e: Expr) -> bool`. (about 4 lines)
- [parser.odin:3050](src/parser.odin#L3050), 3116, 3127, 3173 and [parser.odin:2160](src/parser.odin#L2160): skip-until loops. Share `skip_to(p, kinds: ..Token_Kind)`, which also stops at EOF. (about 8 lines)

**Structure and boundaries**

- [parser.odin:3809](src/parser.odin#L3809) `parse_record`: the union branch inlines a 30-line member loop while the struct branch calls `parse_field_list`. Extract `parse_variant_list` so `parse_record` reads as one header and two member lists.
- [parser.odin:2988](src/parser.odin#L2988) `parse_type`: this 15-line arm in a dispatch table synthesizes the migrate-only attribute. Move it to `parse_move_only_record`, beside `reject_earlier_spelling` at 1212.

**Comments**

- [parser.odin:2373](src/parser.odin#L2373): delete; the next line says it.
- [parser.odin:2492](src/parser.odin#L2492): delete; it repeats the `case` list below and the grammar.md citation at 2463.
- [parser.odin:2525](src/parser.odin#L2525): delete; it restates the name. Likewise 3295, 3735, 3790 and 3915, which restate the code or grammar. (about 7 lines)
- [parser.odin:2680](src/parser.odin#L2680): delete; it narrates the condition. Likewise 2758 and 3172.
- [parser.odin:3601](src/parser.odin#L3601): wrong, since a "nameless receiver" is not what is kept. Write "A parameter with no name to report against is dropped."
- [parser.odin:3861](src/parser.odin#L3861): move to the `using` test at 3871, which it explains.
- [parser.odin:4184](src/parser.odin#L4184): delete; the parser accepts a group here and the checker rejects it with L0488, so it misleads.

### src/private_names.odin

Coherent and well tested on its main paths, but three drivers have grown around one by-name walk, so setup and guards repeat and the by-name model has gaps. Every bug below was reproduced with the `lokec.exe` built at this commit; roughly a sixth of the file could go.

**Bugs**

- `BUG-private_names-1` **medium** [private_names.odin:227](src/private_names.odin#L227) `read_impl`: `x.bound` keeps the block's `$` names after it returns, so later declarations see them as bound. Scenario: private `T :: struct {...}`, then `impl Box($T) {...}`, then `@(public) after :: proc() -> T`: no L0740; without the `impl` it warns. Fix: `defer clear(&x.bound)` in `read_impl`. *Confirmed: Reproduced: private T, impl Box($T), then @(public) after -> T gives no L0740; removing the impl or moving after above it warns at 9:20. Not recorded anywhere. Severity is low: a missed warning, only when a private name equals a block's $ name.*
- `BUG-private_names-2` **medium** [private_names.odin:153](src/private_names.odin#L153) `collect_named`: `impl Box(int)` and `impl Box(string)` share one member table and the last block wins, so `member_selected` can read the wrong one. Scenario: `Inner` public in the first, private in the second: `Twin(Box(int).Inner, int)` warns falsely; with the blocks swapped, `Twin(Box(string).Inner, int)` does not warn. Fix: resolve a selection with no `$` name in a probe, as `resolves_to_type` does. *Confirmed: Reproduced: Box(int).Inner warns L0740 citing Box(string)'s private Inner though an importer can name it; swapped blocks, Box(string).Inner gives no warning though an importer gets L0432. Only a wrong or missing warning, so low rather than medium.*
- `BUG-private_names-3` **low** [private_names.odin:376](src/private_names.odin#L376) `read_group`: a group in an `impl` can list only that block's members (L0395), but `lookup` tries package names first. Scenario: public package `helper` beside private member `helper :: proc(f: Fill)` in `grp :: proc{helper, other}`: no warning; with a private package `helper`, that one is reported instead. Fix: read `x.members[x.subject]` when in an `impl`. *Not verified.*
- `BUG-private_names-4` **low** [private_names.odin:269](src/private_names.odin#L269) `read_public_decl`: a procedure literal's written type is never read, though the spec lists "a constant's written type". Scenario: private `Sig :: distinct proc(x: int)`, `@(public) f: Sig : proc(x: int) {}`: no L0740, while `n: Num : 3` warns. Fix: `walk(x, d.declared_type, .Type)` before `read_signature`. *Not verified.*
- `BUG-private_names-5` **low** [private_names.odin:882](src/private_names.odin#L882) `instantiates_generic_record`: a parametric alias's application is not classified as a type. Scenario: in `impl Box($T)` with no instance, `@(public) A :: Pair(T, Corner)` warns but `@(public) B :: Two(T, Corner)`, for `Two :: Pair($A, $B)`, does not; an instance does warn. Fix: also accept `.Alias`, and rename. *Not verified.*
- `BUG-private_names-6` **low** [private_names.odin:403](src/private_names.odin#L403) `read_record`: a field's visibility and padding tests look only at its first name. Scenario: `@(public) _, a: Fill` gives no L0740; `@(public) a, _: Fill` warns for `Rec.a` and again for `Rec._`. Fix: loop over names, skip `_`, test `field.symbols` per name. `field_shown` ([doc.odin:1106](src/doc.odin#L1106)) has the same first-name test. *Not verified.*
- `BUG-private_names-7` **low** [private_names.odin:588](src/private_names.odin#L588) `walk`: an array length is walked in `.Type` position, so a type named inside it warns, though the spec exempts an array length as a value. Scenario: `@(public) f :: proc(a: [size_of(Priv)]int)` warns, while `@(public) N :: size_of(Corner)` is pinned as not reported. Fix: walk the length only in `.Where` position. *Not verified.*
- `BUG-private_names-8` **low** [private_names.odin:761](src/private_names.odin#L761) `private_type_in`: `depth > 8` silently stops the read, though `selected_member`'s comment says the spec sets no limit. Scenario: `@(public) D :: [1][1][1][1][1][1][1][1][1][1]Fill{}` gives no L0740; `[1][1]Fill{}` warns. Fix: guard any cycle with a visited slice instead of a depth. *Not verified.*
- `BUG-private_names-9` **low** [private_names.odin:212](src/private_names.odin#L212) `subject_name`: returns "" for a subject that is not a name, losing both the subject in the owner and the private-subject exemption. Scenario: private `Hid`, `impl ^Hid { @(public) g :: proc() -> Corner ... }` warns as "public `g`", while the same member in `impl Hid` is exempt. Fix: unwrap `^` in `subject_name`. *Not verified.*

**Simplification**

- [private_names.odin:175](src/private_names.odin#L175) `add_named`: a constant binds exactly one name (L0233, [parser.odin:1078](src/parser.odin#L1078)) and `.Var` never reaches these, so the `for name, index in d.names` loops here and at lines 263, 856, 925, 949 reduce to `d.names[0]`, with one `decl_symbol(c, d)` helper for lines 180, 276, 926, 950. (about 20 lines)
- [private_names.odin:23](src/private_names.odin#L23) `check_private_names`: the same "exports nothing" guard is at lines 23, 813, 901 and 1018; use one `package_exports_names(pkg)`. (about 6 lines)
- [private_names.odin:26](src/private_names.odin#L26) `check_private_names`: the arena, `diagnostic_allocator` pin and allocator swap repeat at lines 973 and 1042; keep the arena in `Exposure` with an open and a close proc, leaving a line or two at each driver. (about 12 lines)
- [private_names.odin:681](src/private_names.odin#L681) `found_name`: the two `warnf` calls differ only in their opening; compute it once and make one call. (about 7 lines)
- [private_names.odin:735](src/private_names.odin#L735) `report_constant_type`: inline it at its one call site, line 313, as `if found := private_type_in(...); found != nil`, and drop the nil guard in `report_private_constant`, whose other caller has already tested it. (about 7 lines)
- [private_names.odin:267](src/private_names.odin#L267) `read_public_decl`: `name if subject == "" else concatenate(...)` is also at lines 381 and 1067; one `qualified(subject, name)` serves them and the plain joins at 660, 1112 and 1149. (about 4 lines)
- [private_names.odin:287](src/private_names.odin#L287) `read_public_decl`: `case ^Type_Distinct` is covered by the default branch: `writes_type` is true, `walk` has the arm, and a parametric `distinct` is rejected (L0744). (2 lines)
- [private_names.odin:482](src/private_names.odin#L482) `bind_poly`: a one-line wrapper of `poly_names`; call that directly. (3 lines)

**Dead code**

- (branch) [private_names.odin:232](src/private_names.odin#L232): this `resize(&x.bound, mark)` and the one at line 995 undo nothing, since every path through `read_public_decl` already restores `bound`.
- (branch) [private_names.odin:385](src/private_names.odin#L385): this `start(x, owner, "")` and the one at line 411 are overwritten: `read_public_decl` is the only caller and nothing is read before its next `start`.
- (branch) [private_names.odin:262](src/private_names.odin#L262): parameter `subject` equals `x.subject` at every call that can report (lines 44, 49, 231, 994, 1064); use the field and delete the comment at line 260.
- (branch) [private_names.odin:374](src/private_names.odin#L374): parameter `owner` of `read_group`, and of `read_record` at line 389, always equals `x.owner`, set by `start` at line 268.
- (branch) [private_names.odin:264](src/private_names.odin#L264): this `_` test and the one at line 951 cannot fire: all callers gate on `decl_is_public`, which rejects a `_` name, and a constant has one name.
- (branch) [private_names.odin:507](src/private_names.odin#L507): `lookup`'s member fallback fires for `walk` only in invalid programs: an unqualified member in a signature or value is L0306 or L0315, in plain and generic blocks. Only `read_group` needs members, so `lookup` can be file scope only.
- (branch) [private_names.odin:611](src/private_names.odin#L611): `walk`'s `^Type_Record` arm needs a record in type position, which L0717 rejects; declared records go through `read_record`. It also reads private fields.
- (branch) [private_names.odin:736](src/private_names.odin#L736): `x.scope != nil` cannot fail: the pass runs only once the package's scope exists ([check.odin:232](src/check.odin#L232)).
- (branch) [private_names.odin:811](src/private_names.odin#L811): `is_call` is always true, because the sole caller ([impl.odin:364](src/impl.odin#L364)) tested it; pass `call` in.

**Data structures and algorithms**

- [private_names.odin:982](src/private_names.odin#L982) `read_instance_declarations`: `exposure_of` rescans the whole package, so B generic blocks cost B x D, and an undecided declaration costs D per instance. Small today, but the syntax pre-pass at line 1028 exists only to avoid it. One table per package, built once, removes the pre-pass and most of the arena copies. (about 30 lines)
- [private_names.odin:161](src/private_names.odin#L161) `collect_named`: `blocks` gets an entry for every `impl` member on every build, but only line 1055 reads it, for one declaration; a per-package table settles this too.

**Near copies**

- [private_names.odin:515](src/private_names.odin#L515) `walk`, [doc.odin:578](src/doc.odin#L578) `api_refs` and [ast.odin:1388](src/ast.odin#L1388) `type_syntax_any_name` repeat one recursion and have drifted: the other two visit a composite's `via`, `walk` does not. A shared `syntax_children(e, out)`, like the `parts` in `pattern_shape`, leaves `walk` the Ident, Selector, `Type_Proc` and Composite arms. (about 60 lines here)
- [private_names.odin:488](src/private_names.odin#L488) `poly_names` and [doc.odin:781](src/doc.odin#L781) `bind_poly_names` are identical; so are [private_names.odin:473](src/private_names.odin#L473) `bind_generic` and [doc.odin:771](src/doc.odin#L771) `bind_generic_params`. Keep one of each, not file-private. (about 15 lines)
- [private_names.odin:417](src/private_names.odin#L417) `field_is_exported` and [doc.odin:1106](src/doc.odin#L1106) `field_shown` have one body; doc's `package_name == "main"` is always false here, since this pass skips `main`. Share `field_exported(c, file, field)`. (about 9 lines)
- [private_names.odin:827](src/private_names.odin#L827) `read_generic_impl_constants` hand-writes [generic.odin:380](src/generic.odin#L380) `declare_stand_in`; drop that proc's `@(private = "file")` and call it. (2 lines)
- [private_names.odin:840](src/private_names.odin#L840) and [private_names.odin:860](src/private_names.odin#L860) (with [generic.odin:345](src/generic.odin#L345) as a third) repeat probe, swap scope, clear `reached`, check a clone, restore; they differ only in the check. A local helper taking the expression and an `as_type` flag merges the two here. (about 4 lines)

**Structure and boundaries**

- [private_names.odin:961](src/private_names.odin#L961): `private_constants_read` ([source.odin:160](src/source.odin#L160)) holds three kinds of settled read, keyed by a name, a written type or a value span, and only one concerns a constant. Rename it `private_reads_settled`. The comment at [source.odin:165](src/source.odin#L165) says "public" members, though line 854 classifies private ones too.
- [private_names.odin:810](src/private_names.odin#L810) `read_generic_impl_constants`: 65 lines that both classify members and report constants. The seam is a `member_is_type(k, stand_ins, d, value)` helper for the classification, leaving this proc the loop and the report.
- [private_names.odin:240](src/private_names.odin#L240): "the subject is private" is decided separately here, at line 822 and at line 909. Lines 822 and 909 test the same thing on a symbol and can share `is_private_to(symbol, pkg)`.
- [private_names.odin:43](src/private_names.odin#L43): this checker pass calls `decl_is_public`, which lives in `doc.odin`, the `-doc` owner. Move it beside `written_is_public` in `check.odin`.

**Comments**

- [private_names.odin:8](src/private_names.odin#L8): cut lines 10-18 to two sentences: the walk is over written syntax by name, as the interface file reads it; `read_generic_impl_constants`, `check_instance_private_names` and `check_generic_private_names` cover what only resolution or an instance can say. (about 50 lines across the file; 170 of its 1151 lines are comments)
- [private_names.odin:801](src/private_names.odin#L801): delete this paragraph except "A member whose value is a type is a type alias, read by its target's syntax in `check_private_names`"; the rest recites the classification below it.
- [private_names.odin:835](src/private_names.odin#L835): delete; it repeats lines 804-805.
- [private_names.odin:854](src/private_names.odin#L854): delete; it repeats lines 820-821. Likewise line 904, which repeats lines 215-217.
- [private_names.odin:892](src/private_names.odin#L892): shorten to "The block's public declarations are read here too, since only an instance says whether a private member they select is a type."
- [private_names.odin:1002](src/private_names.odin#L1002): keep the citation and "read per instance, with the checker in its scope"; the list of declaration kinds repeats the spec, and lines 1007-1009 repeat it again.
- [private_names.odin:303](src/private_names.odin#L303): drop "A type alias's target.", which line 290 says; keep the sentence on `$` names.
- [private_names.odin:621](src/private_names.odin#L621): shorten the last sentences to "A chain of selections is followed until it repeats a member."
- [private_names.odin:1122](src/private_names.odin#L1122): delete; it reads the switch below it aloud.

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
- [queries.odin:499](src/queries.odin#L499) `build_snapshot_queries`: write `definition` as `written ? symbol.span : no_span()` and nest the document append under one `if written`, removing the `else` at line 509. (about 3 lines)
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
- [queries.odin:536](src/queries.odin#L536) and [query_index.odin:9](src/query_index.odin#L9): the hand-written span check is `valid_query_span(c, span)`; an empty span falls through to the type name as it does now. (about 1 line)

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

- (branch) [query_index.odin:9](src/query_index.odin#L9): `span.file != NO_FILE` never decides. `NO_FILE` is `max(u32)`, so the next clause, `int(span.file) < len(c.sources)`, already rejects it.
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
- [query_index.odin:9](src/query_index.odin#L9) and [queries.odin:536](src/queries.odin#L536): the latter hand-writes the bounds checks of `valid_query_span`; an empty span yields the same `text == ""` there, so it can call the helper.

**Structure and boundaries**

- [query_index.odin:6](src/query_index.odin#L6): the walk's driver is at [queries.odin:572](src/queries.odin#L572), so `index_query_item`, `_decl` and `_expr` are package-wide and visible to `lsp`, as are `valid_query_span` and `written_query_binding`. Move the driver here as one `@(private)` entry point and make the rest file-private, except `written_query_binding`, which is `@(private)`.

**Comments**

- [query_index.odin:182](src/query_index.odin#L182): shorten to: `design.md "Promoted struct fields": a promoted selector's added links carry the name's span, so the written operand is below them, and below any implicit `p^`, since the pointer's own members come first (design.md "Methods and implementation blocks").` (about 2 lines)
- [query_index.odin:59](src/query_index.odin#L59): delete; [queries.odin:458](src/queries.odin#L458) already says what `regions` holds and this proc is one line.

### src/reflect.odin

Correct on the main paths; the weak spot is `typeid_sort_key`, whose key is neither injective nor independent of `Type_Id` as its comment claims. The descriptor half is very repetitive and could lose about a quarter of its lines.

**Bugs**

- `BUG-reflect-1` **low** [reflect.odin:666](src/reflect.odin#L666) `typeid_sort_key_walk`: the proc shape omits `param_escapes` and `param_cross_thread`, which `proc_type` interns on (semantic.odin:1252), so two proc types tie. Scenario: `proc(@(escape=stored) p: ^int)` and `proc(p: ^int)`: swapping their `typeid_of` statements swapped IDs 8 and 9; a control pair kept its IDs. Fix: add both to the `:p` entry. *Not verified.*
- `BUG-reflect-2` **low** [reflect.odin:646](src/reflect.odin#L646) `typeid_sort_key_walk`: the `named:` key is the display name, and "unique compilation-wide" is false for `Range(Token)`, iterators and views. Scenario: `Range(a.Token)` and `Range(b.Token)` tie; swapping the requests swapped IDs 1 and 2. Fix: append the `element` and `key` sub-keys to `named:`. *Not verified.*
- `BUG-reflect-3` **low** [reflect.odin:583](src/reflect.odin#L583) `typeid_sort_key_walk`: distinct types share a key and number by request order: `Box(int)` of a local generic `Box` in two procs (the instance path lacks line 595's scope suffix), a local type in each `foreach` expansion, and two in-place `distinct int`. Scenario: their `.ll` labels are equal bar the emitter's suffix. Fix: scope suffix on instances, an expansion index. *Not verified.*
- `BUG-reflect-4` **low** [reflect.odin:495](src/reflect.odin#L495) `write_applied_args`: `const_key_text` spells a `typeid_of(T)` inside a value argument as raw `t<Type_Id>` (generic.odin:1563), against line 534's "independent of ... allocation order". Scenario: with `Foo :: struct($v: Rec)`, reordering the declarations of `T1` and `T2` swaps the IDs of `Foo(Rec{typeid_of(T1), 1})` and its `T2` twin. Fix: key `.Type` values with `typeid_sort_key_walk`. *Not verified.*
- `BUG-reflect-5` **low** [reflect.odin:746](src/reflect.odin#L746) `check_reflection_builtin`: a failed operand is reported twice. Scenario: `typeid_of(Nope)` and `fields_of(Nope)` give L0315 and then L0451 "needs a type" at the same span. Fix: snapshot `k.c.error_count` before `check_single_expr` and report L0451 only if it did not grow (as check_builtin.odin:506). *Not verified.*

**Simplification**

- [reflect.odin:708](src/reflect.odin#L708) `check_reflection_builtin` and [reflect.odin:844](src/reflect.odin#L844) `check_descriptor_operation`: 14 `v.type = INVALID_TYPE` lines before returns. Set it once (at the top; at line 841 in the second), as `check_assert_or_panic` does, and let each failure just return. (about 14 lines)
- [reflect.odin:774](src/reflect.odin#L774) `check_reflection_builtin`: the `.Fields_Of`, `.Enum_Values_Of` and `.Variants_Of` cases differ in the callee and one word. Pick `type, value, ok` and `wanted` in the switch, then share one error and one assignment. (about 15 lines)
- [reflect.odin:563](src/reflect.odin#L563) `typeid_sort_key_walk`: `visiting` is redundant. Store the sentinel in `memo[type]` before walking and overwrite it in the `defer`; the first lookup then answers both. Removes a map and a parameter from 3 procs. (about 12 lines)
- [reflect.odin:584](src/reflect.odin#L584) `typeid_sort_key_walk`: six `strings.builder_make` calls, each ending in `to_string`. Make one builder after the `info == nil` check. (about 6 lines)
- [reflect.odin:654](src/reflect.odin#L654) `typeid_sort_key_walk`: `b`, `s` and `a` add nothing here: `signed` and `written_align` are set only on predeclared and declared types, which returned earlier, and `bits` follows from `kind`. Use `"shape:%d:m%t"`. (about 3 lines)
- [reflect.odin:589](src/reflect.odin#L589) `typeid_sort_key_walk`: `info.symbol != INVALID_SYMBOL` is implied by `sym != nil`; lines 687 and 875 already rely on `symbol_of` answering nil. (1 condition)
- [reflect.odin:695](src/reflect.odin#L695) `typeid_value`: an Odin map index yields zero when the key is absent, so the body is `return c.typeid_values[type]`. (about 3 lines)

**Dead code**

- (branch) [reflect.odin:99](src/reflect.odin#L99): `new_type` has just returned this id, so `info` cannot be nil.
- (branch) [reflect.odin:835](src/reflect.odin#L835): every `meta.Field` constant comes from line 223 with four elements, and hand-written literals are refused (L0453 on `meta.Field{}`, also inside `foreach`), so a nil or short aggregate cannot get past lines 816 and 821.

**Data structures and algorithms**

- [reflect.odin:415](src/reflect.odin#L415) `freeze_typeids`: each requested type gets a fresh memo, so shared sub-keys are rebuilt per requester and kept in the semantic arena; cost grows as requested types times graph size, and `fmt` closes the set over reachable types. Freeze runs only after a clean check (session.odin:166), so no sentinel can arise: one temp-allocated memo can span the loop. Modest in practice.

**Near copies**

- [reflect.odin:20](src/reflect.odin#L20), [reflect.odin:38](src/reflect.odin#L38), [reflect.odin:56](src/reflect.odin#L56): the three lazy `meta_*_type` procs differ in cache slot, name and second member. Use `descriptor_type(c, &c.meta_field_type, "meta.Field", "type", TYPE_TYPE)`; it writes the four members and `Descriptor_Field` goes. (about 30 lines)
- [reflect.odin:216](src/reflect.odin#L216), [reflect.odin:245](src/reflect.odin#L245), [reflect.odin:267](src/reflect.odin#L267), [reflect.odin:292](src/reflect.odin#L292): four copies fill name, payload, index, owner. All three descriptors share that layout (expand.odin:194 already reads `META_FIELD_NAME` from any), so one `descriptor_const(c, type, name, payload, index, owner)` and 4 constants replace them and the 12 `META_*`. (about 25 lines)
- [reflect.odin:90](src/reflect.odin#L90) and [semantic.odin:1103](src/semantic.odin#L1103): the `new_symbol` literal is exactly `new_field(c, name, type, index, public = ...)`. Call that. (about 7 lines)
- [reflect.odin:317](src/reflect.odin#L317) and [const_ops.odin:73](src/const_ops.odin#L73): `typeid_const` is `type_const` byte for byte. Delete it and call `type_const` at line 772. (about 4 lines)
- [reflect.odin:307](src/reflect.odin#L307) and [simd.odin:291](src/simd.odin#L291), [check_builtin.odin:1378](src/check_builtin.odin#L1378), [enums.odin:83](src/enums.odin#L83), [check_expr.odin:3332](src/check_expr.odin#L3332): `aggregate_const` is the 3-line form these write by hand. Move it to const_ops.odin; only its `type_value = type` differs, and I found no reader of that on an aggregate.
- [reflect.odin:196](src/reflect.odin#L196) and [check_builtin.odin:1374](src/check_builtin.odin#L1374), [check_expr.odin:331](src/check_expr.odin#L331), [emit_llvm_runtime.odin:1167](src/emit_llvm_runtime.odin#L1167): `string_view_const` is a private spelling of `Const_Value{kind = .String, text = ...}`. Make it `string_const` beside `rune_const` in const_ops.odin.
- [reflect.odin:163](src/reflect.odin#L163) and [reflect.odin:447](src/reflect.odin#L447): both list element, key, result, parameters, variants and struct fields. A temp-allocated `type_components(c, info) -> []Type_Id` beside `Type_Walk` in semantic.odin reduces each to one loop; neither is hot. (about 15 lines)
- [reflect.odin:689](src/reflect.odin#L689) and [reflect.odin:596](src/reflect.odin#L596): the contract key spells package, name and position by hand, with a source path. Use `symbol_key` plus `declaring_file_index` as the local-type key does, in one `symbol_site_key`. (about 2 lines)

**Structure and boundaries**

- [reflect.odin:554](src/reflect.odin#L554) `typeid_sort_key_walk`: 140 lines. The natural seam is line 652: `write_shape_key` for the structural tail, leaving the walker as identity dispatch.
- [reflect.odin:540](src/reflect.odin#L540): `typeid_sort_key` also builds backend labels for anonymous types (semantic.odin:1576, 1633), and lines 314-700 share almost nothing with the descriptors. They would stand alone as `typeid.odin`.

**Comments**

- [reflect.odin:547](src/reflect.odin#L547): the first sentence is false: keys embed child keys as text, so length follows the expanded tree (`Pair(P, P)` doubles per level). Say "Memoization saves rework, not key length."
- [reflect.odin:645](src/reflect.odin#L645): delete with BUG-reflect-2's fix; it contradicts line 535.
- [reflect.odin:3](src/reflect.odin#L3): drop "reusing the existing constant representation instead of inventing a third one".
- [reflect.odin:201](src/reflect.odin#L201): keep the citation and "observes only what is visible from the lookup package"; the "cannot leak" clause is obscure, since an array formed in the declaring package does hold private fields.
- [reflect.odin:255](src/reflect.odin#L255): shorten to `Every member and variant is listed (design.md "Compile-time reflection"); an enum member's value stays enum_values_of's.`
- [reflect.odin:386](src/reflect.odin#L386) and [reflect.odin:411](src/reflect.odin#L411): both explain the non-capturing sort; keep "stable, so equal keys keep request order" at line 411 and delete line 386's.
- [reflect.odin:394](src/reflect.odin#L394): repeats the header at lines 8-11. Shorten to "Numbers requested types by canonical key, from 1."
- [reflect.odin:572](src/reflect.odin#L572): shorten to "Distinct identities can share a shape (`int`, `i64`), so these key on their name."
- [reflect.odin:906](src/reflect.odin#L906) and [reflect.odin:914](src/reflect.odin#L914): both restate the spec paragraph; cite design.md "Compile-time reflection" and keep "a place, so nothing drops it as a temporary". (about 20 lines across the file)

### src/region.odin

Small and well scoped; what is left is the walk over owned parts it shares with several files.

**Near copies**

- [region.odin:123](src/region.odin#L123), [hooks.odin:370](src/hooks.odin#L370), [hooks.odin:330](src/hooks.odin#L330), [hooks.odin:165](src/hooks.odin#L165) and [borrow.odin:761](src/borrow.odin#L761): the same switch over owned parts (element, key, field types, variants). A `type_owned_part_next(c, info, &i)` iterator would reduce each to a `for` over parts and give one place to define what is owned, which is where the `Shared` bug above sits.

### src/select.odin

The selection fixed point is sound in outline and has no dead procedures, but a condition is only checked for its direct names, which wrongly rejects ordinary programs. The name walker and the two activation entry points can lose roughly a fifth of the file.

**Bugs**

- `BUG-select-1` **high** [select.odin:176](src/select.odin#L176) `resolve_item_when`: only names written in the condition are tested, so one reached through a declared constant or type is evaluated too early. *Confirmed: Reproduced L0315 via N :: size_of(Handle), L0306 only once a when reads S (S alone compiles); design.md "Constant declarations" allows any order, no gap recorded. Worse: with a when-supplied byte :: i64, N :: size_of(byte) stays 1 and picks the wrong branch silently.*
  Scenario: `when (LOKE_ARCH == .Amd64) { Handle :: rawptr; } else { Handle :: int; } N :: size_of(Handle); when (N == 8) {...}` gives L0315 unknown `Handle` (`S :: struct { x: T }` likewise gives L0306); run on this commit's `lokec.exe`.
  Fix: have the walk follow each resolved package-scope symbol's declaration, with a seen set, so the condition stays pending.
- `BUG-select-2` **medium** [select.odin:366](src/select.odin#L366) `first_unresolved_name`: a name found in the universe counts as answered, though a branch not yet selected may shadow it (design.md "when statement": as if written in place). *Confirmed: Reproduced: the when-supplied `string :: i32` prints `2 4`, even with that when written first; a direct declaration prints `1 4`. Conditions resolve against the universe within a round; no gap or decision is recorded. Silent, but contrived: low-to-medium.*
  Scenario: `when (size_of(string) == 4) { A :: 1; } else { A :: 2; } when (true) { string :: i32; }` prints `2 4`; with `string :: i32;` written directly it prints `1 4`. The wrong branch is taken silently.
  Fix: report when a selected branch declares a name an answered condition read from the universe, or wait on universe names while others are pending.
- `BUG-select-3` **low** [select.odin:475](src/select.odin#L475) `first_unresolved_name`: `^Expr_Proc` is listed as having nothing to wait on, but its signature names types, and the walk covers `^Type_Proc` for that reason. *Not verified.*
  Scenario: `when (size_of(proc(x: T) {}) == 8) {...} when (true) { T :: int; }` gives L0306, while `T :: int;` at file scope compiles.
  Fix: `case ^Expr_Proc: return first_unresolved_name(k, v.signature)`.

**Simplification**

- [select.odin:313](src/select.odin#L313) `first_unresolved_name`: add a variadic `first_unresolved_in(k, ..Expr)`, so `^Expr_Cond` becomes `return first_unresolved_in(k, v.cond, v.then, v.otherwise)`; likewise Array, Map, Postfix, Binary, Slice, Range, Or_Else. (about 25 lines)
- [select.odin:72](src/select.odin#L72) `collect_pending_whens`: the nil-`out` mode and `found` serve only `package_has_pending_whens`, which can collect into a temp array and test `len`; early exit helps only while something is pending, and an empty array allocates nothing. (about 10 lines)
- [select.odin:239](src/select.odin#L239) `self_bootstrap_import`: make `find_import_binding` take one `Item` (Import, Block, When over `then` and `otherwise`; nil falls through) and call it with `item` at line 220. The helper and its temp array go. (about 10 lines)
- [select.odin:502](src/select.odin#L502) `when_selected_block`: equals `s.selected`, since only `check_when_stmt` sets it, after `resolved`, nothing resets it and clones copy neither; [query_index.odin:154](src/query_index.odin#L154) already reads it directly. Replace the seven calls. (about 5 lines)
- [select.odin:373](src/select.odin#L373) `first_unresolved_name`: merge the two identical `concat` returns: `if target != nil && target.scope != nil && intern_identifier(k.c, v.name.text) in target.scope.names { return "" }`, then one return. (about 4 lines)
- [select.odin:392](src/select.odin#L392) `first_unresolved_name`: move `^Expr_Propagated_Error` into the nothing-to-wait-on list at line 475. (2 lines)
- [select.odin:28](src/select.odin#L28) `rebuild_active_items`: `file.active_items = slice.clone(out[:], c.semantic_allocator)` replaces the `make` and `copy`. (2 lines)

**Dead code**

- (branch) [select.odin:213](src/select.odin#L213): `missing == ""` cannot occur. Both callers report right after a round with no progress, and `resolve_item_when` settles any pending `when` with no missing name. No test expects the bare message.
- (branch) [select.odin:149](src/select.odin#L149) and [select.odin:197](src/select.odin#L197): the `pkg == nil || pkg.scope == nil` guards. Both callers ([packages.odin:49](src/packages.odin#L49), [incremental.odin:109](src/incremental.odin#L109)) have run `prepare_package`, which creates the scope, on every such package.
- (branch) [select.odin:127](src/select.odin#L127) and [select.odin:132](src/select.odin#L132): `int(id) >= len(seen)` and `pkg == nil`. `seen` spans `c.packages`, which the walk does not grow, and `package_of` returns nil only for ids already excluded (`INVALID_PACKAGE` is 0).

**Data structures and algorithms**

- [select.odin:120](src/select.odin#L120) `package_closure_has_pending_whens`: [check.odin:171](src/check.odin#L171) calls it per `impl` per `prepare_package`, already-declared blocks included, and each call allocates `seen` and scans every item in the closure: impls x closure items x rounds. Test `!impl.declared` first and keep a per-package settled flag, as having no pending `when` is final.
- [ast.odin:1294](src/ast.odin#L1294) `Item_When`: `resolved`, `taken`, `stalled` encode four states in three bools; `resolved` and `stalled` are never both set ([select.odin:186](src/select.odin#L186), [select.odin:189](src/select.odin#L189), [select.odin:211](src/select.odin#L211)), so `!node.stalled` at [doc.odin:426](src/doc.odin#L426) tests nothing. An enum `Pending, Taken, Not_Taken, Stalled` fits.

**Near copies**

- [select.odin:148](src/select.odin#L148) and [select.odin:196](src/select.odin#L196): the same location save, scope setup, file loop and pending collection around a different per-item action. Share `visit_pending_whens(k, pkg, visit: proc(^Checker, ^Item_When) -> bool) -> bool`; `activate_when_items` keeps only `impls_declaring`. (about 10 lines)
- [select.odin:44](src/select.odin#L44), [select.odin:77](src/select.odin#L77), [intrinsic.odin:355](src/intrinsic.odin#L355) and [query_index.odin:107](src/query_index.odin#L107): each decides the selected branch from `resolved` and `taken`. Share `item_when_selected(v) -> Item`, nil when none, the file-scope counterpart of `s.selected`; this also removes `[1]Item` at line 91. (about 8 lines)
- [select.odin:293](src/select.odin#L293) and [box.odin:34](src/box.odin#L34): `callee_is_builtin` and `box_callee` differ only in the kind. Drop the `file` privacy and make `box_callee` call it with `.Box_New`. (about 5 lines)
- [simd.odin:15](src/simd.odin#L15), [iterate.odin:68](src/iterate.odin#L68) and [box.odin:45](src/box.odin#L45), combined at [select.odin:440](src/select.odin#L440): the same procedure but for the spelling. Share `unbound_callee(k, callee, name)`, and at line 440 test only once `missing != ""` rather than three lookups on every call.

**Comments**

- [select.odin:1](src/select.odin#L1): the header claims procedure scope too, but that selection is `check_when_stmt` ([check.odin:3480](src/check.odin#L3480)), tied there by the file-private `check_stmt_sequence`. Say "File-scope selection, and the condition rule both scopes share."
- [select.odin:3](src/select.odin#L3): lines 3-6 repeat the spec at length. Shorten to: `design.md "when statement": an unselected branch is parsed and nothing else.`
- [select.odin:16](src/select.odin#L16): delete the first sentence, keeping "Parser-owned item lists are never mutated" and why an unchanged view keeps its array.
- [select.odin:103](src/select.odin#L103): "selects neither branch" is restated at lines 79-80, 103-104, 181-185 and 209-210, and on `Item_When.stalled`. Delete 103-104 and 209-210; make 181-185 "Rejected: settles as stalled, as `check_when_stmt` does; `false` would check the `else` on a refused condition."
- [select.odin:306](src/select.odin#L306): shorten lines 306-312 to "Type syntax counts: `size_of(^T)` depends on `T` as `size_of(T)` does." The record and enum clause misleads, since L0717 rejects both when written in place; "the switch is exhaustive" is what the code shows.
- [select.odin:236](src/select.odin#L236): delete; it restates the name and signature. Lines 444-445 repeat line 304, so drop the `build_config` key from line 304. (about 18 lines across the file)

### src/semantic.odin

The stores and interning are sound, and the `Symbol` and `Type_Info` definitions are mostly justified "why" comments. The bugs are small; the larger payoff is merging the two type walks, collapsing the kind predicates and procedure-type copies, removing a CPU feature model nobody reads, and moving about 700 lines of type queries to their own file.

**Bugs**

- `BUG-semantic-1` **low** [semantic.odin:2426](src/semantic.odin#L2426) `proc_type_name`: `c_vararg` and `param_by_ptr` are part of type identity but are not printed. Scenario (run): `f: proc "c" (fmt: cstring_view) -> i32 = printf;` with a `@(c_vararg)` `printf` reports "cannot initialise `proc "c"(cstring_view) -> i32` with `proc "c"(cstring_view) -> i32`". Fix: print `..` and `@(by_ptr)`. *Not verified.*
- `BUG-semantic-2` **medium** [semantic.odin:1463](src/semantic.odin#L1463) `intern_type`: the first interner's `Type_Info` wins, and [check.odin:1929](src/check.odin#L1929) hand-writes `[^]T` without the `bits` that `c_pointer_to` sets. Scenario (run): `type_info_of(typeid_of([^]u8)).bits` prints 0, but 64 once an earlier `unsafe.raw_data` has interned it. Fix: call `c_pointer_to` there. *Confirmed: Reproduced: `[^]u8` bits prints 0 if typeid_of precedes raw_data, 64 if it follows; `[^]u16` gives 64 and `[^]u32` 0 in one program. Not recorded in the docs. Severity is low, not medium: only reflected `bits` shows it and no bundled .loke code reads it.*
- `BUG-semantic-3` **low** [semantic.odin:1080](src/semantic.odin#L1080) `intern_identifier`: it keeps the caller's string, and [proc_contracts.odin:147](src/proc_contracts.odin#L147) passes a temp one. Scenario (from reading, not run): a checkpointed package joins two callbacks; [incremental.odin:309](src/incremental.odin#L309) destroys the scratch arena; printing that proc type reads released memory. Fix: clone on a miss. *Not verified.*

**Simplification**

- [semantic.odin:1893](src/semantic.odin#L1893) `type_is_untyped` through `type_is_aggregate`: seven `#partial switch` predicates become one line each, `return underlying_kind(c, id) in Type_Kinds{.Int, .Untyped_Int}`, with `Type_Kinds :: bit_set[Type_Kind]`. (about 28 lines)
- [semantic.odin:1259](src/semantic.odin#L1259) `intern_proc_type`: four make-and-copy blocks plus `has_reset_effect`, `has_escape_level`, `equal_reset_effects` and `equal_escape_levels` reduce to two polymorphic helpers, `equal_padded(a, b, default)` and `clone_unless_default(xs, default, allocator)`, with `slice.clone` for the rest. (about 30 lines)
- [semantic.odin:1450](src/semantic.odin#L1450) `equal_type_ids`, `equal_param_modes`: both are `slice.equal`; `core:slice` is already used across the package. (about 10 lines)
- [semantic.odin:1463](src/semantic.odin#L1463) `intern_type`: every caller writes the same kind, element, key, count and mutable twice. Derive `Type_Info` from the key, as `intern_type(c, key, bits = 0)`, which also removes the cause of BUG-semantic-2. (about 15 lines across 9 callers)
- [semantic.odin:2262](src/semantic.odin#L2262) `type_is_supported_walk`: if it is not merged (see Near copies), its 16 arms still collapse to six: always true, element, Map, and the three that loop. (about 20 lines)
- [semantic.odin:2084](src/semantic.odin#L2084) `record_order_blocker_walk`: nested results are only compared with `""`, so "holds itself by value" and "is not an anonymous record" never reach a user, yet each failure formats text. Use a bool walk and format only in `record_order_blocker`. (about 10 lines)
- [semantic.odin:1522](src/semantic.odin#L1522) `anon_record_type`, and [semantic.odin:1637](src/semantic.odin#L1637) `anon_union_type`: nothing needs `id` before its fields are known, so build one `Type_Info` literal instead of `new_type` plus `if info := type_of(...)`. (about 8 lines)
- [semantic.odin:1525](src/semantic.odin#L1525) `anon_record_type`: the inline `new_symbol` is `new_field(c, identifier_text(c, field.name), field.type, index, public = true)`. (about 7 lines)
- [semantic.odin:1811](src/semantic.odin#L1811) `positional_field_name`: once `intern_identifier` clones on a miss, this is `intern_identifier(c, fmt.tprintf("%d", position))`, and callers such as [iterate.odin:53](src/iterate.odin#L53) can use `tprintf` too. (about 3 lines here)
- [semantic.odin:1390](src/semantic.odin#L1390) `parameters_weaken_to`: the first `if` is what the length check and loop already answer. At [semantic.odin:1403](src/semantic.odin#L1403), test the target's `Type_Info` rather than making a predicate intern a pointer type with `pointer_to`. (about 3 lines)
- [semantic.odin:1367](src/semantic.odin#L1367) `proc_escape_weakens_to`: merge the two loops over the same range. The name is also too narrow: it decides receiver forms, cross-thread and contracts too, so `proc_type_weakens_to` fits. (about 2 lines)
- [semantic.odin:1772](src/semantic.odin#L1772) `type_bits`, and [semantic.odin:1780](src/semantic.odin#L1780) `type_signed`: the `.Enum` recursion is redundant, since [check.odin:1269](src/check.odin#L1269) and [enums.odin:6](src/enums.odin#L6) copy both from the backing. (about 2 lines)
- [semantic.odin:1148](src/semantic.odin#L1148) `synth_proc`: `intern_proc_type` already copies the parameters, so `params = type_of(c, proc_type).parameters` drops a second allocation. (about 2 lines)
- [semantic.odin:1464](src/semantic.odin#L1464) `intern_type`, also `lookup_type`, `anon_record_type`, `anon_union_type`: `init_semantic_stores` is redundant, because reading a nil map is safe, `new_type` initializes before any write, and the anon forms take already interned names. (about 4 lines)

**Dead code**

- `Cpu_Feature` ([semantic.odin:309](src/semantic.odin#L309)): only `.FMA in` and `!= {}` read the set, and the LLVM attributes come from per-level strings. `cpu == .X86_64_V3` and `cpu != .X86_64` replace the enum, `Cpu_Features`, both constants, the switch and `features` (about 30 lines).
- `dispatches` ([semantic.odin:800](src/semantic.odin#L800)): its one read is `symbol.dispatches && symbol.dispatch_cpu > e.c.target.cpu` ([emit_llvm_dispatch.odin:90](src/emit_llvm_dispatch.odin#L90)); the unset `dispatch_cpu` is `.X86_64`, never above any target, so the second test suffices.
- `Procedure_Group` ([semantic.odin:358](src/semantic.odin#L358)): written once at [check_expr.odin:673](src/check_expr.odin#L673) and never read by name; only the "is not another kind" fact matters.
- `Generic_Application` ([semantic.odin:360](src/semantic.odin#L360)): written at [generic.odin:2951](src/generic.odin#L2951) and [interface.odin:204](src/interface.odin#L204), never read by name.
- `add_package_file` ([semantic.odin:2534](src/semantic.odin#L2534)): no caller reads its bool, and six of its seven callers are tests, so it can return nothing and drop the nil guard.
- (branch) [semantic.odin:2205](src/semantic.odin#L2205): `type_of` returns the `.Invalid` entry for `INVALID_TYPE`, so `case .Invalid` already answers this early return.
- (branch) [semantic.odin:2333](src/semantic.odin#L2333): the `#partial switch` above names every `Type_Kind`, so this `return false` is unreachable; the `.Invalid` and `.Interface` arms can instead fall to it.
- (branch) [semantic.odin:1536](src/semantic.odin#L1536): the `info != nil` tests here and at 1495, 1500, 1600 and 1638 are on IDs this store just made or holds; `intern_proc_type` indexes `c.types` directly at 1244.
- (branch) [semantic.odin:2086](src/semantic.odin#L2086): a record's field IDs come from `new_symbol`, so `symbol == nil` and its "did not resolve" text cannot occur.

**Data structures and algorithms**

- [semantic.odin:956](src/semantic.odin#L956) `c.packages`: `[dynamic]Package` holds values, so `package_of` pointers die on the next load, and [packages.odin:249](src/packages.odin#L249) and [packages.odin:316](src/packages.odin#L316) re-fetch to avoid it. `[dynamic]^Package`, as for symbols and types, removes the hazard.
- [semantic.odin:645](src/semantic.odin#L645) `Symbol`: every local and field carries all of the roughly 75 fields, and most enums (`Symbol_Kind`, `Builtin_Kind`, `Synth_Kind`, `Duration`) default to 8-byte `int`. Symbols grow with the program; `enum u8` and grouped bools shrink each with declaration-only edits. Size not measured.
- [semantic.odin:1859](src/semantic.odin#L1859) `named_fields`: each call allocates permanently per literal or destructuring, and [iterate.odin:881](src/iterate.odin#L881) and [iterate.odin:1022](src/iterate.odin#L1022) only take `len`. Return `info.fields` when there is no padding, and add a count helper.

**Near copies**

- [semantic.odin:2204](src/semantic.odin#L2204), [semantic.odin:2262](src/semantic.odin#L2262) and [reflect.odin:149](src/reflect.odin#L149): the same component walk. "Supported" is "no component is Invalid, Interface or a descriptor"; "contains invalid" is the Invalid part. One walk taking a predicate serves all three. (about 70 lines)
- [semantic.odin:1298](src/semantic.odin#L1298), [semantic.odin:1542](src/semantic.odin#L1542) and [semantic.odin:1644](src/semantic.odin#L1644): identical bucket growth, differing only in the map. Shared form: `bucket_append(c, &c.proc_types, hash, bucket, id)`. (about 9 lines)
- [semantic.odin:1477](src/semantic.odin#L1477) and [semantic.odin:1584](src/semantic.odin#L1584): `Anon_Record_Field` and `Anon_Union_Variant` are one `{name, type}` struct, and the hash loops at 1488 and 1594 are the same. Use one struct and one `anon_hash`; keep the separate display and label code. (about 8 lines)
- [semantic.odin:1212](src/semantic.odin#L1212) and [semantic.odin:1487](src/semantic.odin#L1487): the FNV offset basis is spelled by hand; name it beside `HASH_MULTIPLIER` in [hash.odin:14](src/hash.odin#L14). The rotated seed at [semantic.odin:1593](src/semantic.odin#L1593) gains nothing, as its buckets are in a separate map.
- [semantic.odin:2488](src/semantic.odin#L2488) and [semantic.odin:2498](src/semantic.odin#L2498): `lookup_symbol` is `lookup_symbol_with_scope` without the scope; make it a wrapper. (about 6 lines)

**Structure and boundaries**

- [semantic.odin:1753](src/semantic.odin#L1753): lines 1753-2476 are type queries, walks and naming, while the "Source-code map" row gives this file stores and interning. The seam is a `types.odin` from `type_of` through `proc_type_name`.
- [semantic.odin:1965](src/semantic.odin#L1965): comparability and ordering (1965-2152) belong with `type_own_equality` in [hash.odin:258](src/hash.odin#L258) or the delegates in [operators.odin:689](src/operators.odin#L689), since `operator_is_builtin` walks the chain that code builds.
- [semantic.odin:287](src/semantic.odin#L287): `Target_Info` and the CPU types (287-348) belong in `build_config.odin`, which owns `Cpu_Level`. `compiler-architecture.md` line 783 cites this location and would move with them.
- [semantic.odin:1885](src/semantic.odin#L1885): `underlying_info` and `underlying_kind` sit 100 lines from `type_underlying` (1785), with field helpers between them. Put them together and the field and record helpers (1802-1883) in one group.

**Comments**

- [semantic.odin:1800](src/semantic.odin#L1800): stranded when the field helpers were inserted; it describes `underlying_info` and `underlying_kind`. Move it to line 1885.
- [semantic.odin:2028](src/semantic.odin#L2028): stale and wrong; unions have no nil state (`design.md` "Unions", and this file at 152-155). Delete "against nil always".
- [semantic.odin:749](src/semantic.odin#L749): "step 6" refers to nothing now. Use "The declaring procedure literal, for the capture check."
- [semantic.odin:287](src/semantic.odin#L287): "M2" is history; use "The one target". [semantic.odin:2177](src/semantic.odin#L2177): likewise, "a milestone answer" becomes "an unsupported-type error".
- [semantic.odin:2429](src/semantic.odin#L2429): three comments (2429, 2439, 2452) give one reason. One at the top of the proc: "Everything in the type's identity prints, or a mismatch report names the same text twice." (about 6 lines)
- [semantic.odin:429](src/semantic.odin#L429): delete the second sentence; an enum of kinds needs no defense. Likewise delete [semantic.odin:1114](src/semantic.odin#L1114), [semantic.odin:1442](src/semantic.odin#L1442) and [semantic.odin:2222](src/semantic.odin#L2222), which restate the code.
- [semantic.odin:277](src/semantic.odin#L277): delete "A field of its own, not a spare bit of `count`...". [semantic.odin:1101](src/semantic.odin#L1101): delete "Every such type installs...". [semantic.odin:1306](src/semantic.odin#L1306): delete "so an unannotated signature interns exactly the type it always did".
- [semantic.odin:938](src/semantic.odin#L938): keep the why, drop the incident: "`mem.Dynamic_Arena` rejects allocations over its block size, and `append`/`make` swallow the error." (about 2 lines)
- [semantic.odin:513](src/semantic.odin#L513): `Builtin_Kind` comments repeat lowering and spec text (513-545 especially, naming LLVM intrinsics the emitter names anyway). Keep each citation with at most a one-line reason. (about 40 lines across the enum)
- [semantic.odin:1344](src/semantic.odin#L1344): the rule belongs to the cited section; keep the citation and "Levels carry no ABI, so the assignment is a plain pointer copy." (about 3 lines; about 75 lines across the file)

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
- [semantic.odin:546](src/semantic.odin#L546): "exactly as an atomic takes its ordering" contradicts `simd.odin:406` and `core/simd/simd.loke`, which say it differs from an atomic; delete that sentence.
- [simd.odin:417](src/simd.odin#L417): cites a "design.md entry" that does not exist (the intrinsics are not in design.md); shorten to "A built-in has no signature, so the shapes are checked here."
- [simd.odin:56](src/simd.odin#L56), [simd.odin:273](src/simd.odin#L273), [simd.odin:389](src/simd.odin#L389) and [simd.odin:484](src/simd.odin#L484): delete; each repeats the procedure name, the code, or the diagnostic beneath it.
- [simd.odin:520](src/simd.odin#L520): delete the second sentence, which `core/simd/simd.loke` and `stdlib.odin` already state.
- [simd.odin:252](src/simd.odin#L252): shorten to `design.md "Lane-wise operators": also serves `v <<= c`.`
- [simd.odin:4](src/simd.odin#L4): shorten to "`Simd` is predeclared, so it needs no import and can be shadowed." (about 15 lines across the file)

### src/slice.odin

A small, focused file. What remains is the emitter's slice unpacking around it.

**Near copies**

- [emit_llvm_iteration.odin:493](src/emit_llvm_iteration.odin#L493), [emit_llvm_calls.odin:1073](src/emit_llvm_calls.odin#L1073), [emit_llvm_expr.odin:2410](src/emit_llvm_expr.odin#L2410), and [emit_llvm_containers.odin:128](src/emit_llvm_containers.odin#L128), 287, 322, 755, 896, 1413: each extracts data then length, four of them through raw `extractvalue` prints.
  Shared form: `ptr_len_parts(e, storage, value) -> (data, length)` beside `emit_ptr_len`, its inverse; `#assert` at emit_llvm_runtime.odin:116 already ties `SLICE_*` to `VIEW_*`. (about 12 lines net)

### src/source.odin

Small, sound procedures for loading and diagnostics, sharing a file with the 380-line `Compiler` record. Every `Compiler` field has a non-test read, so no dead code was found; the two bugs are both in what `report` prints.

**Bugs**

- `BUG-source-1` **medium** [source.odin:811](src/source.odin#L811) `report`: it compares only with the previous diagnostic, but the sort at line 798 keys on `(file, lo)` alone, so two errors starting at one `lo` interleave and never match. Scenario: `f :: proc(v: $T) { missing_a + "x"; }` called with three types prints L0313 then L0315 three times (reproduced with the built lokec.exe). Fix: break sort ties on `hi`, code, message and label, so identical reports are adjacent. *Confirmed: Reproduced: probes/BUG-source-1/a.loke prints L0313 then L0315 three times at 2:20, while single.loke merges one L0315 with three notes, against report's own comment. Severity is low, not medium: only repeated output; errors and exit 1 are correct.*
- `BUG-source-2` **low** [source.odin:878](src/source.odin#L878) `render`: the caret indent has one blank per byte of the prefix and `width` (line 873) counts bytes, though the snippet prints characters; the comment at line 554 calls this exact. Scenario: `s := "åäöåäö" + 1` puts the caret past the end of the line. Fix: one blank per rune of `text[:col - 1]` (tabs kept); count the marked range in runes. *Not verified.*

**Simplification**

- [source.odin:461](src/source.odin#L461) `load_source`: return `add_loaded_source` straight from the overlay branch, then read the file and report on `err != nil`; `data`, `read_ok` and `read_err` go. Line 462 goes too: `add_loaded_source` inits, and a failed read only calls `errorf`. (about 7 lines)
- [source.odin:768](src/source.odin#L768) `hold_diagnostics`: the early return when nothing is past `wanted` is redundant; the loop, `resize` and `min` are all no-ops then. (about 3 lines)
- [source.odin:647](src/source.odin#L647) `destroy_diagnostic`: the `d.label != ""` guard is redundant: deleting an empty string is a no-op. (about 2 lines)
- [source.odin:546](src/source.odin#L546) `valid_utf8`: `text[i] >= utf8.RUNE_SELF` can never be false when `r == RUNE_ERROR && width == 1`; ASCII never decodes to `RUNE_ERROR`. Drop that test.
- [source.odin:29](src/source.odin#L29) `no_span`: a constant `NO_SPAN :: Span{file = NO_FILE}` replaces the procedure, and the spelled-out defaults at [layout.odin:6](src/layout.odin#L6) and [union.odin:292](src/union.odin#L292). Mechanical across about 110 call sites. (about 2 lines)

**Data structures and algorithms**

- [source.odin:709](src/source.odin#L709) `emission_registries`: `for pkg in c.packages` copies a whole `Package` per iteration to read one length, twice per probe (`begin_probe`, `end_probe`). Cost grows with probes times packages; modest, but `for &pkg` removes it, as `build_snapshot_queries` already writes it.

**Near copies**

- [source.odin:660](src/source.odin#L660), [source.odin:766](src/source.odin#L766), [check.odin:3355](src/check.odin#L3355) and `prov_drop_event_diagnostics`: each shrinks and clamps `last_noted_diagnostic`, and `hold_diagnostics` also undoes `error_count` by hand. Add one helper for `resize` plus the clamp. (about 5 lines)
- [source.odin:863](src/source.odin#L863), [source.odin:904](src/source.odin#L904), [check_builtin.odin:1368](src/check_builtin.odin#L1368), [erased.odin:613](src/erased.odin#L613), [generic.odin:3274](src/generic.odin#L3274) and [query_index.odin:9](src/query_index.odin#L9) test `span.file != NO_FILE && int(span.file) < len(c.sources)`. `span_source(c, span) -> ^Source` (nil if none) fits; `NO_FILE` is `max(u32)`, so the range test alone decides.
- [source.odin:557](src/source.odin#L557) and [paths.odin:77](lsp/paths.odin#L77): both find the line of an offset by binary search in `line_starts`, the LSP's by hand. Export `line_of_offset(line_starts, offset)` for both; the LSP keeps its empty-list guard. (about 3 lines)

**Structure and boundaries**

- [source.odin:78](src/source.odin#L78): `Compiler` is 380 of 911 lines and hides what the file is for. Move it to `compiler.odin`, leaving spans, sources, diagnostics and probes; update the "Source-code map" row. Probes stay put unless the `speculation_depth` guard at test-all.ps1:89, which names this file, moves with them.
- [source.odin:840](src/source.odin#L840): `code_end` sits between `same_diagnostic` and `render` though only `render` and a test use it, and `errors_since` (line 759) splits `hold_diagnostics` from its comment. Put `code_end` beside `line_text`, `errors_since` before line 755.

**Comments**

- [source.odin:755](src/source.odin#L755): lines 755-756 document `hold_diagnostics` but sit above `errors_since`, reading as one comment with lines 757-758. Move them to line 766.
- [source.odin:407](src/source.odin#L407): lines 407-408 describe `Yield` descriptor types that no field holds; they head `memory_order_type`, which has its own comment. Delete them: the citation goes only because the field it annotated is gone.
- [source.odin:397](src/source.odin#L397): shorten to "The `default_allocator` builtin." and drop the M6 history; "the one call expression" describes `default_allocator_arg` 17 lines down, so move it there.
- [source.odin:610](src/source.odin#L610): shorten to "A diagnostic that does not fail the compilation."; `warnf` has other callers than the copy-cost report it explains. (2 lines)
- [source.odin:72](src/source.odin#L72): delete the `Context` naming note, and at [source.odin:425](src/source.odin#L425) drop "Parser ASTs remain per-file arenas.", which lines 75-77 say. Also delete line 632, which adds nothing to line 631. (4 lines)
- [source.odin:674](src/source.odin#L674): keep the citation plus "`end_probe` fails if a probe grew the emission registries without a `begin_commit`"; the rest repeats compiler-architecture.md. Likewise cut [source.odin:733](src/source.odin#L733) to two lines. (about 6 lines)
- [source.odin:483](src/source.odin#L483), line 488 and [source.odin:420](src/source.odin#L420) cite a spec without a heading: use `grammar.md "Source encoding"` and `design.md "Allocators"`; line 488 then repeats line 483 and can go. (1 line)

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

A small, table-driven file whose bindings match design.md "Predeclared names"; no bugs here. What remains is a builtin symbol spelled three ways and one comment in another file.

**Near copies**

- [box.odin:45](src/box.odin#L45), [iterate.odin:68](src/iterate.odin#L68) and [simd.odin:15](src/simd.odin#L15): the predeclared names with no universe entry use one proc three times; only the string differs. Shared form: `predeclared_callee(k, callee, "Box")`. (about 14 lines)
- [check.odin:2330](src/check.odin#L2330) and [check.odin:2334](src/check.odin#L2334): `Simd` compares the name alone where `Box` uses `box_type_callee`, so a bare `x: Simd` naming a program's own generic `Simd` gets the `Simd(f32, 4)` message instead of L0431. Use `simd_callee` here too.

**Comments**

- [semantic.odin:2338](src/semantic.odin#L2338): says the allocator types print under the name `core:mem` binds, but `contribute_allocator_surface` sets no name; [universe.odin:49](src/universe.odin#L49) does. Reword to "named by `build_universe`".

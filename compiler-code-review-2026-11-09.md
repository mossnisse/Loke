# Compiler code review (2026-11-09)

A review of the `lokec` source at revision `fd381d23`. It covers the 170
non-test files in `src/`, `src/subprocess/` and `lsp/`, about 105,500 lines.
Six reviewers each took one subsystem and read its files one by one. Besides
bugs, they looked for four things:

- code that could be simpler or shorter;
- data structures and algorithms that fit their purpose;
- near-copies of the same code;
- structure and module boundaries.

The review is non-normative and changed no code. Every recommendation below is a
proposal. Line numbers are at `fd381d23`.

Where this summary marks a finding as **reproduced** or **checked**, the
claim was confirmed against a probe program or the source after the review.
Every other finding is as its reviewer reported it, and a reviewer's
"(unverified)" marks a claim the reviewer could not confirm.

The marks were checked against the code after `54f5411e`. A finding marked
"done" is fixed, "done in part" says what is left, "not done" or "no change
needed" says why it stays, and an unmarked finding is still open. Bugs not yet
acted on are in [open-questions.md](open-questions.md#compiler-review-findings-not-yet-acted-on-2026-11-09).

## Contents

- [Scope and verdict](#scope-and-verdict)
- [Bugs](#bugs)
- [Cross-cutting themes](#cross-cutting-themes)
- [Recommended order](#recommended-order)
- [Group 1: driver, syntax, and language server](#group-1-driver-syntax-and-language-server)
- [Group 2: checker and semantic core](#group-2-checker-and-semantic-core)
- [Group 3: language features, generics, and bootstrap](#group-3-language-features-generics-and-bootstrap)
- [Group 4: control-flow graphs and provenance](#group-4-control-flow-graphs-and-provenance)
- [Group 5: borrow solver, lifecycle, thread effects, and compile-time interpreter](#group-5-borrow-solver-lifecycle-thread-effects-and-compile-time-interpreter)
- [Group 6: LLVM backend and toolchain](#group-6-llvm-backend-and-toolchain)

## Scope and verdict

| Group | Files | Lines | Bug | Simplify | Data structure / algorithm | Duplication | Structure |
| --- | --- | --- | --- | --- | --- | --- | --- |
| [1: driver, syntax, LSP](#group-1-driver-syntax-and-language-server) | 37 | ~18.2k | 3 | 17 | 19 | 13 + 15 cross-file | 11 |
| [2: checker core](#group-2-checker-and-semantic-core) | 19 | ~18.2k | 4 | 14 | 13 | 14 + 12 cross-file | 4 |
| [3: features, generics](#group-3-language-features-generics-and-bootstrap) | 40 | ~19.5k | 5 | ~21 | ~15 | ~22 + 16 cross-file | 8 |
| [4: CFG, provenance](#group-4-control-flow-graphs-and-provenance) | 23 | ~19.0k | 7 | ~20 | ~20 | ~20 + 16 cross-file | ~10 |
| [5: borrow, lifecycle, eval](#group-5-borrow-solver-lifecycle-thread-effects-and-compile-time-interpreter) | 23 | ~17.2k | 5 | 22 | 15 | 18 + cross-file | 10 |
| [6: LLVM backend](#group-6-llvm-backend-and-toolchain) | 28 | ~16.3k | 1 | 24 | 10 | 22 + 15 cross-file | 18 |

The compiler is in good shape. Every group found the code careful,
consistently commented, and citing the specification. No reviewer found a
miscompile on a path the checker allows, an unsound dataflow merge, or a
fixpoint that fails to terminate. One bug is user-visible and reproduced: a
variadic parameter's attribute was checked differently in a declaration and in a
procedure type; it is now fixed. The rest are small: a diagnostic that leaks a cache encoding,
one with no location, memory charged to the wrong arena, and latent edge cases.

The bigger findings are about cost and shape, not correctness. Hot queries are
recomputed or keyed by formatted strings. Several construction walks are
quadratic. Short-lived data lands in long-lived arenas. A few files have grown
into several subsystems. And the same scaffolding has been written three to
nine times. Applying the duplication and simplification proposals would remove
on the order of 1,500 lines, about 450–550 of them in the backend.

## Bugs

Status: **reproduced** means a probe program shows it, **checked** means the
source at the cited lines confirms it, **reported** means the reviewer's
reading has not been checked again, and **fixed** names the change and its
regression test.

| # | Site | Finding | Severity | Status |
| --- | --- | --- | --- | --- |
| 1 | `src/check.odin:1309-1317`, `:1890-1900` | A variadic `..T` parameter's `@(escape)` and `@(cross_thread)` are checked against `T` in a declaration but against `[]T` in a written procedure type, because `resolve_proc_type` is a drifted copy of `append_signature_group`. `f :: proc(@(escape=none) xs: ..int) {}` is rejected with L0648, but `P :: proc(@(escape=none) xs: ..int);` is accepted. design.md "Variadic parameters" says the escape level bounds the lent values as it does for a `value: T` parameter, so the declaration is right. Fix: one parameter-flattening helper for both (about 35 lines saved). | User-visible | Fixed: one `check_signature_parameter` serves both paths; `tests/err/variadic_attribute_parity.loke` |
| 2 | `src/interface.odin:373` | A user diagnostic formats an interface argument with `const_key_text`, so users see cache encodings such as `t123` or `f64:3ff0000000000000`. Use `generic_value_text`. | User-visible | Fixed: `generic_value_text`; `tests/err/interface_slot_checks.loke` |
| 3 | `src/parallel.odin:194` | L0727 ("`core:thread` declares no `Task_Scope`") is reported at `NO_SPAN`; the L0329 case two lines above uses the `parallel` keyword's span. | Minor | Fixed, with the two other `L0727` reports in the file: `tests/pkg_err/parallel_no_task_scope`, `spawn_no_task_start`, `spawn_no_unsafe_builtin` |
| 4 | `src/emit_llvm_containers.odin:1414-1421` | Hashing a fixed array that is not a large value (up to 4096 bytes) is fully unrolled. A `[4096]u8` key emits about 16k instructions into its hash thunk, while equality loops above `UNROLLED_EQUAL_ELEMENTS`/`UNROLLED_EQUAL_BYTES`. | Code size | Fixed: both use `array_walks_in_loop`; `fixed_array_hash_ir_stays_flat` |
| 5 | `src/provenance_retention.odin:537-541` | `prov_parameter_label` formats into `semantic_allocator`, the long-lived arena, on every graph build. Thirteen more provenance allocations use `context.temp_allocator`, which lasts the whole batch compile, instead of the analysis arena that compiler-architecture.md "Normalized provenance input" asks for. | Memory growth | Fixed: the label and the ten graph-local sites use `graph.alloc`; the rest is in [open-questions.md](open-questions.md#compiler-review-findings-not-yet-acted-on-2026-11-09) |
| 6 | `src/borrow.odin:1691` | `publish_place_settled` compares whole `Proj_Step` structs, including `precision`, `synchronized` and `shifts`, where `same_step` is the place-identity test. A store can lose `one_place` over a flag difference and produce a spurious "may" conflict. | Minor, conservative | Fixed: `same_step`. No probe makes the flags differ, so no test shows a change |
| 7 | `src/capture.odin:276-278` | `capture_call_method` resets `k.c.capture_rewrite` to `nil` rather than to the value it replaced, so a capture lowered while another rewrite is active would lose the outer one. | Latent | Fixed: restores the outer rewrite; reachability not established |
| 8 | `src/const_ops.odin:136,156-158,235,323`, `src/const_float.odin:41-49`, `src/eval.odin:1313,3200-3205,3433-3436` | Big-integer temporaries, sort scratch, and a dispatch frame are charged to the compile-time evaluator's memory limit and never released, against the contract of `bi_release`. | Minor | Fixed for the integer and float folds, sorting and range `foreach` (`evaluator_folds_keep_only_results`); a returned call's frame releases its table and record, and since `0118aa25` so does the frame `eval_dispatch` pushes; their slots stay |
| 9 | `src/simd.odin:431-433` | `simd_written_fold` dereferences the result of `enum_member_by_value` without a nil check; only an edited `core:simd` reaches it. | Latent crash | Fixed: reported as `L0687`; `tests/pkg_err/simd_unknown_fold` |
| 10 | `src/eval_memory.odin:103-105` | A zero-size request yields a negative size class that the allocator reads as the heap-block sentinel, then overwrites the large-block link. Probably unreachable through the runtime wrappers. | Latent | Fixed: an empty request takes the smallest class; `evaluator_storage_serves_empty_requests` |
| 11 | `src/thread_summaries.odin:192,205,214` | `add_global_effect` keeps the first `Effect_Source`, so "may reach" versus "reaches" in a diagnostic depends on order; `effect_call_reach` intersects precision instead. | Wording | Fixed: all three sites use `merge_effect_source`, where an exact route wins; `tests/err/parallel_merged_reach.loke` |
| 12 | `src/provenance_reborrow.odin:211-215` | `prov_reborrow_loaded` takes the last matching reborrow's capability, so the result depends on list order. | Minor | Recorded in [open-questions.md](open-questions.md#compiler-review-findings-not-yet-acted-on-2026-11-09) |
| 13 | `src/provenance_effect.odin:98` | Replay termination relies on fact weight never shrinking; a non-monotone change would loop silently. Add an assert. | Latent | Fixed: asserted |
| 14 | `src/borrow_report.odin:293-323` | `at_once_reaches` writes solver rows as a side effect of a check; harmless today only because the following replay overwrites them. | Fragile | Recorded in [open-questions.md](open-questions.md#compiler-review-findings-not-yet-acted-on-2026-11-09) |
| 15 | `src/cfg_provenance.odin:2037-2053` | Materialized view publication records definitions into the construction graph, contradicting the comment at `:1042-1044`; it widens bit rows but appears harmless. | Minor | Recorded in [open-questions.md](open-questions.md#compiler-review-findings-not-yet-acted-on-2026-11-09) |
| 16 | `src/parser.odin:2421-2422` | `parse_postfix` counts one more level than it builds, so the nesting limit for postfix chains is stricter than intended. | Minor | Fixed: counted once a postfix follows; `postfix_and_binary_spines_count_alike` |
| 17 | `src/check_stmt.odin:426-433` | `_ = nil` is accepted silently where `check_decl_value` reports L0310 for the same case; decide which is intended. | User-visible | Fixed: `_ = nil` reached the backend as `L0405`; it is now `L0310`. `tests/err/nil_values.loke` |
| 18 | `src/erased.odin:676-677`, `src/doc.odin:491-492` | A missing nil check, and an interface-text edge case for a typed procedure constant; both probably unreachable. | Latent | The nil check is added; the interface-text case is recorded in [open-questions.md](open-questions.md#compiler-review-findings-not-yet-acted-on-2026-11-09) |
| 19 | `src/compiler.odin:159-160` | An orphan comment describes fields that no longer exist. | Documentation | Fixed: comment removed |

## Cross-cutting themes

The same weaknesses appear in several groups, so each is best fixed once.

### 1. Hot queries recomputed or keyed by strings

- Generic instance, `dyn` and witness caches build an `fmt` string on every
  lookup, and `generic_arg_equal` allocates two strings per comparison
  (`src/generic.odin:881-963`, `src/erased.odin:392-406,683-688`). Group 3
  proposes one hashed key type for all three.
- Interface satisfaction is never memoized (`src/interface.odin:548-587`,
  `:1281-1330`), and each success appends to `pending_private_reads`.
- Type predicates walk the type every time: `type_is_comparable`
  (`src/operators.odin:1019`), `prov_type_has_region`, `prov_holds_allocator`
  and `prov_view_reaches_provider` (`src/provenance_regions.odin:1075-1650`),
  `transfer_facts` (`src/transfer_facts.odin:192`) and `type_hooks`
  (`src/hooks.odin:246`). Their siblings `type_carries_borrow` and
  `prov_type_reaches_mutable` are already cached in `Compiler` maps
  (`src/carrier_shape.odin:110-149`); the same pattern fits the rest.
- Member, field and operator lookup scan flat member slices on every selector
  and call (`src/impl.odin:567`, `src/check_expr.odin:2880`).

Measure each change with `perf.ps1`, as
[Testing and verification](compiler-architecture.md#testing-and-verification)
describes.

### 2. Quadratic construction

- About ten provenance construction sites scan all of `graph.reborrows` per
  slot (group 4, top recommendation 1). One `prov_add_reborrow` with a
  per-slot index fixes them; the solver's scans in `borrow*.odin` can share it.
- Region-content and written-alias tables copy their whole slice on every
  insert (`src/provenance_regions.odin:732-742`,
  `src/provenance_escape.odin:362-373`, `src/provenance_aliases.odin:415-433`).
  (Done: both tables hold `[dynamic]` rows.)
- A generic `extend` block reallocates its group's member slice for every
  instance (`src/generic_impl.odin:548-561`). (Done.)
- Ten "append if not present" set helpers scan linearly
  (group 5, top recommendation 7); `Global_Set` already uses a bitset in one
  place.

### 3. Allocation domains

Short-lived data goes into long-lived arenas: overload candidate lists, rank
vectors and eagerly formatted diagnostic descriptions in the checker
(group 2, top recommendation 2), and provenance labels and scratch maps
(bug 5). [Allocation domains](compiler-architecture.md#allocation-domains)
already states the rule; these sites predate or bypass it.

### 4. Repeated scaffolding

| Pattern | Copies | Where it is described |
| --- | --- | --- |
| Replay of settled facts (enter block, visit event, `run_prov_event`) | 7 | Group 5, top 1 |
| Worklist or fixpoint queue | 4 | Group 5, top 3 |
| Union-tag compare-and-branch chain in IR | 7 | Group 6, top 1 |
| Spill a value to a stack slot in IR | ~15 | Group 6, top 5 |
| Hand-written runtime `declare` lines | ~85 lines | Group 6, top 3 (done) |
| `branch` immediately before `place_label`, which already branches | 27 | Group 6, top 6 |
| Alias-reachability walks | 4 | Group 4, top 7 |
| Compiler-owned record builders | ~8 | Group 3, top 5 |
| Read-only and mutable iteration-protocol checks | 3 | Group 3, top 4 (done) |
| Parameter flattening for signatures | 2, drifted (bug 1) | Group 2, top 1 |
| Scratch `Compiler` to lex free-standing text | 4 | Group 1, top 4 |
| Bracket-depth token scanners | 11 | Group 1, cross-file table |
| Hand-written recursion that `expr_children` provides | 2 walkers | Group 1, top 3 |
| `type_underlying(c, t) == TYPE_ALLOCATOR` | 20 in 13 files | Group 2, cross-file table |
| Identical path predicates `prov_path_names_one_place` and `path_is_exact` (`src/borrow.odin:278`, `:2454`) | 2 (checked) | Group 5, top 5 |

### 5. Files that hold several subsystems

| File | Lines | Proposed split |
| --- | --- | --- |
| `cfg_provenance.odin` | 4671 | State and event vocabulary, parameters, views, places, and assignment into five `provenance_*` files; about 1.3k lines stay |
| `emit_llvm_expr.odin` | 2726 | Constants, equality with hashing, and text operations into `emit_llvm_const`, `emit_llvm_equality`, `emit_llvm_text` |
| `check.odin` / `check_expr.odin` | 2723 / 2908 | Type-syntax resolution (~680 lines) and indexing/slicing (~650 lines) |
| `borrow.odin` | 2527 | The `Proj_Step` path algebra and the program driver |
| `global_effects.odin` | 1806 | The `prov_note_*` walk hooks (lines 119-800) into the provenance walk family |
| `carrier_shape.odin` | 1237 | The region lattice into `region.odin` |
| `source.odin` | 571 | Probe, commit and settling machinery into a checker-side file |
| `lifecycle.odin` | 569 | Checker special forms (lines 9-286) away from liveness |

Each split must update the table in
[Source-code map](compiler-architecture.md#source-code-map) in the same commit.
`Prov_Event`, at about 45 fields with most used by one kind, is the matching
data-structure problem (group 4, top recommendation 3).

### 6. Text treated as a data structure

The backend re-parses the module text it has already written:
`emit_foreign_declarations` scans `declare` lines (done: it consults
`Emitter.declared`), and `attach_debug_info` counts witnesses (group 6
overview). Free-standing source text is lexed through a full scratch `Compiler`
(group 1). Both should consult the structured state directly.

## Recommended order

Fix correctness first, then work that pays for itself in compile time, then
restructuring. Measure performance items before and after.

1. Bug 1 (done): share parameter flattening in `check.odin`, with a regression
   test for the declaration and procedure-type forms.
2. Bugs 2, 3, 6 and 9 (done): one-line fixes, each with a test where a probe
   reaches it.
3. Bug 4 (done): loop hashing above the equality thresholds, with an IR-growth test
   like `fixed_array_clone_ir_grows_linearly`.
4. Allocation domains (theme 3 and bug 5), then the evaluator accounting (bug 8);
   bugs 5 and 8 are done where a graph or a clear owner exists.
5. The per-slot reborrow index and the amortized region-content tables (theme 2).
   The tables and the `extend` group growth are done.
6. Caches for interface satisfaction, generic keys and type predicates
   (theme 1), each measured with `perf.ps1`. The three region predicates of
   group 4 are done.
7. Shared scaffolding (theme 4), smallest first: the redundant `branch` calls,
   `type_is_allocator`, the identical path predicates (these three done), then
   the replay iterator, the worklist type, and the union `switch` helper (the
   last two done).
8. File splits (theme 5), each as its own move-only commit.

Open items that are not taken up should move into
[known-gaps.md](known-gaps.md) (for divergences from the specification such as
bug 1) or [open-questions.md](open-questions.md) (for decisions),
as [AGENTS.md](AGENTS.md) requires of review findings. The bugs not fixed are
in [Compiler review findings not yet acted on](open-questions.md#compiler-review-findings-not-yet-acted-on-2026-11-09).

The six group reports follow unchanged, apart from heading levels.

## Group 1: driver, syntax, and language server

Revision fd381d23. Read-only review; no repository file was changed.

### Overview

This group is in good shape. The driver, session, and query layers are small
and have clear contracts. The parser is large but consistent: it keeps its
depth guards, recovery, and span invariants throughout. The language server
keeps to its rule of using only session and snapshot APIs. I found no
correctness bug that breaks a documented contract. The few bug-like findings
are a stale comment, a depth overcount in the parser, and an edge case in the
interface-file text.

The recurring themes are:

1. **Repeated recursive walks over the syntax tree.** `expr_children` exists,
   but several walkers still spell out the trivial recursion cases by hand
   (`query_index.odin`, `doc_comments.odin`). There are also many hand-written
   bracket-depth scanners over tokens, in the parser and in the server.
2. **A heavyweight "scratch `Compiler`" pattern.** It is used to lex or parse
   free-standing text in four places. `doc.odin` lexes every shown declaration
   twice through it, just to confirm that nothing changed.
3. **Repeated path canonicalization.** `canonical_dir` calls
   `filepath.abs`, which is a system call plus three temporary allocations. It
   runs again on paths that are already canonical: per directory entry, per
   overlay, and per language-server location.
4. **Small structure leaks.** The probe and commit machinery lives in the
   "source manager". Checker lookups live in `packages.odin`. Language-server
   error codes and JSON-writing helpers are spread across four files.

### Top recommendations

1. **Make `shown_text` skip the token comparison when it cut no comment**
   (done; `-api-check` over `core` showed no measurable change)
   (`src/doc.odin:759-798`). Today every call runs `token_texts` twice, and each
   of those runs `lex_text` with a scratch `Compiler`. If nothing was cut, the
   result is exactly `text[lo:hi]`, so the comparison is guaranteed to pass.
   Track a `cut` flag and compare only when it is set. This removes about two
   lexes per declaration, attribute, field, and impl head in `-api`, `-doc`,
   and the language server's documentation command.
2. **Stop canonicalizing paths that need no canonicalizing in package loading**
   (`src/packages.odin:283`, `:288`; done for `package_sources`,
   while `is_source_directory` canonicalizes once per call and is unchanged).
   - `package_sources` calls `canonical_dir(entry.fullpath)` for every
     directory entry of every package, even when there are no overlays, which
     is always the case for the command line. Guard that bookkeeping with
     `len(overlays) > 0`.
   - The overlay loop also re-canonicalizes each overlay's directory for every
     package load. Store the directory key in `Source_Overlay` when
     `set_session_overlay` records it (`src/overlays.odin:28`), and compare
     against that.
   - The same stored key would make `is_source_directory`
     (`src/overlays.odin:59-66`) cheaper.
3. **Use `expr_children` for the plain-recursion cases in
   `index_query_expr`** (done) (`src/query_index.odin:265-338`). Cases such as
   `^Expr_Index`, `^Expr_Slice`, `^Expr_Postfix`, `^Expr_Unary`, `^Expr_Binary`,
   `^Expr_Range`, `^Expr_Or_Else`, `^Expr_Cond`, `^Expr_Move`, `^Expr_Operator`,
   the pointer, slice, array, and map types, `^Type_Distinct`, `^Type_Dyn`, and
   `^Type_Anon_Union` only recurse. List them in one `case` that calls
   `expr_children`, so the switch stays exhaustive. This saves about 25 lines
   and keeps the walker in step with `ast.odin`. `doc.odin`'s `api_refs`
   (`:646`) and `select.odin`'s `unresolved_name` (`:514`) already use this
   pattern.
4. **Give lexing and parsing of free-standing text one lightweight home**
   (`src/lexer.odin:166-175`, `lsp/editing.odin:336-344`, `src/doc.odin:119`,
   `lsp/tools.odin:27`). Each of these zero-initializes and destroys a whole
   `Compiler`, which is a struct of about 150 fields, only to collect comments
   and discard errors. Two options:
   - Let `Lexer` take a comments sink and a "silent" flag, so it works without
     a `Compiler`.
   - At minimum, add `parse_text_tokens` beside `lex_text` in `lokec` and
     delete `lsp/editing.odin:parsed_tokens`.
5. **Fix the stale comment in `Compiler`** (done; the two lines were already
   gone) (`src/compiler.odin:159-160`). The
   comment "The two local region providers (`src/region.odin`), created on
   first use. `mem.Failure_Policy`, and the `.Panic` its constructors default
   to." describes no field. The next fields are `universe` and `unit_type`, and
   the comment that does describe them starts on line 161. Delete the two
   lines, or restore the fields they describe.
6. **Move the probe, commit, and settling machinery out of `source.odin`**
   (`src/source.odin:325-442`). `Emission_Registries` makes the "source manager
   and diagnostics engine" depend on witnesses, materialized constants, spawn
   tasks, and instances. Move `Probe`, `begin_probe`/`end_probe`,
   `begin_commit`/`end_commit`, `Settling`, `errors_since`, and
   `hold_diagnostics`/`release_held_diagnostics` into a `speculation.odin`
   in the checker section. This also needs a row in compiler-architecture.md
   "Source-code map".
7. **Avoid repeated work across roots in the server's `rename`**
   (`lsp/rename.odin:148-319`).
   - Each root re-runs `parsed_tokens` on every non-bundled source it loads, so
     a package shared by N roots is lexed and parsed N times. Cache the tokens
     by path key for the duration of the request.
   - The function is 170 lines with four nesting levels. Split the per-root
     checks (diagnostics, bundled uses, member conflicts, per-file token scan)
     into helpers.
8. **Derive the CLI's choice lists from the enums** (done; lower-cased, so the
   accepted spellings are unchanged)
   (`src/main.odin:341-354`). `-opt=`, `-log-level=`, and `-build-mode=` spell
   out lower-cased copies of `Opt_Mode`, `Log_Level`, and `Build_Mode`.
   `build_config.odin:133-136` already uses `reflect.enum_field_names` "so the
   two lists cannot drift apart". Write one `enum_choice($E, flag, value)` that
   compares with `strings.equal_fold` against `reflect.enum_field_names(E)`, and
   use it in all three places.

### Per-file findings

#### src/main.odin
Clean, compact CLI. One drift risk.
- **Duplication** (done: `enum_choice`, Top 8), main.odin:341-354: the literal name lists repeat the enum
  members (see Top 8). They could be replaced by a generic `enum_choice`,
  which keeps the existing `choice` error message.
- **Simplify** (done, with `@(require)`), main.odin:142: `_ :: mem` exists only so that `import
  "core:mem"` is used when `LOKE_TRACK_MEMORY` is false. Use the import only
  inside the `when` block, or write `@(require) import "core:mem"`. Minor.

#### src/session.odin
Clear session contract.
- **Simplify** (done; `lsp/server.odin` builds its lists from JSON and rewrites paths, so it keeps its loop), session.odin:45-52: the two copy loops for `defines` and
  `collections` are the same. Replace them with a helper,
  `clone_strings(src: []string, allocator) -> []string`, which saves about 4
  lines. `lsp/server.odin:288-300` builds the same kind of cloned list.
- **Simplify** (done), session.odin:142-155: `finish_session_check` tests
  `c.error_count` three times. It can return early with `if c.error_count > 0
  { return false }` and end with `return documentation || s.ready`. Saves about
  3 lines.

#### src/build_config.odin
Fine.
- **Simplify** (done, for all four), build_config.odin:33-40: `cpu_level_name` is a switch that
  could be a `[Cpu_Level]string` enumerated array, like `OPT_CLANG_FLAGS` at
  `:84`. `parse_cpu_level` would then loop over the array. Saves about 5
  lines. The same applies to `provider_slot_name` (providers.odin:23-29),
  `hook_name` (ast.odin:695-703), and `parse_subsystem`
  (subsystem.odin:29-35).

#### src/providers.odin
Coherent. Collecting, loading, and resolving providers are kept apart by phase.
- **Duplication**, providers.odin:136-152 and packages.odin:357-380: both
  switch on `Import_Resolution` and report `.No_Collection` and
  `.Outside_Collection` with nearly the same text. A helper,
  `report_resolution(c, span, why, what, path)`, could produce both messages
  and save about 12 lines. The import message's extra hint ("add `require
  ...`") can stay in a separate argument.

#### src/subsystem.odin
Fine. The only note is the enumerated-array suggestion under build_config.odin.

#### src/test_runner.odin
Fine. The tree walk, output mapping, and per-test processes are clear. No
findings.

#### src/overlays.odin
Fine.
- **Data structure/algorithm**, overlays.odin:59-66: `is_source_directory`
  builds a prefix and scans every overlay key on each call. It runs for each
  `load_package_dir` and each `register_project` dependency. With a stored
  parent-directory key per overlay (Top 2), a lookup becomes a set membership
  test plus a prefix scan only for nested directories.

#### src/queries.odin
Well structured. The snapshot validation is uniform.
- **Data structure/algorithm**, queries.odin:160-168: `query_references` scans
  every occurrence of every file for each call. The server calls it once per
  root for every references or rename request. A
  `canonical symbol -> [dynamic]Query_Occurrence` index built in
  `build_query_index` would make it linear in the result size. This is only
  worth doing if it shows up in `perf.ps1` (unverified).
- **Data structure/algorithm**, queries.odin:198-211: `occurrence_at` scans a
  file's whole occurrence list on each `query_at`. `rename.odin:234` calls it
  for every matching identifier token. Sorting `occurrences[file]` by
  `span.lo` once would let the scan stop early. Low priority.
- **Simplify** (done, both), queries.odin:589: `symbol == nil` never holds. Slot 0 is a
  real placeholder (`semantic.odin:987`), and the first loop at `:564` already
  assumes no nils. The same applies to query_index.odin:25. Delete both checks.
- **Duplication** (done), queries.odin:354, :523, and query_index.odin:71 each spell
  `symbol.kind == .Proc ? symbol.proc_type : symbol.type`. Add one
  `symbol_value_type(symbol)` helper.

#### src/query_index.odin
Correct and readable.
- **Duplication/Simplify** (done: Top 3), query_index.odin:265-338: see Top 3. This saves
  about 25 lines.
- **Data structure/algorithm**, query_index.odin:9, :54-58: `visited:
  map[rawptr]bool` hashes every expression node in the program. A file walk
  visits each node once. Repeats come only from `symbol.decl` and
  `symbol.proc_literal` revisiting syntax already walked (`:24-28`). A bit on
  `Expr_Base` and `Node_Base`, or a check that the decl or literal was already
  reached from a file item, would avoid the map. This is speculative; measure
  first (unverified).

#### src/incremental.odin
Careful and conservative. The code is small for what it does.
- **Simplify** (done), incremental.odin:216-222: `unbind_package(pkg)` runs once for
  every edited file, not once for every edited package. Unbind after the
  loop, once per distinct package. The effect is negligible.
- **Data structure/algorithm**, incremental.odin:233-235: each replacement does
  a linear search of `c.parsed_files`. That is O(edited × files), which is
  fine at today's sizes. Recording each file's index in `parsed_files` would
  remove the search.

#### src/stack.odin
Fine. No findings.

#### src/install.odin
Fine. No findings.

#### src/packages.odin
The program-level fixed point is clear.
- **Data structure/algorithm** (done: Top 2), packages.odin:283, :288: see Top 2. A
  `GetFullPathNameW` call and three temporary allocations happen per source
  file and per overlay on every package load. They also happen again for every
  package in `incremental.odin:153`, through `package_sources`.
- **Data structure/algorithm** (done for the allocation, which also reads the
  directories of the winning root only; the canonical roots are still computed
  per package), packages.odin:507-528: `package_key` sorts all
  collection names and calls `canonical_dir` on each collection root for every
  package loaded. It also calls `strings.concatenate` into the
  semantic arena each time a longer root is found, which leaves dead bytes in
  the arena that checkpoint images then copy. Instead, keep `best_name` and
  `best_rest`, and allocate once after the loop. Canonical collection roots
  could also be computed once per compilation.
- **Simplify** (done), packages.odin:314-316: `syntax` is set conditionally, and the
  same condition is then tested again for `new`. Write `file := new(File,
  syntax if syntax.procedure != nil else context.allocator)` or similar.
  Saves 1 line and removes the doubled condition.
- **Structure** (done), packages.odin:173: the comment "`written` is only for
  diagnostics; directory identity supplies the key." belongs to
  `load_package_dir` (`:197`), but sits above `package_symbol_named`.
- **Structure**, packages.odin:176-195: `package_symbol_named` and
  `package_type_named` are name lookups in the checker. `package_type_named`
  needs a `^Checker`. They are called from 13 places in other files. They
  belong with the scope and lookup helpers, not in "package discovery".

#### src/paths.odin
Fine.
- **Simplify** (done), paths.odin:38-40: `replace_ext` is the only helper here that
  allocates with `context.allocator` without an `allocator` parameter. Add the
  parameter for consistency with `join_path`, `path_dir`, and `find_on_path`.

#### src/project.odin
Fine. The manifest walk is a small BFS.
- **Simplify** (done), project.odin:29: `join_path(..., c.semantic_allocator)`
  allocates the manifest path in the semantic arena before `os.exists` has
  confirmed the file. For each missing manifest the bytes are wasted and
  later copied into checkpoint images. Use the temporary allocator, and clone
  only when `load_source` keeps the path. Minor.

#### src/select.odin
Thorough. It is the subtlest file in the group and reads well.
- **Structure**, select.odin:362-893: the `When_Walk` dependency walker is
  about 530 lines, beside about 350 lines of selection bookkeeping. Moving it
  to `when_dependencies.odin` would give each file one job. Optional.
- **Data structure/algorithm**, select.odin:459, :575: `slice.contains(w.bound[:],
  name)` is a linear scan of names bound while walking bodies that a
  condition reads. It is fine for typical conditions. If deep CTFE bodies make
  it hot, a counted map would replace it. This is the same pattern as
  `doc.odin:672` (unverified that either matters).
- **Duplication**, select.odin:714-718 (`bind_names`), :737-747, and
  ast.odin:1429-1435 (`bind_generic_params`) are the same name-collecting
  loops over different element types. Small.

#### src/compiler.odin
- **Bug (documentation)** (done: removed in `ad42446c`, bug 19), compiler.odin:159-160: an orphan comment describes
  fields that do not exist (Top 5).
- **Structure**, compiler.odin:39-407: `Compiler` has about 150 fields in
  one flat record, covering the front end, generics, the provenance solver,
  and the emission registries. `restore_checkpoint` copies it whole
  (`incremental.odin:202`), and `emission_registries`
  (`source.odin:342-359`) must list fields by hand. Grouping the fields into
  named sub-records would make phase ownership and reset rules explicit
  without any change in behavior. Example sub-records:
  `generics: Generic_State`, `provenance: Provenance_State`, and
  `emission: Emission_State`. This is a large refactor, so it only makes sense
  alongside other work.

#### src/source.odin
Solid diagnostics engine.
- **Structure**, source.odin:325-442: see Top 6.
- **Data structure/algorithm**, source.odin:116-126: `display_path` calls
  `os.get_working_directory` and allocates for every rendered diagnostic and
  note. `report` and `run_tests` could compute the working directory once
  and pass it in. Minor.
- **Data structure/algorithm** (done; `line_starts_of` serves `lsp/tools.odin`
  too, while `lsp/server_test.odin:1380` counts lines of a prefix and stays),
  source.odin:136-142: `line_starts` grows by
  appending. In incremental mode it lives in the checkpointed semantic arena.
  Counting first (`strings.count(text, "\n") + 1`) gives one exact allocation
  and avoids growth garbage in arena images. That garbage exists only if the
  arena cannot resize the last allocation in place (unverified). The same
  loop is copied in `lsp/tools.odin:71-73`. Expose a
  `line_starts_of(text, allocator)` helper.

#### src/lexer.odin
Clear and robust.
- **Data structure/algorithm**, lexer.odin:426-437: `ident_or_keyword`
  compares every identifier against up to 32 keywords. A cheap prefilter
  would skip most identifiers: every keyword is 2 to 9 lowercase ASCII
  letters, while type names start uppercase. Another option is a `switch word`.
  Low priority.
- **Data structure/algorithm**, lexer.odin:166-175: `lex_text` builds a full
  scratch `Compiler` (Top 4).
- **Simplify** (not done: the token array is kept for the whole compilation,
  so a guess that over-reserves costs memory there, while growth copies at
  most log n times), lexer.odin:153: `make([dynamic]Token)` could reserve
  `len(src)/4` and skip most regrowth. Trivial.

#### src/parser.odin
A large, consistent recursive-descent parser. Recovery and depth handling are
disciplined.
- **Bug (minor, unverified effect)** (done; already fixed: the level now
  counts only once a postfix follows), parser.odin:2421-2422: `parse_postfix`
  runs `spine += 1; deepen(p, 1)` before it knows the next token is a postfix.
  The final pass of `chain` therefore raises `p.peak` for a node it never
  builds, and `measure_height` reports one more than the real height for
  every postfix chain. `parse_binary` (`:2316-2327`) checks the operator
  first. The limit becomes conservative, not unsafe. Moving the increment
  into the cases that consume a token would make the two consistent.
- **Duplication**, six bracket-depth scanners over tokens: `resync_list`
  (`:383`), `sync_to_boundary` (`:481`), `scans_nested_pattern` (`:927`),
  `starts_anon_record_type` (`:977`), `matching_offset` (`:1934`), and
  `scans_anon_union` (`:3054`). `scans_anon_union` and the comma part of
  `starts_anon_record_type` are both "is there a token of kind K at the
  group's own depth before it closes". A shared `at_group_depth(p, offset,
  kinds)` would save about 15 lines. `resync_list` and `sync_to_boundary` could
  share one `Bracket_Depth` step helper. More siblings are in the server:
  `lsp/roots.odin:187-199`, `lsp/editing.odin:194-221` and `:281-298`, and
  `lsp/rename.odin:219-225`.
- **Simplify** (done, at the eight sites of that exact shape), 11 copies of `deepen(p, 1); defer p.depth -= 1; if p.depth >
  MAX_NEST {...}` (for example `:842`, `:1364`, `:1631`, `:1705`, `:1829`,
  `:2188`, `:2368`, `:2892`). A `too_deep :: proc(p) -> bool { deepen(p, 1);
  return p.depth > MAX_NEST }` helper saves about 11 lines. The `defer` must
  stay at each call site.
- **Simplify** (done), parser.odin:4120-4123: `is_operator_symbol` lists every
  compound assignment again. Use `compound_operator(kind) != .EOF ||` in front
  of the rest. Saves 4 lines and cannot drift from `lexer.odin:765`.
- **Structure**, parser.odin as a whole: at 4126 lines it is about 22% of this
  group. It has natural seams: items and declarations (`:589-1310`),
  statements (`:1311-2181`), expressions (`:2183-2845`), and types, records,
  and procedures (`:2846-4126`). Splitting would require turning
  `@(private="file")` helpers into package-private `@(private)` ones, so the
  trade-off is debatable. Optional.

#### src/ast.odin
Clean node definitions with exhaustive `*_base` switches.
- **Simplify** (done), ast.odin:695-703: `hook_name` could be a `[Hook_Kind]string`
  array (see build_config.odin).
- **Structure**, ast.odin:1401-1480: `type_syntax_any_name`,
  `bind_poly_names`, `bind_signature`, and `Name_Walk` are generic-checking
  helpers, not syntax definitions. They fit `generic.odin` better. `ast.odin`
  should keep `expr_children` and the `*_base` accessors. Optional.

#### src/ast_dump.odin
Straightforward deterministic dumper. No findings.

#### src/formatter.odin
Careful, and the token-preservation check is good.
- **Structure** (done, as a comment), formatter.odin:19-45: `rewrite_files` is the shared driver
  for `-fmt` and `-migrate`. It reads as part of the formatter, but
  `migrate.odin` depends on it. A header comment saying so, or a small
  `rewrite.odin`, would make the dependency explicit. Minor.

#### src/migrate.odin
Fine. The edits are checked by comparing AST dumps.
- **Simplify** (not done: reporting "unchanged" would change the
  `rewrite_files` contract for `-fmt` too, to save one copy of a file),
  migrate.odin:34-36: an unchanged file is cloned only so that
  `rewrite_files` can compare it and delete it. If the rewrite procedure could
  report "unchanged", no clone would be needed. Trivial.

#### src/doc.odin
One model drives both `-doc` and `-api`, which is a good design.
- **Data structure/algorithm** (done: Top 1), doc.odin:794: see Top 1. Each call costs two
  `lex_text` calls, each with a scratch `Compiler`, even when no comment was
  removed.
- **Bug (edge, unverified)** (not done: `text` has comments cut by
  `shown_text`, so a source offset such as `expr_span(literal).lo` does not
  index it directly; the case is probably unreachable), doc.odin:491-492:
  `proc_interface_text` finds
  the procedure by `strings.index(text, "::") + 2`. A typed constant written
  `f : proc() : proc() { ... }` has no `::`, so `index` returns -1 and the
  search starts at offset 1. The convention would then go after the type's
  `proc`, not the literal's. The text is only rewritten when the decl is in a
  foreign block with `default_calling_convention`. Foreign members are
  `name :: proc ... ---`, so this is probably unreachable. Using
  `expr_span(literal).lo` would make it exact.
- **Simplify** (done), doc.odin:99-104: the import de-duplication with
  `slice.contains` is quadratic. It is fine at real sizes, but sorting first
  and skipping equal neighbours removes the `contains`. Trivial.

#### src/doc_comments.odin
Fine.
- **Duplication/Simplify**, doc_comments.odin:213-227: the
  `^Type_Pointer`/`C_Pointer`/`Slice`/`Dynamic_Array`/`Distinct`/`Array`/`Map`
  cases only recurse. A default `case: expr_children(...)` saves about 14
  lines. It also changes behavior slightly: records nested inside an array
  length or a call argument would also count as documented. That is arguably
  more correct for `L0260`, but needs a test.

#### src/scratch_arena.odin
Carefully reasoned allocator. No findings.

#### src/subprocess/subprocess.odin
Robust. Job objects, inheritable-handle lists, and quoting are all handled.
- **Data structure/algorithm**, subprocess.odin:84-98: the read loop still
  polls every 1 ms, with `timeBeginPeriod(1)` while any child runs. Overlapped
  reads or `WaitForMultipleObjects` on the process and pipe events would
  remove the polling. This is a deliberate trade-off, so it only matters if
  parallel builds show CPU cost (unverified).
- **Simplify** (no change needed, as the finding says), subprocess.odin:328-337: `environment_block_of` is quadratic
  in the number of environment entries. That is fine at about 100 entries; no
  change is needed.

#### lsp/main.odin
Clean. No findings.

#### lsp/jsonrpc.odin
Fine.
- **Data structure/algorithm**, jsonrpc.odin:29: after each `fill`, the header
  search rescans the whole buffer from the start. `remove_range` (`:49`)
  shifts the rest of the buffer after every message. Both are fine at LSP
  message rates; a read offset would avoid both. Low priority.

#### lsp/server.odin
Clear dispatch and lifecycle.
- **Duplication** (done), server.odin:236-244 and :249-257: the `valueSet` parsing
  for symbol kinds and completion kinds is the same code. A helper,
  `client_value_set(capability: json.Value, default_last: int) -> bit_set[0..<64]`,
  saves about 8 lines.
- **Structure** (done), error codes are defined in four files: server.odin:18-22,
  `CONTENT_MODIFIED` at requests.odin:20, `REQUEST_FAILED` at rename.odin:16,
  and `INVALID_PARAMS` at tools.odin:11. Gather them in server.odin.

#### lsp/roots.odin
Root assignment is subtle but well explained.
- **Duplication** (done), roots.odin:46 and requests.odin:127-130: both contain the
  loop "any root dirty". `has_pending_work` should call `any_root_dirty`, after
  making it non-private.
- **Data structure/algorithm**, roots.odin:122-137: `importing_root` is
  O(roots²) per document, which makes `refresh_roots` O(docs × roots²). It is
  fine for tens of open documents. Note it if workspaces grow.
- **Data structure/algorithm** (done, except in `write_location`, whose
  callers also pass document paths), roots.odin:319, :471, requests.odin:442, and
  rename.odin:81, :278: `path_key(path)` re-runs `canonical_dir`, and so
  `filepath.abs`, on paths that `place` (`roots.odin:335`) already
  canonicalized. Use `lokec.dir_key(path)` for those, which avoids a system
  call per reference, related note, and edit.
- **Structure**, `place`, `write_range`, and `uri_for` (roots.odin) and
  `write_location` (requests.odin) are protocol-encoding helpers that
  requests, rename, and tools all use. They belong with `paths.odin` or
  `jsonrpc.odin`.

#### lsp/requests.odin
Fine.
- **Simplify** (done), requests.odin:211-218: both branches of `if s.markdown_hover`
  append the documentation the same way. Write `value := s.markdown_hover ?
  fmt.tprintf("```loke\n%s\n```", text) : text` and then a single `if
  documented`. Saves 3 lines.
- **Duplication**, requests.odin:283-290 (`client_kind`) and
  editing.odin:23-30 (`completion_client_kind`): the same "member of the
  client's bit set, else an older equivalent" pattern. Likewise
  `outline_kind` (requests.odin:361-378) and `completion_kind`
  (editing.odin:126-144) repeat the mapping from `.Type` to Struct, Enum,
  Interface, or Class. Small.

#### lsp/editing.odin
Fine.
- **Duplication**, editing.odin:336-344: `parsed_tokens` is `lex_text` plus
  `parse` around a scratch `Compiler` (Top 4). Move it into `lokec` next to
  `lex_text`.

#### lsp/rename.odin
The refusal logic is careful and every refusal is explained.
- **Data structure/algorithm**, rename.odin:212-218: per-root re-lex and
  re-parse of shared sources (Top 7).
- **Data structure/algorithm**, rename.odin:250, :389, :399: `visible_named`
  and `reaches` each call `query_visible` for every occurrence. Each call
  sorts the file's locals and walks the package scope plus the universe.
  Renaming a widely used package-level name pays this cost for every use.
  Cache the result per (file, innermost scope span) within the request.
- **Structure**, rename.odin:148-319: one 170-line function (Top 7).

#### lsp/tools.odin
Fine.
- **Duplication** (done), tools.odin:71-73: hand-computed `line_starts` (see
  source.odin).

#### lsp/paths.odin
Fine.
- **Duplication** (not done: the shared part is one expression, so a helper
  saves no lines), paths.odin:99-106 and :109-117: the UTF-16 unit-counting
  loop appears twice. `position_to_offset` could step with a shared
  `utf16_units(r)`. Trivial.

### Cross-file duplication

| Pattern | Sites | Proposal |
| --- | --- | --- |
| Scratch `Compiler` to lex or parse free-standing text | src/lexer.odin:167 (`lex_text`), src/doc.odin:119, lsp/editing.odin:337 (`parsed_tokens`), lsp/tools.odin:27 | A lexer that runs without a `Compiler`, plus `parse_text_tokens` in `lokec` (Top 4) |
| Hand-written recursion that `expr_children` already provides | src/query_index.odin:265-338, src/doc_comments.odin:213-227. Already using it: doc.odin:646, select.odin:514, ast.odin:1477 | Fall back to `expr_children` for the trivial cases (Top 3) |
| Bracket-depth scanners over tokens | src/parser.odin:383, :481, :927, :977, :1934, :3054; lsp/roots.odin:187; lsp/editing.odin:194, :211, :281; lsp/rename.odin:219 | One `Bracket_Depth` step helper in `lokec`, used by both the parser and the server |
| Statement walkers (one `switch` over `Stmt` each) | select.odin:796, query_index.odin:137, ast_dump.odin, plus check_stmt, cfg, eval, expand, ast_clone, emit_llvm_stmt outside this group | A `stmt_children` analogue of `expr_children` would serve at least select.odin and query_index.odin. The others need per-node behavior. Low priority |
| Reporting `Import_Resolution` failures | src/packages.odin:357-380, src/providers.odin:136-152 | One reporting helper (not done: the two report different codes and messages, so a helper would take both as parameters) |
| `line_starts` computation | src/source.odin:136-142, lsp/tools.odin:71-73 (and lsp/server_test.odin:1380) | `line_starts_of(text, allocator)` (done) |
| Enum-to-string switches | build_config.odin:33 (`cpu_level_name`), providers.odin:23 (`provider_slot_name`), ast.odin:695 (`hook_name`), subsystem.odin:29 (`parse_subsystem`) | `[Enum]string` arrays (done), as `OPT_CLANG_FLAGS` and `ast_dump.odin`'s tag tables already are |
| CLI names that repeat enum members | main.odin:341, :343, :352, :354 | Derive from `reflect.enum_field_names` (Top 8) |
| `kind == .Proc ? proc_type : type` | queries.odin:354, :523, query_index.odin:71 | `symbol_value_type` helper (done) |
| Bundled-collection test | project.odin:54, :105; packages.odin:513; queries.odin:107; check_expr.odin:2822 | `is_bundled_collection(name)` and `is_bundled_key(key)` helpers (done; check_expr.odin tests `base:` alone and stays) |
| "Any root dirty" loop | lsp/roots.odin:46, lsp/requests.odin:127-130 | Use one helper (done) |
| Client capability kind fallback | lsp/requests.odin:283 and :361, lsp/editing.odin:23 and :126 | Shared helper with a fallback table |
| Copying a list of strings | src/session.odin:45-52, lsp/server.odin:288-300 | `clone_strings` (done for the session) |
| `path_key` on a path that is already canonical | lsp/roots.odin:319, :471; lsp/requests.odin:442; lsp/rename.odin:81, :278 | `lokec.dir_key` directly (done where the path came from `place`) |
| Bound-name lists checked with `slice.contains` | select.odin:459, :575; doc.odin:577, :672; ast.odin:1420-1450 | Consistent and fine at today's sizes. Change only if profiling shows a cost |

#### Finding counts

| Category | Count |
| --- | --- |
| Bug | 3 (stale field comment; parser depth overcount; `proc_interface_text` edge case, unverified) |
| Simplify | 17 |
| Data structure/algorithm | 19 |
| Duplication | 13 per-file, 2 of them also simplifications, plus 15 cross-file patterns |
| Structure | 11 |

## Group 2: checker and semantic core

Revision fd381d23. Files: `src/check.odin`, `check_stmt.odin`, `switch.odin`,
`check_expr.odin`, `check_composite.odin`, `conversions.odin`, `check_calls.odin`,
`check_builtin.odin`, `bigint.odin`, `const_ops.odin`, `const_float.odin`,
`zero.odin`, `overload.odin`, `impl.odin`, `operators.odin`, `customization.odin`,
`semantic.odin`, `types.odin`, `universe.odin` (about 18,200 lines). Read-only
review; nothing was built or run.

### Overview

The group is in good shape. The code is careful and well commented, it cites the
spec consistently, and the tricky numeric parts (`const_float.odin`, `bigint.odin`)
are correct as far as I could check by hand: they use exact dyadic arithmetic and
document their workarounds for `core:math/big`. Most findings fall under four
themes:

1. **Logic written twice that has started to drift.** The clearest case is
   parameter flattening. `resolve_proc_type` re-implements `append_signature_group`
   and already gives a different answer for `@(escape)` and `@(cross_thread)` on
   variadic parameters.
2. **Throw-away data allocated in the semantic arena, which never frees.**
   Candidate lists, overload rank vectors and diagnostic description strings are
   built on every lookup and every call, inside probes too.
3. **Linear scans on hot lookup paths.** Member, field and operator lookup scan
   flat member slices, and `type_is_comparable` is recomputed from scratch on every
   use.
4. **Very large files.** `check.odin` and `check_expr.odin` each hold several
   separable subsystems.

There are also a few small accounting leaks: evaluator temporaries that the
`bi_release` contract says are released, but are not.

### Top recommendations

1. **Share one parameter-flattening helper between `append_signature_group`
   (`src/check.odin:1262`) and `resolve_proc_type` (`src/check.odin:1854`).** This
   fixes a real divergence:
   - A variadic `..T` parameter's `@(escape)` and `@(cross_thread)` are checked
     against `T` in a declaration but against `[]T` in a written procedure type.
   - So a procedure type can accept what a declaration of the same signature
     rejects (L0648/L0723), and in a generic instance the two can intern different
     procedure types.

   Saves about 35 lines.
2. **Stop putting short-lived lookup and overload data in `c.semantic_allocator`.**
   - Candidate lists: `member_candidates` (`src/impl.odin:567`),
     `method_candidates`, `select_slicers`, `select_by_place`,
     `operator_candidates` and `operator_candidates_for_receiver`.
   - `build_candidate`'s `ranks`, `slots` and `filled` (`src/overload.odin:441-460`).
   - Eagerly built `description` strings (`src/check_calls.odin:425,474,1126`).

   All of these run on every call and every method call, in probes too, and stay
   allocated until the compilation or checkpoint is reclaimed. Use
   `context.temp_allocator`, or format only when a diagnostic is raised.
3. **Index members by name per type, and cache `type_is_comparable`.**
   - `member_candidates`, `find_member`, `struct_field` and `add_operator_members`
     scan `Type_Info.members` or `fields` linearly on every selector, method call
     and operator use.
   - `type_is_comparable` (`src/operators.odin:1019`) walks the whole type and
     calls `inherent_self_operator` twice per node on every comparison and switch.
     (Not cached: its answer reads each type's `==` members, which `impl` blocks
     and generic instances still add while bodies are checked, so a cached
     `false` could go stale. A cache needs a point after which members are final.)

   Measure with `perf.ps1` before and after.
4. **Share zero values when a literal is folded.** (Done: `fold_aggregate`
   shares one zero, and `zero_const` counts once, at the type it was asked
   for, since a component never counts more elements than its whole.) `fold_aggregate`
   (`src/check_composite.odin:530-548`) calls `zero_const` once per unwritten slot,
   so `[1000][100]int{}` builds 1000 identical rows, where `zero_const` itself
   builds one row and shares it. Separately, `zero_const` re-counts
   `const_element_count` at every level of recursion (`src/zero.odin:159`).
5. **Release evaluator temporaries in the constant helpers the evaluator calls.** (Done: bug 8, in `21759e66` and `ae120d14`)
   `exact_fma` (`src/const_float.odin:41-49`), `rotate_const`
   (`src/const_ops.odin:156-158`), `bit_value_const` (`src/const_ops.odin:136`),
   and the unwrapped result in `fold_integer` / `fold_unary`
   (`src/const_ops.odin:323,235`) leave integers charged to the evaluation's
   memory limit, against the contract `bi_release` states. Today the charge is up
   to about 8 times what such a call holds.
6. **Stop re-checking the same things on every checked statement.** (Done for
   `require_unsafe_import`, which asks the package being checked first;
   `place_setters` is not: a program-wide "any `[]=` declared" flag would also
   have to see local operator declarations and survive session checkpoints.)
   - `place_setters` (`src/check_stmt.odin:823`) probe-checks a clone of the
     operand of every indexed assignment, two or three times per target.
   - `require_unsafe_import` (`src/check_expr.odin:2816`) scans every package's
     every file for each unchecked operation.

   Add a cheap pre-filter for both: "is any `[]=` declared at all?", and a fast path
   when `span.file == k.file`.
7. **Merge near-identical helpers** (each is detailed under Cross-file duplication):
   - Three predeclared-type tables become one.
   - (Done.) `struct_field`, `subject_field_named` and `enum_member` become `member_named`.
   - One group-flattening iterator replaces seven loops.
   - (Done.) One allocator-operand check replaces three copies, plus a
     `type_is_allocator` predicate.
8. **Split the two biggest files.** Move type-syntax resolution, finite size and
   unresolved-type diagnostics out of `check.odin` (about 680 lines), and indexing
   and slicing out of `check_expr.odin` (about 650 lines).

### Per-file findings

#### src/check.odin

Verdict: sound, but it mixes five subsystems and holds the group's one
correctness bug.

- **Bug: `@(escape)` and `@(cross_thread)` on a variadic parameter are checked
  against different types in a declaration and in a procedure type.**
  - In a declaration, `append_signature_group` passes
    `written_type = parameter_type`, the element `T` of `..T`, to
    `check_escape_attribute` and `check_cross_thread_attribute`
    (`src/check.odin:1309-1317`).
  - In a written procedure type, `resolve_proc_type` passes `resolved`, which
    `normalize_signature_parameter` has already turned into `[]T`
    (`src/check.odin:1890-1900`).
  - Consequences:
    - `proc(@(escape=none) xs: ..int)` is accepted as a type, since `[]int` carries
      a borrow, but the deferred check rejects it as a declaration with L0648
      (`int` carries none).
    - `@(cross_thread) fs: ..proc()` is the reverse: accepted in a declaration
      (`proc`) and rejected in a type (`[]proc`) with L0723.
    - In a generic instance, `check_escape_attribute` drops the level for a `T`
      without borrows but keeps it for `[]T`, so the declaration and the spelled
      type intern different `param_escapes`.
  - design.md "Variadic parameters" says the level "bounds what the lent values
    hold, as it does for a `value: T` parameter", which favours the declaration
    path.
  - Fix: one helper, used by both callers, that flattens a parameter name into
    (type, mode, reset, escape, cross) and checks attributes against the written
    element type. Add a regression test for each attribute. Unverified by a run;
    reproduce first.
- **Duplication:** (done with bug 1: `check_signature_parameter` and `append_signature_parameter`) apart from the bug, `resolve_proc_type` (`src/check.odin:1866-1902`)
  is a cut-down copy of the per-name loop in `append_signature_group`
  (`src/check.odin:1287-1357`): `allocator_reset_ok`,
  `normalize_signature_parameter`, `variadic_position_ok`, escape, cross-thread.
  Sharing them saves about 35 lines.
- **Simplify: the "for each file, set the location, for each active item" loop is
  repeated.** It appears at `src/check.odin:167,193,277,308,331`, in
  `for_each_package_decl` (360), and again in `src/operators.odin:620`. Generalise
  `for_each_package_decl` to `for_each_package_item(k, pkg, visit: proc(^Checker, Item))`.
  Also wrap the `check_deferred_foreign_parts/escape_parts/union_zeros` trio, which
  is called twice (298-300 and 340-342), in a `check_deferred_parts(k)`. About 25
  lines.
- **Duplication:** the body-context setup is written three times: a new
  `.Procedure` scope, `owner_proc = literal`, and
  `k.body = {proc_literal = literal, ...}`. See `check_param_defaults` (1383-1388),
  `infer_param_default_type` (1420-1424) and `check_proc_body` (2678-2683).
  Extract an `enter_procedure_body(k, literal, result, inout)` that returns the
  saved scope and body. About 10 lines.
- **Data structure/algorithm** (done for struct fields, through a temporary
  map; group members and anonymous record fields are written by hand, so they
  keep the scan): duplicate-name checks are quadratic.
  `resolve_struct_fields` calls `member_named(members[:])` for every field (827),
  `resolve_anon_record` uses `slice.contains(names)` (950), and
  `resolve_group_members` uses `slice.contains(members)` (781). Generated
  bindings, such as C structs with hundreds of fields, pay O(n²). A temp
  `map[Identifier_Id]struct{}` is the same amount of code.
- **Simplify:** `report_unresolved_type` (2087) suppresses `unsupported_construct`
  whenever `k.c.error_count > 0`, so any unrelated earlier error anywhere in the
  compilation suppresses it. Callers such as `check_composite`
  (`src/check_composite.odin:21,40`) call it without an error mark. Pass the mark
  instead.
- **Simplify** (done): two doc comments are stacked on `check_new_local` (495-499). The
  first ("Creates the symbols for one declaration ... foreign block's members")
  belongs on `declare_all`.
- **Structure:** at 2723 lines the file holds:
  - the package phase driver (147-370);
  - entry validation (433-493);
  - signatures (586-1470);
  - destructuring helpers that `check_stmt.odin` and `switch.odin` use (966-1068);
  - finite size (1498-1632);
  - type-syntax resolution and unresolved-type diagnostics (1634-2175);
  - declaration and procedure checking (2176-2723).

  Moving type syntax and finite size into a `check_types.odin` would leave
  `check.odin` to declarations and signatures. That also matches the "type syntax"
  responsibility compiler-architecture.md already names separately.

#### src/check_stmt.odin

Verdict: clear. The `operator([]=)` lowerings are well explained. One walk is
duplicated and one check is repeated on every statement.

- **Duplication:** `report_local_copy_decisions` (30-54) and
  `report_unread_required_results` (74-124) repeat the same walk: unwrap
  `Stmt_Defer`, recurse into `Stmt_When.selected`, select `^Decl`. Extract one
  `for_each_sequence_decl(stmts, visit)`. `src/impl.odin:432`
  (`hoist_hooks_in_stmt`) is a wider relative. About 15 lines.
- **Data structure/algorithm: repeated probe checks on every indexed assignment.** (not done: see Top 6)
  `place_setters` (823) probe-checks a clone of the operand of every indexed
  assignment (`a[i] = v`, `a[i] += v`):
  - `check_assign` → `check_place_setter` (438)
  - `lower_compound_setter` (535)
  - `any_place_setter` (843)
  - `reject_destructured_setter_target` (725)

  A multiple assignment probes each indexed target twice and then checks it for
  real. For an operand containing a call, each probe may instantiate generics.
  Pre-filter cheaply: keep a compiler-wide flag set when any `[]=` operator is
  declared (`join_package_operators`, `install_impl_members` with
  `operator == "[]="`) and skip the probe when it is clear. Or memoise the answer
  on the `Expr_Index` node.
- **Structure:** `lowered_assign` (774), `lowered_address` (769) and
  `check_lowered_block` (562) are syntax builders. Per compiler-architecture.md
  ("`synth.odin`: builders for the syntax lowerings"), `lowered_assign` belongs in
  `synth.odin` as `synth_assign`. Today the only other `new(Stmt_Assign` is at
  check_stmt.odin:697, so `lower_destructuring_setter_assign` could use it too.
- **Bug (unverified, minor):** (done: bug 17, now L0310) the discard path in `check_assign` (426-433)
  handles `_ = nil` silently. `default_type(TYPE_UNTYPED_NIL)` is `INVALID_TYPE`,
  so `materialize` returns false without a diagnostic and the discard keeps type
  `untyped nil`. `check_decl_value` and `infer_param_default_type` report L0310
  ("`nil` has no type to infer here") for the same case. Decide which is intended,
  and add a test either way.

#### src/switch.odin

Verdict: good. Union switches use a quadratic data structure where value
switches deliberately avoid one.

- **Data structure/algorithm** (done): a union switch tracks the variants it has seen in
  a `[dynamic]int` searched with `slice.contains` (308, 343). Then
  `report_uncovered_variants` searches it again for every variant (500). That is
  O(V²). The value switch beside it uses `Integer_Set` precisely because "a
  generated switch can have thousands" (112-120). Use a `[]bool` of
  `variant_count(subject)` (the index is the tag), which gives the same line count
  and O(V).
- **Duplication** (not done: the comparison in check_expr.odin reads the
  collected list again to decide whether to fold, so it keeps collecting it):
  the "collect own equalities, then require them visible" pair at
  54-57 also appears in `src/check_expr.odin:2323-2328`. Fold it into
  `own_equalities_visible(k, type, span)`, which collects them itself.
- **Simplify:** the per-case scope push and pop (78-81, 313-322) is the
  `check_scoped_block` pattern written out twice. A small `with_local_scope` helper,
  or `defer`, would remove the manual restore.

#### src/check_expr.odin

Verdict: the core dispatch and `materialize` are solid. The file is too large
and has allocation and lookup costs on hot paths.

- **Data structure/algorithm:** (done: Top 6) `require_unsafe_import` (2816-2835) loops over
  every package and every file to find the one holding `span.file`, then scans its
  imports. That is O(total files) per C-pointer index, slice or unsafe conversion
  (5 call sites). Nearly always `span.file == k.file`, so fast-path through
  `package_of(k.c, k.pkg)`. Better: record "imports `core:unsafe`" on `File` when
  imports bind.
- **Data structure/algorithm (allocation):**
  - `method_candidates` (1063), `select_slicers` (1552) and `select_by_place`
    (1666) allocate their result in `k.c.semantic_allocator` on every call.
    (Not done for `method_candidates`: a method call keeps its list as
    `overload_members` on the typed AST.)
  - (Done.) `select_call_method` builds a whole candidate list only to test whether it is
    empty: `len(method_candidates(...)) == 0` (771). Use
    `first_method(...) == INVALID_SYMBOL`, which already exists (1052).
  - Lists that do not outlive the call belong in `context.temp_allocator`.
- **Duplication:** `select_call_method` (749-777) repeats the receiver walk of
  `check_value_selector` (670-738): own type, then box payload, then pointee, then
  an untyped receiver's default type. One `select_method_through(k, v, operand,
  callee) -> bool` serves both. About 15 lines.
- **Simplify** (not done: the second lookup is on the payload's underlying
  type, or its pointee when the payload is a pointer, so the two can differ):
  for a boxed operand, `check_value_selector` computes
  `promoted_field_path` for `boxed.element` (677), then computes it again for the
  same record on 700 after the deref. Keep the first result.
- **Duplication** (done, as `field_named` in types.odin): `struct_field` (2880-2891) is
  `member_named(c, underlying_info(...).fields, name)`. It is also the same as
  `subject_field_named` (`src/impl.odin:381`), and `enum_member` (2893) is an
  alias of it. Keep one, `member_named` plus a `field_named(c, type, name)`, in
  `types.odin`.
- **Simplify** (done): the file header (line 3) says "`check.odin` owns declarations and
  statements", but statements are in `check_stmt.odin`.
- **Structure:** at 2908 lines, indexing and slicing (1119-1775:
  `check_index`, `check_slice`, `index_arguments`, `packed_field_reached`) is a
  self-contained unit for a `check_index.odin`. General helpers that are not
  expression checking also live here: `require_unsafe_import`, `struct_field`,
  `enum_member`, `operator_text`, `is_const_expr`.

#### src/check_composite.odin

Verdict: clean and compact. Folding is wasteful for large zero-filled
literals.

- **Data structure/algorithm:** (done: Top 4) `fold_aggregate` (530-548) calls
  `zero_const(k.c, element_type)` once per unwritten slot. For an array, every
  slot has the same `info.element`, so `[1000][100]int{}` builds 1000 separate
  100-element rows, about 11 MB of `Const_Value`s in the semantic arena, where one
  shared row is enough. Compute the zero once when `fields == nil`. Also, when
  `len(v.elements) == 0` for an array or struct, `zero_const(target)` gives the
  whole result directly and already shares the element (`src/zero.odin:216-219`).
- **Simplify** (not done: the text is already built in temporary memory):
  `check_omitted_fields` builds the "the omitted field `x`" text with
  `strings.concatenate` for every omitted field (272), though
  `require_type_has_zero` reads it only when it reports. Build it only on failure,
  or let `require_type_has_zero` take a format and argument.

#### src/conversions.odin

Verdict: clean; nothing notable. `assignable` and `convertible` are compact and
read like the spec.

#### src/check_calls.odin

Verdict: correct and well commented. Argument binding exists in three
variants.

- **Duplication:** filling defaults is written twice:
  - `bind_arguments` (766-789)
  - `bind_variadic_arguments` (1229-1244)

  Both do: skip a bound slot, bail out if a failure already explains the gap,
  report a missing argument, `substitute_caller_location`, then append to the order.
  Extract `fill_defaults(k, v, declared, bound, from, to, &order) -> (defaulted, ok)`.
  About 20 lines.
- **Duplication / Structure (unverified):**
  - The three binders all build `bound` plus `bound_order` with the same rules:
    `bind_arguments`, `bind_variadic_arguments`, and
    `bind_chosen_call`/`bind_candidate_slots`.
  - The direct-call path (`check_procedure_call` → `bind_arguments`) could build a
    single `Candidate` with `build_candidate` and reuse `bind_chosen_call`, which
    already handles named slots, defaults and packs.
  - That removes most of `bind_arguments`, about 80 lines. Diagnostic wording
    differs ("missing an argument for `x`", L0371 for a procedure value), so
    either keep those reports or update the tests.
- **Data structure/algorithm (allocation)** (done, with `fmt.tprintf`; the
  conversion description also names its type in temporary memory):
  `check_method_call` (425),
  `check_group_call` (474) and `check_conversion_hook_call` (1126) build
  `description` with `concat` in the semantic arena on every call. Only a failed
  resolution reads it. `resolve_operator_set` already uses `fmt.tprintf`
  (`src/operators.odin:553`). Do the same, or pass the name and format lazily.

#### src/check_builtin.odin

Verdict: systematic and exhaustive by construction. Small near-copies.

- **Duplication** (done): the allocator-operand check is written three times:
  - `check_allocator_argument` (263-273)
  - the `.Free_All` branch (651-658)
  - `check_via_policy` (`src/check.odin:2516-2529`)

  Each does `check_single_expr(e, TYPE_ALLOCATOR)` and then
  `type_underlying == TYPE_ALLOCATOR`, else L0490/L0578 with a different message.
  Give `check_allocator_argument` a message or code parameter. About 12 lines.
- **Duplication** (done, with a file-private `argument_count_is`;
  `builtin_argument_count_ok` keeps its numeric wording): argument-count
  reports are hand-written, with near-identical
  text, in:
  - `check_typed_builtin_args` (118-124)
  - `check_transmute_builtin` (706-713)
  - `check_wrap_builtin` (803-809)

  This is what `builtin_argument_count_ok` (251) does, except that it prints a
  number rather than a description. Add an optional `wanted_text`. About 15 lines.

#### src/bigint.odin

Verdict: good. The workarounds for `core:math/big` bugs are documented, and
`Integer_Set` fits its job.

- **Simplify:**
  - (Done.) `bi_from_i64` and `bi_from_u64` (62-76) are identical except for the parameter
    type, so one polymorphic `bi_from_int(c, v: $T)` replaces both. Keep the old
    names as one-line wrappers if call-site churn matters.
  - (Not done: `bi_shr_logical` also clamps, and passing `core:math/big`
    procedures needs their exact signatures, defaults included.) `bi_shl`
    (228) and `bi_shr_logical` (253) repeat the setup that `bi_unary` /
    `bi_binary` already factor out (arena, copy, op, settle). Give the shifts a
    `bi_shift(c, a, count, op)` helper.

  About 12 lines.

#### src/const_ops.odin

Verdict: correct folding and transmute logic. A few intermediates escape
`bi_release`.

- **Bug (memory accounting):** (done: bug 8) the evaluator calls these helpers with `ev.alloc`
  (`src/eval.odin:855,900,2609,2625`), where every integer is charged until it is
  released (`src/eval_memory.odin` header; `bi_release` in bigint.odin:38). These
  intermediates are never released:
  - `fold_integer` (322-323): for `+%`, `-%`, `*%` and `<<` the unwrapped `result`
    is lost when `wrap_to_type` builds a new value. Typical CTFE hashing does
    `h = (h ~ b) *% PRIME` in a loop.
  - `fold_unary` (235): the same.
  - `rotate_const` (156-158): `pattern`, both shifted halves, and `rotated` when it
    is re-wrapped.
  - `bit_value_const` (136): a `1` built only to compare against.

  `dyadic_to_float` and `decimal_to_float` show the intended pattern. Release
  whenever the wrapped value's digits differ from the input's.
- **Simplify:** (done with bug 8: decided without building a 1) `bit_value_const` line 136,
  `bi_cmp(value, bi_from_i64(storage, 1)) <= 0`, can be
  `bi_sign(value) <= 0 || bi_magnitude_bits(value) <= 1`. That allocates nothing
  and builds nothing to leak.

#### src/const_float.odin

Verdict: high quality. The exact `sqrt`, `mod` and `fma` and the decimal rounding
are carefully argued. One leak.

- **Bug (memory accounting):** (done: bug 8) `exact_fma` (41-49) builds about 8 integers in
  evaluator storage and releases none of them: three `dyadic_of` significands, the
  product, two shifted terms and the sum. It is called from `src/eval.odin:2590`
  with `ev.alloc`. Add `bi_release` as `dyadic_to_float` (244, 255, 262) does.

#### src/zero.odin

Verdict: fine. The element-count guard is recomputed redundantly.

- **Data structure/algorithm:** (done: Top 4) `zero_const(build = true)` calls
  `const_element_count(c, type)` (159) at every level of its recursion, and
  `const_element_count` walks the whole subtree, so a nested aggregate costs
  O(size × depth). Check once in a public wrapper, then recurse in a file-private
  `zero_const_walk` without the check. `fold_aggregate` adds another full count
  per slot (see check_composite above).
- **Simplify** (done): `capacity_const` (105-109) dereferences `info.count` without
  checking for nil, unlike every sibling. A one-line guard keeps it consistent.

#### src/overload.odin

Verdict: well structured; ranking and tie-breakers read like the spec. It
allocates in the wrong place.

- **Data structure/algorithm (allocation):** `build_candidate` allocates `ranks`,
  `slots` (441-443) and `filled` (460) in `k.c.semantic_allocator` for every
  member of every resolution, inside probes too. `form_candidates` already keeps
  the `Candidate`s themselves in `context.temp_allocator` (694).
  `bind_chosen_call` copies what it keeps (`order`, `bound`), so temp storage
  should be enough (unverified: confirm no `Candidate` is cached on an
  `Instance`).
- **Simplify:** the header comment (28-29) says reasons are "worded only if the
  call fails". But `build_candidate` formats named-argument rejections with
  `fmt.aprintf` into the semantic arena (475-488), and so does
  `c_vararg_rejection` (372), even when another candidate wins. Add a
  `Rejected_Name{name, twice: bool}` variant to `Rejection`, worded in
  `rejection_text`.

#### src/impl.odin

Verdict: the logic is careful (quiet declaration, local hooks, visibility). The
lookup data structure is the weak point.

- **Data structure/algorithm:** every member lookup:
  - runs the 9 `ensure_*` contributors (551-561);
  - allocates `out` in the semantic arena (567);
  - scans all of `info.members` and the package's extension slice, comparing names
    (`expand_visible_members` 641, `visible_member_named` 685, `excluded_member`
    584).

  This is the path of every `x.method()`, `T.member` and associated lookup.
  Contributed tables, such as a container's operations, make `members` long. A
  lazily built `map[Identifier_Id][]Symbol_Id` on `Type_Info`, rebuilt in
  `add_members` and `install_impl_members`, makes it O(1) per name. Measure with
  `perf.ps1` first.
- **Duplication:** group flattening in `expand_visible_members` (649-656). See
  Cross-file duplication.
- **Simplify** (not reproduced: a probe with two bounds that each require a
  `put` slot resolves `T.put(x, 2)` as `x.put(2)` does, so no known-gaps entry
  was written): the `ponytail:` note at 673 records a user-visible limit:
  `T.m(x)` finds nothing for a bound-reached group with more than one member,
  while `x.m()` resolves. Per AGENTS.md, a divergence like this belongs in
  `known-gaps.md` with a reproduction. I found no entry.

#### src/operators.odin

Verdict: the delegation and pending-operator machinery is intricate but well
documented. It has near-copies and one uncached hot predicate.

- **Duplication:** `hidden_inherent_operator` (347-372),
  `inherent_self_operator` (393-416) and `add_operator_members` (276-290) each
  scan `members` for `sym.operator == symbol`, expand a `.Proc_Group` into its
  members and test a predicate. One `for_each_flat_member(c, members, symbol,
  visit)` covers them. About 20 lines.
- **Duplication:** `Pending_Operator`, `Pending_Operator_Block` and
  `Pending_Delegate` (635-697) are the same `{node, location: Checker_Location}`
  pair. One generic `Pending(T)` struct removes two declarations.
- **Data structure/algorithm:** `type_is_comparable` (1019) is not cached. It
  walks the whole type with a fresh `Type_Walk` map, and at every node calls
  `type_own_equality` → `inherent_self_operator` twice, once for the type and once
  for its underlying type, each a linear member scan with string compares. It runs
  for every `==`, every value switch (`src/switch.odin:50`) and every key-policy
  check. Cache it like `type_may_hold_address` (`src/types.odin:234`). Only cache
  once `type_records_finished` holds, and invalidate where inherent members are
  added.
- **Structure:** the comparability and ordering predicates (1015-1262) are type
  queries, not operator declarations. They fit `types.odin`, or a `comparison.odin`
  that `hash.odin` and map-key policy could share. Low priority, since the source
  map documents the current placement.

#### src/customization.odin

Verdict: clean; nothing notable.

#### src/semantic.odin

Verdict: the stores and interning are sound. The predeclared types are defined
in three tables.

- **Duplication / Structure:** the predeclared types are described in three
  places that must stay in step:
  - the positional `Type_Info` array (947-982), guarded only by an `assert` on its
    length;
  - `PREDECLARED_NAMES` (`src/types.odin:443-476`);
  - the universe name table (`src/universe.odin:16-44`), which also writes
    `Type_Info.name` (48).

  Use one table indexed by `Type_Id`, `{name, info, in_universe}`, and set
  `Type_Info.name` in `init_semantic_stores`. Then `write_type_name` needs no
  `PREDECLARED_NAMES`, and `build_universe` loops over the same table. About 35
  lines. Check the effect on `typeid` sort keys and emitter labels, which read
  `info.name` (`src/typeid.odin:367`, `src/emit_llvm_abi.odin:182`).
- **Simplify** (done): the `Contribution` enum ends with a comment that has no member
  (136: "The constructors and handle of a local region provider"). Remove it, or
  restore the member it described.
- **Simplify** (done): `proc_type_weakens_to` (1339-1350) calls
  `proc_param_crosses_thread` and `proc_param_escape`, which run `underlying_info`
  again for `from` and `to` on every parameter, though `a` and `b` are already
  known to be `.Proc` infos. Index `a.param_escapes` and `a.param_cross_thread`
  through a small `padded_at(slice, index, default)`, which is also what
  `equal_padded` encodes.
- **Data structure/algorithm (minor):**
  - `bucket_append` (1279-1285) copies the whole bucket on every insert, and
    `add_members` (1039) copies the whole member slice. Both are fine at today's
    sizes; `map[u64][dynamic]Type_Id` would be simpler.
  - The 80-line eager `make(map...)` list in `init_semantic_stores` (859-942) is
    unnecessary: Odin maps allocate lazily on first insert if the store's
    allocator is set. That would only need `context.allocator` scoping, so treat it
    as optional.

#### src/types.odin

Verdict: clean, well-named queries; the `Type_Walk` design is good.

- **Data structure/algorithm (minor)** (not done: only a record with padding allocates, and the result reaches six callers through `destructure_fields`, some of which may keep it): `named_fields` (178-190) allocates a new
  slice in the semantic arena on every call when a record has padding. It is
  called for every struct literal (`src/check_composite.odin:162`) and every
  destructure. Use the temp allocator, or cache it on `Type_Info`.

#### src/universe.odin

Verdict: fine; see the three-table finding under semantic.odin.

### Cross-file duplication

| Pattern | Sites | Proposal |
| --- | --- | --- |
| Expand a `.Proc_Group` into its members while scanning a member table | `src/check_calls.odin:1093`, `src/impl.odin:650`, `src/interface.odin:856,911`, `src/operators.odin:283,364,409` | One iterator, `for_each_flat_member(c, members, filter, visit)`, or a function returning the flattened slice in temp storage. About 25 lines. |
| `type_underlying(c, t) == TYPE_ALLOCATOR` (or `!=`) | 20 occurrences in 13 files, among them `src/check.odin:1149,2520`, `src/check_builtin.odin:268,655`, `src/container.odin:610`, `src/carrier_shape.odin:20` and the `provenance_*.odin` files | A `type_is_allocator(c, t)` predicate in `types.odin`, beside `type_is_box` and the rest. |
| Look up a field or member by name in a `[]Symbol_Id` | `member_named` (`src/impl.odin:386`), `struct_field` (`src/check_expr.odin:2880`), `enum_member` (`src/check_expr.odin:2893`), `subject_field_named` (`src/impl.odin:381`), and similar `parameter_slot_named` (`src/check_calls.odin:671`) | Keep `member_named` plus one `field_named(c, type, name)` in `types.odin` (done). |
| Filter candidates into a new semantic-arena slice | `method_candidates` (`src/check_expr.odin:1063`), `select_slicers` (1552), `select_by_place` (1666), `operator_candidates_for_receiver` (`src/operators.odin:297`), `delegation_neighbours` (831), `operator_overloads_mentioning` (844) | One `filter_symbols(k, all, pred, allocator)` with a temp default; most of these lists do not outlive the call. |
| For each file, set the location, then for each active item | `src/check.odin:167,193,277,308,331,360`, `src/operators.odin:620` | `for_each_package_item(k, pkg, visit)`. |
| Allocator operand check (`check_single_expr(.., TYPE_ALLOCATOR)` plus an underlying test) | `src/check_builtin.odin:263,651`, `src/check.odin:2516` | `check_allocator_argument` with a message parameter (done). |
| Statement walk that unwraps `defer` and descends into the selected `when` | `src/check_stmt.odin:30,74`; wider in `src/impl.odin:432` | `for_each_sequence_decl(stmts, visit)`. |
| Collect own equalities, then require them visible | `src/switch.odin:54-57`, `src/check_expr.odin:2323-2328` | Let `own_equalities_visible` collect them itself (not done; see switch.odin). |
| Predeclared type tables | `src/semantic.odin:947`, `src/types.odin:443`, `src/universe.odin:16` | One `Type_Id`-indexed table (see semantic.odin). |
| Diagnostic text built before anything fails | `src/check_calls.odin:425,474,1126`, `src/check_composite.odin:272`, `src/overload.odin:372,475-488` | Format at the report site, or into `context.temp_allocator` (done for check_calls.odin; the rest are open). |
| Parameter flattening (attribute checks per parameter name) | `src/check.odin:1287-1357` and `1866-1902` | One helper; this also fixes the variadic attribute bug. |
| `seen: Type_Walk; defer delete(seen); return x_walk(...)` wrappers | 16 sites in 8 files (`types.odin`, `zero.odin`, `operators.odin`, `check_expr.odin`, `hash.odin`, `format.odin`, `reflect.odin`, `test_procedures.odin`) | Acceptable as written. If any becomes hot, back `Type_Walk` with `context.temp_allocator` rather than the default heap. |

## Group 3: language features, generics, and bootstrap

Revision fd381d23. Read-only review of 40 files (~19.5k lines) under `src/`.
Depth: `generic.odin`, `generic_impl.odin`, `generic_alias.odin`, `interface.odin`,
`erased.odin`, `ast_clone.odin`, the four `iteration_*` files plus `iterate.odin`,
`container.odin`, `text.odin`, `simd.odin`, `atomics.odin`, `attributes.odin`,
`union.odin`, `hash.odin`, `format.odin`, `typeid.odin`, `layout.odin`, `abi.odin`
were read in full or nearly; the rest were read in the parts that matter
(declarations, helpers, the paths named below).

### Overview

The group is in good shape: the code is uniformly well commented, cites the spec,
keeps file-private helpers private, and most procedures are short and single-purpose.
I found few real correctness bugs, and the ones I found are small (a diagnostic that
prints a cache encoding, a nil dereference reachable only from a malformed
`core:simd`, a location-less diagnostic). The main themes are (1) **caches keyed by
formatted strings** in the hottest generic paths (`instance_key`, `dyn_key`,
`witness_key`, `generic_arg_equal`), and **interface satisfaction that is never
memoized**; (2) **near-copies** that have grown in parallel: the read-only and mutable
iteration-protocol walks, a dozen hand-built compiler-owned iterator/view records,
two `$`-name walkers, three stand-in probes, two policy caches (sort order / map key),
two "application text" printers; and (3) a few **leaky boundaries**: `ast_clone.odin`
is "clean cloning" but carries three semantic rewriting modes through mutable
`Compiler` fields, `Interface_Info` re-implements `Generic_Location`, and the
generic-success logic lives in `optional.odin`.

### Top recommendations

1. **Stop building `fmt` strings to look up generic instances.** `instance_key`
   (`src/generic.odin:881-901`) runs `fmt.sbprintf` per binding on *every* use of
   `Option(int)` etc. (the code itself says so at `src/generic.odin:2269-2271`), and
   `generic_arg_equal` (`src/generic.odin:955-963`) allocates two key strings per value
   comparison, inside `bind_pattern_name`'s loop. Replace with a hashed struct key
   (`{template, hash(args)}`) plus `generic_args_equal` for collision checks, or intern
   `[]Generic_Arg` vectors to an id once; compare `Const_Value`s structurally and keep
   `const_key_text` only for floats/aggregates. The same key builder backs `dyn_key` and
   `witness_key` (`src/erased.odin:401-406`, `683-688`), so one shared key type serves
   all three caches.
2. **Memoize interface satisfaction** (unverified that it is safe at every phase).
   `interface_check` (`src/interface.odin:548-587`) re-clones and re-checks every
   requirement on each application; it runs for every `where I(T)` of every overload
   probe, every `I(T)` expression, every `dyn` conversion (`src/erased.odin:57`), and
   `required_slot_candidates` (`src/interface.odin:1281-1330`) re-resolves the bound's
   arguments and re-flattens slots on every member-lookup miss inside a constrained
   body. A cache keyed on `(interface, args key, lookup package)` that is enabled once
   the lookup package's extensions are complete would remove most of this. It would
   also stop the unbounded `pending_private_reads` growth: each successful check appends
   one entry (`src/interface.odin:582-585`).
3. **Fix the diagnostic that prints a cache key.** (Done: bug 2, `generic_value_text`) `src/interface.odin:373` formats a
   non-representable interface argument with `const_key_text` (gives `t123`,
   `f64:3ff0000000000000`, or a string without quotes), against the rule in
   compiler-architecture.md "Compile-time execution and generics" that human-readable
   text is separate from `const_key_text`. Use `generic_value_text`, or better make
   `convert_generic_value` (`src/generic.odin:2459-2472`) package-visible and reuse it,
   which also brings the enum-specific wording.
4. **Merge the read-only and mutable protocol walks.** (Done: `read_protocol`,
   `protocol_next` and `bind_protocol_loop`.) `check_protocol_foreach`
   (`src/iteration_foreach.odin:180-232`), `iteration_adapter_member`
   (`src/iteration_adapters.odin:71-82`) and `mutable_protocol`
   (`src/iteration_mutable.odin:104-111`) each validate `Element`/`Iterator`/`iter`;
   `adapter_source_next` (`src/iteration_adapters.odin:144-150`) is
   `foreach_next_member` (`src/iteration_foreach.odin:236-259`) without the report;
   `check_mutable_protocol_foreach` (`src/iteration_mutable.odin:63-94`) repeats
   `check_protocol_foreach`'s tail. A `Read_Protocol` mirror of `Mutable_Protocol`, one
   `protocol_next(k, ..., report)` and one `bind_protocol_loop` tail save ~40 lines.
5. **One builder for compiler-owned records.** `src/iterate.odin:181-310`,
   `src/iteration_mutable.odin:41-49` (a copy of `array_iterator_type` with a mutable
   slice and the field renamed `items`), `src/iteration_adapters.odin:107-115` and
   `155-168`, `src/container.odin:291-301`, `src/reflect.odin:34-46` all hand-assemble
   `fields := make(...); fields[I] = new_field(...); new_type(Type_Info{name =
   intern(tprintf), backend_label = aprintf})`, with inconsistent label schemes (type
   names vs raw `%d` type ids). A `new_owned_record(c, label, over, fields: []Field_Spec,
   base: Type_Info)` saves ~50 lines and makes labels uniform.
6. **Give `clone_expr` an explicit rewrite parameter.** `src/ast_clone.odin` is
   documented as clean syntax cloning, but `clone_expr` consults three mutable
   `Compiler` fields (`capture_rewrite`, `alias_view`, `poly_substitution`,
   `src/compiler.odin:61-68`) at `src/ast_clone.odin:80-86`, `228-232`, `258-262`,
   `333-335`, `403-410`, `582-585`, each saved/restored by hand. A `Clone_Rewrite`
   struct passed down (nil for a plain clone) makes the modes visible and removes the
   save/restore boilerplate; `capture_call_method` already forgets to restore
   (`src/capture.odin:276-278` sets `nil` rather than the saved value).
7. **Share the stand-in probe and the template-of-callee helpers.** (Done:
   `check_against_stand_ins`, and `generic_template_of_callee` takes a set of kinds,
   `TYPE_GENERICS` for a record or alias; the poly-default probe checks a different
   thing and keeps its own.)
   `check_against_stand_ins` (`src/private_names.odin:897-907`) is the same probe as
   `src/generic.odin:277-286` and `320-327`; the "Record or Alias template" test is
   written four times (`src/check.odin:2126`, `src/private_names.odin:922`,
   `src/generic_alias.odin:110-111`, `src/optional.odin:421-424`), each doing two
   callee lookups. ~25 lines.
8. **Remove the quadratic extension-group growth.** (Done: `Compiler.extension_groups`.) `register_instance_extension_name`
   (`src/generic_impl.odin:548-561`) reallocates the group's member slice, copying all
   earlier instances, for every instance of a generic `extend` block: O(n²) arena memory
   (up to `MAX_INSTANTIATIONS` = 4096). Keep a `[dynamic]Symbol_Id` per group.

### Per-file findings

#### src/generic.odin
Verdict: central, careful, and correct as far as I could trace; costs are in key
building and repeated syntax walks.
- **Data structure/algorithm** `src/generic.odin:881-901`, `955-963`: string-keyed instance
  cache and string-comparing `generic_arg_equal` (see Top 1).
- **Data structure/algorithm** `src/generic.odin:1149`, `434-435`: `match_type_pattern` and
  `pattern_relation` call `type_syntax_has_poly` (a full `pattern_shape` subtree walk) at
  every recursion level, so matching is O(depth²) per pattern. Patterns are small; low
  priority. Either compute "has poly" once per node bottom-up, or have the recursive call
  return "bound nothing" and skip the precheck.
- **Simplify** `src/generic.odin:206-207` with `310`: `reject_uninstantiated_generic` calls
  `check_independent_poly_defaults`, which builds its own `signature_stand_ins`, then builds
  a second one. Pass one scope; saves an allocation and 2 lines.
- **Duplication** (done: Top 7; the poly-default probe keeps its own) `src/generic.odin:277-286`, `320-327`: two copies of the "probe against
  stand-ins, see whether `reached`" pattern; a third is `src/private_names.odin:897-907`.
  Move `check_against_stand_ins` here and use it in all three (~12 lines).
- **Duplication** `src/generic.odin:627-669` vs `545-595`: `type_pattern_parts` appends one
  part per `Parameter`/`Field` group while `flat_parameter_types`/`anon_record_pattern_fields`
  flatten per name, so specificity counts `proc(a, b: T)` once but `pattern_relation` treats
  it as two parameters. Harmless today (specificity only orders `impl` blocks), but
  `type_pattern_parts` could reuse the flattening helpers so both agree.
- **Duplication** `src/generic.odin:704-724` (`pattern_names`, `signature_poly_names`, via
  `pattern_shape`) vs `src/ast.odin:1420-1449` (`bind_poly_names`, `bind_signature`, via
  `type_syntax_any_name`): two `$`-name collectors with subtly different coverage
  (`bind_signature` includes defaults; `pattern_shape` stops at value nodes). Document the
  difference at one of them or derive one from the other.
- **Duplication** `src/generic.odin:749-755` and `src/interface.odin:68-74` build
  `[]Generic_Param_Decl` from `generic_params` groups identically; `738-743` and
  `src/interface.odin:62-67` share the `def_scope`-or-package-scope fallback. One helper
  each (~10 lines).
- **Duplication** (done in part: the interface text is built with one builder; the two printers stay separate) `src/generic.odin:979-997` (`generic_instance_name`) and
  `src/interface.odin:512-525` (`interface_application_text`) both print `Name(a, b)` from
  `generic_argument_text`; the interface one builds it by repeated `concat` into the
  semantic arena. One `application_text(c, prefix, name, args)` builder.
- **Simplify** (done) `src/generic.odin:1474`: `intern_identifier(k.c, entry.name.text)` where
  `name_identifier(k.c, entry.name)` is available (same at `src/interface.odin:1380`,
  `1413`, `src/erased.odin:714`).
- **Structure** `src/generic.odin:773-803` (`success_parameters`) is only meaningful with
  `success_names_generic` in `src/optional.odin:390-442`; see optional.odin.

#### src/generic_impl.odin
Verdict: clear two-phase install/settle logic; one quadratic structure and some thin wrappers.
- **Data structure/algorithm** (done: Top 8) `src/generic_impl.odin:548-561`: O(n²) member slice regrowth
  per instance (Top 8).
- **Data structure/algorithm** `src/generic_impl.odin:190-200`: every new instance clones and
  stable-sorts all blocks of its template by specificity. Insert blocks sorted in
  `register_generic_impl` (`61-97`) instead; saves the per-instance sort and ~5 lines.
- **Simplify** (done) `src/generic_impl.odin:52-57`, `537-541`: `pattern_specificity` and
  `impl_block_relation` are one-line wrappers used once/twice; inline (~8 lines).
- **Simplify** `src/generic_impl.odin:305-321`: for a bare `$T` argument the matcher has
  already bound it, yet the code still resolves `written` in a probe and compares; `continue`
  after `match_generic_arg` when `written` is a bare `^Type_Poly`.
- **Structure** `src/generic_impl.odin:584-616`: the drain loop for `pending_private_reads`
  and `pend_template_private_read` live here, while the reads are queued from
  `generic.odin`, `generic_alias.odin` and `interface.odin` and executed by
  `private_names.odin`. Consider moving the queue/drain into `private_names.odin`.

#### src/generic_alias.odin
Verdict: solid; the logic is dense but each procedure has one job.
- **Duplication** (done: Top 7) `src/generic_alias.odin:110-112`: Record-or-Alias callee test (Top 7).
- **Duplication** (done, as `new_param_scope`) `src/generic_alias.odin:192`: `new_scope(..., scope == nil ?
  build_universe(k.c) : scope, .Local)` also at `src/interface.odin:407` and inside
  `new_instance_scope` (`src/generic.odin:1064-1070`). One `new_param_scope(k, parent)`.
- **Simplify** `src/generic_alias.odin:556-562`: the nested loop over params × inner bindings
  could index `inner` by name once; trivial sizes, optional.

#### src/interface.odin
Verdict: correct and well documented, but the most expensive file in the group because
nothing is cached.
- **Bug** (done: bug 2) `src/interface.odin:373`: cache encoding in a user diagnostic (Top 3).
- **Data structure/algorithm** `src/interface.odin:450-467`, `548-587`, `1281-1330`: no
  memoization of satisfaction or of a bound's flattened slots (Top 2).
- **Data structure/algorithm** `src/interface.odin:582-585`: one `Pending_Private_Read` per
  successful check, including repeats of the same application; drained by
  `check_pending_impl_instances`, which only then discovers it is settled.
- **Structure** `src/interface.odin:24-37`, `419-425`, `584`: `Interface_Info` carries
  `scope/pkg/file/file_node` separately and `enter_interface` re-implements
  `enter_generic_location`; line 584 builds a `Generic_Location` by hand from those fields.
  Embed `using location: Generic_Location` as `Generic_Template` does.
- **Simplify** (done for the builder; `generic_instance_name` reads its arguments
  from bindings, so the two still write their own lists) `src/interface.odin:512-525`:
  `concat` chain → `strings.Builder` (and share with `generic_instance_name`, see
  generic.odin).
- **Simplify** (not done: each is one map lookup, and pre-interned ids on
  `Compiler` would have to survive checkpoints) `src/interface.odin:1115`,
  `1126`, `1177`: `intern_identifier(k.c, "call")`
  three times here and at `src/erased.odin:284`, `672`, `src/container.odin:701`,
  `src/check_calls.odin:196`; a predeclared identifier id on `Compiler` would do.

#### src/erased.odin
Verdict: good; key building and one argument binder duplicate other code.
- **Data structure/algorithm** `src/erased.odin:401-406`, `683-688`: string keys (Top 1).
- **Duplication** `src/erased.odin:921-971` (`bind_dyn_slot_arguments`) re-implements
  named/positional binding with its own L0372 check, as in `src/check_calls.odin:751` and
  `1225`. Reuse the general binder with the forwarding member's parameter symbols.
- **Duplication** `src/erased.odin:87-131` vs `src/variadic_lend.odin:49-74`: the two pack
  element passers share their skeleton (precheck, nil base, "accepts else
  `materialize_argument`", untyped materialize). A shared front half saves ~12 lines.
- **Simplify** `src/erased.odin:937`: `order` is allocated in the semantic arena even when no
  argument is named and it is dropped; build it in temp and clone only when kept.
- **Bug (unverified)** (done: checked) `src/erased.odin:676-677`: `callable_witness_slots` indexes
  `k.c.dyn_types[dyn_key(...)]` and dereferences `view.members[0]` without checking that the
  view exists; I could not find a path where it is missing, but a nil check costs nothing.
- **Simplify** (not done: L0463 names the view that failed, and building the
  read-only view first would name `dyn I` where `dyn mut I` was written)
  `src/erased.odin:153-171`: `dyn_type` for a `mutable` view first runs
  `interface_predicates_check`, then recursively builds the read-only view, which runs it
  again; build the read-only view first and return early on its failure.

#### src/ast_clone.odin
Verdict: mechanical and complete; the semantic rewriting modes don't belong in it.
- **Structure** `src/ast_clone.odin:80-86`, `228-232`, `258-262`, `333-335`, `403-410`,
  `582-585`: three rewriting modes read from `Compiler` fields (Top 6).
- **Simplify** (done; each clears the checker-filled `symbols`) `src/ast_clone.odin:106-213`: `clone_params`, `clone_fields`,
  `clone_generic_params`, `clone_bindings`, `clone_enum_fields` each rebuild a struct
  literal field-by-field; `out[i] = entry; out[i].type = clone_expr(...)` (the style
  `clone_variants` already uses) is shorter and cannot silently drop a newly added field
  (~20 lines). Where a field must be dropped (checker-filled), say so explicitly.

#### src/interface.odin / src/erased.odin / src/format.odin (`slot_candidates`)
- **Data structure/algorithm** `src/interface.odin:812-828` calls `ensure_format_member`,
  `ensure_iteration_members`, `ensure_lifecycle_members` for every slot candidate query;
  `ensure_format_member` (`src/format.odin:7-40`) compares `identifier_text(...) !=
  "format"` and may do two linear `standard_package` scans (`src/format.odin:24-25`).
  Compare an interned id and cache the Writer/Options types.

#### src/iterate.odin
Verdict: clear; the type builders are near-copies (Top 5).
- **Duplication** `src/iterate.odin:48-63`, `181-198`, `203-220`, `236-245`, `251-280`,
  `297-310`: six hand-built compiler records (Top 5).
- **Simplify** `src/iterate.odin:453-474`: `iteration_member` interns its `name` string on
  every call; protocol names (`iter`, `next`, `Element`, `Iterator`, `iter_mut`, ...) are
  fixed and could be interned once.

#### src/iteration_foreach.odin
Verdict: good binder; protocol validation duplicated (Top 4).
- **Duplication** (done: Top 4) `src/iteration_foreach.odin:180-232`, `236-259`: see Top 4.
- **Duplication** (done, as `reject_type_iterable`) `src/iteration_foreach.odin:25-33` and `src/expand.odin:278-288`: the same
  "`X` is a type, so it is not iterable; write `.values()`" report with different codes
  (L0456/L0454). One helper taking the code (~10 lines).

#### src/iteration_adapters.odin
Verdict: compact but dense; reuse would shorten it.
- **Duplication** (done: Top 4) `src/iteration_adapters.odin:71-82`, `144-150`: Top 4.
- **Duplication** `src/iteration_adapters.odin:107-115`, `155-168`: Top 5. Backend labels
  here use raw type ids (`"%s.%d.%d"`), elsewhere type names.

#### src/iteration_mutable.odin
Verdict: fine, but half of it is a copy.
- **Duplication** `src/iteration_mutable.odin:41-49`: `array_iterator_type` with a mutable
  slice and the data field renamed `items` (same `ITER_ARRAY_*` positions). Parameterize
  `array_iterator_type` (label, mutability, cache map) instead (~10 lines).
- **Duplication** (done: Top 4) `src/iteration_mutable.odin:63-94`: tail shared with
  `check_protocol_foreach` (Top 4).
- **Structure** (done) the file has no header comment, unlike its siblings.

#### src/iteration_yield.odin
Verdict: tidy.
- **Simplify** (done) `src/iteration_yield.odin:6`: `Derived_Key.member: string` hashes a string
  for one of three fixed names; an enum is cheaper and self-documenting.
- **Data structure/algorithm** (not done: the descriptions nest, so keeping a
  temporary one would need a deep copy on success) `src/iteration_yield.odin:52`:
  `yield_of` allocates the
  `fields` slice in the semantic arena before knowing it will succeed; called per
  `iterator_yield`. Use temp and clone on success.

#### src/container.odin
Verdict: the effect table is exemplary; the policy cache is a near-copy of hash.odin's.
- **Duplication** `src/container.odin:432-484` vs `src/hash.odin:163-278`:
  `Order_Policy_Kind {Unresolved, Builtin, Inherent, Unordered}` and `Key_Policy_Kind
  {Unresolved, Builtin, Inherent, Rejected}` have the same shape, and
  `require_sort_order_policy`/`require_map_key_policy` the same "cached ok → return;
  cached rejected → silent false; resolve; cache rejection only when committing; report"
  flow, but differ in one detail: the map-key path pre-stores `Rejected` as a cycle guard
  (`src/hash.odin:245-247`), the sort path does not. Share one `Policy_Kind` and one
  settle helper, and decide the cycle guard once.
- **Simplify** (done, with `strings.has_prefix`) `src/container.odin:209-212`: `container_member_is_try` re-derives the
  `try_` form from the name text; set a flag when `append_fallible_members` creates it, or
  at least use `strings.has_prefix`.
- **Duplication** `src/container.odin:291-301`: hand-built record (Top 5).

#### src/text.odin
Verdict: fine.
- **Simplify** (done) `src/text.odin:103-124`: `text_op_named` could be an `@(rodata)`
  `[Text_Op]string` table searched once, which also gives the inverse for diagnostics;
  marginal.

#### src/simd.odin
Verdict: fine; one robustness hole.
- **Bug** (done: bug 9) `src/simd.odin:431-433`: `simd_written_fold` dereferences `member.name` without
  checking that `enum_member_by_value` found a member; a non-constant or out-of-range
  `Fold` argument (only reachable from an edited `core:simd`) crashes the compiler instead
  of reporting, unlike the atomics path (L0666). Check for nil and report.
- **Simplify** `src/simd.odin:103-108`: after `materialize(k, index, TYPE_INT)` succeeds the
  index is `int`, so the `type_is_integer` check is dead (unverified: depends on
  `materialize` rejecting non-integer typed indices).

#### src/atomics.odin
Verdict: clean.
- **Simplify** (done) `src/atomics.odin:197-198`: reads `folded.integer` via `bi_to_i64` before
  checking `folded.kind == .Integer`; check the kind first.

#### src/attributes.odin
Verdict: the table-driven validator is good; the file has absorbed unrelated rules.
- **Simplify** (done) `src/attributes.odin:121-152`: `attr_pos_name`/`attr_scope_name` switches →
  `@(rodata)` enumerated arrays `[Attr_Pos]string`, which are exhaustive by construction
  (~20 lines).
- **Structure** `src/attributes.odin:518-606`: seven visibility predicates
  (`declaration_is_public`, `delegation_is_public`, `field_is_public`,
  `attributes_are_public`, `written_is_public`, `field_is_exported`, `decl_is_public`) are
  visibility policy, used by doc, private-names and the checker; and `610-755`
  (`check_escape_attribute`, `check_cross_thread_attribute`, `record_written_alignment`)
  are signature/record semantics. Moving them out leaves this file as "the attribute table
  and its validation", as its header says.

#### src/abi.odin
Verdict: clear and exhaustive.
- **Simplify** (not done: the switch is exhaustive on purpose, so every kind,
  `.Invalid` included, must be named) `src/abi.odin:142-145` with `250`:
  `.Invalid` returns early, so it is dead in the final arm.

#### src/foreign.odin
Verdict: fine; nothing notable.

#### src/layout.odin
Verdict: small and correct; nothing notable.

#### src/enums.odin
Verdict: fine.
- **Data structure/algorithm** (not done: a cache on `Type_Info` would need invalidating while members are added, for a minor gain) `src/enums.odin:97-112`: `enum_member_by_value` is a linear
  scan with big-int compares, called per `Enum.from_int` evaluation in CTFE loops
  (`src/eval.odin:1964`) and per static-expansion note. A per-type value→member map
  cached on `Type_Info` (built from `enum_members_by_value`) would make it O(1); minor.

#### src/union.odin
Verdict: clean.
- **Simplify** (not done; see the interning row under Cross-file duplication)
  `src/union.odin:326-328`: `option_payload` interns `"some"` on every call and
  it sits on iteration hot paths; cache the identifier (or the index, which is fixed by
  `base:runtime`'s `Option`).

#### src/optional.odin
Verdict: correct; one section belongs with generics.
- **Structure** `src/optional.odin:362-541` (`success_needs_no_value`,
  `success_names_generic`, `type_syntax_names_generic`, `local_alias_target`,
  `Generic_Lookup`) is "does this syntax depend on a generic binding" logic, paired with
  `success_parameters` in `src/generic.odin:773-803`. Move them together (generic.odin or
  generic_alias.odin), leaving optional.odin with the failure protocol.
- **Duplication** (done: Top 7) `src/optional.odin:421-424`: Record-or-Alias callee (Top 7).

#### src/variadic_lend.odin
Verdict: fine; mirrors erased.odin's pack path (see erased.odin).

#### src/slice.odin
Verdict: fine.
- **Structure** `src/slice.odin:46-49`: `pointer_to_element` is a pointer helper; it belongs
  with the other type queries in `types.odin`.

#### src/synth.odin
Verdict: good, small builders; nothing notable.

#### src/capture.odin
Verdict: fine apart from the clone side channel.
- **Bug (latent)** (done: bug 7) `src/capture.odin:276-278`: sets `k.c.capture_rewrite = nil` after the
  clone instead of restoring the previous value; correct only while capture lowering is
  never re-entered during a clone. `saved := ...; defer k.c.capture_rewrite = saved`, or
  Top 6.

#### src/test_procedures.odin
Verdict: fine.
- **Data structure/algorithm** `src/test_procedures.odin:92-96`: `omitted_with_test` makes a
  fresh walk per call and is called up to eight times per symbol across emission
  (`src/emit_llvm.odin:308`, `330`, `336`, `src/emit_llvm_names.odin:25`, `80`, `91`,
  `src/emit_llvm_runtime.odin:199`, `269`). Memoize per symbol (unverified cost).

#### src/private_names.odin
Verdict: large but coherent: a by-name syntax walk is the right model for an interface-file
check.
- **Duplication** (done: Top 7) `src/private_names.odin:897-907`: stand-in probe (Top 7).
- **Duplication** (done: Top 7) `src/private_names.odin:917-923`: `applies_generic_type` is the same
  expression as `src/check.odin:2126` (Top 7).
- **Data structure/algorithm** (done, with a map: the walk is seeded with
  bound types of any kind, which a `Type_Walk` would not record)
  `src/private_names.odin:791-841`: `private_type_reached` uses
  a `[dynamic]Type_Id` with `slice.contains` as its visited set (O(n²) on deep types);
  use `Type_Walk` (`src/types.odin:276`) as the other walks do.

#### src/parallel.odin
Verdict: well structured lowering.
- **Bug** (done: bug 3) `src/parallel.odin:194`: L0727 "`core:thread` declares no `Task_Scope`" is reported
  at `NO_SPAN` although `keyword` is passed in for exactly this; use `keyword`.

#### src/box.odin
Verdict: fine; nothing notable.

#### src/hash.odin
Verdict: fine; see container.odin for the policy duplication.

#### src/format.odin
Verdict: fine; two ways to find the same types.
- **Simplify** `src/format.odin:24-25` vs `233-234`: `ensure_format_member` finds `Writer`
  and `Options` with two `standard_package` scans each call, while `format_misdeclared` uses
  `c.runtime_types["Writer"]`/`["Options"]`. Use one source (unverified that
  `runtime_types` is populated at every `ensure_format_member` call).
- **Simplify** (done) `src/format.odin:112`, `127`: compare `sym.name` to an interned `format` id
  instead of `identifier_text(...) == "format"` per member.

#### src/expand.odin
Verdict: good.
- **Duplication** (done, as `reject_type_iterable`) `src/expand.odin:278-288`: see iteration_foreach.odin.

#### src/reflect.odin
Verdict: fine.
- **Duplication** (done) `src/reflect.odin:162-169` and `183-189`: the two enum-member descriptor
  loops differ only in the payload; one helper (~8 lines).
- **Duplication** `src/reflect.odin:34-46`: hand-built record (Top 5).

#### src/typeid.odin
Verdict: careful canonical keys.
- **Data structure/algorithm** `src/typeid.odin:312`, `318`: every sort key and intermediate
  builder is allocated in the semantic arena and kept for the whole compilation, though
  `freeze_typeids` needs them only while sorting. Run the freeze's walk with the temp
  allocator (keep `typeid_sort_key`'s public behaviour for its test callers).
- **Duplication** `src/typeid.odin:165-189`: re-implements `const_key_text`'s aggregate
  encoding (variant first, comma-separated) with a different element encoding; intentional
  (types by canonical key), but worth a cross-reference comment at `const_key_text`.
  (Done: the comment.)

#### src/materialize.odin
Verdict: fine.
- **Duplication** (done, with region.odin) `src/materialize.odin:117-149`: ad-hoc `map[Type_Id]bool` visited set
  where `Type_Walk` exists (also `src/region.odin:85`).

#### src/bootstrap.odin
Verdict: fine.
- **Data structure/algorithm** (not done: a miss before `base:runtime` is
  checked must not be cached, and a mismatch needs an edited runtime)
  `src/bootstrap.odin:169-180`: `memory_order_type` caches only
  success, so a missing or mismatched `Memory_Order` repeats the package scan and lookup on
  every atomic call. Cache the failure too, as `runtime_type_named` does.

#### src/stdlib.odin
Verdict: clear contribution table.
- **Data structure/algorithm** (done: `new_package` records each key in `package_by_key`) `src/stdlib.odin:33-40`: `standard_package` scans all packages
  by key string; it is called from per-call paths (`src/format.odin:24-25`,
  `src/bootstrap.odin:173`, `src/interface.odin:1088`, `src/parallel.odin:187`). Record the
  standard packages by key in a map (or fixed fields) when loaded.

#### src/intrinsic.odin
Verdict: fine.
- **Data structure/algorithm** `src/intrinsic.odin:243-250`: `description_of` is a linear
  scan called per contribution and per provider member; small lists, so optional.

#### src/region.odin
Verdict: fine.
- **Duplication** (done) `src/region.odin:85-109`: own `map[Type_Id]bool` walk (see materialize.odin).

### Cross-file duplication

| Pattern | Sites | Proposal |
| --- | --- | --- |
| String cache keys over `[]Generic_Arg` | `src/generic.odin:881-912` (`instance_key`, `write_generic_arg_key`), `src/erased.odin:392-406` (`dyn_key`), `src/erased.odin:683-688` (`witness_key`), `src/generic.odin:955-963` (`generic_arg_equal` via key text) | One hashed key type (Top 1). |
| Application text `Name(a, b)` | `src/generic.odin:979-997`, `src/interface.odin:512-525`, `src/erased.odin:409-415` | One builder. |
| Const → text | `const_key_text` (`src/generic.odin:915`), `generic_value_text` (`src/generic.odin:1004`), `const_display_text` (`src/const_ops.odin:896`), `static_element_text` (`src/expand.odin:169`) | Keep key vs display apart, but route all diagnostics through `generic_value_text`; `src/interface.odin:373` is the one that doesn't. |
| Probe against stand-ins | `src/generic.odin:277-286`, `320-327`, `src/private_names.odin:897-907` | One helper. |
| Record-or-Alias template of callee | `src/check.odin:2126`, `src/private_names.odin:922`, `src/generic_alias.odin:110-111`, `src/optional.odin:421-424` | `type_template_of_callee`. |
| `Generic_Param_Decl` from groups; scope fallback | `src/generic.odin:738-755`, `src/interface.odin:62-74` | Shared helpers; `Interface_Info` embeds `Generic_Location`. |
| `new_scope(parent or universe)` | `src/generic.odin:1064-1070`, `src/generic_alias.odin:192`, `src/interface.odin:407` | One helper (done). |
| `$`-name collectors | `src/generic.odin:673-724` vs `src/ast.odin:1420-1449` | Document the coverage difference or unify. |
| Read-only vs mutable protocol | `src/iteration_foreach.odin:180-259`, `src/iteration_adapters.odin:71-82`, `144-150`, `src/iteration_mutable.odin:63-111` | `Read_Protocol` + shared next/tail (Top 4). |
| Compiler-owned record builders | `src/iterate.odin:48-310`, `src/iteration_mutable.odin:41-49`, `src/iteration_adapters.odin:107-168`, `src/container.odin:291-301`, `src/reflect.odin:34-46` | `new_owned_record` (Top 5). |
| Policy caches | `src/container.odin:432-484`, `src/hash.odin:163-278` | One `Policy_Kind` + settle helper. |
| "type is not iterable" | `src/iteration_foreach.odin:25-33`, `src/expand.odin:278-288` | One reporter (done). |
| Variadic pack element passing | `src/erased.odin:33-44`, `87-131`, `src/variadic_lend.odin:20-74` | Shared front half. |
| Named/positional argument binding | `src/erased.odin:921-971`, `src/check_calls.odin:751`, `1225`, `src/overload.odin:491`, `src/generic.odin:1566-1573` | Reuse the general binder for dyn slots. |
| Visited sets over types | `Type_Walk` users (`src/hash.odin`, `src/format.odin`, `src/test_procedures.odin`) vs ad-hoc `map[Type_Id]bool` (`src/region.odin:85`, `src/materialize.odin:123`, `src/hooks.odin:562`, `src/carrier_shape.odin:154`, `src/provenance_regions.odin:1656`) and `[dynamic]` + `slice.contains` (`src/private_names.odin:798`) | Use `Type_Walk` where the semantics are "visited" (abi.odin's open/closed map is a genuine variant). Done for region.odin, materialize.odin and private_names.odin (a map there); hooks, carrier_shape and provenance_regions are open. |
| Lazy `if cap(x) == 0 { make(..., semantic) }` | `src/attributes.odin:638-640`, `src/union.odin:129-131` | Initialize these Checker arrays where the Checker is made. (Not done: Checkers are made in many places, tests included.) |
| Interning fixed names per call | `intern_identifier(k.c, "call")` ×7 (see interface.odin), `"some"` (`src/union.odin:327`), protocol names (`src/iterate.odin:454`), `"format"` text compares (`src/format.odin:112`, `127`) | Pre-interned identifier ids on `Compiler`. |

## Group 4: control-flow graphs and provenance

Revision fd381d23. Files: `src/cfg.odin`, `src/cfg_provenance.odin`, and the 21 `src/provenance_*.odin` files listed in the brief (not `provenance_normalization_test.odin`).

### Overview

The code is careful and thoroughly commented. The normalized-input/replay split (`provenance_input`, `_form`, `_transfer`, `_effect`, `_event`) is clean and well enforced by asserts. The weaknesses come from growth by accretion rather than from wrong design. `cfg_provenance.odin` is a 4.7k-line grab bag of at least six subsystems. `Prov_Event` is a ~45-field struct that every event pays for. Several "small" helpers are re-implemented 3 to 9 times across the provenance files. Construction does a lot of linear scanning over growing global arrays (`graph.reborrows`, `graph.place_loans`, `graph.roots`/`graph.loans`), which makes it quadratic in body size. The region-fact containers grow by copying the whole slice on every insert. I found no clear soundness bug in the dataflow merges, and the fact fixpoint terminates because facts only grow. The concrete defects are about memory discipline: some allocations go to the semantic arena or `context.temp_allocator` instead of the analysis arena. There is also one robustness gap in the replay loop.

### Top recommendations

1. **Index reborrows by slot instead of scanning `graph.reborrows`** (Data structure). At least 10 construction-time call sites walk the whole reborrow list per slot. Examples: `prov_slot_is_reborrow` provenance_reborrow.odin:364, `prov_slot_is_pending` :290, `prov_reborrow` :76, `prov_reborrow_loaded` :211, `prov_capture` cfg_provenance.odin:2130, `prov_spawn_reborrows` provenance_tasks.odin:156, `prov_link_retained` provenance_retention.odin:446, `prov_assign` cfg_provenance.odin:4330. Each store, capture and argument therefore costs O(R), so a body costs O(R·events). Add a single `prov_add_reborrow(graph, Prov_Reborrow)`, which all 16 `append(&graph.reborrows, …)` sites should use, and have it maintain per-slot flags on `Prov_Slot` (derived / derived-mutable / pending) plus `by_derived: map[int][dynamic]int`. `prov_settle_pending_reborrows` (which compacts the list) must rebuild the index. The same applies to `prov_reborrow`'s scan of all `graph.place_loans` per slot (provenance_reborrow.odin:25): key place loans by slot.
2. **Split `cfg_provenance.odin`** (Structure). It holds the state and event vocabulary (1–587), switch/case views (599–1008), composite/content slots (1238–1930), traversal publication (1930–2096), parameter binding and caller slots (2698–3116), erased, printed and read-only views (3118–3384), places and carrier hops (3386–3915), temporaries (3955–4085), and declarations and assignments (4087–4671). Suggested files: `provenance_state.odin` (Prov_State/Prov_Facts/Prov_Event and friends), `provenance_parameters.odin`, `provenance_views.odin`, `provenance_places.odin`, and `provenance_assign.odin` (declare/assign/publish_store). That leaves roughly 1.3k lines of slots, loans and emit in `cfg_provenance.odin`. Update the compiler-architecture.md source-map table in the same commit.
3. **Shrink `Prov_Event`** (Data structure). cfg_provenance.odin:379–503 has about 45 fields. Most of them are meaningful for one kind only: `rearranged`, `store`, `load_places`, `load_element`, `region_content`, `unwind_from`, `owner_span`, `ends`, `moved`, `replaces`, `place_path` and others. My estimate is ~500–600 bytes per event (`Region_Set` alone is ~60 bytes; unverified, measure with `size_of`). `Live`/`Def` are the bulk of events and use about six fields. `prov_splice_events` (provenance_event.odin:319) and every per-block `[dynamic]Prov_Event` copy this. Proposal: a common header (`kind`, `span`, `slot`, `loan`, `sources`, `into`, `path`, `access`, `precision`, `reads_only`) plus a `union` payload per kind group (Reset, Escape/Region_Escape, Publish, Load, Rearrange, Task). Pointer payloads also work.
4. **Stop allocating outside the analysis arena** (Bug: memory growth; done in earlier rounds. What remains in `context.temp_allocator` is per compiler, not per body: the cached `prov_view_reaches_provider` walk, `prov_type_shares_region`, and `report_thread_local_writes`, which has no graph.)
   - `prov_parameter_label` provenance_retention.odin:537–541 formats into `graph.k.c.semantic_allocator`, which is the long-lived arena, on every graph build. The result is only an event `verb`. Use `graph.alloc`, as every other `fmt.aprintf` here does (e.g. provenance_escape.odin:201, cfg_provenance.odin:1232).
   - Thirteen allocations use `context.temp_allocator`. During a batch compile that is one scratch arena for the whole compilation (session.odin:75), so per-body scratch accumulates instead of being reclaimed at the analysis-arena reset. The sites are provenance_reborrow.odin:235, provenance_retention.odin:15,158–159,199,234–235,240,432–433, provenance_results.odin:204,216, and provenance_regions.odin:1651,1744. Use `graph.alloc` where a graph is at hand. compiler-architecture.md "Normalized provenance input" asks for this ("Materialization allocates in the analysis arena").
5. **Make the region-content and written-alias tables grow in amortized O(1)** (Data structure; done, with `prov_add_region_content`, `prov_clone_region_contents` and `prov_clone_written_alias`. The dedup scan per insert is still linear.) `prov_define_region_content` (provenance_regions.odin:732–742), `prov_define_copied_content` (provenance_escape.odin:362–373) and `prov_add_written_alias` (provenance_aliases.odin:415–433) each do a linear dedup scan, then allocate `len+1` and copy the whole slice for every new entry. That is quadratic per storage, and every round replays it. Store `[dynamic]` values in `Prov_Facts.region_content`/`written_aliases`. The carry and seed already deep-copy. Then add one helper, `prov_region_content_add(graph, storage, entry, merge: bool)`, used by both region writers. The written-alias version is the same shape. Saves ~25 lines and the quadratic copies.
6. **Cache the uncached recursive type predicates** (Data structure; done, the queried type only. `perf.ps1` front-end times fell by a median of about 4%, within the run-to-run noise. Still open: the first query of each type, and every intermediate type in it, still walks the whole record, so the fields^8 worst case remains. A cached `false` cannot answer an intermediate type, which a deeper start cuts off sooner. Caching every intermediate answer needs the walk to report whether it reached `REGION_SHAPE_DEPTH`.) `prov_type_has_region` (provenance_regions.odin:1110) has 20 callers. Callers include `prov_input_call` per argument, `prov_region_of` per value, and `region_field_shape_into` per node, which makes that walk quadratic. `prov_holds_allocator` (:1075) and `prov_view_reaches_provider` (:1650, which also allocates a temp map per call) walk the type tree on every call. A DAG-shaped record walk is up to fields^8 at `REGION_SHAPE_DEPTH`. Their siblings `type_carries_borrow`, `prov_type_reaches_destination` and `prov_type_reaches_mutable` are already memoized in `Compiler` maps (carrier_shape.odin:110–149). Add `c.has_region`, `c.holds_allocator` and `c.view_reaches_provider` the same way, about 15 lines.
7. **Factor the four alias-reachability walks into one** (Duplication). These walks repeat the same frame: `prov_first_alias_visit` → `carrier_shape(prov_type_at(...))` → `prov_written_aliases_of(storage, bounded ++ carrier.steps)` → recurse.
   - `prov_store_reachable_regions` provenance_escape.odin:539–551
   - `prov_forget_storage_aliases` provenance_aliases.odin:546–569
   - `Walk.walk` in `prov_reached_regions` provenance_regions.odin:1395–1421
   - `prov_load_aliases_below` provenance_aliases.odin:187–205 (breadth-first variant)

   A `prov_walk_reachable(graph, start: []Written_Alias, writable, visit: proc(graph, storage, bounded, writable, user: rawptr))` would hold the visiting rules (depth bound, type-step cut, capability) in one place. That matters because they are subtle and documented once in compiler-architecture.md. Saves ~40 lines.
8. **Add a robustness assert to the replay loop** (Bug, latent; the assert is done. No iteration cap was added: the assert already stops a shrinking round.) In `build_provenance_replay`, `settled := current_weight == seeded` (provenance_effect.odin:98) treats any non-equal weight as "not settled". If a future change makes a fact shrink, for example a non-monotone `precision` update in `prov_fact_weight` (provenance_regions.odin:413), the loop never terminates, silently. Add `assert(current_weight >= seeded, "a replay round lost a carried fact")`, and consider an iteration cap with an internal error.

### Per-file findings

#### src/cfg.odin

Verdict: sound, readable topology builder. The lifecycle/provenance interleave is managed but heavy (55 mode checks), and the block record mixes in solver state.

- **Structure**: `Flow_Block` (cfg.odin:96–136) declares 14 per-block tables that only the borrow solver fills (`reach_entry` … `use_exit`, `reach_known`). Lifecycle graphs carry them too. Move them into the solver's state (`Prov_Solve`, borrow.odin) as per-block arrays. Then cfg.odin no longer knows the solver's layout, and lifecycle blocks shrink by ~14 slice headers (~220 bytes per block).
- **Structure**: `Flow_Graph` has `using prov: ^Prov_State` for provenance-only state, but lifecycle-only state sits inline (`reads`, `held`, `lent`, `last_uses`, `required`, cfg.odin:232–238, initialised for every mode at :284–287). Mirror the prov pattern with a `^Lifecycle_State` that stays nil in provenance modes. Provenance graph creation would then skip five allocations, and accidental cross-mode reads would crash rather than read empty data.
- **Data structure/algorithm** (done: `Block_Queue` became the shared `Worklist`, whose first-in-first-out mode now reuses its space once drained): `Block_Queue.pending` (cfg.odin:372–423) only grows. Every wake appends, and `head` advances without ever reclaiming. A fixpoint with W wakes holds O(W) entries (borrow.odin, lifecycle.odin and view_start.odin all use it). In `block_queue_pop`, when `queue.head == len(queue.pending)`, `clear` and reset `head = 0`. That is 2 lines and keeps the queue at O(blocks).
- **Data structure/algorithm** (done: a latest-first `Worklist` that wakes predecessors): `solve_reads` (cfg.odin:2169–2185) is a round-robin sweep over all blocks until nothing changes, so every pass recomputes unchanged blocks. The file already has `block_queue_last_first` for this. Wake `preds` on change, as borrow.odin:2271–2303 does. Neutral in size.
- **Duplication** (done: `read_after`): `report_unread_required` (cfg.odin:2095–2104) and `transfer_last_uses` (:2121–2127) share the "is slot read after (block, event)?" sequence `reads_at_exit` + `reads_before(..., event+1, ...)` + `reads_get || graph.lent[slot]`. Extract `read_after(graph, rows, block, event, scratch) -> bool`, saving ~6 lines.
- **Simplify** (done): in `walk_flow_expr` (cfg.odin:1650–1656), `expr_base(e)` and `prov_repr(graph, e)` are each computed twice, and `prov_repr` scans the conversion stack. Compute `repr` once, saving 2 lines.
- **Simplify** (done): in `walk_flow_foreach` (cfg.odin:1339–1344), `span_text(expr_span(iterable))` is recomputed per slot inside the loop. Hoist it. The loop also runs in lifecycle mode only because `elements` happens to be nil there; guard it with `graph.mode != .Lifecycle` for clarity.
- **Data structure/algorithm**: `walk_flow_if` (cfg.odin:1267–1272) creates an empty else block even when `s.otherwise == nil`. Likewise `walk_flow_for` creates `post` when `s.post == nil` (:1291). The borrow solver keeps several per-slot tables per block, so every empty block costs (comment at cfg_provenance.odin:1579–1580). Link `entry → merge` directly when there is no else (unverified gain; measure with `perf.ps1`).
- **Data structure/algorithm** (minor): `emit_unwind_branch` (cfg.odin:619–622) rescans all of `graph.in_scope` per statement to learn whether a `defer`/owner is registered, which is O(statements × open registrations). Counting registrations is awkward because `emit_cleanups` truncates temporarily. Leave this unless profiling shows it.

#### src/cfg_provenance.odin

Verdict: correct-looking but far too large. It is the hub of the quadratic scans and of most near-copies.

- **Structure**: split as in Top recommendation 2. In particular, the event vocabulary (`Prov_Kind`, `Prov_Event`, `Prov_Store_Target`, `Prov_*_Borrow`, `Prov_Call_Result`, `Prov_Region_Content`…, lines 260–586) is shared by borrow*.odin and every provenance file, and belongs in its own file.
- **Data structure/algorithm**: `Prov_Event` size; see Top recommendation 3 (cfg_provenance.odin:379–503).
- **Data structure/algorithm**: `prov_capture` (cfg_provenance.odin:2130–2136) copies every reborrow whose `derived == slot` by scanning all of `graph.reborrows`. `prov_spawn_reborrows` (provenance_tasks.odin:154–165) does the same. Both become O(k) with the index from Top recommendation 1.
- **Data structure/algorithm** (done: the graph caches a found root and loan in `view_parameter_loans`; roots and loans only grow, so a found pair stays the first, and a parameter whose own loan is not yet made is scanned again): `prov_view_parameter_loan` (cfg_provenance.odin:3080–3098) linearly scans `graph.roots` and then `graph.loans` on every call. It is reached from `prov_view_at`, so on every access, write or read through a place, and from `prov_view_element`. Record the parameter's loan root and own loan when `prov_bind_parameters` creates them (:2780–2801) in `param_roots: map[Symbol_Id]struct{root: Root_Id, own: Loan_Id}`. That saves ~12 lines and removes O(roots+loans) per access.
- **Structure / possible confusion**: `prov_bind_parameters` creates the parameter's `.Param` root (:2780) without registering it in `root_by_symbol`/`root_by_storage`. A later `prov_root_for_symbol(id)` therefore creates a second root for the same symbol and storage (`prov_storage_id` gives `.Param` kind for pointer-mode parameters, provenance_input.odin:145). This seems intentional (loan root vs binding root), but nothing says so, and `prov_view_parameter_loan` relies on finding the right one by scan order. Document it at :2780, or keep the loan root in a separate field (see the previous item).
- **Duplication** (not done: the sites differ in span, verb, `reads_only`, `publish_map_keys` or the path they access, so a helper saves about a line each): "find place, walk subscripts, access" appears 9 times. The sequence `prov_place_of` → `prov_walk_subscripts` → `prov_access(root, path, kind, span[, reads_only])` is at cfg_provenance.odin:733–735, 1704–1706, 2403–2404, 3716–3718, 3752–3753, 4396–4397 and provenance_arguments.odin:163–165, 182–184, 207–210. Add `prov_access_place(graph, e, kind, span, reads_only := false) -> (root, path, block, index, ok)`, saving ~20 lines.
- **Duplication**: `prov_reborrow_read_only` (cfg_provenance.odin:3554–3567) is `prov_reborrow_traversal` (provenance_reborrow.odin:347–360) with a different predicate (`loaded_mutable` vs `mutable_carrier`) and `mutable = false`. The "snapshot slot, def-copy, append reborrow" core also appears in `prov_view_parts_through_carrier` (:3265–3270), `prov_lend_split_receiver` (provenance_arguments.odin:461–470) and `prov_spawn_lends_loaded` (provenance_tasks.odin:136–144). One `prov_reborrow_into_temp(graph, slot, span, mutable) -> int` would serve all five. Saves ~25 lines.
- **Duplication** (not done: `graph.reborrows[mark:]` already names the reborrows since the mark, so a helper would only rename the slice): "weaken the reborrows taken since mark", that is `taken := len(graph.reborrows) … for &r in graph.reborrows[taken:] { r.<flag> = … }`, appears at cfg_provenance.odin:1588–1596, cfg.odin:1330–1334, provenance_arguments.odin:28–32 and borrow.odin:1210. Add a tiny `prov_reborrows_since(graph, mark) -> []Prov_Reborrow`. It also documents the idiom.
- **Duplication**: "the type a slot holds" has several slightly different fallbacks: `slot_carrier_type` (borrow_summaries.odin:353–362), the inline fallback in `prov_define_one_content` (cfg_provenance.odin:1907–1911), `prov_slot_is_mutable_carrier` (provenance_reborrow.odin:378–386) and `link` in `prov_link_retained` (provenance_retention.odin:466–474). They differ in whether a non-bare named slot falls back to the symbol's type. Pick one documented rule, or name the variants, because each divergence is a latent precision difference.
- **Duplication**: the lazily created `root.slots` content pattern (create via `prov_temp_content` if nil, store on the root, set `has_content_load`) appears in `prov_slice_literal` (:3888–3897) and `prov_temp_root_content` (:4017–4025). Extract `prov_root_content_slots(graph, root, type)`.
- **Simplify** (done: `prov_add_slot`. Not done: `prov_hold_slot` still copies the content fields one by one, because a whole copy would also take the source's kind, symbol, name and borrow flags, which a held temporary must not have, so it would reset more fields than it copies): slot creation via `append(&graph.prov_slots, entry); slot := len(graph.prov_slots) - 1` repeats at :1212–1213, 1480–1481, 1522–1523, 2244–2245 and 2923–2924. Add `prov_add_slot(graph, entry) -> int`. `prov_hold_slot` (:2166–2177) copies five fields one by one. Copy the whole source entry and reset the identity fields instead, so that a new `Prov_Slot` field cannot be forgotten.
- **Simplify** (done; the empty-set check stays, so no empty `provider_parents` entry is made): `prov_declare_provider` (:4228–4235) nests `if initialized { if !region_is_empty(...) {…} }`. `prov_merge_parent` with an empty set is harmless, so collapse it to one line.
- **Structure**: `prov_assign` (:4286–4411) is 125 lines with three interleaved destination kinds: local ident, rooted place, through carrier. Split it into `prov_assign_local` and `prov_assign_place`, keeping the shared preamble. In the same function, `clones` (:4299) is loop-invariant; hoist it. (Hoisting done; the split is still open.)
- **Data structure/algorithm**: `prov_place_hops` allocates afresh on every call, and the same place's hops are recomputed by `prov_read_through_carrier` and then again by callers (e.g. `prov_view_element_store` :3111, `prov_constant_view_element` :3070, `prov_view_parts_through_carrier` :3254). Cache the hops on `Prov_Value` (input is frozen per value), or pass them through.
- **Bug (unverified)** (not done: recorded in open-questions.md as bug 15): in `prov_materialize_view_publish` (:2037–2053), the settled publication emits its `Def`s directly into the construction graph `output`, whose `materialized` is nil. `prov_note_view` therefore appends fresh entries to `output.view_defs` (and `prov_note_offset` records `reach.defined`) after the walk. That contradicts the comment at :1042–1044 that materialized events record no definitions. The construction-time entries become orphans that widen `solve_view_defs`'s bit rows (view_start.odin:332). This looks harmless to correctness. Either set a flag so `prov_note_view`/`prov_note_offset` skip during materialization, or fix the comment.

#### src/provenance_reborrow.odin

Verdict: the logic is clear, but it is the centre of the O(R) scans.

- **Data structure/algorithm**: `prov_slot_is_reborrow` (:364–371), `prov_slot_is_pending` (:290–297), the "weaken earlier reborrows of this slot" loop (:76–80), `prov_reborrow_loaded`'s capability lookup (:211–215) and the per-slot `graph.place_loans` scan (:25–29) are all linear over global arrays. They are called per slot per store or argument. See Top recommendation 1.
- **Bug (minor)** (not done: whether the latest store's capability or any mutable one should win is a design question that needs a reproducing program first): `prov_reborrow_loaded` (:211–215) takes the *last* matching reborrow's capability (`mutable = reborrow.mutable && …` overwritten in the loop). If several reborrows derive from `event.slot`, the result depends on list order. Use `||` (any mutable), or document why the last one wins.
- **Simplify** (done in part: `graph.alloc`, bug 5; the round-robin waits for the index of Top recommendation 1): `prov_settle_pending_reborrows` (:235) allocates from `context.temp_allocator`; use `graph.alloc` (Top recommendation 4). The fixpoint is a round-robin over all reborrows. With the derived-index from Top recommendation 1, a worklist of newly marked slots would be O(R).
- **Duplication**: `prov_reborrow_traversal` (:347–360) and `prov_reborrow_read_only` (cfg_provenance.odin:3554) are near-copies; see cfg_provenance.

#### src/provenance_escape.odin

Verdict: coherent ("what a store or call lets escape"), with one copy of the quadratic-append pattern and one of the four alias walks.

- **Data structure/algorithm / Duplication** (done: Top recommendation 5): `prov_define_copied_content` (:359–374) is the same "dedup scan, then copy into `len+1`" as `prov_define_region_content` (provenance_regions.odin:705–743). Merge them (Top recommendation 5).
- **Duplication**: `prov_store_reachable_regions` (:539–551) is one of the four alias-reachability walks (Top recommendation 7).
- **Simplify** (not done: the one-element slice would make the whole-value case copy `at` through `prov_concat_path`, which the current branch avoids): `prov_store_region_through` (:476–484) has a `landed != nil` branch that only differs by iterating rows. Write `for content in landed or {whole}` with a one-element slice built from `at`, saving 4 lines.
- **Structure**: `prov_call_written_regions` (:605–680) and `prov_call_moved_owner` (:744–768) are call effects. They sit better in `provenance_retention.odin`, which already owns "what a call may leave behind" and calls both from `prov_call_retention`. `prov_type_at`/`prov_type_along` (:113–163) are pure type queries used by six files; they belong in carrier_shape.odin next to `carrier_shape`.
- **Simplify** (done in part: the graph keeps each owner's name once formatted, in `owner_names`; the name is still found before anything escapes): `prov_owner_name` (:710–719) formats a fresh string per call. `prov_store_region`, `prov_store_spread_region` and `prov_store_map_key_region` call it on every replay round even when nothing escapes. Compute it lazily at the `Region_Escape` emit.

#### src/provenance_call_walk.odin

Verdict: good. `prov_call` reads as a clear script of a call's phases.

- **Simplify** (done: `prov_task_effects_scope`, a `deferred_out` helper that restores the outer value): the `graph.task_effects = spawned; …; graph.task_effects = false` bracketing repeats at :267–269, :310–312 and :374–377. It also resets to `false` rather than restoring the prior value. That is correct today only because nothing nests inside those spans. Use `outer := graph.task_effects; graph.task_effects = spawned; defer graph.task_effects = outer`, or a small helper.
- **Structure**: `prov_has_direct_body` (:183–205) is a compiler-wide predicate on symbols (used by results, regions and escape). It belongs with `result_summary`/summaries, not in the call walk.

#### src/provenance_regions.odin

Verdict: the heaviest query logic, well commented. Its main issues are uncached type walks, quadratic content growth, and two copies of the carry/seed clone.

- **Data structure/algorithm** (done in part: Top recommendation 6): `prov_type_has_region` (:1110), `prov_holds_allocator` (:1075) and `prov_view_reaches_provider` (:1650) are uncached; see Top recommendation 6.
- **Data structure/algorithm** (done: Top recommendation 5): in `prov_define_region_content` (:732–742), the full slice copy per new entry is quadratic; see Top recommendation 5.
- **Duplication** (done: `prov_clone_region_contents` and `prov_clone_written_alias`): the deep clone of `region_content` is written twice, in `prov_seed_regions` (:332–338) and `prov_carry_facts` (:380–386). The `Written_Alias` clone at :375 duplicates the field-by-field copy in `prov_add_written_alias` (provenance_aliases.odin:426–432). Add `clone_region_contents(content, allocator)` and `clone_written_alias(alias, allocator)`, saving ~12 lines.
- **Duplication**: one of the alias walks is `Walk.walk` inside `prov_reached_regions` (:1395–1421); see Top recommendation 7.
- **Simplify**: the `region_aliases` fan-out "for alias in aliases { recurse(alias.root, alias.path ++ path) } if prov_aliases_settle(aliases) { return }" appears in `prov_merge_region_of` (:265–271), `prov_region_for_symbol` (:440–448), `prov_region_content_at` (:513–518), `prov_define_region_content` (:722–727) and `prov_written_parameter_content` (:484–488). It also appears in provenance_aliases.odin:310–316, 553–558 and provenance_escape.odin:169–175. An iterator `prov_region_alias_targets(graph, id, path) -> ([]Prov_Region_Alias, settled: bool)` would make the "settled, so skip the local snapshot" rule explicit in one place.
- **Data structure/algorithm**: region queries (`prov_result_region_at` with `.Owners` :37–56, `prov_copied_type_region` :1941–1985) recurse per field and allocate a new path at every step with `prov_concat_path`/`prov_extend`. The same (value, path) is queried repeatedly in one round, for example by escape checks and resets re-reading `prov_result_region_fields`. A per-round memo is unsafe while facts grow within a round. Consider a memo valid only during `prov_materialize_events`, where facts are settled (unverified gain; profile with `bench/provenance_profile`).
- **Simplify** (done in part: `prov_holds_allocator` and `prov_type_has_region` share `record_holds_walk`; `prov_carries_allocator` keeps its own): `prov_carries_allocator`, `prov_holds_allocator` and `prov_type_has_region` are three near-identical recursive walks over struct fields, union variants and array elements with a depth bound (:1066–1138). One `type_any_part(c, type, leaf, depth)` walker with a leaf predicate would serve all three, plus the cache from Top recommendation 6. Saves ~35 lines.
- **Structure**: `prov_reset` (:2070–2105), `prov_hold_owner` and `prov_lend_copied_place` (:2110–2131) are walk-side event recorders, not region queries. Move `prov_reset` next to `prov_materialize_reset` (provenance_event.odin), and the other two to the call/argument files. The provider-token machinery (:756–1015, ~260 lines: `Provider_Path`, tokens, moved providers) is a coherent sub-unit that could be `provenance_providers.odin`.

#### src/provenance_thread_summaries.odin

Verdict: small and focused.

- **Duplication**: `prov_region_closure` (:89–105) and `prov_caller_region` (:112–138) are the same bit-walk over local provider tokens following `provider_parents`. They differ in whether `locals` are kept and how a missing parent is treated (keep vs `default = true`). Use one walker with a `keep_locals` flag, saving ~15 lines. `next_region_param` (carrier_shape.odin:593) already gives the iterator idiom; add a `next_region_local` and use it here.
- **Simplify**: `prov_drop_region` and `prov_symbol_drop_region` (:161–174) are one-liners that differ only in argument type. Fine as they are, but a proc group `prov_drop_region :: proc{…}` would read better at call sites.

#### src/provenance_overwrites.odin

Verdict: clean, self-contained, well-argued meet logic. Nothing significant.

- **Simplify** (no change needed, as the finding says): `prov_param_index` (:300–302) is `slice.linear_search` over `param_symbols`, called from `prov_note_restored` on every `prov_merge_region_of` with params set. That is small in practice. If parameters ever grow, keep a `map[Symbol_Id]int`.
- **Simplify** (no change needed, as the finding says): `prov_link_overwrites` (:154–165) builds the meet with `slice.contains` per element, O(n²). Fine at the realistic sizes; note it only if overwrite sets grow.

#### src/provenance_arguments.odin

Verdict: a well-structured `switch` over `Prov_Argument_Kind`. It contains several of the repeated idioms.

- **Duplication**: three of the nine "place_of + walk_subscripts + access" sites are here (:163–165, :182–184, :207–210); see cfg_provenance.
- **Duplication** (not done: the two branches differ in path, loader and how they mark the result moved; hoisting only `element` saves one line): in `prov_inout_receiver` (:24–52), the `removes` branch is written twice, once for a rooted place and once through carriers. Each computes `element := underlying_info(...).element` and `prov_element_path(...)`. Hoist `element` and the path computation, saving ~4 lines.
- **Duplication**: `prov_lend_split_receiver` (:461–470) is another "snapshot + reborrow" copy; see cfg_provenance.
- **Simplify**: the `.Pack` case (:117–131) repeats the end-of-switch tail (`prov_reborrow`, `prov_lend_carrier`/`prov_reborrow_traversal`, `borrowed^ = join`) per operand. Factor the tail at :254–268 into `prov_lend_argument(graph, actual, type, borrowed, span, is_receiver)` and call it from both places.

#### src/provenance_builtins.odin

Verdict: fine, a straightforward dispatch on builtins.

- **Simplify**: "walk every non-nil bound argument" is open-coded at :45–49, :105–107 and :141–145, and appears again in cfg.odin:1977–1979 and provenance_call_walk.odin:337–339. A `walk_flow_all(graph, exprs) -> []int` (joining) would save ~10 lines.

#### src/provenance_containers.odin

Verdict: fine.

- **Duplication** (done: one `first` argument index per op serves both): the op → stored-argument table is encoded twice in `prov_container_content`: `stored_values` (:41–48) and `parts` (:75–83). Both say Append → bound[1:], Insert → bound[2:], and map inserts → bound[1:]. Derive both from one small table `{first_index, key_step}` per op, saving ~8 lines and preventing drift.

#### src/provenance_retention.odin

Verdict: correct in outline. It holds one real allocation bug and two copies of the candidate filter.

- **Bug** (done: bug 5): `prov_parameter_label` (:537–541) allocates in `semantic_allocator`; see Top recommendation 4.
- **Bug (memory)** (done: bug 5 for the graph-local sites; `report_thread_local_writes` is in open-questions.md): there are nine `context.temp_allocator` allocations (:15, :158–159, :199, :234–235, :240, :432–433). `prov_mutable_reach` allocates a fresh temp map per truncated path per call (:240). Use `graph.alloc` (Top recommendation 4). `report_thread_local_writes` has no graph; give it `c.analysis_allocator`.
- **Simplify** (done: the bool is now `settles_later`. `linked` keeps `slice.contains`, since the worklist holds a few slots): in `prov_link_retained` (:433 vs :459), `pending` is a `[dynamic]int` worklist and is then shadowed inside the loop by `pending := !mutable_source && …` (a bool). It works because the shadow is declared after the last use of the outer name in that iteration, but it is a trap and fails `-vet-shadowing`. Rename the bool `pending_link`.
- **Data structure/algorithm** (done in part: `linked` is a set; the reborrow scan waits for Top recommendation 1): `prov_link_retained` (:446–450) scans all reborrows per temporary source, which the index fixes (Top recommendation 1). `linked` uses `slice.contains` (:437), O(n²) on the worklist; use a `map[int]bool` or a bitset over slots.
- **Duplication**: the candidate filter in `prov_link_copied_carriers` (:76–84) and the `link` closure in `prov_link_retained` (:465–480) skip the same things: an immutable parameter's own slot, temporaries, non-carriers and region providers. Extract `prov_slot_may_take_link(graph, slot) -> (type, ok)`.

#### src/provenance_results.odin

Verdict: fine.

- **Duplication** (done: `next_load_depth` in carrier_shape.odin): `for depth in 1 ..= 8 { if loads & (1 << (depth-1)) == 0 { continue }; for route in result_load_routes(...) }` appears here (:296–305), in provenance_aliases.odin:173–180 and in proc_contracts.odin:239. The magic `8` is the bit width of `param_loads: u8`, not `CARRIER_DEPTH`. Add an iterator `next_load_depth(&bits)` (like `next_region_param`), or at least a named constant.
- **Duplication** (done: `prov_call_result_regions`): `prov_store_call_results` (:17–21) and the replay of `Prov_Effect_Call.Result` (provenance_effect.odin:219–220) compute the same `region`/`region_content` pair. Extract `prov_call_result_regions(graph, id, type) -> Prov_Call_Result`.
- **Simplify** (not done: they apply different spec rules, each documented on its own procedure, and differ in their parameters, so one procedure with a flag would merge two comments into one condition): `prov_callback_result` and `prov_callback_returned` (:203–219) differ only in which `call_callback_*` they call. Fold them into one proc taking a `returns: bool`, saving ~6 lines.

#### src/provenance_tasks.odin

Verdict: fine.

- **Data structure/algorithm**: `prov_spawn_reborrows` (:154–165) is a nested loop over held slots × all reborrows; the index fixes it (Top recommendation 1).
- **Simplify** (done: `new_prov_state` makes them eagerly): the lazy map/array initialisation (`if graph.task_slots == nil { make… }` :92–96, :105–107, :113–115, `parallel_scopes` :184–186, `task_sites` provenance_tasks.odin:48–50) is inconsistent with `new_prov_state`, which eagerly makes ~45 containers. `make(map, allocator)` does not allocate until the first insert, so eagerly making these too removes ~12 lines of nil checks. Alternatively make everything lazy; either is fine, but pick one.
- **Data structure/algorithm** (no change needed, as the finding says) (minor): `prov_window_bit` (:178–189) is a linear search over `parallel_scopes`. It is fine because there are few blocks, but it is called per join and per pool event.

#### src/provenance_offsets.odin

Verdict: a careful, bounded algorithm (Tarjan-style SCC walk with epoch invalidation). The merge step is cubic in the worst case.

- **Data structure/algorithm**: `prov_merge_past_limits` (:450–462) repeats a full O(n²) pair search (`prov_offsets_past_limit` :467–500, plus an O(n²) per-storage count) after each single merge. With n up to 128 (two 64-offset unions), that is O(n³) per union. Sort by (storage, path) once. The pair with the longest common prefix is then adjacent, so each merge round is O(n). Also, counting per storage once into a small map replaces the inner `count` loop.
- **Data structure/algorithm** (no change needed: the storage comparison runs before `prov_offset_covered_in`, so offsets of one storage cost only O(n²) comparisons): `prov_offset_precision` (:407–419) is O(n³): it calls `prov_offset_covered_in` per pair. Short-circuit when all offsets share one storage, which is the common case.
- **Simplify**: in `prov_reaching_offsets` (:186–225), lazily allocating `extra` and then calling `prov_union_offsets` could append directly into `reaching` before `prov_merge_past_limits`, giving one merge instead of two.

#### src/provenance_aliases.odin

Verdict: subtle and well commented. It holds two of the four alias walks and the third copy of the append-by-copy pattern.

- **Data structure/algorithm** (done in part: Top recommendation 5; `prov_written_targets` still dedups by scan): `prov_add_written_alias` (:415–433) copies the slice per insert; see Top recommendation 5. `prov_written_targets` (:53–62) dedups by an O(n²) scan.
- **Duplication**: `prov_forget_storage_aliases` (:546–569) and `prov_load_aliases_below` (:187–205) are reachability walks; see Top recommendation 7. The `region_aliases` fan-out in `prov_written_aliases_of` (:310–316) is another copy of the pattern noted under provenance_regions.
- **Duplication** (done: `next_load_depth`): the `1 ..= 8` load-depth loop (:173); see provenance_results.
- **Simplify** (done): in `prov_add_written_alias` (:408–414), the `paths := [2]^[]Proj_Step{…}` loop over two pointers is clever but obscures a two-line truncation. Write a `truncate_alias_path(path)` helper and call it twice.

#### src/provenance_input.odin

Verdict: a clean boundary module; the identity rules are clear.

- **Data structure/algorithm** (done: keyed by `Prov_Map_Key`, with no allocation): `prov_map_entry_step` (:397–432) formats a string key with `fmt.aprintf` on *every* call, including hits, just to look it up in `map_key_entries: map[string]int`. It is called per map index and per literal key. Key the map by a small struct (`kind`, `i64`, `string`) and allocate only on insert.
- **Simplify** (no change needed, as the finding says): `prov_repr` (:194–202) scans `converting` from the top. Fine; the stack is shallow.

#### src/provenance_form.odin

Verdict: good. Nothing notable.

#### src/provenance_transfer.odin

Verdict: good. It is the single place where syntax becomes transfers, as documented.

- **Simplify** (done: `builtin_moves_out_first`, used by both): `prov_call_transfer` (:175–185) special-cases `.Exchange` and `.Unsafe_Take` with identical bodies. Merge them into one `if builtin.builtin == .Exchange && len(v.bound) == 2 || builtin.builtin == .Unsafe_Take && len(v.bound) == 1`. The same two builtins are also matched together in `prov_moved_providers` (provenance_regions.odin:900–903). A shared predicate `builtin_moves_out_first(sym, bound)` keeps the two in sync.

#### src/provenance_transfer_facts.odin

Verdict: fine. Small and focused.

- **Simplify**: `prov_note_borrowed_owner` (:69–79) uses the effect-recording pattern with an extra dedup map, a 17th variant of the begin/end idiom (see Cross-file duplication).

#### src/provenance_call.odin

Verdict: good. Classifying arguments into an enum keeps `prov_call_argument` readable.

- **Simplify** (done: `borrows_caller_value`): the condition at :149, `index == 0 && input.has_receiver ? input.receiver == .Borrow : param_mode_is_pointer(part.mode) || (…)`, relies on `?:` having the lowest precedence. Parenthesise both arms, or name the boolean `borrows_caller_value`.

#### src/provenance_effect.odin

Verdict: compact and clear replay driver.

- **Bug (latent)** (done: bug 13): the weight-equality termination needs a guard; see Top recommendation 8 (:98).
- **Duplication**: the replay of `.Result` duplicates `prov_store_call_results`'s region part (:219–220); see provenance_results.
- **Simplify**: the recording idiom (`recorded := prov_effect_active(graph) && …; if recorded { prov_effect_begin(graph, Op{…}) }; defer prov_effect_end(graph, recorded)`) is repeated 16 times. Odin's `@(deferred_out=prov_effect_end)` on a `prov_effect_scope :: proc(graph, recorded: bool, op) -> (^Flow_Graph, bool)` turns each into one line. Make `prov_effect_path` return nil when inactive so the eager op construction stays cheap. Saves ~32 lines.

#### src/provenance_event.odin

Verdict: the record/materialize/splice machinery is sound. The file also hosts reset and allocator-use logic that is not about event operations.

- **Structure**: `prov_materialize_reset` and its helpers `prov_reset_blocker`, `prov_returning_region`, `prov_reset_temporary`, `prov_reset_promise` and `prov_parameter_symbol` (:359–529) form the reset check. Together with `prov_reset` (provenance_regions.odin:2070) they would make a `provenance_resets.odin`. `prov_argument_regions`, `prov_argument_region` and `prov_call_allocator_use` (:556–663) are allocator-use effects and belong in provenance_thread_summaries.odin, next to `prov_note_allocator_use`. That leaves this file with what its header says, about 330 lines.
- **Duplication**: the `Region_Set | Value_Id` arms of `prov_materialize_reset`'s switch (:362–366) duplicate `prov_use_region` (:61–68). Make `Prov_Reset_Region` a superset that reuses `Prov_Use_Region`, and call `prov_use_region` for the shared arms.
- **Robustness (unverified)**: `prov_event` (:169–183) materializes a recorded event with `effect_depth` unchanged. A nested `prov_event` or fact operation reached during that materialization is therefore recorded as a site of its own, with a lower sequence number, inside the outer site's event range. Today the only nested fact operation (`Prov_Effect_Borrow_Owner`) emits no events, so `prov_splice_events`' overlap assert (:324) does not fire. A future nested event would cause an assertion failure or a double materialization. Bump `graph.effect_depth` (or a dedicated `event_depth`) around :177 so nested work is inlined, not recorded.

### Cross-file duplication

| Pattern | Sites | Proposal | Est. saving |
| --- | --- | --- | --- |
| Linear scan of `graph.reborrows` by `derived`/`source` | provenance_reborrow.odin:76, 211, 238, 291, 365; cfg_provenance.odin:2130, 4330; provenance_tasks.odin:156; provenance_retention.odin:446; outside the group borrow.odin:1350–1369, borrow_report.odin:333–341, 615, borrow_loaded_below.odin:45, borrow_summaries.odin:136 | `prov_add_reborrow` + per-slot index (Top recommendation 1). The solver-side scans in borrow*.odin can share it. | asymptotic |
| place_of → walk_subscripts → access | cfg_provenance.odin:733, 1704, 2403, 3716, 3752, 4396; provenance_arguments.odin:163, 182, 207 | `prov_access_place` | ~20 lines |
| Snapshot slot + def-copy + append reborrow | provenance_reborrow.odin:347–360; cfg_provenance.odin:3554–3567, 3265–3270; provenance_arguments.odin:461–470; provenance_tasks.odin:136–144 | `prov_reborrow_into_temp` | ~25 lines |
| Weaken/flag reborrows since a mark (not done; see cfg_provenance) | cfg_provenance.odin:1588–1596; cfg.odin:1330–1334; provenance_arguments.odin:28–32; borrow.odin:1210 | `prov_reborrows_since` | small; clarity |
| Effect-recording begin/end | 16 sites: cfg_provenance.odin:922, 4159; provenance_aliases.odin:380, 443; provenance_escape.odin:235, 501, 514, 527, 608; provenance_regions.odin:291, 305, 586, 963, 1498; provenance_results.odin:8; provenance_transfer_facts.odin:72 | `@(deferred_out)` scope helper | ~32 lines |
| Alias-reachability walk with `prov_first_alias_visit` | provenance_escape.odin:539; provenance_aliases.odin:187, 546; provenance_regions.odin:1395 | one `prov_walk_reachable` | ~40 lines |
| `region_aliases` fan-out + `prov_aliases_settle` | provenance_regions.odin:265, 440, 484, 513, 722; provenance_aliases.odin:310, 553; provenance_escape.odin:169 | `prov_region_alias_targets` iterator | ~15 lines; one rule |
| Dedup-then-grow-by-copy of fact slices | provenance_regions.odin:732–742; provenance_escape.odin:362–373; provenance_aliases.odin:415–433 | `[dynamic]` facts + one add helper (Top recommendation 5) | ~25 lines; quadratic copies |
| Deep clone of `Prov_Region_Content` / `Written_Alias` lists | provenance_regions.odin:332–338, 372–386; provenance_aliases.odin:426–432 | `clone_region_contents`, `clone_written_alias` | ~12 lines |
| Recursive "any part of type" walks with depth bound | provenance_regions.odin:1066 (`prov_carries_allocator`), 1075 (`prov_holds_allocator`), 1110 (`prov_type_has_region`); siblings in carrier_shape.odin (`type_reaches_destination`) | one walker + memo maps in `Compiler` (Top recommendation 6) | ~35 lines |
| Local-provider bit walk via `provider_parents` | provenance_thread_summaries.odin:89, 112 | one walker with `keep_locals` | ~15 lines |
| `param_loads` depth loop `1 ..= 8` + `result_load_routes` (done) | provenance_results.odin:296; provenance_aliases.odin:173; proc_contracts.odin:239 | `next_load_depth` iterator / constant | ~6 lines |
| "Type a slot holds" fallback | borrow_summaries.odin:353; cfg_provenance.odin:1907; provenance_reborrow.odin:378; provenance_retention.odin:466 | one documented helper | small; removes divergence |
| Link-candidate filter (immutable param / temporary / non-carrier / provider) | provenance_retention.odin:76–84, 465–480 | `prov_slot_may_take_link` | ~10 lines |
| `task_effects = spawned … = false` bracketing (done) | provenance_call_walk.odin:267, 310, 374 | save/restore helper | ~4 lines; safer |
| Walk all non-nil bound arguments | provenance_builtins.odin:45, 105, 141; provenance_call_walk.odin:337; cfg.odin:1977 | `walk_flow_all` | ~10 lines |
| `context.temp_allocator` in provenance construction | 13 sites listed in Top recommendation 4 | `graph.alloc` | memory hygiene |

Estimated total line saving from the simplifications and duplications above: about 300 lines. The `Prov_Event` restructuring and the `cfg_provenance.odin` split are neutral in lines but carry the largest maintainability and memory value.

## Group 5: borrow solver, lifecycle, thread effects, and compile-time interpreter

Revision `fd381d23`. Read-only review of 23 files (~17.2k lines) under `src/`. Line numbers are at that revision.

### Overview

The group is careful, well-commented code. The fixpoints are monotone and bounded: the reach/links/below solvers in `borrow.odin` use a FIFO block worklist with interned rows and page-shared block tables, and the whole-program summaries use reader-driven worklists. I found no unsound merge or non-termination. Every finding below is about cost, duplication, or structure, plus a few latent edge cases.

There are four main themes:

1. **Repeated scaffolding.** The same replay loop over settled facts appears 7 times, the worklist exists in 4 forms, the "append if not already present" set helper exists about 10 times, and there are many type walkers.
2. **Summaries spread across parallel maps.** Whole-program summaries live in parallel maps (`global_writes`, `global_reads`, `reach_effects`, `allocator_uses`) with a mirrored own-part copy in `Callback_Summary`. This produces four copies of each accessor.
3. **Files that hold more than one subsystem.** `global_effects.odin` is half CFG event recording. `carrier_shape.odin` also holds the region lattice. `borrow.odin` also holds the path algebra and the program driver. `lifecycle.odin` also holds checker builtins.
4. **Uncached hot queries and per-event allocation.** `transfer_facts` and `type_hooks` are not cached, `solve_window` runs twice per body, and `running_sites` and `live_reborrow_of` allocate on every event.

`eval.odin` still has a second implementation of aggregate comparison next to `const_ops.odin`, and the interpreter's value representation is heavy: every scalar is a `core:math/big` integer inside a full `Const_Value`.

### Top recommendations

1. **Merge the replay passes in `summarize_body`, and add one replay iterator for all of them.**
   - The pattern "enter block, visit event, then `run_prov_event`" is repeated at seven sites: `borrow.odin:1076`, `:1186`, `:2139`, `borrow_report.odin:43`, `borrow_summaries.odin:64`, `:452`, `:698`.
   - `summarize_body` (`borrow.odin:1018-1028`) replays the whole body up to three times, once each for thread-local writes, escapes and carrier moves. That happens per body per fixpoint round.
   - Proposal: a `replay_next(&it) -> (^Prov_Event, bool)` iterator that runs the previous event's `run_prov_event`. Then make one fused pass that dispatches on `.Retain`, `.Escape`, `.Publish`, `.Def` and `.Rearrange`.
   - Saves about 35 lines and two thirds of the summary replays.
2. **Rebuild the per-body effect summaries as one struct with an own part and a whole part.**
   - `part_writes`, `part_reads`, `part_reach` and `part_allocator_use` (`global_effects.odin:1261-1294`) are four copies of the same accessor.
   - The maps `c.global_writes`, `c.global_reads`, `c.reach_effects` and `c.allocator_uses` duplicate the own-part fields `writes`, `reads`, `reach` and `use` of `Callback_Summary`.
   - Proposal: `Body_Summary{writes, reads, reach, use}` held twice per body (`own`, `whole`) in one slice indexed like `effect_program.bodies`, and `part_summary(c, part) -> ^Body_Summary`.
   - Saves about 40 lines and four map lookups per part.
   - It also lets `settle_body_effects` (`global_effects.odin:1506`) and `settle_thread_facts` (`thread_summaries.odin:166`) share the parts/closing/readers/queue scaffolding they currently duplicate, about 25 more lines.
3. **Use one worklist type.** (Done: `Worklist` in `semantic.odin`. Block
   problems still take items in wake order and body problems the latest first.
   `settle_result_summaries` keeps its order too. `solve_window` moves from
   round-robin passes to the block queue; its transfer is monotone, so it
   reaches the same fixed point. `perf.ps1` showed no change beyond the noise.)
   - Today there are four:
     - `Block_Queue` (FIFO, `cfg.odin:372-423`).
     - `Body_Queue` (LIFO, near-identical, `global_effects.odin:1078-1112`).
     - A hand-rolled queue/`queued`/`callers` map in `settle_result_summaries` (`borrow.odin:866-935`).
     - A round-robin `for changed` loop in `solve_window` (`borrow_tasks.odin:34-53`).
   - Proposal: one `Worklist` over `int`. `settle_result_summaries` can use `Body_Queue`-style readers indexed by body instead of `map[Symbol_Id][dynamic]^Expr_Proc`, and `solve_window` can use `block_queue_from_entry` like every other block solver.
   - Saves about 50 lines.
4. **Cache the expensive per-type queries the provenance walk asks at every site.**
   - `transfer_facts` (`transfer_facts.odin:192`) allocates a temporary map and walks the type on every call. It is reached per global per reach event (`borrow_tasks.odin:196`), per argument, and per slot via `type_reaches_waker`.
   - `type_hooks` (`hooks.odin:246`) is the same. It is called at every drop and copy site, and twice per copy in `prov_copy_of_held_effects` (`global_effects.odin:652-653`).
   - Both can be cached per underlying type once `lifecycle_of` reports `.Finite` and witnesses are complete, as `type_carries_borrow` already is.
5. **Delete the duplicate path predicates, and use `same_step` where it was meant.** (Done in an earlier round: `path_is_exact` is the one predicate, and `publish_place_settled` uses `same_step`.)
   - `prov_path_names_one_place` (`borrow.odin:278`) is identical to `path_is_exact` (`borrow.odin:2454`). Keep one; saves 11 lines.
   - `publish_place_settled` compares steps with full struct equality (`borrow.odin:1691`, `step != event.place_path[at]`). That compares `precision`, `synchronized` and `shifts` too, where `same_step` is the place-identity test. It is conservative, but it can discard a one-place store for a flag difference.
6. **Split the files that mix subsystems.** These are moves, not rewrites:
   - `global_effects.odin:119-800`, the `prov_note_*` and `prov_*_effects` hooks the CFG walk calls, moves into the `provenance_*` walk family. The whole-program solver and per-call queries stay.
   - The region lattice moves out of `carrier_shape.odin:440-703` into `region.odin`.
   - The `Proj_Step` path algebra (`borrow.odin:163-310`) and the program driver (`borrow.odin:834-1060`) move out of `borrow.odin`.
   - The checker special forms (`lifecycle.odin:9-286`) move out of `lifecycle.odin`, away from liveness.
7. **Replace the linear "append if not present" helpers with one generic, and use bitsets where sets get large.** (Done in part: `append_unique` replaces `add_global_symbol`, `add_effect_value`, `add_link` and the nested `add` in `collect_pointees`, and serves `note_read` and the nested `add` in `carried_types`; `add_global_effect` and `add_reached_global` merge as well as add, `set_add` grows a slice, and no bitset was added.)
   - The helpers are `add_global_symbol` (`global_effects.odin:1682`), `add_global_effect` (`thread_summaries.odin:309`), `add_reached_global` (`borrow.odin:1112`), `add_effect_value` (`global_effects.odin:484`), `add_link` (`borrow_loaded_below.odin:81`), `note_read` (`borrow.odin:2066`), `set_add` (`carrier_shape.odin:1214`), `add_unique` (`callback_summary.odin:29`), the nested `add` in `carried_types` (`borrow_summaries.odin:250`), and the nested `add` in `collect_pointees` (`transfer_facts.odin:347`).
   - `effect_call_globals`/`add_part_globals` and `settle_thread_facts` are quadratic in globals for a body that reaches most of them. `Global_Set` (`global_effects.odin:99`) already solved this with a bitset, but only inside `settle_body_effects`.
8. **Share the aggregate comparison between `eval.odin` and `const_ops.odin`.**
   - `eval_compare` (`eval.odin:1045-1104`) re-implements `aggregate_equal` and `aggregate_order` (`const_ops.odin:436-512`) over `Eval_Value.elements`, including the `initialized_by` live-prefix logic.
   - The two already differ on parts that cannot be compared. `part_equal` counts them as a difference (`const_ops.odin:526`); `eval_part_equal` makes the answer unknown (`eval.odin:1111`). (unverified whether intended)
   - Proposal: a generic `aggregate_compare($E, elements_of, compare_part)`, or freeze small aggregates and call `fold_comparison`.

### Per-file findings

#### src/borrow.odin
Verdict: the solver core is sound and well tuned, but it holds too much (types, path algebra, program driver, solver, publish/load), and several per-event loops scan every loan.

- **Duplication** (done earlier) `borrow.odin:278` `prov_path_names_one_place` and `:2454` `path_is_exact` are the same predicate: Field, or a single-element Range, with no precision. Delete one and rename its callers in `cfg_provenance.odin:2845,2855,3112,4551-4552`. Saves 11 lines. `path_is_indistinct` (`:266`) is the same loop without the precision test and can be written as its negation plus a precision check.
- **Bug (minor, conservative)** (done earlier) `borrow.odin:1690-1696`: `step != event.place_path[at]` compares whole `Proj_Step` structs, including `precision`, `synchronized` and `shifts`. A loan path that reaches the same place through a step whose flags differ loses `one_place`, and the store then joins instead of replacing. That can produce a spurious "may" conflict. Use `!same_step(step, event.place_path[at])`, as `path_has_exact_prefix` does.
- **Data structure/algorithm** (done: `loans_of_root`, built in `prepare_state`, serves `Rebind`, `Root_End`, `Reset` and the invalidation; `Rebind` clears one mask per row) `borrow.odin:1591-1604` (`.Rebind`) scans every loan and then every slot for each matching loan, which is O(loans·slots) per event. `end_loans` (`:1800-1820`) scans all loans per `Access`, `Root_End` and `Reset` event. Build `loans_by_root: [][]int` once in `prepare_state`; `Rebind`, `Root_End` and the invalidation then touch only that root's loans. For `Rebind`, OR those loans into one mask and clear it per slot row in a single pass.
- **Duplication** (done: `solve_links`, whose steps are now private to borrow.odin) `borrow.odin:1133-1137` and `borrow_summaries.odin:84-87` run the same four-step link solve: `link_landed_stores`, `resolve_content_reads`, `prov_settle_pending_reborrows`, `solve_links_held`. Extract `solve_links(state)`. Saves about 5 lines, and the ordering constraint then has one owner.
- **Duplication** `borrow.odin:1274-1279`, `:1378-1395`, `:2283-2291` and `borrow_loaded_below.odin:160-177` each hand-walk `[][]T` block-table pages with `at * BLOCK_TABLE_PAGE + index`. `borrow_tables.odin` should own `block_table_or`, `block_table_and` and an interned-row join, `interned_join(rows, a, b, op) -> u32`. The OR join (`join_links_held`) and the AND join (`join_loaded_below`) are the same code with a different byte operator. Saves about 25 lines.
- **Simplify** (done: top recommendation 3) `settle_result_summaries` (`borrow.odin:866-935`) hand-rolls a FIFO with `queued[]`, a `map[Symbol_Id][dynamic]^Expr_Proc` of callers, and a `registered[]` high-water mark. The `stale` test already decides revisits, so a body-indexed reader list plus the shared worklist (top recommendation 3) gives the same result in about half the code. It also removes the map-iteration miscompile workaround at `:925`.
- **Structure** Lines 163-310 (the `Proj_Step` algebra: `path_extend`, `path_concat`, `paths_overlap`, `steps_overlap`, and so on) are used by `carrier_shape.odin`, `cfg_provenance.odin` and `view_start.odin`, and need no solver. Move them to a `prov_paths.odin`, or to the top of `carrier_shape.odin`, which says it "needs no solver state". Also move:
  - `analyze_program_provenance`, `settle_result_summaries`, `summarize_body`, `check_declared_escape` and `note_instance_sites` (`:840-1060`), which are the program driver, into `borrow_summaries.odin` or a driver file.
  - `body_global_reach`, `note_reached_globals` and `add_reached_global` (`:1069-1124`), which are thread-summary collection, into `provenance_thread_summaries.odin`.
- **Structure** `bit_get`, `bit_mark`, `bit_clear` and `bytes_or` (`:746-832`) are general bitset helpers used by `global_effects.odin`, `view_start.odin`, `borrow_tasks.odin` and `borrow_loaded_below.odin`. Move them to `borrow_tables.odin` beside the rows they serve.
- **Data structure/algorithm** (not done: the lists are usually a few slots, shorter than a per-call table over every slot) `note_read` (`:2066`) and `with_held_content` (`:2189`) use `slice.contains` on a growing list, which is quadratic in reads. Usually small; a per-call `[]bool` over slots, which `state.load_expanded` already provides in spirit, makes it linear. Low priority.
- **Simplify** (done: one loop; `report` sorts diagnostics by position, so their order is unchanged) `analyze_program_provenance` (`:850-859`) walks `checked_bodies` twice, once to analyze and once for `check_declared_escape`. `check_declared_escape` reads only settled summaries and can run in the first loop, unless diagnostic order is deliberate. If it is, say so.

#### src/borrow_summaries.odin
Verdict: correct, but it carries a solver transfer function and call-side queries that belong elsewhere.

- **Structure** `rearrange_carriers` (`:367-396`) is a transfer function of `run_prov_event` (`.Rearrange`) and calls `load_writable_content`. Move it into `borrow.odin` beside `load_writable_content`. Likewise `slot_carrier_type` (`:353`) and `carrier_may_land_in` (`:335`) are solver primitives. `call_carrier_moves`, `written_content_summary` and `written_region_summary` (`:291`, `:630`, `:657`) are call-side queries used by `provenance_*`.
- **Simplify** Three collectors (`collect_carrier_moves :60`, `collect_thread_local_writes :439`, `collect_escape_provenance :695`) each replay the whole body. See top recommendation 1. Saves about 20 lines.
- **Data structure/algorithm** (done: a merge grows the row once, and `set_join` grows a set once, for `merge_carrier_move`, `call_carrier_moves` and `merge_provenance`) `merge_written_content` (`:619-622`) grows `row^` by one element per new entry, copying into `semantic_allocator`. That is quadratic, and every old row is permanent arena garbage across fixpoint rounds. `set_add` (`carrier_shape.odin:1214`, used by `merge_carrier_move :283`) does the same. Use a `[dynamic]` in the semantic allocator, or rebuild once per round.
- **Data structure/algorithm** `copies_outlast_body` (`:126-142`) tests every reborrow against every held slot at each exit block. Iterating only the set bits of each row, or precomputing a `storage` mask over reborrow sources, avoids O(slots·reborrows) per exit.
- **Simplify** (done, next to `CARRIER_DEPTH`) `merge_loan_provenance :761` builds `u8(1) << u8(loan.depth - 1)`. That is correct only because `CARRIER_DEPTH == 4 <= 8`. Add `#assert(CARRIER_DEPTH <= 8)` next to `Result_Dependencies.param_loads` (`carrier_shape.odin:719`) so a budget change cannot silently make `changed` always true and stop the fixpoint from settling.

#### src/borrow_loaded_below.odin
Verdict: clean and well documented; small simplifications only.

- **Duplication** `join_loaded_below` (`:150-178`) and `join_links_held` (`borrow.odin:1378`) are the same interned-row join with AND versus OR. `end_loaded_below` (`:241-263`) and `end_links_of_value` with `row_holds_reborrow_of` (`borrow.odin:1400-1461`) both memoize "row minus some bits" in their own `map[u64]`. One `interned_without(rows, row, mask_or_bit, memo)` in `borrow_tables.odin` serves both. Saves about 30 lines.
- **Simplify** `:210-219` decodes `value` bit by bit to set `below.used[...]`. Keep `used` as a `[]u8` row and `bytes_or(below.used_row, value)`. Saves 8 lines and the inner loop.

#### src/borrow_report.odin
Verdict: clear diagnostics replay; some per-event scans and repeated wording logic.

- **Data structure/algorithm** `live_reborrow_of` (`:216-231`) rebuilds a `candidates` list by scanning every slot's `links_held`, in `context.temp_allocator`, for every source of every `Live`/`Load` event. That is O(events·sources·slots) plus temporary allocation that grows across the whole report pass. Compute the candidate list once per event, since it does not depend on `source` for the non-`At_Once` case, and reuse a scratch `[dynamic]` in `Prov_Solve`. (unverified hotspot; measure with `perf.ps1`)
- **Bug (fragile, unverified)** (not done: recorded in open-questions.md as bug 14) `at_once_reaches` (`:293-323`) zeroes and restores derived rows in `state.reach` without `reach_row_written`, then calls `load_pointee_content`. That writes `use.slot`'s row and precision as a side effect, before the report loop's own `run_prov_event` for that event. It is harmless today because the `.Load` replay overwrites both, but it couples correctness to event order. Prefer a scratch `merged` with no write-back: add a `dry` flag to `load_pointee_content`.
- **Duplication** `reported_within` (`:76-83`) and `reach_reported_within` (`borrow_tasks.odin:566-573`) both scan a whole map for a report inside a span. A per-file sorted list of report offsets, or a single shared helper, would serve both.
- **Duplication** (not done: each site tests a different condition, the diagnostic's precision, a crowded region, a source's precision or a merged loan, so `hedge` would only rename the conditional) The "precision lost, so say may" choice is open-coded at `:189-191`, `:386`, `:581`, `:599`, `:635`, and in `borrow_tasks.odin:598`, `:686` and `:789-797`. A helper `hedge(state, sure, unsure: string) -> string` removes about 15 lines and keeps the wording rule in one place (design.md "Minimum provenance precision").
- **Simplify** `carrier_name` (`:608-627`) scans all reborrows per hop. `state.links_into[at]` (`borrow.odin:661`) already indexes reborrows by derived slot. It only runs on the error path, so it is cheap to fix.

#### src/borrow_tables.odin
Verdict: good data structure. Page sharing plus interned rows fit the problem well.

- **Structure** It should also own the page-walking join and AND helpers now open-coded in `borrow.odin` and `borrow_loaded_below.odin` (see above), and the bitset primitives currently in `borrow.odin:746-832`.
- **Simplify** `Interned_Rows.ids: map[string]u32` (`:96`) hashes the full row on every `intern_row`, including rows that did not change. `reach_settle` already skips unchanged rows. A cheap win is to skip `intern_row` in `join_links_held` and `end_links_of_value` when the edit produced no change (compare with `same_page`). (unverified gain)

#### src/carrier_shape.odin
Verdict: three subsystems in one file. The per-type caches are good, but the walkers repeat.

- **Structure** The region lattice (`Region_Set`, `Param_Reads`, `region_*`, `merge_allocator_use`, `substituted_region`, `callback_allocator_use`, `clone_regions`; `:440-703`, about 260 lines) is independent of carrier shapes. Move it to `region.odin`, which already holds the `Arena`/`Scratch` types and `type_carries_provider`. The result-summary section (`:705-1237`) could likewise be its own `result_summary.odin`. Then `carrier_shape.odin` matches its name.
- **Duplication** `type_carries_borrow` (`:110`), `prov_type_reaches_destination` (`:127`) and `prov_type_reaches_mutable` (`:141`) follow the same "check cache, temp visited map, walk, store" pattern, and so does `type_carries_provider` (`region.odin:74`). A generic `cached_type_walk(cache: ^map[Type_Id]$R, type, walk: proc(...) -> R)` saves about 20 lines. `carrier_leaves` (`:204`) re-walks exactly what `carrier_reach_walk` (`:227`) walks; its comment says so. One walker that collects leaves while computing reach removes about 20 lines.
- **Data structure/algorithm** `param_paths: [][]bool`, `Load_Paths.first/last: []bool`, and the tri-state "nil means every path, or not yet seen" force a `fresh` flag through `narrow_path_row`, `join_path_row`, `join_load_paths`, `merge_param_paths` and `merge_param_load_paths`. Carrier shapes are capped at `CARRIER_WIDTH` = 64 paths, so `Path_Row :: struct { mask: u64, every: bool }` represents this explicitly, without per-row allocation and without `fresh`. That simplifies about 80 lines across `carrier_shape.odin`, `borrow_summaries.odin:796-916` and `proc_contracts.odin:219-249`.
- **Simplify** `region_merge` (`:637-651`) and `region_remove_param` (`:542-552`) touch each `u64` field by name. Grouping `params`, `loaded`, `named.*` and `below.*` into a `[6]u64` (or `bit_set` rows) makes merge a loop and keeps a new field from being forgotten.
- **Simplify** `set_add` (`:1214`) copies the whole set on every insert into `semantic_allocator`. See top recommendation 7.

#### src/callback_summary.odin
Verdict: coherent and small. It duplicates value resolution that `global_effects.odin` already has.

- **Duplication** `callee_values` (`:168-178`) and `passed_values` (`:183-206`) re-derive what `call_values` (`global_effects.odin:870-882`) returns, through the same `c.called_values[site]` and `c.argument_values[site]`. The fallback in `passed_values :193-204`, which reads a named procedure or a parameter from the expression, is a reduced `effect_value` (`global_effects.odin:355-379`). Expose one `call_site_values(c, body, call)` returning both.
- **Duplication** "a procedure type or a `dyn proc` view's signature" is decided in `callable_arity` (`:287-297`), `any_value_call` (`global_effects.odin:977-982`), `callable_type_targets` (`global_effects.odin:1786-1796`), `effect_variable` (`:345`) and `effect_value` (`:364`). Add one `callable_signature(c, type) -> (proc_type, dyn_interface, ok)`.
- **Structure** `add_unique` (`:29`) is a generic map-of-sets helper unrelated to callbacks. Move it beside `set_add`.

#### src/view_start.odin
Verdict: a solid least-fixed-point design. One fragile cache key.

- **Data structure/algorithm** `Prov_View_Query.reaching: rawptr` (`:84-89`, `:127`) keys the answer cache by the address of the `reaching` slice. That is correct only while every caller passes the same backing array for the same set. Two equal sets in different arrays miss the cache, and an arena reuse after `free_all` could alias a stale key. The graph is rebuilt per body, so it is safe today. Interning the reaching lists, or keying by a hash of their contents, removes the dependency on pointer identity.
- **Simplify** `solve_view_defs` (`:360-394`) allocates dense `entry` and `exit` rows per block (blocks × bits). The `block_table_*` page sharing used for reach would apply directly. Low priority: only views that are followed get bits.

#### src/borrow_tasks.odin
Verdict: correct; a few avoidable recomputations and per-event allocations.

- **Data structure/algorithm** (done in part: the block worklist of top recommendation 3; the window is still computed twice per diagnosed body) `solve_window` (`:20-55`) is a round-robin `for changed` loop over every reachable block, while every other block solver uses `block_queue_from_entry`. It is also computed twice per diagnosed body, in `settle_pool_joins` (`:69`, through `prepare_state`) and in `report_provenance` (`borrow_report.odin:17`). The events that `settle_pool_joins` removes carry `joins` and are never `Task_Start` or `Task_Join`, so the window is unchanged and can be cached on the graph. (unverified that no removed event is a window event)
- **Simplify** (done: `next_running_site`) `running_sites` (`:121-129`) allocates a list in `graph.alloc` on every `block_running`, `check_task_reservation`, `check_parent_allocator_use` and `window_block_span` call. Iterate the mask bits inline with a small iterator; saves the allocations and about 8 lines.
- **Data structure/algorithm** `shared_carrier_hazard` (`:190-207`) calls the uncached `transfer_facts` per global per reach event. Cache it per global. See top recommendation 4.
- **Simplify** (done: `REACH_CHAIN_NOTES`) `note_reach_chain` (`:746`) hard-codes 8 steps. Name the constant, or bound it by the chain's visited set.

#### src/global_effects.odin
Verdict: the largest structural problem in the group. About 700 lines of CFG-walk recording hooks sit beside the whole-program solver, and the summary accessors come in fours.

- **Structure** `:119-800` (`prov_note_static_write`, `prov_note_proc_value`, `prov_call_effects`, `prov_note_proc_store`, `prov_*_effects`, `prov_effect_call`, `prov_pool_join_effects`, `prov_window_effect_use`, `prov_note_shared_effect`) are called during graph construction and emit `Prov_Event`s. They belong with `provenance_call_walk.odin` and `provenance_effect.odin`. What remains (`compute_global_writes`, `settle_*`, `call_parts`, `effect_targets`, the per-call queries) is the whole-program solver its architecture-table row describes. The file also lacks the header comment every other file has. (The header was added in an earlier round; the move is still open.)
- **Duplication** `part_writes`, `part_reads`, `part_reach` and `part_allocator_use` (`:1261-1294`) are four copies of one lookup. See top recommendation 2.
- **Data structure/algorithm** `effect_call_globals` (`:1395-1399`) and `add_part_globals` (`:1695`) merge globals through `add_global_symbol`'s linear scan. That runs per call site per body, for both reads and writes, which is O(parts·globals²) for a call near `main`. `Global_Set` with `number_body_globals` (`:1551`) already provides a bitset. Keep the numbering on `effect_program` and reuse it here.
- **Duplication** `settle_body_effects` (`:1506-1546`) and `settle_thread_facts` (`thread_summaries.odin:166-223`) share the build-parts, closing-parts, `part_readers`, `body_queue_make` and `grew` scaffolding. Extract `settle_over_parts(c, parts, closing, visit)`. Saves about 25 lines.
- **Duplication** (done: top recommendation 3) `Body_Queue` (`:1078-1112`) duplicates `Block_Queue` (`cfg.odin:372-423`). See top recommendation 3.
- **Simplify** (done: `prov_copy_effects` answers whether a hook runs) `prov_copy_of_held_effects` (`:651-656`) calls `prov_copy_effects`, which calls `type_copy_hooks`, then calls `type_copy_hooks` again. Pass the hooks through or cache them.

#### src/thread_summaries.odin
Verdict: small and correct. It shares its scaffolding and set representation with `global_effects.odin`, but less efficiently.

- **Data structure/algorithm** `add_global_effect` (`:309-317`) is a linear scan, so `whole_reach` merging is quadratic in reached globals, the same case `Global_Set` was built for.
- **Bug (minor, wording)** (done: bug 11, `merge_effect_source`) `add_global_effect` keeps the first `Effect_Source` and ignores later ones (`:192`, `:205`, `:214`). A global first reached through a merged dependency keeps its precision loss, so the diagnostic says "may reach" even when a later path reaches it exactly. The opposite order says "reaches". The result is order dependent. `effect_call_reach` (`global_effects.odin:1331-1335`) does intersect precision. Decide which is intended, and merge `precision` the same way in both, intersecting if any exact path should win.
- **Duplication** The settle loop mirrors `settle_body_effects` (see above).

#### src/eval.odin
Verdict: a clear tree-walker with careful limits. It is the largest file in the group (3562 lines) and should be split. It keeps a second aggregate comparison and a heavy value representation.

- **Duplication** `eval_compare` (`:1045-1104`) mirrors `aggregate_equal` and `aggregate_order` (`const_ops.odin:436-512`), including `common_live_count` handling and the union-variant shortcut. The handling of uncomparable parts differs (see top recommendation 8; (unverified) whether intended). `eval_hash` (`:2116-2164`) mirrors `emit_hash_value` and `hash_const` by comment only. A shared walker parameterized by element access would stop them drifting.
- **Data structure/algorithm** `Eval_Value` (`:32-43`) embeds a whole `Const_Value`: kind, bool, `float_bits`, `type_value`, a `big.Int` header, the float, `float_raw`, `text`, and an `aggregate` that must stay nil. On top of that come `type`, `variant`, `elements`, `capacity`, `target` and `proc_value`, so roughly 150 bytes per value (unverified exact size). Every integer is a `core:math/big` allocation. Loops and arithmetic dominate compile-time work, so a small-integer fast path (`i64` with overflow promotion to `Big_Int`) and a tagged scalar representation would cut both memory charged against `EVAL_MAX_MEMORY` and time. This is a design change; record it in `future-plans.md` if wanted.
- **Bug (minor leak against the limit)** (done: the sort scratch and the range temporaries in an earlier round, and now the frame `eval_dispatch` pushes for a constant initializer) These allocations are charged to the evaluator and never released:
  - `eval_sort` (`:1313`) never releases `scratch`.
  - `eval_dispatch` (`:3433-3436`) pushes its own frame but only pops it, never calling `eval_release_frame`.
  - `eval_range_foreach` (`:3200-3205`) allocates the integer temporaries `offset`, and its reversed difference, every iteration and never releases them, although they are pure temporaries. `bi_release` exists for this (`bigint.odin:40`).
  - Over a long `foreach` at the 1M-step limit these temporaries add up to tens of MB against the 64 MB limit.
  - Add `defer delete(scratch, ev.alloc)`, `eval_release_frame`, and `bi_release(offset)`.
- **Simplify** (done) `eval_message` (`:2672`) builds its text in `k.c.semantic_allocator` (permanent) for a diagnostic. Use `context.temp_allocator`, as `errorf` formats anyway.
- **Structure** Splitting along the existing sections gives smaller files:
  - expressions (`:542-1130`)
  - containers and maps (`:1167-1640`)
  - places, calls and frames (`:1642-2390`)
  - builtins (`:2392-2685`)
  - statements and loops (`:2687-3562`)
  - The `@(private = "file")` helpers would become `@(private)` package-private. The cost is namespace exposure, so prefix them `eval_`, as most already are; `scalar`, `const_of`, `zero_value`, `copy_value`, `freeze`, `map_find` and `current_frame` are not yet.
- **Simplify** `const_of` (`:407`) is `v.constant`, and `scalar` (`:412`) differs from a literal only in nilling `aggregate`. With `using constant`, both can be inlined, or `scalar` can be kept as the single constructor. This is minor.

#### src/eval_memory.odin
Verdict: a neat size-class allocator. One latent edge case.

- **Bug (latent, unverified reachability)** (done: the empty request in an earlier round, and now the nil guards, tested by `eval_allocator_handles_nil_and_empty_requests`) `eval_shape(0, align)` (`:103-105`) computes `count = 0`, so `class = -1`. After the alignment shift the class is `-3`, `-2` or `-1`, all negative, which the allocator reads as the heap-block sentinel. `pad` stays `align` (16), smaller than `size_of(Eval_Large) + size_of(Eval_Block)` (32). So `eval_block_alloc` would write the `Eval_Large` link at the block start, and the header write at `payload - 16` would then overwrite that link. `storage.large` becomes corrupt and `eval_storage_destroy` walks a garbage pointer.
  - The runtime's `mem_alloc`/`mem_resize` wrappers return early for size 0, so normal `make`/`append` never reach it. Any direct `allocator.procedure` call with size 0 would.
  - The procedure also does not handle `.Resize` with `old_memory == nil`, or `.Free(nil)`, which the Odin allocator contract permits.
  - Fix: `count := max((size + 15) / 16, 1)`, plus nil guards in `eval_allocator_proc`. About 4 lines.

#### src/hooks.odin
Verdict: careful lazy classification. The hook lists are recomputed at every site.

- **Data structure/algorithm** `type_hooks` (`:246-282`) allocates a visited map and walks the type on every call. It is reached from every drop and copy site in every graph build (`prov_drop_effects`, `prov_copy_effects`, `prov_scope_drop_effects`, `drop_cannot_panic`, `type_owns_allocation`). Cache `drop_hooks` and `copy_hooks` per underlying type once `lifecycle_of` returns a `.Finite` entry that was kept (not `open`): add them to `Lifecycle`, or to a side map. `type_drop_runs_hook` (`:229`) then becomes O(1), not "build the list to test `len > 0`".
- **Simplify** `lifecycle_of` (`:124-141`, `:161-163`) allocates a fresh `Lifecycle` in the permanent `semantic_allocator` on every call while a record is resolving, or while `open`, and discards it. Return a pointer to a package-level "unresolved" entry, or to a temporary-allocator copy, for the first case.
- **Duplication** (done: the comment) `has_move_only_part` and `type_clone_disabled_walk` (`:294-331`) re-implement `some_lifecycle_part` (`:552`), which cannot be used because it calls `lifecycle_of`. That is legitimate, but say so in a comment to stop "simplification" attempts.

#### src/hook_validation.odin
Verdict: fine. Coherent and readable.

- **Duplication** (done: `DROP_HOOK_SHAPE`) The drop-signature message is written twice: `check_generic_impl_hooks :216-218` and `require_hook_shape :175-183`. Share the `shape` string constant. Minor.

#### src/lifecycle.odin
Verdict: correct three-point liveness. The file holds two unrelated concerns.

- **Structure** `:9-286` are checker special forms (`check_move`, `check_drop_builtin`, `check_forget_builtin`, `check_exchange_builtin`, `check_capacity_builtin`, `require_argument_ownership`, `place_root_symbol`). They run during checking and belong with the builtin checks (`check_builtin.odin`) or with `copy_sites.odin`'s ownership classification. `:288-569` is the liveness solver the architecture doc assigns to `lifecycle.odin`.
- **Simplify** (done) `require_argument_ownership :258` formats the parameter name with `fmt.aprintf(..., k.c.semantic_allocator)`, which is permanent, for a one-off diagnostic. Use `tprintf`.

#### src/copy_sites.odin
Verdict: clear. The move-only rejection is written three times.

- **Duplication** (not done: the three sites report different codes and wordings, one per field; the shared part is two lines) The sequence "if `type_clone_disabled`, report L0502/L0503 and stop; else `contribute_lifecycle_members`" appears in `classify_return_value :29-40`, `classify_copy :89-100` and `classify_destructure :220-228`. Extract `require_copyable(k, span, type, what) -> bool`. Saves about 15 lines.
- **Simplify** `record_copy` (`:306-308`) sets `copied_as`, and `classify_copy :101` sets it again for the same expression in `classify_declaration_copies` and `classify_assignment_copies`. One owner suffices.
- **Simplify** (done) `report_inline_copy :363-364` and `report_allocating_copy :399-402` format diagnostic fragments with `aprintf` into `semantic_allocator`, which is permanent. Use `tprintf`.

#### src/extended_temporaries.odin
Verdict: fine. Small, focused, matches its spec section.

#### src/transfer_facts.odin
Verdict: coherent. The main fact query is uncached, and its walker repeats the type switch found elsewhere.

- **Data structure/algorithm** `transfer_facts` (`:192-201`) allocates a temporary map and walks the type on every call. `type_reaches_waker` (`:275`) calls it per slot per join (`borrow_tasks.odin:257`) and once per instance argument inside `path_waker :307`. Cache it per `(type, through_views)` after checking, when witnesses are final.
- **Duplication** `transfer_facts_walk` (`:223-271`), `collect_pointees` (`:358-382`) and `type_holds_inline` (`:401-416`) each switch over Struct, Union, Array, Map and Distinct by hand, where `type_owned_parts` (`types.odin:334`) and `Type_Walk` (`types.odin`) already exist. Using them shortens each by about 8 lines.

#### src/provider_end.odin
Verdict: fine. Well scoped to its `Reset_Key` contract.

- **Simplify** `place_is_direct` (`:116-133`) re-walks the place, as `place_root_symbol` (`lifecycle.odin:272`) and `eval_frame_place` (`eval.odin:3447`) do with slightly different rules. Not mergeable as is, since their rules differ, but worth a cross-reference comment.

#### src/panic_free.odin
Verdict: fine. Conservative and matches design.md "Panics and unwinding".

- **Simplify** `expr_cannot_panic_operand` (`:191-201`) repeats the Ident, Selector and Postfix arms of `expr_cannot_panic` without the scalar-type gate. A `place_only: bool` parameter on `expr_cannot_panic` removes it. Saves about 10 lines; minor.

#### src/proc_contracts.odin
Verdict: fine. Compact.

- **Simplify** (done: `next_load_depth`) `dependency_contract_within :239` loops `for depth in 1 ..= 8`, while the matching loop in `merge_result_dependencies` (`carrier_shape.odin:1193`) uses `CARRIER_DEPTH`. Use the constant, or loop over the set bits.
- **Data structure/algorithm** (done in part: the scan stops at a match; the list holds one entry per distinct join) `join_callback_types :49-51` scans all `c.contract_joins` with `slice.equal` and does not `break` on a match. Small, but a `map[string]Symbol_Id` keyed by the joined name it already builds would be direct.
- **Structure** (done) No file header comment, unlike the rest of the group.

#### src/precision.odin
Verdict: fine. A small, focused vocabulary.

### Cross-file duplication

| Pattern | Sites | Proposal |
| --- | --- | --- |
| Replay settled facts: enter block, visit event, then `run_prov_event` | `borrow.odin:1076,1186,2139`; `borrow_report.odin:43`; `borrow_summaries.odin:64,452,698` | `replay_next` iterator; fuse the three summary collectors |
| Worklist / fixpoint queue | `Block_Queue` `cfg.odin:372-423`; `Body_Queue` `global_effects.odin:1078-1112`; hand-rolled queue `borrow.odin:890-934`; round-robin `borrow_tasks.odin:34-53` | One `Worklist` (FIFO/LIFO flag) |
| Parts, closing parts, readers, queue scaffolding | `settle_body_effects` `global_effects.odin:1506`; `settle_thread_facts` `thread_summaries.odin:166`; `settle_called_parameters` `global_effects.odin:1006` | `settle_over_parts` helper |
| Own-part versus whole-summary accessors | `part_writes/reads/reach/allocator_use` `global_effects.odin:1261-1294`; parallel maps `c.global_writes`, `global_reads`, `reach_effects`, `allocator_uses` vs `Callback_Summary` fields | `Body_Summary{own, whole}` |
| Linear "append if absent" sets | `add_global_symbol`, `add_effect_value` (`global_effects.odin:1682,484`); `add_global_effect` (`thread_summaries.odin:309`); `add_reached_global`, `note_read` (`borrow.odin:1112,2066`); `add_link` (`borrow_loaded_below.odin:81`); `set_add` (`carrier_shape.odin:1214`); `add_unique` (`callback_summary.odin:29`); nested `add` in `carried_types` (`borrow_summaries.odin:250`) and `collect_pointees` (`transfer_facts.odin:347`); `add_called_parameter` (`global_effects.odin:1053`) | Generic `append_unique`; bitsets (`Global_Set`) where sets grow with the program |
| Interned-row join and memoized "row minus bits" | `join_links_held` `borrow.odin:1378`; `join_loaded_below` `borrow_loaded_below.odin:150`; `end_links_of_value` and `row_holds_reborrow_of` `borrow.odin:1400-1461`; `end_loaded_below` `borrow_loaded_below.odin:241` | `interned_join`, `interned_without` in `borrow_tables.odin` |
| Block-table page walk `at * BLOCK_TABLE_PAGE + index` | `borrow.odin:1274-1279,1378-1395,2283-2291`; `borrow_loaded_below.odin:160` | `block_table_or`, `block_table_and` |
| Cached per-type predicate with a temporary visited map | `type_carries_borrow`, `prov_type_reaches_destination`, `prov_type_reaches_mutable` (`carrier_shape.odin:110-149`); `type_carries_provider` (`region.odin:74`); uncached `transfer_facts` (`transfer_facts.odin:192`) and `type_hooks` (`hooks.odin:246`) | One `cached_type_walk` helper; cache the last two |
| Hand-written Struct/Union/Array/Map type walkers | `carrier_reach_walk`, `carrier_leaves`, `type_reaches_destination`, `carrier_shape_walk`, `region_field_shape_into`, `widen_summary_map_path` (`carrier_shape.odin`); `transfer_facts_walk`, `collect_pointees`, `type_holds_inline`, `path_waker` (`transfer_facts.odin`); `prov_type_has_region` (`provenance_regions.odin:1110`); `own_equalities_walk` (`operators.odin:1125`); `type_hooks_walk` (`hooks.odin:258`) | Use `type_owned_parts`/`Type_Walk` (`types.odin`) where the walk needs no per-kind step; keep bespoke ones only where steps are recorded |
| Procedure type or `dyn proc` signature | `callable_arity` `callback_summary.odin:287`; `any_value_call` `global_effects.odin:977`; `callable_type_targets` `:1786`; `effect_variable` `:345`; `effect_value` `:364` | `callable_signature(c, type)` |
| Call-site procedure values | `call_values` `global_effects.odin:870`; `callee_values` and `passed_values` `callback_summary.odin:168,183`; `effect_value` `global_effects.odin:355` | One `call_site_values` |
| One-place path predicate (done) | `prov_path_names_one_place` `borrow.odin:278` equals `path_is_exact` `borrow.odin:2454` | Delete one |
| "Reported inside span" scan | `reported_within` `borrow_report.odin:76`; `reach_reported_within` `borrow_tasks.odin:566` | Shared helper |
| "may" hedge on precision loss (not done) | `borrow_report.odin:189,386,581,599,635`; `borrow_tasks.odin:598,686,789-797` | `hedge(state, sure, unsure)` |
| Aggregate equality, ordering and hashing | `eval_compare` `eval.odin:1045-1104` vs `aggregate_equal`/`aggregate_order` `const_ops.odin:436-512`; `eval_hash` `eval.odin:2116` vs `hash_const` (`hash.odin:323`) and `emit_hash_value` | Shared walker over element accessors |
| Move-only copy rejection | `copy_sites.odin:29-40,89-100,220-228` | `require_copyable` |
| Same link-solve sequence (done) | `borrow.odin:1134-1137`; `borrow_summaries.odin:84-87` | `solve_links(state)` |
| Grow-by-one slice copy into the permanent arena | `set_add` `carrier_shape.odin:1214`; `merge_written_content` `borrow_summaries.odin:619`; `add_unique` `callback_summary.odin:29` | `[dynamic]` or per-round rebuild |

Finding counts (per-file bullets): Bug 5, Simplify 22, Data structure/algorithm 15, Duplication 18, Structure 10.

## Group 6: LLVM backend and toolchain

Scope: `src/emission_contract.odin` and the 27 non-test `src/emit_llvm*.odin` files (~16.1k lines). Read-only review; nothing was built or run.

### Overview

The backend is careful and well commented. Ownership, unwind registration, large-value routing, and ABI classification are applied consistently, and I found no high-confidence miscompile on a path the checker allows. Most cases I suspected (float hash keys, `string +=`, managed values crossing a foreign call, `cpu.c` at a higher level) turn out to be ruled out upstream. The real problems are structural:

1. **Hand-rolled IR text with little shared vocabulary.** There are about 197 `x := temp(e); fmt.sbprintfln(...)` pairs and 866 `fmt.sbprint*` calls. The same idioms (spill to a slot, compare a status to 0, OR/AND-fold `i1`s, test a null pointer) are spelled out again at every site.
2. **The same union-tag dispatch chain appears 7 times**, always as compare-and-branch per variant where one LLVM `switch` would do.
3. **The module text is treated as a data structure and re-parsed after the fact.** `splice_prologue`, `unwind_finished_body`, `mark_replay_reads`, `emit_foreign_declarations` (which scans the `declare` lines already written), and the witness counting in `attach_debug_info` all do this. Some of these passes are justified; the declaration scan and the witness counting are fragile and easy to replace.
4. **File boundaries have drifted.** `emit_llvm_expr.odin` holds about 600 lines of constant imaging, about 300 lines of equality and ordering, and about 230 lines of text operations. `emit_llvm_containers.odin` holds the generic memoised-thunk machinery that box and sort also use, plus the hashing that must stay coherent with equality, which lives in expr.

### Top recommendations

1. **Add one tag-dispatch helper built on LLVM `switch`, and use it at all 7 union-variant chains**
   (Done: `emit_union_switch` and `union_tag_llvm`, at all seven sites;
   `union_dispatch_is_one_switch` and `tests/ll/union_format_switch.loke`.
   `emit_format_enum` still compares one member at a time.): `emit_union_widen` (union.odin:102), `emit_union_drop` (lifecycle.odin:596), `emit_union_try_clone_body` (lifecycle.odin:626), `emit_union_equal` (expr.odin:2066), the union arm of `emit_hash_value` (containers.odin:1383), `emit_format_union` (format.odin:378), and the type switch's tests (stmt.odin:787). Each site repeats about 6 lines (`temp`, `icmp eq i%d`, two `new_label`s, `branch_if`, `place_label hit`, … `place_label next`), and the tag width is re-derived in 9 places with `fmt.aprintf("i%d", shape.tag_bytes*8)`. One switch per union is shorter IR and gives faster `-opt=none` code. Saves about 50 lines. `emit_format_enum` (format.odin:425) could use the same helper.
2. **Make hashing of fixed arrays loop instead of unrolling** (containers.odin:1414-1421). (Done in an earlier round: hashing loops wherever `array_walks_in_loop` says equality does.) A non-large array (up to 4096 bytes) is fully unrolled: a `[4096]u8` key emits about 16k instructions into its hash thunk. `emit_array_equal` (expr.odin:1985-1995) already switches to a loop above `UNROLLED_EQUAL_ELEMENTS`/`UNROLLED_EQUAL_BYTES`. Use the same thresholds for hashing, and merge the large-array branch (1401-1413) into that loop. This is a code-size defect, and it also makes hashing and equality lower the same shapes differently. Add a regression test that bounds the IR growth, in the style of `fixed_array_clone_ir_grows_linearly`.
3. **Declare runtime entries from one table instead of ~85 `fmt.sbprintln("declare ...")` lines** (done for the tables and the declared-name set, with the module text unchanged. `Emitter.declared` is the one set of declared names: foreign bindings and `declare_intrinsic` record into it too, which fixed an intrinsic declared twice when a foreign binding named it (`tests/run/foreign_intrinsic_binding.loke`). Still hard-coded in `emit_foreign_declarations`: the four names the compiler defines after it. Still unconditional: the 30 `*.with.overflow` declarations. The tables did not shorten the code; they added about 65 lines.): runtime.odin:58-120 and 172-190, containers.odin:15-41, atomics.odin:31-41, plus the declaration in format.odin:570. A `[]struct{name, signature, attrs}` table would:
   - remove about 70 lines;
   - let `emit_foreign_declarations` (abi.odin:34-50) consult a set instead of re-parsing the `declare ...(` lines already written and keeping hard-coded `seen[...]` entries;
   - make it possible to declare entries lazily through the existing `declare_intrinsic`. This also covers the 30 `*.with.overflow` declarations that are emitted unconditionally (runtime.odin:98-102), while the vector forms already go through `declare_intrinsic` (simd.odin:78).
4. **Split `emit_llvm_expr.odin` (2726 lines) along its own section rulers:**
   - lines 11-612 (constants, byte images, private globals) become `emit_llvm_const.odin`;
   - lines 1837-2135 (comparison and equality), together with `emit_hash_value`/`emit_hash_mix`/`emit_hash_bits` from containers.odin:1342-1471 (whose design note requires coherence with `==`), become `emit_llvm_equality.odin`;
   - lines 2379-2611 (text operations and conversions) become `emit_llvm_text.odin`.

   That leaves expr at about 1500 lines of places and expressions. Update the table in compiler-architecture.md "LLVM and toolchain" in the same commit.
5. **Add one `spill(e, type, value) -> slot` helper (alloca + `store`, passing a large value's address through unchanged) and use it at its ~15 copies** (Done in part: `spill`, at the twelve alloca-and-store copies; `value_storage` and `spill_value` are gone, `emit_union_spill` keeps its shared temporary slot, `simd.odin:144` stores one type into a slot of another, and `spill_equal_operands` already uses `value_address`. `spill` always copies, so the large-value memcpy below remains: a large value may be a read-only constant global (`@.image.N` or `@.zero.N` from `const_operand`), which a drop must not be handed in place.): `value_storage` (containers.odin:927), `spill_value` (format.odin:617), `foreign_spill_operand` (abi.odin:514), `spill_equal_operands` (expr.odin:1961), `emit_discarded_temporary` (cleanup.odin:667), calls.odin:912/1306, expr.odin:1207, iteration.odin:205/255/264/630, simd.odin:144, and the `!is_large_value` branch at containers.odin:1347. For large values this also removes a needless 4 KiB+ memcpy in `emit_discarded_temporary` and `hold_temporary_value` (cleanup.odin:214). Saves about 30 lines.
6. **Delete the ~27 `branch(e, X)` calls that directly precede `place_label(e, X)`.** (Done in an earlier round; none remain.) `place_label` already branches (emit_llvm.odin:645-649). Sites: box.odin:160; calls.odin:355, 709, 1075, 1320; cleanup.odin:133, 248, 287, 538; containers.odin:651, 982, 1018, 1136; entry.odin:221; expr.odin:1093, 2148, 2161; format.odin:394, 414, 444, 468; iteration.odin:115; lifecycle.odin:54, 308, 609; stmt.odin:525; unwind.odin:420. If explicitness is preferred, rename `place_label` to say that it falls through. Saves about 27 lines.
7. **Track the current block label in `Function_State`.** (Done: `current_block`; `short_circuit_phis_name_their_own_blocks`.) The phis in `emit_short_circuit` (expr.odin:2142-2163) and `emit_cond_arm` (expr.odin:2188-2191) could then name their incoming block directly, instead of opening an empty `sc.entry`/`sc.rhs.exit`/`cond.*.exit` block just to have a name. That is about 2 to 3 empty blocks per `&&`, `||`, or `?:`, which survive at `-opt=none`. Saves about 10 lines and a lot of IR.
8. **Intern private constant globals.** (Done: `private_constant`, for the three constant sites; `equal_constants_share_one_global`.) `const_operand` (expr.odin:500), `store`'s `@.aggregate.N` (expr.odin:722), and `slice_literal_storage` (only its immutable form) create a new global at every use of the same large or imaged constant. `text_literal_global` already interns by text through `e.literals`. Keying a map on `type + initializer text` (or `type + value_type`) shrinks the IR and the `-opt=none` output; `unnamed_addr` only lets the optimizer merge them later. Folding all four sites into one `private_constant(e, prefix, type_text, init, align) -> name` also removes about 12 duplicated lines.

   Left after the review of `6b54a4d1`:
   - `private_constant` takes one `definition` string that each caller formats, and the callers disagree: `const_operand`'s includes the alignment and `store`'s `@.aggregate.` one does not, so the same constant reached both ways gets two globals. Its name takes the prefix of whichever site asked first, so a slice literal can come back as `@.image.N`. The signature above fixes both.
   - The mutable branch of `slice_literal_storage` and `large_zero` still write their own `claim_name` and `append`. `large_zeros` lives in `Function_State`, so every function that needs a large zero writes its own global, while `constants` is module-wide; moved to `Emitter`, one global per type would serve the module.
   - No test checks that two `[]mut T` literals of the same elements keep separate storage, the one sharing interning must not do. A phi whose arm diverges is covered only by `tests/run/diverging.loke`, not by an IR test.

### Per-file findings

#### src/emission_contract.odin
Verdict: clean and focused; it does what the architecture document says.
- **Simplify** (minor): in emission_contract.odin:152-158, `expected: Synth_Kind = slot == 0 ? .Clone : .Try_Clone` and the indexed literal array would read more plainly as two explicit checks. No real saving.

#### src/emit_llvm.odin
Verdict: good core plumbing. Function text is copied several times, and the instruction helpers are too few.
- **Data structure** (emit_llvm.odin:254-290, with unwind.odin:357-364 and 439-441): each function's text is copied 3 to 4 times. The body builder is stripped into a new builder (`unwind_finished_body`), header, prologue, and body are written into the header builder, `splice_prologue` searches for `"\nentry:\n"` and copies everything again, and the result is then written into the parent. Keep the header, prologue lines, and body as three separate pieces in `Function_Emission` and concatenate once at `end_function_emission`. That removes the string search and its failure path (`backend_fail` at line 280) and about 15 lines.
- **Simplify** (emit_llvm.odin:554-603): only `extract`, `insert`, `load`, `gep_*`, and `alloca` exist as result-returning helpers. Add `emit_value(e, format, ..args) -> string` (temp plus `"  %s = "` prefix), plus `icmp_zero`, `is_null`/`not_null`, `xor_true` (9 sites), and `combine_or`. That would shrink most of the ~197 `temp` + `sbprintfln` pairs by a line. `combine_and` (expr.odin:2128), `or_match` (stmt.odin:747), the OR chain in `emit_enum_from_int` (calls.odin:205-211), and the OR join in `guard_integer_conversion` (calls.odin:1223-1229) are the same fold written four times. Saves about 150 lines if applied backend-wide.
- **Structure** (emit_llvm.odin:43-45, 616-641): `place_align` is module-wide, but its keys are function-local temporaries. Move it into `Function_State` so it is dropped per function and cannot outlive its names.
- **Duplication** (emit_llvm.odin:302-343 vs names.odin:32-101): `emit_package_items` and `name_package_symbols` walk the same structure (files, `^Decl`, `^Item_Impl` members, `hoisted_procs`, `instances`) with the same template and test filters. One `for_each_emitted_proc(pkg, visit)` iterator would keep the two passes from drifting (`emit_package_items` already skips `omitted_with_test` for impl members while naming does not).

#### src/emit_llvm_expr.odin
Verdict: correct as far as I could check, but too large (see Top recommendation 4). Several small lowering patterns are copied within the file.
- **Duplication** (expr.odin:1055-1059, 1074-1077, 1117-1120): "start = gep(low), count = sub high, low, build slice" appears three times, and the low/high bounds code in `emit_c_pointer_slice` (1104-1117) re-implements `emit_slice_bounds` (1014-1029) with a different upper check. Add `emit_subrange(e, storage, element, data, low, high)` and give `emit_slice_bounds` an optional length. Saves about 12 lines.
- **Duplication** (expr.odin:1274-1277 vs 2232-2235): converting a `string` to a `string_view` is written twice, and there are 7 more "extract `STRING_DATA` / extract `STRING_LEN`" pairs (1612-1613, 1871-1874, 2417, iteration.odin:341-342, 689-690, containers.odin:1426-1427). `ptr_len_parts` (2389) already does this, since `STRING_DATA == SLICE_DATA` (asserted at runtime.odin:138). Use it everywhere and add `string_as_view(e, value)`. Saves about 15 lines.
- **Simplify** (expr.odin:491-503): `const_operand` calls `global_initializer` (which runs `const_needs_image`) and then calls `const_needs_image` again at 497. Return the "needs image" flag from `global_initializer`. A large zero also builds its whole initializer before being discarded at 494.
- **Duplication** (expr.odin:35-57 vs union.odin:25-48 and 52-62): `union_constant`, `union_storage_definition`, and `union_tag_member` each re-derive the same member layout (head, padding, niche, tag, tail). Have one `union_members(shape) -> []member` drive the type text, the constant text, and the tag index. Saves about 20 lines and removes a three-way agreement that is currently only implicit.
- **Data structure** (expr.odin:144-170): byte arrays (`[N]u8`/`[N]i8`) are spelled element by element (`i8 1, i8 2, …`), roughly 6 bytes of IR per byte. `write_byte_array_constant` (103) already emits `c"\XX…"`. Use it for non-mask `i8` arrays.
- **Simplify** (done: `union_tag_llvm`, Top recommendation 1) (expr.odin:2048, 2071): the union tag type is re-spelled locally; part of Top recommendation 1.
- **Structure** (expr.odin:2489-2523): `emit_alloc_check`, `emit_text_call_slot`, `emit_text_allocating_call`, and `emit_text_optional_ok` are generic "runtime call writing an out-slot, status `i32`" helpers that containers re-implements (`branch_on_failure`/`emit_container_policy_failure`, containers.odin:657-667, 1125-1138). Move one status helper to runtime.odin.

#### src/emit_llvm_calls.odin
Verdict: the argument binding is intricate but coherent. Conversions and union construction are mixed in with calls.
- **Structure** (calls.odin:1114-1323): `emit_value_conversion`, `guard_integer_conversion`, `guard_null_reference`, `guard_float_to_int`, `emit_union_construct`, and `emit_union_as` are about 210 lines of conversions, not calls. They would sit better with expr's implicit conversions, or in a small `emit_llvm_convert.odin`.
- **Simplify** (calls.odin:1206, 1282): `predicate := lanes ? fmt.aprintf("<%d x i1>", …) : "i1"` is computed twice; `Int_Form.mask` (expr.odin:1716-1721) already carries it. Build the conversion guards on `Int_Form` (`scalar_int_form`/`lane_int_form`) and use `form_any` instead of the hand-written `if lanes { simd_any_lane }`. Saves about 8 lines.
- **Simplify** (done) (calls.odin:358-359): a hand-written `load` duplicates `load(e, CONTAINER_TYPE, header)`.
- **Structure / robustness** (done: `backend_fail` when a foreign call owes argument or pack drops) (calls.odin:1063-1065): `emit_bound_call` returns before `emit_refusal_branch` and `emit_after_call` for a foreign convention, so any `argument_cleanups` would never be dropped and their entries would stay in `e.held`. Today this is safe only because design.md rules managed types out of foreign signatures. Add an assertion (`backend_fail` if `len(call.argument_cleanups) > 0 || call.pack_cleanup.kind != .None`) so a later relaxation of the foreign-ABI-safe list fails loudly.
- **Simplify** (no change needed, as the finding says) (calls.odin:973-979): spilling a large non-`%` operand is a special case of `store`'s own constant handling plus `temporary_slot`. Fine as is; noted only because `operand[0]` would panic on an empty operand string (no producer of `""` found, so not a bug).

#### src/emit_llvm_stmt.odin
Verdict: clear. The two switch lowerings share their skeleton well through `switch_labels`.
- **Duplication** (done: `or_match` went with the union `switch` of Top recommendation 1) (stmt.odin:747-754): `or_match` duplicates the OR fold (see emit_llvm.odin finding).
- **Simplify** (done; `symbol_place` is package-private now) (stmt.odin:153, 157): `e.names[task.result]` and `e.names[task.scope]` are indexed directly, so a missing entry silently writes `ptr ` with an empty operand. Use `symbol_place` (expr.odin:815, currently file-private), which fails the contract instead.
- **Simplify** (stmt.odin:920-922): use `combine_and`.

#### src/emit_llvm_cleanup.odin
Verdict: sound design. Two hot-path inefficiencies.
- **Data structure** (done in part: `temporaries_owed` returns early when nothing is owed; when something is, the list is still cloned) (cleanup.odin:392-416): `drain_temporaries` runs at every `pop_temporaries`, which is every statement and condition. Each time it allocates `owed` and `slice.clone(e.held)` in the temp allocator, sorts, then clears and re-appends `held`, even when nothing is owed. Return early when `len(e.held) == first_held` and every frame from `frame` up is empty. Clone `held` only if something is actually dropped.
- **Simplify** (not done: see Top recommendation 5; a large value may be a read-only constant global) (cleanup.odin:212-219, 659-670): `hold_temporary_value` and `emit_discarded_temporary` copy a large value into a new alloca although a large value is already a private address. Use the `spill` helper from Top recommendation 5.
- **Data structure** (no change needed, as the finding says) (cleanup.odin:187-197): `release_held` scans linearly by `order`. Fine for current sizes; leave it.

#### src/emit_llvm_unwind.odin
Verdict: inventive and well documented. The state swap in the thunk is fragile.
- **Structure** (unwind.odin:376-384, 442): `emit_unwind_thunk` keeps the parent's whole `Function_State` and then resets a hand-picked list of fields (cleanups, temporaries, prologue, large_*, stack_saves). Everything else (`held`, `loop`, `conditional`, `param_values`, `result_*`, `lent_to_calls`) silently carries over, which is why emit_llvm.odin:155-156 has to warn maintainers. Invert it: start from `Function_State{}` and copy in only what replay needs (`unwind`, `copying`, `copy_cpu`, `large_zeros`, `abi_*`).
- **Structure** (unwind.odin:398 and 412-422): the thunk rebinds `e.names[binding.symbol]` to its own temporaries and never restores them, so after the thunk `e.names` points at names from another function. This is harmless today because the parent body is already finished, but it should be restored or kept in a thunk-local overlay.
- **Data structure** (unwind.odin:427-441, 476-508): `mark_replay_reads` finds which locals the thunk reads by scanning the generated text for `%names`. Recording a read when replay resolves a symbol (an overlay map consulted by `symbol_place`, `emit_expr_at`'s ident case, and the `.Local` arm at 470) would be exact and would remove the scanner and `llvm_name_char`, about 35 lines. Unverified: there may be other lookup paths into `e.names` during replay that would also need the hook.

#### src/emit_llvm_lifecycle.odin
Verdict: thorough, with two near-copies and hand-rolled headers.
- **Duplication** (lifecycle.odin:133-136 and 484-487): `emit_synth_try_clone` and `emit_synth_clone` spell their `define` line by hand, and `open_synth_function(e, symbol, name)` (emit_llvm.odin:230) produces the same text (receiver plus a `ptr %arg1` allocator parameter, with sret). The same applies to `emit_synth_iter` (iteration.odin:647-650). Saves about 9 lines.
- **Duplication** (done: Top recommendation 1) (lifecycle.odin:596-611, 626-655): two of the 7 tag-dispatch chains (Top recommendation 1).
- **Duplication** (lifecycle.odin:461-468 vs 14-28 and 72-83): "alloca destination, `emit_try_clone_into`, invert ok" appears in `emit_part_clone`, in `emit_clone_value`'s container branch, and again in `emit_synth_try_clone`'s intrinsic branch (160-166). Add `try_clone_value(e, type, value_or_src, allocator) -> (cloned, failed)`. Saves about 15 lines.
- **Duplication** (lifecycle.odin:278-292, 383-388, 406-416, and format.odin:541-547): reading and range-checking an `@(initialized)` count is spelled again in `emit_format_struct`, without `emit_prefix_count`'s helper because that one is file-private. Make `emit_prefix_count` package-private and reuse it.

#### src/emit_llvm_containers.odin
Verdict: a large file of mixed concerns; individual bodies are correct.
- **Bug (code size)** (done: bug 4) (containers.odin:1414-1421): fixed arrays are unrolled whenever hashed; see Top recommendation 2.
- **Structure** (containers.odin:336-392): `Thunk_Emission`, `begin_thunk`, `end_thunk`, and `container_thunk` are the backend's generic memoised private-function helper. Box uses it for drop and clone (box.odin:140, 180), and sort_by reimplements its prelude (273-290). Move them to emit_llvm.odin as `memo_thunk`, and rename `e.container_thunks` to match.
- **Structure** (containers.odin:1342-1471): hashing belongs next to equality (Top recommendation 4).
- **Structure** (containers.odin:669-740): the `mem.Arena`/`mem.Scratch` provider bodies have nothing to do with containers. Move them to a small `emit_llvm_provider.odin`, or into runtime.odin next to the provider initializer.
- **Duplication** (containers.odin:148-152, 179-181 vs expr.odin:970-975): "icmp uge/ugt index, count; `panic_if` bounds" appears three times. Add a shared `emit_bounds_check(e, index, count, inclusive, message)`.
- **Duplication** (containers.odin:1038-1039, 1067-1069, 1109-1110, 1156-1158, 1279-1281): every `map_find`/`map_entry` call is followed by "icmp eq/ne ptr, null". Return the presence `i1` from `emit_map_find` and `emit_map_entry`.
- **Duplication** (done) (containers.odin:1197-1217): `emit_map_slot_result` and `emit_map_slot_failure` emit `ret` by hand with their own `emit_unwind_pop`, duplicating `emit_ret` (calls.odin:1355), which already pops. Use `emit_ret(e, result_type, …)`.

#### src/emit_llvm_iteration.odin
Verdict: clean. The in-place `foreach` lowerings and the synthesized `next` bodies duplicate each other's stepping.
- **Duplication** (iteration.odin:367-396 vs 819-857 vs format.odin:474-502): three map slot walks each allocate `key_out`/`value_out`, call `emit_map_scan`, and compare the result to 0. Add `map_scan_step(e, table, ops, cursor) -> (more, key, value)`. Saves about 15 lines.
- **Duplication** (iteration.odin:337-362 vs 861-893): text `foreach` and `emit_synth_text_next` both do "at_end ≥ length, decode, advance offset". Share a `text_step` helper. Saves about 8 lines.
- **Duplication** (iteration.odin:580-588 vs adapters.odin:39-47): "call `next`, test `.some`, spill, read the payload" appears twice. Add `emit_next_call(e, next_symbol, iterator) -> (ok, payload)`.

#### src/emit_llvm_adapters.odin
Verdict: small and fine, but missing the file header comment every sibling has, and it uses magic field indices.
- **Simplify** (done: `ADAPTER_SOURCE`, `ITER_ADAPTER_INNER` and `ITER_ADAPTER_INDEX`, used where the checker builds the records too; the file has a header now) (adapters.odin:20, 40, 51): the adapter record's fields are read as raw `0`/`1`, whereas iterate.odin names every other iterator layout (`ITER_ARRAY_DATA`, …). Add `ADAPTER_SOURCE`/`ADAPTER_INDEX` beside them.
- **Duplication** (adapters.odin:59-60): writes the stop label and `emit_ret(zeroinitializer)` by hand, which is `close_synth_next` (iteration.odin:714) minus the brace. Use it and drop the `}` at 62.
- **Structure**: the architecture document already lists this file together with iteration. At 86 lines it can be merged into `emit_llvm_iteration.odin`.

#### src/emit_llvm_abi.odin
Verdict: the Win64 classification is careful. Declaration discovery parses text.
- **Structure** (done: the declared-name set of Top recommendation 3; the four names the compiler defines afterward stay listed) (abi.odin:34-50): `emit_foreign_declarations` re-reads `e.b` for `declare` lines and hard-codes 3 to 5 names that are declared or defined elsewhere (`program_tls_cleanup`, `sink_write`, `write_std`, `program_init`, `wmain`). A table of declared runtime names (Top recommendation 3) plus a set filled by `open_function`/entry emitters would replace this, about 15 lines.
- **Simplify** (abi.odin:625-645): `foreign_call_result`'s `.Indirect` case calls `load_place` on a fresh private `sret` alloca, which copies a large result into another slot. Use `load_temporary(e, result, sret)`.
- **Duplication** (abi.odin:528-533 vs 637-642, 471-475 vs 502-505): the register-integer store/load round trip is written four times (parameter, return, argument, result). Add `reg_int_reinterpret(e, type, value, to_int: bool)`. Saves about 10 lines.

#### src/emit_llvm_union.odin
Verdict: compact and correct.
- **Duplication** (union.odin:25-62 vs expr.odin:35-57): see the expr finding; one member walker for type, constant, and tag index.
- **Duplication** (done: Top recommendation 1) (union.odin:102-115): the widening tag chain (Top recommendation 1). It already ends in `unreachable`, which is exactly a `switch` with an unreachable default.

#### src/emit_llvm_runtime.odin
Verdict: a reasonable home for runtime declarations and metadata. Its declaration lists should be data.
- **Simplify** (done: Top recommendation 3) (runtime.odin:58-120, 172-190): Top recommendation 3.
- **Data structure** (runtime.odin:259-265): `thread_local_owners` scans `pkg.files` for every thread-local symbol to find its file index, O(symbols × files). Compute a per-package `map[file]int` once. Minor.
- **Duplication** (done in part: `private_constant`; Top recommendation 8 lists what is left) (runtime.odin:150-155, 567-569, expr.odin:500-501, 514-515, 578-582, 722-723): six "claim `@.<prefix>.<len(e.globals)>`, append a private global" sites. Fold them into `private_global(e, prefix, linkage, type, init, align)` (Top recommendation 8).
- **Simplify** (done: a `#partial switch`. No `#assert` was added: each kind picks its own constant, so nothing relies on the three being equal) (runtime.odin:717-718): the nested ternary choosing the length field would read more plainly as a `#partial switch`, and it is the only place that relies on `CONTAINER_LEN == STRING_LEN == SLICE_LEN` without asserting it. Add the `#assert`.

#### src/emit_llvm_format.odin
Verdict: good. It uses chains where `switch` fits.
- **Duplication** (done in part: Top recommendation 1 for unions; `emit_format_enum` still compares one member at a time) (format.odin:370-396 and 419-446): the union and enum formatting chains (Top recommendation 1). An enum's `switch` also handles non-contiguous members, which the comment at 418 cites as the reason for the chain.
- **Duplication** (done: `spill`) (format.odin:617-621): `spill_value` is one of the spill copies (Top recommendation 5).
- **Simplify** (format.odin:531-539): re-copying an under-aligned field duplicates `emit_viewed_address`'s check (expr.odin:1221-1225). Extract `aligned_copy_if_needed(e, type, address)`.
- **Structure** (done in `c92d8811`: declared with the runtime entries) (format.odin:570-595): `emit_sink_bridge` writes its own `declare` of `@loke_rt_v1_write_std`, which `emit_foreign_declarations` then has to know about through a hard-coded `seen` entry. Keep it in the runtime declaration table.

#### src/emit_llvm_debug.odin
Verdict: a self-contained marker post-pass; works, with one fragile seam.
- **Structure** (debug.odin:157-159): witness globals are recognised by the line prefix `@loke.w.` and numbered by count, which relies on `emit_witnesses` writing them in `witness_order` and on nothing else starting that way. Emit a `;dbg.witness N` marker like the other markers. That keeps the post-pass purely marker-driven and removes the counter.
- **Data structure** (debug.odin:115-166): the whole module is copied line by line, with one `fmt.sbprintfln("%s, !dbg !%d")` per instruction. Acceptable for `-g` builds. Writing `line`, then the literal `", !dbg !"`, then the number without `fmt` would be noticeably faster on large modules (unverified magnitude).

#### src/emit_llvm_dispatch.odin
Verdict: small, clear, correct.
- **Simplify** (done) (dispatch.odin:91-100): passing `loke_param_list`'s text (with `nonnull` attributes) as call arguments works because call sites accept parameter attributes; a short comment would stop a reader from "fixing" it.

#### src/emit_llvm_entry.odin
Verdict: fine.
- **Simplify** (done) (entry.odin:211-215): the logger factory is called with a hand-built `call %s %s()`. Use `emit_call_result(e, factory.result, …)` so a large factory result would still follow the sret ABI.

#### src/emit_llvm_box.odin
Verdict: fine.
- **Duplication** (box.odin:83-86 vs 207-210): "take refusal, drop payload, restore refusal" appears twice; extract `drop_keeping_refusal(e, type, place, allocator)`.

#### src/emit_llvm_erased.odin
Verdict: fine.
- **Duplication** (erased.odin:160-171): `open_forwarding_function` is a fourth `define` header builder, alongside `open_synth_function`, `open_synth_receiver`, and `loke_param_list` in emit_llvm.odin. One `function_header(e, linkage, name, result, inout, params: []string)` would serve them all.

#### src/emit_llvm_atomics.odin
Verdict: fine.
- **Simplify** (atomics.odin:161-204): each 128-bit fallback spills its operands by hand (alloca + `store`); the `spill` helper shortens these by about 6 lines.

#### src/emit_llvm_simd.odin
Verdict: fine; nothing notable.

#### src/emit_llvm_math.odin
Verdict: fine.
- **Simplify** (math.odin:42-45 and 130-135): resizing an integer to or from `int` is spelled out twice; a shared `resize_int(e, value, from_bits, to_bits, signed)` would also serve `widen_to_i64` (expr.odin:1140) and `emit_hash_bits` (containers.odin:1458-1468).

#### src/emit_llvm_names.odin
Verdict: fine.
- **Data structure** (done: `Emitter.next_suffix`) (names.odin:107-114): `claim_name` probes `base.1`, `base.2`, … linearly, which is quadratic for a frequently repeated base such as `@loke.entry` (from quoted exports). Keep a `map[string]int` of the next suffix per base. Minor.

#### src/emit_llvm_toolchain.odin
Verdict: fine.
- **Duplication** (not done: each run reports its own code and wording, L0402/L0403, L0633, L0632 or an unreported reason, so `run_tool` would share only the two-way test) (toolchain.odin:98-106 vs 185-211, layout_probe.odin:280-287, runtime_cache.odin:233-243): four subprocess runs each map `err` to "cannot run" and `exit_code` to "failed: stderr". Add `run_tool(c, command, what) -> (stdout, stderr, ok)`. Saves about 12 lines.

#### src/emit_llvm_runtime_cache.odin
Verdict: fine; the concurrency and manifest handling are careful.

#### src/emit_llvm_coff.odin
Verdict: fine; a defensive, bounded parser.

#### src/emit_llvm_layout_probe.odin
Verdict: fine.
- **Structure** (done: the probe restores the setting after its link; `-check-layout` ends the run anyway) (layout_probe.odin:271): `c.debug_info = false` mutates compiler state as a side effect of `-check-layout`. Pass it as a parameter to `link` instead.

### Cross-file duplication

| Pattern | Sites | Proposal |
| --- | --- | --- |
| Union-tag dispatch chain | union.odin:102, lifecycle.odin:596, 626, expr.odin:2066, containers.odin:1383, format.odin:378, stmt.odin:787 (+ enum chain format.odin:425) | One `switch`-based helper; `union_tag_llvm(shape)` for the 9 `fmt.aprintf("i%d", tag_bytes*8)` sites |
| Spill to slot (alloca + store) | containers.odin:927, format.odin:617, abi.odin:514, expr.odin:1207, 1961, cleanup.odin:212, 667, calls.odin:912, 1306, iteration.odin:205, 255, 264, 630, simd.odin:144, containers.odin:1347, atomics.odin:162-199 | `spill(e, type, value)` with large-value passthrough |
| Runtime `declare` lists | runtime.odin:58-120, 172-190, containers.odin:15-41, atomics.odin:31-41, format.odin:570; consumed by abi.odin:34-50 text scan | Table + declared-name set |
| Private constant globals | expr.odin:500, 514, 578, 722, runtime.odin:150, 567 | `private_global` helper with interning |
| `define` header builders | emit_llvm.odin:223, 230, 379; erased.odin:160; lifecycle.odin:133, 484; iteration.odin:647; format.odin:628 | One `function_header` |
| Map slot walk | iteration.odin:367, 819; format.odin:474 | `map_scan_step` |
| `next` call + `.some` test + payload | iteration.odin:580-588; adapters.odin:39-47 | `emit_next_call` |
| `i1` OR/AND folds | expr.odin:2128; stmt.odin:747, 920; calls.odin:205, 1223; iteration.odin:36-38 | `combine_and`/`combine_or` in emit_llvm.odin |
| Status `i32` → failure branch | expr.odin:2492-2496, 2550-2551; calls.odin:339-342; containers.odin:904-905, 1125-1132 | One `status_failed`/`branch_on_failure` in runtime.odin |
| Bounds checks (uge/ugt + `panic_if`) | expr.odin:970-975, 1023-1027, 1113-1117, 2720-2722; containers.odin:148-152, 179-181 | `emit_bounds_check` |
| Register-int ABI round trip | abi.odin:471-475, 502-505, 528-533, 637-642 | `reg_int_reinterpret` |
| Memoised thunk prelude | containers.odin:336-392 (used by box.odin:140, 180), containers.odin:273-290 (sort_by, re-implemented) | Move to emit_llvm.odin as `memo_thunk` |
| `@(initialized)` count read + check | lifecycle.odin:278-292; format.odin:541-545; expr.odin:2029-2032 | Package-private `emit_prefix_count` |
| Subprocess run + error mapping (not done) | toolchain.odin:98-106, 185-211; layout_probe.odin:280-287; runtime_cache.odin:233-243 | `run_tool` |
| Redundant `branch` before `place_label` (done) | 27 sites (listed in Top recommendation 6) | Delete |

Estimated total saving if all proposals are applied: roughly 450 to 550 lines (about 3%), plus smaller IR at `-opt=none` from recommendations 1, 2, 7, and 8.

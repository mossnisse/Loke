# Compiler source audit (2026-11-18)

This audit covers the Odin production sources under `src/` at `af7fe93a`. The scope includes the nested subprocess package, `test_runner.odin`, and `test_procedures.odin`. The 15 `*_test.odin` files were excluded from the file-by-file review. Each production file is assigned to a separate reviewer, with up to three file reviews running concurrently. The review considers correctness, necessity, dead code, simpler implementations, choice of data structures and algorithms, duplicate logic, and ownership across compiler phases.

## Resolution

The findings below were worked through after the audit. The file reviews keep
their original text, so a line number or a "currently" in one describes
`af7fe93a`.

**Fixed.**

- Atomics: `store`, `exchange` and `compare_exchange` retain the borrow they
  write and a loaded value borrows what the atomic held, with an atomic that
  can hold a borrow a retention destination through a read-only `^`
  ([Retaining a borrow](design.md#retaining-a-borrow)). The audit's probe
  covered the store into process-lifetime storage; a local atomic outliving
  what it points at and a returned `load()` were the same hole. The redundant
  `require_const` in ordering checks is gone.
- Foreign ABI: only an `Option` is a nullable C pointer, as
  [Foreign-ABI-safe types](design.md#foreign-abi-safe-types) says, which removes
  the over-aligned union and answers the recursive one; a union still resolving
  its variants defers as a struct does. `param_mode_is_pointer` moved beside
  `param_mode_at`.
- File-scope `when`: a capture literal's written initializers are children of
  the shared expression walk, and the dependency walk reads its procedure with
  the captures bound. `expr_children` visits a conditional's value before its
  condition.
- Attributes: a NUL in `link_name` is `L0608`, and the string-literal test is
  one predicate.
- Bootstrap: a metadata record with `@(align=N)` or `@(packed)` is `L0704`, and
  the enum check reads `reflect.enum_field_names`.
- Provenance driver: the instantiation note covers `check_declared_escape`, and
  the summary worklist queues only bodies already stale.
- Borrow report: the allocator control-block message merges the live slot's
  precision before choosing "would" or "may".
- Smaller ones: the typed `clone_impl` entry, direct writes in `ast_dump.odin`
  and its foreign-block arm, one division in `decimal_to_float`, temporary
  digits and an in-place sign in `bi_parse_int_literal`, one loop in
  `run_loaded_below_event`, `set_join` in `record_summary_dependencies`, and
  `paths_overlap_joined` over `paths_overlap`.

**Declined.**

- `attributes_are_public` and `written_is_public` each scan a short list; the
  split keeps the checker's conflict diagnostic apart from the syntax-only rule.
- `walk_names` asks whether any name matches, so the order of its key pass
  changes no answer.
- `interned_rows_make` would trade one allocation per solve for more code.
- A shared iterator for `prov_slots_overlap` and `view_elements_apart` would be
  longer than the two loops it replaces.

**Open.** The single ordered variadic operand list, alias-view lifetime, hashed
wide-integer membership, and the solver's measurement-first hypotheses are in
[open-questions.md](open-questions.md#compiler-source-audit-follow-ups-2026-11-18).
Two divergences found while fixing the atomics are in
[known-gaps.md](known-gaps.md#gaps).
## File-by-file reviews

Reviewed 14 of 187 production files.

### `src/abi.odin`

This file shares foreign-signature validation and Win64 argument classification between the checker and emitter. The per-query map tracks active and completed record and array visits, which avoids expanding the same shared type repeatedly.

- **Correctness.** `abi_walk` (line 232) accepts an explicitly over-aligned nullable union based on its pointer payload alone. `@(align=16) Nullable :: union { none, some: ^int }` with `@(export) accept :: proc "c" (value: Nullable) -> Nullable { return value; }` compiles and emits an `sret` result and an indirect argument. The documented nullable-pointer exception promises the same C pointer representation as the payload. Restrict it to the documented `Option` cases or require equal size and alignment if equivalent unions are intended. [ABI validation and classification](../src/abi.odin), [Union layout](../src/union.odin), [Foreign-ABI-safe types](design.md#foreign-abi-safe-types)
- **Correctness.** `abi_walk` (lines 180 and 230) waits for a struct's fields, then classifies unions even while their variants are being resolved. `Nullable :: union { none, some: proc "c" (value: Nullable) }` reports `L0619` on the callback because the variant list is still empty. The same completed shape is accepted by the checker elsewhere. Defer both kinds of incomplete records if pointer-shaped user unions remain eligible for this ABI. [ABI validation](../src/abi.odin), [Variant resolution](../src/union.odin)
- **Boundary.** `param_mode_is_pointer` (line 13) also drives ordinary Loke call lowering and normalized provenance. Move this shared parameter-mode query beside `param_mode_at` so the foreign ABI file owns `foreign_param_is_pointer` and Win64 classification. [ABI helper](../src/abi.odin), [Semantic callable queries](../src/semantic.odin), [Provenance input](../src/provenance_input.odin), [Call lowering](../src/emit_llvm_calls.odin)

### `src/ast_clone.odin`

Deep syntax cloning gives generic instantiation and static expansion independent nodes, preserves written data, and clears checker annotations while honoring capture and alias rewrites.

- **Performance.** `new_clone` (line 90) and the subsidiary allocations put overload-ranking alias views in the semantic arena. `compare_generic_specificity` rebuilds both signatures’ views for each comparison, and `pattern_relations` only inspects them synchronously, so those transient trees accumulate for the life of the compilation. Give the alias-view clone path a scratch allocation lifetime, preserving its allocator through nested alias expansion and substitution. Measure an alias-heavy overload workload before changing the path. [Cloner](../src/ast_clone.odin), [alias views](../src/generic_alias.odin), [ranking](../src/generic.odin)
- **Simplify.** `clone_item` (line 57) accepts and returns the full `Item` union, but its sole external caller passes a `^Item_Impl` and immediately asserts the returned variant. Give that entry point a `^Item_Impl` parameter and return type, share it with the statement case at line 508, and keep the general item switch private to cloning member lists. The signature would state the actual invariant and remove both downcasts. [Cloner](../src/ast_clone.odin), [generic implementation installation](../src/generic_impl.odin)

### `src/ast_dump.odin`

Serializes the bounded, pre-check syntax tree for `-dump-ast`, parser goldens, and migration equivalence checks, so the exhaustive switches and stable output serve three live callers.

- **Simplify** `dump_indent` (line 82) and `dump_child` (line 446) write fixed spaces through Odin's variadic `fmt.sbprint`. Use `strings.write_string` for the indentation unit and `strings.write_byte` for the child separator so both paths write directly to the builder. Keep the golden output byte-for-byte. [AST dump](../src/ast_dump.odin)
- **Simplify** The foreign-block arm of `dump_item` (line 150) widens each `^Decl` member to `Item` and immediately switches it back to `^Decl`. Call `dump_decl` directly so the traversal expresses the AST field's declared shape. [AST dump](../src/ast_dump.odin), [AST definitions](../src/ast.odin)

### `src/ast.odin`

The compiler uses one tagged syntax tree with checked annotations, keeping the same node identities across parsing, checking, analysis, and lowering.

- **Correctness** `expr_children` (1539, composite branch at 1598) walks synthesized composite fields and omits a capture literal's written initializers. `unresolved_name` (437, composite branch at 442) has its own composite traversal with the same omission. A file-scope `when (choose())` can consequently check `choose` too early if its body contains `get := proc() -> int capture(n = LATER) { return n; };` and a subsequent `when (true)` declares `LATER`. A focused `lokec -doc` probe reported L0315 and L0344, then succeeded with the constant declared outside the later branch. Give capture literals a shared expression-child path for their written initializers and have the `when` walker handle the capture procedure signature and body with the captures bound in its own scope. [AST walk](../src/ast.odin) [Dependency walk](../src/select.odin) [When statement](design.md#when-statement)
- **Simplify** `Expr_Call` (277) splits checked variadic operands across three slices that must remain synchronized, and `Call_Pack_Cursor` (806) rebuilds their order. `bind_variadic_arguments` allocates three buffers at the total operand capacity, and LLVM's two pack loops reconstruct the order again. Store one ordered slice of checked `(expression, spread)` operands, retain the ordinary bound expression for forwarded slices, and count spread or scalar operands where sizing needs it. Preserve ordered evaluation and the passes that filter to only one operand kind. [AST pack](../src/ast.odin) [Call binding](../src/check_calls.odin) [LLVM pack](../src/emit_llvm_calls.odin)
- **Simplify** `expr_children` documents written order at 1534, but visits the condition before the then expression at 1594, and `walk_names` (1508) processes ambiguous composite keys in a preliminary pass. Early-exit callers can therefore report a later name first. Visit the then expression first and make composite key treatment an option of the single per-element traversal, preserving the distinct ambiguous-key policy for type-syntax callers. [AST walk](../src/ast.odin) [When dependency diagnostic](../src/select.odin)

### `src/atomics.odin`

Atomic checking owns operand types, operation arity, and valid memory orderings, then records the checked call for LLVM to choose a native width or the 128-bit runtime path.

- **Correctness.** `check_atomic_place` (line 138) correctly allows pointer-valued atomic cells, but the provenance walk for atomic builtins (line 131) only walks their arguments. `store`, `exchange`, and a potentially successful `compare_exchange` can retain a pointer without recording that retention against the cell's destination. The workspace `lokec.exe` accepted the probe below with `-emit-ll`, even though the process-lifetime cell can outlive the local it now points to. A plain process-static `Option(^int)` and equivalent assignment were rejected with L0647. Model the possible retention of the value operand in the destination for pointer-bearing stores, including the desired operand on compare-exchange. [Atomic operands](../src/atomics.odin), [atomic provenance](../src/provenance_builtins.odin), [retaining a borrow](design.md#retaining-a-borrow)

  ```loke
  package main;
  import "core:sync";

  cell: static sync.Atomic(Option(^int)) = {};
  publish :: proc() {
      value := 42;
      cell.store(.some(&value));
  }
  main :: proc() { publish(); }
  ```

- **Delete.** In `check_atomic_order` (line 193), the `require_const` call and its failure branch are redundant. The preceding successful `check_value_expr` establishes a typed expression, then `is_const_expr` establishes `base_is_const`. `require_const` immediately returns the cached value under those conditions. Read `expr_base(argument).const_value` after the constant check, retaining the atomic-specific diagnostic and the enum-range validation. [Atomic ordering](../src/atomics.odin), [constant predicate](../src/check_expr.odin), [constant evaluator](../src/eval.odin)

### `src/attributes.odin`

Centralizes attribute position, scope, and value-shape checks and records semantic metadata for feature-specific consumers. The allocation-free lookup and enum bitsets suit the small, fixed vocabulary.

- **Correctness.** `validate_attribute_list` (lines 218–222) checks that the decoded `link_name` is nonempty but accepts a decoded NUL. Compiling `@(export, link_name="n\x00m") f :: proc "c" () {}` in `package main` with `-build-mode=obj -emit-ll` emitted `@"n\00m"`. Clang rejected that IR with “NUL character is not allowed in names.” Reject NUL beside the empty-name check so the diagnostic points to the declaration for both exports and foreign imports. The probe used the installed compiler at `efc26bcb7`, whose attribute checker matches the audited revision. [Attribute validation](../src/attributes.odin), [foreign names](../src/foreign.odin), [LLVM name lowering](../src/emit_llvm_abi.odin)
- **Simplify.** `attributes_are_public` (line 543) scans for `public` and `private`, then `written_is_public` (line 556) repeats the declaration-attribute checks. Resolve the two flags once and use the same precedence expression for checked declarations and syntax-only API extraction. Preserve the conflict diagnostic in the checker and the enclosing foreign block or package defaults. [Visibility helpers](../src/attributes.odin), [foreign-member visibility](../src/foreign.odin), [API extraction](../src/doc.odin)
- **Duplicate.** The `.Value_Required` branch in `validate_attribute_list` (lines 211–223) repeats the `Expr_Literal` and `.String`/`.Raw_String` classification in `attribute_string_text` (line 492). Have both use one syntax predicate and keep decoding at the points that consume text, so ordinary shape validation adds no allocation for escaped strings. [String-attribute checks](../src/attributes.odin), [string decoding](../src/lexer.odin)

### `src/bigint.odin`

This is the arithmetic and allocation boundary between Odin's arbitrary-precision library and Loke's exact constant folding, fixed-width integer operations, and bounded compile-time evaluator.

- **Performance.** `Integer_Set` and `integer_set_add` (lines 388 and 398) switch from hashed membership to an exact linear scan for every value outside `i64`. A generated `u64` switch with thousands of distinct high-bit constants takes quadratic duplicate-checking work. Use a single map keyed by the normalized used digits and sign, with the borrowed digits valid for the checker's set lifetime. This keeps equality exact for out-of-range enum members during error recovery as well. Check the enum switch's companion member index for the same width assumption. [Integer set](../src/bigint.odin), [Switch checking](../src/switch.odin), [Enum members](../src/enums.odin)
- **Duplicate.** The private schoolbook wrappers at lines 208 and 217 each run the complete division. `decimal_to_float` calls both with identical operands when rounding a negative exponent, so a long decimal literal pays for two divisions. Route the wrappers through one optional-output division routine and request both outputs in the conversion. Keep the existing schoolbook workaround and the quotient/remainder behavior for a numerator whose magnitude is smaller than the divisor. [Division](../src/bigint.odin), [Decimal conversion](../src/const_float.odin)
- **Simplify.** `bi_parse_int_literal` (line 94) strips underscores using the result allocator, then creates a second integer to apply a minus sign. Valid separated literals keep the normalized spelling in the semantic arena, and a negative `-define` keeps both integer magnitudes there. Put normalized digits in temporary storage, set the parsed nonzero result's sign in place, and settle the sole result through the existing evaluator-storage helper. Preserve full-string digit validation because Odin's parser accepts some trailing characters. [Integer parsing](../src/bigint.odin), [Build option parsing](../src/build_config.odin)

### `src/bootstrap.odin`

Bootstrap binds standard runtime declarations into the predeclared namespace and validates metadata types before their checked IDs reach LLVM lowering.

- **Correctness.** `runtime_layout_matches` (line 252) validates fields and enum values while accepting record attributes that change the LLVM storage shape. In the existing replacement-runtime layout fixture, restoring the documented field order and `Box` variant and adding `@(align=16)` to `Type_Info` made `-emit-ll` succeed. LLVM declares a ninth field `[0 x i128]` for alignment, and `record_constant` emits an initializer with eight fields. Reject metadata record layouts that the lowering cannot initialize, or make the metadata constant emitter use the same storage representation as its type declaration. [Bootstrap validation](../src/bootstrap.odin), [LLVM struct definitions](../src/emit_llvm_abi.odin), [Metadata initializers](../src/emit_llvm_type_info.odin), [Replacement runtime fixture](../tests/pkg_err/runtime_layout/vendor_base/runtime/runtime.loke)
- **Simplify.** `runtime_enum_matches` (line 236) formats each Odin enum value through `fmt.tprint` and interns the formatted name into the compilation. Use `reflect.enum_field_names(E)`, already used by the compiler, and compare each declared name with `identifier_text(c, sym.name)`. Keep the ordinal check to preserve the runtime contract. [Enum validation](../src/bootstrap.odin), [Existing Odin reflection usage](../src/build_config.odin)

### `src/borrow_loaded_below.odin`

The borrow solver uses interned bit rows and intersection at joins to track which reads are below the current value of a cursor on every path, so a cursor step can be distinguished from a competing access.

- **Performance.** `loaded_below_make` (lines 51–60) allocates the per-slot row handles, row interner, and clear cache before returning for a body with zero eligible anchors. `solve_links_held` still snapshots, compares, and joins this all-zero table for each block. Return before allocating the rows, leaving `held` empty so the shared block-table primitives have no pages to process. Keep the anchor array as initialized or short-circuit `loaded_below` before indexing it. [Allocation](../src/borrow_loaded_below.odin), [solver loop](../src/borrow.odin), [block-table primitives](../src/borrow_tables.odin)
- **Simplify.** `run_loaded_below_event` (lines 187–204) invalidates each `event.replaces` slot with the same loop in two branches. Use one whole-table clear condition for `.Rearrange` or a `.Publish` with nonempty `sources` whose stored type may relink a read, then run a single replacement loop for the remaining cases. This preserves the lazy relink check for a source-free publication. [Event transfer](../src/borrow_loaded_below.odin)

### `src/borrow_program.odin`

Orchestrates whole-program provenance, growing result summaries over direct and newly discovered callback dependencies before running per-body diagnostics with a disposable graph.

- **Correctness.** `analyze_program_provenance` (lines 24–27) calls `check_declared_escape` after the instance-note defer within `analyze_provenance` (line 189) has already run. A fresh `lokec -doc` build reported L0644 without an instantiation location for `pick :: proc(input: []$T, @(escape=none) scratch: []T) -> []T { return scratch; }` called with two `[]int` slices. Put the defer around both per-body checks, preserving the solver's arena cleanup. The diagnostic will identify the call that instantiated the failing declaration. [Provenance driver](../src/borrow_program.odin), [Instantiation notes](../src/generic.odin)
- **Simplify.** `settle_result_summaries` (lines 61–86) enqueues every clean body after its first visit, although the first pop skips any body whose dependencies have stayed unchanged. Register reverse edges and enqueue only the bodies already stale. Keep the dequeue check for later wakes and keep registration after each revisit, since a newly resolved callback can extend the graph. This removes one queue turn for every body with a stable first result. [Summary worklist](../src/borrow_program.odin), [Dependency registration](../src/borrow_summaries.odin)

### `src/borrow_report.odin`

Replays events over settled per-block borrow facts, pairing forward reachability and backward liveness with source diagnostics and duplicate suppression.

- **Correctness.** `check_region_reset` (lines 533–567) chooses “would” or “may” before incorporating precision lost by the live allocator-handle slot that causes the rejection. On `af7fe93a`, create arenas `safe` and `owner`, assign `safe.allocator()` to `values[0]` and `owner.allocator()` to `values[8]` of a zero-initialized `[9]Allocator`, read `allocator := values[0]`, then `drop(owner)` before using `allocator` in `box(0, allocator)`. `-emit-ll` reports L0537 with “would” and a note that merging element borrows may have caused the rejection. The control with `[8]Allocator` and `values[7]` compiles. Merge the live slot's precision before selecting the modal verb in the control-block branch. [Reset diagnostic](../src/borrow_report.odin), [Minimum provenance precision](design.md#minimum-provenance-precision)
- **Performance.** `live_reborrow_of` (lines 256–279) can run `at_once_reaches` repeatedly for the same event and source when its answer is false. Each probe copies and clears reach rows, walks transitive pointee content, and restores the rows. Cache the boolean lazily once per source within the scan and preserve the separate early return for a link held by the source slot itself. [Reborrow scan](../src/borrow_report.odin), [Pointee walk](../src/borrow.odin)
- **Duplicate.** `prov_slots_overlap` (line 495) and `view_elements_apart` (line 1896 in `borrow.odin`) both scan two packed reach rows for shared loan bits whose loans have not ended. Use a shared solver iterator that skips zero bytes of the bitwise intersection and filters ended loans, preserving the `state.loans` cutoff before the place and division marks. The overlap check can then stop at the first yielded bit. [Overlap check](../src/borrow_report.odin), [View check](../src/borrow.odin), [Bit representation](../src/borrow_tables.odin)

### `src/borrow_summaries.odin`

Replays solved provenance to publish the carrier moves, thread-local writes, allocator-region writes, and result dependencies that the whole-program worklist supplies to callers.

- **Duplicate** `record_summary_dependencies` (line 320) implements the same append-ordered set union as `set_join` in `semantic.odin`, already used in this file for carrier types. Retrieve the declaration’s slice, join the new callees, and write it back only when it grows. The stable prefix matters because the worklist registers only newly appended dependencies. [Summary producer](../src/borrow_summaries.odin), [Set join](../src/semantic.odin), [Worklist](../src/borrow_program.odin)
- **Performance** `stored_thread_facts` (line 410) allocates a two-element `Prov_Root` buffer on every retention event, even if the event carries no callback stand-in. `note_thread_local_write` (line 375) can allocate a second buffer to collect destinations that it immediately visits. Start the forwarded buffer lazily in `graph.alloc`, which resets after each body, and process destination roots directly with the same parameter filter. This avoids retaining per-event scratch in the session arena across fixed-point revisits. [Summary replay](../src/borrow_summaries.odin), [Body lifetime](../src/borrow_program.odin), [Session allocator](../src/session.odin)
- **Performance hypothesis** `merge_escape_event` (line 542) scans every loan index once per overlapping result path and again for the whole result, even when only a few bits are set in a source slot’s reaching-loan row. Keep the overlap test per path and enumerate set bits from nonzero row bytes for the two existing cases. Preserve the callback stand-in handling and the current treatment of ended loans. Measure a large procedure returning a record with several borrow-bearing fields before expanding the change to other solver loops. [Escape summarization](../src/borrow_summaries.odin), [Bit enumeration precedent](../src/region.odin)

### `src/borrow_tables.odin`

The provenance solver keeps editable flat state and snapshots immutable pages and interned bit rows, which lets neighboring CFG blocks share unchanged data.

- **Performance.** `reach_join` (line 232) marks a reaching row dirty whenever the predecessor holds a different nonzero row, including when its bits are already a subset of the current row. `reach_settle` then hashes the full row even though the join added nothing. Mark the row dirty only when its OR adds a bit, preserving any existing dirty mark. Compare the change on branch-heavy procedures before keeping it. [Join and settlement](../src/borrow_tables.odin), [reaching solver](../src/borrow.odin)
- **Simplify.** `interned_rows_make` (line 121) allocates a zero-filled row and passes it to `intern_row`, which always clones it because the map is empty. Keep the zero-filled allocation directly as row zero and use its immutable bytes as the map key. Leave `intern_row` responsible for cloning scratch rows from subsequent callers. [Row construction](../src/borrow_tables.odin)
- **Performance.** `block_rows` (line 271) makes a separate fixed-width allocation for each block, twice per task-window or view-definition analysis. Allocate one checked-size backing slice per table and give each block a disjoint row view. This preserves the indexing API while reducing arena allocations from one per block to one per table. [Allocation](../src/borrow_tables.odin), [task windows](../src/borrow_tasks.odin), [view definitions](../src/view_start.odin)

### `src/borrow.odin`

Solves one body’s reaching loans, held reborrows, and backward liveness over a disposable provenance graph, using interned rows and block snapshots to share repeated states.

- **Simplify.** `run_prov_event` (line 1145) calls `mark_released` (line 1334) and `end_loans` (line 1381), which enumerate the same invalidation, root-end, and reset targets twice. An ordinary `.Access` also clears and scans a loan-sized Boolean buffer even though it cannot release anything. Collect the changed loan indices once and apply them to the per-slot stale bits and the all-path `ended` table. Handle a fresh `.Def` directly, and preserve the distinct slot-bit behavior of a revival. [Event transfer](../src/borrow.odin)
- **Performance.** `with_held_content` (line 1860) uses its ordered traversal queue as a membership set, so each discovered carrier slot searches the full growing queue. On a broad or repeatedly aliased reachable object graph, the duplicate checks can make this liveness pass quadratic. Use a reusable visited bit row keyed by dense slot index, keep the queue for deterministic discovery order, and measure borrow-heavy bodies before changing it. [Transitive carrier liveness](../src/borrow.odin)
- **Duplicate.** `paths_overlap_joined` (line 2139) repeats the prefix comparison in `paths_overlap`. Its two callers can retain the allocation-free helper but have it compare the candidate against the prefix, then compare the candidate suffix after `min(len(a), len(prefix))` against the rest. Both comparisons use the shared overlap rule, including the case where either path ends before the other. [Store path comparison](../src/borrow.odin), [shared projection paths](../src/prov_paths.odin)

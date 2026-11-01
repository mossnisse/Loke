# Open questions

Decisions that are deliberately not yet made are recorded here rather than left
implicit in normative prose. [`design.md`](design.md) defines the rules
implementations must follow for the current language version; these questions
concern possible later changes.

Design rationale and differences from Odin are recorded in
[comments.md](comments.md).

The current behavior inventory is in [Nondeterminism and undefined behavior
audit](nondeterminism-audit.md).

## Review of drop-hook copy decisions and generic hook validation (2026-11-01)

Reviewed `3a5b4f7b`, `bf5cb393`, and `46cf2aa8` for correctness,
simplification, and structure. Two gaps it found in the new copy-decision check
have since been fixed: a deferred record declaration bypassing `L0747`, and a
successful first instance of a generic procedure hiding a later instance's
failure, whose acceptance depended on the order of the calls.

An excluded generic drop hook still supplying cleanup, which failed emission with
an internal backend diagnostic, has also been fixed. It was confirmed with a
compiler built from `bf5cb393`, so it was an adjacent existing gap, not a regression
from `46cf2aa8`.

The overall structure is appropriate: copy decisions validate declarations
without adding another lifecycle representation or emitter path; instantiated
hooks reuse `validate_semantic_hook`; and the early generic check handles the
extension restriction and drop-hook shape that need no instance. Validation
and diagnostic deduplication need to remain separate where the answer depends
on the instance. The migration changes the declarations' explicit copyability
without changing their hook bodies or adding replacement copy machinery.
The specialized-copy-hook policy is already recorded under
[A copy hook for some of a generic record's instances](#a-copy-hook-for-some-of-a-generic-records-instances).

Validation: rebuilt the compiler and language server; all 179 compiler and 43
language-server unit tests passed, with the existing toolchain-test allocation
warnings. Ten integration suites passed: run programs, trapping programs,
diagnostics, package diagnostics, LLVM shapes, packages, tutorials, bundled
interface files, layout agreement, and examples. Focused probes confirmed both
copy-decision gaps, their rejecting controls, and the older excluded-drop
failure. The language-server suite was rerun from a binary beside the bundled
libraries after an initial custom output directory made it unable to locate
`base:runtime`. No implementation fixes are included in this review.

## Review of variadic dyn views and any_view removal (2026-11-01)

Reviewed `9337076b`, `03d04d34`, `701846e9`, `b73dfa55`, and `426f1a13` for
correctness, simplification, and structure. One correctness regression, since
fixed: assert and panic arguments did not borrow the places they print (P1),
allowing a later argument to free storage the report will read.
The two newer fixes, `210f1131` and `5580637f`, are outside this review's
scope and address the unrelated divergences these commits recorded.

The overall separation is appropriate: the new conversion is confined to pack
elements rather than ordinary assignment, library printers call ordinary slots,
and the removed type and extraction node are deleted across compiler phases.
The compatibility handling for a misdeclared `format` preserves the existing
declaration diagnostic; the separate call-time registration of printing's
interface is needed before effect and transfer analysis. Neither requires a
new abstraction layer.

Validation: all 179 compiler and 43 language-server unit tests passed, with
the existing toolchain-test allocation warnings. Eight selected integration
suites passed: run programs, trapping programs, diagnostics, LLVM shapes,
packages, tutorials, bundled interface files, and layout agreement. The quick
gate could not write `tests.exe`; a full integration retry at a separate output
path stopped in Odin's runner with exception `0xC000001D`. Focused probes
confirmed the regression and its pre-change rejection, as well as generic and
overloaded variadic calls and formatting through existing views. All 2,876
specification citations resolved before the review notes were added. No
implementation fixes are included in this review.

## Review of slice-literal cleanup and received allocator unwrapping (2026-11-01)

Reviewed `210f1131` and `5580637f` for correctness, simplification, and
structure. Three issues in their fixes, all since fixed:

- Slice cleanup read an initial snapshot rather than the backing array's current
  content. Later stores could leave a hook reading freed data, and replacing an
  initially borrowed element caused a new false rejection.
- Empty literals contributed element hook effects despite containing no element
  to drop.
- A conditional write hid an incoming allocator because the parameter fallback
  was conditional on the merged set being empty.

The existing cleanup and normalized region-query machinery are appropriate
places for these fixes; no additional analysis framework is needed. The main
structural changes should be to read mutable backing storage at cleanup and
retain incoming allocator facts when parameter storage is initialized, so all
readers observe them alongside possible writes.

One concrete simplification, since made, was in `prov_region_of` in
[src/cfg_provenance.odin](src/cfg_provenance.odin): return the new projected
struct-field query directly instead of merging it into a whole-record read.
This removed one line and a redundant query, and fixed a pre-existing
sibling-region false rejection.
An isolated compiler with that change accepted the sibling-field control and
still rejected nested and copied received allocator payloads. No production
implementation changes are included in this review.

Validation: all 179 compiler and 43 language-server unit tests passed, with
the existing runtime toolchain allocation warnings. Both the rejected-program
and executable-program integration suites passed after rebuilding the compiler. Focused probes were
compared with a separate compiler built from `426f1a13`; they confirmed the
new slice false rejections and the remaining holes. The baseline empty-literal
program ran and printed `0` and `7`, confirming that no hook ran. Both compiler
and language-server binaries built successfully; the language server was built
to a separate temporary path. All 2,876 specification citations resolved,
`git diff --check` passed, and the added documentation links were checked
against their target headings.

## Review of Unit successes, parametric aliases, Status, and enum variants (2026-10-31)

Reviewed `e4d9c207`, `0ae279da`, `99057210`, and `3b49d840` for correctness,
simplification, and structure. Five implementation divergences were found, all
since fixed: a local alias hiding a generic success dependency,
resolution-order-dependent recursive aliases, dependently typed value arguments,
nested computed types, and private type exposure warnings. One smaller finding
remains:

- **Describe Status's success as Unit consistently (P3, editorial).**
  [One result](design.md#one-result) and
  [Success returns](design.md#success-returns) still use `Status(E)` as the
  example of a success carrying no payload. It now carries `Unit`, because
  it is an alias of `Result(Unit, E)`. Keep the payloadless rule for user
  unions and describe `Status` alongside the other `Unit` successes.

The overall phase structure is appropriate: aliases resolve to ordinary type
IDs before emission, and declaring `Status` as an alias deletes its duplicate
implementation. The separate scope-aware pattern matcher and syntax-only
overload view serve different needs; merging them without preserving name
ownership would lose hygiene. The alias code has a clear boundary within
[src/generic.odin](src/generic.odin); no additional framework is needed.

Validation: all 180 compiler and 43 language-server unit tests passed, with
the already recorded toolchain-test allocation warnings. The quick gate
could not replace the existing `loke-lsp.exe`; a separate language-server
binary built successfully. A full integration attempt stopped in Odin's test
runner with exception `0xC000001D`. Five selected integration suites passed:
run programs, rejected programs, packages, tutorials, and bundled interface
files. Three more passed for IR shapes, layout agreement, and trapping programs.
All 2,870 specification citations resolved. Additional focused probes confirmed
the divergences above and controls that compile when written without the
problematic alias. No implementation fixes are included in this review.

## Review of unwind bookkeeping and runtime bitcode commits (2026-10-31)

Reviewed `01cd3214` (destructure registrations), `9e0c7f4f` (failure
attributes), `c43c7e20` (unwind-env publication), and `5b6a4da6` (runtime
bitcode), including correctness, simplification, and structure. These findings
remain open:

1. **Treat an older benchmark record's missing flags as the old defaults
   (P2).** In [perf.ps1](perf.ps1), `Format-Records` checks whether build
   options differ only when both records have a non-null `flags` field.
   Records written before `c43c7e20` have no such field and were built without
   extra flags. Comparing one with a new `-BuildFlags -panic=abort` run still
   reports a percentage, mixing a compiler change with a change of panic
   strategy. The existing regression first rewrites its old-format baseline
   through `-Out`, so it exercises only a baseline that already has `flags`.
   Treat a missing previous field as the empty string when the current record
   has flags, and exercise the old-format baseline before rewriting it.

   Reproduced by invoking the script's actual `Format-Records` function with
   these records and the `run_ms` column:

   ```json
   {"program":"bench/probe.loke","input":"same","run_ms":100}
   {"program":"bench/probe.loke","input":"same","flags":"-panic=abort","run_ms":50}
   ```

   The output is `50 (-50%)`; it should identify changed options.

2. **Keep unwind read tracking in emission state rather than rediscovering it
   from LLVM syntax (P3, simplification).** In
   [src/emit_llvm_cleanup.odin](src/emit_llvm_cleanup.odin), the new
   `without_unread_bindings` parses publication-slot numbers out of generated
   lines, while `emit_unwind_thunk` scans LLVM local names to discover reads.
   This couples publication to exact instruction spelling and adds a second
   description of LLVM name syntax. Record each publication's text span in
   `bind_local`, and mark uses of the rebound parent addresses through a shared
   symbol-name accessor during replay, including direct implicit-drop uses.
   A local declared inside the replay must retain its new address and must not
   mark the replaced parent address as used. Remove the two syntax scans and
   `llvm_name_char`; keep the existing deferred prologue and text emitter.
   Apply publication spans before removing pops, so earlier text removal does
   not shift their offsets.
   The estimated saving is about 50 lines after adding the small tracking
   records and accessor. This is a maintainability finding; the reviewed
   corpora exposed no missed replay read.

   Not taken on 2026-11-01. The scan cannot miss a read: whatever the replay's
   text names is loaded, whichever emitter path wrote it. Tracking would have
   about eight sites that read `e.names` mark each use, where a site that forgets
   leaves an undefined name in a thunk only a panic path exercises, and its spans
   would have to survive `without_unpushed_pops`. The saving is an estimate, and
   the spelling the scan depends on is the compiler's own. Worth revisiting if
   the emitter stops producing text.

3. **Give the new bitcode-command unit test a temporary allocator (P3).**
   `runtime_bitcode_keeps_the_cpu_check_native` in
   [src/emit_llvm_test.odin](src/emit_llvm_test.odin) calls toolchain discovery,
   which allocates include paths through `context.allocator`. The test neither
   frees them nor redirects that allocator. A full compiler unit run reports
   15 leaked allocations, 1.23 KiB on this machine, all attributed to this
   test. Use `context.allocator = context.temp_allocator`, as the adjacent
   toolchain-discovery test does. The test runner currently exits successfully
   despite these warnings.

Validation: rebuilt the compiler and a separate language-server executable;
all 180 compiler unit tests and six selected baseline integration suites
passed. Five more suites passed at `-opt=speed` with `lto=yes`: run and trap
corpora, CPU levels, CPU dispatch, and floating-point reproducibility. A
`-g -opt=speed` unwind probe printed its expected cleanup and stack trace.
All 2,845 specification citations resolved. No compiler correctness regression
was found in these checks; the three findings above are not fixed here.

## Review of the design-review proposals (2026-10-31)

Reviewed the full [language design review](design-review-2026-10-31.md#summary)
against the specification and selected checker, emitter, and runtime paths.
Five issues were found in the reviewed draft; these concerned the proposed
changes, not current compiler divergences. All five are now addressed in the
review document. The findings below retain the evidence and implementation
prerequisites; the language changes themselves remain proposals.

1. **Do not derive `captures(none)` from borrow escape levels (P1).**
   [Section 6.1](design-review-2026-10-31.md#61-alias-attributes-from-facts-the-checker-already-proves)
   originally mapped every `@(escape=none)` parameter to this LLVM attribute.
   Loke's [escape levels](design.md#escape-levels) restrict retained borrows; they do
   not prohibit observing a pointer's address. This valid procedure returns
   `true` for equal addresses and `false` for different ones:

   ```loke
   same :: proc(@(escape=none) a: ^int, @(escape=none) b: ^int) -> bool {
       return a == b;
   }
   ```

   LLVM counts that observable result as
   [address capture](https://llvm.org/docs/LangRef.html#address-capture), even
   though no borrow survives the call. Adding `captures(none)` would therefore
   violate the IR contract for a valid program. The proposal needs a separate
   address-capture analysis; consider `captures(address)` only after proving
   that provenance cannot escape through the unchecked routes either. Closing
   the listed borrow-checker gaps alone does not establish this property.

2. **Prove the indexed slice remains unchanged across the loop (P1).**
   [Section 6.3](design-review-2026-10-31.md#63-checked-arithmetic-and-bounds-in-loops)
   originally said the required length stability holds for a slice. A slice
   variable can be reassigned, including by reslicing itself; read-only elements
   do not make its header constant. This accepted program must panic:

   ```loke
   values := [2]int{10, 20};
   xs := values[:];
   foreach (i in 0 ..< xs.len()) {
       xs = xs[:0];
       fmt.println(xs[i]);
   }
   ```

   The range retains its original bound while indexing uses the new header.
   Removing the check merely because `xs` has slice type changes the result.
   Require a proof about the actual header/length at each access, including
   writes through mutable aliases and calls. The broader range-analysis
   proposal remains useful with that prerequisite.

3. **Preserve generic `Status(E)` fallthrough when designing the alias (P2).**
   [Section 2.3](design-review-2026-10-31.md#adopted-proposals), since adopted,
   originally permitted falling through only when the expanded written result
   named no generic argument. That excludes `Status(E)` when `E` is generic, even
   though its success is always empty. This currently compiles and succeeds:

   ```loke
   succeed :: proc(error: $E) -> Status(E) {
       _ = error;
   }
   ```

   The proposed expansion is `Result(Unit, E)` and still names `E`, so the
   stated rule would reject this body. Distinguish a generic-dependent success
   payload from a generic failure payload, and specify bare `return;` alongside
   fallthrough. [Success returns](design.md#success-returns) currently separates
   payloadless success from the generic restriction on implicit wrapping; it
   does not supply the single exclusion the proposal claims. The alias itself
   remains worth designing, with inference and interface-file rules settled
   before it is described as mostly internal.

   Settled for the return rule: [One result](design.md#one-result) now lets a
   `Unit` success reach the end and use `return;` when the result as written,
   not a generic argument, makes it `Unit`, so `Result(Unit, E)` and the body
   above keep both forms while a body generic over `Result(T, E)` gains
   neither.

4. **Keep `any_view`'s storage and temporary rules when sharing its lowering
   (P2).**
   [Section 2.4](design-review-2026-10-31.md#adopted-proposals), since adopted,
   originally proposed using `dyn` lifetime rules with only implicit conversion
   and variadic packing as differences. An `any_view` also could not be a
   result, field, ordinary container element, or captured value; [ordinary `dyn` views](design.md#borrowed-dynamic-interface-values)
   follow slice lifetimes instead. A temporary converted into an `any_view`
   local lives to block end, whereas the ordinary `dyn` rule limits a view of
   a temporary to its complete expression. For example,
   `view: any_view = [dynamic]int{1, 2};` followed by `fmt.println(view);` is
   was valid. Sharing a witness representation is compatible with retaining
   these rules, but replacing them as written is a language change. List them
   explicitly or narrow the proposal to representation and dispatch.

   Resolved: `any_view` is deleted, so no lowering has to keep these rules.
   Its implicit conversion survives only at a `..dyn I` parameter, whose
   temporaries live through the call, and the block-end local is gone with it.

5. **Remove the incorrect small-value ABI premise (P2).**
   [Section 6.4](design-review-2026-10-31.md#64-union-layout-and-small-values)
   originally attributed address-only passing of slices and `Option(^T)` to
   `LARGE_VALUE_BYTES`. In [the emitter](src/emit_llvm_expr.odin) that threshold
   is 4,096 bytes, not two words; [parameter lowering](src/emit_llvm_abi.odin)
   passes smaller ordinary values as LLVM values. A fresh `-O0` assembly probe
   receives a slice's pointer and length in `rcx` and `rdx`, and an
   `Option(^int)` in `rcx` alone. The option already uses the null niche under
   [Representation](design.md#representation). An LLVM aggregate does not by
   itself mean an indirect machine argument. Remove this claimed opportunity
   and measure a specific remaining ABI problem before changing the convention.
   Scalarizing slices to attach pointer attributes is a separate justification
   under section 6.1; general nested-union layout work also remains open.

The strongest next steps are measured runtime LTO and unwind-bookkeeping
experiments, explicit copy decisions beside drop hooks, and consolidating the
specification's shared effect-resolution rules. Consolidation must retain
per-call region substitution and the distinction between a pooled join and a
spawn's effects on the parent's thread-local storage; see
[Structured concurrency](design.md#structured-concurrency) and
[Allocators and tasks](design.md#allocators-and-tasks).

Treat enum/union implementation sharing and attribute placement as separate
refactors with explicit public reflection and syntax migrations. Keep the
reflection deletion and `Uninit(T)` replacement as open design questions: the
latter trades generated prefix cleanup, including partial-copy failure cleanup,
for manually maintained unsafe lifecycle code. The review's decision to retain
`inout` is reasonable. Deleting `using`, typed SIMD splats, success returns, or
`Option.ok_or`, and adding `some` or predeclared interfaces, are language-usage
tradeoffs rather than demonstrated implementation wins; representative programs
should decide their priority. The withdrawn proposals need not be reopened by
any finding here.

Validation used a fresh compiler built from `55610f79` with Odin vet checks.
The pointer-comparison, generic-`Status`, and temporary-`any_view` probes ran
successfully; the resliced-loop probe compiled and panicked with `index out of
range` (exit 3), as required. A separate emitted-IR/Clang assembly probe checked
small-value argument passing. No language or compiler changes were applied.

## Review of remaining generic aliases and view starts (2026-10-31)

Reviewed `1d4a0c29` ("Read the remaining generic alias targets for private
names") and `4e475f11` ("Keep a local view's known start when only its length
varies") for correctness, simplification, and structure. One finding, since closed:

- **Retain starts through zero-offset reslice loops (P2).** The length join
  fixes branches, but a constant reslice from zero in a loop still makes
  the start unknown. The known gap, since closed, had a two-iteration
  reproduction and accepting straight-line and branch controls. This was a
  remaining precision gap, not a new rejection.

The shared `writes_type` recognizer removes differing syntax lists, and
following member chains iteratively with cycle detection removes the
arbitrary depth cutoff. Sharing `view_element_loan` also keeps publication's
loan narrowing in one place. No further abstraction is needed.

Each reviewed commit was built and tested in a separate source snapshot,
because the commits came from separate branches. On each, 177 of 178 compiler
unit tests passed initially; the subprocess deadline test failed to capture
its child's first output under concurrent load and passed when rerun in
isolation. Both 43-test LSP suites passed. The alias revision passed both
diagnostic corpora and the package executable corpus; the view revision
passed both diagnostic corpora, the borrow matrix, and the executable corpus.
Fresh compiler/LSP builds and heading citation checks passed. Both remaining
correctness gaps also reproduced on the merged tree. No implementation fixes
were applied during review.

## Review of local-view loads and repointed-carrier places (2026-10-31)

Reviewed `e6719c8d` and `68504095` for correctness, simplification, and
structure. Two findings, both since closed:

- **Preserve the chosen-place guarantee past the reaching-analysis limits
  (P2).** The new 63-definition and 256-block bounds reintroduce the
  repointed-carrier rejection while each storage remains within its promised
  eight places. The diagnostic names the place and storage limits rather
  than the bound that caused the fallback. The known gap, since closed, had a
  reproduction for each bound, verified against a compiler built from
  `68504095` itself. Keeping only a block's last definition would avoid much
  redundant history; large control-flow graphs still need to retain the
  specified precision.
- **Remove the redundant per-definition merge flag (P3, shrink).**
  `Prov_Offset_Def.merged` in [src/borrow.odin](src/borrow.odin) and its
  propagation in `prov_reaching_offsets` in
  [src/cfg_provenance.odin](src/cfg_provenance.odin) duplicate the slot's
  accumulated `offsets_merged`. Every recorded definition's flag is already
  joined into that slot flag by `prov_note_offset`, and
  `prov_carrier_offsets` always joins the slot flag into its result. Remove
  the field, its initializer, and `merged ||= def.merged`; retain the flag
  for merges performed while joining reaching offsets. Net: two lines fewer.
  Done since, as the walk no longer keeps definitions.

The local-view load fix shares the existing element-loan and reaching-view
helpers, and no additional correctness finding was found in it. The offset
walk separates definition recording, reaching-definition discovery, and
offset joining; caching finished blocks and invalidating on new predecessors
or definitions has a clear purpose. The bounds above leave the specification
guarantee incomplete. The then-recorded dynamic-array content-slot gap was
outside the local-view fix, and has since been
[closed](comments.md#a-dynamic-arrays-elements-as-carrier-paths).

Validation passed on the merged tree: 179 compiler unit tests, the diagnostic
corpus and borrow matrix, and the `view_element_places` executable's expected
output. Boundary probes passed at 63 definitions and 128 intervening empty
branches, and reproduced the false rejection at 64 definitions and 129 such
branches, both on the merged tree and on `68504095`. No implementation fixes
were applied during review.

## Review of private formatter defaults (2026-10-31)

Reviewed `d16a9a2d` ("Print a public type with a private format by the
generated default") and `404acdcb` ("Record a bound generic's direct
format call as an open question") for correctness, simplification, and
structure. Two findings, both since closed:

- **Keep hidden defaults out of completion (P2), since fixed.** The checker
  hid the generated default from ordinary lookup, but the editor still offered
  it to an importer, and calling the suggested method produced `L0363`.
- **Reuse the written-formatter search (P3, shrink), since done.**
  `check_formatter` in [src/format.odin](src/format.odin) now asks
  `written_format_member` rather than repeating its member walk.

The printed-form policy is consistent across erased printing, explicit
interface views, nesting, and public generic instances. The defining
package's bound generic reaches the private method under the current
[ordinary-lookup-first rule](design.md#interface-bodies); `404acdcb`
records a possible later change, rather than an implementation divergence.
No other actionable structure finding was found.

Validation passed on the current checkout, whose reviewed formatter and
lookup code is unchanged since these commits: fresh compiler and LSP
builds, 179 compiler unit tests, 43 LSP unit tests, executable and package
corpora, both diagnostic corpora, LLVM shape checks, and heading citations.
Additional probes covered a public generic's private formatter, a bound
call in its defining package, nested strings through pointers, and the
editor/lookup mismatch. No implementation fixes were applied.

## Review of public types' private interface methods (2026-10-31)

Reviewed `c0b30260` for correctness, simplification, and structure. Of three
findings, the private formatter one (P2) is fixed: printing a public type with
a private `format` reached an internal backend contract error (`L0405`). Such
a type now gets the generated default for the `Formattable` slot and prints by
it in every package, its own included, as
[String format printing](design.md#string-format-printing) and
[Interface bodies](design.md#interface-bodies) together require; the
`tests/pkg/private_formatter` case pins it. Three questions the spec leaves
open remain with that fix:

- **Ordinary lookup of a hidden default `format`.** Ordinary lookup of
  `format` on such a type still finds only the written method: its package
  calls it, and an importer gets `L0363` rather than the default that printing
  uses. The alternative is to let an importer's lookup reach the default, as
  it does on a type without a written `format`.
- **Warning for an unused private `format`.** A public type's private
  `format` is never what printing calls, which an author may not expect. A
  warning at the declaration would say so, but would also fire for a method
  meant only for direct calls in its package.
- **A bound generic's direct call in the defining package.** There, a
  procedure bound by `where fmt.Formattable(T)` that calls
  `value^.format(...)` finds the private method by ordinary lookup, which
  comes before the bound, while printing the same value uses the default.
  Whether a call through the bound should instead reach the slot's method is
  part of the first question.

The other two findings remain:

- **Only diagnose private methods as methods (P3).** `private_slot_member`
  in [src/interface.odin](src/interface.odin) tests name and visibility but
  does not test symbol kind or receiver. A private constant named `call`,
  or a private procedure without a receiver named for a slot, is described
  as a private method when the bound fails. Neither could meet the slot
  even if made public. Restrict this diagnostic to actual receiver methods,
  including those reached through an overload group; otherwise retain the
  missing-method/signature diagnostic. Both failures reproduce with:

  ```loke
  // lib/lib.loke
  package lib;
  @(public) S :: struct {}
  impl S { call :: 42; poke :: proc() -> int { return 1; } }
  ```

  ```loke
  // main.loke
  package main;
  import "./lib";
  import "base:interfaces";
  Check :: interface($T: type) { slot poke: proc(self) -> int; }
  force :: proc(s: $T) where Check(T) {}
  apply :: proc(f: $T) where interfaces.Callable(T, proc() -> int) {}
  main :: proc() { s := lib.S{}; force(s); apply(s); }
  ```

- **Correct the associated-constant comments (P3).** The new comment in
  [tests/pkg_err/private_slot/counter/counter.loke](tests/pkg_err/private_slot/counter/counter.loke)
  says private associated constants meet no requirement anywhere. Ordinary
  lookup still sees them in their own package: adding `Secret :: int` to
  the public `S` above makes `Has_Secret(S)` true there for
  `Has_Secret :: interface($T: type) { T.Secret -> type; }`, while the
  corresponding foreign application is false. Conversely, the citing
  comment above `required_associated_constant` in
  [src/interface.odin](src/interface.odin) still describes its fallback as
  an inherent member "whatever its visibility". State both the ordinary
  lookup rule and the restricted fallback accurately, as
  [Interface bodies](design.md#interface-bodies) does.

Sharing `slot_candidates` between satisfaction, constrained lookup, and witness
construction keeps the visibility policy in one place. The new helpers have
focused responsibilities; no additional abstraction or actionable line-count
simplification was found. The formatter failure exposes a caller that requests
a witness without first ensuring that its slot has an eligible candidate.

Validation passed: 178 compiler unit tests, 43 LSP unit tests, diagnostic and
package-diagnostic suites, the package executable corpus, compiler/LSP builds,
and heading citations. Additional probes covered public generic records,
distinct types, unions, enums, same-package rejection of private slots, and
the associated-constant visibility distinction. The formatter regression was
compared with a freshly built parent compiler. No implementation fixes were
applied during review.

## Review of constant view elements and the wider borrow matrix (2026-10-31)

Reviewed `72431f48` for correctness, simplification, and structure. Two
findings were recorded, and both are fixed:

- **Keep known starts when lengths vary (P2).** Shortening a view on one
  branch left its start unchanged, but accesses to different constant
  elements still conflicted, and full views of dynamic arrays had the same
  problem with an unknown upper bound. The definitions reaching a view now
  need to agree only on where it starts (`publish_view_of` in
  [src/borrow.odin](src/borrow.odin)), and a fresh `&mut d[:]` lends from a
  known start (`Prov_View_Def.open`).
- **Remove the matrix's lookup loop (P3, shrink).** `matrix_expected` in
  [tests/borrow_matrix_test.odin](tests/borrow_matrix_test.odin) only reads
  the operation's name, so it no longer scans `MATRIX_USES` for the fixture
  `matrix_same_element` remaps to.

`Prov_View_At` is a focused record, and sharing the start computation between
publication and place checks avoids duplicate walkers. The precision gap
shows where those callers need different information: element separation needs
a known start, while publication also uses the extent and underlying loan.
The matrix now has a place whose view a branch only shortens
(`local_shortened`). A matrix place for a dynamically backed view is still to
add; the new dynamic `items` cases exercise the array stored inside an
element instead, and copies out of such a view's elements have since been
[told apart](comments.md#a-dynamic-arrays-elements-as-carrier-paths).

The meaning of "fresh borrow of a range" in
[Weakening and reborrows](design.md#weakening-and-reborrows) should also be
explicit about views made through another carrier. A local
`s := &mut a^[0:2]`, with `a: ^mut [2]Counter`, rejects the same distinct
element access:

```loke
package main;
Counter :: struct { count: int }
through_pointer :: proc(a: ^mut [2]Counter) {
    s := &mut a^[0:2];
    first := &mut s[0];
    s[1].count += 1; // L0641
    first^.count += 1;
}
main :: proc() {}
```

Such a slice reborrows the pointer, so whether it qualifies as "fresh" is
not settled by the wording. `prov_slice` in
[src/cfg_provenance.odin](src/cfg_provenance.odin) makes it a place-loan
snapshot rather than a fresh range loan, and `prov_note_view` leaves its
start unknown. Clarify whether that exclusion is intended; this case is a
scope question rather than a confirmed implementation divergence.

Validation passed: 178 compiler unit tests, 43 LSP unit tests, diagnostic and
package-diagnostic suites, the expanded borrow matrix, the executable corpus,
and compiler/LSP builds. The fixed-start/varying-length rejection was
reproduced with a dedicated build of the reviewed compiler; unconditional
reslicing and a bounded dynamic-array view provided accepting controls.
No implementation fixes were applied during review.

## Review of the follow-up fixes (2026-10-31)

Reviewed `4b31729d` (tangent bound and minimized integer copies), `d66b3d8b`
(the summary/arena review record), `72da8ff0` (private names in generic
aliases), and `cb7a73bf` (chosen places per storage) for correctness,
simplification, and structure. Three gaps were found in the alias fix, all
since fixed in [src/private_names.odin](src/private_names.odin) with
regressions in the `private_names` package-diagnostic case:

- **Recognize aliases of the written `type` (P2).** A public `Meta :: type`
  made `Inner: Meta : Corner` bypass the target check, even in an instance
  using the alias. The written type is now resolved.
- **Recognize composite member aliases containing generic parameters (P2).**
  `Hidden :: []T` was not classified as a type, so a public alias selecting
  `Box(T).Hidden` produced no warning. The helpers' differing lists of
  type-syntax nodes now share one recognition rule.
- **Follow member aliases without an arbitrary depth cutoff (P2).** A long
  acyclic chain lost the warning for a public alias of its private first
  member. The chain is now followed until it ends or returns to a member it
  has passed.

The integer copy now uses the existing minimized-copy operation directly,
which removes the extra allocation and copy. The provenance helpers keep
budget accounting separate from the paths used by accesses, and the remaining
repointed-carrier limitation was recorded in `known-gaps.md` (since fixed).
No further actionable simplification was found.

An independent exact rational interval for the listed hard tangent argument
puts its relative midpoint distance strictly between `2^-134` and `2^-132`
(about `2^-132.425`), consistent with the corrected bound. The math API check
passes unchanged. No implementation fixes were applied during review.

Validation passed: 178 compiler unit tests, 43 LSP unit tests, diagnostic and
package-diagnostic suites, the borrow matrix, the executable corpus, the
reproducible-math derivation and rounding suites, compiler/LSP builds, and
heading citations. The three alias omissions were reproduced with
the freshly built compiler; direct written `type`, shorter alias chains,
and a plain `impl` provided controls that do warn. The reproductions and
diagnostic/API checks were also confirmed with a dedicated compiler built
from `e4c5dce6`, the merged state of the four reviewed commits.

## Review of summary visits and scratch arenas (2026-10-31)

Reviewed `e4d3562b` ("Skip unchanged provenance summary visits and drop arena
locks") for correctness, simplification, and structure. The allocator
panicked once a procedure's analysis outgrew one GiB, which the parent compiler
accepted; it now chains another reserved range instead. One finding remains:

- **Correct the reported performance range (P3).** The
  [changelog](CHANGELOG.md#unreleased),
  [baseline explanation](bench/baselines/README.md#skipped-summary-visits-and-lock-free-scratch-arenas),
  and [normalization question](#normalized-input-for-provenance-analysis)
  say front-end time fell 8-17% on workloads taking over 30 ms. For records
  whose baseline exceeds 30 ms, the saved JSON shows about 3-16% instead:
  `bench/nbody.loke` goes from 31 to 30 ms (3.2%), and
  `examples/timestamps.loke` from 126 to 106 ms (15.9%). If the cutoff refers
  to the final measurements instead, `examples/parallel.loke` still goes
  from 44 to 41 ms (6.8%). All compared source hashes match. State the
  cutoff and range consistently with the saved data.

The revision stamps remain local to summary inference, and the guards avoid
work at its source. No further actionable structural change or simplification
was found.

Validation passed: 178 compiler unit tests, 43 LSP unit tests, the diagnostic
and borrow-matrix suites, and all 81 integration tests other than the debugger
test. The performance-script test failed its exact `(-100%)` output assertion
in the parallel run, which printed `(-99%)`, then passed in isolation. The
debugger test aborts in the Odin runner with both the parent and reviewed
compilers. Both compiler/LSP builds and all 2,822 heading citations passed.
The scratch-limit reproduction was compared with fresh parent and reviewed
compiler builds; no implementation fixes were applied during review.

## JSON follow-ups

[`core:encoding/json`](standard-library.md#coreencodingjson) implements the
fully validating document parser and streaming writer; its remaining work is in
[Standard-library maturity](future-plans.md#standard-library-maturity). These
design questions stay open until a caller or a measurement settles them:

- **An event decoder.** When a caller needs one, it would share the scanner's
  token recognition and grammar transitions over contiguous input, with
  `next -> Result(Option(Event), Parse_Error)` and a `skip_value` that
  validates what it skips, consumed through a
  [fallible-source loop](design.md#streaming-a-fallible-source). Borrowed
  decoded text would last until the next step, and a successful decode would
  require consuming the end or calling a `finish` that validates the rest: a
  valid prefix alone is not a validated document.
- **An on-demand cursor or a SIMD structural index.** Either may beat the scalar
  scanner on large input, but their navigation and validation guarantees differ
  ([simdjson's paper](https://arxiv.org/abs/1902.08318), [on-demand design
  constraints](https://simdjson.org/api/3.0.0/md_doc_ondemand_design.html)).
  Neither is established as better for 2 to 64 KiB state files, and either would
  stay separate from fully validating document parsing.
- **Avoiding repeated validation and copies.** `parse` validates UTF-8 and then
  scans; a fused scanner would need a trusted validated-view operation and a
  decision about keeping invalid UTF-8 ahead of every other error. `stringify`
  validates and copies its finished bytes; a consuming bytes-to-string
  conversion could avoid that, as retained owned bytes could avoid the copy in
  an owning file load. Any such operation must preserve [borrow
  provenance](design.md#procedure-result-contracts), allocator ownership, and
  [string invariants](design.md#string-type); `unsafe.string_view` still
  validates. Evaluate one only if profiling makes the cost material.
- **Typed record codecs.** Reflection-based encoding and decoding need explicit
  contracts for field names, missing versus null members, duplicates, numeric
  ranges, and union mappings before an API is chosen. A mutable document,
  automatic object indexes, and chunked input likewise wait for callers.
- **Faster repeated access.** A direct child index or an explicit object index
  pays only if repeated random access outweighs its build time and memory, and
  `validate_unique_keys` waits for a protocol that requires globally unique
  keys.

## Normalized input for provenance analysis

Provenance analysis reads a
[normalized body](compiler-architecture.md#normalized-provenance-input) that it
rebuilds once per analysis invocation, consuming settled lifecycle
annotations. Bodies are not retained across visits; a visit whose summaries
are unchanged is skipped instead
([rationale](comments.md#provenance-replay-and-precise-publication)). Two
decisions remain open:

- **Lifecycle analysis on the same input.** Lifecycle analysis still walks the
  checked AST, and provenance consumes its settled decisions. Moving it onto the
  normalized input needs its own design for unresolved cleanup and last-use
  decisions.
- **The cost of normalization.** Normalization is still the largest provenance
  phase: about 40% of checking time on `bench/workspace` and
  `examples/corpus_runner.loke` after skipped visits and lock-free scratch
  arenas took 8-17% off front-end time (under "Skipped summary visits and
  lock-free scratch arenas" in the repository's `bench/baselines/README.md`).
  A sampling profile of the builds left interning as the largest single cost:
  `Prov_Input_Key`, about 72 bytes, is hashed byte by byte on every value and
  call lookup (`prov_intern_value`, `prov_input_call`, about 7% of build time).
  The three remaining builds per body differ in callee summaries, in whether
  global writes have settled, or in reporting diagnostics; sharing one would
  need the walk's output to stop depending on them. Whether either reduction
  pays for its complexity is open.

## Compositional loan construction

Every access to a place reached through carriers goes through one walk of the
normalized place, and a borrow, slice, traversal, or switch of one takes a
**place loan** ([Ownership, lifecycle, and
provenance](compiler-architecture.md#ownership-lifecycle-and-provenance));
[borrow_matrix_test.odin](tests/borrow_matrix_test.odin) checks the rules
against a model written apart from the compiler. Still open:

- **Calls.** A carrier handed to a call uses every mutable carrier it reaches
  ([Weakening and reborrows](design.md#weakening-and-reborrows)). A
  per-parameter summary of what a body uses through each parameter could
  narrow that, as written-argument regions already do for stores. That is a
  change to the language, not only to the analysis: whether a caller is
  accepted would then depend on what the callee's body touches, so editing a
  body could reject its callers, as [global write
  effects](design.md#global-write-effects) already can. Decide it together
  with [written public borrow
  contracts](#public-borrow-contracts-should-stand-on-their-own).
- **Value identity.** Three rules now say which definition a reborrow belongs
  to: a load defines its slot afresh, a reborrow records the carriers its load
  went through (`Prov_Reborrow.via`), and reloading a temporary severs what was
  reborrowed from its previous value. Explicit reaching definitions would state
  them as one rule; evaluate that if another loop or branch form needs a fourth.
- **Caller storage contents.** A store through a parameter's loan lands in the
  caller slots for the storage it names (`publish_into_caller`), and a later
  load reads them. The remaining imprecision: caller slots of different loans
  are taken to name different storage, so a store through one is not seen
  through another that a cyclic structure makes the same (a mutable cycle
  such as `l.next = .some(&mut l)` keeps `l` suspended, so this cannot be
  exploited); a view's slots stand for all its elements, apart from an element
  at a constant index; a record stored whole into a view parameter's element
  joins into the parameter itself; and storage below the second load, or
  through a view, is one slot.

Language changes should be evaluated separately. The proposed [written public
borrow contracts](#public-borrow-contracts-should-stand-on-their-own) could
simplify call boundaries and library exceptions, but cannot repair local
reborrow construction. Explicit reborrow syntax or move-only mutable carriers
would change ergonomics and compatibility while leaving nested place access and
implicit call reborrows to analyze. Do not adopt those changes solely to work
around the current implementation. Revisit them only with concrete examples and
a demonstrably smaller set of semantic rules.

## Package and import versioning

Should import paths encode package versions? And should a package declaration
remain mandatory in every file, when every file in a directory must name the
same package anyway, or is it ceremony? The current version requires the
declaration and leaves dependency versions to the build system or package
manager. A future package design may need reproducible version selection without
making source imports depend on a particular registry.

What is decided, and why, is in
[Projects name dependencies, not versions](comments.md#projects-name-dependencies-not-versions).

### Before versioned sources

The local-directory workflow is implemented; versioned resolution is still a
direction, planned in
[Packages and dependencies](future-plans.md#packages-and-dependencies). Two
choices are needed before extending it:

- **Separate a collection prefix from dependency identity.** Two independent
  libraries can both use `json` for unrelated sources. The flat namespace
  rejects their combination even though those packages share no types; an
  import alias cannot repair it, since it renames the binding after the
  collection prefix has resolved. Conversely, one name naming one directory
  does not prevent the same versioned source being required under two names
  and resolved to two different versions. Choose whether published prefixes
  must be globally canonical, or whether each manifest's aliases map to a
  separate dependency identity used for version selection and deduplication.
  The identity must survive a change of fetch location or a local replacement.
  The current global conflict rule is deliberate, but preserving type identity
  alone does not require unrelated sources to share a global alias namespace.
- **Bound minimum-version selection by compatibility.** If one dependency
  requires `json` 1.4 and another requires 2.0, taking the highest minimum
  chooses 2.0 without establishing that the first dependency can use it.
  [Go's major-version rule](https://go.dev/ref/mod#major-version-suffixes)
  gives incompatible majors distinct module identities; its minimum-only
  requirements assume compatibility within an identity. Decide whether Loke
  rejects mixed incompatible majors or gives them separate identities, and
  define the compatibility boundary for `0.x` and prereleases too. Merely
  staying within one major is insufficient before 1.0: Loke's own
  [Version policy](releasing.md#version-policy) permits breaking minor
  releases. This decision belongs with dependency identity, before the
  versioned manifest syntax is fixed.

## Using a package without reading its code (proposal, 2026-10-21)

Hand-written documentation goes stale, because nothing checks it. The proposal:
what a package tells its users is generated from its source, checked by the
compiler, or run by the test runner, and prose is kept for intent, which goes
stale slowest. Its first two steps and its seventh are built: [`///` doc
comments](design.md#comments), whose reasons are in
[comments.md](comments.md#doc-comments-start-with-), a checked-in [interface
file](compiler-guide.md#interface-files), `api.loki`, generated and never read
for the reasons in [Hand-written package header
files](comments.md#hand-written-package-header-files), and
[`@(intrinsic)`](design.md#intrinsic) declarations of the names the compiler
supplies, whose reasons are in
[comments.md](comments.md#compiler-supplied-names-are-declared-in-source). The
rest is a proposal for review, not yet a plan of record: once accepted, its plan
moves to [future-plans.md](future-plans.md) and the language rules to
[design.md](design.md).

### Proposed steps

The compiler infers whether a result borrows an argument and from which
allocator it comes (the [result
contract](design.md#procedure-result-contracts)), and whether a call writes
package state (the [write effect](design.md#global-write-effects)). Neither
`-doc`, hover, nor the interface file shows them, so a reader opens the body to
learn them. The proposal continues at step 3; steps 1, 2, and 7 are the built
ones above.

**3. Inferred facts are shown, one line each.** The interface file and hover
add an `// inferred:` line to a public procedure for its result contract and
its write effect, and say nothing when there is nothing to report:

- ``result borrows `text` `` or ``result borrows `list.items` ``, from the
  parameter paths the result contract records;
- ``result is backed by `allocator` ``, from its region provenance;
- `writes package state`, for the package's own globals, or
  ``writes state of `core:log` ``, for another package's.

A generic procedure's contract is per instantiation, and a declaration inside
a `when` is checked for one target only, so neither gets the line. An inferred
fact is not a compatibility promise: a release names a changed `inferred:`
line of a bundled package as a possible break. A
[written contract](#public-borrow-contracts-should-stand-on-their-own), once
it exists, would be shown in its place, without "inferred".

**4. Examples are tests.** `@(example=split)` marks a
[test procedure](design.md#test-procedures) that illustrates `split`, or
`Type.member` for an `impl` member, of its own package. It follows every test
rule, and in addition it may name only public declarations, because it shows
what an importer can write. The interface file lists each example by name
under its declaration (``// example: `split_on_commas` ``), and the HTML page
shows its body. The gate builds each bundled package with `-test`, so an
example that stops compiling or fails is caught.

**5. Names in doc comments are checked.** A backticked span in a doc
comment that is a name or dotted path, such as `split`, `Builder.len`, or
`mem.Allocator`, must resolve, as rustdoc's intra-doc links must. It resolves
in the documented declaration's package and imports, and also among its
parameters and, for a type or `impl` member, the type's members. A span with
any other character, such as `builder.len()` or `[dynamic]u8`, is prose and is
not checked. An unresolved name is a warning in every check, so the editor
shows it. This catches renames and removals, not wrong claims.

**6. `-doc` writes HTML for people.** A browser is on every computer, and a
Markdown page needs a renderer and has no links. `lokec <dir> -doc` writes
`index.html` and one page per package of the project into `doc/`, or the
directory `-o` names. Each page is self-contained, with inline CSS for light
and dark themes and no scripts. Signatures are colored from the compiler's own
tokens, which is exact where a TextMate grammar approximates, and every name in
a signature or checked reference links to its declaration's anchor (`#split`,
`#String_Builder.append`). Doc comments are rendered from a stated subset:
paragraphs, inline code, `*emphasis*`, `**strong**`, `- ` lists, and indented
code blocks. The HTML is generated, not checked in. Hover stays Markdown,
which the protocol requires, and the editor's documentation command shows the
interface file as a Loke document instead of a Markdown preview.

### Not proposed

- **A "may panic" mark.** Once checked arithmetic and indexing count, nearly
  every procedure may panic, so the mark carries no information. A
  precondition a caller must meet is written in the doc comment.
- **Preconditions as code.** Checked clauses are a language feature, and
  types already carry many preconditions. They wait for what remains in doc
  comments after the steps below.
- **Index and single-entry forms of `-doc`.** The interface file and grep
  cover what an agent needs.
- **A checked list of a package's main entry points.** The overview's checked
  references cover it.

The steps are in priority order, and each is usable without the next.

### Still open

- **Allocation.** Whether a call allocates at all is what a caller with an
  arena or a hot loop most wants to know, and the result contract does not
  answer it. It needs its own inferred effect, and then an `inferred:`
  phrasing.
- **Signatures Loke cannot state.** An operation the compiler types itself,
  such as `unsafe.transmute` or `unsafe.raw_data` with its five operand forms,
  has an `@(intrinsic)` signature written for readers and checked only for its
  name. Checking more needs a signature form that states such typing, or a
  rule for which written forms an operation's typing must accept.
- **Interface files outside the repository.** Whether a project's own
  packages get `api.loki` by default, and whether `loke.project` should name
  the packages `-api-check` covers.

## The `op`/`try_op` pair

Should a container keep both spellings of a fallible operation?
`append`/`try_append`, `reserve`/`try_reserve`, and the rest double the
container API over a failure-policy choice. Typed fallibility made the fallible
variant cheap: a `try_` operation reports failure as a `Result` rather than a
bare `bool`, over an ordinary library union with `@(failure=...)` and no
compiler-known error type. That is what makes keeping both spellings need
re-justifying. Every shipped container keeps its pair today; collapsing them is
a separate decision with its own migration.

The language pairs a fallible operation with a policy-following one in a second
place: the compiler-generated
[`clone`/`try_clone`](design.md#lifecycle-hooks-and-resource-types). The shape
is identical, so the two are one question asked twice, but they are not one
answer, for two reasons that the container pair does not share.

The pair costs a type author nothing. Both names are generated from the single
`hook(copy)` role, so a record supplies one implementation and receives both
spellings; a container supplies two implementations, two doc entries, and two
test paths per operation. Duplication in the generated pair is two names, not
two bodies.

And the policy-following half is load-bearing rather than convenient. Copy
assignment of a copyable type is *defined* as `try_clone` plus the [allocation
failure policy](design.md#allocation-failure), and
[`Cloneable`](design.md#standard-interface-catalogue) names the fallible slot,
so both halves already have language-level jobs. Deleting `clone` would not
remove the policy call, only move it to every call site that copies. A container
`try_op` carries no equivalent obligation, which is what leaves the container
pair the live half of the question.

The allocation built-ins are a third instance, and they keep the pair:
`box`/`try_box`, `make`/`try_make`, and `unsafe.new`/`unsafe.try_new` (see [The
allocation built-ins follow the `try_`
convention](comments.md#the-allocation-built-ins-follow-the-try_-convention)).

One alternative is a single fallible operation per container, with the policy
chosen at the call site. In this sketch `append` has today's `try_append`
contract, and `must` is a proposed library helper:

```text
values.append(item) or_return;    // propagate
must(values.append(item));        // panic, reporting the returned error
_ = values.append(item);          // deliberately accept a failed insertion
```

The result type stays the same in every context. A bare statement must not
panic where a value context returns the error, and an enclosing fallible
procedure must not make it propagate, or refactoring and calls through procedure
values would change failure policy. A consuming `must` would transfer a
move-only success, report the error and the caller's location, and follow panic
cleanup; `or_else panic(...)` cannot include the error, since it drops it first.

Allocator policy is the hard part. `append` follows its allocator's `.Panic`
or `.Trap` policy, so a generic panic helper would change `.Trap` behavior,
and `Allocator_Error` records the requested size but not the allocator's
identity or policy. A failed insertion must still leave the container unchanged
and an explicitly moved argument consumed. Prototype this on `String_Builder`
and compare complete callers before touching arrays, maps, or the allocation
built-ins; keeping the convenience forms is defensible if the caller burden
outweighs the smaller API.

## Pure procedures

Should there be a form of procedure, distinct from `proc`, that is guaranteed by
the compiler to be free of side effects?

Compile-time evaluation no longer requires a second procedure kind: an ordinary
procedure is evaluated contextually when its executed path is admissible. A
separate purity contract could still permit safe runtime reordering, parallel
reactive evaluation, and clearer contracts on operations such as `hash` and
`compare`. The cost remains an effect system, especially once useful pure code
is allowed local mutation and result allocation. It is not required by the
current compile-time or interface design.

## Callable records, procedures, and closures

A record with a `call` method is the callable convention: `x(args)` calls it
([Calling a value](design.md#calling-a-value)),
[`interfaces.Callable`](design.md#standard-interface-catalogue) lets one generic
signature accept a procedure or such a record, and a
[capture literal](design.md#capture-literals) declares the record from a
clause, and a [`dyn proc` view](design.md#borrowed-callable-views) erases
either. Their rationale is in [comments.md](comments.md#capture-literals) and
[comments.md "Borrowed callable views"](comments.md#borrowed-callable-views).
What stays open follows.

A callable that outlives its creation scope is a separate ownership question.
`fmt.Writer` and `log.Logger` do not establish a need for one: a formatter lends
its sink for the call, and a logger lends process-lifetime storage, both through
[`dyn mut` views](comments.md#formatting-and-logging-sinks-are-dyn-views).

### What a capture literal's `call` cannot do

A literal's `call` takes a plain `self`, so it reads its captures and writes
through `&mut` ones. What a plain `self` cannot do is keep mutable state inside
the callable, or hand a capture away when called and so be callable once. Both
matter only for a callable that outlives its scope: a stored generator, a
deferred job, a thread worker. Those wait on [Owning runtime
polymorphism](#owning-runtime-polymorphism) and [Thread transfer needs a visible
contract](#thread-transfer-needs-a-visible-contract). Revisit `inout` and `move`
calls when the first API takes such a callable; the receiver mode is then
written, for example on the clause.

### Returning a capture literal

No signature can name a capture literal's type, so it cannot be returned or held
in a file-scope type. A callable that is returned or kept past its frame is
either a file-scope record written by hand or an owning erased value under
[Owning runtime polymorphism](#owning-runtime-polymorphism). Revisit when the
first returned closure is needed. One answer then is an opaque result type,
`-> some interfaces.Callable(proc(a, b: int) -> bool)`, as Rust's `-> impl Fn`
is; it makes a caller depend on the body for the result's size, which works
against [Public borrow contracts should stand on their
own](#public-borrow-contracts-should-stand-on-their-own), and it overlaps an
owning `dyn`. A literal that can be returned could also be a constant's value,
which [compile-time evaluation](design.md#compile-time-procedure-evaluation)
keeps out today; decide that with the returned closure.

### A mutable callable view

A [`dyn proc` view](design.md#borrowed-callable-views) is read-only, since a
`call` takes a plain `self`: it reads its captures and writes through a `&mut`
one. Revisit `dyn mut proc` with the `inout` call in [What a capture literal's
`call` cannot do](#what-a-capture-literals-call-cannot-do): a callable that
keeps mutable state inside itself would need a mutable view to be called through
one.

## Owning runtime polymorphism

Borrowed `dyn Interface` views are now defined. Should a later version add an
owning erased value, and if so should it be a language type such as `Box(dyn I)`
or a library owner built over an exposed witness primitive?

A closure that is returned or kept past its frame is a concrete use: a
[capture literal](design.md#capture-literals) and its borrowed
[`dyn proc` view](design.md#borrowed-callable-views) cannot leave the body
that wrote it.

The proposal must specify allocator identity, alignment, fallible construction,
move, clone, drop, thread-affine destruction, and whether inline small-object
storage changes representation. Borrowed `dyn` intentionally settles none of
those questions and never allocates. The decided
[`Box(T)`](design.md#owned-values) settles them
for a payload whose type is known; `Box(dyn I)` would still need erased clone
and drop, and the payload's size and alignment from the witness.

Note that the witness is currently a mechanism with no user-visible spelling:
the compiler builds one for each `(Interface, Concrete, arguments...)` tuple
reached by a `dyn` conversion, and nothing materializes it as a value. An
earlier draft exposed `witness_of` and a compiler-defined `Witness(...)` type
for exactly this future owner, which meant fixing a layout, a zero value, an
invalid-witness panic rule, and a normative slot-flattening order for a consumer
that did not exist. Whichever way the question above is answered, the primitive
comes back with the owner that needs it.

## Concurrency refinements

The current [memory model](design.md#concurrency-and-the-memory-model) defines
data races, atomics, transfer between threads, and `Shared(T)`. Experience with
a real concurrent runtime should determine whether later versions need
compiler-checked `Send` or `Sync` interfaces, additional atomic orderings, or a
thread-affine owning type for code that wants non-atomic reference counts.

The cost of keeping immutable `string` safe to copy and drop across threads is
treated separately under [Thread-affine strings](#thread-affine-strings).

Higher-level constructs are a separate question: futures or a similar composable
asynchronous result, and language help for reactivity, such as a procedure rerun
when a variable it reads changes. Each needs a use of its own; [Thread transfer
needs a visible contract](#thread-transfer-needs-a-visible-contract) already
rules them out as the answer to borrowing across a join.

## Thread-affine strings

`string` is an owning value whose copies share immutable backing storage, and
a string may be dropped on any thread that received it, so the shared handle
count is atomic: `runtime/text.c` retains with a relaxed atomic add and
releases with an acquire-release atomic subtract, each behind an out-of-line
runtime call. Nothing turns a `string` copy into a move, since copying it
cannot allocate, so this is the most frequent hidden cost in ordinary code.
Measured on 2026-10-28 at `-opt=speed` on an Intel i5-9600K, one uncontended
copy and drop of a heap-backed string costs about 12.5 ns regardless of
length, of which about 4 ns is the two calls and the owner check (a literal or
empty string pays only that) and about 8.5 ns is the two atomic operations; a
24-byte struct copy costs under 0.3 ns, and an allocating copy of 16 bytes
about 65-70 ns. Contended counts, where cache-line traffic dominates, have not
been measured. Atomic accounting does not make an arbitrary allocator
thread-safe; a string that crosses threads still asserts that its bound
allocator may deallocate on the receiving thread.

A thread-affine string with a non-atomic count would be a distinct type rather
than a silent weakening of the guarantee, and would save at most the atomic
part of the cost above. It is not needed now: Windows x64 is the only target,
so copy-always for a target without atomics is not a live constraint, and no
workload in the repository is bound by string copies. Revisit when a profile
shows `string` retain and release on a hot path, when contended counts are
measured, or when a freestanding target is added, since that decides whether
`string` is usable unchanged there.

## Compile-time code generation

The current language evaluates ordinary procedures at compile time, treats
types as typed compile-time values, exposes typed reflection descriptors, and
supports statement-level static `foreach`. It deliberately does not expose
tokens or syntax trees, generate identifiers, inject declarations, or expand a
static loop at file scope.

Experience with serialization, GUI, RPC, and binding libraries should determine
whether typed reflection and expansion are sufficient. If declaration
generation is eventually required, it should preserve lexical name resolution,
hygiene, incremental compilation, and readable diagnostics rather than exposing
an untyped token macro system by default.

## Recoverable panics

Loke makes a panic unrecoverable: unwinding runs `defer`s and managed `drop`s
for cleanup, but there is no `recover`, `try`, or catch construct that lets Loke
code observe or resume from one. The [panic
semantics](design.md#panics-and-unwinding) are otherwise fully defined,
including the two build-selected strategies.

The open question is whether a later version should add a bounded recovery
mechanism (a per-thread catch at a task or request boundary, say) without
reintroducing general exceptions. The appeal is server code that wants to fail
one request rather than the process; the cost is a second control-flow path that
every `drop` hook and `defer` would have to be correct under, and the temptation
to use it as ordinary error handling in place of
[`or_return`](design.md#or_return-operator). Not required by anything in this
document.

## Intrinsics and inline assembly

How should a program reach the instructions the language does not express,
to use SIMD and other hardware features fully: compiler intrinsics, inline
assembly, or both? `Simd(T, N)` covers lane-wise arithmetic; what it leaves
out is the target-specific instruction.

## Abstraction over SOA

Is laying data out as a structure of arrays the programmer's responsibility,
through ordinary records of arrays, or does the language need to help, for
example with a layout attribute that keeps the field-access syntax of an array
of structures?

## LLM optimization

Could the syntax be made token-efficient for language models without making
it worse for people? How a model reads and writes code differs from how a
person does: models are trained on human-written code yet process it
differently. Encapsulation and abstraction stay important either way, so that
a model can work on one part of a program without reading the rest.

## Open questions in `core:strconv`

- `parse_f64` rounds through the C library's `strtod`, as `fmt` already does to
  find its shortest spellings. That makes it foreign code, which design.md
  "Compile-time procedure evaluation" keeps out of constants for good. Both
  now run in a fixed "C" numeric locale, so `setlocale` through a foreign
  binding no longer changes them. A correctly rounded parser in Loke
  (Eisel-Lemire with a big-decimal fallback) would make the parser usable in
  constants. Is that worth that much code?

## Open questions in `core:math`

### Deterministic math functions

[`core:math`](standard-library.md#coremath)'s transcendental functions bind
the C library and are not deterministic. The statically linked UCRT chooses
between an FMA3 and a legacy implementation at run time, and the two disagreed
on up to one seeded argument in 40 (`tan`, 2026-10-27); LLVM also folds a call
with constant arguments using the compiling machine's library. Neither path is
more than an ulp from correct rounding, but `exp` misses it on about one
argument in 200 and `sin` and `cos` on one in 40 (2026-10-29, against
[the oracle](tests/math_oracle.odin)), and `sinf` and `cosf` of an infinity
return a negative NaN.

The answer so far is a separate correctly rounded package,
[`core:math/repro`](standard-library.md#coremathrepro), with platform math
kept and a decision on the default after measurement
([Future plans](future-plans.md#standard-library-maturity)). Open:

- Can `core:math/repro`'s `pow`, `atan2`, `asin`, `acos`, `log2`, and
  `log10` be proved correctly rounded? `pow`'s slow path is within 2^-240
  of x^y, and a value within 2^-230 of a midpoint is tested for being
  exactly that midpoint, so it decides every argument unless an x^y that is
  not a midpoint comes within 2^-230 of one. The others' slow paths, within
  2^-305 for `atan2`, `asin`, and `acos` and 2^-248 for `log2` and `log10`,
  never meet a midpoint, but could meet a result that close to one. For
  one-argument functions, exhaustive searches bound that distance, but none
  for binary64 `asin`, `acos`, `log2`, or `log10` is relied on here; no
  search covers two `f64` arguments, and no proof is known to rule it out.
  Their results are the same everywhere either way.

### Targeting x86-64 levels

Programs target baseline x86-64 (SSE2), which every 64-bit x86 processor runs,
unless built with [`-cpu`](compiler-guide.md#cpu-levels), which offers v2 and
v3 with a startup check; a level changes instructions, not results
([comments.md](comments.md#a-cpu-level-changes-instructions-not-results)).
The levels are:

| Level | Adds | Processors |
| --- | --- | --- |
| v2 | SSE4.2, POPCNT | Intel from 2008, AMD from 2011; Windows 11 24H2 itself requires SSE4.2 and POPCNT |
| v3 | AVX2, FMA, BMI, LZCNT | Intel Core from Haswell (2013), AMD from Excavator (2015) |
| v4 | AVX-512 | AMD Zen 4 and later, Intel server and workstation parts; not Intel consumer parts since Alder Lake |

Steam's survey, as quoted in the Flax Engine's
[commits](https://git.flaxengine.com/Flax/FlaxEngine/commit/d1774cac28988b46bd1de87aec26745ae71fcb48),
put SSE4.2 at 99.78% (September 2025) and AVX2 at 94.48% (May 2025). Windows on
Arm emulates AVX2 and FMA for x64 programs from Windows 11 24H2. Run-time
dispatch is added only where measured, as
[`@(cpu_dispatch)`](design.md#cpu_dispatchstring) does for
`core:math/repro`'s `f64` functions. Open:

- Should the default move to v2, which costs almost nothing?
- Should v4 and `native` follow? v4 needs AVX-512 hardware to test on, and
  `native` resolves to a feature set of its own rather than a level.

### Integer bit operations not yet provided

[Integer bit operations](standard-library.md#integer-bit-operations) has the
counts, the bit width, the rotations, the reversal, and the power-of-two
operations. Left out until a caller settles their contracts:

- **Lane-wise forms.** LLVM's `ctpop`, `ctlz`, `cttz`, `bitreverse`, and
  funnel shifts take vectors, so a `Simd(T, N)` operand could count lane by lane. The result type
  is the question: a `Simd(int, N)` widens every lane past the operand's,
  and a `Simd(T, N)` is not an `int` as the scalar forms are. The checker
  refuses a vector today, so either choice can be added.
- **Bit field extract and deposit** (`pext` and `pdep`), which exist only from
  `x86-64-v3` and would need a portable fallback with the same result.

## Open questions from the linear algebra spike

A spike tried `linalg`'s `Real` interface and generic matrix shapes against
the compiler (`tests/pkg/real_interface`) before
[`core:math/linalg`](standard-library.md#coremathlinalg) and then
[`core:math/dense`](standard-library.md#coremathdense) were built on them.
These language questions came out of that work, and the libraries cannot
settle them by themselves.

### Positional literals for vocabulary records

[Struct literals](design.md#struct-literals) allow positional elements only in
the package that declares the fields, so a reordering cannot silently move a
value. For a vector that rule turns `Vector3(f32){1, 2, 3}` into
`linalg.Vector3(f32){x = 1, y = 2, z = 3}` in every program that uses it, or
into a named constructor such as `Complex`'s `from_components`. The order of
`x`, `y`, `z` is part of such a type's meaning, its layout is promised to
foreign code, and it will never be reordered. A declaration-level opt-in,
an attribute promising the field order as part of the public API, would let
positional literals cross packages for exactly those records. Without it the
library offers `from_components` and named literals, and the cost is
verbosity at every call site.

### Visibility in slot and expression requirements

A named slot is met by a private inherent method on any type no importer can
name ([Interface bodies](design.md#interface-bodies)), while an
expression requirement such as `(a, b: T) a + b -> T` is checked with the
visibility of the package that applies the interface, where the bound is
written, and so needs the operator to be visible there. A type in a
`package main`, whose declarations are private by default, therefore meets
`Real`'s `sqrt` slot but not `Numeric`'s `+` until its operators are marked
`@(public)`. The diagnostic now names the cause. An associated constant
requirement, `T.Real -> type`, falls back to the slot rule when the applying
package sees no such member ([Interface bodies](design.md#interface-bodies));
whether the other expression requirements should agree with slots, and in
which direction, is open.

### Disjoint strided mutable views

[`core:math/dense`](standard-library.md#coremathdense) gives
two disjoint mutable blocks of a matrix by splitting its `[]mut T`, as
[`split_at_mut`](design.md#splitting-a-mutable-slice) does. That works only
when one block's elements all precede the other's: the left and right columns
of a column-major matrix. The top and bottom rows of the same matrix
interleave in memory, so no split of the slice separates them, and two
reborrows cannot be live at once. Blocked algorithms that update a panel and a
trailing block together want exactly that pair. The language could check
disjointness of strided index sets, which is decidable for a fixed stride
pattern but is a new kind of borrow; or the library could build the two views
through `core:unsafe`, which gives up the checker's guarantee for code the
library does not control. The package's factorizations work through one view by
index and need neither; the question is what a user writing their own blocked
algorithm gets.

### Flat views of nested fixed arrays

A nested fixed array is one contiguous value
([Multidimensional arrays](design.md#multidimensional-arrays)), so
`linalg.Matrix(f32, 4, 4)`'s `columns: [4][4]f32` holds 16 consecutive
elements. Safe code cannot borrow them as one `[]f32`: slicing takes one
index, and `[4][4]f32` slices to `[][4]f32`. A flattening borrow, a
contributed member returning `[]T` over every scalar element, would let the
dense package view a fixed matrix without a copy, and would serve image
buffers and lookup tables stored as nested arrays. Without it the dense
package copies at the boundary.

### Overflow checks in index arithmetic

A spike before [`core:math/dense`](standard-library.md#coremathdense)
measured a column-major product written as an ordinary loop over raw pointers. With the
index computed as `k*n + i`, it ran 3.5 times slower than with `k*%n +% i`
at the baseline CPU level and 5.7 times slower at `x86-64-v3`, for the same
bits. The checked operators panic on overflow
([Integer overflow](design.md#integer-overflow)), and that branch per element
keeps the optimizer from vectorizing the loop, even where the induction
variable and the bound make an overflow impossible. A library kernel can write
the wrapping operators once it has checked its extents. A program's own
two-dimensional loop over a slice pays the cost, and bounds checks add to it.
Open: whether the compiler should prove the common shapes overflow-free (an
index affine in loop variables whose ranges are known before the loop), or
whether a checked-once form of indexing belongs in the language.

### Slots through a record's bound

`dense.Lu(T)` is declared `where linalg.Scalar(T)`, so no instance exists for
an element type without `T.Real`. Even so, a method in `impl Lu($T)` cannot
name `T.Real`, or call `x.abs()` on one, until the method restates
`where linalg.Scalar(T)`: a bare bound grants *its own declaration* the slots
and associated constants that satisfied it
([where clauses](design.md#where-clauses)), and the record's own grant
reaches only its fields. `core:math/linalg` restates `Real(T)` on each method
that needs it, and `core:math/dense` restates `Scalar(T)`. Letting a record's
bare bounds carry into its `impl` methods would remove the repetition; against
it, a method's bounds are now all in its own signature, which is what [method
exclusion](design.md#where-clauses) and the interface file show.

## Open questions in `core:random`

### More generators and distributions

ChaCha would give a seedable cryptographic generator, and belongs with a
`core:crypto`. A counter-based generator such as Philox would give random
access into a stream. Floyd's sampling of indices from a range without
materializing it needs a set. `f32` distributions would need their own
ziggurat tables. The remaining candidates are listed in
[Standard-library maturity](future-plans.md#standard-library-maturity).
None is added until a caller needs it.

### Longer seeds

`from_seed` takes 64 bits, which is enough to name a run but not to reach
every state; `from_state` takes all 256. A seed sequence in the style of numpy's
`SeedSequence`, hashing seed material of any length into a state, would sit
between them. Does a caller need it?

## Open questions in `core:time`

[`core:time`](standard-library.md#coretime) has clocks, durations, instants,
the calendar, fixed offsets, the system's local zone, and ISO 8601 text; the
reasons for its shape are in
[Standard-library API choices](comments.md#standard-library-api-choices).
Zones chosen by name are what is left.

### Named time zones

Converting in a zone chosen by name, such as `Europe/Stockholm` in 1950, needs
the IANA time-zone database. Good C libraries exist for it. The hard part is
the data, which changes several times a year, and a stale copy gives wrong
local times without any error.

| Route | Data and its updates | Cost |
| --- | --- | --- |
| ICU in Windows (`icu.dll`) | IANA data in the OS, kept current by Windows Update | A handful of `ucal_` calls, UTF-16 zone names. Windows 10 1903 and Server 2022 or later. Windows only. MSVC's `std::chrono` zones use it. |
| IANA `tzcode`, public domain | TZif files: `/usr/share/zoneinfo` on Linux and macOS, none on Windows | Vendored C. Thread-safe through `tzalloc`, `localtime_rz`, and `mktime_z`. On Windows we would ship tzdata and follow its releases. |
| A TZif reader in Loke (RFC 9636) | The same files as `tzcode` | A few hundred lines of Loke, and the same data problem on Windows |
| Windows' own zones | The registry, kept current by Windows Update | Windows names (`W. Europe Standard Time`), not IANA's, and history only where Microsoft recorded it |

The recommendation is to leave named zones out until a caller needs them. When
one does, use the data each system already keeps current: ICU on Windows, the
system's TZif files elsewhere. Never ship a copy of tzdata with the compiler.
`Zone` then gains a named variant holding shared, immutable rules, so it stays
copyable, and nothing already in the package changes.

### Smaller open points

- **Calendar durations.** `P1Y2M3D` has no type; `add_months` and its siblings
  do the arithmetic. A `Period` type waits for a caller that stores or parses
  one.
- **The system zone's name.** Windows names its zones its own way, and the
  IANA name needs CLDR's mapping, which ICU has, so a `Zone` has no name. A
  caller that shows one, or records the zone beside a time, would need it.

## A copy hook for some of a generic record's instances

[A record with a drop hook says how it is copied](design.md#lifecycle-hooks-and-resource-types),
and a generic record decides once. A `hook(copy)` written only in a specialized
block, `impl Cell(int)`, counts as that decision, so `Cell(string)` keeps the
generated copy beside a drop hook from `impl Cell($T)` with no attribute saying so.
Requiring the copy hook's block to be at least as general as the drop hook's would
close this, at the cost of a rule about block specificity.

## Formatting

The current formatter rules and rationale are in [comments.md
"Formatting"](comments.md#formatting).

Open: aligning columns automatically, as `gofmt` does, so a renamed field
does not leave its neighbors misaligned; and indenting a continued line
inside brackets, which `core/` leaves at the bracket's level.

## Language design review (2026-10-03)

Proposals from a review of the specification, not amendments to it; backward
compatibility was not a constraint. Of its recommendations, checked disjoint
access was adopted as [Splitting a mutable
slice](design.md#splitting-a-mutable-slice) and scoped workers as [Structured
concurrency](design.md#structured-concurrency). The rest follow, in the order
the review suggested: compiler-selected union layout and written borrow
contracts first, then unchecked operations at their use and checked thread
transfer. Try each on a parser, a resource container, a partitioning
algorithm, and a parallel numeric kernel before deciding.

### Put unchecked obligations at their operation

The current [unsafe boundary](design.md#the-unsafe-package) is a file import.
Once a file imports `core:unsafe`, every unchecked pointer conversion and
C-pointer access in it is permitted, not only the one that needed it. Most
unchecked operations are already named at their use (`unsafe.raw_data`,
`unsafe.take`); the syntax forms are the exception. `x: T = ---` and
`@(initialized)` storage now need the import too.

**Proposal:** add a lexical `unsafe { ... }` boundary for unchecked pointer
use and unchecked calls. An unsafe procedure declaration should mean that its
caller owes a stated precondition; an ordinary wrapper can establish it
internally. The spelling is proposed syntax, not syntax accepted today. It
pays once a library exposes a procedure with a caller-owed precondition; none
outside `core:unsafe` does yet, and the files that import `core:unsafe` are
mostly OS wrappers that would wrap nearly every procedure.

Raw pointer constness is a separate idea: a C pointer currently loses both
provenance and read-only capability. Consider `[^]T` for read-only foreign
access and `[^]mut T` for writing, with an unchecked cast required to
strengthen capability. It would change every foreign signature in `core`, and
foreign pointer use would still require lifetime and bounds obligations;
constness alone does not establish either.

### Self-referential storage

Graphs, arenas, and records that view their own storage need tools other than
disjoint access. A graph or arena can use stable integer or generational
handles without pervasive pointers. A record owning a buffer and views into
itself needs address stability and an internal-borrow contract; non-null
pointers do not solve it. Prefer offsets and handles before introducing general
pinning or self-referential types.

### Performance opportunities and actual semantic limits

Fast programs are expressible: fixed arrays, slices, arena-backed owners,
monomorphized generics, static iteration, explicit moves, and `Simd(T, N)`.
What remains open is where the compiler could do more without changing a
specified result:

- **Union layout.** Null already encodes `.none` in an `Option` over a
  non-null reference ([Representation](design.md#representation)); every
  other union has a fixed payload-plus-tag layout. Making an ordinary union's
  layout the compiler's choice would allow other niches and a compact nested
  `Result(Option(T), E)`, keeping `size_of`, alignment, reflection, and the
  ABI within a build accurate, with an explicit representation where a
  stable tag and layout are needed for serialization or foreign code.
- **Alias attributes.** The emitted IR spells no general `noalias` or
  `readonly` parameter attributes. Read-only capability alone does not
  promise that memory cannot change, since atomics write through read-only
  receivers and foreign or unchecked aliases need their own contract, so each
  attribute needs [LLVM's precise obligations](https://llvm.org/docs/LangRef.html#parameter-attributes)
  shown to hold. `noalias` is unsound under the `unwind` strategy, whose
  cleanup reads callers' locals while the callee is still executing, and LLVM
  already infers the capture attributes; see
  [design review 6.1](design-review-2026-10-31.md#61-alias-attributes-from-facts-the-checker-already-proves).
- **Explicit reductions.** A floating-point sum is ordered, and the default
  arithmetic stays strict. Separately named reassociating or tree reductions,
  with their numerical differences documented, would let a kernel ask for the
  faster order.
- **Copy elision.** Which implicit copies of a type with a custom clone or
  drop may be elided is unspecified, so none is.
- **Container fast paths.** An optimized build links the runtime as bitcode
  ([design review 6.2](design-review-2026-10-31.md#62-container-operations-in-ir-not-through-an-operation-table),
  step 1), but in `bench/collections.loke` LLVM still calls `dyn_append`,
  `dyn_reserve`, and `map_find` out of line from the hot loops, and
  `map_find` calls the key's `hash` and `==` through the operation table. The
  review's second step, fast paths emitted in the module per element type,
  remains the way to remove those calls; its cost is a second implementation
  of the probe sequence.

Some transformations are forbidden outright: reordering floating-point
additions into another tree, fusing `a*b + c`, or hoisting a possible panic
above an earlier observable write. Vectorizing independent iterations, proving
checks cannot fail, and runtime alias checks stay available. A general purity
or effect language is not to be added only to request faster code.

### Public borrow contracts should stand on their own

[Procedure result contracts](design.md#procedure-result-contracts) can capture
precise dependencies, but `type_of(procedure)` ties a public callback contract
to that procedure's inferred body. A handwritten procedure type loses details;
`@(escape=none)` excludes whole arguments but cannot name a specific result
field's source or every allocator dependency.

**Proposal:** add a small written result-source contract, with syntax to be
designed, that says a result borrows specified parameter paths or is backed by
a named allocator parameter. Check the body against it. Keep inference as the
default for local helpers and an IDE/documentation aid.

This lets changing an implementation preserve its declared public contract,
and permits callbacks without manufacturing a reference implementation solely
to use its `type_of`. It can also reduce dependence on whole-program inference
as separate compilation develops. It does not require lifetime variables on
every local declaration.

The [minimum provenance budgets](design.md#minimum-provenance-precision) are
another source of surprises: four projection steps, eight distinguished fixed
array elements, and four constant map keys. A harmless wrapper or extra entry
can turn accepted code into a conservative rejection. Keep diagnostics naming
the limit, add acceptance tests just beyond each boundary, and make written
contracts/disjoint primitives reduce dependence on inferred shape. Raising
numeric limits alone does not solve this architectural issue.

A library getter whose result is rebuilt from untracked storage meets the same
gap from the other side. The rebuilt pointer has unknown provenance, which
proves nothing, so no declaration says that the result borrows its receiver.
The compiler asserts it for `Shared(T).get` alone; `Monitor_Guard.read` calls
through a plain procedure type instead, whose result derives from every
borrowed argument, so the borrow ends with the guard. A channel meets the
opposite case: an item taken out of its queue through a guard would look like a
borrow of the guard, though items carry only process-lifetime borrows, so
`Channel` reaches its queue through a `rawptr` cast (`queue_of`) to drop that
provenance. A written contract could say both, and replace the `Shared` special
case.

### Thread transfer needs a visible contract

Answered for work joined before its caller continues. [Structured
concurrency](design.md#structured-concurrency) adds `parallel` blocks whose
tasks keep their argument borrows until a join the block owns, which survives
every early exit and cannot be skipped by `unsafe.forget`. The checks a task
needs are inferred rather than declared through `Send` and `Sync`, apart from
`@(thread_affine)`, `@(synchronized)`, and `@(cross_thread)`;
[comments.md](comments.md#tasks-that-borrow-joined-by-their-block) gives the
reasons. Futures, async syntax, and reactive variables were not needed to borrow
across a join.

Still open:

- A thread `core:thread`'s `spawn` starts outlives any scope, so it still
  takes only `@(escape=static)` arguments, and keeping a `thread_local` borrow
  past the end of its thread is still unchecked; see
  [What is not checked](design.md#what-is-not-checked).
- The [later concurrency extensions](#later-concurrency-extensions).
- Whether the [waiting design](standard-library.md#corethread), with paired
  channel setup and explicit monitor termination, holds up in use. Measure the
  monitor's wake-all cost and the join check's conservative rejections on real
  pipelines; neither justifies a purity effect system or interprocedural
  closed-state analysis without evidence. The join check tells two parameters
  apart by the object types they reach, which is coarse at primitive fields: a
  `[]mut int` parameter still conflicts with a kept sender, since a channel's
  state holds `int` fields. Whether a finer rule, for example one using field
  privacy, would accept enough real programs to pay for itself is unmeasured.

### Later concurrency extensions

`parallel` blocks, `spawn`, monitors, channels, the join check, the polling
ring, pools, indirect spawned calls, and `sync.Lazy(T)` are built: design.md
specifies them under [Structured concurrency](design.md#structured-concurrency),
and standard-library.md under [`core:thread`](standard-library.md#corethread).
These questions remain; none blocks what is built.

1. **Erased callables at a spawn.** A spawned call may go through a procedure
   value or a `dyn` view, and the effects follow the callbacks each call passes.
   A view that arrives erased, as a parameter or stored local, is checked
   through every type converted to its interface application (answered
   2026-10-27; see [Sharing with tasks](design.md#sharing-with-tasks)), and a
   call through it takes its slot's whole effect union. What remains is
   precision: one conversion of a mutable or thread-affine type anywhere rejects
   every erased view of that application, and one fill writing a global rejects
   every call through it. Public callable-effect contracts, which would bound
   both, need a separate demonstrated requirement.

   The same union lets a task read through a `dyn` stored in a global, except
   a `dyn fmt.Formattable`, which stays unknown since printing builds its
   witnesses after the effects. Two more precise directions are open: keeping
   the concrete type through a view stored in a local, which helps only
   locals, and a view type that promises its target may be shared with a
   task, a language extension with a public contract that needs a
   demonstrated requirement.
2. **Recoverable submission.** How to return arguments after failure to
   start a task, without confusing submission failure with worker failure.
3. **Richer result destinations.** Whether live replacement, fields, indices,
   destructuring, or an implicit conversion on the worker justify their
   evaluation, initialization, and cleanup rules. The initial form supports
   only dead outer locals of the call's exact result type.
4. **Channel items carrying borrows.** A later retention rule for the
   read-only `send` receiver; process-duration retention remains the initial
   contract. Also rendezvous channels and nondefault queue allocators.
5. **Blocking-aware pools.** Whether to compensate for waits or provide a
   separate executor. Fixed pools make only the limited progress guarantee
   [Pools](standard-library.md#pools) gives. Scoped submission is compiler
   lowering under the existing spawn borrow checks, not a public
   `@(cross_thread)` submission API for borrowed arguments.
6. **Provider and allocator thread contracts.** Whether a build-selected
   allocator or logging provider must declare that it accepts concurrent use,
   so the compiler checks it instead of trusting it. Whether an `Allocator`
   parameter can promise a concurrent region, so a library can share a
   caller's allocator among tasks.
7. **Timed waits.** `lock_when`, `send`, and `receive` with a deadline from
   `core:time`, reporting a timeout apart from closure. An audio loop that must
   play silence when a decoder falls behind needs them.
8. **Selective cancellation and choice.** A stop token that ends one waiter
   among several on the same object or coordinates cancellation across several
   objects, and a wait on whichever of several channels is ready first. The
   library requires explicit shutdown protocols for those groups.
9. **Unscoped channels.** Endpoints that own shared channel state instead of
   borrowing a local, for a thread `core:thread`'s `spawn` starts or a
   foreign audio callback, which only `@(escape=static)` values reach. The
   [join check](design.md#releasing-before-the-join) cannot follow them, since
   they borrow no root.
10. **Targeted wakeups.** A hint that wakes fewer of a monitor's waiters,
    where waking all of them costs more than their checks. It would narrow
    which waiters wake, not which changes they see.
11. **Blocking ring adapters.** Parking one endpoint and waking it from the
    other requires a proven registration/recheck handshake, closure-race
    handling, and an explicit account of kernel calls on the deadline-bound
    side. It is outside the polling ring's API; see
    [The ring algorithm](standard-library.md#the-ring-algorithm).
12. **Thread-affine values in globals.** A task may borrow a
    `@(thread_affine)` value stored in a plain global, as `window.handle` reads
    one. [Sharing with tasks](design.md#sharing-with-tasks) follows arguments,
    receivers, captures, and results, not globals, so this is not a divergence.
    Closing it needs a task check over the
    [read effect](design.md#global-write-effects), or a rule that rejects a
    global of a type that is or reaches one. A `Lazy` cannot hold one.

### Per-call effect precision

The write, reach, and allocator-use effects the task checks read are per call:
a call takes in the callbacks it passes, a local's possible values, and a
converted view's concrete target, and a `dyn proc` parameter or local is
followed as a procedure-typed one is. Three conservative limits remain:

- **A body's own calls of its parameters keep the type union.** A wrapper
  that spawns a callback it received, `spawn r = g(1)` with `g` a parameter,
  is checked inside the wrapper, where any procedure of `g`'s type may be
  passed, so it is rejected when any procedure of that type writes a global,
  whatever its callers pass. Following the spawn to each caller would need
  the task checks themselves to become a summary a call substitutes, as the
  `thread_local` write-back is; nothing yet shows a program needing it.
- **What a local may hold is flow-insensitive.** `f := tally; f = step;
  spawn r = f(1);` takes `tally`'s effects, since every value stored into a
  local counts wherever it is called. This is the existing resolution the
  `thread_local` write-back shares, and is conservative.
- **A held procedure binds its arguments as a union does.** A callable view
  converted at the call from a named procedure takes that procedure's whole
  effect, but its allocator use takes every argument's region for each
  parameter-backed region, as any call through a value does, rather than the
  argument at that parameter. A capture literal's `call` and a converted
  slot are direct calls and bind by parameter.

### Ring algorithm validation

[The ring algorithm](standard-library.md#the-ring-algorithm) is built as
written, and an exhaustive interleaving search under sequential consistency
found no violation. Two checks remain:

- **Weak-memory model checking.** The interleaving search treats every access
  as sequentially consistent, so it cannot find a missing release or acquire.
  A C11 model check with GenMC or a tool like it, over the same capacities,
  laps, and drop placements, is still needed.
- **Measurements.** Measure the closure check on every send, with the flags
  separated from the indices, and latency and throughput on the intended
  target. The spare slot is for simpler arithmetic, not demonstrated higher
  speed.

## Error handling (2026-10-13)

The error handling proposal of this date is adopted. design.md defines it under
"The failure operand", "Typed fallibility", "One result", and "defer
statement"; comments.md records the reasoning and the alternatives not taken.
These parts are open:

- **A replacement that discards information.** `f() or_return .Bad` drops the
  error `f` returned. That is explicit at the site, as the switch it replaces
  was, but when the error is not an enum a lint could ask for a mapper.
- **Binding the error in `errdefer`.** Zig's `errdefer |err|` names the error
  being returned. An `errdefer` reads locals today; binding needs a syntax and
  a rule for an error that has moved into the result.

## Anonymous unions and their follow-ups (2026-10-18)

A design exploration of 2026-10-17 and the proposal that followed it led to five
adopted changes: [Success returns](design.md#success-returns), [Anonymous
unions](design.md#anonymous-unions), [Widening by
label](design.md#widening-by-label), [Per-variant switch
cases](design.md#per-variant-switch-cases), and [Union argument
expansion](design.md#union-argument-expansion). comments.md records why,
including why `Result`, `Option`, and `Status` remain the fallible boundaries
([Anonymous unions](comments.md#anonymous-unions)). What the proposal left open
follows.

### Generic implementations on structural shapes

A parameter's anonymous record or union binds its `$` names by label
([Specialization](design.md#specialization)), but an `impl` subject does not:
`impl (a: $T, b: $T) { ... }` is `L0437`, since a generic `impl` names a
generic record's application, as `impl Pair($T, $T)` does. An `impl` over a
shape would be an [extension](design.md#methods-and-implementation-blocks)
whose subject is a pattern, which method lookup does not match today. Revisit
when a program wants methods on a family of shapes.

### Parametric aliases

Adopted as [Parametric aliases](design.md#parametric-aliases):
`Io_Result :: Result($T, Io_Error);` fixes one argument of a generic, as Rust's
`io::Result` does, and an application has its expansion's identity.
comments.md ["Parametric aliases"](comments.md#parametric-aliases) records why.
These parts are open:

- **The alias's spelling in diagnostics.** A message names a type by its
  expansion, so `Io_Result(int)` reads `Result(int, Io_Error)`. Keeping the
  written spelling needs the syntax a type came from wherever a message names
  one, since the interned type is shared with every other spelling of it.
- **An `impl` over an alias's applications.** `impl Io_Result($T)` is `L0746`.
  Read as `impl Result($T, Io_Error)`, its pattern would take names from the
  alias's package and the `impl`'s at once, which generic `impl` installation
  resolves in one scope. Revisit when a program wants methods on a family
  written through an alias.
- **Aliases in core.** `core:io` and others name `Result(T, Error)` in full;
  whether each should declare a `Result($T)` of its own is a library question.

### Combining error sets

A caller that flattens its helpers' errors restates each of their labels and
payload types. In [examples/orders.loke](examples/orders.loke), `Order_Error`
repeats `parse_order`'s three alternatives and `quote`'s two. Changing a payload
in a helper is a diagnostic at the caller's `or_return`, naming the
alternative, but the fix is a second edit by hand. A spread inside an anonymous
union could splice in another set's alternatives instead:

```text
Line_Error :: (blank: | no_quantity: | quantity: strconv.Parse_Error);
Stock_Error :: (unknown: | short: (wanted: int, have: int));

Order_Error :: (..Line_Error | ..Stock_Error | limit: Limit_Error);
```

The result would be an ordinary anonymous union, spelled out in place, so both
parts widen into it by the existing rule and nothing about widening changes.
Open points:

- **What a spread names.** Only an anonymous union, since a named union's
  variants belong to its declaration, as with widening. Whether a procedure's
  error set can be named without an alias, by something like `error_of(proc)`,
  is a further question.
- **Repeated labels.** Two parts that share a label with the same payload type
  could merge into one alternative, as flattening by hand does. The same label
  with different payload types must be an error.
- **Order.** Spliced alternatives would take their place in the written order,
  which is also the tag order.
- **Generic sets.** `(..$E | limit: Limit_Error)` over a set bound by a
  generic would need a `$` that binds a set of alternatives. A
  [structural pattern](design.md#specialization) binds one payload per label,
  not the rest of a union.
- **Syntax.** `..` in a type is new. It is the variadic spread's punctuation,
  which [union argument expansion](design.md#union-argument-expansion) also
  uses.

The cost is visibility. The caller's full set no longer shows in its signature,
only in hover and documentation, and a helper that adds an alternative grows
every set that spreads it. Each caller's `switch` then fails to compile until it
handles the new label, which is the intended signal. Compare it with restating
the labels in the [representative
programs](#evaluating-on-representative-programs) before deciding.

### Per-variant expansion

[Per-variant switch cases](design.md#per-variant-switch-cases),
[`variants_of`](design.md#compile-time-reflection), and
[union argument expansion](design.md#union-argument-expansion) are
implemented; comments.md records why. What is still open:

- **Constructing from a descriptor.** A `meta.Variant` describes a variant but
  cannot build one, so generic code cannot yet map one union onto another by
  label.
- **Visitors.** A bridge from any union to a visitor is ordinary generic code,
  an expanded case calling `visitor.visit(variant, payload)`, which overloads on
  the payload type or tests `variant.name` with `when`. Visitor slots named
  after the labels stay out of reach, because static expansion does not
  synthesize identifiers. Whether the library should ship such a bridge waits
  for the representative programs.
- **More arguments.** The expanded union is a call's only written argument.
  Passing context beside it, as in `handle(context, ..event)`, needs a rule for
  how a label competes with positional arguments for a parameter.

### Unordered type-based sums

`(int | string)`, with alternatives chosen by payload type as
[Odin's unions](https://odin-lang.org/docs/overview/#unions) are, is deferred
rather than declined. Labels with widening already compose error sets and keep
equal payload types apart, which a set of types cannot. A type-based form would
need its own rules: identity as an unordered set, with nested sums flattened
and duplicates collapsed; injection by exact type identity, with an explicit
choice for a literal several alternatives admit, such as `1` for
`(i32 | i64)`; a type-based case with a branch-local binding that stays
exhaustive; and constraints for generic inference, which cannot guess a unique
`$A, $B` decomposition of a set. Revisit if programs need selection by type.

### Evaluating on representative programs

The code in this repository is mostly the standard library and its tests, so it
cannot show how often a general-purpose program needs these forms. Evaluate each
on programs written for the purpose, with and without each form:

- an application that loads, parses, and serves, with helpers over several
  error domains, for success returns, anonymous unions, and widening;
- an expression interpreter with several tree walks (evaluation, printing, type
  checking) over one node union, for expanded cases;
- an event loop or message handler with one handler set dispatched from
  several sites, for union argument expansion.

Count declarations, propagation and dispatch sites, and lines; check that
error context survives; and compare the diagnostics after adding, renaming,
and removing a variant or a label. Document an idiom in a tutorial only after
it has been compared this way.

## The diverging arrow's spelling

[`-> !`](design.md#diverging-procedures) means the procedure never returns
normally: `panic`, process exit, and an endless loop. It does not mean that it
returns an error, may panic, or succeeds with no payload. The fact belongs to
the declaration, not to a procedure-value type. `@(noreturn)` would state that
more literally than punctuation. `-> never` also reads well, but should be
spelled only if the language adds a real uninhabited type, with its rules for
procedure types and conversions.

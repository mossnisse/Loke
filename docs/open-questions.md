# Open questions

Decisions that are deliberately not yet made are recorded here rather than left
implicit in normative prose, along with review findings not yet acted on.
[`design.md`](design.md) defines the rules implementations must follow for the
current language version; these questions concern possible later changes. An
entry is removed once it is settled: the reasons go to
[comments.md](comments.md), and a fix to its commit message.

The current behavior inventory is in [Nondeterminism and undefined behavior
audit](nondeterminism-audit.md). The language design reviews of 2026-10-03 and
2026-10-31, and the proposals from them not yet decided, are in
[design-review-2026-10-31.md](design-review-2026-10-31.md).

## What the region and overload matrices left open

The [region matrix](../tests/region_matrix_test.odin) and the [overload
matrix](../tests/overload_matrix_test.odin) each judge the compiler against a
model of the rules written apart from it. Writing the models met two places
where [design.md](design.md) does not decide, and each model follows the
compiler there (2026-11-16):

- **A received resettable allocator beside the default provider.** A reset of
  an `@(allocator_reset)` parameter is `L0537` while an owner backed by the
  default provider is live, because a received allocator [may be any
  region](design.md#allocator-regions-and-region-provenance). No checked call
  can pass the default provider there: handing it, or an allocator read from a
  global, to such a parameter is `L0538`. So the two regions could be told
  apart, which would accept more programs and reject none. Whether that
  precision is wanted is open.
- **A pattern binding through an implicit conversion.** `proc(values: []$E)`
  called with a `[dynamic]int` or a `[3]int` binds `E` to `int` and ranks as
  the view conversion does, 3.
  [Specialization](design.md#specialization) says the argument must convert to
  the type the pattern produces, and its example calls the pattern one that
  allows only read-only slices; it does not say that binding looks through the
  conversion. The text should say which.

## Provenance architecture

A review of the root and region provenance checker on 2026-11-01 asked where its
special cases come from, and which generalizations would remove classes of them
rather than instances. One slot vector per root and per-block region sets were
tried and measured, and [not adopted](comments.md#provenance-slots-and-regions-stay-apart).
These remain. None fixes a bug or accepts a new program, except where it says so,
and estimates have been poor: the
[borrow matrix](../tests/borrow_matrix_test.odin), whose model is written apart from
the compiler, is the oracle for any of them.

- **Place loans beside root loans (P3).** A borrow of a named place is a loan
  of its root and path; one through carriers is a `Prov_Place_Loan`, a
  snapshot slot with a bit of its own, because which storage the carriers name
  is known only to the solve. So there are two conflict checks,
  `access_conflicts` on `.Access` and `check_place_loans` on `.Through`, two
  kinds of liveness bit, the marker slots of `prov_through_marker`, and two
  kinds of `Prov_Slot.borrow` that let `prov_reborrow` weaken each separately. The
  [rationale](comments.md#local-borrow-checking) kept them apart to spare every
  loan the places it is at; the offsets machinery (`Prov_Slot.offsets`,
  `prov_reaching_offsets`) now records those places anyway. The solve could
  resolve a place loan to loans of the roots its carriers reach, as
  `resolve_content_reads` already materializes loaded reborrows after the
  forward pass, leaving one check.
- **An index's syntax as evidence (P3).** `prov_indices_may_write` takes any
  index that may run a program's code to write the carrier being indexed, so a
  place written or mutably borrowed through such an index reborrows the whole
  carrier mutably (`prov_capture`), where the
  [global write effects](design.md#global-write-effects) already say what a
  call writes. A place only read is not affected: its capture is a read-only
  reborrow, which an index that reads does not conflict with. Asking the
  effects would accept more programs, not remove a special case, and a call
  may also write through an argument, which those effects do not cover.
  Whether that precision is worth an effect for writes through arguments is
  open.

### Carrier and region tracking as principles

A review of design.md on 2026-11-09 found that [Carrier
tracking](design.md#carrier-tracking) and [Region
tracking](design.md#region-tracking), about 95 lines, list cases one by one
(nested carriers, box payloads, map keys and values, literal container elements,
`inout` and variadic arguments, `or_else` and `or_return` payloads, widening,
unboxing, shared payloads) where a few general rules might cover them: every
copy, projection, wrap, and unwrap keeps the value's carrier paths and region
dependencies, a write replaces only the storage it is known to reach, and an
unresolved target keeps its uncertainty. Each case was likely added beside a
fix, so a rewrite must show that the general rules imply every listed case, and
reject nothing they now accept, before it replaces them. The two sections are
normative, so this is a careful restatement, not a cut; the
[borrow matrix](../tests/borrow_matrix_test.odin) and the
[store matrix](../tests/carrier_store_matrix_test.odin) are the checks for it.

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
  `examples/corpus_runner.loke`, even with skipped visits and lock-free scratch
  arenas ("Skipped summary visits and lock-free scratch arenas" in the
  repository's `bench/baselines/README.md`).
  A sampling profile of the builds left interning as the largest single cost:
  the key is hashed byte by byte on every value and call lookup
  (`prov_intern_value`, `prov_input_call`, about 7% of build time). The keys
  have since shrunk, to `Prov_Value_Key` and, for a call, `Prov_Call_Key`, and
  the share has not been measured again.
  The three remaining builds per body differ in callee summaries, in whether
  global writes have settled, or in reporting diagnostics; sharing one would
  need the walk's output to stop depending on them. Whether either reduction
  pays for its complexity is open.

## Compositional loan construction

Every access to a place reached through carriers goes through one walk of the
normalized place, and a borrow, slice, traversal, or switch of one takes a
**place loan** ([Ownership, lifecycle, and
provenance](compiler-architecture.md#ownership-lifecycle-and-provenance));
[borrow_matrix_test.odin](../tests/borrow_matrix_test.odin) checks the rules
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
  contracts](design-review-2026-10-31.md#public-borrow-contracts-should-stand-on-their-own).
- **Caller storage contents.** A store through a parameter's loan lands in the
  caller slots for the storage it names (`publish_into_caller`), and a later
  load reads them. The remaining imprecision: caller slots of different loans
  are taken to name different storage, so a store through one is not seen
  through another that a cyclic structure makes the same (a mutable cycle
  such as `l.next = .some(&mut l)` keeps `l` suspended, so this cannot be
  exploited); a view's slots stand for all its elements, apart from an element
  at a constant index; a record whose carriers have no one type on each path,
  stored into a view parameter's element, joins into the parameter itself; and
  storage below the second load, or through a view, is one slot.

Language changes should be evaluated separately. The proposed [written public
borrow contracts](design-review-2026-10-31.md#public-borrow-contracts-should-stand-on-their-own) could
simplify call boundaries and library exceptions, but cannot repair local
reborrow construction. Explicit reborrow syntax or move-only mutable carriers
would change ergonomics and compatibility while leaving nested place access and
implicit call reborrows to analyze. Do not adopt those changes solely to work
around the current implementation. Revisit them only with concrete examples and
a demonstrably smaller set of semantic rules.

## Compiler review findings not yet acted on (2026-11-09)

The 2026-11-09 compiler code review found this (its report,
`compiler-code-review-2026-11-09.md`, is now only in git history), and it has
no probe program that shows a wrong result. It needs a decision or a
reproduction before a change.

- **Which type a slot holds** (group 4). Four places fall back differently
  when a carrier slot records no content type: `slot_carrier_type` in
  `borrow.odin` takes the symbol's type only for the bare slot of a
  symbol, `prov_define_one_content` for any slot of an unshaped symbol,
  `prov_slot_is_mutable_carrier` for any named slot, and the link filter in
  `prov_link_retained` for one at the symbol's root. The two link filters in
  `provenance_retention.odin` also differ for a named slot of unknown type:
  `prov_link_copied_carriers` keeps it and `prov_link_retained` skips it. One
  rule would remove the differences, but each is a precision choice that needs
  a probe program before it changes.

## Compiler simplifications not yet made

A behavior-preserving cleanup of the compiler, cut on 2026-11-08 and replayed
onto `main` on 2026-11-15, found these and left them, because each changes a
diagnostic, needs a decision, or reaches further than such a cleanup should.

- **One way to report an unresolved type argument (P3).** `resolve_type_reporting`
  in [check_types.odin](../src/check_types.odin) reports only when resolving
  added no error, and `resolve_simd_application` ([simd.odin](../src/simd.odin))
  uses it. `resolve_box_application` ([box.odin](../src/box.odin)),
  `resolve_range_application` ([iterate.odin](../src/iterate.odin)) and the
  `[?]T` element in `check_composite`
  ([check_composite.odin](../src/check_composite.odin)) call
  `report_unresolved_type` unconditionally after `resolve_type_syntax`.
  Switching them would drop a second report where resolution already reported
  one; decide with a review of the affected diagnostics corpus.
- **Semantic stores on one allocator (P3).** `init_semantic_stores`
  ([semantic.odin](../src/semantic.odin)) points about 90 containers at
  `semantic_allocator` one `make` at a time, and they are spread through
  `Compiler`. Gathered into one embedded (`using`) record, `use_allocator`
  ([cfg.odin](../src/cfg.odin)) would set them in one call, though the few that
  reserve a capacity would start empty. What `destroy_compilation` deletes one
  by one, such as `parsed_files` and `diagnostics`, is not in the semantic
  arena and stays out of that record.
- **One reference walk over public declarations (P3).** `Ref_Walk`/`api_refs`
  in [doc.odin](../src/doc.odin) and `Exposure`/`walk` in
  [private_names.odin](../src/private_names.odin) both walk public declaration
  syntax by written name and keep the `$` and parameter names in scope; they
  already share `bind_signature` and `bind_generic_params`
  ([ast.odin](../src/ast.odin)). A shared walker that lets each caller decide
  what a reached name means, and where a value position stops the walk, would
  remove the parallel traversal.

## Compiler source audit follow-ups (2026-11-18)

- **Use one ordered representation for checked variadic arguments.** Carry the
  spread flag with each expression so the checker, provenance and LLVM lowering
  consume the same sequence. Preserve forwarding of a single slice and the
  existing evaluation order. [AST review](compiler-source-audit-2026-11-18.md#srcastodin)
- **Shorten the lifetime of overload-ranking alias views.** Alias expansion used
  to compare candidates allocates transient ASTs in the compilation's semantic
  arena. Measure an alias-heavy workload before assigning those views to a
  shorter-lived allocator. [Clone review](compiler-source-audit-2026-11-18.md#srcast_cloneodin)
- **Use exact hashed membership for wide integers.** Duplicate checking scans
  every previous value outside `i64`. Keep keys exact and measure generated
  switches and backed enum lookups before changing the representation.
  [Integer review](compiler-source-audit-2026-11-18.md#srcbigintodin)
- **Measure the borrow solver's allocation and rescanning hypotheses.** The
  audit lists changes it could not justify without a workload: skipping the
  loaded-below rows of a body with no cursor anchor, caching `at_once_reaches`
  per source, a visited row in `with_held_content`, marking a reaching row
  dirty only when a join adds a bit, one backing allocation per block table,
  enumerating set bits in `merge_escape_event`, per-body scratch in
  `stored_thread_facts`, and collecting an event's released loans once for
  `mark_released` and `end_loans`. Run `perf.ps1` on borrow-heavy bodies before
  and after each. [Solver reviews](compiler-source-audit-2026-11-18.md#srcborrowodin)

The [source audit](compiler-source-audit-2026-11-18.md#resolution) records
which of its findings were fixed and which were declined. The divergences it
led to that remain are in [Known gaps](known-gaps.md#gaps).

## Compiler source audit continuation

The [per-file reviews](source-reviews/README.md#review-reports) hold the
evidence for the continuation at `ea622efe`; the
[resolution](source-reviews/README.md#resolution) says what was fixed. These
points remain:

- **Settle the public contracts for two built-ins.** `unsafe.raw_data`
  accepts `string_view` and `cstring_view` beyond the documented operand list.
  The compiler and a test support `panic()`, while the built-in table requires
  a message. [Built-in checker](source-reviews/check_builtin.md#findings)
- **Type-valued conditionals in postfix position.** `(i32 if true else i64)(7)`
  reports `L0320` and `(A if true else B).member` reports `L0363`, while
  binding the conditional to a name first works. Decide whether every constant
  `type` expression denotes a type before a call or selector.
  [Expression checker review](source-reviews/check_expr.md#open-question)
- **Checked pointer to C pointer of another element type.** `([^]u64)(p)` for
  `p: ^u8` converts without `core:unsafe`, while [C pointers](design.md#c-pointers)
  describes that direction with matching element types.
  [Conversions review](source-reviews/conversions.md#simplification-and-boundaries)
- **Doc comments on a local type's fields.** Decide whether "wherever the type
  is written" in [Doc comments](design.md#doc-comments) covers a type declared
  in a procedure body. Its fields warn with `L0260` today, and hover agrees.
  [Doc comment review](source-reviews/doc_comments.md#findings)
- **Derived orderings.** A type that declares only `<` gets no `>`, `<=`, or
  `>=`: `Reverse(1) > Reverse(2)` uses `int`'s built-in `>` for
  `Reverse :: distinct int`, and on a struct it is `L0355`. Decide whether the
  other orderings follow from `<`, as sorting already does.
- **Exact unfixed decimals.** Folding them exactly needs rationals for `/`, a
  second representation through every consumer of `.float`, and a limit for
  literals such as `1e-99999999999`. The spec does not yet say how precise
  unfixed float arithmetic is. [Known gap](known-gaps.md#unfixed-decimal-literals-round-before-constant-folding)
- **Unreproduced hypotheses.** A drop hook that panics while an assignment
  drops its destination's old value may not count as a panic after a move made
  earlier in that statement. A cycle through two generic records, the inner one
  reached while the outer resolves, may leave the inner instance cached as
  successful. A literal whose type is known only after checking, such as an
  untyped argument, still counts return-name uses by the syntactic key rule.
- **Measure first.** Batching later-read queries per block in `cfg.odin`,
  ranges per binding for callback arguments, stopping carrier-shape sibling
  walks after overflow, keyed precision for slices reached through a carrier,
  a worklist for the private-declaration closure in `doc.odin`, opt-in
  provenance profiling counters, and grouping disposable compiler state for
  checkpoints. [Control-flow review](source-reviews/cfg.md#findings) ·
  [Compiler state review](source-reviews/compiler.md#findings)
- **Unifying the LLVM naming and emission walks** around one procedure
  eligibility decision. [LLVM emitter review](source-reviews/emit_llvm.md#simplification-and-compiler-boundaries)

## LLVM source review follow-ups

- **Slice literal identity.** Decide whether separate file-scope immutable
  slice literals may share a backing array when pointer equality can observe
  the sharing. Also specify the lifetime of a mutable literal's backing in a
  file-scope `thread_local` initializer. The file-scope literal rule currently
  gives the array static lifetime.
  [LLVM constant review](source-reviews/emit_llvm_const.md#equal-file-scope-slice-literals-have-observable-shared-backing)
- **Constant emission.** Use LLVM's compact spelling for all-zero union
  padding and relocation ranges. Replace arbitrary-precision union-head
  assembly with a fixed-width integer and reuse the little-endian byte
  writer. Share the carrier decisions between the typed and byte-image
  renderers if that reduces the existing duplication.
  [LLVM constant review](source-reviews/emit_llvm_const.md#findings)
- **Container emission.** Share the direct hash and equality call lowering
  while keeping the map key policy fixed by the checker. Measure miss-heavy
  `find_or_insert` before changing the runtime ABI to reuse a probe across a
  user copy hook.
  [Container review](source-reviews/emit_llvm_containers.md#simplification-and-boundaries)

## Literal elements that lend a temporary to a call

A `[dynamic]T` or map literal hands each element to the container as soon as
it is evaluated, and the element's large temporaries' slots then serve the
next one. An element that hands an address to a call keeps them until the
literal is built (`note_lent_arguments` in
[emit_llvm_cleanup.odin](../src/emit_llvm_cleanup.odin)), since the callee may
keep the address by `unsafe` means for the rest of the full expression
([Temporaries and procedure boundaries](design.md#temporaries-and-procedure-boundaries)).
Every `self: ^` method call on a temporary counts, though only a callee that
reaches `unsafe` can keep its receiver past the call. So a `[dynamic]u8`
literal of 40 elements `large(i).first()`, with a 5000-byte `Large`, takes 80
`Large` slots in the frame, two an element, where its slots were reused before
`05e2b195`; one of `first_of(large(i))` by value still takes 1 (counted in the
emitted IR on 2026-11-12). A long literal of such calls can now exhaust the
stack.

A procedure summary saying whether a call may keep an argument's address past
its return, true for any body that reaches `unsafe` or calls through a
procedure value, would keep the reuse for every other call. Whether that fact
pays for itself, or a literal of large method calls is rare enough, is open.
Found on 2026-11-07 in a review of `05e2b195` (P3).

A fixed-array or slice literal reuses no slot in either form, since only the
`[dynamic]T` and map literals end an element's temporaries
(`end_operand_temporaries` in
[emit_llvm_containers.odin](../src/emit_llvm_containers.odin)): `[40]u8{...}`
and `[]u8{...}` take 40 `Large` slots for the by-value calls and 80 for the
method calls. Whether they should reuse slots as the growable literals do is
open with the summary. Found on 2026-11-12.

## A public type's private `format`

Such a type gets the generated default for the `Formattable` slot and prints by
it in every package, its own included
([Printed forms](standard-library.md#printed-forms),
[Interface bodies](design.md#interface-bodies)). The specification leaves open:

- **Ordinary lookup of the hidden default.** Lookup of `format` on such a type
  finds only the written method: its package calls it, and an importer gets
  `L0363` rather than the default that printing uses. The alternative is to let
  an importer's lookup reach the default, as it does on a type without a written
  `format`.
- **A warning for an unused private `format`.** A public type's private `format`
  is never what printing calls, which an author may not expect. A warning at the
  declaration would say so, but would also fire for a method meant only for direct
  calls in its package.
- **A bound generic's direct call in the defining package.** There, a procedure
  bound by `where fmt.Formattable(T)` that calls `value^.format(...)` finds the
  private method by ordinary lookup, which comes before the bound, while printing
  the same value uses the default. Whether a call through the bound should instead
  reach the slot's method is part of the first question.

## JSON follow-ups

[`core:encoding/json`](standard-library.md#coreencodingjson) implements the
fully validating document parser and streaming writer; its remaining work is in
[Standard-library maturity](future-plans.md#standard-library-maturity). These
design questions stay open until a caller or a measurement settles them:

- **An event decoder.** When a caller needs one, it would share the scanner's
  token recognition and grammar transitions over contiguous input, with
  `next -> Result(Option(Event), Parse_Error)` and a `skip_value` that
  validates what it skips, consumed through a
  [fallible-source loop](standard-library.md#streaming-a-fallible-source). Borrowed
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

## Package and import versioning

Should import paths encode package versions? The current version leaves
dependency versions to the build system or package manager. A future package
design may need reproducible version selection without making source imports
depend on a particular registry.

What is decided, and why, is in
[Projects name dependencies, not versions](comments.md#projects-name-dependencies-not-versions)
and [Every file names its package](comments.md#every-file-names-its-package).

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
stale slowest. [`///` doc comments](design.md#comments), the checked-in
[interface file](compiler-guide.md#interface-files), and
[`@(intrinsic)`](design.md#intrinsic) declarations are built. The rest is a
proposal for review, not yet a plan of record: once accepted, its plan moves to
[future-plans.md](future-plans.md) and the language rules to
[design.md](design.md).

### Proposed steps

The compiler infers whether a result borrows an argument and from which
allocator it comes (the [result
contract](design.md#procedure-result-contracts)), and whether a call writes
package state (the [write effect](design.md#global-write-effects)). Neither
`-doc`, hover, nor the interface file shows them, so a reader opens the body to
learn them.

**1. Inferred facts are shown, one line each.** The interface file and hover
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
[written contract](design-review-2026-10-31.md#public-borrow-contracts-should-stand-on-their-own), once
it exists, would be shown in its place, without "inferred".

**2. Examples are tests.** `@(example=split)` marks a
[test procedure](design.md#test-procedures) that illustrates `split`, or
`Type.member` for an `impl` member, of its own package. It follows every test
rule, and in addition it may name only public declarations, because it shows
what an importer can write. The interface file lists each example by name
under its declaration (``// example: `split_on_commas` ``), and the HTML page
shows its body. The gate builds each bundled package with `-test`, so an
example that stops compiling or fails is caught.

**3. Names in doc comments are checked.** A backticked span in a doc
comment that is a name or dotted path, such as `split`, `Builder.len`, or
`mem.Allocator`, must resolve, as rustdoc's intra-doc links must. It resolves
in the documented declaration's package and imports, and also among its
parameters and, for a type or `impl` member, the type's members. A span with
any other character, such as `builder.len()` or `[dynamic]u8`, is prose and is
not checked. An unresolved name is a warning in every check, so the editor
shows it. This catches renames and removals, not wrong claims.

**4. `-doc` writes HTML for people.** A browser is on every computer, and a
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
  comments after the steps above.
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
  packages get `api.loki` by default.

## The `op`/`try_op` pair

Should a container keep both spellings of a fallible operation?
`append`/`try_append`, `reserve`/`try_reserve`, and the rest double the
container API over a failure-policy choice. Typed fallibility made the fallible
variant cheap: a `try_` operation reports failure as a `Result` rather than a
bare `bool`, over an ordinary library union with `@(failure=...)` and no
compiler-known error type. That is what makes keeping both spellings need
re-justifying. Every shipped container keeps its pair today; collapsing them is
a separate decision with its own migration.

The language pairs a fallible operation with a policy-following one in two
more places, and both keep the pair: the compiler-generated
[`clone`/`try_clone`](design.md#lifecycle-hooks-and-resource-types), for
reasons a container does not share ([`clone` and `try_clone` stay a
pair](comments.md#clone-and-try_clone-stay-a-pair)), and the allocation
built-ins `box`/`try_box`, `make`/`try_make`, and `unsafe.new`/`unsafe.try_new`
([The allocation built-ins follow the `try_`
convention](comments.md#the-allocation-built-ins-follow-the-try_-convention)).
The container pair is the live half of the question.

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

## Callable records, procedures, and closures

A record with a `call` method is the callable convention: `x(args)` calls it
([Calling a value](design.md#calling-a-value)),
[`Callable`](standard-library.md#standard-interface-catalogue) lets one generic
signature accept a procedure or such a record, a
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
contract](design-review-2026-10-31.md#thread-transfer-needs-a-visible-contract). Revisit `inout` and `move`
calls when the first API takes such a callable; the receiver mode is then
written, for example on the clause.

### Returning a capture literal

No signature can name a capture literal's type, so it cannot be returned or held
in a file-scope type. A callable that is returned or kept past its frame is
either a file-scope record written by hand or an owning erased value under
[Owning runtime polymorphism](#owning-runtime-polymorphism). Revisit when the
first returned closure is needed. One answer then is an opaque result type,
`-> some Callable(proc(a, b: int) -> bool)`, as Rust's `-> impl Fn`
is; it makes a caller depend on the body for the result's size, which works
against [Public borrow contracts should stand on their
own](design-review-2026-10-31.md#public-borrow-contracts-should-stand-on-their-own), and it overlaps an
owning `dyn`. A literal that can be returned could also be a constant's value,
which [compile-time evaluation](design.md#compile-time-procedure-evaluation)
keeps out today; decide that with the returned closure.

### A mutable callable view

A [`dyn proc` view](design.md#borrowed-callable-views) is read-only, since a
`call` takes a plain `self`. Revisit `dyn mut proc` with the `inout` call in
[What a capture literal's `call` cannot
do](#what-a-capture-literals-call-cannot-do): a callable that keeps mutable
state inside itself would need a mutable view to be called through one.

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

Two refinements of [Globals while tasks run](design.md#globals-while-tasks-run)
are open, each a relaxation that would reject nothing accepted now:

- **A task's own write of a global.** A task may not write file-scope or
  `static` storage even when no other task and not the parent touches it. The
  parent's side became a reservation; the task's would need the parent's reads
  across the window as well as its writes, each other task's effects, and the
  same spawn's earlier iterations, as an allocator reservation has.
- **Which borrows reserve a global for every task.** A global whose borrow is
  returned, retained, sent, or stored through a carrier is reserved by every
  task, wherever that happens and whether or not a task can find the borrow.
  So a global behind an accessor such as `input :: proc() -> ^Input` stays
  unwritable by the parent in a window. A returned borrow could stop counting
  where every call of the procedure is direct, since its callers then hold a
  loan that names the global; a stored one would need the destinations
  followed.

Higher-level constructs are a separate question: futures or a similar composable
asynchronous result, and language help for reactivity, such as a procedure rerun
when a variable it reads changes. Each needs a use of its own: borrowing across
a join is not one, since [structured
concurrency](design.md#structured-concurrency) already answers it
([reasons](comments.md#tasks-that-borrow-joined-by-their-block)).

## Lent storage whose owners cross threads

A [channel](standard-library.md#channels)'s `send` checks its item as an
argument crossing to another thread: it may own nothing backed by an allocator
the sending procedure received (`L0726`,
[`@(cross_thread)`](design.md#cross_thread)). A helper that is lent a queue and
sends what it holds is therefore rejected, since the queue's elements may be in
any region its caller chose:

```loke
send_all :: proc(send: ^thread.Sender(Job), queue: inout [dynamic]Job) {
	for (queue.len() > 0) {
		job := queue.remove(0);
		_ = send.send(move(job));   // L0726
	}
}
```

The rejection is right as the language stands, and so is the same loop over a
queue in a record lent `inout`. Only a `move` parameter can carry the promise
that its argument may cross: written
`@(cross_thread, escape=static) queue: move [dynamic]Job`, the loop compiles,
and each call checks the queue it hands over. On an `inout` or borrowed
parameter the attribute is `L0723`. A program meeting this keeps the queue as a
local of the procedure that sends, or gives the queue away. Raised on
2026-11-12 by a worker library whose bursts each wanted a queue in a record
that helpers are lent.

What is open is whether a lent parameter may carry such a promise, and how it
is spelled:

- **`@(cross_thread)` on an `inout` or borrowed parameter.** It would mean that
  what the argument owns may cross, and each call would check the argument's
  regions and types as the `move` form does. It would not need
  `@(escape=static)`: the container stays with its caller, and `send` still
  checks each item's borrows. Like the `move` form it is part of the procedure
  type and spreads up the call chain, every caller either owning the storage or
  marking its own parameter. The attribute would then mean two things, an
  argument that goes to another thread and one whose contents may.
- **A bound on the argument's regions under its own name.** The promise is that
  the argument is backed only by regions that accept concurrent use. Stated so,
  it also answers two rejections under
  [Allocators and tasks](design.md#allocators-and-tasks) that have no spelling
  now: a received allocator used by two tasks, and tasks that each fill one
  slot of a received slice (`L0732`). One attribute for the three would be
  named for the regions, not for the crossing.
- **A promise on a field.** A record field declared to hold only such storage
  would let the record be lent with no mark on each helper. Every write to the
  field would have to be checked, which is an invariant on storage where
  [region provenance](design.md#allocator-regions-and-region-provenance) today
  has only facts about values. It is the largest of the three.

Not open: `send` taking its check on trust for a lent queue. An owner backed by
a caller's arena would then be freed on another thread while the caller
allocates from it.

A second program that wants to lend a queue it sends from, or a helper that
fans tasks out over storage it received, should decide between the first two.

## Thread-affine strings

`string` is an owning value whose copies share immutable backing storage, and
a string may be dropped on any thread that received it, so the shared handle
count is atomic: [`runtime/text.c`](../runtime/text.c) retains with a relaxed
atomic add and
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

## What a file-scope `when` waits on

[when statement](design.md#when-statement) makes a condition that calls
`is_copyable` wait while any pending branch in its package or one it imports
holds a lifecycle hook, whatever type the hook's block is for. So
`is_copyable(int)` in one package waits on `impl H { d :: hook(drop) ... }` in a
`when` of a package it imports, and is an error when that `when` stalls, though
no hook of `H` could change the answer. The same coarseness applies to a member
whose receiver the walk cannot type, which waits on any pending block declaring
a member of that name. Narrowing either needs a rule for which subjects a block
may extend: the subject is a type expression that may itself wait, alias
another, or be generic. Found on 2026-11-07 while reviewing `6017278d`.

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
[`or_return`](design.md#or_return-operator). Nothing in
[design.md](design.md) requires it.

## Intrinsics and inline assembly

How should a program reach the instructions the language does not express,
to use SIMD and other hardware features fully: compiler intrinsics, inline
assembly, or both? `Simd(T, N)` covers lane-wise arithmetic; what it leaves
out is the target-specific instruction.

## LLM optimization

Could the syntax be made token-efficient for language models without making
it worse for people? How a model reads and writes code differs from how a
person does: models are trained on human-written code yet process it
differently. Encapsulation and abstraction stay important either way, so that
a model can work on one part of a program without reading the rest.

## Open questions in `core:strconv`

- `parse_f64` rounds through the C library's `strtod`, as `fmt` already does to
  find its shortest spellings. That makes it foreign code, which
  [Compile-time procedure evaluation](design.md#compile-time-procedure-evaluation)
  keeps out of constants for good. Both now run in a fixed "C" numeric locale, so `setlocale` through a foreign
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
[the oracle](../tests/math_oracle.odin)), and `sinf` and `cosf` of an infinity
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

### Integer bit operations not yet provided

[Integer bit operations](standard-library.md#integer-bit-operations) has the
counts, the bit width, the rotations, the reversal, and the power-of-two
operations. Left out until a caller settles their contracts:

- **Lane-wise forms.** LLVM's `ctpop`, `ctlz`, `cttz`, `bitreverse`, and
  funnel shifts take vectors, so a `Simd(T, N)` operand could count lane by
  lane. The result type is the question: a `Simd(int, N)` widens every lane
  past the operand's, and a `Simd(T, N)` is not an `int` as the scalar forms
  are. The checker refuses a vector today, so either choice can be added.
- **Bit field extract and deposit** (`pext` and `pdep`), which exist only from
  `x86-64-v3` and would need a portable fallback with the same result.

## Alias facts for the optimizer

The emitter writes `nonnull` on pointer parameters and nothing else, and a
slice parameter carries no attribute at all. Yet [the one
rule](design.md#capabilities-and-the-one-rule) promises a great deal: while a
borrow is live its root is not written through any other path, and a mutable
borrow excludes every other access. So for the duration of a call:

- a `^mut T`, `inout T`, or `self: ^mut` parameter is the only live path to its
  pointee;
- a `^T` parameter's pointee is written by no one, unless its type reaches a
  [`@(synchronized)`](design.md#synchronized) field, as `Atomic(T)`, `Mutex(T)`,
  and `Monitor(T)` do;
- a `value: T` parameter passed by pointer, which is one over 4096 bytes, is
  under the same exclusion unchanged.

The language design review of 2026-10-31 proposed giving the optimizer these
facts, and settled their form. The programs behind each claim are in its
[probes](design-review-2026-10-31.md#probes).

**The form is scoped metadata, not `noalias`.** A `noalias` parameter says that
nothing else reaches the pointee while the procedure runs, the panic call
included. Under the default `unwind` strategy that is false: the runtime runs
every frame's cleanup inside the panic call
([runtime/panic.c](../runtime/panic.c)), so a caller's drop hooks and `defer`s
read its locals while the callee still holds the pointer. LLVM then drops a
store before the panic as dead, and a drop hook prints `0` where
[Panic strategy](design.md#panic-strategy) requires `3`; an `inout` dynamic
array grown before a panic would be freed twice. `!alias.scope` and `!noalias`
metadata on the body's loads and stores say only that those accesses do not
overlap. The panic call carries none, so LLVM still treats it as reading
everything. The metadata also leaves the calling convention alone, so a slice
needs no split into scalar parameters. What it cannot give is what `noalias`
gives across a call: a callee not passed the pointer is still assumed to reach
the pointee. That remainder is all that `-panic=abort` would add, and it is not
worth a second set of optimization semantics.

**No capture attributes.** Escape levels restrict retained borrows, not
observed addresses: a procedure may return whether two pointer arguments are
equal, which LLVM counts as [address
capture](https://llvm.org/docs/LangRef.html#address-capture) though no borrow
survives. Every Loke procedure is `internal`, and LLVM already infers
`readonly` and `captures(none)` where they hold.

**Facts between parameters buy little.** Measured on 2026-11-16 by adding the
metadata by hand and comparing the IR Clang 22 leaves at `-O2`; nothing was
timed, and the `bench/` kernels were not touched:

| Loop | As emitted | With metadata between parameters |
| --- | --- | --- |
| Two slices, `dst[i] = dst[i] +% src[i]` | Vectorized behind the overlap check LLVM inserts | Not run: at most that one check per entry to the loop |
| A record parameter read in the loop | Vectorized: a value up to 4096 bytes is passed by value | Nothing to gain |
| An `inout` scalar updated beside a slice store | 4 loads and 2 stores per iteration | 2 loads and 2 stores |
| A store through `self.data` beside `self`'s own fields | 5 loads and 2 stores per iteration, not vectorized | No change |

Two things are missing. Hoisting a load above a bounds check needs the pointer
parameter to be `align`ed and `dereferenceable` as well as `nonnull`: with
both, the `inout` scalar is loaded once before the loop, and its store stays in
the loop because the panic must see it. Alone, the two attributes change
nothing. And the last row is the shape most container methods have. Its store
goes through a pointer loaded from `self`, which facts between parameters leave
as one that may alias anything. Only with a further fact, that storage `self`
owns does not overlap `self`, do the loads leave the loop, and then it
vectorizes.

A program already has the fast form with every check kept: copy the scalar
into a local before the loop and write it back after.

Open:

- Is the further fact true, and for which fields? An owning field such as a
  `[dynamic]T`'s storage is a separate allocation. Whether a stored `^mut T`
  or `[]mut T` can point into the record that holds it is for [Values that
  contain borrows](design.md#values-that-contain-borrows) to answer, and
  unchecked code can make either overlap.
- Does it pay? With that fact and the two attributes, measure on the `bench/`
  kernels, after [Overflow checks in index
  arithmetic](#overflow-checks-in-index-arithmetic), whose branches block
  vectorization before aliasing does.
- What unchecked code must then promise. [What is not
  checked](design.md#what-is-not-checked) would have to say that it may not
  make two checked carriers that break the one rule. A cast that only drops
  provenance, as `Channel`'s `queue_of` does, needs no audit, and an access
  through a `rawptr`, a C pointer, or a pointer of unknown provenance gets no
  metadata.
- The metadata turns a borrow the checker wrongly accepts into undefined
  behavior that the optimizer exploits. [known-gaps.md](known-gaps.md#gaps)
  listed no borrow-checker gap on 2026-11-11, but several were found and
  closed in the ten days before, so it would be emitted behind an option until
  "none known" has held for a while.

## Targeting x86-64 levels

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

- Should v4 and `native` follow? v4 needs AVX-512 hardware to test on, and
  `native` resolves to a feature set of its own rather than a level.

## Open questions from the linear algebra spike

A spike tried `linalg`'s `Real` interface and generic matrix shapes against
the compiler ([tests/pkg/real_interface](../tests/pkg/real_interface)) before
[`core:math/linalg`](standard-library.md#coremathlinalg) and then
[`core:math/dense`](standard-library.md#coremathdense) were built on them.
These language questions came out of that work, and the libraries cannot
settle them by themselves.

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
[`split_at_mut`](standard-library.md#splitting-a-mutable-slice) does. That works only
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

The checked operators panic on overflow
([Integer overflow](design.md#integer-overflow)), and a branch per element
keeps the optimizer from vectorizing a loop, even where the induction
variable and the bound make an overflow impossible. A signed sum or
difference written as an index no longer has a branch of its own: its
overflow is tested behind the bounds comparison
([Runtime and library boundary](compiler-architecture.md#runtime-and-library-boundary)),
and LLVM vectorizes past that, so `xs[i + offset]` and `xs[i - offset]` in a
loop cost what the wrapping forms do. Three shapes still pay, measured on
2026-11-16 after `c2645cd2` with Clang 22.1.8:

- **A check that does not vary in the loop, behind one that does.**
  `hand_multiply` in `bench/dense.loke` writes
  `out[i + j*n] = out[i + j*n] + a[i + k*n]*factor`. The checked `k*n` comes
  after the bounds comparison of `out[i + j*n]`, so LLVM hoists the
  multiplication and leaves the branch on its overflow in the loop. It removes
  that by unswitching the loop, which Clang does at `-O3` only: eight products
  of 256 by 256 matrices take 38 ms at `-opt=aggressive` and 102 ms at
  `-opt=speed`. A bounds check that does not vary, `b[round]` after
  `a[r*n + c]`, is held the same way. A program avoids it at `-opt=speed` by
  writing `j*n` and `k*n` before the inner loop, or by slicing once and
  indexing from zero, `column := out[mut j*n : j*n + n]` and then `column[i]`:
  38 ms and 36 ms. `-O2` with `-mllvm -enable-nontrivial-unswitch` vectorizes
  each kernel that `-O3` does; the IR was read, and nothing was timed. Open:
  whether `-opt=speed` should pass it, for what build time and code size.
- **An operation below the last one.** In `xs[base + i + 1]` the inner
  `base + i` keeps its branch. The bounds comparison cannot stand in for it,
  since a valid index may pass through a negative result, as `xs[i - 10 + 20]`
  does, and a sum that wrapped looks the same. `xs[i + (base + 1)]` is the
  fast form.
- **A product**, which can wrap to any index.

Proving the common shapes overflow-free (an index affine in loop variables
whose ranges are known before the loop) does not reach `hand_multiply`, where
nothing bounds `n` before the loops; versioning the loop would, at the cost of
a second copy of it. A descending index, `xs[last - i]`, is not vectorized
with `-%` either, so its checks are not what holds it.

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

## Formatting

The current formatter rules and rationale are in [comments.md
"Formatting"](comments.md#formatting).

Open: aligning columns automatically, as `gofmt` does, so a renamed field
does not leave its neighbors misaligned; indenting a continued line inside
brackets, which `core/` leaves at the bracket's level; and indenting the later
values of a wrapped multi-value statement (`x, y :=` above `1,` and `2;`), whose
commas read as a list's, since the tokens do not tell a block's `{` from a list's.

## Error handling (2026-10-13)

What the adopted error handling proposal left open:

- **A replacement that discards information.** `f() or_return .Bad` drops the
  error `f` returned. That is explicit at the site, as the switch it replaces
  was, but when the error is not an enum a lint could ask for a mapper.
- **Binding the error in `errdefer`.** Zig's `errdefer |err|` names the error
  being returned. An `errdefer` reads locals today; binding needs a syntax and
  a rule for an error that has moved into the result.

## Anonymous unions and their follow-ups (2026-10-18)

What the adopted proposal left open; [comments.md](comments.md#anonymous-unions)
records why it was adopted.

### Generic implementations on structural shapes

A parameter's anonymous record or union binds its `$` names by label
([Specialization](design.md#specialization)), but an `impl` subject does not:
`impl (a: $T, b: $T) { ... }` is `L0437`, since a generic `impl` names a
generic record's application, as `impl Pair($T, $T)` does. An `impl` over a
shape would be an [extension](design.md#methods-and-implementation-blocks)
whose subject is a pattern, which method lookup does not match today. Revisit
when a program wants methods on a family of shapes.

### Parametric aliases

What [Parametric aliases](design.md#parametric-aliases) left open:

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
payload types. In [examples/orders.loke](../examples/orders.loke), `Order_Error`
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
  which is also the order reflection reports.
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

What [per-variant switch cases](design.md#per-variant-switch-cases),
[`variants_of`](design.md#compile-time-reflection), and
[union argument expansion](design.md#union-argument-expansion) left open:

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

## Growable container follow-ups

Questions left by [`Priority_Queue` and `Deque`](standard-library.md#priority-queues),
none of which they wait on.

- **A dynamic array's allocator.** `x.allocator` is not a member, which is the only
  reason `Deque` has its own field. An `x.allocator()` query would remove it, and
  would help any library container that replaces its storage. Is the query worth
  having for its own sake?

## Last-use transfer into a container, `box`, or `shared`

[Last-use transfer](design.md#last-use-transfer) moves a local that a binding or
an assignment would clone, itself or as an operand of the construction bound,
when nothing reads it again. A
[container insertion](design.md#container-insertion), `box`, and `shared` take
their operand as an initialization does and still clone it, so
`out.append(list);`, `out.append(Pair{list, 1});`, and `node := box(list);`
allocate at `list`'s last use unless `move(list)` is written.

Extending the transfer to them is open:

- **Which allocator.** A clone into a container allocates from the container's
  provider, and a `box` or `shared` from the allocator it is given. A move keeps
  the local's own allocator, so the element could be backed by a different
  region than the container holding it. A binding keeps the clone when its
  destination has a `via`, which is written at the declaration; a container's
  provider belongs to its value, and the lifecycle analysis that decides the
  transfer does not know it.
- **Arguments.** An insertion is a call, and an argument of a `move` parameter
  needs a written `move` so that the call shows what it gives away. A transfer
  at an insertion would be the one argument that moves unwritten.

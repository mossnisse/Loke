# Open questions

Decisions that are deliberately not yet made are recorded here rather than left implicit in normative prose. [`design.md`](design.md) defines the rules implementations must follow for the current language version; these questions concern possible later changes.

Design rationale and differences from Odin are recorded in [comments.md](comments.md).

## Normalized input for provenance analysis

Provenance analysis reads a
[normalized body](compiler-architecture.md#normalized-provenance-input) that it
rebuilds once per analysis invocation, consuming settled lifecycle
annotations. Three decisions remain open:

- **Retaining normalized bodies.** Whole-program summary visits rebuild each
  body. Keeping the normalized input across visits would trade memory for the
  repeated normalization; measure both before deciding.
- **Lifecycle analysis on the same input.** Lifecycle analysis still walks the
  checked AST, and provenance consumes its settled decisions. Moving it onto the
  normalized input needs its own design for unresolved cleanup and last-use
  decisions.
- **The cost of normalization.** Against the measurements taken before the
  normalized input was introduced, checking costs 7–14% more front-end time on
  the selected workloads and 3–10% more per workspace LSP operation, while
  compiler peak working set is 5–10% lower on the larger workloads.
  Normalization is the largest provenance phase in the
  [current records](bench/baselines/README.md#completed-migration-stage-5).
  Whether to accept that cost or reduce it is open.

### Checker architecture review (2026-10-26)

The separation between normalized input, monotone fact replay, and the loan
solvers is useful. Keep that boundary and its semantic inspection tests.
The `exchange` result that had no transfer of its own, now described with the
other checked transfers, showed that their coverage needs attention; it did not
justify introducing a general-purpose intermediate representation.

Its three small simplifications are applied (2026-10-26). The indirect load
that `prov_written_aliases_at` and `prov_read_value_aliases` both repeated is
one procedure, `prov_load_aliases` in
[provenance_read.odin](src/provenance_read.odin). Each caller keeps its own
storage lookup and its own treatment of uncertainty. A read that finds nothing
at all is unresolved when it may find unnamed storage; a write's lookup needs
a root for direct storage. The materialization no longer sorts replacements it
already appends in recorded order. `region_merge_grows` is replaced by
`merge_region_provenance`. Diagnostics match on all 1350 corpus inputs.

The structural follow-up is done too (2026-10-26). The facts a round carries
are an explicit `Prov_Facts`, embedded in each graph's state, and the
body's topology is an explicit `Prov_Topology` in the program; see
[Normalized provenance input](compiler-architecture.md#normalized-provenance-input).
`prov_carry_facts` deep-copies only the facts, instead of returning a partly
initialized `Flow_Graph`, and `prov_fact_weight` counts the same five maps.
Fact graphs no longer copy `lent_locals` as topology, since seeding supplies
them. Diagnostics match on all 1350 corpus inputs, and
`normalization_fact_carry_contract` checks that a carry is an independent copy
that seeds the same weight. Fact replay counts are unchanged. `perf.ps1`
measured front-end time within 7% either way, and `-o:speed` builds of both
compilers matched within 1% on `bench/workspace` and `corpus_runner`. Retaining
normalized bodies across whole-program visits remains the separate decision
above.

## Package and import versioning

Should import paths encode package versions? And should a package declaration remain mandatory in every file, when every file in a directory must name the same package anyway, or is it ceremony? The current version requires the declaration and leaves dependency versions to the build system or package manager. A future package design may need reproducible version selection without making source imports depend on a particular registry.

Decided so far, and built as `loke.project` (compiler-guide.md "Projects"):

- Imports carry no version and no location. A project gives each dependency a
  name, and the name is a collection prefix: `import "json:parse";`. Where
  `json` comes from is the project's business, so moving or vendoring it
  changes one manifest line and no source.
- One name names one directory in the whole program, across every
  dependency's manifest. A conflict is an error rather than two copies of a
  package, because two copies would give one type two identities. The names
  are one flat space, so a program can import a dependency of a dependency
  without requiring it; a later version may require the direct `require`.
- The manifest is plain `require <name> <path>` lines, trivial to parse now and
  in a self-hosted compiler.
- Dependencies are local directories. When versioned sources arrive (a git
  URL and tag, fetched into a cache outside the compiler front end), the
  version chosen is the highest minimum any manifest asks for, as Go's minimal
  version selection does: deterministic without a solver. Version selection
  alone does not pin source content: the lock must record the selected source,
  version, immutable commit ID, and content checksum for every dependency, as
  planned in [Packages and dependencies](future-plans.md#packages-and-dependencies).

### Review (2026-10-21)

The local-directory workflow is implemented; versioned resolution is still a
direction. These findings concern the choices needed before extending it, not
compiler divergences from the current specification. The lock, offline builds,
and explicit update boundary are already covered by
[Packages and dependencies](future-plans.md#packages-and-dependencies).

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
- **Qualify the one-manifest-line vendoring claim.** A root manifest with
  `require consumer ../consumer` and `require json vendor/json` conflicts with
  a `consumer/loke.project` containing `require json ../json`: the vendored
  and original directories differ. A compiler probe reports `L0399`; passing
  `-collection json=<vendored-directory>` instead succeeds, as
  [Projects](compiler-guide.md#projects) documents. Updating one manifest line
  therefore works only when the remaining requirements still name the same
  directory. If manifest-only vendoring must also replace a shared transitive
  dependency, define a root replacement rule separately from ordinary
  requirements. Otherwise document that the explicit collection override is
  required for this case.

## Using a package without reading its code (proposal, 2026-10-21)

To use a package today you read its source. Hand-written documentation does
not fix that, because nothing checks it and it goes stale. The proposal: what a
package tells its users is generated from its source, checked by the compiler,
or run by the test runner, and prose is kept for intent, which goes stale
slowest. It is a proposal for review, not yet a plan of record: once accepted,
the implementation plan below moves to [future-plans.md](future-plans.md) and
the language rules to [design.md](design.md).

### What exists and what is missing

[`lokec -doc`](compiler-guide.md#common-options) prints each public
declaration's signature, derived from source, with the comments directly above
it, and hover shows the same ([Language server](compiler-guide.md#language-server)).
A signature already says how to call a procedure and, through its
[fallible union](design.md#typed-fallibility), how it fails. Four problems
remain, measured on the bundled packages on 2026-10-20:

- **Nobody runs `-doc`.** People and agents open the package's folder and read
  what is there, and a command they must first learn about loses to that.
- **The comments serve two audiences.** Comments are 53% of `-doc`'s output
  over 14 `core` packages, and about 40% of that prose is for maintainers:
  spec citations, how an operation is implemented, why an overflow cannot
  happen. `core:strings`'s `index`, for example, is documented only by a note
  on its search algorithm. The rest says what no signature can, such as that
  `core:strings` counts bytes or that `sort` is not stable.
- **The format costs tokens.** The Markdown headings and code fences are 11%
  (`core:fmt`) to 20% (`core:container`) of a page, and the heading repeats the
  name the signature starts with.
- **Inferred facts are hidden.** The compiler infers whether a result borrows
  an argument and from which allocator it comes (the
  [result contract](design.md#procedure-result-contracts)), and whether a call
  writes package state (the [write effect](design.md#global-write-effects)).
  Neither `-doc` nor hover shows them, so a reader opens the body to learn
  them.

### Proposal

**1. `///` marks a doc comment.** A line comment that starts with `///`, but
not `////`, is a doc comment. It documents the declaration, field, enum
member, or `package` clause directly below it, with no blank line between, and
is the only comment that `-doc`, hover, and the interface file show. `//` is
for maintainers and is never shown. A doc comment is still whitespace to the
grammar, so it changes no program's meaning. A `///` that documents nothing,
such as one inside a body or above a blank line, is a warning. Block comments
are never doc comments.

The author decides the audience once, where the comment is written. Neither an
attribute such as `@(doc="…")`, which needs escaping and long strings, nor a
prefix such as `// doc:`, which a typo silently drops, does this as cheaply.
The package overview is the `///` above a `package` clause, so no second
marker such as Rust's `//!` is needed. There is no transition period: the
bundled packages are converted in the same change, and in them a spec citation
belongs in a `//` comment, which `check-citations.ps1` enforces.

**2. Each package directory holds a checked-in interface file, `api.loki`.**
`lokec <dir> -api` writes it: Loke source with every public declaration and no
bodies, in the order of the package's file names and then source order. For
example (shortened, and with illustrative contracts):

```loke
// Generated by `lokec -api` from this directory's .loke files. Do not edit.

// UTF-8 algorithms and efficient construction. Every index and length here
// is a **byte offset**; nothing in this package counts graphemes.
package strings;

import "core:mem";

// A growing buffer finished as one immutable `string`. The zero value is a
// usable, empty builder that allocates from the default provider.
String_Builder :: struct {
	// and fields private to the package
}

// A builder whose buffer and finished string come from `allocator`.
// inferred: result is backed by `allocator`
init :: proc(allocator: Allocator = mem.default_allocator()) -> String_Builder ---;

// Every part between occurrences of `separator`, left to right.
// inferred: result borrows `text` and `separator`
split :: proc(text: string_view, separator: string_view) -> Split_Iterator ---;
```

- **Found without a command.** Listing the folder, the editor's file tree,
  grep, and a code host all show it. An agent reads or greps it, so `-doc`
  needs no index or single-entry form for agents.
- **Checked, so it cannot go stale.** `lokec <dir> -api-check` writes nothing,
  names the file if it differs from what `-api` would write, and exits 1, as
  `-fmt-check` does. The gate runs it for every bundled package, as Kotlin's
  API dumps and Android's `api/current.txt` are checked.
- **Reviewed.** A change to the public API, or to an inferred fact, shows as a
  diff of `api.loki` in the commit that makes it.
- **Output only.** The compiler never reads it, so the source stays the one
  authority and Loke does not get C's two copies of every signature, which
  [Hand-written package header files](comments.md#hand-written-package-header-files)
  rejects. The `.loki` extension keeps it out of the package, whose files are
  its `.loke` files.
- **Parses and is formatted.** It is valid Loke syntax that `-fmt` leaves
  unchanged, though it is never checked. Its comments are written `//`: every
  comment in the file is for the package's users, so `///` would mark
  nothing. In it, a procedure ends in `---`, the existing
  [bodiless form](grammar.md#procedures). A struct shows its public fields and
  notes that private ones exist; enums and unions show their
  members. An `impl`'s public members appear inside `impl Type { … }` and a
  foreign block's as plain declarations. The file imports exactly the packages
  its signatures name.
- **Target-independent.** A public declaration inside a file-scope `when` is
  written inside the same `when`, with its condition as written, so the file
  does not depend on the target or the defines that generate it. In the
  bundled packages, `core:fs`'s `Directory_Reader` and its members are the
  only public declarations inside a top-level `when` today.
- **Private types only where an importer meets them.** A public-default file
  makes an `impl` member public even when its type is package-private, so
  `-doc` used to list members no importer can reach, such as the 28 of
  `core:time`'s `Text` and `Scanner`. Hiding every member of a private type
  would also hide the methods of a private type that a public procedure
  returns, which an importer does call. So an `impl` of a private type is
  shown, after a comment saying the type is private, only once a shown
  declaration names the type, and `-doc` follows the same rule. No bundled
  package returns a private type today.

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

**5. Names in doc comments are checked.** A backticked span in a `///`
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

### Implementation plan

Each step is one or more commits that update the spec, implementation, tests,
citing comments, and CHANGELOG together, and passes `.\test-all.ps1`. The
steps are in priority order; each is usable without the next.

1. **`///` doc comments** — done on 2026-10-21.
   - [design.md "Comments"](design.md#comments): define a doc comment and what
     it documents, and the warning for one that documents nothing.
   - `src/doc.odin` `doc_comment`: take only `///` lines and strip `/// `.
     Hover (`query_documentation` in `src/queries.odin`) uses the same
     procedure, so it follows.
   - A warning, with a new diagnostic code, for a `///` that documents
     nothing.
   - Convert `core/` and `base/` by hand, one commit per few packages: usage
     prose becomes `///`; implementation notes, spec citations, and to-do notes
     stay `//`, below the doc comment or in the body.
   - `check-citations.ps1`: report a spec citation in a `///` comment in
     `core/` or `base/`.
   - Tests: `tests/doc/` cases in `///`, plus cases for `////`, block
     comments, and a misplaced `///`; an LSP hover test.
   - [compiler-guide.md](compiler-guide.md): `-doc` and hover say `///`.
     CHANGELOG: a Changed line and an upgrade note, since existing `//` doc
     comments stop being shown.
2. **The interface file** — done on 2026-10-21. Cases are directories under
   `tests/api/` whose checked-in `api.loki` files are the goldens, so
   `-api-check` is the comparison. `loke-lsp` already ignored every document
   that is not a `.loke` file, and the extension now sends it only those.
   - `src/doc.odin`: an interface writer beside the Markdown one, sharing
     visibility and the struct view: package clause and overview, the imports
     its signatures name, `---` bodies, `impl` blocks, enum and union members
     with their `///` comments only, and `when` blocks as written, whose
     declarations take their visibility from written attributes as a generic
     record's fields do.
   - `src/main.odin`: `-api` writes `api.loki` in the root's directory and in
     each project package's; `-api-check` writes nothing and exits 1 on a
     difference.
   - Generate and check in `api.loki` for every package in `core/` and
     `base/`, subpackages such as `core/encoding/json` included.
   - Tests: `tests/api/*.loke` cases with `.loki` goldens; a corpus test that
     runs `-api-check` on every bundled package; a check that every
     `api.loki` parses and that `-fmt-check` accepts it.
   - Editor: `editors/vscode/package.json` maps `.loki` to the `loke`
     language, and `loke-lsp` ignores `.loki` documents rather than checking
     them. `loke.documentation` answers the interface text, and
     `extension.js` opens it as a `loke` document.
   - AGENTS.md: to use a package, read its `api.loki`; read its source only
     to change it, and regenerate the file with `-api` after a public change.
   - [compiler-guide.md](compiler-guide.md) documents `-api` and `-api-check`,
     [compiler-architecture.md](compiler-architecture.md) the writer, and
     [comments.md "Hand-written package header files"](comments.md#hand-written-package-header-files)
     why the file is generated and never read. CHANGELOG: Added.
3. **Inferred lines.**
   - `src/doc.odin`: the result contract from `result_summary`
     (`src/borrow.odin`) and the write effect from `c.global_writes`
     (`src/global_effects.odin`), turned into the phrasings above; hover adds
     the same line.
   - Regenerate every `api.loki` and read the diff: each line is a claim
     about a bundled procedure, and a surprising one is a finding for
     `known-gaps.md` or for the procedure.
   - Tests: a case for each phrasing, a generic procedure and a `when`
     declaration getting none, and a procedure with nothing to report.
   - [releasing.md](releasing.md): a changed `inferred:` line in a bundled
     package is listed as a possible break. CHANGELOG: Added.
4. **Examples.**
   - [design.md "Test procedures"](design.md#test-procedures): the `example`
     attribute, what it may name, and that it is a test in every other way.
   - Checker: resolve the named declaration, and report a private name used
     in an example's body.
   - `src/doc.odin`: the `// example:` line in the interface file.
   - Gate: a corpus test that runs `-test` on every bundled package with
     tests. None has any today.
   - Write a first few examples in `core:strings` and `core:container`.
     CHANGELOG: Added.
5. **Checked references.**
   - Resolution of backticked spans in `///` comments in the scopes above, a
     warning code for an unresolved one, and the scope rule in design.md
     "Comments".
   - Fix what it reports in `core/` and `base/`.
   - Tests: resolved and unresolved names, a parameter, a member, and prose
     spans that are not checked. CHANGELOG: Added.
6. **HTML `-doc`.**
   - A new `src/doc_html.odin`: pages, anchors, coloring from the lexer's
     tokens, links from the checker's resolution of each name in a signature,
     the comment subset, and examples' bodies.
   - `src/main.odin`: `-doc` writes the directory, with `-o` to choose it.
     The Markdown writer and `tests/doc/`'s Markdown goldens are removed.
   - Tests: an HTML golden for one case, and a check that every link on every
     bundled package's page has a target.
   - [compiler-guide.md](compiler-guide.md): `-doc` and the comment subset.
     CHANGELOG: Changed, with an upgrade note for scripts that read `-doc`'s
     Markdown.
7. **Compiler-contributed declarations**, which fixes
   [`-doc` omits compiler-contributed declarations](known-gaps.md#-doc-omits-compiler-contributed-declarations).
   Declare each name that `src/stdlib.odin` contributes, such as all of
   `core:mem`'s, in its package's source with a `---` body and an attribute
   binding it to the compiler's implementation, as Rust declares its
   intrinsics, so its signature is written once, checked, and shown.

### Still open

- **Allocation.** Whether a call allocates at all is what a caller with an
  arena or a hot loop most wants to know, and the result contract does not
  answer it. It needs its own inferred effect, and then an `inferred:`
  phrasing.
- **Signatures Loke cannot state.** Step 7 leaves operations such as
  `unsafe.transmute`, whose typing no Loke signature expresses, without a
  declaration.
- **Interface files outside the repository.** Whether a project's own
  packages get `api.loki` by default, and whether `loke.project` should name
  the packages `-api-check` covers.

### Interface-generator review (2026-10-21)

A review of `7cc087d`, "Generate a checked-in interface file, api.loki, for
each package", found five correctness problems whose original reproductions
were fixed in `1eef98d`:
comment filtering that joined tokens, imports moved out of their `when`
branch, foreign members that lost the block's convention and result
requirement, public overload groups whose private members were not shown, and
private-type reachability decided by spelling. As the review recommended, a
reference is now followed to the declaration the checker resolved it to, and
by written name only in syntax the checker never resolved. Imports are the
exception: the checker rewrites `mem.default_allocator()` into a reference to
the procedure, so the imports the written text needs are found in that text.

**Should a public declaration be allowed to name a private one?**
[Exported names](design.md#exported-names) does not forbid it, and following
references showed the bundled packages doing it in three ways, which the
interface files now show, marked private:

- a public field of a private type: `fmt.Padded`'s `fill: Fill`. An importer
  can read and write the field but cannot name its type, so it cannot declare
  a `Fill` variable or pass one through its own procedures;
- a private procedure in a public `where` clause: `core:time`'s `is_styled`;
- private procedures behind a public overload group: `thread.spawn`,
  `runtime.shared` and `try_shared`, and `container.Small_Array`'s `append`.

A private type that a public procedure returns is a fourth way, which no
bundled package uses. The group case looks deliberate: a group exports one
name over several signatures, and its members' own names are not meant to be
API. The type cases look accidental. Rust warns on a private type in a public
signature, and Go allows an unexported return type although its documentation
cannot then describe the type. The options are to keep allowing all of it, as
now; to warn when a public signature or public field names a private type, or
a public `where` clause a private procedure, but not for a group's members;
or to make that an error. The warning would make `fmt.Fill` public and keep
the interface writer's private notes for groups only.

### Follow-up review of interface fixes (2026-10-21)

A review of `1eef98d`, "Fix the interface writer's five review findings",
found three more cases, fixed in the commit after it: in syntax the checker
never resolved, a parameter or `$` name was taken for a private declaration
spelled the same, which also made an interface generated without `-debug`
stale under it; a private member selected through its type, as
`Boxed.DEFAULT` in a default value, was not followed; and a constant in
`@(align=N)` was not followed. The review's simplification, reading
`@(test)` directly instead of through a helper, is applied too. Each case is
in `tests/api/bindings`, and every case and bundled package is now checked
with and without `-debug`.

## The `op`/`try_op` pair

Should a container keep both spellings of a fallible operation? `append`/`try_append`, `reserve`/`try_reserve`, and the rest double the container API over a failure-policy choice. Typed fallibility made the fallible variant cheap — a `try_` operation reports failure as a `Result` rather than a bare `bool`, over an ordinary library union with `@(failure=...)` and no compiler-known error type — which is what makes keeping both spellings need re-justifying. Every shipped container keeps its pair today; collapsing them is a separate decision with its own migration.

The language pairs a fallible operation with a policy-following one in a second place: the compiler-generated [`clone`/`try_clone`](design.md#lifecycle-hooks-and-resource-types). The shape is identical, so the two are one question asked twice — but they are not one answer, for two reasons that the container pair does not share.

The pair costs a type author nothing. Both names are generated from the single `hook(copy)` role, so a record supplies one implementation and receives both spellings; a container supplies two implementations, two doc entries, and two test paths per operation. Duplication in the generated pair is two names, not two bodies.

And the policy-following half is load-bearing rather than convenient. Copy assignment of a copyable type is *defined* as `try_clone` plus the [allocation failure policy](design.md#allocation-failure), and [`Cloneable`](design.md#standard-interface-catalogue) names the fallible slot, so both halves already have language-level jobs. Deleting `clone` would not remove the policy call, only move it to every call site that copies. A container `try_op` carries no equivalent obligation, which is what leaves the container pair the live half of the question.

The allocation built-ins are a third instance, and they keep the pair: `box`/`try_box`, `make`/`try_make`, and `unsafe.new`/`unsafe.try_new` (see [The allocation built-ins follow the `try_` convention](comments.md#the-allocation-built-ins-follow-the-try_-convention)).

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

Should there be a form of procedure, distinct from `proc`, that is guaranteed by the compiler to be free of side effects?

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
through `&mut` ones.
What a plain `self` cannot do is keep mutable state inside the callable, or
hand a capture away when called and so be callable once. Both matter only for
a callable that outlives its scope: a stored generator, a deferred job, a
thread worker. Those wait on
[Owning runtime polymorphism](#owning-runtime-polymorphism) and
[Thread transfer needs a visible contract](#thread-transfer-needs-a-visible-contract).
Revisit `inout` and `move` calls when the first API takes such a callable; the
receiver mode is then written, for example on the clause.

### Returning a capture literal

No signature can name a capture literal's type, so it cannot be returned or
held in a file-scope type.
A callable that is returned or kept past its frame is either a file-scope
record written by hand or an owning erased value under
[Owning runtime polymorphism](#owning-runtime-polymorphism). Revisit when the
first returned closure is needed. One answer then is an opaque result type,
`-> some interfaces.Callable(proc(a, b: int) -> bool)`, as Rust's `-> impl Fn` is; it makes a caller depend
on the body for the result's size, which works against
[Public borrow contracts should stand on their own](#public-borrow-contracts-should-stand-on-their-own),
and it overlaps an owning `dyn`.

### Compile-time capture literals

Compile-time evaluation rejects a capture literal, as having no compile-time
value. Its record could be evaluated as any record is; support it when a
compile-time use appears.

### A mutable callable view

A [`dyn proc` view](design.md#borrowed-callable-views) is read-only, since a
`call` takes a plain `self`: it reads its captures and writes through a `&mut`
one. Revisit `dyn mut proc` with the `inout` call in
[What a capture literal's `call` cannot do](#what-a-capture-literals-call-cannot-do):
a callable that keeps mutable state inside itself would need a mutable view to
be called through one.

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

Note that the witness is currently a mechanism with no user-visible spelling: the
compiler builds one for each `(Interface, Concrete, arguments...)` tuple reached
by a `dyn` conversion, and nothing materializes it as a value. An earlier draft
exposed `witness_of` and a compiler-defined `Witness(...)` type for exactly this
future owner, which meant fixing a layout, a zero value, an invalid-witness panic
rule, and a normative slot-flattening order for a consumer that did not exist.
Whichever way the question above is answered, the primitive comes back with the
owner that needs it.

## Concurrency refinements

The current [memory model](design.md#concurrency-and-the-memory-model) defines data races, atomics, transfer between threads, and `Shared(T)`. Experience with a real concurrent runtime should determine whether later versions need compiler-checked `Send` or `Sync` interfaces, additional atomic orderings, or a thread-affine owning type for code that wants non-atomic reference counts.

The cost of keeping immutable `string` safe to copy and drop across threads is treated separately under [Thread-affine strings](#thread-affine-strings).

Higher-level constructs are a separate question: futures or a similar
composable asynchronous result, and language help for reactivity, such as a
procedure rerun when a variable it reads changes. Each needs a use of its own;
[Thread transfer needs a visible contract](#thread-transfer-needs-a-visible-contract)
already rules them out as the answer to borrowing across a join.

`Once` in `core:sync` spins without yielding while another thread runs its
action. A blocking address wait would suit slow, contended initialization if
that turns out to be a real workload; no contention benchmark has been run.

## Thread-affine strings

`string` is an owning value that may share backing storage, and the current
version requires atomic handle accounting in any sharing implementation. This is
the most expensive rule in the language per line of ordinary code: every string
copy is a potential atomic increment, and a freestanding target without atomics
is left with copy-always as the only conforming strategy. Atomic accounting does
not make an arbitrary allocator thread-safe; transferring the string still
asserts that its bound allocator may deallocate on the receiving thread.

A thread-affine string with a non-atomic count would be a distinct type rather
than a silent weakening of the guarantee. Deciding whether it is needed requires
measuring a real implementation; it is recorded here because the cost is
structural rather than an implementation detail, and because the answer affects
whether `string` is usable unchanged on embedded targets.

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

Loke makes a panic unrecoverable: unwinding runs `defer`s and managed
`drop`s for cleanup, but there is no `recover`, `try`, or catch construct that
lets Loke code observe or resume from one. The [panic semantics](design.md#panics-and-unwinding)
are otherwise fully defined, including the two build-selected strategies.

The open question is whether a later version should add a bounded recovery
mechanism — a per-thread catch at a task or request boundary, say — without
reintroducing general exceptions. The appeal is server code that wants to fail
one request rather than the process; the cost is a second control-flow path that
every `drop` hook and `defer` would have to be correct under, and the temptation
to use it as ordinary error handling in place of [`or_return`](design.md#or_return-operator).
Not required by anything in this document.

## intrinsics and inline assembly

How to add some suport to go even more low level and use SIMD efficiently, Intrinsic or inline assembly?

## abstraction over SOA

Is it the programers responsibility to abstract ove the right thing or does the language need some help with that?

## LLM optimization

token optimization, can the syntax be made to be token efficient?
LLM readability and writability, how does that differ from humans? LLM's are trained on human data but works differently.
Encapsulation and abstractions must still be important so they can work on an part of the code.

## Symbolic links before `core:fs` supports them

standard-library.md "`core:fs`" says symbolic links are unsupported and that
their behavior, when it arrives, will be explicit rather than Windows's. Until
then `fs.metadata` reports what `GetFileAttributesExW` says about the link
itself. A junction reads as a `Directory`. A file link reads as the link, which
Windows documents as describing the link rather than its target, though opening
it reads the target. `Kind.Other` is never produced.

Should a reparse point read as `Other` now? That would be explicit. It would
also make `create_directories` fail through a junction, which ordinary Windows
profiles contain.

## Open questions in `core:strconv`

- `parse_f64` rounds through the C library's `strtod`, as `fmt` already does to
  find its shortest spellings. That makes it foreign code, which design.md
  "Compile-time procedure evaluation" keeps out of constants for good. Both
  now run in a fixed "C" numeric locale, so `setlocale` through a foreign
  binding no longer changes them. A correctly rounded parser in Loke
  (Eisel-Lemire with a big-decimal fallback) would make the parser usable in
  constants. Is that worth that much code?

## Open questions in `core:random`

### Random distributions across platforms

The distributions return the same bits on every release of one platform, but
they call the C library's `exp`, `log`, `pow`, or `sqrt`, which
[`core:math`](standard-library.md#coremath) does not promise to the last bit;
`normal` and `exponential` do so only for a wedge or tail value. Once a second
platform ships, a seeded sequence could differ there: rarely for those two,
often for the others, and a different count from `poisson` or `binomial`
shifts every later draw. Correctly rounded functions in Loke would close this,
and would also let the distributions run at compile time. Is cross-platform
identity worth that code, or is per-platform reproducibility the contract?

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
the calendar, fixed offsets, and ISO 8601 text; the reasons for its shape are
in [Standard-library API choices](comments.md#standard-library-api-choices).
Time zones are what is left.

### The local time zone

The planned second phase, for a caller that wants the time on the machine's
clock:

```loke
Zone :: struct { /* private: a fixed offset or the system's zone */ }
local_zone() -> Zone
fixed_zone(offset: Offset) -> Zone
now_local() -> Offset_Date_Time

Zone.offset_at(self, instant: Time) -> Offset
Zone.to_local(self, instant: Time) -> Offset_Date_Time

Resolution :: union {
	unique:  Offset,
	gap:     (before: Offset, after: Offset),     // clocks skipped this time
	overlap: (earlier: Offset, later: Offset),    // clocks showed it twice
}
Choice :: enum { Compatible, Earlier, Later, Reject }
Zone.resolve(self, local: Date_Time) -> Resolution
Zone.at(self, local: Date_Time,
	choice: Choice = .Compatible) -> Option(Offset_Date_Time)
```

The system zone is the one the operating system's clock shows. On Windows,
`GetDynamicTimeZoneInformation` names it and `GetTimeZoneInformationForYear`
gives each year's standard offset and daylight-saving rule, the rules
`SystemTimeToTzSpecificLocalTimeEx` applies. Its history is what Windows
records: changes Microsoft has published, with the earliest recorded rule
standing in for the years before it. The package owns no zone data, and
Windows Update keeps the system's current. The `TZ` environment variable, which
the C runtime reads, is not consulted.

Each use reads the current setting, so a long-running program follows a change
to the system zone, and nothing is read at import
([No hidden process behavior](standard-library.md#no-hidden-process-behavior)).
If Windows reports a failure, which it does not on a supported system, the
call panics, as `random.fill_secure` does.

A wall-clock time can fall in a gap, when clocks skip forward, or an overlap,
when they repeat an hour. `resolve` says which, with the offsets on each side.
`at` chooses: `Compatible` uses the offset before a gap, which moves the time
forward by the gap's length, and the earlier instant of an overlap, as RFC 5545
and Temporal do; `Earlier` and `Later` take the instant before or after;
`Reject` answers `.none` for either. `resolve` tries each offset the zone uses
near that date and keeps those whose instant converts back to the same wall
time. The rule evaluation takes a year's rule as data, so tests can give it
known rules, such as the European Union's, for gaps and overlaps, and compare
`offset_at` with `SystemTimeToTzSpecificLocalTimeEx` across a year in
whatever zone the machine has.

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
- **The system zone's name.** Windows names its zones its own way. The IANA
  name needs CLDR's mapping, which ICU has, so `Zone` would have no name in
  the second phase.

## Formatting

The current formatter rules and rationale are in [comments.md "Formatting"](comments.md#formatting).

Open: aligning columns automatically, as `gofmt` does, so a renamed field
does not leave its neighbours misaligned; and indenting a continued line
inside brackets, which `core/` leaves at the bracket's level.

## Language design review (2026-10-03)

This is a set of proposals, not an amendment to the normative specification.
Backward compatibility is deliberately not a constraint. The review examined
the specification, grammar, rationale, existing open questions, compiler
architecture, relevant checker/emitter code, standard-library APIs, examples,
and focused compiler probes. It is not a proof of compiler soundness or a
performance benchmark.

Loke already has a strong foundation: deterministic evaluation order, lexical
cleanup, checked indexing and signed arithmetic, closed enums, exhaustive
union switches, explicit fallibility, definition-site generic lookup, and no
user-defined implicit conversions. Preserve those. The largest simplification
would come from making ownership, capability, and safety rules compose with
fewer exceptions, rather than shortening keywords.

### Recommended order

| Priority | Proposal | Main benefit | Scope |
| --- | --- | --- | --- |
| Next | Compiler-selected ordinary union layout | Compact nested results | Representation contract |
| Next | Stable written borrow contracts | Public signatures do not depend on implementation bodies | Procedure types |
| Later | Localize unchecked operations | Unsafe obligations are visible where introduced | Syntax and APIs |
| Later | Checked disjoint access | Hand mutable halves to parallel workers | One compiler-known slice operation |
| Later | Checked thread transfer and scoped workers | Reduce races and permit borrowed parallel work | Thread APIs and capabilities |

Try each on concrete programs before deciding: a parser, a resource container,
a sorting or partitioning algorithm, and a parallel numeric kernel.

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

### Provide checked disjoint access

**Adopted (2026-10-22)** as
[Splitting a mutable slice](design.md#splitting-a-mutable-slice), with
[Chunks of a mutable slice](design.md#chunks-of-a-mutable-slice) for the
data-parallel case. Implementing it showed that the claim below about a
checked-slicing body was false until then: one record literal could hold two
mutable reborrows of a carrier, `{&mut xs[:mid], &mut xs[mid:]}`, so a
library procedure could return two overlapping mutable views. That is now
`L0641`, and the claim holds. What follows is the original question.

Two runtime slice ranges conservatively overlap, so two *mutable* halves of
one sequence cannot be live at once: after `left := &mut xs[:mid]`, the
reborrow suspends `xs`, and `&mut xs[mid:]` is `L0641`.

Most algorithms do not need that. A recursive merge sort compiles today:
recursing on one half and then the other (`sort(&mut xs[:mid]);
sort(&mut xs[mid:]);`) ends each reborrow before the next, the merge reads
both halves at once as read-only views (allowed since
[Weakening and reborrows](design.md#weakening-and-reborrows) lets reads of a
carrier coexist), and a swap across the halves is `xs.swap(i, j)`. What
remains impossible is handing each half to its own worker, which needs
[scoped workers](#thread-transfer-needs-a-visible-contract) first. Do this
together with them.

**Proposal:** a compiler-known `xs.split_at_mut(mid)` on `[]mut T`, built like
`swap`: one bounds check, two slice headers, and a result whose two fields are
one mutable reborrow of `xs`. No disjointness relation needs tracking. The one
reborrow keeps `xs` suspended until both halves are finished, so the source
can be neither written nor reallocated meanwhile; writes through the two
halves do not conflict, because suspension constrains uses of the source and
not of its reborrows; and copying one half twice is already rejected, as a
second reborrow of the same field. Acceptance tests should reject a write
through `xs`, reallocation of its owner, and a half retained beyond `xs`.

A library function cannot provide this. Written with `unsafe.raw_data`, a
`split_at_mut` compiles and works, but its halves carry no provenance, so
`values.append(5)` and `xs[0] = 9` are accepted while they are live: a
use-after-reallocation the compiler cannot see. Written with checked slicing,
its body needs the two simultaneous reborrows it is meant to provide.

Related expressiveness limits are real but need different tools. A graph or
arena can use stable integer/generational handles without pervasive pointers.
A record owning a buffer and views into itself needs address stability and an
internal-borrow contract; non-null pointers do not solve it. Prefer offsets
and handles before introducing general pinning or self-referential types.

### Performance opportunities and actual semantic limits

Fast programs are expressible: fixed contiguous arrays, slices, arena-backed
owners, monomorphized generics, static iteration, explicit moves, and
`Simd(T, N)` provide the necessary building blocks. However, no benchmark in
this review establishes that the current compiler achieves C-like performance.

| Area | Current consequence | Recommendation |
| --- | --- | --- |
| Bounds/overflow checks | Observable failure constrains motion and speculation | Keep checks; eliminate those proved redundant and expose explicit arithmetic policies. References are [never null](design.md#types-with-no-zero-value), so they carry no nil checks |
| Aliasing | Local exclusivity can help; unknown provenance and hidden effects limit what may be assumed | Repair effect holes first, then emit alias/memory attributes only where their precise obligations hold |
| Floating-point expressions | Unwritten FMA contraction and reassociation are forbidden; a fused multiply-add is written `math.fma`, computed in software on the baseline target | Add separately named reassociating reductions; keep default arithmetic strict. Emit the FMA instruction for `math.fma` once a target with it can be selected |
| Ordered reductions | A floating SIMD sum is defined left to right | Retain the ordered form and offer an explicit unordered/tree reduction with documented numerical differences |
| Custom clone/drop and allocators | Calls may have observable effects or fail | Define which implicit copies may be elided; preserve explicit clone contracts |
| Dynamic interface dispatch | An unknown witness requires an indirect call | Prefer generic specialization in hot code; devirtualize when a concrete witness is known |
| Atomic string/shared accounting | Cross-thread sharing requires synchronization | Borrow views in hot paths; consider thread-local ownership only after measurement |
| Union representation | Fixed payload-plus-tag layout prevents general niche encoding | Give ordinary unions compiler-selected layout; explicit layout only where requested |

An unused representation, or niche, is a bit pattern no valid payload uses.
For references the niche is decided: null encodes `.none` in an `Option`-shaped
union over a non-null reference
([Representation](design.md#representation)).
What remains here is every other union.

Make the layout of ordinary unions an implementation choice, while retaining
accurate `size_of`, alignment, reflection, and consistent ABI within a build.
An explicit representation contract can preserve a stable tag and field layout
for serialization or external consumers. Do not expose an unstable optimized
representation as a wire format. Nested `Result(Option(T), E)` is another
candidate for compact representation, subject to its actual payload states.

The emitted-IR source does not currently spell general `noalias`/`readonly`
parameter attributes. That is an implementation opportunity, not evidence that
LLVM never infers them. Read-only capability alone is insufficient to promise
memory cannot change: atomic operations intentionally write through read-only
receivers, and foreign/unchecked aliases need their own contract. Follow
[LLVM's attribute requirements](https://llvm.org/docs/LangRef.html#parameter-attributes)
precisely rather than applying them to every `mut` or read-only type.

Some transformations really are forbidden. Turning ordered floating additions
into a different reduction tree, silently fusing `a*b+c`, or hoisting a possible
panic ahead of earlier observable writes can change the specified result.
That does not mean all vectorization is forbidden: independent iterations,
proofs that checks cannot fail, runtime alias checks, and target-supported
ordered reductions remain available. LLVM documents these distinctions in its
[vectorization guide](https://llvm.org/docs/Vectorizers.html).

Do not add a general purity/effect language merely to request faster code.
Start with the inferred effects already needed for safety, explicit numerical
operations, and measurements of bounds checks, allocation counts, retained
strings, generated code, and representative kernels.

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

### Thread transfer needs a visible contract

Answered for work joined before its caller continues.
[Structured concurrency](design.md#structured-concurrency) adds `parallel`
blocks whose tasks keep their argument borrows until a join the block owns,
which survives every early exit and cannot be skipped by `unsafe.forget`. The
checks a task needs are inferred rather than declared through `Send` and
`Sync`, apart from `@(thread_affine)`, `@(synchronized)`, and
`@(cross_thread)`; [comments.md](comments.md#tasks-that-borrow-joined-by-their-block)
gives the reasons. Futures, async syntax, and reactive variables were not
needed to borrow across a join.

Still open:

- A thread `core:thread`'s `spawn` starts outlives any scope, so it still
  takes only `@(escape=static)` arguments, and keeping a `thread_local` borrow
  past the end of its thread is still unchecked; see
  [What is not checked](design.md#what-is-not-checked).
- The [later concurrency extensions](#later-concurrency-extensions).
- Whether the [waiting design](standard-library.md#corethread), with paired
  channel setup and explicit monitor termination, holds up in use: measure
  wake-all costs and conservative join-check rejections. The
  [waiting review](#waiting-and-ownership-review-2026-10-26) records the
  incorporated findings and remaining validation work.

### Later concurrency extensions

`parallel` blocks, `spawn`, monitors, channels, the join check, the polling
ring, pools, and indirect spawned calls are built: design.md specifies them
under [Structured concurrency](design.md#structured-concurrency), and
standard-library.md under [`core:thread`](standard-library.md#corethread).
These questions remain; none blocks what is built. The reviews below name the
milestones of `concurrency-proposal.md`, which was removed once they were
done; git history keeps it.

1. **Erased callables at a spawn.** A spawned call may go through a procedure
   value or a `dyn` view, and the effects follow the callbacks each call
   passes. A view that arrives erased, as a parameter or stored local, is
   checked through every type converted to its interface application
   (answered 2026-10-27; see [Sharing with tasks](design.md#sharing-with-tasks)),
   and a call through it takes its slot's whole effect union. What remains is
   precision: one conversion of a mutable or thread-affine type anywhere
   rejects every erased view of that application, and one fill writing a
   global rejects every call through it. Public callable-effect contracts,
   which would bound both, need a separate demonstrated requirement.
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
7. **Checked lazy initialization.** Whether a `sync.Once(T)` or similar that
   owns its value, as `Mutex(T)` does, should replace `Once` guarding separate
   file-scope storage, so tasks can run lazy setup.
8. **Timed waits.** `lock_when`, `send`, and `receive` with a deadline from
   `core:time`, reporting a timeout apart from closure. An audio loop that must
   play silence when a decoder falls behind needs them.
9. **Selective cancellation and choice.** A stop token that ends one waiter
   among several on the same object or coordinates cancellation across several
   objects, and a wait on whichever of several channels is ready first. The
   library requires explicit shutdown protocols for those groups.
10. **Unscoped channels.** Endpoints that own shared channel state instead of
    borrowing a local, for a thread `core:thread`'s `spawn` starts or a
    foreign audio callback, which only `@(escape=static)` values reach. The
    [join check](design.md#releasing-before-the-join) cannot follow them, since
    they borrow no root.
11. **Targeted wakeups.** A hint that wakes fewer of a monitor's waiters,
    where waking all of them costs more than their checks. It would narrow
    which waiters wake, not which changes they see.
12. **Blocking ring adapters.** Parking one endpoint and waking it from the
    other requires a proven registration/recheck handshake, closure-race
    handling, and an explicit account of kernel calls on the deadline-bound
    side. It is outside the polling ring's API; see
    [The ring algorithm](standard-library.md#the-ring-algorithm).

### Structured concurrency proposal review (2026-10-22)

The review was incorporated into the revised proposal, which is now
[Structured concurrency](design.md#structured-concurrency). It now chooses `spawn result = call;` with
only dead outer locals as result destinations, keeps cleanup before joining,
and specifies [task-start failure](design.md#failure-to-start-a-task).
Its later library stages define explicit cancellation with wakeable waits,
channel close and failed-send ownership, and limited pool progress.

The first implementation must enforce every applicable safety check for
statically known calls; unknown indirect effects are rejected. The remaining
questions are the [extensions](#later-concurrency-extensions):

- How public and erased procedure contracts preserve all sharing, transfer,
  global-access, allocator, and result-provenance facts.
- How recoverable submission returns prepared arguments on failure.
- Whether richer result destinations justify their extra lifetime and
  cleanup rules.
- How channels retain borrowed items, support rendezvous, and use nondefault
  queue allocators.
- How an executor can support blocking work beyond the fixed pool's limited
  progress guarantee.

These extensions do not prevent the smaller initial feature. Validate its
acceptance and rejection cases before
adding library concurrency: a scope-owned join guarantees storage lifetime,
but does not itself guarantee termination or wake a blocked participant.

### Structured concurrency follow-up review (2026-10-22)

A second review checked the revised proposal against design.md, grammar.md,
and the bundled packages. Its fixes are in
[Structured concurrency](design.md#structured-concurrency):

- A pool worker that helps at a join could run a child on the parent's thread
  while the parent held a borrow of that thread's TLS. The join under a helping
  executor now carries its tasks' `thread_local` effects.
- A plain read of a shared `Atomic` or `Mutex` field raced with a task's
  synchronized write. Synchronizing operations now conflict with every other
  access, reads included.
- Under the ordinary parameter rule, `spawn work(i)` borrowed a loop index past
  its iteration. Arguments that copy without a hook or allocation are now
  copied into the task.
- `chunks_mut` was described as existing and attributed to
  [Provide checked disjoint access](#provide-checked-disjoint-access), which
  proposes only `split_at_mut`. Existing iteration rules forbid it; the
  proposal now specifies it.
- Rejecting every indirect call a task reaches would have barred printing,
  `once.do`, and `slice.sort_by`. Calls a task makes now use the whole-program
  union of [Global write effects](design.md#global-write-effects); only the
  spawned call must resolve statically.
- Check 6 rejected every task that logs. Build-selected providers are now a
  stated trust boundary, required to accept concurrent use.
- A received allocator could be read as either a possibly shared region or an
  unknown one. It is now a possibly non-concurrent region.
- The proposal now states that applying its checks to `thread.spawn` is a
  breaking change, that a `thread_local` drop hook writing a global rejects
  every block, and that a statement-initial `parallel` literal must be
  parenthesized. `spawn` is rejected in deferred statements, the grammar takes
  attributes, the flagship sort bounds its depth, and rule 2 cites the one rule.

How a library declares an argument that crosses threads, and its own
synchronized state, was open after this review and is now decided:
`@(cross_thread)` on a parameter and `@(synchronized)` on a field or variable,
so the compiler recognizes no concurrency type or procedure by name. See
[Preparing for implementation](#structured-concurrency-implementation-readiness-2026-10-22)
below.

Still open; the first three are among the proposal's
[later extensions](#later-concurrency-extensions):

- Whether build-selected allocator and logging providers must declare that
  they accept concurrent use, so it is checked rather than trusted. Today a
  build can select an arena-backed default allocator and race silently.
- Whether an `Allocator` parameter can promise a concurrent region, so a
  library can share a caller's allocator among tasks.
- Whether a value-owning `Once(T)` should give tasks checked lazy setup; until
  then a task that may run a `Once` action writing a global is rejected.
- Answered: the whole-program union was conservative, so one compatible
  procedure anywhere that wrote a global affected every indirect call of its
  type. [Per-call effect precision](#per-call-effect-precision-2026-10-26)
  replaced it where it can: a call
  takes in the callbacks it passes, so an unrelated procedure of the same type
  no longer affects it. The union remains for a body's own calls of its
  parameters and for values nothing follows; those limits are recorded there.

### Structured concurrency implementation readiness (2026-10-22)

A third pass made the proposal
ready to implement. It decided what the first implementation needed:

- `@(synchronized)` marks a field, or a file-scope or `static` variable, whose
  declaring package synchronizes every access to it. Outside that package,
  access to a synchronized field needs exclusive access to its record, and a
  synchronized variable's stored carriers are exempt from the global-carrier
  check. `Atomic(T).value`, `Mutex(T).value`, and `log.selected` carry it,
  which replaces the provider exemption inferred from names.
- `@(cross_thread)` marks a `move` parameter, which must also be
  `@(escape=static)`, or a procedure-typed parameter that runs on another
  thread. `thread.spawn` carries it, and the existing race warning keys on it.
- The new summaries are defined: a reach effect for globals' stored carriers,
  an allocator-use effect, per-type transfer facts, and a block's window.
- Lowering is ordinary Loke in `core:thread`; a result local's
  initialization flag is set when its task registers, since a registered task
  completes unless the program ends.
- A result destination must have the call's exact type; a `parallel` block is
  a compile-time evaluation error; the executor header parses and is rejected.
- The first five milestones shipped; the library milestones followed, and
  [Later concurrency extensions](#later-concurrency-extensions) lists what remains.

Open, to settle with evidence during the milestones:

- `@(synchronized)` rejects a plain read of `value` through `^Atomic(T)`,
  which used to compile. Milestone 2 shipped it with an upgrade note; no
  bundled package, test, example, or tutorial needed changing, and
  `Mutex.lock`'s `rawptr(&self.word.value)` is covered by the raw-address
  exception. Whether outside code relies on the rejected form is still
  unknown.
- Answered (2026-10-27): the reach effect rejected a `dyn` stored in a global
  even when only read, since an erased value hides captures that may write.
  A read-only view now reaches what each type converted to its interface
  application reaches; see
  [Globals while tasks run](design.md#globals-while-tasks-run) and the
  [rationale](comments.md#tasks-that-borrow-joined-by-their-block). An
  `any_view` cannot be stored in a global at all. Two limits remain: a
  `dyn fmt.Formattable` stays unknown, since printing builds its witnesses
  after the effects, and the union is per application, so one conversion of a
  mutable record anywhere rejects every registry of that interface. The same
  union now lets a task share a view that arrives erased, the first
  [later extension](#later-concurrency-extensions).

### Waiting and ownership review (2026-10-26)

Incorporated into the revised [waiting proposal](standard-library.md#corethread),
which remains unimplemented. The review kept scoped joins, predicate waits,
bounded channels, and endpoint destruction, and resolved these design findings:

- [Monitors](standard-library.md#monitors) now require an explicit
  termination protocol. The controller example installs cleanup before spawn
  and handles both paused and playing states. Predicate repeatability,
  mutation, and wakeup dependencies are programmer obligations; read-only
  access is not claimed to prove purity.
- [Channels](standard-library.md#channels) establish both initial endpoints
  with one `split`. Move-only endpoints use explicit `fork` to add participants,
  keeping generated `clone` semantics unchanged. The lifecycle table decides
  closure, draining, zero values, FIFO ordering, error precedence, and item
  destruction. The worker example drops its setup receiver before sending.
- The [join check](design.md#releasing-before-the-join) covers
  parameters, wrappers, containers, nested blocks, result slots, and writebacks.
  Closing a retained endpoint is not a static exemption. This is a conservative
  check for values retained across a join, not a general termination proof.
- The deferred [ring](standard-library.md#rings) has exclusive
  endpoint operations and only a polling API. It has no public close or
  blocking wakeup path in its initial form. Moving an endpoint sequentially
  between threads remains possible.
- [Pools](standard-library.md#pools) remain a separate compute feature.
  Helping is limited to workers of the selected pool and the subtree of the
  block they are joining, matching the permitted TLS effects. The mixer is
  explicitly a paced worker, not a hard real-time callback.

The implementation plan adds
startup/early-exit coverage, ownership checks, and bounded liveness harnesses.
Delivery proceeds through monitors and channels, then compute pools; the ring
is not a prerequisite. No compiler or runtime behavior changed with this
proposal revision.

Still open:

- Answered by milestone 8: the ring's atomic algorithm, progress bound,
  closure ordering, and bounded indices are written and built, and its
  endpoint API compiles under the existing borrow rules. Weak-memory model
  checking and measurements remain under
  [Ring algorithm review points](#ring-algorithm-review-points-2026-10-26).
  Blocking adaptation still needs a separate registration/recheck protocol
  and timing contract.
- Measure the monitor's wake-all cost and the join check's conservative
  rejections on real pipelines. Neither justifies a purity effect system or
  interprocedural closed-state analysis without evidence. The one such
  rejection met so far, two parameters of unrelated types, is
  [resolved](#parameters-a-join-check-cannot-tell-apart-2026-10-26).
- Selective cancellation, multi-object group cancellation, and multi-channel
  choice remain [later extensions](#later-concurrency-extensions).
  Endpoint closure alone does not provide them or interrupt foreign waits.
- A library getter whose `^T` result is rebuilt from untracked storage has no
  declarative way to say that the result borrows its receiver: the rebuilt
  pointer has unknown provenance, which proves nothing. The compiler asserts
  it for `Shared(T).get` alone. `Monitor_Guard.read`, built with milestone 6,
  calls through a plain procedure type instead, whose result derives from
  every borrowed argument ([Procedure result contracts](design.md#procedure-result-contracts)),
  so the borrow ends with the guard. Whether a declaration should state such a
  contract, and replace the `Shared` special case, is open. Milestone 7 met
  the opposite case: an item taken out of a channel's queue through a guard
  looked like a borrow of the guard, though items carry only process-lifetime
  borrows, so `Channel` reaches its queue through a `rawptr` cast
  (`queue_of`) to drop that provenance. A declared contract could say both.

### Monitor implementation review (2026-10-26)

Review of `84a9691`. Both findings are fixed:

- `Monitor_Guard`, and `Mutex`'s `Guard`, which had the same omission, were not
  [`@(thread_affine)`](design.md#thread_affine), so checked code could move a
  guard to another thread and release an SRWLOCK there, which Windows
  forbids. Both are thread-affine now;
  [lib_thread_guard_affinity.loke](tests/err/lib_thread_guard_affinity.loke)
  rejects argument transfer to `thread.spawn`, a move into a task, and a task
  returning a guard to its parent.
- The `asking_again` case in
  [lib_thread_monitor.loke](tests/run/lib_thread_monitor.loke) required an
  exact predicate-call count after a read-only guard dropped. A condition
  variable permits
  [spurious wakeups](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-sleepconditionvariablesrw),
  so it could fail with no notification sent. The assertion is gone; the
  remaining counts are lower bounds used only for sequencing. Core packages
  have no in-package tests, so the guard's private notification flag is not
  checked directly.

The implementation's structure is otherwise compact: acquisition and waiting
belong to `Monitor`, while access and release belong to `Monitor_Guard`.
Keep the plain-procedure indirection in `read` until the
[borrow-contract question](#waiting-and-ownership-review-2026-10-26) is resolved.
Replacing it with `return &self.monitor.value` in an isolated package copy
made the compiler accept the existing `read_after_unlock` error case; the
direct pointer follows the monitor borrow rather than the guard's lifetime.
No further abstraction or deletion is justified by this review.

### Channel implementation and join-check review (2026-10-26)

Review of `e8238f6`. Commit `1c0bae5` addresses the five original
reproductions; the follow-up review below records two additional cases:

- The channel iterator held a pointer to the channel rather than borrowing a
  `Receiver`, so its receiver could drop, closing the receiving side, while
  the iterator could still receive: a send then failed, and a receive before
  the last sender dropped waited forever. The iterator borrows its receiver
  now, and `next` forwards to `receive`;
  [lib_thread_channel_iterator.loke](tests/err/lib_thread_channel_iterator.loke)
  rejects the premature drop with `L0512`.
- The [join check](design.md#releasing-before-the-join) found the marked type
  in the whole symbol's type, then attributed every carrier slot of the symbol
  to it, so a guard on one mutex was rejected because a sibling field pointed
  to another a task locks. Only slots whose carrier path passes through a
  marked type, or ends at a carrier reaching one, count now (`path_waker` in
  `borrow.odin`); [parallel_join_retention.loke](tests/err/parallel_join_retention.loke)
  accepts the wrapper case and still rejects a wrapper whose guard locks the
  task's mutex.
- The `early_worker` case in
  [lib_thread_channel.loke](tests/run/lib_thread_channel.loke) assumed its
  worker had returned after sleeping 10 ms. The worker now drops its receiver
  explicitly and then publishes a flag the parent waits for.
- `waker_walk` repeated the traversal of `transfer_facts_walk` in
  [hooks.odin](src/hooks.odin). The first marked type is now the `waker` fact,
  and `type_reaches_waker` reads it.
- `Channel`'s `capacity` field existed only to make the type lack a zero value.
  The private `state` field is `required` instead, and `init` sets it
  explicitly. With the iterator forwarding to `receive`, the private `take`
  had one caller and is inlined there.

The main boundaries are useful: `Channel_State` owns the ring operations,
`Monitor` supplies synchronization, and the endpoints own the participant
counts. The join check belongs in the existing provenance replay, where
cleanup and task holds are already available. Keep `queue_of` as the narrow
trust boundary until the
[borrow-contract question](#waiting-and-ownership-review-2026-10-26) is resolved.

### Pool implementation review (2026-10-26)

Review of `d684700`; all three findings are fixed. Argument and unused result
drop hooks correctly contribute TLS effects, and a helped child's panic
unwinds and terminates without hanging.

- A pooled join on a loop exit the walk reached before the block's first
  spawn emitted no `thread_local` effect, so a view of a buffer an earlier
  iteration's task freed could be returned. The same order hid what plain
  tasks borrow and reborrow from that exit, so a write to a variable a task
  was still reading was accepted. The checker now records each block's
  spawns (`Stmt_Parallel.spawns`), and `prov_enter_parallel` registers the
  block's task slot, one reborrow slot per spawn site, and its pooled tasks
  when the walk enters the block;
  [parallel_pool.loke](tests/err/parallel_pool.loke) and
  [parallel_task_loans.loke](tests/err/parallel_task_loans.loke) cover the
  exits.
- `Pool.submit` stored `Task_Scope.parent` on every spawn, outside the lock,
  while a helper searching the queue could read it. `Task_Scope.pooled` sets
  it once, before any task of the block is queued.
- `Pool_State.workers` and `Task_Scope.threads` held raw handles and repeated
  `Thread`'s join. They hold `Thread`s now and are cleared where the loops
  were; the pool clears its workers before freeing the state they read.

The main boundaries are useful: queue operations stay private to the pool,
the hidden `Task_Scope` owns each join, and the compiler applies helped TLS
effects through the existing provenance checks. No additional scheduler or
executor abstraction is needed for this milestone.

### Pool-fix follow-up review (2026-10-26)

Review of `7df2f25` confirmed the original loop-exit, immutable ancestry,
and `Thread` ownership fixes. Generic pooled calls and repeated blocks also
compile and run correctly, and the AST cloner leaves the new semantic spawn
list empty for rechecking. Registering task metadata on entry keeps its
ownership clear; no additional abstraction or deletion is justified here.

The pre-registration introduced one false positive, now fixed: every exit
of a pooled block applied the `thread_local` writes of every task the block
registered, so a return reached before any task started, or one followed by
an unreachable spawn, was rejected with `L0512`. The join's writes are now
tagged with their block (`Prov_Event.joins`), and `settle_pool_joins` drops
them, before any solver reads them, where the task window shows no task of
that block may have started. A loop's back edge still carries an earlier
iteration's start to an exit written above the spawn, so that exit stays
rejected; [parallel_pool.loke](tests/err/parallel_pool.loke) accepts the
no-task branch and the unreachable spawn beside it.

### Ring algorithm review points (2026-10-26)

[The ring algorithm](standard-library.md#the-ring-algorithm) was revised after review to recommend a spare-slot SPSC
queue. [A spare slot in the ring](comments.md#a-spare-slot-in-the-ring)
records the algorithm choice. Milestone 8 built it as written.

Two findings were addressed in the draft, and the implementation follows it:

- **P1: Checked arithmetic after ownership transfer.** The earlier draft
  assumed ordinary unsigned arithmetic wrapped, contrary to
  [Integer overflow](design.md#integer-overflow). With capacity 1,
  `uint(0) - size` underflowed at initialization. Correcting only that left
  the first send writing an item before `t + 1` panicked at publication;
  receive had the analogous problem after taking an item. The revised draft
  uses bounded indices, an explicit reset at the allocation's end, and
  computes successor indices before ownership transfer. No machine-word
  wrapping arithmetic is needed.
- **P2: Closure checks defeated index caching.** The earlier layout placed
  `receiver_gone` beside `head`, so a receive could invalidate the cache line
  every send loaded for closure, even with cached room. The revised layout
  separates the flags from both hot index lines and qualifies its cache
  traffic claim. Target-specific separation and alignment still need checks.

Settled by the implementation: the Loke tests cover capacity 1 and every
last-slot transition; both endpoints are `@(wakes_on_drop)`, and the
[join check](design.md#releasing-before-the-join) rejects a sender kept past a
join whose task polls for closure; sharing an endpoint between tasks is
rejected and moving it from task to task is accepted; the mixer polls a ring;
the padding is 128 bytes on both targets; the operations lower to native
acquire loads and release stores; and `tests/pkg/ring_allocation` runs them,
both endpoints' drops, and the ring's with the default allocator exhausted.
An exhaustive interleaving search under sequential consistency found no
violation (see [The ring algorithm](standard-library.md#the-ring-algorithm)).

Still open:

- **Weak-memory model checking.** The interleaving search treats every access
  as sequentially consistent, so it cannot find a missing release or acquire.
  A C11 model check with GenMC or a tool like it, over the same capacities,
  laps, and drop placements, is still needed.
- **Measurements.** Measure the closure check on every send, with the flags
  separated from the indices, and latency and throughput on the intended
  target. The spare slot is for simpler arithmetic, not demonstrated higher
  speed.

### Indirect calls inside tasks (2026-10-26)

Before letting a spawned call itself be indirect
(milestone 10),
`tests/err/parallel_indirect_calls.loke` spawns hand-written wrappers that
call a procedure value, a `dyn proc` view, a capture literal, a `dyn` slot,
or a procedure read from a field, one case per task check;
`tests/err/parallel_written_back.loke` already covered a `thread_local`
borrow a callback leaves or returns. The selected cases exercise global writes
and reach, allocator reservation, sharing, thread affinity, the join check,
and a pooled task's `thread_local` writes. They found no lost fact in those
cases; they do not cover every callable form against every check or the
lowering of an indirect spawned callee itself. The
[scope review](#milestone-10-scope-and-next-step-2026-10-26) narrows the
conclusion and proposes the next steps. The spike also found:

- **The write and reach unions are per procedure type, not per call.** A
  call through a procedure value may run any procedure of its type the
  program uses as a value, so a spawn passing a procedure that writes
  nothing is rejected when the program passes a procedure of the same type
  that writes a global anywhere, such as to the same wrapper in an
  unrelated serial call. The `thread_local` borrow a callback leaves is
  substituted per call instead, so the two analyses differ in precision. A
  spawned procedure value has the coarser one. Fixed with
  [milestone 10's third step](#per-call-effect-precision-2026-10-26): the
  write, reach, and allocator-use effects substitute callbacks per call too.
- **A rejection does not name the body responsible.** L0731 says that
  `call_plain` may write `hits`, but not that it is `record_hit`, passed
  as `f`, that writes it; a direct helper gets a "through" note. Under a
  union, that body may be in another package. A spawned procedure value's
  rejection now names each target that writes or reaches the global, and
  since the [third step](#per-call-effect-precision-2026-10-26) a wrapper's
  names the callback with the parameter it was passed for.
- **L0729's advice could not be followed for a `dyn proc` parameter.** For
  a view reaching a `&mut` capture it said to move the callable into the
  task, but `spawn run(move(bump))` with `run :: proc(f: dyn proc())` then
  views a temporary, which [Spawn statements](design.md#spawn-statements)
  rejects (L0513). Only a generic callable parameter takes the moved
  literal. A writing capture literal reaches a task through a `dyn proc`
  only once a [mutable callable view](#a-mutable-callable-view) exists.
  Fixed with [milestone 10's second step](#erased-callable-spawns-2026-10-26):
  for a view made at the call, the advice is now that generic parameter,
  and for a view that arrived erased, where moving it would still hide its
  captures (L0725), the concrete value or a conversion at the call.

### Milestone 10 scope and next step (2026-10-26)

Review of milestone 10
and the [indirect-call spike](#indirect-calls-inside-tasks-2026-10-26): the
spike is useful regression coverage, but its conclusion needs narrowing.
It exercises selected combinations of callable forms and task checks, not
every form against every check. Its named wrappers also make the callable
an ordinary task argument; they do not exercise an indirect callee's own
evaluation, capture in a task frame, or cleanup. Passing these cases gives
evidence for reusing the existing analyses, not a proof that any indirect
spawn lowering preserves them.

Some callable task support already works. A runtime check on `0c1e729`
accepted a moved mutable capture through the generic `call_moved` shape in
the spike, and a direct `spawn result = calculate()` where `calculate` is a
capture literal with a read-only capture. The latter resolves statically to
the record's `call` method under [Calling a value](design.md#calling-a-value).
Making a literal consume its captures when called remains a separate receiver
mode question under [What a capture literal's call cannot do](#what-a-capture-literals-call-cannot-do).
Neither a new owning erased callable nor public effect annotations are
established prerequisites for the scoped cases already expressible through
wrappers.

Recommended sequence; all three steps are done:

1. **A narrow implementation of indirect spawning.** Start with ordinary
   Loke procedure values, including runtime selection between targets. Extend
   the existing [task frame and checked run procedure](compiler-architecture.md#lowering-parallel-blocks)
   to hold the callee evaluated once on the parent, before its arguments.
   Reuse ordinary parameter modes, result provenance, cleanup, and task
   checks. Retain conservative target unions wherever exact targets are
   unknown. Do not simply remove the direct-callee check: the current frame
   holds arguments and refers to a static callee symbol, and analysis paths
   also assume that symbol exists.
2. **Tests of the new boundary.** Pair accepted run cases with rejected
   cases. Cover parent evaluation order, changing a procedure variable after
   submission, argument borrows and results through the join, cleanup when
   argument preparation fails, and both bare and pooled tasks. Check that
   adding a reachable unsafe target to a selection makes the spawn fail.
   Then consider borrowed callable views and `dyn` methods, with the callable
   data itself checked for lifetime, exclusive access, and thread affinity.
   Unknown captures must remain conservative; moving a borrowed view does
   not confer ownership of its payload.
3. **Per-call effect precision as a separate change.** A body can record its
   own effects plus dependencies on callbacks it invokes, then substitute
   the callbacks at each call. The compiler already uses related machinery:
   `callback_effects` in `src/global_effects.odin` separates writes from called
   parameters for thread warnings, and `Callback_Read`/`Callback_Write`
   substitute callback provenance for thread-local borrows. Reuse those
   representations and fixed-point patterns where appropriate, extending
   write, reach, and allocator effects consistently rather than adding a
   spawn-only analysis. Keep a union fallback for unknown values and carry
   the responsible target into diagnostics. A clean callback passed beside
   an unrelated serial dirty call is the acceptance case; recursion,
   forwarding, and same-signature target mixtures guard the fallback.

The first step can be sound with conservative rejections; the third improves
which safe programs it accepts. A public effect-contract design would change
the current [global-write model](design.md#global-write-effects), whose effects
are not part of procedure types. It needs a separate demonstrated requirement
rather than serving as an open-ended gate on this milestone.

Further review found a separate loss of callable information at erasure. On
`0c1e729`, a read-only capture `calculate := proc() -> int capture(value) {
return value + 1; };` can cross into a task through `spawn result =
run(calculate)`, where `run` takes `dyn proc() -> int`. Introducing a local
`saved: dyn proc() -> int = calculate;` and passing `saved` instead rejects
with L0729. Both variants keep the concrete closure alive through the join.
`prov_transferred_type` in `src/cfg_provenance.odin` recovers the concrete
type from an immediate conversion, but not from the stored view. This is a
conservative limitation consistent with the current
[sharing rules](design.md#sharing-with-tasks), not an unsafe acceptance.

Prefer a focused extension of the existing
[normalized provenance input](compiler-architecture.md#normalized-provenance-input)
over a checker rewrite: represent the evaluated callee alongside call
arguments, and preserve known callable/environment facts through value
transfers. Keep facts and summaries out of frozen input; merge alternatives
conservatively and invalidate facts on replacement. Target identity, captured
storage loans, and transfer eligibility are distinct facts. Knowing a target
does not prove its environment can cross a thread boundary. Accepting stored
views on this basis would also require a deliberate update to the sharing
rules and paired acceptance/rejection tests.

The current capture representation as ordinary records with a `call` method
can stay. Mutating owned capture fields or consuming captures on invocation
would require explicit call receiver capabilities and compatible view types;
neither follows from more precise provenance. Keep that language extension
under [capture call modes](#what-a-capture-literals-call-cannot-do). Shared
callee input belongs in the first implementation step; richer erased-value
facts can accompany erased callable support without delaying plain procedure
values or requiring public effect contracts.

### Procedure-value spawn implementation review (2026-10-26)

Review of `bf1cd43`, milestone 10's first step.
The extension fits the existing task machinery: the frame stores the callee,
the parent evaluates it once before the arguments, and the generated ordinary
run procedure supplies its effects. It does not introduce a second target
analysis or scheduler. Tests cover callee reassignment, evaluation order,
pooled tasks, result loans, transfer checks, and argument-preparation cleanup.
The compiler unit suite and the run, trap, and diagnostic corpora pass; extra
runtime probes of procedure-value calls with packed, spread, mixed, and empty
variadic arguments and an `inout` parameter also pass.

One correctness issue was found and is fixed: an immediately spawned
procedure literal lost its write effects. The new value-call classification
and the older direct-callee exclusion in effect collection disagreed on it, so
the literal was left out of the procedures used as values. The exclusion now
applies only to calls `call_through_value` does not classify as through a
value, and the helper sits with the ordinary call metadata in
`src/check_calls.odin`. The omission predated `bf1cd43` for an ordinary call:
a borrow of a global kept across a literal called in place that writes it was
accepted as well. `tests/err/parallel_procedure_values.loke` covers the bare
and pooled spawns beside an accepted pure literal, and
`tests/err/global_effects.loke` the ordinary call.

Two small simplifications were available, and both are applied:

- `src/parallel.odin`, `Spawn_Task.proc_type`: **shrink** the stored metadata.
  The checked call already supplies this through `call_proc_type`; emission
  can query it once and use that local for the signature and callee store.
  Remove the field and its assignment, and shorten the accompanying comment.
- `src/borrow.odin`, `note_value_targets`: **stdlib** membership in
  `c.global_writes[target]` is `slice.contains`, which this file already uses;
  replace the manual loop in the writes branch.

Net: four lines removed with those two local changes. The existing frame
layout helpers and the extension of the common run procedure are appropriate;
a broader checker or capture rewrite is not warranted by this implementation.

### Erased-callable spawns (2026-10-26)

Milestone 10's second step
lets a spawned call go through a `dyn` view. The view is the call's receiver
argument, so the existing argument checks apply to it unchanged. Writing the
tests found:

- **Only a view converted at the spawn is accepted.** Answered
  (2026-10-27): a view that arrives erased, as a parameter or a stored local,
  is now checked through every type converted to it, as under
  [Sharing with tasks](design.md#sharing-with-tasks); the two directions below
  remain more precise alternatives. Before, it hid its captures, so
  [Sharing with tasks](design.md#sharing-with-tasks) rejected it. Where the
  view is converted at the spawn, the program could usually spawn the
  concrete call instead, so the step mainly makes `dyn` calls consistent
  with other calls; it does not yet let a library spawn the callbacks it
  receives. Two directions remain open. One keeps the concrete type through
  a stored local view, the loss recorded under the
  [scope review](#milestone-10-scope-and-next-step-2026-10-26), and helps
  only locals. The other is a view type that promises its target may be
  shared with a task, which is a language extension with a public contract
  and needs a demonstrated requirement.
- **A slot union is per slot, not per conversion.** Where the spawn converts
  `&q` to `dyn Recorder`, the task's write effects are still those of every
  type that fills `record`. So `Quiet`'s view is rejected because `Tally`
  writes `hits`. The concrete fill is known at the conversion, which makes
  this an easy case for step 3.
  Fixed there: a view converted where it is called runs its concrete
  target.
- **A bare spawn cannot start with a parenthesized callee.** `spawn` starts a
  statement only before an identifier, so a `dyn` conversion or procedure
  literal called in place needs a result name. [grammar.md](grammar.md#control-flow)
  now says so; its earlier wording allowed only a name or selector there.
- **No `dyn mut` mutating slot can be spawned.** A temporary `dyn mut` view
  cannot be a mutating receiver anywhere (L0359), and a stored one was erased
  (L0725). A slot that takes `self` by value through a `dyn mut` view is
  spawnable and lends the viewed value exclusively. Since 2026-10-27 a stored
  `dyn mut` view is lent to a mutating slot too, when no type converted to it
  is thread-affine.
- **Named arguments fail on a view converted in place.** This is a separate
  known gap,
  [named arguments to a slot of a view converted in place](known-gaps.md#named-arguments-to-a-slot-of-a-view-converted-in-place).

### Erased-callable spawn implementation review (2026-10-26)

Review of `9e74033`. Representing the callable view as receiver argument 0
keeps the implementation small: existing frame construction, checked run
procedures, argument evaluation order, cleanup, transfer checks, and effect
unions serve both concrete and erased calls. The target notes now reuse
`indirect_call_targets`. No extra scheduler, callable environment container,
or capture representation is needed.

Two gaps at the boundary between those shared representations were found;
both are fixed:

- A spawned dyn slot could return a worker's thread-local borrow: `spawn
  answer = (dyn Getter)(&number).get();`, where `get` returns `&counter`, was
  accepted without L0730. Return provenance used a callable-type lookup where
  an interface slot needs its actual target union. `call_callback_returns` now
  reads, with no value resolved, the returns of every body
  `indirect_call_targets` finds, as the write-back analysis does, and notes
  each as a summary dependency.
- A spawned read-only dyn slot borrowed its temporary view header: `spawn
  answer = (dyn Reader)(&number).get();` with `get(self: ^Self)` was rejected
  with L0513 at the join. The cause was broader than views. Any temporary
  lent to a borrowing parameter of a spawned call was lent from the parent's
  statement and held to the join, although the frame owns it, so `spawn a =
  count(make_bag());` with a managed `bag: Bag` parameter, and `spawn b =
  make_bag().size();` with `size(self: ^)`, were rejected too. Those loans are
  now recorded (`Flow_Graph.spawn_owned`) and left out of what the task holds;
  a result borrowing such a temporary still carries its loan and is rejected
  when used after the join. Separately, a `dyn` slot call lent the view's
  header even outside a spawn, so `p := (dyn Pointing)(&h).at(); p^` was
  rejected though the slot is given the viewed value, never the header. Slot
  dispatch now lends only what the view views.

Extra probes accepted mixed, packed, spread, and empty callable-view
variadic arguments, two read-only calls over arena-backed owned captures,
and a callable view returning a borrow of a parent local. Mutating that
local before the returned pointer's last use correctly rejects, as do
thread-local results through procedure views and thread-local writeback
through an ordinary interface slot. These checks distinguish the missing
slot-return case from the paths already covered.

One local simplification was available and is applied: `src/parallel.odin`,
`spawned_callee`, **shrink** the repeated signature selection. After checking
whether the call form is eligible, it obtains the type with `call_proc_type`
instead of selecting between the callee expression's type and the resolved
symbol's type again, which keeps the interpretation of checked calls in one
helper. Broader work on preserving stored-view facts and per-call effect
precision remains separate from these fixes.

### Per-call effect precision (2026-10-26)

Milestone 10's third step
makes the write, reach, and allocator-use effects per call: a call takes in
the callbacks it passes, a local's possible values, and a converted view's
concrete target. Writing it and its tests found:

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
- **A `dyn proc` parameter kept the union.** Only procedure-typed
  parameters and locals were followed (`effect_variable`, `effect_value`), so
  `apply :: proc(f: dyn proc(n: int) -> int, n: int)` took every procedure
  of the signature, and `spawn r = apply(quiet, 1)` was rejected when another
  call passed it one writing a global; a `proc` parameter accepted it.
  Resolved (2026-10-27): a `dyn proc` parameter or local is followed as a
  procedure-typed one is, and a view converted from a named procedure or a
  capture literal is a value naming that procedure or the literal's `call`.
  An unknown view still takes the view's own union: every slot fill and held
  procedure of its signature. The `thread_local` write-back reads the same
  resolved values and lines a held procedure up by parameter count, as it
  already did. `tests/run/parallel_callback_precision.loke` and
  `tests/err/parallel_callback_precision.loke` pair accepted clean callbacks
  and capture literals, directly and forwarded, with rejected dirty ones,
  reach, a shared arena, and a local view that may hold a dirty procedure.
  This is separate from spawning a received view at the thread boundary,
  which [Sharing with tasks](design.md#sharing-with-tasks) still rejects.
- **The `run` procedure's call resolves at its spawn.** Its frame fields name
  no procedure, so before this step a task through a wrapper took the union
  even where the parent passed a named procedure. The worker's call now
  resolves its callbacks and callee value where the `spawn` is; a parameter
  there is not `run`'s, so it stays the union.

### Per-call effect implementation review (2026-10-26)

Review of `0533623`. The shared `Call_Part` representation is a useful
boundary: the write, reach, and allocator-use analyses consume the same
selection of a body's own effects and its callback effects. `values_from`
preserves the connection between a generated worker call and its source
spawn without attempting to infer callback identity from frame fields. Keep
that structure; a generic fixed-point framework or a second target resolver
would add little here.

The 170 compiler unit tests and the run, trap, and diagnostic corpora pass.
Extra probes correctly reject two tasks using one arena through a forwarding
wrapper and through mutually recursive wrappers. No new unsafe acceptance was
found in the cases checked. One diagnostic regression was found and is
fixed: a task through a view converted at the spawn no longer named the
concrete target, since `call_effect_origins` skipped every callee's own
part. It now keeps that part for a call dispatching on a view, so the note
names `Tally.record`, or the capture literal a callable view runs; an
ordinary call still names only its callbacks.

**Erased callback parameters still take the union.** The new precision does
not extend to this non-generic callback API:

```loke
package main;
hits: int;
quiet :: proc(n: int) -> int { return n; }
dirty :: proc(n: int) -> int { hits += n; return n; }
apply :: proc(f: dyn proc(n: int) -> int, n: int) -> int { return f(n); }
serial :: proc() { _ = apply(dirty, 1); }
main :: proc() {
    answer: int;
    parallel { spawn answer = apply(quiet, 1); } // L0731
}
```

Changing `apply`'s parameter from `dyn proc` to `proc` accepts the spawn.
`effect_variable` and `effect_value` follow only procedure types; a received
callable view consequently contributes the full signature union to the
body's own effects. This is a conservative limitation, separate from
rejecting a stored view at the thread boundary: this spawn passes a concrete
procedure and the wrapper makes the erased call on its worker. Record and
test this limit alongside the other per-call precision limits before
extending the shared callback representation to erased parameters. Recorded
and tested under the [per-call findings](#per-call-effect-precision-2026-10-26),
and resolved there on 2026-10-27: this program now compiles.

Two local simplifications were available, and both are applied:

- `src/global_effects.odin`, `region_merge_grew`: **shrink** the duplicate
  merge helper. Its summary sets have only parameter, default, and unknown
  regions, and the existing `merge_region_provenance` handles those and
  reports growth already. Replace its three uses and delete the helper,
  including its comment and annotation: seventeen lines. It also kept a
  body's local regions, which `region_through` now maps to an unknown region,
  as `merge_allocator_use` does, where the removed helper dropped them.
- `src/global_effects.odin`, `clone_effects`: **stdlib** cloning an effects
  slice is `slice.clone(effects, c.semantic_allocator)`. Replace its two
  calls and remove the six-line wrapper. `core:slice` is already imported.

Net: twenty-three lines removable without changing the analysis structure.

### Dyn proc per-call review (2026-10-27)

Review of `32cf095`. No correctness regression reproduced. The isolated
diagnostic corpus, callback reach/allocator-use unit test, and
[runtime precision case](tests/run/parallel_callback_precision.loke) pass.
Additional cases accept a clean stored view and reject a dirty one, an
`inout` reassignment, an unknown view holding a writing capture literal, and
a pooled callback invalidating a live borrow of thread-local storage.

Both non-blocking follow-ups are applied:

- **Simplification:** `effect_value` in
  [global_effects.odin](src/global_effects.odin) classifies the same identifier
  through `effect_variable` once in the new view branch and again in the
  existing procedure branch. Check that the expression has either callable
  type once, return early for a converted view's concrete target, then share
  the symbol switch and procedure/variable classification. This removes five
  lines and keeps one path for parameters and locals; no new helper is needed.
- **Regression coverage:** the new accepted cases pass named procedures and
  capture literals directly, while the stored-view case only checks rejection.
  That rejection also holds with the old type union, so it does not protect
  precision for locals. Add an accepted stored-view case, for example:

  ```loke
  package main;
  hits: int;
  quiet :: proc(n: int) -> int { return n; }
  dirty :: proc(n: int) -> int { hits += n; return n; }
  apply :: proc(f: dyn proc(n: int) -> int, n: int) -> int { g := f; return g.call(n); }
  work :: proc() -> int { f: dyn proc(n: int) -> int = quiet; return apply(f, 1); }
  main :: proc() { _ = apply(dirty, 1); r: int; parallel { spawn r = work(); } }
  ```

  This is rejected with `L0731` by `9d3da3c` and accepted by `32cf095`.

`effect_value` now checks for either callable type once, returns a converted
view's target early, and shares the symbol classification.
[parallel_callback_precision.loke](tests/run/parallel_callback_precision.loke)
runs a task through a view stored in a local and copied in the wrapper, beside
a serial call passing a dirty procedure.

### Parameters a join check cannot tell apart (2026-10-26)

Writing `examples/mixer.loke` for milestone 9 found that the
[join check](design.md#releasing-before-the-join) rejects an audio loop that
takes its command receiver by `move` and its voices as a borrowed
`[]mut Voice`: two parameters' storage may be the same, so the receiver's
channel may be what a render task borrows. The types say otherwise, since a
`Voice` holds no channel, but the check compares roots, not types. Moving the
voices into the loop, as the proposal's sketch does, is accepted.

Resolved (2026-10-27): the check now tells two parameters, or a parameter and
a global, apart by the object types their roots reach. Typed storage overlaps
only by nesting, so the two may share storage only where an object one
reaches is, holds, or lies within one the other reaches; a raw or foreign
pointer, an erased view, or a type parameter still reaches anything. See
[Releasing before the join](design.md#releasing-before-the-join) and
[Channels end by ownership](comments.md#channels-end-by-ownership);
[parallel_join_retention.loke](tests/err/parallel_join_retention.loke)
accepts the audio-loop shape and rejects a parameter that holds, reaches, or
may view the channel. The test is coarse at primitive fields: a `[]mut int`
parameter still conflicts with a kept sender, since a channel's state holds
`int` fields. Whether a finer rule, for example one using field privacy,
would accept enough real programs to pay for itself is unmeasured.

### Join-check cycle traversal review (2026-10-27)

Review of `9d3da3c`. The reported by-value-cycle crash is fixed; the isolated
diagnostic corpus passes. Both non-blocking follow-ups are applied:

- **Simplification:** `roots_may_share_storage` can drop its `inside` array
  and `type_holds_inline` its stack parameter and push/pop. The only caller
  first collects both roots completely and returns on unknown storage;
  `collect_pointees` rejects a cycle over every inline edge that
  `type_holds_inline` follows. Keep that precondition explicit on the latter
  helper. This removes three executable lines and the argument plumbing.
- **Regression coverage:**
  [parallel_join_cycle.loke](tests/err/parallel_join_cycle.loke) reaches the
  cycle guard in `collect_pointees`, then returns through unknown storage
  before calling `same_storage_type`. The latter's bounded loop fixes an
  independent crash through valid recursive pointer types. Add a case like:

  ```loke
  package main;
  P :: distinct ^P;
  Q :: distinct ^Q;
  Ticket :: struct @(wakes_on_drop) { held: P }
  borrow :: proc(value: Q) {}
  check :: proc(ticket: ^Ticket, value: Q) {
      parallel { spawn borrow(value); }
  }
  main :: proc() {}
  ```

  This exits with `L0733` in `9d3da3c`; its parent overflows the stack
  (`0xC00000FD` on Windows). Keep the bounded comparison loop.

`type_holds_inline` no longer takes a stack, and its comment states the
precondition; `parallel_join_cycle.loke` adds the self-pointer case.

The root collector's independent cycle guard is useful: body-local type
declarations do not run through the package's finite-size phase, so checking
only `size_state == .Cyclic` would not cover every input. A recursion path
also tells a cycle apart from two sibling fields of the same type; replacing
it with a visited set that treats every revisit as unknown would reject
unrelated storage unnecessarily.

### Channel fix follow-up review (2026-10-26)

Review of `1c0bae5`. All three findings are fixed:

- The field-path filter in the [join check](design.md#releasing-before-the-join)
  dropped wakers reached through a generic record's type arguments: a
  `Ticket(thread.Guard(int))` whose only field points to the task's mutex was
  accepted, though `e8238f6` rejected it and such a record may hold a guard
  behind a `rawptr`. `path_waker` now counts every carrier of a record whose
  type argument reaches a marked type.
- A sibling field's borrow was still conflated with a guard's after a
  conversion to a distinct type. A conversion's result reached every operand
  slot from every path, and content selection compared shapes by exact type.
  A conversion now projects its operand's slots by path, and selection
  compares underlying types, which share one carrier shape.
- The commit had no **Unreleased** entry in [CHANGELOG.md](CHANGELOG.md#unreleased).
  It now records the `Receiver.iter` change under breaking changes, with the
  upgrade of keeping the receiver alive until its iterator ends, and the
  newly accepted wrapper case under fixes.

[parallel_join_retention.loke](tests/err/parallel_join_retention.loke) covers
the generic record, and the distinct conversion both accepted on the sibling's
mutex and rejected on the guard's. The direct wrapper case, iterator lifetime
check, and worker-completion handshake pass their regressions. Folding waker
detection into the existing type walk, removing the redundant capacity field,
and inlining `take` keep the implementation simpler; no additional abstraction
is called for.

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
- **Generic code over both result shapes.** A procedure generic over
  `Result($T, $E)` does not accept a `Status(E)`, so a library that is generic
  over fallible results may need both forms. A parametric type alias,
  `Status :: Result(Unit, $E)`, would have avoided this; see
  [Parametric aliases](#parametric-aliases).

## Anonymous unions and their follow-ups (2026-10-18)

A design exploration of 2026-10-17 and the proposal that followed it led to
five adopted changes: [Success returns](design.md#success-returns),
[Anonymous unions](design.md#anonymous-unions),
[Widening by label](design.md#widening-by-label),
[Per-variant switch cases](design.md#per-variant-switch-cases), and
[Union argument expansion](design.md#union-argument-expansion). comments.md records why,
including why `Result`, `Option`, and `Status` remain the fallible boundaries
([Anonymous unions](comments.md#anonymous-unions)). What the proposal left
open follows.

### Generic implementations on structural shapes

A parameter's anonymous record or union binds its `$` names by label
([Specialization](design.md#specialization)), but an `impl` subject does not:
`impl (a: $T, b: $T) { ... }` is `L0437`, since a generic `impl` names a
generic record's application, as `impl Pair($T, $T)` does. An `impl` over a
shape would be an [extension](design.md#methods-and-implementation-blocks)
whose subject is a pattern, which method lookup does not match today. Revisit
when a program wants methods on a family of shapes.

### Parametric aliases

Anonymous unions remove declarations but make signatures longer. A plain alias
already shortens a signature, as `Io_Status :: Status(Io_Error);` and
`Config_Error :: (io: io.Error | parse: Parse_Error);` do, and a named shape
still widens and still matches another package's identical shape. What a plain alias
cannot do is fix one argument of a generic: `Result(T, io.Error)` needs `io` to
name `Result($T, Error)` once, as Rust's `io::Result` does. That is a separate
generics feature with its own design. It would not merge `Status` into
`Result`, whose end-of-body rule differs, but it would have let `Status` be an
alias; see [Error handling](#error-handling-2026-10-13).

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
every set that spreads it. Each caller's `switch` then fails to compile until
it handles the new label, which is the intended signal. Compare it with
restating the labels in the [representative programs](#evaluating-on-representative-programs)
before deciding.

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
- **Code size.** Each expansion is compiled once per variant, and the backend
  does not merge identical copies yet.

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

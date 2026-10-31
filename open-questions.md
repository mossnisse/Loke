# Open questions

Decisions that are deliberately not yet made are recorded here rather than left
implicit in normative prose. [`design.md`](design.md) defines the rules
implementations must follow for the current language version; these questions
concern possible later changes.

Design rationale and differences from Odin are recorded in
[comments.md](comments.md).

The current behavior inventory is in [Nondeterminism and undefined behavior
audit](nondeterminism-audit.md).

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
annotations. Three decisions remain open:

- **Retaining normalized bodies.** Each clean body is normalized about four
  times per compilation: once collecting global writes, once in the summary
  discovery visit and once from the worklist (a body with no result and no
  owner writes skips both, and one whose callee's summary grew is visited
  again), and once for its own diagnostics. Measured on 2026-10-28 with a
  temporary per-body counter on the `bench/baselines/README.md` workloads
  (`bench/provenance.loke`, `bench/workspace`, `examples/corpus_runner.loke`),
  bodies were built 3.9-4.0 times each (at most 6), and the normalizations
  after each body's first cost 6 / 120 / 192 ms of 31 / 386 / 682 ms checking
  time, 20-31%, the most retaining could save; repeat visits would still
  replay and materialize. Retaining every construction graph until its
  diagnostic pass would hold 1.6 / 27 / 38 MB of analysis arena (0.4 / 7 /
  10 MB in table entries alone) against compiler peaks of 12 / 60 / 89 MB.
  A retained input must also serve the diagnostic pass, whose construction
  walk alone reports cross-thread calls and `spawn` transfers, and outlive
  the per-body release of the analysis arena.
- **Lifecycle analysis on the same input.** Lifecycle analysis still walks the
  checked AST, and provenance consumes its settled decisions. Moving it onto the
  normalized input needs its own design for unresolved cleanup and last-use
  decisions.
- **The cost of normalization.** Against the measurements taken before the
  normalized input was introduced, checking costs 7 to 14% more front-end time
  on the selected workloads and 3 to 10% more per workspace LSP operation, while
  compiler peak working set is 5 to 10% lower on the larger workloads.
  Normalization is the largest provenance phase in the current records, under
  "Completed migration (stage 5)" in the repository's
  `bench/baselines/README.md`. Whether to accept that cost or reduce it is open.

## Places one chosen pointer keeps apart

[Minimum provenance precision](design.md#minimum-provenance-precision) bounds
aggregate nesting, carrier paths per type, fixed arrays, and map keys, but not
how many places a pointer chosen across branches may point at. `lokec` keeps
eight (`PROV_OFFSET_LIMIT` in
[src/cfg_provenance.odin](src/cfg_provenance.odin)) and past that merges the
two sharing the longest prefix, so a pointer chosen among nine fields of
`s^.left` and `s^.right` is taken to point into `s^.left`, and a write to
`s^.left.z` is rejected with `L0641`. The diagnostic says the reborrow *may*
cover the place and names the limit, as the section requires. Open: whether
the precision table should guarantee a number of such places, which would make
this program portable; the bound keeps the place loans and `.Through` events a
borrow makes few.

## Compositional loan construction

Every access to a place reached through carriers goes through one walk of the
normalized place, and a borrow, slice, traversal, or switch of one takes a
**place loan** ([Ownership, lifecycle, and
provenance](compiler-architecture.md#ownership-lifecycle-and-provenance));
[borrow_matrix_test.odin](tests/borrow_matrix_test.odin) checks the rules
against a model written apart from the compiler. Still open:

- **A view's elements.** A view's loans name its elements with a wildcard, so
  they are one place: `&mut s[0]` suspends `s[1]`, and a write to
  `s[1].first` conflicts with a switch over `s[0].first`. Making a constant
  element its own place changes the path a view's access states.
- **Calls.** A carrier handed to a call uses every mutable carrier it reaches.
  A per-parameter summary of what a body uses through each parameter could
  narrow that, as written-argument regions already do for stores.
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
- **Matrix coverage.** Slices and traversals are taken of a fixed array, so
  no use beside them reallocates storage, and nothing leaves a traversal or a
  loop early with `break` or `return`. A loop that takes afresh is the one
  shape whose legality differs from straight-line code's: an earlier
  iteration's store changes what the place holds.

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

`Once` in `core:sync` spins without yielding while another thread runs its
action, and `sync.Lazy(T)`'s `get` spins the same way while another task runs
its `init`. A blocking address wait would serve both if slow, contended
initialization turns out to be a real workload; no contention benchmark has
been run.

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
  Their results are the same everywhere either way. Binary64 `sin`, `cos`,
  and `tan` now have published hard cases (Lefèvre, Ly, and Zimmermann,
  "Computing hard-to-round cases of sin, cos, tan in double precision",
  ARITH 2026); checking the slow paths against them would settle those
  three.
- Should the compile-time evaluator reclaim what a call frees? A call to
  `core:math/repro` that takes its fixed-point slow path uses 8 to 16 MB of
  the evaluator's 64 MB budget (`L0342`), since nothing a call frees is
  reclaimed, so one constant can fold four such calls but not eight; a call
  its fast path decides uses far less. `core:math`'s integer `fma` takes
  about 250 KB a call the same way.

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

A named slot is met by an inherent method whatever its visibility, while an
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
- **Printing a zone.** A `Zone` prints as `Zone{}`, whatever it holds, since
  its field is private. A fixed zone could print its offset; what the system
  zone prints waits on its name.

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
  shown to hold.
- **Explicit reductions.** A floating-point sum is ordered, and the default
  arithmetic stays strict. Separately named reassociating or tree reductions,
  with their numerical differences documented, would let a kernel ask for the
  faster order.
- **Copy elision.** Which implicit copies of a type with a custom clone or
  drop may be elided is unspecified, so none is.

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
    Closing it needs a read effect over globals, or a rule that rejects a
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
- **Generic code over both result shapes.** A procedure generic over
  `Result($T, $E)` does not accept a `Status(E)`, so a library that is generic
  over fallible results may need both forms. A parametric type alias,
  `Status :: Result(Unit, $E)`, would have avoided this; see
  [Parametric aliases](#parametric-aliases).

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

Anonymous unions remove declarations but make signatures longer. A plain alias
already shortens a signature, as `Io_Status :: Status(Io_Error);` and
`Config_Error :: (io: io.Error | parse: Parse_Error);` do, and a named shape
still widens and still matches another package's identical shape. What a plain
alias cannot do is fix one argument of a generic: `Result(T, io.Error)` needs
`io` to name `Result($T, Error)` once, as Rust's `io::Result` does. That is a
separate generics feature with its own design. It would not merge `Status` into
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

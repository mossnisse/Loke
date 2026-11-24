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

## Provenance architecture

The review of `b8499982` found two follow-ups to the
[synchronized variable exemption](design.md#global-write-effects).

- **Preserve the lifetime of interior borrows.** A caller can hold one mutex
  across borrowing a slice of a synchronized dynamic array, calling a helper
  that shrinks the array, and using the slice. All accesses are serialized.
  If shrinking relocates or releases the allocation, the earlier slice loses
  its backing storage. The compiler accepts the call today. How should the
  write effect preserve that lifetime check while still allowing multiple
  handles to the fieldless standard logger?
- **Exercise the synchronized write through a slot.** In the
  [global effects fixture](../tests/err/global_effects.loke), only `Circle`
  is converted to `dyn Shape`. Converting `Counter` too would include its
  write to `vouched` in the targets of `shape.area()`. With the attribute
  removed, that call should then produce its own borrow conflict.

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

## Compiler source audit follow-ups (2026-11-18)

- **Measure the borrow solver's allocation and rescanning hypotheses.** The
  audit lists changes it could not justify without a workload: skipping the
  loaded-below rows of a body with no cursor anchor, caching `at_once_reaches`
  per source, a visited row in `with_held_content`, marking a reaching row
  dirty only when a join adds a bit, one backing allocation per block table,
  enumerating set bits in `merge_escape_event`, per-body scratch in
  `stored_thread_facts`, and collecting an event's released loans once for
  `mark_released` and `end_loans`. Run `perf.ps1` on borrow-heavy bodies before
  and after each.

The divergences the audit led to that remain are in
[Known gaps](known-gaps.md#gaps).

## Compiler source audit continuation

The per-file source reviews were removed from the repository; these points
remain from them:

- **Measure first.** Batching later-read queries per block in `cfg.odin`,
  ranges per binding for callback arguments, stopping carrier-shape sibling
  walks after overflow, keyed precision for slices reached through a carrier,
  a worklist for the private-declaration closure in `doc.odin`, opt-in
  provenance profiling counters, and grouping disposable compiler state for
  checkpoints.
- **Unifying the LLVM naming and emission walks** around one procedure
  eligibility decision.

## LLVM source review follow-ups

- **Returning a large value.** A result over 4096 bytes is written through a
  hidden pointer, and three passes over it remain at `-opt=speed` (read in the
  IR on 2026-11-22, Clang 22): the result slot is zeroed on entry, `return out;`
  copies the local into it, and the caller's `x := f();` copies the call's
  temporary into `x`. LLVM folds the second temporary of `return out;`, and
  leaves `return Large{...}` no copy. It cannot remove the rest: each local's
  address is published for the unwind, so none is provably unaliased. A
  procedure returning a 5000-byte local through 100 levels of recursion takes
  210 ns a call, 42 ms for 200,000, and the same procedure through an `inout`
  parameter makes none of the three passes. Building the local in the
  result's storage needs a rule for which local that is: every `return` names
  it, and no `or_return` or other exit publishes into the slot while it is
  live. Passing `x` as the callee's result needs the unwind never to read `x`
  before the call returns. The two rules are what is open; until they are
  settled a program has the fast form with an `inout` parameter.
- **Container emission.** Measure miss-heavy `find_or_insert` before
  changing the runtime ABI to reuse a probe across a user copy hook.

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

## Package documentation

The plan for [what a package tells its users](future-plans.md#package-documentation)
generates it from source, checks it, or runs it. It leaves these open:

- **Allocation.** Whether a call allocates at all is what a caller with an
  arena or a hot loop most wants to know, and the result contract does not
  answer it. It needs its own inferred effect, and then an `inferred:`
  phrasing.
- **Signatures Loke cannot state.** An operation the compiler types itself,
  such as `unsafe.transmute` or `unsafe.raw_data` with its five operand forms,
  has an `@(intrinsic)` signature written for readers and checked only for its
  name. Checking more needs a signature form that states such typing, or a
  rule for which written forms an operation's typing must accept.

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
treated separately under [Thread-affine strings](future-plans.md#thread-affine-strings).

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

A helper lent a queue marks the parameter
[`@(concurrent_regions)`](design.md#concurrent_regions) to send what the queue
holds, and so does one that shares an allocator or a slice of slots among
tasks ([reasons](comments.md#a-parameter-promises-its-regions)). Two questions
about the attribute are open:

- **A provider that declares it accepts concurrent use.** Only the default
  provider does, so the promise is that the default provider backs the
  argument, and a program with a thread-safe provider of its own cannot say so.
  Declaring one would also reopen the rule against `@(allocator_reset)` on the
  same parameter, which costs nothing while no region is both.
- **A large record.** Marking a receiver promises all of its storage, though a
  helper may send from one queue in it. A promise on a field, a record field
  declared to hold only such storage, would narrow that, at the price of
  checking every write to the field. A program whose record holds both a queue
  it sends from and an arena's owners should decide it.

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

## Open questions in `core:fmt`

- Printing a float still goes through the C library: the runtime tries
  `snprintf` precisions until `strtod` reads the value back, both in a "C"
  numeric locale whose creation can fail. So printing a float can panic,
  `try_spell_f64` has a `Backend_Error`, and, being foreign code, neither runs
  in a [constant](design.md#compile-time-procedure-evaluation).
  [`strconv.parse_f64`](standard-library.md#corestrconv) is Loke code now and
  could do the reading back; a shortest-spelling algorithm in Loke, such as
  Ryu or Schubfach, would remove the rest. Is that worth its code and tables?

## Enum_Array simplifications

- Container formatters write their punctuation with `fmt.format_to`, which
  goes through variadic `dyn Formattable` formatting. Writing it with
  `writer.write(literal.bytes())` made formatting a 256-member `Enum_Array`
  about 10% faster (fastest of five runs, 70.5 ms to 63.0 ms at `-opt=speed`).
  Should `core:fmt` make a single literal argument cheap, so every formatter
  gains without each spelling it differently?
- `filled` builds its slots in a `Small_Array` rather than with a designated
  range initializer, `{0..<N = value}`, because [design.md "Fixed
  arrays"](design.md#fixed-arrays) does not say what each slot of a range is
  copied from. Today the compiler clones later slots from the first copy: with
  a copy hook that increments its source ID, filling three slots from ID 100
  gives `101 102 102`, where cloning the given value each time gives
  `101 101 101`. Should every slot of a range be a clone of the written value?
  If so, `filled` could use the initializer once the compiler agrees.
  [Constructor](../core/container/enum_array.loke#L36)

## Constant tables in the front end

- A large array constant is slow to check. `core:strconv`'s table of powers
  of five, 1302 `u64` literals of 16 hexadecimal digits, adds about 11 ms to
  the front end of every program that imports the package: a program that
  prints one parsed float went from 43 to 54 ms (`-emit-ll`, fastest of 15,
  2026-11-22), and 51 ms of that remains when nothing reads the table. Alone
  in a program, the same table costs 9 ms, 1302 one-digit literals 4 ms, and
  the same digits in one raw string 1 ms: about 3 µs an element and 0.2 µs a
  digit. Where the time goes is not profiled; `bi_parse_int_literal` reads
  every literal into a big integer. Until this is cheaper, a package pays for
  its tables in each build, and a constant that computes one is no way out:
  only decoding this table from that raw string by compile-time evaluation
  took over 200 ms.

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

## Open questions from the linear algebra spike

A spike tried `linalg`'s `Real` interface and generic matrix shapes against
the compiler ([tests/pkg/real_interface](../tests/pkg/real_interface)) before
[`core:math/linalg`](standard-library.md#coremathlinalg) and then
[`core:math/dense`](standard-library.md#coremathdense) were built on them.
These language questions came out of that work, and the libraries cannot
settle them by themselves.

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

### Overflow checks in index arithmetic

The checked operators panic on overflow
([Integer overflow](design.md#integer-overflow)), and a branch per element
keeps the optimizer from vectorizing a loop, even where the induction
variable and the bound make an overflow impossible. A signed sum or
difference written as an index no longer has a branch of its own: its
overflow is tested behind the bounds comparison
([Runtime and library boundary](compiler-architecture.md#runtime-and-library-boundary)),
and LLVM vectorizes past that, so `xs[i + offset]` and `xs[i - offset]` in a
loop cost what the wrapping forms do. A check that does not vary in the loop,
behind one that does, is removed by unswitching the loop, which `-opt=speed`
[asks for](comments.md#-optspeed-unswitches-loops) as `-opt=aggressive` always
did: the checked `k*n` of `out[i + j*n] = out[i + j*n] + a[i + k*n]*factor`,
or a `b[round]` after `a[r*n + c]`. Two shapes still pay, measured on
2026-11-16 after `c2645cd2` with Clang 22.1.8:

- **An operation below the last one.** In `xs[base + i + 1]` the inner
  `base + i` keeps its branch. The bounds comparison cannot stand in for it,
  since a valid index may pass through a negative result, as `xs[i - 10 + 20]`
  does, and a sum that wrapped looks the same. `xs[i + (base + 1)]` is the
  fast form.
- **A product**, which can wrap to any index.

Proving the common shapes overflow-free (an index affine in loop variables
whose ranges are known before the loop) does not reach a loop such as
`hand_multiply`'s, where nothing bounds `n` before the loops; versioning the
loop would, at the cost of a second copy of it. A descending index, `xs[last - i]`, is not vectorized
with `-%` either, so its checks are not what holds it.

## Formatting

The current formatter rules and rationale are in [comments.md
"Formatting"](comments.md#formatting).

Open: aligning columns automatically, as `gofmt` does, so a renamed field
does not leave its neighbors misaligned; indenting a continued line inside
brackets, which `core/` leaves at the bracket's level; and indenting the later
values of a wrapped multi-value statement (`x, y :=` above `1,` and `2;`), whose
commas read as a list's, since the tokens do not tell a block's `{` from a list's.

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

# Open questions

Decisions that are deliberately not yet made are recorded here rather than left implicit in normative prose. [`design.md`](design.md) defines the rules implementations must follow for the current language version; these questions concern possible later changes.

Design rationale and differences from Odin are recorded in [comments.md](comments.md).

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

## The `op`/`try_op` pair

Should a container keep both spellings of a fallible operation? `append`/`try_append`, `reserve`/`try_reserve`, and the rest double the container API over a failure-policy choice. Typed fallibility made the fallible variant cheap — a `try_` operation reports failure as a `Result` rather than a bare `bool`, over an ordinary library union with `@(failure=...)` and no compiler-known error type — which is what makes keeping both spellings need re-justifying. Every shipped container keeps its pair today; collapsing them is a separate decision with its own migration.

The language pairs a fallible operation with a policy-following one in a second place: the compiler-generated [`clone`/`try_clone`](design.md#lifecycle-hooks-and-resource-types). The shape is identical, so the two are one question asked twice — but they are not one answer, for two reasons that the container pair does not share.

The pair costs a type author nothing. Both names are generated from the single `hook(copy)` role, so a record supplies one implementation and receives both spellings; a container supplies two implementations, two doc entries, and two test paths per operation. Duplication in the generated pair is two names, not two bodies.

And the policy-following half is load-bearing rather than convenient. Copy assignment of a copyable type is *defined* as `try_clone` plus the [allocation failure policy](design.md#allocation-failure), and [`Cloneable`](design.md#standard-interface-catalogue) names the fallible slot, so both halves already have language-level jobs. Deleting `clone` would not remove the policy call, only move it to every call site that copies. A container `try_op` carries no equivalent obligation, which is what leaves the container pair the live half of the question.

The allocation built-ins are a third instance, and they keep the pair: `box`/`try_box`, `make`/`try_make`, and `unsafe.new`/`unsafe.try_new` (see [The allocation built-ins follow the `try_` convention](comments.md#the-allocation-built-ins-follow-the-try_-convention)).

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

## exponent operator

 ** for pow(a,b)? ^ are used for pointers.

## intrinsics and inline assembly

How to add some suport to go even more low level and use SIMD efficiently, Intrinsic or inline assembly?

## abstraction over SOA

Is it the programers responsibility to abstract ove the right thing or does the language need some help with that?

## LLM optimization

token optimization, can the syntax be made to be token efficient?
LLM readability and writability, how does that differ from humans? LLM's are trained on human data but works differently.
Encapsulation and abstractions must still be important so they can work on an part of the code.

## garbage collection

add an garbage collected allocator as an alternative?

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

```odin
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

- **The `µ` in `µs`.** It is U+00B5, two bytes of UTF-8, as Go prints it. A
  console whose code page is not UTF-8 shows it wrongly; `us` is the ASCII
  alternative, which the parser accepts either way.
- **Zero-padded custom forms.** Other formats, such as `15.10.2026`, are built
  from the accessors, but `fmt` cannot pad with zeros. A `fmt.zero_pad` wrapper
  beside `pad_left` would serve every integer and is preferable to a pattern
  language here.
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

## Keywords reserved in every position

[grammar.md "Keywords"](grammar.md#keywords) reserves 36 words in every
position, and only a few (`self`, `slot`, `using`, `delegate`, the `hook` roles)
are contextual. Some reserved words are also common names: writing
`examples/lexer.loke`, a procedure could not be called `operator`. A
self-hosted compiler would meet this throughout. Counting declarations that use
one as a name (`name :=`, `name:`, `name,`) in the Odin compiler's `src/`:
`type` about 970, `hook` 27, `operator` 20, `in` 16, `dyn` 11, `via` 9.

Should words that only begin a construct in one position, such as `operator`,
`hook`, `via`, `where`, and perhaps `type`, become contextual, like `delegate`
already is? The cost is parser lookahead and error recovery that has to tell a
name from the keyword, and diagnostics that can no longer say "expected a name,
found keyword" there.

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
| Floating-point expressions | Unwritten FMA contraction and reassociation are forbidden | Add explicit `math.fma` and separately named reassociating reductions; keep default arithmetic strict |
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

[The memory model](design.md#concurrency-and-the-memory-model) deliberately leaves
data races, thread-affine destruction, and allocator thread compatibility to
the programmer. An atomic reference count does not make its payload or bound
allocator safe to use on another thread. The current `thread.spawn` also uses
`@(escape=static)`, so joining its handle is not sufficient to let a worker
borrow an ordinary local slice.

**Proposal:** initially make unchecked cross-thread transfer explicit. A later
checked API can validate recursive transfer/share capabilities, with opt-outs
for foreign handles and custom lifecycle hooks and an explicit contract for
allocator deallocation on another thread. A type-only `Send` predicate is not
enough when two values of the same owning type may use different allocators.

Add scoped workers only with a scope-owned join guarantee, enabling disjoint
borrowed slices to be processed before the parent continues. That guarantee
must survive ordinary early exits and leaked/dropped user handles; relying
solely on a handle's destructor is insufficient when `unsafe.forget` can skip
it. Process termination may end the guarantee because no parent continues.
Do not add futures, async syntax, or reactive variables merely to solve this
borrow-and-join problem. See [Concurrency refinements](#concurrency-refinements).

## Language design review (2026-10-11)

A second set of proposals, not an amendment to the specification. The review
read design.md and grammar.md in full, checked each idea against comments.md
and the questions above, and confirmed every behavior it cites with the
shipped compiler at `1ba3c84`. Backward compatibility is not a constraint; a
proposal that reverses a recorded decision says so. The compiler/spec
divergence it found, rune constants converting to floating-point types, has
since been fixed.

The core holds together: one capability axis spelled `mut`, non-null
references with `Option` niches, fallibility by union shape, exhaustive
switches, checked arithmetic and conversions, definition-site lookup, and
hermetic compile-time evaluation. Most proposals were about where everyday code
meets that core: printing, map keys, early exits, error plumbing, and
temporaries. The structural concern is that more checking depends on inferred,
whole-program facts than a library's signatures show; see
[No public mutable globals](#no-public-mutable-globals) and
[Public borrow contracts should stand on their own](#public-borrow-contracts-should-stand-on-their-own).

### Adopted

These proposals, the ones ranked "Next" and the smaller items since, were
adopted. design.md defines each under the headings named, and comments.md
records the reasoning:

- `in` tests ranges, which bind tighter than comparison ("Ranges",
  "Operator precedence").
- `or_else` may `break`, `continue`, or `return` ("or_else expression").
- A `package main` prints its fields and cannot be imported ("Exported
  names").
- A checked pointer prints as its referent ("String format printing").
- A record that keeps its generated `==` gets a generated `hash` ("Maps").
- `main` may return a fallible union ("Program entry and exit").
- An anonymous record whose fields are ordered orders lexicographically
  ("Comparison operators").
- References and owning handles are together the non-null types, which the
  `Option` niche covers ("Types with no zero value", "Representation").
- The handle types are `Box(T)`, `Shared(T)`, and `Weak(T)`; `box` and
  `shared` are only constructors ("Owned values", "Shared ownership").
- A temporary that a local's declaration or whole assignment borrows lives
  until its block ends ("Temporaries and procedure boundaries").
- A case binds a record payload's fields, `case .add(left, right):`, borrowed
  over a place and transferred over a temporary ("Inspecting a union", "Switch
  ownership").
- The [error handling proposal](#error-handling-2026-10-13), which replaced
  declared error wrapping and settled the failure-only `defer`: a failure
  operand after `or_return`, `Status(E)`, a body that ends in its payloadless
  success, and `errdefer` ("The failure operand", "Typed fallibility", "One
  result", "defer statement").

### Recommended order

| Priority | Proposal | Main benefit |
| --- | --- | --- |
| Later | Checked unsigned arithmetic | Wraps become panics; reverses a decision |
| Later | No public mutable globals | Effects stop crossing packages invisibly |
| Later | Test procedures | Unit tests for package-private code |

### Checked unsigned arithmetic

Signed `+`, `-`, and `*` panic on overflow; unsigned ones wrap. The compiler
prints `4294967294` for `u32(3) - u32(5)` and `240` for `u8(' ') - u8('0')`,
and `1 << k` is `0` for `k := -1`. Lengths are `int`, so unsigned values appear
in byte, `u32`, and `u64` code — parsers, codecs, bindings — which is where an
unnoticed wrap does harm. [Signed overflow panics](comments.md#signed-overflow-panics)
keeps unsigned arithmetic modular for hashing and bit manipulation, which
already have `math.wrapping_*` and could take Zig's `+%`, `-%`, and `*%` if the
calls are heavy; the FNV hash in
[Compile-time procedure evaluation](design.md#compile-time-procedure-evaluation)
would need one. Proposal: check unsigned `+`, `-`, and `*` as signed ones are,
keep shifts and atomics modular, and panic on a negative signed shift count,
which a constant count already rejects. This reverses a recorded decision and
costs a check wherever the optimizer cannot discharge it.

### No public mutable globals

[Global write effects](design.md#global-write-effects) are inferred over the
whole program and are not part of a procedure's type. A print takes the union
of every `format` method's effect, a `dyn` call that of every witness for its
slot. A library that adds a write to one of its globals can therefore break a
caller in another package with no signature changed, and incremental checking
must track inferred effects as a dependency that signatures miss.

A caller conflicts only over a global it can borrow. Reject `@(public)` on
mutable file-scope, `static`, and `thread_local` variables, and an importer can
borrow another package's global only through a procedure returning that borrow,
whose result contract already shows static provenance. Effects then cross a
package boundary only for statics a package visibly lends. `core` pays almost
nothing: its one public mutable global, `os.args`, is a zero-sized view that
could be a constant.

### Test procedures

The roadmap's parser and self-hosted compiler need unit tests, and
`core:testing` is an [optional gap](future-plans.md#standard-library-maturity).
A unit test reaches package-private code, which only code in the package can.
Mark zero-argument procedures `@(test)` and compile them only in a test build
that runs each and reports a failed `assert` or `panic` by location. A panic
cannot be caught, so the runner either runs each test in its own process or
stops at the first failure; see [Recoverable panics](#recoverable-panics). Zig's
`test` blocks and Go's `_test.go` files are the precedents; an attribute needs
no new syntax.

## Error handling (2026-10-13)

The error handling proposal of this date is adopted: `or_return` takes a
failure operand that replaces or maps the error, `Status(E)` serves procedures
that only fail and has replaced `Result(Unit, E)` across `core` and the `try_`
operations, such a body may end without `return .ok;`, and `errdefer` runs on a
failure exit and during unwinding. design.md defines them under "The failure
operand", "Typed fallibility", "One result", and "defer statement"; comments.md
records the reasoning and the alternatives not taken. These parts are open:

- **A replacement that discards information.** `f() or_return .Bad` drops the
  error `f` returned. That is explicit at the site, as the switch it replaces
  was, but when the error is not an enum a lint could ask for a mapper.
- **Binding the error in `errdefer`.** Zig's `errdefer |err|` names the error
  being returned. An `errdefer` reads locals today; binding needs a syntax and
  a rule for an error that has moved into the result.
- **Whether `ok_or` keeps a job.** A failure operand covers every propagation
  `ok_or` served and evaluates its error only on failure; `ok_or` remains for
  an `Option` that is stored or passed on. `map_error` keeps the same job for
  a `Result` or `Status`.
- **Generic code over both result shapes.** A procedure generic over
  `Result($T, $E)` does not accept a `Status(E)`, so a library that is generic
  over fallible results may need both forms. A parametric type alias,
  `Status :: Result(Unit, $E)`, would have avoided this, and is worth
  revisiting if aliases gain parameters for another reason.

## Lone carriage returns in the language server

The LSP source review of 2026-10-16 found two line-ending problems in
[paths.odin](lsp/paths.odin). Positions inside a `\r\n` are now clamped
before the `\r`. A lone `\r` is still not a line break for the server, though
the [LSP text-document rules](https://github.com/microsoft/language-server-protocol/blob/gh-pages/_specifications/specification-3-14.md#text-documents)
make it one: in `"abc\rdef"`, the client's `{1, 1}` is the server's line 0, so
`position_to_offset` returns the end of the text rather than 5.

The server counts lines as the compiler does, by its
[source line table](src/source.odin), which only `\n` ends. That matches the
language: [grammar.md "Whitespace and comments"](grammar.md#whitespace-and-comments)
makes a carriage return whitespace, and a line comment runs to the newline, so
a `\r`-only file is one line whose first `//` comments out everything after
it. Treating a lone `\r` as a line break in the server alone would disagree
with every compiler-reported span. Agreeing with the protocol needs either
compiler line tables, and the formatter's, that also end lines at a lone `\r`,
or a decision that `\r`-only sources are rejected or normalized on load.

## Core source review (2026-10-17)

All 38 source files in `core/` were reviewed individually. Three subagents
covered numerics/random, platform/I/O, and foundational containers/intrinsics;
the coordinating review covered formatting, logging, text, parsing, and time.
The scope included correctness, ownership, error paths, performance, structure,
and simplification. The review itself changed no library behavior; findings
fixed since are marked **Fixed** below, with the change recorded in
[the changelog](CHANGELOG.md#unreleased).

### Correctness and specification findings

These are P2 findings unless marked P3. All are fixed; the reproductions are
the regression tests named in each row:

| ID | Location | Finding |
| --- | --- | --- |
| G1 | `core/process/process.loke:203-206` | **Fixed:** a stderr capture failure could hang `output`: the worker recorded failure, but the parent waited for stdout EOF before inspecting it. The worker now ends the child itself. Regression in `tests/obj/process_output_fault.loke`. |
| G2 | `core/term/term.loke:363-371` | **Fixed:** raw-mode acquisition could save a stale raw snapshot, leaving the console raw after both owners close. The claim is now taken before the snapshot. |
| G3 | `core/path/path.loke:174-178` | **Fixed:** joining an extended path could duplicate a separator, turning a valid path into `Invalid_Path`. Regression in `tests/run/lib_path`. |
| G4 | `core/math/complex.loke:308-314,331-337` | **Fixed:** quaternion inverse overflowed a shared factor, destroying finite components and turning zero components into NaNs. Regression in `tests/run/lib_numeric`. |
| G5 | `core/math/complex.loke:225-237,266-278` | **Fixed:** complex division lost subnormal contributions, so a quotient of `0.4-0.2i` became `0.5+0i`. Regression in `tests/run/lib_numeric`. |
| G6 | `core/log/log.loke:70-76` | **Fixed:** standard log records interleaved across threads; five writes per record did not preserve its line. A lock now spans the record, and logging from a spawned thread no longer warns L0707. Regression in `tests/run/lib_log_threads`. |
| G7 (P3) | `core/container/small_array.loke:199-219,243-244` | **Fixed:** the normative section denied consuming try-insertion, although the API and the release notes deliberately supply it. Regression in `tests/run/lib_move_only_containers`. |
| G8 (previously noted) | `core/strconv/strconv.loke:125` | **Fixed:** floating parsing followed the mutable C locale, so a decimal comma locale made `1.5` succeed as `1.0`; `fmt` printed `1.,5` under the same locale. The runtime now spells and reads floats in a fixed "C" numeric locale. Regression in `tests/run/lib_numeric_locale`. |

### Confirmed performance findings

O1 through O4 are **fixed**; O1 has a copy-count regression in
`tests/run/lib_slice`.

- **O1, P2: retain the winning index in slice extrema.**
  `core/slice/slice.loke:164-179` clones the initial element, every improved
  candidate, and the final union payload. An `Ordered` record with a counted
  copy hook gives five clones for `min` on four descending elements and two
  for `max`. Keeping an index and returning
  `.some(values[best].clone())` produced the same minimum with one clone.
  This removes potentially allocating copies and related L0507 warnings,
  with essentially no line-count change. Keep the strict comparison to
  preserve first-winner ties and current NaN behavior.
- **O2, P2: make iterator enum tables constants.**
  `core/container/bit_set.loke:169` and
  `core/container/enum_array.loke:111,129` use `members := E.values()` in
  every `next`. Default-build LLVM initializes the entire enum array on the
  stack on each call, making full iteration copy O(n²) enum values. An
  isolated `members :: E.values()` version returned identical results and
  emitted a private constant table with an indexed load instead. Zero net
  lines; the evidence concerns the default build, since optimization may
  eliminate some copies.
- **O3, P2: borrow large inline receivers explicitly.**
  `core/container/small_array.loke:65-69,305-323` uses plain `self` for
  queries and validation helpers. With trivial elements the ABI copies the
  aggregate: emitted LLVM copies all 1,048 bytes of `Small_Array(int,130)`
  for a bounds or fullness check. The construction loop at
  `core/container/enum_array.loke:38` tests `is_full` 131 times for 130
  members, repeatedly copying its entire buffer. Use `self: ^` for
  `len`, `cap`, `is_empty`, `is_full`, `space`, `check_index`, and
  `check_span`; review `get` the same way. Zero net lines. This follows
  [the specified parameter ABI](design.md#parameter-semantics-and-abi-lowering),
  rather than indicating a compiler correctness bug.
- **O4, P2: return immediately when repeating empty text.**
  `core/strings/strings.loke:310-312` performs `times` append calls even
  when the result must be empty. In an optimized build, repeating empty
  text once took about 700 ns; ten million repetitions took about 42 ms.
  A very large valid count makes an empty result arbitrarily expensive.
  After checking that the count is nonnegative, skip the loop for empty
  text or zero repetitions. Preserve allocator and empty-string semantics.
  These are illustrative local timings, not a benchmark across platforms.

### Simplification and structure

The complexity pass used the `ponytail-review` skill. These are optional P3
refactorings with concrete replacements; no speed claim is implied:

- `core/fmt/fmt.loke:L141-146: shrink:` construct
  `Collector{make([dynamic]u8, 0, 64, allocator)}` directly. Remove the
  intermediate `sink` and its transfer explanation; the constructor receives
  a temporary under the existing move rules. About five lines fewer.
- `core/strings/builder.loke:L126-133: shrink:` implement
  `try_copy_string` with `return allocate_string(self.view(), allocator);`.
  Keep the UTF-8 invariant check and its explanation in `view` alone.
  About four lines fewer; this does not remove validation or introduce an
  unsafe conversion.
- `core/random/continuous.loke:L105-123: shrink:` replace the inner
  normal-resampling loop with `if (v <= 0) { continue; }`, then join the
  two acceptance predicates with short-circuit `||` and use one accepted-value
  assignment. Preserve random draw order and the logarithm fast-path guard.
  About seven lines fewer.
- `core/encoding/utf16/utf16.loke:L78-92: shrink:` assign a decoded
  surrogate pair's scalar back to `value`, advance `at`, and share the
  existing rune append/error handling with the BMP path. About five lines
  fewer, preserving malformed-surrogate rejection and allocation errors.
- `core/fs/fs.loke:L75-80,L640-645: shrink:` make both resource drop
  hooks discard `self.close()` instead of repeating the close/state
  transition. About six to nine lines fewer; retain the fallible public
  close operation and best-effort drop behavior.
- `core/io/io.loke:L300-336: shrink:` use explicit breaks for newline
  and EOF, removing `ended`, and use the collected length at EOF instead
  of `seen`. Keep empty lines distinct from EOF, including `keep_ending`.
  About three to four lines fewer and two fewer mutable state variables.

Two documentation cleanups are also actionable, and both are **fixed**:

- `core/unsafe/unsafe.loke:3-7,28-30` describes eight members, omits
  `new`/`try_new`, and restricts `free` to `^mut T`. The compiler contributes
  ten operations, and accepts `[^]T` for `free` too. Replace the fixed count
  with the operation list and document both pointer forms; compare
  [the unsafe boundary](design.md#the-unsafe-package).
- `core/slice/slice.loke:5-6` claims only `clone` and `try_clone` allocate.
  Element copying in `fill`, `min`, or `max` can allocate through copy hooks.
  Describe allocation through element operations, including the one necessary
  result clone after O1.

The file split is generally cohesive. One optional relocation would put
`log_gamma` and its coefficients from `continuous.loke` beside their caller
in `discrete.loke`; this changes no API and saves no lines. `fmt.Format_View`
is referenced by the compiler and must not be treated as an unused alias.
The literal ziggurat tables and separate floating-width foreign wrappers
serve concrete contracts and were not flagged as unnecessary abstraction.

`core/sync/sync.loke:195` busy-spins without yielding while another thread
runs a `Once` action. Blocking address waits are a candidate if slow,
contended initialization is a real workload; no contention benchmark was run,
so this is a measurement candidate rather than a measured optimization win.

Complexity estimate, excluding correctness fixes and documentation edits:
**net: -30 lines possible.**

### Assessment of every source file

“No additional finding” means the named areas were reviewed without a
confirmed actionable issue, not a proof that all inputs are correct.

| Source file | Separate assessment |
| --- | --- |
| [container/bit_set.loke](core/container/bit_set.loke) | O2. Checked sparse/empty enums, multiword boundaries, complements, counts, iteration, and tail masking; additional 130-member assertions passed. |
| [container/enum_array.loke](core/container/enum_array.loke) | O2 and O3's construction-loop cost. Checked empty and sparse enums, construction, indexing, and borrowed/mutable iteration. |
| [container/small_array.loke](core/container/small_array.loke) | G7 and O3. Checked live-prefix invariants, copied/moved insertion, capacity failures, removal, unwind ordering, slices, and iterators. |
| [cstrings/cstrings.loke](core/cstrings/cstrings.loke) | No additional finding. Checked zero value, terminator, interior-zero validation, allocator ownership, copying, and view lifetime; `view` does not rescan the entire buffer. |
| [encoding/utf16/utf16.loke](core/encoding/utf16/utf16.loke) | Shared append cleanup. Checked surrogate arithmetic/rejection, interior-zero policy, exact-range decode, capacity bounds, and allocation errors. |
| [endian/endian.loke](core/endian/endian.loke) | No additional finding. Checked signed shifts under Loke semantics, byte order, 8-128-bit widths, conversions, and formatting. |
| [fmt/fmt.loke](core/fmt/fmt.loke) | Collector construction cleanup. Checked sink forwarding, spacing, allocator transfer, fixed formatting, padding, rune counting, and options. Formatting twice for padding is explicitly documented. |
| [fs/fs.loke](core/fs/fs.loke) | Drop-hook cleanup. Checked handles, idempotent close/errors, access modes, bounded reads, timestamp saturation, directory enumeration, and wide-path conversion. |
| [io/io.loke](core/io/io.loke) | `read_line` state cleanup. Checked partial transfers, EOF, line endings, UTF-8 boundaries, allocation errors, limits, and formatting's error latch for conforming streams. |
| [log/log.loke](core/log/log.loke) | G6. Checked selected/fallback providers, static/runtime filtering, `Off`, variadic forwarding, and formatting allocations. The no-threads comment is stale. |
| [math/complex.loke](core/math/complex.loke) | G4 and G5. Checked both float widths, generic numeric operations, Hamilton multiplication, magnitude, signs, formatting, and inverse/division scaling. |
| [math/math.loke](core/math/math.loke) | No additional finding. Checked classification bit operations, checked/wrapping arithmetic, conversions, CRT bindings, and float-width separation. |
| [mem/mem.loke](core/mem/mem.loke) | No additional finding. Checked compiler-owned declarations against implementation, region/failure-policy documentation, and the runtime's 128-byte minimum buffer layout. |
| [os/os.loke](core/os/os.loke) | No additional finding. Checked argument bounds/lifetimes, owned conversion, and exit semantics. |
| [os/process.loke](core/os/process.loke) | No additional finding. Checked environment validation, missing/empty values, resize retries, current-directory retries, and executable-path buffer growth. |
| [path/path.loke](core/path/path.loke) | G3. Checked bare-drive behavior, roots, ordinary/extended UNC, base/directory, extension/stem, and lexical cleaning. |
| [process/process.loke](core/process/process.loke) | G1. Checked pipe ownership/direction, quoting, environment blocks, inherited handle lists, PATH search, exit/wait/kill, and concurrent capture errors. |
| [random/continuous.loke](core/random/continuous.loke) | Gamma-loop cleanup and optional helper relocation. Checked parameter validation, endpoint handling, and documented draw mappings. |
| [random/discrete.loke](core/random/discrete.loke) | No additional finding. Checked inversion, PTRS, BTPE, saddle-point probability calculations, endpoint probabilities, and conversion guards. |
| [random/pcg.loke](core/random/pcg.loke) | No additional finding. Checked seed/stream initialization, output transformation, and logarithmic advance. |
| [random/random.loke](core/random/random.loke) | No additional finding. Checked range mapping, rejection thresholds, floating draws, endpoints, fill, shuffle, and permutation. |
| [random/sampling.loke](core/random/sampling.loke) | No additional finding. Checked alias-table bounds, worklists, weights, draw mapping, and allocation cleanup. |
| [random/secure.loke](core/random/secure.loke) | No additional finding. Checked native binding, chunk bounds, little-endian decoding, and zero-state retry. |
| [random/xoshiro.loke](core/random/xoshiro.loke) | No additional finding. Checked reference transitions, seed expansion, state validation, and jump constants/iteration. |
| [random/ziggurat.loke](core/random/ziggurat.loke) | No additional finding. Reviewed fast/wedge/tail sampling and all tables; independent table recomputation test passed. |
| [simd/simd.loke](core/simd/simd.loke) | No additional finding. Checked intrinsic forwarding, conversions, reduction identifiers, overflow, masks, and floating/NaN contracts. |
| [slice/slice.loke](core/slice/slice.loke) | O1 and allocation-comment cleanup. Checked bounds, reversal, searches, sorting bridges, NaNs/ties, and fallible clone cleanup. |
| [strconv/strconv.loke](core/strconv/strconv.loke) | G8 revalidated. Checked signs, radix/prefix selection, underscore grammar, minimum signed value, overflow guards, float syntax, and full-input parsing. |
| [strings/builder.loke](core/strings/builder.loke) | Shared validation cleanup. Checked zero-value allocator binding, capacity overflow, rune validity, fallible transaction behavior, finish/reset, and borrowed views. |
| [strings/iterate.loke](core/strings/iterate.loke) | No additional finding. Checked empty/trailing split parts, empty separator, Unicode fields, LF/CRLF, final unterminated lines, and borrowing. |
| [strings/strings.loke](core/strings/strings.loke) | O4. Checked UTF-8 boundary-safe search/slicing, empty needles, whitespace, trimming, transforms, allocator forwarding, and repeat overflow. Naive search is documented; no replacement algorithm justified by a benchmark in this review. |
| [sync/sync.loke](core/sync/sync.loke) | No confirmed correctness finding. Checked atomic/order forwarding and Once completion/poison publication; contended busy-wait remains a measurement candidate. |
| [term/term.loke](core/term/term.loke) | G2. Checked line conversion, surrogate recovery, modifiers, repeated keys, raw-mode failure paths, and handler/restoration ownership. |
| [thread/thread.loke](core/thread/thread.loke) | No additional finding. Checked moved argument storage, spawn-failure cleanup, runtime attach/detach, join/drop, mutex payload, and guard lifetime. |
| [time/calendar.loke](core/time/calendar.loke) | No additional finding. Checked civil/day conversions, year zero and calendar bounds, ISO weeks, clamped month/year arithmetic, offsets, and date-time carry. |
| [time/text.loke](core/time/text.loke) | No additional finding. Checked fixed buffer bounds, precision/truncation, basic/extended consistency, leap-second checks, duration ordering, full fractions, and range failures. |
| [time/time.loke](core/time/time.loke) | No additional finding. Checked signed duration rounding/truncation, float boundaries, minimum-duration subtraction, pre-epoch floor division, offset extremes, and clock/sleep arithmetic. |
| [unsafe/unsafe.loke](core/unsafe/unsafe.loke) | Operation-list and `free` pointer-form documentation cleanup. Checked actual compiler-contributed surface and trust-boundary descriptions. |

### Validation and limits

Twenty-two existing integration programs compiled, ran, and matched their
expected output: `lib_math`, `lib_math_bits`, `integer_wrap`, `lib_numeric`,
`lib_random`, `lib_random_pcg`, `lib_random_distributions`,
`lib_random_ziggurat`, `lib_enum_containers`, `lib_move_only_containers`,
`lib_small_array`, `lib_endian`, `lib_simd`, `lib_slice`, `lib_text`,
`lib_time`, `lib_strings`, `lib_strings_boundaries`, `lib_strconv`,
`fmt_width_precision`, `lib_log`, and `lib_log_off`. Relevant log-level flags
and expected stderr were included.

Additional checks reproduced the numeric bugs at two optimization levels,
counted copy hooks, compared enum-table and receiver LLVM, exercised wide and
empty enums, reproduced the extended-path failure, and injected a stderr
capture allocation failure. Raw-mode interleaving used deterministic mocked
native console calls against generated library LLVM. The locale and threaded
logging cases ran as real Loke programs. These checks do not establish all
Win32 failure paths or exhaustive numeric/distribution correctness.

Repro artifacts are local and ignored under `tests/tmp/numeric_review_20261017/`,
`tests/tmp/review_foundations/`, `tests/tmp/review_platform/`, and
`tests/tmp/review_main/`; the durable findings are in this section, and the
minimal bug reproductions became the regression tests named in the findings
table. No library source was changed by the review itself.

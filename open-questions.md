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

The [anonymous unions and failure policies exploration](#anonymous-unions-and-failure-policies-2026-10-17)
compares keeping these pairs with one fallible operation and reusable adapters,
alongside changes to result construction and error composition.

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

## Anonymous unions and failure policies (2026-10-17)

Design exploration, not an adopted change. All new spellings below are sketches,
not accepted Loke programs. The current rules remain [Typed
fallibility](design.md#typed-fallibility), [Unions](design.md#unions), and
[Allocation failure](design.md#allocation-failure).

**Recommendation, superseded by [A concrete proposal](#a-concrete-proposal-2026-10-18):**
keep `Result`, `Option`, and `Status` as the fallible boundaries; add success
returns, labeled anonymous unions as plain data, and widening between them by
label. The earlier recommendation, to evaluate labeled anonymous unions as a
replacement for the three wrappers, is assessed and declined there. Separately
prototype one fallible container operation plus reusable failure-policy
adapters.

### Separate the decisions

There are four independent questions: what values a result can contain, which
alternatives count as failure, whether a caller must acknowledge a result, and
what happens when the caller chooses not to recover. A shorter type spelling
does not settle the other three.

Today a two-variant union with `@(failure=...)` supplies the failure protocol;
`@(require_results)` supplies acknowledgment. `Result` and `Status` have both,
while `Option` participates in the failure protocol without requiring use of
every returned option. Error payloads are ordinary data: an `io.Error` stored
in a diagnostic record is not itself an active failure.

| Combination | Benefit | Cost or limit |
| --- | --- | --- |
| Keep result types; allow plain success returns | Removes repeated `.ok(value)` with a narrow change | Does not combine error domains or remove procedure pairs |
| Anonymous `(A | B)` inside `Result(T, E)` | Combines distinct error types without a named wrapper for every helper | Adds structural sums, injection, widening, and type-based matching |
| Flat `(T | Error(E))`, with marked alternatives filtered by the operators | One general union spelling for several successes and failures | Flattening loses result boundaries; classification and generic matching become more complex |
| Labeled structural sums such as `(ok: T | err: E)` | Anonymous counterpart to today's named variants; preserves equal payload types | Still needs a failure designation and construction rules |
| Dedicated `T throws E` or error-union syntax | Clearly separates success and failure without a verbose generic spelling | Another spelling for a result boundary; inferred effects would be a much larger change |

The final row need only describe an ordinary returned value. It does not need
exceptions, automatic propagation, or an inferred list of every error a body
can produce. Explicit public signatures remain easier to keep stable.

### Labeled anonymous unions fit the existing variant model

The follow-up proposal is `(amount: int | message: string)`: the enclosing
type is anonymous, while its alternatives retain names. It is the direct
counterpart of a labeled anonymous record:

```text
(amount: int, message: string) // both fields are present
(amount: int | message: string) // exactly one variant is active
```

Construction and inspection can reuse the current union forms:

```text
answer: (amount: int | message: string) = .amount(42);

switch (answer) {
case .amount(n): use_amount(n);
case .message(text): show_message(text);
}
```

These are variants, not simultaneously accessible record fields: `answer.amount`
does not become an unconditional field access. Exhaustiveness, `.as(.amount)`,
and borrowing or consuming a case payload can follow [Unions](design.md#unions).
An alias such as `Answer :: (amount: int | message: string)` would name the
structural type without creating a new nominal identity; `Answer.amount` can
then name its constructor. A nominal `Answer :: union { ... }` remains a
different type, as a struct differs from an anonymous record.

Labels solve the repeated-payload problem: `(read: io.Error | write: io.Error)`
retains the operation that failed, and `(left: int | right: int)` has two
distinct alternatives. Duplicate labels should be rejected. For a first
version, use the ordered sequence of labels and payload types as structural
identity, matching [Anonymous records](design.md#anonymous-records) and the
current union's declaration indices. Making order irrelevant is possible,
but requires canonical tags and reflection rules; it is a separate decision.

Preserve each variant's payload as a whole, including when it is another union:

```text
(ok: (ok: int | err: Parse_Error) | err: io.Error)
```

`.ok(.err(parse_error))` is then an outer success containing an inner failure.
The nesting objection to flat type sets does not apply: the outer `.ok` label
provides the boundary. Likewise a generic `.ok` can carry an error value as
ordinary data if failure is designated by variant rather than payload type.
The required boundary need not be a nominal type named `Result`.

Keep the grammar small initially: at least two alternatives, each with a
label; `|` separates alternatives and `,` separates record fields. A record
payload is nested explicitly, as `(found: (index: int, value: T) | missing:)`.
`missing:` can reuse today's payloadless-variant spelling without making a
bare identifier ambiguous with a type. A single `(name: T)` remains a record.
An empty payload creates no automatic zero value or failure designation.

Names alone do not identify failure. `message` might be a successful message,
and an `err` alternative can be ordinary data. The anonymous form needs a way
to carry explicit failure metadata before `or_return` or `or_else` can use it.
The placement of that metadata is still open; preserve today's two-alternative
protocol first. A suitable fallible structural shape could eventually underlie
`Result` through a generic alias, but Loke has no parameterized aliases today.
Failure metadata must participate in structural type compatibility, so the
same names and payloads cannot silently change which alternative propagates.

Do not implicitly select an arbitrary variant from a raw payload's type.
Adding a second `int` alternative would otherwise break or reinterpret distant
construction sites. Use `.amount(42)` for an ordinary sum. The separate proposal
to allow `return 42;` when the declared result has one designated success
payload still works: its role, not unique payload typing, selects the variant.
Using `Error(E)` payloads as the sole marker would reintroduce ambiguity when a
generic success payload is itself `Error(X)`; explicit variant roles avoid it.

The tradeoff with unlabeled sums is precise. A labeled anonymous error union
removes the need for a dedicated declaration, but propagation still names its
wrapper, for example `or_return .read` or `or_return .write`. Automatic
type-based composition was a benefit of the separate `(A | B)` design.
General subset conversions between labeled unions can wait; if added, they
must match labels and payloads without dropping a possible alternative.

Prefer this labeled form as the first anonymous-union feature. It adds inline
structural types while retaining existing construction, matching, semantic
labels, and nesting. It does not require new type-based matching or resolving
an unordered set of generic alternatives, and it does not itself settle
error acknowledgment or the `try_`/policy-following operation pairs.

### Replacing Result, Option, and Status with structural shapes

The clarified goal is to replace all three named generic types. This is
coherent with labeled anonymous unions: their explicit variants preserve the
boundaries that flat, unlabeled unions lose. No nominal `Result` is required
for nesting. The current three types are already ordinary library unions
recognized by a common protocol, so the proposal makes their underlying
shapes directly expressible.

The following table shows the shapes; the last column lists properties that
must be expressed in the type as well. The labels alone confer none of them.

| Current type | Structural shape | Required properties |
| --- | --- | --- |
| `Result(T, E)` | `(ok: T | err: E)` | `err` is failure; require acknowledgment |
| `Option(T)` | `(none: | some: T)` | `none` is failure and zero; acknowledgment remains optional |
| `Status(E)` | `(ok: | err: E)` | `err` is failure; require acknowledgment; success is payloadless |

One common rule for two alternatives covers all three. `or_else` selects the
other alternative or evaluates its fallback. `or_return` propagates the
designated failure into the enclosing result's designated failure, regardless
of their labels, under today's payload-compatibility and explicit mapping
rules. Absence has no error payload to propagate into a payload-bearing error;
the existing failure operand must supply one. A payloadless success yields
`Unit` to these operators, as today.

Reuse explicit variant metadata rather than deciding failure from names or
from a generic payload's instantiated type. For example, this is a possible
new spelling, not an existing attribute placement:

```text
parse :: proc(text: string_view)
    -> (amount: int | @(failure) message: string) {
    if (bad_input(text)) { return .message("invalid amount"); }
    return 42;
}
```

`@(failure)` on a variant would express the role currently written as
`@(failure=message)` on a named union. Exactly one non-failure alternative
selects the implicit success construction. `.amount(42)` remains available;
an ordinary union with no failure designation still requires a named
constructor. The final spelling is open, including where zero and
require-results metadata attach to an inline type. All these properties must
survive aliases, procedure values, aggregates, and generic instantiation;
they must not be silently changed by assigning between structural types.

The earlier `Error(E)` wrapper is not needed if the variant has an explicit
failure role. In particular, an `ok` variant with payload type `Error(X)` can
then remain success. Requiring acknowledgment is separate from recognizing
failure: an absence may be safely discarded, while a payloadless error may
still need acknowledgment. Do not infer that policy merely from whether the
failure carries data. Explicit discard remains available.

Preserve the useful behavior behind the names:

- An optional shape retains a designated absent zero value and the existing
  [non-null payload representation](design.md#representation), including foreign
  pointer ABI uses. A payloadless alternative alone does not imply either
  an absent default or failure.
- A status-shaped procedure may reach the end of its body and return its
  unique payloadless success. This must not grant implicit success to every
  union containing an empty alternative.
- `errdefer` and a fallible `main` use the declared outer failure role.
  Returning an inner failure as outer success must not trigger either's
  failure behavior.
- A fallible stream can keep an optional shape inside its success variant:
  `(value: (none: | some: T) | err: E)`, with role metadata at each level.
  One `or_return` handles the outer error and leaves end-of-input for the caller.

Removing the nominal generic names also changes generic library code.
`map_error`, `ok_or`, and helpers such as `must` need structural matching or a
compile-time fallibility protocol that exposes the success and failure roles.
Matching only literal labels `ok` and `err` would fail for the `amount` and
`message` example. Transformations must state whether they preserve labels or
produce a documented canonical shape. A no-payload success must also be
representable in generic code without pretending it is the same as a `Unit`
payload. This is real design work, not solved just by changing the parser.

Domain aliases may abbreviate long structural types without retaining the
three generic names. Parameterized compatibility aliases could aid migration
if alias support is deliberately added, but they are not the objective or
a requirement of this replacement. The gain is one general type model with
descriptive inline variants; the cost is more verbose repeated signatures and
the need for generic operations over their roles.

This replaces the representation and naming of fallible results. Mandatory
acknowledgment and the `try_`/policy-following operation pairs remain independent
policy decisions; dropping the three names must not silently settle them.

### Dispatching to procedure groups and visitors (2026-10-18)

Labeled anonymous unions can support compact deconstruction through existing
callable operations. Prefer an explicit dispatch at the call site, preserving
the active variant's name. Type-only overload selection would lose the
distinction between `(left: int | right: int)`.

An interesting spelling to prototype is union argument expansion:

```text
show_amount :: proc(amount: int) { fmt.println(amount); }
show_message :: proc(message: string) { fmt.println(message); }
show :: proc{show_amount, show_message};

answer: (amount: int | message: string) = .amount(42);
show(..answer);
```

The last call is proposed behavior. It would evaluate `answer` once, select
its tag, and make one of these calls through ordinary overload resolution:

```text
switch (answer) {
case .amount(n): show(amount=n);
case .message(s): show(message=s);
}
```

The label becomes a [named argument](design.md#named-arguments). Existing
overload resolution rejects a member with no parameter of that name, so
handlers declared `proc(left: int)` and `proc(right: int)` remain distinct
even with identical payload types. Their procedure names need not match the
variants. The parameter labels are part of the dispatch contract, just as they
are part of an explicitly named call's contract.

This uses a [procedure group](design.md#explicit-procedure-overloading) as
the callee. It avoids needing to pass the group as a value: today's checker
rejects that with `L0396`. The otherwise attractive `visit(answer, show)`
would need special handling of the group operand or a separate change making
groups usable as compile-time arguments. Neither follows automatically from
adding anonymous unions.

The grammar already accepts `..expression` as a call argument, but its
current meaning is [variadic spreading](design.md#variadic-parameters).
Spreading a union into a named argument is a new semantic rule, not supported
today. Its readability needs comparison with an explicit `visit` spelling;
sharing punctuation saves syntax but puts two forms of argument expansion
behind it. Record expansion, if later considered, would supply every field,
while union expansion supplies only the active alternative. Record expansion
is not a prerequisite and is not existing behavior either.

Keep the first design bounded:

- Accept one union expansion as the sole argument initially. Multiple union
  arguments would require checking combinations of alternatives; forwarding
  other arguments also needs precise evaluation and name-collision rules.
- Check every variant at compile time. Each expanded named call must have
  a unique best overload under the existing rules, even if a particular
  runtime execution never reaches that variant. Adding a variant can then
  diagnose a missing handler.
- Resolve each handler from the argument first. Require a common result type,
  or that all handlers return nothing, applying existing divergence rules to
  handlers that never return. Do not select overloads from the destination
  type or automatically invent an anonymous union of their return types.
- Preserve the payload as one argument. A nested union remains nested, and
  a record payload is passed whole rather than recursively expanding its
  fields. Ordinary destructuring inside the handler remains available.
- A place operand lends its selected payload for the call. A temporary or
  `..move(answer)` owns it and can reach a consuming overload, with ordinary
  cleanup if the handler borrows instead. Preserve return-escape checking
  and exactly-once destruction; do not implicitly copy or consume the whole
  union merely to perform the dispatch. Mutable payload access can initially
  stay with `switch` until an explicit expansion mode is designed.
- For a payloadless variant, a group needs a label-bearing argument to
  distinguish it from other empty variants. One candidate is
  `show(none=Unit{})`, handled by `proc(none: Unit)`. This supplies a zero-sized
  argument for dispatch without adding a payload to the union itself.

Do not make ordinary `show(answer)` distribute automatically over the union.
A whole-union overload or an unconstrained generic may already accept it;
adding such a member must not silently replace a dispatch over variants.
An explicit expansion keeps the operation visible and permits the existing
overload rules to be applied independently within each alternative.

A second candidate favors callbacks with arbitrary parameter names:

```text
visit(answer, amount=print_number, message=print_text);
```

The labels select the handlers, and each selected handler receives its payload
positionally. A payloadless variant naturally calls a zero-argument handler.
This could accept ordinary procedures or capture literals without grouping
them, but a universal `visit` with variant-derived named parameters also needs
compiler support or richer metaprogramming. It is not an ordinary generic
library procedure available today. Treat it as an alternative surface form,
not an additional feature required by group expansion.

Callback construction follows normal evaluation order: all arguments and
their captures are evaluated before a call. Two handlers capturing the same
place with `&mut` can therefore conflict even though only one body will run.
A visitor object can keep shared state once. `return` or `or_return` in a
callback exits that callback, and cannot return from the surrounding caller;
likewise a callback cannot break the caller's loop. Keep the ordinary `switch`
for local control flow, mutation, and branch-specific cleanup. Short callback
syntax would be a separate proposal.

For a visitor object, method names provide the same label correspondence:
the `.amount` branch calls `visitor.amount(payload)`, and `.message` calls
`visitor.message(payload)`. A generic visitor gives statically selected calls.
A runtime-selected visitor can use a [dynamic
interface](design.md#borrowed-dynamic-interface-values):

```text
Answer_Visitor :: interface($Self: type) {
    slot amount: proc(self, value: int);
    slot message: proc(self, value: string);
}
```

A procedure taking `dyn Answer_Visitor` can already dispatch a named union
with an explicit switch and call the selected slot. A generalized generated
visitor bridge would remove that switch at each new union shape, but `dyn`
does not generate it by itself. Today's [compile-time
reflection](design.md#compile-time-reflection) does not supply the typed union
variant extraction needed for an arbitrary library implementation.

The runtime tag chooses a variant; the visitor's witness chooses that slot's
implementation. These are separate decisions. A dynamic visitor can be useful
when behavior is supplied at runtime or reused behind a stable interface, at
the cost of an interface declaration, borrowing, and potentially indirect
calls. A `dyn proc` has one signature and cannot stand for an unresolved group
of differently typed handlers. Erasing a visitor does not erase the union's
typed payload arguments: a slot may consume an explicitly transferred payload
even though a consuming receiver is excluded from dyn-compatible interfaces.

Alternatively, forwarding a common interface from every union payload serves
calls such as `draw()` that have the same meaning for all alternatives. It
does not expose the variant labels, and two variants carrying the same concrete
type need adapters to produce different behavior. Such forwarding is another
proposal, not existing union-to-dyn conversion behavior.

Evidence: a local compiler probe using an existing nominal union verified
dispatch through named arguments to group members with identical `int`
parameters, an empty variant dispatched through `Unit`, and a `dyn` visitor
with separate slots over those same alternatives. The switch was written
explicitly in both versions. This verifies the building blocks, not the
proposed anonymous-union syntax or `show(..answer)` expansion.

**Recommendation, superseded by [Part 5](#part-5-per-variant-expansion-and-union-argument-expansion):**
the earlier recommendation was to prototype explicit union argument expansion
for reusable procedure groups and compare it with named callback dispatch.
Part 5 keeps union argument expansion, defined over a per-variant switch case
with `variants_of(T)`, and declines named callback dispatch.

### Anonymous sums have a useful job outside errors

`(int | string)` can describe a value that is either an integer or text,
just as `(int, string)` describes a value containing both. It still needs a
runtime discriminant. This is not a C union, `any_view`, or dynamic typing.
[Odin's unions](https://odin-lang.org/docs/overview/#unions) provide a precedent
for selecting an alternative by payload type and injecting values into it;
that does not establish structural identity or normalization rules for Loke.

A useful candidate rule is an unordered set of exact type identities:
`(A | B)` and `(B | A)` are the same type, nested anonymous sums flatten,
and duplicate alternatives collapse. A singleton reduces to its member.
Aliases do not distinguish alternatives; nominal types do. No implicit `nil`
or zero alternative is added. This deliberately differs from records, where
position identifies fields and `(int, int)` contains two independent values.

Consequently `(string | string)` cannot distinguish a username from a password,
nor `(io.Error | io.Error)` a failed read from a failed log write. Keep named
unions or nominal wrappers wherever that distinction matters. For example,
today's `App_Error` can have both `io: io.Error` and `log_write: io.Error`;
replacing it with a set of payload types would lose information.

For an initial design, inject typed values by exact alternative identity,
and widen `(A | B)` to `(A | B | C)` by preserving the active alternative.
Do not search for arbitrary conversion chains. A literal admitted by several
alternatives, such as `1` for `(i32 | i64)`, needs an explicit choice. Aliases
and implicit numeric conversions must not silently select a different tag.
Adding an alternative must not reinterpret an already typed value.

Matching needs a type-based case with a branch-local binding, borrowing or
consuming as today's [Switch ownership](design.md#switch-ownership) does.
The precise syntax remains open; exhaustive checking is still required. A
type-based match must also distinguish a generic type pattern from a value
pattern without making ordinary `|` expressions ambiguous. Generic inference
cannot guess a unique `$A, $B` decomposition of an unordered set; it needs
constraints or explicit arguments where several decompositions fit.

Semantic widening can require remapping the runtime tag and moving a payload
into larger storage. Do not promise a bitcast or a stable tag number. Layout,
reflection, hashing, formatting, compile-time evaluation, and borrow provenance
must all agree with canonical type identity. No allocation is inherently
needed to represent a closed union, but no performance improvement has been
measured here.

### What an Error wrapper would mean

Use `Error(E)` for the proposed wrapper type and `error(value)` for its value
constructor, following the existing `Box(T)`/`box(value)` distinction. Both
are placeholders; `Failure(E)`/`failure(value)` would avoid competing with
packages' existing `Error` names. The marker must be a specific declared type
or an explicit protocol, never a convention based on an identifier's spelling.

For example, a procedure returning `(int | Error(Parse_Error))` could return
`42` on success or `error(Parse_Error.Bad_Digit)` on failure. A
`(string | Error(string))` remains unambiguous: a bare string is success and
a wrapped string is failure. Inferring failure from a bare payload is unsafe
when success and failure have the same type.

The proposed operators would partition only the union's immediate alternatives:

| Operand type | Success type after handling | Failures handled |
| --- | --- | --- |
| `(int | Error(E))` | `int` | `E` |
| `(int | string | Error(E))` | `(int | string)` | `E` |
| `(int | Error(E1) | Error(E2))` | `int` | `E1` or `E2` |
| `(Unit | Error(E))` | `Unit` | `E` |
| `(Option(int) | Error(E))` | `Option(int)` | `E`, leaving `.none` as data |

`Error(E)` alone contains only failure; it cannot also mean successful
completion with no value. That needs a success alternative, such as `Unit`,
or today's `Status(E)`. Implicit success at the end of a `Unit`-bearing body
would also be a new rule: today it is reserved for a payloadless success.

`or_return` would return the active marked alternative on failure and leave
the success value on success. `or_else` would supply a value of the remaining
success type or leave control flow, as today. Every possible failure must
fit the enclosing result or be explicitly mapped; accepting only some of
them would silently narrow the contract. An operand containing no marked
alternatives should be rejected, not make `or_return` a silent no-op.

Recognizing several marked alternatives does not require making
`Error(A | B)` identical to `(Error(A) | Error(B))`. Distributing through the
wrapper would be another conversion rule, including ownership and generic
inference consequences. Grouping errors under one `Error(A | B)` is simpler
for signatures; multiple wrappers need an explicit normalization decision.

Only the active outer alternative denotes failure. A record containing an
`Error(E)`, a collection of errors, or the success payload of an explicitly
tagged result must remain ordinary data. `errdefer` and a fallible `main` must
use the same classification as the operators. This would extend today's
exactly-two-variants protocol, not merely abbreviate its declaration.

Replacing the existing protocol outright would also break `Option` handling:
`.none` has no `Error` wrapper. Keep its existing absence protocol or design
an explicit replacement; absence and a reported error should remain distinct.
For a fallible stream, `Result(Option(T), E)` currently represents those three
states without treating end-of-input as failure.

### Flattening is the obstacle to replacing Result

Consider `Result(Result(int, Parse_Error), io.Error)`. Its outer operation can
succeed while returning an inner parse failure; one `or_return` removes only
the outer failure boundary. A mechanical alias
`Result(T, E) = (T | Error(E))`, with sums flattened, instead becomes:

```text
int | Error(Parse_Error) | Error(io.Error)
```

Now one operator handles both failures. If both errors have the same type,
duplicate elimination also loses which layer failed. Keeping the nesting in
`(T | Error(E))` requires an opaque group or explicit success wrapper, restoring
the boundary that `Result` already supplies. Parentheses cannot both be ordinary
grouping and secretly preserve a result layer.

There is a second problem: substituting `Error(X)` as a generic success type
would reclassify that success as failure in a flat union. A container, parser,
or task executor must be able to return a failure value as successful data.
Named variants or an explicit `Success(T)` wrapper solve it, but then the
marker design has recreated the roles of `.ok` and `.err`.

Flat marked unions are still reasonable for deliberately flat concrete APIs.
They should earn their additional protocol through uses that the hybrid below
cannot express conveniently, rather than being adopted as a universal alias.

### The strongest combination retains a result boundary

Allow anonymous sums as ordinary payload types, and add success construction
in `return`. An illustrative helper could then be written as follows; `read`
and `parse` stand for APIs returning `Result(string, io.Error)` and
`Result(Config, Parse_Error)` respectively:

```text
Load_Error :: (io.Error | Parse_Error);

load :: proc(path: string_view) -> Result(Config, Load_Error) {
    text := read(path) or_return;
    config := parse(text) or_return;
    return config;
}
```

The outer result still says whether the operation succeeded. Anonymous sums
remove an `App_Error` declaration and per-site wrapping when only the original
error type matters. If the application needs contextual cases such as
`.log_write`, retain a named error union and `or_return .log_write`.

This differs from guessing a variant in an existing named union, rejected in
[The failure operand of `or_return`](comments.md#the-failure-operand-of-or_return).
A structural sum gives each exact type one alternative by definition. A named
union may give the same payload several distinct meanings. Adding structural
injection must not change the latter's construction rules.

Success construction can be a narrow return rule: first honor existing result
construction and whole-result assignability; otherwise permit an expression
assignable to the single success payload of the declared fallible result.
`return n;` in `Result(int, int)` then means success; failure stays
`return .err(n);`. Contextual `.ok(...)` and `.err(...)` remain explicit escape
hatches, including nested results. A bare error payload never chooses `.err`.

Apply the rule by the existing marked-union shape, not by the name `Result`.
Initially keep it at `return` sites; general implicit wrapping at assignments,
arguments, and overload resolution would be a larger change. Returning a whole
compatible result must not wrap it again. Existing copy, move, and return-escape
checks still apply: wrapping must not silently move a place or extend a borrow.
Payloadless `Status` success already needs no final statement.

[Zig's error unions](https://ziglang.org/documentation/0.15.1/#Error-Union-Type)
and [coercions](https://ziglang.org/documentation/0.15.1/#Type-Coercion-Error-Unions)
show the ergonomic value of direct success returns and propagation. Loke can
take that convenience while retaining arbitrary, structured error payloads
and explicit outer result boundaries. It need not adopt inferred error effects.

### Require acknowledgment, not proof of recovery

A visible return type alone does not catch `save(config);` silently dropping
a disk error. Keep a compile-time diagnostic for an ignored failure-bearing
call, with explicit discard available. The caller can inspect it, propagate
it, return/store/pass it as data, choose a fallback, panic, or write `_ = ...`.
Whether recovery is meaningful depends on the caller, not solely on whether
the error type is allocation-related, a parse error, or an I/O error.

This is deliberately weaker than proving every possible failure was handled.
Today's [require-results rule](design.md#require_results) accepts any read of
the binding, even on only one path. Passing it to a logger counts; it does not
prove recovery. A stricter obligation that follows results through every store,
callback, and branch is a separate dataflow or linearity design, not a property
automatically supplied by `Error(E)`. Rust's
[must-use attribute](https://doc.rust-lang.org/reference/attributes/diagnostics.html#the-must_use-attribute)
is another acknowledgment mechanism, not proof of recovery.

For a marker-based alternative, calls returning a union with `Error` arms
should inherit the acknowledgment requirement, including through aliases and
aggregates. Do not require every ordinary union or `Option` result merely
because it has multiple alternatives. Whether an ignored predicate deserves
a diagnostic is independent of whether an operation can fail.

### One operation can expose several caller policies

Changing the result representation alone does not remove the
[`op`/`try_op` pair](#the-optry_op-pair). A concrete alternative is one fallible
public operation and reusable adapters. In this sketch `append` has the
current `try_append` contract, and `must` is a proposed library helper:

```text
values.append(item) or_return;    // propagate
must(values.append(item));        // panic, reporting the returned error
_ = values.append(item);          // deliberately accept a failed insertion
```

The return type stays the same in every context. Do not make a bare statement
panic while a value context returns an error, or silently propagate because
the enclosing procedure happens to be fallible. Those rules make refactoring
change failure policy and confuse calls through procedure values.

A consuming `must` helper for `Result` and `Status` can implement the choice
without a new operator. It should transfer move-only successes, report the
actual error and caller location, and obey panic cleanup rules. Today's
`or_else panic("message")` already expresses an unconditional panic fallback,
but drops a temporary's error before evaluating it, so cannot automatically
include that error. Error-binding fallback syntax is another possible extension,
not a prerequisite for a library helper.

Allocator policy needs separate treatment. `append` today follows its
allocator's `.Panic` or `.Trap` policy; `try_append` reports the failure.
Replacing the former with a generic panic helper would change `.Trap` behavior.
A policy-preserving adapter needs the allocator as well as the error: an
`Allocator_Error` currently retains the requested size, not the allocator's
identity and policy. Extending the error to carry that information is another
design choice, not free syntax sugar.

Nor does one explicit fallible API make a procedure free of panics. Implicit
copies, concatenation, bounds checks, and other language operations retain
their contracts. Generated `clone`/`try_clone` also serve copying and
`Cloneable`; removing names does not remove those jobs. Preserve transaction
and ownership guarantees when changing a pair: a failure leaves the container
unchanged, but an explicitly moved insertion argument remains consumed.

This tradeoff is worthwhile to prototype on `String_Builder`: fewer public
methods and one implementation of each operation, against a policy choice at
every ordinary append. Compare complete real callers before migrating arrays,
maps, allocation built-ins, and lifecycle operations. Keeping convenience forms
is defensible if the caller burden outweighs the API reduction. Automatic
generation could remove duplicated wrappers, but leaves the doubled API.

### What the diverging arrow means

[`-> !`](design.md#diverging-procedures) means the procedure never returns
normally to its caller. `panic`, process exit, and an endless loop are examples.
It does not mean that the procedure returns an error, may panic, or returns
success with no payload. That is why `value or_else panic("missing")` needs
no fallback value: the failure path cannot continue.

Loke currently attaches this fact to the declaration, not to a first-class
procedure-value type. For readability, `@(noreturn)` would fit those semantics
more literally than punctuation. `-> never` is also readable, but should become
a real uninhabited result type only if the language deliberately adds that
model, including procedure types and conversions. Neither is necessary for
anonymous unions or error handling; keep any spelling decision separate.

### What would establish that the change is an improvement

Prototype success returns independently, then anonymous sums used for error
payloads, before combining them with a library API migration. Acceptance cases
must include equal success/error payload types, overlapping numeric literals,
duplicate aliases, generic alternatives becoming identical, subset propagation,
nested results, error values returned as success, fallible streams, move-only
successes and errors, borrowed errors, and exactly-once cleanup on fallback.
Also check `errdefer`, fallible `main`, explicit discard, and allocator `.Trap`.

Use the same parser helper, file-loading helper, and builder-heavy caller for
each design. Count declarations and call-site ceremony, inspect diagnostics,
and verify that error context survives. This exploration establishes semantic
tradeoffs, not compiler acceptance of the proposed syntax or measured speed.
Adoption requires coordinated specification, grammar, compiler, library, tests,
tooling, rationale, and upgrade notes.

### A concrete proposal (2026-10-18)

Three changes, each specified and built on its own and useful without the
others, cover what the exploration above found valuable for results. Two more
are separate features: one shortens signatures, and one replaces the explored
dispatch forms. Together they keep `Result`, `Option`, and `Status` as the
only fallible boundaries and make anonymous unions plain data.

1. **Success returns.** `return value;` builds the success variant.
2. **Labeled anonymous unions.** `(io: io.Error | parse: Parse_Error)` is an
   ordinary union with no declaration and no attributes.
3. **Widening by label.** An anonymous union converts to a larger one that
   contains each of its alternatives, which lets a bare `or_return` propagate
   a helper's smaller error set.
4. **Later, separately: parametric aliases**, the only change here that
   shortens a common signature.
5. **Independently: per-variant expansion.** A switch case written
   `case $variant(payload):` is checked once per remaining variant, and
   `variants_of(T)` reflects a union's variants. The explored
   `show(..answer)` becomes sugar defined by that expansion.

None of them changes the meaning of a program that compiles today.

#### Assessment of the exploration

| Part | Verdict |
| --- | --- |
| [Separate the decisions](#separate-the-decisions) | Keep. The parts below each settle one of the four questions and leave the others alone. |
| [Labeled anonymous unions](#labeled-anonymous-unions-fit-the-existing-variant-model) | Adopt as data: part 2. |
| [Replacing the three wrappers](#replacing-result-option-and-status-with-structural-shapes) | Decline; see below. |
| [Dispatch to groups and visitors](#dispatching-to-procedure-groups-and-visitors-2026-10-18) | Keep `show(..answer)`, defined over a per-variant expansion: part 5. Decline `visit(...)`; keep the dyn visitor as an idiom. |
| [Unordered type-based sums](#anonymous-sums-have-a-useful-job-outside-errors) | Defer. Labels plus widening give the composition without set normalization, type-based matching, or literal ambiguity, and they keep `read` and `log_write` apart. |
| [`Error(E)` markers and flat unions](#what-an-error-wrapper-would-mean) | Decline, for the reasons the exploration itself gives under [Flattening is the obstacle](#flattening-is-the-obstacle-to-replacing-result). |
| [A retained result boundary](#the-strongest-combination-retains-a-result-boundary) | Adopt, with labeled alternatives in place of unlabeled ones: parts 1 to 3. |
| [Acknowledgment](#require-acknowledgment-not-proof-of-recovery) | Keep today's rule unchanged. An anonymous union is data and requires nothing. |
| [One operation, several policies](#one-operation-can-expose-several-caller-policies) | Independent. Prototype on `String_Builder` as recommended. |
| [The diverging arrow](#what-the-diverging-arrow-means) | Independent; no change. |

**Why not replace the wrappers.** The labels would be per API, so every
generic helper (`map_error`, `ok_or`, a `must`, any code generic over a result)
would need a role protocol to find the success and the failure, which nominal
generics give today for nothing. The failure, zero, and acknowledgment
properties would become part of a structural type's identity, so
`(ok: T | err: E)` and its fallible twin would be different types that differ
only by an attribute: a concept Loke has nowhere else. Callers would lose the
uniform `.ok`/`.err` they match on. And the signatures would grow:
`Result(File, io.Error)` would become `(ok: File | @(failure) err: io.Error)`.
A named union with `@(failure=)` already serves an API that wants its own
labels.

#### Part 1: success returns

**Status: adopted** as [Success returns](design.md#success-returns). The rule
differs from the text below in three places, each recorded in
[comments.md](comments.md#success-returns):

- `nil` is never wrapped, although it is an unfixed constant, so `return nil;`
  in an `Option(^T)` is an error instead of `.some(nil)`.
- A wrapped return takes its value as the plain statement does: an owned local
  transfers, where a written `.ok(x)` copies the place.
- A body whose written result names a generic argument and whose failure
  carries a payload, such as `Result(T, E)`, never wraps, which is how a body
  returning an `E` stays rejected in every instance. `Option(T)` keeps the
  shorthand in generic bodies.

Migrating `core` returns remains a separate commit.

In a procedure whose result is a [fallible union](design.md#typed-fallibility):

- `return expression;` keeps its current meaning when `expression` is a
  contextual construction of the result (`.ok(x)`, `.err(e)`, `.some(x)`,
  `.none`) or has a type assignable to the result.
- Otherwise, when the success variant carries a payload, `expression` is
  checked against that payload and the return builds the success variant,
  exactly as `return .ok(expression);` or `return .some(expression);` would,
  with the same copy, move, and return-escape rules.
- An implicit selector still resolves against the result's variants, so
  `return .Bad_Digit;` in `Result(int, Parse_Error)` is an error that suggests
  `.err(.Bad_Digit)`. Nothing selects the failure variant implicitly, and an
  error value never becomes a failure because of its type.
- When the success carries nothing, as `Status`'s does, `return;` returns it,
  as reaching the end of the body already does. `Result(Unit, E)` is not
  covered, for the reason [`Status(E)`](comments.md#statuse) gives.

The checker decides by the expression's form, before giving it an expected
type: a variant construction or implicit selector targets the result; an
expression with its own type targets the result when assignable to it and the
payload otherwise; a composite literal or unfixed constant targets the payload,
since no union is built from one. Lower the wrapped return to the variant
construction it stands for in
[check.odin](src/check.odin) `check_return`, so control flow, borrow checking,
compile-time evaluation, and emission see only code they handle today.

`core`, `base`, `examples`, and `bench` have 117 `return .ok(` and 57
`return .some(` sites. A typical one, from [text.loke](core/time/text.loke):

```text
return .ok(Date.from_components(year, month, day) or_return .Invalid_Value);
return Date.from_components(year, month, day) or_return .Invalid_Value;   // proposed
```

#### Part 2: labeled anonymous unions

**Status: adopted** as [Anonymous unions](design.md#anonymous-unions), with
three differences from the text below:

- A `$` binding inside one is rejected, as it is inside an anonymous record,
  rather than binding by label and order. Binding inside either is one
  later change.
- Methods follow anonymous records rather than being forbidden: neither is
  rejected by `impl` on an alias today, and the spec says nothing about either.
  Whether an alias of a structural type may take methods, which would then
  apply to every spelling of that type in the package, is open for both.
- `distinct` over one is rejected, as over an anonymous record, since a
  nominal union is declared.

In place of the reflection bullet, a type name prints the alternatives,
`(found: int | missing:)`, as an anonymous record's does.

`(label: Type | label: Type | label:)` is the anonymous counterpart of a named
union, as `(label: Type, label: Type)` is of a struct:

- It has at least two alternatives, each `label: Type` or payloadless `label:`,
  with distinct labels. The colon is required, so `(a | b)` remains an
  expression and `(x: T)` remains a one-field record. A name list such as
  `(a, b: int | c:)` is not accepted.
- Its identity is structural: the ordered sequence of labels and payload types,
  as for [anonymous records](design.md#anonymous-records). The order is the
  tag order. An alias names the shape and creates no new identity.
- Every rule of [Unions](design.md#unions) applies unchanged: contextual
  `.label(payload)` construction, an alias's `Alias.label` constructor, switch
  ownership and exhaustiveness, `.as(.label)`, copy, move, drop, equality,
  formatting, and the [representation](design.md#representation), so
  `(node: ^Node | end:)` is one address. Reflection reports it as a union with
  the empty name.
- It carries no attributes. It has no zero value, is not a fallible expression,
  and does not require its results. `or_return` and `or_else` reject it with a
  diagnostic naming `Result`, `Option`, or a named union with `@(failure=)`.
  It takes no methods and cannot be recursive, since it has no name.
- A `$` binding inside it, as in `(some: $T | none:)`, binds by label and order.

The [failure operand](design.md#the-failure-operand) already resolves `.label`
against `F`, the enclosing result's failure payload, so it needs no change to
wrap into an anonymous `F`:

```text
read_config :: proc(path: string_view) -> Result(Config, (io: io.Error | parse: Parse_Error)) {
    text := fs.read_text(path) or_return .io;
    return parse(text) or_return .parse;
}
```

Implementation mirrors anonymous records: a `Type_Anon_Union` node from
`parse_anon_record_type` in [parser.odin](src/parser.odin) when `|` follows the
first labeled alternative, interning beside `anon_record_type` in
[semantic.odin](src/semantic.odin) with the union kind, and the existing union
paths from there.

#### Part 3: widening by label

Add to [Implicit type conversions](design.md#implicit-type-conversions): an
anonymous union value converts to an anonymous union type that has, for each
of its alternatives, an alternative with the same label and the same payload
type, or the same payloadless label. Order may differ; the conversion remaps
the tag and moves the payload into the larger storage. It is a value
conversion, as dropping record labels is: it does not reach through
`[dynamic]`, `Option`, or a procedure type, a place operand copies and must be
copyable, and a temporary transfers. Named unions neither widen nor are
widened. Narrowing is a `switch`.

A bare `or_return` requires only that the failure payload be assignable, so
widening makes a smaller error set propagate with no operand, and `map_error`
and ordinary returns accept it too:

```text
start :: proc() -> Result(App, (io: io.Error | parse: Parse_Error | net: Net_Error)) {
    config := read_config("app.cfg") or_return;          // widened by label
    socket := net.connect(config.host) or_return .net;
    return App{config, socket};
}
```

This is not the variant inference that
[The failure operand of `or_return`](comments.md#the-failure-operand-of-or_return)
rejected. The label and the payload type are written on both sides, so adding
an alternative to the destination changes no existing conversion, and adding
one to the source, renaming a label, or changing a payload type is a
diagnostic, naming the missing alternative, at each site whose destination
lacks it.

The caller chooses between flattening and context. Repeating the callee's
labels in its own set flattens them, as above. A wrapping label keeps the
layer, `(config: (io: io.Error | parse: Parse_Error) | net: Net_Error)` with
`or_return .config`, and two labels keep equal payload types apart,
`(read: io.Error | log_write: io.Error)`.

#### Part 5: per-variant expansion and union argument expansion

[Dispatching to procedure groups and visitors](#dispatching-to-procedure-groups-and-visitors-2026-10-18)
serves two needs that recur in general-purpose programs: interpreters and
compilers walking a tree, event loops, protocol and actor message handlers,
and state machines.

- **One operation for every alternative**, such as `area()`, `span()`, or
  reporting an error, where every payload supports the same call.
- **A different handler for each label**, where the handlers are procedures
  in their own right and the same handler set is dispatched from several
  places. Labels matter here: `(left: int | right: int)` has two handlers
  although its payloads have one type.

The existing standard library and tests are not a sample of either. They hold
almost no data unions, so their switches say nothing about how often these
needs arise. Judge both on design merits and on representative programs
written for the purpose; see
[Implementation order and acceptance](#implementation-order-and-acceptance).

Part 5a serves the first need and is the foundation. Part 5b serves the second
and is defined as sugar over 5a, so it adds a spelling, not a mechanism.

##### Part 5a: per-variant expansion

Zig serves the first need with
[`inline else`](https://ziglang.org/documentation/0.15.1/#Inline-Switch-Prongs),
a switch prong expanded once per remaining tag. Loke already has the
machinery in [static `foreach` expansion](design.md#static-foreach-expansion),
so the proposal stays inside `switch`:

```text
area :: proc(shape: ^Shape) -> f64 {
    switch (shape^) {
    case $variant(s): return s.area();     // checked once per variant
    }
}

report :: proc(error: (io: io.Error | parse: Parse_Error | net: Net_Error)) {
    switch (error) {
    case $variant(e): fmt.println("failed:", variant.name, e);
    }
}

switch (event) {
case .quit: return;
case $variant(payload): handle(payload);   // every other variant, by payload type
}
```

The rules:

- Only in a switch over a union, named or anonymous. The case covers every
  variant no earlier case names, so it is the last case, there is at most one,
  and `default:` cannot follow it.
- Its body is parsed once and checked once per covered variant after
  substitution, as a static `foreach` body is. A diagnostic names the variant.
  Adding a variant checks the body against the new payload, which keeps the
  protection that `default:` gives up: a new payload without `area()` is a
  compile error, not a silently absorbed case.
- `variant` is a compile-time `meta.Variant` descriptor with `name`, `type`,
  and `index`, under the rules of [compile-time reflection](design.md#compile-time-reflection):
  immutable and never materialized at runtime. `type` is the payload type, or
  `Unit` for a payloadless variant.
- `payload` follows [Switch ownership](design.md#switch-ownership): it borrows
  from a place, owns from a temporary, and `&mut payload` is a writable place.
  A payloadless variant binds `Unit{}`, as `.as(.name)` yields `Unit`. Field
  bindings are not accepted, since the payloads differ in shape.
- It is an ordinary case for control flow, `defer`, `errdefer`, and
  `or_return`.
- The body is instantiated once per variant; the backend may merge identical
  copies.

`variants_of(T)` returns the union's `meta.Variant` descriptors in declaration
order, beside `fields_of(T)` and `enum_values_of(T)`. Runtime reflection
already reports `Member_Kind.Union_Variant`; this adds the compile-time
counterpart. With it, generic code can iterate a union's shape with
`foreach ($v in variants_of(T))`, and a library bridge from any union to a
visitor becomes ordinary generic code: an expanded case calling one generic
method, `visitor.visit(variant, payload)`, which overloads on the payload type
or tests `variant.name` with `when`. Visitor slots named after the labels stay
out of reach, because static expansion does not synthesize identifiers.
Constructing a variant from a descriptor is left open.

Part 5 works with parts 2 and 3 but needs neither. With them, one `report`
procedure is generic over any anonymous error set, however it was widened:

```text
report :: proc(error: $E) {   // a constraint meaning "E is a union" is open
    switch (error) {
    case $variant(e): fmt.println("failed:", variant.name, e);
    }
}
```

##### Part 5b: union argument expansion

The exploration's `show(..answer)` is defined as a 5a expansion whose case
calls the callee once, with the variant's label as the argument name:

```text
show(..answer);

// means
switch (answer) {
case $variant(payload): show(<the label of variant> = payload);
}
```

Ordinary overload resolution then picks the member for each label. A label
becomes an argument name only inside this expansion; there is no user-visible
form that names an argument from a descriptor. Most of the rules the
exploration listed follow from the definition instead of being added: each
variant is checked at compile time, and a variant with no handler is a
diagnostic naming it; the operand follows switch ownership, so a place lends
its payload and a temporary or `move(answer)` gives it up; a payloadless
variant passes `Unit{}` to a `proc(none: Unit)` member; and one expanded union
is the sole argument initially. The one rule 5a does not supply is for the
call's value, since a switch is a statement: every expansion must have the
same result type, or none has a result, with the existing divergence rules.

On the merits:

- **Labels become handler parameter names.** This is the coupling a visitor's
  method names have with the cases it visits, and here it is checked: renaming
  a label or a parameter is a compile error at the expansion, never a silent
  change. One hazard remains: a new label that matches a parameter of another
  member, with a payload type that member accepts, dispatches to it. The
  explicit `..` keeps such groups deliberate.
- **Handlers are procedures.** `return` and `or_return` in one leave the
  handler, not the caller. Use a switch or 5a where the caller's control flow
  is needed. The call's own result still propagates: `show(..answer) or_return`.
- **The spelling.** `..` already spreads a sequence into variadic arguments.
  A union is never a sequence, so the operand's type decides without
  ambiguity, and spreading a value's active alternative into the arguments is
  close to spreading its elements. A method spelling such as
  `answer.dispatch(show)` would need procedure groups as values, which the
  checker rejects today with `L0396`.
- **The benefit.** A handler set is declared once and dispatched in one
  expression from every site, exhaustively and by label.

Build 5a first. Prototype 5b on it and compare both with explicit switches in
the representative programs below.

`visit(answer, amount=..., message=...)` stays declined, on its own costs:
deriving named parameters from the variants needs compiler support beyond 5b;
every callback and its captures are evaluated though one body runs, so two
`&mut` captures of one place conflict; and a capture literal per variant is
longer than a case. A dyn visitor remains an idiom over an explicit switch or a
5a expansion, and `variants_of(T)` makes a generic bridge to one possible.

#### What gets shorter

Anonymous unions make a signature longer and remove a declaration; they do not
shorten a signature. Today's `Result(Config, Config_Error)` with
`Config_Error :: union { io: io.Error, parse: Parse_Error }` becomes the
signature of `read_config` above. The program gets shorter where the helpers
are: no wrapper declaration per helper, no `or_return .name` at each level
after the first wrap, and a precise error set per helper instead of one
application-wide union that every helper over-reports. That is the shape of
application code that combines error domains, not of the standard library: a
`core` package reports one error type, so parts 2 and 3 need no `core`
migration. Part 1 shortens bodies everywhere, `core` included.

Signatures are shortened by aliases, which suit structural types because they
add no identity:

- A plain alias works today: a local probe accepted `Io_Status :: Status(Io_Error);`
  and a procedure returning `Io_Status` that reached the end of its body.
- `Config_Error :: (io: io.Error | parse: Parse_Error);` names the shape, and the
  named shape still widens and still matches another package's identical shape.
  It also avoids the double parentheses of
  `Status((io: io.Error | parse: Parse_Error))`.
- `Result(T, io.Error)` needs a parametric alias, which is part 4, so that `io`
  can name `Result($T, Error)` once, as Rust's `io::Result` does. That is a
  separate generics feature with its own design; it does not merge `Status`
  into `Result`, whose end-of-body rule differs.

Dedicated syntax such as `T ! E` or `?T` is not proposed. It saves a few
characters per signature, adds a second spelling for each wrapper, and `!`
already means divergence in `-> !`.

#### How the parts combine

- Success returns and the failure operand together leave a body with no
  `.ok(...)`: failure is always written, and success never is.
- A labeled anonymous error set uses the existing failure operand unchanged.
- Widening uses the existing assignability rule of a bare `or_return`, so no
  propagation rule changes.
- Nested results keep their boundaries, because the fallible layer is still a
  `Result`: `Result(Result(int, Parse_Error), io.Error)` means what it does
  today.
- `errdefer`, a fallible `main`, `@(require_results)`, and `map_error` read the
  same `Result` and `Status` as today.

#### Implementation order and acceptance

Build and release each part separately, specification, grammar, compiler,
tests, and `CHANGELOG.md` together. Migrating `core` returns to part 1 is a
separate commit.

The code in this repository is mostly the standard library and its tests, so
it cannot show how often a general-purpose program needs these forms. Evaluate
each part on representative programs written for the purpose, each in the
current language and with the proposal:

- an application that loads, parses, and serves, with helpers over several
  error domains, for parts 1 to 3;
- an expression interpreter with several tree walks (evaluation, printing, type
  checking) over one node union, for part 5;
- an event loop or message handler with one handler set dispatched from
  several sites, for part 5b.

Count declarations, propagation and dispatch sites, and lines; check that
error context survives; and compare the diagnostics after adding, renaming,
and removing a variant or a label. Document an idiom in a tutorial only after
it has been compared this way.

Acceptance cases:

- **Part 1.** In `Result(int, int)`, `return n;` succeeds and `return .err(n);`
  fails. In `Option(Option(int))`, an `Option(int)` value wraps once. A whole
  compatible result is not wrapped again. `return .Bad_Digit;` is diagnosed. A
  body generic over `Result($T, $E)` that returns an `E` is rejected, and is
  not wrapped as success in an instance where `E` happens to be assignable to
  `T`. Also: move-only and borrowed success payloads, `errdefer` not running on
  a wrapped return, a fallible `main`, `return;` in `Status`, and `return;`
  rejected in `Result(Unit, E)`.
- **Part 2.** `(left: int | right: int)` has two alternatives. Duplicate labels,
  one alternative, and `(a | b)` as a type are rejected. A different order is a
  different type. `(node: ^Node | end:)` has the pointer's size. A file-scope
  variable of one is rejected, since it has no zero. `or_return` on one is
  rejected. A failure operand constructs into an anonymous `F`. Formatting,
  reflection, hover, and `-fmt` agree.
- **Part 3.** Widening succeeds across orders. A missing label, the same label
  with another payload type, a move-only place, and conversion through
  `[dynamic]` are rejected. An overload taking the exact type wins over one that
  needs widening. Widening is the same in compile-time evaluation, and a
  borrowed payload keeps its provenance.
- **Part 5.** An expanded case after explicit cases covers only the rest. A
  case after it, a second one, and one over an enum or `any_view` subject are
  rejected. Adding a variant whose payload lacks what the body uses is
  diagnosed, naming the variant. A payloadless variant binds `Unit`. `return`
  and `or_return` leave the procedure from an expansion. Over a temporary,
  each expansion owns and drops its payload once; `&mut payload` requires a
  writable subject. `variants_of(T)` keeps declaration order, rejects a
  non-union, and its descriptors cannot reach runtime storage.
- **Part 5b.** `(left: int | right: int)` reaches `proc(left: int)` and
  `proc(right: int)` separately. A missing handler, an ambiguous one, and
  expansions with different result types are diagnosed, naming the variant. A
  payloadless variant reaches `proc(name: Unit)`. A place operand is lent, and a
  temporary or `move` operand reaches a consuming member. A whole-union member
  of the group is not chosen by `..`, and `show(answer)` without `..` never
  distributes.

## Success returns and anonymous unions commit review (2026-10-18)

Reviewed `5cfc8b0` (success returns) and `f5ee2ff` (anonymous unions) for
correctness and structure. Two confirmed findings, both **resolved** since:

- P2, `5cfc8b0`: the walk that decides whether a result names a generic
  argument skipped expressions, so `Result([N + 1]int, [2]int)` wrapped
  `return error;` as success when `N` was 1 and rejected it otherwise.
  **Fixed**: the walk is now `type_syntax_any_name` in [ast.odin](src/ast.odin),
  shared with the erasure check, and runs only inside an instance, so its
  conservative answer for inline records cannot affect ordinary code.
  `tests/err/success_returns` covers the case.
- P3, `f5ee2ff`: `parse_anon_union_type` accepted a trailing `|`, which the
  grammar did not allow. **Resolved by accepting it**: a trailing `|` is now in
  [the grammar](grammar.md#types) and [the spec](design.md#anonymous-unions),
  like a trailing comma in a record, so a union written one alternative per line
  ends each line alike. An empty alternative between two `|` is still an
  error; `tests/syntax_err/anonymous-union-alternatives` covers both.

The phase boundaries are sound: lowering success returns to ordinary union
constructions lets ownership, provenance, evaluation, and emission share their
existing handling. Interning anonymous unions as the existing union kind keeps
the new feature's implementation concentrated in parsing, type resolution, and
identity. The collision buckets compare complete shapes, and the added
cross-package test covers payload types that share a display name.

Two optional P3 simplifications from the `ponytail-review` pass, both
**applied** since:

- [union.odin](src/union.odin):L79: shrink: remove the duplicated payload-validation branch in `resolve_anon_union`; share a `(Type_Id, bool)` payload resolver with `resolve_union_variants`, keeping duplicate-label collection and named-union attributes with their callers. The repeated checks for payloadless type names, type resolution, and invalid payload kinds can lose about 20 net lines.
- [check.odin](src/check.odin):L4301: shrink: replace the five manual selector-field assignments with `check_union_variant_selector(k, selector, result, true)` before `finish_union_construct`. That helper already sets these fields for a payload variant; the wrapping branch guarantees a nonempty payload. Four net lines fewer, with one owner for the selector annotation contract.

**net: -24 lines possible.** This estimate excludes the correctness fixes.
The partly duplicated generic-name traversal also caused the first gap; sharing
its expression coverage is part of that fix, rather than a separate cosmetic
finding. Both were applied as described: `resolve_variant_payload` serves both
union forms with the named union's wording, and the success-return wrapper
calls `check_union_variant_selector`.

Validation used freshly built `review-lokec.exe` and `review-loke-lsp.exe`:
134 compiler unit tests and 43 LSP unit tests passed, as did the 10 integration
suites for executable programs, packages, diagnostics, package diagnostics,
syntax recovery, generated IR, layout, and three LSP behavior checks. The
existing success-return and anonymous-union run programs also passed directly.
Focused probes confirmed both gaps and exercised nested union payloads,
generic anonymous-union construction, dynamic-array transfers, and borrowed
view returns. A broader integration attempt crashed in Odin's test runner at
`tests.a_debugger_shows_values` with exception `0xC000001D`; it is not a passing
full gate. Its leftover compiler process was stopped. Reproduction artifacts
are ignored under `tests/tmp/review-*.loke`. Heading citations and local links
were checked after recording these findings.

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
the regression tests named in each row. The
[follow-up commit review](#core-fix-commit-review-2026-10-17) reopened two
cases and found a performance regression, all three fixed since.

| ID | Location | Finding |
| --- | --- | --- |
| G1 | `core/process/process.loke:203-206` | **Fixed:** a stderr capture failure could hang `output`: the worker recorded failure, but the parent waited for stdout EOF before inspecting it. The worker now ends the child itself. Regression in `tests/obj/process_output_fault.loke`. |
| G2 | `core/term/term.loke:363-371` | **Fixed:** raw-mode acquisition could save a stale raw snapshot, leaving the console raw after both owners close. The claim is now taken before the snapshot. |
| G3 | `core/path/path.loke:174-178` | **Fixed:** joining an extended path could duplicate a separator, turning a valid path into `Invalid_Path`. Repeated boundary runs were fixed after the [fix commit review](#core-fix-commit-review-2026-10-17). Regression in `tests/run/lib_path`. |
| G4 | `core/math/complex.loke:308-314,331-337` | **Fixed:** quaternion inverse overflowed a shared factor, destroying finite components and turning zero components into NaNs. Regression in `tests/run/lib_numeric`. |
| G5 | `core/math/complex.loke:225-237,266-278` | **Fixed:** complex division lost subnormal contributions, so a quotient of `0.4-0.2i` became `0.5+0i`. Regression in `tests/run/lib_numeric`. |
| G6 | `core/log/log.loke:70-76` | **Fixed:** standard log records interleaved across threads; five writes per record did not preserve its line. A lock now spans the record, and logging from a spawned thread no longer warns L0707. Regression in `tests/run/lib_log_threads`. |
| G7 (P3) | `core/container/small_array.loke:199-219,243-244` | **Fixed:** the normative section denied consuming try-insertion, although the API and the release notes deliberately supply it. Regression in `tests/run/lib_move_only_containers`. |
| G8 (previously noted) | `core/strconv/strconv.loke:125` | **Fixed:** floating parsing followed the mutable C locale, so a decimal comma locale made `1.5` succeed as `1.0`; `fmt` printed `1.,5` under the same locale. The runtime now uses a fixed "C" numeric locale, and panics if it cannot create one (after the [fix commit review](#core-fix-commit-review-2026-10-17)). Regressions in `tests/run/lib_numeric_locale` and `tests/obj/numeric_locale_fault.c`. |

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
refactorings with concrete replacements; no speed claim is implied. All six
are **done**, with no output change in the affected tests:

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
**net: -30 lines possible.** The six refactorings above came to -28.

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

## Core fix commit review (2026-10-17)

Reviewed `59bb7cf` (numerics, path join, raw mode, performance), `40bdfaf`
(output cancellation, log lines, C locale), and `32fdedd` (simplifications).
Three confirmed P2 findings, all **fixed** since:

- `59bb7cf`, `core/path/path.loke:181-189`: the boundary fix still preserved
  repeated separators supplied entirely by either side, in three minimal
  cases now in `tests/run/lib_path`. Existing regressions cover one leading
  separator, and repeated leading separators only when the prefix already
  has a trailing separator.
- `59bb7cf`, `core/path/path.loke:181`: calling `builder.view()` to inspect
  its last byte validates the entire accumulated UTF-8 prefix at every
  boundary. Extended-path joining becomes quadratic instead of linear in
  total input bytes. At `-opt=speed`, one extended prefix followed by
  5,000/10,000/20,000 four-byte components took about 30.7/125.9/540.3 ms;
  the previous boundary logic took about 0.154/0.313/0.796 ms and produced
  identical output. The extended prefix makes `clean` return verbatim, so
  these timings isolate the new prefix scanning. **Fixed** with the first
  finding: `join` holds each part's trailing separator run instead of reading
  the builder back, and took about 0.24/0.55/0.93 ms afterwards.
- `40bdfaf`, `runtime/format.c:34-36`: failed creation of the fixed numeric
  locale falls back to the mutable process locale. A fault-injected C host
  reproduced parse rejection and decimal-comma/malformed formatting. The
  runtime now panics instead; `tests/obj/numeric_locale_fault.c` is that host
  as a regression.

No findings in `32fdedd`. All six simplifications preserve the examined
ownership, allocator, error, Unicode, and random-draw behavior. A differential
`io.read_line` test against its previous loop passed 31,248 cases, comparing
results, consumed bytes, and read-call counts. Cases covered byte strings of
length 0-5 containing ASCII, CR, LF, NUL, and invalid UTF-8, both ending
options, EOF/other read errors, and default/starved allocators.

The numeric fixes address the original subnormal complex and quaternion
failures at both widths. Container constant tables, pointer receivers, and
slice winner indices are consistent with the intended optimizations.
Process-handle lifetime through reader joining, stderr cancellation, complete
standard-record locking, foreign numeric signatures, and atomic locale cache
publication/disposal showed no additional issue in this review. As a small
test improvement, the quaternion inverse regression should explicitly check
that its expected finite component is finite: the negative upper-bound
comparison also accepted negative infinity. It now checks `is_finite` too.

Validation: the quick gate passed 134 compiler and 43 LSP unit tests. The
integration run completed its other 54 tests (including the intentional
quick-gate mutation-fuzzer skip), but `a_debugger_shows_values` failed with
`Signal caught: Unknown`. An isolated rerun reproduced that failure in about
14 ms before building the debugger fixture. That test is unchanged by these
commits; the only debugger command found was the WindowsApps `cdbX64` alias,
and the SDK debugger was absent. This points to local tool discovery, but
the quick gate did not pass in full. The targeted `lib_numeric` and `lib_path`
programs separately compiled, ran, and matched expected output.

Artifacts remain ignored under `tests/tmp/review_commits_numeric/`,
`tests/tmp/review_commits_platform/`, and `tests/tmp/review_commits_cleanup/`.
Only review records were changed; no implementation fix was applied.

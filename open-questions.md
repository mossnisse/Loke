# Open questions

Decisions that are deliberately not yet made are recorded here rather than left implicit in normative prose. [`design.md`](design.md) defines the rules implementations must follow for the current language version; these questions concern possible later changes.

Design rationale and differences from Odin are recorded in [comments.md](comments.md).

## Compiler review (2026-10-14)

The [stage-by-stage compiler review](compiler-review-2026-10-14.md) records
correctness, robustness, optimization, simplification, structure, and verification
results. Confirmed language divergences are tracked separately in
[Known gaps](known-gaps.md#gaps), with minimal reproductions. No implementation
changes are included in the review. Its gaps, engineering findings and
simplifications have since been fixed, and G14 was decided for the body
reading.

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
  "Compile-time procedure evaluation" keeps out of constants for good, and it
  reads the decimal point of the C locale, which a program that calls
  `setlocale` through a foreign binding can change. A correctly rounded parser
  in Loke (Eisel-Lemire with a big-decimal fallback) would fix both. Is either
  worth that much code?

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

## `core:time` proposal (2026-10-15)

A plan for a `core:time` package, not yet part of
[standard-library.md](standard-library.md). It covers clocks, durations,
instants, the proleptic Gregorian calendar, fixed UTC offsets, ISO 8601 text,
and, in a second phase, the system's local time zone. Named time zones and
their history are left out, for the reasons in
[Named time zones](#named-time-zones); the API leaves room to add them later
without changing anything here.

ISO 8601 is the only text form. Every type prints in the ISO 8601 extended
format through `fmt`, in the RFC 3339 profile where one applies, and parses it
back. There is no locale, no month or weekday name in text, and no pattern
language.

### Types

| Type | Holds | Zero value |
| --- | --- | --- |
| `Duration` | Signed nanoseconds, a `distinct i64`: about ±292 years | No time |
| `Tick` | A monotonic clock reading | A reading at an unspecified moment |
| `Time` | An instant: nanoseconds since 1970-01-01T00:00:00Z in an `i64`, from 1677-09-21 to 2262-04-11 | The Unix epoch |
| `Date` | A date from 0000-01-01 to 9999-12-31, held as days since 1970-01-01 | 1970-01-01 |
| `Time_Of_Day` | Nanoseconds since midnight, less than 24 hours | Midnight |
| `Date_Time` | A `Date` and a `Time_Of_Day`, with no offset | 1970-01-01T00:00:00 |
| `Offset` | Whole minutes east of UTC, −23:59 to +23:59 | UTC |
| `Offset_Date_Time` | A `Date_Time` and the `Offset` it was read at | 1970-01-01T00:00:00Z |
| `Zone` | Phase 2: the rule that maps instants to offsets | UTC |

Every zero value is a valid value
([Zeros that are values](comments.md#zeros-that-are-values)), which is why
`Date` counts days rather than holding a month that could be zero. All of them
are plain copyable data with no resource to drop, so they cross threads freely.
The four calendar types are the four kinds of date and time ISO 8601 text
distinguishes, and TOML's four: local date, local time, local date-time, and
offset date-time.

Everything is in one package. It imports `core:fmt` for printing, and
`core:fs` will import it for file times.

### Clocks

```odin
now() -> Time
tick_now() -> Tick
Tick.elapsed(self) -> Duration
Tick - Tick -> Duration
Tick + Duration -> Tick
sleep(duration: Duration)
```

`now` reads the system clock: `GetSystemTimePreciseAsFileTime` on Windows, in
100-nanosecond units. It follows the system clock, so a reading can be earlier
than the one before it when the clock is set back. Measure intervals with
`Tick`, which is monotonic: `QueryPerformanceCounter` on Windows, scaled to
nanoseconds by a quotient and a remainder so the product cannot overflow. Only
the difference between two ticks of one process means anything.

`sleep` blocks the calling thread for at least `duration`; zero or a negative
duration returns at once. Windows' `Sleep` counts milliseconds on a scheduler
tick, often 15.6 ms, and can return early for a request shorter than that tick,
so the implementation sleeps again until a monotonic reading shows the time has
passed.

`now`, `tick_now`, and `sleep` cannot run during
[compile-time evaluation](design.md#compile-time-procedure-evaluation). The
rest of phase 1 is integer arithmetic in Loke, and can.

### Durations

```odin
Duration :: distinct i64
NANOSECOND, MICROSECOND, MILLISECOND, SECOND, MINUTE, HOUR :: Duration

+, - (binary and unary), Duration * i64, i64 * Duration, Duration / i64,
Duration / Duration -> i64, Duration % Duration -> Duration, comparisons
Duration.seconds(self) -> i64           // and milliseconds, microseconds;
                                        // each rounds toward zero
Duration.seconds_f64(self) -> f64
from_seconds_f64(seconds: f64) -> Option(Duration)
Duration.truncate(self, unit: Duration) -> Duration
Duration.round(self, unit: Duration) -> Duration
```

A `Duration` is exact. There is no `DAY`: once a zone has daylight saving, a
calendar day is not always 24 hours, so steps of days belong to `Date`.
Arithmetic that overflows panics, as signed integer arithmetic does
([Integer overflow](design.md#integer-overflow)).

A duration prints as an ISO 8601 duration in hours, minutes, and seconds:
`PT1H30M`, `PT0.25S`, `PT36H`, and `PT0S` for none. Hours never roll over into
days, for the same reason. A negative duration takes a leading sign, `-PT1.5S`,
as Temporal writes it and Java's `Duration.parse` reads it.

### Instants

```odin
Time :: struct { /* private: Unix nanoseconds */ }

from_unix_nanoseconds(nanoseconds: i64) -> Time
from_unix_seconds(seconds: i64) -> Option(Time)
Time.unix_nanoseconds(self) -> i64
Time.unix_seconds(self) -> i64          // rounds down
Time + Duration -> Time, Time - Duration -> Time, Time - Time -> Duration,
comparisons
Time.utc(self) -> Date_Time
Time.at_offset(self, offset: Offset) -> Offset_Date_Time
```

`Time` is Unix time: every day has 86 400 seconds and leap seconds are not
counted, as in POSIX, Go, Java, and Rust. It prints in UTC with `Z`:
`2026-10-15T12:34:56.789Z`.

`fs.Metadata.modified` becomes `Option(time.Time)`, `.none` where Windows
records no time instead of today's zero. That is a breaking change and needs
an upgrade note. The `FILETIME` conversion in `core:fs` moves into `core:time`.

### The calendar

```odin
Month :: enum { January = 1, February, ..., December }
Weekday :: enum { Monday = 1, Tuesday, ..., Sunday }

Date.from_components(year: int, month: Month, day: int) -> Option(Date)
Date.from_unix_days(days: i64) -> Option(Date)
Date.year(self) -> int                  // and month, day, weekday, day_of_year
Date.iso_week(self) -> (year: int, week: int)
Date.unix_days(self) -> i64
Date.add_days(self, days: i64) -> Date
Date.add_months(self, months: i64) -> Date
Date.add_years(self, years: i64) -> Date
Date.days_until(self, later: Date) -> i64
is_leap_year(year: int) -> bool
days_in_month(year: int, month: Month) -> int

Time_Of_Day.from_components(hour, minute, second: int,
	nanosecond: int = 0) -> Option(Time_Of_Day)
Time_Of_Day.hour(self) -> int           // and minute, second, nanosecond

Date_Time :: struct { date: Date, time: Time_Of_Day }
Date_Time + Duration -> Date_Time, Date_Time - Duration -> Date_Time,
comparisons
Date_Time.at_offset(self, offset: Offset) -> Offset_Date_Time
```

The calendar is ISO 8601's proleptic Gregorian calendar, with year 0 the year
before year 1. Years 0000 to 9999 are the ones ISO 8601 writes in four digits
without prior agreement and the ones RFC 3339 allows; widening the range later
breaks nothing. Day counts use Hinnant's public-domain `days_from_civil` and
`civil_from_days` algorithms, which are exact over the whole range without
tables. Weekdays are numbered as ISO 8601 numbers them, Monday first, and
`iso_week` gives the ISO 8601 week-numbering year and week.

`add_months` and `add_years` keep the day of the month unless the resulting
month is shorter, and then take its last day: 2026-01-31 plus one month is
2026-02-28, and 2024-02-29 plus one year is 2025-02-28. A result outside the
range panics, as integer overflow does. Dates read from input are checked by
the constructors and parsers, which answer `.none` or an error instead.

Adding a `Duration` to a `Date_Time` counts every day as 24 hours: without a
zone there is no daylight saving.

A struct is not ordered field by field
([Comparison operators](design.md#comparison-operators)), so `Time`, `Date`,
`Time_Of_Day`, and `Date_Time` declare `<`, ordering chronologically.
`Offset_Date_Time` has `==` and no `<`. Two values for one instant at different
offsets are unequal, and comparing their fields would order the later instant
first; compare `to_time()` instead.

### Offsets

```odin
Offset :: struct { /* private: minutes east of UTC */ }
UTC :: Offset{}
Offset.from_minutes(minutes: int) -> Option(Offset)
Offset.minutes(self) -> int

Offset_Date_Time :: struct { date_time: Date_Time, offset: Offset }
Offset_Date_Time.to_time(self) -> Option(Time)
```

Offsets are whole minutes up to ±23:59, the range RFC 3339 writes. Offsets with
seconds occur only in the history of named zones (local mean time before
standard time), which this package does not have. `to_time` answers `.none`
outside the range of `Time`.

### ISO 8601 text

| Type | Prints | With `basic = true` |
| --- | --- | --- |
| `Time` | `2026-10-15T12:34:56.789Z` | `20261015T123456.789Z` |
| `Offset_Date_Time` | `2026-10-15T14:34:56.789+02:00` | `20261015T143456.789+0200` |
| `Date_Time` | `2026-10-15T14:34:56` | `20261015T143456` |
| `Date` | `2026-10-15` | `20261015` |
| `Time_Of_Day` | `14:34:56.789` | `143456.789` |
| `Offset` | `+02:00`, or `Z` when zero | `+0200` |
| `Duration` | `PT1H30M0.5S` | The same |

- Seconds always print. A fraction prints with as few digits as are exact, and
  not at all for whole seconds, as Temporal and Go's `RFC3339Nano` do.
- A zero offset prints `Z`; ISO 8601 treats `Z` and `+00:00` as the same
  offset. RFC 9557 now reads `Z` as "UTC is known, the local offset is not",
  a distinction this package does not keep.
- `fmt.Options` do not affect these types.

A wrapper chooses another form, as `fmt.fixed` does for floats:

```odin
Precision :: enum { Shortest, Seconds, Milliseconds, Microseconds, Nanoseconds }
Style :: struct { basic: bool, precision: Precision }
styled(value: $T, style: Style) -> Styled(T)
```

A fixed precision makes every value of a type print at one width, so the text
sorts as the times do; the shortest form does not, because `.` sorts before
`Z`. A fixed precision truncates and never rounds, so it never prints a second,
or a day, that has not arrived yet. `basic` drops the separators, which also
makes a timestamp fit in a Windows file name, where `:` is not allowed:
`backup-20261015T123456Z.zip`.

```odin
Parse_Error :: enum { Invalid_Syntax, Invalid_Value, Missing_Offset, Out_Of_Range }

parse_time(text: string_view) -> Result(Time, Parse_Error)
parse_offset_date_time(text: string_view) -> Result(Offset_Date_Time, Parse_Error)
parse_date_time(text: string_view) -> Result(Date_Time, Parse_Error)
parse_date(text: string_view) -> Result(Date, Parse_Error)
parse_time_of_day(text: string_view) -> Result(Time_Of_Day, Parse_Error)
parse_offset(text: string_view) -> Result(Offset, Parse_Error)
parse_duration(text: string_view) -> Result(Duration, Parse_Error)
```

- Each parser reads what its type prints in either format, but one value is
  all basic or all extended, as ISO 8601 requires. It also takes RFC 3339's
  allowances, lower-case `t` and `z` and a space in place of `T`, and ISO
  8601's comma as the decimal sign.
- A fraction of any length is read and truncated after nine digits.
- `-00:00` reads as `Z`. ISO 8601 does not allow it; RFC 3339 used it for an
  unknown local offset, which RFC 9557 now writes as `Z`.
- Second 60, a leap second, reads as second 59, keeping its fraction. Hour 24
  is invalid, as in RFC 3339.
- `parse_time` requires an offset, reporting `Missing_Offset` without one, and
  converts to UTC. `parse_offset_date_time` keeps the offset.
  `parse_date_time` rejects an offset rather than drop it.
- `parse_duration` reads hours, minutes, and seconds, with a fraction only on
  the last. Years, months, weeks, and days are calendar units a `Duration`
  cannot hold exactly, so they are `Invalid_Value`.
- As in `core:strconv`, surrounding ASCII whitespace is allowed and anything
  else left over is `Invalid_Syntax`.
- `Invalid_Syntax` is the wrong shape. `Invalid_Value` is a field outside its
  range: month 13, 2026-02-29, minute 60. `Out_Of_Range` is a valid value the
  type cannot hold: a `Time` after 2262, a duration beyond ±292 years.

### The local time zone

Phase 2:

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
known rules instead of depending on the machine's zone.

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
copyable, and phases 1 and 2 do not change.

### Phases and callers

1. **Clocks, durations, instants, the calendar, offsets, and ISO 8601 text.**
   The corpus runner reports how long each case took with `Tick` and
   `Duration`; `fs.Metadata.modified` gets its type; and an example stamps its
   output with `now()` and parses timestamps back. `lib_time` pins known
   answers: day counts at both ends of the range and around 1970; the leap
   years 1900, 2000, 2024, and 2100; ISO weeks across year ends (2020-12-31
   and 2021-01-03 are both in 2020's week 53); month clamping; the `FILETIME`
   limits; every parse error; and a print-then-parse round trip for every type
   and style. It also walks every day of the range one at a time against
   `from_unix_days`. Trap tests cover each overflow panic.
2. **The system's local zone.** Tests evaluate the year rule with fixed rules,
   such as the European Union's, for gaps and overlaps, and compare
   `offset_at` with `SystemTimeToTzSpecificLocalTimeEx` across a year in
   whatever zone the machine has.
3. **Named zones**, only when a caller needs them, by the route above.

### Open points

- **The range of `Time`.** `i64` nanoseconds match `fs.Metadata` and Odin,
  make arithmetic one integer operation, and cover every clock reading and
  file time, but not every `Date_Time`, so `to_time` is partial before 1677
  and after 2262. Seconds and nanoseconds in 16 bytes, as Go and jiff hold
  them, would cover 0000 to 9999 and make it total.
- **Leap seconds in text.** Reading `:60` as `:59` accepts real RFC 3339 data
  at the cost of up to a second. Rejecting it is stricter.
- **A short form for durations.** `PT0.153S` reads poorly in a test runner's
  summary beside Go's `153ms`. A style could add one without changing the
  ISO 8601 default.
- **Zero-padded custom forms.** Other formats, such as `15.10.2026`, are built
  from the accessors, but `fmt` cannot pad with zeros. A `fmt.zero_pad` wrapper
  beside `pad_left` would serve every integer and is preferable to a pattern
  language here.
- **Calendar durations.** `P1Y2M3D` has no type; `add_months` and its siblings
  do the arithmetic. A `Period` type waits for a caller that stores or parses
  one.
- **The system zone's name.** Windows names its zones its own way. The IANA
  name needs CLDR's mapping, which ICU has, so `Zone` has no name in phase 2.

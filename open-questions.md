# Open questions

Decisions that are deliberately not yet made are recorded here rather than left implicit in normative prose. [`design.md`](design.md) defines the rules implementations must follow for the current language version; these questions concern possible later changes.

Design rationale and differences from Odin are recorded in [comments.md](comments.md).

## Package and import versioning

Should import paths encode package versions, and should a package declaration remain mandatory in every file? The current version requires the declaration and leaves dependency versions to the build system or package manager. A future package design may need reproducible version selection without making source imports depend on a particular registry.

Decided so far, and built as `loke.project` (readme.md "Projects"):

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

## package declaration

is the package declaration needed or is it unessesary sermony?

## The `op`/`try_op` pair

Should a container keep both spellings of a fallible operation? `append`/`try_append`, `reserve`/`try_reserve`, and the rest double the container API over a failure-policy choice. Typed fallibility made the fallible variant cheap — a `try_` operation reports failure as a `Result` rather than a bare `bool`, over an ordinary library union with `@(failure=...)` and no compiler-known error type — which is what makes keeping both spellings need re-justifying. Every shipped container keeps its pair today; collapsing them is a separate decision with its own migration.

The language pairs a fallible operation with a policy-following one in a second place: the compiler-generated [`clone`/`try_clone`](design.md#lifecycle-hooks-and-resource-types). The shape is identical, so the two are one question asked twice — but they are not one answer, for two reasons that the container pair does not share.

The pair costs a type author nothing. Both names are generated from the single `hook(copy)` role, so a record supplies one implementation and receives both spellings; a container supplies two implementations, two doc entries, and two test paths per operation. Duplication in the generated pair is two names, not two bodies.

And the policy-following half is load-bearing rather than convenient. Copy assignment of a copyable type is *defined* as `try_clone` plus the [allocation failure policy](design.md#allocation-failure), and [`Cloneable`](design.md#standard-interface-catalogue) names the fallible slot, so both halves already have language-level jobs. Deleting `clone` would not remove the policy call, only move it to every call site that copies. A container `try_op` carries no equivalent obligation, which is what leaves the container pair the live half of the question.

The allocation built-ins are a third instance, and they keep the pair: `box`/`try_box`, `make`/`try_make`, and `unsafe.new`/`unsafe.try_new` (see [The allocation built-ins follow the `try_` convention](comments.md#the-allocation-built-ins-follow-the-try_-convention)).

## Unnamed record fields, and records versus structs

**Unnamed fields.** `divide :: proc(dividend, divisor: int) -> (int, int)` is
rejected (`L0238`): an [anonymous record](design.md#anonymous-records) names
every field, and the names are part of its type. A caller that destructures,
`q, r := divide(17, 5)`, never reads them, so they can look like ceremony.
Allowing the unnamed form would need:

- an unnamed record type, and a way to reach its fields without names, such as
  `.0` and `.1`, which Loke does not have;
- a spelling for one field, since `(T)` must stay grouping;
- a rule for how `(int, int)` relates to `(quotient: int, remainder: int)`:
  unrelated types, or a conversion between them.

Against it: the names document each result where the procedure is declared,
and [One result](comments.md#one-result-and-the-compatibility-break-that-came-with-it)
accepted them as part of procedure-type identity, the price of structural
record identity. Revisit if real call sites keep writing names nobody reads.

**Records versus structs.** Loke has two kinds of record. A `struct` is
nominal: its declaration is its identity, a field may be private, a positional
literal or a destructure is allowed only in the declaring package, and it can
carry hooks and attributes such as `move_only`. An anonymous record is
structural: its ordered field names and types are its identity, every field is
public, and positional use is allowed anywhere. No package declares it, so an
`impl` on one, through an alias such as `Pair :: (a: int, b: int)`, is an
extension block: it may add methods but no hooks (`L0486`). Could they be one
concept, with a `struct` as a named, nominal record over the same field list, so
literals, destructuring, equality, formatting, reflection, and layout have one
set of rules, and the tutorials explain records once? The questions it raises
are the differences above: privacy, the field-order rule, which package owns
a record's hooks, and whether naming a record type always makes it nominal or
only when it is declared `struct`. Nothing is wrong today; the question is
whether two kinds are worth their extra rules.

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

The current [callback convention](comments.md#build-selected-services-and-explicit-runtime-state)
uses a record with a `call` method. `slice.sort_by` also accepts an ordinary
procedure through a library wrapper. Possible extensions remain exploratory:

- Should every procedure type gain a compiler-contributed `call` member, so one
  generic signature accepts both procedures and callable records? One standard
  API uses this convention today; the library wrapper covers it without a new
  language rule.
- How should an API infer a callable record's result type? `Result.map_error`
  currently matches `proc(error: move E) -> $F`. Supporting records would need
  a way to derive the result from `call`, as an iterator derives `Iterator`
  from `iter`, and a rule for an overloaded `call`.
- Would closure syntax usefully abbreviate that record and method? The
  proposed spelling is [a capture clause](#a-capture-clause-after-the-signature);
  its open points need deciding together with the two questions above. No
  closure syntax is committed.

A callable that outlives its creation scope is a separate ownership question.
`fmt.Writer` and `log.Logger` do not establish a need for one: a formatter lends
its sink for the call, and a logger lends process-lifetime storage, both through
[`dyn mut` views](comments.md#formatting-and-logging-sinks-are-dyn-views).

### A capture clause after the signature

**Proposal.** A procedure literal lists what it captures in a clause between
its signature and its body, where a [`where` clause](design.md#where-clauses)
goes:

```odin
less := proc(a, b: int) -> bool capture(limit) {
    return (a < limit) && !(b < limit);
};
slice.sort_by(values, less);

count := 0;
bump := proc() capture(&mut count) { count += 1; };
job := proc() capture(move(buffer)) { ... };
per := proc(x: int) -> int capture(n = len(items)) { return x / n; };
```

Each entry reuses a spelling the language already has:

- `limit` copies the place, as a binding does
  ([Value semantics and the ownership rule](design.md#value-semantics-and-the-ownership-rule)):
  a managed value is cloned, unless this is the place's last use, which
  transfers it as [Last-use transfer](design.md#last-use-transfer) does for a
  binding;
- `&limit` borrows it read-only, spelled as the `&place` that forms a `^T`;
- `&mut count` borrows it writably, as a `&mut` binding does in a `foreach`
  header or a case;
- `move(buffer)` transfers the value and ends `buffer`;
- `n = len(items)` captures a computed value under a new name.

The mode is written only in the clause. The body names every capture the same
way, `limit` or `count`, as the place itself: a borrowed capture is read as a
borrowed `foreach` leaf is, with no `^`, and `&limit` in the body yields a
`^T` carrying the root's provenance. A callable with a borrowed capture
carries that borrow and is checked as a record holding a `^T` or `^mut T` is
([Values that contain borrows](design.md#values-that-contain-borrows)): it may
be passed to `slice.sort_by`, but not returned or stored past the root, and
the root may not be written, moved, or dropped while the callable is live.

```odin
// Borrowed: sorts by a lookup table without cloning the map.
slice.sort_by(ids, proc(a, b: Id) -> bool capture(&priority) {
    return priority[a] < priority[b];
});

less := proc(a, b: int) -> bool capture(&limit) { ... };
limit += 1;          // ERROR: `limit` is borrowed by `less`, used below
slice.sort_by(values, less);
```

The clause is evaluated once, left to right, where the literal is evaluated.
The literal lowers to the record and `call` method written by hand today, with
one field per entry in clause order. A literal without the clause still
captures nothing and is an ordinary procedure value.

**Why not declarations in the body.** The alternative leaves the signature
unmarked and declares each capture as a statement, `capture limit;`, beside
its use. It is rejected:

- A body statement runs on every call, but a capture runs once, when the
  literal is created. `capture move(buffer);` inside the body would end
  `buffer` before the first call, which no other statement in a body does.
- The captures decide what the value is: its size, whether it is copyable or
  move-only, and whether it borrows and so cannot escape. Body declarations
  hide that behind what reads as a thin `proc(a, b: int) -> bool`, so a
  reader, and the escape check, must scan the body. That works against
  [Public borrow contracts should stand on their own](#public-borrow-contracts-should-stand-on-their-own).
- A capture under an `if`, in a loop, or after an early `return` has no
  meaning. Restricting captures to the start of the body makes them a header
  written inside the braces, as Swift's `{ [weak self] in ... }` is.

What the body form does better is keep a capture beside its use and leave
`proc(...)` looking exactly as it does today.

**Why not a list before the parameters.** The earlier sketch,
`proc [limit] (a, b: int) -> bool`, puts state captured at creation ahead of
what the procedure takes and returns, and gives `[...]` a new meaning after
`proc`. The clause keeps the signature first and puts the captures where
creation ends and the body begins.

**Why a plain name copies.** The alternative makes an unmarked capture
borrow, as an ordinary parameter borrows its argument, so the default never
allocates. It is rejected:

- Sharing is written in Loke. A variable holds a value, and a pointer, slice,
  or view is the written opt-out; a capture is a binding, and a binding of a
  place clones. An unmarked borrowing capture would be the one binding that
  shares silently.
- A parameter borrows because, for one call, a borrow cannot be told from a
  copy. A callable outlives the expression that made it, so the difference
  shows: a borrow rejects `limit += 1` while the callable is live where a copy
  keeps the old value, and a borrowing callable cannot be returned or stored
  past `limit`. That should be chosen, not met.
- Borrowing only when the callable cannot escape makes its size, and whether
  it carries a borrow, depend on its uses, the objection that rules out
  declarations in the body.

The cost is a silent clone when `capture(table)` names a map that is read
again later. That is the cost `saved := table` already has; last-use transfer
removes it when `table` is not read again, and
[copy-cost diagnostics](design.md#copy-cost-diagnostics) can report the rest.

`&name` stays an error as a `foreach` or case leaf. There the traversal's
[yield mode](design.md#yield-modes) decides between owning and borrowing, and
an unmarked leaf already borrows; a bare `&` was removed there because it bound
a writable place. A capture has no yield mode to defer to, so it states the
mode itself, and `&limit` is read-only as `&place` is.

**How `call` takes `self`.** A literal's `call` takes a plain `self`. The body
may read every capture and write through a `&mut` one, since a `^mut` field is
writable through a plain receiver: capability is in the carrier
([Capabilities and the one rule](design.md#capabilities-and-the-one-rule)). It
may not assign to a copied capture or move one out. Either is an error naming
the two ways out: capture an outer local with `&mut`, or write the record and
its `call` by hand with a `self: inout` or `self: move` receiver.

```odin
compares := 0;
slice.sort_by(values, proc(a, b: int) -> bool capture(&mut compares) {
    compares += 1;
    return a < b;
});
```

A plain `self` is the mode the most APIs accept. Receiver modes must match an
interface slot exactly, except that a plain `self` also meets a `self: ^` slot
([Receiver forms](design.md#receiver-forms)), and `slice.Comparator`'s slot is
`call: proc(self, left, right: T) -> bool`. A literal with an `inout` or `move`
`call` would be rejected by every callback API in the standard library.

What a plain `self` cannot do is keep mutable state inside the callable, or
hand a capture away when called and so be callable once. Both matter only for
a callable that outlives its scope: a stored generator, a deferred job, a
thread worker. Those wait on
[Owning runtime polymorphism](#owning-runtime-polymorphism) and
[Thread transfer needs a visible contract](#thread-transfer-needs-a-visible-contract).
Revisit `inout` and `move` calls when the first API takes such a callable; the
receiver mode is then written, for example on the clause.

**Why not infer the receiver.** Rust infers `Fn`, `FnMut`, or `FnOnce` from
what the body does with its captures. That makes which APIs accept a literal
depend on its body: adding an assignment deep in the body silently changes it,
the objection that rules out declarations in the body.

**Still open:**

- The keyword: `capture(...)` or `use(...)`.
- Whether an entry may be a path, `self.limit` or `a[i]`, or only a name and
  `name = expr`.
- The literal's type. Each literal is its own type, as a body-local type is, so
  two identical literals do not share one; it reaches a generic parameter or a
  `dyn` view, never a `proc` type. Whether that type can be named, or only
  inferred.

## Owning runtime polymorphism

Borrowed `dyn Interface` views are now defined. Should a later version add an
owning erased value, and if so should it be a language type such as `box(dyn I)`
or a library owner built over an exposed witness primitive?

The proposal must specify allocator identity, alignment, fallible construction,
move, clone, drop, thread-affine destruction, and whether inline small-object
storage changes representation. Borrowed `dyn` intentionally settles none of
those questions and never allocates. The decided
[`box(T)`](design.md#owned-values) settles them
for a payload whose type is known; `box(dyn I)` would still need erased clone
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

The current [memory model](design.md#concurrency-and-the-memory-model) defines data races, atomics, transfer between threads, and `shared(T)`. Experience with a real concurrent runtime should determine whether later versions need compiler-checked `Send` or `Sync` interfaces, additional atomic orderings, or a thread-affine owning type for code that wants non-atomic reference counts.

The cost of keeping immutable `string` safe to copy and drop across threads is treated separately under [Thread-affine strings](#thread-affine-strings).

high level concurrency constructs
Should we have some monady thing for concurency like futures?
Should we have some language help for reactivity, like procedures that automatically get called when an variable is changed?

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

Version 1 makes a panic unrecoverable: unwinding runs `defer`s and managed
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

## Open questions in `core:term`

- Every console test writes records into the console the test run is using,
  because Windows 10 cannot allocate a hidden console. Anything typed into that
  console while `tests/run/lib_term_console` runs is read along with the
  records it wrote.

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
| Later | Explicit-capture callables | Shorter callbacks | Small syntax additions |
| Later | Checked disjoint access | Hand mutable halves to parallel workers | One compiler-known slice operation |
| Later | Checked thread transfer and scoped workers | Reduce races and permit borrowed parallel work | Thread APIs and capabilities |

The decided change should precede a broad syntax rewrite. The next group should
be tried on concrete programs: a parser, a resource container, a sorting or
partitioning algorithm, and a parallel numeric kernel.

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

### Callbacks deserve a small convenience

A stateful comparator or error mapper requires a nominal record plus an
`impl call`, while ordinary procedures and callable records are not accepted
uniformly by every callback API. (The fallible-stream loop this item also
covered is now [Conditional patterns](design.md#conditional-patterns).)

First unify the existing callable-record convention in library
APIs. Then consider an explicit-capture procedure literal that lowers to that
same record and method. Captures should say whether they copy, borrow, or move;
escaping a borrowed capture must be checked, and creating a generic stack
callable should not imply heap allocation. The proposed spelling is
[a capture clause after the signature](#a-capture-clause-after-the-signature),
`proc(a, b: int) -> bool capture(limit) { ... }`.

Specify mutable/consuming captures and callable result inference before making
this syntax normative. Owning runtime type erasure is a separate question;
most sorting and mapping callbacks do not need it. This refines
[Callable records, procedures, and closures](#callable-records-procedures-and-closures).

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


## Source review follow-up (2026-10-07)

The [complete per-file review](source-review-2026-10-07.md) covers 168 implementation,
library, example, benchmark, script, CI, and test-harness files. Small corpus
fixtures were outside the agreed scope. The four earlier items fixed in
`1a8aa53` remain closed. The confirmed language, library, and tooling findings
are fixed or settled by the spec, and the ten candidates that needed evidence
(C01–C10) were each reproduced and fixed.

Sibling literal/container cleanup paths and large packed equality projections
are identified beside their confirmed reproductions in
[Known gaps](known-gaps.md#gaps). They still need separate checks when those
families are fixed.

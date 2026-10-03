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
  version selection does: deterministic without a solver, so a lock file only
  has to record checksums.

## package header files

I am not happy with the package level encapsulation, one idea is
An files containing all public signature and what is reachable from the outside.
Should be optional but if it exists it should be checked by the compiler that it's correct.
A way to improve encapsulation and make it easier to see what an package can do both for humans and LLM's.

## package declaration

is the package declaration needed or is it unessesary sermony?

## The `op`/`try_op` pair

Should a container keep both spellings of a fallible operation? `append`/`try_append`, `reserve`/`try_reserve`, and the rest double the container API over a failure-policy choice. Typed fallibility made the fallible variant cheap — a `try_` operation reports failure as a `Result` rather than a bare `bool`, over an ordinary library union with `@(failure=...)` and no compiler-known error type — which is what makes keeping both spellings need re-justifying. Every shipped container keeps its pair today; collapsing them is a separate decision with its own migration.

The language pairs a fallible operation with a policy-following one in a second place: the compiler-generated [`clone`/`try_clone`](design.md#lifecycle-hooks-and-resource-types). The shape is identical, so the two are one question asked twice — but they are not one answer, for two reasons that the container pair does not share.

The pair costs a type author nothing. Both names are generated from the single `hook(copy)` role, so a record supplies one implementation and receives both spellings; a container supplies two implementations, two doc entries, and two test paths per operation. Duplication in the generated pair is two names, not two bodies.

And the policy-following half is load-bearing rather than convenient. Copy assignment of a copyable type is *defined* as `try_clone` plus the [allocation failure policy](design.md#allocation-failure), and [`Cloneable`](design.md#standard-interface-catalogue) names the fallible slot, so both halves already have language-level jobs. Deleting `clone` would not remove the policy call, only move it to every call site that copies. A container `try_op` carries no equivalent obligation, which is what leaves the container pair the live half of the question.

The allocation built-ins are a third instance, and they keep the pair: `new`/`try_new`, `new_clone`/`try_new_clone`, and `make`/`try_make` (see [The allocation built-ins follow the `try_` convention](comments.md#the-allocation-built-ins-follow-the-try_-convention)).

## `()` as a type category

Is `()` a new zero-sized type category, or the anonymous spelling of an already-legal empty struct? The shipped `Unit :: struct {}` already covers `Result(Unit, E)`, so a second spelling for one type buys nothing yet, and the product, call-matching, and one-result work all shipped without it. The question only becomes live if a second zero-sized use appears.

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

## Retaining defer

Does scope-based `defer` provide enough clarity and utility to remain in the final language? Its current semantics are fully defined, including its ordering with automatic cleanup. The remaining question is whether explicit resource types and managed cleanup make most uses unnecessary.

The standard library has since stopped using it. Stages 0-3 carried thirty-five explicit `drop(x)` and `defer drop(x)` statements that the compiler already emitted at scope exit; deleting them left `defer` with no user anywhere in `core/` or `base/`. What remains in the tree is the feature exercising itself under `tests/`, plus one line of `examples/config_parser.loke` that defers a `println` precisely to show its ordering against an automatic drop — a trace, not a release.

That narrows the question rather than answering it. Every deferred *release* the library needed turned out to be one a managed local already performed, which is the case against keeping the statement. But nothing here tests a deferred *side effect* — logging, a counter, restoring a plain variable — and a resource type does not cover those, because there is no resource. Whether that residue justifies a statement form of its own is what is left to decide.

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
- Would closure syntax usefully abbreviate that record and method? Written
  captures, mutation, allocation, and escape rules need deciding together with
  the two questions above. No closure syntax is committed.

A callable that outlives its creation scope is a separate ownership question.
`fmt.Writer` and `log.Logger` do not establish a need for one: a formatter lends
its sink for the call, and a logger lends process-lifetime storage, both through
[`dyn mut` views](comments.md#formatting-and-logging-sinks-are-dyn-views).

## Owning runtime polymorphism

Borrowed `dyn Interface` views are now defined. Should a later version add an
owning erased value, and if so should it be a language type such as `box(dyn I)`
or a library owner built over an exposed witness primitive?

The proposal must specify allocator identity, alignment, fallible construction,
move, clone, drop, thread-affine destruction, and whether inline small-object
storage changes representation. Borrowed `dyn` intentionally settles none of
those questions and never allocates.

Note that the witness is currently a mechanism with no user-visible spelling: the
compiler builds one for each `(Interface, Concrete, arguments...)` tuple reached
by a `dyn` conversion, and nothing materializes it as a value. An earlier draft
exposed `witness_of` and a compiler-defined `Witness(...)` type for exactly this
future owner, which meant fixing a layout, a zero value, an invalid-witness panic
rule, and a normative slot-flattening order for a consumer that did not exist.
Whichever way the question above is answered, the primitive comes back with the
owner that needs it.

## Marking a dead variable live

Should `core:unsafe` gain an operation that tells the checker a dead variable is
live again, without writing a value into it?

Two thirds of the original question have since been answered. Reviving a dead
variable is already possible and already cheap: a full assignment completes an
initialization and makes the variable live, so `a = [dynamic]int{7, 8}` after a
`move(a)` is the supported spelling (see
[Assignment statements](design.md#assignment-statements) and
[Managed values and storage](design.md#managed-values-and-storage)). The
opposite direction shipped too — [`unsafe.forget`](design.md#unsafeforget) makes
a live owner dead without running its cleanup. What is missing is only the
combination of the two: becoming live again *without* the write.

The optimization motivation is narrower than it looks. Liveness is a
compile-time property and "does not add storage to ordinary variables", so a
definitely-live or definitely-dead variable costs nothing at runtime and has
nothing to remove. Only the *conditionally* live case can cost anything: the
specification permits the compiler to preserve that state however it likes, and
today it emits a hidden `i1` drop flag, set when a variable is conditionally
assigned or dead on one exit path. So the entire surface of this question is
letting a programmer assert that such a variable is definitely one state or the
other, and thereby delete one flag and the branch that reads it. No corpus
program has yet shown that flag mattering.

The package charter is no longer an objection. `core:unsafe` was scoped to
operations that "discard or manufacture provenance"; `unsafe.take` and
`unsafe.write` are liveness operations and live there, so the charter now reads
"provenance, or a liveness the compiler cannot see" — which is what `forget`
always was. What is left is only whether the flag this would remove is worth a
member, and no corpus program has yet shown one mattering.

The `unsafe.Maybe_Uninit(T)` half of that precedent is settled. The
implementation need appeared — `Small_Array(T, N)` could not hold an element
with no zero value, while `[dynamic]T` could — and it was answered by
[`@(initialized = count)`](design.md#uninitialized-capacity) plus that pair of
operations, rather than by a wrapper type. A container's storage stays `[N]T`,
so it still yields a contiguous `[]T`, and the count it already keeps is what
bounds the generated copy and drop.

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

## Compile time

Make more stuff work at compile time
file handling?
fail load, can the programmer easily see what is going to run at compile time

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

## Nominal conformance

An `implements Drawable(Circle);` declaration was proposed and rejected. With no
semantic force it is only a second spelling of `static_assert(Drawable(Circle));`
while suggesting a nominal relationship the language does not create. The
structural interface model is complete without it.

It should be reconsidered only as a proposal in which it *has* force. That
proposal must define ownership and orphan rules, coherence, generic and
conditional conformances, conformances for built-in types, compatibility with
existing structural code, and whether a claim gates static satisfaction or only
`dyn` witness construction. Until then satisfaction stays structural, and a
file-scope assertion stays a check rather than a registry.

## Printed form of built-in types

Formatting uses a real `fmt.Formattable` interface so a custom representation
can be checked by a generic constraint and borrowed through `dyn`, as other
capabilities can. Generated defaults supply the same slot for built-in types
and aggregates. The print family keeps `..any_view`: it permits mixed arguments
and existing forwarding wrappers without implicit interface conversions.
A private compiler primitive recovers a concrete witness from an erased
value's `typeid`; the library then calls the ordinary interface slot.
Definition-site slot selection preserves one printed representation per type.

design.md "String format printing" says the compiler provides the format for a
type without its own, but not what that format is. Two choices in it may
surprise a reader:

- A struct prints its public fields only, as reflection from another package
  sees it, because one printed form serves every package. In a `package main`
  whose fields are private by default, `fmt.println(Point{1, 2})` prints
  `Point{}`.
- A float in integer range prints without a fraction, so `fmt.println(1.0)`
  prints `1`, the same as `fmt.println(1)`.

Should the spec fix these forms, and should either change?

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

## Open questions in `core:os`

- `from_last_error` is written three times, in `core:os`, `core:fs`, and
  `core:term`, with different tables. Process and filesystem path errors now
  agree, but should shared mappings be checked together or factored into one
  helper? The input and path-error decisions are recorded in
  [comments.md "Portable process input and path errors"](comments.md#portable-process-input-and-path-errors).

## Open questions in `core:strconv`

- `parse_f64` rounds through the C library's `strtod`, as `fmt` already does to
  find its shortest spellings. That makes it foreign code, which design.md
  "Compile-time procedure evaluation" keeps out of constants for good, and it
  reads the decimal point of the C locale, which a program that calls
  `setlocale` through a foreign binding can change. A correctly rounded parser
  in Loke (Eisel-Lemire with a big-decimal fallback) would fix both. Is either
  worth that much code?

## Slicing text at a byte offset

`text[a:b]` panics when an offset falls inside a code point, so an offset read
from input or computed by arithmetic ("the first 10 bytes") can crash a program
on text its author never tried. An offset from `find`, `split`, or
`rune_offsets()` is always on a boundary, so the risk is only in the second
kind. Keeping the panic matches an out-of-range array index; the question is
what to offer so that a program rarely needs to risk it:

- `try_slice(a, b) -> Option(string_view)`, answering `none` for a cut through
  a code point, for offsets that come from outside the program.
- Operations naming the usual reasons to cut, which cannot fail:
  `truncate_bytes(n)` (at most `n` bytes, rounded down to a boundary),
  `prefix_runes(n)`, and `floor_boundary(i)` / `ceil_boundary(i)`.
- `bytes()[a:b]` already slices anywhere, for data that is bytes rather than
  text.

Two alternatives seem worse. An opaque index type, as in Swift, makes a bad cut
a compile error, but `text[0:3]` stops compiling and every offset needs a
conversion. Rounding inside `[a:b]` never crashes, but quietly returns other
text than was asked for.

## Open questions in `core:term`

- Every console test writes records into the console the test run is using,
  because Windows 10 cannot allocate a hidden console. Anything typed into that
  console while `tests/run/lib_term_console` runs is read along with the
  records it wrote.

## Open questions in the allocation runtime

- design.md "Allocation failure" gives every allocator one of two policies, but
  no source spelling selects `.Trap`: `core:mem` names no policy, and `Arena`
  and `Scratch` always answer `.Panic`. Only a record a foreign provider builds
  can carry it, so the non-unwinding abort that `runtime/fail.c` implements
  for it has no corpus test. Where does a program choose `.Trap`: on the
  factory, on `Arena`/`Scratch` construction, or as a build-wide default for
  freestanding targets?

## Width and precision in `fmt`

`fmt.Options` holds only `base` and `uppercase`, so a width, a precision, or
padding has no spelling: `3.14159` cannot be printed as `3.14`, nor a column
aligned.

## Open questions in the compiler's structure

An architecture review of `src/` left these open. Each is a structural risk
rather than a wrong answer; the wrong answers it found are in
[known-gaps.md](known-gaps.md).

- **Should probes have a stronger mutation boundary?** `begin_probe` and
  `end_probe` pair speculation with diagnostic rollback, and registry writes
  share the `committing(c)` gate. Silent generic instantiation uses this probe
  protocol and retains a rejected signature's head diagnostic for later use;
  it no longer rolls back at depth zero. The current contract and regression
  coverage are described in
  [Checking and overload resolution](compiler-architecture.md#checking-and-overload-resolution).
  The remaining structural question is whether registry writes should be
  journaled for rollback, or probes should stop before body-level work, rather
  than requiring each write to use the gate.
- **Lifecycle and provenance meet through shared keys.** The dead owners at
  each reset point reach the provenance walk through `reset_dead` and
  `cleanup_reset_dead`, keyed by a `Reset_Key` both walks build alike: the
  ending node or exit, the local, and the `defer` expansion. Lifecycle registers every
  point it walks, marks the ones its solve reaches, and a key the provenance walk
  does not find is an assertion failure rather than "nothing to check". The
  coupling remains: should liveness at reset points be solved on the provenance
  graph, which already has the topology?
- **One graph builder serves three modes.** The provenance modes' state is a
  `Prov_State` that a lifecycle graph does not have, but one walk in `cfg.odin`
  still builds every mode's topology and events, branching on the mode, because
  the provenance walk computes loans as it goes. The lifecycle walk also
  decides clone or move for declarations and assignments (`value_clones`,
  `rhs_clones`) and reports copy costs, so the disposable view writes
  annotations the backend reads. Should topology construction be separated from
  the per-mode consumers?
- **Keep one copy of process waiting when that code next changes.**
  `run_process`/`drain` in
  [src/emit_llvm_toolchain.odin](src/emit_llvm_toolchain.odin) and `exec`/`drain`
  in [tests/corpus_test.odin](tests/corpus_test.odin) duplicate roughly 65 lines
  of pipe draining and process waiting. A shared internal helper can remove
  one copy, less package/import overhead, without adding a dependency. The
  documented busy-loop behavior is a reason to retain the current waiting
  semantics, not to substitute `os2.process_exec` blindly.

The completed audit and its decisions are recorded in
[comments.md "Compiler architecture audit (2026-09-28)"](comments.md#compiler-architecture-audit-2026-09-28).

## Review cleanup in `cfg_provenance.odin`

The correctness findings and reproductions are in
[known-gaps.md](known-gaps.md). One recommendation for
[src/cfg_provenance.odin](src/cfg_provenance.odin) remains: give `prov_call`
visible phase boundaries using small helpers for builtin calls and argument
preparation, following its existing `prov_text_call` pattern. Its current
dispatch, evaluation, borrow creation, and effect application occupy one
procedure of roughly 360 lines.

## Review cleanup in `check.odin`

The confirmed specification divergences and reproductions are in
[known-gaps.md](known-gaps.md). One recommendation for
[src/check.odin](src/check.odin) remains: keep the existing sections,
`Checker_Location`, and `Body_Context` save/restore units, but share signature
guards between named and anonymous procedures, and declaration validation
between ordinary and destructured initialization. Small shared checks address
the divergent paths; another checker abstraction or a file split by size is
unnecessary.

## Review cleanup in `check_expr.odin`

Recommendations for [src/check_expr.odin](src/check_expr.odin) that remain:

- Reuse `materialize_value_expr` for SIMD lane validation and
  `index_arguments`' candidate context for slicing. Share the packed-storage
  check with slicing and its existing borrow callers; no general conversion
  abstraction is needed.
- Correct the `convert_const` comment when repairing float-to-integer
  conversion; an exact implicit conversion is still forbidden.

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

## Read-only reborrows of one carrier in one call

[design.md "Weakening and reborrows"](design.md#weakening-and-reborrows)
suspends a mutable carrier while a read-only reborrow of it is live, and a
suspended carrier may not be used at all. A `[]mut T` passed where a `[]T` is
wanted is such a reborrow for the duration of the call, so
`slice.equal(s, s)` with `s: []mut int` is rejected (`L0641`) although both
arguments only read: the second argument uses `s` while the first argument's
reborrow is live. Binding a read-only view first, `view: []int = s;
slice.equal(view, view)`, is accepted.

Should a suspended carrier allow uses that are themselves read-only reborrows
or plain reads, so only writes and mutable reborrows conflict? That matches
the rule's purpose, that no mutable alias writes behind the reborrow, but it
changes the rule for explicit bindings too: `view: []int = source; x :=
source[1];` is rejected today.

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
| First | Non-null checked references | Remove ordinary nil dereferences and redundant optional states | Types and APIs |
| First | Flow-sensitive fault/result diagnostics | Catch definite failures and overwritten errors | Analysis |
| Next | Explicit mutable slices and compatible reborrows | Capability no longer depends on expression context | Borrow rules and syntax |
| Next | Checked disjoint access | Express partitioning and parallel array algorithms | Library primitives and provenance |
| Next | Fallible insertion of move-only values | Handle allocation failure while transferring resources | Container APIs |
| Next | Uniform arithmetic policies | Scalar and vector code preserve the same meaning | Numeric APIs and lowering |
| Next | Compiler-selected ordinary union layout | Compact optionals and nested results | Representation contract |
| Next | Stable written borrow contracts | Public signatures do not depend on implementation bodies | Procedure types |
| Later | Localize unchecked operations | Unsafe obligations are visible where introduced | Syntax and APIs |
| Later | Explicit-capture callables and conditional patterns | Shorter callbacks and fallible streaming loops | Small syntax additions |
| Later | Checked thread transfer and scoped workers | Reduce races and permit borrowed parallel work | Thread APIs and capabilities |
| Later | Focused syntax and construction cleanup | Remove duplicate forms and accidental zero fields | Grammar and initialization |

The first group should precede a broad syntax rewrite. The next group should
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

### Non-null references and explicit allocation owners

[Pointers](design.md#pointers), procedure values, and `dyn` views all have nil
states. `Option(^T)` consequently permits three states: absent, present-nil,
and present-valid. Usually only two are wanted. `new(T)` also returns the same
pointer shape as a borrow while transferring manual release responsibility
only by convention ([Owners and drop](design.md#owners-and-drop)).

**Proposal:** make checked `^T`, `^mut T`, procedure values, and `dyn I` non-null.
Use `Option(...)` for absence. They then have no zero value, which fits the
existing no-zero-type rules and dead local declarations. Raw C pointers may
remain nullable for interop. Foreign and unsafe code must validate before
constructing a checked reference.

Provide a move-only `Box(T)` in the library for an individually allocated
owning value; it holds its allocator, drops automatically, and lends references.
Reserve raw allocation/release for allocator and interop code. This does not
require converting arenas or every allocation into a box.

Tradeoff: more explicit `Option` handling at nullable APIs, and a significant
library migration. Benefit: fewer runtime nil checks, clearer release
responsibility, and an unused null representation available for compact
optionals. Non-nullness does not prove lifetime or exclusivity; those checks
remain necessary.

### Definite faults and unused results need dataflow

[Nil states](design.md#nil-states) currently inspect writes across the entire
body. This complete program compiled successfully to IR:

```odin
package main;
import "core:fmt";
main :: proc() {
    value := 42;
    p: ^int = nil;
    fmt.println(p^);  // certainly nil at this point
    p = &value;       // this later write suppresses the diagnostic
    fmt.println(p^);
}
```

**Proposal:** use flow-sensitive facts at each operation. Diagnose a proven
nil dereference/call, zero divisor, invalid fixed bound, or impossible checked
conversion on a reachable path. Refine facts after a guard and discard them
after writes or calls that can invalidate them. Unknown values still need
runtime checks; do not make acceptance depend on speculative optimization or
pretend arbitrary input can be proven valid.

The same principle applies to
[`require_results`](design.md#require_results). Today this compiles:

```odin
fail :: proc() -> Result(int, int) { return .err(1); }
main :: proc() {
    outcome := fail();
    _ = outcome;
    outcome = fail(); // this second result is never inspected or discarded
}
```

Track each produced required result, not whether its variable name was ever
read. An overwrite or scope exit with an unobserved result should be diagnosed;
an explicit discard consumes the obligation of that particular value. This
does not require proving that business logic handles every error correctly.

### Make mutable access explicit and permit compatible reads

[Slices](design.md#slices) are read-only under `:=`, but an expected `[]mut T`
can select mutable slicing. An adapter can also change the outcome:

```odin
read := a[:];             // read-only
view := a[:].indexed();   // can retain a mutable view
```

A probe confirmed that `read` is `[]int`, while `foreach (&value, index in
view)` mutates `a`. Destination-selected user slicing is an exception to the
otherwise valuable rule that destinations do not select overloads.

**Proposal:** `a[lo:hi]` always produces a read-only view. Request a writable
one explicitly through one spelling, for example `a.mut_slice(lo, hi)`.
The exact spelling is secondary; its meaning should survive adding a type
annotation or an adapter. Use the same rule for built-in and library containers.
An adapter preserves the capability it receives and never upgrades it.

Separately, adopt the relaxation discussed under
[Read-only reborrows](#read-only-reborrows-of-one-carrier-in-one-call): a live
read-only reborrow forbids writes and mutable reborrows, not another compatible
read. `slice.equal(xs, xs)` with `xs: []mut int` currently fails with `L0641`;
binding one read-only view first succeeds. Allow the direct form. Keep the
stronger exclusion while a mutable child borrow is live. These rules must also
apply through stored carriers, not only to two arguments of one call.

### Provide checked disjoint access

Two runtime slice ranges conservatively overlap. Creating `left := xs[:mid]`
and `right := xs[mid:]` as mutable slices is rejected even when they partition
one sequence; the first reborrow suspends `xs`. This makes sorting, partitioning,
matrix subviews, and parallel kernels harder to factor into safe helpers.

**Proposal:** add a narrowly specified `slice.split_at_mut(xs, mid)` returning
`(left: []mut T, right: []mut T)`, after one bounds check. The result paths
carry a checked disjointness relation, and the source remains suspended until
both are finished. Add a two-element counterpart only if a real algorithm
needs it; unequal runtime indices would be validated before lending them.

The compiler must understand the relation: a library wrapper alone cannot
recover information the analysis currently merges. A few such primitives are
smaller than a general theorem prover. Their intended acceptance tests should
also reject overlap, root reallocation, and retained loans beyond the source.

Related expressiveness limits are real but need different tools. A graph or
arena can use stable integer/generational handles without pervasive pointers.
A record owning a buffer and views into itself needs address stability and an
internal-borrow contract; non-null pointers do not solve it. Prefer offsets
and handles before introducing general pinning or self-referential types.

### Fallible insertion must accept resources

[Container insertion](design.md#container-insertion) allows moving a resource
into `append`, but `try_append`, `try_insert`, and `try_find_or_insert` copy
their inputs. `items.try_append(Token{1})` for a move-only `Token` is rejected
with `L0491`, even though the argument is a temporary. Reserving first and then
inserting is an existing workaround, but splits one logical operation into a
capacity protocol and does not generalize cleanly to arbitrary containers.

**Proposal:** add consuming fallible insertion. A representative API is:

```odin
// Proposed API: failure returns ownership of the uninserted value.
Insert_Failure :: struct($T: type) {
    cause: Allocator_Error,
    value: T,
}
// try_push(self: inout, value: move T)
//     -> Result(Unit, Insert_Failure(T))
```

On success the container owns the value. On failure the container is unchanged
and the error owns it. Cleanup drops it if the caller chooses not to retry.
The input binding is consumed on both paths; this is intentionally a different
contract from leaving that binding unchanged. Map insertion also needs explicit
key ownership and replacement semantics.

This makes failure atomicity compatible with move-only resources. First prove
this API on dynamic arrays and `Small_Array`, then decide whether to collapse
the broader [op/try_op pairs](#the-optry_op-pair). Do not delete all convenient
panic-on-OOM methods before callers have a concise replacement.

### One explicit arithmetic policy across scalar and vector code

[Integer overflow](design.md#integer-overflow) traps for signed scalar addition,
subtraction, multiplication, negation, and division, but signed SIMD arithmetic
wraps. Signed shifts and integer conversions also truncate. Replacing a scalar
kernel with SIMD can therefore change correctness at its boundary values.

**Proposal:** preserve checked signed operators as the default for scalars and
vectors, and provide named `wrapping_add`, `checked_add`, and, where needed,
`saturating_add` operations, with corresponding multiplication/conversion APIs.
The names here describe proposed APIs. Let vector implementations use native
wrapping instructions when wrapping was requested; checked vector operations
must detect an invalid lane and panic according to a specified rule.

Likewise make a narrowing integer conversion checked by default, retain
`math.to(T, value)` for recoverable exact conversion, and provide an explicit
truncating conversion for bit manipulation. Currently a runtime `int` of 300
converts to `u8` as 44, whereas the unfixed literal `u8(300)` is rejected. Both
behaviors were verified. Moving a value between a literal, a typed constant,
and a runtime variable should not silently select input-validation policy.

Checked arithmetic with an error result is particularly useful for parsers:
the illustrative `digits` in [config_parser](examples/config_parser.loke)
returns `Result` but accumulates with trapping signed arithmetic, so a long
digit sequence can terminate the process. The actual `strconv` integer parser
already checks for overflow; this is an ergonomic gap in expressing the same
operation, not evidence that all numeric parsing is unsafe.

### Performance opportunities and actual semantic limits

Fast programs are expressible: fixed contiguous arrays, slices, arena-backed
owners, monomorphized generics, static iteration, explicit moves, and
`Simd(T, N)` provide the necessary building blocks. However, no benchmark in
this review establishes that the current compiler achieves C-like performance.

| Area | Current consequence | Recommendation |
| --- | --- | --- |
| Bounds/nil/overflow checks | Observable failure constrains motion and speculation | Keep checks; eliminate those proved redundant and expose explicit arithmetic policies |
| Aliasing | Local exclusivity can help; unknown provenance and hidden effects limit what may be assumed | Repair effect holes first, then emit alias/memory attributes only where their precise obligations hold |
| Floating-point expressions | Unwritten FMA contraction and reassociation are forbidden | Add explicit `math.fma` and separately named reassociating reductions; keep default arithmetic strict |
| Ordered reductions | A floating SIMD sum is defined left to right | Retain the ordered form and offer an explicit unordered/tree reduction with documented numerical differences |
| Custom clone/drop and allocators | Calls may have observable effects or fail | Define which implicit copies may be elided; preserve explicit clone contracts |
| Dynamic interface dispatch | An unknown witness requires an indirect call | Prefer generic specialization in hot code; devirtualize when a concrete witness is known |
| Atomic string/shared accounting | Cross-thread sharing requires synchronization | Borrow views in hot paths; consider thread-local ownership only after measurement |
| Union representation | Fixed payload-plus-tag layout prevents general niche encoding | Give ordinary unions compiler-selected layout; explicit layout only where requested |

An unused representation, or niche, is a bit pattern no valid payload uses.
With non-null checked references, null could encode `Option(^T).none` without
another tag. The current Windows x64 compiler reports `size_of(^int) == 8`
and `size_of(Option(^int)) == 16`. This is a layout measurement, not a speed
measurement. Nullable `^T` cannot use the same encoding while preserving
`.some(nil)`, so the type and representation changes belong together.

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

### Callbacks and fallible loops deserve small conveniences

Two practical workflows are unnecessarily verbose:

- A stateful comparator or error mapper requires a nominal record plus an
  `impl call`, while ordinary procedures and callable records are not accepted
  uniformly by every callback API.
- A `Result(Option(T), E)` stream requires a loop, error propagation, and a
  switch even for the simple operation "read until the end". This is verbosity,
  not missing expressive power: `break` already exits the nearest loop through
  an enclosing switch, so code can continue afterwards without a helper.

For callbacks, first unify the existing callable-record convention in library
APIs. Then consider an explicit-capture procedure literal that lowers to that
same record and method. Captures should say whether they copy, borrow, or move;
escaping a borrowed capture must be checked, and creating a generic stack
callable should not imply heap allocation. Example *proposed syntax*:

```odin
less := proc [limit] (a, b: int) -> bool {
    return (a < limit) && !(b < limit);
};
slice.sort_by(values, less);
```

Specify mutable/consuming captures and callable result inference before making
this syntax normative. Owning runtime type erasure is a separate question;
most sorting and mapping callbacks do not need it. This refines
[Callable records, procedures, and closures](#callable-records-procedures-and-closures).

For streaming, reuse the existing shallow variant pattern in a conditional
header instead of adding a second fallibility protocol. Example *proposed
syntax*:

```odin
for (case .some(entry) = reader.next() or_return) {
    use(entry);
}
continue_after_stream();
```

The expression is evaluated once per step; a matching payload lives for the
body, a nonmatching variant ends the loop, and `or_return` handles errors in
the ordinary way. Borrowed entries must expire before the next call. An `if`
form can share the same rule. Do not add nested patterns, implicit error
conversion, and general comprehensions as prerequisites.

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

### Focused syntax and construction cleanup

Prefer changes that remove an ambiguity or semantic exception:

1. **One union matching form.** Keep `switch (value)` with branch-local
   `.some(payload)` patterns; consider removing `switch (payload in value)`.
   Grouped arms can inspect the original subject. This removes the grammar's
   special interpretation of a membership expression and its extra-parenthesis
   workaround.
2. **Use `mut` for mutable loop bindings.** A proposed `foreach (&mut value in
   items)` agrees with `&mut value` elsewhere. Today `&value` means a writable
   iteration binding but a read-only pointer in an expression.
3. **Payloadless variants need no dangling colon.** `union { none, some: T }`
   is an unambiguous proposed spelling. Keep enums for explicit numeric
   representations; eliminating enums would not eliminate that requirement.
4. **Use one pattern grammar where destructuring is supported.** Ordinary
   destructuring is flat but `foreach` nesting is recursive. Either support
   the same small nested pattern in bindings or explicitly keep this limited;
   do not grow several subtly different pattern languages.
5. **Consider a `default:` switch arm.** It names the intent more clearly than
   bare `case:`. This is a readability preference with lower value than the
   capability and matching changes.
6. **Protect important fields from silent zero fill.** Keep explicit `T{}`
   zero construction for zeroable types, but consider requiring named literals
   to supply every field unless a field declares a default. An opt-in
   constructor-only/no-default-initialization record is a smaller alternative.
   Zero being representable does not mean it satisfies a resource or domain
   invariant.

Keep the distinction between nominal structs and structural records: privacy,
hook ownership, and cross-package positional construction have real semantics.
Share their rules and implementation where possible instead of erasing the
distinction just to reduce the count of type forms. Likewise, retain named
record results rather than adding unnamed tuples without a demonstrated need.

There is no compelling reason here to remove `defer`, semicolons, parenthesized
control-flow headers, explicit overload groups, or hermetic compile-time
evaluation. `defer` still expresses rollback/restoration and other scoped side
effects. Requiring a custom resource type for each is more ceremony. Keep
compile-time file I/O out; an explicit build input mechanism would be easier to
make reproducible than ambient filesystem access. Package headers should be
generated documentation or checked API manifests, not a second manually
maintained declaration source by default.

### Specification consistency and validation

One normative inconsistency was found: [grammar Types](grammar.md#types) limits
`Type_Name` to one selector and says associated selectors do not chain, while
[Iteration protocol](design.md#iteration-protocol) explicitly uses
`S.Iterator.Item`. The rebuilt compiler accepts the chained type in this
complete probe:

```odin
package main;
import "base:interfaces";
first :: proc(values: $S) -> Option(S.Iterator.Item)
    where interfaces.Iterable(S) {
    iterator := values.iter();
    return iterator.next();
}
main :: proc() { _ = first(0..<2); }
```

Resolve the document conflict deliberately, preferably in favor of ordinary
chained associated types, and add a grammar regression with that decision.
Do not advertise this as a missing compiler feature: the probe already works.

Validation performed for this review:

- Rebuilt `lokec.exe` from the workspace with Odin's unused/shadowing vet flags.
- Compiled the nil, uninitialized-read, implicit-hook, invalid initialized-count,
  overwritten-result, and chained-associated-type probes to LLVM IR. The
  potentially invalid memory programs were not executed.
- Confirmed rejection of repeated read reborrows, simultaneous mutable split
  slices, and fallible insertion of a move-only temporary.
- Built and ran the slice-capability and pointer-layout/conversion probes.
  Observed 8/16-byte pointer/optional sizes and wrapping runtime conversions.
  Confirmed that the corresponding out-of-range unfixed literal conversions
  are rejected.
- Built and ran the existing last-use-transfer example and observed its
  copy-hook and cleanup trace.
- Ran the specification citation checker, checked local file links in the
  edited documents, and ran `git diff --check`; all passed.

These are focused design checks, not the complete integration suite, and no
optimization-speed or allocation-count measurements were taken. Apart from
the grammar/document conflict above, the highlighted accepted/rejected cases
follow the current specification. They are proposed changes to its promises,
not claimed fixes to undocumented compiler behavior.

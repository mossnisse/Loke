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

- A Ctrl+letter key arrives as `.Character` with the control character in
  `value` (Ctrl+C is `3`, with `control` set), because that is what the console
  reports. Some libraries report the letter instead and leave the control
  character to the flag. standard-library.md does not say which one `value`
  holds.
- Every console test writes records into the console the test run is using,
  because Windows 10 cannot allocate a hidden console. Anything typed into that
  console while `tests/run/lib_term_console` runs is read along with the
  records it wrote.
- `core:fmt` writes standard output through the C library's text-mode stream,
  so every `\n` it prints reaches the handle as `\r\n`. `term.stdout()` writes
  the bytes it is given, so a program using both sends mixed line endings down
  one redirected stream, and `fmt` cannot print a bare `\n` at all. Should
  standard output be binary for both, as Odin's is, or text for both?

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
- **Query walkers are partial.** The main passes switch over `Expr`
  exhaustively, but the smaller walkers that ask one question of a subtree
  (`first_unresolved_name`, `type_syntax_names`, `pattern_shape`, and the
  like) each recurse through a `#partial switch` of their own, so a form one of
  them forgets is skipped silently, as `first_unresolved_name` skipped slices,
  ranges, `or_else`, and `.(T)` until the review;
  default checking now collects parsed `Type_Poly` names through
  `pattern_shape`, after a raw-source scan let comments change acceptance. That
  bug is fixed; should the remaining queries recurse through one exhaustive child
  enumeration?
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

## Open checker-fuzzer findings

The checker fuzzer (`tests/checker_fuzz_test.odin`) found these with
`LOKE_FUZZ_SEED=1 LOKE_FUZZ_MUTANTS=10`. They break no rule of the
specification, so they are not in [known-gaps.md](known-gaps.md), but each
fails one of the fuzzer's checks under some seed.

- **A copyable fixed array with a `hook(copy)` element compiles in quadratic
  time.** `arr := [N]Value{Value{1}};`, where `Value` has a copy hook, takes
  2.4 s at N = 1024 and 9.4 s at N = 2048; without the hook, N = 65536 takes
  2 s. The fuzzer reports it as a hang at N = 65536.
- **Errors in a generic record's field type repeat and cascade.** For
  `Sized :: struct($V: [2]int) { items: [V[18446744073709551616]]int }`
  and two instances, each reports `L0352` followed by `L0361` for the same
  unrepresentable constant. The primary error has no "while instantiating"
  note; only the cascade identifies the instance, using `Sized({0,1:1,1:9})`
  rather than `Sized([2]int{1, 9})`.

## Open generics findings

A review of the generics implementation left these open. None breaks a rule of
the specification as written.

- **Generic arguments print badly in diagnostics.** A floating argument prints
  its bits (`Tag(f64:8000000000000000)`), an aggregate prints its cache key (see
  the fuzzer finding above), an argument with no type prints `f(<invalid>)`
  under a misleading "`$T` is not bound here", and the instantiation-limit
  error (`L0436`) prints every nested type in full on each of its notes, so
  `deep([1]T{x})` spells `[1]` 64 times per line.

## Found by writing the tutorials

Writing [tutorials/](tutorials/README.md) raised this remaining question, besides
the ones since fixed.

- **Two slices of one local array in one call.** `fmt.println(primes[1:4],
  total(primes[:]))` is rejected (`L0511`): slicing a mutable local gives
  `[]mut int`, which keeps that type inside the `any_view`, so the second slice
  conflicts with it. That follows design.md "Slices", and an extracted
  `[]mut int` could indeed write. But a reader who only prints has to write
  `middle := primes[1:4];` first, as in
  [Arrays and slices](tutorials/04-strings-and-containers.md#arrays-and-slices).
  Erasing a fresh slice into an
  `any_view` could settle it read-only, as a `[]T` destination does, but that
  would make an erased slice's type depend on where it lands. The rule stays:
  one extra binding is a small price for a slice type that does not change.

## Formatting

The current formatter rules and rationale are in [comments.md "Formatting"](comments.md#formatting).

Open: aligning columns automatically, as `gofmt` does, so a renamed field
does not leave its neighbours misaligned; and indenting a continued line
inside brackets, which `core/` leaves at the bracket's level.

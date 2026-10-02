# Open questions

Decisions that are deliberately not yet made are recorded here rather than left implicit in normative prose. [`design.md`](design.md) defines the rules implementations must follow for the current language version; these questions concern possible later changes.

Design rationale and differences from Odin are recorded in [comments.md](comments.md).

## Exponential support queries on recursive type graphs

Unresolved review finding in [src/semantic.odin](src/semantic.odin):
`type_is_supported_depth` expands recursive types as a tree until its depth
limit, revisiting each shared pointer and record for every field. A small,
valid graph therefore asks exponentially many identical questions:

```odin
package main;
Node :: struct { a, b, c, d: ^Node }
main :: proc() {}
```

On 2026-10-02, a fresh development build compiling this file with `-emit-ll`
had not completed after 20 seconds and was terminated. The one-pointer
version compiled in about 43 milliseconds. An isolated query over an
equivalent semantic graph measured:

| Recursive pointer fields | Time for one `type_is_supported` call |
| --- | --- |
| 1 | 29 microseconds |
| 2 | 7.7 milliseconds |
| 3 | 3.38 seconds |

Track visited type identities and memoize results within each query, as the
type-ID sort-key walk already does. A depth limit alone bounds nesting but
does not bound repeated work. Per-query state avoids caching answers while
record fields are still resolving.

## Comparison queries recurse into diagnosed value cycles

Unresolved review finding in [src/semantic.odin](src/semantic.odin):
`type_is_comparable` recursively follows aggregate fields without checking
for cycles or the finite-size pass's `.Cyclic` result. The checker continues
checking procedure bodies after diagnosing an invalid record, so the
comparison in this malformed program overflows the compiler's stack:

```odin
package main;
Node :: struct { self: Node }
equal :: proc(a, b: Node) -> bool { return a == b; }
main :: proc() {}
```

A fresh development build exits with Windows status `0xC00000FD`
(`-1073741571`), without printing the diagnostic. Replacing `a == b` with
`true` reports the ordinary `L0364` value-cycle error and exits 1. Reject a
known cyclic aggregate, or guard the comparison walk by type identity, so
checking an already invalid type cannot crash the compiler.

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

## Platform selection in `core:thread`

[standard-library.md](standard-library.md) says every platform call sits behind
a `when (LOKE_OS == ...)`, and `core:fs`, `core:os`, `core:path`,
`core:process`, and `core:term` follow it. `core:thread` declares its Windows
implementation directly. Should it gain the `when`, or should the convention let
a package with one target skip it?

## Review cleanup in `cfg_provenance.odin`

The correctness findings and reproductions are in
[known-gaps.md](known-gaps.md). The remaining recommendations concern
[src/cfg_provenance.odin](src/cfg_provenance.odin):

- Remove the repeated `level < .Stored` guard in `prov_call_retention`;
  the earlier guard already excludes it. Resolve the procedure type's info
  once in that helper.
- Keep graph construction's mutation contract accurate. The construction
  comment says the typed AST is never written, but `prov_owner_view` and
  `walk_flow_expr_erased` temporarily change and restore conversion fields and
  expression types. Prefer passing the source type into the walk when that
  code changes, or explicitly document this temporary exception in
  [compiler-architecture.md "Disposable control-flow graphs"](compiler-architecture.md#disposable-control-flow-graphs).
- Give `prov_call` visible phase boundaries using small helpers for builtin
  calls and argument preparation, following its existing `prov_text_call`
  pattern. Its current dispatch, evaluation, borrow creation, and effect
  application occupy one procedure of roughly 360 lines.
- Keep comments explaining return holds across cleanup, capability weakening,
  provider tokens, summary fixed points, and lifecycle's reset facts. Remove
  comments that only repeat helper names, such as the case payload and
  destructured field wrappers.

## Review cleanup in `check.odin`

The confirmed specification divergences and reproductions are in
[known-gaps.md](known-gaps.md). The remaining recommendations concern
[src/check.odin](src/check.odin):

- Keep the existing sections, `Checker_Location`, and `Body_Context` save/restore
  units. Share signature guards between named and anonymous procedures, and
  declaration validation between ordinary and destructured initialization.
  Small shared checks address the divergent paths; another checker abstraction
  or a file split by size is unnecessary.
- Replace `field_initialized_attribute` with the existing
  `find_attribute(attributes, "initialized")`. Remove the empty `!evaluated`
  branch in `resolve_enum_members` by checking `evaluated` positively.
- Correct the receiver comment after `resolve_proc_signature`: `self: ^T`
  can be a receiver; `self: ^mut T` is the excluded form. Replace
  `report_unresolved_type`'s claim that `resolve_type_syntax` reports nothing:
  several resolution paths do report diagnostics.
- Remove obvious helper synopses, such as `check_proc_body`'s, and shorten the
  failed-initializer comment to why an erroneous initializer cannot be
  evaluated. Keep comments about partial record resolution, store reacquisition,
  selection phases, and body-context restoration. Replace generic `design.md:`
  references with exact section headings, as required by [AGENTS.md](AGENTS.md).

Three consistency questions remain:

- **Foreign bindings and exported definitions use separate symbol tables.**
  `check_exports` checks exports against exports and foreign bindings against
  foreign bindings, without comparing the two sets:

  ```odin
  package main;
  foreign import system "system:kernel32.lib";
  foreign system {
      @(link_name="answer") other :: proc() -> f64 ---;
  }
  @(export) answer :: proc "c" () -> i32 { return 7; }
  main :: proc() { _ = other(); }
  ```

  This compiles and emits `define i32 @answer()` with `call double @answer()`.
  Matching signatures compile; two incompatible foreign bindings for the same
  name report L0600. Should compatible foreign bindings resolve to an exported
  definition, with incompatible ones rejected in the same whole-program pass?
  [design.md "@(export)"](design.md#export) and
  [design.md "Foreign system"](design.md#foreign-system) should specify this
  boundary.
- **Variadic position is enforced only on named declarations.**
  `bad: proc(nums: ..int, tail: int);` is accepted, while
  `bad :: proc(nums: ..int, tail: int) {}` reports L0574. The existing
  [variadic shape regression](tests/err/m6a_variadic_shape.loke) states the
  intended trailing-only rule, but
  [design.md "Variadic parameters"](design.md#variadic-parameters) and
  [grammar.md "Procedures"](grammar.md#procedures) do not state it explicitly.
  Specify the restriction and reuse the declaration check for procedure types.
- **Field visibility conflicts differ from declaration conflicts.**
  `field_is_public` accepts a field with `@(public, private)` as public, while
  `declaration_is_public` reports L0332 for that combination. Both attributes
  apply to fields under [design.md "Attributes"](design.md#attributes).
  Clarify the conflict rule and share its validation.

## Review cleanup in `check_expr.odin`

The new correctness findings and reproductions are in
[known-gaps.md](known-gaps.md). The existing anonymous-procedure signature
finding from the `check.odin` review also applies here. Recommendations for
[src/check_expr.odin](src/check_expr.odin):

- Keep the current feature sections and the `select_field`/`inherit_capability`
  split. Reuse `materialize_value_expr` for SIMD lane validation and
  `index_arguments`' candidate context for slicing. Share the packed-storage
  check with slicing and its existing borrow callers; no general conversion
  abstraction is needed.
- Delete the misplaced expected-type comment above `Expr_Position`. Correct
  `promoted_field_path`'s "same level" claim: competing promotion routes are
  ambiguous even at different depths, under
  [design.md "Promoted struct fields"](design.md#promoted-struct-fields).
- Describe `materialize` briefly as recording implicit conversions for the
  emitter and provenance walker. Its current "untyped node" description misses
  typed views, erasure, and splats. Correct the `convert_const` comment when
  repairing float-to-integer conversion; an exact implicit conversion is still
  forbidden. Remove the stale "M2" and "M4" stage labels.
- Shorten `select_slicers`' comment to why expected capability filters
  candidates before ranking. Explain packed ancestry in terms of alignment
  within the same storage, rather than "anywhere in the selector chain".
  Keep the contextual comments about materialized constants, interface
  diagnostics, evaluator budgets, and `zero_const(build=false)`.
- Update shift-count comments to the current
  [design.md "Arithmetic operators"](design.md#arithmetic-operators) rule:
  typed signed counts are accepted and read as unsigned. Replace generic
  `design.md` references with exact headings, as [AGENTS.md](AGENTS.md) requires.

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

## Repeated parsing of procedure-literal arguments

Unresolved parser finding: `parse_argument_value` in
[src/parser.odin](src/parser.odin) parses a complete procedure literal as a
type probe, rewinds the token position, and parses that literal again as an
expression. Each nested procedure-literal argument repeats the process in
both passes, so time and syntax-arena allocations grow exponentially. The
discarded probe nodes remain in the syntax arena. The nesting guard does not
bound this repeated work.

The following generates a roughly 330-byte file that exercises only parsing:

```powershell
$body = 'sink();'
for ($level = 0; $level -lt 16; $level += 1) {
    $body = 'sink(proc() { ' + $body + ' });'
}
$source = 'package main; main :: proc() { ' + $body + ' }'
New-Item -ItemType Directory -Path tests/tmp -Force | Out-Null
Set-Content -LiteralPath tests/tmp/parser-probe.loke -Value $source -Encoding ASCII
.\lokec.exe tests/tmp/parser-probe.loke -parse-only
```

An in-process probe measured `File.arena.total_used` on 2026-10-02:

| Nested arguments | Source bytes | Syntax-arena bytes |
| --- | --- | --- |
| 8 | 184 | 924,240 |
| 12 | 256 | 14,809,680 |
| 16 | 328 | 236,976,720 |

Each additional four levels costs about sixteen times as much storage.
Parenthesizing every argument, `sink((proc() { ... }));`, avoids the type
probe and uses only 35,696 syntax-arena bytes at 16 levels. The byte counts
above exclude the file's trailing newline. The original 18-level form also
parsed successfully but took about 1.7 seconds for a 364-byte source.

Reuse the parsed primary when continuing through postfix expressions, so
the procedure body is parsed once. Reclaiming probe allocations alone would
leave the exponential execution time.

## Held diagnostics in the front-end test helper

`check_one_package` in [src/front_end_test.odin](src/front_end_test.odin) stops
after `check_package_bodies`. Unlike the production pipeline, it does not
release diagnostics held while a compile-time call checks a procedure body.
Consequently, tests using `check_source` or `check_parsed` can observe zero
errors for a program the normal compiler rejects. This affects the diagnostic
commitment contract under
[compiler-architecture.md "Checking and overload resolution"](compiler-architecture.md#checking-and-overload-resolution).

The following regression, placed in a compiler unit-test file, currently fails:

```odin
package lokec
import "core:testing"

@(test)
held_body_errors_reach_frontend_assertions :: proc(t: ^testing.T) {
    p: Checked
    defer destroy_checked(&p)
    check_source(&p, `package main;
candidate :: proc(value: $T) -> int where calculate() { return 1; }
fallback :: proc(value: int) -> int { return 2; }
choose :: proc{candidate, fallback};
main :: proc() { _ = choose(1); }
calculate :: proc() -> bool {
    if (false) { x := 1; y := move(x); _ = x; }
    return true;
}
`)
    testing.expect(t, p.c.error_count == 1)
}
```

Confirmed on 2026-10-02: after `check_source`, `error_count` and the visible
diagnostic count are both zero, while `held_diagnostics` contains one `L0500`.
Calling `release_held_diagnostics` changes the error count to one. A compiler
built from the same source rejects the Loke fixture with `L0500` and exits 1.
The concrete overload succeeds after the generic bound is rejected, so the
bound's rolled-back diagnostics do not independently fail the fixture.

Release held diagnostics at the helper's completed checking boundary, with
this regression retained. The helper deliberately omits whole-program
analysis; tests needing provenance results should continue to invoke that
analysis explicitly. All 57 existing tests in `front_end_test.odin` pass with
memory tracking and the repository's vet checks enabled, so their current
fixtures do not expose the missing diagnostic release.

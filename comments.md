# Open questions

Decisions that are deliberately not yet made are recorded here rather than left implicit in normative prose. [`design.md`](design.md) defines the rules implementations must follow for the current language version; these questions concern possible later changes.

## Tutorial review resolution

The 2026-09-29 review assumed readers already know another programming language.
Its eight follow-ups are resolved: the tutorials shorten basic control-flow
explanations, introduce pointer and slice mutation, distinguish runes from
grapheme clusters, and qualify panic cleanup and generic type inference.
The time parser rejects negative components. The command-line example checks
both running totals before printing and uses space-separated output without a
category-width limit. Regression examples live in the tutorial pages and run
through `tutorials_compile_and_run`; the language rules did not change.

## Tutorial learning progression

The follow-up pedagogical review on 2026-09-29 led to a fifteen-lesson
[reading order](tutorials/README.md). The first seven pages reach a working
command-line tool before introducing generics and dynamic dispatch. Later
lessons cover borrowing, compile-time execution, local allocators, resource
ownership, C calls, default providers, and reflection. Custom formatting now
follows those foundations instead of appearing in the first methods example.

Each lesson uses complete, checked examples and explains their constraints.
Learning exercises were explicitly excluded by the user; the earlier exercise
suggestion and the command-line page's exercises are removed. Runtime tests
verify examples, not learning outcomes.

The provider lesson selects a built-in arena with process-lifetime storage.
Implementing a new allocation algorithm currently requires the runtime ABI,
so it links the authoritative header and explains the callback obligations
instead of teaching a duplicate ABI declaration as ordinary Loke code.

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

The allocation built-ins are a third instance, and they keep the pair: `new`/`try_new`, `new_clone`/`try_new_clone`, and `make`/`try_make` (see [The allocation built-ins follow the `try_` convention](#the-allocation-built-ins-follow-the-try_-convention)).

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
and [One result](#one-result-and-the-compatibility-break-that-came-with-it)
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

## Implementation blocks

Should methods be written in a separate `impl` block or inside a struct? If they
are written inside structs, how should methods on other kinds of types work?
`impl` blocks were chosen partly because they extend to `distinct` types,
enums, and generic instantiations without a second syntax, but the cost is that
a type's data and its behavior are declared apart.

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

- An environment name that is empty or contains `=` fails `set_environment`
  and `unset_environment` as `Other` (Windows error 87), while
  `get_environment` answers `.none` for it. Should the portable layer reject
  such names as `Invalid_Data` on every call, as POSIX `setenv` does?
- `from_last_error` is written three times, in `core:os`, `core:fs`, and
  `core:term`, with different tables. `core:os` maps less: error 161 is
  `Invalid_Path` from `fs` but `Other` from `os`, and 267 (a file given as the
  new working directory) is `Other` in both.

## Open questions in `core:path`

- `path.volume("\\?\UNC\server\share\x")` is `\\?\UNC`, not
  `\\?\UNC\server\share`, so `fs.create_directories` on such a path tries to
  create `\\?\UNC\server` and fails. `clean` already declines extended-length
  paths. Should `volume` understand `\\?\UNC\`, or should extended-length paths
  be documented as unsupported by the walking operations?

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
- A high surrogate that is not followed by a low one is dropped from `read_key`,
  while `read_line` answers `Invalid_Data` for the same units. A keyboard cannot
  send one, but a program writing console input can. Should it be U+FFFD?
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

- **Hypothetical checks are a counter, not a boundary.** A probe runs the
  ordinary checker with `speculation_depth` raised, each registry that must not
  remember the probe checks the counter itself, and rollback removes only
  diagnostics. Enrollments reached from a procedure literal inside a probe have
  missed the check four times: hoisting, `checked_bodies`, static locals, and
  contributed lifecycle members (all fixed; `probe_emission_state` in
  `src/front_end_test.odin` probes such a literal and counts each registry,
  `synth_procs` included). `begin_probe`/`end_probe`
  now pair the depth with the rollback, but the silent probe in
  `build_generic_candidate` still truncates diagnostics at depth zero, which
  compiler-architecture.md "Checking and overload resolution" rules out: its
  instance is cached for every later call, so running it inside a probe would
  drop what a signature that holds records. A generic record instance is cached
  the same way, and one first made where its field errors will be rolled back
  was left looking valid; it is now rejected with its head diagnostic
  (`diagnostics_provisional` in `src/generic.odin`), as a silently rejected
  signature is. Should
  registry writes made under speculation be journaled and rolled back with the
  diagnostics, or should a probe stop before body-level work?
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
- **Positional flags are saved by hand.** The body context is one
  `Body_Context` record, replaced and restored whole, but `in_callee`,
  `place_position`, and `insert_position` are still set before a `check_expr`
  and restored at each site that needs them. Passed as parameters, they would
  leave nothing to restore.
- **Query walkers are partial.** The main passes switch over `Expr`
  exhaustively, but the smaller walkers that ask one question of a subtree
  (`first_unresolved_name`, `type_syntax_names`, `pattern_shape`, and the
  like) each recurse through a `#partial switch` of their own, so a form one of
  them forgets is skipped silently, as `first_unresolved_name` skipped slices,
  ranges, `or_else`, and `.(T)` until the review;
  default checking now collects parsed `Type_Poly` names through
  `pattern_shape`, after a raw-source scan let comments change acceptance (A2
  below). Should the remaining queries recurse through one exhaustive child
  enumeration?
- **The runtime ABI is written twice.** `runtime/loke_rt.h` and the `declare`
  lines in `emit_llvm_runtime.odin` are kept in step by hand. With opaque
  pointers a mismatched parameter list is a silent miscompile, not a link error.
  Generate one from the other, or compare them in a test?

## Compiler architecture audit (2026-09-28)

Reviewed revision `b2cc712`. This is a source-wide structural inventory and a
targeted trace of the driver, checking/CTFE/generics, ownership/provenance,
semantic finalization, LLVM emission, runtime interface, and test/build
harnesses. It is not a proof of every language rule or a full audit of the C
runtime. The implementation guide remains
[compiler-architecture.md](compiler-architecture.md).

The architecture fits the current whole-program Windows x64 compiler. Stable
IDs, arena ownership, one annotated AST, explicit call operations, shared
constant operations, and a separate toolchain layer are useful decisions.
The main weakness is that the documented phase contracts are stronger than
their enforcement. Several consumers still complete semantic state, and
several temporary states depend on every caller remembering the same rules.
Strengthening those boundaries has a clearer benefit than adding another IR
or splitting the whole compiler into Odin packages.

The inventory contains 81 production Odin files and 64,235 physical lines,
including comments and blank lines, plus six unit-test files. A declaration
scan found 2,189 production procedures, of which 1,194 are file-private.
`Compiler` has 107 fields. These are navigation and coupling indicators, not
defect counts. In particular, the large exhaustive dispatches in the parser,
checker, clone operation, and backend are not automatically abstractions to
replace.

| Area | Assessment |
| --- | --- |
| Source, parsing, AST | Explicit error nodes, spans, nesting limits, and clone-field classification give a sound foundation. Small semantic queries still use independent partial walks; the raw-source binding scanner found here was removed in A2. |
| Checker and language features | Central overload ranking and recorded `Call_Operation` variants avoid backend resolution. Positional state and speculative mutation remain distributed across callers. |
| Generics and CTFE | Definition-site scopes, syntax cloning, and shared constant operations are appropriate. Instance caching, diagnostic rollback, and eager member installation have different commitment rules. |
| Ownership and provenance | The finite dataflow analyses and dependency worklist are substantial strengths. Rebuilt graphs, retained iteration storage, and cleanup identities carry hidden coupling. |
| LLVM emission | The file split follows responsibilities and the backend has useful negative tests. Its claimed read-only semantic boundary is currently violated on an ordinary program. |
| Runtime and toolchain | The versioned C interface and artifact/process separation are appropriate. ABI declarations and runtime-cache identity need stronger validation. |
| Verification | The corpus covers success, errors, traps, LLVM validity, layout, C hosts, packages, examples, and tutorials. Some architecture tests exercise only part of the real pipeline. |

The following priorities distinguish observed failures from structural risks.
P1 is the first reliability issue to address; P2 is focused corrective work.
Previously recorded findings are explicitly identified, rather than counted
as new discoveries.

### A1 — resolved: Constant construction bypassed the evaluator's resource bounds

**Existing defect; allocation paths rechecked.** The large-array failures
then recorded in [known-gaps.md](known-gaps.md) were an architectural problem:
the bounded interpreter is only one way the compiler constructs constants.
`check_array_literal` builds a full-length expression vector and passes it to
`fold_aggregate`; `zero_const` and `capacity_const` likewise allocate
`info.count` constant elements directly in semantic storage, all in
[src/check_expr.odin](src/check_expr.odin). Those paths do not pass through
`eval_elements` or the 64 MB scratch budget in [src/eval.odin](src/eval.odin).

Consequently, the compiler can exhaust memory or spend unbounded time before
the evaluator's safeguards apply. A layout-size limit alone also does not
bound the much larger host representation of each constant element. The
documented billion-element crash and maximal-array hang were not rerun during
this audit.

**Next change:** validate array layout before materialization, check allocation
failure, and place a checked construction limit at the shared aggregate
construction boundary. Dense constants that are mostly zero should eventually
retain a zero/repeat representation instead of manufacturing one host object
per element. Keep this focused on real constant constructors, not a new
compiler-wide allocator framework. Verify both direct literals and evaluated
equivalents, and preserve the existing reproduction until fixed.

**Fixed:** `const_element_count` measures the constants a value is built from,
through arrays and struct fields, and `MAX_CONST_ELEMENTS` holds it to the
evaluator's 64 MB (`EVAL_MAX_MEMORY` over `size_of(Const_Value)`).
`fold_aggregate` and a building `zero_const` refuse past it, so the literal is
not a constant: at run time it is built into memory, and where a constant is
required the evaluator runs instead and reports `L0342`. An array literal keeps
only its written elements. The backend writes a zero with `llvm_zero` as
`zeroinitializer`, asking `zero_const` only whether one exists, since design.md
"Zero values" makes every zero all-zero bits; a 16 MB zeroed global fell from
44 s to 0.05 s. A variable's declared type and a composite literal's type now
request their layout, so an oversized one is `L0364` where it is written.
[tests/err/large_constant_arrays.loke](tests/err/large_constant_arrays.loke),
[tests/ll/large_arrays.loke](tests/ll/large_arrays.loke), and
[tests/run/large_literal_runtime.loke](tests/run/large_literal_runtime.loke)
cover the three reproductions, a direct literal and its evaluated equivalent,
and a struct literal built at run time.

Two costs remain. A literal past the bound is built like one with non-constant
elements, in a stack temporary, so `g = [2000000]u8{7};` into a global
overflows the default 1 MB stack where it used to be copied from a folded
module constant; a large value built in place of its destination would fix
that and the non-constant case together. Below the bound, a literal is still
folded, and emitted, one element at a time; a zero/repeat representation would
make that cost follow what the literal writes.

### A2 — resolved: Semantic binding was rediscovered from raw source text

**New correctness reproduction of a previously recorded structural concern.**
`declare_poly_stand_ins` in [src/generic.odin](src/generic.odin) scanned a type's
source span for `$name`, skipping literals but not comments. The audit
confirmed that the following unused procedure was accepted:

```odin
package main;
f :: proc(x: ^/* $Missing */$T, $N: int = Missing) {}
main :: proc() {}
```

Removing only the comment changed compilation from exit 0 to exit 1 with
`L0315`. The scanner created a fictitious parameter, so
`check_independent_poly_defaults` treated an erroneous independent default as
dependent, contrary to [design.md "Default values"](design.md#default-values).

**Fixed:** the source scanner was deleted. Default checking now collects actual
`Type_Poly` bindings through the existing `pattern_shape` traversal, preserving
the same pattern forms that inference recognizes. Regression cases in
[tests/err/poly_default_comments.loke](tests/err/poly_default_comments.loke)
cover block, line, and nested comments and a fictitious binding shadowing a
constant. [tests/run/poly_default_binding.loke](tests/run/poly_default_binding.loke)
covers quotes in comments and dependent defaults through pointers, arrays,
maps/slices, generic applications, and procedure parameter/result types.

The broader traversal concern remains: `first_unresolved_name`,
`type_syntax_names`, and `pattern_shape` still implement their own partial
syntax walks in [src/select.odin](src/select.odin),
[src/erased.odin](src/erased.odin), and [src/generic.odin](src/generic.odin).
Use a small exhaustive child enumeration where these queries really share
traversal; preserve their different stopping and binding rules. Evaluation,
checking, and control-flow construction need their own traversal semantics.
Verification should include comments inside types, nested type forms, and
defaults that genuinely depend on an earlier parameter.

### A3 — resolved: LLVM emission created semantic symbols

**New, reproduced on the ordinary production pipeline.**
[compiler-architecture.md "LLVM and toolchain"](compiler-architecture.md#llvm-and-toolchain)
says that `emit_llvm_module` creates no types or symbols and only mutates the
layout cache. However, `define_struct` in
[src/emit_llvm_abi.odin](src/emit_llvm_abi.odin) calls
`ensure_any_view_fields`, which calls `new_field` twice and writes
`Type_Info.fields` and `backend_label` in [src/erased.odin](src/erased.odin).

A temporary in-package probe compiled `package main; main :: proc() {}` with
`compile_program`, validated its entry and exports, and ran
`finalize_semantics`. The subsequent successful `emit_llvm_module` changed
the symbol count from **206 to 208** and `any_view`'s field count from **0 to
2**. No malformed state was injected for this observation.

This is a phase-contract violation, not a demonstrated wrong executable.
The current layering checks cannot catch it: the emitter calls a semantic
helper that performs the writes without naming `Checker`. The layout helper
also has `ensure_*_fields` calls, so checking only direct backend calls would
leave another route.

**Next change:** install carrier fields during semantic initialization or
finalization, then make emitter access validate and consume them. Add a
before/after semantic-state assertion around emission, allowing the documented
layout cache and diagnostics but excluding new symbols, types, members, or
registry entries. Repeated identical IR alone is insufficient: the first
emission can repair state and all later emissions can agree.

**Fixed:** slices and containers already install their fields when interned;
`finalize_semantics` now installs `any_view`'s, and `define_struct` no longer
calls either installer. `validate_emission_dependencies` requires every
carrier's fields, so the installers that layout and `zero_const` still reach
during emission find nothing to do. `emit_llvm_module` compares
`semantic_extent` (symbols, types, instances, synthesized procedures,
witnesses, materialized constants, typeids, formatters, lifecycle records, and
key and ordering policies) before and after, and fails emission when it grew.
Every emitting test and corpus program now runs under that check; the
`carrier` case of `emission_rejects_incomplete_registries` covers missing
fields.

### A4 — resolved: The emission validator did not establish phase completion

**New, reproduced with deliberate state probes.**
`validate_emission_dependencies` in
[src/emission_contract.odin](src/emission_contract.odin) checks existing
formatter entries but never requires `formatters_ready`; an empty unfinished
registry passes. It checks `error_count` but not `held_diagnostics`, whose
errors are deliberately excluded from that count. After compiling and
finalizing the minimal program, the audit independently observed:

```text
formatters_ready = false                         -> validation succeeds
one held error, error_count = 0                  -> validation succeeds
```

The normal driver currently discovers formatters and releases held
diagnostics in the correct order. These probes demonstrate missing boundary
guards, not acceptance of either state through the current CLI. There is also
no completion fact for the entire provenance/contract analysis. The
`check_for_emission` unit-test fixture in
[src/emit_llvm_test.odin](src/emit_llvm_test.odin) checks bodies and the entry
but omits the whole-program provenance stage and held-diagnostic release.
Thus successful emission tests do not all establish the production preconditions.

**Next change:** reject unfinished formatter discovery and pending held
diagnostics; record and require completion of the whole-program semantic
analyses at the checked-program boundary. Let ordinary emission fixtures run
those stages, while tests of low-level emitter helpers can construct their
explicit smaller inputs. Add negative tests for the missing completion facts.
One clear readiness contract is enough; separate wrapper types for every
pipeline phase would add little here.

**Fixed:** `finish_program_analysis` runs the whole-program provenance and
provider analyses and releases held diagnostics, then records
`program_analyzed`; `compile_program` and the `check_for_emission` fixture
both call it, so emission tests now run the production tail. The validator
rejects a missing `program_analyzed`, an unfinished `formatters_ready`, and any
held diagnostic. `emission_rejects_incomplete_registries` has a negative case
for each.

### A5 — resolved: Speculation had multiple commitment policies

**Existing concern, confirmed in the current call path.**
`begin_probe`/`end_probe` pair a counter with diagnostic rollback in
[src/source.odin](src/source.odin), but do not undo semantic mutations.
`build_generic_candidate` in [src/overload.odin](src/overload.odin) calls
`instantiate_generic(..., report = false)` without opening that boundary.
A rejected signature can then truncate diagnostics at depth zero while its
instance stays cached. `diagnostics_provisional` separately scans silent
instantiation frames. CTFE's `ensure_proc_typed_for_eval` adds a third policy:
temporarily commit at depth zero and hold the resulting diagnostics aside.

These rules explain why adding one counter check at a new enrollment site is
not a complete fix. They also conflict with the implementation guide's blanket
statement that all diagnostic truncation occurs under speculation. The
previously fixed enrollment bugs and `probe_emission_state` test are documented
under [Open questions in the compiler's structure](#open-questions-in-the-compilers-structure).

**Next change:** make signature-cache commitment explicit and distinct from
runtime dependency enrollment. Keep rollback ownership next to the operation
that can reject a candidate, and centralize the few enrollment operations
instead of adding more scattered counter tests. Preserve CTFE's intentional
body commitment and diagnostics. Test rejected candidates followed by selected
uses in both orders, with lifecycle contributions, attributes, and defaults.
A general mutation journal should wait until these narrower rules prove
insufficient.

**Changed:** no wrong result could be reproduced. Probe-then-use in both orders,
with a rejected signature, a default only valid for some `T`, a clone
contribution through a bound-rejected candidate, and `@(require_results)`, all
behaved, because a silent rejection keeps its head diagnostic for the next
reporting request. The structural fix the finding asks for is done: a silent
`instantiate_generic` now opens a probe itself, so the rollback belongs to the
operation that rejects, every checker truncation happens under speculation as
compiler-architecture.md says, and a silently resolved signature is cached
without enrolling anything; enrollment waits for `promote_generic_instance`.
CTFE's depth-zero body commitment is unchanged, which is why
`diagnostics_provisional` still asks the instantiation frames.
[tests/run/generic_probe_then_use.loke](tests/run/generic_probe_then_use.loke)
and [tests/err/generic_probe_then_use.loke](tests/err/generic_probe_then_use.loke)
pin the orders above.

The scattered counter tests are now one operation. `committing(c)` in
[src/source.odin](src/source.odin), beside `begin_probe`/`end_probe`, answers
whether what the checker finds belongs to the program. The 22 sites that tested
`speculation_depth` directly ask it instead: registry enrollment, report-once
caches, the last-use annotation, and the finalization and emission guards.
CTFE's commit uses `begin_commit`/`end_commit` instead of assigning the counter.
`test-all.ps1` fails when a file other than `source.odin` names
`speculation_depth`, so a new enrollment site cannot test the counter its own
way. Behaviour is unchanged. The general journal of speculative writes is
still not needed.

### A6 — resolved: Region fixed-point iterations retained whole superseded graphs

**New structural finding; no timing or memory regression measured.**
`build_flow_graph` in [src/cfg.odin](src/cfg.odin) repeatedly calls
`build_flow_pass` until region facts stop growing. Every graph is allocated in
the same analysis arena. Replacing the local `graph` pointer does not reclaim
the preceding graph; `summarize_body` and `analyze_provenance` in
[src/borrow.odin](src/borrow.odin) reset the arena only after the entire call.
`prov_seed_regions` in
[src/cfg_provenance.odin](src/cfg_provenance.odin) also retains projection-path
slices from the preceding graph, so an early reset would currently be unsafe.

For P graph-building passes, peak scratch retains the sum of all P graphs,
not just the final one. The work is repeated when global effects, result
summaries, and final diagnostics each request provenance graphs. This makes
the documentation's disposable-graph model less memory-bounded than it sounds.

**Next change:** first measure pass counts and peak scratch on a reverse-order
region-propagation chain. If significant, carry only owned region facts across
iterations and reclaim the superseded graph storage, or settle those facts on
one topology. Preserve the monotone fixed point; an arbitrary iteration cap
would change analysis results. There is no evidence here that a durable MIR
is necessary.

**Measured and fixed:** a loop whose body assigns `h1 = h0` after
`h2 = h1` and so on down a chain of N allocator handles takes N + 2 passes in
each provenance mode. Peak analysis scratch was 0.9 MB at N = 8, 6.5 MB at
N = 32, and 100 MB at N = 128, growing with the square of N. `build_flow_graph`
in [src/cfg.odin](src/cfg.odin) now builds each pass inside an arena
watermark: a pass that added facts has them copied into a small carry arena
(`prov_carry_regions`) and is rolled back, and the next pass is seeded from
the carry. `prov_seed_regions` copies projection paths instead of sharing
them. The fixed point and the stopping test are unchanged; only the final pass
stays in the analysis arena. At N = 128 the compiler's peak working set went
from 114 MB to 35 MB. The passes still cost quadratic time on such a chain.

### A7 — resolved: Cleanup identity depended on matching traversal order

**Existing concern, rechecked.** `provider_region_end` in
[src/cfg.odin](src/cfg.odin) identifies an implicit cleanup by procedure,
symbol, and an incrementing per-symbol ordinal. The lifecycle mode records
`cleanup_reset_dead`; provenance rebuilds the walk and expects the same key.
Explicit reset calls use node identity. Missing keys assert, which is useful,
but the assertion proves existence rather than that an ordinal still means
the same exit event after a traversal change.

**Next change:** give cleanup occurrences an explicit identity shared by the
consumers, or keep the relevant topology long enough to run both analyses on
it. Start with this specific interface. Separating every CFG event producer
into a general pass framework would be a much larger change. Verification
needs multiple exits, nested defers, provider moves, and unreachable paths,
where one local has several cleanup occurrences.

**Fixed, with a real defect behind it:** a deferred `drop(arena)` or
`free_all(arena.allocator())` is walked once per exit, but its node key named
all those walks alike, so the last exit lifecycle solved decided the dead
owners at every other. With `xs` dropped before an early `return` and live at
the scope's end, the region reset at the scope's end went unreported. Every
reset point is now named by a `Reset_Key` in [src/cfg.odin](src/cfg.odin): the
body, the ending node (the call, `drop`, `move`, `exchange`, or assignment, or
the `return`, `break`, `continue`, or `or_return` whose cleanups run it; nil at
the scope's end), the local, and the `defer` expansion being walked (the
deferred statement and the exit running it). Both walks build the key from what
they are at, not from a count, so there is no per-symbol ordinal left. Nested
defers do not exist (`L0369`). The provenance walk no longer clears an
explicit reset's recorded liveness either. The two new cases in
[tests/err/provider_region_end.loke](tests/err/provider_region_end.loke) failed
before the fix; [tests/run/deferred_region_ends.loke](tests/run/deferred_region_ends.loke)
covers a `break`, several returns, a provider moved on one path, and a
deferred reset at every exit.

### A8 — resolved: Runtime function signatures had two unchecked handwritten authorities

**Existing concern; no ABI mismatch demonstrated.**
[runtime/loke_rt.h](runtime/loke_rt.h) specifies the C ABI, while
[src/emit_llvm_runtime.odin](src/emit_llvm_runtime.odin) separately spells
LLVM declarations. Header static assertions check several C record sizes;
the layout corpus checks compiler/LLVM agreement. Neither establishes that
every runtime function's LLVM declaration matches the C compiler's lowering
of the header. Separate object linking does not supply that signature check.

**Next change:** add one ABI-conformance check using clang's lowering of a
small C translation unit that references the runtime entry points. Compare
return types, parameter types, and ABI-relevant attributes against the emitted
declarations, accounting for the target's aggregate lowering. Add record field
offset checks where only total size is currently pinned. Start with validation;
a new interface-definition language or broad binding generator is unnecessary.

**Fixed as validation:** `runtime_abi_matches_header` in
[tests/runtime_test.odin](tests/runtime_test.odin) collects every literal
`declare`/`define` of a `loke_rt_v1_` function in `src/emit_llvm*.odin`, has
clang lower a translation unit that references each one the header declares,
for the triple the compiler emits, and compares return and parameter types
plus the attributes that change passing (`signext`, `zeroext`, `inreg`,
`byval`, `sret`, `byref`, `inalloca`). The same unit instantiates
`loke_rt_string_v1`, `loke_rt_dynamic_v1`, `loke_rt_map_v1`, and
`loke_rt_container_ops_v1`; their lowered structs must equal the
`%loke.string`, `%loke.container`, and `%loke.container_ops` types every module
carries, and the default allocator's record must equal the compiler's
`external global` type. A formatted runtime declaration fails the test, since
it could not be checked; a compiler `declare` absent from the header fails too;
a compiler `define` the header lacks (`loke_rt_v1_program_init`) is skipped. No
mismatch was found. Mutating a parameter width, a carrier field, and the
allocator record's field order (same size) each failed the test.
`fmt.Options` is a Loke-declared record whose LLVM spelling (`{ i64, i1 }`)
differs from the C one without differing in layout, so the header now pins
`offsetof(loke_rt_options_v1, uppercase) == 8` instead. The other runtime
records passed by pointer are all pointer-sized fields or runtime-private.

### A9 — resolved: The runtime-object cache omitted build inputs from its identity

**New source-confirmed risk; no stale-cache failure forced.**
`prebuilt_runtime_objects` in
[src/emit_llvm_toolchain.odin](src/emit_llvm_toolchain.odin) selects a directory
using only `opts.opt_mode`. `prebuilt_current` checks runtime source/header
timestamps against object timestamps. Compilation also depends on
`find_clang`, the discovered MSVC/SDK include paths, and the compiler-owned C
flags, none of which participate in cache validation. Changing `LOKE_CLANG`
can therefore build the new LLVM module with one compiler while reusing
runtime objects from another, without any cache miss.

**Next change:** store a small manifest of the effective C build inputs beside
each cached set and rebuild when it changes. Include the compiler identity,
target, relevant toolchain roots, flags, and runtime input identity. Keep the
existing staging/install behavior and the custom-runtime fallback. Verify
invalidation when the tool override or effective flags change; this does not
require a general-purpose build cache.

**Fixed:** `prebuilt_runtime_objects` in
[src/emit_llvm_toolchain.odin](src/emit_llvm_toolchain.odin) builds the runtime
compile command once and writes it, one argument per line, to
`build-inputs.txt` inside the staged set, followed by the clang binary's
modification time. The command names the clang path, the optimization flag,
and the runtime and MSVC/SDK include roots; the host target is clang's
default, so the clang identity covers it. `prebuilt_current` requires the
recorded manifest to equal the current one, as well as the existing timestamp
check. A set cached before this change has no manifest and is rebuilt once.
`runtime_cache_follows_build_inputs` in
[tests/runtime_test.odin](tests/runtime_test.odin) links through a private
copy of the compiler and runtime, so its rebuilds never touch the objects the
corpus links. An unchanged link reuses the set, a `LOKE_CLANG` spelling the
same clang differently rebuilds it, and so does switching back. The test
failed against the previous cache.

### A10 — resolved: Generic member installation committed before applicability settled

**Existing language defects with a common structural cause.** The two generic
`impl` reproductions then in [known-gaps.md](known-gaps.md) exposed eager
member installation in `install_generic_impls`, `install_one_generic_impl`,
and `declare_instance_impl_members` in
[src/generic.odin](src/generic.odin). An instance can exist during package
`when` selection, before later applicable blocks are registered. Installation
then treats competing members as declaration conflicts, although the language
requires specificity and ambiguity to be decided for a use.

**Next change:** retain applicable member candidates until the declaration set
is stable and resolve their conflicts at the semantic point the spec defines.
Reuse the existing overload/specificity machinery. Verify both source orders,
an instance created from a `when`, an unused ambiguous member, and a called
ambiguous member. Reordering files or rewriting the specification would leave
the premature commitment intact.

**Fixed:** each record instance keeps `impl_candidates`, the members no other
block is more specialized than, by name and member table.
`declare_instance_impl_members` admits a block's member against them: a more
specialized supplier makes it lose silently, as before; an equal pattern, or a
crossed non-procedure, is still a duplicate (`L0409`). A block more specialized
than every supplier takes the name over and marks the replaced member
`superseded`, which skips its body check and emission, so a general body that
is invalid for the instance is never checked for it. Crossed procedure
survivors share the table entry as a `Proc_Group`, so a call reaches the
overload engine and reports the ambiguity (`L0391`) and an unused one costs
nothing. Member lookups mark the entry `looked_up`; a block arriving after a
lookup cannot change what it found and is reported as before.
[tests/run/generic_impl_specificity.loke](tests/run/generic_impl_specificity.loke)
covers crossed blocks unused and settled by a third block, and the `when`-made
instance with an invalid general body;
[tests/err/generic_impl_conflicts.loke](tests/err/generic_impl_conflicts.loke)
now expects the called ambiguity at the call.

Still open: a `when` condition cannot yet see a member of a generic `impl`
block declared in the same package, as in
`when (Box(int){5}.which() == 1) { ... }` with `impl Box($T)` above it
(`L0363`). This predates the fix and leaves the `looked_up` conflict hard to
reach from one package.

### Structure and simplification work with lower urgency

- **Narrow mutation access before splitting packages.** The single `lokec`
  package is deliberate, and many file boundaries are already useful. The 107
  fields of `Compiler` combine build options, source/diagnostics, stores,
  speculative state, analysis registries, and allocation domains. Small
  operations for enrollment and finalization would make the important writes
  auditable. Merely moving those fields into nested records would improve
  navigation without enforcing a boundary. Keep the current package until a
  concrete independent consumer justifies an exported API.
- **Make positional expression inputs explicit.** `Body_Context` and
  `Function_State` are improvements worth preserving. `in_callee`,
  `place_position`, and `insert_position` still travel through mutable checker
  state; `emit_unwind_thunk` also saves and restores a selected subset of
  emitter fields manually. Narrow parameters for expression position and a
  documented replay-state boundary would reduce restoration obligations.
- **Keep one copy of process waiting when that code next changes.**
  `run_process`/`drain` in
  [src/emit_llvm_toolchain.odin](src/emit_llvm_toolchain.odin) and `exec`/`drain`
  in [tests/corpus_test.odin](tests/corpus_test.odin) duplicate roughly 65 lines
  of pipe draining and process waiting. A shared internal helper can remove
  one copy, less package/import overhead, without adding a dependency. The
  documented busy-loop behavior is a reason to retain the current waiting
  semantics, not to substitute `os2.process_exec` blindly.
- **Repair comments that describe removed representations.**
  [src/ast.odin](src/ast.odin) still describes `.as(T)` as yielding `(T, bool)`
  immediately above the correct `Option(T)` metadata;
  [src/slice.odin](src/slice.odin), [src/container.odin](src/container.odin),
  and [src/erased.odin](src/erased.odin) still warn about pointers into a growing
  type store, although entries now have stable allocations. Some "first use"
  comments contradict constructors that already install fields. These are
  misleading maintenance instructions. Heading-citation checks cannot detect
  semantic drift inside otherwise valid comments.

There is no evidence for removing a backend abstraction layer, replacing the
Odin standard library, or adding a compiler framework. The arbitrary-precision
integer wrapper already delegates to `core:math/big`. Most small feature files
represent real language rules, not speculative extension points. The concrete
deletions are the raw-source binding scanner (removed in A2), backend semantic
repair calls (removed in A3), and one duplicated process runner; their replacements require code, so
a larger net line-saving estimate would be speculative. No dependency removal
was identified.

### Recommended order and verification record

1. Address the known constant-allocation failure with focused correctness
   regressions. Both it (A1) and the comment/default bug (A2) are now fixed
   with their regressions.
2. Close emission preparation: settle carrier fields, require completed
   phases, and test that emission cannot add semantic entities. Include the
   real production pipeline in that check. Done (A3, A4).
3. Clarify generic commitment and member applicability, retaining the existing
   overload engine and CTFE behavior. Done (A10, A5).
4. Measure graph iteration/storage before changing analysis topology; then
   improve cleanup identity and scratch ownership where the evidence warrants.
   Done (A6, A7).
5. Add the runtime ABI check and cache-input manifest. Do the smaller state,
   duplication, and comment cleanups alongside relevant changes. Done (A8,
   A9); the smaller cleanups remain.

Validation performed on the reviewed implementation:

- `test-all.ps1` passed: **1,010 specification citations**, both layering
  checks, **100 compiler unit tests** with memory tracking, the vetted compiler
  build, and **33 integration test functions**. Those integration functions
  execute the larger case corpora; 33 is not the number of Loke programs.
- The integration harness reported NASM unavailable and skipped its assembly
  link coverage. The mutation fuzzer was skipped because `LOKE_TEST_FULL` was
  unset. The optimization matrix and full fuzzer were not run locally.
- The two comment/default programs were compiled separately with `-emit-ll`,
  confirming exit 0 with the comment and exit 1 without it.
- One temporary in-package audit test ran the actual compilation/finalization
  path and reported the symbol/field mutation and the two accepted incomplete
  states described above. It passed with memory tracking and was removed
  after the observations were recorded. Its successful result confirms the
  observations, not that those states satisfy the intended contract.

The original audit changed documentation only. A1–A10 were fixed in the
follow-ups described above; the lower-urgency structure items remain open.

## Open checker-fuzzer findings

The checker fuzzer (`tests/checker_fuzz_test.odin`) found these with
`LOKE_FUZZ_SEED=1 LOKE_FUZZ_MUTANTS=10`. They break no rule of the
specification, so they are not in [known-gaps.md](known-gaps.md), but each
fails one of the fuzzer's checks under some seed.

- **A copyable fixed array with a `hook(copy)` element compiles in quadratic
  time.** `arr := [N]Value{Value{1}};`, where `Value` has a copy hook, takes
  2.4 s at N = 1024 and 9.4 s at N = 2048; without the hook, N = 65536 takes
  2 s. The fuzzer reports it as a hang at N = 65536.
- **An error in a generic record's field type is repeated per instance without
  saying which.** For `Sized :: struct($V: [2]int) { items: [V[18446744073709551616]]int }`
  and two instances, `L0352` is reported twice, identically, with no
  "while instantiating" note; the `L0361` that follows each is a cascade from
  the same unrepresentable constant, and the note names the instance
  `Sized({0,1:1,1:9})` rather than `Sized([2]int{1, 9})`.

## Open generics findings

A review of the generics implementation left these open. None breaks a rule of
the specification as written.

- **`$T: Type` in a type position has no meaning.** grammar.md "Types" lists
  `"$" Identifier (":" Type)?` as a specialization binding, and the parser keeps
  the part after `:`, but design.md never says what it means and the checker
  ignores it: `f :: proc(x: $T: []int)` accepts `f(3.5)` with `T` bound to
  `f64`. Give it a meaning, such as requiring `T` to match the shape, or remove
  it from the grammar and reject it.
- **What identifies a floating generic argument.** An instance's cache key uses
  the value's bits, so `Tag(0.0)` and `Tag(-0.0)` are different types, while
  `bind_pattern_name` compares with `const_equal`, under which they are equal.
  design.md "Interfaces as reusable constraints" says the converted value is
  part of an application's identity without saying whether that is value or
  representation equality.
- **Generic arguments print badly in diagnostics.** A floating argument prints
  its bits (`Tag(0h8000000000000000)`), an aggregate prints its cache key (see
  the fuzzer finding above), an argument with no type prints `f(<invalid>)`
  under a misleading "`$T` is not bound here", and the instantiation-limit
  error (`L0436`) prints every nested type in full on each of its notes, so
  `deep([1]T{x})` spells `[1]` 64 times per line.

## Found by writing the tutorials

Writing [tutorials/](tutorials/README.md) found these, besides the ones since
fixed. The pages work around both, so each workaround marks a place to revisit
if the answer changes.

- **Column widths.** `fmt` has no width, so the tool in tutorials/08 pads with
  `strings.repeat`. Widths wait for [Width and precision in
  `fmt`](#width-and-precision-in-fmt), to be settled together with precision
  when a program needs both; the workaround is two lines.
- **Two slices of one local array in one call.** `fmt.println(primes[1:4],
  total(primes[:]))` is rejected (`L0511`): slicing a mutable local gives
  `[]mut int`, which keeps that type inside the `any_view`, so the second slice
  conflicts with it. That follows design.md "Slices", and an extracted
  `[]mut int` could indeed write. But a reader who only prints has to write
  `middle := primes[1:4];` first (tutorials/04). Erasing a fresh slice into an
  `any_view` could settle it read-only, as a `[]T` destination does, but that
  would make an erased slice's type depend on where it lands. The rule stays:
  one extra binding is a small price for a slice type that does not change.

## Formatting

`lokec -fmt` ([src/formatter.odin](src/formatter.odin)) settles the layout
`core/` already used, and changes whitespace only. The rules:

- **Line breaks are the author's.** It never joins or splits a line, and a run
  of blank lines becomes one. Wrapping at a width was rejected: it is most of a
  formatter's code, and a renamed identifier would re-flow its neighbours in a
  diff.
- **Tabs, one per enclosing bracket** opened on an earlier line, however many
  opened together. A `case` sits at its `switch`'s level, and a line that
  continues an unfinished statement outside any `(` or `[` goes one deeper. A
  file-scope `when` body stays at column zero when written there, as `core/`'s
  long platform blocks are.
- **Spacing between tokens** is one space after a comma, around `::`, `:=`,
  assignment, comparison, logical, range, and arrow operators, and none inside
  brackets, before `,`, `;`, `)`, and `]`, or after a prefix operator. An
  arithmetic or bitwise operator written with no space on either side stays
  tight, because `core/` writes `a*b + c*d` by precedence; one written with a
  space on either side gets one on both.
- **Extra spaces inside a line are kept.** `core/` aligns field types and
  trailing comments with them. Only the leading indentation is recomputed.

It works on the real lexer's tokens rather than printing the syntax tree:
keeping the author's breaks leaves nothing for a tree printer to decide, and a
token stream cannot lose or reorder syntax. The parser still runs, so a file
that does not parse is refused, and each result is lexed again and must hold
the input's tokens exactly, or the formatter reports an internal error instead
of writing. tests/corpus_test.odin keeps `core/` and `base/` formatted and
formats every program corpus to a layout that formats to itself.

Open: aligning columns automatically, as `gofmt` does, so a renamed field
does not leave its neighbours misaligned; and indenting a continued line
inside brackets, which `core/` leaves at the bracket's level.

# Differences from Odin and design motivations

This section is non-normative. It records why Loke differs from Odin and why
some larger design choices were made. [`design.md`](design.md) remains the
authoritative language definition.

## Added features compared to Odin

### Local borrow checking

Loke adds a deliberately small, procedure-local borrow checker. It catches
invalidating a container while a view is live and prevents obvious local
escapes without adding lifetime syntax. Named procedures and generic
instantiations infer result contracts that record borrowed parameters and
[carrier paths](design.md#values-that-contain-borrows), roots, and allocator-region
dependencies. Returning one field of a record argument uses that field's root
rather than everything the argument holds.

[Inferred callback types](design.md#procedure-result-contracts) preserve those
contracts: both `callback := choose` and `Chooser :: type_of(choose)` retain the
same provenance as a direct call. Copies and generic forwarding preserve it too.
The contract participates in type identity and compatibility, so changing a
published procedure's result dependencies can break clients.

Converting to a plain written `proc(...) -> T` signature erases that refinement;
converting back cannot recover it. Calls through that plain type conservatively
derive borrowed results from every borrowed argument not excluded by
[`@(escape=none)`](design.md#escapelevel). Owning results retain the region
dependencies of every moved owner and allocator argument. Plain signatures keep
this conservative precision tradeoff.

Raw pointers, stored borrows, foreign calls, and cross-thread lifetimes remain
explicit trust boundaries. This keeps low-level optimization and interop
possible without making unsafe behavior the default.

### Threads the language can start

The memory model, `thread_local` teardown, `Once` poisoning, `shared(T)`, and
atomic handle accounting on every `string` copy were specified and paid for
before anything in `core` or `base` started a thread, so no program exercised
them. `core:thread` is the smallest library that gives them a caller: `spawn`,
`join`, and `Mutex`.

Odin's `thread.create` hands the new thread a `rawptr` of data. `spawn` takes an
entry procedure and one moved argument instead, and the argument is checked
with `@(escape=static)`: any borrow it carries must be of process-lifetime
storage. The audit proposed "no checked borrow" at all; the escape level is the
rule the checker already had, and it lets a string literal travel while a
slice of a local does not. A static root can still race, but that is the case
the effect warning below covers. One argument is enough: several travel as a
record, and a procedure with no argument has its own overload.

A mutex beside its data would be of little use here. A `^T` cannot be written
through, so a `shared(T)` payload guarded by a `Mutex` field could not be
updated, and data in a global beside a mutex is exactly what the race warning
reports. So `Mutex(T)` owns the value, as Rust's does, and the guard returns it
as an `inout` result, whose provenance the language already ties to the guard.
Dropping an unjoined `Thread` joins it rather than detaching, so the owner of a
handle always outlives the thread.

The race check is a warning over the existing
[global write effects](design.md#global-write-effects): a spawned entry whose
effect writes shared, non-`thread_local` storage. Atomic operations and the
mutex take read-only receivers, so they are not writes and need no exemption.
It is a warning because it sees only globals and cannot prove that a global is
written only before a thread starts or after it is joined.

### Managed lexical storage

Strings, dynamic arrays, maps, and user resource types are owning values with
automatic scope cleanup. [`unsafe.forget`](design.md#unsafeforget) consumes an
individual value without cleanup; a lexical place is passed as
`unsafe.forget(move(value))`. `static` and `thread_local` control storage duration
without creating a second type.

File-scope and `static` managed values are not automatically dropped. A global
destruction order across packages would make shutdown depend on initialization
order and on whether other threads can still reach a value. Externally
observable process cleanup therefore uses a lexical owner, `defer`, or
`drop` in `main`. To extract a static-duration value for cleanup, use
[`exchange`](design.md#exchange) to leave a live replacement; direct `move` and
`drop` on that storage are forbidden. A managed `thread_local` has a natural
local endpoint and is dropped on normal thread return, in reverse initialization order;
aborting termination makes no such guarantee.

### Storage modifiers instead of storage attributes

Odin spells static-duration locals `@(static)` and thread locals
`@(thread_local)`. Loke writes `static` and `thread_local` in the declaration
because they specify where and how long the variable lives. The two modifiers
are mutually exclusive.

The dividing line is not metadata versus meaning: `@(packed)` and
`@(allocator_reset)` are attributes and both are load-bearing. It is that these
two answer a question about the declared storage itself, which is what the
declaration is for. Remove `@(link_name)` or `@(export)` and the program still
means what it meant; remove `static` and a counter resets on every call, cleanup
starts running at scope exit, and a borrow that used to be returnable no longer
is.

Cleanup suppression is a per-value operation through `unsafe.forget`, not a
declaration modifier.

### No `stack` modifier, and no heap-promoted locals

An earlier draft let the compiler place a large fixed-size local on the heap when
the frame would otherwise be impractical, and added a `stack` duration modifier
so that embedded and real-time code could forbid it per declaration.

Both are gone. A local with lexical duration lives in its frame, full stop; a
declaration too large for the stack overflows it, as in C. The promotion rule was
a silent allocation — and a silent allocation-failure path — behind a declaration
that reads as free, and `stack` existed only to buy back the property the
declaration started with. Deleting the pair removes a modifier, a placement rule,
and a guarantee, and puts the cost of eight megabytes of local back in the
declaration that asks for it.

### Value-semantic assignment

Odin assignment of a `[dynamic]T` or `map` copies only the header, so two
variables alias one mutable backing allocation and one of them frees it. Loke
keeps value semantics: a copy of an owner is independent of it, and the silent
shared-backing alias, the classic source of double-free and
mutation-at-a-distance bugs, is never produced. `b := a` over a `[dynamic]int`
clones it, from `b`'s declaration allocation policy. Immutable `string` and
`shared(T)` retain their storage instead. Shared mutable ownership is opted
into with a pointer or `shared(T)`.

This has gone back and forth. The allocating copy was first implicit, then
(0.7.1) an error, L0504, that offered `move(a)`, `a.clone()`, or a borrow: a
count across the examples and `tests/run` found the copy only in tests of the
copy rules, so requiring it to be written seemed to cost nothing. It is implicit
again because the error cost more than that count showed:

- assignment, the most common operation, did nothing useful for a whole class of
  types, and a beginner met three ways out of L0504 before a first `append`;
- adding a `[dynamic]T` field to a record of strings made every copy of the
  record elsewhere an error, so a private detail broke other packages;
- generic code copying a `T` had to write `.clone()`, so every copyable type
  needed one.

The cost the error guarded against is a hidden allocation. Loke already has
abstractions that hide work, and the answer here is to make the common case
free rather than forbid it: a copy at a local's last use is a move
([design.md "Last-use transfer"](design.md#last-use-transfer)), which removes
the copy people write when they mean "hand it over", and the copy-cost
diagnostic still reports large inline copies. What stays a copy is one whose
source is used afterwards, where the copy was the point.

Last-use transfer is decided on the procedure's control-flow graph, backward
from each candidate, and is conservative about borrows rather than exact: a
local that is ever stored into a borrow-carrying value, or passed as one to a
call with an `inout` argument, never moves at a last use, whether or not the
borrow is still live. An exact answer needs the provenance pass, which runs
after lifecycle analysis has already fixed each local's drop. The transfer is
then an ordinary `move(x)` in the syntax tree, so the borrow and region checks
see it as written, and a borrow the rule misses is an error at the copy with a
note, not unsoundness. It applies only to bindings and assignments; an
argument, an aggregate element, or an insertion still clones, which keeps the
rule short and each copy site's cost visible in one place.

A generic `clone` for fixed arrays and compile-time evaluation of a generated
`clone`, both added while the error stood, remain: the first is still needed by
generic code that clones, the second by constant evaluation of one.

### Panics run lexical cleanup

Odin's managed model has no destructors, so a crash has nothing to unwind. Loke
adds managed `drop` and lifecycle hooks, which forces a decision Odin never had
to make: what runs when a program panics. The [answer](design.md#panics-and-unwinding)
is that a panic under the unwinding strategy runs exactly the cleanup attached to
live owners and `defer`s as it unwinds the faulting thread — so `defer os.close(f)`
and a resource's `drop` are reliable when they are on that thread's stack — and
nothing else. Loke has no automatic package shutdown hooks. An owner in `main`
is cleaned only when `main` is on the panicking thread's stack; a worker panic
does not unwind other threads.

Two strategies exist because the machinery is not free: hosted builds default to
`unwind` for the cleanup, while freestanding and embedded builds default to
`abort`, which runs no cleanup and needs no unwind tables. Because a panic cannot
be caught either way, the choice never changes which programs are valid, only what
observable cleanup happens on the way down.

### Methods, interfaces, and operator overloading

Methods and `impl` blocks let libraries attach behavior to records and
other types without embedding procedure declarations in every type definition.
An extension affects implicit lookup only in its declaring package. A public
extension procedure is an ordinary export of that package, so importers call it
as `adapter.procedure(value)` unless they add a local forwarding extension. This
keeps an unrelated import from changing an existing expression.
Interfaces describe capabilities used by generic code. Named `slot`
requirements additionally let the compiler reify the same proof as a witness
table for explicit `dyn` values. Free-form expression requirements remain
static-only, so adding runtime dispatch does not weaken the concise structural
constraints used by numeric and container algorithms. The name `interface`
replaced the earlier draft's `concept` because it now describes both roles
directly.

Generic bodies and their interface requirements use definition-site lookup, so
a caller-local extension cannot change an existing instantiation. The built-in
map is stricter still: equality and hashing for a user key must be inherent to
the key type. Without that restriction, two packages could operate on the same
map using different hash policies and invalidate its contents.

The receiver is an explicit first parameter named `self`. A procedure in an
`impl` block is a method exactly when it declares one, so the declaration shows
whether it is called on a value or on the type, as instance and static methods
differ in Java. Writing it also places the receiver's mode where every other
parameter's mode is written: `self`, `self: ^`, `self: inout`, or
`self: move`.

Operator overloading, indexing, iteration, conversions, and lifecycle hooks let
library types be as convenient as built-in types.

### One language at compile time

`$`, `::`, `when`, and static `foreach` have separate jobs. `$` introduces a
specialization input or pattern, `::` binds a computed constant, `when` selects
which source is present, and `foreach ($item in values)` expands heterogeneous
typed code. Keeping those meanings separate avoids a general sigil that can
silently move arbitrary runtime work into compilation.

Ordinary procedures are interpreted when a constant context requires their
result. Their values retain ordinary Loke types; only `type` and the opaque
reflection descriptors are compile-time-only. This gives libraries loops,
local mutation, type computation, and reflection without a parallel untyped
macro language. File and environment access remain in an explicit build program
rather than becoming ambient compiler effects.

Built-in operations on built-in types cannot be shadowed. Domain-specific
behavior over a primitive representation uses a `distinct` type, keeping the
changed meaning visible at its declaration.

A `distinct` type inherits none of its underlying type's operators — `Meters ::
distinct f64` starts with no arithmetic at all — which is what stops a unit type
from silently behaving like its representation. The cost is per-operator
boilerplate for numeric newtypes, so `delegate` re-exports a chosen set of the
underlying operators in one line. It is deliberately a list rather than blanket
inheritance: `Meters` delegates `+` and `-` but not `*`, because two lengths add
to a length but do not multiply to one. Selective delegation keeps the newtype
convenient without reintroducing the wrong-dimensioned operations that
distinctness exists to forbid.

### Build-selected services and explicit runtime state

An earlier draft gave every Loke call a hidden pointer to an immutable ambient
context containing allocators, logging, tracing, clocks, and related services.
It made call-tree overrides concise, but also changed every procedure ABI and
introduced context derivation, installation, snapshotting, and thread
propagation rules for services most procedures never use.

Loke instead lets the final build select one default allocator provider and one
logging provider for the whole program. Imports cannot configure separate copies
of a package. Per-import configuration would require generic package instances:
two imports with different providers would need rules for duplicated code,
globals, initialization, symbol identity, transitive dependencies, and whether
public nominal types from the two instances are compatible. That is a package
type system, not a small service-selection feature.

Only the provider implementation is static. Allocator regions, scratch arenas,
request log fields, trace spans, clocks used by simulations, cancellation, and
other execution state remain ordinary runtime values. They are passed directly
or retained in application-defined state objects. This makes nondefault policy
visible and lets two concurrent requests use different state without a global or
thread-local override.

The removed context pointer is not retained as a closure substitute. It would
provide the caller's environment when a procedure is invoked, not the lexical
environment in effect when a procedure value was created, and retained work
would still need ownership and lifetime rules. Typed `state + proc` records and
callbacks with explicit generic state provide the useful mechanism using
ordinary language facilities while keeping procedure values thin.

`core:slice.sort_by` is the first standard generic callback algorithm built on
that choice. Its comparator is an ordinary record with an immutable `call`
method, so configuration and checked borrows remain typed and allocation-free. A
plain procedure is accepted too: the library wraps it in such a record, so it is
checked and lowered like one written by hand. The compiler erases addresses only
inside a generated call-scoped adapter to the shared runtime introsort; the
runtime neither owns nor retains the comparator. This keeps raw relocation and
one copy of the introsort below the language boundary without making `rawptr`
part of the user-facing callback protocol.

That settles the convention this area should follow: **a callable is a value
with a `call` method.** Three steps complete it, and none of them is worth
taking before something needs it.

A procedure should meet the convention itself, through a `call` the compiler
contributes to every procedure type, as it already contributes `iter` to the
built-in containers. One generic signature would then serve records and
procedures alike, a user's own included, and `sort_by`'s procedure member could
go. One standard API takes a `call` callable today, which is why that member is
a library wrapper rather than a language rule.

An API whose callable's result type varies cannot take a record at all. A
generic signature can name that type only by matching a procedure type, which is
why `Result.map_error` takes `proc(error: move E) -> $F`. Deriving a callable's
result from its only `call`, as an iterator's `Iterator` is derived from `iter`,
is what such an API would need first.

Closure syntax is then a shorthand for the same record and method, with written
captures, ordinary lifetime checks, and no implicit allocation. It is what gives
the other two steps a caller, so its capture, mutation, and escape rules should
be decided together with them. A callable that outlives the scope it was made in
stays a separate question. `fmt.Writer` and `log.Logger` were once cited as
needing one; they turned out to need only a `dyn mut` view
([Formatting and logging sinks are `dyn` views](#formatting-and-logging-sinks-are-dyn-views)).

### Typed fallibility, and the `Option` decision it reverses

An earlier revision of [`design.md`](design.md) said the language and core
library define no `Option`, `Maybe`, or `Result`, that a procedure with no value
returns `(T, bool)`, and that nothing prevents a library from declaring its own
`Option` because "no language construct is aware of it". That decision is
reversed. `Option(T)` and `Result(T, E)` are now ordinary generic unions in
`base:runtime`, and `or_else` and `or_return` are specified over the *shape* a
union declares rather than over a trailing result's position.

The old answer was defensible on its own terms — a trailing `bool` is cheap and
needs no library type. What it could not do was compose. A `(T, bool)` result
lived only in a result list: it could not be stored in a field, passed through
an unconstrained generic, or returned through a procedure value without a caller
rebuilding the convention by hand. Every producer that wanted the shape needed
privileged syntax, and every consumer needed to know which of two spellings it
was looking at.

Two shapes also cost more of the language than they looked like they did. To
make a trailing error work, a union needed a nil state to be the successful
value, which needed an `active_typeid()` to ask what was in a non-nil one, which
could not discriminate two variants sharing a payload type — so `Result(int,
int)` was not expressible. Meanwhile the specification carried an "optional-ok"
rule letting a destination change a producer's result count, and a "status
result" concept with two admissible spellings and an explicit list of types that
compare against `nil` but are *not* statuses. One shape removed all of it.

The migration was not free, and the cost is recorded rather than waved at:
front-end time rose 7–18%, largest on the smallest program, because
`base:runtime` is a fixed charge; an empty program's binary is byte-identical,
and two real example programs grew about 3%. The change also surfaced nine compiler defects, each fixed with the
migration.

One library contract changed with it. `io.Reader.read` used to return a count
*and* an error together, so a reader could report progress and a failure in one
result. A `Result` carries one or the other, so progress is reported and the
failure surfaces on the next call — the same contract Rust's `Read` has, and one
every helper in `core:io` was already written for, because they all loop until
they have what they asked for.

### One result, and the compatibility break that came with it

A procedure returns at most one value. Multiple results, named result locals,
and the bare `return;` that published them are gone, and so is the
definite-initialisation dataflow that existed only to let `or_return` perform
that bare return with several results outstanding. Several values are returned
as one [anonymous record](design.md#anonymous-records) and taken apart by
[destructuring](design.md#destructuring), which is now one rule in declarations,
assignments, and `foreach` rather than a result-only special case.

The migration cost was near zero because typed fallibility had already collapsed
the library to single results: `core:` had exactly one multi-result procedure
(`strings.encode_rune`), `base:` and `examples:` had none, and five naked
returns existed in the whole live corpus. Everything else was test fixtures for
the mechanism being deleted.

**The break.** `-> (a: int, b: int)` keeps compiling and changes meaning: it was
two named results, and it is now one record result. Result names used to be
excluded from procedure-type identity, while anonymous-record field names are
part of it — so `proc() -> (a: int, b: int)` and `proc() -> (x: int, y: int)`
were compatible before this phase and are not after it, through a procedure
value, an overload, an interface slot, reflection, and ABI lowering alike. The
one-result form changes too: `-> (n: T)` was one named `T`, and is now a
one-field record. `-> (T, U)` is no longer a type and says so.

That break is the price of the answer to the identity question. Interning on the
*semantic* vector — the ordered `(field name, field type)` pairs, compared pair
by pair — rather than on a printed type name is what keeps two packages'
unrelated `Token` types from collapsing into one record type merely because both
print as `Token`. A display-string key would have been shorter and wrong.

One pre-existing defect surfaced during the migration and was fixed with it: a
composite literal's *named* elements were joined into every borrow-provenance
path instead of being resolved to the field each names, because the checker's
resolved slot was not carried into the flow graph. Every migrated record literal
is written with named fields, so this turned an exact per-field result
provenance into a join. The same missing information was behind a second bug:
named call arguments evaluated in *parameter* order rather than source order.
Both now read the slot the checker already chose.

## Removed or narrowed features

### Generics are not ABI surface

Generics are resolved before ABI lowering, so a generic procedure or type has no
representation of its own and is excluded from every binary interface: it cannot
be exported, given a foreign calling convention, placed in a `foreign` block, or
held in a procedure value. Only concrete instantiations reach the ABI, and
exposing generic functionality to C means instantiating it and wrapping the
result in a foreign-ABI-safe procedure. Saying so explicitly keeps the choice
between monomorphization and dictionary passing an implementation detail with no
observable consequence, and keeps the foreign boundary defined over concrete
types only.

### Constraint entailment in overload resolution

An earlier draft let [the specialization tie-breaker](design.md#operator-lookup-and-overload-resolution)
order two structurally identical candidates by constraint strength: the one whose
normalized constraint set syntactically entailed the other's won. Constraints now
decide only whether a candidate is *viable*; structure alone decides which viable
candidate wins, and a tie is an ambiguity error.

Entailment carried the most machinery of any single rule in the language — normalize
as an unordered conjunction, expand interface composition transitively, alpha-rename
bound names, test atom-subset — plus the caveat that an implementation reasoning more
strongly must not thereby change which overload is selected. It bought one pattern:
Rust-style automatic selection of a strictly-more-constrained refinement. Making that
refinement an explicit call is consistent with how the language treats every other
ambiguity, and it means a reader never has to perform a subset test to know which
procedure runs.

### Statement labels and multi-level breaks

Labels made structured control flow read like a hidden `goto`. The common
multi-level exit cases can use a returned helper procedure, a loop condition,
or an `if` chain. Loke therefore keeps `break` and `continue` limited to the
innermost loop. A switch is selection rather than iteration and is not a break
target; its cases already stop automatically.

### File-private visibility

`@(private="file")` is gone; `@(private)` now takes no argument and names package
visibility explicitly, which is only load-bearing inside a file whose package
clause carries `@(public)`. A package is the encapsulation boundary, and one
level of hiding *inside* that boundary cost an attribute value, a package-clause
form, a mutual-exclusion rule against `@(public)`, and a rule for opting back out
of a file-wide private default. A file that wants its own boundary wants to be a
package.

### Standard free aliases

A closed set of nine names — `len`, `cap`, `hash`, `format`, `compare`, `iter`,
`iter_reverse`, `clone`, `try_clone` — used to perform receiver lookup, so
`len(x)` and `x.len()` selected one declaration. The second spelling bought no
expressiveness and cost four rules: the closed set itself, a restriction to
immutable receivers, a matching rule keeping mutators method-only so their
receiver borrow could not hide in free-call syntax, and a rule that an alias
contributes no overload candidates of its own. All four exist only to keep the
two spellings from disagreeing.

The method is now the only spelling. `len(x)` is not a call, a free procedure
named `len` is an ordinary declaration, and the one remaining rule is the one
already needed: `f(x)` is a lexical call and `x.f()` is a receiver call. The
built-in types keep their compiler-contributed `len`, `cap`, and `hash` members,
which is what `x.len()` selects on a slice exactly as on a user record. A fixed
array's and a vector's lengths stay properties of their type, but `x.len()` is
still an ordinary call and still evaluates `x`; the unevaluated operand is
`size_of`'s job, not a method call's.

### `mem.` spellings of the allocation built-ins

`design.md` once promised that `new`, `new_clone`, `make`, `free`, `free_all`,
and `drop` were also available in package `mem`. No compiler ever contributed
them, and a second name for each built-in would buy nothing: each allocating
built-in has a `try_` form returning `Result(T, Allocator_Error)`, so there is
no stricter error handling left for a `mem.` spelling to add. The universe name
is the only spelling.

### `fallthrough`

Multi-value case lists cover what most C fallthrough chains are written for, and
a case that must run another case's body calls a shared procedure. Keeping a
keyword to reintroduce the C behaviour that Loke's `switch` exists to remove was
not worth the reserved word, the statement, and the extra clause in the `defer`
restrictions.

### Named-result initializers

`-> (color := "blue")` was removed first, then named results themselves. The
initializer resembled a parameter default but fired on a different condition —
every entry, rather than every call that omits an argument — and two similar
spellings with different trigger conditions is a poor use of syntax. What
remains is simpler still: a result is anonymous and `return` always carries its
value.

### Reflection beyond fields and enum values

Compile-time reflection is `fields_of` and `enum_values_of` with two descriptor
types. An earlier draft also had `procedures_of`, `parameters_of`,
`requirements_of`, and `attributes_of`, with three further descriptors and a rule
about which extension members `procedures_of` observes. Field and enum shape is
what serialization, bindings, and GUI generation walk; the rest was a guess at
what an RPC or documentation generator might want. Adding a descriptor later is
additive.

### Associated interface members use expressions

`const T.NAME: Type;` is gone. `T.NAME -> Type;` is an ordinary expression
requirement that says the same thing, since `T.NAME` already names its owner
unambiguously. The dedicated form bought only the additional demand that the
member be a compile-time constant, which value requirements did not need. An
associated type uses the same mechanism as `T.Element -> type;`; because its
result is itself a type, that selected member is necessarily compile-time known.
No second member-declaration grammar is needed.

### Headless switch

Odin permits a condition-only switch:

```odin
switch {
case x < 0:
	fmt.println("x is negative");
case x == 0:
	fmt.println("x is zero");
case:
	fmt.println("x is positive");
}
```

The same logic is clearer as an `if`/`else if` chain, so Loke requires a switch
expression and avoids a second conditional construct with overlapping purpose.

### Compiler-defined domain types

Complex numbers, quaternions, matrices, and similar domains are library types
instead of compiler-defined primitives because ordinary records and overloads
can express their behavior. SIMD vectors remain built in because their
semantics include lowering to target vector operations, which an ordinary
record cannot guarantee.

### Owning type erasure

`any_view` remains borrowed and call-scoped, while `dyn Interface` is a more
capable borrowed view carrying a coherent interface witness. Neither owns the
erased payload. An owning `any` or `dyn` would need stable payload allocation,
allocator provenance, alignment, erased clone/drop behavior, borrow rules across
moves, thread-affine destruction, and an allocation-failure contract.

Keeping ownership out of the initial design lets generic and dynamic dispatch
interoperate without silently allocating. Closed owning sets use unions;
libraries that need open ownership can first validate an explicit owner record
around raw storage and their own callback record.

### User-defined implicit conversions

There are none, at either scale. A general facility would have converted runtime
values silently based on what happened to be imported, so it was cut early; what
survived it was `@(implicit)`, a narrowed form that applied a one-argument
`hook(convert)` to an unfixed constant only. That went too.

Its motivating case was literals entering library numeric types: `z*z + 2.0`
should mean what it looks like. But the version that does is `z*z +
Complex_F64(2.0)`, which is four characters longer and needs no language feature.
Against that, `@(implicit)` cost an attribute, a rank below every built-in
conversion in overload resolution, an interaction with the unfixed-constant
rule, and a standing proof obligation that conversions cannot chain.

Removing it also removed the rules that existed only to contain the general
version: the cap on conversion chain depth, the argument that lookup terminates,
and the advice that implementations warn about lossy implicit conversions.
A conversion now happens exactly where one is written.

### A read-only-data attribute

Odin has `@(rodata)` for a global that lives in the read-only section. Loke
deleted it and made constants materializable instead: a constant indexed by a
non-constant or sliced is emitted into read-only storage, once, and shared by
every use. Taking its address is rejected because Loke pointers do not carry a
read-only capability; foreign access goes through a read-only slice and an
explicit `unsafe.raw_data` conversion.

`@(rodata)` existed for exactly one reason — a constant had no storage, so
`TABLE[index]` with a runtime index did not work. Everything else it provided,
process lifetime and immutability, a constant already had. Deleting it removed
the attribute, the rule that such a declaration's type had to be written `[]int`
rather than the `[]mut int` a literal would otherwise produce, and the last
exception to "there is no general `const` qualifier in the language."

The cost is that "constants exist only at compile time" is no longer literally
true, and the language has to say that all uses of a materialized constant share
one backing object. Rust keeps `const` and `static` separate to avoid exactly that
question. The trade was taken because a runtime-indexable read-only table is
ordinary systems code, and spending a declaration attribute on it — one that
looks like metadata but changes whether the program compiles — put it in the
wrong category.

### No octal escapes

Odin's `\NNN` is a byte, as in C and Go. Loke's named a code point up to U+01FF
and UTF-8 encoded it, so `"\377"` was the two bytes of `ÿ` where C gives the
one byte `0xFF`: the escape a C programmer uses to write a byte meant something
else. `\x` spells a byte and `\u` a character, so it added nothing, and only
one test used it. It is removed; a backslash followed by a digit is an error
that names `\x` and `\u`.

### Sized boolean types

Loke has a single one-byte `bool`. Boolean-looking foreign typedefs bind as their
actual integer representation and are converted in a wrapper. This also handles
encodings such as `VARIANT_BOOL`, whose true value is `-1`, without pretending
that every foreign boolean is just a differently sized Loke `bool`.

### Unchecked union extractions

A union has no unchecked extraction: it is inspected with a `switch`, whose
cases are variant names and which the compiler requires to be exhaustive. A
branch pattern such as `.some(value)` exposes the payload only in the arm that
has already checked that variant. There is no spelling that reads one variant's
payload while another is active.

`value.as(.name)` is the checked read for code that wants one variant without a
switch. It tests the tag and yields an `Option`, the union counterpart of
`view.as(T)` and `Enum.from_int`, so `or_else`, `or_return`, and a switch on the
`Option` all apply. It copies rather than borrows because an `Option` cannot
hold a borrow, which is why a move-only payload still needs a switch. There is
no panicking `value.(.name)`: `or_else` makes the safe form just as short.
Interpreting the wrong payload as an owning type can manufacture a container
header from unrelated bits and later pass an invalid pointer to `drop`.
`unsafe.transmute` and raw storage in `core:unsafe` remain available for explicit
low-level work, and the checked extraction that does exist — `view.(T)` on an
`any_view`, where the set of types is open — traps rather than guessing.

## Changed features

### Unchecked operations need the import

design.md [The `unsafe` package](design.md#the-unsafe-package) always said the
`core:unsafe` import was the review mechanism, but three operations that give an
unchecked address a usable shape were ordinary syntax. With no import at all, a
procedure could return `(^mut int)(r)` for `r: rawptr = &mut local`, slice a
freed dynamic array through `([^]int)(rawptr(&mut values[0]))[0:3]`, and write
`d: [dynamic]int = ---; d.append(1);`, which stopped at run time with
"allocator record does not match this runtime's ABI".

The conversions and C-pointer accesses now need the import in the file that
writes them, and `---` is limited to plain data. Losing provenance stays free —
anything converts to `rawptr`, and `^T` to `[^]T` — because nothing can be read
through the result without one of the gated operations. The rule is per file
rather than per expression because the import is already the unit a reviewer
searches for, and the cost was two library files: `core:fmt` and `core:io`,
both for `fmt.Writer`'s `rawptr` state, which the `dyn` sinks below have since
removed. `base:` packages are exempt: they are
the runtime, reach the same operations through compiler-contributed names, and
cannot import `core:`.

### Formatting and logging sinks are `dyn` views

`fmt.Writer` and `log.Logger` were a procedure beside a `rawptr` of state, so a
sink that formatted into its own record converted `state` back to a typed
pointer: `core:fmt` did so in `to_string`'s collector, and `core:io` in the
latch adapter standard-library.md had to call "not a safe construction". The closing
paragraph of
[Build-selected services](#build-selected-services-and-explicit-runtime-state)
said neither a generic parameter nor a borrowed `dyn` describes a handle kept
for the life of the program. Neither use needs one. A
formatter uses its sink only for the call, which is what a borrowed `dyn mut`
view is, and a logger's factory already has to return process-lifetime
storage, so a `dyn mut` view of a `static` record is exactly that handle.

Both are now aliases of `dyn mut` views: `fmt.Writer :: dyn mut fmt.Sink`, with
one `write(bytes: []u8)` slot, and `log.Logger :: dyn mut log.Sink`. A sink is
any record with the method, the collector and the latch are ordinary records,
and neither library imports `core:unsafe`. What it cost is in the seed runtime,
whose scalar formatters write through a `Writer`. The generated module now
supplies `loke_rt_v1_sink_write`, which calls the witness's one slot with a
slice built in LLVM, so no C prototype has to agree with how LLVM passes a
two-word aggregate, and the process streams are a compiler-emitted witness
whose data pointer is the stream selector. A nil `Writer` used to write
nothing; it now panics, as every slot call through a nil view does.

A logger is no longer comparable with another: views are comparable only with
`nil`. The provider test that compared `current().write` with
`standard_logger().write` to see whether publication had happened now logs a
record and checks whether its own sink received it.

### Explicit overload groups

Overloads are assembled in named procedure groups. Each implementation keeps an
ordinary callable name, the overload set is visible, and ambiguity is diagnosed
instead of being resolved by declaration order. Methods and operators use the
same resolution rules.

### `+` concatenates strings at runtime

Odin's `+` on strings works only between constants; runtime concatenation is
`strings.concat` with an explicit allocator. Loke lets `+` concatenate at runtime
too, allocating from `mem.default_allocator()`.

The argument against was that it hides an allocation behind an operator. But the
language already hides allocations behind `append`, map insertion, and plain
assignment, and it has a [copy-cost diagnostic](design.md#copy-cost-diagnostics)
for exactly this — so `+` is not the place the rule would first be broken, and
refusing it only makes the common two-or-three-piece message the awkward case.
The quadratic loop is the real hazard, and it is answered by reporting it rather
than by removing the operator: `String_Builder` remains the way to accumulate,
and the way to choose an allocator.

### No enum arithmetic or bitwise operators

An earlier draft allowed `+`, `-`, and the bitwise operators on enums, inherited
from treating them as thin wrappers over integers. Enum members may have holes,
so the result of `Foo.A + Foo.B` need not be a member of `Foo`, and the language
has `Bit_Set(Enum)` for flag sets. Enums remain comparable and ordered, and
converting to the backing integer type is one call.

### Closed enums and payloadless unions

Enums are closed sums whose variants carry no payload. They retain `enum`
syntax, explicit integer representations, and integer ordering, while sharing
the meaning of variants and exhaustive control flow with tagged unions. A switch
covering every variant now guarantees that a case runs; when every arm returns,
no trailing return is needed.

The former unchecked integer conversion made member coverage weaker than value
coverage. [`Enum.from_int`](design.md#integer-conversion) now validates the
backing integer and returns `Option(Enum)`. Foreign APIs and wire formats keep
unknown numbers in an integer or `distinct` integer wrapper until validated.
Its argument may be any integer type: validation, not the argument's type,
decides membership, so demanding the backing type only moved a narrowing
conversion, which is what `from_int` exists to avoid, onto the caller. It also
keeps a small explicit backing type (`enum u8`) cheap to choose, which is why
the default stays `int` rather than shrinking to fit the members and tying the
enum's layout to its member list.
An enum without a variant represented by zero has no zero value, and that
restriction propagates through aggregates just as it does for unions.

### Signed overflow panics

Signed `+`, `-`, `*`, and `<<` used to wrap two's-complement, defended against
C's undefined overflow: a meaning that does not change under optimization is
worth more than the loop optimizations undefined overflow buys, because the
alternative is a program whose correctness depends on a compiler flag.
Trapping was never weighed, and it keeps that property while catching the bugs
the library had guarded by hand:

- `strings.repeat` reserved `text.len() * times`, which wrapped to a small
  reservation (fixed in `c2f30eb` with a hand-written bound);
- `String_Builder.try_reserve` computed `len + additional`, which wrapped
  negative (same commit);
- `core:fs` documents a tick subtraction in `unix_nanoseconds` that would wrap
  an unrecorded time into the far future.

All three are `int` or `i64`. Nothing in `core`, `base`, or the examples relied
on signed wrap: turning the rule on changed three corpus programs, each of which
existed to demonstrate wrapping. The rule is also what the rest of the language
already did where a value does not fit — `u32(-0.5)` panics, while
`i32(2147483647) + 1` gave `-2147483648` silently.

So signed `+`, `-`, `*`, `/`, and unary `-` panic when the mathematical result
does not fit, at every optimization level, and are a diagnostic (L0397) where
they are evaluated at compile time. Unsigned arithmetic stays modular, since
hashing and bit manipulation are written in it, and signed wrap is spelled by
computing in the unsigned type and converting back, which keeps the low bits.
The exceptions each keep an existing definition: `<<` is a bit operation whose
limit is already defined for every count; `%` cannot overflow; a SIMD lane has
no per-lane overflow flag to test; an atomic `add` is a hardware
read-modify-write whose other readers have already seen the result; and integer
conversion is the explicit wrap.

The cost is a checked operation, `llvm.sadd.with.overflow` and its siblings, per
signed arithmetic step, much of it removed where loop bounds already prove the
range. It returns part of what wrapping cost: on the path that continues, the
result is known to be in range, so the optimizer may widen induction variables
the old rule forbade it to.

### `in` is a comparison, not an additive operator

Odin places `in` at the comparison precedence level and Loke had moved it to the
additive one. That silently regrouped `x in values + extra` as
`(x in values) + extra`. `in` produces a `bool`, so it belongs with `==` and `<`.

### Comparisons do not chain

Odin, like C, groups comparisons left, so `a == b == false` is
`(a == b) == false`: for `a := 1; b := 2` it is `true`, although it reads as a
chain and is not one. Ordering chains such as `1 < 2 < 3` were already rejected
by type, leaving only the misleading `bool` equality chains. Making the
comparison level non-associative, as the range level already is, turns every
such chain into a syntax error whose note gives both the parenthesised form and
the `&&` chain. Nothing expressible is lost: `(a == b) == c` still means what it
says.

### Field order stays inside the declaring package

Odin accepts an imported struct's positional literal, so reordering the
struct's fields, a routine change to remove padding, silently swaps any two of
the same type at every such site; destructuring would add more. With
`Point :: struct { y: int, x: int }`, formerly `{ x: int, y: int }`,
`x, y := origin_offset()` would put the old `y` in `x`, and `Point{3, 4}` would
set `y` to 3, and both would compile. Outside the declaring package both forms
are therefore rejected in favour of named fields, as Go vet treats unkeyed
fields of an imported struct. Inside the package, a reordering is a change its
author can see. Anonymous records are unaffected, since their field order is
their type identity, so `core:container`'s `Enum_Array` yields
`(key: E, value: T)` rather than a nominal entry struct. The migration was 85
literals, all in tests; 50 of them were `core:math` `Complex` and `Quaternion`
values in one file.

### Diverging procedures belong to the declaration

Loke takes Odin's `-> !`. Before it, a call that never returned could not say
so: `os.exit` at the end of a value-returning procedure was L0365, and `panic`
was not a value, so `m.lookup_value(key) or_else panic("missing")` was L0309.
The library wrote a one-line procedure per fallback type instead, ten in core
and nine in tests, all now gone.

Unlike Odin, divergence is not part of the procedure type. A diverging call
takes whatever type its context expects, which the checker settles from the
callee's declaration; carrying it through procedure values would add a
subtyping rule (`proc() -> !` wherever `proc() -> T` is expected) for a case
nothing in the tree needs. A later change can add it without breaking code.

### The allocation built-ins follow the `try_` convention

Odin's `new` and `make` return the value and an error. Loke's returned a
`Result` under the plain name, the opposite of the library-wide convention
that `try_` marks the form returning the failure its plain form would panic
on. Callers wanted both: of the twelve calls in `core` and `base`, seven
returned or reported the error and five turned it into a panic through a
one-line helper, and design.md's `make` examples used `or_else {}`, which
turns an allocation failure into an empty container. `new`, `new_clone`, and
`make` now follow the allocator's failure policy, and `try_new`,
`try_new_clone`, and `try_make` return the `Result`. About a hundred calls in
`tests/` changed spelling.

### `main` may return an `i32` status

Odin's `main` has no result, and neither had Loke's. Since `os.exit` runs no
cleanup, a program that had to fail after cleanup moved its body into a
helper and called `os.exit` on what the helper returned. `main :: proc() ->
i32` returns the status instead, after its scope-exit actions, as C's `main`
does. The status is `i32` because that is what the process gets: `os.exit`
took an `int` and narrowed it, so `os.exit(4294967297)` exited with 1. It now
takes an `i32` as well, and a wider value needs an explicit conversion.

### `assert` and `panic` print values after the message

Odin's `assert` and `panic` take a runtime message string, and `fmt.assertf`
and `fmt.panicf` format one. Loke's message is a compile-time string, so the
report never needs an allocation that could itself fail, and a failed check
could not say which value failed it. Values now follow the message as
`..any_view` arguments. The generated code formats them onto the report line
through the same per-type formatters `fmt.print` uses, writing straight to
the error stream, so `base` and `core` code can use them without importing
`core:fmt`. The runtime's panic entry is split into a begin and an end so the
values land between the message and the newline. An `assert`'s arguments are
evaluated only on the failing path, like its message in C, so an expensive
argument costs nothing while the check holds.

### An iterator's yield mode follows from `next`

An iterator used to declare a `Yield` descriptor, built from the predeclared
markers `Yield_Owned`, `Yield_Borrowed`, and `Yield_Mutable`, and the checker
computed `Item` from it and `Element`. The declaration carried no
information: `next` already says what it returns, and a `Yield` that
disagreed with it was an error. The checker now reads the mode off `next`'s
`Item`, as it reads `Iterator` off `iter`, and the three markers are gone from
the universe. The library declared `Yield` three times, in
`Small_Array_Iterator` and the two `Enum_Array` iterators, and the compiler
no longer synthesizes one for its own iterators. The derivation tries owned
before borrowed, so an element that is itself a pointer, returned unchanged,
stays owned; the old descriptor could say otherwise only by making `Item` a
pointer to the pointer, which `next` would then have to return anyway.

### A map's mutable lookup is the marked one

Everywhere else the mutable form is the marked one: `^mut`, `[]mut`,
`dyn mut`, `iter_mut`, `get_mut`. The map had it the other way round, with
`find` returning `Option(^mut V)` from an `inout` receiver and the read-only
probe spelled `find_ref`. `find` now returns `Option(^V)` and `find_mut`
`Option(^mut V)`. Every call in the tree was renamed to keep its meaning.

### A `[]mut T` destination selects a mutable slicing overload

A slice of a mutable place is `[]mut T` when a `[]mut T` destination asks for
one, but a user container could not do the same: `operator([:])` overloads
were ranked by their arguments alone, so `Small_Array`'s one read-only
overload made `sv: []mut int = s[0:2]` L0310 where the same line over a
dynamic array compiled. A `[]mut T` destination now counts as a place
position for slicing, as an `inout` argument does for indexing, and
`Small_Array` has a `span_mut` overload for it. Its `slice()` stays: a method
receiver is not a destination, so `small.slice().indexed()` still names the
mutable view it iterates.

### A string literal receiver is a static `string_view`

`"hello".len()` compiled and `"hello".bytes()` was L0363, because an unfixed
receiver took its default type, `string`, through ordinary method lookup,
while the text operations looked only at receivers whose type was already
fixed. A literal's storage is static, so the receiver that describes it
without an owner is a `string_view`, and nothing borrowed from it can end:
`"hello".bytes()` may be returned from a procedure. An extension method
declared on `string` alone no longer applies to a literal receiver; the
view is what the literal is.

### Map element mutation

Odin prohibits `m[key].field = value`. Loke permits it because indexing a user
type can already return an `inout` place, and built-in maps should follow the
same place rules. It writes a field of an element that must already be there:
creating one to hold a partial update was a way to end up with a half-written
object nobody asked for, and it made the read depend on whether the element type
had a zero at all. So the whole-element assignment `m[key] = elem` is the one
index form that creates an entry — it writes the value, so nothing is
manufactured — and every other position panics for a missing key, as a dynamic
array's index does. `m.find(key)` answers `Option(^mut V)` without inserting,
and `m.find_or_insert(key, elem)` answers the slot either way, so a caller that
wants a default names the default rather than inheriting the element's zero.

### Container insertion takes its element like an initialization

`append`, `insert`, `try_insert` and `find_or_insert` once borrowed their
element and cloned it in, which left a move-only element no way into a
container but `m[key] = elem` and a literal. Giving them `move` parameters was
rejected: `move(...)` needs a lexical owner, so `d.append(File{...})` could not
be written at all, and `d.append(move(x))` would be required for every `int`.
Instead the element is taken exactly as `x := elem` takes it — a temporary or
`move(x)` transfers, a borrowed place copies — which is already what assignment
and literals do. A copyable element reads and behaves as before; a move-only one
needs `move(x)` only where any other copy of it would. The operation owns the
element from the call, so it drops the one it does not store: the duplicate a
`find_or_insert` hit makes unnecessary, or a pack an allocation failure left out.

### `string` borrows as `string_view`

`string` converts implicitly to `string_view`. Without it the two types compete
for every signature that reads text: an API taking `string` cannot accept a
substring without allocating one, and an API taking `string_view` makes every
caller holding a `string` write a conversion. The conversion is a borrow, costs
nothing, and needs no validation, so the division is simply that `string_view`
reads and `string` owns. It is one-way; going back allocates, via `.copy()`.

### String ownership and concurrency

`string` is an immutable owning value. Implementations may share backing storage,
so a shared reference count is atomic. The allocator that eventually frees the
storage must separately support the thread on which the last drop occurs; as for
other owner lifecycles, version 1 leaves that transfer check to the programmer.
Code that does not want shared ownership uses a byte slice or `string_view`.

### Allocation failure

Implicitly allocating expressions have no result slot for an error, so each
allocator carries a failure policy. `.Panic` is the default because continuing
with a silently truncated value would corrupt later results, and `.Trap` is the
freestanding alternative. Recoverable allocation uses `try_` operations. The
earlier `.Error` policy was removed with ambient context because its sticky error
slot was a hidden side channel and could not identify which implicit operation
had failed.

## Changed syntax

### Statement termination

Statements end in `;` unless their outermost form ends in a declaration or
statement block. A block-closing `}` terminates that form; a trailing semicolon
is accepted only as a separate empty statement. This keeps termination
deterministic without requiring a redundant `;` after a block.

### `transmute` is a procedure in `core:unsafe`, not an operator

Odin spells a bit cast `transmute(T)value`, which needs a reserved word and its
own unary binding rule. Loke writes `unsafe.transmute(T, value)` and makes it an
ordinary call — types are already passable as arguments, so nothing was gained
by the operator form except a keyword. `move` stays a keyword because it is also
a parameter mode and has to be reserved regardless.

It is not predeclared either. Reinterpreting bits is not a safe, universally
valid conversion: nothing about the source value says the destination
representation is one its type ever admits. That is the same loss `raw_data` and
`free` make visible, so it is spelled at the same boundary and an import says
the program does it.

### Parenthesized control-flow headers

Loke requires parentheses around every control-flow header, for example
`if (x >= 0) {}`. Odin omits them and needs a special parsing rule to
distinguish some condition expressions from composite literals. Loke's uniform
header shape keeps the header separate from the body brace.

### Slice literals state their capability

Odin's `[]int{1, 2, 3}` produces a mutable slice. Loke has two slice types, so
the literal is written with the one it produces: `[]int{...}` is read-only and
`[]mut int{...}` is not. Inferring `[]mut T` from a literal spelled `[]T` would
have made the most common example of a mutable slice the one place in the
language where a written type does not describe the value.

### No uniform call syntax

`x.f()` resolves only to a `self` receiver declared in an `impl`
block, or to a built-in container operation. There is no rule rewriting `f(x)`
as `x.f()`, and none rewriting `f(x)` to a receiver either — see
[Standard free aliases](#standard-free-aliases) above. Free procedures therefore
never acquire a method spelling by accident, and every receiver operation reads
the same way: `x.len()` and `x.append(v)` are both calls on a named receiver.

### `foreach`

Odin's `for value in values` form is written `foreach (value in values)`.
Keeping `for` and `foreach` separate makes the repetition form visible at the
keyword and lets `in` retain its membership-operator meaning in an ordinary
`for` condition.

`for (key in counts)` is nonetheless rejected: it is the header a programmer from
Odin, or one who forgot `foreach`, writes, and as a membership loop it compiled
and ran whenever `key` happened to be declared, or failed with only "unknown
name `key`". `for` therefore takes the rule `switch` already uses for the same
collision: the membership loop is `for ((key in counts))`.

## Features kept close to Odin

### Foreign declarations

The foreign system intentionally remains close enough to Odin that maintained
bindings can be ported mechanically. A port mainly updates visibility and
attributes and replaces owning C-string assumptions with `cstring_view` or the
appropriate explicit foreign-string type. Bindings keep foreign symbol spelling
and can expose an idiomatic wrapper separately.

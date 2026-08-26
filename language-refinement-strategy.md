# Loke language refinement strategy

Status: proposed

This document describes how to make Loke simpler and more orthogonal without
losing the reasons for creating it. It is a strategy for evaluating and staging
language changes, not a replacement for the normative specification in
[`design.md`](design.md) or the open questions in [`comments.md`](comments.md).

## Outcome

The strategy is to consolidate before adding more features. Loke should have a
small set of semantic mechanisms that compose predictably, even when some of
those mechanisms receive specialized compiler lowering.

Orthogonality and simplicity are good design constraints, but they are not the
only goals. A change is an improvement only when it also preserves Loke's core
promise:

- high-level abstractions with low-level control;
- visible ownership and allocation obligations;
- deterministic behavior at calls and package boundaries;
- practical C ABI interoperability;
- useful local lifetime checking without requiring Rust's complete safety
  model; and
- ordinary source code at compile time where its executed operations permit it.

The central rule for refinement is:

> One expression has one meaning and one result type, and one semantic concept
> has one primary mechanism.

Shorter syntax is not sufficient. Semantic compression matters more than token
compression.

## What “better” means

A refinement should improve most of these properties and must not seriously
damage any of them:

1. **Local reasoning.** A reader can determine an expression's behavior from
   that expression and the types involved, without inspecting its destination.
2. **Composability.** A value can be bound, stored, passed, returned, and used by
   generic code without changing which language rules apply to it.
3. **One lookup story.** Built-ins and user declarations participate in the
   same visible model whenever their semantics permit it.
4. **Explicit obligations.** Mutation, ownership transfer, allocation choice,
   unchecked access, and failure propagation remain visible.
5. **Small specification surface.** The change deletes exceptions, special
   contexts, or parallel mechanisms from the language description.
6. **Small compiler surface.** The implementation needs fewer independent
   resolution paths and fewer producer-specific semantic cases.
7. **Good diagnostics.** An invalid program fails at the operation that broke a
   general rule, rather than later because a special case did not apply.
8. **Predictable lowering.** Simplification must not silently introduce
   allocation, copying, dynamic dispatch, or ABI changes.

Specification line count and grammar production count are useful signals, but
not goals by themselves. A slightly longer statement of one universal rule is
better than a short statement followed by many exceptions.

## Design laws

### 1. Context must not change an expression's meaning

Assignment arity, a comma-ok destination, or use as the left operand of an
operator should not change whether an expression traps, returns zero, or
produces a status value.

Different behavior needs a different operation. For example, a trapping union
extraction and an optional extraction should have distinct spellings, and map
indexing and optional map lookup should be distinct operations.

### 2. Capabilities belong in values and types

Read-only versus mutable access, ownership versus borrowing, and checked versus
unchecked access should be represented by types or explicit value-forming
operations. They should not be inferred from an unrelated syntactic context.

The current `^T`/`^mut T`, `[]T`/`[]mut T`, `dyn I`/`dyn mut I`, and
`&`/`&mut` capability matrix is a model to preserve. It expresses one axis in a
regular way.

### 3. User-visible regularity matters more than compiler uniformity

The compiler may intrinsically lower arrays, maps, strings, operators, copying,
or dropping. That does not require a separate user-facing lookup or declaration
model for every intrinsic.

Conversely, forcing fundamentally different operations through one syntax is
not useful orthogonality. C pointers and checked borrows may remain distinct
when their safety and lifetime contracts are genuinely different.

### 4. Prefer libraries when language semantics are not required

A feature belongs in the language when it affects parsing, static semantics,
layout, lifetime checking, control flow, or ABI in a way a library cannot
express. Convenience operations and policies should normally be library code,
even if the compiler supplies an optimized implementation of the standard
version.

### 5. Every new mechanism pays a complexity cost

A proposal that adds a keyword, type category, lookup path, parameter mode,
contextual typing rule, or compiler hook must do at least one of the following:

- remove an existing mechanism;
- make previously special values compose as ordinary values;
- close an important expressiveness gap that libraries cannot close; or
- enforce one of Loke's stated safety or predictability guarantees.

Convenience alone is not enough during the consolidation period.

### 6. Compatibility is temporary, not a second language

Loke is a private project with no users outside this repository, so no change
in this program owes anyone a compatibility period. Migrate the whole source
and test corpus with each semantic change, and never preserve two spellings or
two lookup systems as a transition aid. A deprecated path still consumes
language and compiler complexity until it is removed.

This is a decision, not an observation to re-derive each phase. If an external
consumer ever appears, revisit this law first, because it sets the cost of
every other phase.

## Decision process

Every substantial language proposal should include the following evidence.

### Mechanism inventory

List what the current feature needs in:

- grammar and contextual parsing;
- type and value categories;
- name or member lookup;
- overload resolution;
- lifetime and ownership analysis;
- compile-time evaluation;
- runtime representation and ABI;
- diagnostics; and
- library/compiler special cases.

Then list which entries the proposed design adds and deletes. The proposal
should normally delete more independent semantic rules than it adds.

### Representative programs

Show old and proposed source for at least:

- a small direct use;
- a generic use;
- a managed or move-only value;
- a failure path;
- a compile-time use where applicable;
- a foreign boundary where applicable; and
- a deliberately invalid use with its expected diagnostic.

A feature that is elegant only for scalar examples is not ready.

### Competing designs

Compare at least the status quo, the proposed design, and the smallest viable
alternative. Include “remove the convenience and use an ordinary library
operation” when that is possible.

### Vertical prototype

Implement or model one complete path before changing the whole language. The
prototype must include parsing, checking, lowering or evaluation, diagnostics,
and representative tests. It is evidence for a decision, not an implicit
commitment to merge the design.

### Decision record

Record the selected design and rejected alternatives in `comments.md` or a
focused plan. Merge the normative `design.md` and `grammar.md` changes together
with the implementation and migrated examples, so the repository never has two
current definitions of the language.

## Refinement program

The phases below are ordered by semantic leverage, not by implementation ease.
They are not a queue. Serialize two phases only where they touch the same
mechanism; run independent phases whenever it suits the work.

The real dependencies are:

- Phase 1a is a prerequisite for Phase 1b, and both are prerequisites for a
  final answer to Phase 2 — but Phase 2's cheapest alternative should be chosen
  first, because it decides what Phase 1 is migrating toward.
- Phase 5 depends on Phase 3, not on Phase 4: making `Map(K, V)` an ordinary
  library type requires the canonical-member model to carry indexing, literals,
  and iteration.
- Phase 4 is independent of everything else here.
- Phase 6 depends on all of them.

Phase 3 is already in progress: `src/customization.odin` installs canonical
receiver members, and [`interface-plan.md`](interface-plan.md) stages the
interface half. That work does not need to stop and wait for Phase 1.

What must not be parallelized is *shipping*: finish and remove a superseded
mechanism before the next change lands on top of it, so the repository never
carries two current definitions of one concept.

### Phase 0 — establish the baseline

1. Freeze discretionary feature growth while consolidation is active.
2. Run and preserve the complete test and optimization matrix.
3. Record, for the producers Phase 1a touches, every compiler branch that exists
   only for one built-in producer or one destination context.
4. Add characterization tests for exactly those producers: checked extraction,
   map lookup, validating conversion, and their interaction with `or_else`,
   `or_return`, and comma-ok destinations.

Do not attempt a whole-language inventory. Each later phase writes its own
characterization tests as a first step, against the mechanisms it actually
changes; a speculative inventory of `inout` results or standard customization
ages out before Phase 3 or 4 reaches it.

Exit condition: every destination-sensitive behavior listed in step 4 has a
failing-if-changed test, and the branch list in step 3 is small enough to serve
as Phase 1a's deletion checklist.

### Phase 1 — make fallibility context-independent

This is the highest-priority refinement because the current result-position
protocol affects built-ins, calls, assignments, fallback, propagation, named
results, and definite initialization.

Part of it is already done. `4cf660c` defined the status protocol once and
shared it with `or_else`, `7400c12` made `Allocator_Error` a status so
allocations propagate, and `72ea7c7` aligned the milestone plans with the
result. [`design.md`](design.md) now states one status shape and one fallback
rule for procedures. What remains is not the protocol; it is the built-in
producers that still read their destination.

The remaining defect is stated in the specification itself: *"Single-value
behavior is per-producer"* — a missing map lookup yields zero, while a failed
single-value checked extraction panics. Checked extraction has optional-ok
semantics in a comma-ok destination and traps outside one; validating
conversion behaves the same way.

The phase therefore splits into a cheap change that fixes the stated defect and
an expensive change that reshapes how absence is typed. They have very
different costs and must be decided separately.

#### Phase 1a — give each behavior its own spelling

Split every destination-sensitive producer into distinct operations, keeping
the existing status protocol as the result shape:

```odin
value.(T)       // always checked and trapping
value.as(T)     // always non-trapping, one fixed arity
table[key]      // one ordinary indexing behavior
table.get(key)  // always non-trapping, one fixed arity
```

Final names come from the prototype. The migration is bounded: roughly 19 of
the 362 `.loke` files under `base`, `core`, `examples`, and `tests` mention
`or_else` or `or_return` at all.

Exit conditions:

- no destination changes the number of results an expression produces;
- no producer changes between trapping and non-trapping by context; and
- the per-producer paragraph is deleted from `design.md` rather than reworded.

#### Phase 1b — decide whether absence becomes a type

Only after 1a lands, evaluate representing absence and failure as ordinary
`Option(T)` and `Result(T, E)` values rather than as a trailing status result,
with `or_else` and `or_return` specified by operand type.

This is a separate decision because 1a already satisfies every context-
independence goal above. What 1b adds is composability: a generic procedure
accepting or returning a fallible value without privileged producer syntax, and
one absence convention across the standard library.

What it costs is a real type family — layout, reflection, generic, lifecycle,
and ABI rules — which is precisely the bill that design law 5 and property 8
(*predictable lowering*) exist to make visible. A trailing `bool` status lowers
to a second C-ABI return today; `Option(T)` needs its own guaranteed layout to
keep that true.

1b also reverses a recorded decision. [`design.md`](design.md) currently states
that nothing prevents a library from declaring `Option :: union($T: type) {T}`,
but that the core library does not and no language construct is aware of one.
The prototype must cite that passage and rebut it directly; per the decision
record rule above, a reversal that routes around the existing entry leaves two
current answers in the repository.

The prototype must compare `Option`/`Result` against the smaller alternative of
keeping the explicit status protocol from 1a unchanged. Keeping it is the
default outcome; 1b wins only by demonstrating the composability gap on a
generic and a managed-value program, not on scalars.

Exit conditions:

- `or_else` and `or_return` are specified by operand type, not trailing-result
  position;
- the standard library uses one absence/failure convention; and
- the recorded `Option` decision in `design.md` is replaced, not contradicted.

### Phase 2 — decide whether multiple results become tuples

First-class tuples are not automatically simpler: they add a real type family,
layout, reflection, generic, lifecycle, and ABI rules. They are worthwhile only
if they replace enough special behavior.

This phase is entangled with Phase 1 and cannot simply follow it. A
multiple-payload `or_else` fallback must be a multiple-result call today,
because Loke has no tuple literal to provide a second spelling — so whether
payloads are tuples decides what `or_else` consumes, and Phase 1 is migrating
toward an answer this phase has not given.

Resolve that by choosing alternative 1 provisionally before Phase 1a starts. It
costs nothing to choose, since it is the status quo, and it lets Phase 1a
migrate against a fixed target. Revisit it here with real evidence.

Prototype these three alternatives:

1. keep special multiple results after Phase 1;
2. introduce first-class tuples and general destructuring; or
3. use named structs for multi-value results and remove most multiple-result
   convenience.

If tuples win, procedure results become ordinary tuple values at the language
level even when the ABI lowers their components separately. The same pattern
rules should then serve local declarations, assignment, `foreach`, and other
destructuring positions. There should not be one tuple-like facility for calls
and another for loops.

Exit condition: Loke has one documented model for grouping and destructuring
multiple values, with lifecycle and generic behavior proven on managed values.

### Phase 3 — converge customization and interface lookup

This phase is in progress. `src/customization.odin` already installs canonical
`len`, `cap`, and `hash` receiver members for built-in types and resolves the
standard free spellings to them instead of forming independent overload groups.
[`interface-plan.md`](interface-plan.md) stages the interface half in four
phases and is the detailed plan for that work; this section states the language
goal it serves, and the two documents must be changed together.

One tension to settle there rather than by default: the `implements`
declaration proposed by `interface-plan.md` adds a keyword and a top-level
declaration form while explicitly remaining a checked assertion rather than a
nominal gate, so it removes no existing mechanism. Under design law 5 it must
justify itself as closing an expressiveness gap or enforcing a stated
guarantee — declaration-site conformance diagnostics — and the plan should say
which, in those terms.

Continue the current direction in which standard free spellings select a
canonical receiver member rather than forming independent overload sets. Then
choose one final source-level rule:

- method-only customization; or
- uniform call syntax for every eligible method.

The recommended endpoint is method-only customization because it keeps lookup
visible and prevents an ordinary lexical call from acquiring receiver behavior
by accident. A permanent closed list of privileged free aliases is less
orthogonal than either endpoint and should be transitional unless there is
strong usability evidence for retaining it.

Operators, indexing, iteration, hashing, formatting, cloning, and dropping
should be declared through one recognizable `impl` and member model. The
compiler may attach special semantic roles to some canonical members, but that
role should not create an unrelated lookup mechanism.

Interfaces should also be narrowed. The preferred interface body contains:

- named method slots;
- associated types and constants;
- interface composition; and
- ordinary Boolean `where` clauses for value predicates.

Avoid a validity expression whose truth is ignored alongside a visually similar
composition expression whose truth is required. Retain structural satisfaction
unless a separate proposal demonstrates that nominal conformance improves
coherence enough to justify its registry and orphan rules. A file-scope
assertion can provide declaration-site checking without introducing a second
meaning of conformance.

Exit conditions:

- a diagnostic can describe one lookup trace for a built-in or user type;
- generic and direct calls see the same canonical operation;
- an interface requirement has one of a small number of explicit meanings; and
- adding a standard operation does not require adding another lookup engine.

### Phase 4 — evaluate a first-class reference model

Do not replace `inout` merely because a first-class reference looks more
orthogonal. Call-bound `inout` deliberately limits where exclusive aliases can
flow, and that restriction may be simpler overall than general reference
lifetime rules.

Prototype and compare:

1. the current `inout T` parameter/result modes;
2. a non-null scoped `ref T`/`ref mut T` type alongside nullable pointers; and
3. pointer-only signatures using `^T`/`^mut T` with strengthened non-null and
   lifetime contracts where required.

The comparison must cover whole-owner invalidation, interior projections,
returned places, method receivers, alias suspension, storage in aggregates,
generic matching, foreign ABI lowering, and diagnostics. A reference type wins
only if it removes more parameter/result and place rules than its lifetime and
storage restrictions add.

Exit condition: parameter passing, returned borrows, and stored pointers have a
small set of distinctions that correspond to real differences in nullability,
lifetime, ownership, or invalidation.

### Phase 5 — evaluate containers and storage policy

Fixed arrays and slices directly express layout and borrowing, so they remain
good language primitives. Dynamic arrays and maps should be evaluated as
ordinary generic library types with intrinsic lowering hidden behind their
implementation:

```odin
Vec(T)
Map(K, V)
```

This is preferable to merely shortening `[dynamic]T`, especially because
`dyn` already denotes runtime interface erasure.

This phase depends on Phase 3, not on Phase 4. `Map(K, V)` can only become an
ordinary library type once the canonical-member model carries indexing, literal
construction, and iteration for a user-declared type as well as it does for the
built-in. Hiding the intrinsic lowering behind a library implementation is the
hard part of this phase and should be prototyped before its spelling is
discussed.

The same phase should examine declaration-specific `via` and `manual` policies.
Compare them with explicit value construction and wrappers such as
`Manually_Drop(T)`. Do not change them unless the alternative preserves:

- visible allocator selection;
- correct region provenance;
- predictable cloning and assignment allocators;
- inert zero values where required for static initialization;
- failure atomicity; and
- exact cleanup behavior.

Exit condition: every remaining storage modifier changes a binding property
that cannot be represented more clearly by an ordinary value or type.

### Phase 6 — simplify surface syntax last

Only after semantic consolidation should the project reconsider declaration
punctuation, container spelling, package headers, semicolon rules, or other
surface syntax. Earlier syntax churn makes semantic migrations harder to review
and can create the impression of simplicity without reducing the language.

Apply the same test: a syntax change should remove a parsing ambiguity,
eliminate a special grammar production, or make an important semantic
distinction visible. Character count alone is not a sufficient reason.

## Changes to retain unless contrary evidence appears

The refinement effort should not destabilize mechanisms that already express a
clear general rule:

- the checked borrow capability matrix;
- explicit `move`, `drop`, and `exchange` operations;
- deterministic lexical cleanup and its ordering with `defer`;
- ordinary procedures evaluated at compile time when admissible;
- structural specialization separated from Boolean `where` filtering;
- coherent inherent behavior for hashing, formatting, and erased witnesses;
- explicit `core:unsafe` boundaries; and
- C-compatible foreign types and calling conventions.

These may need smaller repairs, but replacing them is not a current objective.

## Features to defer during consolidation

Do not add broad new systems such as owning runtime polymorphism, recoverable
panics, token macros, purity/effects, garbage collection policy, or concurrency
refinements while the core mechanisms above are changing. Record useful cases
in `comments.md` and revisit them after the refinement program. Deferral is not
rejection; it prevents a new feature from being designed around rules that are
about to disappear.

## Verification for every phase

Each phase must:

1. update `design.md`, `grammar.md`, examples, and implementation together;
2. migrate all `base`, `core`, `examples`, and `tests` source rather than leave
   two permanent mechanisms;
3. add positive, negative, generic, managed-value, compile-time, package, and
   LLVM tests as applicable;
4. run the full `test-all.ps1` matrix at every optimization level;
5. compare generated ABI and runtime behavior where the change is intended to
   be source-only;
6. verify that diagnostics identify the general violated rule; and
7. record which grammar productions, semantic branches, and specification
   exceptions were removed.

## Stop conditions

Reject or redesign a proposed simplification when it:

- only shortens spelling;
- replaces one special case with another special case elsewhere;
- makes mutation, allocation, transfer, failure, or unchecked access less
  visible;
- requires callers to know a callee's implementation to predict behavior;
- creates a second lookup or conformance model;
- weakens C interoperability without a compensating boundary design;
- introduces hidden allocation or dynamic dispatch in previously static code;
- makes common diagnostics less specific; or
- needs an indefinite compatibility subsystem.

## Initial decisions

This strategy makes the following decisions now:

1. Adopt context-independent expression meaning as a language design law.
2. Consolidate before expanding the feature set.
3. Loke has no external users, so every change migrates the whole corpus and no
   transitional spelling is retained.
4. Do Phase 1a first: split the destination-sensitive producers into distinct
   spellings under the existing status protocol. Typed fallibility is a
   separate, later decision that must beat "keep the status protocol".
5. Provisionally keep special multiple results, so Phase 1a has a fixed target.
6. Continue toward canonical receiver-based customization, then explicitly
   decide between method-only and fully uniform call syntax.
7. Simplify interface requirement forms before adding a conformance declaration.
8. Do not commit tuples, first-class references, library containers, or
   storage-policy changes until their total semantic cost is measured.
9. Treat syntax shortening as the final phase, not the main strategy.

The immediate next step is Phase 0 step 4 followed by Phase 1a: characterize
checked extraction, map lookup, and validating conversion, then give each
behavior its own spelling, migrate the affected files, and delete the
destination-sensitivity rules from `design.md`. That enforces design law 1 with
a bounded diff, and it is also the experiment that shows whether typed
fallibility is still worth its cost.

The intended result is not the smallest possible language. It is the smallest
set of rules that still delivers Loke's intended control, ergonomics, and
predictability.

# Loke language refinement strategy

Status: proposed

This document describes how to make Loke simpler and more orthogonal without
losing the reasons for creating it. It is a strategy for evaluating and staging
language changes, not a replacement for the normative specification in
[`design.md`](design.md) or the open questions in [`comments.md`](comments.md).

## Relationship to the other plans

This document owns priorities, dependencies, and acceptance criteria. Detailed
compiler work belongs in focused plans:

- [`interface-plan.md`](interface-plan.md) owns interface mechanics. Phase 3
  identifies which parts remain applicable and which must be revised; it does
  not create a second interface implementation plan.
- [`consolidation-provenance-plan.md`](consolidation-provenance-plan.md) is the
  second consolidation implementation plan and owns Phase 4a/4b's aggregate
  provenance and call-contract work. It supersedes
  [`provenance-plan.md`](provenance-plan.md), whose motivating programs remain
  historical input, not an implementation checklist. The new plan is not a
  completion claim or adoption of the old inference shortcuts and
  `unsafe.forget_provenance` proposal.
- [`language-design-consolidation-proposal.md`](language-design-consolidation-proposal.md)
  is a candidate value design. Its anonymous records, dual union forms, and
  default `Result` value are evaluated in Phase 2, not accepted by reference.

Requirements such as preserving a borrow through a wrapper are acceptance
criteria. Recommended APIs and representations below are prototype candidates;
their examples do not introduce current language syntax. Selecting the existing
design is a valid outcome where a phase explicitly offers that alternative.

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

Expected types may still resolve literals and implicit selectors. Once an
operation and its operand types are resolved, destination arity must not select
a different result or failure contract.

### 2. Capabilities belong in values and types

Read-only versus mutable access, ownership versus borrowing, and checked versus
unchecked access should be represented by types or explicit value-forming
operations. They should not be inferred from an unrelated syntactic context.

The current `^T`/`^mut T`, `[]T`/`[]mut T`, `dyn I`/`dyn mut I`, and
`&`/`&mut` capability matrix is a model to preserve. It expresses one axis in a
regular way.

Wrapping a checked borrow in a record, union, or container must preserve its
lifetime and access obligations. An ordinary aggregate is not an unsafe escape
hatch. Ownership and allocator-region dependencies must compose through the
same values without being mistaken for borrows of the source variable.

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
- a borrowed value, both bare and inside a record or union;
- the same operation through a direct call and a procedure value;
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

Phase numbers identify workstreams, not an implementation queue. Phase 1a is
the first bounded semantic migration; Phase 4's provenance prototype and the
compatible interface work can start alongside it. Serialize changes where they
touch the same mechanism.

The real dependencies are:

- Phase 0 establishes the baseline before semantic changes ship. Provisionally
  retain special multiple results so Phase 1a has a fixed target.
- Phase 1b and Phase 2 evaluate their shared payload, variant, and default-value
  decisions together after Phase 1a. Neither waits for the other to finish;
  record compatible decisions and ship coupled changes together.
- Phase 4a must land before a Phase 1b or Phase 2 migration moves checked
  borrows into ordinary aggregates. Prototypes may use existing records and
  unions; they do not need new `Option` syntax to test provenance.
- Phase 4b must establish usable call contracts before adopting APIs that
  return or retain these borrows through procedure values. It does not require
  the new reference types evaluated separately in Phase 4c.
- Phase 5a can prototype operation contracts on built-in containers. Moving
  containers into the library in Phase 5b requires Phase 3's canonical members,
  Phase 4's relevant provenance guarantees, and the selected value/result
  conventions. It does not require replacing `inout`.
- Phase 6 waits for the preceding decisions, including any decisions to retain
  existing mechanisms.

Phase 3 is already in progress: `src/customization.odin` installs canonical
receiver members. [`interface-plan.md`](interface-plan.md) supplies diagnostic
and interface argument work to reuse, but its requirement forms and conformance
ordering are superseded as described in Phase 3 below. The compatible work does
not need to stop and wait for Phase 1.

What must not be parallelized is *shipping*: finish and remove a superseded
mechanism before the next change lands on top of it, so the repository never
carries two current definitions of one concept.

### Phase 0 — establish the baseline

1. Freeze discretionary feature growth while consolidation is active.
2. Run and preserve the complete test and optimization matrix.
3. Record, for the producers Phase 1a touches, every compiler branch that exists
   only for one built-in producer or one destination context.
4. Add characterization tests for checked extraction and map lookup, including
   their interaction with `or_else`, `or_return`, and comma-ok destinations.
   Also preserve validating conversions as an existing context-independent
   baseline: they always produce `(value, bool)`, return zero and `false` for
   invalid input, and reject a single-value destination with an arity diagnostic.
5. Characterize one borrow through a record, a union, a helper, and a procedure
   value. Record which cases are currently unchecked so Phase 4 deliberately
   changes those expectations rather than treating them as regressions.

Do not attempt a whole-language inventory. Each later phase writes its own
characterization tests as a first step, against the mechanisms it actually
changes; a speculative inventory of `inout` results or standard customization
ages out before Phase 3 or 4 reaches it.

Exit condition: steps 4 and 5 have characterization tests, including the
fixed-arity conversion baseline, and the branch list in step 3 is small enough
to serve as Phase 1a's deletion checklist. Record accepted unsafe cases as
baseline behavior, not as guarantees the new provenance design must retain.

### Phase 1 — make fallibility context-independent

This supplies the first bounded semantic migration because the current
result-position protocol affects built-ins, calls, assignments, fallback,
propagation, named results, and definite initialization.

Part of it is already done. `4cf660c` defined the status protocol once and
shared it with `or_else`, `7400c12` made `Allocator_Error` a status so
allocations propagate, and `72ea7c7` aligned the milestone plans with the
result. [`design.md`](design.md) now states one status shape and one fallback
rule for procedures. What remains is not the protocol; it is the built-in
producers that still read their destination.

The remaining defect is stated in the specification itself: *"Single-value
behavior is per-producer"* — a missing map lookup yields zero, while a failed
single-value checked extraction panics. Checked extraction has optional-ok
semantics in a comma-ok destination or as the left operand of `or_else`, but
produces one value or panics in a single-value context.

Validating text conversions already have a fixed `(value, bool)` result shape.
Invalid input produces zero and `false`; a single-value use is a compile-time
arity error, not a trapping conversion. Phase 1a preserves these operations and
uses them as a baseline rather than splitting or renaming them.

The phase therefore splits into a cheap change that fixes the stated defect and
an expensive change that reshapes how absence is typed. They have very
different costs and must be decided separately.

#### Phase 1a — give each behavior its own spelling

Split every destination-sensitive producer into distinct operations, keeping
the existing status protocol as the result shape:

```odin
value.(T)               // one payload; traps on a variant mismatch
value.as(T)             // payload plus status; mismatch does not trap
table[key]              // ordinary indexing; no optional second result
table.lookup_value(key) // value plus status; missing key does not trap
```

**Implemented.** These are the names as landed, not illustrative ones. `as`
takes exactly one positional type argument and resolves on the receiver's type,
so a declared member named `as` on any other type is unaffected;
`lookup_value` is a contributed map member with an immutable receiver that
performs exactly one clone of a managed payload, inside the operation. Neither
is the borrowed lookup API proposed in Phase 5a, which may still rename the
pairing with `find`.
Phase 1a changes result arity and mismatch/absence handling, not copying,
allocator failure, or map insertion policy. A payload copy or user hook can
still fail under its existing contract; "non-trapping lookup" must not promise
that arbitrary user code cannot panic. Record the selected indexing policy
explicitly, and change it only in the complete Phase 5a migration.

Final names come from the prototype. Inventory affected uses across `base`,
`core`, `examples`, and `tests`, including comma-ok extractions and map lookups;
counting only `or_else` and `or_return` uses would miss migration sites.
Validating conversions retain their current spelling and fixed result shape.

Exit conditions:

- no destination changes the number of results an expression produces;
- no producer changes between trapping and non-trapping by context;
- validating conversions retain their fixed result shape and single-value
  arity diagnostic; and
- the per-producer paragraph is deleted from `design.md` rather than reworded.

All four hold. One defect was fixed as a consequence rather than preserved: the
old comma-ok map read loaded the element without cloning it while still
registering it for drop, so a managed payload was freed twice. `lookup_value`
clones inside the operation, which makes the two-name form own its payload for
the same reason the one-name form already did.

#### Phase 1b — decide whether absence becomes a type

Only after 1a lands, evaluate representing absence and failure as ordinary
`Option(T)` and `Result(T, E)` values rather than as a trailing status result,
with `or_else` and `or_return` specified by operand type.

This is a separate decision because 1a fixes destination-sensitive result arity
and failure handling. What 1b adds is composability: storing, passing, and
returning a fallible value without privileged producer syntax, and one absence
convention across the standard library. Provenance and container policy remain
separate work even if typed fallibility is adopted.

Even library-declared result types need defined layout, reflection, generic,
lifecycle, and ABI behavior. Measure the additional rules and changed costs
under design law 5 and property 8 (*predictable lowering*), rather than assuming
they need a separate compiler type category. Existing `(T, bool)` procedure
results use the `loke` calling convention and are emitted as one LLVM aggregate.
Foreign calling conventions permit at most one result, so there is no second
C-ABI return to preserve. The prototype must compare the representation and
call lowering of `Option`/`Result` with the current Loke results, and separately
define any C boundary through foreign-ABI-safe wrappers.

Prefer ordinary generic library unions over compiler-owned result types. Count
only the rules that cannot be reused from the selected union model. Phase 2b
settles variant identity, Phase 2c settles default construction, and Phase 4a
must preserve borrows inside their payloads before the migration ships.

If typed fallibility wins, make `require_results` a type attribute on `Result`
so direct and indirect calls share discard diagnostics; `_` remains an explicit
discard. Specify its behavior for containing aggregates and generic wrappers.
This checks discarded results, not whether every error stored in a variable is
eventually inspected. Operator recognition must identify the intended protocol
explicitly, not turn any unrelated two-variant union into an error result.

Adopting `Option`/`Result` would also reverse a recorded decision.
[`design.md`](design.md) currently states that nothing prevents a library from
declaring `Option :: union($T: type) {T}`, but that the core library does not and
no language construct is aware of one. The prototype must cite that passage,
and an adoption proposal must rebut it directly; per the decision record rule
above, a reversal that routes around the existing entry leaves two current
answers in the repository.

The prototype must compare `Option`/`Result` against the smaller alternative of
keeping the explicit status protocol from 1a unchanged. Keeping it is the
default outcome; `Option`/`Result` wins only by demonstrating the composability
gap on a generic and a managed-value program, not on scalars.

Exit condition: record the comparison and complete one of these outcomes:

- **Keep the status protocol.** Record why typed fallibility did not justify its
  cost. Retain the Phase 1a protocol and the existing `Option` decision in
  `design.md`; no language migration is required.
- **Adopt typed fallibility.** Specify `or_else` and `or_return` by operand type
  rather than trailing-result position, migrate the standard library to one
  absence/failure convention, document the representation and ABI decisions,
  prove borrowed and managed payload behavior, define discard diagnostics, and
  replace the recorded `Option` decision in `design.md`.

Either outcome completes Phase 1b once it agrees with Phase 2's related
decisions. Keeping the status protocol does not block the provenance work.

### Phase 2 — unify product, variant, and initialization rules

Evaluate this phase together with Phase 1b. If fallibility becomes ordinary
union values, its payload and variant models must agree; neither decision
should force a second mechanism into the other. The consolidation proposal
supplies examples, not a requirement to adopt its complete design.

#### Phase 2a — one model for grouped values

Compare retaining special multiple results, returning named structs, anonymous
records with structural identity, and a separate tuple family. Provisionally
keep special results for Phase 1a; no product decision is needed for that fix.

Prefer reusing record fields, layout, reflection, and lifecycle rules if grouped
results become ordinary values. An anonymous spelling earns its place only if
it avoids a separate product mechanism. Named structs remain the default for
public concepts and values with invariants or behavior.

The prototype must settle identity and field ordering, generic matching,
destructuring, and ownership of omitted fields. Binding a result before
destructuring it must not conceal new copies. A consuming destructure must drop
discarded fields exactly once and respect custom lifecycle hooks; it cannot
bypass a resource type's invariants merely because its fields are visible.
Use the same destructuring rules in declarations, assignments, and iteration.
Call argument matching may share machinery without materializing an argument
record or changing parameter modes.

#### Phase 2b — one model for union variants

If named variants are adopted, prefer one variant model throughout:

```odin
Value :: union {
    none,
    integer: i32,
    text: string,
}
```

Variant identity is the declared name; absence is an explicit variant. Two
variants may carry the same payload type, so switching and reflection cannot
use payload type as variant identity. Include `Result(int, int)` in the proof.

The consolidation proposal's permanent split between anonymous unions with
implicit nil and named unions without it is not the recommended endpoint.
Keep anonymous syntax only if it is exact shorthand for the same semantics;
otherwise migrate it away with its type-based extraction and nil-state rules.
Any union migration must also migrate the nil-status consumers it changes; it
cannot remove their success state while retaining their old interpretation.
Runtime type inspection of `any_view` and C-compatible integer enums are
separate concerns and need not change as a side effect.

#### Phase 2c — distinguish default values from dead storage

The recommended candidate gives `Option(T)` an explicit `.none` default but
requires explicit construction of `Result(T, E)`. Do not make the first variant
silently determine a successful result such as `.ok(T{})`.

Compare this with retaining the universal zero-value rule. Allowing types
without defaults must be a general type property, not a special prohibition
on `Result`. Define how generic zero construction, omitted fields, and arrays
depend on that property; an empty option need not require a default for `T`.

Local declarations without initializers remain dead until assigned, as in the
current design. Static-duration storage without a default needs an explicit
constant initializer. Empty containers and ordinary scalar defaults remain
useful. Cleared bytes after `move` or `drop` are dead storage, not a completed
initialization: define cleanup without requiring every dead representation to
be a usable value. Verify partial initialization, custom drop hooks, and static
startup before relaxing the current inert-zero requirements.

Exit condition: record the selected product, variant, and default rules,
including retained designs where justified. Any adopted model must demonstrate
managed and borrowed payloads, generic construction, exhaustive inspection,
cleanup, and ABI behavior, and delete the mechanisms it supersedes. Borrowed
aggregate migrations require Phase 4a.

### Phase 3 — converge customization and interface lookup

This phase is in progress. `src/customization.odin` already installs canonical
`len`, `cap`, and `hash` receiver members for built-in types and resolves the
standard free spellings to them instead of forming independent overload groups.
[`interface-plan.md`](interface-plan.md) is an earlier four-phase proposal, not
an unchanged implementation plan for this endpoint. Its shared diagnostics and
type/value arguments with interface `where` clauses remain useful. This strategy
supersedes its proposal to retain general expression and validity requirements,
and its ordering of conformance claims without first narrowing those forms.
Revise the detailed plan to reflect the sequence below before implementing its
interface changes; keep both documents aligned thereafter.

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

The revised interface plan must put a stage for narrowing requirements after
shared diagnostics and interface `where`, and before any `implements`
declaration. That stage must prototype and migrate the standard interface
catalogue and user interfaces to the retained forms, including operator and
associated member requirements, then remove the superseded grammar and checker
paths. Tests for old validity behavior characterize the baseline only; after
migration they must diagnose the removed forms. The earlier plan's concrete
and conditional claim phases remain gated on this migration and the
justification under design law 5 above; any nominal conformance policy still
needs a separate proposal.

Borrowing interface slots must use the same call contracts selected in Phase
4b as ordinary procedures; do not add an interface-only lifetime mechanism.
Their lookup and conformance work remains in `interface-plan.md`.

Exit conditions:

- a diagnostic can describe one lookup trace for a built-in or user type;
- generic and direct calls see the same canonical operation;
- the detailed interface plan reflects this sequence and migrated interfaces
  use only the retained requirement forms;
- an interface requirement has one of a small number of explicit meanings; and
- adding a standard operation does not require adding another lookup engine.

### Phase 4 — make provenance compose through values and calls

Use [`consolidation-provenance-plan.md`](consolidation-provenance-plan.md) for
implementation against the contracts below; it replaces the outdated provenance
checklist. This work can start immediately; it does not depend on adopting typed
fallibility, tuples, or first-class references.

#### Phase 4a — wrapping preserves dependencies

A borrow must carry the same obligations when it is stored in an ordinary
record, fixed array, union, or container. This program must eventually fail for
the same reason as returning `bytes[:]` directly:

```odin
View :: struct { bytes: []u8 }

bad :: proc() -> View {
    bytes := [dynamic]u8{1, 2, 3};
    return View{bytes[:]}; // rejected: the local owner does not survive
}
```

Start with existing aggregates. `Option(View)` and borrowed record results must
later inherit the rule without new producer-specific checks. Preserve three
distinct relationships:

| Operation | Dependency to preserve |
| --- | --- |
| Copy a stored pointer or slice | Its original borrowed root; loading the field adds no new root dependency |
| Take an address or project an `inout` place | The root containing that storage, plus relevant inherited dependencies |
| Move an owner | Its ownership, region, and contained-borrow dependencies; no new borrow of the old binding |

Preserve field distinctions where statically known so selecting one field need
not keep unrelated fields' roots borrowed. Use conservative joins for unknown
indices and control flow; measure false rejections before adding per-element
tracking. Mutable carriers retain their existing exclusivity and reborrow
rules inside aggregates. Container removal, clearing, and returned elements
need explicit rules for when dependencies remain live.

Raw addresses and foreign retention remain documented trust boundaries. Prefer
explicit raw conversions when crossing them. Do not adopt a blanket
`forget_provenance` operation without showing why narrower conversions fail;
erasing root information must never erase a region obligation or count as proof
of a lifetime. Suppressing cleanup with `forget` is a different operation and
does not extend storage lifetime either.

Exit condition: wrapping, selection, movement, and return preserve the correct
dependencies, including through recursive aggregates. Negative tests cover
escaping locals, conflicting mutation, invalidation, and region reset; positive
tests cover independent fields and borrowed parameters that remain live.

This exit condition is met. A type's carrier paths are enumerated to a bounded
depth, and each one carries its own root and capability through copies, moves,
unions, containers, and calls; a cut path joins what lies beneath it, so a limit
costs precision and never a check. Region provenance stayed the separate
per-owner analysis it already was, and step 9 fixed the one place it was still
lost by wrapping: an owner assigned into a *field* of file-scope storage. Field distinctions survive a call: a
helper returning one field of a record argument substitutes that field's root.
The measured false rejections were fixed rather than accepted, and `wrap`/`unwrap`
stayed legal. Element precision follows what an index or key
proves: a small fixed array gives each element its own path, and a map gives a
bounded number of constant keys an entry each, so two elements or two keys
holding two roots stay independent. A removal names the removed element's own
root rather than the container, so `pop` and both `remove` forms hand back the
dependencies the element had. One conservative limit is recorded, and it is the
domain rather than a defect: where no index or key is provable — a dynamic array
index, a runtime key, a long array, a wide map entry — the elements keep one
joined content set.

#### Phase 4b — stable contracts at procedure boundaries

Compare portable inferred summaries with small explicit contracts describing
which inputs a result borrows, whether an input may be retained, and which
mutable destination may retain it. Include root and region dependencies, not
only pointer results. Local inference remains useful; public declarations and
procedure types need a stable, checkable contract.

For example, a parser may return a view of `input` while using `scratch` only
during the call. Passing that parser as a procedure value must not silently
erase the distinction. A helper that stores a view into an `inout` destination
must expose that retention to its caller. These examples specify semantics,
not a chosen annotation syntax.

Check bodies against declared contracts, define compatible procedure-value
assignments, and preserve the contract across packages without changing the
runtime ABI. An unavailable contract must cause conservative checking or an
explicit trust-boundary operation, not an invented safe lifetime. Foreign
wrappers may state audited promises but cannot make foreign retention checked.

This is a bounded proposal about borrowing and retention, not a general effects
system. Reuse the existing allocator-reset contract where possible. Do not
require lifetime parameters everywhere merely to express common local borrows.

Exit condition: the same borrowing operation has a usable, documented contract
when called directly, generically, across a package, or through a procedure
value. Record whether summaries alone suffice or explicit annotations are
needed, and which conservative rejections remain.

This exit condition is met, and the recorded answer is that summaries alone do
not suffice. Inference covers every direct, generic, and cross-package call, but
an indirect call has no body to infer from, so the parser example needed the
distinction written down: `@(escape=<level>)` on a parameter, four totally
ordered levels, `result` by default, part of the procedure type as
`@(allocator_reset)` already is. Bodies are checked against the declared level
and call sites against the argument supplied — including the caller's half of
`stored`, where the call is modelled as the assignment the callee may make, so
the argument's borrows travel into the destination and the existing scope rules
answer the rest without proving one local outlives another. One limit remains: a container
whose element index or key is not provable holds one joined content set.
Procedure-value
compatibility follows the intended ordering — a callee may be assigned, passed,
or returned as a type whose levels are the same or higher than its own, and what
governs a call is always the type of the value called.

#### Phase 4c — reconsider reference types only with evidence

Keep `inout` parameters, receivers, and place results while establishing the
preceding guarantees. Compare the current model with scoped `ref T`/`ref mut T`
types or pointer-only signatures only if real programs expose a remaining gap.

The comparison must cover whole-owner invalidation, interior projections,
returned places, alias suspension, aggregate storage, generic matching, foreign
ABI lowering, and diagnostics. A new reference type wins only if it removes
more parameter/result and place rules than its lifetime and storage rules add.
Keeping `inout` is a complete outcome and does not block container work.

### Phase 5 — evaluate containers and storage policy

#### Phase 5a — separate lookup, borrowing, and insertion

Decide operation contracts before changing container representation. Prototype
this candidate on the current built-in map:

| Operation | Proposed contract |
| --- | --- |
| `get(key)` | Optional immutable borrow of an existing entry; does not clone the payload |
| `get_mut(key)` | Optional mutable borrow of an existing entry |
| `insert(key, value)` | Explicit insertion or replacement, reporting allocation failure |
| `[key]` | Access an existing entry; a missing key traps and never inserts |

Here "optional borrow" means `(^V, bool)` or `(^mut V, bool)` if the status
protocol remains, and the corresponding `Option` values if Phase 1b adopts
them. The current pointer capabilities suffice; no `ref` type is assumed.
Define the receiver capability, borrow duration, and invalidating operations.
An ordinary entry API may support lookup followed by conditional insertion.

Compare this against current indexing and a smaller explicit value-lookup API.
Retaining value lookup must account for copying managed payloads and its
failure policy. The prototype must cover move-only values, replacement cleanup,
ownership of a supplied value on failed insertion, and failure atomicity. A
borrowed lookup avoids a payload clone; it does not promise arbitrary hashing
or equality hooks cannot allocate or panic.

Prefer one canonical fallible mutation with an ordinary explicit panic adapter
over duplicating every operation into ordinary and `try_` families. Prove the
ergonomics under the selected result protocol. This does not remove allocation
from copy assignment: its existing allocator and failure policy remain unless
separately reconsidered with the recorded value-semantics decision.

#### Phase 5b — move representation into libraries where it simplifies rules

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

`Map(K, V)` can become an ordinary library type only when canonical members
carry indexing, literal construction, and iteration, and user-defined borrowing
iterators obey Phase 4's rules. Settle the operation contracts and value/result
conventions first. Prototype intrinsic lowering behind the library before
discussing spelling; changing `map[K]V` to a name alone removes no mechanism.

#### Phase 5c — make owning allocation APIs ordinary values

Prototype an ordinary move-only `Owned(T)` library wrapper as the preferred
application API for an individually allocated value. Its header stays inline
without a separate allocation for wrapper metadata. Preserve allocator choice,
cleanup, region dependencies, and borrowing through direct and indirect calls.
Compare it with existing resource wrappers rather than adding a compiler-owned
box category.

Keep `new`/`free` for explicit low-level allocation. A consuming `into_raw`
operation must transfer all state needed to release or adopt the allocation;
an audited inverse re-establishes ownership. This changes neither the location
of ordinary local values nor the availability of manual allocation. It should
reduce dependence on special fresh-allocation summaries at application APIs,
not hide a release obligation inside a borrowed pointer.

#### Phase 5d — keep storage policy distinct from value ownership

The same phase should examine declaration-specific `via` and `manual` policies.
Compare them with explicit construction, consuming ownership transfers, and
narrow unsafe storage operations. A wrapper that merely recreates `manual`
under another spelling is not a simplification. Do not change them unless the
alternative preserves:

- visible allocator selection;
- correct region provenance;
- predictable cloning and assignment allocators;
- valid static initialization under the default-value rule selected in Phase 2c;
- failure atomicity; and
- exact cleanup behavior.

Exit condition: record the selected operation, representation, allocation, and
storage policies, including justified decisions to retain current mechanisms.
Any adopted changes must preserve borrowing, explicit allocation obligations,
and cleanup. Every remaining storage modifier must describe a binding property
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
- call-bound `inout` parameters and receivers while provenance is repaired;
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
panics, token macros, general purity/effects, garbage collection policy, or
concurrency refinements while the core mechanisms above are changing. Record
useful cases in `comments.md` and revisit them after the refinement program.
Deferral is not rejection; it prevents a new feature from being designed around
rules that are about to disappear.

The bounded borrow/retention contracts in Phase 4b are in scope. They do not
authorize a general effects framework. Likewise, `Owned(T)` is an ordinary
concrete resource wrapper, not owning runtime polymorphism.

## Verification for every phase

For a phase that retains the existing design, record the evidence and decision;
no language migration is required. Every phase that adopts a change must:

1. update `design.md`, `grammar.md`, examples, and implementation together;
2. migrate all `base`, `core`, `examples`, and `tests` source rather than leave
   two permanent mechanisms;
3. add positive, negative, generic, managed-value, compile-time, package, and
   LLVM tests as applicable, including bare versus wrapped borrows and direct
   versus indirect calls;
4. run the full `test-all.ps1` matrix at every optimization level;
5. compare generated ABI and runtime behavior where the change is intended to
   be source-only;
6. verify that diagnostics identify the general violated rule; and
7. record which grammar productions, semantic branches, and specification
   exceptions were removed.

For value migrations, verify cleanup and provenance through construction,
binding, movement, destructuring, fallback, propagation, and partial failure.
Neither an intermediate variable nor an ordinary wrapper may silently remove a
dependency. Record intentional changes to defaults, insertion, copying, and
failure policy rather than hiding them in syntax migration tests.

## Stop conditions

Reject or redesign a proposed simplification when it:

- only shortens spelling;
- replaces one special case with another special case elsewhere;
- makes mutation, allocation, transfer, failure, or unchecked access less
  visible;
- requires callers to know a callee's implementation to predict behavior;
- loses checked provenance when a value is wrapped or passed indirectly;
- creates a second lookup or conformance model;
- weakens C interoperability without a compensating boundary design;
- introduces hidden allocation or dynamic dispatch in previously static code;
- makes common diagnostics less specific; or
- needs an indefinite compatibility subsystem.

## Initial decisions

This strategy makes the following decisions now:

1. Require stable expression contracts and preservation of borrow obligations
   through ordinary wrappers.
2. Consolidate before expanding. Loke has no external users, so migrate the
   whole corpus with each semantic change and retain no compatibility spelling.
3. Make Phase 1a the first bounded migration under the existing status protocol
   and special multiple results. Preserve validating conversions unchanged.
4. Use the rebased `consolidation-provenance-plan.md`. Phase 4a gates borrowed
   aggregate migrations; Phase 4b establishes their contracts at indirect and
   package boundaries. Writing the plan does not complete those gates.
5. Evaluate typed fallibility with the product, variant, and default decisions.
   Prefer reuse of records and one union model; prototype explicit defaults
   instead of an automatic successful `Result`. Keeping the status protocol
   remains a valid outcome and requires no value-model migration.
6. Continue toward canonical receiver-based customization, then explicitly
   decide between method-only and fully uniform call syntax. Keep interface
   mechanics in their own plan, with narrowing before conformance declarations.
7. Keep `inout` and explicit `new`/`free` while prototyping container contracts
   and ordinary owning wrappers. Decide whether to move containers into the
   library only after their semantics and provenance work for user types.
8. Do not commit new reference types, default rules, or storage-policy changes
   without measuring their total cost. Surface syntax remains the final phase.

## Immediate next work

The bounded Phase 1a producer change is complete; its baseline and verification
are recorded in [`consolidation-phase-1a-plan.md`](consolidation-phase-1a-plan.md).
Use [`consolidation-provenance-plan.md`](consolidation-provenance-plan.md) to
establish a fresh provenance baseline and build one integrated prototype:
obtain a borrow from a map, wrap it in an ordinary record or union, and return
it through a helper and a procedure value across a package boundary. Use
existing aggregate syntax first; adopting `Option` is not a prerequisite to
the test.

The prototype must demonstrate:

- acceptance while the borrowed owner and its allocator region remain valid;
- independent record fields without unnecessary lifetime coupling;
- rejection when the owner ends, is invalidated, or its region is reset while
  a dependent value remains live;
- caller-visible retention into a mutable destination, and rejection of an
  escape whose source does not outlive that destination; and
- a stable call contract without boxing, runtime provenance metadata, or
  special compiler treatment of an `Option` wrapper.

If the wrapped or indirect path escapes checking, repair that contract before
shipping the value migration. If conservative checks reject essential library
programs, use those programs to choose the smallest contract or precision
improvement rather than adding a general reference system by default.

The intended result is not the smallest possible language. It is the smallest
set of rules that still delivers Loke's intended control, ergonomics, and
predictability.

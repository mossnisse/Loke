# M4b implementation plan — generics, interfaces, iteration, and erased views

## Context

`compiler-plan.md` splits M4 into two shippable halves.
[M4a](m4a-plan.md) delivered concrete user abstractions: the overload resolution
engine, `impl`/`extend` methods, user operators, `init` conversion, and unions
with their extraction and error protocol. **M4b** makes those abstractions
generic and erasable: `$` parameters and inference, `where`, monomorphization,
interfaces, compile-time reflection, `foreach` and the iteration protocol,
`any_view`, and `dyn` witnesses. It completes B9.

What M4b builds on:

- `overload.odin` from M4a already owns candidate formation, conversion-rank
  vectors, the first three tie-breakers, and the ambiguity diagnostic. M4b adds
  the generic-signature phase, structural-specialization metadata and
  tie-breaker 4, and a shared constraint-viability call used by both ordinary
  resolution and `overload_has_viable`. Structure orders candidates;
  constraints only filter.
- Each declaration records its lookup package (M4a), which is what definition-site
  lookup needs so a caller's `extend` cannot reach into an instantiation.
- Methods, associated constants, and `Type.member` access exist, so an interface
  requirement has something to resolve against, and a type can supply associated
  `Element`/`Iterator` members.
- Unions, checked extractions, and optional-ok exist, so `next` can return
  `(T, bool)` and an extraction's two result shapes are already one construct.
- The M3 evaluator ([eval.odin](src/eval.odin)) runs typed procedure bodies, with
  `require_const` as the single compile-time funnel. `where` bounds, generic value
  arguments, interface applications, and static iterables all route through it.

Type annotations are written back onto AST nodes, and there is no separate typed
tree (decision A1). That single fact drives the largest decision below: a second
instantiation of a generic body cannot annotate the same nodes, so M4b introduces
declaration cloning.

This plan covers compiler implementation. It adds no core library beyond the
unmanaged portion of the interface catalogue written as ordinary Loke source.
The lifecycle-dependent `Cloneable` entry waits for M5's allocator and lifecycle
types. Slices, maps, dynamic arrays, and runtime `string` remain absent, which
bounds what `foreach` and `any_view` can reach.

## Scope

### In M4b

| Area | Contents |
|---|---|
| Generics (B9) | Declaration cloning, explicit `$` type and value parameters, inferred parameters, structural specialization, generic structs/unions/`impl`/`extend` blocks, `where` clauses, the instantiation cache and limits, and per-instance emission |
| Interfaces | `interface` declarations, expression/validity/slot requirements, binding lists, composition, associated types, dyn-compatibility rules, and per-requirement failure diagnostics |
| Catalogue | The unmanaged entries of `base/interfaces/` as ordinary Loke source, exercised through `-collection base=base`; `Cloneable` is appended in M5 once its allocator and lifecycle types exist |
| Compile-time reflection | `fields_of`, `enum_values_of`, opaque descriptors, the compile-time portion of `string_view` needed by descriptor names, `field.get`/`field.pointer`, `type_of`, `typeid_of`, and static `foreach` expansion |
| Iteration | First-class runtime integer-range values; runtime `foreach` over those ranges and fixed arrays, including `&value` and the index binding; plus the `Iterable`/`Iterator` protocol for user types and the `iter` hook |
| Erased views | Runtime `typeid`, `any_view` locals and parameters with checked extraction and type switch, `dyn Interface` values, witness materialization, and slot dispatch |
| Backend | Per-instantiation symbols and mangling, witness globals and receiver thunks, indirect slot calls, first-class range values, compiler-contributed hash operations, `any_view` temporary storage, static-expansion emission, and iteration lowering |

### Deferred after M4

| Deferred | Goes to |
|---|---|
| Slices, `[dynamic]T`, `map`, runtime `string`, general runtime `string_view`/`cstring_view`, and iteration over them | M5/M6 |
| `Cloneable` in the standard interface catalogue and lifecycle-dependent satisfaction | M5, with allocator types and lifecycle hooks |
| `..any_view` variadic parameters, the call-scoped `[]any_view`, and `fmt` | M6, with slices and the seed runtime |
| The library `reverse` adapter and compiler-contributed built-in `iter_reverse` overloads | M6, with the core iterator library; a user-declared `iter_reverse` remains an ordinary overload in M4b |
| Borrow, escape, and exclusivity checking for `any_view`, `dyn`, `inout` results, and `operator([:])` results | M5 (B12) |
| Move-receiver liveness, deep copy, and the `try_clone`/`clone`/`drop` lifecycle hooks; copy-cost diagnostics | M5 (B11) |
| `base:meta` and `base:interfaces` as nameable packages; `runtime.Type_Info`, `type_info_of`, and the emitted type-info table | M6 |
| Receiver and aggregate ABI, `@(packed)`, calling conventions | M7 (B15) |
| Code sharing between identical instantiations, memoized requirement checking, instantiation-graph parallelism | Post-v1 |

## Decisions

| Area | Choice | Why |
|---|---|---|
| Instantiation representation | Add `ast_clone.odin`. A signature instance clones enough syntax to bind generic arguments, substitute parameter and result types, and evaluate bounds without checking the body. Only the selected overload is promoted to a body instance: it clones the complete declaration, reuses the bound arguments and concrete signature, and checks the body. Static `foreach` uses the same general AST-cloning facility for a block per element. | Candidate ranking needs concrete signatures but must not diagnose or check every generic body it considers. Type annotations live on AST nodes (A1), so independently checked bodies still require independent syntax. |
| Instantiation identity | Key the cache on (declaration symbol, canonical argument vector of `Type_Id`s and frozen `Const_Value`s). Identical arguments reuse one instance; distinct instances always emit distinct symbols. | This is monomorphization (A2). Physical sharing of identical emitted bodies stays an unobservable post-v1 optimization. |
| Generic candidate pipeline | During candidate construction, infer and bind generic arguments, create or reuse a signature instance, evaluate its constraints silently, and then rank the written arguments against the substituted concrete parameters. Extend `Candidate` with parametric and structural-specificity facts and implement tie-breaker 4. Both `resolve_overload` and `overload_has_viable` call the same builder. A selected candidate alone triggers body checking and emission. | The current M4a engine has no constraint hook and tie-breaker 4 is a placeholder. Ranking an unsubstituted `$` parameter is impossible, while checking all candidate bodies would produce diagnostics from overloads that are never selected. |
| Instantiation depth | Enforce a documented instantiation-depth and instance-count ceiling, diagnosed with the instantiation stack like an evaluator limit. | Recursive generic instantiation is non-terminating in general; M3's rule that resource exhaustion is a diagnostic rather than a fallback applies here too. |
| Definition-site lookup | An instantiation checks its clone against the *definition's* lookup package (recorded in M4a) for method, operator, and extension candidates, while ordinary name resolution uses a clone scope whose parent is the declaration's lexical definition scope, never the caller's scope. | design.md requires the same instantiation to mean the same thing in every caller, and requires that a caller-local `extend` cannot make a requirement appear satisfied. |
| Constraint placement | Add constraint viability to generic candidate construction after inference and signature substitution and before conversion ranking completes. A failed constraint records a silent candidate reason. Ordering still uses conversion vectors and the four structural tie-breakers alone. | Constraints need bound generic arguments, and the same viability behavior must serve named calls, methods, operators, `init`, indexing, and fallback probes without leaking diagnostics. |
| `where` timing | Evaluate bounds after argument binding and before body checking. A failed bound removes a candidate during overload resolution and is a hard error at a direct instantiation. Reject a bound that depends on runtime state, and a clause with no generic parameters in scope. | A bound is a compile-time predicate over the instantiation, and its failure means two different things at the two sites. |
| Requirement checking and lookup | Substitute the interface arguments, synthesize each requirement as an expression over temporary binding symbols, and check it in a scratch checker whose diagnostics are captured rather than emitted. Free expression and validity requirements use the interface application's lexical lookup package, or the generic declaration's definition package when the application is inside a clone. A named slot is matched only by an inherent method or an extension from the package that declares that slot's owning interface; composed slots retain their own declaring-interface package. Report the specific requirement line and concrete type. | Static expressions obey definition-site lookup, while named slots deliberately have the coherent lookup rule stated by design.md. One undifferentiated scratch-checker package would either admit caller-local slots or hide legitimate interface-package slots. |
| Interface applications and `dyn` formation | A complete interface application in `where` or composition is a compile-time boolean produced through the M3 `require_const` funnel. Forming `dyn Interface(args...)` instead validates the interface declaration, the non-subject arguments, and dyn compatibility; it cannot evaluate satisfaction because the erased subject is absent. Conversion from `^Concrete` checks `Interface(Concrete, args...)` using coherent dyn lookup and then requests the witness. | The subject parameter is deliberately omitted from a `dyn` type. Satisfaction becomes meaningful only when a concrete pointer is converted to that type. |
| Dyn compatibility | Compute compatibility once per interface declaration and cache it with the reason for failure. Forming a `dyn` type reports the first disqualifying rule and the requirement that violated it. | The five rules are properties of the declaration, not of the use site, and the diagnostic belongs at the declaration. |
| `typeid` | During checking, a `typeid_of(T)` constant carries the canonical `Type_Id` symbolically, so equality and compile-time evaluation do not depend on an allocation order. After semantic discovery is complete, a freeze pass sorts all requested concrete types by stable canonical type key and assigns deterministic nonzero `u64` values; zero remains the nil `typeid`. The frozen mapping is used by emission, `any_view`, checked extractions, type switches, and a union's compiler-provided `active_typeid()` method. | `type_info_of` needs the seed runtime's `Type_Info` records (M6), but identity is required earlier. Separating symbolic checking from numeric emission prevents traversal or instantiation discovery order from changing observable IDs and preserves the nil zero value. `active_typeid()` maps tag zero to that nil value and each other tag to its variant's frozen id. |
| `any_view` | `{ ptr data, i64 id }`, non-owning. Enforce its position rules after type resolution with a recursive semantic predicate, so aliases and generic substitutions cannot hide it: the resolved top-level type is permitted only for locals and parameters, and it is rejected recursively in results, globals, fields, containers, captured state, and other stored types. A conversion of a non-addressable expression creates compiler-owned temporary storage lasting through the complete call for a parameter conversion or through the local's scope for a local conversion. Checked extractions reuse M4a's context-flagged `Expr_Checked_Extract`. Provenance, escape, and overlap analysis remains M5. | Position is a property of the resolved type and use site, not merely its written syntax. The backend still needs stable storage for the data pointer even before the borrow checker exists. |
| `dyn` representation and coherence | `{ ptr data, ptr witness }`. A witness is a private immutable global materialized once per `(Interface, Concrete, arguments)` and named from those parts. Its satisfaction and slot selection always use inherent members plus extensions in each slot's declaring-interface package, never the conversion-site package. Every slot entry is a compiler-generated thunk taking the erased receiver pointer. | The witness key is compilation-global, so its lookup policy must also be global and coherent; otherwise the same key could denote different behavior in two packages. |
| Reflection descriptors | Add the semantic `string_view` identity needed for descriptor names, but keep general runtime `string_view` materialization gated until M6. `meta.Field` and `meta.Enum_Value` are compiler-owned compile-time nominal struct types; their values are ordinary `Const_Aggregate`s carrying a constant `string_view` name, `type`, index, and field identity, plus a marker that forbids runtime materialization. Descriptor formation starts from the resolved nominal declaration and its `Type_Info.fields`/enum-member table, which already reflects the selected active declaration, then filters symbols by package/public visibility at the reflection lookup package. A generic clone uses its definition's lookup package. Reflection results are therefore formed per `(type, lookup package)`, not cached by type alone. `field.get`/`field.pointer` are builtins whose result type follows the descriptor constant. M4b records the same visibility on struct fields that other declarations use, but only reflection consults it; ordinary reads, writes, and construction retain M4a behavior until M5 enforces the rule uniformly. | `File.active_items` contains top-level items rather than the fields of a selected type. Reusing `Const_Aggregate` avoids a third constant representation while preserving design.md's reflection rule; the lookup-package key prevents a descriptor array formed inside the declaring package from leaking inaccessible members. Keeping ordinary access unchanged preserves the M4a corpus while making the compatibility exception explicit and bounded. |
| `base:` packages | There is no implicit `base:` root in M4b. A descriptor is reachable only through the value that produced it, and the unmanaged standard-interface subset is ordinary Loke source under `base/interfaces/`, reached in tests by explicitly supplying `-collection base=base`. | M3 deliberately added no implicit import root and there is no core library. The catalogue is ordinary Loke code; writing the currently implementable entries as source dogfoods interfaces instead of hard-coding them. |
| Runtime range representation | Give an integer range expression a compiler-owned canonical `Range(T)` semantic type and a runtime value containing its low endpoint, high endpoint, and closed/half-open flag. Add constant freezing, layout, parameter passing, and evaluator/emitter support; do not add comparison operations that design.md does not specify. Direct `foreach` may optimize the written expression, while a range passed through generic `Iterable` code uses its compiler-provided associated members and opaque iterator. | Direct syntax lowering alone loses the range kind when the value is stored or passed to a generic procedure. The standard catalogue requires runtime ranges to satisfy `Iterable`. |
| Iteration lowering | `foreach` over an integer range or fixed array lowers directly to an index loop; no iterator object is constructed. A user iterable goes through `iter`/`next` with the loop maintaining the two-name index counter. Compiler-contributed associated members and `iter`/`next` candidates make range values and arrays satisfy the same static interfaces. | design.md requires built-ins to satisfy the same static interface, not to be implemented through it. Slice, map, string, and dynamic-array iteration lands with those types. Reverse traversal remains a library adapter rather than an alternate `foreach` lowering. |
| Static `foreach` | Fold the iterable to a compile-time array, enum type, range, or descriptor array; clone and check one body per element; emit nothing for an empty iterable; reject `break`/`continue` targeting the expansion. Diagnostics name the element index and its descriptor. | This is expansion, not a loop, and it shares the cloning facility with generic instantiation. |
| Emission order | Extend M3's rule: name every ordinary symbol, then every instantiation and witness, before emitting any body. Instantiations and witnesses are emitted after their owning package's items in deterministic instantiation order. | Cross-package generic calls and witness references need final names before bodies are written, and reproducible output requires a deterministic order. |
| Diagnostics | Reserve `L0431`–`L0470`: `L0431`–`L0440` generics, `L0441`–`L0450` interfaces, `L0451`–`L0455` reflection and static expansion, `L0456`–`L0461` iteration, `L0462`–`L0470` erased views. `L0391`–`L0399` and `L0406`–`L0430` belong to M4a; `L0401`–`L0405` remain the driver and backend I/O codes in `emit_llvm.odin`. | Fixed ranges keep fixtures stable and keep each family's failures separable across both halves. |
| Corpora | Reuse `tests/run`, `tests/err`, `tests/ll`, and `tests/trap`. Definition-site lookup and cross-package witnesses get directory cases under `tests/pkg` and `tests/pkg_err`; the catalogue is exercised through `-collection base=base`. | The existing corpora already cover single-file and directory cases; M4b adds no new corpus kind. |

## Steps

Each step ends with a built compiler and a green existing corpus. New behavior
gets an exact success or diagnostic fixture in the same step that enables it.

### 1. Generic instantiation, specialization, and `where`

- Add `ast_clone.odin`: deep clones of declarations and statement blocks with
  fresh annotation state, fresh semantic binding IDs, and preserved source
  spans.
- Add generic-template metadata plus signature-instance and body-instance
  states. Insert a provisional cache entry before checking an instance so a
  recursive request is diagnosed with the instantiation stack rather than
  recursively constructing duplicate clones.
- Bind explicit `$` type and value parameters, infer parameters from argument
  types, and implement structural specialization patterns (`[]$E`, `[$N]E`,
  `^Table($K, $V)`) as a matcher that binds parts.
- Refactor candidate construction to infer and substitute a generic signature
  before ranking it, silently evaluate its bounds, record parametric and
  structural-specificity facts on the candidate, and implement tie-breaker 4.
  Route `resolve_overload` and `overload_has_viable` through this same path.
  Do not check an unselected candidate's body.
- Implement generic structs, unions, and both `impl` and `extend` blocks,
  including blocks written for structural or concrete specializations and
  tie-breaker 4 between them. Generic extensions remain in their declaring
  package's extension table and never become inherent members of an instance.
- Implement `where` clauses on procedures and records, evaluated per
  instantiation through `require_const`, rejecting bounds that depend on runtime
  state and rejecting a clause with no generic parameters in scope.
- A failed bound removes an overload candidate with a captured reason rather
  than reporting immediately, while a direct record instantiation and the
  ultimately selected procedure instance report the bound and instantiation
  stack.
- Add the instantiation cache, the instantiation stack, depth/count limits, and
  instantiation-stack notes on any diagnostic raised inside a clone.
- Check instantiations against the definition's lookup package.
- Reject `@(export)`, foreign conventions, and procedure-value storage for
  uninstantiated generics.
- Promote only a selected signature instance to a checked body instance, then
  name and emit each body instance as its own symbol after its package's items.

**Exit:** a generic `Table($K, $V)` with a generic `impl` compiles and runs for
two instantiations that do not share annotations; a specialized overload beats an
unspecialized one; `where N > 2` splits a procedure group; a failing bound
reports the bound and the instantiation stack; a caller's `extend` does not enter
an instantiation; a generic `extend` applies only in its declaring package and
selects its concrete specialization there; a runaway recursive instantiation is
a diagnostic; a non-selected generic overload with an invalid body emits no
body diagnostic, and `overload_has_viable` agrees with ordinary resolution.

### 2. Interfaces and requirement checking

- Check `interface` declarations: generic parameters, binding lists, expression,
  validity, and slot requirements, composition by naming another interface, and
  uniqueness of slot names across composition.
- Implement requirement checking by substitution into a scratch checker with
  captured diagnostics, `inout` bindings as hypothetical places, `-> inout T`
  requiring an exact assignable place, and associated members resolved as
  ordinary `impl` constants.
- Give every requirement check an explicit lookup context. Free expression and
  validity requirements use the lexical application package (or a generic
  clone's definition package); a named slot uses inherent members plus
  extensions from the package declaring that slot's owning interface. Preserve
  the owning interface when flattening composition.
- Make associated types usable in later requirements and in constrained generic
  bodies, and make slots callable through method syntax inside constrained code.
- Implement interface applications as compile-time booleans usable in `where`
  and in composition. Keep `dyn Interface(args...)` type formation separate: it
  validates non-subject arguments and dyn compatibility but has no concrete
  subject to test.
- Add compiler-contributed `hash(value, seed: uint) -> uint` candidates and
  compile-time/runtime lowering for the M4b built-ins promised to satisfy
  `Hashable`: booleans, integers, floats, runes, pointers, enums, `typeid`, and
  recursively hashable fixed arrays. Normalize `+0` and `-0` before hashing.
  User records and unions still require their coherent inherent equality/hash
  pair.
- Report a failure as the specific requirement line plus the concrete type.
- Add `base/interfaces/` as ordinary Loke source containing the entries whose
  signatures use only M4b types (`Equatable`, `Ordered`, `Hashable`, `Numeric`,
  `Integral`, `Iterator`, `Iterable`, `Sequence`, `Mutable_Sequence`, and
  `Growable_Sequence`). Add fixtures through `-collection base=base`. Leave an
  explicit M5 handoff for `Cloneable`, whose signature requires allocator and
  lifecycle types that do not exist in M4b.

**Exit:** `Additive(T)`-style constraints admit and reject the right types with a
line-accurate diagnostic; the unmanaged catalogue subset compiles as ordinary
Loke source without placeholder runtime types; a constrained generic body calls
a slot through method syntax; requirement order does not matter for associated
members; an extension in the interface package can satisfy its slot while the
same extension at a call site cannot; and `Hashable(int)` succeeds through the
compiler-contributed `hash` operation.

### 3. Reflection, `type_of`/`typeid_of`, and static `foreach`

- Add a semantic `string_view` type identity and constant string-view values for
  descriptor names; keep ordinary runtime construction,
  storage, and operations on `string_view` gated for M6.
- Add the compiler-owned descriptor types and the `fields_of` and
  `enum_values_of` builtins. Start from the resolved nominal type's field or
  enum-member table, preserve declaration order from the selected active
  declaration, and filter member symbols by visibility at the reflection lookup
  package. Definition-site lookup applies inside a generic clone.
- Implement `field.get`/`field.pointer` with per-element result types, the
  reflection visibility rules, and rejection of descriptor materialization into
  runtime storage. Do not use this step to tighten ordinary field access or
  aggregate construction; M5 owns that compatibility break.
- Implement `type_of` (compile-time `type`) and `typeid_of` (a symbolic
  compile-time constant that emits as runtime `typeid`), with `type`/`typeid`
  equality and the existing compile-time-only rules. Add `Typeid` to layout and
  backend support here, reserve numeric ID zero for nil, and freeze requested
  concrete IDs deterministically before any body is emitted.
- Implement static `foreach`: fold the iterable, clone and check one body per
  element, reject mixed static/runtime bindings, `&` bindings, and
  `break`/`continue` targeting the expansion, and emit the copies in order.
- Add element-and-descriptor context to every diagnostic raised inside an
  expansion.

**Exit:** a `visit_fields` procedure walks a struct's fields with a different
static field type in each copy; an empty iterable expands to nothing; a
descriptor stored in a variable is rejected; `type_of(x) == int` and two
`typeid_of` comparisons fold; reflection from another package omits inaccessible
fields while reflection inside a generic uses the definition package's view;
`type_of(field.name) == string_view` folds, while materializing that value into
ordinary runtime storage remains gated for M6.

### 4. Runtime `foreach` and the iteration protocol

- Add the compiler-owned `Range(T)` semantic type and its low/high/kind value
  representation, type checking, constant freezing, layout, evaluator support,
  parameter passing, and emission. Both `..<` and `..=` preserve their behavior
  after the value is stored or passed to a generic procedure.
- Implement `foreach` over integer ranges and fixed arrays: value binding, index
  binding, `&value` over a mutable array, discard bindings, and interaction with
  `break`, `continue`, and `defer`.
- Implement the user-type path: resolve associated `Element`/`Iterator`, the
  `iter` overload, and `next` with optional-ok semantics; maintain the two-name
  index counter in the loop. Bare `foreach` never selects `iter_reverse`.
- Make compiler-contributed associated members and `iter` overloads visible to
  interface checking for fixed arrays and range values. Provide their opaque
  iterator types and `next` candidates so generic `Iterable` code operates on
  values passed through a parameter rather than relying on syntax lowering.
- Reject by-reference iteration over a user type with the diagnostic that names
  the mutable-slice and indexed alternatives.
- Lower range and array iteration to index loops and user iteration to an
  iterator local plus a `next` call per step.

**Exit:** range, array, by-reference, and two-name loops run correctly; a
`Countdown` user type iterates through the protocol; a generic procedure
constrained by `Iterable` compiles for an array, a stored half-open range, a
stored closed range, and a user iterable. A user `iter_reverse` declaration is
an ordinary callable overload and does not change bare `foreach` order.

### 5. Erased views: `typeid`, `any_view`, and `dyn`

- Reuse step 3's symbolic/freeze machinery and add `Any_View`/`Dyn` acceptance
  in `type_is_supported`; concrete types discovered by these conversions join
  the same request set before the per-compilation freeze pass runs.
- Implement `any_view`: implicit conversion at a local or parameter destination,
  semantic rejection after alias expansion and generic substitution in every
  other position, temporary materialization for non-addressable sources,
  checked extraction in both result shapes, and the type switch over concrete types.
- Implement `dyn Interface(args...)`: dyn-compatibility computation with a
  reason; formation without a satisfaction test; conversion from a pointer to
  the concrete subject that checks `Interface(Concrete, args...)` using the
  interface-package coherence rule; nil conversion and nil comparison;
  assignment and copying; conversion to a composed base interface; and `dyn I`
  satisfying `I` through forwarding slots.
- Materialize witnesses once per `(Interface, Concrete, arguments)` with
  receiver thunks, emit them as private immutable globals, and lower slot calls
  as indirect calls with a nil-witness trap.
- Reject checked extractions and type switches on `dyn`, with the diagnostic that
  points at slots or `any_view`.

**Exit:** an `any_view` parameter inspects several concrete types through a type
switch; a `dyn Drawable` dispatches to two concrete types through one call site;
a static generic call on the same types produces a direct call; a
non-dyn-compatible interface names the disqualifying requirement; calling a slot
on nil traps; a type alias or generic wrapper cannot bypass an `any_view`
position restriction; an `any_view` made from a temporary remains valid for the
complete call; and two packages request the same coherent witness even when one
declares a caller-local extension with the same slot name.

### 6. Gate, diagnostic, backend, and documentation audit

- Audit every M4b construct against emitter dispatch; reaching the backend
  without a lowering remains an assertion.
- Audit `type_is_supported` and every remaining `L0350` site: each surviving
  gate names its milestone, and every deferred family keeps exactly one fixture.
- Audit every new code for an exact `tests/err/*.expected` entry with code,
  message substring, line, and column, and every new trap for a `tests/trap`
  fixture.
- Add `tests/ll` goldens small enough to inspect instantiation symbol names,
  witness globals and thunks, range parameter representation, built-in hash
  lowering, `any_view` temporary storage, static-expansion output, and iteration
  lowering.
- Add one integrated program using a generic container, an interface bound,
  reflection, iteration, and a `dyn` call, plus one file of unrelated failures to
  confirm accumulation.
- Update `USAGE` in `src/main.odin`, `readme.md`, and the M4b milestone record in
  `compiler-plan.md`.

**Exit:** the full verification below passes from a clean build, with the M4a
corpus still green.

## Verification

```powershell
odin test src -define:ODIN_TEST_TRACK_MEMORY=false
odin build src -out:lokec.exe
odin test tests -define:ODIN_TEST_TRACK_MEMORY=false
./lokec.exe examples/hello.loke -o hello.exe
./hello.exe
```

Milestone spot checks:

- A generic container instantiated twice produces two independent instances with
  distinct symbols and independent annotations.
- Generic candidate inference substitutes a concrete signature before ranking;
  an unselected candidate body is not checked, and silent viability probes make
  the same decision as ordinary overload resolution.
- An exact generic match beats a concrete overload that requires a conversion,
  and two candidates differing only in constraint strength are ambiguous.
- A failed interface bound names the exact requirement line and the concrete type
  that failed it.
- A caller-local `extend` cannot make a requirement appear satisfied, and cannot
  change what an existing instantiation means.
- A named slot can be supplied by its interface package but not by the package
  that happens to apply the interface; witness creation follows the same rule.
- Forming `dyn I(args...)` does not attempt satisfaction without a subject;
  converting `^T` to it checks `I(T, args...)` and requests the witness.
- A static `foreach` over `fields_of(T)` type-checks a different field type per
  copy, its descriptor names have type `string_view`, and an empty expansion
  emits nothing.
- `foreach` over a written range, a stored range passed through generic
  `Iterable`, an array, and a user iterable produces the same sequence a
  hand-written loop would; bare `foreach` never selects `iter_reverse`.
- `Hashable(int)` resolves the compiler-contributed `hash` operation, including
  compile-time and runtime calls.
- An `any_view` alias or generic substitution cannot bypass a forbidden storage
  position, and a conversion from a temporary has storage for its required
  minimum lifetime.
- One `dyn` call site dispatches to two concrete types; the equivalent generic
  call is direct.
- Instantiation-depth, requirement-failure, and dyn-compatibility diagnostics all
  carry their stack or reason.
- The M4b-compatible interface catalogue in `base/interfaces/` compiles as
  ordinary Loke source, and its M5 `Cloneable` handoff is explicit.

## Deliberate shortcuts

### Earlier shortcuts M4b repays

| Earlier shortcut | M4b replacement |
|---|---|
| No generic instantiation | Declaration cloning, inference, specialization, `where`, and a monomorphization cache |
| Gated `interface`, `dyn`, `any_view`, `typeid` | Requirement checking, witness dispatch, erased views, and their representations |
| M4a's candidate engine has no constraint phase and leaves tie-breaker 4 as a placeholder | Generic signature inference/substitution, shared silent constraint viability, and structural-specificity ordering complete the engine without letting constraints rank candidates |
| No iteration statement | `foreach` over ranges, fixed arrays, and the user protocol, plus static expansion |

### Shortcuts retained after M4b

| Shortcut | Replaced when |
|---|---|
| Annotated AST lowers directly to LLVM; no MIR | M6 (B13) |
| No borrow, escape, or exclusivity checking for `any_view`, `dyn`, `inout` results, or `[:]` results | M5 (B12) |
| `move` receivers transfer by value with no liveness tracking; no lifecycle hooks | M5 (B11) |
| Reflection filters package-visible struct fields, but ordinary field reads, writes, and aggregate construction remain unfiltered for M4a compatibility | M5, which applies the same package/public check to every field operation |
| `typeid` is an identity only; no type-info table and no `type_info_of` | M6 |
| Descriptor types and the interface catalogue have no implicitly supplied `base:` package root; M4b tests map the source tree explicitly with `-collection` | M6 |
| `print_int` remains the output stand-in; no `..any_view` variadics | M6 |
| Private aggregate and receiver call convention; natural layout only | M7 (B15) |
| Every instantiation emits its own body; no sharing of identical code | Post-v1 (A2) |

## Assumptions

- `design.md` and `grammar.md` are normative. Where this plan narrows a feature
  for milestone sequencing, the gate is explicit and non-cascading.
- M4a is complete: the overload engine, methods, operators, unions, and the
  optional-ok protocol are in place and their contracts are not reopened here.
- M1 parser and AST node kinds are stable. M4b adds cloned declaration instances
  and compiler-owned types, but no syntax node kind.
- Cloning syntax is the only way a declaration body or static-expansion block is
  checked more than once. No phase mutates shared syntax annotations on behalf
  of an instance or expansion element.
- A witness layout, an instantiation symbol name, and a `typeid` value are
  compiler-internal but must be deterministic for a given program and options.
- Windows x64 remains the only code-generation target, and layout stays
  target-owned rather than duplicated between checker and emitter.

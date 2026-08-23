# M4a implementation plan — user abstractions, operators, and unions

## Context

`compiler-plan.md` splits M4 into two shippable halves. **M4a** makes
user-defined types as capable as built-in ones at concrete types: one overload
resolution engine, `impl`/`extend` methods, user operators, `init` construction
and conversion, and unions with their extraction and error protocol.
[M4b](m4b-plan.md) then adds generics, interfaces, reflection, iteration, and
erased views on top of it.

The split is at the only place M4's steps do not depend on each other: nothing
in M4a needs an instantiated declaration, and everything in M4b needs methods
and overload resolution.

Where the repository stands after M3:

- The front end parses all of `grammar.md`, including `impl`/`extend`,
  `operator(...)`, `delegate`, and `union` ([ast.odin](src/ast.odin)). M4a adds
  no syntax node kind.
- `Resolution_Kind` already reserves `Method`, `Procedure_Group`,
  `Builtin_Operator`, and `User_Operator`; `Type_Kind` already reserves `Union`.
  `type_is_supported` answers `false` for `Union`, so it is one `L0350` today.
- `check_expr.odin` resolves calls against one declaration
  ([check_expr.odin:1148](src/check_expr.odin:1148)), converts through the fixed
  built-in table ([check_expr.odin:1679](src/check_expr.odin:1679)), and binds
  arguments positionally and by name
  ([check_expr.odin:1563](src/check_expr.odin:1563)). There is no candidate set
  and no ranking.
- `layout.odin` caches natural size/alignment/offsets; `emit_llvm.odin` lowers
  the annotated AST directly, names every symbol before emitting any body, and
  owns hoisted procedure literals per package.
- M2's cleanup stack and `Flow_Info` already carry `defer`, returns, and branch
  targets, which is what `or_return` reuses.

This plan covers compiler implementation. It adds no core library. Slices, maps,
dynamic arrays, and runtime `string` remain absent.

## Scope

### In M4a

| Area | Contents |
|---|---|
| Overload resolution (B8) | One candidate engine: viability filtering, per-argument conversion-rank vectors, partial ordering, the four tie-breakers, and a diagnostic listing every maximal candidate with its vector and the failing tie-breaker |
| Procedure groups | `proc{...}` for free procedures, methods, and operators; explicit overloading; group members resolved after declaration collection |
| Methods (B6/B8) | `impl` and `extend` blocks, the three receiver forms, associated constants and types, `Type.member` access, field-lookup priority, package-scoped extension visibility, and the per-declaration lookup package |
| Construction and conversion | `init` overload groups, the two-stage `T(...)` resolution order, and `@(implicit)` one-argument conversion from untyped constants |
| Operators | `operator(sym)` declarations and groups, the `!=` and compound-assignment fallbacks, `operator([])`/`([]=)`/`([:])` with place-position selection, `delegate(...)` on `distinct` types, and the unshadowable built-in rule |
| Unions | Tagged representation and layout, `@(align=N)`, nil zero value and nil comparison, single-value and comma-ok checked extraction with `v.(T)`, and the type switch |
| Error protocol | One status-result definition — a `bool` status, or a union as the nil status — shared by `or_else` and `or_return`; the optional-ok result shape as its `bool` case; and `or_return`'s definite-initialization requirement on named results |
| Backend | Method and operator symbols, union tag/payload lowering, trapping and comma-ok extractions, type-switch dispatch, `or_else` branches, and `or_return`'s branch through the existing cleanup stack |

### Deferred to M4b

| Deferred | Why it waits |
|---|---|
| `$` parameters, inference, specialization, `where`, generic records and `impl` blocks, monomorphization | Needs declaration cloning, which nothing in M4a requires |
| `interface` declarations and requirement checking | Requirements are checked against methods and operators M4a introduces |
| `fields_of`, `enum_values_of`, `type_of`, `typeid_of`, static `foreach` | Static expansion shares M4b's cloning facility |
| Runtime `foreach` and the iteration protocol | The protocol is stated as associated types and interface slots |
| `typeid`, `any_view`, and `dyn` witnesses | Witness slots are interface slots |

### Deferred after M4

| Deferred | Goes to |
|---|---|
| Slices, `[dynamic]T`, `map`, and runtime `string` | M5/M6 |
| Borrow, escape, and exclusivity checking for `inout` results and `operator([:])` results | M5 (B12) |
| Move-receiver liveness, dead-source marking, deep copy, the `try_clone`/`clone`/`drop` lifecycle hooks, and copy-cost diagnostics | M5 (B11) |
| Receiver and aggregate ABI, `@(packed)`, `@(align)` interaction with foreign layout, calling conventions | M7 (B15) |

## Decisions

| Area | Choice | Why |
|---|---|---|
| One candidate engine | Add `overload.odin`, owning candidate formation, viability, conversion-rank vectors, partial ordering, tie-breakers, and the ambiguity diagnostic. Named groups, methods, operators, `init` conversions, and indexing all call it; M4b's generic candidates and iteration hooks join the same engine. | design.md ranks operator overloads "using the same algorithm as named procedure overloads". Two implementations would disagree, and the error-quality goal wants one place that can print vectors. |
| Constraints never rank | The engine's ordering uses conversion vectors and the four structural tie-breakers alone. Viability hooks exist for M4b's `where` clauses and interface applications, and can never influence ordering. | design.md is explicit: two candidates of identical shape differing only in constraint strength are an ambiguity, not a preference. Building the hook now keeps M4b from reopening the engine's contract. |
| Built-in priority | Two separate predicates: "all operands are built-in *and* the built-in table defines this operator for them" selects the built-in operation before any lookup; a `distinct` type fails that predicate but still counts as built-in for stage 1 of `T(...)`. | The two rules genuinely differ for `distinct`. One shared `is_builtin` helper would get one of them wrong. |
| Method storage | Nominal `Type_Info` carries the inherent method and associated-member table written by `impl`. `extend` writes a separate per-package table keyed by `Type_Id` and is never merged into the type. | Extension visibility is package-scoped by design; an unused import must not change or make ambiguous an existing expression. Storing extensions on the type would leak them through every import. |
| Lookup package | Every declaration records the package whose method, operator, and extension tables its body may use, separate from the checker's current package. | This is what `delegate` freezes at its declaration, and what M4b's definition-site lookup needs for instantiations. Adding it later would mean revisiting every candidate-formation call site. |
| Receiver lowering | Immutable `self` uses M2's private by-value convention; `inout self` reuses M2's `inout` pointer alias; `move self` is a value transfer in M4a. A first parameter typed `^T` is not a receiver and gets no method sugar. | The receiver ABI is not frozen before M7 (B15), and no managed type exists yet, so a move of a copyable value is a copy. Liveness and dead-source marking arrive with M5. |
| Union representation | A named LLVM storage type with a payload region, an `iN` tag, and explicit padding. The payload member must carry the widest variant's ABI alignment (or the validated `@(align=N)` alignment); a raw `[payload_size x i8]` member alone is not sufficient because LLVM would align it to one byte. Tag 0 is nil; variants are numbered in declaration order. `layout.odin` computes the payload size/alignment, tag offset, tail padding, and total stride, and the emitter constructs a type whose LLVM-reported layout matches those cached facts before reading the payload through a typed pointer. | One layout module remains the source of truth without asking LLVM to infer a conflicting alignment. An alignment-carrying storage type is required so unions remain correctly aligned when allocated directly, nested in a struct, or used as array elements. |
| Extraction phases | One `Expr_Checked_Extract` node with a context flag set by the checker: a single-value position traps on mismatch; a comma-ok destination or `or_else` left operand yields `(T, bool)` with a zeroed payload and never traps. M4b's `any_view` extractions reuse the same rule. | design.md gives one construct two result shapes chosen by context, not two constructs. |
| `or_return` lowering | Check it as an expression with a flow effect: it contributes to `Flow_Info`, requires named results when the procedure has several, and runs a definite-initialization pass over the earlier named results. The emitter branches to the epilogue through M2's existing cleanup stack. | No AST rewriting is needed, and reusing the cleanup stack keeps `defer` ordering in one implementation. |
| Diagnostics | Reserve `L0391`–`L0399` and `L0406`–`L0430`: `L0391`–`L0399` overloads and groups, `L0406`–`L0415` `impl`/`extend`/`init`, `L0416`–`L0421` operators and indexing, `L0422`–`L0430` unions and the error protocol. `L0400` and the audited gaps below `L0390` are left unused; `L0401`–`L0405` are already the driver and backend I/O codes in `emit_llvm.odin` and are not reassigned. `L0431`–`L0470` are reserved for M4b. | Fixed ranges keep fixtures stable and keep each family's failures separable across both halves. Skipping the live `L0401`–`L0405` block costs one unused code and leaves each family contiguous. |
| Corpora | Reuse `tests/run`, `tests/err`, `tests/ll`, and `tests/trap`. Extension visibility gets directory cases under `tests/pkg` and `tests/pkg_err`. | The existing corpora already cover single-file and directory cases; M4a adds no new corpus kind. |

## Steps

Each step ends with a built compiler and a green existing corpus. New behavior
gets an exact success or diagnostic fixture in the same step that enables it.

### 1. Overload resolution engine and procedure groups

- Add `overload.odin`: candidate records, viability filtering (arity, parameter
  modes, known destination type, and a viability hook M4b fills in), per-argument
  conversion ranks 0–4, vector partial ordering, the four tie-breakers, and the
  ambiguity diagnostic that prints every maximal candidate with its vector and
  the failing tie-breaker.
- Give `Symbol_Kind.Proc_Group` real members: resolve `proc{...}` names after
  declaration collection, reject non-procedure members and duplicates, and
  forbid a group in a procedure value.
- Route `check_call` through the engine when the callee resolves to a group,
  keeping the single-declaration path as the one-candidate case.
- Keep rank 4 (`@(implicit)`) unreachable until step 2 declares one.

**Exit:** a free procedure group selects by exact match, by built-in conversion,
and by untyped-constant context; a crossed conversion vector is ambiguous with a
diagnostic naming both candidates; a group used as a procedure value is
rejected.

### 2. `impl`/`extend`, methods, and `init` construction

- Check `Item_Impl` for both kinds: resolve the subject type, install inherent
  members on the type or extension members in the package table, and reject an
  `extend` for a type in the same package where `impl` belongs.
- Implement the three receiver forms, the `^T`-is-not-a-receiver rule, method
  call resolution with field lookup taking priority, and `Type.member` access to
  associated constants and types.
- Record each declaration's lookup package and use it for method and extension
  candidate formation.
- Implement `init` groups and the two-stage `T(...)` order: built-in or
  `distinct` conversion first, then `init` overloads.
- Implement `@(implicit)` on one-argument `init` overloads: permitted only for
  built-in numeric, boolean, rune, or string parameter types, reachable only
  from an untyped constant, and ranked below every built-in conversion.
- Emit methods as ordinary procedures with type-qualified symbol names.

**Exit:** a struct with value, `inout`, and associated members works through both
method and qualified-call syntax; an `extend` block is invisible to an importing
package but its named procedures are not; `Complex(1, 2)` and `Complex(x)` select
the right explicit `init` overload, while a procedure expecting `Complex` accepts
the untyped constant `2.0` through `@(implicit)` and rejects a runtime `f64`.

### 3. User operators, indexing, and `delegate`

- Check `operator(sym)` declarations and operator groups, validate the symbol
  against the overloadable table and the declaration's arity, and register them
  in the inherent or extension operator tables.
- Extend `check_unary`, `check_binary`, `check_comparison`, and compound
  assignment to consult the built-in table first and the operator candidate sets
  otherwise, with the unshadowable built-in rule enforced ahead of lookup.
- Implement the `!=` fallback to `!(a == b)` and the compound-assignment
  fallback to binary-plus-assign, each only when no direct overload exists.
- Implement `operator([])`, `([]=)`, and `([:])`, with place position selecting
  the `inout` overload before ordinary ranking, and `&` treated as a place
  position that never creates an element.
- Implement `delegate(...)` on `distinct` types: generate one forwarding
  overload per listed symbol from the underlying type's operations resolved at
  the declaration's lookup package, wrapping only results of the underlying
  type, and diagnose an undefined or already-declared symbol.
- Lower operator calls as ordinary calls; a place-position index that selects an
  `inout` overload produces an address.

**Exit:** a vector type supports arithmetic, comparison, and compound
assignment; `int + int` still means integer addition with a user `+` in scope;
a grid supports read, place-position write, and `[:]`; a delegating `distinct`
type gets `+`, `+=`, and `<` without a hand-written overload; `z + 2.0` reaches
the constant-only `init` conversion while `z + runtime_f64` is rejected.

### 4. Unions, checked extractions, type switches, and the error protocol

- Resolve union variants, reject duplicates and unrepresentable variant sets,
  validate `@(align=N)`, compute the payload alignment, tag offset, total size,
  and tail padding in `layout.odin`, and add `Union` to `type_is_supported` and
  to the finite-size check.
- Implement nil zero value, assignment from a variant, nil comparison, and
  variant equality where the variants are comparable.
- Implement `v.(T)` in both phases, the type switch with its multiple-type case
  keeping the union-typed binding, the default case, and exhaustiveness
  reporting for unions.
- Implement one status-result test shared by both operators; `or_else` over
  either status with single and multiple payload fallbacks, discarding the
  status; and `or_return` with its named-result and definite-initialization
  rules, its ban inside deferred statements, and its cleanup ordering. The two
  operators differ only in arity — `or_else` requires a payload, `or_return`
  does not — so a nil-comparable pointer or slice is a status for neither.
- Lower union storage, tag tests, trapping and comma-ok extractions, the type
  switch, `or_else` branches, and `or_return`'s branch to the epilogue.

**Exit:** a union round-trips every variant; a failed single-value extraction
traps while the comma-ok form yields `false` and a zeroed payload; `or_else`
supplies a fallback without evaluating it on success, over a `bool` status and a
union status alike; and an `or_return` chain over an `Error` union propagates
through named results with `defer` running in order.

### 5. Gate, diagnostic, backend, and documentation audit

- Audit every M4a construct against emitter dispatch; reaching the backend
  without a lowering remains an assertion.
- Audit `type_is_supported` and every remaining `L0350` site: each surviving
  gate names its milestone, and every deferred family keeps exactly one fixture,
  including the M4b families.
- Audit every new code for an exact `tests/err/*.expected` entry with code,
  message substring, line, and column, and every new trap for a `tests/trap`
  fixture.
- Add `tests/ll` goldens small enough to inspect union tags, method symbol
  names, operator calls, and `or_return`'s cleanup path.
- Extend `tests/layout` with unions whose widest payload is `i64`/`i128`, an
  explicitly aligned union, a struct containing each union, and a fixed array of
  each union. `-check-layout` must agree on size, alignment, field offsets, and
  array stride for every case.
- Add one integrated program using methods, operators, `init` conversion, a
  union result, and `or_return`, plus one file of unrelated failures to confirm
  accumulation.
- Update `USAGE` in `src/main.odin`, `readme.md`, and the M4a milestone record in
  `compiler-plan.md`.

**Exit:** the full verification below passes from a clean build.

## Verification

```powershell
odin test src -define:ODIN_TEST_TRACK_MEMORY=false
odin build src -out:lokec.exe
odin test tests -define:ODIN_TEST_TRACK_MEMORY=false
./lokec.exe examples/hello.loke -o hello.exe
./hello.exe
```

Milestone spot checks:

- An ambiguous overload lists every maximal candidate, its conversion vector, and
  the tie-breaker where selection failed.
- A user vector type is used with `+`, `+=`, `==`, `[]`, and `[:]`, and
  `int + int` keeps its built-in meaning in the same file.
- An `extend` block changes lookup only inside its own package; the same
  expression in an importing package is unchanged.
- `T(x)` picks the built-in conversion where one exists and an `init` overload
  otherwise; `@(implicit)` applies to a constant and not to a runtime value.
- A `union` round-trips its variants; a failed single-value extraction traps while
  the comma-ok form does not.
- A type switch with a multiple-type case keeps the binding at the union type.
- `or_return` propagates through named results with `defer` cleanup in order, and
  an uninitialized earlier named result is a compile-time error.

## Deliberate shortcuts

### M2/M3 shortcuts M4a repays

| Earlier shortcut | M4a replacement |
|---|---|
| Calls resolve against one declaration; no candidate set | One shared overload engine for groups, methods, operators, `init`, and indexing |
| Built-in operator table only | User operators, `delegate`, and the unshadowable built-in rule stated as its own predicate |
| `T(v)` is a built-in conversion | The two-stage `T(...)` resolution with `init` overloads and `@(implicit)` |
| Gated `union` | Real tagged representation, layout, checked extractions, and type switches |

### Narrowings taken while implementing M4a

| Narrowing | Why, and what would lift it |
|---|---|
| Untyped constants preserve their literal kind during ranking: `f(7)` prefers an integer overload to a floating overload, while two compatible integer overloads remain ambiguous | This matches Odin without making the fallback default type an overload preference. Rank 2 is a kind-preserving constant conversion; other built-in conversions rank 3; `@(implicit)` ranks 4 |
| A public `extend` procedure additionally binds its own name in the extension package, so importers write `adapter.member(value)`; an `impl` member remains under `Type.member` | This fixes the "ordinary qualification" spelling without making imports affect implicit lookup. Members use the normal file and declaration visibility defaults; private members of different types do not consume package names |
| Method sugar does not auto-dereference a pointer receiver; `p^.method()` is written out | The receiver ABI is not frozen before M7 (B15), and `p^` is already a place, so `inout self` works unchanged |
| A compound assignment on a container with only `operator([]=)` reports `L0419` instead of reading through `[]` and writing back through `[]=` | design.md's read-modify-write fallback needs a temporary the borrow model has not specified yet; the diagnostic names the missing `inout` overload rather than guessing |
| A file-scope union starts at nil (`L0424`) | Writing a tag needs code, and a global initialiser has none. Lifted by M6's runtime initialisation |
| Named-result state is intersected across `if` and `switch` joins; loop exits conservatively retain only assignments live before the loop | This prevents `or_return` from propagating an uninitialised result. M5's full liveness lattice can accept assignments proven on every `break` path |
| Built-in indexing still reaches through a `distinct` array | Changing it would silently retire an M2 behaviour that has a corpus; a `distinct` container that wants its own indexing declares `operator([])`, which is found first |

### Shortcuts retained after M4a

| Shortcut | Replaced when |
|---|---|
| Annotated AST lowers directly to LLVM; no MIR | M6 (B13) |
| No borrow, escape, or exclusivity checking for `inout` results or `[:]` results | M5 (B12) |
| `move` receivers transfer by value with no liveness tracking; no lifecycle hooks | M5 (B11) |
| `print_int` remains the output stand-in | M6 |
| Private aggregate and receiver call convention; natural layout only | M7 (B15) |

## Assumptions

- `design.md` and `grammar.md` are normative. Where this plan narrows a feature
  for milestone sequencing, the gate is explicit and non-cascading.
- M1 parser and AST node kinds are stable. M4a adds semantic annotations and
  compiler-owned tables, but no syntax node kind.
- The overload engine's contract — viability first, structure orders, constraints
  never rank — is fixed here and is not reopened by M4b.
- Windows x64 remains the only code-generation target, and layout stays
  target-owned rather than duplicated between checker and emitter.
- No unused import and no unselected `when` branch may change overload
  resolution, symbol names, or emitted code.

# M2 — Static core semantics implementation plan

## Context

`compiler-plan.md` milestone M2 implements name resolution, the type system,
type checking, constant folding, and typed LLVM lowering for the non-generic,
non-managed core of Loke. Its exit criterion is that programs in that subset
type-check and run through the existing textual-LLVM path.

Where the repository stands after M1:

- The front end is complete: full lexer, full grammar, recovery, spans, the
  syntax corpus, ambiguity goldens, and the mutation fuzzer.
- Semantic scaffolding already exists in `src/semantic.odin`: interned
  `Type_Id`/`Identifier_Id`/`Symbol_Id`/`Package_Id`, `Type_Info` + `Type_Key`
  interning, `Symbol`, `Scope`, `Package`, `Const_Value`, `Resolution`,
  `Value_Category`, and a per-compilation arena.
- `src/check.odin` already uses the B6 phase order over a package
  ([check.odin:31](src/check.odin:31)): collect top-level declarations → create
  nominal type shells → resolve signatures and fields → bind names in bodies →
  check and fold.
- The checked language is still M0: `int` and `untyped_int`, eleven binary
  operators, scalar declarations, no assignment or control flow, and procedures
  without parameters or results. Everything else is gated by `L0350`.
- `src/emit_llvm.odin` is `i64`-only and directly lowers the annotated AST:
  alloca/load/store, `printf` through `print_int`, and procedures without
  parameters or results.

M2 widens that end-to-end slice. It does not add MIR, managed ownership, package
loading, user-defined abstractions, or the compile-time interpreter.

**Exit criteria**

- Every construct listed as in scope below type-checks, folds where constant,
  emits valid LLVM, and runs as a Windows executable through `clang`.
- Runtime integer behavior agrees with constant folding for every width,
  including wrapping signed arithmetic, oversized shifts, division by zero, and
  `MIN / -1`.
- Every deferred outer construct reports exactly one `L0350`, at that outer
  construct, and descendants are not checked.
- Every new diagnostic has a stable code, an exact fixture in `tests/err/`, and
  a span on the offending node.
- Each implementation step adds its own tests and ends with a freshly built
  compiler and a green M0/M1/M2 corpus.

---

## Scope

### In M2

| Area | Contents |
|---|---|
| Types | `bool`; `i8`–`i128`, `u8`–`u128`, `int`, `uint`, `uintptr`, `byte`; `f16`/`f32`/`f64`; `rune`; `rawptr`; `^T`; `[N]T`; `struct`; `enum`; `distinct`; procedure types; compile-time `type` values only where needed for type aliases and conversion classification |
| Constants | Untyped int/float/bool/rune/nil, typed scalar constants, aggregate struct/array constants, default types, representability, and folding of every M2 operator |
| Expressions | All seven binary levels, unary `+ - ~ !`, comparisons, `&&`/`||`, `x if c else y`, conversions `T(v)`, indexing, field selection, `&`/`^`, and composite literals |
| Statements | Single/multiple/compound assignment, `if`/`else` with init, all three `for` headers, value `switch` including ranges and enum exhaustiveness, `break`, `continue`, `defer`, and `return` |
| Procedures | Value and `inout` parameters, multiple and named results, defaults, named arguments, recursion, non-capturing procedure literals, and procedure values |
| Backend | Incremental typed LLVM lowering for every item above, including indirect calls, aggregate values, structural equality, bounds/nil checks, and structured control flow |

`type` is compile-time-only. M2 accepts type-valued constants such as aliases and
uses type values to classify `T(v)`, but it rejects `type` as a runtime variable,
field, ordinary parameter, or ordinary result. Procedures that compute types and
`$` parameters belong to M3/M4.

### Deferred after M2

Each deferred item still parses and is gated once at its enclosing outer
construct.

| Deferred | Goes to |
|---|---|
| `impl`/`extend`, methods, `operator(...)`, `proc{...}` groups, user conversions, and conversion-vector ranking | M4 |
| `union`, type assertion `x.(T)`, and type switch | M4 |
| Runtime and `static foreach`, plus the iteration protocol | M4 |
| Generics, `$` parameters, `where`, interfaces, reflection, `any_view`, and `dyn` | M4 |
| `string`, slices, `[dynamic]T`, maps, `via`, `static`/`thread_local`/`manual`, `move`, lifecycle hooks, and variadics | M5/M6 |
| `import`, multi-file packages, and file/procedure-scope `when` | M3 |
| Compile-time procedures, `size_of`, `len`, `offset_of`, `#assert`, `#config`, and `#location` | M3 |
| `or_else`, `or_return`, and optional-ok | M4/M5 |
| `[^]T`, unchecked pointer/container operations, foreign declarations, and foreign ABI behavior | M7 |

`compiler-plan.md` is amended with this narrower M2 boundary. User-defined
operators sit in M4 beside the generic conversion ranking they share; M5
integrates the already-working M2 `defer` mechanism with implicit drops rather
than introducing `defer` for the first time.

---

## Decisions

| | Choice | Why |
|---|---|---|
| Integer constants | Replace `Const_Value.integer: i64` with an arena-owned, immutable signed-magnitude `Big_Int` using normalized little-endian `u64` limbs | A signed `i128` cannot represent the upper half of `u128`, or the positive magnitude used to spell `i128::min`. Untyped folding must not reject a value merely because no runtime integer type can hold an intermediate. Materialization performs the range check or modulo-`2^n` normalization. |
| Float constants | Keep an untyped folded value plus its semantic width; parse a literal directly for its destination width, and round after every typed `f16`/`f32`/`f64` operation and conversion | Folding typed `f16` or `f32` entirely in `f64` and rounding only at materialization can disagree with runtime execution. Materialization is not the first rounding point for a typed expression. |
| Aggregate constants | Add arena-owned `Const_Aggregate {type, elements}` referenced by `Const_Value` | Struct/array constants, constant field selection and indexing, and non-zero aggregate globals cannot be represented by the current scalar payload. Recursive pointers avoid a recursive-by-value Odin struct. |
| Type metadata | Add scalar `bits` and `signed`; record enum backing types and aggregate members; add `Target_Info` for the fixed Windows-x64 widths used in M2 | `int`, `uint`, and `uintptr` are target-selected. They must not be guessed independently by checker and backend. A full layout table still waits for M3/M7. |
| Universe | Build one real universe scope per compilation in new `src/universe.odin` | Predeclared names are shadowable symbols. `byte` is another symbol for `u8`, not a distinct type. Hard-coded string comparisons disappear. |
| Deferred types | Known predeclared deferred names such as `string`, `typeid`, and `any_view` receive symbols; composite deferred syntax still resolves to a real `Type_Id` | “Unknown type” would be false. `type_is_supported` recursively identifies deferred content without pretending it is absent. |
| Gate granularity | Gate once per outer semantic unit: declaration, statement, or expression. A declaration is preflighted recursively and emits one `L0350` even if several fields or parameters contain deferred types | This preserves M1’s no-cascade contract. Checking every field binding would produce several diagnostics for one struct declaration. |
| Contextual checking | Change expression checking to accept an expected type. Add `check_single_expr` and `check_value_list`; a call records `result_types`, while `Expr_Base.type` remains the exactly-one-value type | Untyped `nil`, implicit enum selectors, typeless composites, argument conversion, and return checking require context. Multiple results are not tuples and cannot be forced into one `Type_Id`. |
| Place model | Keep `Value_Category`, and add independent `addressable` and `assignable` annotations plus an immutable-reason enum | An ordinary value parameter is immutable but addressable, an `inout` parameter is an assignable alias, and a composite literal is addressable but not an assignment destination. One “place” bit cannot express all three. |
| Procedure values | A procedure identifier/literal has its interned `proc_type`; calls obtain results from that type/declaration. Nested literals are hoisted to uniquely named module functions and may not capture an enclosing local or parameter | This completes the one-code-pointer model and gives direct and indirect calls one type representation. |
| IR | Continue annotating the AST in place; no MIR in M2 | MIR remains B13/M6. M2 nevertheless introduces small checker/backend helper structs for value lists, flow summaries, places, and cleanup targets. |
| Backend | Widen the backend alongside each semantic slice, retaining alloca/load/store and letting `mem2reg` build SSA | No semantic step claims to run before its lowering exists. Each checkpoint builds and executes its new fixtures. |
| Integer lowering | Centralize typed integer opcode selection and exceptional cases | LLVM shifts by a count at least the width and signed `MIN / -1` are poison. Loke defines both, so the emitter must branch or clamp before emitting the primitive instruction. Signed/unsigned division, remainder, comparison, and right shift use different opcodes. |
| Aggregate validity | Run a layout-independent finite-size dependency check after fields resolve | LLVM cannot emit a struct or array that recursively contains itself by value. Pointer edges break the cycle. Exact offsets and ABI classification remain deferred. |
| Structural equality | Generate recursive equality for structs and arrays; use `icmp`/`fcmp` only for scalar leaves | LLVM has no aggregate `icmp`. The generated operation evaluates operands once and combines leaf comparisons with short-circuiting blocks. |
| `defer` | Maintain a lexical cleanup stack. Each syntactic defer has an entry-block `i1` flag, reset on each scope activation, set when registration is reached, and drained in reverse at every edge leaving that scope | A loop reuses storage across activations, so flags must reset. Return values move to result temporaries before cleanup. M5 later interleaves implicit drops on the same stack. |
| Flow analysis | Use `Flow_Info` with `can_fall_through` and sets for return/break/continue targets, not a single terminator Boolean | Missing-return checking, unreachable emission, loop exits, and cleanup routing need more information than “terminates.” The backend separately tracks whether the current LLVM block already has a terminator. |
| File split | `check.odin` owns declarations/statements; new `check_expr.odin` owns expressions/conversions/folding; new `universe.odin` owns predeclared symbols | The split follows responsibility without reorganizing the Odin package. |
| Sequencing | Seven feature slices with checker, backend, diagnostics, and tests together; an eighth integration/documentation sweep | Every checkpoint is executable and independently verified. Aggregates precede enum-aware switches. |

The verification sequence at the end of every step is:

```powershell
odin test src -define:ODIN_TEST_TRACK_MEMORY=false
odin build src -out:lokec.exe
odin test tests -define:ODIN_TEST_TRACK_MEMORY=false
```

The build is deliberately between the two test commands because
`tests/corpus_test.odin` executes `lokec.exe`.

---

## Step 1 — Universe, constant storage, and type-system core (B7)

`src/semantic.odin`, new `src/universe.odin`, `src/check.odin`,
`src/emit_llvm.odin`.

- Extend `Type_Kind` and the fixed type IDs for `bool`, all sized integers,
  `int`/`uint`/`uintptr`, `f16`/`f32`/`f64`, `rune`, `rawptr`, and the untyped
  int/float/bool/rune/nil kinds.
- Add the compiler-owned `Big_Int` helpers needed by M2: parse, normalize,
  compare, add/subtract/multiply, quotient/remainder, shifts, bitwise operations,
  signed conversion, fit checks, and modulo-`2^n` projection. Values are immutable
  after publication in `Const_Value`.
- Add width-aware float helpers. A typed operation converts operands to the
  semantic width, performs the operation, and rounds its result back to that
  width before storing it canonically.
- Add `Const_Aggregate` storage now so later steps do not change the constant
  representation again.
- Add `Target_Info`; M2’s only target is
  `x86_64-pc-windows-msvc`, where pointers, `int`, `uint`, and `uintptr` are 64
  bits. Checker and emitter read the same facts.
- Build the universe symbols, including `true`, `false`, `nil`, all type names,
  `byte` as an alias of `u8`, and `print_int`.
- Implement `default_type`, `constant_fits`, scalar classification,
  `assignable`, `convertible`, recursive `type_is_supported`, and complete
  `type_name` rendering.
- Add the contextual/single-value/value-list checker APIs and result annotations,
  while keeping current M0 callers working.
- Add `llvm_type` for scalar types and convert existing scalar globals, allocas,
  loads, and stores to use it. Existing M0 code continues to emit `i64`.
- Reject runtime storage of `type`; accept a type-valued constant alias.

Tests land in this step for universe shadowing, aliases, every scalar type name,
`u128` boundary parsing, `i128::min` spelling, and one diagnostic for a deferred
type declaration.

**Exit:** scalar declarations of every M2 type check and emit correctly; valid
`u128` constants are retained exactly; `Alias :: u32` resolves as a type; and a
runtime `x: type;` is rejected.

## Step 2 — Scalar expressions, conversions, folding, and lowering (B8/B16)

New `src/check_expr.odin`, plus the scalar expression half of
`src/emit_llvm.odin`.

- Check int/float/bool/rune/nil literals with expected-type propagation and
  representability diagnostics.
- Implement unary `+ - ~ !` and all built-in binary levels. Except for shifts,
  an untyped operand converts to the other operand’s concrete type when
  representable.
- For shifts, require an unsigned typed count or a non-negative untyped constant
  representable by an unsigned type. An untyped left operand takes the type it
  would assume alone.
- Implement scalar comparisons, `&&`/`||`, and conditional expressions.
  Short-circuit and conditional expressions check both branches but fold only
  the selected value when the condition is constant.
- Implement built-in `T(v)` conversions: numeric↔numeric, int↔rune,
  pointer/rawptr where the source kind is already available, and identity.
  Pointer and distinct conversions are completed in Step 4.
- Fold every scalar operation. Untyped integer operations use `Big_Int`; typed
  integer operations project modulo their width after each operation. Typed
  floats round after each operation. Constant integer division/remainder by zero
  remains a diagnostic; floating division by zero follows IEEE-754.
- Lower arithmetic with the correct typed LLVM instructions:
  `sdiv`/`udiv`, `srem`/`urem`, `ashr`/`lshr`, signed/unsigned `icmp`, and
  floating operations/comparisons.
- Generalize the current division seam for every signed width. Guard zero and
  `MIN / -1` before LLVM division.
- Lower oversized runtime shifts explicitly: left shift becomes zero; right
  shift becomes zero or the replicated sign bit according to the operand type.
  No out-of-range count reaches an LLVM shift instruction.
- Lower `&&`, `||`, and conditional expressions with branches and result
  temporaries/phi nodes.

Tests land for all numeric widths, wrapping, signed and unsigned comparisons,
oversized constant and runtime shifts, division edge cases, float-width
rounding, conversions, short-circuit side effects, and conditional values.

**Exit:** scalar expression fixtures fold to the same results they produce at
runtime for every M2 numeric width.

## Step 3 — Declarations, assignments, and places

`src/semantic.odin`, `src/check.odin`, and declaration/place lowering in
`src/emit_llvm.odin`.

- Make `addressable` and `assignable` annotations load-bearing:
  - variables and pointer dereferences are addressable and assignable;
  - the model reserves “addressable but immutable” for value parameters and
    “addressable and assignable alias” for `inout` parameters when Step 6 enables
    procedure signatures;
  - a field/array element inherits the relevant capability from its base;
  - a composite literal is addressable temporary storage but is not itself an
    assignment destination;
  - constants and `_` are neither readable places nor mutable storage.
- Implement single, multiple, and compound assignments. `check_value_list`
  establishes arity; Step 6 adds the call case that expands one expression into
  several values.
- Preserve evaluation order: all right sides left-to-right, all destination
  place calculations left-to-right, then writes left-to-right. Compound
  assignment evaluates its destination once before its right operand.
- Check assignability separately from addressability and give immutable
  parameters a specific diagnostic.
- Implement zero initialization for every runtime M2 type. `---` remains
  uninitialized storage, not a zero value, and requires an explicitly written
  trivial runtime type.
- Continue gating `static`, `thread_local`, `manual`, and `via` at the enclosing
  declaration.
- Lower assignments through prepared value temporaries and destination
  addresses. Do not perform the first write until every value and destination
  has been prepared.

Tests land for swaps, discard destinations, side-effect order, compound
assignment evaluation count, assignment to constants/non-places, and the
addressable-versus-assignable helper invariants. Parameter cases land with
procedure signatures in Step 6.

**Exit:** assignment fixtures run with the normative evaluation order, and the
checker has separate addressability and mutability facts rather than deriving
one from the other.

## Step 4 — Structs, enums, arrays, pointers, distinct, and aggregate constants

`src/semantic.odin`, `src/check.odin`, `src/check_expr.odin`, and aggregate
lowering in `src/emit_llvm.odin`.

- Resolve struct fields, then run a finite-size graph check over direct
  struct/array/distinct containment. Report a path for cycles such as
  `A → B → A`; pointer edges terminate the path.
- Implement field selection, positional and named struct literals, typeless
  literals under an expected struct type, nested literals, and source-order
  element evaluation. Keep `using`, packed layout, and promoted fields gated.
- Implement enum backing types, explicit and implicit member values,
  representability, duplicate names, typed `.Member`, equality, and ordering.
  Enum arithmetic remains invalid.
- Fold fixed-array length expressions through the M2 evaluator, implement `[?]T`
  literal inference, literals, indexing, constant bounds diagnostics, and
  runtime lower/upper bounds checks.
- Implement pointer address-of and dereference. `&` accepts every addressable
  operand defined by the design, including value parameters and composite
  literals. Dereference emits a nil check before access.
- Complete raw-pointer and distinct conversions. A distinct type has a fresh
  identity and no inherited operators.
- Construct `Const_Aggregate` values for constant struct/array literals. Fold
  field selection, constant indexing, and structural equality over them.
- Emit named LLVM struct types once. Lower arrays and structs as whole values,
  use `getelementptr`/`extractvalue` for places and values, and emit aggregate
  constants recursively.
- Generate structural equality recursively. Each operand is evaluated once;
  scalar leaves use `icmp`/`fcmp`, and aggregate nodes combine them with
  short-circuit blocks.

Tests land for recursive pointer structs, rejected by-value cycles, enum
boundaries, nested and named literals, aggregate constants/globals, structural
equality, constant/runtime bounds checks, addressable composite literals, nil
dereference, and distinct conversion requirements.

**Exit:** a program builds, compares, indexes, and points into nested
struct/enum/array values and produces the expected output; malformed recursive
value types are diagnosed before LLVM emission.

## Step 5 — Control flow, reachability, and `defer`

`src/check.odin` and structured block lowering in `src/emit_llvm.odin`.

- Implement `if`/`else if`/`else` with an init scope spanning all branches.
- Implement three-part, condition-only, and infinite `for` forms with the init
  declaration scoped to the loop.
- Implement value `switch`: required subject, source-order non-constant cases,
  multiple values, ranges, default, duplicate scalar constant detection, and
  enum exhaustiveness. Constant scalar cases may use LLVM `switch`; ranges and
  non-constant cases use an ordered comparison chain.
- Track lexical break/continue targets and reject branch statements outside a
  valid construct.
- Enforce deferred-statement restrictions: no escaping return/or-return,
  no break/continue targeting an outer construct, and no nested defer. A
  procedure literal nested syntactically inside deferred code is checked as a
  separate procedure.
- Compute `Flow_Info` for blocks, branches, loops, and switches. Step 6's
  missing-return check consumes `can_fall_through`; the emitter already uses
  explicit block-termination state rather than guessing.
- Lower real basic blocks for control flow. Each lexical scope owns a cleanup
  slice. Normal fallthrough, return, break, and continue drain exactly the
  scopes they leave.
- Allocate defer flags in the procedure entry block, reset them when their
  lexical scope activates, set them at registration, and execute flagged
  statements in reverse registration order. Loop iterations therefore do not
  inherit a prior iteration’s registration.

Tests land for init scoping, all loop forms, ordered dynamic switch cases,
ranges, exhaustive enums, nested break/continue targets, conditional defer
registration, loop reactivation, normal fallthrough, and early bare returns.

**Exit:** nested control-flow and defer-order fixtures run correctly, and every
emitted basic block ends in exactly one terminator.

## Step 6 — Procedures, defaults, multiple results, and procedure values

`src/semantic.odin`, `src/check.odin`, and call/procedure lowering in
`src/emit_llvm.odin`.

- Install typed parameters and named results in the procedure scope. Value
  parameters are immutable addressable locals; `inout` parameters are mutable
  aliases requiring `inout expr` at the call site.
- Store procedure expression types in `proc_type`; do not reuse the single
  result type as the type of a procedure value.
- Check returns against `result_types`. Named results start at zero; a bare
  return selects all of them. Return expressions move into result temporaries
  before lexical cleanup begins. A result-bearing procedure whose `Flow_Info`
  can fall through receives the missing-return diagnostic.
- Permit a sole multi-result call in `a, b := f()`, `a, b = f()`, and
  `return f()`. Reject a multi-result expression in scalar contexts and reject
  arbitrary tuple-like mixing.
- Check positional-before-named ordering, duplicate/unknown names, arity, modes,
  and contextual assignability.
- Defaults are allowed only on value parameters. Resolve each default in the
  declaration’s lexical scope, permit references only to `self` and parameters
  to its left, and evaluate omitted defaults once in parameter order after all
  supplied arguments have been bound.
- Only a directly named procedure/method/group may use defaults. Calls through a
  procedure value supply every parameter.
- Give named procedure identifiers and compatible procedure literals their
  `proc_type`. Check procedure-type compatibility by convention, parameter and
  result types, and modes.
- Reject captures by a nested procedure literal when an identifier resolves to
  an enclosing procedure’s local, parameter, or result. Package/universe names
  and constants remain visible.
- Hoist each procedure literal to a uniquely named LLVM function. Emit direct
  calls for known declarations and indirect calls through `ptr` for procedure
  values; guard nil indirect callees through the M2 trap seam.
- Return several results as a private LLVM literal struct. This is an internal
  M2 calling convention used consistently by caller and callee, not the frozen
  Loke or C ABI.
- Keep `main` validation unchanged and keep move/variadic parameters gated.

Tests land for recursion and mutual recursion, value/inout parameters,
address-taking of value parameters, mutation through `inout`, multiple and named
results, missing returns, bare return with defer, defaults referencing earlier
parameters, named arguments, invalid default dependencies/modes, assigning and
calling procedure values, indirect nil calls, and rejected captures.

**Exit:** direct and indirect recursive procedures with parameters, defaults,
named arguments, and multiple results compile and run.

## Step 7 — Backend integration and invariant hardening

`src/emit_llvm.odin` plus focused semantic/backend tests.

- Audit every checked M2 expression and statement kind against emitter dispatch;
  reaching the backend without a lowering remains an assertion.
- Emit named struct definitions before uses, handling pointer recursion while
  relying on the checker to reject by-value cycles.
- Complete typed scalar and aggregate globals, zero initializers, and folded
  constants.
- Centralize operand rendering so integer signs, float constants, aggregate
  constants, procedure pointers, and nil use valid LLVM spelling.
- Assert that every basic block receives one terminator and no instruction is
  appended after termination.
- Run generated `.ll` through `clang` for every run/trap fixture. Keep
  representative `-emit-ll` goldens small enough to inspect integer guards,
  short-circuit blocks, defer flags, aggregate equality, bounds checks, and
  indirect calls.
- Add one integrated program using every M2 area and one file containing
  unrelated semantic failures to confirm diagnostic accumulation.

**Exit:** every fixture added in Steps 1–6 compiles from a clean build, and the
integrated program runs with the expected output.

## Step 8 — Diagnostic, gate, documentation, and milestone audit

- Continue stable semantic codes after `L0351`, allocated by failure category:
  representability, mismatch, arity, non-scalar value, addressability,
  immutability, recursive value type, missing return, switch exhaustiveness,
  duplicate case, invalid branch target, defer restriction, argument
  mode/name/default, conversion, bounds, and capture.
- Audit every code for an exact `tests/err/*.expected` entry containing the code,
  message substring, line, and column.
- Audit every runtime failure seam: index out of range, nil pointer/procedure
  dereference, and integer division by zero.
- Keep one `L0350` fixture per deferred family and include a declaration with
  several deferred fields to prove it still emits one diagnostic.
- Run the syntax corpus, ambiguity goldens, mutation fuzzer, M0/M1 run/err/trap
  corpora, and every M2 fixture.
- Update `USAGE` in `src/main.odin` and `readme.md` to describe M2’s executable
  subset and the remaining gates.

**Exit:** the full verification section below is green from a clean compiler
build, with no stale executable involved.

---

## Verification

```powershell
odin test src -define:ODIN_TEST_TRACK_MEMORY=false
odin build src -out:lokec.exe
odin test tests -define:ODIN_TEST_TRACK_MEMORY=false
./lokec.exe examples/hello.loke -o hello.exe
./hello.exe
```

Milestone spot checks:

- The maximum `u128`, `i128::min`, wrapping typed arithmetic, oversized runtime
  shifts, and `MIN / -1` fold and run identically.
- Typed `f16`/`f32` constant expressions match the same expressions evaluated at
  runtime.
- A nested struct of enum and array values can be constant or runtime, compares
  structurally, and supports checked indexing and pointers.
- A direct recursive procedure and an indirect procedure value use parameters,
  defaults, named arguments, `inout`, multiple results, and early returns with
  defer cleanup.
- A by-value recursive struct is diagnosed; the pointer-recursive equivalent
  compiles.
- A declaration containing several deferred field types produces one `L0350`.
- `-emit-ll` shows explicit oversized-shift/division guards, bounds and nil
  checks, short-circuit blocks, reverse defer cleanup, recursive aggregate
  equality, and indirect calls.

## Deliberate shortcuts, and when they are replaced

| Shortcut | Replaced when |
|---|---|
| No MIR; annotated AST lowers directly to LLVM | M6 (B13) |
| Private aggregate call/result convention, not a frozen Loke/C ABI | M7 (B15), before foreign calls |
| No offset/alignment table; only target widths and finite-size checking | M3 for `size_of`/`offset_of`; M7 for packed/foreign layout |
| Runtime failures use `llvm.trap` without a message or unwind | M6 seed runtime |
| `print_int` remains the only output builtin | M6 `core:fmt` |
| Single file and one package | M3 (B5) |
| `inout` modes are checked, but alias conflicts and escapes are not | M5 (B12) |
| Hand-written constant evaluator rather than the B10 interpreter | M3; B10 replaces its dispatch while retaining `Big_Int` and constant storage |

## Assumptions

- `design.md` and `grammar.md` are normative; M2 may redesign the language if needed and then ask for permision.
- The M1 parser and AST node kinds are stable. M2 may add semantic annotations
  such as result lists and place capabilities, but adds no syntax node kind.
- No external dependency, parser generator, code generator, or MIR is introduced.
  The compiler-owned `Big_Int` and constant aggregates use the existing semantic
  arena.

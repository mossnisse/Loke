# Loke compiler — build plan

A multi-level plan for building the Loke compiler (`lokec`), written in Odin.
The normative language is [design.md](design.md); the grammar is
[grammar.md](grammar.md). This document is **not** an implementation spec — it
decomposes the work so each component can get its own implementation plan later,
one at a time.

Three levels:

- **[A. Big decisions](#a-big-decisions)** — the architectural forks to settle before writing much code.
- **[B. Components](#b-components)** — the pipeline, phase by phase, with the Loke-specific hard parts.
- **[C. Milestones](#c-milestones)** — the order to build them so there's always something that runs.

Then [D. Out of scope for v1](#d-out-of-scope-for-v1) and [E. Testing & tooling](#e-testing--tooling).

Long-term goals driving this (from the brief): Windows-x64 first (Linux/macOS
later), **good error messages** backed by strict syntax, performant, LLVM for
optimized release builds, an optional fast debug build without LLVM.

---

## A. Big decisions

Settle these first; each shapes multiple components. "Locked" = already implied
by design.md, listed for the record. "Open" = a real fork — recommendation given,
revisit trigger noted.

| # | Decision | Recommendation | Status | Why / revisit when |
|---|----------|----------------|--------|--------------------|
| A1 | **IR count** | 3 durable stages: untyped AST → the same AST annotated with types/resolutions → a simple basic-block **MIR** for lowering & backends. Ownership and borrow dataflow use a lightweight per-procedure CFG view whose blocks reference typed-AST nodes; it is an analysis index, not another lowered IR. | Open, low-risk | Typed-AST analyses need control-flow edges, while backends need explicit operations and basic blocks. Keep the CFG view disposable and add a 4th durable IR only when a transformation cannot be expressed cleanly in MIR. |
| A2 | **Generics** | Monomorphization (instantiate per concrete argument set), with sharing of identical emitted bodies allowed later. | Open | design.md locks semantic specialization before ABI lowering, but explicitly leaves physical code sharing as an implementation detail. Revisit if compile time or binary size shows that full monomorphization is costly; internal dictionaries or erasure must remain unobservable at the ABI. |
| A3 | **Compile-time evaluation** | One tree-walking interpreter over the typed AST, reused everywhere a compile-time value is needed. | Locked | design.md requires ordinary `proc`s run at compile time. This engine is the keystone (see [B10](#b10-compile-time-evaluation-engine)); build it once, call it from constants, `when`, `where`, array lengths, `static foreach`, reflection. |
| A4 | **Debug backend (no-LLVM path)** | Direct **MIR → x86-64** codegen, emitting COFF objects. No transpiler, no external toolchain on this path. | Deferred — [out of v1 scope](#d-out-of-scope-for-v1) | Still the long-term goal (self-contained fast debug build), but a large component of its own. v1 ships on LLVM only; the eventual approach is recorded here so the MIR seam ([B13](#b13-lowering-to-mir)) stays backend-agnostic. |
| A5 | **LLVM interface** | Emit **textual `.ll`** and run `opt`/`llc`/`clang`. Move to the LLVM-C API only if IR-emit throughput matters. | Open, low-risk | Textual IR is trivial to inspect and needs no linked LLVM. Odin itself uses the C API — that's the upgrade path. |
| A6 | **Runtime/core seed language** | Write the minimal runtime (allocators, panic/unwind, string/array/map primitives, `dyn` dispatch) **in Odin/C first**; port to Loke-written `core` once the compiler can compile it. | Open | Avoids a chicken-and-egg block: the compiler needs a runtime to produce working exes before it can compile a Loke-written one. |
| A7 | **Linker** | Shell out to whatever's on the box (`lld-link` or MSVC `link.exe`); emit standard COFF objects. | Open, low-risk | Direct PE writing is a later optimization, not a v1 need. |
| A8 | **Compiler memory** | Per-phase arenas; intern types and identifiers into long-lived pools. | Locked (Odin has no GC) | Simple, fast, and frees a whole phase at once. |
| A9 | **Self-hosting** | No. Compiler stays in Odin for v1. | Locked | Self-hosting is a post-v1 goal, not a constraint now. |
| A10 | **Incremental & parallel compilation** | Not in v1. Keep the package as the natural boundary so it can be added later. | Locked (design lists it open) | Correctness and a working pipeline first; parallelism is an optimization with its own project. |

The one worth an explicit answer before much code exists is **A6** (runtime seed
language). The rest have safe lazy defaults.

---

## B. Components

Grouped front → back. Each entry: what it does, its input→output, the parts that
are *Loke-specific hard* (generic-compiler knowledge won't cover them), and what
to defer. Each is a candidate for its own implementation plan.

### Front end

#### B1. Driver & build config
CLI, resolve target/`#config`, seed package discovery from the root, drive the
iterative front-end phases, own the top-level arena and exit codes.
- **In:** command line, a root package dir. **Out:** a compiled artifact or diagnostics.
- **Loke-specific:** `#config` values are language constants visible to
  compile-time eval — the driver seeds them, it doesn't inject source. Build
  config is *not* source tags (design §Build configuration).
- **Defer:** watch mode, parallel jobs, caching.

#### B2. Source manager & diagnostics engine
Load files as byte buffers, map byte-offset ↔ line/col, render errors with source
snippets, carets, notes, and stable error codes; accumulate rather than abort.
- **In:** file paths. **Out:** buffers + a diagnostics sink used by every later phase.
- **Loke-specific:** the brief makes error quality a headline goal — this is a
  first-class component, not an afterthought. Every AST/MIR node carries a span
  back to here. Build it in [M0](#c-milestones) and never let a phase throw away spans.
- **Defer:** JSON diagnostic output, fix-its, colors are cheap add-ons.

#### B3. Lexer
UTF-8 (no BOM), tokens per grammar §Lexical structure. Longest-match; ASCII
outside strings/comments/chars; nested block comments; `#name` compile-time
names; the `::`/`:=` **token-pair** rule (they are `:` `:` and `:` `=`, not
single tokens).
- **In:** buffer. **Out:** token stream with spans (+ trivia if docs later want it).
- **Loke-specific:** longest-match edge cases (`&~=`, `..=`), rune/string escapes,
  raw strings, error *tokens* so the parser can keep going for good messages.
- **Defer:** doc-comment association.

#### B4. Parser & AST
Recursive descent, small fixed lookahead, per grammar.md. Produces the AST with a
node type per production and a span on every node. Handles the grammar's listed
[resolved ambiguities](grammar.md#resolved-ambiguities) with bounded scans
(declaration-vs-simple-statement, type-switch `name in expr`, contextual
keywords `static`/`slot`/`delegate`/`via`, brace-bodied constants, unresolved
generic args left for name resolution).
- **In:** tokens. **Out:** AST per source file.
- **Loke-specific:** **error recovery** (synchronize on `;`, `}`, top-level
  keywords) is where "strict syntax → good errors" is cashed in. Attributes
  attach to many positions. Keep unresolved `T(x)` argument/generic forms as an
  "unclassified" node — name resolution decides type-vs-value.
- **Defer:** nothing structural; this must be complete and well-tested early.

### Semantic middle

#### B5. Package loading & import graph
Group files by directory into packages (one package per dir, matching package
clause), discover imports to a fixed point, build the import DAG, **reject
cycles** with the import path (design §Import cycles), and topologically order it
for `@(init)`. This is staged orchestration rather than a one-shot phase:
unconditional imports extend the graph first; once their packages are available,
the header-level parts of B6/B8/B10 resolve each file-scope `when` condition and
activate only the selected top-level items. Newly activated imports extend the
graph, and the process repeats until no edge is added. A `when` condition cannot
bootstrap itself from an import inside one of its own branches.
- **In:** root-package ASTs + target/config constants. **Out:** selected ASTs,
  finalized package DAG, resolved import edges, deterministic init order.
- **Loke-specific:** `core:`/`foreign import` resolution; conditional imports in
  file-scope `when`; cycle diagnostics as paths of active import statements.

#### B6. Name resolution & scopes
Two passes: collect all top-level decls of a package (order-independent), then
resolve names in bodies. Scope rules, discard `_`, shadowable predeclared
`nil`/`true`/`false`/built-ins, keyword reservation, shadowing mostly rejected
(design open-question defaults to reject). Classify the parser's unclassified
generic/argument nodes as type / const / value.
- **In:** ordered packages. **Out:** every identifier bound to a symbol; each node classified.
- **Loke-specific:** package-vs-public visibility (exactly two levels), `impl`/`extend`
  method lookup registration (no UFCS — `x.f()` binds only to a `self` receiver
  or a built-in), definition-site lookup for generic bodies.

#### B7. Type system core
Type representation + interning: basic types, `distinct`, structs/enums/unions,
slices `[]T`/`[]mut T`, arrays, `[dynamic]T`, `map`, `^T`, `[^]T`, proc types,
`type`/`typeid`, `any_view`, `dyn Interface`, untyped constants,
`string`/`string_view`/`cstring_view`, SIMD.
- **Out:** a canonical, comparable type for every type expression.
- **Loke-specific:** `[]T` vs `[]mut T` capability distinction; `distinct`
  inherits no operators; compile-time-only `type` vs runtime `typeid`;
  call-scoped `any_view` and borrowed `dyn`; untyped-constant default types;
  foreign-ABI-safe subset.

#### B8. Type checking & overload resolution
Bidirectional-ish checking of decls, assignments, expressions; untyped-constant
handling; operator typing; optional-ok / `or_else` / `or_return`; method &
operator resolution with the exact tie-breaker rules; interface constraint
checks; `any_view` conversions, assertions, type switches, and its narrow
`..any_view` variadic exception; **copy-cost diagnostics**.
- **In:** resolved AST. **Out:** typed AST (nodes annotated with types + chosen overloads).
- **Loke-specific:** procedure groups & operator overload resolution (structure
  decides the winner, ties are errors — design §Operator lookup); no enum
  arithmetic; `+` string concat; map place/`inout` semantics; `@(implicit)`
  one-arg `init` on untyped constants only.
- **Defer:** none essential; grows alongside B9–B12.

#### B9. Generics, interfaces & specialization
`$` params + inference, `where` clauses, interface satisfaction (structural
requirements + named `slot`s), monomorphization with an instantiation cache,
`static foreach` expansion, compile-time reflection (`fields_of`, `enum_values_of`).
- **In:** typed generic decls + instantiation sites. **Out:** concrete instantiated decls.
- **Loke-specific:** definition-site lookup (a caller's local `extend` can't
  change an instantiation); `dyn` compatibility + witness-table construction per
  `(Interface, Concrete, args)`; `where` must be compile-time bool. Leans hard on B10.

#### B10. Compile-time evaluation engine
Tree-walking interpreter over the typed AST. Serves constant initializers,
`when`, `where`, array lengths, enum values, `$`/generic value args, `static
foreach` iterables, reflection, `#assert`/`#config`/`#location`/`#caller_location`.
Hermetic sandbox: on the *executed* path forbid runtime/foreign/atomic/IO/address
observation; compiler-owned storage for temp managed values; documented
step/recursion/memory limits that **diagnose** rather than fall back to runtime.
- **In:** a typed expression + a compile-time environment. **Out:** a compile-time value or a diagnostic.
- **Loke-specific:** this is the core of "one language at compile time." Same
  `proc` must run at compile time and runtime with identical semantics — no
  phase-observing operation. Only the executed branch must satisfy the sandbox;
  ordinary branches still type-check, but a branch discarded by `when` does not.
  Expose the same evaluator through the staged file-scope `when` orchestration in
  B5; do not build a second conditional-compilation evaluator. Build early
  ([M3](#c-milestones)); it unblocks generics.

#### B11. Ownership, move & lifecycle analysis
Build or reuse the disposable per-procedure CFG view described in A1. Use it to
place `drop`s at scope exit in reverse-init order, order them against `defer`,
track moved-from bindings and drop flags, select deep copies for managed owners,
honor `manual`/`static`/`thread_local`, compute panic-unwind cleanup sets, and
materialize constants used by non-constant indexing or slicing.
- **In:** typed (post-generic) AST. **Out:** typed AST annotated with explicit
  copy/drop/defer/move obligations + the analysis CFG view.
- **Loke-specific:** default deep-copy for mutable owners (design §Value-semantic
  assignment), immutable `string` may share backing (atomic count), file-scope &
  `static` owners never auto-dropped, `thread_local` dropped on normal return only,
  `@(fini)` excluded from panic path.

#### B12. Borrow & lifetime checker
Mostly procedure-local dataflow over the same CFG view. Enforce "the one rule"
(design §Borrows): reject invalidating a container while a view (`[]T`, `[]mut
T`, `string_view`, `cstring_view`, `any_view`, or `dyn`) is live and reject
obvious local escapes; conservatively attribute a returned borrow to every
borrowed argument it could derive from.

Also track allocator region identity and owner provenance. Copies of an
allocator retain one region identity; owners and borrows remember the region
that backs them; an owner backed by a shorter-lived region cannot escape it.
Calls carrying `@(allocator_reset)` are checked against every live owner and
borrow that may use the affected region, and procedure effect summaries verify
and propagate that promise through direct and indirect calls.
- **In:** typed AST + analysis CFG + callee effect summaries. **Out:** pass/fail
  diagnostics, owner/borrow provenance annotations, verified procedure effects;
  optional debug-mode runtime checks.
- **Loke-specific:** raw pointers / stored borrows / foreign calls / cross-thread
  are explicit trust boundaries and *not* checked. Allocator-reset effects and
  owner region provenance are the deliberate cross-call exception. Diagnostics
  name the region root, escaping owner or live borrow, and invalidating operation.

### Lowering & runtime

#### B13. Lowering to MIR
After monomorphization and the ownership/borrow analyses, lower the annotated
typed AST to a simple basic-block MIR. Rebuild durable basic blocks rather than
promoting the disposable analysis CFG: make explicit the method calls,
operators, composite literals, `foreach`, `defer`, `or_return`, slice/map ops,
`any_view` conversion/assertion/type-switch operations and call-scoped variadic
storage, `dyn` witness dispatch, string ops, bounds checks, and copy/drop calls
into the runtime.
- **In:** fully resolved typed AST + ownership/provenance annotations. **Out:**
  backend-agnostic MIR with explicit cleanup and control flow.
- **Loke-specific:** the seam both backends target ([A4](#a-big-decisions)/[A5](#a-big-decisions)); keep it small and explicit.

#### B14. Runtime / core library
Minimal runtime linked into every program: allocator interface + default
allocators + failure policy (`.Panic`/`.Trap`), `string`/`[dynamic]T`/`map`
primitives, panic + `unwind`/`abort` strategies, bounds/assertion traps, type
information for `type_info_of`, `any_view`, and `dyn`, witness tables, drop
dispatch.
- **Loke-specific:** allocation-failure policy per allocator; two panic strategies
  (hosted `unwind` vs freestanding `abort`); atomic string handle accounting.
- **Seed in Odin/C ([A6](#a-big-decisions)); grow the Loke `core:` once self-compilable.**

### Back end

#### B15. ABI & layout
Struct layout/alignment, `@(packed)` and layout attributes, SIMD lowering,
foreign-ABI-safe types, Windows x64 calling convention, `"c"`/`"stdcall"`
conventions, foreign symbol/link-name handling. **Shared by all codegen backends.**

#### B16. LLVM backend (release)
MIR → textual LLVM IR ([A5](#a-big-decisions)) → `opt`/`llc`. Optimized release builds.
The only backend in v1 — the no-LLVM debug backend is [out of scope](#d-out-of-scope-for-v1).

#### B17. Linking & object emission
Standard COFF objects, invoke `lld-link`/`link.exe`, link foreign C libraries,
produce the `.exe`.

### Cross-cutting (built once, used by all)

- **Diagnostics & source manager** — [B2](#b2-source-manager--diagnostics-engine), the backbone of the error-quality goal.
- **Interning/arenas** — [A8](#a-big-decisions); types, identifiers, strings.
- **Testing** — [E](#e-testing--tooling).

---

## C. Milestones

Build a thin end-to-end slice first, then widen. Each milestone ends with a
runnable checkpoint. Per-component implementation plans get written just-in-time
as each milestone starts.

| M | Goal | Exit criterion |
|---|------|----------------|
| **M0** | **Vertical slice.** Driver + source mgr + diagnostics skeleton + lexer + parser for a tiny subset (`main`, int vars, arithmetic, a builtin print) + trivial type check + **a running Windows exe via the LLVM textual path** ([A5](#a-big-decisions) — least code to a first exe). | `main :: proc(){ ... }` compiles and prints. The whole spine and the backend seam exist. |
| **M1** | **Full front end.** Complete lexer + parser for *all* of grammar.md with error recovery + a parser/lexer test corpus. | Every grammar construct parses; malformed inputs give good, recovering diagnostics. |
| **M2** | **Static core semantics.** Name resolution + type system + type checking + overloads/operators for the non-generic, non-managed subset (basics, structs/enums/unions, control flow, procs). Constant folding. | Non-generic programs type-check and run through the M0 backend. |
| **M3** | **Compile-time engine** ([B10](#b10-compile-time-evaluation-engine)). Constants, file- and procedure-scope `when`, conditional-import discovery, array lengths, enum values, `#assert`/`#config`/`#location`. | Compile-time `proc` evaluation works; discarded `when` branches are not semantically checked, the conditional package graph reaches a stable DAG, and sandbox violations are diagnosed. |
| **M4** | **Generics & erased views.** `$`/inference, interfaces + `where`, monomorphization, `static foreach`, reflection, `any_view`, `dyn` witnesses. | Generic + interface programs compile and run; `any_view` and `dyn` obey their representation, dispatch, and borrow/escape rules. |
| **M5** | **Managed memory.** Ownership/move/deep-copy, drop insertion, `defer` ordering, lifecycle hooks, materialization; then borrow and allocator-region checking ([B11](#b11-ownership-move--lifecycle-analysis)/[B12](#b12-borrow--lifetime-checker)). | Owning values, `defer`, `move`, borrows, region-backed owners, and `@(allocator_reset)` behave per spec; invalid escapes/resets and copy costs are diagnosed. |
| **M6** | **MIR + runtime.** Full lowering ([B13](#b13-lowering-to-mir)) + the seed runtime ([B14](#b14-runtime--core-library)): strings, dynamic arrays, maps, panic/unwind. | Real programs using the managed stdlib run correctly. |
| **M7** | **Release + interop.** LLVM backend ([B16](#b16-llvm-backend-release)), ABI/layout completeness ([B15](#b15-abi--layout)), foreign/C interop, linking. | Optimized release builds; C libraries link and call. |
| **M8** | **Later.** Linux/macOS targets, incremental/parallel, debug info, tooling. | Out of v1 scope. |

Sequencing rationale: M3 precedes M4 because type-checking generics needs
compile-time evaluation (`where`, lengths, `when`). Package discovery is the
intentional staged exception: B5 invokes the header-level parts of name/type
checking and the M3 evaluator until conditional imports stabilize. M5 follows M4
because drop/move/borrow/region analysis operates on fully resolved,
monomorphized types. M6 turns those analysis results into durable MIR only once
everything above is resolved.

---

## D. Out of scope for v1

- **No-LLVM debug backend** (direct MIR → x86-64, [A4](#a-big-decisions)) — still a
  long-term goal, but v1 ships on the LLVM backend only. Keep the MIR seam
  ([B13](#b13-lowering-to-mir)) backend-agnostic so it can be added without rework.

Mostly already deferred by design.md's open questions — don't build them:
recoverable panics / `recover`, first-class tuples, a GC allocator, Unicode
identifiers, token/AST macros & declaration generation, an effect/purity system,
owning type erasure (`box(dyn I)`), thread-affine strings, incremental &
parallel compilation, self-hosting, non-Windows targets, debug-info/DWARF/PDB.

Adding any of these later is additive; none changes the pipeline shape above.

---

## E. Testing & tooling

Thin and boring, added per milestone — not a framework project:

- **Lexer/parser:** golden token/AST dumps + a corpus of malformed inputs
  asserting the *diagnostic* (the error-quality goal is a testable artifact).
- **Semantics:** pass/fail `.loke` files, each asserting either success or a
  specific error code + span.
- **Run tests:** compile + run + check stdout on every enabled backend. v1 runs
  these on LLVM; when the no-LLVM backend lands, the same corpus becomes a
  differential suite that keeps both backends in agreement.
- **Compile-time:** files asserting a computed constant and files asserting a
  sandbox-violation diagnostic.
- **Parser fuzzing** once M1 lands — cheap insurance for "never crash, always diagnose."

---

*Next step: pick a milestone (M0 is the natural start) or a single component and
turn it into a detailed implementation plan.*

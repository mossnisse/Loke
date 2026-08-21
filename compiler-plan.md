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
| A1 | **IR count** | 2 durable v1 stages: untyped AST → the same AST annotated with types/resolutions. Ownership and borrow dataflow use a lightweight per-procedure CFG view whose blocks reference typed-AST nodes; it is an analysis index, not another lowered IR. Add a durable basic-block MIR when a second backend or another concrete consumer exists. | Settled for v1 | The typed-AST-to-textual-LLVM emitter is already the only v1 backend. MIR would currently rewrite that working path without serving another consumer; the disposable CFG remains sufficient for semantic dataflow. |
| A2 | **Generics** | Monomorphization (instantiate per concrete argument set), with sharing of identical emitted bodies allowed later. | Open | design.md locks semantic specialization before ABI lowering, but explicitly leaves physical code sharing as an implementation detail. Revisit if compile time or binary size shows that full monomorphization is costly; internal dictionaries or erasure must remain unobservable at the ABI. |
| A3 | **Compile-time evaluation** | One tree-walking interpreter over the typed AST, reused everywhere a compile-time value is needed. | Locked | design.md requires ordinary `proc`s run at compile time. This engine is the keystone (see [B10](#b10-compile-time-evaluation-engine)); build it once, call it from constants, `when`, `where`, array lengths, `static foreach`, reflection. |
| A4 | **Debug backend (no-LLVM path)** | Introduce the deferred backend-agnostic MIR, then lower it directly to x86-64 COFF. No transpiler or external toolchain on this path. | Deferred — [out of v1 scope](#d-out-of-scope-for-v1) | Still the long-term goal, but it is the first concrete second consumer that justifies a durable MIR. v1 ships on the existing LLVM path. |
| A5 | **LLVM interface** | Emit **textual `.ll`** and run `opt`/`llc`/`clang`. Move to the LLVM-C API only if IR-emit throughput matters. | Open, low-risk | Textual IR is trivial to inspect and needs no linked LLVM. Odin itself uses the C API — that's the upgrade path. |
| A6 | **Runtime/core seed language** | A versioned **C** runtime supplies allocation, panic, thread, and container primitives; ordinary Loke-source `base:`/`core:` packages layer their public APIs on it. | Settled for M6 | C sources can join the existing clang invocation without a bootstrap cycle. Loke source remains the public library surface once the required language features exist. |
| A7 | **Linker** | Shell out to whatever's on the box (`lld-link` or MSVC `link.exe`); emit standard COFF objects. | Open, low-risk | Direct PE writing is a later optimization, not a v1 need. |
| A8 | **Compiler memory** | Per-phase arenas; intern types and identifiers into long-lived pools. | Locked (Odin has no GC) | Simple, fast, and frees a whole phase at once. |
| A9 | **Self-hosting** | No. Compiler stays in Odin for v1. | Locked | Self-hosting is a post-v1 goal, not a constraint now. |
| A10 | **Incremental & parallel compilation** | Not in v1. Keep the package as the natural boundary so it can be added later. | Locked (design lists it open) | Correctness and a working pipeline first; parallelism is an optimization with its own project. |

A1 and A6 are settled for v1. The remaining open entries have safe lazy
defaults.

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
  first-class component, not an afterthought. Every AST node and future lowered
  node carries a span back to here. Build it in [M0](#c-milestones) and never
  let a phase throw away spans.
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
for dependency processing. This is staged orchestration rather than a one-shot
phase:
unconditional imports extend the graph first; once their packages are available,
the header-level parts of B6/B8/B10 resolve each file-scope `when` condition and
activate only the selected top-level items. Newly activated imports extend the
graph, and the process repeats until no edge is added. A `when` condition cannot
bootstrap itself from an import inside one of its own branches.
- **In:** root-package ASTs + target/config constants. **Out:** selected ASTs,
  finalized package DAG, resolved import edges, deterministic dependency order.
- **Loke-specific:** `core:`/`foreign import` resolution; conditional imports in
  file-scope `when`; cycle diagnostics as paths of active import statements.

#### B6. Name resolution & scopes
Two passes: collect all top-level decls of a package (order-independent), then
resolve names in bodies. Scope rules, discard `_`, shadowable predeclared
`nil`/`true`/`false`/built-ins, keyword reservation, shadowing mostly rejected
(design open-question defaults to reject). Classify the parser's unclassified
generic/argument nodes as type / const / value.
- **In:** ordered packages. **Out:** every identifier bound to a symbol; each node classified.
- **Loke-specific:** package-vs-public visibility (exactly two levels), including
  uniform checks for struct-field reads, writes, aggregate construction, and
  reflection; `impl`/`extend` method lookup registration (no UFCS — `x.f()`
  binds only to a `self` receiver or a built-in); definition-site lookup for
  generic bodies.

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
honor `manual`/`static`/`thread_local`, compute the cleanup registration and
liveness facts consumed by normal exit and panic unwind, and materialize
constants used by non-constant indexing or slicing.
- **In:** typed (post-generic) AST. **Out:** typed AST annotated with explicit
  copy/drop/defer/move obligations + the analysis CFG view.
- **Loke-specific:** default deep-copy for mutable owners (design §Value-semantic
  assignment), immutable `string` may share backing (atomic count), file-scope &
  `static` owners never auto-dropped, `thread_local` dropped on normal return only,
  and `os.exit` bypasses lexical cleanup.

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

**Deferred past v1 with A4.** When a second backend or another concrete consumer
exists, lower the annotated typed AST to a simple basic-block MIR. Rebuild
durable basic blocks rather than promoting the disposable analysis CFG: make
explicit method calls, operators, composite literals, `foreach`, `defer`,
`or_return`, slice/map ops, erased conversion/assertion/type-switch operations,
call-scoped variadic storage, witness dispatch, string ops, bounds checks, and
runtime copy/drop/panic calls.
- **In:** fully resolved typed AST + ownership/provenance annotations. **Out:**
  backend-agnostic MIR with explicit cleanup and control flow.
- **Loke-specific:** keep it small and backend-agnostic when it is introduced;
  do not promote the semantic CFG into a durable lowering IR.

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
Annotated typed AST → textual LLVM IR ([A5](#a-big-decisions)) →
`opt`/`llc`/`clang`. Optimized release builds.
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
| **M2** | **Static core semantics.** Universe/name resolution, built-in type checking and constant folding, plus typed LLVM widening for the non-generic, non-managed core: numeric/Boolean/rune scalars, raw and typed pointers, fixed arrays, structs, enums, distinct and procedure types; assignment, control flow, `defer`, procedures, and procedure values. User-defined operators and unions remain gated. | Programs in the precisely bounded [M2 subset](m2-plan.md#scope) type-check, fold, compile, and run through the textual-LLVM path; deferred outer constructs still produce one non-cascading gate diagnostic. |
| **M3** | **Compile-time engine and packages** ([B5](#b5-package-loading--import-graph)/[B10](#b10-compile-time-evaluation-engine)). Retain the checker's contextual leaf/operator folding as the shared value core and add the typed interpreter for procedure evaluation; add file- and procedure-scope `when`, staged conditional imports, multi-file packages, untyped compile-time strings, `#assert`/`#config` with `-define`, phase-neutral `assert`/`panic`, and natural-layout `size_of`/`align_of`/`offset_of`/`len`. Collection prefixes resolve through `-collection name=path`, with no implicit `core:` root. `#location`/`#caller_location` move to M6a with runtime `string` and `Source_Code_Location`; packed/foreign layout remains M7. | Compile-time `proc` evaluation works from every required M3 context; discarded `when` branches are neither checked nor emitted; the conditional package graph reaches a stable DAG; multi-package code emits collision-free symbols; layout agrees with executed LLVM-derived values (`-check-layout`); and sandbox/limit failures are diagnosed with the compile-time stack. |
| **M4a** | **User abstractions** ([B8](#b8-type-checking--overload-resolution)), planned in [m4a-plan.md](m4a-plan.md). One overload-resolution engine — viability, conversion-rank vectors, tie-breakers — shared by procedure groups, `impl`/`extend` methods, user operators, `delegate`, indexing, and `init` conversions including `@(implicit)`; unions with assertions, type switches, `or_else`, and `or_return`. Concrete types only: nothing here instantiates a declaration. | User operators, methods, and `init` conversion work at concrete types; an ambiguous call lists every maximal candidate with its vector and failing tie-breaker; an `extend` block changes lookup only in its own package; unions round-trip, assertions trap or yield comma-ok by position, and `or_return` propagates through named results with `defer` in order. |
| **M4b** | **Generics, interfaces & erased views** ([B9](#b9-generics-interfaces--specialization)), planned in [m4b-plan.md](m4b-plan.md). Declaration cloning, `$`/inference, specialization, `where`, and monomorphization; interfaces with per-requirement diagnostics and the unmanaged portion of the catalogue as ordinary Loke source; reflection and static `foreach`; `foreach` over ranges, fixed arrays, and the user iteration protocol; `typeid`, `any_view`, and `dyn` witnesses. Reflection filters struct fields by package/public visibility at its lookup package. Ordinary field access and construction temporarily retain M4a behavior and remain unfiltered until M5a. Managed types remain absent, so `Cloneable`, iteration over slices/maps/strings, `..any_view`, and lifecycle hooks stay with the milestone that introduces their dependencies. | A generic container instantiated twice yields independent instances with distinct symbols; a failed interface bound names the requirement line and the concrete type; a caller-local `extend` cannot reach into an instantiation; cross-package reflection omits package-visible fields and static expansion type-checks a different field type per visible copy; `any_view` and `dyn` obey their representation and dispatch rules, with borrow/escape checking deferred to M5b and the boundary stated. |
| **M5a** *(implemented)* | **Visibility, slices, and lifecycle** ([B11](#b11-ownership-move--lifecycle-analysis)), planned in [m5a-plan.md](m5a-plan.md). Apply one package/public rule to reflection, ordinary field reads/writes, `offset_of`, and aggregate construction. Add complete slice value/capability behavior and constant materialization; fixed lifecycle hooks, ownership/move/deep-copy, parameter/result transfer, drop insertion, storage modifiers, copy-cost diagnostics, allocator semantic types, and a minimal default-CRT `new`/`new_clone`/safe-direct-`free` path. Full provenance, copied-root `free`, and region reset remain M5b. | Reflection and ordinary access agree across package boundaries; slices, literals, iteration, and read-only materialization run; a resource drops exactly once on every normal exit in one LIFO order with `defer`; move kills its source, conditional liveness cleans up correctly, deep copy preserves a live destination on failure, all four copy sites are diagnosed, and `Cloneable` compiles against real lifecycle and allocator types. |
| **M5b** *(implemented)* | **Borrows, provenance, and allocator regions** ([B12](#b12-borrow--lifetime-checker)), planned in [m5b-plan.md](m5b-plan.md). Propagate root/capability and region provenance over M5a's CFG; enforce last-use borrowing, exclusivity, invalidation, escape, copied allocation-root release, direct/cross-package result summaries, conservative procedure-value results, `free_all`, and transitive `@(allocator_reset)` effects. Close the `any_view`, `dyn`, `inout`-result, `[:]`-result, and slice lifetime gaps. | Invalid root access, local escape, longer-lived region escape, and reset are rejected with diagnostics naming the creation/dependency and conflict; copied allocation bases free once and invalidate aliases; direct and indirect calls preserve the required summaries/effects; every deliberate v1 trust boundary remains tested as accepted. |
| **M6a** | **Runtime foundations and strings** ([B14](#b14-runtime--core-library)), planned in [m6a-plan.md](m6a-plan.md). Add the versioned C runtime and allocator-provider ABI, implicit `base:`/`core:` roots and nameable runtime/meta/mem/fmt/unsafe packages, logical cross-frame panic cleanup with unwind/abort selection, runtime strings and borrowed text views, multi-pointers, ordinary `..T` plus call-scoped `..any_view` variadics, checked runtime type information, coherent erased formatting, and source locations. | Programs link the compiler-relative runtime; every specified panic follows unwind or abort correctly; text ownership/borrowing is checked; homogeneous and erased variadics run; `fmt` replaces `print_int`; `type_info_of` and source locations expose their frozen runtime layouts. |
| **M6b** | **Managed containers and regions**, planned in detail in [m6b-plan.md](m6b-plan.md). Add dynamic arrays and maps with complete operations/lifecycle/formatting, eager `via` and lazy default allocator binding, iteration and invalidation, address-stable `mem.Arena`/`mem.Scratch` controls as real local regions, successful reset, and the remaining dynamic-array-dependent string/unsafe/evaluator handoffs. | Dynamic arrays and maps preserve value, allocator, failure, and borrow semantics; arena-backed owners cannot escape or survive reset; moving a provider preserves its allocator-record address and region identity; all managed runtime types iterate, format, copy/move/drop, and fail without publishing partial state. |
| **M7** | **Release + interop**, planned in [m7-plan.md](m7-plan.md). LLVM backend ([B16](#b16-llvm-backend-release)), ABI/layout completeness ([B15](#b15-abi--layout)), foreign/C interop, linking. Optimization and build modes with the `LOKE_*` build constants; one attribute validation table; `@(packed)`/`@(align=N)`; the Windows x64 classification for `"c"`/`"stdcall"` with `@(by_ptr)` and `@(c_vararg)`; foreign imports, blocks and globals; `@(export)` with object output; and `core:os` over a foreign block. | Optimized release builds, identical in behaviour at every optimization level; C libraries link and call, and C links and calls exported Loke code. |
| **M8** | **Later.** `Simd(T, N)` with lane-wise operators and `core:simd`; the [library types](#d-out-of-scope-for-v1) design.md assumes, including the compiler atomic intrinsics `Atomic(T)` and `shared(T)` need; then Linux/macOS targets, incremental/parallel, debug info, tooling. | Out of v1 scope. |

Sequencing rationale: M3 precedes M4 because type-checking generics needs
compile-time evaluation (`where`, lengths, `when`). Package discovery is the
intentional staged exception: B5 invokes the header-level parts of name/type
checking and the M3 evaluator until conditional imports stabilize. M5a follows M4
because drop/move/borrow/region analysis operates on fully resolved,
monomorphized types. M5a establishes lifecycle liveness, cleanup ordering, and
the concrete carriers without requiring general provenance; M5b consumes those
states and CFG edges for every borrow, escape, and allocator-reset rule. Slices
land in M5a because they have no runtime allocator or cleanup obligation, are
required by materialization, and give M5b a real built-in carrier to check. M6a
turns those analysis results into a working runtime, panic cleanup, strings, and
standard library seams; M6b consumes those seams for containers and real local
allocator regions. Durable MIR waits until a second backend or another concrete
consumer justifies it. User-defined operator resolution lands in M4a
beside named overloads because both share candidate formation, conversion
vectors, and the same tie-breakers; M2 implements only the fixed built-in
operator table.

M4a is implemented: `src/overload.odin` owns the one candidate engine,
`src/impl.odin` the method and `init` tables, `src/operators.odin` the operator
tables and `delegate`, and `src/union.odin` plus `src/optional.odin` the tagged
representation and the error protocol. Diagnostics `L0391`–`L0396`,
`L0406`–`L0413`, `L0416`–`L0421`, and `L0422`–`L0430` are live; the narrowings
taken along the way are recorded in [m4a-plan.md](m4a-plan.md).

M4b is implemented: `src/ast_clone.odin` supplies the declaration cloning both
generics and static `foreach` need, `src/generic.odin` the templates, inference,
structural specialization, `where` clauses and the monomorphization cache,
`src/interface.odin` requirement checking with its per-requirement lookup
contexts, `src/hash.odin` the compiler-contributed `hash` the standard
`Hashable` entry is satisfied through, `src/reflect.odin` the descriptors and the
symbolic-to-numeric `typeid` freeze, `src/expand.odin` static expansion,
`src/iterate.odin` `Range(T)` and the iteration protocol, and `src/erased.odin`
`any_view`, `dyn`, and witnesses. The unmanaged catalogue is ordinary Loke source
in `base/interfaces/`. Diagnostics `L0431`–`L0438` (generics), `L0441`–`L0445`
(interfaces), `L0451`–`L0455` (reflection and static expansion), `L0456`–`L0458`
(iteration), and `L0462`–`L0467` (erased views) are live; the narrowings taken
along the way are recorded in [m4b-plan.md](m4b-plan.md).

M4b also introduces field visibility metadata and consults it when
`fields_of` forms descriptors at a reflection lookup package. Ordinary reads,
writes, and aggregate construction intentionally remain unfiltered for M4a
corpus compatibility. M5a must make those operations use the same package/public
check; `@(private)` denotes package visibility throughout and is not a
reflection-only hiding mechanism.

Two narrowings are worth stating here because they differ from the plan's
letter. An instance is cloned once rather than as a separate signature instance
and body instance: an unselected candidate's body is still never checked, so the
observable contract holds with half the machinery. And tie-breaker 4 between a
generic `impl Table($K, $V)` and a specialized `impl Table(string, int)` is
applied when the blocks are installed on an instance rather than in the
candidate engine, because monomorphization makes both blocks resolve to the same
concrete type before any call is ranked.

M4 splits at the one seam where its work stops being mutually dependent: nothing
in M4a instantiates a declaration, and everything in M4b needs M4a's methods and
overload engine. M4a fixes the engine's contract — viability filters, structure
orders, constraints never rank — and leaves a viability hook that M4b fills with
`where` clauses and interface applications, so the second half never reopens the
first. The seam is why generics and static `foreach` stay together in M4b: types
are annotated onto the AST (A1), so a second instantiation cannot reuse the
first's nodes, and both features need the same declaration-cloning facility.

M5 splits at the analogous dataflow seam. M5a owns lifecycle state and the
observable cleanup/copy behavior; M5b owns the root and region relationships
that require those states. The only narrow bridge was M5a's fresh-allocation-base
fact, which kept its direct `new`/`free` path safe and is now subsumed by M5b's
general root provenance.

M5b is implemented: `src/cfg.odin`'s structural walk is split from its
mode-specific actions, so the same block topology serves M5a's lifecycle
analysis and two read-only provenance rebuilds, and `src/borrow.odin` solves the
root and region lattices over the provenance event stream that second walk
records. Root provenance is reaching loans forwards and carrier liveness
backwards, over places that are a root plus a normalized projection path; region
provenance is allocator identity, `@(allocator_reset)` verification, and the
reset liveness proof. Result-provenance summaries are collected by one extra
read-only rebuild per body and iterated to a whole-program fixed point, so they
are independent of source order and cross package and generic-instance
boundaries. `@(allocator_reset)` is interned into the procedure type, which is
what makes the effect survive an indirect call. Diagnostics `L0511`–`L0514`
(root access, invalidation, outlived root, allocation base), `L0526` (escape),
`L0536`–`L0539` (region escape, surviving dependant, unpromised reset, misplaced
attribute) and `L0547` (mutable user slice) are live; the narrowings taken along
the way are recorded in [m5b-plan.md](m5b-plan.md).

M6a is implemented in full ([m6a-plan.md](m6a-plan.md)). `runtime/` holds the versioned C seed, whose
sorted `*.c` inputs join the existing clang invocation; the directory is
resolved from the canonical `lokec.exe` path unless `-runtime=<dir>` replaces
it. An `Allocator` is one pointer to a `loke_rt_allocator_v1` record — version
and size prefix, state, canonical region identity, ops table, failure policy —
so copying a handle preserves every one of those facts, and `new`, `new_clone`,
`free`, generated lifecycle clones and `free_all` all dispatch through it with
the exact size and alignment. `base` and `core` are seeded from directories
beside the compiler and replaced, not merged, by an explicit `-collection`;
`src/stdlib.odin` binds `Allocator`, `Allocator_Error`, `default_allocator`,
`meta.Field` and `meta.Enum_Value` into `core:mem`, `base:runtime` and
`base:meta` as the *same* identities the universe and M4b already own, so no
spelling creates a second type. Every runtime fault that design.md calls a panic
now reaches `loke_rt_v1_panic` with its own message instead of `llvm.trap`;
under `-panic=unwind` each procedure that owns a cleanup pushes an opaque
`{previous, thunk, context}` frame, publishes each action's registration in a
live-flag array, and generates one thunk that replays the still-registered
actions newest-first, while `-panic=abort` registers nothing. Step 4 makes text real. A `string` is `{data, byte_len, owner_flags}`: a literal
is a compile-time constant over static zero-terminated storage with the static
bit set, and a runtime buffer carries a header holding an atomic handle count
and the allocator that created it, so assignment retains, drop releases, the
last handle frees through that allocator, and only `.clone()` allocates.
`string_view` is `{data, byte_len}` and `cstring_view` is one address; both are
borrow carriers, so `src/borrow.odin` rejects an escaping subrange, `bytes()`
result, or `to_c_view()` temporary with the same machinery it already applied to
slices. `src/text.odin` holds the checking side of the operations and
conversions, `[^]T` indexes without a bound and slices into either shape,
`core:unsafe` publishes `raw_data`/`string_view`/`cstring_view`, and `#location`
and `#caller_location` fold to constant `runtime.Source_Code_Location`
aggregates.

Step 5 adds the erased half. A `..T` parameter is one read-only `[]T`: a sole
compatible spread forwards its slice untouched, and any other mix of explicit
arguments and `..slice` spreads is concatenated in source order into
compiler-owned stack storage, sized statically when it can be and with a
runtime `alloca` when a spread makes it dynamic. Overload ranking places
trailing arguments into the pack and design.md's fixed-over-variadic
tie-breaker still decides between candidates. `..any_view` is the call-scoped
exception: its slice and elements cannot be returned or stored, and a
source-declared `[]any_view` is still rejected everywhere else. `type_info_of`
reads a dense table keyed by the frozen `typeid`, built over a requested set
closed recursively so member types resolve, and answers nil for the zero id and
for one forged out of range. Formatting is coherent per concrete `typeid`: the
compiler generates one thunk per printable type into a private table parallel to
the type-info table, an owning package's own `format(value, writer, options)`
replaces the generated one, and two such declarations for one type are `L0572` —
a defensive check, because the ordinary member-uniqueness rule `L0409` reaches
every program that would reach it first. A `typeid` prints as the name of what it
identifies, read from a private table parallel to the thunks so that printing
does not oblige a program to import `base:runtime`.
`core:fmt` is ordinary Loke source over four compiler-owned intrinsics — the two
standard writers, a raw byte sink, and the erased dispatch — so `print`,
`println`, `eprint`, `eprintln`, and `format_to` are library procedures.

Step 6 retires the scaffolding. `print_int` is gone and every fixture prints
through `core:fmt`; the source-visible `default_allocator()` is gone and the
symbol it named is now reachable only as `mem.default_allocator()`, which is
still the same `Symbol_Id` a generated lifecycle default resolves to. Nothing
emits `llvm.trap` any more. `string`, `string_view`, `Allocator` and
`Allocator_Error` stay predeclared on purpose, as the plan's "Compiler-owned
names" decision requires, and export the same `Type_Id`s through `core:mem` and
`base:runtime`. `type_is_supported` now denies only dynamic arrays, maps, and
`interface` as a runtime type, and the `L0350` fixtures are down to the managed
containers and `via`. `L0551` and `L0561`–`L0575` are live.

Five deviations from the M6a plan's letter are worth stating. The frozen
`Type_Kind`/`Member_Info`/`Type_Info`/`Source_Code_Location` declarations, and
with them `#location`/`#caller_location`, landed in step 4 rather than step 2:
every one of those layouts has a `string_view` field, so declaring them earlier
would have declared a package that cannot compile. Every local is published into
the unwind env rather than only those a cleanup names, which trades one store
per local for not needing a free-variable pass over every deferred statement.
Two of step 1's listed checks — a failed `resize` preserving the old allocation,
and an unsupported provider reset failing at run time — have no source-level
operand until M6b's dynamic arrays and arenas exist, so they are enforced in the
C runtime and left untested from Loke, exactly as the plan already defers the
arena-backed `free_all` fixtures. And `#location`/`#caller_location` require the
file's package to import `base:runtime`, because that package owns the one
`Source_Code_Location` identity and the compiler does not force it into a
program that never asked for it; the diagnostic says so. `type_info_of` requires
the same import for the same reason.

The fifth is a narrowing kept rather than retired: a lifecycle hook still cannot
write the default argument design.md spells for it. The compiler supplies
`mem.default_allocator()` at every call site that omits one, and `L0489` now says
that instead of naming a milestone.

Two smaller decisions belong with step 4. `to_c_view()` never allocates: every
`string` buffer is allocated with room for a terminator and a literal already
carries one, so design.md's "adds a terminator only when necessary" case cannot
arise under this representation, and the call-scoped temporary it describes is
not created. And the parser now accepts the keyword `type` as a member name — a
field, an enum member, or the name after `.` — because design.md spells both
`field.type` and `runtime.Member_Info.type` that way and neither was reachable
before; a name in that position can never begin a type expression.

Two narrowings are worth stating here because they differ from the plan's
letter. Region identity is flow-insensitive — one entry per allocator binding
rather than a lattice — because M5 has no source-level provider that creates a
region, so no two identities can be proven distinct and precision would buy
nothing until M6b supplies `mem.Arena`. And a reset treats every region-backed
owner still in scope as a surviving dependant rather than consulting M5a's
liveness states, which over-blocks a `manual` owner that was explicitly dropped
first; both are marked at their site and are conservative in the safe direction.

M6b step 1 is implemented ([m6b-plan.md](m6b-plan.md)). `[dynamic]T` and
`map[K]V` are compiler-owned struct-shaped types with four synthesised fields —
storage, length, capacity, and the bound provider handle — so layout, parameter
passing, constant zeros, runtime metadata and emission all reuse the aggregate
paths a slice already uses, and `-check-layout` proves both headers against
LLVM's own placement. `runtime/container.c` owns every byte of storage
bookkeeping behind them: checked byte sizes and round-ups, geometric array
growth, and one open-addressed table block holding header, control bytes, keys
and values with an opaque per-table seed. What C cannot know — what a concrete
Loke element costs to clone or drop — arrives as one generated
`loke_rt_container_ops_v1` per concrete type, whose element and key thunks are
memoised per part type. A container's clone and drop are therefore intrinsic,
like a `string`'s, but its implicit copy is a real deep clone that can fail,
which is why `type_clone_is_fallible` answers true for one and a container of a
move-only element is itself move-only.

Two consequences fall out. `emit_clone_value` now takes the destination's
selected allocator, which retires the M5a shortcut that cloned every implicit
copy with the default provider: a `T via provider` declaration records its
policy on the *symbol*, so it survives drop and move and is what a revival
selects, while the handle a live value holds travels in the value. And `make` is
a new built-in whose first operand is a type; its trailing allocator is
recognised by type rather than by position, so `make([dynamic]int, 8, arena)`
needs no written parameter name. Diagnostics `L0576`–`L0579` (static-duration
`via`, inapplicable `via`, non-allocator policy, `make` shape) are live.

Two things are deliberately not here yet. Every container *operation* still
reports `L0350` at the operation rather than at the declaration — a literal with
elements, indexing, `len`, iteration — because each is ungated in the step that
also installs its M5b invalidation. And there is no failure-injection provider:
an allocation that must fail is written as a representable request no heap will
satisfy, which is what the existing M5a clone-failure fixtures already do.

M6b step 2 is implemented: the dynamic-array operation set. The decisive choice
is that the operations are *contributed members* rather than a second call path.
`xs.append(1)` is an ordinary method call, so it reuses overload ranking, `..T`
packing, default arguments, and the `inout`-receiver place rule — and the same
members are what generic code constrained by the standard catalogue finds. Two
consequences follow. `bind_variadic_arguments` had to learn about receivers: a
variadic *method* was previously impossible, and without the receiver its first
written argument ranked against the receiver's own type. And because a `..T`
pack is by the language's own rule a read-only slice, `append` clones each
element into the container through its selected allocator; a move-only element
therefore cannot travel through the variadic form, which is a consequence of the
pack's type rather than a shortcut.

Provenance needed two edges added. `xs[lo:hi]` now lends from the container's own
root exactly as slicing a fixed array does, and `&xs[i]` lends the whole
container rather than one slot, because once the storage can move no projection
survives. An `inout` receiver already recorded an invalidating access, so every
mutating operation ended every view of it as soon as those two edges existed.

Growth never releases the old block until the copy out of it is complete, so a
`src` pointing into the container's own storage stays readable; `dyn_src_aliases`
makes that explicit for `insert`. In practice the M5b one rule already rejects
the source-level case — `ys.append(..ys[:])` is a read of `ys` under an exclusive
borrow of it — so the C-side handling is defence for callers the language does
not yet have, not a path source code can reach. Diagnostics `L0386` (a `cap`
whose operand is not a container) joins the range already in use.

M6b step 3 is implemented: maps. `runtime/container.c` holds one open-addressed
block per table — header, control bytes, keys, values — with linear probing,
explicit tombstones, power-of-two slot counts, a seven-eighths load ceiling, and
an opaque per-table seed derived from the block address and a running counter, so
iteration order is unspecified by construction rather than by promise. Growth and
`shrink` both rebuild, which also clears every tombstone.

The coherence rule needed a new lookup rather than the ordinary interface query:
`map_key_policy` accepts a built-in `Hashable` conformance or a pair of *inherent*
members, and never consults `Package.extensions`. It is asked at `gate_type`, so
one map reports once however many operations it has, and `L0586` is its
diagnostic. `string` and `string_view` became hashable in the same step — the
catalogue always listed them — with a byte-wise FNV-1a that the constant folder
and `loke_rt_v1_hash_bytes` spell identically.

The place/read split needed one new checker fact. `k.place_position` already
existed for `inout` overload selection, but design.md makes `&m[key]` a place
position that deliberately does *not* insert, so `k.insert_position` was added
beside it and only the writing positions set both. Place-ness now also propagates
through a selector's operand, which is what makes design.md's `m["Dana"].x = 7`
insert while `fmt.println(m["nobody"].x)` does not — and the backend has two
addresses for one syntax: the inserting entry, and the existing slot or a zeroed
temporary. `in` became a real binary operator (`L0587`) rather than an
unimplemented token.

M6b step 4 is implemented: container iteration. A dynamic array reuses the
existing index-loop lowering with the header's length word as its bound; a map
walks slots through one runtime `map_scan` that hands back a cursor, so the
controls, seed, and slot count stay entirely inside the C helper and iteration
order is unspecified by construction. design.md's two-name exception is real —
the first of two names is the key — and a key binding *borrows* the stored key in
place rather than copying it, which is what lets `map[string]V` be iterated at
all without a per-iteration clone and drop. `L0591` rejects `&key`.

One defect found on the way is fixed here rather than left: a program that
imported `core:fmt` without formatting anything emitted an empty `any_view`
struct, because that type's two members are installed on first *use* and
`core:fmt`'s own body was emitted before any use existed.

The loop-loan gap recorded here earlier is closed. A direct write inside the
body was rejected while a mutating *method* call was not, and the asymmetry was
real rather than cosmetic: an invalidating access marks every overlapping loan
dead, that bit is a forward fixed point, and a loop's back edge carried it from
the body all the way round to the body's own *entry* — so by the time the check
ran, the iterator loan already looked dead. A write never sets the bit, which is
exactly why `xs[0] = 5` was caught and `xs.append(v)` was not. The fix says what
is actually true: the loop head re-reads its iterable every iteration, so the
`Live` event emitted there is marked `revives` and re-establishes the loans it
names. Nothing else emits that marker, and an invalidation followed by a use
*within* one iteration is still caught by the same in-block replay as before.
`tests/err/m6b_loop_loan` pins all five forms.

The same investigation turned up a second real hole: `prov_place_of` had no
`.Map` arm, so `m[key] = v` recorded only the operand *read* rather than a write
of the container. It was caught anyway — as "this read of `m`" — but for the
wrong reason, and inside a loop body it was not caught at all. Insertion may
rehash, so the projection is the whole map, exactly as a dynamic array's is.

Both containers now contribute `Element`, `Iterator`, `iter` and `next`. A
dynamic array's iterator deliberately holds the `{data, len}` view rather than
the container header: an iterator is a borrow, and a managed field inside one
would be followed by a drop with no business running. That also makes
`Slice_Next` its `next` verbatim. A map's iterator is `{table, cursor}` over the
same runtime slot scan the direct loop uses, and its single `Element` is the
value — the key is reachable only through the two-name loop form, which is
direct iteration rather than the protocol.

Formatting is the slice formatter for a dynamic array and a `[key = value]` slot
walk for a map, both recursive through M6a's table, so a map of dynamic arrays
prints. `string.to_runes` counts before it reserves, so the capacity is the exact
rune count rather than a fourfold over-allocation on ASCII, and releases its
partial buffer before handing control to the allocator's failure policy.
`unsafe.raw_data([dynamic]E)` is one `extractvalue` — the current allocation's
first element, with nothing keeping it current, which is the whole point of the
boundary.

One unrelated defect was found and *not* fixed here, because it is not M6b's:
an untyped composite literal cannot be passed to any overload-resolved call, so
`b.set({1, 2})` fails where the free `f({1, 2})` works. `collect_call_arguments`
checks every written argument once with no destination type — correct for untyped
constants, wrong for a composite literal, which has no untyped form to fall back
on. It is filed separately.

M6b step 5 is implemented: local allocator regions. `mem.Arena` and
`mem.Scratch` are two nominal names over one address-stable control block in
`runtime/arena.c`, and a Loke value is one pointer to it. That is the whole
design: design.md says "copying an allocator value preserves that identity", and
here the identity *is* the control block's address, so a move, a copied handle,
and a handle passed through a call all preserve it without a per-copy tag. A
provider is move-only, because two owners of one control block would release it
twice and a bump region has no meaningful copy.

An `Arena` may be laid over a caller's fixed buffer, in which case the control
block is carved out of the front of that buffer and the region never allocates at
all. The buffer must then outlive the arena — which is not a new rule: a provider
is a *borrow carrier*, so `mem.Arena(buffer[:])` carries the buffer's loan and
the existing root analysis rejects returning it with no region machinery
involved. `Arena` therefore has distinct fixed-buffer and provider-backed
`init` overloads; the latter, and `Scratch`, accept a parent allocator defaulted
to `mem.default_allocator()`. `mem.try_arena` and `mem.try_scratch` expose the
same provider-backed construction without applying the parent's failure policy.
A live provider-backed child records its parent-region dependency, so resetting
the parent is rejected until the child is dropped. Provider result summaries
transfer that dependency while giving the caller's returned owner a fresh local
region token, which permits ordinary wrapper procedures without leaking a bare
handle.

The region lattice gained one bit per local provider — a word, not a slice, with
an overflow bit that degrades to the conservative answer, since a body with more
than 64 arenas is not a thing. Those bits are what make three separate rules
true at once: a body may reset a region it created *without* a promise, because
no caller can own anything in it; a reset blocks only on owners of *that* region,
so two arenas do not interfere; and an owner backed by a local region may not be
returned or stored past it (`L0592`). design.md's `bad_view` and `bad_owner` now
run verbatim in `tests/err/m6b_regions`.

Two corrections fell out of writing it. A `via` binding, not the initialiser, is
what gives an owner its region — a literal `{}` names no region at all, so
region provenance was simply not reaching any container that had one. And
assigning a place *clones* it, so the destination is built with its own
allocator and inherits nothing; the escape check was reading the source's region
and would have rejected a copy that is entirely safe.

The reset check uses M5a's definite liveness rather than scope presence, so
design.md's "an explicitly dropped manual owner is dead and no longer blocks
reset" holds literally. Getting there needed no new lattice: M5a already
classifies every tracked local as definitely live, definitely dead, or
conditionally live at each program point, and the only real problem was that it
runs one pass earlier over a *different* graph, which it then discards. So the
liveness pass emits one `Reset_Point` event — inert for its own transfer — and
records, against the reset's own call node, which owners were definitely dead
there; the provenance pass reads that back. Both passes decide what counts as a
reset through one shared `call_is_reset`, so they cannot disagree about which
calls to record and which to check.

Only `Dead` releases the block. A conditionally live owner may still need its
cleanup on one path, so dropping it inside an `if` keeps the reset rejected —
which `tests/err/m6b_regions` pins alongside the accepted forms.

M6b step 6 is implemented: the compile-time evaluator, and the audit.

A compile-time container is its live contents and nothing else. There is no
allocation to model, no provider to bind, and no address to hand out, so the
runtime's four-word header has no compile-time meaning at all — which is why
`zero_value` and `value_from_const` both answer the *empty container* rather
than a four-element record. The evaluator performs each operation from the same
`Symbol.container_op` the backend emits from, so the two cannot drift apart by
being written twice against one description.

Two things are deliberately *not* observable there, and both are rejected rather
than approximated, because an approximation would let a folded constant differ
from what the same source computes at run time. A map's iteration order, which
design.md leaves unspecified — `L0593`, written as its own case in the `foreach`
arm so it stays closed when compile-time `foreach` does arrive, rather than
being covered incidentally by the general "no compile-time meaning". And a
capacity, which is a property of an allocation — `L0595`. design.md gained one
clause for the second, since capacity growth was already documented as not a
language guarantee.

Escape is `L0594`: design.md gives a container exactly one constant value, the
empty one, so a non-empty one cannot leave evaluation. An empty one freezes to
the all-zero header and is fine.

Every M6b gate is now retired. The last one — a container reaching the general
index path — was removed rather than left: it could only fire for `xs[a, b]`,
where "unsupported construct" is a worse diagnostic than the ordinary arity one.
`tests/err/parsed_not_compiled` was repointed at the honest remaining limit,
compile-time `foreach`.

One plan exit condition is not met, and weakening a safety rule to meet it would
have been the wrong trade. The plan asks that
`free_all(mem.default_allocator())` reach the runtime unsupported-reset trap.
It cannot: M5b settled, with design.md's own words and a fixture
(`hidden_default_reset`), that the default provider is pre-existing storage
whose reset a parameterless wrapper may not hide — and since `main` takes no
parameters, no promise chain can start. Both the direct and the transitive form
are therefore rejected at compile time, which is the stricter and, on M5b's
reading, the correct answer. The runtime half is implemented and unchanged since
M6a: a provider whose `reset` answers 0 aborts. It is simply unreachable from
checked Loke, and is marked as such at its site so nobody assumes it is covered.

The reset-liveness gap recorded under step 5 was closed after the audit; see
that step's record. M6b leaves nothing on its own list — what remains is the
documented v1 trust-boundary set, unchanged.

M7 steps 1–3 are implemented ([m7-plan.md](m7-plan.md)): release output, record
layout, and the Windows x64 C ABI.

`-opt=none|minimal|size|speed|aggressive` maps to one `-O` flag on the single
`clang` invocation that already consumed the `.ll`; [A5](#a-big-decisions)'s
separate `opt`/`llc` split is not taken, because clang runs the same pipeline on
textual IR. The claim M7 makes about optimization is behaviour preservation, and
that is a testing obligation rather than a pipeline one — `LOKE_TEST_FLAGS` runs
the whole `tests/run` and `tests/trap` corpus at every level and requires
identical output. Building the differential corpus immediately found a real
defect it was meant to find: `zero_const` had no `.Typeid` case, so `x: typeid;`
was left uninitialised and diverged at `-O2`.

The `LOKE_*` constants are predeclared, but their enum *types* are allocated
lazily, on first use of a `LOKE_*` constant. Eager allocation would shift every
`Type_Id` after them and so renumber every `%struct.X.<id>` in the module, which
is observable in `tests/ll` and would have made a program that never reads build
config pay for one that does. They are deliberately not bound into `base:runtime`
for the same reason: that would re-shift for any `core:fmt` importer.

`@(packed)` and `@(align=N)` needed a representation choice, because an LLVM
struct type cannot carry a requested ABI alignment. Storage-site `align` can
guarantee a base address but cannot change a containing record's field offsets
or an array's stride. So each attributed shape gets the body that is exact for
it: packed-only is LLVM's own `<{ ... }>`; align-only is `{fields, [0 x iN]}`,
where the trailing zero-length aligned member forces both the alignment and the
tail padding, and containers and arrays then compose naturally with no
transitive byte-exactness needed; combined `@(packed, align=N)` is explicit byte
members plus that trailing member. Field GEP indices stay equal to the logical
field index in every form, which is what lets ordinary access, reflection, and
formatting stay on one path. Alignment is also tracked per *place*: entering a
packed field lowers the effective guarantee to 1 for every nested access, so
`packed.outer.inner` cannot accidentally regain the inner type's natural
alignment. `&packed.field` is rejected (`L0614`); the whole value's address
stays valid.

The two ABI worlds are deliberate. The `loke` convention keeps LLVM's own
first-class-aggregate lowering, unchanged and byte-identical to M6b's output,
because design.md makes its classification implementation-defined and requires
only that caller and callee compiled for one target agree — which one LLVM and
one triple already guarantee. Only a foreign convention gets a compiler-written
classification, because the C ABI is the only one with an external partner. That
classification was verified against `clang --target=x86_64-pc-windows-msvc`
rather than derived from the documents: an aggregate of size 1, 2, 4, or 8 passes
in one integer register of that width, loaded byte-exact from a temporary —
using the aggregate's *size*, so `{i32,i8}` is 8 and still a register; every
other size passes as a pointer to caller-owned storage, with a hidden `sret`
first argument for a result; a single-`f32` struct goes in an integer register,
never `xmm`; and a direct C `_Bool` is `i1 zeroext` while its stored form stays
one byte. One spelling detail cost a debugging cycle and is worth recording: an
LLVM parameter attribute follows its type (`i1 zeroext %x`) while a return
attribute precedes it (`zeroext i1`).

M7 step 4 is implemented: foreign imports, blocks, and linking.

The decisive choice is that a foreign block's members are collected as *ordinary
package symbols*, in the same top-level pass as every other declaration. Name
resolution, visibility, overload ranking, and call checking therefore need no
foreign-specific path at all; what differs is only that a member has no body,
carries a link name and a library, and emits a `declare` rather than a
definition. The block supplies defaults its members may override — the calling
convention (`@(default_calling_convention)`), the visibility, and
`@(require_results)` — so collecting members as ordinary symbols does not lose
the block-wide policy design.md promises.

`@(by_ptr)` and `@(c_vararg)` moved here from step 3, where the plan had put
them. Both are foreign-declaration-only in design.md, and a bodied `proc "c"`
cannot consume varargs, so their real consumer is the foreign-import machinery
and splitting them across two steps would have meant writing the call-site half
against nothing. `@(c_vararg)` keeps `..any_view` notation but is a checker-only
exception rather than permission to pass any Loke value: each concrete argument
must satisfy the foreign-ABI predicate, the call emits a true LLVM varargs call
with the C default promotions (`f32` → `double`; `bool`, enums, and narrow
integers → `i32`), and a spread is rejected because it either erases the
concrete types or has a runtime count LLVM call syntax cannot express.

Three link failures are distinguished rather than folded into clang's exit code:
a missing import file (`L0631`), a missing or failing assembler (`L0632`), and an
unresolved link name (`L0633`). The last is detected by scanning clang's stderr
*after* the link rather than before it — a deviation from the plan's letter,
recorded because a pre-link check would mean reading every import library's
symbol table, which is more machinery than one diagnostic is worth.

M7 step 5 is implemented: exported symbols, object output, and `core:os`.

`@(export)` replaces the mangled `@loke.p.<pkg>.<name>` with the written symbol,
checked across the whole program. Two declarations agreeing on a name is
otherwise a link-time failure with no source location, and the compiler owns the
whole symbol table, so it says which two they were (`L0634`, with a note at the
first). An exported procedure must declare a foreign calling convention
(`L0629`), and neither an export nor a link name may claim the reserved
`loke_rt_` prefix (`L0635`).

`obj` mode is one relocatable compiler module, not a disguised final link. It
accepts any root package, skips executable validation, emits no entry, and runs
`clang -c` on the generated `.ll` alone; the object deliberately *retains* its
runtime and foreign references, and its C consumer supplies the runtime sources
and libraries at the final link. This avoids both a duplicate `main` and the
impossible `clang -c a.ll runtime/*.c -o one.obj` shape, and it makes the runtime
ABI dependency explicit rather than silently satisfied. An assembly import
cannot ride along in a single relocatable object, so an `obj` build that has one
is diagnosed with the instruction its consumer needs (`L0603`); the same import
in an `exe` build reaches the assembler as before. The TLS teardown thunk moved
out of the entry emitter in the process — every generated module supplies it,
entry or no entry.

`core:os` is the proof that the foreign system works, which is why it is a
milestone exit rather than library work. Executable entry became `wmain`, so
`runtime/args.c` converts the incoming UTF-16 argument vector to cached UTF-8
before the initial thread attaches — surrogate pairs combined, unpaired ones
replaced with U+FFFD — and Loke's UTF-8 invariant survives Windows. The library
half is ordinary Loke source over one foreign block: `Args`, `args`, `len`,
indexing, iteration, and `exit`. `os.exit` needs no compiler knowledge at all,
because the process dies inside the call and no cleanup runs by construction.
One shape had to differ from the plan: `Args.Element` is `string_view` rather
than `string`, because by-value `foreach` over a managed element is rejected
(`L0504`); indexing still returns an owning `string`, so the specified surface is
unchanged for every use except the loop binding.

One pre-existing defect surfaced and was fixed here rather than deferred, since
`core:os` is the first package to hit it: `emit_address` treated every selector
as a field GEP, so *any* cross-package global (`pkg.g`) failed with `L0405` "a
resolved place has no storage".

M7 step 6 is implemented: the audit.

The audit's finding is that `L0350` — "this construct parses, but is not compiled
yet in this milestone" — was still reachable from ordinary source in nine
distinct ways, and in every one of them it named the wrong problem and pointed at
a milestone that would never fix it. Each now answers what is actually wrong, and
none of them waits for anything: `---` outside a foreign block, on a declaration
or a procedure value (`L0630`); `a[i, j]` on a built-in container and slicing a
type with no `operator([:])` (`L0362`); a spread with no variadic parameter to
fill, and a named or modal argument to a built-in (`L0370`/`L0371`); a keyed
element in a sequence literal (`L0372`, reported once for the literal rather than
once per element); an unknown *generic* type application, which said "not
compiled yet" where a bare unknown name said "unknown type" (`L0306`); and a
literal whose written type does not resolve, which was gating the enclosing
construct instead of reporting the type. `Simd(T, N)` gets its own answer
(`L0636`) naming it as specified-but-absent in v1, rather than being an unknown
name.

Every remaining `unsupported_construct` call site sits on a dispatch arm whose
union or token set is exhaustively handled above it — verified case by case
against the parser: `Item_Block` and `Item_When` are flattened out of
`active_items` before checking, `Item_Delegate` only ever appears inside an
`impl`, `check_stmt` covers every `Stmt` variant, only `Caret` and `Or_Return`
produce a postfix node, `Amp` is consumed by the address-of path before the unary
switch, and `is_compound_assign` and `compound_operator` cover exactly the same
eleven tokens. The calls are kept as invariant guards rather than deleted, since
reaching one means a parser or resolver invariant broke and a diagnostic naming
the span beats falling through with an unchecked node.

Two cascades were collapsed, both cases of one mistake producing two
diagnostics. A generic member of a foreign block reported `L0624` *and* `L0438`
for the convention it had inherited from the block rather than written; the
inherited convention is not a second error. And a member the parser could not
read reported `L0206` and then `L0622`; the recovery node is now skipped, which
leaves `L0622` an invariant guard like the ones above.

One documented limitation was fixed rather than re-documented. Step 2 had
recorded that `==` over a combined `@(packed, align=N)` record was unsupported,
because byte members make whole-value `extractvalue` ill-typed. It was worse than
recorded: it reached the backend and produced *invalid IR* that clang rejected,
which is never an acceptable answer. Equality now reads each field through its
address — the same GEP ordinary field access already uses — so the comparison is
the ordinary one and only the way the operands are reached differs. Such a record
now works as a map key and a container element as well.

The audit also found that step 1's attribute discipline had no error fixture at
all, despite being six diagnostics; `tests/err/m7_attributes` now proves one
diagnostic per way of writing an attribute wrongly, plus the two that carry
behaviour at the use site. All thirteen attributes design.md defines were checked
to have behaviour outside the validation table, not merely a table row.

The audit also found one defect it is deliberately *not* fixing, because doing so
is a backend refactor rather than an M7 obligation. Several `alloca`s are emitted
at their point of use rather than in the entry block — the composite-literal
temporary, the slice-literal backing root, the union spill, and now the
byte-member equality scratch. LLVM releases an `alloca` only when the function
returns, so any of them reached inside a loop grows the stack per iteration: a
two-million-iteration `==` against a struct literal exhausts the stack at
`-opt=none`, and `-opt=speed` and above hide it because SROA promotes the slot.
`emit_slice_literal` already carried a note saying to hoist "if a real program
shows stack growth", which one now does. The fix needs an entry-block seam every
function emitter shares, and `src/emit_llvm.odin` has twenty-one sites that write
`define`+`entry:` while only `emit_proc` has such a seam; a first attempt that
flushed hoisted allocas from `emit_unwind_prologue` was reverted, because the
other twenty would have leaked theirs into whichever function's prologue ran
next. It is recorded here and marked at each site rather than half-fixed.

Otherwise M7 leaves nothing on its own list. What remains is the documented v1
trust-boundary set, unchanged — retention of a pointer, `cstring_view`, or
`inout` argument by foreign code is not checked, which is a v1 decision rather
than a gap M7 closes — and `Simd(T, N)`, which now names itself.

---

## D. Out of scope for v1

- **MIR and the no-LLVM debug backend** ([B13](#b13-lowering-to-mir)/[A4](#a-big-decisions))
  — still long-term goals, but v1 has one lowering consumer and ships on the
  annotated-typed-AST-to-LLVM path. Introduce the small backend-agnostic MIR with
  the second backend rather than maintaining an unused durable representation.
- **`Simd(T, N)`** — specified in design.md and reserved in the public
  `Type_Kind`, but nothing in the language, runtime, or standard packages depends
  on it, so it is the one piece of ABI surface that can be left out without
  leaving another feature half-built. M8.
- **The library types design.md assumes** — `String_Builder`, `C_String`,
  `Small_Array(T, N)`, `Bit_Set`/`Enum_Array`, `Complex`/`Quaternion`,
  `Little_Endian`/`Big_Endian`, slice sorting, `Logger`/`core:log`, and
  `shared(T)`/`weak(T)`/`Atomic(T)`/`core:sync`. All but the last group are
  ordinary Loke source over facilities M6 already provides; that group needs
  compiler atomic intrinsics, which want their own memory-model fixtures. M8.
  `core:os` is the exception and stays in M7: the program model names `os.args`
  and `os.exit` normatively, and writing them over a foreign block is the proof
  that the foreign system works.

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

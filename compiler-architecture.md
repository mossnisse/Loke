# Compiler architecture

`lokec` is a whole-program Windows x64 compiler written in Odin. It checks one
annotated AST, analyzes ownership and provenance through disposable control-flow
graphs, emits textual LLVM IR, and invokes clang with a versioned C runtime.

This guide explains where to make changes and which phase contracts to preserve.
[design.md](design.md) defines the language, [grammar.md](grammar.md) defines
its syntax, and [compiler-guide.md](compiler-guide.md) covers the command line.

- [Pipeline](#pipeline-at-a-glance) and [phase order](#driver-and-phase-order)
- [Representations and ownership](#core-representations-and-ownership)
- [Semantic architecture](#semantic-architecture) and [runtime
  boundary](#runtime-and-library-boundary)
- [Source-code map](#source-code-map)
- [Making changes](#how-to-make-a-compiler-change) and
  [testing](#testing-and-verification)
- [Sessions](#reusable-batch-sessions), [queries](#snapshots-and-queries),
  [invalidation](#invalidation-rules), and [incremental
  checking](#incremental-checking)
- [Language server](#language-server)
- [Deliberate boundaries](#deliberate-boundaries)

## Pipeline at a glance

```text
configuration -> source loading -> lexing -> parsing
    -> package/import/when discovery and declaration preparation
    -> body checking, CTFE, monomorphization, and lifecycle analysis
    -> whole-program borrow/region analysis and provider resolution
    -> entry/export validation and semantic finalization
    -> emission contract -> textual LLVM IR
    -> .ll, .obj, or executable linked with runtime and foreign inputs
```

The checker records symbols, overloads, conversions, lifecycle operations,
witnesses, and runtime dependencies. Compile-time evaluation and LLVM lowering
consume those decisions; neither repeats source lookup nor repairs missing
semantic state. There is no durable MIR or second backend.

## Driver and phase order

`main.odin` parses options and initializes a `Compilation_Session` in
`session.odin`. Configuration is fixed before discovery. `check_session` loads
project collections through `register_project`, then follows this order:

1. `compile_program` loads `base:runtime`, the root package, and providers
   selected by the root's package attributes.
2. Discover imports and reject cycles. Static graphs prepare and check each
   dependency before its dependents. Graphs with file-scope `when` or providers
   repeat discovery, declaration preparation, and selection until stable, then
   check bodies. Only `File.active_items` have semantic effect; inactive
   branches are still parsed.
3. Check concrete bodies and their ownership. Generic instances and pending
   generic `impl` bodies are checked when concrete uses commit them.
4. `finish_program_analysis` runs whole-program provenance analysis, including
   global writes, result summaries, callback contracts, borrows, escapes, and
   allocator regions. It resolves provider factories, releases held diagnostics,
   and records `program_analyzed`.
5. Validate entry and exports. `finalize_semantics` freezes `typeid` values,
   discovers `fmt.Formattable` witnesses, snapshots lifecycle operations, and
   installs `any_view` fields. These steps are idempotent.
6. `emit_session` calls `emit_package`, then `emit_llvm_module`. Before
   allocating an emitter, `validate_emission_dependencies` verifies the checked
   state. One module contains every package in deterministic dependency order.
7. Write `.ll`, compile a relocatable `.obj`, or link an executable with the C
   runtime and foreign inputs. Object builds leave those references to the host.

`-parse-only`, `-dump-ast`, and `-dump-tokens` take the single-file parsing
path. `-check-layout` compares finalized compiler layout facts with LLVM.
Documentation checking omits executable-entry validation and finalization.

## Core representations and ownership

### Source and syntax

`Span` is a byte range in a `Source`. Every AST node, including recovery nodes,
has one. Comments are recorded separately on the source in lexical order. The
parser retains explicit error nodes and resumes at synchronization points. A
simple statement it cannot finish keeps what it parsed as `Stmt_Error.partial`.
The checker checks that statement so queries see its names and types, then drops
the diagnostics located inside it, and a missing name after `.` checks only the
operand; flow analysis and emission skip the statement. A file with a syntax
error cannot build, so that check commits like any other, and a report-once
diagnostic first met there can stay unreported until the syntax error is fixed.
Types and expressions share `Expr`, since syntax alone cannot distinguish all
generic applications and calls.

### Stable semantic state

`Compiler` owns compilation-wide state. AST annotations use `Identifier_Id`,
`Symbol_Id`, `Type_Id`, and `Package_Id`. Symbol and type entries are
individually allocated, so pointers from `symbol_of` and `type_of` survive store
growth. Packages live in a dynamic array: retain a `Package_Id`, not a pointer,
across operations that may load packages. These identities last only for the
current checked result; external consumers use [snapshot
handles](#snapshots-and-queries).

### One annotated AST

Checking annotates parsed syntax with types, constants, places, resolved
symbols, arguments, conversions, and lowering operations. `Expr_Call.operation`
is a tagged `Call_Operation`; nil means unchecked. Symbol identity remains in
`Expr_Base.resolution`, while argument binding and evaluation order stay on the
call. LLVM dispatches on the recorded operation.

Struct literals record field indices in source order; entry validation records
the entry symbol; extraction uses the checked union's failure metadata.
Consumers must use these facts rather than reconstructing them.

Generic specialization and static `foreach` clone syntax through
`ast_clone.odin`, clear semantic annotations, then check each clone in its
definition-site scope. An annotated template cannot serve as a fresh
specialization.

### Disposable control-flow graphs

`cfg.odin` builds `Flow_Graph` blocks referencing typed AST nodes.
`cfg_provenance.odin` supplies carrier projections, allocator regions, and call
effects. Graphs serve analysis; LLVM still walks the AST directly.

| Mode | Purpose |
| --- | --- |
| `Lifecycle` | Initialization, moves, drops, cleanup, and lifecycle diagnostics. |
| `Prov_Summary` | Provenance events while cross-procedure summaries settle. |
| `Prov_Diagnose` | Provenance events for checking each body's borrows and regions. |

Each body/mode/summary round gets a fresh graph. Provenance construction
preserves settled lifecycle annotations and makes no lasting compiler mutations;
the only diagnostics it emits are a spawn's transfer checks
(`prov_spawn_transfers`). Allocator-region and target facts are accumulated to a
fixed point, so later writes can reach earlier reads. A construction walk
records ordered fact operations; subsequent rounds replay those operations in
disposable fact state. Only carried facts are copied between rounds. The
construction graph's control flow, loans, roots, and carrier slots do not depend
on the carried facts; the events, diagnostics, and summary outputs that do are
recorded as event operations
([provenance_event.odin](src/provenance_event.odin)) and materialized again,
interleaved with one more replay, once the facts settle. Superseded diagnostics
are discarded, so each diagnostic appears once.

Provenance construction keeps what a body does apart from the facts that grow
while it is analyzed; [normalized provenance
input](#normalized-provenance-input) describes that boundary.

### Normalized provenance input

The construction walk (`walk_flow_expr` and the provenance helpers it calls) is
the only provenance code that reads source syntax for its meaning. It consumes
the checked AST and the settled lifecycle annotations, interns the body's
input, records ordered operations, and builds the graph's control flow, loans,
roots, and carrier slots:

```text
checked AST + settled lifecycle annotations
    -> construction walk: input tables, fact operations, event operations
    -> frozen input; fact replay rounds until the fact weight stops growing
    -> one settled round that also materializes the event operations
    -> borrow and region solvers, summaries, diagnostics
```

| File | Input it owns |
| --- | --- |
| [provenance_input.odin](src/provenance_input.odin) | `Prov_Input`: body-local `Storage_Id` and `Value_Id` tables, zero meaning unresolved storage or no value; canonical typed places (`Prov_Place`). |
| [provenance_form.odin](src/provenance_form.odin) | Each value's checked form (`Prov_Form`), with its operands, a call's argument and pack values, and the call a user operator stands for, all as values. |
| [provenance_transfer.odin](src/provenance_transfer.odin), [provenance_transfer_facts.odin](src/provenance_transfer_facts.odin) | Typed transfers (constructors, owner views, payload extraction, widening, copies and moves) and how they apply to targets and regions. |
| [provenance_call.odin](src/provenance_call.odin) | Checked call inputs: contract, signature, parameter modes, result type, argument slots in source evaluation order, a lending call's captured receiver, and the evaluated callee of a call through a procedure value, as `call_through_value` in `check_calls.odin` classifies it. |
| [provenance_read.odin](src/provenance_read.odin) | A leaf alias read, derived from a value and its form. |
| [provenance_effect.odin](src/provenance_effect.odin) | Fact operations, their replay, and freezing. |
| [provenance_event.odin](src/provenance_event.odin) | Event operations and their materialization. |

A value is keyed by its node, its representation (`Prov_Repr`: type, view,
erasure, widening, and composite backing), and its `Defer_Expansion`. The value
beneath an implicit conversion is a distinct value (`prov_value_beneath`);
construction never rewrites a node's annotations. Storage is keyed by
`Written_Storage`: named storage by its symbol, anonymous storage by its source
identity, type, and expansion. A local is therefore one storage across every
exit, while temporaries evaluated in different defer expansions are distinct. A
place starts at storage, or at a carrier value for an indirect place, and ends
in a typed projection path. Interning a value also records its form. Its
operands are interned at their checked representation in the value's own
expansion, so construction, replay, and materialization read the same values.
The value also records whether its storage ends with its statement, and whether
a read through it may find targets no write named.

Keep these phase rules:

- **Operations hold no facts.** Input and operations store no alias sets,
  region sets, loans, or call summaries. Replay reads current callee and copy
  hook summaries each round, so a summary can grow without changing input or
  identities. Body-local IDs never reach a summary; summaries name parameter and
  result paths and symbols.
- **Replay reads only recorded input.** Freezing describes every value's
  transfer, then fixes the tables. `prov_writable_input` asserts that no fact
  replay or materialization adds a value, storage, call input, copy operation,
  or transfer; only a finished graph's later query takes a private copy first.
  Fact operations (declarations, stores, borrowed bindings, provider transfers,
  call results and writes, and target invalidation) each record their values,
  paths, block, and defer expansion, and a high-level operation owns the nested
  writes it performs.
- **Only `Prov_Facts` crosses rounds.** The carried facts are a body's
  region facts, path-indexed region content, provider parents, lent locals,
  and carrier targets (`Prov_Facts`, embedded in each graph's state).
  `prov_carry_facts` deep-copies them into the carry arena, `prov_seed_regions`
  starts the next round from them, and `prov_fact_weight` counts them for
  convergence. A fact graph takes the body's `Prov_Topology` (roots, provider
  tokens, operator calls, and block count) from the program. Everything else it
  holds is built afresh by the round, so a fact added anywhere else would not
  survive to the next round, and one added to `Prov_Facts` must also be copied,
  seeded, and weighed.
- **Fact-dependent output is an event operation.** A construction site whose
  output depends on the facts, such as a reset, an escape, a region or key
  escape, allocator use, a received region, or a write published through a
  borrowed payload binding, records its fact-independent inputs. It is
  materialized immediately with the construction facts, then again in the
  settled round, interleaved in recorded order with the fact operations at each
  operation's block and expansion. A graph whose facts never grow is returned as
  built. The [rationale](comments.md#provenance-replay-and-precise-publication)
  explains why events are materialized after the facts settle.
- **Below the walk, queries read values.** A region or target query chooses
  its rule from a value's form and follows operands as values. What it may
  still read from the AST is a lookup key, a diagnostic span or name, or
  checked metadata: constness, value category, resolution, how many arguments a
  call binds, and a variadic pack's order. A few lookups are keyed by a node the
  walk evaluated at the same site: an event's call input and argument values,
  a declaration's `via` allocator, and a temporary root's owner. These work
  because replay and materialization restore each site's block and expansion. A
  new spelling of an existing transfer should change interning and its tests,
  not the queries.
- **Materialization allocates in the analysis arena.** The language server
  checks the same bodies on every edit, and nothing reclaims process-heap
  allocations made during a check.

The representation keeps a place apart from its contents, and a borrow, a
carrier copy, an owner clone, and a move apart from each other. It keeps an
allocator handle's dependency apart from an owner's, a known alternative apart
from an unresolved one, and a storage's cleanup apart from its last use. A
lending call (`split_at_mut`, `chunks_mut`) captures its receiver as a value of
its own before later arguments run, and reborrows the source binding only
after them. A copy names its checked lifecycle operation, and custom copy
hooks, including hooks nested in generated copies, substitute their current
result summaries.

[provenance_normalization_test.odin](src/provenance_normalization_test.odin)
inspects the input by semantic property: shared storage identity, transfer
modes, evaluation order, recorded forms, and replay after a summary grows. It
deliberately avoids IDs, map order, and graph dumps. The `provenance_*` runtime
and rejection cases in `tests/` are the behavioral controls. For a change to
this boundary, also compare diagnostics over the test, example, tutorial,
bench, and package inputs with the parent commit's compiler, each run from its
own checkout. The [profiling probe](bench/provenance_profile/main.odin) reports
body builds, fact replays, normalization, replay, and materialization time, and
the largest sampled build arena:

```powershell
odin run bench/provenance_profile -- bench/provenance.loke bench/workspace examples/corpus_runner.loke
```

The baseline records in the repository's `bench/baselines/README.md`, under
"Provenance normalization", hold its results and the matching `perf.ps1`
records.

### Allocation domains

| Storage | Lifetime and contents |
| --- | --- |
| Batch inputs | Process-owned source buffers and diagnostics; one syntax arena per parsed file. |
| Semantic arena | Stores, interned data, specializations, cloned syntax, and frozen constants. Incremental inputs, syntax, and diagnostics also live here for checkpointing. |
| Analysis arena | Disposable ownership/provenance graphs, reclaimed after analysis. |
| CTFE scratch | Bounded frames and mutable values; escaping constants are frozen into semantic storage. |
| Emission arena | LLVM text, temporary maps, layout probes, and toolchain scratch; released with the compilation. |
| Session arenas | Copied configuration, scratch, queries, and statistics; see [sessions](#reusable-batch-sessions). |

Diagnostic strings use their list's original allocator, including diagnostics
raised during emission. Constants built outside CTFE obey the same
`MAX_CONST_ELEMENTS` budget; the backend can emit zero without constructing an
aggregate constant. Emission temporaries never become semantic annotations.

## Semantic architecture

### Package preparation and source selection

Packages are directory identities in a dependency DAG with deterministic
post-order traversal. Conditional imports require discovery, preparation, and
CTFE to cooperate until selection stabilizes.

`bootstrap.odin` binds ordinary `base:runtime` declarations into the predeclared
universe instead of synthesizing duplicate types. These include `Unit`,
`Option`, `Result`, `Shared`, `Weak`, and the constructor groups `shared` and
`try_shared`.

### Checking and overload resolution

`check.odin` handles declarations, signatures, statements, and type syntax.
`check_expr.odin` handles contextual typing, conversions, places, and folding;
`check_calls.odin` handles call forms and argument binding. Expected types guide
untyped constants, implicit enum members, `nil`, and typeless literals.

`overload.odin` centralizes viability, conversion ranking, tie-breakers, and
ambiguity for named groups, methods, operators, `init`, and indexing. Feature
modules supply candidates and their special constraints.

**Any check whose diagnostics may be rolled back must run as a probe.**
`begin_probe` raises `speculation_depth` and marks diagnostics; `end_probe`
discards them before lowering the depth. Probes may annotate cloned syntax but
must not enroll final-program artifacts. All such decisions ask `committing(c)`
in `source.odin`; `test-all.ps1` forbids reading the depth elsewhere.

Gate registry enrollment, report-once caches, and last-use annotations on that
same decision. Otherwise a rolled-back diagnostic can leave a cache suppressing
the real report. `end_probe` checks registry growth, except for sanctioned
commits. Synthesized members may remain on a type after probing; a committed
call, value, loop, or witness must enroll them through `enroll_synth`, including
adapter targets.

The sanctioned nested commit is `ensure_proc_typed_for_eval`: it checks a CTFE
body at depth zero between `begin_commit` and `end_commit`. Its diagnostics are
held outside rollback and `error_count`, then released by
`finish_program_analysis`.

Silent generic instantiation (`report = false`) is also a probe. It caches the
signature or rejection without enrollment; `promote_generic_instance` commits
the body. Bounds checked speculatively are checked again on commitment so their
diagnostics and dependencies are retained.

### Compile-time execution and generics

`const_ops.odin` supplies shared constant semantics. `eval.odin` interprets
already typed AST with bounded frames, mutation, calls, loops, containers, and
`defer`. Aggregate assignment deep-copies, except that slices share elements
and pointers share targets.

`generic.odin` owns inference, specialization, `where` checks, caching, and body
commitment. Procedures and records are monomorphized with definition-site
lookup; caller-local extensions cannot change a specialization. Human-readable
arguments and bounded diagnostic names are separate from `const_key_text`
cache encodings.

### Ownership, lifecycle, and provenance

`hooks.odin` classifies managed types and lifecycle operations. Checking selects
clone/move behavior and records copy costs. Before liveness analysis,
`settle_last_uses` rewrites eligible last-use clones as ordinary moves, outside
probes. Allocating-copy diagnostics wait for that decision. `lifecycle.odin`
then settles initialization, liveness, and cleanup slots. All locals have
initialization state; only managed locals need scope-exit cleanup.

Normal exits and panic unwind consume the same cleanup facts. Where `defer`
is registered, CFG construction models a possible panic at each statement and
walks the applicable cleanups. Unwind blocks record liveness for provenance but
do not report lifecycle errors or add normal-path cleanup points.

`borrow.odin` tracks two related facts:

- **Root provenance:** which storage a view, pointer-like result, or aggregate
  carrier borrows; checks exclusivity, invalidation, retention, and escape.
- **Region provenance:** which allocator backs an owner or borrow; checks
  escape and reset. A clone may still retain its source's regions through
  shared strings, even when container storage uses the destination allocator.

Both run over the [disposable graphs](#disposable-control-flow-graphs) built
from the [normalized input](#normalized-provenance-input). The mechanism of
each concept is described at its owner; the table says where to look. The
`provenance_*` cases in `tests/` and `borrow_matrix_test.odin` are the
behavioral controls for all of it.

| Concept | Owner |
| --- | --- |
| Access through carriers: the hops to a place, the caller slots a parameter's loan stands for, and the reborrow a loaded copy takes | `prov_read_through_carrier`, `prov_place_hops`, `prov_caller_slots`, `prov_reborrow_loaded` in `cfg_provenance.odin` |
| Place loans, taken by a borrow, slice, traversal, or switch of a place reached through carriers | `Prov_Place_Loan`, `prov_place_loan`, `place_bit`, `check_place_loans` in `borrow.odin` |
| Access events, the places a slot's definitions may point at, and their merging | `prov_access_through`, `Prov_Slot.offsets`, `prov_note_offset`, `prov_union_offsets` |
| Publication: a store through carriers | `publish_into_loan`, `publish_into_caller`, `read_caller_slots`, `resolve_content_reads` in `borrow.odin` |
| Written-argument regions, by parameter and by path | `param_writes_caller`, `Compiler.written_regions`, `written_owner_regions`, `written_region_content`, `Prov_Region_Content` |
| Region shapes and queries of a value's fields | `region_field_shape`, `Region_Query`, `prov_result_region_at`, `prov_result_region_fields` |
| Copies and clones | `Prov_Region_Copy`, `prov_copied_region_at`, `prov_clone_region_at`, `prov_define_value_regions` |
| Implicit failure returns | `prov_error_region_fields`, `Expr_Propagated_Error` |
| Temporaries, resets, and the cleanup walk | `Flow_Graph.temp_roots`, `Prov_State.held_owners`, `emit_cleanups`, `emit_return_cleanups` in `cfg.odin` |
| Written aliases: what a local's carriers may reach | `Written_Alias`, `written_aliases`, `prov_written_targets`, `prov_call_written_aliases`, `WRITTEN_ALIAS_DEPTH` |
| What a call leaves in its arguments | `prov_leave_region`, `prov_region_escape_into`, `content_loans`, `prov_mutable_reach`, `prov_load_writable` |
| `thread_local` borrows crossing calls, and callbacks | `Compiler.thread_local_writes`, `Callback_Write`, `Callback_Read`, `CALLBACK_RESULT`, `prov_callback_result`, `prov_callback_returned` |
| Global-write effects and the callbacks a call passes | `compute_global_writes`, `Called_Parameter`, `Callback_Summary`, `call_parts`, `indirect_call_targets`, `callable_type_targets` in `global_effects.odin` |
| Thread summaries for `parallel` blocks | `compute_thread_summaries`, `Compiler.reach_effects`, `allocator_uses`, `thread_facts_pending`, `thread_summaries_wanted` |
| Bounded merges and the diagnostics that say *may* | `precision.odin`, `Carrier_Path.cut`, `L0646`, `L0647`, `L0730` |

Keep these contracts:

- **One walk reads every carrier access.** A load, borrow, store, or switch
  subject of a place reached through carriers goes through
  `prov_read_through_carrier`, outermost carrier first, and emits a `.Through`
  event with the carriers, the path below their pointee, and whether it reads
  or writes. Locals and parameters behave alike: a parameter's caller storage
  has no content of its own, so its loan gets caller slots standing for what
  that storage holds. A new place form changes the walk and its tests, not
  the solvers.
- **A place reached through carriers takes a place loan, not a root loan.**
  Which storage the carriers name is known only to the solve, so a borrow,
  slice, traversal, or switch of such a place snapshots the carriers and is
  checked against later accesses by path overlap (`check_place_loans`); a
  borrow's conflict is `L0641`, a switch's `L0511`.
- **Paths are below the pointee, and bounded.** Slot offsets, place-loan
  paths, written-alias paths, and region content paths all start below where
  the carriers point, so a write lands only where it names. Offsets merge past
  eight places and alias paths stop at `WRITTEN_ALIAS_DEPTH`; a truncated
  path carries the precision marker, so `L0646`, `L0647`, and `L0730` say the
  borrow *may* be there, and recursive cursors converge.
- **A store through carriers is a `Publish` event.** It joins what is stored
  into the slots of each storage the carriers' loans name. Where they name one
  place with one live loan of exact path, the slot of the stored type at that
  place is replaced, as a store to the place itself replaces it (design.md
  "Values that contain borrows"). A parameter's loan publishes into its caller
  slots, so the parameter itself holds nothing stored.
- **Owners, handles, and fields stay apart.** Region facts are kept by path,
  and backing dependencies apart from payload dependencies: a record's fields,
  a container's elements and backing, a shared handle's control block and
  payload, and a union's variants each have an entry of their own.
  Written-argument summaries keep the owners' part apart from allocator
  handles (`written_owner_regions`) and keep each part at the path the body
  wrote (`written_region_content`); a copy within one argument is a copy
  entry the call resolves in its caller.
- **Copies keep their source's regions unless they allocate.** Newly
  allocated storage is in the destination; strings, shared handles, and
  borrowed parts keep their source regions, recursively, and custom copy hooks
  substitute their result summaries.
- **Unknown stays unknown.** A set of carrier targets keeps an explicit
  unresolved alternative beside its known targets, and a source with no target
  facts contributes one per possible source, so one known source cannot hide
  another's missing facts. Region reads, writes, and escape checks follow the
  known aliases and keep the conservative fallback.
- **Writes through parameters are summarized per written parameter.** A
  parameter is written when it is `inout`, a mutable carrier, or a read-only
  carrier reaching a mutable one (`param_writes_caller`), and a local set from
  it counts as the parameter (`written_aliases`). The borrow a call leaves
  lands only where the argument's mutable carrier paths lead
  (`prov_mutable_reach`); that walk visits each type once, so a recursive type
  stands for every carrier below it and a long chain hides nothing.
- **Callbacks substitute per call.** What a callback leaves in its arguments
  or returns is summarized against a stand-in root and substituted with what
  each call passes. A call through a value may be any body of its type the
  global-write effects found, whatever contract the type carries, since a
  contract bounds only the result. Effects settle per call, not per procedure
  type ([Global write effects](design.md#global-write-effects)), and each
  summary part keeps the call or hook it came through, so a rejection names
  its origin.
- **Thread facts are opt-in.** Once the result summaries settle,
  `compute_thread_summaries` builds each body's graph once more for the
  summaries a `parallel` block's checks read ([Globals while tasks
  run](design.md#globals-while-tasks-run), [Allocators and
  tasks](design.md#allocators-and-tasks)). Those facts are recorded only while
  `thread_facts_pending` is set, and the pass runs only when checking a block
  set `thread_summaries_wanted`: it adds 10 to 20 percent to the front end,
  which only a program with a block should pay.
- **Temporaries end with their statement.** The statement-end walk runs
  resets against only the owners whose cleanup is still pending, popping
  registrations as they run and restoring them for other exits. Owned
  operands are held while later operands run, and a moved argument leaves
  that set on entry to the callee.

### Lowering parallel blocks

A [`parallel` block](design.md#structured-concurrency) needs no runtime entry
point of its own: its tasks run through `core:thread`, whose private
`Task_Scope` the compiler names through a registered lifecycle operation, not
by lookup from user code. A program with a selected block depends on
`core:thread` without importing it, so discovery binds that package for any
file whose selected items hold a `parallel` keyword (`File.parallels`), and a
block reports `L0329` where no collection provides it.

```text
Task_Scope :: move_only struct          // private to core:thread
Task_Scope.pooled(pool: ^Pool) -> Task_Scope
                                        // the scope of `parallel (pool)`, borrowing it
Task_Scope.start(self: inout, run: proc(frame: rawptr), frame: rawptr)
                                        // reserves a slot, then creates the thread,
                                        // or queues the task on the pool
hook(drop) on Task_Scope                // joins every started thread,
                                        // then waits for the pooled tasks
```

- **The block.** `parallel.odin` checks a block as the block a programmer
  would write with a hidden `Task_Scope` local declared first, zero until its
  first spawn, and records that block as `Stmt_Parallel.lowered`. The local's
  drop is the join, so the ordinary cleanup order runs the block's own
  cleanup first. An executor header adds `parallel$pool: ^Pool = executor;`
  before it, so a wrong executor is reported as that initializer, and the
  scope is `Task_Scope.pooled(parallel$pool)`, whose result borrows the pool
  until the join. `Spawn_Task.pooled` marks the spawns of such a block.
- **Each spawn site.** Checking a spawn synthesizes a frame record and a run
  procedure, as `capture.odin` does for capture literals, and records them in
  `Compiler.spawn_tasks`. The frame holds a leading slot for `run`, each bound
  argument (copied, owned, or as an address), the result local's address, and,
  for a call through a procedure value (`Spawn_Task.through_value`), that value,
  which the parent evaluates before the arguments. The run procedure takes the
  owned arguments out of the frame, makes the call, by name or through the
  frame's value, writes the result through the address with `unsafe.write`,
  since the local is dead, and frees the frame. A call through a `dyn` view
  needs no field of its own: its view is the receiver, bound argument 0, so
  `run` selects the slot on that argument, and a callable view's `call` is the
  view type's forwarding member, called by name. The view gets every argument
  check, including the transfer checks. A variadic pack's field is a record of
  its operands in written order (`Spawn_Task.pack`): the parent fills it as
  `emit_variadic_pack` would copy each element, and `run` packs them again,
  moving owned elements in and passing each spread on as `..s`. A lone spread is
  a copied slice the worker forwards. An element copied from a place the parent
  keeps is shared with the task, as a copy of what that place reaches.
- **Registration.** `emit_llvm_stmt.odin` fills the frame on the parent from
  the default allocator, which accepts concurrent use. The parent registers
  the frame for the unwind until `start` returns, beside the guards that drop
  the owned arguments. `start` grows the scope's thread list before creating
  the thread, so the append afterwards cannot fail, and a creation failure
  panics with the frame still the parent's, which the unwind frees. Either the
  task is owned and joined, or it never runs.
- **Result initialization.** A registered task completes unless the program
  ends, so the parent sets the result local's ordinary dynamic initialization
  flag right after `start` returns, and the enclosing scope drops the result
  through that flag on every exit. No runtime completion tracking is needed.
- **Threads.** Each task runs through the existing `thread_main`, which
  attaches to the runtime's panic state and runs the thread's `thread_local`
  drops before exit, so waiting for the thread orders its TLS destruction
  before the join returns.
- **Pools.** `core:thread`'s `Pool` keeps a queue of nodes, each a frame and
  its block's scope, under one SRWLOCK and condition variable. A scope counts
  its unfinished tasks and records the scope whose task its thread was running
  (the thread-local `running_in`), so a joining worker can tell its block's
  descendants. A worker runs a task through `loke_rt_v1_run_task`, a C
  trampoline in `runtime/panic.c`: an indirect call in Loke would make the
  effect analysis follow every procedure of the run procedure's type into the
  join hook, which every block shares.

The checks run on the `Prov_Diagnose` graph:

- **Task loans.** A block's tasks hold what they lend in one slot per block,
  `task_slots`, which the hidden local's drop uses, so every task loan is live
  until the join. Each spawn adds to it, so a spawn in a loop keeps the
  earlier iterations' loans, and the join empties it for a block entered
  again. A temporary the spawned call borrows is in the frame, so its loan
  (`spawn_owned`) is left out of what the task holds; a result that borrows it
  still carries the loan. A spawn site that reborrows a mutable carrier also
  holds a slot of its own, `task_holds`, so the carrier stays suspended until
  the join while a loop's fresh chunk binding is not.
- **The task window.** A spawn emits a `Task_Start` event naming its site in
  `task_sites`, with what its arguments hold and the regions its task
  reserves, and the hidden local's drop emits `Task_Join` for its block. The
  window solver in `borrow.odin` is a may-analysis over blocks with one bit
  per spawn site, so a branch that has not spawned is outside the window and a
  spawn in a loop holds it open around the back edge; past 64 sites, the last
  bit is shared and never cleared. Writes and reaches inside a block are
  `Shared_Effect` events in `global_effects.odin`, the parent's allocator use
  `Region_Use` events, and the solver reports both against the tasks that may
  be running. The emission contract validates each recorded spawn.
- **`thread_local` effects depend on the executor.** A spawned call's effects
  are recorded with `task_effects` set, and none of its `thread_local` writes
  become accesses at the spawn (`prov_effect_call`). A bare block's call is
  recorded `elsewhere`, so `compute_global_writes` leaves its `thread_local`
  writes out of the enclosing procedure's. A pooled block's spawns are kept in
  `pool_tasks` by scope, and its join applies their run procedures'
  `thread_local` writes as invalidations (`prov_pool_join_effects`).
  `prov_enter_parallel` registers the block's spawns (`Stmt_Parallel.spawns`)
  as the walk enters it, since a loop may reach an exit written above the
  first spawn; every exit then carries the join's writes, and
  `settle_pool_joins` drops them where the window shows no task of the block
  may have started.
- **The join check** ([Releasing before the
  join](design.md#releasing-before-the-join)) runs at each `Task_Join` in the
  same replay (`check_join_retention`). The values the parent keeps are the
  slots of a symbol live after the join and every borrowed parameter's slots;
  a slot counts when its carrier path reaches an `@(wakes_on_drop)` type
  (`path_waker`, from the `waker` of `transfer_facts` in `hooks.odin`), so a
  wrapper's other fields do not count. Its loans are compared with the
  block's `task_slots` and `task_holds` by root (`loans_may_share_storage`,
  `roots_may_share_storage`); a raw pointer or erased view reaches anything.
  A drop counts as a use of what the value borrows (`prov_drop_reads`), so a
  local dropped in the block's cleanup is not live at the join, and one
  dropped later, on any exit path, is.

### Closed semantic registries

Before emission, the checked program must contain exact map/order policies,
committed generic bodies, materialized constants, erased witnesses, frozen
type IDs, formatter witnesses, and immutable lifecycle operations.
`emission_contract.odin` validates those records and phase-completion flags,
including released diagnostics and completed carrier fields. It never checks
or fills missing state. Local emitter assertions provide a second check;
failure returns no partial module.

## Runtime and library boundary

| Location | Responsibility |
| --- | --- |
| `base/` | Foundational Loke declarations: runtime types, reflection metadata, and structural interfaces. |
| `core/` | Standard library in ordinary Loke; see [standard-library.md](standard-library.md). |
| `runtime/` | Versioned C ABI for allocation, managed storage, atomics, formatting, failure, and panic. `loke_rt.h` is the ABI contract. |

Prefer Loke source when it can express the feature. `stdlib.odin` contributes
compiler-owned primitives such as atomic operations, erased formatting,
allocator-aware string allocation, and provider access. Each public one is
declared in its package's source with
[`@(intrinsic)`](design.md#intrinsic), which `intrinsic.odin` binds to the
contributed symbol and checks; the declaration never reaches the selected view,
so no other pass sees it. A new public contribution needs such a declaration,
or every program importing the package reports `L0737`.

Package-private `allocate_string` bridges `core:strings` and `core:fmt` to the
runtime, returning `Result(string, Allocator_Error)`. `allocation_failed`
applies allocator policy, including non-unwinding `.Trap` failure.
`String_Builder.finish` copies because raw dynamic-array storage cannot become a
string's reference-counted allocation directly.

Platform declarations use `when (LOKE_OS == .Windows)`; filenames such as
`_windows.loke` have no selection effect. Windows is currently the only target.
`Target_Info` (`src/semantic.odin`) describes it: the triple, the layout widths,
and the [CPU level](compiler-guide.md#cpu-levels) with the features it adds.
Every Clang command takes its code-generation flags from
`append_codegen_flags`, so the module and the runtime cannot disagree on the
level or on `-ffp-contract=off`. `runtime/cpu.c` is the one runtime file
compiled as baseline code whatever the level, because the startup check runs
before anything the level permits. Its callers are baseline too: `wmain`, and
in an object build the `@llvm.global_ctors` entry `emit_object_cpu_check`
adds, both through explicit `"target-features"` lists.

`prebuilt_runtime_objects` caches C objects under
`runtime/prebuilt/<cpu>-<mode>-<hash>/`. The key covers the clang path, flags
(including the CPU level's `-march`), MSVC/SDK include roots, clang
modification time, and runtime source/header names and contents. Installed sets are immutable for concurrent links; changed inputs
create a new set. On cache build/install failure, the link compiles sources
directly and records the reason in `runtime/prebuilt/last-failure.txt`.

## Source-code map

Files directly in `src/` form the `lokec` package; `src/subprocess/` is a
separate package shared with the test harness. `lsp/` is the [language
server](#language-server), a separate executable that imports `lokec`. Shared
subsystem helpers are package-private; helpers used only within one file should
be file-private. Paths below are relative to `src/`.

### Driver, source, and syntax

| Files | Responsibility |
| --- | --- |
| `main.odin`, `session.odin`, `build_config.odin`, `providers.odin` | CLI presentation, session orchestration, build configuration, and provider selection. |
| `test_runner.odin` | The `-test` driver, which runs a built test executable once per test. |
| `overlays.odin`, `queries.odin`, `query_index.odin` | Unsaved sources, snapshot APIs, and the read-only query index. |
| `incremental.odin` | Bounded package checkpoints, input validation, dependency-prefix replay, reclamation, and checking statistics. |
| `stack.odin` | 64 MiB compiler stack reservation and nesting budget. |
| `install.odin`, `packages.odin`, `project.odin`, `select.odin` | Installation-relative roots, `loke.project` dependencies, package loading/import graph, dependency order, and `when` selection. |
| `source.odin` | `Compiler`, sources, spans, and diagnostics; destruction lives in `semantic.odin`. |
| `lexer.odin` | Tokens and lexical scanning. |
| `parser.odin`, `ast.odin`, `ast_dump.odin` | Recursive-descent parsing, syntax node definitions, error recovery, and deterministic syntax dumps. |
| `formatter.odin` | Token-preserving `-fmt` and `-fmt-check` for parseable source. |
| `doc.odin` | `-doc` Markdown and `-api` interface files for the checked root and imported project packages, from one model of each package's API. |
| `semantic.odin`, `universe.odin` | Semantic stores, interning, predeclared names, and compiler-contributed members. |

### Checking and language features

| Files | Responsibility |
| --- | --- |
| `check.odin`, `check_expr.odin`, `check_calls.odin`, `check_builtin.odin` | Main checker: declarations/statements/type syntax, expression dispatch/conversions/folding, call checking/argument binding, and compiler-owned primitive call contracts. |
| `bigint.odin`, `const_ops.odin`, `zero.odin` | Exact integer constants, shared constant operations, zero-value rules, and required-result classification. |
| `overload.odin`, `impl.odin`, `operators.odin`, `customization.odin` | Candidate ranking, methods/extensions, operators/delegates, and the built-in `len`/`cap`/`hash` receiver members. |
| `attributes.odin`, `abi.odin`, `foreign.odin`, `layout.odin` | Attribute validation, foreign ABI safety and Win64 classification, foreign declarations/imports, and canonical layout. |
| `enums.odin`, `union.odin`, `optional.odin`, `erased.odin` | Enums, unions, extraction/failure protocol, erased views, and witnesses. |
| `slice.odin`, `container.odin`, `text.odin`, `simd.odin`, `atomics.odin` | The slice type, its shared ABI type and queries; managed-container, text, SIMD, and atomic semantics, and the member tables of the built-in carriers. |
| `capture.odin` | Lower capture literals to ordinary records, `call` methods, and record literals. |
| `test_procedures.odin` | `@(test)` declarations, checked in every build and called only by a test build's entry. |
| `parallel.odin` | `parallel` blocks and `spawn` statements: placement, callee and result rules, and each spawn's frame record and run procedure ([Lowering parallel blocks](#lowering-parallel-blocks)). |
| `box.odin` | Box types, construction, unboxing, dereference projections, and shared allocation layout. |
| `hash.odin`, `format.odin`, `iterate.odin` | Contributed hashing, coherent formatting, ranges, `foreach`, and iteration protocol support. |
| `iteration_adapters.odin`, `iteration_mutable.odin`, `iteration_yield.odin` | Iterable adapters, mutable lending, and ownership/borrow modes of yielded bindings. |

### Generics, compile-time features, and bootstrap

| Files | Responsibility |
| --- | --- |
| `ast_clone.odin`, `generic.odin` | Clean syntax cloning, generic inference, specialization, monomorphization, and instance caches. |
| `interface.odin` | Typed interface arguments, interface-local predicates, structural requirements, and slot lookup contexts. |
| `eval.odin` | Bounded typed-AST interpreter for compile-time execution. |
| `expand.odin`, `reflect.odin` | Static `foreach`, expanded switch cases and union argument expansion, reflection descriptors, `type_of`, `typeid_of`, and type-ID freezing. |
| `materialize.odin` | Read-only storage for address-requiring constants. |
| `bootstrap.odin`, `stdlib.odin` | Binding ordinary bootstrap declarations and contributing compiler-owned standard members without duplicating type identity. |
| `intrinsic.odin` | Binding each `@(intrinsic)` declaration to the member it describes, checking what it states, and reporting a public contribution nothing describes. |

### Ownership and memory safety

| Files | Responsibility |
| --- | --- |
| `hooks.odin`, `lifecycle.odin` | Managed-type classification, lifecycle hooks, copy/move/drop checking, liveness, and cleanup slots. |
| `cfg.odin`, `cfg_provenance.odin` | Disposable control-flow topology and lifecycle events; provenance event construction, carrier projections, allocator regions, and call effects. |
| `provenance_input.odin`, `provenance_form.odin`, `provenance_transfer.odin`, `provenance_transfer_facts.odin`, `provenance_call.odin`, `provenance_read.odin` | Normalized provenance input: storage, values, places, value forms, transfers, call inputs, and leaf reads ([Normalized provenance input](#normalized-provenance-input)). |
| `provenance_effect.odin`, `provenance_event.odin` | Recorded fact operations and their replay; recorded event operations and their materialization. |
| `proc_contracts.odin` | Inferred callback result contracts, checked substitution bounds, and immutable borrow arguments. |
| `precision.odin` | Diagnostic metadata explaining bounded provenance merges without changing acceptance. |
| `borrow.odin` | Root loans, carrier paths, result summaries, escape contracts, allocator-region analysis, and diagnostics. |
| `global_effects.odin` | Whole-program global writes and their copy-hook and thread-entry diagnostics; the reach and allocator-use effects and thread-exit drops, and what a `parallel` block's parent does with them while its tasks run. |
| `region.odin` | `Arena`/`Scratch` semantic types. |

### LLVM and toolchain

| File | Responsibility |
| --- | --- |
| `emission_contract.odin` | Read-only validation of the checked-program boundary. |
| `emit_llvm.odin` | Module orchestration, emitter state, symbol names, procedures, globals, and instruction plumbing. |
| `emit_llvm_abi.odin` | LLVM type spelling and foreign signatures, arguments, and returns; a foreign entry's floating-point guard and `-debug`'s check after a foreign call. |
| `emit_llvm_stmt.odin` | Statements, control flow, local bindings, assignment, and returns. |
| `emit_llvm_expr.odin` | Constants, places, scalar expressions, comparisons, and text operations. |
| `emit_llvm_calls.odin` | Resolved calls, argument packing, conversions, allocation built-ins, and erased dispatch. |
| `emit_llvm_cleanup.odin` | Lifecycle clone/drop, cleanup registration, and panic replay. |
| `emit_llvm_containers.odin` | Container operation tables, construction, synthesized element/key bodies, and typed-comparator sort adapters. |
| `emit_llvm_iteration.odin`, `emit_llvm_adapters.odin` | Built-in iteration, iterable adapters, and synthesized iterator bodies. |
| `emit_llvm_atomics.odin`, `emit_llvm_simd.odin` | Atomic instruction/fallback lowering and LLVM vector lowering. |
| `emit_llvm_box.odin` | Box construction, unboxing, and recursive drop/clone thunks. |
| `emit_llvm_runtime.odin` | Runtime declarations, reflection metadata, formatting tables, globals, and witnesses. |
| `emit_llvm_debug.odin` | Debug locations, scopes, locals, CodeView metadata, and Natvis rules. |
| `emit_llvm_toolchain.odin` | `.ll`/`.obj`/`.exe` artifact policy, clang/NASM discovery and invocation, foreign inputs, and layout probes. |
| `subprocess/subprocess.odin` | Child-process execution without busy-waiting; also used by the test harness. |

`emit_llvm_module` consumes checked state and returns text without filesystem or
process operations. It creates no types, symbols, or registry entries; only the
shared layout cache may change. `semantic_extent` checks this boundary. Backend
names and temporaries belong to `Emitter`, not semantic symbols.

Non-test backend files (`emit_llvm*.odin`, `emission_contract.odin`) must not
name `Checker`. Front-end files other than `main.odin` and `session.odin` must
not call emitter procedures. Shared helpers belong with their semantic owner;
`test-all.ps1` enforces both directions.

Preserve these lowering rules:

- Implicit conversions pass an effective type through `emit_expr_at` and typed
  helpers without changing checked AST annotations.
- Values above `LARGE_VALUE_BYTES` travel by address and return through `sret`,
  avoiding LLVM first-class aggregates that can crash clang. Route Loke values
  through `load_place`, `store`, `temporary_slot`, `emit_call_result`,
  `emit_ret`, and `sret_param`; reuse temporary storage between full
  expressions.
- Fixed-array clone failures drop the built prefix in reverse order with a loop,
  keeping cleanup IR linear. `fixed_array_clone_ir_grows_linearly` guards this.
- Debug locations follow statements, conditions, and switch subjects. Each
  emitted copy of a deferred local needs its own declaration and scope.

## How to make a compiler change

1. Settle behavior in [design.md](design.md). For syntax changes, update
   [grammar.md](grammar.md), lexer/parser, AST, dump, clone rules, and recovery
   fixtures together. Exhaustive walkers and
   `ast_clone_classifies_every_node_field` help catch missing cases; place-path
   walkers deliberately remain partial.
2. Implement the decision in its semantic owner and record the result on the AST
   or in a registry. Comments cite exact headings, such as `design.md "Maps"`.
3. Add compile-time value semantics to `const_ops.odin` or `eval.odin` when
   applicable. Ownership, borrowing, retention, and allocator changes belong in
   CFG events and their solvers.
4. Register runtime dependencies during committed checking and extend the
   emission contract. Lower the recorded operation in its `emit_llvm_*` file;
   keep layout in `layout.odin` and foreign classification in `abi.odin`.
5. Prefer `base/` or `core/` implementations over new compiler/runtime
   primitives when the language can express them. Add a focused regression and
   run the relevant checks below. Follow [AGENTS.md](AGENTS.md) for accompanying
   documents and changelog entries.

For backend failures, trace the assertion back to the missing annotation or
registry entry. Fix the phase responsible for that fact rather than adding a
backend lookup. Use `rg` for procedure names, diagnostic codes, or `@(test)`.

## Testing and verification

From the repository root:

```powershell
.\test-all.ps1                     # quick gate
.\test-all.ps1 -Full -RequireTools  # CI gate
```

The quick gate checks heading citations and layering, runs unit tests, rebuilds
`lokec.exe`, and runs baseline integration tests. `-Full` adds the checker
mutation fuzzer and reruns optimization-sensitive corpora at every supported
level. Use it locally for that additional coverage or to investigate CI
failures.

Some checks need external tools: NASM, clang with a C-host toolset, or cdb
(WinDbg/ Windows SDK, optionally selected by `LOKE_CDB`). Missing capabilities
are reported as skips. `-RequireTools`, or `LOKE_TEST_REQUIRE_TOOLS=1`, turns
those skips into failures; CI uses both switches.

Unit tests live beside the compiler implementation in `src/*_test.odin`.
`session_test.odin` and `incremental_test.odin` compare diagnostics, semantic
registries, and IR with fresh batch checks, and verify invalidation and memory
reclamation. The integration harness is in `tests/`:

| Cases | Checks |
| --- | --- |
| `run/`, `trap/` | Stdout against `.expected`; failing processes against `.expected-err`. |
| `err/`, `pkg_err/` | Diagnostic counts, codes, fragments, optional spans, and source warnings. |
| `syntax/`, `syntax_err/` | Valid syntax, AST goldens, and recovery with a surviving trailing sentinel. Valid syntax and parser fuzzing run in-process in `src/syntax_corpus_test.odin`. |
| `ll/`, `layout/` | Required/forbidden LLVM shapes and LLVM acceptance; compiler/LLVM layout agreement. |
| `pkg/`, `obj/`, `os/` | Multi-package programs, C-host linking, process arguments, environment, and file links where the account may create one. |
| `doc/`, `examples/` | Generated documentation and classified real example programs with expected output. |
| `test/` | Test builds: the `-test` runner's report against `.expected`, exiting 1 when it lists a failure. |
| `api/` | Interface files: `-api-check` against each case's checked-in `api.loki`, with and without `-debug`, and `-api` restoring them to a copy. |
| `debugger/` | Debug information: cdb runs a `-g` build, stops in it, and shows the caller's locals through the Natvis rules. |
| `tutorial_test.odin` | Programs, auxiliary files, outputs, panics, and diagnostics extracted from tutorial fences. |
| `runtime_test.odin` | Runtime-header ABI agreement and concurrent runtime-cache creation/reuse. |
| `checker_fuzz_test.odin` | Deterministic source mutation; failures reduced and saved under `tests/tmp/fuzz/`. |
| `borrow_matrix_test.odin` | Generated programs crossing place forms with mutable copies, payload bindings, borrows, slices, and traversals, and the uses beside them in straight-line code, branches, and loops, judged against `matrix_expected`, a model of the reborrow rules written apart from the compiler; `matrix_known_gap` lists the cases `known-gaps.md` records. |

`every_diagnostic_code_is_pinned` requires each diagnostic to have a test or a
reasoned entry in `UNPINNED` in `tests/corpus_test.odin`. Fuzzer failures become
regressions with their fixes; `LOKE_FUZZ_SEED` and `LOKE_FUZZ_MUTANTS` explore
more cases. Harness workers collect results and assertions run on the test
thread; child processes use the shared `subprocess` package without
busy-waiting.

For individual suites:

```powershell
odin test src -vet-unused -vet-shadowing -vet-packages:lokec
odin build src -out:lokec.exe -vet-unused -vet-shadowing
odin test lsp -vet-unused -vet-shadowing -vet-packages:lsp
odin build lsp -out:loke-lsp.exe -vet-unused -vet-shadowing
odin test tests -define:ODIN_TEST_TRACK_MEMORY=false -vet-unused -vet-shadowing -vet-packages:tests
```

**Rebuild before direct integration runs after compiler changes.** The harness
uses existing `lokec.exe` (or `LOKEC`) and `loke-lsp.exe` (or `LOKE_LSP`);
`odin test tests` rebuilds neither.
Add `-define:ODIN_TEST_NAMES=<name>` to select an Odin test procedure:
`programs_run` selects the executable corpus, and `tutorials_compile_and_run`
selects tutorial programs, not a single source file.

For direct optimization runs, set `$env:LOKE_TEST_FLAGS = "-opt=speed"`, then
restore/remove it afterward. Run/trap, package, example, and tutorial
compilations honor it; `test-all.ps1` manages it itself.

Unit tests track allocations. Build with `-define:LOKE_TRACK_MEMORY=true` to
report whole-compilation leaks and bad frees. `-vet-packages` confines test
vetting to the repository package. `test-all.ps1` judges each tool by its exit
code alone, so it also runs under Windows PowerShell 5.1 with its output
redirected (`*>`, `2>&1`, `Tee-Object`); there the first stderr line of a tool
is shown as a `NativeCommandError` block, which is noise, not a failure. Running
a suite directly in 5.1 with `2>&1` and `$ErrorActionPreference = 'Stop'` stops
at that line; use PowerShell 7 (`pwsh`, as CI does) or check `$LASTEXITCODE`
instead.

Test code deletes directories with `remove_tree` (`lokec.remove_tree` from the
language server's tests, and its copy in `tests/corpus_test.odin`), never
`os.remove_all`. On Windows that call goes through the shell, which raises and
then handles an access violation of its own; Odin's test runner catches every
access violation with a vectored exception handler and stops the running test
as a `Segmentation_Fault`, intermittently and in whichever test was deleting.

For documentation-only changes, check local links and run `check-citations.ps1`;
compile affected examples or run the tutorial suite when needed. A full compiler
gate is unnecessary. Preserve cited headings when reorganizing this guide.

For performance changes, build the baseline compiler and run:

```powershell
.\perf.ps1 -Out before.json
# Make the change and rebuild lokec.exe, then:
.\perf.ps1 -Baseline before.json
```

Use the same machine and workloads. The script measures front-end and full-build
time, peak working set, executable size, and benchmark runtime, and times
`loke-lsp.exe` editing `bench/workspace` (see [Language
server](#language-server)). Timings use the fastest of three runs, and every
run's benchmark output must match. A program or server operation slower than
`-TimeoutSeconds` fails the run. Each record carries a hash of the program's own
sources, not the standard library's, and a figure measured on other sources than
its baseline's is shown as `(sources changed)` rather than compared. CI compares
with the latest release's `perf.json`; releases attach their own record. The
tests of `perf.ps1` itself drive it with `tests/perf/fake_compiler.loke` in
place of `lokec`. For structural backend refactors, also compare emitted `.ll`
using identical source paths and options to catch naming or ordering drift.

### Standard-library verification

Use `tests/run/lib_*.loke` and examples. Cover the boundaries relevant to the
API:

- Empty/binary data, valid/invalid UTF-8, and rune offsets.
- Unicode and long paths; missing, inaccessible, read-only, and existing paths.
- Short reads/writes, EOF, interruption, broken pipes, and redirected handles.
- Limits just below/at/above the boundary; `Limit_Exceeded` destroys partial
  owners.
- Allocation failure with unchanged destinations; a small `mem.Arena` makes it
  deterministic. Also check close followed by drop, double close, and unwind.
- For `core:random`: known-answer vectors from each generator's reference
  implementation, draw counts compared through `state()`, a scripted `Source`
  for rejection paths and float ends, and seeded statistical checks with
  generous bounds: moments for continuous distributions, and Pearson's
  chi-square against the exact mass function for counting ones. An
  `.expected` file holds only seeded values and comparisons, never an unseeded
  draw. `lib_random_ziggurat` checks the distribution tables against a
  recomputation, and `lib_random_pcg` pins vectors from numpy's PCG64DXSM.
- For `core:time`: known answers checked against another calendar
  implementation, at both ends of every range and around 1970; a walk over
  every day from 0000-01-01 to 9999-12-31; every parse error; and a
  print-then-parse round trip for every type and style. An `.expected` file
  holds no clock reading, only comparisons with one.

Use fake short readers/writers as in `lib_io` and isolated temporary directories
as in `lib_fs`. `lib_term` covers output and redirected handles;
`lib_term_console` drives console input by writing records into the input
buffer of the console the test run is using, because Windows 10 cannot allocate
a hidden one. Do not type into that console while it runs, or the keys are read
along with the records. It also checks that leaving raw mode restores the
console's mode. Restoration during unwinding and the console control handler
remain manual checks with `examples/keys.loke`.

## Reusable batch sessions

`src/session.odin` owns one `Compiler`, copied configuration and overlays,
session arenas, and optional package checkpoints. CLI presentation stays in
`main.odin`; filesystem/toolchain policy stays in `emit_llvm_toolchain.odin`.

| Operation | Contract |
| --- | --- |
| `init_session(&s, config)` | Initialize a zeroed session; copy configuration strings/arrays. Defaults to `DEFAULT_COMPILATION_CONFIG`. Invalid configuration returns false with diagnostics; a live session cannot be reinitialized. |
| `check_session(&s, input)` | Replace the compilation, reload inputs, check, validate entry/exports, and finalize. Return false with diagnostics on errors. The input path is copied. |
| `check_session(&s, input, documentation = true)` | Check for `-doc` and `-api`, without executable-entry validation or emission finalization. Cannot emit. |
| `check_session_incremental(&s, input, documentation = false)` | Reuse an eligible dependency prefix; otherwise perform a full check. Documentation checks reuse their own checkpoints. See [Incremental checking](#incremental-checking). |
| `session_check_stats(&s)` | Rechecked/reused package IDs and semantic/checkpoint byte counts. ID slices expire on the next check or destruction. |
| `invalidate_session(&s)` | Expire the result after external changes. Repeated calls are safe; false only for an uninitialized/destroyed session. |
| `emit_session_ir(&s)` | Return module text and a success flag; no files or tools. Requires a successful finalized check. Each module remains allocated until the next check or destruction. |
| `emit_session(&s, options)` | Write artifacts using `Emission_Options` (`output`, `emit_ll`, `keep_temps`, `runtime_dir`). Optimization/build mode come from configuration. An empty output returns 2 without a diagnostic and permits retry; otherwise return toolchain status. |
| `destroy_session(&s)` | Release all owned storage. Safe on zeroed sessions, after failures, and repeatedly. |

Do not copy a live session or `Compiler`: allocator pointers refer into them.
The allocator captured at initialization must outlive the session. Configuration
is fixed; create a new session to change it. Operations require exclusive access
except for the concurrent queries described below.

`s.compiler` exposes borrowed sources, syntax, IDs, diagnostics, and emitted
text. Their lifetime ends at invalidation, an overlay edit, the next check (even
if it fails), or destruction. Copy anything needed longer. Batch/documentation
checks discard checkpoints; batch checking remains the reference for incremental
results.

## Snapshots and queries

`overlays.odin` supplies unsaved sources; `queries.odin` exposes recorded
checking results; `query_index.odin` indexes checked syntax and committed
generic/static-loop clones. The query arena and formatted type names are built
lazily on the first snapshot. Queries never resolve names, check bodies,
instantiate generics, or enroll artifacts.

All operations below return a success flag. Query handles carry a process-unique
snapshot ID; entry points reject stale/foreign handles and out-of-range IDs,
including after destroying and reinitializing a session.

| Operation | Result or effect |
| --- | --- |
| `set_session_overlay(&s, path, text)` | Copy a `.loke` path/text, normalized as Windows package loading does. Empty text replaces disk content. New files/directories and imported packages are supported; directory discovery includes direct `.loke` children. No disk writes. Invalid paths/extensions or uninitialized sessions return false. |
| `remove_session_overlay(&s, path)` | Restore disk loading or remove an unsaved-only file. An absent overlay returns false without invalidation. |
| `session_snapshot(&s)` | Capture current views, even after failed initialization/checking. False for zeroed/destroyed sessions or after invalidation until a check runs. |
| `query_file` / `query_source` | Loaded file ID or path, source text, and line-start byte offsets, including loaded manifests. `bundled` marks a file of the `base:` or `core:` library shipped with the compiler. |
| `query_symbols` / `query_symbol` | Written bindings and their names, kinds, types, visibility, generic status, and definitions, including locals, parameters, fields, and enum members. Each also has its whole written declaration (`extent`, from its first attribute; the name alone for a binding with no declaration, such as a loop binding) and `parent`, the innermost other written binding whose extent contains its own: a field's record, a member's enum, a parameter's, local's, or loop binding's procedure. A written binding is spelled as an identifier, so generated declarations named after their syntax, such as a capture literal's record, are omitted. `owner` is the type of an `impl` or `extend` member, and `promotes` marks a `using` field. `scope` is where a local, parameter, or loop binding can be named: the innermost block, statement, switch case, or procedure holding its name; a selected `when` branch is not one, since its braces open no scope. |
| `query_documentation` | A binding's doc comment, as `-doc` reads it; caller-owned. False when there are none. |
| `query_at` | Narrowest written node at a half-open byte offset; available symbol/type independently, including selected overloads or generic instances. `type_value` marks a node that denotes its type rather than a value of it. |
| `query_selector_operand` | The written operand of the selector whose name holds an offset, described as `query_at` describes a node. Parentheses are not part of an operand's span, and the links the checker adds for a promoted field are skipped, so `(outer).x` and a promoted `outer.x` both give `outer`. So is an implicit dereference: `p.m()` through a pointer gives `p`, whose own members come first. Instances merge as in `query_at`: an unchecked generic template adds nothing, and only instances that disagree hide a part. |
| `query_visible` | Bindings an unqualified name can reach at an offset, innermost first: locals whose `scope` holds the offset and whose name ends before it, then the file's package scope with its imports, then the predeclared names. Shadowed names are omitted. Caller-owned. |
| `query_implicit_names` | Member names reached by name where no use spells them: those the compiler looks up itself (`call`, iteration, `format`, `hash`, `len`) and the slot names and selected members of every interface the program uses. |
| `query_members` | What may follow `operand.` for a `query_at` result: a package alias's public declarations; a type's enum members or union variants and members; a value's fields, then the fields its `using` fields promote, and methods, through a pointer or box. Members are those recorded and visible from the file's package, so one contributed on demand appears once a lookup created it. Sorted by name; caller-owned. |
| `query_type` | Recorded type properties, components, fields, members, and parameter types/modes. Zero IDs mean unavailable. |
| `query_definition` | Snapshot-scoped written location; false for builtins/synthetic bindings without definitions. |
| `query_references` | Exact-binding named uses, deduplicated across generic/static-loop clones; excludes implicit operations. `include_definition` defaults to false. Caller owns the array and must `delete` it with the query allocator. |
| `query_signatures` | Procedure/group signatures, parameters/defaults, result and termination properties. Generic templates expose written syntax with `complete = false`. |
| `query_diagnostics` | Captured severity, code, message, labels, locations, and notes. Snapshot before emission to capture checking diagnostics; later emission cannot alter that view. |

See [queries.odin](src/queries.odin) for full signatures. Except for reference
arrays, returned strings/slices are borrowed, read-only, and expire on
[invalidation](#invalidation-rules); snapshot tokens do not retain compilations.

After the first `session_snapshot` builds views, later snapshot/query calls may
run concurrently. Allocating queries use the calling thread's `context`. The
first snapshot, invalidation, overlay edits, checks, emission, and destruction
all require exclusive access.

Failed checks expose loaded sources, diagnostics, and whatever semantics were
recorded. Unresolved/inactive nodes have no semantic result; signature queries
omit erroneous signatures. Position queries never substitute a parent for an
unresolved narrowest node. If specializations disagree at one written position,
that symbol/type component is unavailable; shared binding identity can remain
when only types differ. References from failed checks are partial.

## Invalidation rules

Invalidation expires the **whole compilation's public snapshot**, clears
emission readiness, and releases query storage. Configuration, overlays, and
package checkpoints remain. Overlay replacement/removal and each new check
invalidate old views; a failed check replaces the preceding result and cannot
emit.

Disk changes do not update snapshots automatically. Call `invalidate_session`
when notified, or check again directly. Notification performs no reads/checking;
events may be batched. Do not filter solely by `query_file`: new or missing
files, imports, package members, and nearer manifests may affect previously
loaded code.

Batch checks rebuild everything. Incremental checks validate the full input set
before reusing a prefix. Reuse depends on root identity/mode, working directory,
exact source bytes and directory membership, overlays, import/selection state,
nearest/transitive manifests (including previously absent ones), collection
roots, and provider selections. Configuration, compiler identity, and target are
fixed by the live session.

Exported signatures alone are insufficient: CTFE bodies, generic bounds and
lookup, inferred global writes/provenance, and formatting/drop hooks can change
dependents without changing a signature. Their derived registries, diagnostics,
queries, and emission must be rebuilt or restored to a valid checking boundary.
Semantic IDs and generic-instance keys are compilation-local cache keys.

Foreign inputs, runtime sources, toolchain identity/environment, output paths,
and artifact options are read during emission. There is no cache of complete
program artifacts; the [runtime-object cache](#runtime-and-library-boundary) is
separate. A future persistent cache must include compiler identity and all
relevant inputs rather than treating version strings or signatures as
sufficient.

## Incremental checking

The CLI uses batch checking and allocates no package cache. The opt-in
incremental API reuses only static graphs without selected providers. A graph is
static when no `import` sits inside a file-scope `when`; then each package
settles its own `when` selection, which reads only that package and what it
imports, after preparing its declarations and before any dependent is prepared.
Batch checks take the same path, and the bundled library's platform `when`
blocks no longer force a full check. Whole-program provenance/provider analysis,
entry/export validation, and finalization still run; LLVM emission remains
whole-program.

Before preparing each package, a checkpoint saves compiler fields, the semantic
arena watermark, and its used bytes. Incremental sources, syntax, diagnostics,
and registries share that arena, so images capture earlier mutable data as well
as new allocations. Allocator pointers keep naming the same live `Compiler`;
checkpoints cannot move between sessions. Restoration recreates disposable
analysis/emission arenas.

Before reuse, a temporary loader re-resolves manifests and collections,
enumerates packages, and reads source bytes through overlays. It compares
root/mode/current directory, manifests, roots, membership, package clauses, and
ordered imports. Timestamps and hashes do not substitute for byte equality.

Restore the nearest checkpoint at or before the earliest changed package and
recheck the entire suffix, including unrelated later packages. Checkpoints stop
at errors, so edits after an error restart there. Even unchanged inputs recheck
the final package. This rolls back cross-package effects from generics, CTFE,
and registries rather than trusting unchanged signatures.

After restoration, compare every suffix source with current inputs, including
edits made since older checkpoints. Reparse changes at their original source
indices, in that loading order as a batch parses them, and rebind imports to
refresh spans. Keep the checkpoint before those
replacement allocations, discard/rebuild later checkpoints, reclaim query and
emission storage, and issue a new snapshot ID.

Full-check fallbacks are:

- First use; changed input, working directory, or root mode; switching between
  batch, documentation, and executable checking.
- Added/removed files or packages; changed manifests, collection roots, package
  clauses, file attributes, or import paths/aliases.
- An `import` inside a file-scope `when`, or selected providers.
- Source read, UTF-8, or BOM failures; unavailable checkpoints.
- Syntax errors in an edited file when the restored boundary holds warnings. A
  batch reports syntax errors while loading, before any checking, so they
  precede every warning; after a boundary they follow its diagnostics.
  Checkpoints hold no errors, so with no warnings the order is the same.

Semantic errors and syntax errors in an edited file may retain an unaffected
prefix and are retried after repair. A full check whose sources have syntax
errors keeps no checkpoints, so the check after the repair is full as well.
Fallbacks rebuild eligible checkpoints. Images have a 64 MiB payload limit;
oldest boundaries are evicted first and oversized images are not cached.
`session_check_stats` reports package reuse, semantic-arena usage, and image
payload, excluding metadata, other arenas, and OS overhead. These are accounting
counters, not working-set measurements.

On `bench/workspace`, five packages over twelve bundled ones, an edit to the
root package rechecks one package of seventeen. When incremental checking was
introduced (2026-10-14), an optimized build checked in about 52 ms instead of
72 ms. Almost all of what remained was whole-program
provenance analysis, about 43 ms, which runs over every checked body,
including the bundled library's. The checkpoint images took about 57 MiB, and
the first check about 45 ms longer to capture them. Equivalence and cost
evaluation continues in [Compiler services](future-plans.md#compiler-services).

## Language server

`lsp/` builds `loke-lsp.exe`, which speaks the Language Server Protocol on
stdio. Behavior and configuration for users are in
[Language server](compiler-guide.md#language-server).
The server never duplicates the front end: every result comes from the
[session](#reusable-batch-sessions) and [snapshot](#snapshots-and-queries) APIs.

| File | Responsibility |
| --- | --- |
| `main.odin` | Command line, reader thread, inbox, debounce, and the main loop. |
| `jsonrpc.odin` | `Content-Length` framing, JSON output, and tolerant field access. |
| `server.odin` | Lifecycle, request/notification dispatch, cancellation, configuration, and open documents. |
| `roots.odin` | Root assignment, checking, diagnostic conversion, and publication. |
| `requests.odin` | Request queueing, waiting, cancelled and stale requests; hover, definition, and document symbols. |
| `editing.odin` | Completion and signature help, from the compiler's tokens and the queries above. |
| `rename.odin` | References and rename across roots, and rename's refusals. |
| `tools.odin` | Formatting and the documentation command, through `-fmt` and `-api`. |
| `paths.odin` | `file:` URIs, path keys, and UTF-8/UTF-16 positions. |

A reader thread frames stdin into an inbox. The main thread runs checks, so it
has the compiler's [stack reservation](#driver-and-phase-order). It applies
every queued message in order, then waits for edits to pause briefly, then
performs one step of `run_pending_work`. A `$/cancelRequest` cancels a request
queued in the same batch or still waiting for a check. A running check is not
interrupted: its result is discarded if an edit arrives first. `shutdown` drops
pending work; `exit` and the end of input stop the process.

Each root is one `lokec` input with its own `Compilation_Session` and the same
fixed configuration. Every open document is an overlay in every session. An edit
marks every root dirty because any root may import the edited file. A change
that leaves the text as it was changes only the version its diagnostics are
published with, so no root checks again and no waiting request becomes stale. A
document's own root is its directory, or the file when two or more sibling files
declare `main`. `refresh_roots` assigns a document to another root whose last
check loaded its file, provided that root is some other open document's own
root, so closing an application returns its imported packages to their own
roots. If several roots qualify, it picks the outermost: the one whose own
package no other candidate loads. Otherwise the document gets its own root.
`declares_entry` runs the compiler's lexer and looks for `main :` outside
brackets, once per document revision; each refresh counts open entries by
directory. Assignment runs again after every check, so it does not depend on the
order documents were opened. Roots that no open document uses are destroyed.
`check_root` uses `check_session_incremental`, rechecking once in documentation
mode when the root package is not `main`, so a root reuses the packages before
the first one an edit reached. A root no edit reached reruns only its last
package. It records the paths of loaded sources and copies snapshot diagnostics
into the root's result arena with client positions. Diagnostics with no source
location are shown on that root's open documents.

Diagnostics are published only after every root has been checked since the last
edit. A file's list is the deduplicated union across roots, because an imported
package is checked by each importer. Notes are part of a diagnostic's identity:
two programs can report one error with different declarations behind it, and the
client gets both. The server records what it sent for each file and sends only
changes, including an empty list when a file has no diagnostics left. An open
document keeps the client's URI spelling and receives its version.

Position requests wait in `pending` until `refresh_roots` has run and their
document's root is clean, so the root's snapshot was taken from the document's
current text; references and rename also wait for every other root.
`run_pending_work` answers them before anything else and checks a requested root
before other dirty roots. Each document records the server's edit `revision`; a
request whose document changed or closed while it waited is answered
`ContentModified`, and a later `$/cancelRequest` or `shutdown` answers it as
cancelled. Before answering, the server confirms the snapshot's text for the
file equals the document's; otherwise, and whenever `query_at` records no
binding, the result is `null`. Positions just past a name fall back to the name.
Hover text and the outline come only from `Query_Symbol`, signatures, recorded
type names, written declaration extents, and `query_documentation`. Document
symbols omit anything whose `parent` chain reaches a procedure, which leaves
package-level declarations with their fields and enum members as children. Kinds
after `Array` are sent only to a client that lists them in
`symbolKind.valueSet`; others get `Class` for a struct and `Constant` for an
enum member.

Completion and signature help lex the document with the compiler's lexer to find
the cursor's context, then ask the snapshot. Neither answers inside a comment or
a literal, including one the lexer rejected, which an unclosed literal holds to
its end. After `operand.`, the operand's last byte goes to `query_at` and then
`query_members`; elsewhere `query_visible` lists the names in scope, followed by
the keywords. Signature help takes the innermost bracket open before the cursor,
which must be a `(` after a name, and the procedure or group `query_at` records
there; commas at that depth, a named argument, and a method call's implicit
`self` choose the active parameter. A parameter's label offsets point at its
name, never at a type spelled the same, and count UTF-16 units under either
position encoding, as the protocol defines them. Completion kinds after
`Reference` are negotiated like symbol kinds.

References and rename identify a binding by its written definition, so every
root whose snapshot has the same binding at that place contributes its recorded
uses. Rename refuses rather than guesses: every root that loads the binding's
file must check without errors, since references from a failed check are
partial, and every occurrence of the old name in those roots' non-bundled
sources must have a recorded binding, so an inactive `when` branch or an
interface slot stops it. The new name may not capture or be captured, as
`query_visible` and each binding's `scope` show, and a field or member rename
is checked at every selector against the members `query_selector_operand`
records, promoted fields included. [rename.odin](lsp/rename.odin) states each
refusal beside the check that makes it.

Formatting and documentation call the procedures behind `-fmt` and `-api`
rather than reimplementing them. `textDocument/formatting` needs no check, so
it is answered as soon as it is dispatched: `format_text` registers the
document's text in a scratch `Compiler` under the same encoding rules
`load_source` applies, then runs `format_source`. The reply replaces the lines
from the first that changed to the last in one edit, so both ends of its range
start a line. A refusal reports the first error and its line. The
`loke.documentation` command queues like a position request and answers with
`interface_of_source`, the interface file of the document's package. It skips
the position requests' check that the snapshot holds the document, so a check
that failed before loading it, such as for a malformed manifest, still fails
the command, and a failure names the first error `lokec -api` would report. A
library root was checked as `lokec -api` checks it, so its snapshot is used
directly. A program root is checked again with `check_session` in
documentation mode, in a temporary session with the same configuration and
overlays, so that an executable-only error such as a missing `main` does not
block the interface, and the root's checkpoints stay as they are. The text is
built in the request's temporary memory because `interface_of_source` frees
little.

`editors/vscode/` is a thin client for VS Code and VSCodium: it starts the
server for `.loke` documents only, passes its settings as
`initializationOptions`, and shows the interface the documentation command
returns as a Loke document. Its TextMate grammar highlights from the text
alone, naming the keywords and predeclared names; `tests/editor_test.odin`
compares those lists with grammar.md "Keywords" and design.md "Predeclared
names" in both directions, so a new keyword or built-in also needs the grammar.

`lsp/server_test.odin` drives the server in process, choosing when checks run
relative to edits, and compares results after rapid edits and disk changes with
a fresh batch check. It compares formatting with `format_files` and the
documentation command with a fresh documentation-mode check.
`tests/lsp_test.odin` runs the built executable over pipes, and compares its
formatting and documentation with `lokec.exe -fmt` and `-api`.
`perf.ps1` times the built server editing `bench/workspace`, from each
notification to its answer: opening it, edits to its root package and to a
library package, and completion in an unfinished statement. Each figure
includes the 150 ms pause the server waits for further edits. When incremental
checking was introduced (2026-10-14), it answered an edit in about 295 ms
instead of 340 ms, and completion in about 290 ms instead of 340 to 470 ms,
while the server's peak working set grew from about 33 MB to about 89 MB for
the checkpoints. The provenance-normalization records in
`bench/baselines/README.md` include later timings of the same operations.

## Deliberate boundaries

- Windows x64 only, with its foreign ABI classification.
- Whole-program, single-process emission through textual LLVM, clang/NASM, and
  the C runtime. Object output exists; separate or parallel package compilation
  does not. Introduce a durable MIR only for a concrete consumer.
- The compiler remains in Odin; [self-hosting](future-plans.md#self-hosting) is
  future work.
- Debug information covers source procedures, statements, scopes, and locals;
  compiler-contributed methods lack it. Natvis describes maps and erased values.
  See [compiler options](compiler-guide.md#common-options) for debug
  limitations.
- Recoverable panic, macros, owning type erasure, and a GC allocator are absent.
- Raw-pointer provenance, `core:unsafe`, foreign retention/aliasing, and
  cross-thread transfer remain trust boundaries.

Record spec divergences with reproductions in [known-gaps.md](known-gaps.md).
Rationale belongs in [comments.md](comments.md), unresolved questions in
[open-questions.md](open-questions.md), and later initiatives in
[future-plans.md](future-plans.md).

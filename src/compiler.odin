package lokec

import "core:mem"
import "core:mem/virtual"

// What a build selects for the whole program, on the command line or through a
// session's configuration.
Compilation_Settings :: struct {
	// An option rather than a rule, because it is target-specific and not part of
	// the language (compiler-guide.md "Copy-cost diagnostics"). A copy site reports when it
	// duplicates at least this many inline bytes, or when its clone may allocate.
	copy_cost_threshold: u64,
	copy_cost_enabled:   bool,
	// design.md "Panic strategy": `-panic=unwind` registers one logical frame per
	// procedure that can own a cleanup, so a panic replays every active Loke
	// frame's live actions before terminating; `-panic=abort` registers none.
	// A whole-program build selection, never a source construct.
	panic_unwind:        bool,
	// design.md "Build configuration": the whole-program optimization and build
	// mode the driver selected. The `LOKE_OPTIMIZATION_MODE` and `LOKE_BUILD_MODE`
	// predeclared constants take their value from these.
	opt_mode:            Opt_Mode,
	build_mode:          Build_Mode,
	// `-cpu`, which `target` is resolved at.
	cpu:                 Cpu_Level,
	// `-g`: emit debug information (`emit_llvm_debug.odin`).
	debug_info:          bool,
	// `-debug`, the value `LOKE_DEBUG` is predeclared with.
	debug:               bool,
	// `-log-level`, the value `LOKE_LOG_LEVEL` is predeclared with.
	log_level:           Log_Level,
}

// Compiler-wide state.
//
// Batch source buffers and diagnostics use the process allocator and each File
// owns its syntax arena. Incremental inputs/syntax/diagnostics join identifiers,
// types, symbols, scopes, and packages in the checkpointed semantic arena.
Compiler :: struct {
	using settings: Compilation_Settings,
	// Opt-in session package checkpoints; nil for ordinary batch compilations.
	package_cache: ^Package_Check_Cache,
	sources:     [dynamic]Source,
	// The session's overlays; read through `compiler_overlays`. A pointer, not a
	// copy of the map, so an overlay edit cannot leave a stale map header. Loaded
	// buffers are copied so an edit cannot alter a compilation being consumed.
	source_overlays: ^map[string]Source_Overlay,
	diagnostics: [dynamic]Diagnostic,
	error_count: int,
	// What a declaration settled from inside a probe reported (`begin_settling`), and
	// a body checked on demand for compile-time execution
	// (`ensure_proc_typed_for_eval`). Each is settled and never checked again, so a
	// speculative check that led to it and then rolls its diagnostics back must not
	// take these along; they rejoin the list once no probe is open
	// (`release_held_diagnostics`).
	held_diagnostics: [dynamic]Diagnostic,

	// While a capture literal's body is cloned into its record's `call`: the
	// captured names, which the clone rewrites to the receiver's fields
	// (`ast_clone.odin`). Nil for every other clone.
	capture_rewrite: ^Capture_Rewrite,
	// While a parametric alias's body is cloned into a view: each parameter's
	// written argument, which the clone puts where its `$` name was; and the
	// checker whose scope tells which applications in the clone are aliases to
	// expand the same way (`alias_view` in generic.odin). Nil for every other
	// clone.
	poly_substitution: ^map[Identifier_Id]Expr,
	alias_view:        ^Checker,

	// Hypothetical checks (overload bounds and interface requirements) may use
	// the ordinary checker, but must not enroll backend artifacts in the final
	// module. Nested checks share this counter so every registry has one gate.
	speculation_depth: int,
	// How many `begin_commit`s have run, so a probe can tell its own enrollment
	// from a sanctioned commit inside it.
	commits:           int,
	// Commits under way (`begin_commit`), any of which may sit inside a probe.
	open_commits:      int,

	// The widths `int`, `uint`, `uintptr` and every pointer take. Checker and
	// emitter read this one record so they cannot disagree.
	target:      Target_Info,

	// Project-wide `-define:NAME=VALUE` configuration, seeded before package
	// discovery so the first file-scope `when` round sees it and every package
	// agrees on what a name means.
	defines:     map[string]Const_Value,

	// Package discovery (`src/packages.odin`). `package_by_dir` is keyed by the
	// canonical directory, so an alias never creates a second package instance.
	collections:    map[string]string,
	package_by_dir: map[string]Package_Id,
	root_dir:       string,
	root_package:   Package_Id,
	// Validated by the session for executable builds; never resolved by emission.
	entry_point:    Symbol_Id,
	// design.md "Test procedures": a test build's tests, in the order it runs them.
	tests:          [dynamic]Symbol_Id,
	// Every parsed file, so one `destroy_compilation` frees the lot.
	parsed_files:   [dynamic]^File,

	// Generics (`src/generic.odin`). `instances` is the positive/negative
	// specialization cache, keyed by (declaration symbol, canonical argument
	// vector); the stack and unique-entry count enforce the documented ceiling.
	generic_templates:     map[Symbol_Id]^Generic_Template,
	generic_impls:         map[Symbol_Id][dynamic]^Generic_Impl,
	// Each generic `extend` block's public procedure group, by group symbol: the
	// members its instances added, which the group's `members` views.
	extension_groups:      map[Symbol_Id][dynamic]Symbol_Id,
	instances:             map[string]^Instance,
	procedure_instances:   map[Symbol_Id]^Instance,
	// design.md "Parametric aliases": the type each application denotes, by the
	// same key, so an alias names one type however often it is applied.
	alias_expansions:      map[string]Type_Id,
	instantiation_stack:   [dynamic]Instantiation_Frame,
	instantiation_count:   int,
	instantiation_limit_hit: bool,
	// The diagnostic that already carries the instantiation stack, so unwinding
	// a deep instantiation does not attach it once per level.
	last_noted_diagnostic: int,
	pending_impl_instances: [dynamic]Pending_Impl,
	// The blocks of each subject whose `delegate` items have yet to run
	// (`settle_delegates`).
	pending_delegates:     map[Type_Id][dynamic]Pending_Delegate,
	// The blocks of the package being declared, and its operators whose signatures have
	// yet to resolve (`settle_pending_operators`), with the first of each not yet taken.
	pending_operator_blocks:     [dynamic]Pending_Operator_Block,
	next_pending_operator_block: int,
	pending_operators:           [dynamic]Pending_Operator,
	next_pending_operator:       int,
	// The first of them `check_pending_impl_instances` has yet to check.
	next_pending_impl:     int,
	// Instances of generic declarations that `check_pending_impl_instances` has yet
	// to read for private names.
	pending_private_reads: [dynamic]Pending_Private_Read,
	// What instances of a generic declaration have settled in their reads of it
	// (`src/private_names.odin`): a constant warned about by its value's type, and
	// the name, written type or value of a declaration read by its syntax, so each is
	// read once, or until it selects no member a later instance may say is a type.
	private_reads_settled: map[Span]bool,
	// Where a written private name has been warned about, so an instance's reading
	// of a block's syntax does not repeat its template's.
	private_names_warned: map[Span]bool,
	// The names of generic `impl` members whose value is a type, which no symbol
	// in the template records, so `check_private_names` reads them as type aliases.
	generic_impl_types: map[Span]bool,

	// Interface declarations (`src/interface.odin`), keyed by their symbol.
	interfaces:            map[Symbol_Id]^Interface_Info,
	// Checked map key operations, keyed by the underlying key type. Consumers
	// must use these IDs rather than selecting members again.
	map_key_policies:      map[Type_Id]Key_Policy,
	// The `<` one `sort` uses, per element type (`src/container.odin`).
	order_policies:        map[Type_Id]Order_Policy,

	// Compile-time reflection (`src/reflect.odin`, `src/typeid.odin`). The descriptor
	// types are created on first use; `typeid` identity is symbolic during checking
	// and numeric only after `freeze_typeids`.
	meta_field_type:      Type_Id,
	meta_enum_value_type: Type_Id,
	meta_variant_type:    Type_Id,
	// design.md "Typed fallibility": the `base:runtime` declarations the
	// compiler bootstraps and binds into the universe. `Unit` is a type; the
	// others are generic templates instantiated through `src/bootstrap.odin`.
	universe:             ^Scope,
	unit_type:            Type_Id,
	option_symbol:        Symbol_Id,
	// `Status(Allocator_Error)`, instantiated once at bootstrap: every
	// recoverable operation with no success value returns exactly this type.
	alloc_result_type:    Type_Id,
	result_symbol:        Symbol_Id,
	bootstrap_ready:      bool,
	typeid_requested:     map[Type_Id]bool,
	typeid_order:         [dynamic]Type_Id,
	typeid_values:        map[Type_Id]u64,
	typeid_frozen:        bool,

	// Iteration (`src/iterate.odin`). Range and iterator types are interned per
	// element type; contributed procedures are emitted once for the whole
	// compilation, not per package.
	range_types:        map[Type_Id]Type_Id,
	iterator_types:     map[Type_Id]Type_Id,
	// The container views `entries()`, `keys()`, `values()`, and
	// `rune_offsets()` answer with. Keyed by source and kind because one map has
	// three of them.
	view_types:         map[View_Key]Type_Id,
	adapter_members:    map[Adapter_Key]Symbol_Id,
	derived_members:    map[Derived_Key]struct{},
	// design.md "Capture literals": the records capture literals lower to,
	// each with its `call`'s literal, the one body that reads its fields.
	capture_records:    map[Type_Id]^Expr_Proc,
	// The names a capture literal reserves in its lowering scope, each with the
	// field it stands for and the `call` whose body may read it.
	capture_placeholders: map[Symbol_Id]Capture_Placeholder,
	// Carrier shapes (`src/carrier_shape.odin`), asked during provenance analysis after
	// every body is checked. Both are pure functions of the type graph.
	carrier_reach:      map[Type_Id]Carrier_Reach,
	reaches_destination: map[Type_Id]bool,
	reaches_mutable:    map[Type_Id]bool,
	provider_carriers:  map[Type_Id]bool,
	// The recursive region predicates of `src/provenance_regions.odin`.
	has_region:         map[Type_Id]bool,
	holds_allocator:    map[Type_Id]bool,
	view_reaches_provider: map[Type_Id]bool,
	carrier_shapes:     map[Type_Id][]Carrier_Path,
	// `type_may_hold_address`, asked of each literal element's type during emission.
	may_hold_address:   map[Type_Id]bool,
	// Per type, `region_field_shape` with every region empty.
	region_shapes:      map[Type_Id][]Prov_Region_Content,
	// Whether a map type's shape gives constant keys entries of their own.
	map_keyed:          map[Type_Id]bool,
	synth_procs:        [dynamic]Symbol_Id,
	// One constructor procedure per union variant used as a value.
	variant_constructors: map[Variant_Key]Symbol_Id,

	// Erased views (`src/erased.odin`). A witness is compilation-global, so it is
	// keyed and emitted once for the whole program.
	dyn_types:     map[string]Type_Id,
	// Per `dyn` type: the flattened slots, in witness order.
	dyn_slots:     map[Type_Id][]Interface_Slot,
	witnesses:     map[string]^Witness,
	witness_order: [dynamic]^Witness,
	interface_witnesses: map[Symbol_Id][dynamic]^Witness,
	// Per `dyn proc` type: the code word for a procedure the view holds.
	dyn_proc_adapters: map[Type_Id]Symbol_Id,

	// Materialised constants (`src/materialize.odin`): one read-only global per
	// constant that runtime indexing or slicing needs storage for, keyed by the
	// resolved symbol, which declaration cloning makes distinct per instance.
	materialized:       map[Materialized_Key]^Materialized,
	materialized_order: [dynamic]^Materialized,

	// The committed spawns (`src/parallel.odin`), whose frames and run
	// procedures the emitter reads (compiler-architecture.md "Lowering parallel
	// blocks").
	spawn_tasks: [dynamic]^Spawn_Task,
	// Each committed task's call on its worker, the one `run` makes.
	spawn_calls: map[^Expr_Call]^Spawn_Task,

	// Lifecycle classification (`src/hooks.odin`), cached per nominal type.
	lifecycles: map[Type_Id]^Lifecycle,
	// Above zero while `prepare_package` or `activate_when_items` runs: a file-scope
	// `impl` block may not be declared yet, so `lifecycle_of` keeps no answer.
	impls_declaring: int,
	// Attribute lists already validated, by the first attribute's position. A
	// body checked once per generic instance or static `foreach` element is a
	// clone with the same spans, and must not report its attributes again.
	validated_attributes: map[u64]bool,
	// What `check_copy_decision` has reported of each declaration, by the same key,
	// so instances of a generic procedure that fail alike report it once.
	reported_copy_failures: map[u64]bit_set[Copy_Failure],
	// A generic block's hook already reported, by its declaration's position, so
	// each of the record's instances does not report it again.
	reported_generic_hooks: map[u64]bool,
	// Final value snapshots consumed by emission; no lazy classification or
	// member selection is allowed through this interface.
	lifecycle_operations:       map[Type_Id]Lifecycle_Operations,
	lifecycle_operations_ready: bool,
	// Set by `finish_program_analysis` once every body is checked and the
	// whole-program provenance and provider analyses have run.
	program_analyzed: bool,
	// Allocating binding and assignment copies of the body being analysed,
	// reported once last-use transfer has settled which stay copies.
	held_copy_reports: [dynamic]Held_Copy_Report,
	// Under `-g`, the natvis rules emission wrote for the linker to put in the PDB.
	natvis:              string,
	// The type of `LOKE_LOG_LEVEL`, which `core:log` binds as `Level`.
	log_level_type:      Type_Id,
	// design.md "`type` and `typeid`": whether this program asked for runtime
	// metadata at all. The dense table is emitted only when it did.
	type_info_requested: bool,
	// Whether formatting needs the per-type dispatch table: requested by
	// core:fmt, a generated format method, or a formatted panic/assert.
	format_requested:    bool,
	// The ordinary Formattable witness recovered from an erased value's typeid.
	formatters:          map[Type_Id]^Witness,
	formatters_ready:    bool,
	// The `base:runtime` types the compiler needs to build that table, resolved
	// through the import that made them nameable so there is one identity.
	runtime_types:       map[string]Type_Id,

	// Every concrete procedure body that finished checking, in checking order. The
	// two provenance analyses run after the program settles, so a forward or
	// mutually recursive callee already has its result summary.
	checked_bodies: [dynamic]Checked_Body,
	// The procedures in `checked_bodies`, including inherent members whose
	// symbols have neither a literal nor a declaration.
	checked_body_symbols: map[Symbol_Id]bool,
	// Compile-time declaration metadata for cross-package checking; it does not
	// change the runtime ABI (design.md "Temporaries and procedure boundaries").
	// Keyed per declaration or instance, so two instances may differ.
	result_summaries: map[Symbol_Id]^Result_Provenance,
	// Per parameter, the regions of owners a body may leave in the storage that
	// argument names (design.md "Allocator regions and region provenance").
	written_summaries: map[Symbol_Id]Written_Summary,
	// Per parameter, what a body may store in the storage that argument names
	// out of what that same argument held (design.md "Values that contain
	// borrows").
	carrier_moves: map[Symbol_Id][]Carrier_Move,
	// Per parameter, a `thread_local` global whose borrow a body may leave in
	// the storage that argument names, or INVALID_SYMBOL (design.md "Borrows
	// crossing between tasks").
	thread_local_writes: map[Symbol_Id][]Symbol_Id,
	// What a body may leave in caller storage from its calls through the
	// callbacks it received, substituted at each call (`Callback_Write`).
	callback_thread_local_writes: map[Symbol_Id][]Callback_Write,
	// What a body's result may hold that a callback it received leaves in an
	// argument, substituted at each call (`Callback_Read`).
	callback_result_reads: map[Symbol_Id][]Callback_Read,
	// design.md "Global write effects": per call in a body, what a procedure
	// variable it calls through may hold, and what each procedure-valued
	// argument may be, as the write effects resolved them.
	called_values:   map[Call_Site][]Effect_Arg,
	argument_values: map[Call_Site][]Effect_Arg,
	// design.md "Borrowed callable views": a signature's contract with the view
	// as an added first parameter, both ways.
	receiver_contracts:   map[Symbol_Id]Symbol_Id,
	receiver_contract_of: map[Symbol_Id]Symbol_Id,
	proc_contract_checks: [dynamic]Proc_Contract_Check,
	// The contracts a conditional between two inferred callbacks joined.
	contract_joins: [dynamic]Symbol_Id,
	// Direct summary dependencies, discovered while building each body's first
	// provenance graph. The solver schedules only callers of a changed callee.
	result_summary_dependencies: map[Symbol_Id][]Symbol_Id,
	// design.md "Global write effects": the globals each body may write or read,
	// and what an indirect call may reach, settled before provenance runs.
	global_writes:       map[Symbol_Id][]Symbol_Id,
	indirect_writes:     map[Effect_Key][]Symbol_Id,
	global_reads:        map[Symbol_Id][]Symbol_Id,
	indirect_reads:      map[Effect_Key][]Symbol_Id,
	// Per body that calls a procedure value it received, its summaries apart
	// from that value, which each call substitutes; and the bodies an indirect
	// call may run, nil until there are bodies to choose from.
	callback_summaries:  map[Symbol_Id]^Callback_Summary,
	effect_unions:       map[Effect_Key][]int,
	global_writes_ready: bool,
	thread_spawns:       [dynamic]Thread_Spawn,
	// The bodies the write effects settled over, for the summaries after them.
	effect_program:      Effect_Program,
	// design.md "Globals while tasks run": per body, the globals whose stored
	// carriers it may reach and the allocator regions it may use; and what
	// every thread runs when it exits, a `thread_local` owner's drop. Settled
	// after the result summaries, while `thread_facts_pending`, and only when
	// `thread_summaries_wanted`: the pass costs a graph per body, so only a
	// program that a check reads them for pays for it.
	thread_summaries_wanted: bool,
	reach_effects:        map[Symbol_Id][]Global_Effect,
	allocator_uses:       map[Symbol_Id]Region_Set,
	thread_exit_drops:    []Thread_Exit_Drop,
	thread_facts_pending: bool,

	// Static-duration locals, in declaration order. They need module-level
	// storage, which cannot be written inside a function body, so the checker
	// records them and `emit_globals` walks the list.
	static_locals: [dynamic]Symbol_Id,

	// The `default_allocator` builtin.
	default_allocator_symbol: Symbol_Id,
	// design.md "Build-selected providers": the root package's selection,
	// resolved to one factory per slot. An unselected slot keeps the runtime's
	// fallback.
	providers:                [Provider_Slot]Provider_Selection,
	// `runtime.Memory_Order`, found by name on first use (`src/atomics.odin`).
	memory_order_type:        Type_Id,
	// design.md "Shared ownership": the two record templates the universe names
	// `Shared` and `Weak` bind to, and the procedure group `shared` names.
	shared_symbol:            Symbol_Id,
	weak_symbol:              Symbol_Id,
	shared_construct_symbol:  Symbol_Id,
	try_shared_symbol:        Symbol_Id,
	// The one call expression the compiler installs as the omitted allocator
	// argument of every lifecycle hook.
	default_allocator_arg:    Expr,
	// An explicitly dropped owner is dead and no longer blocks reset (design.md
	// "Allocators"). Liveness answers that a pass earlier than the reset check, so the dead owners
	// at each call or cleanup are recorded here (`src/lifecycle.odin`, `src/cfg.odin`).
	reset_dead:               map[Reset_Key]Reset_Liveness,
	cleanup_reset_dead:       map[Reset_Key]Reset_Liveness,
	// Compilation-lifetime semantic storage.
	semantic_initialized: bool,
	semantic_arena:       virtual.Arena,
	semantic_allocator:   mem.Allocator,
	// Per-procedure ownership-analysis scratch, reserved once and reset after
	// each body. Nothing built in it outlives `analyze_ownership`.
	analysis_arena:       Scratch_Arena,
	// The provenance fixed point's carried facts and each round's graph
	// (`build_provenance_replay`), reset after each body like the analysis arena.
	replay_carry_arena:   Scratch_Arena,
	replay_round_arena:   Scratch_Arena,
	provenance_stats: Prov_Replay_Statistics,
	analysis_allocator:   mem.Allocator,
	// Everything LLVM emission and the toolchain allocate: the backend builds its
	// module from many short-lived strings and frees none of them individually.
	emission_arena:       virtual.Arena,
	identifier_names:     [dynamic]string,
	identifier_by_name:   map[string]Identifier_Id,
	// One allocation per entry, so the pointer `type_of` or `symbol_of` returns
	// stays valid while checking interns more types and symbols.
	types:                [dynamic]^Type_Info,
	type_by_shape:        map[Type_Key]Type_Id,
	// Anonymous record types, bucketed by a hash of their ordered field vector.
	// The hash only picks a bucket; identity is settled by comparing every
	// `(name, type)` pair, so a collision costs a walk and never a wrong reuse.
	anon_record_types:    map[u64][]Type_Id,
	// Anonymous union types, bucketed the same way by their ordered
	// `(label, payload)` vector.
	anon_union_types:     map[u64][]Type_Id,
	// Procedure types, bucketed the same way by parameters, modes, and result.
	proc_types:           map[u64][]Type_Id,
	symbols:              [dynamic]^Symbol,
	packages:             [dynamic]^Package,
}

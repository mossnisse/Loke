// Source manager and diagnostics engine.
//
// Every later phase reports through here; every AST node carries a Span back
// to it. Diagnostics accumulate — nothing in the compiler aborts on the first
// error.
package lokec

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

// A byte range in one loaded file. Line and column are derived at render time,
// so nothing upstream has to carry them.
Span :: struct {
	file: u32,
	lo:   u32,
	hi:   u32,
}

// Span for a diagnostic that belongs to no particular source location, such as
// a missing file on the command line.
NO_FILE :: max(u32)

no_span :: proc() -> Span {
	return Span{file = NO_FILE}
}

Source :: struct {
	path:        string,
	text:        string,
	// Non-empty only for process-allocated text. Incremental source text lives in
	// the checkpointed arena; tests may register string literals directly.
	owned_text:  []u8,
	line_starts: []u32, // byte offset of the first character of each line
	// Every comment, in source order, as the lexer last found them: a `//`
	// comment without its line ending, a block comment through its `*/`. The
	// token stream leaves them out; the formatter, the documentation
	// generator, and hover read them here, by span.
	comments:    [dynamic]Span,
}

Source_Overlay :: struct {
	key:  string,
	path: string, // absolute, cleaned path; the map key is case-insensitive
	text: string,
}

Severity :: enum {
	Error,
	Warning,
}

Note :: struct {
	span:    Span, // NO_FILE for a note with no location
	message: string,
}

Diagnostic :: struct {
	severity: Severity,
	code:     string, // stable, e.g. "L0104"
	span:     Span,
	message:  string,
	label:    string, // short text printed after the caret; may be empty
	notes:    [dynamic]Note,
}

// Compiler-wide state. Named `Compiler` rather than `Context` because `context`
// is an Odin keyword.
//
// Batch source buffers and diagnostics use the process allocator and each File
// owns its syntax arena. Incremental inputs/syntax/diagnostics join identifiers,
// types, symbols, scopes, and packages in the checkpointed semantic arena.
Compiler :: struct {
	// Opt-in session package checkpoints; nil for ordinary batch compilations.
	package_cache: ^Package_Check_Cache,
	sources:     [dynamic]Source,
	// The session's overlays; read through `compiler_overlays`. Loaded buffers
	// are copied so an overlay edit cannot alter a compilation being consumed.
	source_overlays: ^map[string]Source_Overlay,
	diagnostics: [dynamic]Diagnostic,
	error_count: int,
	// What a body checked on demand for compile-time execution reported
	// (`ensure_proc_typed_for_eval`). That body is settled and never checked
	// again, so a speculative check that led to it and then rolls its
	// diagnostics back must not take these along; they rejoin the list when
	// checking ends (`release_held_diagnostics`).
	held_diagnostics: [dynamic]Diagnostic,

	// While a capture literal's body is cloned into its record's `call`: the
	// captured names, which the clone rewrites to the receiver's fields
	// (`ast_clone.odin`). Nil for every other clone.
	capture_rewrite: ^Capture_Rewrite,

	// Hypothetical checks (overload bounds and interface requirements) may use
	// the ordinary checker, but must not enroll backend artifacts in the final
	// module. Nested checks share this counter so every registry has one gate.
	speculation_depth: int,
	// How many `begin_commit`s have run, so a probe can tell its own enrollment
	// from a sanctioned commit inside it.
	commits:           int,

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
	// Every parsed file, so one `destroy_compilation` frees the lot.
	parsed_files:   [dynamic]^File,

	// Generics (`src/generic.odin`). `instances` is the positive/negative
	// specialization cache, keyed by (declaration symbol, canonical argument
	// vector); the stack and unique-entry count enforce the documented ceiling.
	generic_templates:     map[Symbol_Id]^Generic_Template,
	generic_impls:         map[Symbol_Id][dynamic]^Generic_Impl,
	instances:             map[string]^Instance,
	procedure_instances:   map[Symbol_Id]^Instance,
	instantiation_stack:   [dynamic]Instantiation_Frame,
	instantiation_count:   int,
	instantiation_limit_hit: bool,
	// The diagnostic that already carries the instantiation stack, so unwinding
	// a deep instantiation does not attach it once per level.
	last_noted_diagnostic: int,
	pending_impl_instances: [dynamic]Pending_Impl,

	// Interface declarations (`src/interface.odin`), keyed by their symbol.
	interfaces:            map[Symbol_Id]^Interface_Info,
	// Checked map key operations, keyed by the underlying key type. Consumers
	// must use these IDs rather than selecting members again.
	map_key_policies:      map[Type_Id]Key_Policy,
	// The `<` one `sort` uses, per element type (`src/container.odin`).
	order_policies:        map[Type_Id]Order_Policy,

	// Compile-time reflection (`src/reflect.odin`). The descriptor types are
	// created on first use; `typeid` identity is symbolic during checking and
	// numeric only after `freeze_typeids`.
	meta_field_type:      Type_Id,
	meta_enum_value_type: Type_Id,
	// The two local region providers (`src/region.odin`), created on first use.
	arena_type:           Type_Id,
	scratch_type:         Type_Id,
	// `mem.Failure_Policy`, and the `.Panic` its constructors default to.
	failure_policy_type:  Type_Id,
	panic_policy_arg:     Expr,
	// design.md "Typed fallibility": the three `base:runtime` declarations the
	// compiler bootstraps and binds into the universe. `Unit` is a type; the
	// other two are generic templates instantiated through `src/bootstrap.odin`.
	universe:             ^Scope,
	unit_type:            Type_Id,
	option_symbol:        Symbol_Id,
	// `Result(Unit, Allocator_Error)`, instantiated once at bootstrap: every
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
	item_states:        map[Item_Key]Item_State,
	// design.md "Capture literals": the records capture literals lower to,
	// each with its `call`'s literal, the one body that reads its fields.
	capture_records:    map[Type_Id]^Expr_Proc,
	// The names a capture literal reserves in its lowering scope, each with the
	// field it stands for and the `call` whose body may read it.
	capture_placeholders: map[Symbol_Id]Capture_Placeholder,
	// Carrier shapes (`src/borrow.odin`), asked during provenance analysis after
	// every body is checked. Both are pure functions of the type graph.
	carrier_reach:      map[Type_Id]Carrier_Reach,
	carrier_shapes:     map[Type_Id][]Carrier_Path,
	// Whether a map type's shape gives constant keys entries of their own.
	map_keyed:          map[Type_Id]bool,
	synth_procs:        [dynamic]Symbol_Id,
	// One constructor procedure per union variant used as a value.
	variant_constructors: map[Variant_Key]Symbol_Id,

	// Erased views (`src/erased.odin`). A witness is compilation-global, so it is
	// keyed and emitted once for the whole program.
	dyn_types:     map[string]Type_Id,
	witnesses:     map[string]^Witness,
	witness_order: [dynamic]^Witness,
	// Per `dyn proc` type: the code word for a procedure the view holds.
	dyn_proc_adapters: map[Type_Id]Symbol_Id,

	// Materialised constants (`src/materialize.odin`): one read-only global per
	// constant that runtime indexing or slicing needs storage for, keyed by the
	// resolved symbol, which declaration cloning makes distinct per instance.
	materialized:       map[Symbol_Id]^Materialized,
	materialized_order: [dynamic]^Materialized,

	// Lifecycle classification (`src/hooks.odin`), cached per nominal type.
	lifecycles: map[Type_Id]^Lifecycle,
	// Attribute lists already validated, by the first attribute's position. A
	// body checked once per generic instance or static `foreach` element is a
	// clone with the same spans, and must not report its attributes again.
	validated_attributes: map[u64]bool,
	// Final value snapshots consumed by emission; no lazy classification or
	// member selection is allowed through this interface.
	lifecycle_operations:       map[Type_Id]Lifecycle_Operations,
	lifecycle_operations_ready: bool,
	// Set by `finish_program_analysis` once every body is checked and the
	// whole-program provenance and provider analyses have run.
	program_analyzed: bool,
	// An option rather than a rule, because it is target-specific and not part of
	// the language (design.md "Copy-cost diagnostics"). A copy site reports when it
	// duplicates at least this many inline bytes, or when its clone may allocate.
	copy_cost_threshold: u64,
	copy_cost_enabled:   bool,
	// Allocating binding and assignment copies of the body being analysed,
	// reported once last-use transfer has settled which stay copies.
	held_copy_reports: [dynamic]Held_Copy_Report,
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
	// `-g`: emit debug information (`emit_llvm_debug.odin`).
	debug_info:          bool,
	// Under `-g`, the natvis rules emission wrote for the linker to put in the PDB.
	natvis:              string,
	// `-debug`, the value `LOKE_DEBUG` is predeclared with.
	debug:               bool,
	// The build-configuration enum types, synthesized once and shared by the
	// `LOKE_*` universe constants and their `base:runtime` bindings.
	build_config:        Build_Config,
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
	// Compile-time declaration metadata for cross-package checking; it does not
	// change the runtime ABI (design.md "Temporaries and procedure boundaries").
	// Keyed per declaration or instance, so two instances may differ.
	result_summaries: map[Symbol_Id]^Proc_Summary,
	// Per parameter, the regions of owners a body may leave in the storage that
	// argument names (design.md "Allocator regions and region provenance").
	written_regions: map[Symbol_Id][]Region_Set,
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
	// design.md "Global write effects": the globals each body may write, and what
	// an indirect call may reach, settled before provenance runs.
	global_writes:       map[Symbol_Id][]Symbol_Id,
	indirect_writes:     map[string][]Symbol_Id,
	global_writes_ready: bool,
	thread_spawns:       [dynamic]Thread_Spawn,

	// Static-duration locals, in declaration order. They need module-level
	// storage, which cannot be written inside a function body, so the checker
	// records them and `emit_globals` walks the list.
	static_locals: [dynamic]Symbol_Id,

	// The `default_allocator` builtin, and the one call expression the compiler
	// installs as the omitted allocator argument of every lifecycle hook. M6
	// replaces it with the design's written `= mem.default_allocator()`.
	default_allocator_symbol: Symbol_Id,
	// design.md "Build-selected providers": the root package's selection,
	// resolved to one factory per slot. An unselected slot keeps the runtime's
	// fallback.
	providers:                [Provider_Slot]Provider_Selection,
	// `-log-level`, the value `LOKE_LOG_LEVEL` is predeclared with.
	log_level:                Log_Level,
	// design.md "Iteration protocol": the three `Yield` descriptor types, in
	// `Yield_Kind` order, bound with the rest of the runtime bootstrap.
	// `runtime.Memory_Order`, found by name on first use (`src/atomics.odin`).
	memory_order_type:        Type_Id,
	// design.md "Shared ownership": the two record templates the universe names
	// `shared` and `weak` bind to, and the procedure group `shared(value)` means.
	shared_symbol:            Symbol_Id,
	weak_symbol:              Symbol_Id,
	shared_construct_symbol:  Symbol_Id,
	try_shared_symbol:        Symbol_Id,
	default_allocator_arg:    Expr,
	// The constant `0` a defaulted container `shrink` floor uses.
	zero_int_arg:             Expr,
	// An explicitly dropped owner is dead and no longer blocks reset (design.md).
	// Liveness answers that a pass earlier than the reset check, so the dead owners
	// at each call or cleanup are recorded here (`src/lifecycle.odin`, `src/cfg.odin`).
	reset_dead:               map[Reset_Key]Reset_Liveness,
	cleanup_reset_dead:       map[Reset_Key]Reset_Liveness,
	// Compilation-lifetime semantic storage. Parser ASTs remain per-file arenas.
	semantic_initialized: bool,
	semantic_arena:       virtual.Arena,
	semantic_allocator:   mem.Allocator,
	// Per-procedure ownership-analysis scratch, reserved once and reset after
	// each body. Nothing built in it outlives `analyze_ownership`.
	analysis_arena:       virtual.Arena,
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
	// Procedure types, bucketed the same way by parameters, modes, and result.
	proc_types:           map[u64][]Type_Id,
	symbols:              [dynamic]^Symbol,
	packages:             [dynamic]Package,
}

// Loads a file and registers it, reporting the failure itself.
load_source :: proc(c: ^Compiler, path: string) -> (index: u32, ok: bool) {
	init_semantic_stores(c)
	data: []u8
	read_ok: bool
	if overlays := compiler_overlays(c); len(overlays) > 0 {
		if overlay, found := overlays[dir_key(canonical_dir(path))]; found {
			data, read_ok = transmute([]u8)strings.clone(overlay.text), true
		}
	}
	if !read_ok {
		read_err: os.Error
		data, read_err = os.read_entire_file(path, context.allocator)
		read_ok = read_err == nil
	}
	if !read_ok {
		errorf(c, no_span(), "L0001", "cannot read file `%s`", path)
		return 0, false
	}

	text := string(data)
	// grammar.md: a source file is UTF-8 *without* a BOM.
	if strings.has_prefix(text, "\xef\xbb\xbf") {
		errorf(c, no_span(), "L0002", "`%s` starts with a UTF-8 byte order mark", path)
		delete(data)
		return 0, false
	}

	if c.package_cache != nil {
		// A checkpoint owns source bytes along with syntax and semantic state.
		text = strings.clone(text, c.semantic_allocator)
		delete(data)
		data = nil
	}
	index = add_source(c, path, text, data)
	if valid, bad_offset := valid_utf8(text); !valid {
		errorf(
			c,
			Span{file = index, lo = bad_offset, hi = bad_offset + 1},
			"L0003",
			"source is not valid UTF-8",
		)
		return index, false
	}
	return index, true
}

// A diagnostic names a file relative to the working directory when it lies
// under it, and with `/` however the loader reached it, so a directory's files
// read like a file given on the command line.
display_path :: proc(path: string) -> string {
	shown := path
	if filepath.is_abs(path) {
		cwd := os.get_working_directory(context.temp_allocator) or_else ""
		if relative, err := filepath.rel(cwd, path, context.temp_allocator); err == nil && !strings.has_prefix(relative, "..") {
			shown = relative
		}
	}
	slashed, _ := strings.replace_all(shown, "\\", "/", context.temp_allocator)
	return slashed
}

// Registers source text; `owned` is freed with the compilation.
add_source :: proc(c: ^Compiler, path, text: string, owned: []u8 = nil) -> u32 {
	context.allocator = c.semantic_allocator if c.package_cache != nil else context.allocator
	starts := make([dynamic]u32)
	append(&starts, 0)
	for i := 0; i < len(text); i += 1 {
		if text[i] == '\n' {
			append(&starts, u32(i + 1))
		}
	}
	append(&c.sources, Source{path = path, text = text, owned_text = owned, line_starts = starts[:], comments = make([dynamic]Span)})
	return u32(len(c.sources) - 1)
}

valid_utf8 :: proc(text: string) -> (valid: bool, bad_offset: u32) {
	for i := 0; i < len(text); {
		r, width := utf8.decode_rune_in_string(text[i:])
		if r == utf8.RUNE_ERROR && width == 1 && text[i] >= utf8.RUNE_SELF {
			return false, u32(i)
		}
		i += width
	}
	return true, 0
}

// 1-based line and column of a byte offset. The column counts bytes, which is
// exact for Loke: everything outside literals and comments is ASCII.
line_col :: proc(src: ^Source, offset: u32) -> (line: int, col: int) {
	i, found := slice.binary_search(src.line_starts, offset)
	if !found {
		i -= 1
	}
	return i + 1, int(offset-src.line_starts[i]) + 1
}

@(private = "file")
line_text :: proc(src: ^Source, line: int) -> string {
	start := src.line_starts[line - 1]
	end := u32(len(src.text))
	if line < len(src.line_starts) {
		end = src.line_starts[line]
	}
	return strings.trim_right(src.text[start:end], "\r\n")
}

// Diagnostics are raised in every phase, including emission, whose context
// allocator is an arena. Pinning one allocator — the list's own — keeps a
// diagnostic from being freed with an allocator that did not hand it out.
diagnostic_allocator :: proc(c: ^Compiler) -> mem.Allocator {
	if c.diagnostics.allocator.procedure == nil {
		c.diagnostics.allocator = context.allocator
	}
	return c.diagnostics.allocator
}

@(private = "file")
append_diagnostic :: proc(
	c: ^Compiler,
	severity: Severity,
	span: Span,
	code: string,
	format: string,
	args: ..any,
) {
	context.allocator = diagnostic_allocator(c)
	append(
		&c.diagnostics,
		Diagnostic {
			severity = severity,
			code = code,
			span = span,
			message = fmt.aprintf(format, ..args),
		},
	)
}

errorf :: proc(c: ^Compiler, span: Span, code: string, format: string, args: ..any) {
	append_diagnostic(c, .Error, span, code, format, ..args)
	c.error_count += 1
}

// A diagnostic that does not fail the compilation. design.md keeps size out of
// type correctness — size is never a type error — so the copy-cost report is a
// warning and leaves `error_count` alone.
warnf :: proc(c: ^Compiler, span: Span, code: string, format: string, args: ..any) {
	append_diagnostic(c, .Warning, span, code, format, ..args)
}

// Same as `errorf` but with a short label printed under the caret.
error_labelf :: proc(
	c: ^Compiler,
	span: Span,
	code: string,
	label: string,
	format: string,
	args: ..any,
) {
	errorf(c, span, code, format, ..args)
	// A label is either source-backed or a temporary, so clone it for one owner.
	c.diagnostics[len(c.diagnostics) - 1].label = strings.clone(label, diagnostic_allocator(c))
}

// Attaches a secondary location to the most recently emitted diagnostic.
// Keeping the Span makes cross-file duplicate/cycle diagnostics durable.
add_notef :: proc(c: ^Compiler, span: Span, format: string, args: ..any) {
	if len(c.diagnostics) == 0 {
		return
	}
	context.allocator = diagnostic_allocator(c)
	diagnostic := &c.diagnostics[len(c.diagnostics) - 1]
	append(&diagnostic.notes, Note{span = span, message = fmt.aprintf(format, ..args)})
}

// Resizing the list alone would lose the owned strings and note arrays past the
// new length, so a dropped diagnostic is freed through here.
destroy_diagnostic :: proc(c: ^Compiler, d: ^Diagnostic) {
	context.allocator = diagnostic_allocator(c)
	delete(d.message)
	if d.label != "" {
		delete(d.label)
	}
	for &note in d.notes {
		delete(note.message)
	}
	delete(d.notes)
	d^ = {}
}

// Rolls the list back to `length`, undoing the `error_count` the dropped errors
// raised: a speculative check that reports and then rolls back must leave the
// compilation exactly as it found it.
truncate_diagnostics :: proc(c: ^Compiler, length: int) {
	wanted := clamp(length, 0, len(c.diagnostics))
	for index := wanted; index < len(c.diagnostics); index += 1 {
		if c.diagnostics[index].severity == .Error {
			c.error_count -= 1
		}
		destroy_diagnostic(c, &c.diagnostics[index])
	}
	resize(&c.diagnostics, wanted)
	// An instantiation stack is remembered by the length that attached it, so a
	// rollback past that point must let the next diagnostic claim its own frames.
	c.last_noted_diagnostic = min(c.last_noted_diagnostic, wanted)
}

// A hypothetical check (compiler-architecture.md "Checking and overload
// resolution"): `begin_probe` raises `speculation_depth` and marks the
// diagnostics, and `end_probe` rolls them back, unless `keep`, before lowering
// the depth again, so a rollback never happens outside speculation. A probe
// that grew the emission registries without a `begin_commit` skipped the
// `committing(c)` gate somewhere, and fails here.
Probe :: struct {
	diagnostics, depth, commits: int,
	registries:                  Emission_Registries,
}

// The sizes of the registries emission reads.
Emission_Registries :: struct {
	typeids, typeid_order, witnesses, witness_order: int,
	materialized, materialized_order:                int,
	instances, checked_bodies, static_locals:        int,
	synth_procs:                                     int,
	format_requested, type_info_requested:           bool,
}

emission_registries :: proc(c: ^Compiler) -> Emission_Registries {
	r := Emission_Registries {
		typeids             = len(c.typeid_requested),
		typeid_order        = len(c.typeid_order),
		witnesses           = len(c.witnesses),
		witness_order       = len(c.witness_order),
		materialized        = len(c.materialized),
		materialized_order  = len(c.materialized_order),
		checked_bodies      = len(c.checked_bodies),
		static_locals       = len(c.static_locals),
		synth_procs         = len(c.synth_procs),
		format_requested    = c.format_requested,
		type_info_requested = c.type_info_requested,
	}
	for pkg in c.packages { r.instances += len(pkg.instances) }
	return r
}

begin_probe :: proc(c: ^Compiler) -> Probe {
	c.speculation_depth += 1
	return Probe {
		diagnostics = len(c.diagnostics),
		depth       = c.speculation_depth,
		commits     = c.commits,
		registries  = emission_registries(c),
	}
}

end_probe :: proc(c: ^Compiler, probe: Probe, keep := false) {
	assert(c.speculation_depth == probe.depth, "a probe ended out of order")
	assert(c.commits != probe.commits || emission_registries(c) == probe.registries,
	       "a probe enrolled emission state without asking committing(c)")
	if !keep {
		truncate_diagnostics(c, probe.diagnostics)
	}
	c.speculation_depth -= 1
}

// Whether what the checker finds now belongs to the program. Outside every
// probe it does; inside one, its diagnostics may be rolled back and its
// candidate discarded, so nothing is enrolled for emission, no answer is cached
// with a diagnostic, and nothing written is left for the backend to read. Every
// such write asks this, and nothing else reads `speculation_depth`.
committing :: proc(c: ^Compiler) -> bool {
	return c.speculation_depth == 0
}

// The one sanctioned commit from inside a probe: `ensure_proc_typed_for_eval`
// checks a body compile-time evaluation will execute, which is a real use.
begin_commit :: proc(c: ^Compiler) -> (saved: int) {
	saved = c.speculation_depth
	c.speculation_depth = 0
	c.commits += 1
	return
}

end_commit :: proc(c: ^Compiler, saved: int) {
	c.speculation_depth = saved
}

// Moves every diagnostic past `length`, with its share of `error_count`, out of
// `truncate_diagnostics`' reach until `release_held_diagnostics`.
// Whether an error was reported since `mark`, a length of `c.diagnostics`.
// Diagnostics a nested check held aside belong to that check.
errors_since :: proc(c: ^Compiler, mark: int) -> bool {
	for d in c.diagnostics[clamp(mark, 0, len(c.diagnostics)):] {
		if d.severity == .Error { return true }
	}
	return false
}

hold_diagnostics :: proc(c: ^Compiler, length: int) {
	wanted := clamp(length, 0, len(c.diagnostics))
	if wanted == len(c.diagnostics) {
		return
	}
	context.allocator = diagnostic_allocator(c)
	for index in wanted ..< len(c.diagnostics) {
		if c.diagnostics[index].severity == .Error {
			c.error_count -= 1
		}
		append(&c.held_diagnostics, c.diagnostics[index])
	}
	resize(&c.diagnostics, wanted)
	c.last_noted_diagnostic = min(c.last_noted_diagnostic, wanted)
}

release_held_diagnostics :: proc(c: ^Compiler) {
	context.allocator = diagnostic_allocator(c)
	for d in c.held_diagnostics {
		append(&c.diagnostics, d)
		if d.severity == .Error {
			c.error_count += 1
		}
	}
	clear(&c.held_diagnostics)
}

// Renders every accumulated diagnostic to stderr. The two provenance analyses
// run after the whole program is checked, so their diagnostics arrive last; a
// stable sort by position restores one reading order.
report :: proc(c: ^Compiler) {
	release_held_diagnostics(c)
	slice.stable_sort_by(c.diagnostics[:], proc(a, b: Diagnostic) -> bool {
		if a.span.file != b.span.file {
			return a.span.file < b.span.file
		}
		return a.span.lo < b.span.lo
	})
	previous: ^Diagnostic
	reported_notes: [dynamic]Note
	defer delete(reported_notes)
	for &d in c.diagnostics {
		// One mistake reported twice is one diagnostic: two blocks left open by the
		// same missing brace both run out of input at the same span. A repeated
		// generic error contributes its new context without repeating the cause.
		if previous != nil && same_diagnostic(previous^, d) {
			for note in d.notes {
				if !slice.contains(reported_notes[:], note) {
					render_note(c, note)
					append(&reported_notes, note)
				}
			}
			continue
		}
		if previous != nil { fmt.eprintln() }
		render(c, &d)
		previous = &d
		clear(&reported_notes)
		append(&reported_notes, ..d.notes[:])
	}
	if previous != nil { fmt.eprintln() }
}

@(private = "file")
same_diagnostic :: proc(a, b: Diagnostic) -> bool {
	return a.severity == b.severity &&
		a.code == b.code &&
		a.span == b.span &&
		a.label == b.label &&
		a.message == b.message
}

// The length of `line` without a trailing `//` comment or the blanks before
// it. Quotes are skipped, so a `//` inside a string or rune literal stays code.
code_end :: proc(line: string) -> int {
	quote: u8 = 0
	for i := 0; i < len(line); i += 1 {
		ch := line[i]
		switch {
		case quote != 0 && ch == '\\' && quote != '`':
			i += 1
		case quote != 0:
			if ch == quote { quote = 0 }
		case ch == '"' || ch == '\'' || ch == '`':
			quote = ch
		case ch == '/' && i + 1 < len(line) && line[i + 1] == '/':
			return len(strings.trim_right_space(line[:i]))
		}
	}
	return len(line)
}

@(private = "file")
render :: proc(c: ^Compiler, d: ^Diagnostic) {
	severity := d.severity == .Error ? "error" : "warning"
	fmt.eprintf("%s[%s]: %s\n", severity, d.code, d.message)

	if d.span.file != NO_FILE && int(d.span.file) < len(c.sources) {
		src := &c.sources[d.span.file]
		line, col := line_col(src, d.span.lo)
		text := line_text(src, line)
		gutter := len(fmt.tprintf("%d", line))

		// The snippet drops the line ending, so a span pointing into it lands past
		// the text; a multi-line span only marks where it starts. Both stay inside.
		// A trailing comment is not part of what it marks.
		col = min(col, len(text) + 1)
		width := max(int(d.span.hi) - int(d.span.lo), 1)
		width = min(width, max(code_end(text)-col+1, 1))

		// The caret line keeps the prefix's tabs, so the marker stays under the
		// right column whatever the reader's tab width is.
		indent := strings.clone(text[:col - 1], context.temp_allocator)
		for i in 0 ..< len(indent) {
			if indent[i] != '\t' {
				(transmute([]u8)indent)[i] = ' '
			}
		}

		fmt.eprintf("%*s--> %s:%d:%d\n", gutter, "", display_path(src.path), line, col)
		fmt.eprintf("%*s |\n", gutter + 1, "")
		// Diagnostics are text, so a line that is not valid UTF-8, which L0003
		// reports, shows each run of bad bytes as one U+FFFD rather than echoing it.
		fmt.eprintf("%d | %s\n", line, strings.to_valid_utf8(text, "�", context.temp_allocator))
		fmt.eprintf("%*s | %s%s", gutter + 1, "", indent, strings.repeat("^", width, context.temp_allocator))
		if d.label != "" {
			fmt.eprintf(" %s", d.label)
		}
		fmt.eprintln()
	}

	for note in d.notes {
		render_note(c, note)
	}
}

@(private = "file")
render_note :: proc(c: ^Compiler, note: Note) {
	if note.span.file != NO_FILE && int(note.span.file) < len(c.sources) {
		src := &c.sources[note.span.file]
		line, col := line_col(src, note.span.lo)
		fmt.eprintf("  = note: %s:%d:%d: %s\n", display_path(src.path), line, col, note.message)
	} else {
		fmt.eprintf("  = note: %s\n", note.message)
	}
}

// Backend (compiler-plan B16/B17): typed AST straight to textual LLVM IR
// (decision A5), then `clang` to object-and-link in one step.
//
// There is no MIR here on purpose — B13 arrives at M6, and keeping codegen to
// this one file is what makes it replaceable then.
//
// Every local is an alloca plus load/store: LLVM's mem2reg builds the SSA form,
// so this file constructs a phi node only where a value genuinely joins two
// paths it created itself.
package lokec

import "core:fmt"
import "core:os"
import "core:path/filepath"
import os2 "core:os/os2"
import "core:slice"
import "core:strconv"
import "core:strings"

@(private = "file")
// One registered cleanup action. design.md gives explicit `defer` and the
// implicit drop of a managed local one reverse registration order, so they share
// one entry and one stack rather than the second mechanism a parallel list would
// be (m5a-plan decision "Drop/defer ordering").
//
// `flag` is empty when the CFG proved the slot reached unconditionally: no
// source or ABI rule requires a flag, so a definite state does not get one.
Deferred :: struct {
	flag: string,
	// A written `defer`, or nil for an implicit drop of `place`.
	stmt:  Stmt,
	place: string,
	// The local whose storage `place` is. A cleanup thunk reaches it through the
	// env rather than by name, so the symbol travels with the entry.
	place_symbol: Symbol_Id,
	type:  Type_Id,
	// A compiler-owned variadic buffer uses one cleanup action with per-element
	// flags. The three env indices let the unwind thunk reach its dynamic buffer,
	// flag array, and runtime count; the direct names serve normal cleanup.
	array_cleanup:  bool,
	array_buffer:   string,
	array_flags:    string,
	array_count:    string,
	array_buffer_env: int,
	array_flags_env:  int,
	array_count_env:  int,
	// This action's index in the procedure's runtime registration state, or -1
	// when the procedure registers no frame at all (`-panic=abort`).
	slot: int,
}

// One procedure's runtime-visible cleanup registration (m6a-plan decision
// "Logical panic unwind").
//
// design.md gives a panic no way to resume, so the runtime never unwinds the
// native stack: it calls back into each still-live frame through a generated
// thunk. What that thunk needs is the frame's *state* — which actions are
// currently registered, and where their storage is — so every procedure that
// owns a cleanup carries two arrays and pushes a `{previous, thunk, context}`
// record.
//
// The arrays are separate allocas rather than fields of one record because
// their lengths are only known once the whole body has been emitted, and a
// `getelementptr` over `i8`/`ptr` needs no length in its type.
Unwind_State :: struct {
	// `[live x i1]`: whether action `i` is registered right now. Set only after
	// the action is fully registered, cleared before normal control flow runs it.
	live: string,
	// `[env x ptr]`: the storage each replayed action addresses. A cleanup thunk
	// is a separate function, so it cannot name the parent's allocas directly.
	env:   string,
	frame: string, // the `{previous, cleanup, context}` record this frame pushes
	ctx:   string, // `[2 x ptr]` = {live, env}, the thunk's one argument
	thunk: string,
	// Every action, in source order. A live action's registration point is
	// always lexically before any later-registered live one — an inner scope's
	// actions are cleared when it exits — so replaying by descending index is
	// replaying in reverse registration order.
	actions: [dynamic]Deferred,
	// Env index per local symbol whose address a cleanup may need.
	env_index: map[Symbol_Id]int,
	env_count: int,
	// The registration slot of a managed local's implicit drop, and of a written
	// `defer`, so `move`/`drop` and a re-entered scope can clear the same
	// registration the existing drop flags clear.
	slot_by_symbol: map[Symbol_Id]int,
	slot_by_defer:  map[int]int,
	// True while the thunk itself is being emitted, so replayed code does not
	// register a second time into the state it is replaying.
	replaying: bool,
}

@(private = "file")
Cleanup_Scope :: struct {
	entries: [dynamic]Deferred,
}

@(private = "file")
Emitter :: struct {
	c:    ^Compiler,
	b:    strings.Builder,
	next: int, // temporary and unique-name counter
	failed: bool,
	// Backend names are an emitter concern. Semantic symbols remain reusable by
	// MIR, interpreters, and multiple backend invocations.
	names:        map[Symbol_Id]string,
	struct_names: map[Type_Id]string,

	// Whether the block being appended to already ends in a terminator. LLVM
	// rejects both a block without one and an instruction after one.
	terminated: bool,

	// Current procedure.
	result_types: []Type_Id,
	result_slots: []string,
	// Which results were declared `inout`. Such a result is returned as the
	// address of a place, which is what makes `grid[i] = v` an ordinary store.
	result_inout: []bool,
	defer_flags:  []string,
	cleanups:     [dynamic]Cleanup_Scope,
	break_label:    string,
	continue_label: string,
	break_depth:    int,
	continue_depth: int,
	// Parameter values already bound at the call site being emitted, so a
	// default expression that names a parameter to its left reads that value.
	param_values: map[Symbol_Id]string,

	// The current procedure's panic-cleanup registration, and the functions
	// generated to replay it. Both are empty under `-panic=abort`.
	unwind: Unwind_State,
	pending: [dynamic]string,
	// Generated formatter thunks, flushed once at the end of the module: each is
	// a function, and a function cannot be defined inside another.
	pending_thunks: [dynamic]string,
	// The writer and options records a `format_any` call spilled, so a nested
	// dispatch names the same storage.
	fmt_writer:  string,
	fmt_options: string,
	// One operation table per concrete container type, keyed by that type so a
	// `[dynamic]int` reached from ten places shares one table and one set of
	// element thunks (m6b-plan decision "Container runtime boundary").
	container_ops: map[Type_Id]string,
	// The element and key thunks those tables point at, keyed by generated name:
	// one part type reached from two container types is one thunk.
	container_thunks: map[string]bool,
	// Interned C string constants (panic messages), keyed by content so one
	// message is one global, plus the module-scope definitions they need.
	messages: map[string]string,
	// Static literal storage, keyed by content so one literal is one global.
	literals: map[string]string,
	globals:  [dynamic]string,
}

emit_package :: proc(c: ^Compiler, package_id: Package_Id, opts: Options) -> int {
	module, generated := emit_llvm_module(c, package_id)
	if !generated {
		return 2
	}
	ll_path := replace_ext(opts.output, ".ll")
	if !os.write_entire_file(ll_path, transmute([]u8)module) {
		errorf(c, no_span(), "L0401", "cannot write `%s`", ll_path)
		return 2
	}
	if opts.emit_ll {
		fmt.printfln("wrote %s", ll_path)
		return 0
	}
	defer if !opts.keep_temps {
		os.remove(ll_path)
	}

	return link(c, ll_path, opts.output, opts)
}

// Pure module generation boundary: lowering and LLVM serialization consume the
// checked compilation and return bytes in memory. Filesystem policy and the
// external toolchain remain in `emit_package` above.
emit_llvm_module :: proc(c: ^Compiler, package_id: Package_Id) -> (string, bool) {
	pkg := package_of(c, package_id)
	if pkg == nil {
		errorf(c, no_span(), "L0404", "cannot emit an unknown package")
		return "", false
	}
	e := Emitter {
		c            = c,
		names        = make(map[Symbol_Id]string),
		struct_names = make(map[Type_Id]string),
		cleanups     = make([dynamic]Cleanup_Scope),
		param_values = make(map[Symbol_Id]string),
		pending      = make([dynamic]string),
		pending_thunks = make([dynamic]string),
		container_ops = make(map[Type_Id]string),
		container_thunks = make(map[string]bool),
		messages     = make(map[string]string),
		literals     = make(map[string]string),
		globals      = make([dynamic]string),
	}
	strings.builder_init(&e.b)

	emit_preamble(&e)
	emit_struct_definitions(&e)
	// Registered during checking, so every use already knows its name.
	emit_materialized_constants(&e)

	// One module, in deterministic dependency order. Every procedure in every
	// package is named before any body is emitted: a cross-package call, a
	// procedure value, and a hoisted literal all need final names first.
	order := package_order(c)
	for id in order {
		name_package_symbols(&e, package_of(c, id))
	}
	name_synth_procs(&e)
	// Module-level storage first: a body that names a `static` local needs its
	// global to exist before the body is emitted.
	emit_static_locals(&e)
	for id in order {
		emit_package_items(&e, package_of(c, id))
	}
	emit_synth_procs(&e)
	emit_witnesses(&e)
	emit_entry(&e)
	emit_type_info_tables(&e)
	emit_format_thunks(&e)
	for text in e.pending_thunks {
		strings.write_string(&e.b, text)
	}
	for text in e.globals {
		strings.write_string(&e.b, text)
	}
	if e.failed {
		return "", false
	}
	return strings.to_string(e.b), true
}

@(private = "file")
backend_fail :: proc(e: ^Emitter, message: string) {
	if e.failed {
		return
	}
	e.failed = true
	errorf(e.c, no_span(), "L0405", "internal backend contract violation: %s", message)
}

@(private = "file")
name_package_symbols :: proc(e: ^Emitter, pkg: ^Package) {
	if pkg == nil {
		return
	}
	for file in pkg.files {
		for item in file.active_items {
			#partial switch v in item {
			case ^Decl:
				// A template has no signature and no body of its own; only its
				// instances are named and emitted.
				if decl_proc_literal(v) != nil && len(v.symbols) > 0 && !symbol_is_template(e.c, v.symbols[0]) {
					e.names[v.symbols[0]] = llvm_proc_name(pkg, v.names[0].text)
				}
			case ^Item_Impl:
				// A method is an ordinary procedure under a type-qualified name.
				for member in v.members {
					d, is_decl := member.(^Decl)
					if !is_decl || decl_proc_literal(d) == nil || len(d.symbols) == 0 {
						continue
					}
					sym := symbol_of(e.c, d.symbols[0])
					if sym == nil {
						continue
					}
					e.names[d.symbols[0]] = llvm_proc_name(pkg, llvm_safe(qualified_member_name(e.c, sym)))
				}
			}
		}
	}
	for literal, index in pkg.hoisted_procs {
		e.names[literal.symbol] = llvm_proc_name(pkg, fmt.aprintf("lambda.%d", index))
	}
	// Instantiations are named with their own package's symbols, in deterministic
	// instantiation order, so a cross-package generic call has a final name
	// before any body is written (m4b-plan decision "Emission order").
	for instance in pkg.instances {
		e.names[instance.symbol] = llvm_proc_name(pkg, llvm_safe(instance.name))
	}
}

// The compiler-contributed `iter` and `next` are compilation-global rather than
// package-owned, so they are named with the ordinary symbols and emitted after
// every package's items.
@(private = "file")
name_synth_procs :: proc(e: ^Emitter) {
	for symbol_id in e.c.synth_procs {
		symbol := symbol_of(e.c, symbol_id)
		if symbol == nil {
			continue
		}
		e.names[symbol_id] = fmt.aprintf("@loke.i.%s", llvm_safe(qualified_member_name(e.c, symbol)))
	}
}

@(private = "file")
symbol_is_template :: proc(c: ^Compiler, symbol_id: Symbol_Id) -> bool {
	sym := symbol_of(c, symbol_id)
	return sym != nil && sym.generic
}

@(private = "file")
emit_package_items :: proc(e: ^Emitter, pkg: ^Package) {
	if pkg == nil {
		return
	}
	for file in pkg.files {
		for item in file.active_items {
			if d, ok := item.(^Decl); ok && decl_proc_literal(d) == nil {
				emit_global(e, pkg, d)
			}
		}
	}
	for file in pkg.files {
		for item in file.active_items {
			#partial switch v in item {
			case ^Decl:
				if len(v.symbols) == 0 || symbol_is_template(e.c, v.symbols[0]) {
					continue
				}
				if literal := decl_proc_literal(v); literal != nil {
					emit_proc(e, v.symbols[0], literal)
				}
			case ^Item_Impl:
				for member in v.members {
					d, is_decl := member.(^Decl)
					if !is_decl || len(d.symbols) == 0 {
						continue
					}
					if literal := decl_proc_literal(d); literal != nil {
						emit_proc(e, d.symbols[0], literal)
					}
				}
			}
		}
	}
	for literal in pkg.hoisted_procs {
		emit_proc(e, literal.symbol, literal)
	}
	for instance in pkg.instances {
		if literal := decl_proc_literal(instance.decl); literal != nil {
			emit_proc(e, instance.symbol, literal)
		}
	}
}

@(private = "file")
emit_preamble :: proc(e: ^Emitter) {
	fmt.sbprintfln(&e.b, `target triple = "%s"`, e.c.target.triple)
	fmt.sbprintln(&e.b, "")
	// Every defined runtime failure — division by zero, an index out of range, a
	// nil dereference or nil indirect call — reaches the seed runtime's panic or
	// abort entry rather than inheriting LLVM poison, a target-specific hardware
	// exception, or the `llvm.trap` that stood in for both before M6a.
	emit_runtime_declarations(e)
	fmt.sbprintln(&e.b, "")
}

// The seed runtime's allocator surface (m6a-plan decision "Allocator handle
// ABI"). An `Allocator` value is a pointer to a `loke_rt_allocator_v1` record
// and nothing else, so copying a handle preserves the provider's state, its
// canonical region identity, and its failure policy without any per-copy tag.
//
// The record's own fields are never loaded here: dispatch goes through the
// runtime helpers, which keeps the layout to one reader and lets the record grow
// behind its version/size prefix.
RT_DEFAULT_ALLOCATOR :: "@loke_rt_v1_default_allocator"
RT_ALLOCATOR_RECORD :: "{ i32, i32, ptr, ptr, ptr, i32, i32 }"

@(private = "file")
emit_runtime_declarations :: proc(e: ^Emitter) {
	fmt.sbprintfln(&e.b, "%s = external global %s", RT_DEFAULT_ALLOCATOR, RT_ALLOCATOR_RECORD)
	fmt.sbprintln(&e.b, "declare ptr @loke_rt_v1_alloc(ptr, i64, i64)")
	fmt.sbprintln(&e.b, "declare ptr @loke_rt_v1_alloc_zeroed(ptr, i64, i64)")
	fmt.sbprintln(&e.b, "declare ptr @loke_rt_v1_resize(ptr, ptr, i64, i64, i64)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_free(ptr, ptr, i64, i64)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_reset(ptr)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_alloc_failed(ptr)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_panic(ptr)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_abort(ptr)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_thread_attach()")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_thread_detach()")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_frame_push(ptr, ptr, ptr)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_frame_pop(ptr)")
	fmt.sbprintln(&e.b, "declare void @llvm.memset.p0.i64(ptr, i8, i64, i1)")
	fmt.sbprintln(&e.b, "declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_write_std(ptr, ptr, i64)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_fmt_bytes(ptr, ptr, i64)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_fmt_i64(ptr, i64, ptr)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_fmt_u64(ptr, i64, ptr)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_fmt_i128(ptr, i64, i64, ptr)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_fmt_u128(ptr, i64, i64, ptr)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_fmt_f64(ptr, double)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_fmt_bool(ptr, i32)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_fmt_rune(ptr, i32)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_fmt_ptr(ptr, ptr)")
	emit_carrier_types(e)
	emit_text_declarations(e)
	emit_container_declarations(e)
}

// design.md "string type" and "string type conversions". The two named types are
// the frozen carriers: an owning `string` is data, byte length, and owner flags;
// a borrowed `string_view` is data and byte length, with no allocator and no
// ownership.
STRING_TYPE :: "%loke.string"
STRING_VIEW_TYPE :: "%loke.string_view"
STRING_DATA :: 0
STRING_LEN :: 1
STRING_OWNER :: 2
VIEW_DATA :: 0
VIEW_LEN :: 1
// `owner_flags` of a literal. Zero is the empty value; anything else is the
// address of a runtime buffer's header.
STRING_STATIC :: 1

// One zero-terminated static constant per distinct literal. design.md: "A string
// literal uses static storage", and its bytes are already zero-terminated, which
// is what lets the same global initialize a `cstring_view`.
@(private = "file")
text_literal_global :: proc(e: ^Emitter, text: string) -> string {
	if existing, found := e.literals[text]; found {
		return existing
	}
	name := fmt.aprintf("@.str.%d", len(e.literals))
	e.literals[text] = name
	append(&e.globals, fmt.aprintf(
		"%s = private unnamed_addr constant [%d x i8] c\"%s\\00\"\n",
		name, len(text) + 1, llvm_escape(text),
	))
	return name
}

// A literal `string` or `string_view` value. A literal costs no allocation and
// no handle accounting: its owner flags say "static", which is exactly what a
// retain and a release both ignore.
@(private = "file")
text_constant :: proc(e: ^Emitter, value: Const_Value, owning: bool) -> string {
	if value.kind != .String || value.text == "" {
		// design.md: "The empty value is all zero", and a nil view has length 0 and
		// points at no storage.
		return "zeroinitializer"
	}
	b := strings.builder_make()
	strings.write_string(&b, "{ ptr ")
	strings.write_string(&b, text_literal_global(e, value.text))
	fmt.sbprintf(&b, ", i64 %d", len(value.text))
	if owning {
		fmt.sbprintf(&b, ", i64 %d", STRING_STATIC)
	}
	strings.write_string(&b, " }")
	return strings.to_string(b)
}

// The named carrier shapes every module needs, whether or not it emits a body:
// a struct with a `string` or a container field mentions them, so the layout
// probe has to define them exactly as the real module does.
//
// `{` is a directive to core:fmt, so the record shapes are written literally.
emit_carrier_types :: proc(e: ^Emitter) {
	fmt.sbprint(&e.b, STRING_TYPE)
	fmt.sbprintln(&e.b, " = type { ptr, i64, i64 }")
	fmt.sbprint(&e.b, STRING_VIEW_TYPE)
	fmt.sbprintln(&e.b, " = type { ptr, i64 }")
	fmt.sbprint(&e.b, CONTAINER_TYPE)
	fmt.sbprintln(&e.b, " = type { ptr, i64, i64, ptr }")
	fmt.sbprint(&e.b, CONTAINER_OPS_TYPE)
	fmt.sbprintln(&e.b, " = type { i64, i64, ptr, ptr, i64, i64, ptr, ptr, ptr, ptr }")
}

@(private = "file")
emit_text_declarations :: proc(e: ^Emitter) {
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_string_from_bytes(ptr, ptr, i64, ptr)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_string_concat(ptr, ptr, i64, ptr, i64, ptr)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_string_clone(ptr, ptr, i64, ptr)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_string_from_runes(ptr, ptr, i64, ptr)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_string_retain(i64)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_string_release(i64)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_utf8_valid(ptr, i64)")
	fmt.sbprintln(&e.b, "declare i64 @loke_rt_v1_rune_count(ptr, i64)")
	fmt.sbprintln(&e.b, "declare i64 @loke_rt_v1_rune_at(ptr, i64, i64, ptr)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_bytes_compare(ptr, i64, ptr, i64)")
	fmt.sbprintln(&e.b, "declare i64 @loke_rt_v1_cstring_len(ptr)")
}

// ============================================================= containers ==

// m6b-plan decisions "Dynamic-array value ABI", "Map value ABI" and "Container
// runtime boundary". One four-word header serves both containers, and the raw
// storage behind it belongs to `runtime/container.c`.
CONTAINER_TYPE :: "%loke.container"
CONTAINER_OPS_TYPE :: "%loke.container_ops"

@(private = "file")
emit_container_declarations :: proc(e: ^Emitter) {
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_dyn_reserve(ptr, ptr, i64)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_dyn_bind(ptr)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_dyn_append(ptr, ptr, ptr, i64)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_dyn_insert(ptr, ptr, i64, ptr, i64)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_dyn_pop(ptr, ptr, ptr)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_dyn_remove(ptr, ptr, i64, ptr, i32)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_dyn_clear(ptr, ptr)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_dyn_resize(ptr, ptr, i64)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_dyn_shrink(ptr, ptr, i64)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_dyn_clone(ptr, ptr, ptr, ptr)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_dyn_drop(ptr, ptr)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_map_reserve(ptr, ptr, i64)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_map_clone(ptr, ptr, ptr, ptr)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_map_drop(ptr, ptr)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_checked_add(i64, i64, ptr)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_checked_bytes(i64, i64, ptr)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_container_fault(ptr)")
	fmt.sbprintln(&e.b, "declare i64 @loke_rt_v1_hash_bytes(ptr, i64, i64)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_map_bind(ptr)")
	fmt.sbprintln(&e.b, "declare ptr @loke_rt_v1_map_find(ptr, ptr, ptr)")
	fmt.sbprintln(&e.b, "declare ptr @loke_rt_v1_map_entry(ptr, ptr, ptr, ptr)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_map_remove(ptr, ptr, ptr, ptr)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_map_clear(ptr, ptr)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_map_shrink(ptr, ptr, i64)")
}

// The operation table for one concrete container type, made once and reused.
// The element and key thunks it points at are generated alongside it, so asking
// for the table is the only thing a caller has to do.
@(private = "file")
container_ops_global :: proc(e: ^Emitter, type: Type_Id) -> string {
	under := type_underlying(e.c, type)
	if existing, found := e.container_ops[under]; found {
		return existing
	}
	name := fmt.aprintf("@.loke.ops.%d", int(under))
	// Registered before the thunks are generated: a container whose element is
	// itself a container would otherwise recurse forever.
	e.container_ops[under] = name

	element := container_element(e.c, under)
	key := container_key(e.c, under)
	elem_drop := container_drop_thunk(e, element)
	elem_clone := container_clone_thunk(e, element)
	key_drop, key_clone, key_hash, key_equal := "null", "null", "null", "null"
	key_size, key_align := u64(0), u64(0)
	if key != INVALID_TYPE {
		key_drop = container_drop_thunk(e, key)
		key_clone = container_clone_thunk(e, key)
		key_hash = container_hash_thunk(e, key)
		key_equal = container_equal_thunk(e, key)
		key_size, key_align = type_size(e.c, key), type_align(e.c, key)
	}
	// `{` is a directive to core:fmt, so the row is concatenated rather than
	// formatted.
	b := strings.builder_make()
	fmt.sbprintf(&b, "%s = private unnamed_addr constant %s ", name, CONTAINER_OPS_TYPE)
	strings.write_string(&b, "{")
	fmt.sbprintf(
		&b, " i64 %d, i64 %d, ptr %s, ptr %s, i64 %d, i64 %d, ptr %s, ptr %s, ptr %s, ptr %s }\n",
		type_size(e.c, element), type_align(e.c, element), elem_drop, elem_clone,
		key_size, key_align, key_drop, key_clone, key_hash, key_equal,
	)
	append(&e.globals, strings.to_string(b))
	return name
}

// A NULL `drop` means the part is trivially destroyed, which is what keeps the
// C loop out of the way entirely for a `[dynamic]int`.
@(private = "file")
container_drop_thunk :: proc(e: ^Emitter, part: Type_Id) -> string {
	if part == INVALID_TYPE || !type_is_managed(e.c, part) {
		return "null"
	}
	name := fmt.aprintf("@loke.cdrop.%d", int(type_underlying(e.c, part)))
	if e.container_thunks[name] {
		return name
	}
	e.container_thunks[name] = true
	saved_body, saved_terminated := e.b, e.terminated
	e.b, e.terminated = strings.builder_make(), false
	// `{` is a directive to core:fmt, so the brace is printed separately.
	fmt.sbprintf(&e.b, "define private void %s(ptr %%p)", name)
	fmt.sbprintln(&e.b, " {")
	fmt.sbprintln(&e.b, "entry:")
	emit_drop_place(e, part, "%p")
	fmt.sbprintln(&e.b, "  ret void")
	fmt.sbprintln(&e.b, "}")
	fmt.sbprintln(&e.b, "")
	text := strings.to_string(e.b)
	e.b, e.terminated = saved_body, saved_terminated
	append(&e.pending_thunks, text)
	return name
}

// A NULL `clone` means the part's clone is the copy its representation already
// is, so the C helper memcpys the whole run instead of calling back per element.
@(private = "file")
container_clone_thunk :: proc(e: ^Emitter, part: Type_Id) -> string {
	if part == INVALID_TYPE || !type_is_managed(e.c, part) {
		return "null"
	}
	name := fmt.aprintf("@loke.cclone.%d", int(type_underlying(e.c, part)))
	if e.container_thunks[name] {
		return name
	}
	e.container_thunks[name] = true
	saved_body, saved_terminated := e.b, e.terminated
	e.b, e.terminated = strings.builder_make(), false
	fmt.sbprintf(&e.b, "define private i32 %s(ptr %%out, ptr %%src, ptr %%a)", name)
	fmt.sbprintln(&e.b, " {")
	fmt.sbprintln(&e.b, "entry:")
	ok := emit_try_clone_into(e, part, "%out", "%src", "%a")
	widened := temp(e)
	fmt.sbprintfln(&e.b, "  %s = zext i1 %s to i32", widened, ok)
	fmt.sbprintfln(&e.b, "  ret i32 %s", widened)
	fmt.sbprintln(&e.b, "}")
	fmt.sbprintln(&e.b, "")
	text := strings.to_string(e.b)
	e.b, e.terminated = saved_body, saved_terminated
	append(&e.pending_thunks, text)
	return name
}

// m6b-plan decision "Map algorithm and coherence": the concrete operation table
// *freezes* the key's `==`/`hash` selection, so a map that travels between
// packages keeps one policy. The checker has already rejected a key with no
// coherent inherent pair, so this only has to emit whichever pair it settled on.
@(private = "file")
container_hash_thunk :: proc(e: ^Emitter, key: Type_Id) -> string {
	name := fmt.aprintf("@loke.chash.%d", int(type_underlying(e.c, key)))
	if e.container_thunks[name] {
		return name
	}
	e.container_thunks[name] = true
	saved_body, saved_terminated := e.b, e.terminated
	e.b, e.terminated = strings.builder_make(), false
	fmt.sbprintf(&e.b, "define private i64 %s(ptr %%p, i64 %%seed)", name)
	fmt.sbprintln(&e.b, " {")
	fmt.sbprintln(&e.b, "entry:")
	value := temp(e)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %%p", value, llvm_type(e, key))
	out := ""
	if hook := key_policy_member(e.c, key, false); hook != INVALID_SYMBOL {
		out = temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i64 %s(%s %s, i64 %%seed)",
			out, e.names[hook], llvm_type(e, key), value,
		)
	} else {
		out = emit_hash_value(e, key, value, "%seed")
	}
	fmt.sbprintfln(&e.b, "  ret i64 %s", out)
	fmt.sbprintln(&e.b, "}")
	fmt.sbprintln(&e.b, "")
	text := strings.to_string(e.b)
	e.b, e.terminated = saved_body, saved_terminated
	append(&e.pending_thunks, text)
	return name
}

@(private = "file")
container_equal_thunk :: proc(e: ^Emitter, key: Type_Id) -> string {
	name := fmt.aprintf("@loke.cequal.%d", int(type_underlying(e.c, key)))
	if e.container_thunks[name] {
		return name
	}
	e.container_thunks[name] = true
	saved_body, saved_terminated := e.b, e.terminated
	e.b, e.terminated = strings.builder_make(), false
	fmt.sbprintf(&e.b, "define private i32 %s(ptr %%a, ptr %%b)", name)
	fmt.sbprintln(&e.b, " {")
	fmt.sbprintln(&e.b, "entry:")
	llvm := llvm_type(e, key)
	left, right := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %%a", left, llvm)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %%b", right, llvm)
	same := ""
	if hook := key_policy_member(e.c, key, true); hook != INVALID_SYMBOL {
		same = temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i1 %s(%s %s, %s %s)",
			same, e.names[hook], llvm, left, llvm, right,
		)
	} else {
		same = emit_compare(e, .Eq_Eq, key, left, right)
	}
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = zext i1 %s to i32", out, same)
	fmt.sbprintfln(&e.b, "  ret i32 %s", out)
	fmt.sbprintln(&e.b, "}")
	fmt.sbprintln(&e.b, "")
	text := strings.to_string(e.b)
	e.b, e.terminated = saved_body, saved_terminated
	append(&e.pending_thunks, text)
	return name
}

// The key type's own inherent `hash` or `operator(==)`, or INVALID_SYMBOL when
// the compiler supplies the pair. An `extend` member is never one of these.
@(private = "file")
key_policy_member :: proc(c: ^Compiler, key: Type_Id, want_equal: bool) -> Symbol_Id {
	if type_is_hashable(c, key) {
		return INVALID_SYMBOL
	}
	info := type_of(c, type_underlying(c, key))
	if info == nil {
		return INVALID_SYMBOL
	}
	for member in info.members {
		sym := symbol_of(c, member)
		if sym == nil {
			continue
		}
		if want_equal && sym.operator == "==" {
			return member
		}
		if !want_equal && sym.operator == "" && sym.kind == .Proc &&
		   identifier_text(c, sym.name) == "hash" {
			return member
		}
	}
	return INVALID_SYMBOL
}

// Deep-copy the value at `src` into the storage at `out`, answering an `i1` that
// is true on success. This is the one place that knows how the three kinds of
// managed part differ: a container clones through its C helper, a fallible hook
// returns its own error, and everything else has a clone that cannot fail.
//
// On failure `out` is left untouched, which is what lets the caller destroy
// exactly the prefix it did build (m6b-plan decision "Atomic mutation").
@(private = "file")
emit_try_clone_into :: proc(e: ^Emitter, type: Type_Id, out, src, allocator: string) -> string {
	if lifecycle_of(e.c, type).container {
		helper := type_is_map(e.c, type) ? "loke_rt_v1_map_clone" : "loke_rt_v1_dyn_clone"
		status, ok := temp(e), temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i32 @%s(ptr %s, ptr %s, ptr %s, ptr %s)",
			status, helper, out, src, container_ops_global(e, type), allocator,
		)
		fmt.sbprintfln(&e.b, "  %s = icmp ne i32 %s, 0", ok, status)
		return ok
	}
	value := temp(e)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", value, llvm_type(e, type), src)
	if !type_clone_is_fallible(e.c, type) {
		store(e, type, emit_clone_value(e, type, value, allocator), out)
		return "true"
	}
	hook := type_hook(e.c, type, "try_clone")
	if hook == INVALID_SYMBOL {
		backend_fail(e, "a fallible container element has no `try_clone` member")
		return "false"
	}
	pair := clone_pair_type(llvm_type(e, type))
	returned := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call %s %s(%s %s, ptr %s)",
		returned, pair, e.names[hook], llvm_type(e, type), value, allocator,
	)
	cloned, error, ok := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, 0", cloned, pair, returned)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, 1", error, pair, returned)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i64 %s, 0", ok, error)
	// The hook already cleaned its own temporary on the failing path, and a
	// failed clone returns the zero value, so publishing it unconditionally would
	// leave an inert value the caller must not count as initialised. Store it
	// only where it is real.
	store_label, done_label := new_label(e, "clone.store"), new_label(e, "clone.done")
	branch_if(e, ok, store_label, done_label)
	place_label(e, store_label)
	store(e, type, cloned, out)
	branch(e, done_label)
	place_label(e, done_label)
	e.terminated = false
	return ok
}

// Writes a container declaration's written `via` into its header at the
// declaration point. A declaration with no policy is left allocator-unbound,
// which is what makes the lazy default binding observable.
@(private = "file")
emit_eager_via_binding :: proc(e: ^Emitter, symbol_id: Symbol_Id, address: string) {
	sym := symbol_of(e.c, symbol_id)
	if sym == nil || sym.via == nil || !type_is_container(e.c, sym.type) {
		return
	}
	provider, slot := emit_expr(e, sym.via), temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = getelementptr inbounds %s, ptr %s, i32 0, i32 %d",
		slot, CONTAINER_TYPE, address, CONTAINER_ALLOC,
	)
	fmt.sbprintfln(&e.b, "  store ptr %s, ptr %s", provider, slot)
}

// The provider a construction into one destination selects: the declaration's
// written `via`, or the default when it has no policy (m6b-plan decision
// "Allocator binding"). The policy belongs to the declaration, so this is the
// destination's own symbol rather than anything the source value carries.
@(private = "file")
emit_destination_allocator :: proc(e: ^Emitter, symbol_id: Symbol_Id) -> string {
	written := symbol_via_allocator(e.c, symbol_id)
	return written == nil ? RT_DEFAULT_ALLOCATOR : emit_expr(e, written)
}

// The allocator a call selected: the one it was given, or the default provider
// when the argument was omitted. The checker already bound whichever it was, so
// this never re-derives the choice.
@(private = "file")
emit_allocator_operand :: proc(e: ^Emitter, v: ^Expr_Call, index: int) -> string {
	if len(v.bound) > index {
		return emit_expr(e, v.bound[index])
	}
	return RT_DEFAULT_ALLOCATOR
}

// design.md: `free_all` "frees every allocation in the allocator's region. Not
// all allocators support this procedure." It is one call through the provider's
// reset callback, never a guessed sequence of `free` calls: only the provider
// knows what its region contains. A provider that answers "no region" fails at
// run time — a different thing from the compile-time rejection when a dependant
// would survive the reset.
@(private = "file")
emit_region_reset :: proc(e: ^Emitter, v: ^Expr_Call) {
	handle := emit_expr(e, v.bound[0])
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_reset(ptr %s)", handle)
}

// ------------------------------------------------------- layout agreement --

// One number the checker claims and LLVM can be made to compute.
@(private = "file")
Layout_Probe :: struct {
	description: string,
	llvm:        string, // a constant expression that evaluates to the number
	expected:    u64,
}

// `-check-layout`: builds a module that prints LLVM's own size, alignment, and
// field offsets for every type in the compilation, runs it, and compares the
// results with the checker's cached layout.
//
// Executing LLVM-derived values tests the actual target backend rather than a
// second copy of the checker's formula (m3-plan decision "Layout agreement").
check_layout_agreement :: proc(c: ^Compiler, opts: Options) -> int {
	e := Emitter {
		c            = c,
		names        = make(map[Symbol_Id]string),
		struct_names = make(map[Type_Id]string),
		cleanups     = make([dynamic]Cleanup_Scope),
		param_values = make(map[Symbol_Id]string),
		pending      = make([dynamic]string),
		pending_thunks = make([dynamic]string),
		container_ops = make(map[Type_Id]string),
		container_thunks = make(map[string]bool),
		messages     = make(map[string]string),
		literals     = make(map[string]string),
		globals      = make([dynamic]string),
	}
	strings.builder_init(&e.b)
	fmt.sbprintfln(&e.b, `target triple = "%s"`, c.target.triple)
	fmt.sbprintln(&e.b, `@.fmt_int = private unnamed_addr constant [6 x i8] c"%lld\0A\00"`)
	fmt.sbprintln(&e.b, "declare i32 @printf(ptr, ...)")
	// The normal module supplies this detach callback. A layout probe has no Loke
	// thread-local values, but it links the same seed runtime and therefore owes
	// the runtime the no-op side of that ABI.
	fmt.sbprintln(&e.b, "define void @loke_rt_v1_program_tls_cleanup() { ret void }")
	emit_carrier_types(&e)
	emit_struct_definitions(&e)

	probes := make([dynamic]Layout_Probe)
	for index in 0 ..< len(c.types) {
		type := Type_Id(index)
		if !layout_probeable(c, type) {
			continue
		}
		llvm := llvm_type(&e, type)
		name := type_name(c, type)
		append(&probes, Layout_Probe {
			description = fmt.aprintf("size_of(%s)", name),
			llvm        = fmt.aprintf("ptrtoint (ptr getelementptr (%s, ptr null, i64 1) to i64)", llvm),
			expected    = type_size(c, type),
		})
		// The offset of the second member of `{ i8, T }` is T's alignment: LLVM
		// has no `alignof`, but it does have to place that member.
		append(&probes, Layout_Probe {
			description = fmt.aprintf("align_of(%s)", name),
			// `{` is a format directive to core:fmt, so this one is concatenated.
			llvm        = strings.concatenate(
				{"ptrtoint (ptr getelementptr ({ i8, ", llvm, " }, ptr null, i64 0, i32 1) to i64)"},
			),
			expected    = type_align(c, type),
		})
		info := type_of(c, type)
		if info.kind != .Struct {
			continue
		}
		for field, position in info.fields {
			symbol := symbol_of(c, field)
			if symbol == nil {
				continue
			}
			append(&probes, Layout_Probe {
				description = fmt.aprintf("offset_of(%s, %s)", name, identifier_text(c, symbol.name)),
				llvm        = fmt.aprintf("ptrtoint (ptr getelementptr (%s, ptr null, i64 0, i32 %d) to i64)", llvm, position),
				expected    = type_field_offset(c, type, position),
			})
		}
	}

	fmt.sbprintln(&e.b, "define i32 @main() {")
	fmt.sbprintln(&e.b, "entry:")
	for probe in probes {
		fmt.sbprintfln(&e.b, "  call i32 (ptr, ...) @printf(ptr @.fmt_int, i64 %s)", probe.llvm)
	}
	fmt.sbprintln(&e.b, "  ret i32 0")
	fmt.sbprintln(&e.b, "}")

	ll_path := replace_ext(opts.output, ".layout.ll")
	if !os.write_entire_file(ll_path, transmute([]u8)strings.to_string(e.b)) {
		errorf(c, no_span(), "L0401", "cannot write `%s`", ll_path)
		return 2
	}
	defer if !opts.keep_temps {
		os.remove(ll_path)
	}
	if code := link(c, ll_path, opts.output, opts); code != 0 {
		return code
	}
	defer if !opts.keep_temps {
		os.remove(opts.output)
	}

	state, stdout, _, err := os2.process_exec(
		os2.Process_Desc{command = []string{opts.output}},
		context.allocator,
	)
	if err != nil || state.exit_code != 0 {
		errorf(c, no_span(), "L0405", "cannot run the layout probe")
		return 2
	}
	lines := strings.split_lines(strings.trim_space(strings.replace_all(string(stdout), "\r\n", "\n") or_else ""))
	if len(lines) != len(probes) {
		errorf(c, no_span(), "L0405", "the layout probe produced %d values, expected %d", len(lines), len(probes))
		return 2
	}
	disagreements := 0
	for probe, index in probes {
		actual, parsed := strconv.parse_u64(strings.trim_space(lines[index]))
		if !parsed || actual != probe.expected {
			errorf(
				c,
				no_span(),
				"L0405",
				"%s: the checker says %d, LLVM says %s",
				probe.description,
				probe.expected,
				lines[index],
			)
			disagreements += 1
		}
	}
	if disagreements > 0 {
		return 1
	}
	fmt.printfln("%d layout facts agree with LLVM", len(probes))
	return 0
}

// A type whose layout LLVM can be asked about at all: it must lower to a real
// LLVM type and hold a runtime value.
@(private = "file")
layout_probeable :: proc(c: ^Compiler, type: Type_Id) -> bool {
	info := type_of(c, type)
	if info == nil || !type_is_supported(c, type) {
		return false
	}
	#partial switch info.kind {
	case .Bool, .Int, .Float, .Rune, .Raw_Pointer, .Pointer, .Proc, .Enum, .Array, .Struct,
	     .Distinct, .Union, .Slice, .Allocator, .Allocator_Error,
	     .Dynamic_Array, .Map:
		return true
	}
	return false
}

// ------------------------------------------------------------ LLVM types --

// Named struct definitions, in containment order. The checker has already
// rejected a by-value cycle, so a value edge cannot come back here.
@(private = "file")
emit_struct_definitions :: proc(e: ^Emitter) {
	emitted := make(map[Type_Id]bool)
	defer delete(emitted)
	for index in 0 ..< len(e.c.types) {
		define_struct(e, Type_Id(index), &emitted)
	}
	fmt.sbprintln(&e.b, "")
}

@(private = "file")
define_struct :: proc(e: ^Emitter, type: Type_Id, emitted: ^map[Type_Id]bool) {
	info := type_of(e.c, type)
	if info == nil || emitted[type] {
		return
	}
	// A generic record's own shell is a placeholder for its instances and has no
	// layout of its own.
	if sym := symbol_of(e.c, info.symbol); sym != nil && sym.generic {
		emitted[type] = true
		return
	}
	if info.kind == .Union {
		if !type_is_supported(e.c, type) {
			return
		}
		emitted[type] = true
		fmt.sbprintfln(&e.b, "%s = type %s", struct_name(e, type), union_storage_definition(e, type))
		return
	}
	if info.kind == .Slice {
		// Only the read-only variant is defined; `[]mut T` shares its name.
		if !type_is_supported(e.c, type) || slice_abi_type(e.c, type) != type {
			return
		}
		ensure_slice_fields(e.c, type)
		info = type_of(e.c, type)
	} else if info.kind != .Struct && info.kind != .Any_View && info.kind != .Dyn {
		return
	}
	emitted[type] = true
	for field in info.fields {
		symbol := symbol_of(e.c, field)
		if symbol == nil {
			continue
		}
		// A pointer edge stops here: `ptr` needs no definition of its pointee.
		define_struct(e, struct_dependency(e.c, symbol.type), emitted)
	}
	name := struct_name(e, type)
	// `{` is a format directive to core:fmt, so the brace is printed separately.
	fmt.sbprintf(&e.b, "%s = type", name)
	fmt.sbprint(&e.b, " {")
	for field, index in info.fields {
		symbol := symbol_of(e.c, field)
		if index > 0 {
			fmt.sbprint(&e.b, ",")
		}
		fmt.sbprintf(&e.b, " %s", llvm_type(e, symbol.type))
	}
	fmt.sbprintln(&e.b, " }")
}

// The struct a value-typed field depends on, looking through arrays and
// distinct wrappers but never through a pointer.
@(private = "file")
struct_dependency :: proc(c: ^Compiler, type: Type_Id) -> Type_Id {
	current := type_underlying(c, type)
	for i := 0; i < 32; i += 1 {
		info := type_of(c, current)
		if info == nil || info.kind != .Array {
			return current
		}
		current = type_underlying(c, info.element)
	}
	return current
}

@(private = "file")
struct_name :: proc(e: ^Emitter, raw: Type_Id) -> string {
	// Both slice capabilities share one backend type, so `[]mut T` weakening to
	// `[]T` is the no-op the design says it is.
	type := slice_abi_type(e.c, raw)
	if name, ok := e.struct_names[type]; ok {
		return name
	}
	info := type_of(e.c, type)
	prefix := info != nil && info.kind == .Union ? "union" : "struct"
	name := ""
	if info != nil && (info.mangled != "" || info.name != INVALID_IDENTIFIER) {
		// An instantiation carries its own backend spelling; a written name may
		// still mention punctuation LLVM would need quoting for.
		text := info.mangled
		if text == "" {
			text = identifier_text(e.c, info.name)
			if !llvm_plain_name(text) {
				text = llvm_safe(text)
			}
		}
		name = fmt.aprintf("%%%s.%s.%d", prefix, text, int(type))
	} else {
		name = fmt.aprintf("%%%s.anon.%d", prefix, int(type))
	}
	e.struct_names[type] = name
	return name
}

llvm_type :: proc(e: ^Emitter, type: Type_Id) -> string {
	// Nothing untyped should reach the backend, but taking its default type here
	// keeps a leak from silently becoming a zero of the wrong width.
	under := type_underlying(e.c, default_type(e.c, type))
	info := type_of(e.c, under)
	if info == nil {
		return "i64"
	}
	#partial switch info.kind {
	case .Void:
		return "void"
	case .Bool:
		// ponytail: `i1` everywhere, so a `bool` alloca is not one byte. Nothing
		// in M2 observes a bool's storage size; switch to i8-in-memory when the
		// foreign ABI lands in M7.
		return "i1"
	case .Int, .Enum, .Allocator_Error:
		return fmt.aprintf("i%d", type_bits(e.c, under))
	case .Typeid:
		// design.md: an ordinary runtime scalar holding one concrete type's unique
		// identifier. Zero is nil.
		return "i64"
	case .Rune:
		return "i32"
	case .Float:
		switch info.bits {
		case 16:
			return "half"
		case 32:
			return "float"
		}
		return "double"
	case .Pointer, .Multi_Pointer, .Raw_Pointer, .Proc, .Allocator, .CString_View:
		// An `Allocator` is a one-word handle on the provider record; a
		// `cstring_view` is one zero-terminated address; a multi-pointer is one
		// address with neither a length nor a capability.
		return "ptr"
	case .String:
		return STRING_TYPE
	case .String_View:
		return STRING_VIEW_TYPE
	case .Dynamic_Array, .Map:
		// m6b-plan decisions "Dynamic-array value ABI" and "Map value ABI": both
		// headers are the same four words, so they share one backend type exactly
		// as the two slice capabilities do.
		return CONTAINER_TYPE
	case .Array:
		return fmt.aprintf("[%d x %s]", info.count, llvm_type(e, info.element))
	case .Struct, .Union, .Any_View, .Dyn, .Slice:
		// A two-word erased view or slice is an ordinary aggregate to the backend.
		return struct_name(e, under)
	}
	return "i64"
}

// The union storage type, built so LLVM's own layout matches the checker's
// cached facts: an alignment-carrying payload head, explicit payload padding,
// the tag, and tail padding. A bare `[N x i8]` payload would be byte-aligned,
// which is wrong wherever a union is allocated directly, nested in a struct, or
// used as an array element.
@(private = "file")
union_storage_definition :: proc(e: ^Emitter, type: Type_Id) -> string {
	shape := union_layout(e.c, type)
	b := strings.builder_make()
	strings.write_string(&b, "{ ")
	fmt.sbprintf(&b, "i%d", shape.align * 8)
	if pad := shape.payload_size - shape.align; pad > 0 {
		fmt.sbprintf(&b, ", [%d x i8]", pad)
	}
	if gap := shape.tag_offset - shape.payload_size; gap > 0 {
		fmt.sbprintf(&b, ", [%d x i8]", gap)
	}
	fmt.sbprintf(&b, ", i%d", shape.tag_bytes * 8)
	if tail := shape.size - shape.tag_offset - shape.tag_bytes; tail > 0 {
		fmt.sbprintf(&b, ", [%d x i8]", tail)
	}
	strings.write_string(&b, " }")
	return strings.to_string(b)
}

// A variant value becoming a union value: zero the storage, write the payload
// through a typed pointer, then write the tag.
@(private = "file")
emit_union_value :: proc(e: ^Emitter, union_type, variant: Type_Id, value: string) -> string {
	slot := emit_union_slot(e, union_type, variant, value)
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", out, llvm_type(e, union_type), slot)
	return out
}

@(private = "file")
emit_union_slot :: proc(e: ^Emitter, union_type, variant: Type_Id, value: string) -> string {
	llvm := llvm_type(e, union_type)
	slot := temp(e)
	fmt.sbprintfln(&e.b, "  %s = alloca %s", slot, llvm)
	fmt.sbprintfln(&e.b, "  store %s zeroinitializer, ptr %s", llvm, slot)
	payload := temp(e)
	fmt.sbprintfln(&e.b, "  %s = getelementptr inbounds %s, ptr %s, i32 0, i32 0", payload, llvm, slot)
	fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", llvm_type(e, variant), value, payload)
	emit_union_store_tag(e, union_type, slot, union_variant_tag(e.c, union_type, variant))
	return slot
}

@(private = "file")
emit_union_store_tag :: proc(e: ^Emitter, union_type: Type_Id, slot: string, tag: int) {
	llvm := llvm_type(e, union_type)
	shape := union_layout(e.c, union_type)
	address := temp(e)
	fmt.sbprintfln(
		&e.b,
		"  %s = getelementptr inbounds %s, ptr %s, i32 0, i32 %d",
		address, llvm, slot, union_tag_member(e, union_type),
	)
	fmt.sbprintfln(&e.b, "  store i%d %d, ptr %s", shape.tag_bytes * 8, tag, address)
}

// The tag of a union *value*, which is what every assertion and type switch
// tests.
@(private = "file")
emit_union_tag :: proc(e: ^Emitter, union_type: Type_Id, value: string) -> string {
	out := temp(e)
	fmt.sbprintfln(
		&e.b,
		"  %s = extractvalue %s %s, %d",
		out, llvm_type(e, union_type), value, union_tag_member(e, union_type),
	)
	return out
}

// Spills a union value so its payload can be read at a variant's own type.
@(private = "file")
emit_union_spill :: proc(e: ^Emitter, union_type: Type_Id, value: string) -> string {
	llvm := llvm_type(e, union_type)
	slot := temp(e)
	fmt.sbprintfln(&e.b, "  %s = alloca %s", slot, llvm)
	fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", llvm, value, slot)
	return slot
}

@(private = "file")
emit_union_payload :: proc(e: ^Emitter, union_type, variant: Type_Id, slot: string) -> string {
	payload := temp(e)
	fmt.sbprintfln(
		&e.b,
		"  %s = getelementptr inbounds %s, ptr %s, i32 0, i32 0",
		payload, llvm_type(e, union_type), slot,
	)
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", out, llvm_type(e, variant), payload)
	return out
}

// Which member of that storage type holds the tag.
@(private = "file")
union_tag_member :: proc(e: ^Emitter, type: Type_Id) -> int {
	shape := union_layout(e.c, type)
	index := 1
	if shape.payload_size > shape.align {
		index += 1
	}
	if shape.tag_offset > shape.payload_size {
		index += 1
	}
	return index
}

// The internal convention for several results: one anonymous literal struct,
// used consistently by caller and callee. This is not the frozen Loke or C ABI
// (m2-plan shortcut table); M7 replaces it.
@(private = "file")
llvm_result_type :: proc(e: ^Emitter, results: []Type_Id, inout: []bool = nil) -> string {
	// An `inout` result is a place, so it travels as its address.
	slot :: proc(e: ^Emitter, results: []Type_Id, inout: []bool, index: int) -> string {
		if index < len(inout) && inout[index] {
			return "ptr"
		}
		return llvm_type(e, results[index])
	}
	switch len(results) {
	case 0:
		return "void"
	case 1:
		return slot(e, results, inout, 0)
	}
	b := strings.builder_make()
	strings.write_string(&b, "{ ")
	for _, index in results {
		if index > 0 {
			strings.write_string(&b, ", ")
		}
		strings.write_string(&b, slot(e, results, inout, index))
	}
	strings.write_string(&b, " }")
	return strings.to_string(b)
}

@(private = "file")
result_inout_of :: proc(e: ^Emitter, proc_type: Type_Id) -> []bool {
	info := type_of(e.c, proc_type)
	return info == nil ? nil : info.result_inout
}

@(private = "file")
emit_result_is_inout :: proc(e: ^Emitter, index: int) -> bool {
	return index < len(e.result_inout) && e.result_inout[index]
}

// ---------------------------------------------------------------- globals --

// design.md "Storage modifiers": a `static` local "creates one instance for the
// life of the process" and a `thread_local` one "for each thread", so neither
// lives in the frame. The checker recorded them in declaration order, which is
// also the order design.md gives thread-local teardown.
@(private = "file")
emit_static_locals :: proc(e: ^Emitter) {
	for symbol_id, index in e.c.static_locals {
		sym := symbol_of(e.c, symbol_id)
		if sym == nil || sym.kind != .Var {
			continue
		}
		name := fmt.aprintf("@loke.s.%d.%s", index, llvm_safe(identifier_text(e.c, sym.name)))
		e.names[symbol_id] = name
		value := "zeroinitializer"
		if zero, ok := zero_const(e.c, sym.type); ok {
			value = llvm_const(e, zero, sym.type)
		}
		if sym.decl != nil {
			for initialiser, position in sym.decl.values {
				if position < len(sym.decl.symbols) && sym.decl.symbols[position] == symbol_id &&
				   initialiser != nil && is_const_expr(initialiser) {
					value = llvm_const(e, const_value_of(initialiser), sym.type)
				}
			}
		}
		qualifier := sym.duration == .Thread_Local ? "thread_local " : ""
		fmt.sbprintfln(&e.b, "%s = %sglobal %s %s", name, qualifier, llvm_type(e, sym.type), value)
	}
	if len(e.c.static_locals) > 0 {
		fmt.sbprintln(&e.b, "")
	}
}

// The fixed callback the runtime invokes from `thread_detach`. It addresses
// LLVM thread-local globals, so the same function drops the values belonging to
// whichever initial, runtime-created, or foreign-attached thread is detaching.
@(private = "file")
emit_thread_local_teardown :: proc(e: ^Emitter) {
	fmt.sbprintln(&e.b, "define void @loke_rt_v1_program_tls_cleanup() {")
	fmt.sbprintln(&e.b, "entry:")
	for index := len(e.c.static_locals) - 1; index >= 0; index -= 1 {
		symbol_id := e.c.static_locals[index]
		sym := symbol_of(e.c, symbol_id)
		if sym == nil || sym.duration != .Thread_Local || sym.manual {
			continue // the runtime does not drop a manual TLS owner
		}
		if !type_is_managed(e.c, sym.type) {
			continue
		}
		emit_drop_place(e, sym.type, e.names[symbol_id])
	}
	fmt.sbprintln(&e.b, "  ret void")
	fmt.sbprintln(&e.b, "}")
	fmt.sbprintln(&e.b, "")
}

// File-scope variables need constant initialisers (design.md "Values that
// outlive every scope"), so folding has already produced the value.
emit_global :: proc(e: ^Emitter, pkg: ^Package, d: ^Decl) {
	for symbol_id, i in d.symbols {
		sym := symbol_of(e.c, symbol_id)
		if sym == nil || sym.kind != .Var {
			continue
		}
		name := llvm_global_name(pkg, identifier_text(e.c, sym.name))
		e.names[symbol_id] = name
		value := ""
		if i < len(d.values) && d.values[i] != nil && is_const_expr(d.values[i]) {
			value = llvm_const(e, const_value_of(d.values[i]), sym.type)
		} else {
			zero, ok := zero_const(e.c, sym.type)
			if !ok {
				backend_fail(e, "a global type was not gated by the checker")
				continue
			}
			value = llvm_const(e, zero, sym.type)
		}
		fmt.sbprintfln(&e.b, "%s = global %s %s", name, llvm_type(e, sym.type), value)
	}
	fmt.sbprintln(&e.b, "")
}

// -------------------------------------------------------------- constants --

llvm_const :: proc(e: ^Emitter, value: Const_Value, type: Type_Id) -> string {
	under := type_underlying(e.c, default_type(e.c, type))
	info := type_of(e.c, under)
	if info == nil {
		return "0"
	}
	#partial switch info.kind {
	case .Typeid:
		// Symbolic during checking, numeric here: `freeze_typeids` has assigned a
		// deterministic value to every requested type before any body is emitted.
		return fmt.aprintf("%d", typeid_value(e.c, value.type_value))
	case .Bool:
		return value.boolean ? "true" : "false"
	case .Int, .Enum, .Rune:
		bits := type_bits(e.c, under)
		signed := type_signed(e.c, under)
		if info.kind == .Rune {
			bits, signed = 32, true
		}
		return bi_text(e.c, bi_wrap(e.c, value.integer, bits, signed))
	case .Float:
		return llvm_float(value.float, info.bits)
	case .Pointer, .Multi_Pointer, .Raw_Pointer, .Proc, .Allocator:
		return "null"
	case .CString_View:
		// design.md: "A string literal may initialize a `cstring_view` because its
		// zero-terminated bytes have static lifetime."
		return value.kind == .String ? text_literal_global(e, value.text) : "null"
	case .String, .String_View:
		return text_constant(e, value, info.kind == .String)
	case .Allocator_Error:
		// Nil is success, and success is zero.
		return value.kind == .Nil ? "0" : bi_text(e.c, value.integer)
	case .Union:
		// The only constant of a union or an erased view is its zero value; every
		// other one is built at run time.
		return "zeroinitializer"
	case .Array:
		b := strings.builder_make()
		strings.write_string(&b, "[")
		for index in 0 ..< int(info.count) {
			if index > 0 {
				strings.write_string(&b, ",")
			}
			element := Const_Value{}
			if value.aggregate != nil && index < len(value.aggregate.elements) {
				element = value.aggregate.elements[index]
			}
			fmt.sbprintf(&b, " %s %s", llvm_type(e, info.element), llvm_const(e, element, info.element))
		}
		strings.write_string(&b, " ]")
		return strings.to_string(b)
	case .Struct, .Any_View, .Dyn, .Slice, .Dynamic_Array, .Map:
		if value.kind == .Nil {
			return "zeroinitializer"
		}
		b := strings.builder_make()
		strings.write_string(&b, "{")
		for field, index in info.fields {
			symbol := symbol_of(e.c, field)
			if index > 0 {
				strings.write_string(&b, ",")
			}
			element := Const_Value{}
			if value.aggregate != nil && index < len(value.aggregate.elements) {
				element = value.aggregate.elements[index]
			}
			fmt.sbprintf(&b, " %s %s", llvm_type(e, symbol.type), llvm_const(e, element, symbol.type))
		}
		strings.write_string(&b, " }")
		return strings.to_string(b)
	}
	return "0"
}

// LLVM's decimal float syntax is only exact for values it can round-trip, so
// every float constant is spelled as its bit pattern. `half` uses the 16-bit
// form; `float` uses the double pattern, which is exact because the value was
// already rounded to single precision.
@(private = "file")
llvm_float :: proc(value: f64, bits: u16) -> string {
	if bits == 16 {
		return fmt.aprintf("0xH%04X", f64_to_f16_bits(value))
	}
	pattern := transmute(u64)value
	if bits == 32 {
		pattern = transmute(u64)f64(f32(value))
	}
	return fmt.aprintf("0x%016X", pattern)
}

// ------------------------------------------------------------ procedures --

@(private = "file")
emit_proc :: proc(e: ^Emitter, symbol_id: Symbol_Id, literal: ^Expr_Proc) {
	symbol := symbol_of(e.c, symbol_id)
	if symbol == nil || literal == nil || literal.body == nil {
		return
	}
	llvm_name, named := e.names[symbol_id]
	if !named {
		// Every declared and hoisted procedure is named before any body is
		// emitted, so arriving here would mean emitting one nothing can call.
		backend_fail(e, "a procedure has no mangled name")
		return
	}

	e.result_types = symbol.results
	e.result_inout = result_inout_of(e, symbol.proc_type)
	e.result_slots = make([]string, len(symbol.results))
	e.terminated = false
	clear(&e.cleanups)
	begin_unwind_frame(e, llvm_name)

	fmt.sbprintf(&e.b, "define %s %s(", llvm_result_type(e, symbol.results, e.result_inout), llvm_name)
	for parameter, index in symbol.params {
		if index > 0 {
			fmt.sbprint(&e.b, ", ")
		}
		mode := symbol_param_mode(e.c, symbol, index)
		type := mode == .Inout ? "ptr" : llvm_type(e, parameter)
		fmt.sbprintf(&e.b, "%s %%arg%d", type, index)
	}
	fmt.sbprintln(&e.b, ") {")
	fmt.sbprintln(&e.b, "entry:")

	// The rest of the body goes to a side builder: the frame prologue needs the
	// number of registered actions and the number of published locals, and
	// neither is known until the whole body has been walked.
	module := e.b
	e.b = strings.builder_make()

	// A value parameter is immutable but addressable, so it gets storage of its
	// own; an `inout` parameter is already the alias.
	for parameter, index in symbol.params {
		binding := symbol.param_symbols[index]
		if binding == INVALID_SYMBOL {
			continue
		}
		if symbol_param_mode(e.c, symbol, index) == .Inout {
			bind_local(e, binding, fmt.aprintf("%%arg%d", index))
			continue
		}
		slot := fmt.aprintf("%%p%d.%d", index, next_id(e))
		fmt.sbprintfln(&e.b, "  %s = alloca %s", slot, llvm_type(e, parameter))
		fmt.sbprintfln(&e.b, "  store %s %%arg%d, ptr %s", llvm_type(e, parameter), index, slot)
		bind_local(e, binding, slot)
	}

	// Named results start at their zero value (design.md "Named results").
	for result, index in symbol.results {
		slot := fmt.aprintf("%%r%d.%d", index, next_id(e))
		if emit_result_is_inout(e, index) {
			// The slot holds the address of the place being handed back.
			fmt.sbprintfln(&e.b, "  %s = alloca ptr", slot)
			fmt.sbprintfln(&e.b, "  store ptr null, ptr %s", slot)
			e.result_slots[index] = slot
			if index < len(symbol.result_symbols) && symbol.result_symbols[index] != INVALID_SYMBOL {
				bind_local(e, symbol.result_symbols[index], slot)
			}
			continue
		}
		fmt.sbprintfln(&e.b, "  %s = alloca %s", slot, llvm_type(e, result))
		zero, ok := zero_const(e.c, result)
		if ok {
			fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", llvm_type(e, result), llvm_const(e, zero, result), slot)
		}
		e.result_slots[index] = slot
		if index < len(symbol.result_symbols) && symbol.result_symbols[index] != INVALID_SYMBOL {
			bind_local(e, symbol.result_symbols[index], slot)
		}
	}

	// One `i1` flag per syntactic defer, reset when its scope activates and set
	// when registration is reached, so a loop iteration cannot inherit the
	// previous one's registration.
	e.defer_flags = make([]string, literal.defer_count)
	for index in 0 ..< literal.defer_count {
		flag := fmt.aprintf("%%defer%d.%d", index, next_id(e))
		fmt.sbprintfln(&e.b, "  %s = alloca i1", flag)
		e.defer_flags[index] = flag
	}

	// design.md "Parameter semantics": a `move` parameter transfers ownership to
	// the callee, so the callee drops it. Its scope sits outside the body's,
	// which makes its cleanup the outermost one every exit replays.
	push_scope_stmts(e, nil)
	for parameter, index in symbol.params {
		_ = parameter
		if index < len(symbol.param_symbols) {
			register_implicit_drop(e, symbol.param_symbols[index])
		}
	}

	emit_scoped_block(e, literal.body)
	if !e.terminated {
		emit_return_values(e, nil)
	}
	fmt.sbprintln(&e.b, "}")
	fmt.sbprintln(&e.b, "")

	body := strings.to_string(e.b)
	e.b = module
	emit_unwind_prologue(e)
	strings.write_string(&e.b, body)
	emit_unwind_thunk(e)
	for text in e.pending {
		strings.write_string(&e.b, text)
	}
	clear(&e.pending)
}

@(private = "file")
symbol_param_mode :: proc(c: ^Compiler, symbol: ^Symbol, index: int) -> Param_Mode {
	info := type_of(c, symbol.proc_type)
	if info == nil || index >= len(info.param_modes) {
		return .Value
	}
	return info.param_modes[index]
}

// The C entry point. Internal runtime startup belongs here, which is why
// Loke's `main` is not the C `main`.
@(private = "file")
emit_entry :: proc(e: ^Emitter) {
	emit_thread_local_teardown(e)
	fmt.sbprintln(&e.b, "define i32 @main() {")
	fmt.sbprintln(&e.b, "entry:")
	// design.md "Threads" and m6a-plan decision "Thread runtime": the initial
	// thread attaches like any other, and the same detach that drops managed TLS
	// on a normal return is simply never reached when a panic terminates the
	// process instead.
	fmt.sbprintln(&e.b, "  call void @loke_rt_v1_thread_attach()")
	fmt.sbprintfln(&e.b, "  call void %s()", e.names[entry_symbol(e.c)] or_else "@loke.p.main")
	fmt.sbprintln(&e.b, "  call void @loke_rt_v1_thread_detach()")
	fmt.sbprintln(&e.b, "  ret i32 0")
	fmt.sbprintln(&e.b, "}")
}

// ------------------------------------------------------------ block plumbing --

@(private = "file")
next_id :: proc(e: ^Emitter) -> int {
	e.next += 1
	return e.next
}

@(private = "file")
temp :: proc(e: ^Emitter) -> string {
	return fmt.aprintf("%%t%d", next_id(e))
}

@(private = "file")
new_label :: proc(e: ^Emitter, prefix: string) -> string {
	return fmt.aprintf("%s.%d", prefix, next_id(e))
}

@(private = "file")
place_label :: proc(e: ^Emitter, label: string) {
	if !e.terminated {
		fmt.sbprintfln(&e.b, "  br label %%%s", label)
	}
	fmt.sbprintfln(&e.b, "%s:", label)
	e.terminated = false
}

@(private = "file")
branch :: proc(e: ^Emitter, label: string) {
	if e.terminated {
		return
	}
	fmt.sbprintfln(&e.b, "  br label %%%s", label)
	e.terminated = true
}

@(private = "file")
branch_if :: proc(e: ^Emitter, cond: string, then_label, else_label: string) {
	if e.terminated {
		return
	}
	fmt.sbprintfln(&e.b, "  br i1 %s, label %%%s, label %%%s", cond, then_label, else_label)
	e.terminated = true
}

// ------------------------------------------------------ runtime failures --

// One zero-terminated message constant per distinct text, so the same failure
// reported from twenty places is one global.
@(private = "file")
message_global :: proc(e: ^Emitter, text: string) -> string {
	if existing, found := e.messages[text]; found {
		return existing
	}
	name := fmt.aprintf("@.msg.%d", len(e.messages))
	e.messages[text] = name
	// Module scope, appended at the end: a message is first needed while a
	// function body is being written, and a global cannot be defined inside one.
	append(&e.globals, fmt.aprintf(
		"%s = private unnamed_addr constant [%d x i8] c\"%s\\00\"\n",
		name, len(text) + 1, llvm_escape(text),
	))
	return name
}

// Only printable ASCII reaches here — every message is a compiler-owned literal
// — so the one thing that must be escaped is the quote LLVM's own syntax uses.
@(private = "file")
llvm_escape :: proc(text: string) -> string {
	b := strings.builder_make()
	for index in 0 ..< len(text) {
		ch := text[index]
		if ch < 0x20 || ch >= 0x7f || ch == '"' || ch == '\\' {
			fmt.sbprintf(&b, "\\%02X", ch)
			continue
		}
		strings.write_byte(&b, ch)
	}
	return strings.to_string(b)
}

// The compile-time string a `panic`/`assert` was written with. design.md makes
// it a constant, so the runtime message is a module global rather than anything
// the program has to build.
@(private = "file")
panic_message_text :: proc(e: ^Emitter, v: ^Expr_Call, index: int, fallback: string) -> string {
	if index < len(v.bound) && v.bound[index] != nil {
		if base := expr_base(v.bound[index]); base != nil && base.is_const && base.const_value.kind == .String {
			return base.const_value.text
		}
	}
	return fallback
}

// design.md "Panics and unwinding" enumerates exactly which runtime faults are
// panics. They take the program's panic strategy: under `unwind` the runtime
// replays each active frame's registered cleanup first, and under `abort` no
// frames were ever registered, so the same call terminates at the fault.
@(private = "file")
emit_panic :: proc(e: ^Emitter, message: string) {
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_panic(ptr %s)", message_global(e, message))
	fmt.sbprintln(&e.b, "  unreachable")
	e.terminated = true
}

// The failures that bypass both strategies: an allocator whose policy is
// `.Trap`, and a panic raised while one is already unwinding.
@(private = "file")
emit_abort :: proc(e: ^Emitter, message: string) {
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_abort(ptr %s)", message_global(e, message))
	fmt.sbprintln(&e.b, "  unreachable")
	e.terminated = true
}

// Panics when `cond` holds, and continues in a fresh block otherwise.
@(private = "file")
panic_if :: proc(e: ^Emitter, cond: string, prefix: string, message: string) {
	guard_if(e, cond, prefix, message, emit_panic)
}

@(private = "file")
abort_if :: proc(e: ^Emitter, cond: string, prefix: string, message: string) {
	guard_if(e, cond, prefix, message, emit_abort)
}

@(private = "file")
guard_if :: proc(
	e: ^Emitter,
	cond: string,
	prefix: string,
	message: string,
	fail_with: proc(e: ^Emitter, message: string),
) {
	fail := new_label(e, prefix)
	ok := new_label(e, "ok")
	branch_if(e, cond, fail, ok)
	fmt.sbprintfln(&e.b, "%s:", fail)
	e.terminated = false
	fail_with(e, message)
	fmt.sbprintfln(&e.b, "%s:", ok)
	e.terminated = false
}

// ---------------------------------------------------------- panic unwind --

// Whether this procedure body registers a runtime-visible frame at all. Under
// `-panic=abort` design.md guarantees no cleanup, so nothing is registered and
// no thunk is generated: the strategy is the difference between the two, not a
// runtime flag the frames carry.
@(private = "file")
unwind_enabled :: proc(e: ^Emitter) -> bool {
	return e.c.panic_unwind && !e.unwind.replaying
}

// Fresh registration state for one procedure. The names are chosen before the
// body is emitted, because the body refers to storage whose size — and therefore
// whose defining instruction — is only settled afterwards.
@(private = "file")
begin_unwind_frame :: proc(e: ^Emitter, llvm_name: string) {
	e.unwind = Unwind_State {
		actions        = make([dynamic]Deferred),
		env_index      = make(map[Symbol_Id]int),
		slot_by_symbol = make(map[Symbol_Id]int),
		slot_by_defer  = make(map[int]int),
	}
	if !e.c.panic_unwind {
		return
	}
	id := next_id(e)
	e.unwind.frame = fmt.aprintf("%%uframe.%d", id)
	e.unwind.live = fmt.aprintf("%%ulive.%d", id)
	e.unwind.env = fmt.aprintf("%%uenv.%d", id)
	e.unwind.ctx = fmt.aprintf("%%uctx.%d", id)
	e.unwind.thunk = fmt.aprintf("@loke.u%d.%s", id, strings.trim_prefix(llvm_name, "@"))
}

// Reserves this action's registration slot. Called where the existing cleanup
// entry is built, so the two orders cannot drift apart.
@(private = "file")
unwind_reserve :: proc(e: ^Emitter, entry: ^Deferred) {
	entry.slot = -1
	if !unwind_enabled(e) {
		return
	}
	entry.slot = len(e.unwind.actions)
	append(&e.unwind.actions, entry^)
}

// The env index of a local, assigning one on first use. A cleanup thunk is a
// separate function, so the only way it can reach the parent's storage is
// through a pointer the parent wrote here.
@(private = "file")
unwind_env_slot :: proc(e: ^Emitter, symbol_id: Symbol_Id) -> int {
	if index, found := e.unwind.env_index[symbol_id]; found {
		return index
	}
	index := e.unwind.env_count
	e.unwind.env_count += 1
	e.unwind.env_index[symbol_id] = index
	return index
}

@(private = "file")
unwind_reserve_env :: proc(e: ^Emitter) -> int {
	index := e.unwind.env_count
	e.unwind.env_count += 1
	return index
}

@(private = "file")
unwind_publish_env :: proc(e: ^Emitter, index: int, address: string) {
	if !unwind_enabled(e) || index < 0 || address == "" {
		return
	}
	fmt.sbprintfln(&e.b, "  store ptr %s, ptr %s", address, unwind_env_address(e, index))
}

// Names a local and, when the procedure carries a frame, publishes its address
// into the env so a replayed `defer` can reach it.
//
// ponytail: every local is published, not just the ones a cleanup names. Picking
// the smaller set means a free-variable walk over every deferred statement; one
// extra store per local is cheaper than that pass and cannot be wrong about it.
@(private = "file")
bind_local :: proc(e: ^Emitter, symbol_id: Symbol_Id, name: string) {
	e.names[symbol_id] = name
	if symbol_id == INVALID_SYMBOL || !unwind_enabled(e) || e.unwind.env == "" {
		return
	}
	fmt.sbprintfln(
		&e.b, "  store ptr %s, ptr %s",
		name, unwind_env_address(e, unwind_env_slot(e, symbol_id)),
	)
}

@(private = "file")
unwind_live_address :: proc(e: ^Emitter, slot: int) -> string {
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = getelementptr i8, ptr %s, i64 %d", out, e.unwind.live, slot)
	return out
}

@(private = "file")
unwind_env_address :: proc(e: ^Emitter, index: int) -> string {
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = getelementptr ptr, ptr %s, i64 %d", out, e.unwind.env, index)
	return out
}

// Publishes an action as registered. design.md: the flag is set only once the
// action is *fully* registered, so a panic between "this storage exists" and
// "this value is complete" replays nothing for it. The action's storage is
// already published — `bind_local` did that when the local was named.
@(private = "file")
unwind_register :: proc(e: ^Emitter, entry: Deferred) {
	if entry.slot < 0 || !unwind_enabled(e) {
		return
	}
	fmt.sbprintfln(&e.b, "  store i1 true, ptr %s", unwind_live_address(e, entry.slot))
}

// Clears a registration. Called before the action's own code runs on the normal
// path, so a panic raised *by* a cleanup cannot ask for that cleanup again.
@(private = "file")
unwind_clear :: proc(e: ^Emitter, slot: int) {
	if slot < 0 || !unwind_enabled(e) {
		return
	}
	fmt.sbprintfln(&e.b, "  store i1 false, ptr %s", unwind_live_address(e, slot))
}

// The frame prologue, written once the body is emitted and the two array
// lengths are finally known.
@(private = "file")
emit_unwind_prologue :: proc(e: ^Emitter) {
	u := &e.unwind
	if u.frame == "" {
		return // `-panic=abort`: design.md guarantees no cleanup, so none is tracked
	}
	// `{` is a directive to core:fmt, so the record type is written literally.
	FRAME :: "{ ptr, ptr, ptr }"
	fmt.sbprint(&e.b, "  ")
	fmt.sbprint(&e.b, u.frame)
	fmt.sbprint(&e.b, " = alloca ")
	fmt.sbprintln(&e.b, FRAME)
	fmt.sbprint(&e.b, "  store ")
	fmt.sbprint(&e.b, FRAME)
	fmt.sbprint(&e.b, " zeroinitializer, ptr ")
	fmt.sbprintln(&e.b, u.frame)
	if len(u.actions) == 0 && u.env_count == 0 {
		// Nothing to replay and nothing published, so nothing is pushed. The zeroed
		// record still makes the epilogue's pop a no-op rather than a special case.
		return
	}
	// A procedure with locals but no cleanup still published their addresses, so
	// the env exists even where the live array would be empty. LLVM drops both
	// when nothing reads them.
	fmt.sbprintfln(&e.b, "  %s = alloca [%d x i1]", u.live, max(len(u.actions), 1))
	fmt.sbprintfln(
		&e.b, "  call void @llvm.memset.p0.i64(ptr %s, i8 0, i64 %d, i1 false)",
		u.live, max(len(u.actions), 1),
	)
	fmt.sbprintfln(&e.b, "  %s = alloca [%d x ptr]", u.env, max(u.env_count, 1))
	fmt.sbprintfln(&e.b, "  %s = alloca [2 x ptr]", u.ctx)
	if len(u.actions) == 0 {
		return
	}
	fmt.sbprintfln(&e.b, "  store ptr %s, ptr %s", u.live, u.ctx)
	slot := temp(e)
	fmt.sbprintfln(&e.b, "  %s = getelementptr ptr, ptr %s, i64 1", slot, u.ctx)
	fmt.sbprintfln(&e.b, "  store ptr %s, ptr %s", u.env, slot)
	fmt.sbprintfln(
		&e.b, "  call void @loke_rt_v1_frame_push(ptr %s, ptr %s, ptr %s)",
		u.frame, u.thunk, u.ctx,
	)
}

// Leaving the frame normally. Passing the record rather than popping blindly is
// what lets a procedure that registered nothing share this one path.
@(private = "file")
emit_unwind_pop :: proc(e: ^Emitter) {
	if !unwind_enabled(e) || e.unwind.frame == "" {
		return
	}
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_frame_pop(ptr %s)", e.unwind.frame)
}

// The generated thunk: replay every still-registered action of one frame,
// newest first. Emitted into `e.pending` because LLVM functions do not nest.
@(private = "file")
emit_unwind_thunk :: proc(e: ^Emitter) {
	u := &e.unwind
	if len(u.actions) == 0 {
		return
	}
	saved_body, saved_terminated := e.b, e.terminated
	saved_cleanups := e.cleanups
	e.b = strings.builder_make()
	e.terminated = false
	e.cleanups = make([dynamic]Cleanup_Scope)
	u.replaying = true

	fmt.sbprintf(&e.b, "define private void %s(ptr %%ctx)", u.thunk)
	fmt.sbprintln(&e.b, " {")
	fmt.sbprintln(&e.b, "entry:")
	live, env_slot, env := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = load ptr, ptr %%ctx", live)
	fmt.sbprintfln(&e.b, "  %s = getelementptr ptr, ptr %%ctx, i64 1", env_slot)
	fmt.sbprintfln(&e.b, "  %s = load ptr, ptr %s", env, env_slot)

	// The parent's allocas are unreachable from here, so every local a replayed
	// action names is rebound to its address in the env.
	saved_names := make(map[Symbol_Id]string)
	for symbol_id, index in u.env_index {
		saved_names[symbol_id] = e.names[symbol_id]
		address, value := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = getelementptr ptr, ptr %s, i64 %d", address, env, index)
		fmt.sbprintfln(&e.b, "  %s = load ptr, ptr %s", value, address)
		e.names[symbol_id] = value
	}

	for index := len(u.actions) - 1; index >= 0; index -= 1 {
		entry := u.actions[index]
		flag, address := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = getelementptr i8, ptr %s, i64 %d", address, live, index)
		fmt.sbprintfln(&e.b, "  %s = load i1, ptr %s", flag, address)
		run, skip := new_label(e, "unwind.run"), new_label(e, "unwind.skip")
		branch_if(e, flag, run, skip)
		place_label(e, run)
		fmt.sbprintfln(&e.b, "  store i1 false, ptr %s", address)
		if entry.array_cleanup {
			load_env := proc(e: ^Emitter, env: string, index: int) -> string {
				slot, value := temp(e), temp(e)
				fmt.sbprintfln(&e.b, "  %s = getelementptr ptr, ptr %s, i64 %d", slot, env, index)
				fmt.sbprintfln(&e.b, "  %s = load ptr, ptr %s", value, slot)
				return value
			}
			buffer := load_env(e, env, entry.array_buffer_env)
			flags := load_env(e, env, entry.array_flags_env)
			count := load_env(e, env, entry.array_count_env)
			emit_drop_flagged_array(e, entry.type, buffer, flags, count)
		} else if entry.stmt != nil {
			emit_stmt(e, entry.stmt)
		} else if place, bound := e.names[entry.place_symbol]; bound {
			emit_drop_place(e, entry.type, place)
		}
		branch(e, skip)
		place_label(e, skip)
	}
	fmt.sbprintln(&e.b, "  ret void")
	fmt.sbprintln(&e.b, "}")
	fmt.sbprintln(&e.b, "")

	for symbol_id, name in saved_names {
		e.names[symbol_id] = name
	}
	append(&e.pending, strings.to_string(e.b))
	u.replaying = false
	e.b, e.terminated, e.cleanups = saved_body, saved_terminated, saved_cleanups
}

// -------------------------------------------------------------- cleanups --

@(private = "file")
push_scope :: proc(e: ^Emitter, b: ^Block) {
	push_scope_stmts(e, b == nil ? nil : b.stmts)
}

@(private = "file")
push_scope_stmts :: proc(e: ^Emitter, stmts: []Stmt) {
	append(&e.cleanups, Cleanup_Scope{entries = make([dynamic]Deferred)})
	// Reset the flag of every defer written directly in this scope: the storage
	// is reused across loop iterations, so a stale `true` would run a
	// registration that never happened this time round.
	reset_defer_flags(e, stmts)
}

// A `defer` written inside a selected `when` belongs to the surrounding scope,
// so its flag is reset with that scope's own.
@(private = "file")
reset_defer_flags :: proc(e: ^Emitter, stmts: []Stmt) {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^Stmt_Defer:
			if s.slot < len(e.defer_flags) {
				fmt.sbprintfln(&e.b, "  store i1 false, ptr %s", e.defer_flags[s.slot])
			}
			if slot, registered := e.unwind.slot_by_defer[s.slot]; registered {
				unwind_clear(e, slot)
			}
		case ^Decl:
			// A managed local's hidden flag reuses the same storage across loop
			// iterations, so it needs the same reset a written `defer` gets.
			for symbol_id in s.symbols {
				if flag := drop_flag_of(e, symbol_id); flag != "" {
					fmt.sbprintfln(&e.b, "  store i1 false, ptr %s", flag)
				}
				if slot, registered := e.unwind.slot_by_symbol[symbol_id]; registered {
					unwind_clear(e, slot)
				}
			}
		case ^Stmt_When:
			if selected := when_selected_block(s); selected != nil {
				reset_defer_flags(e, selected.stmts)
			}
		}
	}
}

@(private = "file")
pop_scope :: proc(e: ^Emitter) {
	if len(e.cleanups) == 0 {
		return
	}
	if !e.terminated {
		run_cleanups(e, len(e.cleanups) - 1)
	}
	pop(&e.cleanups)
}

// Runs the deferred statements of every scope above `down_to`, innermost first
// and in reverse registration order within each.
@(private = "file")
run_cleanups :: proc(e: ^Emitter, down_to: int) {
	for depth := len(e.cleanups) - 1; depth >= down_to; depth -= 1 {
		entries := e.cleanups[depth].entries
		for index := len(entries) - 1; index >= 0; index -= 1 {
			entry := entries[index]
			if entry.flag == "" {
				run_one_cleanup(e, entry)
				continue
			}
			flag := temp(e)
			fmt.sbprintfln(&e.b, "  %s = load i1, ptr %s", flag, entry.flag)
			run := new_label(e, "defer.run")
			skip := new_label(e, "defer.skip")
			branch_if(e, flag, run, skip)
			fmt.sbprintfln(&e.b, "%s:", run)
			e.terminated = false
			run_one_cleanup(e, entry)
			branch(e, skip)
			fmt.sbprintfln(&e.b, "%s:", skip)
			e.terminated = false
		}
	}
}

@(private = "file")
run_one_cleanup :: proc(e: ^Emitter, entry: Deferred) {
	// design.md "Panic during unwinding": clearing the registration first is what
	// keeps a panic raised *by* this cleanup from asking for the same cleanup
	// again on the way down.
	unwind_clear(e, entry.slot)
	if entry.stmt != nil {
		emit_stmt(e, entry.stmt)
		return
	}
	emit_drop_place(e, entry.type, entry.place)
}

// -------------------------------------------------------------- statements --

@(private = "file")
emit_scoped_block :: proc(e: ^Emitter, b: ^Block) {
	push_scope(e, b)
	emit_block_statements(e, b)
	pop_scope(e)
}

@(private = "file")
emit_block_statements :: proc(e: ^Emitter, b: ^Block) {
	if b == nil {
		return
	}
	for stmt in b.stmts {
		if e.terminated {
			// Unreachable code still needs a block to live in, or LLVM rejects
			// the instructions that follow a terminator.
			fmt.sbprintfln(&e.b, "unreachable.%d:", next_id(e))
			e.terminated = false
		}
		emit_stmt(e, stmt)
	}
}

@(private = "file")
emit_stmt :: proc(e: ^Emitter, stmt: Stmt) {
	switch s in stmt {
	case ^Stmt_Error:

	case ^Decl:
		emit_local_decl(e, s)

	case ^Stmt_Expr:
		for expr in s.exprs {
			// `#assert` is checked and answered at compile time and has no runtime
			// cost, so there is nothing here to emit.
			if call, is_call := expr.(^Expr_Call); is_call {
				if _, is_hash := call.callee.(^Expr_Hash); is_hash {
					continue
				}
			}
			value := emit_expr(e, expr)
			emit_discarded_temporary(e, expr, value)
		}

	case ^Stmt_Assign:
		emit_assign(e, s)

	case ^Stmt_If:
		emit_if(e, s)

	case ^Stmt_For:
		emit_for(e, s)

	case ^Stmt_Switch:
		if s.kind == .Type {
			emit_type_switch(e, s)
		} else {
			emit_switch(e, s)
		}

	case ^Stmt_Defer:
		if s.slot < len(e.defer_flags) && len(e.cleanups) > 0 {
			entry := Deferred{flag = e.defer_flags[s.slot], stmt = s.stmt}
			unwind_reserve(e, &entry)
			e.unwind.slot_by_defer[s.slot] = entry.slot
			fmt.sbprintfln(&e.b, "  store i1 true, ptr %s", e.defer_flags[s.slot])
			unwind_register(e, entry)
			append(&e.cleanups[len(e.cleanups) - 1].entries, entry)
		}

	case ^Stmt_Return:
		emit_return_values(e, s)

	case ^Stmt_Branch:
		if s.kind == .Break {
			run_cleanups(e, e.break_depth)
			branch(e, e.break_label)
		} else {
			run_cleanups(e, e.continue_depth)
			branch(e, e.continue_label)
		}

	case ^Block:
		emit_scoped_block(e, s)

	case ^Stmt_When:
		// Structural selection: the branch the checker chose is emitted in place,
		// with no scope of its own, so its declarations and `defer`s belong to
		// the surrounding block exactly as written.
		emit_block_statements(e, when_selected_block(s))

	case ^Stmt_Foreach:
		if s.kind == .Unresolved {
			// The checker's L0350 arm gates every statement missing here, so this
			// is a hole in that gate — and skipping it would emit a program that
			// silently does less than the source says.
			backend_fail(e, "an unresolved statement reached emission")
			return
		}
		emit_foreach(e, s)
	}
}

@(private = "file")
emit_local_decl :: proc(e: ^Emitter, d: ^Decl) {
	// A call filling several names evaluates once.
	if len(d.values) == 1 && len(d.symbols) > 1 {
		if base := expr_base(d.values[0]); base != nil && len(base.result_types) == len(d.symbols) {
			results := emit_multi_value(e, d.values[0])
			for symbol_id, index in d.symbols {
				slot := declare_local(e, symbol_id)
				if slot != "" {
					store(e, base.result_types[index], results[index], slot)
					register_implicit_drop(e, symbol_id)
				}
			}
			return
		}
	}
	for symbol_id, i in d.symbols {
		sym := symbol_of(e.c, symbol_id)
		// Constants are folded at every use, so they need no storage.
		if sym == nil || sym.kind != .Var {
			continue
		}
		// Static-duration storage was emitted at module level and initialised
		// before any code ran, so reaching the declaration writes nothing.
		if sym.duration != .None {
			continue
		}
		slot := declare_local(e, symbol_id)
		if i < len(d.values) && d.values[i] == nil {
			continue // `---`: storage without an initial value
		}
		if i < len(d.values) && d.values[i] != nil {
			value := emit_expr(e, d.values[i])
			if i < len(d.value_clones) && d.value_clones[i] {
				value = emit_clone_value(e, sym.type, value, emit_destination_allocator(e, symbol_id))
			}
			store(e, sym.type, value, slot)
			register_implicit_drop(e, symbol_id)
			continue
		}
		zero, ok := zero_const(e.c, sym.type)
		if ok {
			store(e, sym.type, llvm_const(e, zero, sym.type), slot)
		}
		// design.md "Allocators": a written `via` is *eager* — the provider is
		// selected where the declaration is evaluated, so a later operation on this
		// container allocates through it rather than lazily binding the default.
		emit_eager_via_binding(e, symbol_id, slot)
		register_implicit_drop(e, symbol_id)
	}
}

// design.md: "A managed local declaration places an implicit conditional
// `defer drop(value)` at the declaration point." Registration is what fixes its
// position in the one reverse order every exit replays.
@(private = "file")
register_implicit_drop :: proc(e: ^Emitter, symbol_id: Symbol_Id) {
	sym := symbol_of(e.c, symbol_id)
	if sym == nil {
		return
	}
	// The flag says "this place holds a value", which an assignment's drop reads
	// as well as cleanup, so it is set whenever one exists.
	flag := drop_flag_of(e, symbol_id)
	if flag != "" {
		fmt.sbprintfln(&e.b, "  store i1 true, ptr %s", flag)
	}
	if !sym.drop_at_exit || len(e.cleanups) == 0 {
		return
	}
	entry := Deferred{flag = flag, place = e.names[symbol_id], place_symbol = symbol_id, type = sym.type}
	unwind_reserve(e, &entry)
	e.unwind.slot_by_symbol[symbol_id] = entry.slot
	unwind_register(e, entry)
	append(&e.cleanups[len(e.cleanups) - 1].entries, entry)
}

// The hidden `i1` of a conditionally live local, or "" when the CFG left its
// state definite at every cleanup point.
@(private = "file")
drop_flag_of :: proc(e: ^Emitter, symbol_id: Symbol_Id) -> string {
	sym := symbol_of(e.c, symbol_id)
	if sym == nil || !sym.drop_conditional || sym.cleanup_slot >= len(e.defer_flags) {
		return ""
	}
	return e.defer_flags[sym.cleanup_slot]
}

// `move(x)` and `drop(x)` both leave the source dead: the inert zero
// representation is written, and a conditional slot records that its cleanup
// must not run again.
@(private = "file")
kill_place :: proc(e: ^Emitter, symbol_id: Symbol_Id) {
	sym := symbol_of(e.c, symbol_id)
	if sym == nil {
		return
	}
	if zero, ok := zero_const(e.c, sym.type); ok {
		store(e, sym.type, llvm_const(e, zero, sym.type), e.names[symbol_id])
	}
	if flag := drop_flag_of(e, symbol_id); flag != "" {
		fmt.sbprintfln(&e.b, "  store i1 false, ptr %s", flag)
	}
	// The same fact the drop flag records, made visible to a panic: this place no
	// longer holds a value, so its registered cleanup must not be replayed.
	if slot, registered := e.unwind.slot_by_symbol[symbol_id]; registered {
		unwind_clear(e, slot)
	}
}

// design.md "Storage modifiers": `drop(value)` "runs the cleanup operation,
// writes the inert zero representation, and marks the variable dead".
@(private = "file")
emit_explicit_drop :: proc(e: ^Emitter, v: ^Expr_Call) {
	ident, is_ident := v.bound[0].(^Expr_Ident)
	if !is_ident {
		backend_fail(e, "`drop` has no named operand")
		return
	}
	sym := symbol_of(e.c, ident.symbol)
	if sym == nil {
		return
	}
	emit_drop_place(e, sym.type, e.names[ident.symbol])
	kill_place(e, ident.symbol)
}

// design.md: an owning temporary nothing binds is still a completed
// initialization, so it is cleaned up exactly once.
//
// ponytail: dropped at its full-expression boundary rather than registered in
// the surrounding scope's reverse order. Nothing can name it, so the only
// observable difference is ordering against other cleanups — and registering it
// would drop one value per emitted statement rather than one per loop iteration.
@(private = "file")
emit_discarded_temporary :: proc(e: ^Emitter, expr: Expr, value: string) {
	base := expr_base(expr)
	if base == nil || !type_is_managed(e.c, base.type) {
		return
	}
	// A place names storage someone else owns; only an owned temporary is ours
	// to clean up.
	if expression_is_borrowed_place(e.c, expr) {
		return
	}
	slot := temp(e)
	fmt.sbprintfln(&e.b, "  %s = alloca %s", slot, llvm_type(e, base.type))
	store(e, base.type, value, slot)
	emit_drop_place(e, base.type, slot)
}

// design.md "Exchange": "The compiler evaluates the destination place once and
// then evaluates `replacement` completely before modifying the destination. If
// evaluation or construction of the replacement fails or panics, the destination
// remains unchanged. Once the replacement is ready, the compiler moves the old
// value into result storage and moves the replacement into the destination as one
// lifecycle operation."
//
// So the order below is the specification: address, replacement, load, store. No
// hook runs between the two moves — the old value is handed back rather than
// dropped, and the destination is never observably dead.
@(private = "file")
emit_exchange :: proc(e: ^Emitter, v: ^Expr_Call) -> string {
	address := emit_address(e, v.bound[0])
	replacement := emit_expr(e, v.bound[1])
	previous := temp(e)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", previous, llvm_type(e, v.type), address)
	store(e, v.type, replacement, address)
	return previous
}

// design.md "Assignment statements": `move` "transfers the representation,
// writes the inert zero representation to a lexical source, and marks that
// source dead".
@(private = "file")
emit_move :: proc(e: ^Emitter, v: ^Expr_Move) -> string {
	value := emit_expr(e, v.value)
	if ident, is_ident := v.value.(^Expr_Ident); is_ident {
		kill_place(e, ident.symbol)
	}
	return value
}

@(private = "file")
declare_local :: proc(e: ^Emitter, symbol_id: Symbol_Id) -> string {
	sym := symbol_of(e.c, symbol_id)
	if sym == nil || sym.kind != .Var {
		return ""
	}
	name := fmt.aprintf("%%%s.%d", identifier_text(e.c, sym.name), next_id(e))
	fmt.sbprintfln(&e.b, "  %s = alloca %s", name, llvm_type(e, sym.type))
	bind_local(e, symbol_id, name)
	return name
}

// design.md "Assignment statements": every right side is evaluated, then every
// destination address, then the writes happen. Nothing is written before all of
// both are prepared.
@(private = "file")
emit_assign :: proc(e: ^Emitter, s: ^Stmt_Assign) {
	if s.op != .Assign {
		emit_compound_assign(e, s)
		return
	}
	// `operator([]=)`: a container with no location to hand out.
	if s.place_setter != INVALID_SYMBOL {
		emit_operator_call(e, s.place_setter, s.setter_bound)
		return
	}

	values: []string
	types: []Type_Id
	if len(s.rhs) == 1 && len(s.lhs) > 1 {
		values = emit_multi_value(e, s.rhs[0])
		types = expr_base(s.rhs[0]).result_types
	} else {
		values = make([]string, len(s.rhs))
		types = make([]Type_Id, len(s.rhs))
		for value, index in s.rhs {
			values[index] = emit_expr(e, value)
			// design.md: the clone happens before the destination is touched, so a
			// failure leaves a previously live destination unchanged.
			if index < len(s.rhs_clones) && s.rhs_clones[index] {
				values[index] = emit_clone_value(
					e, expr_base(s.lhs[index]).type, values[index],
					emit_destination_allocator(e, place_root_symbol(e.c, s.lhs[index])),
				)
			}
			types[index] = expr_base(value).type
		}
	}

	addresses := make([]string, len(s.lhs))
	for target, index in s.lhs {
		if is_discard(target) {
			continue
		}
		addresses[index] = emit_address(e, target)
	}
	for target, index in s.lhs {
		if addresses[index] == "" || index >= len(values) {
			continue
		}
		emit_replace_place(e, s, index, addresses[index])
		store(e, expr_base(target).type, values[index], addresses[index])
	}
}

// design.md "Assignment statements": the assignment `drop(destination)` between
// a successful clone and the write. The destination's state decides whether it
// happens at all — a definitely dead one holds nothing, and a conditional one
// asks its hidden flag.
@(private = "file")
emit_replace_place :: proc(e: ^Emitter, s: ^Stmt_Assign, index: int, address: string) {
	target := s.lhs[index]
	type := expr_base(target).type
	if !type_is_managed(e.c, type) {
		return
	}
	state := index < len(s.destination_live) ? s.destination_live[index] : Liveness.Live
	if state == .Dead {
		return
	}
	flag := ""
	if ident, is_ident := target.(^Expr_Ident); is_ident {
		flag = drop_flag_of(e, ident.symbol)
	}
	if state == .Live || flag == "" {
		emit_drop_place(e, type, address)
	} else {
		live := temp(e)
		fmt.sbprintfln(&e.b, "  %s = load i1, ptr %s", live, flag)
		run, skip := new_label(e, "replace.drop"), new_label(e, "replace.done")
		branch_if(e, live, run, skip)
		place_label(e, run)
		emit_drop_place(e, type, address)
		branch(e, skip)
		place_label(e, skip)
	}
	// The place holds a value again from here.
	if ident, is_ident := target.(^Expr_Ident); is_ident && flag != "" {
		fmt.sbprintfln(&e.b, "  store i1 true, ptr %s", flag)
	}
}

// The destination is evaluated once, before the right operand.
@(private = "file")
emit_compound_assign :: proc(e: ^Emitter, s: ^Stmt_Assign) {
	target := s.lhs[0]
	if s.operator != INVALID_SYMBOL {
		operands := [2]Expr{target, s.rhs[0]}
		if s.operator_direct {
			// A direct `+=` overload writes through its `inout` destination.
			emit_operator_call(e, s.operator, operands[:])
			return
		}
		// The fallback: the binary operator, then an ordinary assignment.
		address := emit_address(e, target)
		value := emit_operator_call(e, s.operator, operands[:])
		store(e, expr_base(target).type, value, address)
		return
	}
	type := expr_base(target).type
	address := emit_address(e, target)
	current := temp(e)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", current, llvm_type(e, type), address)
	rhs := emit_expr(e, s.rhs[0])
	op := compound_op(s.op)
	result := emit_binary_op(e, op, type, expr_base(s.rhs[0]).type, current, rhs)
	store(e, type, result, address)
}

@(private = "file")
compound_op :: proc(op: Token_Kind) -> Token_Kind {
	#partial switch op {
	case .Plus_Eq:
		return .Plus
	case .Minus_Eq:
		return .Minus
	case .Star_Eq:
		return .Star
	case .Slash_Eq:
		return .Slash
	case .Percent_Eq:
		return .Percent
	case .Pipe_Eq:
		return .Pipe
	case .Tilde_Eq:
		return .Tilde
	case .Amp_Eq:
		return .Amp
	case .Amp_Tilde_Eq:
		return .Amp_Tilde
	case .Shl_Eq:
		return .Shl
	case .Shr_Eq:
		return .Shr
	}
	return .Plus
}

@(private = "file")
is_discard :: proc(target: Expr) -> bool {
	ident, ok := target.(^Expr_Ident)
	return ok && ident.name == "_"
}

@(private = "file")
emit_if :: proc(e: ^Emitter, s: ^Stmt_If) {
	push_scope(e, nil)
	if s.init != nil {
		emit_stmt(e, s.init)
	}
	cond := emit_expr(e, s.cond)
	then_label := new_label(e, "if.then")
	else_label := new_label(e, "if.else")
	done_label := new_label(e, "if.done")
	branch_if(e, cond, then_label, s.otherwise == nil ? done_label : else_label)

	fmt.sbprintfln(&e.b, "%s:", then_label)
	e.terminated = false
	emit_scoped_block(e, s.then)
	branch(e, done_label)

	if s.otherwise != nil {
		fmt.sbprintfln(&e.b, "%s:", else_label)
		e.terminated = false
		emit_stmt(e, s.otherwise)
		branch(e, done_label)
	}
	fmt.sbprintfln(&e.b, "%s:", done_label)
	e.terminated = false
	pop_scope(e)
}

@(private = "file")
emit_for :: proc(e: ^Emitter, s: ^Stmt_For) {
	outer_break, outer_continue := e.break_label, e.continue_label
	outer_break_depth, outer_continue_depth := e.break_depth, e.continue_depth
	defer {
		e.break_label, e.continue_label = outer_break, outer_continue
		e.break_depth, e.continue_depth = outer_break_depth, outer_continue_depth
	}

	// The loop's own scope holds the init declaration; `break` leaves it too.
	e.break_depth = len(e.cleanups)
	push_scope(e, nil)
	if s.init != nil {
		emit_stmt(e, s.init)
	}

	head := new_label(e, "for.head")
	body := new_label(e, "for.body")
	post := new_label(e, "for.post")
	done := new_label(e, "for.done")
	e.break_label = done
	e.continue_label = post
	e.continue_depth = len(e.cleanups)

	place_label(e, head)
	if s.cond != nil {
		branch_if(e, emit_expr(e, s.cond), body, done)
	} else {
		branch(e, body)
	}

	fmt.sbprintfln(&e.b, "%s:", body)
	e.terminated = false
	emit_scoped_block(e, s.body)
	branch(e, post)

	fmt.sbprintfln(&e.b, "%s:", post)
	e.terminated = false
	if s.post != nil {
		emit_stmt(e, s.post)
	}
	branch(e, head)

	fmt.sbprintfln(&e.b, "%s:", done)
	e.terminated = false
	pop_scope(e)
}

// ponytail: one ordered comparison chain rather than an LLVM `switch` for the
// all-constant case. Ranges and non-constant cases need the chain anyway, and a
// second lowering would have to agree with this one about source order. Add the
// jump table when a measured switch is hot.
@(private = "file")
emit_switch :: proc(e: ^Emitter, s: ^Stmt_Switch) {
	outer_break, outer_break_depth := e.break_label, e.break_depth
	defer {
		e.break_label = outer_break
		e.break_depth = outer_break_depth
	}

	e.break_depth = len(e.cleanups)
	push_scope(e, nil)
	if s.init != nil {
		emit_stmt(e, s.init)
	}
	subject_type := expr_base(s.subject).type
	subject := emit_expr(e, s.subject)

	done := new_label(e, "switch.done")
	e.break_label = done

	bodies := make([]string, len(s.cases))
	tests := make([]string, len(s.cases))
	for index in 0 ..< len(s.cases) {
		bodies[index] = new_label(e, "case.body")
		tests[index] = new_label(e, "case.test")
	}
	default_index := -1
	for entry, index in s.cases {
		if len(entry.values) == 0 {
			default_index = index
		}
	}

	// Value cases are tested in source order; the default is the fallthrough of
	// the last of them, wherever it was written.
	order := make([dynamic]int)
	defer delete(order)
	for entry, index in s.cases {
		if len(entry.values) > 0 {
			append(&order, index)
		}
	}
	fallback := default_index >= 0 ? bodies[default_index] : done

	branch(e, len(order) > 0 ? tests[order[0]] : fallback)
	for case_index, position in order {
		fmt.sbprintfln(&e.b, "%s:", tests[case_index])
		e.terminated = false
		next := position + 1 < len(order) ? tests[order[position + 1]] : fallback
		matched := ""
		for value in s.cases[case_index].values {
			test := emit_case_test(e, subject, subject_type, value)
			if matched == "" {
				matched = test
			} else {
				combined := temp(e)
				fmt.sbprintfln(&e.b, "  %s = or i1 %s, %s", combined, matched, test)
				matched = combined
			}
		}
		branch_if(e, matched, bodies[case_index], next)
	}

	for entry, index in s.cases {
		fmt.sbprintfln(&e.b, "%s:", bodies[index])
		e.terminated = false
		push_scope_stmts(e, entry.stmts)
		for stmt in entry.stmts {
			if e.terminated {
				fmt.sbprintfln(&e.b, "unreachable.%d:", next_id(e))
				e.terminated = false
			}
			emit_stmt(e, stmt)
		}
		pop_scope(e)
		branch(e, done)
	}

	fmt.sbprintfln(&e.b, "%s:", done)
	e.terminated = false
	pop_scope(e)
}

// A type switch dispatches on the tag. Each case binds its own name: at the
// variant's type where one is known, and at the union's type where a case names
// several types or is the default.
@(private = "file")
emit_type_switch :: proc(e: ^Emitter, s: ^Stmt_Switch) {
	outer_break, outer_break_depth := e.break_label, e.break_depth
	defer {
		e.break_label = outer_break
		e.break_depth = outer_break_depth
	}

	e.break_depth = len(e.cleanups)
	push_scope(e, nil)
	if s.init != nil {
		emit_stmt(e, s.init)
	}
	union_type := expr_base(s.subject).type
	// An `any_view` switch compares the stored `typeid` and reads through the
	// data pointer; a union switch compares its tag and reads its payload.
	erased := union_type == TYPE_ANY_VIEW
	tag_llvm := "i64"
	value := emit_expr(e, s.subject)
	slot := ""
	tag := ""
	if erased {
		storage := llvm_type(e, TYPE_ANY_VIEW)
		slot = temp(e)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", slot, storage, value, ANY_VIEW_DATA)
		tag = temp(e)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", tag, storage, value, ANY_VIEW_ID)
	} else {
		shape := union_layout(e.c, union_type)
		tag_llvm = fmt.aprintf("i%d", shape.tag_bytes * 8)
		slot = emit_union_spill(e, union_type, value)
		tag = emit_union_tag(e, union_type, value)
	}

	done := new_label(e, "typeswitch.done")
	e.break_label = done

	bodies := make([]string, len(s.cases))
	tests := make([]string, len(s.cases))
	for index in 0 ..< len(s.cases) {
		bodies[index] = new_label(e, "typecase.body")
		tests[index] = new_label(e, "typecase.test")
	}
	default_index := -1
	order := make([dynamic]int)
	defer delete(order)
	for entry, index in s.cases {
		if len(entry.values) == 0 {
			default_index = index
		} else {
			append(&order, index)
		}
	}
	fallback := default_index >= 0 ? bodies[default_index] : done

	branch(e, len(order) > 0 ? tests[order[0]] : fallback)
	for case_index, position in order {
		fmt.sbprintfln(&e.b, "%s:", tests[case_index])
		e.terminated = false
		next := position + 1 < len(order) ? tests[order[position + 1]] : fallback
		matched := ""
		for variant_expr in s.cases[case_index].values {
			variant := expr_base(variant_expr).denoted_type
			test := temp(e)
			discriminant := erased ? typeid_value(e.c, variant) : u64(union_variant_tag(e.c, union_type, variant))
			fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, %d", test, tag_llvm, tag, discriminant)
			if matched == "" {
				matched = test
			} else {
				combined := temp(e)
				fmt.sbprintfln(&e.b, "  %s = or i1 %s, %s", combined, matched, test)
				matched = combined
			}
		}
		branch_if(e, matched, bodies[case_index], next)
	}

	for entry, index in s.cases {
		fmt.sbprintfln(&e.b, "%s:", bodies[index])
		e.terminated = false
		push_scope_stmts(e, entry.stmts)
		emit_type_case_binding(e, entry, union_type, value, slot, erased)
		for stmt in entry.stmts {
			if e.terminated {
				fmt.sbprintfln(&e.b, "unreachable.%d:", next_id(e))
				e.terminated = false
			}
			emit_stmt(e, stmt)
		}
		pop_scope(e)
		branch(e, done)
	}

	fmt.sbprintfln(&e.b, "%s:", done)
	e.terminated = false
	pop_scope(e)
}

@(private = "file")
emit_type_case_binding :: proc(e: ^Emitter, entry: Switch_Case, union_type: Type_Id, value, slot: string, erased := false) {
	if entry.binding_symbol == INVALID_SYMBOL {
		return
	}
	binding := fmt.aprintf("%%bind.%d", next_id(e))
	fmt.sbprintfln(&e.b, "  %s = alloca %s", binding, llvm_type(e, entry.binding_type))
	bind_local(e, entry.binding_symbol, binding)
	if erased {
		if entry.binding_type == union_type {
			fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", llvm_type(e, union_type), value, binding)
			return
		}
		// A concrete case reads the erased value through the data pointer.
		loaded := temp(e)
		fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", loaded, llvm_type(e, entry.binding_type), slot)
		store(e, entry.binding_type, loaded, binding)
		return
	}
	if entry.binding_type == union_type {
		fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", llvm_type(e, union_type), value, binding)
		return
	}
	payload := emit_union_payload(e, union_type, entry.binding_type, slot)
	store(e, entry.binding_type, payload, binding)
}

@(private = "file")
emit_case_test :: proc(e: ^Emitter, subject: string, subject_type: Type_Id, value: Expr) -> string {
	if range, is_range := value.(^Expr_Range); is_range {
		lo := emit_expr(e, range.lo)
		hi := emit_expr(e, range.hi)
		low_ok := emit_compare(e, .Gt_Eq, subject_type, subject, lo)
		high_op := range.op == .Range_Excl ? Token_Kind.Lt : Token_Kind.Lt_Eq
		high_ok := emit_compare(e, high_op, subject_type, subject, hi)
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = and i1 %s, %s", out, low_ok, high_ok)
		return out
	}
	return emit_equal(e, subject_type, subject, emit_expr(e, value))
}

// ----------------------------------------------------------------- returns --

// Return values move into the result slots before any cleanup runs, so a
// deferred statement cannot change what is returned.
@(private = "file")
emit_return_values :: proc(e: ^Emitter, s: ^Stmt_Return) {
	if s != nil && len(s.values) > 0 {
		if len(s.values) == 1 && len(e.result_types) > 1 {
			if base := expr_base(s.values[0].expr); base != nil && len(base.result_types) == len(e.result_types) {
				results := emit_multi_value(e, s.values[0].expr)
				for value, index in results {
					store(e, e.result_types[index], value, e.result_slots[index])
				}
				emit_epilogue(e)
				return
			}
		}
		values := make([]string, len(s.values))
		for value, index in s.values {
			// An `inout` result hands back the place itself, not a copy of it.
			if emit_result_is_inout(e, index) {
				values[index] = emit_address(e, value.expr)
			} else {
				values[index] = emit_expr(e, value.expr)
			}
			if value.clone_on_return && index < len(e.result_types) {
				values[index] = emit_clone_value(e, e.result_types[index], values[index])
			}
		}
		for value, index in values {
			if index >= len(e.result_slots) {
				continue
			}
			if emit_result_is_inout(e, index) {
				fmt.sbprintfln(&e.b, "  store ptr %s, ptr %s", value, e.result_slots[index])
			} else {
				store(e, e.result_types[index], value, e.result_slots[index])
			}
		}
		// The result is in result storage before cleanup runs, so a transferred
		// local can be marked dead here without the epilogue dropping what was
		// just handed back (design.md "Managed values and storage").
		for value in s.values {
			if value.clone_on_return {
				continue
			}
			if ident, is_ident := value.expr.(^Expr_Ident); is_ident {
				if sym := symbol_of(e.c, ident.symbol); sym != nil && type_is_managed(e.c, sym.type) {
					kill_place(e, ident.symbol)
				}
			}
		}
	}
	emit_epilogue(e)
}

// design.md: an implicit copy — a binding, an assignment, or the return of a
// borrowed managed owner — goes through `clone`, the policy-following entry
// point. It calls `try_clone` once and applies the allocator's failure policy,
// so a failure never reaches a half-written destination.
//
// `allocator` is the destination's selected provider: its written `via`, or the
// default when the declaration has no policy (m6b-plan decision "Allocator
// binding").
@(private = "file")
emit_clone_value :: proc(e: ^Emitter, type: Type_Id, value: string, allocator := RT_DEFAULT_ALLOCATOR) -> string {
	entry := lifecycle_of(e.c, type)
	// design.md "Dynamic arrays"/"Maps": a container's copy is a deep clone, so
	// an implicit copy duplicates the storage through the C helper and applies
	// the allocator's failure policy — there is nowhere here to return an error.
	if entry.container {
		source, destination := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = alloca %s", source, CONTAINER_TYPE)
		fmt.sbprintfln(&e.b, "  %s = alloca %s", destination, CONTAINER_TYPE)
		fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", CONTAINER_TYPE, value, source)
		ok := emit_try_clone_into(e, type, destination, source, allocator)
		fail_label, done_label := new_label(e, "cclone.fail"), new_label(e, "cclone.done")
		branch_if(e, ok, done_label, fail_label)
		place_label(e, fail_label)
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_alloc_failed(ptr %s)", allocator)
		branch(e, done_label)
		place_label(e, done_label)
		e.terminated = false
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", out, CONTAINER_TYPE, destination)
		return out
	}
	// design.md "string type": "cheap value copy; immutable backing storage may
	// be shared". An implicit copy of a string retains a handle; only `.clone()`
	// allocates, and that is a written call, not this path.
	if entry.intrinsic {
		owner := temp(e)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", owner, STRING_TYPE, value, STRING_OWNER)
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_string_retain(i64 %s)", owner)
		return value
	}
	hook := type_hook(e.c, type, "clone")
	if hook == INVALID_SYMBOL {
		backend_fail(e, "an implicit copy has no `clone` member")
		return "0"
	}
	out := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call %s %s(%s %s, ptr %s)",
		out, llvm_type(e, type), e.names[hook], llvm_type(e, type), value, allocator,
	)
	return out
}

@(private = "file")
emit_epilogue :: proc(e: ^Emitter) {
	run_cleanups(e, 0)
	// This frame is leaving normally, so it is no longer one a panic can call
	// back into.
	emit_unwind_pop(e)
	slot_type :: proc(e: ^Emitter, index: int) -> string {
		return emit_result_is_inout(e, index) ? "ptr" : llvm_type(e, e.result_types[index])
	}
	switch len(e.result_types) {
	case 0:
		fmt.sbprintln(&e.b, "  ret void")
	case 1:
		value := temp(e)
		fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", value, slot_type(e, 0), e.result_slots[0])
		fmt.sbprintfln(&e.b, "  ret %s %s", slot_type(e, 0), value)
	case:
		aggregate := "undef"
		result_type := llvm_result_type(e, e.result_types, e.result_inout)
		for _, index in e.result_types {
			value := temp(e)
			fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", value, slot_type(e, index), e.result_slots[index])
			next := temp(e)
			fmt.sbprintfln(
				&e.b,
				"  %s = insertvalue %s %s, %s %s, %d",
				next, result_type, aggregate, slot_type(e, index), value, index,
			)
			aggregate = next
		}
		fmt.sbprintfln(&e.b, "  ret %s %s", result_type, aggregate)
	}
	e.terminated = true
}

// ------------------------------------------------------------------ places --

@(private = "file")
store :: proc(e: ^Emitter, type: Type_Id, value, address: string) {
	if address == "" || value == "" {
		return
	}
	fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", llvm_type(e, type), value, address)
}

// The address of a place. Composite literals get temporary storage here, which
// is what makes `&Point{1, 2}` work.
@(private = "file")
emit_address :: proc(e: ^Emitter, expr: Expr) -> string {
	// design.md "Materialization": every runtime use of one constant shares one
	// read-only object, so the address is the global the checker registered.
	if entry := materialization_of(e.c, expr); entry != nil {
		return entry.name
	}
	#partial switch v in expr {
	case ^Expr_Ident:
		if name, ok := e.names[v.symbol]; ok {
			return name
		}
		backend_fail(e, "a resolved place has no storage")
		return "null"

	case ^Expr_Postfix:
		pointer := emit_expr(e, v.operand)
		emit_nil_check(e, pointer)
		return pointer

	case ^Expr_Selector:
		symbol := symbol_of(e.c, v.resolution.symbol)
		base_type, base_address := emit_base_address(e, v.operand)
		out := temp(e)
		fmt.sbprintfln(
			&e.b,
			"  %s = getelementptr inbounds %s, ptr %s, i32 0, i32 %d",
			out, llvm_type(e, base_type), base_address, symbol.index,
		)
		return out

	case ^Expr_Index:
		// An `operator([])` returning `inout T` hands back the address itself.
		if v.resolution.kind == .User_Operator {
			return emit_operator_call(e, v.resolution.symbol, v.bound)
		}
		// A slice element lives in the root, reached through the data word, and its
		// bound is the runtime length rather than a static count.
		if type_is_slice(e.c, expr_base(v.operand).type) {
			return emit_slice_element_address(e, v)
		}
		// A dynamic array's element lives behind its data word, bounded by its
		// length word: the same two loads, read out of the container header.
		if type_is_dynamic_array(e.c, expr_base(v.operand).type) {
			return emit_dynamic_element_address(e, v)
		}
		if type_is_map(e.c, expr_base(v.operand).type) {
			// design.md: only a real place position inserts. A read reached through
			// a field chain — `m[key].x` as a value — still needs an address, and it
			// is the existing slot's or a zeroed temporary's.
			if v.map_inserts {
				return emit_map_place(e, v)
			}
			address, _ := emit_map_read_address(e, v)
			return address
		}
		// design.md "Multi-pointers": "Indexing without bounds checking." There is
		// no length to check against, which is exactly what the type says.
		if operand_info := type_of(e.c, type_underlying(e.c, expr_base(v.operand).type));
		   operand_info != nil && operand_info.kind == .Multi_Pointer {
			data := emit_expr(e, v.operand)
			index := widen_to_i64(e, emit_expr(e, v.indices[0]), expr_base(v.indices[0]).type)
			out := temp(e)
			fmt.sbprintfln(
				&e.b, "  %s = getelementptr inbounds %s, ptr %s, i64 %s",
				out, llvm_type(e, operand_info.element), data, index,
			)
			return out
		}
		base_type, base_address := emit_base_address(e, v.operand)
		info := type_of(e.c, type_underlying(e.c, base_type))
		index := emit_expr(e, v.indices[0])
		index = emit_bounds_check(e, index, expr_base(v.indices[0]).type, info.count)
		out := temp(e)
		fmt.sbprintfln(
			&e.b,
			"  %s = getelementptr inbounds %s, ptr %s, i64 0, i64 %s",
			out, llvm_type(e, base_type), base_address, index,
		)
		return out

	case ^Expr_Composite:
		slot := temp(e)
		fmt.sbprintfln(&e.b, "  %s = alloca %s", slot, llvm_type(e, v.type))
		emit_composite_into(e, v, slot)
		return slot
	}
	// Any other addressable expression is materialised into a temporary.
	type := expr_base(expr).type
	slot := temp(e)
	fmt.sbprintfln(&e.b, "  %s = alloca %s", slot, llvm_type(e, type))
	store(e, type, emit_expr(e, expr), slot)
	return slot
}

// `xs[i]`: the element's address inside the container's current allocation,
// bounds-checked against the header's length word. design.md: "Indexing and
// slicing produce views into the current allocation", so this address is exactly
// as long-lived as that allocation — which is what the M5b invalidation events
// registered by every relocating operation are there to enforce.
@(private = "file")
emit_dynamic_element_address :: proc(e: ^Emitter, v: ^Expr_Index) -> string {
	operand_type := expr_base(v.operand).type
	header := emit_address(e, v.operand)
	data, length := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = load ptr, ptr %s", data, header)
	length_slot := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = getelementptr inbounds %s, ptr %s, i32 0, i32 %d",
		length_slot, CONTAINER_TYPE, header, CONTAINER_LEN,
	)
	fmt.sbprintfln(&e.b, "  %s = load i64, ptr %s", length, length_slot)

	index := widen_to_i64(e, emit_expr(e, v.indices[0]), expr_base(v.indices[0]).type)
	// Unsigned, so a negative index is caught by the same comparison as an
	// oversized one.
	out_of_range := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp uge i64 %s, %s", out_of_range, index, length)
	panic_if(e, out_of_range, "bounds", "index out of range")

	out := temp(e)
	fmt.sbprintfln(
		&e.b,
		"  %s = getelementptr inbounds %s, ptr %s, i64 %s",
		out, llvm_type(e, container_element(e.c, operand_type)), data, index,
	)
	return out
}

// `s[i]`: the element's address inside the slice's root, bounds-checked against
// the runtime length word.
@(private = "file")
emit_slice_element_address :: proc(e: ^Emitter, v: ^Expr_Index) -> string {
	operand_type := expr_base(v.operand).type
	slice := emit_expr(e, v.operand)
	llvm := llvm_type(e, operand_type)
	data, length := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", data, llvm, slice, SLICE_DATA)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", length, llvm, slice, SLICE_LEN)

	index := widen_to_i64(e, emit_expr(e, v.indices[0]), expr_base(v.indices[0]).type)
	// Unsigned, so a negative index is caught by the same comparison as an
	// oversized one.
	out_of_range := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp uge i64 %s, %s", out_of_range, index, length)
	panic_if(e, out_of_range, "bounds", "index out of range")

	out := temp(e)
	fmt.sbprintfln(
		&e.b,
		"  %s = getelementptr inbounds %s, ptr %s, i64 %s",
		out, llvm_type(e, slice_element(e.c, operand_type)), data, index,
	)
	return out
}

// `p.x` and `p[i]` accept one pointer hop, in which case the pointer value
// itself is the base address.
@(private = "file")
emit_base_address :: proc(e: ^Emitter, operand: Expr) -> (Type_Id, string) {
	type := expr_base(operand).type
	info := type_of(e.c, type_underlying(e.c, type))
	if info != nil && info.kind == .Pointer {
		pointer := emit_expr(e, operand)
		emit_nil_check(e, pointer)
		return info.element, pointer
	}
	return type, emit_address(e, operand)
}

@(private = "file")
emit_nil_check :: proc(e: ^Emitter, pointer: string) {
	is_nil := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", is_nil, pointer)
	panic_if(e, is_nil, "nil.deref", "nil pointer dereference")
}

// A built-in slice expression: `base[lo:hi]` over a fixed array or another
// slice. The base and both bounds are each evaluated once, in written order,
// then checked as `0 <= lo <= hi <= len` before any address is formed.
@(private = "file")
emit_builtin_slice :: proc(e: ^Emitter, v: ^Expr_Slice) -> string {
	operand_type := expr_base(v.operand).type
	info := type_of(e.c, type_underlying(e.c, operand_type))
	element := info.element

	data, length := "", ""
	#partial switch info.kind {
	case .String, .String_View:
		return emit_text_subrange(e, v)
	case .Multi_Pointer:
		return emit_multi_pointer_slice(e, v)
	}
	if info.kind == .Slice {
		value := emit_expr(e, v.operand)
		llvm := llvm_type(e, operand_type)
		data, length = temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", data, llvm, value, SLICE_DATA)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", length, llvm, value, SLICE_LEN)
	} else if info.kind == .Dynamic_Array {
		// The view is over the *current* allocation and stops at `len`, never at
		// the capacity: the slots past the length hold no initialized element.
		value := emit_expr(e, v.operand)
		data, length = temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", data, CONTAINER_TYPE, value, CONTAINER_STORAGE)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", length, CONTAINER_TYPE, value, CONTAINER_LEN)
	} else {
		data = emit_address(e, v.operand)
		length = fmt.aprintf("%d", info.count)
	}

	low := "0"
	if v.lo != nil {
		low = widen_to_i64(e, emit_expr(e, v.lo), expr_base(v.lo).type)
	}
	high := length
	if v.hi != nil {
		high = widen_to_i64(e, emit_expr(e, v.hi), expr_base(v.hi).type)
	}

	// One trap seam for the whole range, so a reversed or oversized pair cannot
	// produce a slice with a negative or out-of-root length.
	reversed := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp ugt i64 %s, %s", reversed, low, high)
	past_end := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp ugt i64 %s, %s", past_end, high, length)
	bad := temp(e)
	fmt.sbprintfln(&e.b, "  %s = or i1 %s, %s", bad, reversed, past_end)
	panic_if(e, bad, "slice.bounds", "slice bounds out of range")

	// The result's data pointer is the low bound's address in the root, so
	// reslicing composes without a second base.
	start := temp(e)
	fmt.sbprintfln(
		&e.b,
		"  %s = getelementptr inbounds %s, ptr %s, i64 %s",
		start, llvm_type(e, element), data, low,
	)
	count := temp(e)
	fmt.sbprintfln(&e.b, "  %s = sub i64 %s, %s", count, high, low)

	result := llvm_type(e, v.type)
	first, out := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, ptr %s, %d", first, result, start, SLICE_DATA)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, i64 %s, %d", out, result, first, count, SLICE_LEN)
	return out
}

// design.md "From string to X": `st[low:high]` is a subrange *view*. The bounds
// are byte offsets, and a range that split a code point would hand out a
// `string_view` that is not valid UTF-8 — so the encoding is checked with the
// range, not merely the length.
@(private = "file")
emit_text_subrange :: proc(e: ^Emitter, v: ^Expr_Slice) -> string {
	data, length := emit_text_parts(e, v.operand)
	low := "0"
	if v.lo != nil {
		low = widen_to_i64(e, emit_expr(e, v.lo), expr_base(v.lo).type)
	}
	high := length
	if v.hi != nil {
		high = widen_to_i64(e, emit_expr(e, v.hi), expr_base(v.hi).type)
	}
	reversed, past_end, bad := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp ugt i64 %s, %s", reversed, low, high)
	fmt.sbprintfln(&e.b, "  %s = icmp ugt i64 %s, %s", past_end, high, length)
	fmt.sbprintfln(&e.b, "  %s = or i1 %s, %s", bad, reversed, past_end)
	panic_if(e, bad, "slice.bounds", "string slice bounds out of range")

	start, count := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = getelementptr inbounds i8, ptr %s, i64 %s", start, data, low)
	fmt.sbprintfln(&e.b, "  %s = sub i64 %s, %s", count, high, low)
	valid, split := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = call i32 @loke_rt_v1_utf8_valid(ptr %s, i64 %s)", valid, start, count)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i32 %s, 0", split, valid)
	panic_if(e, split, "slice.utf8", "string slice bounds split a code point")

	first, out := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, ptr %s, %d", first, STRING_VIEW_TYPE, start, VIEW_DATA)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, i64 %s, %d", out, STRING_VIEW_TYPE, first, count, VIEW_LEN)
	return out
}

// design.md "Multi-pointers": `x[:]`/`x[i:]` stay multi-pointers and carry no
// bounds; `x[:n]`/`x[i:n]` produce a `[]T` and are checked, because only then is
// there a length to check against.
@(private = "file")
emit_multi_pointer_slice :: proc(e: ^Emitter, v: ^Expr_Slice) -> string {
	element := type_of(e.c, type_underlying(e.c, expr_base(v.operand).type)).element
	data := emit_expr(e, v.operand)
	low := "0"
	if v.lo != nil {
		low = widen_to_i64(e, emit_expr(e, v.lo), expr_base(v.lo).type)
	}
	start := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = getelementptr inbounds %s, ptr %s, i64 %s",
		start, llvm_type(e, element), data, low,
	)
	if v.hi == nil {
		return start
	}
	high := widen_to_i64(e, emit_expr(e, v.hi), expr_base(v.hi).type)
	reversed := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp ugt i64 %s, %s", reversed, low, high)
	panic_if(e, reversed, "slice.bounds", "slice bounds out of range")
	count := temp(e)
	fmt.sbprintfln(&e.b, "  %s = sub i64 %s, %s", count, high, low)
	return emit_slice_value(e, v.type, start, count)
}

@(private = "file")
emit_bounds_check :: proc(e: ^Emitter, index: string, index_type: Type_Id, count: u64) -> string {
	// An unsigned comparison catches a negative index and an oversized one at
	// once: a negative value becomes a very large unsigned one. Compare before
	// truncating a 128-bit index, then use the checked i64 value for the GEP.
	out_of_range := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp uge %s %s, %d", out_of_range, llvm_type(e, index_type), index, count)
	panic_if(e, out_of_range, "bounds", "index out of range")
	return widen_to_i64(e, index, index_type)
}

@(private = "file")
widen_to_i64 :: proc(e: ^Emitter, value: string, type: Type_Id) -> string {
	bits := type_bits(e.c, type)
	if bits == 64 {
		return value
	}
	out := temp(e)
	op := type_signed(e.c, type) ? "sext" : "zext"
	if bits > 64 {
		op = "trunc"
	}
	fmt.sbprintfln(&e.b, "  %s = %s i%d %s to i64", out, op, bits, value)
	return out
}

// ------------------------------------------------------------ expressions --

// Returns an operand: a literal, or a `%name`.
@(private = "file")
emit_expr :: proc(e: ^Emitter, expr: Expr) -> string {
	if expr == nil {
		return "0"
	}
	base := expr_base(expr)
	// A variant value becoming a union value. The node is evaluated at the type
	// it actually produces, then payload and tag are written.
	// A concrete value becoming an `any_view`: its address plus the frozen
	// `typeid`. A non-addressable source gets compiler-owned temporary storage.
	if from := base.erased_from; from != INVALID_TYPE {
		target := base.type
		base.erased_from, base.type = INVALID_TYPE, from
		address := spill_iterable(e, expr)
		base.erased_from, base.type = from, target
		return emit_any_view_value(e, address, from)
	}
	// design.md: a `string` borrowed as a `string_view` — the same pointer and
	// byte length, with the owning word dropped. Nothing is retained: the view
	// borrows the string and cannot outlive it, which `src/borrow.odin` checks.
	if from := base.view_from; from != INVALID_TYPE {
		target := base.type
		base.view_from, base.type = INVALID_TYPE, from
		value := emit_expr(e, expr)
		base.view_from, base.type = from, target
		data, length := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", data, STRING_TYPE, value, STRING_DATA)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", length, STRING_TYPE, value, STRING_LEN)
		first, out := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, ptr %s, %d", first, STRING_VIEW_TYPE, data, VIEW_DATA)
		fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, i64 %s, %d", out, STRING_VIEW_TYPE, first, length, VIEW_LEN)
		return out
	}
	if from := base.union_from; from != INVALID_TYPE {
		target := base.type
		base.union_from, base.type = INVALID_TYPE, from
		inner := emit_expr(e, expr)
		base.union_from, base.type = from, target
		return emit_union_value(e, target, from, inner)
	}
	if base.is_const && base.const_value.kind != .Invalid {
		return llvm_const(e, base.const_value, base.type)
	}

	switch v in expr {
	case ^Expr_Error:
		return "0"

	case ^Expr_Literal:
		return llvm_const(e, v.const_value, v.type)

	case ^Expr_Ident:
		if name, ok := e.param_values[v.symbol]; ok {
			return name // a default argument reading a parameter to its left
		}
		symbol := symbol_of(e.c, v.symbol)
		if symbol != nil && symbol.kind == .Proc {
			return e.names[v.symbol] or_else "null"
		}
		out := temp(e)
		address, ok := e.names[v.symbol]
		if !ok {
			backend_fail(e, "a resolved value has no storage")
			return "0"
		}
		fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", out, llvm_type(e, v.type), address)
		return out

	case ^Expr_Slice:
		if v.resolution.kind == .User_Operator {
			return emit_operator_call(e, v.resolution.symbol, v.bound)
		}
		return emit_builtin_slice(e, v)

	case ^Expr_Postfix:
		if v.op == .Or_Return {
			results := emit_multi_value(e, expr)
			return len(results) == 0 ? "0" : results[0]
		}
		address := emit_address(e, expr)
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", out, llvm_type(e, base.type), address)
		return out

	case ^Expr_Selector, ^Expr_Index:
		// design.md "Maps": a read does not insert, and a missing key "returns the
		// zero value". The address of that zero is a temporary of this frame.
		if index, is_index := expr.(^Expr_Index); is_index && !index.map_inserts &&
		   index.operand != nil && type_is_map(e.c, expr_base(index.operand).type) {
			return emit_map_lookup(e, index)[0]
		}
		// A user `operator([])`. A value overload produces the element; an `inout`
		// overload produces its address, which is then read through.
		if index, is_index := expr.(^Expr_Index); is_index && base.resolution.kind == .User_Operator {
			result := emit_operator_call(e, index.resolution.symbol, index.bound)
			if base.value_category != .Place {
				return result
			}
			out := temp(e)
			fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", out, llvm_type(e, base.type), result)
			return out
		}
		// `pkg.f` as a value is the procedure itself, not storage holding one.
		if symbol := symbol_of(e.c, base.resolution.symbol); symbol != nil && symbol.kind == .Proc {
			return e.names[base.resolution.symbol] or_else "null"
		}
		address := emit_address(e, expr)
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", out, llvm_type(e, base.type), address)
		return out

	case ^Expr_Unary:
		return emit_unary(e, v)

	case ^Expr_Binary:
		return emit_binary(e, v)

	case ^Expr_Cond:
		return emit_cond(e, v)

	case ^Expr_Call:
		return emit_call(e, v)

	case ^Expr_Type_Assert, ^Expr_Or_Else:
		return emit_multi_value(e, expr)[0]

	case ^Expr_Composite:
		if v.backing != INVALID_TYPE {
			return emit_slice_literal(e, v)
		}
		slot := emit_address(e, expr)
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", out, llvm_type(e, v.type), slot)
		return out

	case ^Expr_Proc:
		if name, ok := e.names[v.symbol]; ok {
			return name
		}
		return "null"

	case ^Expr_Range:
		return emit_range_value(e, v)

	case ^Expr_Move:
		return emit_move(e, v)

	case ^Expr_Hash, ^Expr_Proc_Group, ^Expr_Operator,
	     ^Type_Pointer, ^Type_Multi_Pointer, ^Type_Slice, ^Type_Dynamic_Array,
	     ^Type_Array, ^Type_Map, ^Type_Distinct, ^Type_Dyn, ^Type_Type,
	     ^Type_Poly, ^Type_Proc, ^Type_Record, ^Type_Enum, ^Type_Interface:
	}
	// Same gate as `emit_stmt`: returning `0` here would compile silently and
	// produce the wrong answer.
	backend_fail(e, "an unresolved expression reached emission")
	return "0"
}

// design.md "Slice literals": "The backing array of a slice literal is a hidden
// fixed-array owner in the surrounding lexical scope, so the slice remains valid
// until that scope exits." The hidden root is filled, then viewed whole.
//
// ponytail: the root is an ordinary `alloca` at its use, exactly like a
// composite literal's temporary storage. A literal inside a loop therefore
// allocates per iteration; hoist to the entry block if a real program shows
// stack growth.
@(private = "file")
emit_slice_literal :: proc(e: ^Emitter, v: ^Expr_Composite) -> string {
	backing := v.backing
	info := type_of(e.c, backing)
	root := temp(e)
	fmt.sbprintfln(&e.b, "  %s = alloca %s", root, llvm_type(e, backing))

	for element, index in v.elements {
		slot := temp(e)
		fmt.sbprintfln(
			&e.b,
			"  %s = getelementptr inbounds %s, ptr %s, i64 0, i64 %d",
			slot, llvm_type(e, backing), root, index,
		)
		store(e, info.element, emit_expr(e, element.value), slot)
	}

	result := llvm_type(e, v.type)
	first, out := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, ptr %s, %d", first, result, root, SLICE_DATA)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, i64 %d, %d", out, result, first, len(v.elements), SLICE_LEN)
	return out
}

@(private = "file")
emit_composite_into :: proc(e: ^Emitter, v: ^Expr_Composite, address: string) {
	// Start from the zero value so an omitted field is not left undefined.
	zero, ok := zero_const(e.c, v.type)
	if ok {
		store(e, v.type, llvm_const(e, zero, v.type), address)
	}
	info := type_of(e.c, type_underlying(e.c, v.type))
	if info == nil {
		return
	}
	if info.kind == .Dynamic_Array {
		emit_dynamic_literal_into(e, v, address, info.element)
		return
	}
	if info.kind == .Map {
		emit_map_literal_into(e, v, address, info.key, info.element)
		return
	}
	for element, index in v.elements {
		slot := index
		element_type := info.element
		if info.kind == .Struct {
			if element.key != nil {
				key := element.key.(^Expr_Ident)
				field := struct_field(e.c, v.type, intern_identifier(e.c, key.name))
				slot = int(symbol_of(e.c, field).index)
			}
			element_type = symbol_of(e.c, info.fields[slot]).type
		}
		value := emit_expr(e, element.value)
		if index < len(v.element_clones) && v.element_clones[index] {
			value = emit_clone_value(e, element_type, value)
		}
		field_address := temp(e)
		fmt.sbprintfln(
			&e.b,
			"  %s = getelementptr inbounds %s, ptr %s, i32 0, i32 %d",
			field_address, llvm_type(e, v.type), address, slot,
		)
		store(e, element_type, value, field_address)
	}
}

// `[dynamic]T{a, b, c}` over the header this expression has already zeroed.
//
// Each element is appended as soon as it is evaluated, so the container itself
// owns the initialized prefix: the C helper destroys exactly that prefix if a
// later clone fails, and the destination's own drop covers it afterwards.
//
// ponytail: a panic raised *inside* a later element's expression leaks the
// earlier ones, because the literal's storage is not registered for unwind until
// it reaches its destination. The variadic pack's per-element flag array is the
// upgrade path if that window ever matters.
@(private = "file")
emit_dynamic_literal_into :: proc(e: ^Emitter, v: ^Expr_Composite, address: string, element: Type_Id) {
	if len(v.elements) == 0 {
		return
	}
	ops := container_ops_global(e, v.type)
	// The destination's own policy is written before the first reservation, so
	// the literal never allocates through a default-backed provider first.
	if v.via != nil {
		provider, slot := emit_expr(e, v.via), temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = getelementptr inbounds %s, ptr %s, i32 0, i32 %d",
			slot, CONTAINER_TYPE, address, CONTAINER_ALLOC,
		)
		fmt.sbprintfln(&e.b, "  store ptr %s, ptr %s", provider, slot)
	}
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_dyn_bind(ptr %s)", address)
	reserved := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call i32 @loke_rt_v1_dyn_reserve(ptr %s, ptr %s, i64 %d)",
		reserved, address, ops, len(v.elements),
	)
	emit_container_policy_failure(e, address, reserved)

	slot := temp(e)
	fmt.sbprintfln(&e.b, "  %s = alloca %s", slot, llvm_type(e, element))
	for written, index in v.elements {
		value := emit_expr(e, written.value)
		if index < len(v.element_clones) && v.element_clones[index] {
			value = emit_clone_value(e, element, value)
		}
		store(e, element, value, slot)
		status := temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i32 @loke_rt_v1_dyn_append(ptr %s, ptr %s, ptr %s, i64 1)",
			status, address, ops, slot,
		)
		emit_container_policy_failure(e, address, status)
		// The staged copy was cloned into the container, so this frame still owns
		// the temporary it appended from.
		emit_drop_place(e, element, slot)
	}
}

// `map[K]V{ key = value, ... }` over the header this expression has already
// zeroed. Each entry is inserted as soon as it is evaluated, so the map itself
// owns what has been built; the same unwind window the dynamic-array literal has
// applies here for the same reason.
@(private = "file")
emit_map_literal_into :: proc(e: ^Emitter, v: ^Expr_Composite, address: string, key, element: Type_Id) {
	if len(v.elements) == 0 {
		return
	}
	ops := container_ops_global(e, v.type)
	if v.via != nil {
		provider, slot := emit_expr(e, v.via), temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = getelementptr inbounds %s, ptr %s, i32 0, i32 %d",
			slot, CONTAINER_TYPE, address, CONTAINER_ALLOC,
		)
		fmt.sbprintfln(&e.b, "  store ptr %s, ptr %s", provider, slot)
	}
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_map_bind(ptr %s)", address)
	reserved := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call i32 @loke_rt_v1_map_reserve(ptr %s, ptr %s, i64 %d)",
		reserved, address, ops, len(v.elements),
	)
	emit_container_policy_failure(e, address, reserved)

	for written, index in v.elements {
		key_slot := temp(e)
		fmt.sbprintfln(&e.b, "  %s = alloca %s", key_slot, llvm_type(e, key))
		store(e, key, emit_expr(e, written.key), key_slot)
		value := emit_expr(e, written.value)
		if index < len(v.element_clones) && v.element_clones[index] {
			value = emit_clone_value(e, element, value)
		}
		place := emit_map_entry(e, ops, address, key_slot)
		emit_drop_place(e, key, key_slot)
		missing := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", missing, place)
		fail_label, store_label, done_label :=
			new_label(e, "mlit.fail"), new_label(e, "mlit.store"), new_label(e, "mlit.done")
		branch_if(e, missing, fail_label, store_label)
		place_label(e, fail_label)
		provider, slot := temp(e), temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = getelementptr inbounds %s, ptr %s, i32 0, i32 %d",
			slot, CONTAINER_TYPE, address, CONTAINER_ALLOC,
		)
		fmt.sbprintfln(&e.b, "  %s = load ptr, ptr %s", provider, slot)
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_alloc_failed(ptr %s)", provider)
		branch(e, done_label)
		place_label(e, store_label)
		// A duplicate key replaces its value, so whatever the slot held goes first.
		emit_drop_place(e, element, place)
		store(e, element, value, place)
		branch(e, done_label)
		place_label(e, done_label)
		e.terminated = false
	}
}

// A container operation with no result to report through applies the provider's
// own failure policy, exactly as an implicit allocation does.
@(private = "file")
emit_container_policy_failure :: proc(e: ^Emitter, header, status: string) {
	failed := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i32 %s, 0", failed, status)
	fail_label, done_label := new_label(e, "clit.fail"), new_label(e, "clit.done")
	branch_if(e, failed, fail_label, done_label)
	place_label(e, fail_label)
	slot, provider := temp(e), temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = getelementptr inbounds %s, ptr %s, i32 0, i32 %d",
		slot, CONTAINER_TYPE, header, CONTAINER_ALLOC,
	)
	fmt.sbprintfln(&e.b, "  %s = load ptr, ptr %s", provider, slot)
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_alloc_failed(ptr %s)", provider)
	branch(e, done_label)
	place_label(e, done_label)
	e.terminated = false
}

@(private = "file")
emit_unary :: proc(e: ^Emitter, v: ^Expr_Unary) -> string {
	if v.op == .Amp {
		return emit_address(e, v.operand)
	}
	if v.resolution.kind == .User_Operator {
		operands := [1]Expr{v.operand}
		return emit_operator_call(e, v.resolution.symbol, operands[:])
	}
	operand := emit_expr(e, v.operand)
	type := v.type
	llvm := llvm_type(e, type)
	out := temp(e)
	#partial switch v.op {
	case .Plus:
		return operand
	case .Minus:
		if type_is_float(e.c, type) {
			fmt.sbprintfln(&e.b, "  %s = fneg %s %s", out, llvm, operand)
		} else {
			fmt.sbprintfln(&e.b, "  %s = sub %s 0, %s", out, llvm, operand)
		}
	case .Tilde:
		fmt.sbprintfln(&e.b, "  %s = xor %s %s, -1", out, llvm, operand)
	case .Not:
		fmt.sbprintfln(&e.b, "  %s = xor i1 %s, true", out, operand)
	}
	return out
}

@(private = "file")
emit_binary :: proc(e: ^Emitter, v: ^Expr_Binary) -> string {
	if v.resolution.kind == .User_Operator {
		operands := [2]Expr{v.lhs, v.rhs}
		result := emit_operator_call(e, v.resolution.symbol, operands[:])
		if !v.negated {
			return result
		}
		// The `!=` fallback: `!(a == b)`.
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = xor i1 %s, true", out, result)
		return out
	}
	#partial switch v.op {
	case .And_And, .Or_Or:
		return emit_short_circuit(e, v)
	case .In:
		return emit_map_membership(e, v)
	case .Eq_Eq, .Not_Eq, .Lt, .Lt_Eq, .Gt, .Gt_Eq:
		operand_type := expr_base(v.lhs).type
		lhs := emit_expr(e, v.lhs)
		rhs := emit_expr(e, v.rhs)
		return emit_compare(e, v.op, operand_type, lhs, rhs)
	}
	if v.op == .Plus && type_is_utf8_text(e.c, expr_base(v.lhs).type) {
		return emit_text_concat(e, v)
	}
	lhs := emit_expr(e, v.lhs)
	rhs := emit_expr(e, v.rhs)
	return emit_binary_op(e, v.op, v.type, expr_base(v.rhs).type, lhs, rhs)
}

// design.md "Concatenation": "the operation allocates from
// `mem.default_allocator()` and follows its failure policy". Both operands are
// already valid UTF-8, so the result needs no validation.
@(private = "file")
emit_text_concat :: proc(e: ^Emitter, v: ^Expr_Binary) -> string {
	left_data, left_len := emit_text_parts(e, v.lhs)
	right_data, right_len := emit_text_parts(e, v.rhs)
	return emit_text_allocating_call(
		e, "loke_rt_v1_string_concat",
		fmt.aprintf(
			"ptr %s, i64 %s, ptr %s, i64 %s, ptr %s",
			left_data, left_len, right_data, right_len, RT_DEFAULT_ALLOCATOR,
		),
		fail_is_panic = true,
	)
}

@(private = "file")
emit_binary_op :: proc(e: ^Emitter, op: Token_Kind, type: Type_Id, rhs_type: Type_Id, lhs, rhs: string) -> string {
	llvm := llvm_type(e, type)
	if type_is_float(e.c, type) {
		out := temp(e)
		name := ""
		#partial switch op {
		case .Plus:
			name = "fadd"
		case .Minus:
			name = "fsub"
		case .Star:
			name = "fmul"
		case .Slash:
			name = "fdiv"
		}
		fmt.sbprintfln(&e.b, "  %s = %s %s %s, %s", out, name, llvm, lhs, rhs)
		return out
	}

	signed := type_signed(e.c, type) || type_is_rune(e.c, type)
	#partial switch op {
	case .Slash, .Percent:
		return emit_divrem(e, op, type, signed, lhs, rhs)
	case .Shl, .Shr:
		return emit_shift(e, op, type, signed, rhs_type, lhs, rhs)
	case .Amp_Tilde:
		complement := temp(e)
		fmt.sbprintfln(&e.b, "  %s = xor %s %s, -1", complement, llvm, rhs)
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = and %s %s, %s", out, llvm, lhs, complement)
		return out
	}
	name := ""
	#partial switch op {
	case .Plus:
		name = "add"
	case .Minus:
		name = "sub"
	case .Star:
		name = "mul"
	case .Amp:
		name = "and"
	case .Pipe:
		name = "or"
	case .Tilde:
		name = "xor"
	}
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = %s %s %s, %s", out, name, llvm, lhs, rhs)
	return out
}

// Division and remainder need two guards. Zero takes the explicit trap seam;
// `MIN / -1` has the wrapping result design.md requires and must not reach LLVM
// `sdiv`/`srem`, where it would be poison.
@(private = "file")
emit_divrem :: proc(e: ^Emitter, op: Token_Kind, type: Type_Id, signed: bool, lhs, rhs: string) -> string {
	llvm := llvm_type(e, type)
	bits := type_bits(e.c, type)

	is_zero := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, 0", is_zero, llvm, rhs)
	panic_if(e, is_zero, "div.zero", "integer division by zero")

	if !signed {
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = %s %s %s, %s", out, op == .Slash ? "udiv" : "urem", llvm, lhs, rhs)
		return out
	}

	minimum := bi_text(e.c, bi_neg(e.c, bi_pow2(e.c, bits - 1)))
	special_label := new_label(e, "div.special")
	normal_label := new_label(e, "div.normal")
	done_label := new_label(e, "div.done")

	is_min := temp(e)
	is_neg_one := temp(e)
	is_overflow := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, %s", is_min, llvm, lhs, minimum)
	fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, -1", is_neg_one, llvm, rhs)
	fmt.sbprintfln(&e.b, "  %s = and i1 %s, %s", is_overflow, is_min, is_neg_one)
	branch_if(e, is_overflow, special_label, normal_label)

	fmt.sbprintfln(&e.b, "%s:", special_label)
	e.terminated = false
	branch(e, done_label)

	fmt.sbprintfln(&e.b, "%s:", normal_label)
	e.terminated = false
	normal_value := temp(e)
	fmt.sbprintfln(&e.b, "  %s = %s %s %s, %s", normal_value, op == .Slash ? "sdiv" : "srem", llvm, lhs, rhs)
	branch(e, done_label)

	fmt.sbprintfln(&e.b, "%s:", done_label)
	e.terminated = false
	out := temp(e)
	special_value := op == .Slash ? minimum : "0"
	fmt.sbprintfln(
		&e.b,
		"  %s = phi %s [ %s, %%%s ], [ %s, %%%s ]",
		out, llvm, special_value, special_label, normal_value, normal_label,
	)
	return out
}

// design.md: a shift count at or beyond the operand's width is defined — zero,
// or the replicated sign bit for an arithmetic right shift. No out-of-range
// count reaches an LLVM shift instruction, where it would be poison.
@(private = "file")
emit_shift :: proc(e: ^Emitter, op: Token_Kind, type: Type_Id, signed: bool, count_type: Type_Id, lhs, rhs: string) -> string {
	llvm := llvm_type(e, type)
	bits := type_bits(e.c, type)
	count_llvm := llvm_type(e, count_type)
	count_bits := type_bits(e.c, count_type)

	// The comparison happens in the count's own width, before any truncation
	// could hide how large it was.
	oversized := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp uge %s %s, %d", oversized, count_llvm, rhs, bits)

	count := rhs
	if count_bits != bits {
		converted := temp(e)
		operation := count_bits > bits ? "trunc" : "zext"
		fmt.sbprintfln(&e.b, "  %s = %s %s %s to %s", converted, operation, count_llvm, rhs, llvm)
		count = converted
	}

	if op == .Shr && signed {
		// Clamping to width-1 is the limit of the repeated one-bit shift.
		clamped := temp(e)
		fmt.sbprintfln(&e.b, "  %s = select i1 %s, %s %d, %s %s", clamped, oversized, llvm, bits - 1, llvm, count)
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = ashr %s %s, %s", out, llvm, lhs, clamped)
		return out
	}

	safe := temp(e)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, %s 0, %s %s", safe, oversized, llvm, llvm, count)
	raw := temp(e)
	fmt.sbprintfln(&e.b, "  %s = %s %s %s, %s", raw, op == .Shl ? "shl" : "lshr", llvm, lhs, safe)
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, %s 0, %s %s", out, oversized, llvm, llvm, raw)
	return out
}

emit_compare :: proc(e: ^Emitter, op: Token_Kind, type: Type_Id, lhs, rhs: string) -> string {
	// design.md: "`string` and `string_view` values are comparable and ordered,
	// lexically byte-wise." One runtime call answers all six operators.
	if type_is_utf8_text(e.c, type) {
		storage := llvm_type(e, type_underlying(e.c, type))
		left_data, left_len, right_data, right_len := temp(e), temp(e), temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", left_data, storage, lhs, STRING_DATA)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", left_len, storage, lhs, STRING_LEN)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", right_data, storage, rhs, STRING_DATA)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", right_len, storage, rhs, STRING_LEN)
		order := temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i32 @loke_rt_v1_bytes_compare(ptr %s, i64 %s, ptr %s, i64 %s)",
			order, left_data, left_len, right_data, right_len,
		)
		name := ""
		#partial switch op {
		case .Eq_Eq:
			name = "eq"
		case .Not_Eq:
			name = "ne"
		case .Lt:
			name = "slt"
		case .Lt_Eq:
			name = "sle"
		case .Gt:
			name = "sgt"
		case .Gt_Eq:
			name = "sge"
		}
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp %s i32 %s, 0", out, name, order)
		return out
	}
	if type_is_aggregate(e.c, type) || type_is_union(e.c, type) || type_is_erased_view(e.c, type) {
		equal := emit_equal(e, type, lhs, rhs)
		if op == .Eq_Eq {
			return equal
		}
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = xor i1 %s, true", out, equal)
		return out
	}
	llvm := llvm_type(e, type)
	out := temp(e)
	if type_is_float(e.c, type) {
		// Ordered comparisons, so a NaN operand compares false — except `!=`,
		// which is true whenever the operands are unordered.
		name := ""
		#partial switch op {
		case .Eq_Eq:
			name = "oeq"
		case .Not_Eq:
			name = "une"
		case .Lt:
			name = "olt"
		case .Lt_Eq:
			name = "ole"
		case .Gt:
			name = "ogt"
		case .Gt_Eq:
			name = "oge"
		}
		fmt.sbprintfln(&e.b, "  %s = fcmp %s %s %s, %s", out, name, llvm, lhs, rhs)
		return out
	}
	signed := type_signed(e.c, type) || type_is_rune(e.c, type)
	name := ""
	#partial switch op {
	case .Eq_Eq:
		name = "eq"
	case .Not_Eq:
		name = "ne"
	case .Lt:
		name = signed ? "slt" : "ult"
	case .Lt_Eq:
		name = signed ? "sle" : "ule"
	case .Gt:
		name = signed ? "sgt" : "ugt"
	case .Gt_Eq:
		name = signed ? "sge" : "uge"
	}
	fmt.sbprintfln(&e.b, "  %s = icmp %s %s %s, %s", out, name, llvm, lhs, rhs)
	return out
}

// LLVM has no aggregate `icmp`, so structural equality is generated: each
// operand is evaluated once, and the leaf comparisons are combined.
//
// ponytail: one flat `and` chain rather than short-circuiting blocks. Every leaf
// is a pure `extractvalue` plus `icmp`/`fcmp`, so skipping them is unobservable,
// and a chain of N blocks would be worse IR than N ands. Revisit if a measured
// comparison of a very large array shows up.
@(private = "file")
emit_equal :: proc(e: ^Emitter, type: Type_Id, lhs, rhs: string) -> string {
	under := type_underlying(e.c, type)
	info := type_of(e.c, under)
	if info == nil {
		return "true"
	}
	#partial switch info.kind {
	case .Union:
		return emit_union_equal(e, under, lhs, rhs)
	case .Dyn, .Any_View:
		// design.md: dynamic interface values are comparable only with `nil`, and
		// nil is the zero view. Comparing the second word — the witness, or the
		// `typeid` — is what distinguishes a live view from the nil one.
		llvm := llvm_type(e, under)
		left, right := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, 1", left, llvm, lhs)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, 1", right, llvm, rhs)
		out := temp(e)
		operand := info.kind == .Dyn ? "ptr" : "i64"
		fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, %s", out, operand, left, right)
		return out
	case .Slice:
		// The checker admits only `slice == nil`, and a nil slice is the one with a
		// null data pointer, so the first word decides it.
		llvm := llvm_type(e, under)
		left, right := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", left, llvm, lhs, SLICE_DATA)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", right, llvm, rhs, SLICE_DATA)
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, %s", out, left, right)
		return out
	case .Array:
		result := "true"
		for index in 0 ..< int(info.count) {
			left := extract(e, under, lhs, index)
			right := extract(e, under, rhs, index)
			leaf := emit_equal(e, info.element, left, right)
			result = combine_and(e, result, leaf)
		}
		return result
	case .Struct:
		result := "true"
		for field, index in info.fields {
			symbol := symbol_of(e.c, field)
			left := extract(e, under, lhs, index)
			right := extract(e, under, rhs, index)
			leaf := emit_equal(e, symbol.type, left, right)
			result = combine_and(e, result, leaf)
		}
		return result
	}
	return emit_compare(e, .Eq_Eq, type, lhs, rhs)
}

// An erased view is an aggregate the ordinary struct path cannot compare, so it
// takes the same route a union does.
@(private = "file")
type_is_erased_view :: proc(c: ^Compiler, type: Type_Id) -> bool {
	#partial switch type_kind(c, type_underlying(c, type)) {
	case .Dyn, .Any_View, .Slice:
		return true
	}
	return false
}

// Two unions are equal when their tags match and, for a non-nil tag, the active
// variant's payloads match.
//
// ponytail: every variant's comparison is computed and then selected, rather
// than branching per tag. Each payload load is inside the union's own storage,
// so reading one at the wrong variant's type is harmless — only the selected
// comparison is ever used. Switch to a block-per-variant chain if a union ever
// holds a variant whose comparison is expensive.
@(private = "file")
emit_union_equal :: proc(e: ^Emitter, union_type: Type_Id, lhs, rhs: string) -> string {
	info := type_of(e.c, union_type)
	shape := union_layout(e.c, union_type)
	tag_llvm := fmt.aprintf("i%d", shape.tag_bytes * 8)

	left_tag := emit_union_tag(e, union_type, lhs)
	right_tag := emit_union_tag(e, union_type, rhs)
	same_tag := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, %s", same_tag, tag_llvm, left_tag, right_tag)

	left_slot := emit_union_spill(e, union_type, lhs)
	right_slot := emit_union_spill(e, union_type, rhs)

	// Nil equals nil, so the chain starts from `true` and each variant overrides
	// it when its own tag is active.
	payloads := "true"
	for variant, index in info.variants {
		left := emit_union_payload(e, union_type, variant, left_slot)
		right := emit_union_payload(e, union_type, variant, right_slot)
		equal := emit_equal(e, variant, left, right)
		active := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, %d", active, tag_llvm, left_tag, index + 1)
		next := temp(e)
		fmt.sbprintfln(&e.b, "  %s = select i1 %s, i1 %s, i1 %s", next, active, equal, payloads)
		payloads = next
	}
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = and i1 %s, %s", out, same_tag, payloads)
	return out
}

@(private = "file")
extract :: proc(e: ^Emitter, aggregate_type: Type_Id, value: string, index: int) -> string {
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", out, llvm_type(e, aggregate_type), value, index)
	return out
}

@(private = "file")
combine_and :: proc(e: ^Emitter, a, b: string) -> string {
	if a == "true" {
		return b
	}
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = and i1 %s, %s", out, a, b)
	return out
}

@(private = "file")
emit_short_circuit :: proc(e: ^Emitter, v: ^Expr_Binary) -> string {
	lhs := emit_expr(e, v.lhs)
	rhs_label := new_label(e, "sc.rhs")
	done_label := new_label(e, "sc.done")
	entry_label := new_label(e, "sc.entry")

	// The incoming edge needs a name of its own for the phi, and the left
	// operand may itself have created blocks.
	branch(e, entry_label)
	fmt.sbprintfln(&e.b, "%s:", entry_label)
	e.terminated = false
	if v.op == .And_And {
		branch_if(e, lhs, rhs_label, done_label)
	} else {
		branch_if(e, lhs, done_label, rhs_label)
	}

	fmt.sbprintfln(&e.b, "%s:", rhs_label)
	e.terminated = false
	rhs := emit_expr(e, v.rhs)
	rhs_exit := new_label(e, "sc.rhs.exit")
	branch(e, rhs_exit)
	fmt.sbprintfln(&e.b, "%s:", rhs_exit)
	e.terminated = false
	branch(e, done_label)

	fmt.sbprintfln(&e.b, "%s:", done_label)
	e.terminated = false
	out := temp(e)
	short := v.op == .And_And ? "false" : "true"
	fmt.sbprintfln(
		&e.b,
		"  %s = phi i1 [ %s, %%%s ], [ %s, %%%s ]",
		out, short, entry_label, rhs, rhs_exit,
	)
	return out
}

@(private = "file")
emit_cond :: proc(e: ^Emitter, v: ^Expr_Cond) -> string {
	cond := emit_expr(e, v.cond)
	then_label := new_label(e, "cond.then")
	else_label := new_label(e, "cond.else")
	done_label := new_label(e, "cond.done")
	branch_if(e, cond, then_label, else_label)

	fmt.sbprintfln(&e.b, "%s:", then_label)
	e.terminated = false
	then_value := emit_expr(e, v.then)
	then_exit := new_label(e, "cond.then.exit")
	branch(e, then_exit)
	fmt.sbprintfln(&e.b, "%s:", then_exit)
	e.terminated = false
	branch(e, done_label)

	fmt.sbprintfln(&e.b, "%s:", else_label)
	e.terminated = false
	else_value := emit_expr(e, v.otherwise)
	else_exit := new_label(e, "cond.else.exit")
	branch(e, else_exit)
	fmt.sbprintfln(&e.b, "%s:", else_exit)
	e.terminated = false
	branch(e, done_label)

	fmt.sbprintfln(&e.b, "%s:", done_label)
	e.terminated = false
	out := temp(e)
	fmt.sbprintfln(
		&e.b,
		"  %s = phi %s [ %s, %%%s ], [ %s, %%%s ]",
		out, llvm_type(e, v.type), then_value, then_exit, else_value, else_exit,
	)
	return out
}

// ================================================== coherent formatting ==

// design.md "String format printing" and m6a-plan decision "Coherent
// formatting": runtime formatting has one formatter per concrete `typeid`. The
// table is private and parallel to the type-info table, because the public
// `Type_Info` layout deliberately exposes no code pointers — that is what keeps
// `base:runtime` from having to know `core:fmt` exists.
FMT_THUNKS :: "@.loke.fmt_thunks"
FMT_THUNK_COUNT :: "@.loke.fmt_thunks.count"
TYPE_NAMES :: "@.loke.type_names"

@(private = "file")
fmt_thunk_name :: proc(e: ^Emitter, type: Type_Id) -> string {
	return fmt.aprintf("@loke.f.%d", typeid_value(e.c, type))
}

// One generated formatter per requested printable type, then the table that
// dispatches an erased value to it.
@(private = "file")
emit_format_thunks :: proc(e: ^Emitter) {
	if !e.c.format_requested {
		return
	}
	count := len(e.c.typeid_order)
	entries := make([]string, count + 1)
	entries[0] = "null"
	for index in 1 ..< len(entries) {
		entries[index] = "null"
	}
	for type in e.c.typeid_order {
		id := typeid_value(e.c, type)
		if id == 0 || int(id) > count || !type_is_printable(e.c, type) {
			continue
		}
		emit_one_format_thunk(e, type)
		entries[id] = fmt_thunk_name(e, type)
	}

	// The names a `typeid` prints as. This is the same text `runtime.Type_Info`
	// carries, but it is a private table so that printing does not oblige a
	// program to import `base:runtime` for a public record it never names.
	names := make([]string, count + 1)
	for index in 0 ..< len(names) {
		names[index] = ""
	}
	for type in e.c.typeid_order {
		id := typeid_value(e.c, type)
		if id != 0 && int(id) <= count {
			names[id] = type_name(e.c, type)
		}
	}

	b := strings.builder_make()
	fmt.sbprintf(&b, "%s = private unnamed_addr constant [%d x ptr] [", FMT_THUNKS, count + 1)
	for entry, index in entries {
		if index > 0 {
			strings.write_string(&b, ",")
		}
		fmt.sbprintf(&b, " ptr %s", entry)
	}
	strings.write_string(&b, " ]\n")
	fmt.sbprintf(&b, "%s = private unnamed_addr constant i64 %d\n", FMT_THUNK_COUNT, count)
	// Built with the same `{ptr, len}` shape a `string_view` has, so the formatter
	// reads it with the loads it already emits for one.
	fmt.sbprintf(&b, "%s = private unnamed_addr constant [%d x %s] [", TYPE_NAMES, count + 1, STRING_VIEW_TYPE)
	for name, index in names {
		if index > 0 {
			strings.write_string(&b, ",")
		}
		if name == "" {
			fmt.sbprintf(&b, " %s zeroinitializer", STRING_VIEW_TYPE)
			continue
		}
		// `{` is a core:fmt format directive, so this row is concatenated.
		strings.write_string(&b, strings.concatenate({
			" ", STRING_VIEW_TYPE, " { ptr ", text_literal_global(e, name),
			", i64 ", fmt.aprintf("%d", len(name)), " }",
		}))
	}
	strings.write_string(&b, " ]\n")
	append(&e.globals, strings.to_string(b))
}

// design.md gives no spelling for an aggregate, so these are the ones the
// library's own examples imply: elements between brackets, fields named inside
// braces, and an enum by the member's own name.
@(private = "file")
emit_one_format_thunk :: proc(e: ^Emitter, type: Type_Id) {
	saved_body, saved_terminated := e.b, e.terminated
	e.b = strings.builder_make()
	e.terminated = false

	fmt.sbprintf(&e.b, "define private void %s(ptr %%data, ptr %%w, ptr %%o)", fmt_thunk_name(e, type))
	fmt.sbprintln(&e.b, " {")
	fmt.sbprintln(&e.b, "entry:")
	emit_format_body(e, type, "%data")
	fmt.sbprintln(&e.b, "  ret void")
	fmt.sbprintln(&e.b, "}")
	fmt.sbprintln(&e.b, "")

	text := strings.to_string(e.b)
	e.b, e.terminated = saved_body, saved_terminated
	append(&e.pending_thunks, text)
}

// A literal separator: `[`, `, `, ` = ` and friends all go through the same
// static storage the string literals already use.
@(private = "file")
emit_format_literal :: proc(e: ^Emitter, text: string) {
	global := text_literal_global(e, text)
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_fmt_bytes(ptr %%w, ptr %s, i64 %d)", global, len(text))
}

@(private = "file")
emit_format_call :: proc(e: ^Emitter, type: Type_Id, address: string) {
	if !type_is_printable(e.c, type) || typeid_value(e.c, type) == 0 {
		emit_format_literal(e, "<unformattable>")
		return
	}
	fmt.sbprintfln(&e.b, "  call void %s(ptr %s, ptr %%w, ptr %%o)", fmt_thunk_name(e, type), address)
}

@(private = "file")
emit_format_body :: proc(e: ^Emitter, type: Type_Id, address: string) {
	// design.md's coherence rule: a `format` declared in the value type's own
	// package *is* the formatter for that type, so the thunk is a call to it.
	if hook := e.c.formatters[type]; hook != INVALID_SYMBOL {
		value := temp(e)
		fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", value, llvm_type(e, type), address)
		writer, options := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = load %s, ptr %%w", writer, llvm_type(e, e.c.runtime_types["Writer"]))
		fmt.sbprintfln(&e.b, "  %s = load %s, ptr %%o", options, llvm_type(e, e.c.runtime_types["Options"]))
		fmt.sbprintfln(
			&e.b, "  call void %s(%s %s, %s %s, %s %s)",
			e.names[hook],
			llvm_type(e, type), value,
			llvm_type(e, e.c.runtime_types["Writer"]), writer,
			llvm_type(e, e.c.runtime_types["Options"]), options,
		)
		return
	}
	// A `distinct` type prints as the shape it wraps: it has a fresh identity,
	// not a fresh representation.
	under := type_underlying(e.c, type)
	info := type_of(e.c, under)
	if info == nil {
		emit_format_literal(e, "<unformattable>")
		return
	}

	#partial switch info.kind {
	case .Bool:
		value, widened := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = load i1, ptr %s", value, address)
		fmt.sbprintfln(&e.b, "  %s = zext i1 %s to i32", widened, value)
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_fmt_bool(ptr %%w, i32 %s)", widened)

	case .Int, .Allocator_Error:
		llvm := llvm_type(e, under)
		value := temp(e)
		fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", value, llvm, address)
		signed := type_signed(e.c, under)
		if type_bits(e.c, under) > 64 {
			low, shifted, high := temp(e), temp(e), temp(e)
			fmt.sbprintfln(&e.b, "  %s = trunc %s %s to i64", low, llvm, value)
			fmt.sbprintfln(&e.b, "  %s = lshr %s %s, 64", shifted, llvm, value)
			fmt.sbprintfln(&e.b, "  %s = trunc %s %s to i64", high, llvm, shifted)
			callee := signed ? "loke_rt_v1_fmt_i128" : "loke_rt_v1_fmt_u128"
			fmt.sbprintfln(&e.b, "  call void @%s(ptr %%w, i64 %s, i64 %s, ptr %%o)", callee, low, high)
			return
		}
		widened := widen_to_i64(e, value, under)
		if signed {
			fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_fmt_i64(ptr %%w, i64 %s, ptr %%o)", widened)
		} else {
			fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_fmt_u64(ptr %%w, i64 %s, ptr %%o)", widened)
		}

	case .Typeid:
		value := temp(e)
		fmt.sbprintfln(&e.b, "  %s = load i64, ptr %s", value, address)
		emit_format_type_name(e, value)

	case .Rune:
		value := temp(e)
		fmt.sbprintfln(&e.b, "  %s = load i32, ptr %s", value, address)
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_fmt_rune(ptr %%w, i32 %s)", value)

	case .Float:
		llvm := llvm_type(e, under)
		value := temp(e)
		fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", value, llvm, address)
		widened := value
		if llvm != "double" {
			widened = temp(e)
			fmt.sbprintfln(&e.b, "  %s = fpext %s %s to double", widened, llvm, value)
		}
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_fmt_f64(ptr %%w, double %s)", widened)

	case .Pointer, .Multi_Pointer, .Raw_Pointer, .Proc, .Allocator:
		value := temp(e)
		fmt.sbprintfln(&e.b, "  %s = load ptr, ptr %s", value, address)
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_fmt_ptr(ptr %%w, ptr %s)", value)

	case .String, .String_View:
		value, data, length := temp(e), temp(e), temp(e)
		storage := llvm_type(e, under)
		fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", value, storage, address)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", data, storage, value, STRING_DATA)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", length, storage, value, STRING_LEN)
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_fmt_bytes(ptr %%w, ptr %s, i64 %s)", data, length)

	case .CString_View:
		value, length := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = load ptr, ptr %s", value, address)
		fmt.sbprintfln(&e.b, "  %s = call i64 @loke_rt_v1_cstring_len(ptr %s)", length, value)
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_fmt_bytes(ptr %%w, ptr %s, i64 %s)", value, length)

	case .Enum:
		emit_format_enum(e, under, address)

	case .Array:
		emit_format_sequence(e, info.element, address, fmt.aprintf("%d", info.count), inline_array = true)

	case .Slice:
		value, data, length := temp(e), temp(e), temp(e)
		storage := llvm_type(e, under)
		fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", value, storage, address)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", data, storage, value, SLICE_DATA)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", length, storage, value, SLICE_LEN)
		emit_format_sequence(e, info.element, data, length, inline_array = false)

	case .Struct:
		emit_format_struct(e, type, under, address)

	case .Any_View:
		// design.md: the erased view is a pointer plus a `typeid`, which is exactly
		// what the dispatch needs — so a nested `any_view` formats its subject.
		value, data, id := temp(e), temp(e), temp(e)
		storage := llvm_type(e, under)
		fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", value, storage, address)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", data, storage, value, ANY_VIEW_DATA)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", id, storage, value, ANY_VIEW_ID)
		emit_format_dispatch(e, data, id)

	case .Union:
		emit_format_union(e, under, address)

	case:
		// A `dyn` view, and anything else whose spelling design.md does not fix,
		// prints as its type name, which is still coherent.
		emit_format_literal(e, type_name(e.c, type))
	}
}

// design.md "Unions": "tag 0 is nil", and a union prints as whatever it is
// currently holding — the same thing a type switch would see. The chain is over
// variants for the same reason the enum one is: the tag is not an index into
// anything the formatter can address.
@(private = "file")
emit_format_union :: proc(e: ^Emitter, under: Type_Id, address: string) {
	info := type_of(e.c, under)
	shape := union_layout(e.c, under)
	tag_llvm := fmt.aprintf("i%d", shape.tag_bytes * 8)
	value := temp(e)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", value, llvm_type(e, under), address)
	tag := emit_union_tag(e, under, value)
	slot := emit_union_spill(e, under, value)
	done := new_label(e, "fmt.union.done")
	for variant in info.variants {
		matched := temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = icmp eq %s %s, %d",
			matched, tag_llvm, tag, union_variant_tag(e.c, under, variant),
		)
		hit, next := new_label(e, "fmt.union.hit"), new_label(e, "fmt.union.next")
		branch_if(e, matched, hit, next)
		place_label(e, hit)
		payload := temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = getelementptr inbounds %s, ptr %s, i32 0, i32 0",
			payload, llvm_type(e, under), slot,
		)
		emit_format_body(e, variant, payload)
		branch(e, done)
		place_label(e, next)
	}
	// Tag 0: design.md's nil union, which prints like every other nil.
	emit_format_literal(e, "<nil>")
	branch(e, done)
	place_label(e, done)
}

// design.md: `type_info_of` "accepts a runtime `typeid` and returns runtime
// metadata", and that metadata carries the type's name — so a `typeid` prints as
// the name of what it identifies. An id with no entry, including the nil one and
// a forged one, has no name to print and falls back to its numeric identity.
@(private = "file")
emit_format_type_name :: proc(e: ^Emitter, id: string) {
	limit, zero, past, bad := temp(e), temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = load i64, ptr %s", limit, FMT_THUNK_COUNT)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i64 %s, 0", zero, id)
	fmt.sbprintfln(&e.b, "  %s = icmp ugt i64 %s, %s", past, id, limit)
	fmt.sbprintfln(&e.b, "  %s = or i1 %s, %s", bad, zero, past)
	safe := temp(e)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, i64 0, i64 %s", safe, bad, id)
	view, data, stride, length := temp(e), temp(e), temp(e), temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = getelementptr inbounds %s, ptr %s, i64 %s",
		view, STRING_VIEW_TYPE, TYPE_NAMES, safe,
	)
	fmt.sbprintfln(&e.b, "  %s = load ptr, ptr %s", data, view)
	fmt.sbprintfln(
		&e.b, "  %s = getelementptr inbounds %s, ptr %s, i32 0, i32 %d",
		stride, STRING_VIEW_TYPE, view, STRING_LEN,
	)
	fmt.sbprintfln(&e.b, "  %s = load i64, ptr %s", length, stride)
	// An id with no name — the nil one, a forged one, or a type this program
	// never requested — has nothing to spell, so it prints its numeric identity.
	missing := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i64 %s, 0", missing, length)
	numeric, named, done := new_label(e, "fmt.typeid.number"), new_label(e, "fmt.typeid.named"), new_label(e, "fmt.typeid.done")
	branch_if(e, missing, numeric, named)

	place_label(e, named)
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_fmt_bytes(ptr %%w, ptr %s, i64 %s)", data, length)
	branch(e, done)

	place_label(e, numeric)
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_fmt_u64(ptr %%w, i64 %s, ptr %%o)", id)
	branch(e, done)
	place_label(e, done)
}

// design.md: an enum's members "are named constants that need not be
// contiguous", so the spelling is a chain of comparisons rather than an index.
@(private = "file")
emit_format_enum :: proc(e: ^Emitter, under: Type_Id, address: string) {
	info := type_of(e.c, under)
	llvm := llvm_type(e, under)
	value := temp(e)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", value, llvm, address)
	done := new_label(e, "fmt.enum.done")
	for field in info.fields {
		sym := symbol_of(e.c, field)
		if sym == nil || sym.const_value.kind != .Integer {
			continue
		}
		matched := temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = icmp eq %s %s, %s",
			matched, llvm, value, bi_text(e.c, sym.const_value.integer),
		)
		hit, next := new_label(e, "fmt.enum.hit"), new_label(e, "fmt.enum.next")
		branch_if(e, matched, hit, next)
		place_label(e, hit)
		emit_format_literal(e, identifier_text(e.c, sym.name))
		branch(e, done)
		place_label(e, next)
	}
	// A value no member names is still a value: print the number rather than
	// nothing.
	widened := widen_to_i64(e, value, under)
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_fmt_i64(ptr %%w, i64 %s, ptr %%o)", widened)
	branch(e, done)
	place_label(e, done)
}

@(private = "file")
emit_format_sequence :: proc(e: ^Emitter, element: Type_Id, base, count: string, inline_array: bool) {
	emit_format_literal(e, "[")
	cursor := temp(e)
	fmt.sbprintfln(&e.b, "  %s = alloca i64", cursor)
	fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", cursor)
	head, body, done := new_label(e, "fmt.seq.head"), new_label(e, "fmt.seq.body"), new_label(e, "fmt.seq.done")
	place_label(e, head)
	index := temp(e)
	fmt.sbprintfln(&e.b, "  %s = load i64, ptr %s", index, cursor)
	more := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp slt i64 %s, %s", more, index, count)
	branch_if(e, more, body, done)
	place_label(e, body)
	first := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i64 %s, 0", first, index)
	separator, formatted := new_label(e, "fmt.seq.sep"), new_label(e, "fmt.seq.item")
	branch_if(e, first, formatted, separator)
	place_label(e, separator)
	emit_format_literal(e, ", ")
	branch(e, formatted)
	place_label(e, formatted)
	slot := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = getelementptr inbounds %s, ptr %s, i64 %s",
		slot, llvm_type(e, element), base, index,
	)
	emit_format_call(e, element, slot)
	advanced := temp(e)
	fmt.sbprintfln(&e.b, "  %s = add i64 %s, 1", advanced, index)
	fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", advanced, cursor)
	branch(e, head)
	place_label(e, done)
	emit_format_literal(e, "]")
}

@(private = "file")
emit_format_struct :: proc(e: ^Emitter, type, under: Type_Id, address: string) {
	info := type_of(e.c, under)
	emit_format_literal(e, type_name(e.c, type))
	emit_format_literal(e, "{")
	written := 0
	for field, index in info.fields {
		sym := symbol_of(e.c, field)
		if sym == nil || !sym.public {
			continue // the same public rule the metadata table follows
		}
		if written > 0 {
			emit_format_literal(e, ", ")
		}
		written += 1
		emit_format_literal(e, identifier_text(e.c, sym.name))
		emit_format_literal(e, " = ")
		slot := temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = getelementptr inbounds %s, ptr %s, i32 0, i32 %d",
			slot, llvm_type(e, under), address, index,
		)
		emit_format_call(e, sym.type, slot)
	}
	emit_format_literal(e, "}")
}

// The erased dispatch itself: look the concrete formatter up by `typeid`, which
// is the only thing an `any_view` carries. A nil or forged id has no formatter,
// so it prints as nil rather than reading past the table.
@(private = "file")
emit_format_dispatch :: proc(e: ^Emitter, data, id: string) {
	limit := temp(e)
	fmt.sbprintfln(&e.b, "  %s = load i64, ptr %s", limit, FMT_THUNK_COUNT)
	zero, past, bad := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i64 %s, 0", zero, id)
	fmt.sbprintfln(&e.b, "  %s = icmp ugt i64 %s, %s", past, id, limit)
	fmt.sbprintfln(&e.b, "  %s = or i1 %s, %s", bad, zero, past)
	safe := temp(e)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, i64 0, i64 %s", safe, bad, id)
	slot, thunk := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = getelementptr inbounds ptr, ptr %s, i64 %s", slot, FMT_THUNKS, safe)
	fmt.sbprintfln(&e.b, "  %s = load ptr, ptr %s", thunk, slot)
	missing := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", missing, thunk)
	none, call, done := new_label(e, "fmt.none"), new_label(e, "fmt.call"), new_label(e, "fmt.done")
	branch_if(e, missing, none, call)
	place_label(e, none)
	emit_format_literal(e, "<nil>")
	branch(e, done)
	place_label(e, call)
	fmt.sbprintfln(&e.b, "  call void %s(ptr %s, ptr %%w, ptr %%o)", thunk, data)
	branch(e, done)
	place_label(e, done)
}

// The four compiler-owned `core:fmt` entry points.
@(private = "file")
emit_fmt_builtin :: proc(e: ^Emitter, v: ^Expr_Call, kind: Builtin_Kind) -> string {
	writer_type := llvm_type(e, e.c.runtime_types["Writer"])
	#partial switch kind {
	case .Fmt_Stdout_Writer, .Fmt_Stderr_Writer:
		stream := kind == .Fmt_Stdout_Writer ? 0 : 1
		first, out := temp(e), temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = insertvalue %s undef, ptr @loke_rt_v1_write_std, 0",
			first, writer_type,
		)
		fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, ptr inttoptr (i64 %d to ptr), 1", out, writer_type, first, stream)
		return out

	case .Fmt_Write_Bytes:
		writer := spill_value(e, e.c.runtime_types["Writer"], emit_expr(e, v.bound[0]))
		data, length := emit_text_parts(e, v.bound[1])
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_fmt_bytes(ptr %s, ptr %s, i64 %s)", writer, data, length)
		return "0"

	case .Fmt_Format_Any:
		view := emit_expr(e, v.bound[0])
		storage := llvm_type(e, TYPE_ANY_VIEW)
		data, id := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", data, storage, view, ANY_VIEW_DATA)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", id, storage, view, ANY_VIEW_ID)
		// The thunks name `%w` and `%o`, so the two records are spilled to storage
		// the call can address.
		writer := spill_value(e, e.c.runtime_types["Writer"], emit_expr(e, v.bound[1]))
		options := spill_value(e, e.c.runtime_types["Options"], emit_expr(e, v.bound[2]))
		saved_w, saved_o := e.fmt_writer, e.fmt_options
		e.fmt_writer, e.fmt_options = writer, options
		emit_format_dispatch_at(e, data, id, writer, options)
		e.fmt_writer, e.fmt_options = saved_w, saved_o
		return "0"
	}
	return "0"
}

// The dispatch, written at a call site rather than inside a thunk, so the two
// records are named operands instead of the thunk's own parameters.
@(private = "file")
emit_format_dispatch_at :: proc(e: ^Emitter, data, id, writer, options: string) {
	limit := temp(e)
	fmt.sbprintfln(&e.b, "  %s = load i64, ptr %s", limit, FMT_THUNK_COUNT)
	zero, past, bad := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i64 %s, 0", zero, id)
	fmt.sbprintfln(&e.b, "  %s = icmp ugt i64 %s, %s", past, id, limit)
	fmt.sbprintfln(&e.b, "  %s = or i1 %s, %s", bad, zero, past)
	safe := temp(e)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, i64 0, i64 %s", safe, bad, id)
	slot, thunk := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = getelementptr inbounds ptr, ptr %s, i64 %s", slot, FMT_THUNKS, safe)
	fmt.sbprintfln(&e.b, "  %s = load ptr, ptr %s", thunk, slot)
	missing := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", missing, thunk)
	none, call, done := new_label(e, "fmt.none"), new_label(e, "fmt.call"), new_label(e, "fmt.done")
	branch_if(e, missing, none, call)
	place_label(e, none)
	nil_text := text_literal_global(e, "<nil>")
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_fmt_bytes(ptr %s, ptr %s, i64 5)", writer, nil_text)
	branch(e, done)
	place_label(e, call)
	fmt.sbprintfln(&e.b, "  call void %s(ptr %s, ptr %s, ptr %s)", thunk, data, writer, options)
	branch(e, done)
	place_label(e, done)
}

@(private = "file")
spill_value :: proc(e: ^Emitter, type: Type_Id, value: string) -> string {
	slot := temp(e)
	fmt.sbprintfln(&e.b, "  %s = alloca %s", slot, llvm_type(e, type))
	store(e, type, value, slot)
	return slot
}

// ==================================================== runtime metadata ==

// design.md "`type` and `typeid`": one dense entry per requested runtime type,
// keyed by the frozen `typeid`, plus a zero entry at index 0 so the nil id
// resolves to nothing. `base:runtime` owns the layouts; this fills them.
//
// The table is emitted only for a program that asked for it, and every entry is
// a type the compilation already requested a `typeid` for -- which
// `close_type_info_requests` has extended to everything the public metadata
// names, so a member type is always resolvable too.
TYPE_INFO_TABLE :: "@.loke.type_info"
TYPE_INFO_COUNT :: "@.loke.type_info.count"

@(private = "file")
emit_type_info_tables :: proc(e: ^Emitter) {
	if !e.c.type_info_requested {
		return
	}
	record, has_record := e.c.runtime_types["Type_Info"]
	member, has_member := e.c.runtime_types["Member_Info"]
	if !has_record || !has_member {
		backend_fail(e, "`type_info_of` was checked without the `base:runtime` layouts")
		return
	}
	// Frozen ids are 1..N and dense, so the table is indexed directly.
	count := len(e.c.typeid_order)
	entries := make([]string, count + 1)
	entries[0] = "zeroinitializer"
	for type in e.c.typeid_order {
		id := typeid_value(e.c, type)
		if id == 0 || int(id) > count {
			continue
		}
		entries[id] = type_info_entry(e, record, member, type)
	}
	for index in 0 ..< len(entries) {
		if entries[index] == "" {
			entries[index] = "zeroinitializer"
		}
	}

	b := strings.builder_make()
	fmt.sbprintf(&b, "%s = private unnamed_addr constant [%d x %s] [", TYPE_INFO_TABLE, count + 1, struct_name(e, record))
	for entry, index in entries {
		if index > 0 {
			strings.write_string(&b, ",")
		}
		fmt.sbprintf(&b, " %s %s", struct_name(e, record), entry)
	}
	strings.write_string(&b, " ]\n")
	fmt.sbprintf(&b, "%s = private unnamed_addr constant i64 %d\n", TYPE_INFO_COUNT, count)
	append(&e.globals, strings.to_string(b))
}

@(private = "file")
type_info_entry :: proc(e: ^Emitter, record, member, type: Type_Id) -> string {
	shape := type_of(e.c, type_underlying(e.c, type))
	members := type_info_members(e, member, type)

	values := make(map[string]string)
	defer delete(values)
	values["id"] = fmt.aprintf("%d", typeid_value(e.c, type))
	values["kind"] = fmt.aprintf("%d", public_type_kind(e.c, type))
	values["name"] = text_constant(e, Const_Value{kind = .String, text = type_name(e.c, type)}, false)
	values["size"] = fmt.aprintf("%d", type_size(e.c, type))
	values["align"] = fmt.aprintf("%d", type_align(e.c, type))
	values["bits"] = fmt.aprintf("%d", shape == nil ? 0 : shape.bits)
	values["signed"] = shape != nil && shape.signed ? "true" : "false"
	values["element"] = fmt.aprintf("%d", typeid_value(e.c, shape == nil ? INVALID_TYPE : shape.element))
	values["key"] = fmt.aprintf("%d", typeid_value(e.c, shape == nil ? INVALID_TYPE : shape.key))
	values["count"] = fmt.aprintf("%d", shape == nil ? 0 : shape.count)
	values["members"] = members
	return named_field_constant(e, record, values)
}

// The public `Type_Kind` a compiler kind maps to. The order is frozen by
// `base/runtime`'s declaration; adding a member there requires a runtime ABI
// version bump. The untyped kinds never reach here: a `typeid` is only ever
// requested for a concrete runtime type.
@(private = "file")
public_type_kind :: proc(c: ^Compiler, type: Type_Id) -> int {
	PUBLIC_KINDS :: []string {
		"Invalid", "Void", "Bool", "Signed_Int", "Unsigned_Int", "Float", "Rune",
		"Raw_Pointer", "Pointer", "Multi_Pointer", "Array", "Slice", "Dynamic_Array", "Map",
		"Struct", "Enum", "Union", "Proc", "String", "String_View", "CString_View",
		"Typeid", "Any_View", "Dyn", "Distinct", "Simd", "Allocator", "Allocator_Error",
	}
	wanted := "Invalid"
	// A `distinct` type is its own public kind: it has a fresh identity, and the
	// shape it wraps stays reachable through `element`.
	under := type_underlying(c, type)
	if type_kind(c, type) == .Distinct {
		wanted = "Distinct"
	} else {
		#partial switch type_kind(c, under) {
		case .Void:            wanted = "Void"
		case .Bool:            wanted = "Bool"
		case .Int:             wanted = type_signed(c, under) ? "Signed_Int" : "Unsigned_Int"
		case .Float:           wanted = "Float"
		case .Rune:            wanted = "Rune"
		case .Raw_Pointer:     wanted = "Raw_Pointer"
		case .Pointer:         wanted = "Pointer"
		case .Multi_Pointer:   wanted = "Multi_Pointer"
		case .Array:           wanted = "Array"
		case .Slice:           wanted = "Slice"
		case .Dynamic_Array:   wanted = "Dynamic_Array"
		case .Map:             wanted = "Map"
		case .Struct:          wanted = "Struct"
		case .Enum:            wanted = "Enum"
		case .Union:           wanted = "Union"
		case .Proc:            wanted = "Proc"
		case .String:          wanted = "String"
		case .String_View:     wanted = "String_View"
		case .CString_View:    wanted = "CString_View"
		case .Typeid:          wanted = "Typeid"
		case .Any_View:        wanted = "Any_View"
		case .Dyn:             wanted = "Dyn"
		case .Allocator:       wanted = "Allocator"
		case .Allocator_Error: wanted = "Allocator_Error"
		}
	}
	for name, index in PUBLIC_KINDS {
		if name == wanted {
			return index
		}
	}
	return 0
}

// The `[]Member_Info` of one aggregate: a struct's public fields, an enum's
// members, a union's variants, or a procedure's parameters and results, in
// declaration order.
@(private = "file")
type_info_members :: proc(e: ^Emitter, member, type: Type_Id) -> string {
	shape := type_of(e.c, type_underlying(e.c, type))
	if shape == nil {
		return "zeroinitializer"
	}
	entries := make([dynamic]string)
	#partial switch shape.kind {
	case .Struct:
		for field, index in shape.fields {
			sym := symbol_of(e.c, field)
			if sym == nil || !sym.public {
				continue // design.md: member tables expose public fields only
			}
			values := make(map[string]string)
			defer delete(values)
			values["kind"] = "0" // Field
			values["name"] = text_constant(e, Const_Value{kind = .String, text = identifier_text(e.c, sym.name)}, false)
			values["tag"] = text_constant(e, Const_Value{kind = .String, text = field_tag_text(e.c, type, sym)}, false)
			values["type"] = fmt.aprintf("%d", typeid_value(e.c, sym.type))
			values["offset"] = fmt.aprintf("%d", type_field_offset(e.c, type, index))
			append(&entries, named_field_constant(e, member, values))
		}
	case .Enum:
		for field in shape.fields {
			sym := symbol_of(e.c, field)
			if sym == nil {
				continue
			}
			low, high := enum_raw_words(e.c, sym.const_value)
			values := make(map[string]string)
			defer delete(values)
			values["kind"] = "1" // Enum_Value
			values["name"] = text_constant(e, Const_Value{kind = .String, text = identifier_text(e.c, sym.name)}, false)
			values["type"] = fmt.aprintf("%d", typeid_value(e.c, type))
			values["value_low"] = low
			values["value_high"] = high
			append(&entries, named_field_constant(e, member, values))
		}
	case .Union:
		for variant in shape.variants {
			values := make(map[string]string)
			defer delete(values)
			values["kind"] = "2" // Union_Variant
			values["name"] = text_constant(e, Const_Value{kind = .String, text = type_name(e.c, variant)}, false)
			values["type"] = fmt.aprintf("%d", typeid_value(e.c, variant))
			append(&entries, named_field_constant(e, member, values))
		}
	case .Proc:
		for parameter in shape.parameters {
			values := make(map[string]string)
			defer delete(values)
			values["kind"] = "3" // Parameter
			values["type"] = fmt.aprintf("%d", typeid_value(e.c, parameter))
			append(&entries, named_field_constant(e, member, values))
		}
		for result in shape.results {
			values := make(map[string]string)
			defer delete(values)
			values["kind"] = "4" // Result
			values["type"] = fmt.aprintf("%d", typeid_value(e.c, result))
			append(&entries, named_field_constant(e, member, values))
		}
	}
	if len(entries) == 0 {
		return "zeroinitializer"
	}
	name := fmt.aprintf("@.loke.members.%d", len(e.globals))
	b := strings.builder_make()
	fmt.sbprintf(&b, "%s = private unnamed_addr constant [%d x %s] [", name, len(entries), struct_name(e, member))
	for entry, index in entries {
		if index > 0 {
			strings.write_string(&b, ",")
		}
		fmt.sbprintf(&b, " %s %s", struct_name(e, member), entry)
	}
	strings.write_string(&b, " ]\n")
	append(&e.globals, strings.to_string(b))
	// `{` is a directive to core:fmt, so the slice constant is built rather than
	// formatted.
	slice := strings.builder_make()
	strings.write_string(&slice, "{ ptr ")
	strings.write_string(&slice, name)
	fmt.sbprintf(&slice, ", i64 %d ", len(entries))
	strings.write_string(&slice, "}")
	return strings.to_string(slice)
}

// design.md: enum values use "the two raw words without narrowing signed or
// unsigned 128-bit values".
//
// ponytail: the low word carries the value and the high word its sign
// extension. Every enum backing this compiler accepts fits in 64 bits today; a
// 128-bit backing needs the real split here and nowhere else.
@(private = "file")
enum_raw_words :: proc(c: ^Compiler, value: Const_Value) -> (low: string, high: string) {
	if value.kind != .Integer {
		return "0", "0"
	}
	mask := bi_sub(c, bi_pow2(c, 64), bi_from_i64(c, 1))
	low_bits := bi_and(c, value.integer, mask)
	high_bits := bi_and(c, bi_shr(c, value.integer, 64), mask)
	low_value, low_ok := bi_to_u64(c, low_bits)
	high_value, high_ok := bi_to_u64(c, high_bits)
	if !low_ok || !high_ok {
		return "0", "0" // both halves were masked to 64 bits; defensive only
	}
	return fmt.aprintf("%d", low_value), fmt.aprintf("%d", high_value)
}

// One aggregate constant, filled by *name* against the record's declared
// fields. design.md's layouts are the ABI authority, so matching by name means a
// reordered or renamed field produces a differently ordered constant rather than
// a silently wrong table.
@(private = "file")
named_field_constant :: proc(e: ^Emitter, record: Type_Id, values: map[string]string) -> string {
	info := type_of(e.c, type_underlying(e.c, record))
	if info == nil {
		backend_fail(e, "a runtime metadata record has no fields")
		return "zeroinitializer"
	}
	b := strings.builder_make()
	strings.write_string(&b, "{")
	for field, index in info.fields {
		sym := symbol_of(e.c, field)
		if sym == nil {
			continue
		}
		if index > 0 {
			strings.write_string(&b, ",")
		}
		name := identifier_text(e.c, sym.name)
		value, supplied := values[name]
		if !supplied {
			zero, ok := zero_const(e.c, sym.type)
			value = ok ? llvm_const(e, zero, sym.type) : "zeroinitializer"
		}
		fmt.sbprintf(&b, " %s %s", llvm_type(e, sym.type), value)
	}
	strings.write_string(&b, " }")
	return strings.to_string(b)
}

// design.md: `type_info_of(0)` and an out-of-range or forged id return nil. The
// builtin lowers to a checked table address, not a runtime call.
@(private = "file")
emit_type_info_of :: proc(e: ^Emitter, v: ^Expr_Call) -> string {
	id := emit_expr(e, v.bound[0])
	limit := temp(e)
	fmt.sbprintfln(&e.b, "  %s = load i64, ptr %s", limit, TYPE_INFO_COUNT)
	zero, past := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i64 %s, 0", zero, id)
	fmt.sbprintfln(&e.b, "  %s = icmp ugt i64 %s, %s", past, id, limit)
	bad := temp(e)
	fmt.sbprintfln(&e.b, "  %s = or i1 %s, %s", bad, zero, past)
	record := e.c.runtime_types["Type_Info"]
	address := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = getelementptr inbounds %s, ptr %s, i64 %s",
		address, struct_name(e, record), TYPE_INFO_TABLE, id,
	)
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, ptr null, ptr %s", out, bad, address)
	return out
}

// ------------------------------------------------------------------- text --

// `{ data, len }` for a slice type.
@(private = "file")
emit_slice_value :: proc(e: ^Emitter, slice_type: Type_Id, data, length: string) -> string {
	storage := llvm_type(e, slice_type)
	first, out := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, ptr %s, %d", first, storage, data, SLICE_DATA)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, i64 %s, %d", out, storage, first, length, SLICE_LEN)
	return out
}

// The data pointer and byte length of a `string` or `string_view` value, which
// is all every text operation needs: the two carriers differ only in whether a
// third word owns the storage.
@(private = "file")
emit_text_parts :: proc(e: ^Emitter, operand: Expr) -> (data: string, length: string) {
	type := type_underlying(e.c, expr_base(operand).type)
	value := emit_expr(e, operand)
	if type_kind(e.c, type) == .CString_View {
		// design.md "C string views": terminated, not measured, so its length is a
		// scan rather than a field.
		length = temp(e)
		fmt.sbprintfln(&e.b, "  %s = call i64 @loke_rt_v1_cstring_len(ptr %s)", length, value)
		return value, length
	}
	storage := llvm_type(e, type)
	data, length = temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", data, storage, value, STRING_DATA)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", length, storage, value, STRING_LEN)
	return data, length
}

@(private = "file")
emit_text_operation :: proc(e: ^Emitter, v: ^Expr_Call) -> []string {
	out := make([]string, 1)
	out[0] = "0"
	switch v.text {
	case .None:
		backend_fail(e, "a text call has no operation")

	case .Byte_Len:
		// design.md: "`len(text)` is shorthand for `text.byte_len()` so that it
		// remains a constant-time operation."
		_, length := emit_text_parts(e, v.bound[0])
		out[0] = length

	case .Rune_Count:
		data, length := emit_text_parts(e, v.bound[0])
		out[0] = temp(e)
		fmt.sbprintfln(&e.b, "  %s = call i64 @loke_rt_v1_rune_count(ptr %s, i64 %s)", out[0], data, length)

	case .Bytes:
		// A read-only `[]u8` over the same storage: the borrow costs nothing and
		// cannot be widened to `[]mut u8`.
		data, length := emit_text_parts(e, v.bound[0])
		out[0] = emit_slice_value(e, v.type, data, length)

	case .Clone:
		data, length := emit_text_parts(e, v.bound[0])
		out[0] = emit_text_allocating_call(
			e, "loke_rt_v1_string_clone",
			fmt.aprintf("ptr %s, i64 %s, ptr %s", data, length, RT_DEFAULT_ALLOCATOR),
			fail_is_panic = true,
		)

	case .To_C_View:
		// ponytail: every `string` buffer is allocated with room for a terminator
		// and a literal already carries one, so the "add a terminator only when
		// necessary" case of design.md's rule never arises and no call-scoped
		// temporary is created. A representation that could hand out an
		// unterminated `string` would need the allocating branch back.
		data, _ := emit_text_parts(e, v.bound[0])
		out[0] = data

	case .To_Runes:
		backend_fail(e, "`to_runes` is gated to M6b and should not reach the backend")

	case .From_Runes:
		slice := emit_expr(e, v.bound[0])
		storage := llvm_type(e, expr_base(v.bound[0]).type)
		data, count := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", data, storage, slice, SLICE_DATA)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", count, storage, slice, SLICE_LEN)
		return emit_text_optional_ok(
			e, "loke_rt_v1_string_from_runes",
			fmt.aprintf("ptr %s, i64 %s, ptr %s", data, count, RT_DEFAULT_ALLOCATOR),
		)
	}
	return out
}

// A runtime call that fills a `string` out-parameter and answers 1 on success.
// The out-pointer form keeps the ABI to pointers and integers, so the C and
// LLVM sides cannot disagree about how a 24-byte aggregate is returned.
@(private = "file")
emit_text_call_slot :: proc(e: ^Emitter, callee: string, arguments: string) -> (slot: string, ok: string) {
	slot = temp(e)
	fmt.sbprintfln(&e.b, "  %s = alloca %s", slot, STRING_TYPE)
	ok = temp(e)
	fmt.sbprintfln(&e.b, "  %s = call i32 @%s(ptr %s, %s)", ok, callee, slot, arguments)
	return slot, ok
}

// design.md "Allocation failure": an implicit allocation — a clone, a
// concatenation — has nowhere to return an error, so failure follows the
// allocator's own policy.
@(private = "file")
emit_text_allocating_call :: proc(e: ^Emitter, callee, arguments: string, fail_is_panic: bool) -> string {
	slot, ok := emit_text_call_slot(e, callee, arguments)
	if fail_is_panic {
		failed := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp eq i32 %s, 0", failed, ok)
		fail, done := new_label(e, "text.failed"), new_label(e, "ok")
		branch_if(e, failed, fail, done)
		fmt.sbprintfln(&e.b, "%s:", fail)
		e.terminated = false
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_alloc_failed(ptr %s)", RT_DEFAULT_ALLOCATOR)
		fmt.sbprintln(&e.b, "  unreachable")
		e.terminated = true
		fmt.sbprintfln(&e.b, "%s:", done)
		e.terminated = false
	}
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", out, STRING_TYPE, slot)
	return out
}

// design.md "Optional-ok results": the value is the zero value on failure, which
// the runtime has already published into the slot.
@(private = "file")
emit_text_optional_ok :: proc(e: ^Emitter, callee, arguments: string) -> []string {
	slot, ok := emit_text_call_slot(e, callee, arguments)
	out := make([]string, 2)
	out[0], out[1] = temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", out[0], STRING_TYPE, slot)
	fmt.sbprintfln(&e.b, "  %s = icmp ne i32 %s, 0", out[1], ok)
	return out
}

// design.md "string type conversions": every one of these validates, so each has
// optional-ok results and publishes the zero value on failure.
@(private = "file")
emit_text_conversion :: proc(e: ^Emitter, v: ^Expr_Call) -> []string {
	switch v.text_conversion {
	case .None:
		break

	case .String_From_Bytes:
		data, length := emit_byte_slice_parts(e, v.bound[0])
		return emit_text_optional_ok(
			e, "loke_rt_v1_string_from_bytes",
			fmt.aprintf("ptr %s, i64 %s, ptr %s", data, length, RT_DEFAULT_ALLOCATOR),
		)

	case .View_From_Bytes:
		// design.md "From []u8 to X": "validate and borrow". No allocation and no
		// copy — the view points into the slice's own root, and `src/borrow.odin`
		// is what keeps it from outliving that root.
		data, length := emit_byte_slice_parts(e, v.bound[0])
		valid, ok := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = call i32 @loke_rt_v1_utf8_valid(ptr %s, i64 %s)", valid, data, length)
		fmt.sbprintfln(&e.b, "  %s = icmp ne i32 %s, 0", ok, valid)
		kept_data, kept_len := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = select i1 %s, ptr %s, ptr null", kept_data, ok, data)
		fmt.sbprintfln(&e.b, "  %s = select i1 %s, i64 %s, i64 0", kept_len, ok, length)
		first, view := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, ptr %s, %d", first, STRING_VIEW_TYPE, kept_data, VIEW_DATA)
		fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, i64 %s, %d", view, STRING_VIEW_TYPE, first, kept_len, VIEW_LEN)
		out := make([]string, 2)
		out[0], out[1] = view, ok
		return out

	case .String_From_C_View:
		// design.md "C string views": "Converting it to `string` scans for the
		// terminator, validates UTF-8, and copies into owned storage."
		pointer := emit_expr(e, v.bound[0])
		length := temp(e)
		fmt.sbprintfln(&e.b, "  %s = call i64 @loke_rt_v1_cstring_len(ptr %s)", length, pointer)
		return emit_text_optional_ok(
			e, "loke_rt_v1_string_from_bytes",
			fmt.aprintf("ptr %s, i64 %s, ptr %s", pointer, length, RT_DEFAULT_ALLOCATOR),
		)
	}
	backend_fail(e, "an unclassified text conversion reached emission")
	out := make([]string, 2)
	out[0], out[1] = "zeroinitializer", "false"
	return out
}

@(private = "file")
emit_byte_slice_parts :: proc(e: ^Emitter, operand: Expr) -> (data: string, length: string) {
	storage := llvm_type(e, expr_base(operand).type)
	value := emit_expr(e, operand)
	data, length = temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", data, storage, value, SLICE_DATA)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", length, storage, value, SLICE_LEN)
	return data, length
}

// design.md "unsafe.raw_data procedure": "A multi-pointer carries neither a
// length nor a read-only capability, and its lifetime is no longer checked after
// conversion." So each of these is an address extraction and nothing more —
// except `unsafe.string_view`, which still validates, because the type it
// produces promises valid UTF-8.
@(private = "file")
emit_unsafe_builtin :: proc(e: ^Emitter, v: ^Expr_Call, kind: Builtin_Kind) -> []string {
	out := make([]string, 1)
	out[0] = "null"
	operand_kind := type_kind(e.c, type_underlying(e.c, expr_base(v.bound[0]).type))
	#partial switch kind {
	case .Unsafe_Raw_Data:
		#partial switch operand_kind {
		case .Slice:
			data, _ := emit_byte_slice_parts(e, v.bound[0])
			out[0] = data
		case .String, .String_View:
			data, _ := emit_text_parts(e, v.bound[0])
			out[0] = data
		case:
			// A pointer to a fixed array, or a `cstring_view`: the value is already
			// the address of the first element.
			out[0] = emit_expr(e, v.bound[0])
		}

	case .Unsafe_C_String_View:
		out[0] = emit_expr(e, v.bound[0])

	case .Unsafe_String_View:
		data := emit_expr(e, v.bound[0])
		length := widen_to_i64(e, emit_expr(e, v.bound[1]), expr_base(v.bound[1]).type)
		valid, ok := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = call i32 @loke_rt_v1_utf8_valid(ptr %s, i64 %s)", valid, data, length)
		fmt.sbprintfln(&e.b, "  %s = icmp ne i32 %s, 0", ok, valid)
		kept_data, kept_len := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = select i1 %s, ptr %s, ptr null", kept_data, ok, data)
		fmt.sbprintfln(&e.b, "  %s = select i1 %s, i64 %s, i64 0", kept_len, ok, length)
		first, view := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, ptr %s, %d", first, STRING_VIEW_TYPE, kept_data, VIEW_DATA)
		fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, i64 %s, %d", view, STRING_VIEW_TYPE, first, kept_len, VIEW_LEN)
		pair := make([]string, 2)
		pair[0], pair[1] = view, ok
		return pair
	}
	return out
}

// ------------------------------------------------------------------- calls --

@(private = "file")
emit_call :: proc(e: ^Emitter, v: ^Expr_Call) -> string {
	if v.is_dyn_call {
		results := emit_dyn_slot_call(e, v)
		return len(results) == 0 ? "0" : results[0]
	}
	if v.resolution.kind == .Conversion && type_is_dyn(e.c, v.type) {
		return emit_dyn_value(e, v)
	}
	if v.text_conversion != .None {
		return emit_text_conversion(e, v)[0]
	}
	if v.resolution.kind == .Conversion {
		return emit_conversion(e, v)
	}
	if v.reflect != .None {
		return emit_descriptor_operation(e, v)
	}
	if v.text != .None {
		return emit_text_operation(e, v)[0]
	}
	symbol := symbol_of(e.c, v.resolution.symbol)
	if symbol != nil && symbol.kind == .Builtin {
		switch symbol.builtin {
		case .Assert:
			// The runtime half of a phase-neutral built-in. design.md makes the
			// message a compile-time string, so it is a module global here and the
			// failure takes the program's panic strategy like every other one.
			cond := emit_expr(e, v.bound[0])
			failed := temp(e)
			fmt.sbprintfln(&e.b, "  %s = xor i1 %s, true", failed, cond)
			panic_if(e, failed, "assert.failed", panic_message_text(e, v, 1, "assertion failed"))
			return "0"
		case .Panic:
			emit_panic(e, panic_message_text(e, v, 0, "explicit panic"))
			return "0"
		case .Hash:
			return emit_hash(e, v.bound[0], v.bound[1])
		case .Iter:
			// The checker rewrote the call to name the chosen `iter` overload, so
			// this arm is only reachable if that failed.
			backend_fail(e, "an `iter` call has no chosen overload")
			return "0"
		case .Len, .Cap:
			// A slice and the two containers reach here; every other `len` folded.
			// Both headers keep the length in the same word a slice does, so the
			// only difference is which one is read.
			source := emit_expr(e, v.bound[0])
			word := symbol.builtin == .Cap ? CONTAINER_CAP : SLICE_LEN
			out := temp(e)
			fmt.sbprintfln(
				&e.b,
				"  %s = extractvalue %s %s, %d",
				out, llvm_type(e, expr_base(v.bound[0]).type), source, word,
			)
			return out
		case .Default_Allocator:
			// design.md "Build-selected providers": the default provider is fixed at
			// build time, so the handle is the runtime's own record.
			return RT_DEFAULT_ALLOCATOR
		case .New, .New_Clone:
			return emit_allocation(e, v, symbol.builtin)
		case .Make:
			return emit_make_container(e, v)[0]
		case .Drop:
			emit_explicit_drop(e, v)
			return "0"
		case .Exchange:
			return emit_exchange(e, v)
		case .Unsafe_Raw_Data, .Unsafe_String_View, .Unsafe_C_String_View:
			return emit_unsafe_builtin(e, v, symbol.builtin)[0]
		case .Type_Info_Of:
			return emit_type_info_of(e, v)
		case .Fmt_Stdout_Writer, .Fmt_Stderr_Writer, .Fmt_Write_Bytes, .Fmt_Format_Any:
			return emit_fmt_builtin(e, v, symbol.builtin)
		case .Free:
			emit_free(e, v)
			return "0"
		case .Free_All:
			emit_region_reset(e, v)
			return "0"
		case .None, .Size_Of, .Align_Of, .Offset_Of,
		     .Type_Of, .Typeid_Of, .Fields_Of, .Enum_Values_Of:
			// These fold to a constant in every reachable case; arriving here
			// would mean emitting a runtime call for a layout query.
			backend_fail(e, "an unfrozen compile-time built-in reached emission")
			return "0"
		}
	}
	results := emit_multi_call(e, v)
	return len(results) == 0 ? "0" : results[0]
}

// `field.get(value)` and `field.pointer(value)`. The descriptor selected one
// field at check time, so both are an ordinary member address, plus a load for
// `get`.
@(private = "file")
emit_descriptor_operation :: proc(e: ^Emitter, v: ^Expr_Call) -> string {
	base := emit_expr(e, v.bound[0])
	owner := type_of(e.c, type_underlying(e.c, expr_base(v.bound[0]).type))
	field := symbol_of(e.c, v.reflect_field)
	address := temp(e)
	fmt.sbprintfln(
		&e.b,
		"  %s = getelementptr inbounds %s, ptr %s, i32 0, i32 %d",
		address, llvm_type(e, owner.element), base, field.index,
	)
	if v.reflect == .Field_Pointer {
		return address
	}
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", out, llvm_type(e, field.type), address)
	return out
}

// The runtime half of the compiler-contributed `hash`. It spells the same two
// steps `hash_const` folds, so a constant hash and a computed one agree.
@(private = "file")
emit_hash :: proc(e: ^Emitter, value_expr, seed_expr: Expr) -> string {
	value := emit_expr(e, value_expr)
	seed := emit_expr(e, seed_expr)
	return emit_hash_value(e, expr_base(value_expr).type, value, seed)
}

emit_hash_value :: proc(e: ^Emitter, type: Type_Id, value, seed: string) -> string {
	under := type_underlying(e.c, type)
	info := type_of(e.c, under)
	if info != nil && info.kind == .Array {
		current := seed
		for index in 0 ..< int(info.count) {
			element := temp(e)
			fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", element, llvm_type(e, under), value, index)
			current = emit_hash_value(e, info.element, element, current)
		}
		return current
	}
	// design.md: `string` and `string_view` hash byte-wise, which is the coherent
	// partner of the byte-wise `==` they already have.
	if type_is_utf8_text(e.c, under) {
		storage := llvm_type(e, under)
		data, length, out := temp(e), temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", data, storage, value, STRING_DATA)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", length, storage, value, STRING_LEN)
		fmt.sbprintfln(
			&e.b, "  %s = call i64 @loke_rt_v1_hash_bytes(ptr %s, i64 %s, i64 %s)",
			out, data, length, seed,
		)
		return out
	}
	bits := emit_hash_bits(e, under, value)
	mixed := temp(e)
	fmt.sbprintfln(&e.b, "  %s = xor i64 %s, %s", mixed, seed, bits)
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = mul i64 %s, %d", out, mixed, HASH_MULTIPLIER)
	return out
}

// One scalar's 64-bit integer image.
@(private = "file")
emit_hash_bits :: proc(e: ^Emitter, under: Type_Id, value: string) -> string {
	info := type_of(e.c, under)
	out := temp(e)
	#partial switch info.kind {
	case .Bool:
		fmt.sbprintfln(&e.b, "  %s = zext i1 %s to i64", out, value)
	case .Raw_Pointer, .Pointer, .Multi_Pointer, .Proc:
		fmt.sbprintfln(&e.b, "  %s = ptrtoint ptr %s to i64", out, value)
	case .Float:
		// design.md: `+0` and `-0` hash identically because they compare equal.
		llvm := llvm_type(e, under)
		pattern := temp(e)
		width := int(info.bits)
		fmt.sbprintfln(&e.b, "  %s = bitcast %s %s to i%d", pattern, llvm, value, width)
		widened := pattern
		if width < 64 {
			widened = temp(e)
			fmt.sbprintfln(&e.b, "  %s = zext i%d %s to i64", widened, width, pattern)
		}
		zero := temp(e)
		fmt.sbprintfln(&e.b, "  %s = fcmp oeq %s %s, 0.0", zero, llvm, value)
		fmt.sbprintfln(&e.b, "  %s = select i1 %s, i64 0, i64 %s", out, zero, widened)
	case:
		width := type_bits(e.c, under)
		if info.kind == .Rune {
			width = 32
		}
		switch {
		case width == 64:
			return value
		case width > 64:
			fmt.sbprintfln(&e.b, "  %s = trunc i%d %s to i64", out, width, value)
		case type_signed(e.c, under) || info.kind == .Rune:
			fmt.sbprintfln(&e.b, "  %s = sext i%d %s to i64", out, width, value)
		case:
			fmt.sbprintfln(&e.b, "  %s = zext i%d %s to i64", out, width, value)
		}
	}
	return out
}

// An operator, index, or slice call. Operator lookup has already chosen one
// named procedure, so this is an ordinary direct call — except for a `delegate`
// overload, which has no body and applies the underlying type's operation to the
// unwrapped operands instead.
@(private = "file")
emit_operator_call :: proc(e: ^Emitter, symbol_id: Symbol_Id, bound: []Expr) -> string {
	symbol := symbol_of(e.c, symbol_id)
	if symbol == nil {
		return "0"
	}
	if symbol.delegated {
		return emit_delegated(e, symbol, bound)
	}
	info := type_of(e.c, symbol.proc_type)
	results := emit_bound_call(e, symbol_id, e.names[symbol_id] or_else "null", info, bound)
	return len(results) == 0 ? "0" : results[0]
}

// A `distinct` newtype's forwarding overload: unwrap, apply the underlying
// operation, and let the wrap back into the distinct type be the no-op it is —
// the two share a representation.
@(private = "file")
emit_delegated :: proc(e: ^Emitter, symbol: ^Symbol, bound: []Expr) -> string {
	// The underlying type's own overload takes the operands as they stand: a
	// distinct type and what it wraps lower to one LLVM type, so unwrapping is
	// the no-op the representation already makes it.
	if symbol.delegate_target != INVALID_SYMBOL {
		return emit_operator_call(e, symbol.delegate_target, bound)
	}
	op := operator_token(symbol.operator)
	underlying := symbol.delegate_underlying
	if len(bound) == 1 {
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = xor i1 %s, true", out, emit_expr(e, bound[0]))
		return out
	}
	lhs := emit_expr(e, bound[0])
	rhs := emit_expr(e, bound[1])
	#partial switch op {
	case .Eq_Eq, .Not_Eq, .Lt, .Lt_Eq, .Gt, .Gt_Eq:
		return emit_compare(e, op, underlying, lhs, rhs)
	}
	return emit_binary_op(e, op, underlying, underlying, lhs, rhs)
}

// Every result of an expression that produces several: a call, a comma-ok type
// assertion, an `or_else`, or an `or_return`.
@(private = "file")
emit_multi_value :: proc(e: ^Emitter, expr: Expr) -> []string {
	#partial switch v in expr {
	case ^Expr_Call:
		// A conversion and a built-in are calls in syntax only, and each has its
		// own lowering; `emit_call` is what knows the difference.
		if kind := call_builtin_kind(e, v); kind == .New || kind == .New_Clone {
			return emit_allocation_pair(e, v, kind)
		}
		if call_builtin_kind(e, v) == .Make {
			return emit_make_container(e, v)
		}
		if v.text != .None {
			return emit_text_operation(e, v)
		}
		if v.text_conversion != .None {
			return emit_text_conversion(e, v)
		}
		if kind := call_builtin_kind(e, v); kind == .Unsafe_String_View {
			return emit_unsafe_builtin(e, v, kind)
		}
		if len(v.result_types) > 1 {
			return emit_multi_call(e, v)
		}
		single := make([]string, 1)
		single[0] = emit_expr(e, expr)
		return single
	case ^Expr_Index:
		// `elem, ok := m[key]`, the comma-ok form of a non-inserting read.
		if v.operand != nil && type_is_map(e.c, expr_base(v.operand).type) && !v.map_inserts {
			return emit_map_lookup(e, v)
		}
		single := make([]string, 1)
		single[0] = emit_expr(e, expr)
		return single
	case ^Expr_Type_Assert:
		return emit_type_assert(e, v)
	case ^Expr_Or_Else:
		return emit_or_else(e, v)
	case ^Expr_Postfix:
		if v.op == .Or_Return {
			return emit_or_return(e, v)
		}
	}
	single := make([]string, 1)
	single[0] = emit_expr(e, expr)
	return single
}

@(private = "file")
call_builtin_kind :: proc(e: ^Emitter, v: ^Expr_Call) -> Builtin_Kind {
	if v.resolution.kind == .Conversion || v.reflect != .None {
		return .None
	}
	sym := symbol_of(e.c, v.resolution.symbol)
	return sym != nil && sym.kind == .Builtin ? sym.builtin : Builtin_Kind.None
}

// design.md "Allocation failure": `new` and `new_clone` "always return an error
// and do not invoke the allocator failure policy". So there is no branch on
// failure here — the caller receives a null pointer and a non-nil error and
// decides.
//
@(private = "file")
emit_allocation_pair :: proc(e: ^Emitter, v: ^Expr_Call, kind: Builtin_Kind) -> []string {
	// design.md: `new_clone` "creates a new allocation root containing a clone of
	// the value", so a record whose clone can fail goes through its hook rather
	// than through a shallow store of the representation.
	if kind == .New_Clone && type_clone_is_fallible(e.c, v.alloc_type) {
		return emit_new_clone_hook(e, v)
	}
	// `new(T)` binds only an allocator; `new_clone(v)` binds the value first.
	allocator := emit_allocator_operand(e, v, kind == .New ? 0 : 1)
	size, align := type_size(e.c, v.alloc_type), type_align(e.c, v.alloc_type)
	pointer := temp(e)
	if kind == .New {
		// design.md: `new` zero-initialises.
		fmt.sbprintfln(
			&e.b, "  %s = call ptr @loke_rt_v1_alloc_zeroed(ptr %s, i64 %d, i64 %d)",
			pointer, allocator, size, align,
		)
	} else {
		fmt.sbprintfln(
			&e.b, "  %s = call ptr @loke_rt_v1_alloc(ptr %s, i64 %d, i64 %d)",
			pointer, allocator, size, align,
		)
	}
	failed := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", failed, pointer)

	if kind == .New_Clone {
		// A failed allocation has nothing to clone into, so the copy is guarded.
		// Nothing is partially built on that path: this arm only runs for a value
		// whose clone is the copy its representation already is.
		store_label, done_label := new_label(e, "newclone.store"), new_label(e, "newclone.done")
		fmt.sbprintfln(&e.b, "  br i1 %s, label %%%s, label %%%s", failed, done_label, store_label)
		place_label(e, store_label)
		store(e, v.alloc_type, emit_expr(e, v.bound[0]), pointer)
		branch(e, done_label)
		place_label(e, done_label)
		e.terminated = false
	}

	error := temp(e)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, i64 1, i64 0", error, failed)
	out := make([]string, 2)
	out[0], out[1] = pointer, error
	return out
}

// The clone-through-a-hook half of `new_clone`, and the only path with a
// partially cloned allocation to destroy: the hook already cleaned its own
// temporary, so what is left is the block it was going to be published into.
// The result travels through storage rather than phi nodes, so the three exits
// do not need their predecessor labels tracked.
@(private = "file")
emit_new_clone_hook :: proc(e: ^Emitter, v: ^Expr_Call) -> []string {
	value_type := llvm_type(e, v.alloc_type)
	value := emit_expr(e, v.bound[0])
	allocator := emit_allocator_operand(e, v, 1)
	size, align := type_size(e.c, v.alloc_type), type_align(e.c, v.alloc_type)

	pointer_slot, error_slot := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = alloca ptr", pointer_slot)
	fmt.sbprintfln(&e.b, "  %s = alloca i64", error_slot)
	fmt.sbprintfln(&e.b, "  store ptr null, ptr %s", pointer_slot)
	fmt.sbprintfln(&e.b, "  store i64 1, ptr %s", error_slot)

	pointer := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call ptr @loke_rt_v1_alloc(ptr %s, i64 %d, i64 %d)",
		pointer, allocator, size, align,
	)
	no_memory := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", no_memory, pointer)
	clone_label := new_label(e, "newclone.clone")
	done_label := new_label(e, "newclone.done")
	branch_if(e, no_memory, done_label, clone_label)

	place_label(e, clone_label)
	hook := type_hook(e.c, v.alloc_type, "try_clone")
	if hook == INVALID_SYMBOL {
		backend_fail(e, "a fallible `new_clone` has no `try_clone` member")
		failed := make([]string, 2)
		failed[0], failed[1] = "null", "1"
		return failed
	}
	pair := clone_pair_type(value_type)
	returned := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call %s %s(%s %s, ptr %s)",
		returned, pair, e.names[hook], value_type, value, allocator,
	)
	cloned, error, failed := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, 0", cloned, pair, returned)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, 1", error, pair, returned)
	fmt.sbprintfln(&e.b, "  %s = icmp ne i64 %s, 0", failed, error)
	release_label, publish_label := new_label(e, "newclone.release"), new_label(e, "newclone.publish")
	branch_if(e, failed, release_label, publish_label)

	place_label(e, release_label)
	fmt.sbprintfln(
		&e.b, "  call void @loke_rt_v1_free(ptr %s, ptr %s, i64 %d, i64 %d)",
		allocator, pointer, size, align,
	)
	fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", error, error_slot)
	branch(e, done_label)

	place_label(e, publish_label)
	store(e, v.alloc_type, cloned, pointer)
	fmt.sbprintfln(&e.b, "  store ptr %s, ptr %s", pointer, pointer_slot)
	fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", error_slot)
	branch(e, done_label)

	place_label(e, done_label)
	e.terminated = false
	out := make([]string, 2)
	out[0], out[1] = temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = load ptr, ptr %s", out[0], pointer_slot)
	fmt.sbprintfln(&e.b, "  %s = load i64, ptr %s", out[1], error_slot)
	return out
}

@(private = "file")
emit_allocation :: proc(e: ^Emitter, v: ^Expr_Call, kind: Builtin_Kind) -> string {
	return emit_allocation_pair(e, v, kind)[0]
}

// `make(T, counts..., allocator)`. The checker bound the counts in written
// order followed by the allocator, so this only has to run them.
//
// The header is built in storage and published complete: the provider handle is
// written first, because the reserve below allocates *through* it, and a failed
// reserve leaves an empty container bound to that same provider rather than
// something half-built (m6b-plan decision "Atomic mutation").
@(private = "file")
emit_make_container :: proc(e: ^Emitter, v: ^Expr_Call) -> []string {
	is_map := type_is_map(e.c, v.alloc_type)
	counts := is_map ? 1 : 2
	values := make([]string, counts)
	for index in 0 ..< counts {
		values[index] = v.bound[index] == nil ? "" : emit_expr(e, v.bound[index])
	}
	allocator := v.bound[counts] == nil ? RT_DEFAULT_ALLOCATOR : emit_expr(e, v.bound[counts])

	header := temp(e)
	fmt.sbprintfln(&e.b, "  %s = alloca %s", header, CONTAINER_TYPE)
	fmt.sbprintfln(&e.b, "  store %s zeroinitializer, ptr %s", CONTAINER_TYPE, header)
	provider := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = getelementptr inbounds %s, ptr %s, i32 0, i32 %d",
		provider, CONTAINER_TYPE, header, CONTAINER_ALLOC,
	)
	fmt.sbprintfln(&e.b, "  store ptr %s, ptr %s", allocator, provider)

	// design.md: `cap` defaults to `len`, and a `len > cap` relationship is an
	// ordinary program fault rather than an allocation failure.
	length := values[0] == "" ? "0" : values[0]
	capacity := length
	if !is_map && len(values) > 1 && values[1] != "" {
		capacity = values[1]
		bad := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp sgt i64 %s, %s", bad, length, capacity)
		panic_if(e, bad, "make.len_gt_cap", "a container's length cannot exceed its capacity")
	}
	negative := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp slt i64 %s, 0", negative, length)
	panic_if(e, negative, "make.negative", "a container's length cannot be negative")

	helper := is_map ? "loke_rt_v1_map_reserve" : "loke_rt_v1_dyn_reserve"
	status := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call i32 @%s(ptr %s, ptr %s, i64 %s)",
		status, helper, header, container_ops_global(e, v.alloc_type), capacity,
	)
	failed := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i32 %s, 0", failed, status)
	fill_label, done_label := new_label(e, "make.fill"), new_label(e, "make.done")
	branch_if(e, failed, done_label, fill_label)

	// A dynamic array's initial length is `len` zero values. Every Loke zero
	// value is all-zero bits, so this is one memset rather than a per-element
	// loop, and dropping those zeros is the no-op every hook must already handle.
	place_label(e, fill_label)
	if !is_map {
		element := container_element(e.c, v.alloc_type)
		data, bytes := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = load ptr, ptr %s", data, header)
		fmt.sbprintfln(&e.b, "  %s = mul i64 %s, %d", bytes, length, type_size(e.c, element))
		fmt.sbprintfln(&e.b, "  call void @llvm.memset.p0.i64(ptr %s, i8 0, i64 %s, i1 false)", data, bytes)
		count_slot := temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = getelementptr inbounds %s, ptr %s, i32 0, i32 %d",
			count_slot, CONTAINER_TYPE, header, CONTAINER_LEN,
		)
		fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", length, count_slot)
	}
	branch(e, done_label)
	place_label(e, done_label)
	e.terminated = false

	out := make([]string, 2)
	out[0], out[1] = temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", out[0], CONTAINER_TYPE, header)
	fmt.sbprintfln(&e.b, "  %s = zext i1 %s to i64", out[1], failed)
	return out
}

// design.md: "Deallocation operations such as `free` and `drop` return no
// status." The checker has already restricted the operand to a binding holding a
// fresh allocation base, so the pointee type supplies the size and alignment the
// provider was given at `new`.
//
// ponytail: `free` names no allocator, and design.md makes matching the creating
// one the program's obligation. M6a installs exactly one provider, so the
// default record is always the right one; M6b's arenas need the allocation to
// carry its provider, or `free` to name it.
@(private = "file")
emit_free :: proc(e: ^Emitter, v: ^Expr_Call) {
	pointer := emit_expr(e, v.bound[0])
	allocator := emit_allocator_operand(e, v, 1)
	info := type_of(e.c, type_underlying(e.c, expr_base(v.bound[0]).type))
	if info == nil || info.kind != .Pointer {
		backend_fail(e, "`free` did not receive an allocation pointer")
		return
	}
	fmt.sbprintfln(
		&e.b, "  call void @loke_rt_v1_free(ptr %s, ptr %s, i64 %d, i64 %d)",
		allocator, pointer, type_size(e.c, info.element), type_align(e.c, info.element),
	)
}

// design.md "Type assertions are always checked": a single-value assertion traps
// on a mismatch, and the comma-ok form yields a zeroed payload with `false`.
@(private = "file")
emit_type_assert :: proc(e: ^Emitter, v: ^Expr_Type_Assert) -> []string {
	union_type := expr_base(v.operand).type
	if union_type == TYPE_ANY_VIEW {
		return emit_any_view_assert(e, v)
	}
	shape := union_layout(e.c, union_type)
	tag_llvm := fmt.aprintf("i%d", shape.tag_bytes * 8)
	value := emit_expr(e, v.operand)
	slot := emit_union_spill(e, union_type, value)
	tag := emit_union_tag(e, union_type, value)

	matched := temp(e)
	fmt.sbprintfln(
		&e.b,
		"  %s = icmp eq %s %s, %d",
		matched, tag_llvm, tag, union_variant_tag(e.c, union_type, v.type),
	)
	if !v.optional {
		failed := temp(e)
		fmt.sbprintfln(&e.b, "  %s = xor i1 %s, true", failed, matched)
		panic_if(e, failed, "assert.variant", "type assertion failed")
		out := make([]string, 1)
		out[0] = emit_union_payload(e, union_type, v.type, slot)
		return out
	}
	// The zeroed payload is selected by address, so no aggregate has to be
	// selected and nothing out of bounds is ever read.
	llvm := llvm_type(e, v.type)
	zero_slot := temp(e)
	fmt.sbprintfln(&e.b, "  %s = alloca %s", zero_slot, llvm)
	fmt.sbprintfln(&e.b, "  store %s zeroinitializer, ptr %s", llvm, zero_slot)
	payload := temp(e)
	fmt.sbprintfln(
		&e.b,
		"  %s = getelementptr inbounds %s, ptr %s, i32 0, i32 0",
		payload, llvm_type(e, union_type), slot,
	)
	chosen := temp(e)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, ptr %s, ptr %s", chosen, matched, payload, zero_slot)
	loaded := temp(e)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", loaded, llvm, chosen)

	out := make([]string, 2)
	out[0], out[1] = loaded, matched
	return out
}

// design.md "or_else expression": the fallback is evaluated only when `ok` is
// false, which is why it lives in its own block.
@(private = "file")
emit_or_else :: proc(e: ^Emitter, v: ^Expr_Or_Else) -> []string {
	values := emit_multi_value(e, v.value)
	ok := values[len(values) - 1]
	payloads := values[:len(values) - 1]

	entry := new_label(e, "orelse.entry")
	fallback_label := new_label(e, "orelse.fallback")
	done := new_label(e, "orelse.done")
	branch(e, entry)
	fmt.sbprintfln(&e.b, "%s:", entry)
	e.terminated = false
	branch_if(e, ok, done, fallback_label)

	fmt.sbprintfln(&e.b, "%s:", fallback_label)
	e.terminated = false
	fallback := emit_multi_value(e, v.fallback)
	fallback_exit := new_label(e, "orelse.fallback.exit")
	branch(e, fallback_exit)
	fmt.sbprintfln(&e.b, "%s:", fallback_exit)
	e.terminated = false
	branch(e, done)

	fmt.sbprintfln(&e.b, "%s:", done)
	e.terminated = false
	out := make([]string, len(payloads))
	types := expr_base(v.value).result_types
	for index in 0 ..< len(payloads) {
		joined := temp(e)
		fmt.sbprintfln(
			&e.b,
			"  %s = phi %s [ %s, %%%s ], [ %s, %%%s ]",
			joined, llvm_type(e, types[index]), payloads[index], entry, fallback[index], fallback_exit,
		)
		out[index] = joined
	}
	return out
}

// design.md "or_return operator": on failure the status is assigned to the final
// result and control leaves through the ordinary epilogue, so `defer` ordering
// stays in one implementation.
@(private = "file")
emit_or_return :: proc(e: ^Emitter, v: ^Expr_Postfix) -> []string {
	values := emit_multi_value(e, v.operand)
	operand := expr_base(v.operand)
	status_type := operand.type
	if len(operand.result_types) > 0 {
		status_type = operand.result_types[len(operand.result_types) - 1]
	}
	status := values[len(values) - 1]
	failed := emit_status_failed(e, status_type, status)

	fail_label := new_label(e, "orreturn.fail")
	ok_label := new_label(e, "orreturn.ok")
	branch_if(e, failed, fail_label, ok_label)

	fmt.sbprintfln(&e.b, "%s:", fail_label)
	e.terminated = false
	last := len(e.result_slots) - 1
	if last >= 0 {
		target := e.result_types[last]
		if target != status_type && type_is_union(e.c, target) && union_holds(e.c, target, status_type) {
			status = emit_union_value(e, target, status_type, status)
		}
		store(e, target, status, e.result_slots[last])
	}
	emit_epilogue(e)

	fmt.sbprintfln(&e.b, "%s:", ok_label)
	e.terminated = false
	return values[:len(values) - 1]
}

// The status is successful when it is `true` for `bool`, or `nil` for a
// nil-comparable type. No other truthiness rules apply.
@(private = "file")
emit_status_failed :: proc(e: ^Emitter, status_type: Type_Id, status: string) -> string {
	out := temp(e)
	if type_is_union(e.c, status_type) {
		shape := union_layout(e.c, status_type)
		tag := emit_union_tag(e, status_type, status)
		result := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp ne i%d %s, 0", result, shape.tag_bytes * 8, tag)
		return result
	}
	if type_is_boolean(e.c, status_type) {
		fmt.sbprintfln(&e.b, "  %s = xor i1 %s, true", out, status)
		return out
	}
	fmt.sbprintfln(&e.b, "  %s = icmp ne ptr %s, null", out, status)
	return out
}

// Emits the call and returns one operand per result.
@(private = "file")
emit_multi_call :: proc(e: ^Emitter, v: ^Expr_Call) -> []string {
	callee_type := type_of(e.c, type_underlying(e.c, expr_base(v.callee).type))
	symbol := symbol_of(e.c, v.resolution.symbol)

	callee := ""
	if symbol != nil && symbol.kind == .Proc {
		callee = e.names[v.resolution.symbol] or_else "null"
	} else {
		callee = emit_expr(e, v.callee)
		// A procedure value may be nil; the call takes the same trap seam every
		// other defined runtime failure does.
		is_nil := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", is_nil, callee)
		panic_if(e, is_nil, "nil.call", "call through a nil procedure value")
	}

	return emit_bound_call(e, v.resolution.symbol, callee, callee_type, v.bound, v)
}

// design.md "Variadic parameters": the callee always receives one read-only
// slice, so the caller either forwards a compatible spread as-is or builds
// compiler-owned contiguous storage and hands over a slice of it.
//
// The storage is a stack buffer: fixed-size when the element count is static,
// and a checked dynamic `alloca` when a spread makes it runtime-sized. Nothing
// here depends on M6b's dynamic arrays.
@(private = "file")
Variadic_Pack :: struct {
	value:   string,
	cleanup: Deferred,
}

@(private = "file")
register_variadic_cleanup :: proc(
	e: ^Emitter, element: Type_Id, buffer, flags, count: string,
) -> Deferred {
	entry := Deferred {
		type             = element,
		array_cleanup    = true,
		array_buffer     = buffer,
		array_flags      = flags,
		array_count      = count,
		array_buffer_env = -1,
		array_flags_env  = -1,
		array_count_env  = -1,
		slot             = -1,
	}
	if unwind_enabled(e) {
		entry.array_buffer_env = unwind_reserve_env(e)
		entry.array_flags_env = unwind_reserve_env(e)
		entry.array_count_env = unwind_reserve_env(e)
	}
	unwind_reserve(e, &entry)
	unwind_publish_env(e, entry.array_buffer_env, buffer)
	unwind_publish_env(e, entry.array_flags_env, flags)
	unwind_publish_env(e, entry.array_count_env, count)
	unwind_register(e, entry)
	return entry
}

@(private = "file")
checked_variadic_total :: proc(e: ^Emitter, total, added: string) -> string {
	negative := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp slt i64 %s, 0", negative, added)
	panic_if(e, negative, "variadic.length", "invalid variadic spread length")
	sum := temp(e)
	fmt.sbprintfln(&e.b, "  %s = add i64 %s, %s", sum, total, added)
	overflow := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp ult i64 %s, %s", overflow, sum, total)
	panic_if(e, overflow, "variadic.size", "variadic argument pack is too large")
	return sum
}

@(private = "file")
emit_variadic_pack :: proc(e: ^Emitter, v: ^Expr_Call, pack_type: Type_Id) -> Variadic_Pack {
	// A sole compatible spread forwards its slice directly, which is what makes
	// `println(..args)` inside a variadic procedure cost nothing.
	if v.variadic_forwards {
		return Variadic_Pack{value = emit_expr(e, v.bound[v.variadic_slot])}
	}
	element := slice_element(e.c, pack_type)
	element_llvm := llvm_type(e, element)
	static_count := len(v.variadic_elements)
	if len(v.variadic_spreads) == 0 && static_count == 0 {
		// design.md's `sum()` case: an empty pack is a nil slice, which has length
		// 0 and points at no storage.
		return Variadic_Pack{value = "zeroinitializer"}
	}
	managed := type_is_managed(e.c, element)

	// Managed explicit operands first enter fixed staging storage. That storage
	// is already registered while later operands are evaluated, so a panic cannot
	// strand an owned temporary before the runtime-sized final buffer exists.
	staging, staging_flags, staging_count := "", "", ""
	staging_cleanup := Deferred{slot = -1}
	if managed && static_count > 0 {
		staging, staging_flags, staging_count = temp(e), temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = alloca [%d x %s]", staging, static_count, element_llvm)
		fmt.sbprintfln(&e.b, "  %s = alloca [%d x i1]", staging_flags, static_count)
		fmt.sbprintfln(
			&e.b, "  call void @llvm.memset.p0.i64(ptr %s, i8 0, i64 %d, i1 false)",
			staging_flags, static_count,
		)
		fmt.sbprintfln(&e.b, "  %s = alloca i64", staging_count)
		fmt.sbprintfln(&e.b, "  store i64 %d, ptr %s", static_count, staging_count)
		staging_cleanup = register_variadic_cleanup(e, element, staging, staging_flags, staging_count)
	}

	// Every operand is evaluated once, in written order, before any storage is
	// formed: a spread's length is part of the size the buffer needs.
	elements := make([]string, static_count)
	spreads := make([]string, len(v.variadic_spreads))
	spread_data := make([]string, len(v.variadic_spreads))
	spread_len := make([]string, len(v.variadic_spreads))
	next_element, next_spread := 0, 0
	total := fmt.aprintf("%d", static_count)
	for is_spread in v.variadic_order {
		if is_spread {
			expr := v.variadic_spreads[next_spread]
			spreads[next_spread] = emit_expr(e, expr)
			storage := llvm_type(e, expr_base(expr).type)
			data, length := temp(e), temp(e)
			fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", data, storage, spreads[next_spread], SLICE_DATA)
			fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", length, storage, spreads[next_spread], SLICE_LEN)
			spread_data[next_spread], spread_len[next_spread] = data, length
			total = checked_variadic_total(e, total, length)
			next_spread += 1
			continue
		}
		expr := v.variadic_elements[next_element]
		value := emit_expr(e, expr)
		// A borrowed owner is cloned; a temporary or move already owns the value
		// transferred into staging.
		if managed && expression_is_borrowed_place(e.c, expr) {
			value = emit_clone_value(e, element, value)
		}
		elements[next_element] = value
		if managed {
			slot, flag := temp(e), temp(e)
			fmt.sbprintfln(
				&e.b, "  %s = getelementptr inbounds [%d x %s], ptr %s, i64 0, i64 %d",
				slot, static_count, element_llvm, staging, next_element,
			)
			store(e, element, value, slot)
			fmt.sbprintfln(&e.b, "  %s = getelementptr i1, ptr %s, i64 %d", flag, staging_flags, next_element)
			fmt.sbprintfln(&e.b, "  store i1 true, ptr %s", flag)
		}
		next_element += 1
	}

	buffer := temp(e)
	if len(v.variadic_spreads) == 0 {
		fmt.sbprintfln(&e.b, "  %s = alloca [%d x %s]", buffer, static_count, element_llvm)
	} else {
		limit := u64(max(i64)) / max(type_size(e.c, element), 1)
		too_large := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp ugt i64 %s, %d", too_large, total, limit)
		panic_if(e, too_large, "variadic.size", "variadic argument pack is too large")
		fmt.sbprintfln(&e.b, "  %s = alloca %s, i64 %s", buffer, element_llvm, total)
	}
	final_flags, final_count := "", ""
	cleanup := Deferred{slot = -1}
	if managed {
		final_flags, final_count = temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = alloca i1, i64 %s", final_flags, total)
		fmt.sbprintfln(&e.b, "  call void @llvm.memset.p0.i64(ptr %s, i8 0, i64 %s, i1 false)", final_flags, total)
		fmt.sbprintfln(&e.b, "  %s = alloca i64", final_count)
		fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", total, final_count)
		cleanup = register_variadic_cleanup(e, element, buffer, final_flags, final_count)
	}

	cursor := "0"
	cursor_slot := ""
	if managed {
		cursor_slot = temp(e)
		fmt.sbprintfln(&e.b, "  %s = alloca i64", cursor_slot)
		fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", cursor_slot)
	}
	next_element, next_spread = 0, 0
	for is_spread in v.variadic_order {
		if managed {
			if is_spread {
				index_slot := temp(e)
				fmt.sbprintfln(&e.b, "  %s = alloca i64", index_slot)
				fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", index_slot)
				head, body, done := new_label(e, "vararg.copy.head"), new_label(e, "vararg.copy.body"), new_label(e, "vararg.copy.done")
				branch(e, head)
				place_label(e, head)
				index := temp(e)
				fmt.sbprintfln(&e.b, "  %s = load i64, ptr %s", index, index_slot)
				more := temp(e)
				fmt.sbprintfln(&e.b, "  %s = icmp ult i64 %s, %s", more, index, spread_len[next_spread])
				branch_if(e, more, body, done)
				place_label(e, body)
				source, loaded := temp(e), temp(e)
				fmt.sbprintfln(&e.b, "  %s = getelementptr inbounds %s, ptr %s, i64 %s", source, element_llvm, spread_data[next_spread], index)
				fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", loaded, element_llvm, source)
				cloned := emit_clone_value(e, element, loaded)
				position, destination := temp(e), temp(e)
				fmt.sbprintfln(&e.b, "  %s = load i64, ptr %s", position, cursor_slot)
				fmt.sbprintfln(&e.b, "  %s = getelementptr inbounds %s, ptr %s, i64 %s", destination, element_llvm, buffer, position)
				store(e, element, cloned, destination)
				flag := temp(e)
				fmt.sbprintfln(&e.b, "  %s = getelementptr i1, ptr %s, i64 %s", flag, final_flags, position)
				fmt.sbprintfln(&e.b, "  store i1 true, ptr %s", flag)
				next_index, next_position := temp(e), temp(e)
				fmt.sbprintfln(&e.b, "  %s = add i64 %s, 1", next_index, index)
				fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", next_index, index_slot)
				fmt.sbprintfln(&e.b, "  %s = add i64 %s, 1", next_position, position)
				fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", next_position, cursor_slot)
				branch(e, head)
				place_label(e, done)
				next_spread += 1
				continue
			}
			position, destination, source := temp(e), temp(e), temp(e)
			fmt.sbprintfln(&e.b, "  %s = load i64, ptr %s", position, cursor_slot)
			fmt.sbprintfln(&e.b, "  %s = getelementptr inbounds %s, ptr %s, i64 %s", destination, element_llvm, buffer, position)
			fmt.sbprintfln(
				&e.b, "  %s = getelementptr inbounds [%d x %s], ptr %s, i64 0, i64 %d",
				source, static_count, element_llvm, staging, next_element,
			)
			loaded := temp(e)
			fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", loaded, element_llvm, source)
			store(e, element, loaded, destination)
			final_flag, staging_flag := temp(e), temp(e)
			fmt.sbprintfln(&e.b, "  %s = getelementptr i1, ptr %s, i64 %s", final_flag, final_flags, position)
			fmt.sbprintfln(&e.b, "  store i1 true, ptr %s", final_flag)
			fmt.sbprintfln(&e.b, "  %s = getelementptr i1, ptr %s, i64 %d", staging_flag, staging_flags, next_element)
			fmt.sbprintfln(&e.b, "  store i1 false, ptr %s", staging_flag)
			next_position := temp(e)
			fmt.sbprintfln(&e.b, "  %s = add i64 %s, 1", next_position, position)
			fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", next_position, cursor_slot)
			next_element += 1
			continue
		}
		slot := temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = getelementptr inbounds %s, ptr %s, i64 %s",
			slot, element_llvm, buffer, cursor,
		)
		if is_spread {
			bytes := temp(e)
			fmt.sbprintfln(
				&e.b, "  %s = mul i64 %s, %d",
				bytes, spread_len[next_spread], type_size(e.c, element),
			)
			fmt.sbprintfln(
				&e.b, "  call void @llvm.memcpy.p0.p0.i64(ptr %s, ptr %s, i64 %s, i1 false)",
				slot, spread_data[next_spread], bytes,
			)
			advanced := temp(e)
			fmt.sbprintfln(&e.b, "  %s = add i64 %s, %s", advanced, cursor, spread_len[next_spread])
			cursor = advanced
			next_spread += 1
			continue
		}
		store(e, element, elements[next_element], slot)
		advanced := temp(e)
		fmt.sbprintfln(&e.b, "  %s = add i64 %s, 1", advanced, cursor)
		cursor = advanced
		next_element += 1
	}
	if staging_cleanup.array_cleanup {
		unwind_clear(e, staging_cleanup.slot)
	}
	return Variadic_Pack{value = emit_slice_value(e, pack_type, buffer, total), cleanup = cleanup}
}

// The shared call sequence: bind the operands left to right, emit the call, and
// hand back one operand per result.
@(private = "file")
emit_bound_call :: proc(
	e: ^Emitter,
	symbol_id: Symbol_Id,
	callee: string,
	callee_type: ^Type_Info,
	bound: []Expr,
	call_node: ^Expr_Call = nil,
) -> []string {
	symbol := symbol_of(e.c, symbol_id)
	if callee_type == nil {
		return nil
	}
	// Arguments are bound left to right. A default that names a parameter to its
	// left reads the value bound a moment ago, which is why this map exists.
	outer_params := e.param_values
	e.param_values = make(map[Symbol_Id]string)
	defer {
		delete(e.param_values)
		e.param_values = outer_params
	}

	operands := make([]string, len(bound))
	// design.md "Variadic parameters": the pack is materialised where it appears
	// in the argument order, so the explicit arguments and the spreads are
	// evaluated exactly once, left to right, together with the fixed ones.
	pack := -1
	if call_node != nil && call_node.is_variadic {
		pack = call_node.variadic_slot
	}
	pack_cleanup := Deferred{slot = -1}
	for argument, index in bound {
		if index == pack {
			packed := emit_variadic_pack(e, call_node, callee_type.parameters[index])
			operands[index] = packed.value
			pack_cleanup = packed.cleanup
			continue
		}
		mode := index < len(callee_type.param_modes) ? callee_type.param_modes[index] : Param_Mode.Value
		if mode == .Inout {
			operands[index] = emit_address(e, argument)
		} else {
			operands[index] = emit_expr(e, argument)
		}
		// design.md: method-call syntax supplies the receiver's `move` marker
		// implicitly, so the source is read and then killed here rather than by an
		// `Expr_Move` the caller wrote.
		if index == 0 && symbol != nil && symbol.receiver == .Move {
			if ident, is_ident := argument.(^Expr_Ident); is_ident {
				kill_place(e, ident.symbol)
			}
		}
		if symbol != nil && index < len(symbol.param_symbols) && symbol.param_symbols[index] != INVALID_SYMBOL {
			e.param_values[symbol.param_symbols[index]] = operands[index]
		}
	}

	result_type := llvm_result_type(e, callee_type.results, callee_type.result_inout)
	call := ""
	if len(callee_type.results) > 0 {
		call = temp(e)
		fmt.sbprintf(&e.b, "  %s = call %s %s(", call, result_type, callee)
	} else {
		fmt.sbprintf(&e.b, "  call void %s(", callee)
	}
	for operand, index in operands {
		if index > 0 {
			fmt.sbprint(&e.b, ", ")
		}
		mode := index < len(callee_type.param_modes) ? callee_type.param_modes[index] : Param_Mode.Value
		type := mode == .Inout ? "ptr" : llvm_type(e, callee_type.parameters[index])
		fmt.sbprintf(&e.b, "%s %s", type, operand)
	}
	fmt.sbprintln(&e.b, ")")
	if pack_cleanup.array_cleanup {
		emit_drop_flagged_array(
			e, pack_cleanup.type, pack_cleanup.array_buffer,
			pack_cleanup.array_flags, pack_cleanup.array_count,
		)
		unwind_clear(e, pack_cleanup.slot)
	}

	switch len(callee_type.results) {
	case 0:
		return nil
	case 1:
		single := make([]string, 1)
		single[0] = call
		return single
	}
	results := make([]string, len(callee_type.results))
	for index in 0 ..< len(callee_type.results) {
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", out, result_type, call, index)
		results[index] = out
	}
	return results
}

@(private = "file")
emit_conversion :: proc(e: ^Emitter, v: ^Expr_Call) -> string {
	if v.text_conversion != .None {
		return emit_text_conversion(e, v)[0]
	}
	source_expr := v.bound[0]
	source := expr_base(source_expr).type
	target := v.type
	value := emit_expr(e, source_expr)

	from := type_underlying(e.c, source)
	to := type_underlying(e.c, target)
	if llvm_type(e, from) == llvm_type(e, to) {
		return value
	}

	from_float := type_is_float(e.c, from)
	to_float := type_is_float(e.c, to)
	from_bits, to_bits := type_bits(e.c, from), type_bits(e.c, to)
	from_signed := type_signed(e.c, from) || type_is_rune(e.c, from)
	to_signed := type_signed(e.c, to) || type_is_rune(e.c, to)

	operation := ""
	switch {
	case from_float && to_float:
		operation = from_bits > to_bits ? "fptrunc" : "fpext"
	case from_float:
		operation = to_signed ? "fptosi" : "fptoui"
	case to_float:
		operation = from_signed ? "sitofp" : "uitofp"
	case from_bits > to_bits:
		operation = "trunc"
	case from_bits < to_bits:
		operation = from_signed ? "sext" : "zext"
	case:
		return value
	}
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = %s %s %s to %s", out, operation, llvm_type(e, from), value, llvm_type(e, to))
	return out
}

// ------------------------------------------------------------------ naming --

// Every user symbol carries its package's logical key, so two packages with the
// same declared name and the same source-level symbols still emit distinct
// working symbols (m3-plan decision "Symbol mangling"). The root package's key
// is empty, which is what keeps its entry procedure at a fixed name.
@(private = "file")
llvm_global_name :: proc(pkg: ^Package, name: string) -> string {
	return fmt.aprintf("@loke.g.%s%s", mangled_key(pkg), name)
}

@(private = "file")
llvm_proc_name :: proc(pkg: ^Package, name: string) -> string {
	return fmt.aprintf("@loke.p.%s%s", mangled_key(pkg), name)
}

// A type-qualified member name may mention punctuation LLVM would need quoting.
// Fixed-width hex keeps every byte sequence distinct and LLVM-safe.
@(private = "file")
llvm_plain_name :: proc(name: string) -> bool {
	for i in 0 ..< len(name) {
		if !llvm_name_byte(name[i]) {
			return false
		}
	}
	return len(name) > 0
}

@(private = "file")
llvm_name_byte :: proc(ch: u8) -> bool {
	return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') ||
		ch == '_' || ch == '.'
}

// A type-qualified member name, and an instantiation's `Table(int, i32)`,
// mention punctuation LLVM would need quoting for. Keeping the bytes LLVM
// already accepts and escaping the rest as `$XX` stays injective — `$` itself is
// escaped — while leaving the emitted symbol readable in a `tests/ll` golden.
llvm_safe :: proc(name: string) -> string {
	hex := "0123456789abcdef"
	out := make([dynamic]u8, 0, len(name) + 8)
	for i in 0 ..< len(name) {
		ch := name[i]
		if llvm_name_byte(ch) {
			append(&out, ch)
			continue
		}
		append(&out, '$', hex[ch >> 4], hex[ch & 0x0f])
	}
	return string(out[:])
}

// A substitution such as `/` -> `.` is not injective (`a-b`, `a.b`, and `a/b`
// would collide), so the escape above is used instead: it keeps distinct logical
// package identities distinct while leaving the readable part readable.
@(private = "file")
mangled_key :: proc(pkg: ^Package) -> string {
	if pkg == nil || pkg.key == "" {
		return ""
	}
	return fmt.aprintf("%s.", llvm_safe(pkg.key))
}

@(private = "file")
entry_symbol :: proc(c: ^Compiler) -> Symbol_Id {
	pkg := package_of(c, c.root_package)
	if pkg == nil || pkg.scope == nil {
		return INVALID_SYMBOL
	}
	return lookup_symbol(pkg.scope, intern_identifier(c, "main"))
}

@(private = "file")
replace_ext :: proc(path: string, ext: string) -> string {
	if i := strings.last_index_byte(path, '.'); i >= 0 {
		return strings.concatenate({path[:i], ext})
	}
	return strings.concatenate({path, ext})
}

// clang does llc + link + CRT startup in one process (decision A5, A7). It
// finds the Windows SDK itself, but computes a relative, unusable
// VCToolsInstallDir unless it is run from a developer prompt — so the CRT
// import libraries are located here.
//
// The seed runtime's C sources join the same invocation (m6a-plan decision
// "Runtime language and discovery"): one object-and-link seam already existed,
// and compiling the runtime here keeps it in step with the module beside it.
@(private = "file")
link :: proc(c: ^Compiler, ll_path: string, exe_path: string, opts: Options) -> int {
	clang := find_clang()

	runtime_dir := resolved_runtime_dir(opts)
	sources := runtime_sources(runtime_dir)
	if len(sources) == 0 {
		errorf(
			c,
			no_span(),
			"L0551",
			"no seed runtime sources in `%s`: %s",
			runtime_dir == "" ? "<unknown>" : runtime_dir,
			dir_exists(runtime_dir) \
				? "the directory holds no `.c` files" \
				: "the directory does not exist; pass `-runtime=<dir>`",
		)
		return 2
	}

	command := make([dynamic]string)
	append(&command, clang, ll_path, "-o", exe_path)
	for source in sources {
		append(&command, source)
	}
	append(&command, "-I", runtime_dir)
	// The module states its triple; clang's default carries an MSVC version
	// suffix, and the mismatch is not interesting.
	append(&command, "-Wno-override-module")
	// `f16` arithmetic lowers to the compiler-rt conversion helpers
	// (`__extendhfsf2`, `__truncsfhf2`) on x86-64 without F16C, and the MSVC CRT
	// does not provide them.
	append(&command, "-rtlib=compiler-rt")
	if lib := msvc_lib_dir(); lib != "" {
		append(&command, "-L", lib)
	}
	for include in msvc_include_dirs() {
		append(&command, "-isystem", include)
	}

	state, _, stderr, err := os2.process_exec(
		os2.Process_Desc{command = command[:]},
		context.allocator,
	)
	if err != nil {
		errorf(
			c,
			no_span(),
			"L0402",
			"cannot run `%s`: install LLVM (`winget install LLVM.LLVM`) or set LOKE_CLANG",
			clang,
		)
		return 2
	}
	if state.exit_code != 0 {
		errorf(
			c, no_span(), "L0403",
			"`%s` failed (seed runtime: `%s`):\n%s",
			clang, runtime_dir, string(stderr),
		)
		return 2
	}
	return 0
}

@(private = "file")
find_clang :: proc() -> string {
	if configured := os2.get_env("LOKE_CLANG", context.allocator); configured != "" {
		return configured
	}
	candidates := []string {
		`C:\Program Files\LLVM\bin\clang.exe`,
		`C:\Program Files (x86)\LLVM\bin\clang.exe`,
	}
	for candidate in candidates {
		if os.is_file(candidate) {
			return candidate
		}
	}
	return "clang"
}

// The MSVC toolset's `lib\x64`, or "" when there is nothing to add: a developer
// prompt has already put it in LIB, which lld-link honours.
@(private = "file")
msvc_lib_dir :: proc() -> string {
	if os2.get_env("LIB", context.allocator) != "" {
		return ""
	}
	if root := msvc_tools_dir(); root != "" {
		return filepath.join({root, "lib", "x64"})
	}
	return ""
}

// The C headers the seed runtime includes: the MSVC toolset's own, and the
// Windows SDK's UCRT. Empty in a developer prompt, whose INCLUDE clang honours.
//
// Only the runtime's `.c` inputs need these — a generated `.ll` includes
// nothing — so they arrived with M6a rather than with the original link seam.
@(private = "file")
msvc_include_dirs :: proc() -> []string {
	if os2.get_env("INCLUDE", context.allocator) != "" {
		return nil
	}
	dirs := make([dynamic]string)
	if root := msvc_tools_dir(); root != "" {
		append(&dirs, filepath.join({root, "include"}))
	}
	if ucrt := newest_match(
		`C:\Program Files (x86)\Windows Kits\10\Include\*\ucrt`,
		`C:\Program Files\Windows Kits\10\Include\*\ucrt`,
	); ucrt != "" {
		append(&dirs, ucrt)
	}
	return dirs[:]
}

// `...\VC\Tools\MSVC\<version>`, the root both the libraries and the headers
// hang off. A toolset must hold both to be a candidate: a build-tools
// installation can ship headers with no `lib\x64`, and mixing its headers with
// another version's libraries is worse than not finding it at all.
@(private = "file")
msvc_tools_dir :: proc() -> string {
	@(static) cached: string
	@(static) resolved: bool
	if resolved {
		return cached
	}
	resolved = true
	for candidate in newest_matches(
		`C:\Program Files\Microsoft Visual Studio\*\*\VC\Tools\MSVC\*`,
		`C:\Program Files (x86)\Microsoft Visual Studio\*\*\VC\Tools\MSVC\*`,
	) {
		if os.is_dir(filepath.join({candidate, "include"})) &&
		   os.is_dir(filepath.join({candidate, "lib", "x64"})) {
			cached = candidate
			return cached
		}
	}
	return cached
}

@(private = "file")
newest_match :: proc(patterns: ..string) -> string {
	all := newest_matches(..patterns)
	return len(all) == 0 ? "" : all[0]
}

// ponytail: a glob and a string compare instead of vswhere.exe. Orders by the
// last path element, which sorts real MSVC and SDK version numbers correctly
// today and keeps a newer toolset under `Program Files` from losing to an older
// one under `(x86)`. Switch to vswhere if that ever stops holding, or if a build
// needs a specific toolset.
@(private = "file")
newest_matches :: proc(patterns: ..string) -> []string {
	found := make([dynamic]string)
	for pattern in patterns {
		matches, err := filepath.glob(pattern)
		if err != nil {
			continue
		}
		append(&found, ..matches)
	}
	slice.sort_by(found[:], proc(a, b: string) -> bool {
		return filepath.base(a) > filepath.base(b)
	})
	return found[:]
}

// ============================================================== iteration ==

// `{ T, i1 }`. Built rather than formatted: `{` is a directive to core:fmt.
@(private = "file")
optional_pair_type :: proc(element: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{ ")
	strings.write_string(&b, element)
	strings.write_string(&b, ", i1 }")
	return strings.to_string(b)
}

// `a ..< b` and `a ..= b` as a stored value: the endpoints plus the closed flag,
// so a range keeps its kind after being assigned or passed to a generic
// procedure (m4b-plan decision "Runtime range representation").
@(private = "file")
emit_range_value :: proc(e: ^Emitter, v: ^Expr_Range) -> string {
	info := type_of(e.c, v.type)
	element := info.element
	low := emit_expr(e, v.lo)
	high := emit_expr(e, v.hi)
	closed := v.op == .Range_Incl ? "true" : "false"
	storage := llvm_type(e, v.type)
	step1 := temp(e)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, %s %s, %d", step1, storage, llvm_type(e, element), low, RANGE_LOW)
	step2 := temp(e)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, %s %s, %d", step2, storage, step1, llvm_type(e, element), high, RANGE_HIGH)
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, i1 %s, %d", out, storage, step2, closed, RANGE_CLOSED)
	return out
}

@(private = "file")
emit_foreach :: proc(e: ^Emitter, s: ^Stmt_Foreach) {
	if s.kind == .Static {
		// An expansion is not a loop: its checked copies run in iterable order,
		// and an empty iterable emits nothing.
		for copy_block in s.expansion {
			emit_block_statements(e, copy_block)
		}
		return
	}

	outer_break, outer_continue := e.break_label, e.continue_label
	outer_break_depth, outer_continue_depth := e.break_depth, e.continue_depth
	defer {
		e.break_label, e.continue_label = outer_break, outer_continue
		e.break_depth, e.continue_depth = outer_break_depth, outer_continue_depth
	}
	e.break_depth = len(e.cleanups)
	push_scope(e, nil)
	defer pop_scope(e)

	if s.kind == .Protocol {
		emit_protocol_foreach(e, s)
		return
	}
	if s.kind == .Text {
		emit_text_foreach(e, s)
		return
	}
	emit_indexed_foreach(e, s)
}

// design.md "String iteration": the loop yields decoded code points, and the
// second name is "the index at which the yielded code point begins, so it
// advances by 1 to 4 per step and the loop's final offset is not `len(x) - 1`".
// That is the unit that can be fed back into `bytes()` or a subrange.
@(private = "file")
emit_text_foreach :: proc(e: ^Emitter, s: ^Stmt_Foreach) {
	data, length := emit_text_parts(e, s.iterable)
	offset, decoded := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = alloca i64", offset)
	fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", offset)
	fmt.sbprintfln(&e.b, "  %s = alloca i32", decoded)

	head := new_label(e, "foreach.head")
	body := new_label(e, "foreach.body")
	post := new_label(e, "foreach.post")
	done := new_label(e, "foreach.done")
	e.break_label, e.continue_label = done, post
	e.continue_depth = len(e.cleanups)

	place_label(e, head)
	current := temp(e)
	fmt.sbprintfln(&e.b, "  %s = load i64, ptr %s", current, offset)
	at_end := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp sge i64 %s, %s", at_end, current, length)
	branch_if(e, at_end, done, body)

	place_label(e, body)
	used := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call i64 @loke_rt_v1_rune_at(ptr %s, i64 %s, i64 %s, ptr %s)",
		used, data, length, current, decoded,
	)
	// A `string` is valid UTF-8 by construction and every borrowed view of one is
	// checked where it is created, so a zero here would mean the invariant was
	// already broken.
	stalled := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i64 %s, 0", stalled, used)
	panic_if(e, stalled, "text.invalid", "invalid UTF-8 in a string")

	if binding := s.bindings[0].symbol; binding != INVALID_SYMBOL {
		slot, value := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = alloca i32", slot)
		fmt.sbprintfln(&e.b, "  %s = load i32, ptr %s", value, decoded)
		fmt.sbprintfln(&e.b, "  store i32 %s, ptr %s", value, slot)
		bind_local(e, binding, slot)
	}
	if len(s.bindings) == 2 && s.bindings[1].symbol != INVALID_SYMBOL {
		slot := temp(e)
		fmt.sbprintfln(&e.b, "  %s = alloca i64", slot)
		fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", current, slot)
		bind_local(e, s.bindings[1].symbol, slot)
	}
	emit_scoped_block(e, s.body)
	branch(e, post)

	place_label(e, post)
	advanced := temp(e)
	fmt.sbprintfln(&e.b, "  %s = add i64 %s, %s", advanced, current, used)
	fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", advanced, offset)
	branch(e, head)
	place_label(e, done)
}

// A range or a fixed array: an index loop, with no iterator object at all.
@(private = "file")
emit_indexed_foreach :: proc(e: ^Emitter, s: ^Stmt_Foreach) {
	element := llvm_type(e, s.element_type)
	cursor := temp(e)
	limit := ""
	closed := ""
	array_slot := ""
	counter_type := element

	switch s.kind {
	case .Range:
		written := s.iterable.(^Expr_Range)
		low := emit_expr(e, written.lo)
		high := emit_expr(e, written.hi)
		fmt.sbprintfln(&e.b, "  %s = alloca %s", cursor, element)
		fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", element, low, cursor)
		limit = high
		closed = written.op == .Range_Incl ? "true" : "false"

	case .Stored_Range:
		range_type := llvm_type(e, expr_base(s.iterable).type)
		value := emit_expr(e, s.iterable)
		low := temp(e)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", low, range_type, value, RANGE_LOW)
		high := temp(e)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", high, range_type, value, RANGE_HIGH)
		flag := temp(e)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", flag, range_type, value, RANGE_CLOSED)
		fmt.sbprintfln(&e.b, "  %s = alloca %s", cursor, element)
		fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", element, low, cursor)
		limit = high
		closed = flag

	case .Array:
		// `&value` names the element in place, so the array must be a place
		// rather than a copy.
		array_slot = spill_iterable(e, s.iterable)
		counter_type = "i64"
		fmt.sbprintfln(&e.b, "  %s = alloca i64", cursor)
		fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", cursor)
		limit = fmt.aprintf("%d", s.count)

	case .Slice:
		// The slice is evaluated once; the loop then walks its root through the
		// data word, so `&value` reaches the root rather than a copy.
		slice_type := llvm_type(e, expr_base(s.iterable).type)
		value := emit_expr(e, s.iterable)
		array_slot = temp(e)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", array_slot, slice_type, value, SLICE_DATA)
		length := temp(e)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", length, slice_type, value, SLICE_LEN)
		counter_type = "i64"
		fmt.sbprintfln(&e.b, "  %s = alloca i64", cursor)
		fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", cursor)
		limit = length

	case .Unresolved, .Static, .Protocol, .Text:
		backend_fail(e, "an unresolved `foreach` reached emission")
		return
	}

	head := new_label(e, "foreach.head")
	body := new_label(e, "foreach.body")
	post := new_label(e, "foreach.post")
	done := new_label(e, "foreach.done")
	e.break_label, e.continue_label = done, post
	e.continue_depth = len(e.cleanups)

	// The index binding is a counter the loop maintains, so it lives across
	// iterations rather than being rebuilt per step.
	index_slot := ""
	if len(s.bindings) == 2 && s.bindings[1].symbol != INVALID_SYMBOL {
		index_slot = temp(e)
		fmt.sbprintfln(&e.b, "  %s = alloca i64", index_slot)
		fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", index_slot)
		bind_local(e, s.bindings[1].symbol, index_slot)
	}

	place_label(e, head)
	current := temp(e)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", current, counter_type, cursor)
	test := temp(e)
	if s.kind == .Array || s.kind == .Slice {
		fmt.sbprintfln(&e.b, "  %s = icmp slt i64 %s, %s", test, current, limit)
	} else {
		// `..<` stops before the high endpoint and `..=` includes it; a stored
		// range carries which at run time.
		signed := type_signed(e.c, s.element_type) || type_is_rune(e.c, s.element_type)
		open_test, closed_test := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp %s %s %s, %s", open_test, signed ? "slt" : "ult", counter_type, current, limit)
		fmt.sbprintfln(&e.b, "  %s = icmp %s %s %s, %s", closed_test, signed ? "sle" : "ule", counter_type, current, limit)
		fmt.sbprintfln(&e.b, "  %s = select i1 %s, i1 %s, i1 %s", test, closed, closed_test, open_test)
	}
	branch_if(e, test, body, done)

	fmt.sbprintfln(&e.b, "%s:", body)
	e.terminated = false
	bind_indexed_value(e, s, current, array_slot, element)
	emit_scoped_block(e, s.body)
	branch(e, post)

	fmt.sbprintfln(&e.b, "%s:", post)
	e.terminated = false
	if s.kind != .Array && s.kind != .Slice {
		// An inclusive range whose high endpoint is the integer maximum cannot
		// represent high+1. Finish directly after yielding high instead.
		at_high, finished := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, %s", at_high, counter_type, current, limit)
		fmt.sbprintfln(&e.b, "  %s = and i1 %s, %s", finished, closed, at_high)
		step := new_label(e, "foreach.step")
		branch_if(e, finished, done, step)
		place_label(e, step)
	}
	step_counter(e, cursor, counter_type)
	if index_slot != "" {
		step_counter(e, index_slot, "i64")
	}
	branch(e, head)

	fmt.sbprintfln(&e.b, "%s:", done)
	e.terminated = false
}

@(private = "file")
step_counter :: proc(e: ^Emitter, slot, type: string) {
	current := temp(e)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", current, type, slot)
	next := temp(e)
	fmt.sbprintfln(&e.b, "  %s = add %s %s, 1", next, type, current)
	fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", type, next, slot)
}

@(private = "file")
bind_indexed_value :: proc(e: ^Emitter, s: ^Stmt_Foreach, current, array_slot, element: string) {
	value := s.bindings[0].symbol
	if value == INVALID_SYMBOL {
		return // the discard binding names nothing
	}
	if s.kind != .Array && s.kind != .Slice {
		slot := temp(e)
		fmt.sbprintfln(&e.b, "  %s = alloca %s", slot, element)
		fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", element, current, slot)
		bind_local(e, value, slot)
		return
	}
	address := temp(e)
	if s.kind == .Slice {
		// `array_slot` is the slice's data pointer, so the element index walks it
		// directly rather than indexing into an inline array.
		fmt.sbprintfln(
			&e.b,
			"  %s = getelementptr inbounds %s, ptr %s, i64 %s",
			address, element, array_slot, current,
		)
	} else {
		fmt.sbprintfln(
			&e.b,
			"  %s = getelementptr inbounds [%d x %s], ptr %s, i64 0, i64 %s",
			address, s.count, element, array_slot, current,
		)
	}
	if s.bindings[0].is_ref {
		// `&value` is the element itself, so the binding is its address and a
		// store through it reaches the array.
		bind_local(e, value, address)
		return
	}
	// By default each iterated value is a copy, and assignment to the copy does
	// not modify the source.
	slot := temp(e)
	fmt.sbprintfln(&e.b, "  %s = alloca %s", slot, element)
	loaded := temp(e)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", loaded, element, address)
	fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", element, loaded, slot)
	bind_local(e, value, slot)
}

// A user iterable: `it := iter(x)`, then `next(&it)` per step, with the loop
// maintaining the two-name index counter itself.
@(private = "file")
emit_protocol_foreach :: proc(e: ^Emitter, s: ^Stmt_Foreach) {
	iter_sym := symbol_of(e.c, s.iter_symbol)
	subject := emit_expr(e, s.iterable)
	iterator_type := llvm_type(e, s.iterator_type)
	iterator := temp(e)
	fmt.sbprintfln(&e.b, "  %s = alloca %s", iterator, iterator_type)
	made := temp(e)
	fmt.sbprintfln(
		&e.b,
		"  %s = call %s %s(%s %s)",
		made, iterator_type, e.names[s.iter_symbol], llvm_type(e, iter_sym.params[0]), subject,
	)
	fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", iterator_type, made, iterator)

	counter := temp(e)
	fmt.sbprintfln(&e.b, "  %s = alloca i64", counter)
	fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", counter)
	if len(s.bindings) == 2 && s.bindings[1].symbol != INVALID_SYMBOL {
		bind_local(e, s.bindings[1].symbol, counter)
	}

	head := new_label(e, "foreach.head")
	body := new_label(e, "foreach.body")
	post := new_label(e, "foreach.post")
	done := new_label(e, "foreach.done")
	e.break_label, e.continue_label = done, post
	e.continue_depth = len(e.cleanups)

	place_label(e, head)
	element := llvm_type(e, s.element_type)
	pair_type := optional_pair_type(element)
	pair := temp(e)
	fmt.sbprintfln(&e.b, "  %s = call %s %s(ptr %s)", pair, pair_type, e.names[s.next_symbol], iterator)
	value := temp(e)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, 0", value, pair_type, pair)
	ok := temp(e)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, 1", ok, pair_type, pair)
	branch_if(e, ok, body, done)

	fmt.sbprintfln(&e.b, "%s:", body)
	e.terminated = false
	if binding := s.bindings[0].symbol; binding != INVALID_SYMBOL {
		slot := temp(e)
		fmt.sbprintfln(&e.b, "  %s = alloca %s", slot, element)
		fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", element, value, slot)
		bind_local(e, binding, slot)
	}
	emit_scoped_block(e, s.body)
	branch(e, post)

	fmt.sbprintfln(&e.b, "%s:", post)
	e.terminated = false
	step_counter(e, counter, "i64")
	branch(e, head)

	fmt.sbprintfln(&e.b, "%s:", done)
	e.terminated = false
}

// An array the loop indexes: its own storage when it has any, and a spill
// otherwise.
@(private = "file")
spill_iterable :: proc(e: ^Emitter, expr: Expr) -> string {
	base := expr_base(expr)
	if base.addressable {
		return emit_address(e, expr)
	}
	value := emit_expr(e, expr)
	slot := temp(e)
	fmt.sbprintfln(&e.b, "  %s = alloca %s", slot, llvm_type(e, base.type))
	fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", llvm_type(e, base.type), value, slot)
	return slot
}

// ------------------------------------------- compiler-contributed procedures --

// design.md: built-ins satisfy the same static interface a user type does, so
// their `iter` and `next` are real procedures rather than a checker fiction.
// Emitted once for the whole compilation, after every package's items.
@(private = "file")
emit_synth_procs :: proc(e: ^Emitter) {
	for symbol_id in e.c.synth_procs {
		symbol := symbol_of(e.c, symbol_id)
		if symbol == nil || symbol.synth == .None {
			continue
		}
		e.terminated = false
		name := e.names[symbol_id]
		switch symbol.synth {
		case .Range_Iter, .Array_Iter:
			emit_synth_iter(e, symbol, name)
		case .Range_Next:
			emit_synth_range_next(e, symbol, name)
		case .Array_Next:
			emit_synth_array_next(e, symbol, name)
		case .Slice_Next:
			emit_synth_slice_next(e, symbol, name)
		case .Try_Clone:
			emit_synth_try_clone(e, symbol, name)
		case .Clone:
			emit_synth_clone(e, symbol, name)
		case .Dyn_Forward:
			emit_dyn_forwarding_slot(e, symbol, name)
		case .Container_Op:
			emit_synth_container_op(e, symbol, name)
		case .None:
		}
		fmt.sbprintln(&e.b, "")
	}
}

@(private = "file")
emit_synth_iter :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	source := llvm_type(e, symbol.params[0])
	iterator := llvm_type(e, symbol.results[0])
	fmt.sbprintf(&e.b, "define %s %s(%s %%arg0)", iterator, name, source)
	fmt.sbprintln(&e.b, " {")
	fmt.sbprintln(&e.b, "entry:")
	if symbol.synth == .Array_Iter {
		// `{ data, 0 }`: iteration is by value, so the iterator owns a copy.
		first := temp(e)
		fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, %s %%arg0, %d", first, iterator, source, ITER_ARRAY_DATA)
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, i64 0, %d", out, iterator, first, ITER_ARRAY_INDEX)
		fmt.sbprintfln(&e.b, "  ret %s %s", iterator, out)
		fmt.sbprintln(&e.b, "}")
		return
	}
	element := llvm_type(e, type_of(e.c, symbol.params[0]).element)
	low, high, closed := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %%arg0, %d", low, source, RANGE_LOW)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %%arg0, %d", high, source, RANGE_HIGH)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %%arg0, %d", closed, source, RANGE_CLOSED)
	step1, step2, out := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, %s %s, %d", step1, iterator, element, low, ITER_RANGE_CURRENT)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, %s %s, %d", step2, iterator, step1, element, high, ITER_RANGE_HIGH)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, i1 %s, %d", out, iterator, step2, closed, ITER_RANGE_CLOSED)
	fmt.sbprintfln(&e.b, "  ret %s %s", iterator, out)
	fmt.sbprintln(&e.b, "}")
}

@(private = "file")
emit_synth_range_next :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	element := llvm_type(e, symbol.results[0])
	iterator := llvm_type(e, symbol.params[0])
	signed := type_signed(e.c, symbol.results[0]) || type_is_rune(e.c, symbol.results[0])

	pair_type := optional_pair_type(element)
	fmt.sbprintf(&e.b, "define %s %s(ptr %%arg0)", pair_type, name)
	fmt.sbprintln(&e.b, " {")
	fmt.sbprintln(&e.b, "entry:")
	current_ptr, current := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = getelementptr inbounds %s, ptr %%arg0, i32 0, i32 %d", current_ptr, iterator, ITER_RANGE_CURRENT)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", current, element, current_ptr)
	high_ptr, high := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = getelementptr inbounds %s, ptr %%arg0, i32 0, i32 %d", high_ptr, iterator, ITER_RANGE_HIGH)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", high, element, high_ptr)
	closed_ptr, closed := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = getelementptr inbounds %s, ptr %%arg0, i32 0, i32 %d", closed_ptr, iterator, ITER_RANGE_CLOSED)
	fmt.sbprintfln(&e.b, "  %s = load i1, ptr %s", closed, closed_ptr)

	open_test, closed_test, live := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp %s %s %s, %s", open_test, signed ? "slt" : "ult", element, current, high)
	fmt.sbprintfln(&e.b, "  %s = icmp %s %s %s, %s", closed_test, signed ? "sle" : "ule", element, current, high)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, i1 %s, i1 %s", live, closed, closed_test, open_test)
	yield_label, stop_label := new_label(e, "next.yield"), new_label(e, "next.stop")
	fmt.sbprintfln(&e.b, "  br i1 %s, label %%%s, label %%%s", live, yield_label, stop_label)

	fmt.sbprintfln(&e.b, "%s:", yield_label)
	stepped, at_high, last := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = add %s %s, 1", stepped, element, current)
	fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, %s", at_high, element, current, high)
	fmt.sbprintfln(&e.b, "  %s = and i1 %s, %s", last, closed, at_high)
	next_current, next_closed := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, %s %s, %s %s", next_current, last, element, current, element, stepped)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, i1 false, i1 %s", next_closed, last, closed)
	fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", element, next_current, current_ptr)
	fmt.sbprintfln(&e.b, "  store i1 %s, ptr %s", next_closed, closed_ptr)
	first, out := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, %s %s, 0", first, pair_type, element, current)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, i1 true, 1", out, pair_type, first)
	fmt.sbprintfln(&e.b, "  ret %s %s", pair_type, out)

	// design.md optional-ok: a false `bool` ends the loop with the first result
	// unobserved, so the payload is the zero value.
	fmt.sbprintfln(&e.b, "%s:", stop_label)
	fmt.sbprintfln(&e.b, "  ret %s zeroinitializer", pair_type)
	fmt.sbprintln(&e.b, "}")
}

@(private = "file")
emit_synth_array_next :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	element := llvm_type(e, symbol.results[0])
	iterator := llvm_type(e, symbol.params[0])
	iterator_info := type_of(e.c, symbol.params[0])
	array_type := symbol_of(e.c, iterator_info.fields[ITER_ARRAY_DATA]).type
	data_type := llvm_type(e, array_type)
	count := type_of(e.c, array_type).count

	pair_type := optional_pair_type(element)
	fmt.sbprintf(&e.b, "define %s %s(ptr %%arg0)", pair_type, name)
	fmt.sbprintln(&e.b, " {")
	fmt.sbprintln(&e.b, "entry:")
	index_ptr, index := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = getelementptr inbounds %s, ptr %%arg0, i32 0, i32 %d", index_ptr, iterator, ITER_ARRAY_INDEX)
	fmt.sbprintfln(&e.b, "  %s = load i64, ptr %s", index, index_ptr)
	live := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp slt i64 %s, %d", live, index, count)
	yield_label, stop_label := new_label(e, "next.yield"), new_label(e, "next.stop")
	fmt.sbprintfln(&e.b, "  br i1 %s, label %%%s, label %%%s", live, yield_label, stop_label)

	fmt.sbprintfln(&e.b, "%s:", yield_label)
	data_ptr, slot, value := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = getelementptr inbounds %s, ptr %%arg0, i32 0, i32 %d", data_ptr, iterator, ITER_ARRAY_DATA)
	fmt.sbprintfln(&e.b, "  %s = getelementptr inbounds %s, ptr %s, i64 0, i64 %s", slot, data_type, data_ptr, index)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", value, element, slot)
	stepped := temp(e)
	fmt.sbprintfln(&e.b, "  %s = add i64 %s, 1", stepped, index)
	fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", stepped, index_ptr)
	first, out := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, %s %s, 0", first, pair_type, element, value)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, i1 true, 1", out, pair_type, first)
	fmt.sbprintfln(&e.b, "  ret %s %s", pair_type, out)

	fmt.sbprintfln(&e.b, "%s:", stop_label)
	fmt.sbprintfln(&e.b, "  ret %s zeroinitializer", pair_type)
	fmt.sbprintln(&e.b, "}")
}

// The slice half of `next`. Same `{ data, index }` iterator as an array's; the
// bound is the slice's own length word and the element address goes through its
// data pointer rather than into an inline array.
@(private = "file")
emit_synth_slice_next :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	element := llvm_type(e, symbol.results[0])
	iterator := llvm_type(e, symbol.params[0])
	iterator_info := type_of(e.c, symbol.params[0])
	slice_type := symbol_of(e.c, iterator_info.fields[ITER_ARRAY_DATA]).type
	slice_llvm := llvm_type(e, slice_type)

	pair_type := optional_pair_type(element)
	fmt.sbprintf(&e.b, "define %s %s(ptr %%arg0)", pair_type, name)
	fmt.sbprintln(&e.b, " {")
	fmt.sbprintln(&e.b, "entry:")
	index_ptr, index := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = getelementptr inbounds %s, ptr %%arg0, i32 0, i32 %d", index_ptr, iterator, ITER_ARRAY_INDEX)
	fmt.sbprintfln(&e.b, "  %s = load i64, ptr %s", index, index_ptr)
	slice_ptr, slice_value, length := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = getelementptr inbounds %s, ptr %%arg0, i32 0, i32 %d", slice_ptr, iterator, ITER_ARRAY_DATA)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", slice_value, slice_llvm, slice_ptr)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", length, slice_llvm, slice_value, SLICE_LEN)
	live := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp slt i64 %s, %s", live, index, length)
	yield_label, stop_label := new_label(e, "next.yield"), new_label(e, "next.stop")
	fmt.sbprintfln(&e.b, "  br i1 %s, label %%%s, label %%%s", live, yield_label, stop_label)

	fmt.sbprintfln(&e.b, "%s:", yield_label)
	data, slot, value := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", data, slice_llvm, slice_value, SLICE_DATA)
	fmt.sbprintfln(&e.b, "  %s = getelementptr inbounds %s, ptr %s, i64 %s", slot, element, data, index)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", value, element, slot)
	stepped := temp(e)
	fmt.sbprintfln(&e.b, "  %s = add i64 %s, 1", stepped, index)
	fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", stepped, index_ptr)
	first, out := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, %s %s, 0", first, pair_type, element, value)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, i1 true, 1", out, pair_type, first)
	fmt.sbprintfln(&e.b, "  ret %s %s", pair_type, out)

	fmt.sbprintfln(&e.b, "%s:", stop_label)
	fmt.sbprintfln(&e.b, "  ret %s zeroinitializer", pair_type)
	fmt.sbprintln(&e.b, "}")
}

// ------------------------------------------------------ container bodies --

// One contributed container operation. Every one of them is a call into the
// versioned C helper with this type's operation table; what differs is how the
// arguments arrive and what comes back.
//
// A fallible operation has two forms. The `try_` one returns the error and the
// caller decides; the ordinary one has nowhere to report it, so it applies the
// *allocator's* failure policy, which is what design.md's "Allocation failure"
// requires of an implicit allocation.
@(private = "file")
emit_synth_container_op :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	container := symbol.params[0]
	element := container_element(e.c, container)
	element_llvm := llvm_type(e, element)
	ops := container_ops_global(e, container)
	fallible := len(symbol.results) == 1 && symbol.results[0] == TYPE_ALLOCATOR_ERROR

	result := llvm_result_type(e, symbol.results, nil)
	fmt.sbprintf(&e.b, "define %s %s(", result, name)
	for parameter, index in symbol.params {
		if index > 0 {
			fmt.sbprint(&e.b, ", ")
		}
		type := index == 0 ? "ptr" : llvm_type(e, parameter)
		fmt.sbprintf(&e.b, "%s %%arg%d", type, index)
	}
	fmt.sbprintln(&e.b, ") {")
	fmt.sbprintln(&e.b, "entry:")
	e.terminated = false

	// A single value entering the container is spilled so the helper can read it
	// through a pointer, exactly as it reads a `..T` pack's storage.
	value_storage :: proc(e: ^Emitter, element: Type_Id, argument: string) -> string {
		slot := temp(e)
		fmt.sbprintfln(&e.b, "  %s = alloca %s", slot, llvm_type(e, element))
		fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", llvm_type(e, element), argument, slot)
		return slot
	}

	status := ""
	switch symbol.container_op {
	case .Append, .Try_Append:
		data, count := temp(e), temp(e)
		pack := llvm_type(e, symbol.params[1])
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %%arg1, %d", data, pack, SLICE_DATA)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %%arg1, %d", count, pack, SLICE_LEN)
		status = temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i32 @loke_rt_v1_dyn_append(ptr %%arg0, ptr %s, ptr %s, i64 %s)",
			status, ops, data, count,
		)

	case .Insert, .Try_Insert:
		slot := value_storage(e, element, "%arg2")
		status = temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i32 @loke_rt_v1_dyn_insert(ptr %%arg0, ptr %s, i64 %%arg1, ptr %s, i64 1)",
			status, ops, slot,
		)
		// The argument was a borrowed copy of the caller's value and the helper
		// cloned from it, so this frame still owns it.
		emit_drop_place(e, element, slot)

	case .Pop:
		out, found := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = alloca %s", out, element_llvm)
		fmt.sbprintfln(&e.b, "  %s = call i32 @loke_rt_v1_dyn_pop(ptr %%arg0, ptr %s, ptr %s)", found, ops, out)
		value, ok, first, pair := temp(e), temp(e), temp(e), optional_pair_type(element_llvm)
		fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", value, element_llvm, out)
		fmt.sbprintfln(&e.b, "  %s = icmp ne i32 %s, 0", ok, found)
		fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, %s %s, 0", first, pair, element_llvm, value)
		built := temp(e)
		fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, i1 %s, 1", built, pair, first, ok)
		fmt.sbprintfln(&e.b, "  ret %s %s", pair, built)
		fmt.sbprintln(&e.b, "}")
		return

	case .Remove, .Remove_Unordered:
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = alloca %s", out, element_llvm)
		fmt.sbprintfln(
			&e.b, "  call void @loke_rt_v1_dyn_remove(ptr %%arg0, ptr %s, i64 %%arg1, ptr %s, i32 %d)",
			ops, out, symbol.container_op == .Remove_Unordered ? 1 : 0,
		)
		value := temp(e)
		fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", value, element_llvm, out)
		fmt.sbprintfln(&e.b, "  ret %s %s", element_llvm, value)
		fmt.sbprintln(&e.b, "}")
		return

	case .Clear:
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_dyn_clear(ptr %%arg0, ptr %s)", ops)
		fmt.sbprintln(&e.b, "  ret void")
		fmt.sbprintln(&e.b, "}")
		return

	case .Resize, .Try_Resize:
		status = temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i32 @loke_rt_v1_dyn_resize(ptr %%arg0, ptr %s, i64 %%arg1)", status, ops,
		)

	case .Reserve, .Try_Reserve:
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_dyn_bind(ptr %%arg0)")
		status = temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i32 @loke_rt_v1_dyn_reserve(ptr %%arg0, ptr %s, i64 %%arg1)", status, ops,
		)

	case .Shrink, .Try_Shrink:
		status = temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i32 @loke_rt_v1_dyn_shrink(ptr %%arg0, ptr %s, i64 %%arg1)", status, ops,
		)

	case .Map_Find:
		// design.md: "It returns a pointer to the existing value and `true`, or
		// `nil` and `false`. It does not insert."
		slot := value_storage(e, container_key(e.c, container), "%arg1")
		found, ok := temp(e), temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call ptr @loke_rt_v1_map_find(ptr %%arg0, ptr %s, ptr %s)", found, ops, slot,
		)
		emit_drop_place(e, container_key(e.c, container), slot)
		fmt.sbprintfln(&e.b, "  %s = icmp ne ptr %s, null", ok, found)
		pair, first, built := optional_pair_type("ptr"), temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, ptr %s, 0", first, pair, found)
		fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, i1 %s, 1", built, pair, first, ok)
		fmt.sbprintfln(&e.b, "  ret %s %s", pair, built)
		fmt.sbprintln(&e.b, "}")
		return

	case .Map_Try_Insert:
		key_type := container_key(e.c, container)
		key_slot := value_storage(e, key_type, "%arg1")
		place := emit_map_entry(e, ops, "%arg0", key_slot)
		emit_drop_place(e, key_type, key_slot)
		missing, ok_label, done_label := temp(e), new_label(e, "mins.ok"), new_label(e, "mins.done")
		fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", missing, place)
		branch_if(e, missing, done_label, ok_label)
		place_label(e, ok_label)
		// The slot's previous value -- the freshly written zero, or the entry that
		// was already there -- is destroyed before the new one is published.
		emit_drop_place(e, element, place)
		// The argument is a borrowed copy the caller still owns, so a managed value
		// is duplicated into the slot rather than aliased.
		stored := "%arg2"
		if type_is_managed(e.c, element) {
			stored = emit_clone_value(e, element, stored)
		}
		store(e, element, stored, place)
		branch(e, done_label)
		place_label(e, done_label)
		e.terminated = false
		failed_insert, error := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", failed_insert, place)
		fmt.sbprintfln(
			&e.b, "  %s = zext i1 %s to %s", error, failed_insert, llvm_type(e, TYPE_ALLOCATOR_ERROR),
		)
		fmt.sbprintfln(&e.b, "  ret %s %s", result, error)
		fmt.sbprintln(&e.b, "}")
		return

	case .Map_Remove:
		key_type := container_key(e.c, container)
		key_slot := value_storage(e, key_type, "%arg1")
		out, found := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = alloca %s", out, element_llvm)
		fmt.sbprintfln(
			&e.b, "  %s = call i32 @loke_rt_v1_map_remove(ptr %%arg0, ptr %s, ptr %s, ptr %s)",
			found, ops, key_slot, out,
		)
		emit_drop_place(e, key_type, key_slot)
		value, ok := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", value, element_llvm, out)
		fmt.sbprintfln(&e.b, "  %s = icmp ne i32 %s, 0", ok, found)
		pair, first, built := optional_pair_type(element_llvm), temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, %s %s, 0", first, pair, element_llvm, value)
		fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, i1 %s, 1", built, pair, first, ok)
		fmt.sbprintfln(&e.b, "  ret %s %s", pair, built)
		fmt.sbprintln(&e.b, "}")
		return

	case .Map_Clear:
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_map_clear(ptr %%arg0, ptr %s)", ops)
		fmt.sbprintln(&e.b, "  ret void")
		fmt.sbprintln(&e.b, "}")
		return

	case .Map_Reserve, .Map_Try_Reserve:
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_map_bind(ptr %%arg0)")
		status = temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i32 @loke_rt_v1_map_reserve(ptr %%arg0, ptr %s, i64 %%arg1)", status, ops,
		)

	case .Map_Shrink, .Map_Try_Shrink:
		status = temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i32 @loke_rt_v1_map_shrink(ptr %%arg0, ptr %s, i64 %%arg1)", status, ops,
		)

	case .None:
		backend_fail(e, "a contributed container member has no operation")
		fmt.sbprintln(&e.b, "  ret void")
		fmt.sbprintln(&e.b, "}")
		return
	}

	failed := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i32 %s, 0", failed, status)
	if fallible {
		error := temp(e)
		fmt.sbprintfln(&e.b, "  %s = zext i1 %s to %s", error, failed, llvm_type(e, TYPE_ALLOCATOR_ERROR))
		fmt.sbprintfln(&e.b, "  ret %s %s", result, error)
		fmt.sbprintln(&e.b, "}")
		return
	}
	// The ordinary form has no result to report through, so the provider's own
	// policy decides: `.Panic` follows the program strategy, `.Trap` terminates.
	provider, fail_label, done_label := temp(e), new_label(e, "cop.fail"), new_label(e, "cop.done")
	branch_if(e, failed, fail_label, done_label)
	place_label(e, fail_label)
	slot := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = getelementptr inbounds %s, ptr %%arg0, i32 0, i32 %d",
		slot, CONTAINER_TYPE, CONTAINER_ALLOC,
	)
	fmt.sbprintfln(&e.b, "  %s = load ptr, ptr %s", provider, slot)
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_alloc_failed(ptr %s)", provider)
	branch(e, done_label)
	place_label(e, done_label)
	e.terminated = false
	fmt.sbprintln(&e.b, "  ret void")
	fmt.sbprintln(&e.b, "}")
}

// `key in m`: one probe, no insertion and no value.
@(private = "file")
emit_map_membership :: proc(e: ^Emitter, v: ^Expr_Binary) -> string {
	container := expr_base(v.rhs).type
	key := container_key(e.c, container)
	ops := container_ops_global(e, container)
	header := emit_address(e, v.rhs)
	value := emit_expr(e, v.lhs)
	key_slot := temp(e)
	fmt.sbprintfln(&e.b, "  %s = alloca %s", key_slot, llvm_type(e, key))
	store(e, key, value, key_slot)
	found, out := temp(e), temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call ptr @loke_rt_v1_map_find(ptr %s, ptr %s, ptr %s)", found, header, ops, key_slot,
	)
	emit_drop_place(e, key, key_slot)
	fmt.sbprintfln(&e.b, "  %s = icmp ne ptr %s, null", out, found)
	return out
}

// `m[key]` in a place position. design.md: "If the key is absent, the zero value
// of the element type is inserted first and the resulting slot is the location."
// The insertion allocates, and a place has nowhere to report a failure, so the
// provider's own policy decides.
@(private = "file")
emit_map_place :: proc(e: ^Emitter, v: ^Expr_Index) -> string {
	container := expr_base(v.operand).type
	ops := container_ops_global(e, container)
	header := emit_address(e, v.operand)
	key_slot := emit_map_key_slot(e, v, container)
	place := emit_map_entry(e, ops, header, key_slot)
	emit_drop_place(e, container_key(e.c, container), key_slot)
	failed := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", failed, place)
	fail_label, done_label := new_label(e, "mplace.fail"), new_label(e, "mplace.done")
	branch_if(e, failed, fail_label, done_label)
	place_label(e, fail_label)
	provider, slot := temp(e), temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = getelementptr inbounds %s, ptr %s, i32 0, i32 %d",
		slot, CONTAINER_TYPE, header, CONTAINER_ALLOC,
	)
	fmt.sbprintfln(&e.b, "  %s = load ptr, ptr %s", provider, slot)
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_alloc_failed(ptr %s)", provider)
	branch(e, done_label)
	place_label(e, done_label)
	e.terminated = false
	return place
}

// The address a non-inserting read of `m[key]` produces: the existing slot, or a
// zeroed temporary of this frame. design.md: "A lookup of a missing key returns
// the zero value", and reading one must not create an entry.
@(private = "file")
emit_map_read_address :: proc(e: ^Emitter, v: ^Expr_Index) -> (string, string) {
	container := expr_base(v.operand).type
	element := container_element(e.c, container)
	element_llvm := llvm_type(e, element)
	ops := container_ops_global(e, container)
	header := emit_address(e, v.operand)
	key_slot := emit_map_key_slot(e, v, container)

	found := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call ptr @loke_rt_v1_map_find(ptr %s, ptr %s, ptr %s)", found, header, ops, key_slot,
	)
	emit_drop_place(e, container_key(e.c, container), key_slot)
	zero_slot := temp(e)
	fmt.sbprintfln(&e.b, "  %s = alloca %s", zero_slot, element_llvm)
	if zero, ok := zero_const(e.c, element); ok {
		fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", element_llvm, llvm_const(e, zero, element), zero_slot)
	}
	present, source := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp ne ptr %s, null", present, found)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, ptr %s, ptr %s", source, present, found, zero_slot)
	return source, present
}

// `m[key]` as a read, in both its single-value and comma-ok shapes.
@(private = "file")
emit_map_lookup :: proc(e: ^Emitter, v: ^Expr_Index) -> []string {
	element_llvm := llvm_type(e, container_element(e.c, expr_base(v.operand).type))
	source, present := emit_map_read_address(e, v)
	value := temp(e)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", value, element_llvm, source)
	out := make([]string, 2)
	out[0], out[1] = value, present
	return out
}

// The key, spilled so the C helper can read it through a pointer. The value is
// this frame's, so a managed key is dropped by the caller once the probe is
// done.
@(private = "file")
emit_map_key_slot :: proc(e: ^Emitter, v: ^Expr_Index, container: Type_Id) -> string {
	key := container_key(e.c, container)
	value := emit_expr(e, v.indices[0])
	slot := temp(e)
	fmt.sbprintfln(&e.b, "  %s = alloca %s", slot, llvm_type(e, key))
	store(e, key, value, slot)
	return slot
}

// design.md "Maps": an inserting place. The slot is found or created with the
// zero value, and the answer is NULL only when the insertion could not allocate.
@(private = "file")
emit_map_entry :: proc(e: ^Emitter, ops, header, key_slot: string) -> string {
	inserted, place := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = alloca i32", inserted)
	fmt.sbprintfln(
		&e.b, "  %s = call ptr @loke_rt_v1_map_entry(ptr %s, ptr %s, ptr %s, ptr %s)",
		place, header, ops, key_slot, inserted,
	)
	return place
}

// ------------------------------------------------------- lifecycle bodies --

// `{ T, i64 }`, the `(T, Allocator_Error)` result pair. Built rather than
// formatted, because `{` is a directive to core:fmt.
@(private = "file")
clone_pair_type :: proc(value: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{ ")
	strings.write_string(&b, value)
	strings.write_string(&b, ", i64 }")
	return strings.to_string(b)
}

// design.md: "Compiler-generated field-wise cloning calls `try_clone`
// recursively for every owning field, destroys a partially completed temporary
// on failure, and returns zero plus the error."
//
// A type no part of which reaches a custom hook cannot fail, so its generated
// body is the copy the representation already is. The branchy shape below exists
// only where a real hook can return an error.
@(private = "file")
emit_synth_try_clone :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	subject := symbol.params[0]
	value_type := llvm_type(e, subject)
	pair := clone_pair_type(value_type)
	fmt.sbprintf(&e.b, "define %s %s(%s %%arg0, ptr %%arg1)", pair, name, value_type)
	fmt.sbprintln(&e.b, " {")
	fmt.sbprintln(&e.b, "entry:")
	e.terminated = false

	if !type_clone_is_fallible(e.c, subject) {
		first, out := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, %s %%arg0, 0", first, pair, value_type)
		fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, i64 0, 1", out, pair, first)
		fmt.sbprintfln(&e.b, "  ret %s %s", pair, out)
		fmt.sbprintln(&e.b, "}")
		return
	}

	// Both sides are addressed rather than kept in registers: a failure path has
	// to drop what the destination already holds, and a drop hook takes a place.
	self, out := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = alloca %s", self, value_type)
	fmt.sbprintfln(&e.b, "  store %s %%arg0, ptr %s", value_type, self)
	fmt.sbprintfln(&e.b, "  %s = alloca %s", out, value_type)
	// design.md: "every hook must handle the inert zero value", and a cleanup that
	// runs before a part is written must see that zero rather than garbage.
	fmt.sbprintfln(&e.b, "  store %s zeroinitializer, ptr %s", value_type, out)

	for index in 0 ..< clone_part_count(e.c, subject) {
		part := clone_part(e.c, subject, index)
		source := element_address(e, subject, self, index)
		destination := element_address(e, subject, out, index)
		if !type_clone_is_fallible(e.c, part) {
			loaded := temp(e)
			fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", loaded, llvm_type(e, part), source)
			store(e, part, loaded, destination)
			continue
		}
		cloned, error := emit_part_clone(e, part, source)
		failed := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp ne i64 %s, 0", failed, error)
		unwind, ok := new_label(e, "clone.unwind"), new_label(e, "clone.ok")
		branch_if(e, failed, unwind, ok)

		// The partially built temporary, cleaned in reverse part order. Everything
		// past `index` is still the inert zero this block never wrote.
		place_label(e, unwind)
		for done := index - 1; done >= 0; done -= 1 {
			emit_drop_place(e, clone_part(e.c, subject, done), element_address(e, subject, out, done))
		}
		zeroed := temp(e)
		fmt.sbprintfln(&e.b, "  %s = insertvalue %s zeroinitializer, i64 %s, 1", zeroed, pair, error)
		fmt.sbprintfln(&e.b, "  ret %s %s", pair, zeroed)
		e.terminated = true
		// Only a successful part is published, so a hook that breaks its contract
		// and hands back a live value beside an error cannot leave one in the
		// temporary that cleanup would never reach.
		place_label(e, ok)
		store(e, part, cloned, destination)
	}

	built, first, result := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", built, value_type, out)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, %s %s, 0", first, pair, value_type, built)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, i64 0, 1", result, pair, first)
	fmt.sbprintfln(&e.b, "  ret %s %s", pair, result)
	fmt.sbprintln(&e.b, "}")
}

// The address of part `index`, which is a struct field or an array element.
@(private = "file")
element_address :: proc(e: ^Emitter, owner: Type_Id, base: string, index: int) -> string {
	info := type_of(e.c, type_underlying(e.c, owner))
	out := temp(e)
	if info != nil && info.kind == .Array {
		fmt.sbprintfln(
			&e.b, "  %s = getelementptr inbounds %s, ptr %s, i64 0, i64 %d",
			out, llvm_type(e, owner), base, index,
		)
		return out
	}
	fmt.sbprintfln(
		&e.b, "  %s = getelementptr inbounds %s, ptr %s, i32 0, i32 %d",
		out, llvm_type(e, owner), base, index,
	)
	return out
}

// Clones one part through its own `try_clone` — custom or generated, both real
// members. Returns the cloned value and the error word; the caller publishes the
// value only on the success path.
@(private = "file")
emit_part_clone :: proc(e: ^Emitter, part: Type_Id, source: string) -> (string, string) {
	// A container part has no `try_clone` member: its fallible clone is the
	// versioned C helper, driven by this type's generated operation table.
	if lifecycle_of(e.c, part).container {
		destination := temp(e)
		fmt.sbprintfln(&e.b, "  %s = alloca %s", destination, CONTAINER_TYPE)
		ok := emit_try_clone_into(e, part, destination, source, "%arg1")
		cloned, error := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", cloned, CONTAINER_TYPE, destination)
		fmt.sbprintfln(&e.b, "  %s = select i1 %s, i64 0, i64 1", error, ok)
		return cloned, error
	}
	hook := type_hook(e.c, part, "try_clone")
	if hook == INVALID_SYMBOL {
		// `type_clone_is_fallible` said this part reaches a custom hook, so the
		// contribution pass owed it one.
		backend_fail(e, "a fallible clone part has no `try_clone` member")
		return "0", "1"
	}
	part_type := llvm_type(e, part)
	pair := clone_pair_type(part_type)
	loaded, returned := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", loaded, part_type, source)
	fmt.sbprintfln(
		&e.b, "  %s = call %s %s(%s %s, ptr %%arg1)",
		returned, pair, e.names[hook], part_type, loaded,
	)
	cloned, error := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, 0", cloned, pair, returned)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, 1", error, pair, returned)
	return cloned, error
}

// Drops every initialized element of a compiler-owned variadic buffer in
// reverse order. A flag is cleared before its hook runs, so a panic raised by
// that hook cannot replay the same element; remaining flags stay visible to the
// frame's unwind action.
@(private = "file")
emit_drop_flagged_array :: proc(e: ^Emitter, element: Type_Id, buffer, flags, count_address: string) {
	count, cursor := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = load i64, ptr %s", count, count_address)
	fmt.sbprintfln(&e.b, "  %s = alloca i64", cursor)
	fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", count, cursor)
	head, inspect, done := new_label(e, "vararg.drop.head"), new_label(e, "vararg.drop.inspect"), new_label(e, "vararg.drop.done")
	branch(e, head)
	place_label(e, head)
	remaining := temp(e)
	fmt.sbprintfln(&e.b, "  %s = load i64, ptr %s", remaining, cursor)
	has_more := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp ugt i64 %s, 0", has_more, remaining)
	branch_if(e, has_more, inspect, done)
	place_label(e, inspect)
	index := temp(e)
	fmt.sbprintfln(&e.b, "  %s = sub i64 %s, 1", index, remaining)
	fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", index, cursor)
	flag_address, live := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = getelementptr i1, ptr %s, i64 %s", flag_address, flags, index)
	fmt.sbprintfln(&e.b, "  %s = load i1, ptr %s", live, flag_address)
	run, next := new_label(e, "vararg.drop.run"), new_label(e, "vararg.drop.next")
	branch_if(e, live, run, next)
	place_label(e, run)
	fmt.sbprintfln(&e.b, "  store i1 false, ptr %s", flag_address)
	slot := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = getelementptr inbounds %s, ptr %s, i64 %s",
		slot, llvm_type(e, element), buffer, index,
	)
	emit_drop_place(e, element, slot)
	branch(e, next)
	place_label(e, next)
	branch(e, head)
	place_label(e, done)
}

// design.md: "`clone` ... calls `try_clone` once and, on failure, invokes the
// supplied allocator's failure policy."
//
// ponytail: M5a's fixed fallback is a non-unwinding trap; M6's allocator-selected
// `.Panic`/`.Trap` dispatch replaces the trap block, not the shape.
@(private = "file")
emit_synth_clone :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	subject := symbol.params[0]
	value_type := llvm_type(e, subject)
	pair := clone_pair_type(value_type)
	fmt.sbprintf(&e.b, "define %s %s(%s %%arg0, ptr %%arg1)", value_type, name, value_type)
	fmt.sbprintln(&e.b, " {")
	fmt.sbprintln(&e.b, "entry:")
	e.terminated = false

	hook := type_hook(e.c, subject, "try_clone")
	if hook == INVALID_SYMBOL {
		backend_fail(e, "a generated `clone` has no `try_clone` member")
		return
	}
	returned := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call %s %s(%s %%arg0, ptr %%arg1)",
		returned, pair, e.names[hook], value_type,
	)
	cloned, error, failed := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, 0", cloned, pair, returned)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, 1", error, pair, returned)
	fmt.sbprintfln(&e.b, "  %s = icmp ne i64 %s, 0", failed, error)
	// design.md "Allocation failure": an implicit copy has nowhere to return an
	// error, so the *allocator's* policy decides — `.Panic` follows the program
	// strategy and `.Trap` terminates immediately under either. The runtime reads
	// that policy off the handle the clone was given.
	fail, ok := new_label(e, "clone.failed"), new_label(e, "ok")
	branch_if(e, failed, fail, ok)
	fmt.sbprintfln(&e.b, "%s:", fail)
	e.terminated = false
	fmt.sbprintln(&e.b, "  call void @loke_rt_v1_alloc_failed(ptr %arg1)")
	fmt.sbprintln(&e.b, "  unreachable")
	e.terminated = true
	fmt.sbprintfln(&e.b, "%s:", ok)
	e.terminated = false
	fmt.sbprintfln(&e.b, "  ret %s %s", value_type, cloned)
	fmt.sbprintln(&e.b, "}")
}

// The `try_clone` or `drop` a type answers to: a written one when the `impl`
// block has it, and the contributed one otherwise.
type_hook :: proc(c: ^Compiler, type: Type_Id, name: string) -> Symbol_Id {
	info := type_of(c, type_underlying(c, type))
	if info == nil {
		return INVALID_SYMBOL
	}
	return member_named_in(c, info.members, intern_identifier(c, name))
}

// design.md: "`drop(value)` invokes the user hook when present" and "Fields are
// dropped in reverse declaration order after the containing type's drop hook
// returns." Used by partial-clone cleanup now; step 4's scope-exit cleanup is
// the same walk from a different caller.
emit_drop_place :: proc(e: ^Emitter, type: Type_Id, address: string) {
	if !type_is_managed(e.c, type) {
		return
	}
	// design.md "Dynamic arrays"/"Maps": container drop destroys every live
	// element exactly once, releases the raw storage through the bound provider,
	// and writes the inert all-zero representation. The all-zero value has no
	// storage and no provider, so dropping one is already a no-op in the helper.
	if lifecycle_of(e.c, type).container {
		helper := type_is_map(e.c, type) ? "loke_rt_v1_map_drop" : "loke_rt_v1_dyn_drop"
		fmt.sbprintfln(&e.b, "  call void @%s(ptr %s, ptr %s)", helper, address, container_ops_global(e, type))
		return
	}
	// design.md "string type": the drop releases one handle, and the last one
	// deallocates through the allocator the string was created with. A static
	// literal and the empty value are both no-ops the runtime recognises.
	if lifecycle_of(e.c, type).intrinsic {
		value, owner := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", value, STRING_TYPE, address)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", owner, STRING_TYPE, value, STRING_OWNER)
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_string_release(i64 %s)", owner)
		return
	}
	if hook := custom_drop_of(e.c, type); hook != INVALID_SYMBOL {
		fmt.sbprintfln(&e.b, "  call void %s(ptr %s)", e.names[hook], address)
	}
	for index := clone_part_count(e.c, type) - 1; index >= 0; index -= 1 {
		part := clone_part(e.c, type, index)
		if !type_is_managed(e.c, part) {
			continue
		}
		emit_drop_place(e, part, element_address(e, type, address, index))
	}
}

@(private = "file")
custom_drop_of :: proc(c: ^Compiler, type: Type_Id) -> Symbol_Id {
	return lifecycle_of(c, type).custom_drop
}

// ============================================================ erased views ==

// `{ ptr data, typeid id }`. The conversion never allocates: it pairs the
// source's address with its frozen `typeid`.
@(private = "file")
emit_any_view_value :: proc(e: ^Emitter, address: string, concrete: Type_Id) -> string {
	storage := llvm_type(e, TYPE_ANY_VIEW)
	first := temp(e)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, ptr %s, %d", first, storage, address, ANY_VIEW_DATA)
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, i64 %d, %d", out, storage, first, typeid_value(e.c, concrete), ANY_VIEW_ID)
	return out
}

// An assertion against an `any_view`: compare the stored `typeid`, then read the
// data pointer as the asserted type. A single-value position traps on a
// mismatch; the comma-ok form yields a zeroed payload and `false`.
@(private = "file")
emit_any_view_assert :: proc(e: ^Emitter, v: ^Expr_Type_Assert) -> []string {
	view := emit_expr(e, v.operand)
	storage := llvm_type(e, TYPE_ANY_VIEW)
	data, id := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", data, storage, view, ANY_VIEW_DATA)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", id, storage, view, ANY_VIEW_ID)
	matched := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i64 %s, %d", matched, id, typeid_value(e.c, v.type))

	target := llvm_type(e, v.type)
	if !v.optional {
		failed := temp(e)
		fmt.sbprintfln(&e.b, "  %s = xor i1 %s, true", failed, matched)
		panic_if(e, failed, "anyview.mismatch", "type assertion failed")
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", out, target, data)
		single := make([]string, 1)
		single[0] = out
		return single
	}

	slot := temp(e)
	fmt.sbprintfln(&e.b, "  %s = alloca %s", slot, target)
	fmt.sbprintfln(&e.b, "  store %s zeroinitializer, ptr %s", target, slot)
	then_label, done_label := new_label(e, "anyview.match"), new_label(e, "anyview.done")
	fmt.sbprintfln(&e.b, "  br i1 %s, label %%%s, label %%%s", matched, then_label, done_label)
	fmt.sbprintfln(&e.b, "%s:", then_label)
	loaded := temp(e)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", loaded, target, data)
	fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", target, loaded, slot)
	branch(e, done_label)
	fmt.sbprintfln(&e.b, "%s:", done_label)
	e.terminated = false
	payload := temp(e)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", payload, target, slot)
	pair := make([]string, 2)
	pair[0], pair[1] = payload, matched
	return pair
}

// `(dyn I)(&value)`: the data pointer plus the coherent witness for the erased
// type. A nil concrete pointer produces the nil view and retains no witness.
@(private = "file")
emit_dyn_value :: proc(e: ^Emitter, v: ^Expr_Call) -> string {
	storage := llvm_type(e, v.type)
	if v.dyn_witness == nil {
		return "zeroinitializer"
	}
	data := emit_expr(e, v.bound[0])
	first := temp(e)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, ptr %s, %d", first, storage, data, DYN_DATA)
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, ptr %s, %d", out, storage, first, v.dyn_witness.name, DYN_WITNESS)
	return out
}

// A slot call: load the thunk from the witness table and call it indirectly,
// trapping first if the view is nil.
@(private = "file")
emit_dyn_slot_call :: proc(e: ^Emitter, v: ^Expr_Call) -> []string {
	view := emit_expr(e, v.bound[0])
	storage := llvm_type(e, expr_base(v.bound[0]).type)
	data, witness := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", data, storage, view, DYN_DATA)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", witness, storage, view, DYN_WITNESS)

	// design.md: calling a slot on nil panics.
	is_nil := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", is_nil, witness)
	panic_if(e, is_nil, "dyn.nil", "call through a nil dyn view")

	entry, thunk := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = getelementptr inbounds ptr, ptr %s, i64 %d", entry, witness, v.dyn_slot)
	fmt.sbprintfln(&e.b, "  %s = load ptr, ptr %s", thunk, entry)

	signature := type_of(e.c, expr_base(v.callee).type)
	result_type := llvm_result_type(e, signature.results, nil)
	operands := make([dynamic]string, 0, len(v.bound), context.temp_allocator)
	append(&operands, data)
	for index in 1 ..< len(v.bound) {
		if signature.param_modes[index] == .Inout {
			append(&operands, emit_address(e, v.bound[index]))
		} else {
			append(&operands, emit_expr(e, v.bound[index]))
		}
	}

	call := ""
	if len(signature.results) > 0 {
		call = temp(e)
		fmt.sbprintf(&e.b, "  %s = call %s %s(", call, result_type, thunk)
	} else {
		fmt.sbprintf(&e.b, "  call void %s(", thunk)
	}
	for operand, index in operands {
		if index > 0 {
			fmt.sbprint(&e.b, ", ")
		}
		type := index == 0 || signature.param_modes[index] == .Inout ? "ptr" : llvm_type(e, signature.parameters[index])
		fmt.sbprintf(&e.b, "%s %s", type, operand)
	}
	fmt.sbprintln(&e.b, ")")

	switch len(signature.results) {
	case 0:
		return nil
	case 1:
		single := make([]string, 1)
		single[0] = call
		return single
	}
	out := make([]string, len(signature.results))
	for index in 0 ..< len(signature.results) {
		out[index] = temp(e)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", out[index], result_type, call, index)
	}
	return out
}

// One private immutable global per materialised constant, in registration order
// (design.md "Materialization"). A constant used only at constant indices never
// registered one and so occupies no space in the program.
@(private = "file")
emit_materialized_constants :: proc(e: ^Emitter) {
	if len(e.c.materialized_order) == 0 {
		return
	}
	for entry in e.c.materialized_order {
		fmt.sbprintfln(
			&e.b,
			"%s = private unnamed_addr constant %s %s",
			entry.name, llvm_type(e, entry.type), llvm_const(e, entry.value, entry.type),
		)
	}
	fmt.sbprintln(&e.b, "")
}

// One private immutable global per `(Interface, Concrete, arguments)`, holding a
// compiler-generated thunk per slot. A thunk takes the erased receiver pointer
// and re-types it for the concrete implementation.
@(private = "file")
emit_witnesses :: proc(e: ^Emitter) {
	for witness in e.c.witness_order {
		for slot, index in witness.slots {
			emit_witness_thunk(e, witness, slot, index)
		}
	}
	for witness in e.c.witness_order {
		fmt.sbprintf(&e.b, "%s = private unnamed_addr constant [%d x ptr] [", witness.name, len(witness.slots))
		for _, index in witness.slots {
			if index > 0 {
				fmt.sbprint(&e.b, ",")
			}
			fmt.sbprintf(&e.b, " ptr %s", witness_thunk_name(e, witness, index))
		}
		fmt.sbprintln(&e.b, " ]")
	}
	fmt.sbprintln(&e.b, "")
}

@(private = "file")
witness_thunk_name :: proc(e: ^Emitter, witness: ^Witness, index: int) -> string {
	return fmt.aprintf("%s.thunk.%d", witness.name, index)
}

@(private = "file")
emit_witness_thunk :: proc(e: ^Emitter, witness: ^Witness, slot: Witness_Slot, index: int) {
	target := symbol_of(e.c, slot.target)
	if target == nil {
		return
	}
	e.terminated = false
	name := witness_thunk_name(e, witness, index)
	signature := type_of(e.c, target.proc_type)
	result_type := llvm_result_type(e, target.results, nil)

	fmt.sbprintf(&e.b, "define private %s %s(ptr %%arg0", result_type, name)
	for position in 1 ..< len(target.params) {
		mode := signature.param_modes[position]
		type := mode == .Inout ? "ptr" : llvm_type(e, target.params[position])
		fmt.sbprintf(&e.b, ", %s %%arg%d", type, position)
	}
	fmt.sbprint(&e.b, ")")
	fmt.sbprintln(&e.b, " {")
	fmt.sbprintln(&e.b, "entry:")

	// The receiver arrives erased. An immutable `self` is a value parameter, so
	// it is loaded; an `inout self` is already the alias the callee wants.
	receiver := "%arg0"
	if slot.mode != .Inout {
		loaded := temp(e)
		fmt.sbprintfln(&e.b, "  %s = load %s, ptr %%arg0", loaded, llvm_type(e, target.params[0]))
		receiver = loaded
	}

	call := ""
	if len(target.results) > 0 {
		call = temp(e)
		fmt.sbprintf(&e.b, "  %s = call %s %s(", call, result_type, e.names[slot.target])
	} else {
		fmt.sbprintf(&e.b, "  call void %s(", e.names[slot.target])
	}
	receiver_type := slot.mode == .Inout ? "ptr" : llvm_type(e, target.params[0])
	fmt.sbprintf(&e.b, "%s %s", receiver_type, receiver)
	for position in 1 ..< len(target.params) {
		mode := signature.param_modes[position]
		type := mode == .Inout ? "ptr" : llvm_type(e, target.params[position])
		fmt.sbprintf(&e.b, ", %s %%arg%d", type, position)
	}
	fmt.sbprintln(&e.b, ")")

	if len(target.results) == 0 {
		fmt.sbprintln(&e.b, "  ret void")
	} else {
		fmt.sbprintfln(&e.b, "  ret %s %s", result_type, call)
	}
	fmt.sbprintln(&e.b, "}")
	fmt.sbprintln(&e.b, "")
}

// design.md: `dyn I` satisfies `I` through compiler-provided forwarding slots.
// The forwarder takes the view by value, traps on a nil witness, and calls the
// slot's thunk with the view's own data pointer.
@(private = "file")
emit_dyn_forwarding_slot :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	signature := type_of(e.c, symbol.proc_type)
	result_type := llvm_result_type(e, symbol.results, nil)
	view_type := llvm_type(e, symbol.params[0])

	receiver_inout := len(signature.param_modes) > 0 && signature.param_modes[0] == .Inout
	receiver_type := receiver_inout ? "ptr" : view_type
	fmt.sbprintf(&e.b, "define %s %s(%s %%arg0", result_type, name, receiver_type)
	for position in 1 ..< len(symbol.params) {
		mode := signature.param_modes[position]
		type := mode == .Inout ? "ptr" : llvm_type(e, symbol.params[position])
		fmt.sbprintf(&e.b, ", %s %%arg%d", type, position)
	}
	fmt.sbprint(&e.b, ")")
	fmt.sbprintln(&e.b, " {")
	fmt.sbprintln(&e.b, "entry:")

	view := "%arg0"
	if receiver_inout {
		view = temp(e)
		fmt.sbprintfln(&e.b, "  %s = load %s, ptr %%arg0", view, view_type)
	}
	data, witness := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", data, view_type, view, DYN_DATA)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", witness, view_type, view, DYN_WITNESS)
	is_nil := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", is_nil, witness)
	panic_if(e, is_nil, "dyn.nil", "call through a nil dyn view")

	entry, thunk := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = getelementptr inbounds ptr, ptr %s, i64 %d", entry, witness, symbol.index)
	fmt.sbprintfln(&e.b, "  %s = load ptr, ptr %s", thunk, entry)

	call := ""
	if len(symbol.results) > 0 {
		call = temp(e)
		fmt.sbprintf(&e.b, "  %s = call %s %s(ptr %s", call, result_type, thunk, data)
	} else {
		fmt.sbprintf(&e.b, "  call void %s(ptr %s", thunk, data)
	}
	for position in 1 ..< len(symbol.params) {
		mode := signature.param_modes[position]
		type := mode == .Inout ? "ptr" : llvm_type(e, symbol.params[position])
		fmt.sbprintf(&e.b, ", %s %%arg%d", type, position)
	}
	fmt.sbprintln(&e.b, ")")

	if len(symbol.results) == 0 {
		fmt.sbprintln(&e.b, "  ret void")
	} else {
		fmt.sbprintfln(&e.b, "  ret %s %s", result_type, call)
	}
	fmt.sbprintln(&e.b, "}")
}

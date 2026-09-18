// LLVM module orchestration, emitter state, naming, and instruction plumbing.
//
// Part of the textual LLVM backend; see compiler-architecture.md.
package lokec


import "core:fmt"
import "core:mem/virtual"
import "core:strings"

@(private)
Emitter :: struct {
	c:    ^Compiler,
	b:    strings.Builder,
	next: int, // temporary and unique-name counter
	failed: bool,
	// Set while `emit_synth_procs` emits member bodies. A member such as
	// `lookup_value` on a move-only element clones a type with no clone, but the
	// checker rejected every call to it (L0491), so its body is dead and the copy
	// aborts instead of failing the build.
	synth_bodies: bool,
	// Backend names are an emitter concern. Semantic symbols remain reusable by
	// MIR, interpreters, and multiple backend invocations.
	names:        map[Symbol_Id]string,
	struct_names: map[Type_Id]string,
	// design.md "@(packed)": a place's guaranteed alignment, keyed by its pointer
	// temporary, when lower than the pointee's natural alignment (true of any
	// access through a packed field). Such a load/store carries `align 1` so the
	// optimizer never assumes the missing alignment.
	place_align:  map[string]u64,

	// Everything that describes the one function currently being written.
	// `begin_function_emission` saves and clears the whole thing, so a thunk
	// emitted mid-body cannot inherit any of it.
	using fn: Function_State,

	// The functions generated to replay panic cleanups. Empty under
	// `-panic=abort`.
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
	// element thunks.
	container_ops: map[Type_Id]string,
	// The element and key thunks those tables point at, keyed by generated name:
	// one part type reached from two container types is one thunk.
	container_thunks: map[string]bool,
	// Interned C string constants (panic messages), keyed by content so one
	// message is one global, plus the module-scope definitions they need.
	messages: map[string]string,
	// Static literal storage, keyed by content so one literal is one global.
	literals: map[string]string,
	// The LLVM vector-reduction intrinsics this module declares, keyed by their
	// mangled name so one shape is declared once.
	simd_intrinsics: map[string]bool,
	globals:  [dynamic]string,
}

// Every emitter starts here. The layout probe builds one too, and a field added
// to `Emitter` but not to a second literal is a silently half-initialized map,
// so there is exactly one literal.
make_emitter :: proc(c: ^Compiler) -> Emitter {
	e := Emitter {
		c            = c,
		names        = make(map[Symbol_Id]string),
		struct_names = make(map[Type_Id]string),
		place_align  = make(map[string]u64),
		cleanups     = make([dynamic]Cleanup_Scope),
		param_values = make(map[Symbol_Id]string),
		pending      = make([dynamic]string),
		pending_thunks = make([dynamic]string),
		container_ops = make(map[Type_Id]string),
		container_thunks = make(map[string]bool),
		messages     = make(map[string]string),
		literals     = make(map[string]string),
		simd_intrinsics = make(map[string]bool),
		globals      = make([dynamic]string),
	}
	strings.builder_init(&e.b)
	return e
}

// Pure module generation boundary: lowering and LLVM serialization consume the
// checked compilation and return bytes in memory. One module holds every package
// in dependency order, so there is nothing per-package to select. Filesystem
// policy and the external toolchain remain in `emit_package` above.
emit_llvm_module :: proc(c: ^Compiler) -> (string, bool) {
	context.allocator = virtual.arena_allocator(&c.emission_arena)
	if !validate_emission_dependencies(c) { return "", false }
	e := make_emitter(c)

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
	// Foreign `declare`s and `external global`s, once each: a call or a global
	// reference names one already.
	emit_foreign_declarations(&e)
	// Module-level storage first: a body that names a `static` local needs its
	// global to exist before the body is emitted.
	emit_static_locals(&e)
	for id in order {
		emit_package_items(&e, package_of(c, id))
	}
	emit_synth_procs(&e)
	emit_witnesses(&e)
	// The TLS teardown thunk is supplied by *every* generated module: the runtime's
	// `thread_detach` calls it, so an object build needs it as much as an
	// executable does.
	emit_thread_local_teardown(&e)
	// design.md "Build-selected providers": the initializer exists only where
	// something is selected. An object build exports it for its host to call; an
	// executable calls it from its own entry. An unselected build has no
	// initializer at all, which is what keeps an existing host unchanged.
	if any_provider_selected(c) {
		emit_program_init(&e)
	}
	// design.md "Build modes": an object build emits no C entry.
	// Its foreign host owns process startup and calls the exported procedures; a
	// generated `main`/`wmain` would collide with the host's own entry.
	if c.build_mode == .Exe {
		emit_entry(&e)
	}
	emit_type_info_tables(&e)
	emit_format_thunks(&e)
	for text in e.pending_thunks {
		strings.write_string(&e.b, text)
	}
	for text in e.globals {
		strings.write_string(&e.b, text)
	}
	if e.failed || c.error_count != 0 {
		return "", false
	}
	return strings.to_string(e.b), true
}

// Every function emitter writes into an isolated buffer, so storage can never
// leak into the next function even as new emitters are added.
//
// A thunk emitted mid-body must not inherit the outer function's
// `result_slot`, cleanup scope, or loop label, so isolation covers every field
// describing "the function being written," not just the buffer. Everything
// listed here is saved, zeroed for the nested function, and put back;
// anything the module owns (`names`, `next`, `globals`) deliberately is not.
@(private = "file")
Function_Emission :: struct {
	parent: strings.Builder,
	saved:  Function_State,
}

// The per-function half of `Emitter`, embedded so a field is still written as
// `e.result_type` and adding one to this struct is all it takes for
// `begin_function_emission` to save and restore it. `emit_unwind_thunk` is the
// one emitter that does not go through it: a replayed action re-emits the
// parent's own `defer` statements, so it inherits most of this state and swaps
// only the four fields it owns. A new field that a replay must not share with
// the frame it unwinds has to be added there as well.
@(private)
Function_State :: struct {
	// Whether the block being appended to already ends in a terminator. LLVM
	// rejects both a block without one and an instruction after one.
	terminated: bool,

	// Current procedure. design.md: at most one result; INVALID_TYPE when it has
	// none, and then `result_slot` is empty.
	result_type: Type_Id,
	result_slot: string,
	// Whether the result was declared `inout`. Such a result is returned as the
	// address of a place, which is what makes `grid[i] = v` an ordinary store.
	result_inout: bool,
	// design.md "Calling conventions": whether the procedure being emitted uses a
	// foreign convention, so its signature and `ret` follow the Windows x64
	// classification rather than LLVM's own aggregate lowering.
	abi_foreign: bool,
	// The hidden `sret` result pointer, when the single result is returned
	// indirectly. Empty otherwise. The body's result slot aliases it directly.
	abi_sret:    string,
	defer_flags: []string,
	cleanups:    [dynamic]Cleanup_Scope,
	// design.md "Borrows and lifetimes": a value temporary lives until the end of
	// its complete expression, which is narrower than any lexical scope. One
	// frame per full expression, because the storage is a hoisted alloca a loop
	// reuses — registering these in the surrounding scope would drop only the
	// last value and leak every earlier iteration.
	temporaries: [dynamic][dynamic]Deferred,
	break_label:    string,
	continue_label: string,
	break_depth:    int,
	continue_depth: int,
	// Parameter values already bound at the call site being emitted, so a
	// default expression that names a parameter to its left reads that value.
	param_values: map[Symbol_Id]string,
	// The current procedure's panic-cleanup registration.
	unwind: Unwind_State,
	// Every fixed-size `alloca` this function asked for, in order asked. LLVM
	// retains an alloca until the function returns, so one left in place would
	// grow the native stack on every iteration of an enclosing loop at
	// `-opt=none`; they are spliced into the entry block on the way out.
	prologue: [dynamic]string,
}

// `define <signature> {` followed by the entry label. `{` is a `core:fmt`
// directive and can never appear in a format string, which is why every caller
// used to split the write in two and comment about it; that trap is now sprung
// once, here.
@(private)
open_function :: proc(e: ^Emitter, format: string, args: ..any) {
	fmt.sbprintf(&e.b, format, ..args)
	fmt.sbprintln(&e.b, " {")
	fmt.sbprintln(&e.b, "entry:")
}

@(private)
begin_function_emission :: proc(e: ^Emitter) -> Function_Emission {
	state := Function_Emission{parent = e.b, saved = e.fn}
	e.b = strings.builder_make()
	e.fn = {}
	e.result_type = INVALID_TYPE
	return state
}

// Ends the isolated emission and hands back the finished function text, which
// the caller places: into the enclosing buffer for an ordinary definition, or
// into `pending_thunks` for one generated in the middle of another function.
@(private)
end_function_emission :: proc(e: ^Emitter, state: Function_Emission) -> string {
	text := splice_prologue(e, strings.to_string(e.b), e.prologue[:])
	e.b = state.parent
	e.fn = state.saved
	return text
}

@(private)
finish_function_emission :: proc(e: ^Emitter, state: Function_Emission) {
	strings.write_string(&e.b, end_function_emission(e, state))
}

// A function cannot be defined inside another, so a thunk generated while a
// body is being written is parked and flushed once at the end of the module.
@(private)
finish_pending_thunk :: proc(e: ^Emitter, state: Function_Emission) {
	append(&e.pending_thunks, end_function_emission(e, state))
}

// Places the collected `alloca` lines immediately after the function's entry
// label, which is the only point at which every one of them is known.
@(private)
splice_prologue :: proc(e: ^Emitter, body: string, prologue: []string) -> string {
	if len(prologue) == 0 {
		return body
	}
	ENTRY :: "\nentry:\n"
	at := strings.index(body, ENTRY)
	if at < 0 {
		// Every function that reaches here opened with an entry label, so there is
		// nowhere to place the storage only if one was written without one. The text
		// is handed on unchanged for LLVM to describe the break in its own terms,
		// but `e.failed` is what stops a module missing a function's allocas from
		// being returned as though it were whole.
		backend_fail(e, "a function has no entry block to hold its storage")
		return body
	}
	out := strings.builder_make()
	strings.write_string(&out, body[:at + len(ENTRY)])
	for line in prologue {
		fmt.sbprintln(&out, line)
	}
	strings.write_string(&out, body[at + len(ENTRY):])
	return strings.to_string(out)
}

// design.md "@(export)": an export is the only reason a generated procedure needs
// a linker-visible name. Everything else is emitted under a mangled `@loke.` name
// no external consumer can even spell — `.` is not an identifier byte in C — and
// this module holds the whole program, so `internal` is what lets LLVM drop a body
// once it has finished inlining it. The runtime's own entry points
// (`@loke_rt_v1_*`, `@wmain`) are written as fixed text and never reach here.
@(private)
llvm_linkage :: proc(name: string) -> string {
	return strings.has_prefix(name, "@loke.") ? "internal " : ""
}

@(private)
backend_fail :: proc(e: ^Emitter, message: string) {
	if e.failed {
		return
	}
	e.failed = true
	errorf(e.c, no_span(), "L0405", "internal backend contract violation: %s", message)
}

// The backend name of an already resolved operation. Every symbol a body can
// name is bound before any body is emitted, so an unbound one means a semantic
// registry reached lowering holding a symbol nothing emits — the same class of
// break `emission_contract.odin` rejects earlier, caught here for the registries
// it does not know about. The placeholder only keeps the text well formed;
// `e.failed` is what stops the module from being returned.
symbol_name :: proc(e: ^Emitter, id: Symbol_Id) -> string {
	if name, named := e.names[id]; named {
		return name
	}
	backend_fail(e, "a resolved operation has no emitted name")
	return "null"
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
				for symbol_id in v.symbols {
					if sym := symbol_of(e.c, symbol_id); sym != nil && sym.kind == .Var && !sym.is_foreign {
						e.names[symbol_id] = sym.exported \
							? llvm_external_name(sym.link_name) \
							: llvm_global_name(pkg, identifier_text(e.c, sym.name))
					}
				}
				// A template has no signature and no body of its own; only its
				// instances are named and emitted.
				if decl_proc_literal(v) != nil && len(v.symbols) > 0 && !symbol_is_template(e.c, v.symbols[0]) {
					// design.md "@(export)": an exported procedure emits
					// its definition under the written/`@(link_name)` symbol so a C
					// consumer can link to it, in place of the mangled name.
					if sym := symbol_of(e.c, v.symbols[0]); sym != nil && sym.exported {
						e.names[v.symbols[0]] = llvm_external_name(sym.link_name)
					} else {
						e.names[v.symbols[0]] = llvm_proc_name(pkg, v.names[0].text)
					}
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
			case ^Item_Foreign_Block:
				// design.md "Foreign system": a member's link name is its external
				// symbol, so calls and the `declare` share `@<link_name>` with no
				// package mangling.
				for member in v.members {
					d, is_decl := member.(^Decl)
					if !is_decl {
						continue
					}
					for sid in d.symbols {
						if sym := symbol_of(e.c, sid); sym != nil && sym.is_foreign {
							e.names[sid] = foreign_llvm_name(sym)
						}
					}
				}
			}
		}
	}
	for literal, index in pkg.hoisted_procs {
		// A declared body-local procedure is hoisted by the same route an
		// anonymous literal is, so it is named here too. The written name keeps
		// the module readable; the index is what keeps two bodies declaring the
		// same name apart.
		written := "lambda"
		if sym := symbol_of(e.c, literal.symbol); sym != nil && sym.decl != nil {
			written = llvm_safe(identifier_text(e.c, sym.name))
		}
		e.names[literal.symbol] = llvm_proc_name(pkg, fmt.aprintf("%s.%d", written, index))
	}
	// Instantiations are named with their own package's symbols, in deterministic
	// instantiation order, so a cross-package generic call has a final name
	// before any body is written.
	//
	// Each part of that name is the argument type as source spells it, and a
	// written name is not unique across packages: `size_of_arg(alpha.Item)` and
	// `size_of_arg(beta.Item)` are two instances with one spelling. The symbol
	// id separates them, exactly as it does for the synthesized procedures
	// below, so a collision costs a suffix rather than a definition.
	taken := make(map[string]bool, len(pkg.instances), context.temp_allocator)
	for instance in pkg.instances {
		name := llvm_proc_name(pkg, llvm_safe(instance.name))
		if taken[name] {
			name = fmt.aprintf("%s.%d", name, int(instance.symbol))
		}
		taken[name] = true
		e.names[instance.symbol] = name
	}
}

// The compiler-contributed `iter` and `next` are compilation-global rather than
// package-owned, so they are named with the ordinary symbols and emitted after
// every package's items.
@(private = "file")
name_synth_procs :: proc(e: ^Emitter) {
	used := make(map[string]bool, context.temp_allocator)
	for symbol_id in e.c.synth_procs {
		symbol := symbol_of(e.c, symbol_id)
		if symbol == nil {
			continue
		}
		base := fmt.aprintf("@loke.i.%s", llvm_safe(qualified_member_name(e.c, symbol)))
		name := base
		if used[name] {
			name = fmt.aprintf("%s.%d", base, int(symbol_id))
		}
		used[name] = true
		e.names[symbol_id] = name
	}
}

@(private = "file")
symbol_is_template :: proc(c: ^Compiler, symbol_id: Symbol_Id) -> bool {
	sym := symbol_of(c, symbol_id)
	if sym == nil {
		return false
	}
	if sym.generic {
		return true
	}
	// Template registration is lazy. A package can reach emission without an
	// unused generic declaration's signature ever being checked, so retain the
	// syntax-level classification at this final boundary. Instances deliberately
	// keep their cloned generic syntax and are distinguished by `instance_of`.
	return sym.instance_of == INVALID_SYMBOL && declaration_generic_kind(sym.decl) != .None
}

@(private = "file")
emit_package_items :: proc(e: ^Emitter, pkg: ^Package) {
	if pkg == nil {
		return
	}
	for file in pkg.files {
		for item in file.active_items {
			if d, ok := item.(^Decl); ok && decl_proc_literal(d) == nil {
				emit_global(e, d)
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
					// A generic method is a template like any other declaration: it has
					// no body to emit until an instantiation gives its `$` names values,
					// and its uninstantiated body was never checked.
					if symbol_is_template(e.c, d.symbols[0]) {
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
		// An instantiated `impl` block installs its members as instances, and a
		// *generic method* among them is still a template: its `$` names have no
		// values until it is itself instantiated, and its body was never checked.
		if symbol_is_template(e.c, instance.symbol) {
			continue
		}
		if literal := decl_proc_literal(instance.decl); literal != nil {
			emit_proc(e, instance.symbol, literal)
		}
	}
}

// ============================================================= containers ==

// One four-word header serves both containers, and the raw storage behind it
// belongs to `runtime/container.c`.
CONTAINER_TYPE :: "%loke.container"

CONTAINER_OPS_TYPE :: "%loke.container_ops"

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
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)

	e.result_type = symbol.result
	e.result_inout = result_inout_of(e, symbol.proc_type)
	e.abi_foreign = convention_is_foreign(proc_convention_of(e, symbol))
	begin_unwind_frame(e, llvm_name)

	if e.abi_foreign {
		emit_foreign_signature(e, symbol, llvm_name)
	} else {
		fmt.sbprintf(
			&e.b, "define %s%s %s(",
			llvm_linkage(llvm_name), llvm_result_type(e, symbol.result, e.result_inout), llvm_name,
		)
		for parameter, index in symbol.params {
			if index > 0 {
				fmt.sbprint(&e.b, ", ")
			}
			mode := symbol_param_mode(e.c, symbol, index)
			type := param_mode_is_pointer(mode) ? "ptr" : llvm_type(e, parameter)
			fmt.sbprintf(&e.b, "%s %%arg%d", type, index)
		}
		fmt.sbprintln(&e.b, ") {")
	}
	fmt.sbprintln(&e.b, "entry:")

	// The rest of the body goes to a side builder: the frame prologue needs the
	// number of registered actions and the number of published locals, and
	// neither is known until the whole body has been walked.
	module := e.b
	e.b = strings.builder_make()

	// A value parameter is immutable but addressable, so it gets storage of its
	// own; an `inout` parameter, and an immutable receiver, are already the alias
	// to the caller's storage (design.md "Receiver forms").
	for parameter, index in symbol.params {
		binding := symbol.param_symbols[index]
		if binding == INVALID_SYMBOL {
			continue
		}
		if param_mode_is_pointer(symbol_param_mode(e.c, symbol, index)) {
			bind_local(e, binding, fmt.aprintf("%%arg%d", index))
			continue
		}
		if e.abi_foreign {
			bind_local(e, binding, emit_foreign_param_slot(e, parameter, index))
			continue
		}
		slot := fmt.aprintf("%%p%d.%d", index, next_id(e))
		alloca_named(e, slot, llvm_type(e, parameter))
		fmt.sbprintfln(&e.b, "  store %s %%arg%d, ptr %s", llvm_type(e, parameter), index, slot)
		bind_local(e, binding, slot)
	}

	// The result slot starts at the result type's zero, so `or_return` has
	// somewhere to publish a failure from inside an expression.
	if result := symbol.result; result != INVALID_TYPE {
		// A result returned through a hidden `sret` pointer writes straight into
		// caller storage: the result slot is that pointer, not a fresh alloca.
		if e.abi_sret != "" {
			e.result_slot = e.abi_sret
			if zero, ok := zero_const(e.c, result); ok {
				fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", llvm_type(e, result), llvm_const(e, zero, result), e.abi_sret)
			}
		} else if e.result_inout {
			// The slot holds the address of the place being handed back.
			slot := fmt.aprintf("%%r0.%d", next_id(e))
			alloca_named(e, slot, "ptr")
			fmt.sbprintfln(&e.b, "  store ptr null, ptr %s", slot)
			e.result_slot = slot
		} else {
			slot := fmt.aprintf("%%r0.%d", next_id(e))
			alloca_named(e, slot, llvm_type(e, result))
			if zero, ok := zero_const(e.c, result); ok {
				fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", llvm_type(e, result), llvm_const(e, zero, result), slot)
			}
			e.result_slot = slot
		}
	}

	// One `i1` flag per syntactic defer, reset when its scope activates and set
	// when registration is reached, so a loop iteration cannot inherit the
	// previous one's registration.
	e.defer_flags = make([]string, literal.defer_count)
	for index in 0 ..< literal.defer_count {
		flag := fmt.aprintf("%%defer%d.%d", index, next_id(e))
		alloca_named(e, flag, "i1")
		e.defer_flags[index] = flag
	}

	// design.md "Parameter semantics and ABI lowering": a `move` parameter
	// transfers ownership to the callee, so the callee drops it. Its scope sits
	// outside the body's, which makes its cleanup the outermost one every exit
	// replays.
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

// The C entry point — internal runtime startup belongs here, which is why
// Loke's `main` is not the C `main`.
//
// design.md "Program entry and exit": the entry is `wmain`,
// so arguments arrive as UTF-16 and are converted to cached UTF-8 by the
// runtime before anything else runs. `os.args` is then a read, not a
// conversion, and no Loke package needs an initializer.
@(private = "file")
emit_entry :: proc(e: ^Emitter) {
	entry, found := e.names[e.c.entry_point]
	if !found || entry == "" {
		backend_fail(e, "the validated entry procedure has no emitted name")
		return
	}
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	fmt.sbprintln(&e.b, "define i32 @wmain(i32 %argc, ptr %argv) {")
	fmt.sbprintln(&e.b, "entry:")
	fmt.sbprintln(&e.b, "  call void @loke_rt_v1_args_init(i32 %argc, ptr %argv)")
	// design.md "Threads": the initial thread attaches like any other, and the
	// same detach that drops managed TLS on a normal return is simply never
	// reached when a panic terminates the process instead.
	fmt.sbprintln(&e.b, "  call void @loke_rt_v1_thread_attach()")
	// design.md "Executable startup ABI": arguments, then the thread, then the
	// providers, then `main`. Nothing runs between them.
	if any_provider_selected(e.c) {
		fmt.sbprintln(&e.b, "  call void @loke_rt_v1_program_init()")
	}
	fmt.sbprintfln(&e.b, "  call void %s()", entry)
	fmt.sbprintln(&e.b, "  call void @loke_rt_v1_thread_detach()")
	fmt.sbprintln(&e.b, "  ret i32 0")
	fmt.sbprintln(&e.b, "}")
}

// design.md "Build-selected providers": one initializer, run once, on the
// attached startup thread. The allocator is published first so the logger
// factory's own default allocations already use it; the allocator factory's own
// run before anything is published and therefore use the system heap.
//
// The runtime owns the once-and-only-once state, because it also owns the
// answer to "has this already happened" that a foreign host may ask twice.
@(private = "file")
emit_program_init :: proc(e: ^Emitter) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	fmt.sbprintln(&e.b, "define void @loke_rt_v1_program_init() {")
	fmt.sbprintln(&e.b, "entry:")
	e.terminated = false
	go, run := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = call i32 @loke_rt_v1_provider_init_begin()", go)
	fmt.sbprintfln(&e.b, "  %s = icmp ne i32 %s, 0", run, go)
	body, done := new_label(e, "init.run"), new_label(e, "init.done")
	branch_if(e, run, body, done)
	place_label(e, body)

	if allocator := e.c.providers[.Allocator].factory; allocator != INVALID_SYMBOL {
		handle := temp(e)
		fmt.sbprintfln(&e.b, "  %s = call ptr %s()", handle, symbol_name(e, allocator))
		// The runtime checks the handle for nil and for a matching record, and
		// terminates before application code runs when either fails.
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_publish_allocator(ptr %s)", handle)
	}
	if logger := e.c.providers[.Logger].factory; logger != INVALID_SYMBOL {
		slot := log_current_logger_symbol(e.c)
		result := symbol_of(e.c, logger).result
		handle := temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call %s %s()",
			handle, llvm_type(e, result), symbol_name(e, logger),
		)
		if global, found := e.names[slot]; found {
			store(e, result, handle, global)
		} else {
			backend_fail(e, "the selected logger has nowhere to be published")
		}
	}
	fmt.sbprintln(&e.b, "  call void @loke_rt_v1_provider_init_end()")
	branch(e, done)
	place_label(e, done)
	fmt.sbprintln(&e.b, "  ret void")
	fmt.sbprintln(&e.b, "}")
}

// ------------------------------------------------------------ block plumbing --

@(private)
next_id :: proc(e: ^Emitter) -> int {
	e.next += 1
	return e.next
}

@(private)
temp :: proc(e: ^Emitter) -> string {
	return fmt.aprintf("%%t%d", next_id(e))
}

@(private)
new_label :: proc(e: ^Emitter, prefix: string) -> string {
	return fmt.aprintf("%s.%d", prefix, next_id(e))
}

// ---------------------------------------------------- instruction spellings --
//
// The handful of instructions that produce a value and are emitted everywhere.
// Each names its own result, so a caller writes what it wants instead of
// threading a `temp(e)` through a format string. The LLVM type is taken as
// *text*, since that's what call sites already hold — `llvm_type(e, id)` for a
// Loke type, or a fixed spelling like `CONTAINER_TYPE`.

@(private)
extract :: proc(e: ^Emitter, aggregate: string, value: string, index: int) -> string {
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", out, aggregate, value, index)
	return out
}

// The write half of `extract`. `into` is `"undef"` when this is the first field
// written into a fresh aggregate, and the previous partial value otherwise.
@(private)
insert :: proc(e: ^Emitter, aggregate, into, field_type, value: string, index: int) -> string {
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, %s %s, %d", out, aggregate, into, field_type, value, index)
	return out
}

// A plain, naturally aligned load. A place known to be *under*-aligned (e.g.
// reached through a packed field) needs the explicit `, align N` form
// instead, exactly as `store` gets it from `align_suffix`.
@(private)
load :: proc(e: ^Emitter, type: string, address: string) -> string {
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", out, type, address)
	return out
}

@(private)
alloca :: proc(e: ^Emitter, type: string) -> string {
	out := temp(e)
	alloca_named(e, out, type)
	return out
}

// The same storage, for a caller that has already chosen the slot's name.
@(private)
alloca_named :: proc(e: ^Emitter, name, type: string) {
	append(&e.prologue, fmt.aprintf("  %s = alloca %s", name, type))
}

// A pack whose element count is an SSA value, so it cannot move to the entry
// block: the count does not exist there.
@(private)
alloca_count :: proc(e: ^Emitter, name, type, count: string) {
	fmt.sbprintfln(&e.b, "  %s = alloca %s, i64 %s", name, type, count)
}

// The address of field `index` of an aggregate.
@(private)
gep_field :: proc(e: ^Emitter, aggregate: string, address: string, index: int) -> string {
	out := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = getelementptr inbounds %s, ptr %s, i32 0, i32 %d",
		out, aggregate, address, index,
	)
	return out
}

// The address of element `index` of a sequence, where `index` is an i64 operand
// rather than a constant field number.
@(private)
gep_at :: proc(e: ^Emitter, element: string, address: string, index: string) -> string {
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = getelementptr inbounds %s, ptr %s, i64 %s", out, element, address, index)
	return out
}

@(private)
place_label :: proc(e: ^Emitter, label: string) {
	if !e.terminated {
		fmt.sbprintfln(&e.b, "  br label %%%s", label)
	}
	fmt.sbprintfln(&e.b, "%s:", label)
	e.terminated = false
}

@(private)
branch :: proc(e: ^Emitter, label: string) {
	if e.terminated {
		return
	}
	fmt.sbprintfln(&e.b, "  br label %%%s", label)
	e.terminated = true
}

@(private)
branch_if :: proc(e: ^Emitter, cond: string, then_label, else_label: string) {
	if e.terminated {
		return
	}
	fmt.sbprintfln(&e.b, "  br i1 %s, label %%%s, label %%%s", cond, then_label, else_label)
	e.terminated = true
}

// ================================================== coherent formatting ==

// design.md "String format printing": runtime formatting has one formatter
// per concrete `typeid`. The table is private and parallel to the type-info
// table, because the public `Type_Info` layout deliberately exposes no code
// pointers — that is what keeps `base:runtime` from having to know
// `core:fmt` exists.
FMT_THUNKS :: "@.loke.fmt_thunks"

FMT_THUNK_COUNT :: "@.loke.fmt_thunks.count"

TYPE_NAMES :: "@.loke.type_names"

// ------------------------------------------------------------------ naming --

// Every user symbol carries its package's logical key, so two packages with the
// same declared name and the same source-level symbols still emit distinct
// working symbols. The root package's key is empty, which is what keeps its
// entry procedure at a fixed name.
@(private)
llvm_global_name :: proc(pkg: ^Package, name: string) -> string {
	return fmt.aprintf("@loke.g.%s%s", mangled_key(pkg), name)
}

@(private = "file")
llvm_proc_name :: proc(pkg: ^Package, name: string) -> string {
	return fmt.aprintf("@loke.p.%s%s", mangled_key(pkg), name)
}

// A type-qualified member name may mention punctuation LLVM would need quoting.
// Fixed-width hex keeps every byte sequence distinct and LLVM-safe.
@(private)
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
// mention punctuation LLVM would need quoting for. Keeping bytes LLVM already
// accepts and escaping the rest as `$XX` (escaping `$` itself too) stays
// injective while leaving the emitted symbol readable in a `tests/ll` golden.
// `dots = false` for a part that a `.` joins to others, so the separator stays
// unambiguous: `show("a.b", "c")` and `show("a", "b.c")` are two symbols.
llvm_safe :: proc(name: string, dots := true, allocator := context.allocator) -> string {
	hex := "0123456789abcdef"
	out := make([dynamic]u8, 0, len(name) + 8, allocator)
	for i in 0 ..< len(name) {
		ch := name[i]
		if llvm_name_byte(ch) && (dots || ch != '.') {
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

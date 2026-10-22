package lokec

import "core:fmt"
import "core:mem"

// design.md "Global write effects": a call writes whatever static-duration
// storage its callee may write, directly or through its own callees. Each body's
// set is settled over the whole program before provenance runs, and a call then
// counts as a write to every global in its callee's set, so a borrow of one that
// is still in use across the call conflicts exactly as a local write would.

// What one call may reach: a direct procedure, a `dyn` slot, or any procedure of
// a compatible type called through a value.
Effect_Call :: struct {
	callee:        Symbol_Id,
	type:          Type_Id,
	dyn_interface: Symbol_Id,
	dyn_index:     int,
	// Through a procedure value held in this body's parameter or local
	// `variable`, and once the body is summarized, the values it may hold.
	variable:      Symbol_Id,
	through:       []Effect_Arg,
	// A direct call's arguments that may be followed, each with the callee
	// parameter it binds; one missing there may be any procedure of its type.
	args:          []Effect_Arg,
	// Where the call is, and while the thread summaries collect, the region of
	// each argument by callee parameter, nil when no argument has one.
	span:          Span,
	regions:       []Region_Set,
}

// What a procedure value may be.
Effect_Arg :: struct {
	kind:      Effect_Arg_Kind,
	binding:   int,       // in `Effect_Call.args`: the callee parameter it binds
	parameter: int,       // `.Parameter`: the body's own parameter
	symbol:    Symbol_Id, // `.Procedure`, or `.Variable` until summarized
}

Effect_Arg_Kind :: enum u8 {
	Other,     // any procedure of its type
	Parameter, // what the caller passed for the parameter
	Procedure, // a named procedure
	Variable,  // whatever a variable of this body may hold
	Nil,       // none: a declaration without a value
}

// A value stored into a variable that holds a procedure. A declaration's makes
// the variable followed; a parameter is followed from the start.
Effect_Store :: struct {
	variable: Symbol_Id,
	value:    Effect_Arg,
	declares: bool,
}

// A call passing a named procedure for a `@(cross_thread)` parameter, and that
// procedure.
Thread_Spawn :: struct {
	entry: Symbol_Id,
	span:  Span,
}

// The bodies an indirect call may reach, kept from the write effects for the
// summaries settled after them: every clean body, and which are used as values.
Effect_Body :: struct {
	symbol: Symbol_Id,
	type:   Type_Id,
}

Effect_Program :: struct {
	bodies:        []Effect_Body,
	index_of:      map[Symbol_Id]int,
	used_as_value: map[Symbol_Id]bool,
}

// One body's own writes and calls, before the fixed point.
@(private = "file")
Body_Effects :: struct {
	symbol: Symbol_Id,
	type:   Type_Id,
	writes:  [dynamic]Symbol_Id,
	direct:  int, // how many of `writes` the body makes itself
	calls:   []Effect_Call,
	targets: [dynamic]int, // the bodies those calls may run
}

// A write, invalidation, or mutable borrow of a global's storage.
prov_note_static_write :: proc(graph: ^Flow_Graph, root: Root_Id) {
	if root == NO_ROOT {
		return
	}
	entry := graph.roots[int(root)]
	if (entry.kind != .Static && entry.kind != .Thread_Local) || entry.symbol == INVALID_SYMBOL {
		return
	}
	for existing in graph.effect_writes {
		if existing == entry.symbol {
			return
		}
	}
	append(&graph.effect_writes, entry.symbol)
}

// A procedure named anywhere but as a direct callee may be called through a
// value, so an indirect call's targets are drawn from these.
prov_note_proc_value :: proc(graph: ^Flow_Graph, e: Expr) {
	c := graph.k.c
	if c.global_writes_ready || e == nil {
		return
	}
	id := INVALID_SYMBOL
	#partial switch v in e {
	case ^Expr_Ident:
		id = v.symbol
	case ^Expr_Selector:
		id = v.resolution.symbol
	case ^Expr_Proc:
		id = v.symbol
	case:
		return
	}
	sym := symbol_of(c, id)
	if sym == nil || sym.kind != .Proc {
		return
	}
	if callee := graph.callee_expr; callee != nil && expr_base(callee) == expr_base(e) {
		graph.callee_expr = nil
		return
	}
	append(&graph.effect_values, id)
}

// The callee a call's global writes come from.
@(private = "file")
call_effect :: proc(c: ^Compiler, v: ^Expr_Call) -> (Effect_Call, bool) {
	#partial switch op in v.operation {
	case Call_Sort_By:
		return Effect_Call{callee = op.comparator}, op.comparator != INVALID_SYMBOL
	case Call_Dyn_Slot:
		sel, is_selector := v.callee.(^Expr_Selector)
		if !is_selector || sel.operand == nil {
			return {}, false
		}
		info := underlying_info(c, expr_base(sel.operand).type)
		if info == nil || info.kind != .Dyn {
			return {}, false
		}
		return Effect_Call{dyn_interface = info.dyn_interface, dyn_index = op.index}, true
	case Call_Procedure:
	case:
		return {}, false
	}
	id := v.resolution.chosen_overload
	if id == INVALID_SYMBOL {
		id = v.resolution.symbol
	}
	if sym := symbol_of(c, id); sym != nil && sym.kind == .Proc {
		if forwarded, is_forward := forwarding_effect(c, sym); is_forward {
			return forwarded, true
		}
		return Effect_Call{callee = id}, true
	}
	if base := expr_base(v.callee); base != nil && underlying_kind(c, base.type) == .Proc {
		call := Effect_Call{type = base.type}
		if ident, is_ident := v.callee.(^Expr_Ident); is_ident && effect_variable(c, ident.symbol) {
			call.variable = ident.symbol
		}
		return call, true
	}
	return {}, false
}

// A `dyn` forwarding member reaches what fills its slot, whatever the receiver
// expression is; a callable view also any procedure it holds.
@(private = "file")
forwarding_effect :: proc(c: ^Compiler, sym: ^Symbol) -> (Effect_Call, bool) {
	info := underlying_info(c, sym.owner_type)
	if sym.synth != .Dyn_Forward || info == nil || info.kind != .Dyn {
		return {}, false
	}
	return Effect_Call {
		dyn_interface = info.dyn_interface,
		dyn_index     = int(sym.index),
		type          = dyn_proc_signature(c, sym.owner_type),
	}, true
}

// Records the call while the effects settle; once they have, the callee's
// writes become accesses at the call, after its arguments' loans are taken.
prov_call_effects :: proc(graph: ^Flow_Graph, v: ^Expr_Call) {
	c := graph.k.c
	prov_implicit_call_effects(graph, v)
	target, ok := call_effect(c, v)
	if !ok {
		return
	}
	if !c.global_writes_ready {
		note_thread_spawn(graph, v)
		if target.callee != INVALID_SYMBOL {
			target.args = effect_args(c, v, graph.alloc)
		}
	}
	if c.thread_facts_pending {
		target.regions = prov_argument_regions(graph, v)
	}
	prov_effect_call(graph, target, v.span)
}

// Each argument that is a named procedure or a variable's value, with the
// callee's parameter it binds; most calls pass neither.
@(private = "file")
effect_args :: proc(c: ^Compiler, v: ^Expr_Call, allocator: mem.Allocator) -> []Effect_Arg {
	args: [dynamic]Effect_Arg
	for argument, index in v.bound {
		value := effect_value(c, argument)
		if value.kind == .Other {
			continue
		}
		if args == nil {
			args = make([dynamic]Effect_Arg, 0, 2, allocator)
		}
		value.binding = index
		append(&args, value)
	}
	return args[:]
}

// A parameter, or a local, whose procedure value is followed through the body.
@(private = "file")
effect_variable :: proc(c: ^Compiler, id: Symbol_Id) -> bool {
	sym := symbol_of(c, id)
	if sym == nil || underlying_kind(c, sym.type) != .Proc {
		return false
	}
	return sym.kind == .Parameter || (sym.kind == .Var && sym.duration == .None)
}

// What a procedure-valued expression may be.
@(private = "file")
effect_value :: proc(c: ^Compiler, e: Expr) -> Effect_Arg {
	value := e
	if moved, is_move := value.(^Expr_Move); is_move {
		value = moved.value
	}
	id := INVALID_SYMBOL
	#partial switch v in value {
	case ^Expr_Ident:
		id = v.symbol
	case ^Expr_Selector:
		id = v.resolution.symbol
	case:
		return {}
	}
	if underlying_kind(c, expr_base(value).type) != .Proc {
		return {}
	}
	if sym := symbol_of(c, id); sym != nil && sym.kind == .Proc {
		return Effect_Arg{kind = .Procedure, symbol = id}
	}
	if effect_variable(c, id) {
		return Effect_Arg{kind = .Variable, symbol = id}
	}
	return {}
}

// design.md "Global write effects": a value stored into a variable that holds a
// procedure, followed so a call through it runs only what it may hold. A write
// that is neither a declaration nor a plain assignment passes no value, and may
// store anything.
prov_note_proc_store :: proc(graph: ^Flow_Graph, variable: Symbol_Id, value: Expr, declares := false, written := true) {
	c := graph.k.c
	if c.global_writes_ready || !effect_variable(c, variable) {
		return
	}
	stored := written ? effect_value(c, value) : Effect_Arg{kind = .Nil}
	for existing in graph.effect_stores {
		if existing.variable == variable && existing.value == stored && existing.declares == declares {
			return
		}
	}
	append(&graph.effect_stores, Effect_Store{variable = variable, value = stored, declares = declares})
}

prov_note_declared_procs :: proc(graph: ^Flow_Graph, d: ^Decl) {
	for id, index in d.symbols {
		if d.destructure.active {
			prov_note_proc_store(graph, id, nil, declares = true)
			continue
		}
		initializer, written := declared_initializer(d, index)
		prov_note_proc_store(graph, id, initializer, declares = true, written = written && initializer != nil)
	}
}

prov_note_assigned_procs :: proc(graph: ^Flow_Graph, s: ^Stmt_Assign) {
	plain := s.op == .Assign && !s.destructure.active && len(s.rhs) == len(s.lhs)
	for target, index in s.lhs {
		if ident, is_ident := target.(^Expr_Ident); is_ident {
			prov_note_proc_store(graph, ident.symbol, plain ? s.rhs[index] : nil)
		}
	}
}

// What a variable may hold: a parameter what its caller passed, and either
// every value stored into it. One no declaration of this body made, as a loop's
// binding, may hold anything.
@(private = "file")
effect_variable_values :: proc(c: ^Compiler, stores: []Effect_Store, variable: Symbol_Id) -> []Effect_Arg {
	out := make([dynamic]Effect_Arg, 0, 2, context.temp_allocator)
	visited := make(map[Symbol_Id]bool, 4, context.temp_allocator)
	collect_variable_values(c, stores, variable, &out, &visited)
	return out[:]
}

@(private = "file")
collect_variable_values :: proc(
	c: ^Compiler,
	stores: []Effect_Store,
	variable: Symbol_Id,
	out: ^[dynamic]Effect_Arg,
	visited: ^map[Symbol_Id]bool,
) {
	if variable in visited^ {
		return
	}
	visited^[variable] = true
	declared := false
	if sym := symbol_of(c, variable); sym != nil && sym.kind == .Parameter {
		add_effect_value(out, Effect_Arg{kind = .Parameter, parameter = int(sym.index)})
		declared = true
	}
	for store in stores {
		if store.variable != variable {
			continue
		}
		declared ||= store.declares
		#partial switch store.value.kind {
		case .Variable:
			collect_variable_values(c, stores, store.value.symbol, out, visited)
		case .Nil:
		case:
			add_effect_value(out, store.value)
		}
	}
	if !declared {
		add_effect_value(out, Effect_Arg{})
	}
}

// A call's arguments with each variable replaced by what it may hold.
@(private = "file")
effect_resolved_args :: proc(c: ^Compiler, stores: []Effect_Store, args: []Effect_Arg) -> []Effect_Arg {
	out := make([dynamic]Effect_Arg, 0, len(args), context.temp_allocator)
	for arg in args {
		if arg.kind != .Variable {
			add_effect_value(&out, arg)
			continue
		}
		for value in effect_variable_values(c, stores, arg.symbol) {
			bound := value
			bound.binding = arg.binding
			add_effect_value(&out, bound)
		}
	}
	return out[:]
}

@(private = "file")
add_effect_value :: proc(list: ^[dynamic]Effect_Arg, value: Effect_Arg) {
	for existing in list {
		if existing == value {
			return
		}
	}
	append(list, value)
}

// Map operations that hash or compare keys: a lookup, an insertion, and a
// rehash.
@(private = "file")
KEY_HASHING_OPS :: bit_set[Container_Op]{
	.Map_Find, .Map_Find_Or_Insert, .Map_Lookup_Value, .Map_Try_Insert, .Map_Remove, .Map_Reserve, .Map_Shrink,
}

// A member the compiler supplies that calls a type's own `hash` or `==`: a
// generated `hash`, or a map operation on its keys.
@(private = "file")
prov_implicit_call_effects :: proc(graph: ^Flow_Graph, v: ^Expr_Call) {
	c := graph.k.c
	sym := symbol_of(c, v.resolution.chosen_overload)
	if sym == nil || len(v.bound) == 0 || v.bound[0] == nil {
		return
	}
	subject := expr_base(v.bound[0]).type
	#partial switch sym.synth {
	case .Standard_Hash:
		prov_hash_effects(graph, subject, v.span)
	case .Container_Op:
		if sym.container_op in KEY_HASHING_OPS {
			prov_key_effects(graph, subject, v.span)
		}
	}
}

// design.md "Global write effects": the language calls a type's own `hash` and
// `==` where it hashes or compares one, and each counts as a call there. A
// generated `hash` calls each part's own `hash`.
prov_hash_effects :: proc(graph: ^Flow_Graph, type: Type_Id, span: Span) {
	c := graph.k.c
	parts: [dynamic]Type_Id
	defer delete(parts)
	own_equalities_within(c, type, &parts)
	for part in parts {
		if own := part_own_hash(c, part); own != INVALID_SYMBOL {
			prov_effect_call(graph, Effect_Call{callee = own}, span)
		}
	}
}

// A structural `==` calls each part's own `==`.
prov_equality_effects :: proc(graph: ^Flow_Graph, type: Type_Id, span: Span) {
	c := graph.k.c
	parts: [dynamic]Type_Id
	defer delete(parts)
	own_equalities_within(c, type, &parts)
	for part in parts {
		if own := type_own_equality(c, part); own != INVALID_SYMBOL {
			prov_effect_call(graph, Effect_Call{callee = own}, span)
		}
	}
}

// design.md "Program entry and exit": a fallible `main`'s failure is printed
// after its cleanup, while what the result borrows is still in use, so each
// return from it reaches every `format` printing does. design.md "Test
// procedures": so does a test build's from a fallible test.
prov_entry_report_effects :: proc(graph: ^Flow_Graph, span: Span) {
	c := graph.k.c
	if graph.literal == nil {
		return
	}
	sym := symbol_of(c, graph.literal.symbol)
	if sym == nil {
		return
	}
	described := "modified by printing a failure `main` returns"
	switch c.build_mode {
	case .Exe:
		// The entry point is validated after this pass, so it is found by name.
		if sym.has_receiver || identifier_text(c, sym.name) != "main" {
			return
		}
		if pkg := package_of(c, sym.pkg); pkg == nil || identifier_text(c, pkg.name) != "main" {
			return
		}
	case .Test:
		if !sym.is_test || sym.pkg != c.root_package {
			return
		}
		described = "modified by printing a failure a test returns"
	case .Obj:
		return
	}
	if _, fallible := entry_failure_type(c, sym.result); !fallible {
		return
	}
	view, found := c.runtime_types["Format_View"]
	if !found {
		return
	}
	prov_effect_call(
		graph, Effect_Call{dyn_interface = underlying_info(c, view).dyn_interface}, span,
		described = described,
	)
}

// A built-in `==` or `!=` compares structurally, and `in` looks a key up in a
// map.
prov_operator_effects :: proc(graph: ^Flow_Graph, v: ^Expr_Binary) {
	#partial switch v.op {
	case .Eq_Eq, .Not_Eq:
		prov_equality_effects(graph, expr_base(v.lhs).type, v.span)
	case .In:
		if container := expr_base(v.rhs).type; underlying_kind(graph.k.c, container) == .Map {
			prov_key_effects(graph, container, v.span)
		}
	}
}

// A map operation on a key hashes it and compares it with the keys stored.
prov_key_effects :: proc(graph: ^Flow_Graph, map_type: Type_Id, span: Span) {
	key := container_key(graph.k.c, map_type)
	if key == INVALID_TYPE {
		return
	}
	prov_hash_effects(graph, key, span)
	prov_equality_effects(graph, key, span)
}

// design.md "Global write effects": a named procedure passed for a
// `@(cross_thread)` parameter runs on another thread, as an entry or as the
// value an entry calls, so it is kept until the effects settle.
@(private = "file")
note_thread_spawn :: proc(graph: ^Flow_Graph, v: ^Expr_Call) {
	c := graph.k.c
	proc_type := call_proc_type(c, v)
	info := underlying_info(c, proc_type)
	if info == nil || len(info.param_cross_thread) == 0 {
		return
	}
	for argument, index in v.bound {
		if argument == nil || !proc_param_crosses_thread(c, proc_type, index) {
			continue
		}
		entry := INVALID_SYMBOL
		#partial switch e in argument {
		case ^Expr_Ident:
			entry = e.symbol
		case ^Expr_Selector:
			entry = e.resolution.symbol
		}
		if entry_sym := symbol_of(c, entry); entry_sym != nil && entry_sym.kind == .Proc {
			append(&graph.thread_spawns, Thread_Spawn{entry = entry, span = v.span})
		}
	}
}

// A spawned entry that writes a global every thread shares races with any other
// thread that reaches it. `thread_local` storage is the thread's own, an atomic
// operation reads its receiver, and a `@(synchronized)` variable's package
// vouches for every access to it, so none is a write here. A procedure value the
// entry received runs what its caller passed, which is reported where that
// crossing call passes it, so the entry is not blamed for calling it, directly,
// through a local it copied the value to, or through helpers it hands the value
// to (`callback_effects`).
@(private = "file")
warn_thread_races :: proc(c: ^Compiler, bodies: []Body_Effects, callers: [][dynamic]int) {
	if len(c.thread_spawns) == 0 {
		return
	}
	own := callback_effects(c, bodies, callers)
	for spawn in c.thread_spawns {
		index, found := c.effect_program.index_of[spawn.entry]
		if !found {
			continue
		}
		for global in own[index].writes {
			sym := symbol_of(c, global)
			if sym == nil || sym.duration == .Thread_Local || sym.synchronized {
				continue
			}
			warnf(
				c, spawn.span, "L0707",
				"`%s` writes `%s`, which every thread shares, so this thread may race with another",
				identifier_text(c, symbol_of(c, spawn.entry).name), identifier_text(c, sym.name),
			)
			add_notef(c, sym.span, "declared here; make it `thread_local`, an `Atomic`, or a `thread.Mutex`")
		}
	}
}

// One body's writes apart from the procedure values it received, and which of
// its parameters it may call: those values run whatever each caller passes.
@(private = "file")
Callback_Effects :: struct {
	writes: [dynamic]Symbol_Id,
	called: [dynamic]int,
}

// Settled over the whole program, as the write effects are. A call through a
// variable contributes what each value it may hold runs (`add_callback_value`).
// A direct call contributes its callee's own writes, and for each parameter the
// callee calls, what the arguments bound there run, or every procedure of the
// parameter's type when none was followed. Other calls contribute everything
// they may reach.
@(private = "file")
callback_effects :: proc(c: ^Compiler, bodies: []Body_Effects, callers: [][dynamic]int) -> []Callback_Effects {
	program := &c.effect_program
	out := make([]Callback_Effects, len(bodies), context.temp_allocator)
	for &entry, index in out {
		entry.writes = make([dynamic]Symbol_Id, 0, bodies[index].direct, context.temp_allocator)
		append(&entry.writes, ..bodies[index].writes[:bodies[index].direct])
		entry.called = make([dynamic]int, context.temp_allocator)
	}
	queued := make([]bool, len(bodies), context.temp_allocator)
	pending := make([dynamic]int, 0, len(bodies), context.temp_allocator)
	for index := len(bodies) - 1; index >= 0; index -= 1 {
		append(&pending, index)
		queued[index] = true
	}
	for len(pending) > 0 {
		index := pop(&pending)
		queued[index] = false
		grew := false
		for call in bodies[index].calls {
			if call.variable != INVALID_SYMBOL {
				for value in call.through {
					grew |= add_callback_value(c, &out[index], value, call.type, bodies)
				}
				continue
			}
			target, direct := program.index_of[call.callee]
			if call.callee == INVALID_SYMBOL || !direct {
				for reached in effect_targets(c, call, program) {
					for global in bodies[reached].writes {
						grew |= add_global_write(&out[index].writes, global)
					}
				}
				continue
			}
			for global in out[target].writes {
				grew |= add_global_write(&out[index].writes, global)
			}
			for parameter in out[target].called {
				type := proc_parameter_type(c, bodies[target].type, parameter)
				bound := false
				for arg in call.args {
					if arg.binding == parameter {
						bound = true
						grew |= add_callback_value(c, &out[index], arg, type, bodies)
					}
				}
				if !bound {
					grew |= add_callback_value(c, &out[index], Effect_Arg{}, type, bodies)
				}
			}
		}
		if !grew {
			continue
		}
		for caller in callers[index] {
			if !queued[caller] {
				queued[caller] = true
				append(&pending, caller)
			}
		}
	}
	return out
}

// What running `value` adds to a body: nothing yet for what its own caller
// passed, which joins `called`; a named procedure's whole effect; and anything
// else, every procedure of its type.
@(private = "file")
add_callback_value :: proc(c: ^Compiler, out: ^Callback_Effects, value: Effect_Arg, type: Type_Id, bodies: []Body_Effects) -> bool {
	grew := false
	#partial switch value.kind {
	case .Parameter:
		grew = add_index(&out.called, value.parameter)
	case .Procedure:
		for global in c.global_writes[value.symbol] {
			grew |= add_global_write(&out.writes, global)
		}
	case .Other:
		for reached in effect_targets(c, Effect_Call{type = type}, &c.effect_program) {
			for global in bodies[reached].writes {
				grew |= add_global_write(&out.writes, global)
			}
		}
	}
	return grew
}

@(private = "file")
proc_parameter_type :: proc(c: ^Compiler, proc_type: Type_Id, index: int) -> Type_Id {
	info := underlying_info(c, proc_type)
	if info == nil || index >= len(info.parameters) {
		return INVALID_TYPE
	}
	return info.parameters[index]
}

@(private = "file")
add_index :: proc(list: ^[dynamic]int, value: int) -> bool {
	for existing in list {
		if existing == value {
			return false
		}
	}
	append(list, value)
	return true
}

// Dropping a value runs its `hook(drop)`s, which write what a call of each
// would. `dropped` names the value, as source text unless it is `unnamed`.
// While the thread summaries collect, `region` is the value's when known
// (`prov_drop_region`): releasing an owner frees in it, and a hook is given it.
prov_drop_effects :: proc(
	graph: ^Flow_Graph, type: Type_Id, span: Span, dropped := "", unnamed := false, region: Maybe(Region_Set) = nil,
) {
	regions: []Region_Set
	if set, known := region.?; known {
		if type_owns_allocation(graph.k.c, type) {
			prov_note_allocator_use(graph, set, span, owned = true)
		}
		regions = make([]Region_Set, 1, graph.alloc)
		regions[0] = prov_caller_region(graph, set)
	}
	for hook in type_drop_hooks(graph.k.c, type) {
		prov_effect_call(graph, Effect_Call{callee = hook, regions = regions}, span, dropped, unnamed = unnamed)
	}
}

// A value nothing binds, an expression statement's or `_ = value`'s, is
// dropped where it is discarded.
prov_discarded_drop_effects :: proc(graph: ^Flow_Graph, expr: Expr) {
	if graph.mode == .Lifecycle || expr == nil || expression_is_borrowed_place(expr) {
		return
	}
	if base := expr_base(expr); base != nil && base.type != INVALID_TYPE && base.type != TYPE_VOID {
		prov_drop_effects(graph, base.type, expr_span(expr), region = prov_drop_region(graph, expr))
	}
}

// `clear` and a `resize` that may shrink drop the elements they discard; `pop` and
// `remove` hand theirs back.
@(private = "file")
ELEMENT_DROPPING_OPS :: bit_set[Container_Op]{.Clear, .Resize, .Map_Clear}

prov_container_drop_effects :: proc(graph: ^Flow_Graph, v: ^Expr_Call) {
	sym := symbol_of(graph.k.c, v.resolution.chosen_overload)
	if graph.mode == .Lifecycle || sym == nil || sym.synth != .Container_Op || len(v.bound) == 0 ||
	   sym.container_op not_in ELEMENT_DROPPING_OPS {
		return
	}
	prov_drop_effects(graph, expr_base(v.bound[0]).type, v.span)
}

// A local's scope exit drops it only where the lifecycle pass found it may
// still be live there; a moved-out local runs no hook.
prov_scope_drop_effects :: proc(graph: ^Flow_Graph, id: Symbol_Id, span: Span) {
	if sym := symbol_of(graph.k.c, id); sym != nil && sym.drop_at_exit {
		prov_drop_effects(graph, sym.type, span, identifier_text(graph.k.c, sym.name), region = prov_symbol_drop_region(graph, id))
	}
}

@(private = "file")
prov_effect_call :: proc(graph: ^Flow_Graph, target: Effect_Call, span: Span, dropped := "", described := "", unnamed := false) {
	c := graph.k.c
	if !c.global_writes_ready || c.thread_facts_pending {
		recorded := target
		recorded.span = span
		append(&graph.effect_calls, recorded)
	}
	if !c.global_writes_ready {
		return
	}
	name := ""
	if described != "" {
		name = described
	} else if sym := symbol_of(c, target.callee); sym != nil && dropped != "" && unnamed {
		name = fmt.tprintf("modified by `%s` when %s is dropped", identifier_text(c, sym.name), dropped)
	} else if sym != nil && dropped != "" {
		name = fmt.tprintf("modified by `%s` when `%s` is dropped", identifier_text(c, sym.name), dropped)
	} else if sym != nil {
		name = fmt.tprintf("modified by `%s`", identifier_text(c, sym.name))
	} else {
		name = "modified by a procedure this call may reach"
	}
	for global in effect_call_writes(c, target) {
		root := prov_root_for_symbol(graph, global)
		prov_access(graph, root, nil, .Invalidate, span, name)
	}
}

// The settled writes of one call target.
@(private = "file")
effect_call_writes :: proc(c: ^Compiler, target: Effect_Call) -> []Symbol_Id {
	if target.callee != INVALID_SYMBOL {
		return c.global_writes[target.callee]
	}
	return c.indirect_writes[effect_key(target, context.temp_allocator)]
}

// An indirect target's key: a `dyn` slot, or a procedure type.
@(private = "file")
effect_key :: proc(target: Effect_Call, allocator: mem.Allocator) -> string {
	if target.dyn_interface != INVALID_SYMBOL {
		return fmt.aprintf("d%d.%d.t%d", int(target.dyn_interface), target.dyn_index, int(target.type), allocator = allocator)
	}
	return fmt.aprintf("t%d", int(target.type), allocator = allocator)
}

// Every clean body's own writes and calls, then the fixed point: a body writes
// what it writes itself and what anything it may call writes. An indirect call
// may reach every body of a compatible type that is used as a value, and a
// `dyn` slot every witness target for it; both are keyed and settled with the
// rest.
compute_global_writes :: proc(k: ^Checker) {
	c := k.c
	c.global_writes = make(map[Symbol_Id][]Symbol_Id, c.semantic_allocator)
	c.indirect_writes = make(map[string][]Symbol_Id, c.semantic_allocator)
	// Kept for the thread summaries, which settle over the same calls.
	program := &c.effect_program
	program.used_as_value = make(map[Symbol_Id]bool, 16, c.semantic_allocator)
	bodies := make([dynamic]Body_Effects, 0, len(c.checked_bodies), context.temp_allocator)
	for body in c.checked_bodies {
		if !body.clean {
			continue
		}
		graph := build_flow_graph(k, body.literal, .Prov_Summary)
		effects := Body_Effects{symbol = body.literal.symbol}
		if sym := symbol_of(c, body.literal.symbol); sym != nil {
			effects.type = sym.proc_type
		}
		effects.writes = make([dynamic]Symbol_Id, 0, len(graph.effect_writes), context.temp_allocator)
		append(&effects.writes, ..graph.effect_writes[:])
		effects.direct = len(effects.writes)
		effects.calls = make([]Effect_Call, len(graph.effect_calls), context.temp_allocator)
		copy(effects.calls, graph.effect_calls[:])
		// The graph's storage is reset below.
		for &call in effects.calls {
			if call.variable != INVALID_SYMBOL {
				call.through = effect_variable_values(c, graph.effect_stores[:], call.variable)
			}
			if len(call.args) > 0 {
				call.args = effect_resolved_args(c, graph.effect_stores[:], call.args)
			}
		}
		for id in graph.effect_values {
			program.used_as_value[id] = true
		}
		if len(graph.thread_spawns) > 0 {
			if c.thread_spawns == nil {
				c.thread_spawns = make([dynamic]Thread_Spawn, 0, 4, c.semantic_allocator)
			}
			append(&c.thread_spawns, ..graph.thread_spawns[:])
		}
		append(&bodies, effects)
		free_all(c.analysis_allocator)
	}
	program.bodies = make([]Effect_Body, len(bodies), c.semantic_allocator)
	program.index_of = make(map[Symbol_Id]int, len(bodies), c.semantic_allocator)
	for body, index in bodies {
		program.bodies[index] = Effect_Body{symbol = body.symbol, type = body.type}
		program.index_of[body.symbol] = index
	}
	for &body in bodies {
		body.targets = make([dynamic]int, 0, len(body.calls), context.temp_allocator)
		for call in body.calls {
			append(&body.targets, ..effect_targets(c, call, program))
		}
	}
	// A body's set grows only when a callee's does, so only the callers of a
	// body that grew are visited again.
	callers := make([][dynamic]int, len(bodies), context.temp_allocator)
	for &list in callers {
		list = make([dynamic]int, context.temp_allocator)
	}
	for body, index in bodies {
		for target in body.targets {
			append(&callers[target], index)
		}
	}
	queued := make([]bool, len(bodies), context.temp_allocator)
	pending := make([dynamic]int, 0, len(bodies), context.temp_allocator)
	for index := len(bodies) - 1; index >= 0; index -= 1 {
		append(&pending, index)
		queued[index] = true
	}
	for len(pending) > 0 {
		index := pop(&pending)
		queued[index] = false
		grew := false
		for target in bodies[index].targets {
			for global in bodies[target].writes {
				grew |= add_global_write(&bodies[index].writes, global)
			}
		}
		if !grew {
			continue
		}
		for caller in callers[index] {
			if !queued[caller] {
				queued[caller] = true
				append(&pending, caller)
			}
		}
	}
	for body in bodies {
		if len(body.writes) > 0 {
			c.global_writes[body.symbol] = clone_symbols(c, body.writes[:])
		}
	}
	// What an indirect call reaches is keyed once for the provenance pass.
	for body in bodies {
		for call in body.calls {
			if call.callee != INVALID_SYMBOL {
				continue
			}
			key := effect_key(call, c.semantic_allocator)
			if key in c.indirect_writes {
				continue
			}
			writes := make([dynamic]Symbol_Id, 0, 4, context.temp_allocator)
			for target in effect_targets(c, call, program) {
				for global in bodies[target].writes {
					add_global_write(&writes, global)
				}
			}
			c.indirect_writes[key] = clone_symbols(c, writes[:])
		}
	}
	c.global_writes_ready = true
	warn_thread_races(c, bodies[:], callers)
	reject_copy_hook_writes(c)
}

// design.md "Lifecycle hooks and resource types": how many copies run is
// unspecified, so a copy hook writes no global. Reported once per declaration,
// not per generic instance.
@(private = "file")
reject_copy_hook_writes :: proc(c: ^Compiler) {
	reported := make(map[Span]bool, context.temp_allocator)
	for body in c.checked_bodies {
		sym := symbol_of(c, body.literal.symbol)
		writes := c.global_writes[body.literal.symbol]
		if sym == nil || sym.hook != .Copy || len(writes) == 0 || reported[sym.span] {
			continue
		}
		reported[sym.span] = true
		global := symbol_of(c, writes[0])
		errorf(
			c, sym.span, "L0711",
			"`%s` is a copy hook and may not write `%s`: how many copies run is unspecified",
			identifier_text(c, sym.name), identifier_text(c, global.name),
		)
		add_notef(c, global.span, "declared here; a count kept by copies can be a `sync.Atomic`, whose updates are not writes")
	}
}

// The bodies one call may run.
@(private = "file")
effect_targets :: proc(c: ^Compiler, call: Effect_Call, program: ^Effect_Program, seen: ^map[string]bool = nil) -> []int {
	bodies, index_of, used_as_value := program.bodies, program.index_of, program.used_as_value
	out := make([dynamic]int, 0, 4, context.temp_allocator)
	visited := seen
	if visited == nil {
		visited = new(map[string]bool, context.temp_allocator)
		visited^ = make(map[string]bool, context.temp_allocator)
	}
	// A view of itself would otherwise recurse.
	key := effect_key(call, context.temp_allocator)
	if key in visited^ {
		return nil
	}
	visited^[key] = true
	switch {
	case call.callee != INVALID_SYMBOL:
		if index, found := index_of[call.callee]; found {
			append(&out, index)
		}
	case call.dyn_interface != INVALID_SYMBOL:
		for witness in c.witness_order {
			if witness.interface_symbol != call.dyn_interface || call.dyn_index >= len(witness.slots) {
				continue
			}
			// A callable view's witnesses are per signature.
			if call.type != INVALID_TYPE && (len(witness.args) == 0 || witness.args[0].type != call.type) {
				continue
			}
			target := witness.slots[call.dyn_index].target
			if index, found := index_of[target]; found {
				append(&out, index)
			}
			// A view of a view runs what the inner view may run.
			if sym := symbol_of(c, target); sym != nil {
				if inner, is_forward := forwarding_effect(c, sym); is_forward {
					append(&out, ..effect_targets(c, inner, program, visited))
				}
			}
		}
		// design.md "Borrowed callable views": or a procedure the view holds.
		if call.type != INVALID_TYPE {
			for body, index in bodies {
				if used_as_value[body.symbol] && assignable(c, body.type, call.type) {
					append(&out, index)
				}
			}
		}
		// design.md "String format printing": the witness erased printing
		// recovers for each printed type is built after this pass, so the slot
		// may reach any `format` method.
		if view, found := c.runtime_types["Format_View"]; found && call.dyn_interface == underlying_info(c, view).dyn_interface {
			for body, index in bodies {
				if sym := symbol_of(c, body.symbol); sym != nil && sym.has_receiver && identifier_text(c, sym.name) == "format" {
					append(&out, index)
				}
			}
		}
	case:
		for body, index in bodies {
			if used_as_value[body.symbol] && assignable(c, body.type, call.type) {
				append(&out, index)
			}
		}
	}
	return out[:]
}

@(private = "file")
add_global_write :: proc(writes: ^[dynamic]Symbol_Id, global: Symbol_Id) -> bool {
	for existing in writes {
		if existing == global {
			return false
		}
	}
	append(writes, global)
	return true
}

@(private = "file")
clone_symbols :: proc(c: ^Compiler, symbols: []Symbol_Id) -> []Symbol_Id {
	out := make([]Symbol_Id, len(symbols), c.semantic_allocator)
	copy(out, symbols)
	return out
}

// ------------------------------------------------------- thread summaries --

// concurrency-proposal.md "The summaries the checks read": where one part of a
// summary comes from. `via` is INVALID_SYMBOL for the body's own access at
// `span`; otherwise `span` is the call, hook run, or drop that reaches `via`,
// whose own summary says where it got it, so a diagnostic can follow the chain.
// `precision` is the provenance merge that may have widened the access.
Effect_Source :: struct {
	via:       Symbol_Id,
	span:      Span,
	precision: Precision_Loss,
}

// A global whose stored carriers a body may dereference, index, slice, call,
// or dispatch through, read or written: the reach effect. Handing such a
// carrier to a call, returning it, or storing it counts too, since what
// receives it may reach through it.
Global_Effect :: struct {
	global: Symbol_Id,
	source: Effect_Source,
}

// A `thread_local` owner every thread drops when it exits, and what that drop
// does: the owner's own release (`hook` INVALID_SYMBOL), or one of its hooks.
// Every task carries all of them (concurrency-proposal.md check 6).
Thread_Exit_Drop :: struct {
	variable: Symbol_Id,
	hook:     Symbol_Id,
	writes:   []Symbol_Id,
	reach:    []Global_Effect,
	use:      Allocator_Use,
}

// Whether a call's effects come from bodies the effects settle over: a direct
// callee with a body, or any call through a value or a `dyn` slot.
call_follows_bodies :: proc(c: ^Compiler, v: ^Expr_Call) -> bool {
	target, ok := call_effect(c, v)
	if !ok {
		return false
	}
	return target.callee == INVALID_SYMBOL || target.callee in c.effect_program.index_of
}

// One body's own thread facts, and the bodies each of its calls may run.
@(private = "file")
Thread_Body :: struct {
	reach:   [dynamic]Global_Effect,
	use:     Allocator_Use,
	calls:   []Effect_Call,
	targets: [][]int,
}

// Each clean body's graph is built once more, with the result summaries
// settled, recording its own reach and allocator use and its calls; then both
// settle over the calls as the write effects do. A call through a value or a
// `dyn` slot reaches every body the write effects found for it.
compute_thread_summaries :: proc(k: ^Checker) {
	c := k.c
	program := &c.effect_program
	c.reach_effects = make(map[Symbol_Id][]Global_Effect, c.semantic_allocator)
	c.allocator_uses = make(map[Symbol_Id]Allocator_Use, c.semantic_allocator)
	facts := make([]Thread_Body, len(program.bodies), context.temp_allocator)
	for &body, index in facts {
		body.reach = make([dynamic]Global_Effect, context.temp_allocator)
		count := 0
		if sym := symbol_of(c, program.bodies[index].symbol); sym != nil {
			count = len(sym.param_symbols)
		}
		body.use = new_allocator_use(count, context.temp_allocator)
	}
	c.thread_facts_pending = true
	for body in c.checked_bodies {
		index, found := program.index_of[body.literal.symbol]
		if !body.clean || !found {
			continue
		}
		graph := build_flow_graph(k, body.literal, .Prov_Summary)
		if graph == nil {
			free_all(c.analysis_allocator)
			continue
		}
		own := &facts[index]
		if graph.allocator_use.regions.params != nil {
			resize_allocator_use(&own.use, graph.param_count)
			merge_allocator_use_from(&own.use, graph.allocator_use)
		}
		own.calls = make([]Effect_Call, len(graph.effect_calls), context.temp_allocator)
		own.targets = make([][]int, len(graph.effect_calls), context.temp_allocator)
		for call, position in graph.effect_calls {
			kept := call
			kept.args, kept.through = nil, nil
			kept.regions = clone_regions(call.regions, context.temp_allocator)
			own.calls[position] = kept
			targets := effect_targets(c, kept, program)
			own.targets[position] = make([]int, len(targets), context.temp_allocator)
			copy(own.targets[position], targets)
		}
		// Solved last: the solve's storage is the graph's.
		body_global_reach(k, graph, &own.reach)
		free_all(c.analysis_allocator)
	}
	c.thread_facts_pending = false

	callers := make([][dynamic]int, len(facts), context.temp_allocator)
	for &list in callers {
		list = make([dynamic]int, context.temp_allocator)
	}
	for body, index in facts {
		for targets in body.targets {
			for target in targets {
				append(&callers[target], index)
			}
		}
	}
	queued := make([]bool, len(facts), context.temp_allocator)
	pending := make([dynamic]int, 0, len(facts), context.temp_allocator)
	for index := len(facts) - 1; index >= 0; index -= 1 {
		append(&pending, index)
		queued[index] = true
	}
	for len(pending) > 0 {
		index := pop(&pending)
		queued[index] = false
		grew := false
		for call, position in facts[index].calls {
			for target in facts[index].targets[position] {
				via := program.bodies[target].symbol
				for reached in facts[target].reach {
					source := Effect_Source{via = via, span = call.span, precision = reached.source.precision}
					grew |= add_global_effect(&facts[index].reach, reached.global, source)
				}
				grew |= substitute_allocator_use(&facts[index].use, facts[target].use, call, via == call.callee, via)
			}
		}
		if !grew {
			continue
		}
		for caller in callers[index] {
			if !queued[caller] {
				queued[caller] = true
				append(&pending, caller)
			}
		}
	}
	for body, index in facts {
		symbol := program.bodies[index].symbol
		if len(body.reach) > 0 {
			reach := make([]Global_Effect, len(body.reach), c.semantic_allocator)
			copy(reach, body.reach[:])
			c.reach_effects[symbol] = reach
		}
		if !allocator_use_is_empty(body.use) {
			c.allocator_uses[symbol] = clone_allocator_use(body.use, c.semantic_allocator)
		}
	}
	collect_thread_exit_drops(c)
}

// What a callee's allocator use is at its call: its default and unknown
// regions as they are, and each parameter's as the region of the argument
// bound there. A call through a value or a `dyn` slot may bind any argument to
// any parameter of the target, and a call with no argument regions, as a
// hook's on a value whose region was not known, binds an unknown one.
@(private = "file")
substitute_allocator_use :: proc(into: ^Allocator_Use, from: Allocator_Use, call: Effect_Call, direct: bool, via: Symbol_Id) -> bool {
	if allocator_use_is_empty(from) {
		return false
	}
	source := Effect_Source{via = via, span = call.span}
	grew := false
	if from.regions.default {
		grew |= merge_allocator_use(into, Region_Set{default = true}, source)
	}
	if from.regions.unknown {
		grew |= merge_allocator_use(into, Region_Set{unknown = true}, source)
	}
	for wanted, parameter in from.regions.params {
		if !wanted {
			continue
		}
		switch {
		case call.regions == nil:
			grew |= merge_allocator_use(into, Region_Set{unknown = true}, source)
		case direct:
			if parameter < len(call.regions) {
				grew |= merge_allocator_use(into, call.regions[parameter], source)
			}
		case:
			for set in call.regions {
				grew |= merge_allocator_use(into, set, source)
			}
		}
	}
	return grew
}

// design.md "Owners and `drop`": a thread's exit drops each `thread_local`
// owner, as a task's completion does under thread-per-spawn. What the release
// and each hook do comes from the settled summaries; a hook's parameter is
// the owner, in the region its `via` names, or else the default provider's.
@(private = "file")
collect_thread_exit_drops :: proc(c: ^Compiler) {
	drops := make([dynamic]Thread_Exit_Drop, 0, 4, c.semantic_allocator)
	for sym, index in c.symbols {
		if sym == nil || sym.kind != .Var || sym.duration != .Thread_Local {
			continue
		}
		hooks := type_drop_hooks(c, sym.type)
		owns := type_owns_allocation(c, sym.type)
		if !owns && len(hooks) == 0 {
			continue
		}
		owner := Region_Set{default = sym.via == nil, unknown = sym.via != nil}
		variable := Symbol_Id(index)
		if owns {
			use := new_allocator_use(0, c.semantic_allocator)
			merge_allocator_use(&use, owner, Effect_Source{span = sym.span})
			append(&drops, Thread_Exit_Drop{variable = variable, use = use})
		}
		for hook in hooks {
			drop := Thread_Exit_Drop{variable = variable, hook = hook, writes = c.global_writes[hook]}
			reach := make([dynamic]Global_Effect, 0, len(c.reach_effects[hook]), c.semantic_allocator)
			for reached in c.reach_effects[hook] {
				append(&reach, Global_Effect{global = reached.global, source = Effect_Source{via = hook, span = sym.span}})
			}
			drop.reach = reach[:]
			drop.use = new_allocator_use(0, c.semantic_allocator)
			if from, found := c.allocator_uses[hook]; found {
				regions := make([]Region_Set, 1, context.temp_allocator)
				regions[0] = owner
				call := Effect_Call{callee = hook, span = sym.span, regions = regions}
				substitute_allocator_use(&drop.use, from, call, true, hook)
			}
			append(&drops, drop)
		}
	}
	c.thread_exit_drops = drops[:]
}

@(private = "file")
add_global_effect :: proc(list: ^[dynamic]Global_Effect, global: Symbol_Id, source: Effect_Source) -> bool {
	for existing in list {
		if existing.global == global {
			return false
		}
	}
	append(list, Global_Effect{global = global, source = source})
	return true
}

@(private = "file")
clone_regions :: proc(regions: []Region_Set, allocator: mem.Allocator) -> []Region_Set {
	if regions == nil {
		return nil
	}
	out := make([]Region_Set, len(regions), allocator)
	for set, index in regions {
		out[index] = set
		out[index].params = nil
		if set.params != nil {
			out[index].params = make([]bool, len(set.params), allocator)
			copy(out[index].params, set.params)
		}
	}
	return out
}

@(private = "file")
clone_allocator_use :: proc(use: Allocator_Use, allocator: mem.Allocator) -> Allocator_Use {
	out := new_allocator_use(len(use.regions.params), allocator)
	copy(out.regions.params, use.regions.params)
	copy(out.param_sources, use.param_sources)
	out.regions.default, out.regions.unknown = use.regions.default, use.regions.unknown
	out.default_source, out.unknown_source = use.default_source, use.unknown_source
	return out
}

// Grows a body's parameter rows to what its graph counts.
@(private = "file")
resize_allocator_use :: proc(use: ^Allocator_Use, count: int) {
	if count <= len(use.regions.params) {
		return
	}
	grown := new_allocator_use(count, context.temp_allocator)
	merge_allocator_use_from(&grown, use^)
	use^ = grown
}

// Adds `from`'s parts new to `into`, each keeping its own source.
@(private = "file")
merge_allocator_use_from :: proc(into: ^Allocator_Use, from: Allocator_Use) {
	for wanted, index in from.regions.params {
		if wanted && index < len(into.regions.params) && !into.regions.params[index] {
			into.regions.params[index] = true
			into.param_sources[index] = from.param_sources[index]
		}
	}
	if from.regions.default && !into.regions.default {
		into.regions.default = true
		into.default_source = from.default_source
	}
	if from.regions.unknown && !into.regions.unknown {
		into.regions.unknown = true
		into.unknown_source = from.unknown_source
	}
}

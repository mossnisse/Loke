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
	// Through a procedure value the body received as its parameter `parameter`:
	// what it runs is whatever the caller passed.
	through_parameter: bool,
	parameter:         int,
	// A direct call's arguments, by parameter, for following a procedure value
	// the body hands on to its callee.
	args:              []Effect_Arg,
}

// Where a direct call's argument comes from, when it may be a procedure value.
Effect_Arg :: struct {
	kind:      Effect_Arg_Kind,
	parameter: int,       // `.Parameter`: the calling body's own parameter
	procedure: Symbol_Id, // `.Procedure`: a named procedure
}

Effect_Arg_Kind :: enum u8 {
	Other,
	Parameter,
	Procedure,
}

// A call passing a named procedure for a `@(cross_thread)` parameter, and that
// procedure.
Thread_Spawn :: struct {
	entry: Symbol_Id,
	span:  Span,
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
		if ident, is_ident := v.callee.(^Expr_Ident); is_ident {
			if callee := symbol_of(c, ident.symbol); callee != nil && callee.kind == .Parameter {
				call.through_parameter, call.parameter = true, int(callee.index)
			}
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
	prov_effect_call(graph, target, v.span)
}

// Each argument that is a procedure value the body received, or a named
// procedure, by the callee's parameter it binds.
@(private = "file")
effect_args :: proc(c: ^Compiler, v: ^Expr_Call, allocator: mem.Allocator) -> []Effect_Arg {
	args := make([]Effect_Arg, len(v.bound), allocator)
	for argument, index in v.bound {
		value := argument
		if moved, is_move := value.(^Expr_Move); is_move {
			value = moved.value
		}
		id := INVALID_SYMBOL
		#partial switch e in value {
		case ^Expr_Ident:
			id = e.symbol
		case ^Expr_Selector:
			id = e.resolution.symbol
		}
		sym := symbol_of(c, id)
		if sym == nil || underlying_kind(c, expr_base(value).type) != .Proc {
			continue
		}
		#partial switch sym.kind {
		case .Parameter:
			args[index] = Effect_Arg{kind = .Parameter, parameter = int(sym.index)}
		case .Proc:
			args[index] = Effect_Arg{kind = .Procedure, procedure = id}
		}
	}
	return args
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
// crossing call passes it, so the entry is not blamed for calling it, directly
// or through helpers it hands the value to (`callback_effects`).
@(private = "file")
warn_thread_races :: proc(
	c: ^Compiler,
	bodies: []Body_Effects,
	index_of: map[Symbol_Id]int,
	used_as_value: map[Symbol_Id]bool,
	callers: [][dynamic]int,
) {
	if len(c.thread_spawns) == 0 {
		return
	}
	own := callback_effects(c, bodies, index_of, used_as_value, callers)
	for spawn in c.thread_spawns {
		index, found := index_of[spawn.entry]
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

// Settled over the whole program, as the write effects are. A direct call
// contributes its callee's own writes, and for each parameter the callee calls,
// what the argument there runs: nothing yet if it is this body's own received
// value, which joins `called`; a named procedure's whole effect; and otherwise
// every procedure of the parameter's type. Other calls contribute everything
// they may reach.
@(private = "file")
callback_effects :: proc(
	c: ^Compiler,
	bodies: []Body_Effects,
	index_of: map[Symbol_Id]int,
	used_as_value: map[Symbol_Id]bool,
	callers: [][dynamic]int,
) -> []Callback_Effects {
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
			if call.through_parameter {
				grew |= add_index(&out[index].called, call.parameter)
				continue
			}
			target, direct := index_of[call.callee]
			if call.callee == INVALID_SYMBOL || !direct {
				for reached in effect_targets(c, call, bodies, index_of, used_as_value) {
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
				arg := parameter < len(call.args) ? call.args[parameter] : Effect_Arg{}
				switch arg.kind {
				case .Parameter:
					grew |= add_index(&out[index].called, arg.parameter)
				case .Procedure:
					for global in c.global_writes[arg.procedure] {
						grew |= add_global_write(&out[index].writes, global)
					}
				case .Other:
					any_of_type := Effect_Call{type = proc_parameter_type(c, bodies[target].type, parameter)}
					for reached in effect_targets(c, any_of_type, bodies, index_of, used_as_value) {
						for global in bodies[reached].writes {
							grew |= add_global_write(&out[index].writes, global)
						}
					}
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
prov_drop_effects :: proc(graph: ^Flow_Graph, type: Type_Id, span: Span, dropped := "", unnamed := false) {
	for hook in type_drop_hooks(graph.k.c, type) {
		prov_effect_call(graph, Effect_Call{callee = hook}, span, dropped, unnamed = unnamed)
	}
}

// A value nothing binds, an expression statement's or `_ = value`'s, is
// dropped where it is discarded.
prov_discarded_drop_effects :: proc(graph: ^Flow_Graph, expr: Expr) {
	if graph.mode == .Lifecycle || expr == nil || expression_is_borrowed_place(expr) {
		return
	}
	if base := expr_base(expr); base != nil && base.type != INVALID_TYPE && base.type != TYPE_VOID {
		prov_drop_effects(graph, base.type, expr_span(expr))
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
		prov_drop_effects(graph, sym.type, span, identifier_text(graph.k.c, sym.name))
	}
}

@(private = "file")
prov_effect_call :: proc(graph: ^Flow_Graph, target: Effect_Call, span: Span, dropped := "", described := "", unnamed := false) {
	c := graph.k.c
	if !c.global_writes_ready {
		append(&graph.effect_calls, target)
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
	used_as_value := make(map[Symbol_Id]bool, 16, context.temp_allocator)
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
			if len(call.args) > 0 {
				args := make([]Effect_Arg, len(call.args), context.temp_allocator)
				copy(args, call.args)
				call.args = args
			}
		}
		for id in graph.effect_values {
			used_as_value[id] = true
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
	index_of := make(map[Symbol_Id]int, len(bodies), context.temp_allocator)
	for body, index in bodies {
		index_of[body.symbol] = index
	}
	for &body in bodies {
		body.targets = make([dynamic]int, 0, len(body.calls), context.temp_allocator)
		for call in body.calls {
			append(&body.targets, ..effect_targets(c, call, bodies[:], index_of, used_as_value))
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
			for target in effect_targets(c, call, bodies[:], index_of, used_as_value) {
				for global in bodies[target].writes {
					add_global_write(&writes, global)
				}
			}
			c.indirect_writes[key] = clone_symbols(c, writes[:])
		}
	}
	c.global_writes_ready = true
	warn_thread_races(c, bodies[:], index_of, used_as_value, callers)
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
effect_targets :: proc(
	c: ^Compiler,
	call: Effect_Call,
	bodies: []Body_Effects,
	index_of: map[Symbol_Id]int,
	used_as_value: map[Symbol_Id]bool,
	seen: ^map[string]bool = nil,
) -> []int {
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
					append(&out, ..effect_targets(c, inner, bodies, index_of, used_as_value, visited))
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

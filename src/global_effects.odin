package lokec

import "core:fmt"
import "core:mem"
import "core:slice"

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
	// `variable`, whose values the write effects resolve
	// (`Compiler.called_values`), or the procedure a callable view converted at
	// the call holds.
	variable:      Symbol_Id,
	held:          Symbol_Id,
	// A direct call's arguments that may be followed, each with the callee
	// parameter it binds; one missing there may be any procedure of its type.
	// Kept only until the body is summarized (`Compiler.argument_values`).
	args:          []Effect_Arg,
	// A task's call on its worker: its values are those the `spawn` in this
	// procedure resolved, where none of its parameters are `run`'s.
	values_from:   Symbol_Id,
	// Where the call is, and while the thread summaries collect, the region of
	// each argument by callee parameter, nil when no argument has one.
	span:          Span,
	regions:       []Region_Set,
	// The call is a bare block's task, which runs on a thread of its own: its
	// `thread_local` writes are that thread's, not the caller's (design.md
	// "Globals while tasks run"). A pooled block's task may run on the thread
	// joining it, so its writes count, at that join.
	elsewhere:     bool,
}

// A call in one body; a generic's instances share its spans.
Call_Site :: struct {
	body: Symbol_Id,
	span: Span,
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
	// Its own part, apart from the callbacks it calls, then all of it.
	own:    [dynamic]Symbol_Id,
	writes: [dynamic]Symbol_Id,
	calls:  []Effect_Call,
}

// A write, invalidation, or mutable borrow of a global's storage.
prov_note_static_write :: proc(graph: ^Flow_Graph, root: Root_Id, span: Span) {
	if root == NO_ROOT {
		return
	}
	entry := graph.roots[int(root)]
	if (entry.kind != .Static && entry.kind != .Thread_Local) || entry.symbol == INVALID_SYMBOL {
		return
	}
	prov_note_shared_effect(graph, entry.symbol, .Write, span)
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
	// A task's `run` makes the spawned call from its frame, which holds what
	// the parent evaluated (design.md "Spawn statements").
	if task, spawned := c.spawn_calls[v]; spawned && task.call != nil {
		target, ok := call_effect(c, task.call)
		target.values_from = task.parent
		return target, ok
	}
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
		if converted, found := converted_view_call(c, sel.operand, op.index); found {
			return converted, true
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
			if len(v.bound) > 0 {
				if converted, found := converted_view_call(c, v.bound[0], int(sym.index)); found {
					converted.type = forwarded.type
					return converted, true
				}
				// A `dyn proc` view this body holds runs what the view may hold.
				if ident, is_ident := v.bound[0].(^Expr_Ident); is_ident && effect_variable(c, ident.symbol) {
					forwarded.variable = ident.symbol
				}
			}
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

// design.md "Global write effects": a view converted where it is called runs
// what its concrete value supplies for the slot, not any witness of it: the
// concrete type's own method, a capture literal's `call`, or the procedure a
// callable view holds. A view of a view still reaches the inner view's union.
@(private = "file")
converted_view_call :: proc(c: ^Compiler, view: Expr, slot: int) -> (Effect_Call, bool) {
	value := view
	if conversion, is_call := view.(^Expr_Call); is_call {
		#partial switch op in conversion.operation {
		case Call_Dyn_Conversion:
			if op.witness == nil || slot >= len(op.witness.slots) {
				return {}, false
			}
			target := op.witness.slots[slot].target
			if sym := symbol_of(c, target); sym == nil || sym.kind != .Proc || sym.synth != .None {
				return {}, false
			}
			return Effect_Call{callee = target}, true
		case Call_Conversion:
			if len(conversion.args) != 1 {
				return {}, false
			}
			value = conversion.args[0].value
		case:
			return {}, false
		}
	}
	base := expr_base(value)
	if base == nil || base.erased_from == INVALID_TYPE || dyn_proc_signature(c, base.type) == INVALID_TYPE {
		return {}, false
	}
	if method, is_capture := c.capture_records[base.erased_from]; is_capture && method != nil {
		return Effect_Call{callee = method.symbol}, true
	}
	id := INVALID_SYMBOL
	#partial switch named in value {
	case ^Expr_Ident:
		id = named.symbol
	case ^Expr_Selector:
		id = named.resolution.symbol
	case ^Expr_Proc:
		id = named.symbol
	}
	if sym := symbol_of(c, id); sym != nil && sym.kind == .Proc {
		return Effect_Call{held = id}, true
	}
	return {}, false
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
		if target.callee != INVALID_SYMBOL && target.values_from == INVALID_SYMBOL {
			target.args = effect_args(c, v, graph.alloc)
		}
	}
	prov_effect_call(graph, target, v.span, regions_of = prov_tracks_allocator_use(graph) ? v : nil)
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

// A parameter, or a local, whose procedure value or `dyn proc` view is
// followed through the body.
@(private = "file")
effect_variable :: proc(c: ^Compiler, id: Symbol_Id) -> bool {
	sym := symbol_of(c, id)
	if sym == nil || underlying_kind(c, sym.type) != .Proc && dyn_proc_signature(c, sym.type) == INVALID_TYPE {
		return false
	}
	return sym.kind == .Parameter || (sym.kind == .Var && sym.duration == .None)
}

// What a procedure-valued expression, or a `dyn proc` view, may be. A view
// converted from a named procedure or a capture literal runs that procedure or
// the literal's `call`.
@(private = "file")
effect_value :: proc(c: ^Compiler, e: Expr) -> Effect_Arg {
	value := e
	if moved, is_move := value.(^Expr_Move); is_move {
		value = moved.value
	}
	base := expr_base(value)
	if base == nil {
		return {}
	}
	if dyn_proc_signature(c, base.type) != INVALID_TYPE {
		if converted, found := converted_view_call(c, value, 0); found {
			return Effect_Arg{kind = .Procedure, symbol = converted.held if converted.held != INVALID_SYMBOL else converted.callee}
		}
	} else if underlying_kind(c, base.type) != .Proc {
		return {}
	}
	id := INVALID_SYMBOL
	#partial switch v in value {
	case ^Expr_Ident:
		id = v.symbol
	case ^Expr_Selector:
		id = v.resolution.symbol
	case ^Expr_Proc:
		id = v.symbol
	case:
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
// to: `own` is each body's writes apart from its callbacks.
@(private = "file")
warn_thread_races :: proc(c: ^Compiler, own: [][dynamic]Symbol_Id) {
	for spawn in c.thread_spawns {
		index, found := c.effect_program.index_of[spawn.entry]
		if !found {
			continue
		}
		for global in own[index] {
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

// ------------------------------------------------------- per-call effects --

// design.md "Global write effects": a parameter a body calls, itself or by
// passing it where a callee calls its own, runs what each caller passes there.
// `elsewhere`: only on a bare block's task, whose `thread_local` writes are its
// own thread's. `span` is a call that runs it.
Called_Parameter :: struct {
	parameter: int,
	elsewhere: bool,
	span:      Span,
}

// What a body that calls a procedure value it received does apart from that
// value, so each call of the body takes in what its caller passes instead of
// every procedure of the parameter's type. The whole summaries
// (`Compiler.global_writes`, `reach_effects`, `allocator_uses`) add that union.
// `regions` is, per `called`, the regions of what the body passes the callback.
Callback_Summary :: struct {
	called:  []Called_Parameter,
	writes:  []Symbol_Id,
	reach:   []Global_Effect,
	use:     Allocator_Use,
	regions: []Region_Set,
}

// One body whose summary a call takes in: the direct callee's own part, or all
// of what a procedure value, a callback the callee calls, or a member of a
// union runs. A callback is the callee `via`'s `called[callback]`, given the
// regions `via` passes it.
@(private = "file")
Call_Part :: struct {
	body:      int,
	whole:     bool,
	elsewhere: bool,
	via:       int,
	callback:  int,
}

// The procedure-valued arguments a call passes, and what the value it goes
// through may be, as the write effects resolved them at its site. A task's
// call on its worker is resolved where its `spawn` is, whose parameters are
// not this body's.
@(private = "file")
call_values :: proc(c: ^Compiler, body: Symbol_Id, call: Effect_Call) -> (args: []Effect_Arg, values: []Effect_Arg, followed: bool) {
	if call.held != INVALID_SYMBOL {
		single := make([]Effect_Arg, 1, context.temp_allocator)
		single[0] = Effect_Arg{kind = .Procedure, symbol = call.held}
		return nil, single, true
	}
	from := call.values_from if call.values_from != INVALID_SYMBOL else body
	site := Call_Site{body = from, span = call.span}
	args = c.argument_values[site]
	values, followed = c.called_values[site]
	if from != body {
		args, values = foreign_values(args), foreign_values(values)
	}
	return
}

@(private = "file")
foreign_values :: proc(values: []Effect_Arg) -> []Effect_Arg {
	out := make([]Effect_Arg, len(values), context.temp_allocator)
	for value, index in values {
		out[index] = value
		if value.kind == .Parameter {
			out[index] = Effect_Arg{binding = value.binding}
		}
	}
	return out
}

// What one call in `body` takes in. A direct call takes its callee's own part,
// and for each callback the callee calls, what this call passes there; a call
// through a followed value, what each value runs; any other, every body its
// union holds. A value `body` itself received is its caller's to resolve
// while the summaries settle (`Called_Parameter`), or with `open`, any
// procedure of its type.
@(private = "file")
call_parts :: proc(c: ^Compiler, body: Symbol_Id, call: Effect_Call, open: bool) -> []Call_Part {
	program := &c.effect_program
	out := make([dynamic]Call_Part, 0, 2, context.temp_allocator)
	whole := Call_Part{whole = true, elsewhere = call.elsewhere, via = -1, callback = -1}
	args, values, followed := call_values(c, body, call)
	switch {
	case call.callee != INVALID_SYMBOL:
		target, found := program.index_of[call.callee]
		if !found {
			break
		}
		append(&out, Call_Part{body = target, elsewhere = call.elsewhere, via = -1, callback = -1})
		summary := c.callback_summaries[call.callee]
		if summary == nil {
			break
		}
		for called, position in summary.called {
			type := proc_parameter_type(c, program.bodies[target].type, called.parameter)
			part := Call_Part{whole = true, elsewhere = call.elsewhere || called.elsewhere, via = target, callback = position}
			bound := false
			for arg in args {
				if arg.binding == called.parameter {
					bound = true
					value_parts(c, &out, arg, any_value_call(c, type), part, open)
				}
			}
			if !bound {
				value_parts(c, &out, Effect_Arg{}, any_value_call(c, type), part, open)
			}
		}
	case followed:
		any := Effect_Call{type = call.type, dyn_interface = call.dyn_interface, dyn_index = call.dyn_index}
		for value in values {
			value_parts(c, &out, value, any, whole, open)
		}
	case:
		for reached in effect_targets(c, call, program) {
			part := whole
			part.body = reached
			append(&out, part)
		}
	}
	return out[:]
}

// The parts one value contributes; `any` reaches every value it may be.
@(private = "file")
value_parts :: proc(c: ^Compiler, out: ^[dynamic]Call_Part, value: Effect_Arg, any: Effect_Call, part: Call_Part, open: bool) {
	program := &c.effect_program
	#partial switch value.kind {
	case .Procedure:
		if index, found := program.index_of[value.symbol]; found {
			named := part
			named.body = index
			append(out, named)
		}
		return
	case .Nil:
		return
	case .Parameter:
		if !open {
			return
		}
	}
	for reached in effect_targets(c, any, program) {
		member := part
		member.body = reached
		append(out, member)
	}
}

// A call reaching any value of `type`: any procedure of a procedure type, or
// whatever a `dyn proc` view of its signature may run.
@(private = "file")
any_value_call :: proc(c: ^Compiler, type: Type_Id) -> Effect_Call {
	if signature := dyn_proc_signature(c, type); signature != INVALID_TYPE {
		return Effect_Call{dyn_interface = underlying_info(c, type).dyn_interface, type = signature}
	}
	return Effect_Call{type = type}
}

// What a body's whole summary adds to its own part: every procedure of each
// called parameter's type, given the regions the body passes it.
@(private = "file")
closing_parts :: proc(c: ^Compiler, index: int) -> []Call_Part {
	program := &c.effect_program
	summary := c.callback_summaries[program.bodies[index].symbol]
	if summary == nil {
		return nil
	}
	out := make([dynamic]Call_Part, 0, 2, context.temp_allocator)
	for called, position in summary.called {
		type := proc_parameter_type(c, program.bodies[index].type, called.parameter)
		part := Call_Part{whole = true, elsewhere = called.elsewhere, via = index, callback = position}
		value_parts(c, &out, Effect_Arg{}, any_value_call(c, type), part, true)
	}
	return out[:]
}

// Which parameters each body calls, through a variable that may hold one, or
// by passing one where a callee calls its own. Settled before the effects,
// which need it to tell a body's own part from its callbacks.
@(private = "file")
settle_called_parameters :: proc(c: ^Compiler, bodies: []Body_Effects) -> [][dynamic]Called_Parameter {
	program := &c.effect_program
	called := make([][dynamic]Called_Parameter, len(bodies), context.temp_allocator)
	callers := make([][dynamic]int, len(bodies), context.temp_allocator)
	for &list in called {
		list = make([dynamic]Called_Parameter, context.temp_allocator)
	}
	for &list in callers {
		list = make([dynamic]int, context.temp_allocator)
	}
	for body, index in bodies {
		for call in body.calls {
			if target, found := program.index_of[call.callee]; found && call.callee != INVALID_SYMBOL {
				append(&callers[target], index)
			}
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
		for call in bodies[index].calls {
			args, values, followed := call_values(c, bodies[index].symbol, call)
			if target, found := program.index_of[call.callee]; found && call.callee != INVALID_SYMBOL {
				for passed in called[target] {
					for arg in args {
						if arg.binding == passed.parameter && arg.kind == .Parameter {
							grew |= add_called_parameter(&called[index], arg.parameter, call.elsewhere || passed.elsewhere, call.span)
						}
					}
				}
			} else if followed {
				for value in values {
					if value.kind == .Parameter {
						grew |= add_called_parameter(&called[index], value.parameter, call.elsewhere, call.span)
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
	return called
}

// A parameter called on the body's own thread is not only a task's.
@(private = "file")
add_called_parameter :: proc(list: ^[dynamic]Called_Parameter, parameter: int, elsewhere: bool, span: Span) -> bool {
	for &existing in list {
		if existing.parameter == parameter {
			if existing.elsewhere && !elsewhere {
				existing.elsewhere = false
				return true
			}
			return false
		}
	}
	append(list, Called_Parameter{parameter = parameter, elsewhere = elsewhere, span = span})
	return true
}

@(private = "file")
proc_parameter_type :: proc(c: ^Compiler, proc_type: Type_Id, index: int) -> Type_Id {
	info := underlying_info(c, proc_type)
	if info == nil || index >= len(info.parameters) {
		return INVALID_TYPE
	}
	return info.parameters[index]
}

// Which bodies read each body's summaries, through the parts of its calls and
// of its whole summary, so a fixed point revisits only those.
@(private = "file")
part_readers :: proc(parts: [][]Call_Part, closing: [][]Call_Part) -> [][dynamic]int {
	readers := make([][dynamic]int, len(parts), context.temp_allocator)
	for &list in readers {
		list = make([dynamic]int, context.temp_allocator)
	}
	for index in 0 ..< len(parts) {
		for part in parts[index] {
			append(&readers[part.body], index)
		}
		for part in closing[index] {
			append(&readers[part.body], index)
		}
	}
	return readers
}

// Dropping a value runs its `hook(drop)`s, which write what a call of each
// would. `dropped` names the value, as source text unless it is `unnamed`.
// While the thread summaries collect, `region` is the value's when known
// (`prov_drop_region`): releasing an owner frees in it, and a hook is given it.
prov_drop_effects :: proc(
	graph: ^Flow_Graph, type: Type_Id, span: Span, dropped := "", unnamed := false, region: Maybe(Prov_Use_Region) = nil,
) {
	if set, known := region.?; known && type_owns_allocation(graph.k.c, type) {
		prov_event(graph, Prov_Event_Allocator_Use{set, span, true})
	}
	for hook in type_drop_hooks(graph.k.c, type) {
		prov_effect_call(graph, Effect_Call{callee = hook}, span, dropped, unnamed = unnamed, dropped_region = region)
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

// `regions_of` or `dropped_region` gives the regions the target's parameters
// are given, read from facts when the effect materializes.
@(private = "file")
prov_effect_call :: proc(
	graph: ^Flow_Graph, target: Effect_Call, span: Span, dropped := "", described := "", unnamed := false,
	regions_of: ^Expr_Call = nil, dropped_region: Maybe(Prov_Use_Region) = nil,
) {
	c := graph.k.c
	target := target
	target.span = span
	effect := -1
	if !c.global_writes_ready || c.thread_facts_pending {
		recorded := target
		recorded.elsewhere = graph.task_effects && !graph.spawning_pooled
		effect = len(graph.effect_calls)
		append(&graph.effect_calls, recorded)
	}
	_, drops := dropped_region.?
	use := Prov_Event_Effect_Use{target, regions_of, dropped_region, effect, span}
	if !c.global_writes_ready {
		if regions_of != nil || drops { prov_event(graph, use) }
		return
	}
	name := effect_call_description(c, target, dropped, described, unnamed)
	// design.md "Globals while tasks run": what the parent calls while its
	// tasks run reaches what the callee's summaries say. The writes are noted
	// where they become accesses below.
	if graph.parallel_depth > 0 && !graph.task_effects && !c.thread_facts_pending {
		caller := "a procedure this call may reach"
		if sym := symbol_of(c, target.callee); sym != nil {
			caller = fmt.tprintf("`%s`", identifier_text(c, sym.name))
		}
		for reached in effect_call_reach(c, graph_body(graph), target) {
			prov_note_shared_effect(graph, reached, .Read, span, caller)
		}
	}
	if regions_of != nil || drops {
		prov_event(graph, use)
	} else {
		prov_window_effect_use(graph, target, span)
	}
	graph.effect_name = name
	defer graph.effect_name = ""
	for global in effect_call_writes(c, graph_body(graph), target) {
		// A task's `thread_local` writes are never the parent's at its spawn:
		// a bare block's task has a thread of its own, and a pooled one runs
		// on the parent's thread only at the join, which counts them there.
		if graph.task_effects && global_is_thread_local(c, global) {
			continue
		}
		root := prov_root_for_symbol(graph, global)
		prov_access(graph, root, nil, .Invalidate, span, name)
	}
}

// The body a graph summarizes, whose call sites the write effects resolved.
@(private = "file")
graph_body :: proc(graph: ^Flow_Graph) -> Symbol_Id {
	return graph.literal.symbol if graph.literal != nil else INVALID_SYMBOL
}

global_is_thread_local :: proc(c: ^Compiler, global: Symbol_Id) -> bool {
	sym := symbol_of(c, global)
	return sym != nil && sym.duration == .Thread_Local
}

// A task of a pooled block: the procedure that runs it, and how diagnostics
// name what it calls.
Pool_Task :: struct {
	runs: Symbol_Id,
	name: string,
}

// design.md "Parallel blocks": a pool worker joining a pooled block may run
// the block's tasks on the joining thread, and their descendants on the same
// pool, so the join writes the `thread_local` storage they may write. A
// spawned call's summary counts what it calls and the pooled tasks it spawns
// in turn, but not a bare block's, which never run on this thread: exactly
// the tasks a helping join may run. Their other writes are the window's
// concern, wherever they run.
prov_pool_join_effects :: proc(graph: ^Flow_Graph, tasks: []Pool_Task, span: Span) {
	c := graph.k.c
	if !c.global_writes_ready || c.thread_facts_pending {
		return
	}
	for task in tasks {
		name := fmt.tprintf("modified by `%s`, which this join may run on this thread,", task.name)
		for global in effect_call_writes(c, INVALID_SYMBOL, Effect_Call{callee = task.runs}) {
			if global_is_thread_local(c, global) {
				prov_access(graph, prov_root_for_symbol(graph, global), nil, .Invalidate, span, name)
			}
		}
	}
}

// design.md "Allocators and tasks": a call inside a `parallel` block allocates
// where the callee's summary says, with the call's arguments for its
// parameters, and each callback where what the callee passes it is.
prov_window_effect_use :: proc(graph: ^Flow_Graph, target: Effect_Call, span: Span) {
	c := graph.k.c
	if graph.parallel_depth == 0 || c.thread_facts_pending || !c.global_writes_ready {
		return
	}
	for part in call_parts(c, graph_body(graph), target, open = true) {
		from, found := part_allocator_use(c, part)
		if !found {
			continue
		}
		call := target
		if part.callback >= 0 {
			given := make([]Region_Set, 1, context.temp_allocator)
			given[0] = prov_empty_region(graph)
			region_through(&given[0], callback_region(c, part), target.regions)
			call.regions = given
		}
		prov_note_window_allocator_use(graph, substituted_region(graph, from, call, !part.whole), span)
	}
}

// What one part of a call contributes: the whole summary of a body, or a
// direct callee's own part apart from its callbacks.
@(private = "file")
part_writes :: proc(c: ^Compiler, part: Call_Part) -> []Symbol_Id {
	symbol := c.effect_program.bodies[part.body].symbol
	if summary := c.callback_summaries[symbol]; summary != nil && !part.whole {
		return summary.writes
	}
	return c.global_writes[symbol]
}

@(private = "file")
part_reach :: proc(c: ^Compiler, part: Call_Part) -> []Global_Effect {
	symbol := c.effect_program.bodies[part.body].symbol
	if summary := c.callback_summaries[symbol]; summary != nil && !part.whole {
		return summary.reach
	}
	return c.reach_effects[symbol]
}

@(private = "file")
part_allocator_use :: proc(c: ^Compiler, part: Call_Part) -> (Allocator_Use, bool) {
	symbol := c.effect_program.bodies[part.body].symbol
	if summary := c.callback_summaries[symbol]; summary != nil && !part.whole {
		return summary.use, !allocator_use_is_empty(summary.use)
	}
	return c.allocator_uses[symbol]
}

// The regions a callback is given, in its callee's terms; unknown until the
// thread summaries settle them.
@(private = "file")
callback_region :: proc(c: ^Compiler, part: Call_Part) -> Region_Set {
	summary := c.callback_summaries[c.effect_program.bodies[part.via].symbol]
	if summary == nil || part.callback >= len(summary.regions) {
		return Region_Set{unknown = true}
	}
	return summary.regions[part.callback]
}

// Adds `set`, in a callee's terms, to `into` in its caller's: each parameter
// region as the region of the argument the call binds there, or an unknown one
// when the call's regions are not known. The callee's own local regions are
// unknown to its caller, as `merge_allocator_use` counts them.
@(private = "file")
region_through :: proc(into: ^Region_Set, set: Region_Set, regions: []Region_Set) {
	into.default ||= set.default
	into.unknown ||= set.unknown || set.crowded || set.locals != 0
	for wanted, parameter in set.params {
		switch {
		case !wanted:
		case regions == nil:
			into.unknown = true
		case parameter < len(regions):
			region_merge(into, regions[parameter])
		}
	}
}

// What a call reached through `target` is said to do in a diagnostic.
@(private = "file")
effect_call_description :: proc(c: ^Compiler, target: Effect_Call, dropped, described: string, unnamed: bool) -> string {
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
	return name
}

// The globals whose stored carriers one call may reach, from the thread
// summaries, with its callbacks resolved as its writes are.
@(private = "file")
effect_call_reach :: proc(c: ^Compiler, body: Symbol_Id, target: Effect_Call) -> []Symbol_Id {
	out := make([dynamic]Symbol_Id, 0, 2, context.temp_allocator)
	for part in call_parts(c, body, target, open = true) {
		for reached in part_reach(c, part) {
			add_global_write(&out, reached.global)
		}
	}
	return out[:]
}

// design.md "Globals while tasks run": inside a `parallel` block, a write of a
// global or a reach through one it stores is kept for the window check, which
// the solver applies where a task may be running. `name` says what call made
// it, or is empty for the body's own. A thread's own `thread_local` storage,
// and a `@(synchronized)` variable, whose package vouches for every access, are
// not shared writes; a carrier stored in `thread_local` storage is still
// reached.
prov_note_shared_effect :: proc(graph: ^Flow_Graph, global: Symbol_Id, access: Access_Kind, span: Span, name := "") {
	c := graph.k.c
	if graph.parallel_depth == 0 || graph.task_effects || !c.global_writes_ready || c.thread_facts_pending {
		return
	}
	sym := symbol_of(c, global)
	if sym == nil || sym.synchronized || (access != .Read && sym.duration == .Thread_Local) {
		return
	}
	described := name if name != "" else graph.effect_name
	prov_emit(graph, Prov_Event{kind = .Shared_Effect, symbol = global, access = access, span = span, name = described})
}

// A callee's allocator use at one call, in the caller's terms, as
// `substitute_allocator_use` settles it.
@(private = "file")
substituted_region :: proc(graph: ^Flow_Graph, from: Allocator_Use, call: Effect_Call, direct: bool) -> Region_Set {
	out := prov_empty_region(graph)
	out.default = from.regions.default
	out.unknown = from.regions.unknown
	for wanted, parameter in from.regions.params {
		if !wanted {
			continue
		}
		switch {
		case call.regions == nil:
			out.unknown = true
		case direct:
			if parameter < len(call.regions) {
				region_merge(&out, call.regions[parameter])
			}
		case:
			for set in call.regions {
				region_merge(&out, set)
			}
		}
	}
	return out
}

// The settled writes of one call: its callee's own, with each callback the
// callee calls taken from what this call passes there, or what the value or
// slot it goes through may run. A union is settled once per key.
@(private = "file")
effect_call_writes :: proc(c: ^Compiler, body: Symbol_Id, target: Effect_Call) -> []Symbol_Id {
	switch {
	case target.callee != INVALID_SYMBOL:
		if c.callback_summaries[target.callee] == nil {
			return c.global_writes[target.callee]
		}
	case target.held == INVALID_SYMBOL && target.variable == INVALID_SYMBOL:
		key := effect_key(target, context.temp_allocator)
		if writes, found := c.indirect_writes[key]; found {
			return writes
		}
		writes := make([dynamic]Symbol_Id, 0, 4, context.temp_allocator)
		for reached in effect_targets(c, target, &c.effect_program) {
			for global in c.global_writes[c.effect_program.bodies[reached].symbol] {
				add_global_write(&writes, global)
			}
		}
		settled := clone_symbols(c, writes[:])
		c.indirect_writes[effect_key(target, c.semantic_allocator)] = settled
		return settled
	}
	out := make([dynamic]Symbol_Id, 0, 4, context.temp_allocator)
	for part in call_parts(c, body, target, open = true) {
		for global in part_writes(c, part) {
			if !part.elsewhere || !global_is_thread_local(c, global) {
				add_global_write(&out, global)
			}
		}
	}
	return out[:]
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
// what it writes itself and what anything it may call writes. A direct call
// takes its callee's own part and, for each callback the callee calls, what
// this call passes there (`call_parts`). A value nothing followed may be every
// body of a compatible type that is used as a value, and a `dyn` slot every
// witness target for it; each union is keyed and settled with the rest.
compute_global_writes :: proc(k: ^Checker) {
	c := k.c
	c.global_writes = make(map[Symbol_Id][]Symbol_Id, c.semantic_allocator)
	c.indirect_writes = make(map[string][]Symbol_Id, c.semantic_allocator)
	c.callback_summaries = make(map[Symbol_Id]^Callback_Summary, c.semantic_allocator)
	c.type_unions = nil
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
		effects.own = make([dynamic]Symbol_Id, 0, len(graph.effect_writes), context.temp_allocator)
		append(&effects.own, ..graph.effect_writes[:])
		effects.calls = make([]Effect_Call, len(graph.effect_calls), context.temp_allocator)
		copy(effects.calls, graph.effect_calls[:])
		// The graph's storage is reset below; what each call's values may be is
		// kept by site. A task's call on its worker is resolved at its `spawn`.
		for &call in effects.calls {
			site := Call_Site{body = body.literal.symbol, span = call.span}
			if call.variable != INVALID_SYMBOL && call.values_from == INVALID_SYMBOL {
				c.called_values[site] = clone_effect_args(c, effect_variable_values(c, graph.effect_stores[:], call.variable))
			}
			if len(call.args) > 0 {
				c.argument_values[site] = clone_effect_args(c, effect_resolved_args(c, graph.effect_stores[:], call.args))
			}
			call.args = nil
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
	c.type_unions = make(map[Type_Id][]int, 16, c.semantic_allocator)
	for called, index in settle_called_parameters(c, bodies[:]) {
		if len(called) == 0 {
			continue
		}
		summary := new(Callback_Summary, c.semantic_allocator)
		summary.called = make([]Called_Parameter, len(called), c.semantic_allocator)
		copy(summary.called, called[:])
		c.callback_summaries[bodies[index].symbol] = summary
	}

	parts := make([][]Call_Part, len(bodies), context.temp_allocator)
	closing := make([][]Call_Part, len(bodies), context.temp_allocator)
	for body, index in bodies {
		list := make([dynamic]Call_Part, 0, len(body.calls), context.temp_allocator)
		for call in body.calls {
			append(&list, ..call_parts(c, body.symbol, call, open = false))
		}
		parts[index] = list[:]
		closing[index] = closing_parts(c, index)
	}
	// A body's sets grow only when one it reads does, so only its readers are
	// visited again.
	readers := part_readers(parts, closing)
	for &body in bodies {
		body.writes = make([dynamic]Symbol_Id, 0, len(body.own), context.temp_allocator)
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
		body := &bodies[index]
		grew := false
		for part in parts[index] {
			from := bodies[part.body].writes if part.whole else bodies[part.body].own
			for global in from {
				if !part.elsewhere || !global_is_thread_local(c, global) {
					grew |= add_global_write(&body.own, global)
				}
			}
		}
		for global in body.own {
			grew |= add_global_write(&body.writes, global)
		}
		for part in closing[index] {
			for global in bodies[part.body].writes {
				if !part.elsewhere || !global_is_thread_local(c, global) {
					grew |= add_global_write(&body.writes, global)
				}
			}
		}
		if !grew {
			continue
		}
		for reader in readers[index] {
			if !queued[reader] {
				queued[reader] = true
				append(&pending, reader)
			}
		}
	}
	own := make([][dynamic]Symbol_Id, len(bodies), context.temp_allocator)
	for body, index in bodies {
		own[index] = body.own
		if len(body.writes) > 0 {
			c.global_writes[body.symbol] = clone_symbols(c, body.writes[:])
		}
		if summary := c.callback_summaries[body.symbol]; summary != nil {
			summary.writes = clone_symbols(c, body.own[:])
		}
	}
	c.global_writes_ready = true
	warn_thread_races(c, own)
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
		// Asked for every call through a value, so kept once settled.
		if cached, found := c.type_unions[call.type]; found {
			return cached
		}
		for body, index in bodies {
			if used_as_value[body.symbol] && assignable(c, body.type, call.type) {
				append(&out, index)
			}
		}
		if c.type_unions != nil {
			kept := make([]int, len(out), c.semantic_allocator)
			copy(kept, out[:])
			c.type_unions[call.type] = kept
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
clone_effect_args :: proc(c: ^Compiler, args: []Effect_Arg) -> []Effect_Arg {
	out := make([]Effect_Arg, len(args), c.semantic_allocator)
	copy(out, args)
	return out
}

@(private = "file")
clone_symbols :: proc(c: ^Compiler, symbols: []Symbol_Id) -> []Symbol_Id {
	out := make([]Symbol_Id, len(symbols), c.semantic_allocator)
	copy(out, symbols)
	return out
}

// ------------------------------------------------------- thread summaries --

// compiler-architecture.md "Ownership, lifecycle, and provenance": where one
// part of a summary comes from. `via` is INVALID_SYMBOL for the body's own
// access at `span`; otherwise `span` is the call, hook run, or drop that
// reaches `via`, whose own summary says where it got it, so a diagnostic can
// follow the chain. `precision` is the provenance merge that may have widened
// the access.
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
// Every task carries all of them (design.md "Globals while tasks run").
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

// The bodies a call through a value or a `dyn` slot may run, as the write
// effects found them, and whether the call is one; none before they settle.
// A procedure type's inferred contract bounds only what its result borrows, so
// any body of its plain signature may be the one called.
indirect_call_targets :: proc(c: ^Compiler, v: ^Expr_Call) -> ([]Symbol_Id, bool) {
	target, ok := call_effect(c, v)
	if !ok {
		return nil, false
	}
	// A view converted at the call runs what its concrete value supplies.
	if converted := target.callee if target.callee != INVALID_SYMBOL else target.held; converted != INVALID_SYMBOL {
		if !prov_dispatches_on_view(c, v) {
			return nil, false
		}
		single := make([]Symbol_Id, 1, context.temp_allocator)
		single[0] = converted
		return single, true
	}
	if target.dyn_interface == INVALID_SYMBOL {
		target.type = erase_proc_contract(c, type_underlying(c, target.type))
	}
	return effect_target_symbols(c, target), true
}

// What brings `global` into a call's writes, or its reach, besides its
// callee's own part: a procedure value, a callback, or a union member, and for
// a callback, the callee that calls it and the parameter it was passed for.
Effect_Origin :: struct {
	target:    Symbol_Id,
	callee:    Symbol_Id,
	parameter: int,
}

// Each origin of `global` at `call` in `body`, as the summaries resolve it
// there, for a diagnostic to name. A direct callee's own part is the call's
// subject, except the concrete target of a view converted at the call.
call_effect_origins :: proc(c: ^Compiler, body: Symbol_Id, call: ^Expr_Call, global: Symbol_Id, writes: bool) -> []Effect_Origin {
	target, ok := call_effect(c, call)
	if !ok {
		return nil
	}
	target.span = call.span
	bodies := c.effect_program.bodies
	converted := prov_dispatches_on_view(c, call)
	out := make([dynamic]Effect_Origin, 0, 2, context.temp_allocator)
	for part in call_parts(c, body, target, open = true) {
		if !part.whole && !converted {
			continue
		}
		found := false
		if writes {
			found = slice.contains(part_writes(c, part), global)
		} else {
			for reached in part_reach(c, part) {
				found ||= reached.global == global
			}
		}
		if !found {
			continue
		}
		origin := Effect_Origin{target = bodies[part.body].symbol, parameter = -1}
		if part.callback >= 0 {
			origin.callee = bodies[part.via].symbol
			origin.parameter = c.callback_summaries[origin.callee].called[part.callback].parameter
		}
		if !slice.contains(out[:], origin) {
			append(&out, origin)
		}
	}
	return out[:]
}

// The bodies a value of a procedure type or a `dyn proc` view may run.
callable_type_targets :: proc(c: ^Compiler, type: Type_Id) -> []Symbol_Id {
	if underlying_kind(c, type) == .Proc {
		return effect_target_symbols(c, Effect_Call{type = erase_proc_contract(c, type_underlying(c, type))})
	}
	signature := dyn_proc_signature(c, type)
	if signature == INVALID_TYPE {
		return nil
	}
	view := underlying_info(c, type)
	return effect_target_symbols(c, Effect_Call{dyn_interface = view.dyn_interface, type = signature})
}

@(private = "file")
effect_target_symbols :: proc(c: ^Compiler, call: Effect_Call) -> []Symbol_Id {
	reached := effect_targets(c, call, &c.effect_program)
	out := make([]Symbol_Id, len(reached), context.temp_allocator)
	for index, position in reached {
		out[position] = c.effect_program.bodies[index].symbol
	}
	return out
}

// One body's thread facts: its own part, apart from the callbacks it calls,
// then all of it; per called parameter, the regions of what it passes there;
// and what each of its calls takes in.
@(private = "file")
Thread_Body :: struct {
	reach:       [dynamic]Global_Effect,
	use:         Allocator_Use,
	whole_reach: [dynamic]Global_Effect,
	whole_use:   Allocator_Use,
	regions:     []Region_Set,
	calls:       []Effect_Call,
	parts:       [][]Call_Part,
	// The use is settled by the body's role, not by its calls
	// (`shared_handle_operation`).
	settled_use: bool,
}

// design.md "Shared ownership": a handle's operations work on its one control
// block through a raw pointer, so what they call, and what they rebuild from
// that pointer, has an unknown region, though the block is the handle's region
// (`prov_call_region`). A handle operation keeps only its own use, and one that
// frees, the drop hook releasing the block and the payload through the
// allocator the constructor stored there, uses its receiver's region instead
// (design.md "Allocators and tasks"). Reading, copying, or upgrading a handle
// reserves nothing.
@(private = "file")
shared_handle_operation :: proc(c: ^Compiler, symbol: Symbol_Id, own: Allocator_Use) -> (handle, frees: bool) {
	sym := symbol_of(c, symbol)
	if sym == nil || !sym.has_receiver || !type_is_shared_handle(c, sym.owner_type) {
		return false, false
	}
	return true, sym.hook == .Drop || own.regions.unknown
}

// Each clean body's graph is built once more, with the result summaries
// settled, recording its own reach and allocator use and its calls; then both
// settle over the calls as the write effects do, each callback taken from
// where its caller passes it and given the regions its callee passes it.
compute_thread_summaries :: proc(k: ^Checker) {
	c := k.c
	program := &c.effect_program
	c.reach_effects = make(map[Symbol_Id][]Global_Effect, c.semantic_allocator)
	c.allocator_uses = make(map[Symbol_Id]Allocator_Use, c.semantic_allocator)
	facts := make([]Thread_Body, len(program.bodies), context.temp_allocator)
	for &body, index in facts {
		body.reach = make([dynamic]Global_Effect, context.temp_allocator)
		body.whole_reach = make([dynamic]Global_Effect, context.temp_allocator)
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
		if handle, frees := shared_handle_operation(c, body.literal.symbol, graph.allocator_use); handle {
			own.use = new_allocator_use(graph.param_count, context.temp_allocator)
			if frees {
				receiver := Region_Set{params = make([]bool, len(own.use.regions.params), context.temp_allocator)}
				receiver.params[0] = true
				merge_allocator_use(&own.use, receiver, Effect_Source{span = body.literal.span})
			} else if graph.allocator_use.regions.params != nil {
				merge_allocator_use_from(&own.use, graph.allocator_use)
			}
			own.settled_use = true
		} else if graph.allocator_use.regions.params != nil {
			resize_allocator_use(&own.use, graph.param_count)
			merge_allocator_use_from(&own.use, graph.allocator_use)
		}
		own.calls = make([]Effect_Call, len(graph.effect_calls), context.temp_allocator)
		own.parts = make([][]Call_Part, len(graph.effect_calls), context.temp_allocator)
		for call, position in graph.effect_calls {
			kept := call
			kept.args = nil
			kept.regions = clone_regions(call.regions, context.temp_allocator)
			own.calls[position] = kept
			parts := call_parts(c, body.literal.symbol, kept, open = false)
			own.parts[position] = make([]Call_Part, len(parts), context.temp_allocator)
			copy(own.parts[position], parts)
		}
		// Solved last: the solve's storage is the graph's.
		body_global_reach(k, graph, &own.reach)
		free_all(c.analysis_allocator)
	}
	c.thread_facts_pending = false

	parts := make([][]Call_Part, len(facts), context.temp_allocator)
	closing := make([][]Call_Part, len(facts), context.temp_allocator)
	for &body, index in facts {
		body.whole_use = new_allocator_use(len(body.use.regions.params), context.temp_allocator)
		list := make([dynamic]Call_Part, 0, len(body.calls), context.temp_allocator)
		for each in body.parts {
			append(&list, ..each)
		}
		parts[index] = list[:]
		closing[index] = closing_parts(c, index)
		if summary := c.callback_summaries[program.bodies[index].symbol]; summary != nil {
			body.regions = make([]Region_Set, len(summary.called), context.temp_allocator)
			for &set in body.regions {
				set.params = make([]bool, len(body.use.regions.params), context.temp_allocator)
			}
		}
	}
	readers := part_readers(parts, closing)
	queued := make([]bool, len(facts), context.temp_allocator)
	pending := make([dynamic]int, 0, len(facts), context.temp_allocator)
	for index := len(facts) - 1; index >= 0; index -= 1 {
		append(&pending, index)
		queued[index] = true
	}
	for len(pending) > 0 {
		index := pop(&pending)
		queued[index] = false
		body := &facts[index]
		grew := false
		for call, position in body.calls {
			for part in body.parts[position] {
				via := program.bodies[part.body].symbol
				reach := facts[part.body].whole_reach if part.whole else facts[part.body].reach
				for reached in reach {
					source := Effect_Source{via = via, span = call.span, precision = reached.source.precision}
					grew |= add_global_effect(&body.reach, reached.global, source)
				}
				// The receiver's region already covers what the calls free.
				if body.settled_use { continue }
				use := facts[part.body].whole_use if part.whole else facts[part.body].use
				if part.callback >= 0 {
					given := Region_Set{params = make([]bool, len(body.use.regions.params), context.temp_allocator)}
					region_through(&given, facts[part.via].regions[part.callback], call.regions)
					grew |= substitute_allocator_use(&body.use, use, callback_call(call.span, given), false, via)
				} else {
					grew |= substitute_allocator_use(&body.use, use, call, !part.whole, via)
				}
			}
			grew |= note_callback_regions(c, facts, index, call)
		}
		for reached in body.reach {
			grew |= add_global_effect(&body.whole_reach, reached.global, reached.source)
		}
		grew |= merge_allocator_use_from(&body.whole_use, body.use)
		summary := c.callback_summaries[program.bodies[index].symbol]
		for part in closing[index] {
			via := program.bodies[part.body].symbol
			span := summary.called[part.callback].span
			for reached in facts[part.body].whole_reach {
				source := Effect_Source{via = via, span = span, precision = reached.source.precision}
				grew |= add_global_effect(&body.whole_reach, reached.global, source)
			}
			if body.settled_use { continue }
			given := callback_call(span, body.regions[part.callback])
			grew |= substitute_allocator_use(&body.whole_use, facts[part.body].whole_use, given, false, via)
		}
		if !grew {
			continue
		}
		for reader in readers[index] {
			if !queued[reader] {
				queued[reader] = true
				append(&pending, reader)
			}
		}
	}
	for body, index in facts {
		symbol := program.bodies[index].symbol
		if len(body.whole_reach) > 0 {
			c.reach_effects[symbol] = slice.clone(body.whole_reach[:], c.semantic_allocator)
		}
		if !allocator_use_is_empty(body.whole_use) {
			c.allocator_uses[symbol] = clone_allocator_use(body.whole_use, c.semantic_allocator)
		}
		if summary := c.callback_summaries[symbol]; summary != nil {
			summary.reach = slice.clone(body.reach[:], c.semantic_allocator)
			summary.use = clone_allocator_use(body.use, c.semantic_allocator)
			summary.regions = clone_regions(body.regions, c.semantic_allocator)
		}
	}
	collect_thread_exit_drops(c)
}

// A callback's call as its callee makes it: every argument in `given`.
@(private = "file")
callback_call :: proc(span: Span, given: Region_Set) -> Effect_Call {
	regions := make([]Region_Set, 1, context.temp_allocator)
	regions[0] = given
	return Effect_Call{span = span, regions = regions}
}

// What one call passes the callbacks the body received: a call through one
// gives it every argument's region, and a direct call passing one on gives
// it what the callee gives it there.
@(private = "file")
note_callback_regions :: proc(c: ^Compiler, facts: []Thread_Body, index: int, call: Effect_Call) -> bool {
	program := &c.effect_program
	body := &facts[index]
	summary := c.callback_summaries[program.bodies[index].symbol]
	if summary == nil {
		return false
	}
	grew := false
	args, values, followed := call_values(c, program.bodies[index].symbol, call)
	if target, found := program.index_of[call.callee]; found && call.callee != INVALID_SYMBOL {
		passed := c.callback_summaries[call.callee]
		if passed == nil {
			return false
		}
		for callback, position in passed.called {
			for arg in args {
				own := called_position(summary, arg.parameter)
				if arg.binding != callback.parameter || arg.kind != .Parameter || own < 0 {
					continue
				}
				given := Region_Set{params = make([]bool, len(body.regions[own].params), context.temp_allocator)}
				region_through(&given, facts[target].regions[position], call.regions)
				grew |= merge_region_provenance(&body.regions[own], given)
			}
		}
	} else if followed {
		for value in values {
			own := called_position(summary, value.parameter) if value.kind == .Parameter else -1
			if own < 0 {
				continue
			}
			if call.regions == nil {
				grew |= merge_region_provenance(&body.regions[own], Region_Set{unknown = true})
			}
			for set in call.regions {
				grew |= merge_region_provenance(&body.regions[own], set)
			}
		}
	}
	return grew
}

@(private = "file")
called_position :: proc(summary: ^Callback_Summary, parameter: int) -> int {
	for called, position in summary.called {
		if called.parameter == parameter {
			return position
		}
	}
	return -1
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
merge_allocator_use_from :: proc(into: ^Allocator_Use, from: Allocator_Use) -> bool {
	grew := false
	for wanted, index in from.regions.params {
		if wanted && index < len(into.regions.params) && !into.regions.params[index] {
			into.regions.params[index] = true
			into.param_sources[index] = from.param_sources[index]
			grew = true
		}
	}
	if from.regions.default && !into.regions.default {
		into.regions.default = true
		into.default_source = from.default_source
		grew = true
	}
	if from.regions.unknown && !into.regions.unknown {
		into.regions.unknown = true
		into.unknown_source = from.unknown_source
		grew = true
	}
	return grew
}


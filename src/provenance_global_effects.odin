// What the provenance walk records of global effects (design.md "Global write
// effects", "Globals while tasks run"): a body's own static writes and reads, the
// procedure values it stores and calls, and, once the whole program's effects are
// settled in `global_effects.odin`, the accesses each call, hook run, drop, and
// pooled join makes, and what the parent of a `parallel` block does while its tasks
// run.
package lokec

import "core:fmt"
import "core:mem"
import "core:slice"

// The global whose storage `root` is, or INVALID_SYMBOL.
@(private = "file")
prov_root_global :: proc(graph: ^Flow_Graph, root: Root_Id) -> Symbol_Id {
	if root == NO_ROOT {
		return INVALID_SYMBOL
	}
	entry := graph.roots[int(root)]
	return entry.symbol if entry.kind == .Static || entry.kind == .Thread_Local else INVALID_SYMBOL
}

// A write, invalidation, or mutable borrow of a global's storage, kept while the
// effects settle.
prov_note_static_write :: proc(graph: ^Flow_Graph, root: Root_Id, span: Span) {
	global := prov_root_global(graph, root)
	if global == INVALID_SYMBOL {
		return
	}
	prov_note_shared_effect(graph, global, .Write, span)
	if !graph.k.c.global_writes_ready {
		append_unique(&graph.effect_writes, global)
	}
}

// A read of a global's storage by name, or a read-only borrow of it, kept only
// while the effects settle.
prov_note_static_read :: proc(graph: ^Flow_Graph, root: Root_Id) {
	if graph.k.c.global_writes_ready {
		return
	}
	if global := prov_root_global(graph, root); global != INVALID_SYMBOL {
		append_unique(&graph.effect_reads, global)
	}
}

// A procedure named anywhere but as a direct callee may be called through a
// value, so an indirect call's targets are drawn from these.
prov_note_proc_value :: proc(graph: ^Flow_Graph, e: Expr) {
	c := graph.k.c
	if c.global_writes_ready || e == nil {
		return
	}
	id := named_value_symbol(e)
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
@(private)
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
@(private)
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
	if method, is_capture := c.capture_records[base.erased_from]; is_capture {
		return Effect_Call{callee = method.symbol}, true
	}
	id := named_value_symbol(value)
	if sym := symbol_of(c, id); sym != nil && sym.kind == .Proc {
		return Effect_Call{held = id}, true
	}
	return {}, false
}

// Records the call while the effects settle; once they have, the callee's
// writes and reads become accesses at the call, after its arguments' loans are
// taken.
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

// What a value written by its name, or as a procedure literal, names.
@(private)
named_value_symbol :: proc(e: Expr) -> Symbol_Id {
	#partial switch v in e {
	case ^Expr_Ident:
		return v.symbol
	case ^Expr_Selector:
		return v.resolution.symbol
	case ^Expr_Proc:
		return v.symbol
	}
	return INVALID_SYMBOL
}

// The signature a value of `type` is called by: a procedure type's own, or a
// `dyn proc` view's, with the view's interface; not `ok` for any other type.
callable_signature :: proc(c: ^Compiler, type: Type_Id) -> (signature: Type_Id, view: Symbol_Id, ok: bool) {
	if underlying_kind(c, type) == .Proc {
		return type_underlying(c, type), INVALID_SYMBOL, true
	}
	if signature = dyn_proc_signature(c, type); signature != INVALID_TYPE {
		return signature, underlying_info(c, type).dyn_interface, true
	}
	return INVALID_TYPE, INVALID_SYMBOL, false
}

// A parameter, or a local, whose procedure value or `dyn proc` view is
// followed through the body.
@(private = "file")
effect_variable :: proc(c: ^Compiler, id: Symbol_Id) -> bool {
	sym := symbol_of(c, id)
	if sym == nil {
		return false
	}
	_, _, callable := callable_signature(c, sym.type)
	return callable && (sym.kind == .Parameter || (sym.kind == .Var && sym.duration == .None))
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
	_, view, callable := callable_signature(c, base.type)
	if !callable {
		return {}
	}
	if view != INVALID_SYMBOL {
		if converted, found := converted_view_call(c, value, 0); found {
			return Effect_Arg{kind = .Procedure, symbol = converted.held if converted.held != INVALID_SYMBOL else converted.callee}
		}
	}
	id := named_value_symbol(value)
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
@(private)
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
		append_unique(out, Effect_Arg{kind = .Parameter, parameter = int(sym.index)})
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
			append_unique(out, store.value)
		}
	}
	if !declared {
		append_unique(out, Effect_Arg{})
	}
}

// A call's arguments with each variable replaced by what it may hold.
@(private)
effect_resolved_args :: proc(c: ^Compiler, stores: []Effect_Store, args: []Effect_Arg) -> []Effect_Arg {
	out := make([dynamic]Effect_Arg, 0, len(args), context.temp_allocator)
	for arg in args {
		if arg.kind != .Variable {
			append_unique(&out, arg)
			continue
		}
		for value in effect_variable_values(c, stores, arg.symbol) {
			bound := value
			bound.binding = arg.binding
			append_unique(&out, bound)
		}
	}
	return out[:]
}

// A member the compiler supplies that calls a type's own `hash`, `==`, or `<`: a
// generated `hash`, a map operation on its keys, or a sort of its elements.
@(private = "file")
prov_implicit_call_effects :: proc(graph: ^Flow_Graph, v: ^Expr_Call) {
	c := graph.k.c
	sym := symbol_of(c, v.resolution.chosen_overload)
	if sym == nil || len(v.bound) == 0 || v.bound[0] == nil {
		return
	}
	subject := expr_base(v.bound[0]).type
	#partial switch sym.synth {
	case .Clone, .Try_Clone:
		prov_copy_effects(graph, subject, v.span)
	case .Adapter_View:
		// A view holding its source by value keeps a copy of it.
		if type_of(c, sym.result).adapter_by_value { prov_copy_effects(graph, subject, v.span) }
	case .Adapter_Iter, .Iterator_Copy, .Indexed_Next, .Copied_Next, .Array_Next:
		prov_iteration_member_effects(graph, sym, v.span)
	case .Standard_Hash:
		prov_hash_effects(graph, subject, v.span)
	case .Container_Op:
		effects := CONTAINER_OP_EFFECTS[sym.container_op]
		if .Hashes_Key in effects {
			prov_key_effects(graph, subject, v.span)
		}
		// An `append` keeps a copy of what a lone spread lends it, and a lookup
		// hands back a copy of what it finds.
		if sym.container_op == .Map_Lookup_Value || sym.container_op == .Append && v.variadic_forwards {
			prov_copy_effects(graph, container_element(c, subject), v.span)
		}
		if .Stores_Key in effects {
			prov_copy_effects(graph, container_key(c, subject), v.span)
		}
		if .Compares_Elements in effects {
			policy := resolved_element_order_policy(c, sequence_element(c, subject))
			if policy.kind == .Inherent {
				prov_effect_call(graph, Effect_Call{callee = policy.less}, v.span)
			}
		}
	}
}

// design.md "Global write effects": a `foreach` calls a protocol's `iter` once and
// its `next` each step, and each counts as a call there. Both are handed what the
// iterable holds, so `region` is its region, as `prov_drop_effects` takes a value's.
prov_iteration_call_effects :: proc(graph: ^Flow_Graph, member: Symbol_Id, span: Span, region: Maybe(Prov_Use_Region) = nil) {
	if sym := symbol_of(graph.k.c, member); sym != nil {
		prov_effect_call(graph, Effect_Call{callee = member}, span, dropped_region = region)
		prov_iteration_member_effects(graph, sym, span, region)
	}
}

// What a member the compiler supplies on an iterator runs besides itself: the member
// it wraps, and a clone where it hands back a copy (`emit_synth_adapter`). A `copied()`
// over a `next` that hands back its element by value makes none, as there is nothing
// lent to copy out of.
@(private = "file")
prov_iteration_member_effects :: proc(graph: ^Flow_Graph, sym: ^Symbol, span: Span, region: Maybe(Prov_Use_Region) = nil) {
	c := graph.k.c
	wrapped := symbol_of(c, sym.iteration_target)
	#partial switch sym.synth {
	case .Iterator_Copy, .Array_Next:
		prov_copy_effects(graph, sym.result, span)
	case .Copied_Next:
		if wrapped != nil && wrapped.result != sym.result {
			prov_copy_effects(graph, sym.result, span)
		}
	}
	if wrapped != nil {
		prov_iteration_call_effects(graph, sym.iteration_target, span, region)
	}
}

// design.md "Global write effects": the language calls a type's own `hash` and
// `==` where it hashes or compares one, and each counts as a call there. A
// generated `hash` calls each part's own `hash`.
prov_hash_effects :: proc(graph: ^Flow_Graph, type: Type_Id, span: Span) {
	prov_own_part_effects(graph, type, span, part_own_hash)
}

// A structural `==` calls each part's own `==`.
prov_equality_effects :: proc(graph: ^Flow_Graph, type: Type_Id, span: Span) {
	prov_own_part_effects(graph, type, span, type_own_equality)
}

@(private = "file")
prov_own_part_effects :: proc(graph: ^Flow_Graph, type: Type_Id, span: Span, own_of: proc(c: ^Compiler, part: Type_Id) -> Symbol_Id) {
	c := graph.k.c
	parts: [dynamic]Type_Id
	defer delete(parts)
	own_equalities_called(c, type, &parts)
	for part in parts {
		if own := own_of(c, part); own != INVALID_SYMBOL {
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
	sym := symbol_of(c, graph.literal.symbol)
	described := "printing a failure `main` returns"
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
		if !symbol_is_test(sym) || sym.pkg != c.root_package {
			return
		}
		described = "printing a failure a test returns"
	case .Obj:
		return
	}
	if _, fallible := entry_failure_type(c, sym.result); !fallible {
		return
	}
	if view := format_view_interface(c); view != INVALID_SYMBOL {
		prov_effect_call(graph, Effect_Call{dyn_interface = view}, span, described = described)
	}
}

// design.md "Global write effects": a copy may run the `hook(copy)` of what it
// copies, whose writes are rejected, so what remains is what it reads. How many
// copies run is unspecified, so each copy site counts, and a copy last-use
// transfer turns into a move counts as well. Answers whether a copy runs a hook.
prov_copy_effects :: proc(graph: ^Flow_Graph, type: Type_Id, span: Span) -> (runs_hooks: bool) {
	c := graph.k.c
	hooks := type_copy_hooks(c, type)
	for hook in hooks {
		if !c.global_writes_ready {
			append_unique(&graph.effect_copy_hooks, hook)
			continue
		}
		reads := body_summary(c, hook).reads
		if len(reads) == 0 {
			continue
		}
		name := effect_call_description(c, Effect_Call{callee = hook}, "read", "", "", false)
		for global in reads {
			if !graph.task_effects || !global_is_thread_local(c, global) {
				prov_access(graph, prov_root_for_symbol(graph, global), nil, .Read, span, name)
			}
		}
	}
	return len(hooks) > 0
}

// `prov_copy_effects` for a copy of a value holding `loans`. Its hook is handed that
// value, so what it holds is in use across the hook's reads, whether or not the value
// or the copy is used again.
prov_copy_of_held_effects :: proc(graph: ^Flow_Graph, type: Type_Id, loans: []int, span: Span) {
	if prov_copy_effects(graph, type, span) && len(loans) > 0 {
		prov_emit(graph, Prov_Event{kind = .Live, sources = loans, span = span})
	}
}

// design.md "Fixed arrays": an element filling a range of slots is evaluated once
// and then copied into the rest, before the next element is evaluated.
prov_repeated_element_effects :: proc(graph: ^Flow_Graph, v: ^Expr_Composite, literal_type: Type_Id, index: int, loans: []int) {
	first, end := composite_element_slots(v, index)
	if end - first <= 1 || v.elements[index].value == nil {
		return
	}
	type := prov_element_type(graph, v, literal_type, index)
	prov_copy_of_held_effects(graph, type, loans, expr_span(v.elements[index].value))
}

// design.md "Destructuring": a place destructure copies each retained field and
// never calls the containing record's hook, so each cloned field counts alone.
prov_destructure_copy_effects :: proc(graph: ^Flow_Graph, plan: ^Destructure, operand: Expr) {
	for cloned, index in plan.clones {
		if field := symbol_of(graph.k.c, plan.fields[index]); cloned && field != nil {
			prov_copy_effects(graph, field.type, expr_span(operand))
		}
	}
}

// design.md "Built-in procedures": an `assert` or `panic` report prints `type`
// through its `format` methods and any `format` slot of a `dyn` view in it. As for
// a failure `main` returns, the slot may reach any `format` method. A value printed
// with no method runs nothing, and that is most of them.
prov_report_effects :: proc(graph: ^Flow_Graph, type: Type_Id, span: Span) {
	c := graph.k.c
	view := format_view_interface(c)
	if view == INVALID_SYMBOL || !type_prints_through_method(c, type) {
		return
	}
	prov_effect_call(graph, Effect_Call{dyn_interface = view}, span, described = "printing an argument of this report")
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

// `clear` and a `resize` that may shrink drop what they discard. A map's `try_insert`
// drops the element a present key replaces, its `find_or_insert` the one a present
// key does not take, which is in its own region, and its `remove` the stored key;
// `pop` and `remove` hand the element back.
prov_container_drop_effects :: proc(graph: ^Flow_Graph, v: ^Expr_Call) {
	c := graph.k.c
	sym := symbol_of(c, v.resolution.chosen_overload)
	if graph.mode == .Lifecycle || sym == nil || sym.synth != .Container_Op || len(v.bound) == 0 {
		return
	}
	subject := expr_base(v.bound[0]).type
	region := prov_drop_region(graph, v.bound[0])
	effects := CONTAINER_OP_EFFECTS[sym.container_op]
	if .Drops_Contents in effects {
		prov_drop_effects(graph, subject, v.span, region = region)
	}
	if .Drops_Element in effects {
		prov_drop_effects(graph, container_element(c, subject), v.span, region = region)
	}
	if .Drops_Given in effects {
		prov_drop_effects(graph, container_element(c, subject), v.span, region = prov_drop_region(graph, v.bound[2]))
	}
	if .Drops_Key in effects {
		prov_drop_effects(graph, container_key(c, subject), v.span, region = region)
	}
}

// A local's scope exit drops it only where the lifecycle pass found it may
// still be live there; a moved-out local runs no hook.
prov_scope_drop_effects :: proc(graph: ^Flow_Graph, id: Symbol_Id, span: Span) {
	if sym := symbol_of(graph.k.c, id); sym != nil && sym.drop_at_exit {
		prov_drop_effects(graph, sym.type, span, identifier_text(graph.k.c, sym.name), region = prov_symbol_drop_region(graph, id))
	}
}

// design.md "Global write effects": a named procedure passed for a
// `@(cross_thread)` parameter, or in such a pack, runs on another thread, as an
// entry or as the value an entry calls, so it is kept until the effects settle.
@(private = "file")
note_thread_spawn :: proc(graph: ^Flow_Graph, v: ^Expr_Call) {
	c := graph.k.c
	for crossing in call_cross_thread_operands(c, v, graph.alloc) {
		if !crossing.of_proc {
			continue
		}
		if _, literal := crossing.operand.(^Expr_Proc); literal {
			continue
		}
		entry := named_value_symbol(crossing.operand)
		if entry_sym := symbol_of(c, entry); entry_sym != nil && entry_sym.kind == .Proc {
			append(&graph.thread_spawns, Thread_Spawn{entry = entry, span = v.span})
		}
	}
}

// One operand a call passes to a `@(cross_thread)` parameter, and whether it is a
// procedure.
Cross_Thread_Operand :: struct {
	operand: Expr,
	of_proc: bool,
}

// design.md "@(cross_thread)": the operands `call` passes to its `@(cross_thread)`
// parameters, in parameter order. Each element written in a `..proc()` pack
// crosses as the one argument of a `proc()` parameter would; a spread is a slice
// of procedure values, none of them named, and a pack of any other type cannot
// carry the attribute.
call_cross_thread_operands :: proc(c: ^Compiler, call: ^Expr_Call, allocator: mem.Allocator) -> []Cross_Thread_Operand {
	proc_type := call_proc_type(c, call)
	info := underlying_info(c, proc_type)
	if info == nil || len(info.param_cross_thread) == 0 {
		return nil
	}
	out := make([dynamic]Cross_Thread_Operand, 0, len(call.bound), allocator)
	for index in 0 ..< min(len(call.bound), len(info.parameters)) {
		if !proc_param_crosses_thread(c, proc_type, index) {
			continue
		}
		parameter := info.parameters[index]
		if param_mode_at(info, index) != .Variadic {
			if call.bound[index] != nil {
				append(&out, Cross_Thread_Operand{call.bound[index], underlying_kind(c, parameter) == .Proc})
			}
		} else if call_packs(call, index) && underlying_kind(c, slice_element(c, parameter)) == .Proc {
			cursor: Call_Pack_Cursor
			for operand, spread in call_pack_next(call, &cursor) {
				if !spread {
					append(&out, Cross_Thread_Operand{operand, true})
				}
			}
		}
	}
	return out[:]
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
	deferred := regions_of != nil || drops
	use := Prov_Event_Effect_Use{target, regions_of, dropped_region, effect, span}
	if !c.global_writes_ready {
		if deferred { prov_event(graph, use) }
		return
	}
	// design.md "Globals while tasks run": what the parent calls while its
	// tasks run reaches what the callee's summaries say. The writes are noted
	// where they become accesses below.
	if graph.parallel_depth > 0 && !graph.task_effects && !c.thread_facts_pending {
		caller := "a procedure this call may reach"
		if sym := symbol_of(c, target.callee); sym != nil {
			caller = fmt.tprintf("`%s`", identifier_text(c, sym.name))
		}
		for reached in effect_call_reach(c, graph.literal.symbol, target) {
			prov_note_shared_effect(graph, reached.global, .Read, span, caller, reached.source.precision)
		}
	}
	if deferred {
		prov_event(graph, use)
	} else {
		prov_window_effect_use(graph, target, span)
	}
	writes := effect_call_writes(c, graph.literal.symbol, target)
	reads := effect_call_reads(c, graph.literal.symbol, target)
	// Described only for the accesses below, which most calls make none of.
	if len(writes) > 0 {
		name := effect_call_description(c, target, "modified", dropped, described, unnamed)
		graph.effect_name = name
		defer graph.effect_name = ""
		for global in writes {
			// Not the parent's at the spawn; a pooled join counts them
			// (`prov_pool_join_effects`).
			if graph.task_effects && global_is_thread_local(c, global) {
				continue
			}
			root := prov_root_for_symbol(graph, global)
			prov_access(graph, root, nil, .Invalidate, span, name)
		}
	}
	if len(reads) > 0 {
		name := effect_call_description(c, target, "read", dropped, described, unnamed)
		for global in reads {
			// A write above already conflicts with every loan a read would.
			if slice.contains(writes, global) || graph.task_effects && global_is_thread_local(c, global) {
				continue
			}
			prov_access(graph, prov_root_for_symbol(graph, global), nil, .Read, span, name)
		}
	}
}

// A task of a pooled block: the procedure that runs it, and how diagnostics
// name what it calls.
Pool_Task :: struct {
	runs: Symbol_Id,
	name: string,
}

// design.md "Parallel blocks": a helping join may run the block's pooled tasks
// and their descendants, so it writes and reads their `thread_local` storage.
prov_pool_join_effects :: proc(graph: ^Flow_Graph, tasks: []Pool_Task, span: Span) {
	c := graph.k.c
	if !c.global_writes_ready || c.thread_facts_pending {
		return
	}
	for task in tasks {
		name := fmt.tprintf("modified by `%s`, which this join may run on this thread,", task.name)
		writes := effect_call_writes(c, INVALID_SYMBOL, Effect_Call{callee = task.runs})
		for global in writes {
			if global_is_thread_local(c, global) {
				prov_access(graph, prov_root_for_symbol(graph, global), nil, .Invalidate, span, name)
			}
		}
		name = fmt.tprintf("read by `%s`, which this join may run on this thread,", task.name)
		for global in effect_call_reads(c, INVALID_SYMBOL, Effect_Call{callee = task.runs}) {
			if global_is_thread_local(c, global) && !slice.contains(writes, global) {
				prov_access(graph, prov_root_for_symbol(graph, global), nil, .Read, span, name)
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
	for part in call_parts(c, graph.literal.symbol, target, open = true) {
		from := part_summary(c, part).use
		if part.callback >= 0 {
			from = callback_allocator_use(from, callback_region(c, part), target.regions)
		} else {
			from = substituted_region(from, target.regions, direct = !part.whole)
		}
		prov_note_window_allocator_use(graph, from, span)
	}
}

// design.md "Globals while tasks run": inside a `parallel` block, a write of a
// global or a reach through one it stores is kept for the window check. `name`
// says what call made it, or is empty for the body's own.
prov_note_shared_effect :: proc(graph: ^Flow_Graph, global: Symbol_Id, access: Access_Kind, span: Span, name := "", precision: Precision_Loss = {}) {
	c := graph.k.c
	if graph.parallel_depth == 0 || graph.task_effects || !c.global_writes_ready || c.thread_facts_pending {
		return
	}
	sym := symbol_of(c, global)
	if sym == nil || sym.synchronized || (access != .Read && sym.duration == .Thread_Local) {
		return
	}
	described := name if name != "" else graph.effect_name
	prov_emit(graph, Prov_Event{kind = .Shared_Effect, symbol = global, access = access, span = span, name = described, precision = precision})
}

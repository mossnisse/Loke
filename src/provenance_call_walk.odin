// How the provenance walk records a call: a user operator as the call it
// resolved to, the arguments bound to their parameters, and what the call's result
// and its `inout` arguments hold afterwards.
package lokec

import "core:slice"

// design.md "Operator declarations": a user operator is a call to the procedure
// it resolved to, its operands bound in parameter order. Each operator node keeps
// one call node, so a later region or place query finds that call's result. The
// call yields the procedure's result, beneath any implicit conversion of the
// node: an erased `[dynamic]T` result still depends on its allocator.
@(private)
prov_operator_call :: proc(graph: ^Flow_Graph, e: Expr) -> ^Expr_Call {
	if call, found := graph.operator_calls[rawptr(expr_base(e))]; found {
		return call
	}
	assert(!graph.replaying_facts, "fact replay reached an operator call absent from normalization")
	bound: []Expr
	indexes := false
	#partial switch v in e {
	case ^Expr_Index:
		bound, indexes = v.bound, true
	case ^Expr_Slice:
		bound, indexes = v.bound, true
	case ^Expr_Binary:
		bound = make([]Expr, 2, graph.alloc)
		bound[0], bound[1] = v.lhs, v.rhs
	case ^Expr_Unary:
		bound = make([]Expr, 1, graph.alloc)
		bound[0] = v.operand
	}
	base := expr_base(e)
	call := prov_synthetic_call(graph, base.resolution.chosen_overload, bound, prov_unconverted_type(e), base.span, indexes)
	graph.operator_calls[rawptr(base)] = call
	return call
}

// A call to `callee` that no `Expr_Call` spells: a user operator, a compound
// assignment's, or `operator([]=)`. An indexing receiver is borrowed after its
// operands, as a built-in container is, so `x[x.len() - 1]` and the `len()` an
// omitted endpoint reads are not uses under the receiver's own borrow; an
// operand's borrow that outlives it still conflicts at the call.
@(private)
prov_synthetic_call :: proc(
	graph: ^Flow_Graph, callee: Symbol_Id, bound: []Expr, type: Type_Id, span: Span, indexes := false,
) -> ^Expr_Call {
	key := Prov_Synthetic_Call_Key{callee, type, span, graph.expansion, indexes}
	cached := graph.effect_program != nil
	if cached {
		if call, found := graph.input.synthetic_calls[key]; found { return call }
		prov_writable_input(graph)
	}
	call := new(Expr_Call, graph.alloc)
	call.span = span
	call.type = type
	call.bound = slice.clone(bound, graph.alloc)
	call.resolution = Resolution{kind = .User_Operator, symbol = callee, chosen_overload = callee}
	call.operation = Call_Procedure{}
	if indexes && len(bound) > 1 {
		call.bound_order = make([]int, len(bound), graph.alloc)
		for index in 1 ..< len(bound) {
			call.bound_order[index - 1] = index
		}
		call.bound_order[len(bound) - 1] = 0
	}
	if cached { graph.input.synthetic_calls[key] = call }
	return call
}

// The call an expression makes, if it is one: a spelled call or a user operator.
@(private = "file")
prov_call_node :: proc(graph: ^Flow_Graph, e: Expr) -> ^Expr_Call {
	#partial switch v in e {
	case ^Expr_Call:
		return v.dispatch == nil ? v : nil
	case ^Expr_Index, ^Expr_Slice, ^Expr_Binary, ^Expr_Unary:
		if expr_base(e).resolution.kind == .User_Operator {
			return prov_operator_call(graph, e)
		}
	}
	return nil
}

// design.md "`inout` results": walks a call whose result is `inout` and returns
// the place that result names, which its `inout` arguments borrow.
@(private)
prov_inout_result_place :: proc(graph: ^Flow_Graph, e: Expr) -> ([]int, bool) {
	if !prov_names_inout_result(graph, e) {
		return nil, false
	}
	walk_flow_expr(graph, e)
	return graph.call_results[prov_call_node(graph, e)].place, true
}

@(private)
prov_names_inout_result :: proc(graph: ^Flow_Graph, e: Expr) -> bool {
	call := prov_call_node(graph, e)
	return call != nil && prov_result_is_inout(graph, call)
}

// The loans of every argument not marked `@(escape=none)`, as far as a callee may
// hand them back (`prov_argument_kept`).
@(private)
prov_escaping_actuals :: proc(graph: ^Flow_Graph, v: ^Expr_Call, actuals: [][]int) -> []int {
	proc_type := call_proc_type(graph.k.c, v)
	out: []int
	for slots, index in actuals {
		if proc_param_escape(graph.k.c, proc_type, index) == .None {
			continue
		}
		out = prov_join(graph, out, prov_argument_kept(graph, v, proc_type, index, slots))
	}
	return out
}

// The operands of a built pack, by how they stand to it: `elements` as its
// elements, and `spreads` at the pack's type, copied in, one load above them.
Prov_Pack_Operands :: struct {
	elements, spreads: []int,
}

// What a callee may hand back or keep of argument `index`, whose loans are `held`:
// the argument and what it reaches, or of a pack only what lies below what it lends
// for the call (design.md "Variadic parameters"). Elements, and a spread a `..^T`
// pack lends, stand as one element; a forwarded spread, and a spread copied into
// a built pack, stand as the pack, one load above. Values that hold no borrow leave
// nothing, where a load into storage with no carriers would stand for the storage
// itself.
@(private)
prov_argument_kept :: proc(graph: ^Flow_Graph, v: ^Expr_Call, proc_type: Type_Id, index: int, held: []int) -> []int {
	lending, packs := proc_param_pack_lending(graph.k.c, proc_type, index)
	if !packs {
		return prov_with_content(graph, held, v.span)
	}
	if !type_carries_borrow(graph.k.c, lending.held).any {
		return nil
	}
	if !call_packs(v, index) {
		return prov_kept_below(graph, held, v.span, lending.depth + 1)
	}
	if operands, split := graph.pack_operands[v]; split {
		return prov_join(
			graph,
			prov_kept_below(graph, operands.elements, v.span, lending.depth),
			prov_kept_below(graph, operands.spreads, v.span, lending.depth + 1),
		)
	}
	return prov_kept_below(graph, held, v.span, lending.depth)
}

// What `held` reaches `from` loads down and below, or at 0 also `held` itself.
@(private = "file")
prov_kept_below :: proc(graph: ^Flow_Graph, held: []int, span: Span, from: int) -> []int {
	return from == 0 ? prov_with_content(graph, held, span) : prov_load_deep(graph, held, span, from = from)
}

// What is stored behind `carriers`, `from` loads down and at every depth below:
// what a callee may hand back or keep from the storage an argument reaches.
// `route` narrows the first load to one place in what `carriers` name, and the
// last, the `from`th, to one place in what it reads; when they are one load, the
// last's place wins, as `prov_load_held` has taken the first's already.
@(private)
prov_load_deep :: proc(graph: ^Flow_Graph, carriers: []int, span: Span, from := 1, route := Load_Route{}) -> []int {
	if len(carriers) == 0 {
		return nil
	}
	graph.has_content_load = true
	through := carriers
	for depth in 1 ..= from {
		slot := prov_temp_slot(graph)
		along: []Proj_Step
		switch {
		case depth == from && route.last != nil:
			along = route.last
		case depth == 1:
			along = route.first
		}
		prov_emit(graph, Prov_Event{
			kind = .Load, slot = slot, into = through, path = along, load = .Deep if depth == from else .Place, span = span,
		})
		through = prov_one(graph, slot)
	}
	return through
}

// Where a write through `carriers` may land at any depth: the storage each
// mutable carrier below them names, reached through mutable carriers and
// through read-only ones whose pointee still reaches a destination, so
// `view: ^int` beside a recursive `next: ^mut Node` names no destination.
prov_load_writable :: proc(graph: ^Flow_Graph, carriers: []int, span: Span) -> []int {
	if len(carriers) == 0 {
		return nil
	}
	graph.has_content_load = true
	slot := prov_temp_slot(graph)
	prov_emit(graph, Prov_Event{kind = .Load, slot = slot, into = carriers, load = .Writable, span = span})
	return prov_one(graph, slot)
}

// An argument and everything it reaches, for a callee with no summary to say
// which of the two it hands back or keeps.
@(private)
prov_with_content :: proc(graph: ^Flow_Graph, slots: []int, span: Span) -> []int {
	return prov_join(graph, slots, prov_load_deep(graph, slots, span))
}

// A call dispatching through the `dyn` view it takes as its receiver: a slot
// call, or a view's forwarding member.
@(private)
prov_dispatches_on_view :: proc(c: ^Compiler, v: ^Expr_Call) -> bool {
	if _, slot := v.operation.(Call_Dyn_Slot); slot {
		return true
	}
	sym := symbol_of(c, v.resolution.symbol)
	return sym != nil && sym.synth == .Dyn_Forward
}

@(private)
prov_parameter_type :: proc(graph: ^Flow_Graph, v: ^Expr_Call, index: int) -> Type_Id {
	input := prov_input_call(graph, v)
	return index < len(input.arguments) ? input.arguments[index].type : INVALID_TYPE
}

@(private)
prov_result_is_inout :: proc(graph: ^Flow_Graph, v: ^Expr_Call) -> bool {
	return prov_input_call(graph, v).result_inout
}

@(private)
prov_argument_is_inout :: proc(graph: ^Flow_Graph, v: ^Expr_Call, index: int) -> bool {
	input := prov_input_call(graph, v)
	return index < len(input.arguments) && input.arguments[index].mode == .Inout
}

// design.md "Allocators": the control block follows the region's lifecycle,
// independently of its movable owner's inline storage.
@(private = "file")
prov_handle_call :: proc(graph: ^Flow_Graph, v: ^Expr_Call) -> []int {
	receiver := v.bound[0]
	loans := walk_flow_expr(graph, receiver)
	receiver_value := prov_input_value(graph, receiver)
	region, _ := prov_handle_region(graph, v, receiver_value)
	// Querying a policy does not evaluate it. Only this walk creates a
	// provider whose lifetime ends with the statement (design.md "Allocators").
	if prov_expr_is_temporary(receiver) && region.locals != 0 {
		append(&graph.temp_providers, Temp_Provider{bit = region.locals, span = expr_span(receiver)})
	}
	root: Root_Id
	if place, path, ok := prov_place_of(graph, receiver); ok {
		provider := graph.roots[int(place)]
		if provider.kind != .Local {
			return prov_join(graph, loans, prov_borrow(graph, place, path, false, v.span, "allocator handle"))
		}
		root = prov_new_root(graph, .Provider, expr_span(receiver), "this allocator control block")
		graph.roots[int(root)].region = region
		// A named provider's region is a carried fact, settled later; one in
		// a record is its position's token, from the walk.
		if _, named := receiver.(^Expr_Ident); named && graph.effect_program != nil {
			append(&graph.effect_program.root_regions, Prov_Root_Region{root, v, receiver_value})
		}
	} else if prov_expr_is_temporary(receiver) {
		root = prov_temp_root(graph, expr_span(receiver))
	} else {
		return loans
	}
	return prov_join(graph, loans, prov_borrow(graph, root, nil, false, v.span, "allocator handle"))
}

// A call that bound no arguments: `v.args` are all there is to walk.
@(private = "file")
prov_unbound_call :: proc(graph: ^Flow_Graph, v: ^Expr_Call, callee: []int, spawned: bool) -> []int {
	actuals := make([][]int, max(len(v.args), 1), graph.alloc)
	borrowed: []int
	for argument, index in v.args {
		actuals[index] = walk_flow_expr(graph, argument.value)
		prov_hold_owner(graph, argument.value)
		borrowed = prov_join(graph, borrowed, actuals[index])
	}
	if !spawned {
		prov_reach_call(graph, callee, actuals, v.span)
	}
	// The reset precedes the boundary use, so the actuals are live at it.
	prov_call_resets(graph, v)
	{
		prov_task_effects_scope(graph, spawned)
		prov_call_effects(graph, v)
	}
	if len(borrowed) > 0 {
		prov_emit(graph, Prov_Event{kind = .Live, sources = borrowed, span = v.span, hands_on = true})
	}
	prov_call_carrier_moves(graph, v, .None, actuals)
	return prov_store_call_results(graph, v, actuals)
}

// Evaluation order, not parameter order: a named argument written first borrows
// before a later one invalidates.
@(private = "file")
prov_bound_arguments :: proc(graph: ^Flow_Graph, v: ^Expr_Call, input: Prov_Call_Input) -> (actuals: [][]int, borrowed: []int) {
	actuals = make([][]int, len(v.bound), graph.alloc)
	split_receiver: []int
	// design.md "Weakening and reborrows": the mutable loans the arguments take,
	// which start once they are all evaluated.
	reserved := make([dynamic]Prov_Reserved, 0, 0, graph.alloc)
	for step in 0 ..< len(v.bound) {
		index := call_slot_at(v, step)
		if index == 0 && input.capture != 0 {
			split_receiver = walk_flow_expr(graph, v.bound[0])
			graph.captured_values[input.capture] = prov_snapshot(graph, split_receiver, expr_span(v.bound[0]))
			continue
		}
		actuals[index] = prov_call_argument(graph, v, index, input, &borrowed, &reserved)
		prov_hold_owner(graph, v.bound[index])
	}
	prov_start_reserved(graph, v, reserved[:], actuals, &borrowed)
	if input.capture != 0 {
		actuals[0] = prov_lend_split_receiver(graph, split_receiver, graph.captured_values[input.capture], expr_span(v.bound[0]))
		borrowed = prov_join(graph, borrowed, actuals[0])
	}
	return
}

@(private)
prov_call :: proc(graph: ^Flow_Graph, v: ^Expr_Call) -> []int {
	c := graph.k.c
	input := prov_input_call(graph, v)
	defer prov_call_written_aliases(graph, prov_input_value(graph, v))
	held := len(graph.held_owners)
	defer resize(&graph.held_owners, held)
	// A spawned call runs on its task, whose reach and effects its start checks;
	// the parent only prepares the arguments, which are copied for the task.
	spawned := v == graph.spawning && !c.thread_facts_pending
	{
		prov_task_effects_scope(graph, spawned)
		prov_event(graph, Prov_Event_Call_Allocator_Use{v})
	}
	#partial switch _ in v.operation {
	case Call_Text, Call_Text_Conversion:
		return prov_text_call(graph, v)
	case Call_Conversion, Call_Dyn_Conversion:
		// design.md "Implicit type conversions", "Borrowed callable views": a view
		// conversion is the implicit conversion written out. The operand is the
		// result, so it borrows what it views as at a typed destination.
		if operand, viewing := explicit_view_operand(v); viewing {
			return walk_flow_expr(graph, operand)
		}
		if viewed, is_view := prov_read_only_conversion(graph, v); is_view {
			return viewed
		}
	}
	if result, handled := prov_builtin_call(graph, v); handled {
		return result
	}
	#partial switch call_provider_op(c, v) {
	case .Handle:
		if len(v.bound) > 0 {
			return prov_handle_call(graph, v)
		}
	case .Open, .Try_Open, .Open_Fixed:
		opened: []int
		for argument in v.bound {
			if argument != nil { opened = prov_join(graph, opened, walk_flow_expr(graph, argument)) }
		}
		return prov_value_content(graph, opened, prov_type(graph, v), v.span)
	}
	callee: []int
	if !call_receiver_is_bound(c, v) {
		// A procedure the call names is not used as a value; one an
		// immediately called literal or other expression evaluates is.
		if !call_through_value(c, v) {
			graph.callee_expr = v.callee
		}
		callee = walk_flow_expr(graph, v.callee)
	}
	// design.md "Spawn statements": a procedure value a task calls is evaluated
	// on the parent, before the arguments, and held with them until the join.
	if v == graph.spawning && input.callee != 0 {
		graph.spawn_held = callee
	}
	if len(v.bound) == 0 {
		return prov_unbound_call(graph, v, callee, spawned)
	}
	actuals, borrowed := prov_bound_arguments(graph, v, input)
	if !spawned {
		prov_reach_call(graph, callee, actuals, v.span)
	}
	// A moved argument now belongs to the callee, which checks its own resets
	// against that parameter's lifetime. Value arguments remain caller-owned
	// until the call returns (design.md "Parameter semantics and ABI lowering").
	resize(&graph.held_owners, held)
	for argument, index in v.bound {
		mode := index == 0 && input.has_receiver ? input.receiver : input.arguments[index].mode
		if mode != .Move { prov_hold_owner(graph, argument) }
	}
	prov_call_resets(graph, v)
	prov_call_cross_thread(graph, v)
	prov_call_retention(graph, v, actuals)
	{
		prov_task_effects_scope(graph, spawned)
		prov_call_effects(graph, v)
		prov_argument_drop_effects(graph, v)
	}
	prov_use_reached_at_once(graph, v, borrowed)
	if len(borrowed) > 0 {
		prov_emit(graph, Prov_Event{kind = .Live, sources = borrowed, span = v.span, hands_on = true})
	}
	// What the container stores reborrows the arguments, so it is stored after
	// their use in the call: the operation's own read of an argument is not a
	// use of it while the stored copy lives.
	prov_container_content(graph, v, input.container, actuals)
	prov_call_carrier_moves(graph, v, input.container, actuals)
	if v == graph.spawning {
		graph.spawn_held = prov_join(graph, graph.spawn_held, borrowed)
		for actual, index in actuals {
			graph.spawn_held = prov_join(graph, graph.spawn_held, actual)
			prov_spawn_lends_loaded(graph, v, index, actual)
		}
	}
	return prov_store_call_results(graph, v, actuals)
}

// Until the end of the enclosing scope, what is recorded is the effect of a
// call spawned on a task when `spawned`, and of the parent's own call otherwise.
// The outer setting comes back at the end of the scope.
@(private = "file", deferred_out = prov_end_task_effects)
prov_task_effects_scope :: proc(graph: ^Flow_Graph, spawned: bool) -> (^Flow_Graph, bool) {
	outer := graph.task_effects
	graph.task_effects = spawned
	return graph, outer
}

@(private = "file")
prov_end_task_effects :: proc(graph: ^Flow_Graph, outer: bool) {
	graph.task_effects = outer
}

// design.md "Evaluation order": an owned value already evaluated is live
// while later operands run, even when its named source has been moved.
@(private)
prov_hold_owner :: proc(graph: ^Flow_Graph, value: Expr) {
	if value != nil && type_is_managed(graph.k.c, prov_type(graph, value)) && !expression_is_borrowed_place(value) {
		append(&graph.held_owners, value)
	}
}

// design.md "Evaluation order": a managed place given to `box` is read when it is
// reached but cloned from the allocator evaluated after it, so it stays
// borrowed until then, as a call's argument does.
@(private)
prov_lend_copied_place :: proc(graph: ^Flow_Graph, value: Expr) -> []int {
	if !type_is_managed(graph.k.c, prov_type(graph, value)) || !expression_is_borrowed_place(value) {
		return nil
	}
	if root, path, named := prov_place_of(graph, value); named && !expression_converts_storage(value) {
		return prov_borrow(graph, root, path, false, expr_span(value), "borrow")
	}
	if carriers, _, through := prov_read_through_carrier(graph, value, reads_only = true); through {
		return prov_reborrow_traversal(graph, carriers, expr_span(value), false)
	}
	return nil
}

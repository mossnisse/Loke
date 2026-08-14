// Ownership: `move`, explicit `drop`, and the liveness that decides where the
// compiler drops a managed local (m5a-plan step 4).
//
// design.md "Managed values and storage": "The compiler performs dataflow
// analysis and classifies a lexical local as definitely live, definitely dead,
// or conditionally live at each program point. A use that requires a value is
// valid only in the definitely-live state."
//
// Both halves of that live here. `move` and `drop` are compiler special forms
// over a storage location rather than ordinary calls, so they are checked as
// syntax; the classification itself runs once per concrete body over the
// `src/cfg.odin` view, after the body is checked and every node has its type.
//
// The analysis writes two facts back onto each local's symbol: whether scope
// exit drops it at all, and whether it reaches its scope exits in the same
// state on every path. Only the second case needs a runtime flag, which is what
// keeps "no source or ABI rule requires a flag" true for the ordinary local.
package lokec

// ------------------------------------------------------ the special forms --

// design.md "Assignment statements": "`move(value)` transfers ownership without
// a copy. The operation writes the inert zero representation to the lexical
// source and marks it dead until a later full assignment."
check_move :: proc(k: ^Checker, v: ^Expr_Move) {
	v.value_category = .Value
	operand := check_single_expr(k, v.value)
	if operand == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	v.type = operand
	if !require_lexical_owner(k, v.value, "move") {
		v.type = INVALID_TYPE
	}
}

// design.md "Storage modifiers": `drop(value)` "runs the cleanup operation,
// writes the inert zero representation, and marks the variable dead".
check_drop_builtin :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident) {
	v.type = TYPE_VOID
	v.value_category = .Value
	if len(v.args) != 1 || v.args[0].name.text != "" || v.args[0].mode != .Value {
		errorf(k.c, v.span, "L0496", "`drop` takes one argument, the variable being cleaned up")
		v.type = INVALID_TYPE
		return
	}
	if check_single_expr(k, v.args[0].value) == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	if !require_lexical_owner(k, v.args[0].value, "drop") {
		v.type = INVALID_TYPE
		return
	}
	bound := make([]Expr, 1, k.c.semantic_allocator)
	bound[0] = v.args[0].value
	v.bound = bound
}

// design.md: "The operand of `drop` must name a variable. Like `move`, `drop`
// operates on a storage location", it "cannot operate directly on a field, an
// element, or a map entry", and applying either "to file-scope, `static`, or
// `thread_local` storage, or to a subplace rooted in such storage, is a
// compile-time error".
@(private = "file")
require_lexical_owner :: proc(k: ^Checker, e: Expr, form: string) -> bool {
	ident, is_ident := e.(^Expr_Ident)
	sym := is_ident ? symbol_of(k.c, ident.symbol) : nil
	if sym == nil || (sym.kind != .Var && sym.kind != .Parameter && sym.kind != .Result) {
		errorf(
			k.c,
			expr_span(e),
			"L0497",
			"`%s` names a variable; move the owner out of the aggregate first, or %s the whole value",
			form,
			form,
		)
		return false
	}
	if sym.decl != nil && sym.decl.top_level {
		errorf(k.c, expr_span(e), "L0498", "`%s` cannot be applied to file-scope storage, which is always live", form)
		add_notef(k.c, sym.span, "declared here; `exchange` replaces a static-duration value instead")
		return false
	}
	// design.md "Parameter semantics": an ordinary `value: T` parameter is a
	// non-owning immutable borrow. Consuming one is the caller's `move` at the
	// call site, not this body's.
	if sym.kind == .Parameter && sym.mode != .Inout {
		errorf(
			k.c,
			expr_span(e),
			"L0499",
			"`%s` borrows `%s`, so this body does not own it; `move` at the call site is what transfers ownership",
			form,
			identifier_text(k.c, sym.name),
		)
		add_notef(k.c, sym.span, "declared here")
		return false
	}
	return true
}


// ------------------------------------------------- ownership at the call --

// design.md "Parameter semantics": "Both non-default modes are required at the
// call site, not just at the declaration ... an argument to a `move` parameter
// must be written `move(expr)`. Omitting the marker is an error naming the
// parameter and the mode it needs." Method-call syntax supplies the marker for
// its own receiver, which is the one documented exception.
require_argument_ownership :: proc(k: ^Checker, v: ^Expr_Call, declaration: Symbol_Id) {
	sym := symbol_of(k.c, declaration)
	if sym == nil {
		return
	}
	info := type_of(k.c, sym.proc_type)
	if info == nil {
		return
	}
	first := 0
	if sym.has_receiver {
		first = 1 // the receiver's marker is implicit in method-call syntax
	}
	for slot in first ..< len(v.bound) {
		if slot >= len(info.param_modes) || info.param_modes[slot] != .Move {
			continue
		}
		argument := v.bound[slot]
		if argument == nil {
			continue
		}
		if _, is_move := argument.(^Expr_Move); is_move {
			continue
		}
		name := "this parameter"
		if slot < len(sym.param_symbols) {
			if parameter := symbol_of(k.c, sym.param_symbols[slot]); parameter != nil {
				name = identifier_text(k.c, parameter.name)
			}
		}
		errorf(
			k.c,
			expr_span(argument),
			"L0501",
			"`%s` is a `move` parameter, so this argument is written `move(...)`",
			name,
		)
	}
}

// design.md: "Returning such a borrowed managed parameter by value performs a
// logical clone, because the callee owns nothing it could move out. ... In
// contrast, returning a managed local, named result, temporary, or `move`
// parameter transfers that owned value into result storage without cloning."
classify_return_value :: proc(k: ^Checker, value: ^Return_Value, result: Type_Id) {
	if value.is_inout || !type_is_managed(k.c, result) {
		return
	}
	root := place_root_symbol(k, value.expr)
	sym := symbol_of(k.c, root)
	if sym == nil {
		return // a temporary: already owned, nothing to clone
	}
	// An owned source transfers. Everything else the callee can name is borrowed.
	if sym.kind == .Var && sym.decl != nil && !sym.decl.top_level {
		return
	}
	if sym.kind == .Result {
		return
	}
	if sym.kind == .Parameter && sym.mode == .Move {
		return
	}
	if type_clone_disabled(k.c, result) {
		errorf(
			k.c,
			expr_span(value.expr),
			"L0502",
			"`%s` disables `try_clone`, so a borrowed value of it cannot be returned by value; return a `move` parameter or a local instead",
			type_name(k.c, result),
		)
		return
	}
	value.clone_on_return = true
	// The generated entry point has to exist by emission.
	contribute_lifecycle_members(k, result)
}

// The variable a place expression is rooted in, or INVALID_SYMBOL for a
// temporary. Field and element selection do not change the root.
@(private = "file")
place_root_symbol :: proc(k: ^Checker, e: Expr) -> Symbol_Id {
	#partial switch v in e {
	case ^Expr_Ident:
		return v.symbol
	case ^Expr_Selector:
		return place_root_symbol(k, v.operand)
	case ^Expr_Index:
		return place_root_symbol(k, v.operand)
	}
	return INVALID_SYMBOL
}

// ------------------------------------------------------------- liveness --

// Where a local sits at one program point. The join of two different states is
// `Conditional`, which is exactly design.md's "conditionally live".
Liveness :: enum u8 {
	Dead,
	Live,
	Conditional,
}

@(private = "file")
join :: proc(a, b: Liveness) -> Liveness {
	return a == b ? a : .Conditional
}

// One concrete body's answer, run after checking so every node carries its type
// and every `defer` already has its slot.
analyze_ownership :: proc(k: ^Checker, literal: ^Expr_Proc) {
	graph := build_flow_graph(k, literal)
	if graph == nil {
		return
	}
	solve_liveness(k, graph)
	assign_cleanup_slots(k, graph)
}

// Forward dataflow to a fixed point. The lattice has three points and the graph
// is finite, so the loop terminates; iteration order is block order, which
// converges in one pass for everything but a back edge.
@(private = "file")
solve_liveness :: proc(k: ^Checker, graph: ^Flow_Graph) {
	tracked := len(graph.tracked)
	if tracked == 0 {
		return
	}
	for block in graph.blocks {
		block.entry_state = make([]Liveness, tracked, k.c.semantic_allocator)
		block.exit_state = make([]Liveness, tracked, k.c.semantic_allocator)
		block.visited = false
	}

	changed := true
	for round := 0; changed && round < 64; round += 1 {
		changed = false
		for block, index in graph.blocks {
			state := make([]Liveness, tracked, context.temp_allocator)
			if index == 0 {
				// An ordinary parameter is a borrow and a local is dead until its
				// declaration completes; a `move` parameter arrives owned.
				for slot in 0 ..< tracked {
					state[slot] = graph.tracked[slot].live_on_entry ? .Live : .Dead
				}
			} else {
				first := true
				for predecessor in block.preds {
					source := graph.blocks[predecessor]
					if !source.visited {
						continue
					}
					for slot in 0 ..< tracked {
						state[slot] = first ? source.exit_state[slot] : join(state[slot], source.exit_state[slot])
					}
					first = false
				}
				if first {
					continue // no reachable predecessor yet
				}
			}
			copy(block.entry_state, state)
			run_events(graph, block, state)
			if !block.visited || !states_equal(block.exit_state, state) {
				copy(block.exit_state, state)
				block.visited = true
				changed = true
			}
		}
	}

	// A second walk with the fixed point in hand: this is where the events that
	// need an answer — a use, a cleanup point — read their state.
	for block in graph.blocks {
		if !block.visited {
			continue
		}
		state := make([]Liveness, tracked, context.temp_allocator)
		copy(state, block.entry_state)
		report_events(k, graph, block, state)
	}
}

@(private = "file")
states_equal :: proc(a, b: []Liveness) -> bool {
	for value, index in a {
		if value != b[index] {
			return false
		}
	}
	return true
}

@(private = "file")
run_events :: proc(graph: ^Flow_Graph, block: ^Flow_Block, state: []Liveness) {
	for event in block.events {
		#partial switch event.kind {
		case .Init:
			state[event.slot] = .Live
		case .Kill:
			state[event.slot] = .Dead
		}
	}
}

// The diagnostics and the cleanup obligations, with the solved entry state.
@(private = "file")
report_events :: proc(k: ^Checker, graph: ^Flow_Graph, block: ^Flow_Block, state: []Liveness) {
	for event in block.events {
		local := &graph.tracked[event.slot]
		switch event.kind {
		case .Init:
			state[event.slot] = .Live
		case .Kill:
			if state[event.slot] != .Live {
				report_not_live(k, event, state[event.slot])
			}
			state[event.slot] = .Dead
		case .Use:
			if state[event.slot] != .Live {
				report_not_live(k, event, state[event.slot])
			}
		case .Cleanup:
			// Every cleanup point of one local votes: any disagreement between
			// them, or a conditional state at one of them, makes the drop
			// conditional and gives the slot a runtime flag.
			local.seen_cleanup = true
			switch state[event.slot] {
			case .Live:
				local.live_exit = true
			case .Dead:
				local.dead_exit = true
			case .Conditional:
				local.live_exit, local.dead_exit = true, true
			}
		}
	}
}

@(private = "file")
report_not_live :: proc(k: ^Checker, event: Flow_Event, state: Liveness) {
	if state == .Dead {
		errorf(
			k.c,
			event.span,
			"L0500",
			"`%s` has already been moved or dropped here",
			event.name,
		)
		return
	}
	errorf(
		k.c,
		event.span,
		"L0500",
		"`%s` is only live on some paths that reach here; a use needs it live on all of them",
		event.name,
	)
}

// design.md: "A managed local declaration places an implicit conditional
// `defer drop(value)` at the declaration point." The slot joins the same
// registration order every explicit `defer` uses, so cleanup replays one
// reverse order rather than two.
@(private = "file")
assign_cleanup_slots :: proc(k: ^Checker, graph: ^Flow_Graph) {
	for local in graph.tracked {
		sym := symbol_of(k.c, local.symbol)
		if sym == nil || !local.seen_cleanup || !local.live_exit {
			continue // never reaches a cleanup point live: nothing to drop
		}
		sym.drop_at_exit = true
		sym.drop_conditional = local.dead_exit
		if !sym.drop_conditional {
			continue // definite at every exit: no runtime state to keep
		}
		sym.cleanup_slot = k.defer_slots
		k.defer_slots += 1
	}
}

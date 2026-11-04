// The ownership special forms, and local liveness.
package lokec

import "core:fmt"
import "core:slice"

// ------------------------------------------------------ the special forms --

check_move :: proc(k: ^Checker, v: ^Expr_Move) {
	operand := check_single_expr(k, v.value)
	if operand != INVALID_TYPE && require_lexical_owner(k, v.value, "move") {
		v.type = operand
	}
}

check_drop_builtin :: proc(k: ^Checker, v: ^Expr_Call) {
	if !has_one_plain_argument(v) {
		errorf(k.c, v.span, "L0496", "`drop` takes one argument, the variable being cleaned up")
		return
	}
	if check_single_expr(k, v.args[0].value) == INVALID_TYPE || !require_lexical_owner(k, v.args[0].value, "drop") {
		return
	}
	v.bound = bound_exprs(k, v.args[0].value)
	v.type = TYPE_VOID
}

// `unsafe.forget` consumes without cleanup; it does not extend borrows.
check_forget_builtin :: proc(k: ^Checker, v: ^Expr_Call) {
	if !has_one_plain_argument(v) {
		errorf(k.c, v.span, "L0649", "`unsafe.forget` takes one argument, the value whose cleanup is suppressed")
		return
	}
	operand := v.args[0].value
	type := check_single_expr(k, operand)
	if type == INVALID_TYPE {
		return
	}
	// A place must spell its transfer; a temporary is already owned.
	if expression_is_borrowed_place(operand) {
		errorf(
			k.c,
			expr_span(operand),
			"L0501",
			"`unsafe.forget` consumes its operand, so a place is written `unsafe.forget(move(...))`",
		)
		return
	}
	// Forgetting a non-owner must not discard borrow provenance.
	if !type_is_managed(k.c, type) && type_carries_borrow(k.c, type).any {
		errorf(
			k.c,
			expr_span(operand),
			"L0650",
			"`%s` owns nothing and carries a borrow, so there is no cleanup for `unsafe.forget` to suppress",
			type_name(k.c, type),
		)
		return
	}
	v.bound = bound_exprs(k, operand)
	v.type = TYPE_VOID
}

// `move` and `drop` require an owned lexical variable.
require_lexical_owner :: proc(k: ^Checker, e: Expr, form: string) -> bool {
	ident, is_ident := e.(^Expr_Ident)
	sym := is_ident ? symbol_of(k.c, ident.symbol) : nil
	if sym == nil || (sym.kind != .Var && sym.kind != .Parameter) {
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
	if symbol_outlives_bodies(sym) {
		errorf(
			k.c,
			expr_span(e),
			"L0498",
			"`%s` cannot be applied to %s, which is always live",
			form,
			sym.duration == .Thread_Local ? "`thread_local` storage" :
				sym.duration == .Static ? "`static` storage" : "file-scope storage",
		)
		add_notef(k.c, sym.span, "declared here; `exchange` replaces a static-duration value instead")
		return false
	}
	if sym.borrowed_binding != .None {
		errorf(
			k.c,
			expr_span(e),
			"L0690",
			sym.borrowed_binding == .Switch_Payload ? "`%s` views the payload of a switch over a place, which still owns it; `switch (move(...))` hands it over first" :
				"`%s` views an element a `foreach` source still owns; take the element out of the source instead",
			form,
		)
		add_notef(k.c, sym.span, "bound here")
		return false
	}
	if sym.kind == .Parameter && sym.mode != .Move {
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


// `exchange` replaces a live value and returns the old one without cloning.
check_exchange_builtin :: proc(k: ^Checker, v: ^Expr_Call) {
	if len(v.args) != 2 {
		errorf(k.c, v.span, "L0505", "`exchange` takes a destination place and its replacement")
		return
	}
	if v.args[0].mode != .Inout {
		errorf(
			k.c,
			v.args[0].span,
			"L0505",
			"`exchange` replaces the destination, so it is written `exchange(inout place, replacement)`",
		)
		return
	}
	if v.args[0].name.text != "" || v.args[1].name.text != "" {
		errorf(k.c, v.span, "L0505", "`exchange` takes positional arguments only")
		return
	}
	if v.args[1].mode != .Value {
		errorf(k.c, v.args[1].span, "L0505", "`exchange`'s replacement is passed by value")
		return
	}

	destination := check_single_expr(k, v.args[0].value)
	if destination == INVALID_TYPE {
		return
	}
	base := expr_base(v.args[0].value)
	if base == nil || !base.assignable {
		report_not_assignable(k, base, "the destination of an `exchange`")
		return
	}
	replacement := v.args[1].value
	if !check_value_expr(k, replacement, destination, "exchange into") {
		return
	}
	// design.md "Exchange": the replacement's bits are stored, and a place would
	// go on owning them.
	if expression_is_borrowed_place(replacement) && type_is_managed(k.c, copied_type(replacement, destination)) {
		errorf(
			k.c,
			expr_span(replacement),
			"L0501",
			"`exchange` takes ownership of its replacement and copies nothing, so a place is written `move(...)`, or `.clone()` for a copy",
		)
		return
	}

	v.bound = bound_exprs(k, v.args[0].value, replacement)
	v.type = destination
	contribute_lifecycle_members(k, destination)
}

// Move values across container capacity whose liveness the compiler cannot track.
check_capacity_builtin :: proc(k: ^Checker, v: ^Expr_Call, kind: Builtin_Kind) {
	taking := kind == .Unsafe_Take
	name := taking ? "unsafe.take" : "unsafe.write"
	wanted := taking ? 1 : 2
	if len(v.args) != wanted {
		errorf(
			k.c, v.span, "L0692",
			taking ? "`unsafe.take` takes one argument, the place the value is read out of" :
				"`unsafe.write` takes the place and the value written into it",
		)
		return
	}
	for argument in v.args {
		if argument.name.text != "" || argument.mode != .Value {
			errorf(k.c, v.span, "L0692", "`%s` takes positional arguments only", name)
			return
		}
	}
	place := check_single_expr(k, v.args[0].value)
	if place == INVALID_TYPE {
		return
	}
	base := expr_base(v.args[0].value)
	if base == nil || !base.assignable {
		report_not_assignable(k, base, taking ? "the place `unsafe.take` reads" : "the place `unsafe.write` fills")
		return
	}
	if _, is_ident := v.args[0].value.(^Expr_Ident); is_ident {
		errorf(
			k.c, expr_span(v.args[0].value), "L0692",
			"`%s` reaches storage whose liveness is not tracked, and a variable's is; %s",
			name, taking ? "`move` takes a variable's value out" : "an ordinary assignment fills it",
		)
		return
	}
	bound := make([]Expr, wanted, k.c.semantic_allocator)
	bound[0] = v.args[0].value
	if !taking {
		if !check_value_expr(k, v.args[1].value, place, "write into") {
			return
		}
		classify_copy_cost(k, v.args[1].value, place, .Write)
		classify_copy(k, v.args[1].value, place, .Write)
		bound[1] = v.args[1].value
	}
	v.bound = bound
	v.type = taking ? place : TYPE_VOID
	if taking {
		contribute_lifecycle_members(k, place)
	}
}

// ------------------------------------------------- ownership at the call --

// A place passed to a `move` parameter must spell the transfer.
require_argument_ownership :: proc(
	k: ^Checker, v: ^Expr_Call, declaration: Symbol_Id, signature: ^Type_Info = nil,
) {
	sym := symbol_of(k.c, declaration)
	info := signature
	if info == nil && sym != nil {
		info = type_of(k.c, sym.proc_type)
	}
	if info == nil {
		return
	}
	first := 0
	if sym != nil && sym.has_receiver && sym.receiver != .Move {
		first = 1 // an `inout` receiver's marker is implicit in method-call syntax
	}
	for slot in first ..< len(v.bound) {
		if param_mode_at(info, slot) != .Move {
			continue
		}
		argument := v.bound[slot]
		if argument == nil {
			continue
		}
		if expression_is_owned_argument(argument) {
			continue
		}
		// A call through a procedure value has no declaration to name the parameter.
		name := "this parameter"
		if sym != nil && slot < len(sym.param_symbols) {
			if parameter := symbol_of(k.c, sym.param_symbols[slot]); parameter != nil {
				name = fmt.aprintf("`%s`", identifier_text(k.c, parameter.name), allocator = k.c.semantic_allocator)
			}
		}
		errorf(
			k.c,
			expr_span(argument),
			"L0501",
			"%s is a `move` parameter, so this argument is written `move(...)`",
			name,
		)
	}
}

// The variable a place is rooted in; INVALID_SYMBOL for a temporary or through a dereference.
place_root_symbol :: proc(e: Expr) -> Symbol_Id {
	#partial switch v in e {
	case ^Expr_Ident:
		return v.symbol
	case ^Expr_Selector:
		return place_root_symbol(v.operand)
	case ^Expr_Index:
		// A value-returning `operator([])` produces a temporary, not a place.
		if v.resolution.kind == .User_Operator && v.value_category != .Place {
			return INVALID_SYMBOL
		}
		return place_root_symbol(v.operand)
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
// and every `defer` already has its slot. `held` is how many copy reports were
// held before this body.
analyze_ownership :: proc(k: ^Checker, literal: ^Expr_Proc, held: int) {
	if graph := build_flow_graph(k, literal); graph != nil {
		settle_last_uses(graph)
		solve_liveness(k, graph)
		assign_cleanup_slots(k, graph)
	}
	flush_held_copy_reports(k, held)
	// A nested literal is checked, and analysed, before the body containing it
	// reaches here, so one reserved arena reset per body is enough.
	free_all(k.c.analysis_allocator)
}

// Forward dataflow to a fixed point. The lattice has three points and the graph
// is finite, so the worklist terminates; a block is re-queued only when one of
// its predecessors produced a new exit state.
@(private = "file")
solve_liveness :: proc(k: ^Checker, graph: ^Flow_Graph) {
	tracked := len(graph.tracked)
	if tracked == 0 {
		return
	}
	for block in graph.blocks {
		block.entry_state = make([]Liveness, tracked, graph.alloc)
		block.exit_state = make([]Liveness, tracked, graph.alloc)
		block.visited = false
	}

	queue := block_queue_from_entry(graph)
	state := make([]Liveness, tracked, graph.alloc)
	for id in block_queue_pop(&queue) {
		block := graph.blocks[id]
		if id == 0 {
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
		}
		copy(block.entry_state, state)
		for event in block.events {
			run_event(event, state)
		}
		if block.visited && slice.equal(block.exit_state, state) {
			continue
		}
		copy(block.exit_state, state)
		block.visited = true
		block_queue_wake(&queue, block.succs[:])
	}

	// A second walk with the fixed point in hand: this is where the events that
	// need an answer — a use, a cleanup point — read their state.
	assigned := make(map[Assigned_Destination]bool, allocator = graph.alloc)
	owners := make([dynamic]int, 0, tracked, graph.alloc)
	for local, slot in graph.tracked {
		if sym := symbol_of(k.c, local.symbol); sym != nil && type_is_managed(k.c, sym.type) {
			append(&owners, slot)
		}
	}
	for block in graph.blocks {
		if !block.visited {
			continue
		}
		copy(state, block.entry_state)
		report_events(k, graph, block, state, owners[:], &assigned)
	}
}

// One destination of an assignment node, which a `defer` expands at each exit.
@(private = "file")
Assigned_Destination :: struct {
	assign: ^Stmt_Assign,
	target: int,
}

@(private = "file")
run_event :: proc(event: Flow_Event, state: []Liveness) {
	#partial switch event.kind {
	case .Init, .Assign, .Spawn_Result:
		state[event.slot] = .Live
	case .Kill, .Cleanup, .Declare:
		state[event.slot] = .Dead
	}
}

// The diagnostics and the cleanup obligations, with the solved entry state.
@(private = "file")
report_events :: proc(
	k: ^Checker, graph: ^Flow_Graph, block: ^Flow_Block, state: []Liveness, owners: []int,
	assigned: ^map[Assigned_Destination]bool,
) {
	for event in block.events {
		#partial switch event.kind {
		case .Reset_Point:
			record_reset_liveness(k, graph, event, state)
		case .Panic_Point:
			for slot in owners {
				graph.tracked[slot].live_at_panic ||= state[slot] != .Dead
			}
		case .Kill:
			if state[event.slot] != .Live {
				report_not_live(k, block, event, state[event.slot], graph.tracked[event.slot].ever_written)
			}
		case .Use:
			// `x: T = ---` asserts that something else fills the storage, so an
			// ordinary read, borrow, or address of it is accepted (design.md
			// "Built-in values"). `move` and `drop` still are not: they are `.Kill`.
			local := graph.tracked[event.slot]
			if state[event.slot] != .Live && !local.unchecked {
				report_not_live(k, block, event, state[event.slot], local.ever_written)
			}
		case .Assign:
			record_destination_state(graph, event, state[event.slot], assigned)
		case .Cleanup:
			// A deferred assignment may have revived what no panic point finds live.
			graph.tracked[event.slot].live_at_panic ||= block.unwind && state[event.slot] != .Dead
		}
		// An unwind's deferred statements read what they name, which must be live
		// as it must be on any exit, and a deferred assignment drops what it
		// finds. Its cleanups are no cleanup points, and what it writes is no write
		// the normal paths see.
		if !block.unwind {
			report_normal_event(k, graph, event, state)
		}
		run_event(event, state)
	}
}

// design.md: assignment drops the destination's previous value, so what the
// emitter needs here is the state on the way in, not on the way out. A deferred
// assignment's expansions share one node, unwinding ones included, so the state
// it keeps is the join of every expansion's, and a disagreement needs the
// runtime flag.
@(private = "file")
record_destination_state :: proc(
	graph: ^Flow_Graph, event: Flow_Event, state: Liveness, assigned: ^map[Assigned_Destination]bool,
) {
	destination_state := state
	if event.assign != nil && event.target < len(event.assign.destination_live) {
		key := Assigned_Destination{event.assign, event.target}
		recorded := &event.assign.destination_live[event.target]
		if key in assigned {
			destination_state = join(recorded^, destination_state)
		}
		recorded^ = destination_state
		assigned[key] = true
	}
	if destination_state == .Conditional {
		graph.tracked[event.slot].conditional_assign = true
	}
}

// What only a normal path's event reports or counts.
@(private = "file")
report_normal_event :: proc(k: ^Checker, graph: ^Flow_Graph, event: Flow_Event, state: []Liveness) {
	#partial switch event.kind {
	case .Init, .Assign:
		graph.tracked[event.slot].ever_written = true
	case .Spawn_Result:
		// design.md "Spawn statements": neither a live value nor another
		// task's result is replaced.
		if state[event.slot] != .Dead {
			reason := state[event.slot] == .Conditional ? "it holds a value, or another task's result, on some of the paths that reach this point" :
				"it already holds a value, or another task's result"
			errorf(k.c, event.span, "L0728", "`%s` cannot take a task's result here: %s", event.name, reason)
		}
		graph.tracked[event.slot].ever_written = true
	case .Cleanup:
		// Every cleanup point of one local votes: any disagreement between
		// them, or a conditional state at one of them, makes the drop
		// conditional and gives the slot a runtime flag.
		local := &graph.tracked[event.slot]
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

// Only `.Dead` unblocks a reset (design.md "Allocators"): a conditionally live
// owner may still need cleanup on one path. In the compilation arena, since the
// reset check runs later, over a different graph. A point keyed by a symbol asks
// whether that symbol is dead, and only one ending a region who else is live.
@(private = "file")
record_reset_liveness :: proc(k: ^Checker, graph: ^Flow_Graph, event: Flow_Event, state: []Liveness) {
	live := Reset_Liveness{reached = true}
	if slot, tracked := graph.by_symbol[event.reset.symbol]; tracked {
		live.dead = state[slot] == .Dead
	}
	if event.reset.symbol == INVALID_SYMBOL || provider_local(k.c, event.reset.symbol) {
		owners := make([dynamic]Symbol_Id, 0, 4, k.c.semantic_allocator)
		for local, slot in graph.tracked {
			if state[slot] == .Dead {
				continue
			}
			if sym := symbol_of(k.c, local.symbol); sym != nil && type_is_managed(k.c, sym.type) {
				append(&owners, local.symbol)
			}
		}
		live.owners = owners[:]
	}
	table := event.call != nil ? &k.c.reset_dead : &k.c.cleanup_reset_dead
	table[event.reset] = live
}

@(private = "file")
report_not_live :: proc(k: ^Checker, block: ^Flow_Block, event: Flow_Event, state: Liveness, ever_written: bool) {
	action := event.verb == "" ? "used" : event.verb
	// design.md "Variable declarations": a local starts dead, so one nothing
	// ever assigns holds no value rather than having lost one.
	reason := state != .Dead ? "it is live on only some of the paths that reach this point" :
		ever_written ? "it has already been moved, dropped, or released" : "it has no value yet"
	errorf(k.c, event.span, "L0500", "`%s` cannot be %s here: %s", event.name, action, reason)
	if block.unwind {
		add_notef(k.c, block.unwind_at, "a panic in this statement runs the deferred statement")
	}
}

// A managed local declaration places an implicit conditional
// `defer drop(value)` at the declaration point (design.md). The slot joins the
// same registration order every explicit `defer` uses, so cleanup replays one
// reverse order, not two.
@(private = "file")
assign_cleanup_slots :: proc(k: ^Checker, graph: ^Flow_Graph) {
	for local in graph.tracked {
		// Definite initialization follows every local; only a managed one has a
		// cleanup a hidden flag could have to disambiguate.
		sym := symbol_of(k.c, local.symbol)
		if sym == nil || !type_is_managed(k.c, sym.type) {
			continue
		}
		// Reaching a cleanup point live is what gives a local an implicit drop.
		sym.drop_at_exit = local.live_exit
		sym.drop_on_unwind = local.live_at_panic
		// A hidden flag exists only where a lowering has to tell the runtime paths
		// apart: cleanup points that disagree, or an assignment whose destination
		// is live on one path and dead on another (design.md "Managed values and
		// storage": "No flag is required for every variable").
		sym.drop_conditional = (sym.drop_at_exit && local.dead_exit) || local.conditional_assign
		if sym.drop_conditional {
			sym.cleanup_slot = k.defer_slots
			k.defer_slots += 1
		}
	}
}

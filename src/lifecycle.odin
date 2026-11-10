// Local liveness: where each local is live, moved, or dropped, and its cleanup slots.
// The special forms that move and drop are checked in `ownership_forms.odin`.
package lokec

import "core:slice"

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
	for id in worklist_pop(&queue) {
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
		worklist_wake_all(&queue, block.succs[:])
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
			graph.tracked[event.slot].live_at_panic ||= event.unwinding && state[event.slot] != .Dead
		}
		// An unwind's deferred statements read what they name, which must be live
		// as it must be on any exit, and a deferred assignment drops what it
		// finds. What the panic left behind is no cleanup point, and what it writes
		// is no write the normal paths see. What a deferred statement declares is
		// its own: it starts and ends in the statement, which may have no other
		// expansion to count them.
		owned_by_deferred := event.kind == .Init || event.kind == .Cleanup && !event.unwinding
		if !block.unwind || owned_by_deferred {
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

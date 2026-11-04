// Spawn statements and `parallel` blocks: what a task holds until its join
// (design.md "Task borrows and the join").
package lokec

import "core:slice"

// design.md "Task borrows and the join": a spawn is checked as
// a call whose duration extends to the join. What its arguments lend and
// carry, and the result local it reserves, are held by the block's hidden
// scope from here on, so its drop at the join is a use of every loan. The
// result takes the call's provenance as an assignment would, with no access:
// the parent cannot reach it before the join.
@(private)
prov_spawn :: proc(graph: ^Flow_Graph, s: ^Stmt_Spawn) {
	call, is_call := s.call.(^Expr_Call)
	if !is_call {
		return
	}
	outer, outer_held, outer_owned, outer_pooled := graph.spawning, graph.spawn_held, graph.spawn_owned, graph.spawning_pooled
	graph.spawning, graph.spawn_held, graph.spawn_owned = call, nil, nil
	graph.spawning_pooled = s.task != nil && s.task.pooled
	graph.task_reserve = {}
	result := walk_flow_expr(graph, call)
	kept := make([dynamic]int, 0, len(graph.spawn_held), graph.alloc)
	for slot in graph.spawn_held {
		if !slice.contains(graph.spawn_owned, slot) {
			append(&kept, slot)
		}
	}
	held := kept[:]
	graph.spawning, graph.spawn_held, graph.spawn_owned, graph.spawning_pooled = outer, outer_held, outer_owned, outer_pooled
	task := s.task
	if task == nil {
		return
	}
	prov_spawn_transfers(graph, s, call, held, result)
	if s.result != nil {
		prov_store_value(graph, s.result, call, result, call.span)
		if root, path, ok := prov_place_of(graph, s.result); ok {
			held = prov_join(graph, held, prov_borrow(graph, root, path, true, s.result.span, "task result"))
		}
	}
	// The task runs from here: what it reaches, and what the parent does
	// until the join, are checked against the globals (design.md "Globals while
	// tasks run").
	runs := spawn_runs(graph, s)
	graph.has_window_event = true
	if graph.task_sites == nil {
		graph.task_sites = make([dynamic]Task_Site, 0, 2, graph.alloc)
	}
	append(&graph.task_sites, Task_Site{block = prov_window_bit(graph, task.scope), reserve = graph.task_reserve, span = s.span, call = call})
	prov_emit(graph, Prov_Event{
		kind = .Task_Start, slot = len(graph.task_sites) - 1, symbol = runs, sources = held, span = s.span,
		name = spawn_callee_name(graph.k.c, call),
	})
	slot, found := graph.task_slots[task.scope]
	hold, has_hold := graph.spawn_holds[s]
	if !found || !has_hold {
		return // registered by `prov_enter_parallel` unless its block failed to lower
	}
	join := s.span
	if scope := symbol_of(graph.k.c, task.scope); scope != nil {
		join = scope.span
	}
	prov_hold_until_join(graph, slot, held, s.span, join)
	prov_spawn_reborrows(graph, hold, held, s.span, join)
}

// The procedure a spawn's task runs: its `run` wrapper, or the declared
// callee when the effect analysis has no body for the wrapper.
@(private = "file")
spawn_runs :: proc(graph: ^Flow_Graph, s: ^Stmt_Spawn) -> Symbol_Id {
	callee := s.call.(^Expr_Call).resolution.symbol
	sym := symbol_of(graph.k.c, callee)
	if s.task.run in graph.k.c.effect_program.index_of || s.task.through_value || sym == nil || sym.synth != .None {
		return s.task.run
	}
	return callee
}

// design.md "Task borrows and the join": every exit of a `parallel` block
// joins its tasks, including an exit the walk reaches before a spawn that a
// loop's back edge runs earlier. So the slot of what the block's tasks lend,
// each spawn site's reborrow slot, and a pooled block's tasks are registered
// as the block is entered, before the walk reaches any exit.
@(private)
prov_enter_parallel :: proc(graph: ^Flow_Graph, s: ^Stmt_Parallel) {
	if len(s.spawns) == 0 {
		return
	}
	prov_window_bit(graph, s.scope)
	if graph.task_slots == nil {
		graph.task_slots = make(map[Symbol_Id]int, graph.alloc)
		graph.task_holds = make(map[Symbol_Id][]int, graph.alloc)
		graph.spawn_holds = make(map[^Stmt_Spawn]int, graph.alloc)
	}
	graph.task_slots[s.scope] = prov_temp_slot(graph)
	holds := make([dynamic]int, 0, len(s.spawns), graph.alloc)
	tasks: [dynamic]Pool_Task
	for spawn in s.spawns {
		hold := prov_temp_slot(graph)
		append(&holds, hold)
		graph.spawn_holds[spawn] = hold
		if spawn.task.pooled {
			if tasks == nil {
				tasks = make([dynamic]Pool_Task, 0, len(s.spawns), graph.alloc)
			}
			append(&tasks, Pool_Task{runs = spawn_runs(graph, spawn), name = spawn_callee_name(graph.k.c, spawn.call.(^Expr_Call))})
		}
	}
	graph.task_holds[s.scope] = holds[:]
	if tasks != nil {
		if graph.pool_tasks == nil {
			graph.pool_tasks = make(map[Symbol_Id][]Pool_Task, graph.alloc)
		}
		graph.pool_tasks[s.scope] = tasks[:]
	}
}

// Adds what a task holds to `slot`. Earlier tasks, of another spawn or of this
// one on an earlier iteration, still hold theirs through this spawn's own
// accesses: a redefinition alone is not a use of what it keeps, so the slot is
// used first, at the join, which is what holds it.
@(private = "file")
prov_hold_until_join :: proc(graph: ^Flow_Graph, slot: int, held: []int, span, join: Span) {
	prov_emit(graph, Prov_Event{kind = .Live, sources = prov_one(graph, slot), span = join})
	prov_emit(graph, Prov_Event{kind = .Def, slot = slot, loan = NO_LOAN, sources = prov_join(graph, prov_one(graph, slot), held), span = span})
}

// design.md "Task borrows and the join": a carrier loaded out of a place, as `l^.to`, is
// reborrowed as one passed by name is, under the capability of the parameter it is
// lent to, which only the call knows.
@(private)
prov_spawn_lends_loaded :: proc(graph: ^Flow_Graph, v: ^Expr_Call, index: int, actual: []int) {
	mutable := type_carries_borrow(graph.k.c, prov_parameter_type(graph, v, index)).mutable
	for slot in actual {
		if !graph.prov_slots[slot].loaded {
			continue
		}
		derived := prov_temp_slot(graph)
		prov_def_copy(graph, derived, slot, v.span)
		append(&graph.reborrows, Prov_Reborrow{source = slot, derived = derived, span = v.span, mutable = mutable})
		graph.spawn_held = prov_join(graph, graph.spawn_held, prov_one(graph, derived))
	}
}

// design.md "Task borrows and the join": a carrier the spawned call reborrows stays
// reborrowed until the join, as far as the reborrow's own capability says. The hold
// is the spawn site's own, so the next spawn's argument is not mistaken for what an
// earlier task holds, and a loop's chunk binding may be lent again on the next step.
@(private = "file")
prov_spawn_reborrows :: proc(graph: ^Flow_Graph, hold: int, held: []int, span, join: Span) {
	reborrows := false
	existing := len(graph.reborrows)
	for lent in held {
		for index in 0 ..< existing {
			reborrow := graph.reborrows[index]
			if reborrow.derived != lent {
				continue
			}
			reborrows = true
			append(&graph.reborrows, Prov_Reborrow {
				source = reborrow.source, derived = hold, span = span, mutable = reborrow.mutable, passes_on = reborrow.passes_on, pending = reborrow.pending,
			})
		}
		if prov_slot_may_come_to_reborrow(graph, lent) {
			reborrows = true
			append(&graph.reborrows, Prov_Reborrow{source = lent, derived = hold, span = span, passes_on = true, pending = true})
		}
	}
	if reborrows {
		prov_hold_until_join(graph, hold, held, span, join)
	}
}

// A `parallel` block's index, in the order the walk enters it.
@(private)
prov_window_bit :: proc(graph: ^Flow_Graph, scope: Symbol_Id) -> int {
	for existing, index in graph.parallel_scopes {
		if existing == scope {
			return index
		}
	}
	if graph.parallel_scopes == nil {
		graph.parallel_scopes = make([dynamic]Symbol_Id, 0, 2, graph.alloc)
	}
	append(&graph.parallel_scopes, scope)
	return len(graph.parallel_scopes) - 1
}

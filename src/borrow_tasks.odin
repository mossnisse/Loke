// What tasks and their `parallel` block may do to each other (design.md "Globals
// while tasks run", "Allocators and tasks", "Releasing before the join", "Borrows
// crossing between tasks"), solved over the reaching loans in `borrow.odin`.
package lokec

import "core:fmt"
import "core:mem"
import "core:slice"

// --------------------------------------------------------- task window --
// design.md "Globals while tasks run": from a block's first spawn to its join,
// neither a task nor the parent may write a global every thread shares, or
// reach through one that stores mutable or erased state.

// The spawns whose tasks may be running on entry to each block, one bit per
// spawn site (`task_sites`): a spawn sets its own, and a join clears those of
// its block. A path through a loop that spawns returns to the head with the
// bit set.
@(private)
solve_window :: proc(state: ^Prov_Solve) -> [][]u8 {
	graph := state.graph
	entry := make([][]u8, len(graph.blocks), graph.alloc)
	if !graph.has_window_event {
		return entry
	}
	width := (len(graph.task_sites) + 7) / 8
	exit := make([][]u8, len(graph.blocks), graph.alloc)
	for id in 0 ..< len(graph.blocks) {
		entry[id] = make([]u8, width, graph.alloc)
		exit[id] = make([]u8, width, graph.alloc)
	}
	// A block not visited yet adds nothing to its successors' entry.
	visited := make([]bool, len(graph.blocks), graph.alloc)
	mask := make([]u8, width, graph.alloc)
	queue := block_queue_from_entry(graph)
	for id in worklist_pop(&queue) {
		block := graph.blocks[id]
		mem.zero_slice(mask)
		for predecessor in block.preds {
			bytes_or(mask, exit[int(predecessor)])
		}
		copy(entry[id], mask)
		for event in block.prov {
			window_step(graph, mask, event)
		}
		if visited[id] && slice.equal(mask, exit[id]) {
			continue
		}
		visited[id] = true
		copy(exit[id], mask)
		worklist_wake_all(&queue, block.succs[:])
	}
	return entry
}

// design.md "Parallel blocks": a pooled join may run, on the joining thread,
// only tasks started on a path that reaches it. The walk emits the join's
// `thread_local` writes at every exit of the block, since a loop's back edge
// may start a task before an exit written above its spawn; here, before any
// solver reads them, those writes are dropped where no task of the block may
// have started.
@(private)
settle_pool_joins :: proc(state: ^Prov_Solve) {
	graph := state.graph
	if len(graph.pool_tasks) == 0 {
		return
	}
	window_entry := solve_window(state)
	mask := make([]u8, (len(graph.task_sites) + 7) / 8, graph.alloc)
	for block, id in graph.blocks {
		copy(mask, window_entry[id])
		kept := 0
		for event in block.prov {
			if event.joins == 0 || block_running(graph, mask, event.joins - 1) {
				block.prov[kept] = event
				kept += 1
			}
			window_step(graph, mask, event)
		}
		resize(&block.prov, kept)
	}
}

@(private = "file")
block_running :: proc(graph: ^Flow_Graph, mask: []u8, index: int) -> bool {
	cursor := 0
	for site in next_running_site(graph, mask, &cursor) {
		if graph.task_sites[site].block == index {
			return true
		}
	}
	return false
}

@(private)
window_step :: proc(graph: ^Flow_Graph, mask: []u8, event: Prov_Event) {
	#partial switch event.kind {
	case .Task_Start:
		bit_mark(mask, event.slot)
	case .Task_Join:
		for site, index in graph.task_sites {
			if site.block == event.slot {
				bit_clear(mask, index)
			}
		}
	}
}

@(private = "file")
window_is_open :: proc(mask: []u8) -> bool {
	for byte in mask {
		if byte != 0 {
			return true
		}
	}
	return false
}

// Takes the next site, from `from^` on, whose task may be running by `mask`,
// to walk those sites without listing them.
@(private = "file")
next_running_site :: proc(graph: ^Flow_Graph, mask: []u8, from: ^int) -> (site: int, ok: bool) {
	for from^ < len(graph.task_sites) {
		site = from^
		from^ += 1
		if bit_get(mask, site) {
			return site, true
		}
	}
	return 0, false
}

@(private)
Shared_Report :: struct {
	span:   Span,
	global: Symbol_Id,
}

// What has been reported, so a global met twice at one place, or a block's
// thread-exit drops, are reported once.
@(private)
Shared_Reports :: struct {
	seen:   map[Shared_Report]bool,
	scopes: map[int]bool,
}

@(private)
check_shared_event :: proc(state: ^Prov_Solve, event: Prov_Event, window: []u8, shared: ^Shared_Reports) {
	#partial switch event.kind {
	case .Task_Start:
		check_task_globals(state, event, shared)
		check_thread_exit_drops(state, event, shared)
		check_task_reservation(state, event, window)
	case .Region_Use:
		check_parent_allocator_use(state, event, window)
	case .Shared_Effect:
		if !window_is_open(window) {
			return
		}
		if event.access == .Read {
			report_shared_reach(state, event.symbol, event.span, window, shared, event.name, event.precision)
		} else {
			report_parent_write(state, event, window, shared)
		}
	case .Reach, .Escape, .Retain, .Publish:
		if !window_is_open(window) {
			return
		}
		reached := make([dynamic]Global_Effect, 0, 2, state.graph.alloc)
		for slot in event.sources {
			note_reached_globals(state, slot, event.span, &reached)
		}
		for global in reached {
			report_shared_reach(state, global.global, event.span, window, shared, precision = global.source.precision)
		}
	}
}

// What a global stores that a task sharing it could race on: a mutable
// carrier, through which any thread may write, or an erased one, which hides
// what it reaches. A read-only `dyn` view reaches what each type converted to
// it reaches. An allocator's operations are reserved instead
// (design.md "Allocators and tasks").
@(private = "file")
Shared_Hazard :: struct {
	type:   Type_Id,
	erased: bool,
	via:    Transfer_Via,
}

@(private = "file")
shared_carrier_hazard :: proc(c: ^Compiler, global: Symbol_Id) -> Shared_Hazard {
	sym := symbol_of(c, global)
	if sym == nil || sym.synchronized || type_is_allocator(c, sym.type) ||
	   type_is_region_provider(c, sym.type) {
		return {}
	}
	facts := transfer_facts(c, sym.type, through_views = true)
	if facts.mutable != INVALID_TYPE {
		return {type = facts.mutable}
	}
	if facts.viewed != INVALID_TYPE {
		return {facts.viewed, false, facts.viewed_via}
	}
	if facts.erased != INVALID_TYPE {
		return {facts.erased, true, facts.erased_via}
	}
	return {}
}

@(private = "file")
shared_hazard_text :: proc(c: ^Compiler, global: Symbol_Id, hazard: Shared_Hazard) -> string {
	name := identifier_text(c, symbol_of(c, global).name)
	consequence := hazard.erased ? "which hides what it reaches" : "through which another thread may write as well"
	return fmt.tprintf("`%s` holds %s, %s", name, view_chain_text(c, hazard.type, hazard.via), consequence)
}

// ----------------------------------------------------- join retention --
// design.md "Releasing before the join": a task may be waiting for the parent
// to drop a guard or endpoint, and the join waits for the task. At the join,
// after the block's own cleanup, a value the parent still holds that is or
// reaches an `@(wakes_on_drop)` type must borrow no storage a task of the block
// may borrow. The parent holds a local or result that is used or dropped
// later, and every parameter, which the caller holds past the join. This does
// not prove the task waits on that storage: it is conservative.
@(private)
check_join_retention :: proc(state: ^Prov_Solve, event: Prov_Event, live: []Slot_Use) {
	graph := state.graph
	c := state.k.c
	scope := graph.parallel_scopes[event.slot]
	held := make([dynamic]int, 0, 4, graph.alloc)
	if slot, found := graph.task_slots[scope]; found {
		append(&held, slot)
	}
	if holds, found := graph.task_holds[scope]; found {
		append(&held, ..holds)
	}
	if len(held) == 0 {
		return
	}
	is_task_slot := make(map[int]bool, len(held), graph.alloc)
	for slot in held {
		is_task_slot[slot] = true
	}
	reported := make(map[Symbol_Id]bool, graph.alloc)
	wakers := make(map[Symbol_Id]Type_Id, graph.alloc)
	reached := make(map[Root_Id]Reached_Storage, graph.alloc)
	for slot in 0 ..< state.slots {
		info := graph.prov_slots[slot]
		sym := symbol_of(c, info.symbol)
		if sym == nil || is_task_slot[slot] || reported[info.symbol] {
			continue
		}
		if live[slot] == .None && !kept_by_caller(sym) {
			continue
		}
		waker, cached := wakers[info.symbol]
		if !cached {
			waker = type_reaches_waker(c, sym.type)
			wakers[info.symbol] = waker
		}
		if waker == INVALID_TYPE {
			continue
		}
		// Only the marked subvalue's carriers count: a wrapper's sibling field
		// may borrow what a task borrows without holding up its wait.
		if info.content_shape == sym.type {
			waker = path_waker(c, sym.type, info.path)
			if waker == INVALID_TYPE {
				continue
			}
		}
		row := reach_row(state, state.reach, slot)
		for index in 0 ..< state.loans {
			if !bit_get(row, index) || state.ended[index] {
				continue
			}
			if task, shared := task_loan_overlapping(state, held[:], graph.loans[index], &reached); shared {
				report_join_retention(state, event, sym, waker, graph.loans[index], task)
				reported[info.symbol] = true
				break
			}
		}
	}
}

// A borrowed parameter: the caller keeps what it reaches past every join here.
// A `move` parameter is this procedure's own, kept only while a local would be.
@(private = "file")
kept_by_caller :: proc(sym: ^Symbol) -> bool {
	return sym.kind == .Parameter && sym.mode != .Move
}

@(private = "file")
task_loan_overlapping :: proc(state: ^Prov_Solve, held: []int, retained: Prov_Loan, reached: ^map[Root_Id]Reached_Storage) -> (Prov_Loan, bool) {
	graph := state.graph
	it := slots_loans(state, held)
	for _, index in next_live_loan(&it) {
		task := graph.loans[index]
		if loans_may_share_storage(graph, retained, task, reached) {
			return task, true
		}
	}
	return {}, false
}

// Two loans may borrow overlapping storage: one root and overlapping paths,
// or roots the body cannot tell apart. Unknown storage may be anything, and a
// parameter's may be the caller's storage another parameter or a global names,
// unless their types rule it out; a local of this body is neither.
@(private = "file")
loans_may_share_storage :: proc(graph: ^Flow_Graph, a, b: Prov_Loan, reached: ^map[Root_Id]Reached_Storage) -> bool {
	if a.root == b.root {
		return paths_overlap(a.path, b.path)
	}
	first, second := graph.roots[int(a.root)].kind, graph.roots[int(b.root)].kind
	if first == .Unknown || second == .Unknown {
		return true
	}
	external :: proc(kind: Root_Kind) -> bool {
		#partial switch kind {
		case .Param, .Static, .Thread_Local, .Materialized:
			return true
		}
		return false
	}
	if !((first == .Param && external(second)) || (second == .Param && external(first))) {
		return false
	}
	return roots_may_share_storage(graph, a.root, b.root, reached)
}

// What storage a root's symbol may borrow, by object type: `objects` holds the
// symbol's own type and the type of everything it reaches, `unknown` that it
// reaches storage of no known type.
@(private = "file")
Reached_Storage :: struct {
	objects: [dynamic]Type_Id,
	unknown: bool,
}

// design.md "Releasing before the join": two external roots share no storage
// when no object one reaches holds, inline, an object the other reaches, or
// is held by one. Storage of one type lies within storage of another only as a
// field, element, or variant, so two objects that overlap are nested.
@(private = "file")
roots_may_share_storage :: proc(graph: ^Flow_Graph, a, b: Root_Id, reached: ^map[Root_Id]Reached_Storage) -> bool {
	c := graph.k.c
	first, second := root_reached_storage(graph, a, reached), root_reached_storage(graph, b, reached)
	if first.unknown || second.unknown {
		return true
	}
	for outer in first.objects {
		for inner in second.objects {
			if type_holds_inline(c, outer, inner) || type_holds_inline(c, inner, outer) {
				return true
			}
		}
	}
	return false
}

@(private = "file")
root_reached_storage :: proc(graph: ^Flow_Graph, root: Root_Id, reached: ^map[Root_Id]Reached_Storage) -> Reached_Storage {
	if found, cached := reached[root]; cached {
		return found
	}
	c := graph.k.c
	result := Reached_Storage{objects = make([dynamic]Type_Id, 0, 8, graph.alloc)}
	if sym := symbol_of(c, graph.roots[int(root)].symbol); sym != nil && sym.type != INVALID_TYPE {
		append(&result.objects, sym.type)
		inside := make([dynamic]Type_Id, 0, 8, context.temp_allocator)
		for index := 0; index < len(result.objects) && !result.unknown; index += 1 {
			result.unknown = !collect_pointees(c, result.objects[index], &result.objects, &inside)
		}
	} else {
		result.unknown = true
	}
	reached[root] = result
	return result
}

@(private = "file")
report_join_retention :: proc(state: ^Prov_Solve, event: Prov_Event, sym: ^Symbol, waker: Type_Id, retained, task: Prov_Loan) {
	c := state.k.c
	graph := state.graph
	name := identifier_text(c, sym.name)
	root := graph.roots[int(retained.root)]
	if kept_by_caller(sym) {
		errorf(
			c, event.span, "L0733",
			"the caller keeps `%s` past this join, and it may borrow storage a task of the block borrows too; dropping it may be what the task waits for",
			name,
		)
		if sym.span.file != NO_FILE {
			add_notef(c, sym.span, "`%s` is a parameter, so ending this procedure's borrow of it does not drop it", name)
		}
	} else {
		// An owned parameter's own borrows are of what its caller passed.
		borrowed := root_phrase(root)
		if root.kind == .Param && symbol_of(c, root.symbol) == sym {
			borrowed = "storage its caller passed"
		}
		errorf(
			c, event.span, "L0733",
			"`%s` is kept past this join while it borrows %s, which a task of the block borrows too; dropping it may be what the task waits for",
			name, borrowed,
		)
		if sym.span.file != NO_FILE {
			add_notef(c, sym.span, "`%s` is declared here, outside the block; drop it or move it to a task before the join", name)
		}
	}
	if waker != sym.type {
		add_notef(c, sym.span, "it holds or reaches `%s`, which is `@(wakes_on_drop)`", type_name(c, waker))
	}
	if task.span.file != NO_FILE {
		add_notef(c, task.span, "a task borrows it here")
	}
}

// The span of the innermost `parallel` keyword whose tasks may be running.
@(private = "file")
window_block_span :: proc(state: ^Prov_Solve, window: []u8) -> Span {
	graph := state.graph
	innermost := -1
	cursor := 0
	for site in next_running_site(graph, window, &cursor) {
		innermost = max(innermost, graph.task_sites[site].block)
	}
	if innermost >= 0 {
		if scope := symbol_of(state.k.c, graph.parallel_scopes[innermost]); scope != nil {
			return scope.span
		}
	}
	return {}
}

// design.md "Allocators and tasks": two reserved sets conflict where they may
// name one region. A parameter may be any handle its caller passes, so two
// may be the same; a local region is distinct from any that existed at
// entry; an unknown region may be any of them.
@(private = "file")
reservations_conflict :: proc(a, b: Region_Set) -> bool {
	if region_is_empty(a) || region_is_empty(b) {
		return false
	}
	if a.unknown || b.unknown || a.crowded || b.crowded {
		return true
	}
	return (region_is_parameter_backed(a) && region_is_parameter_backed(b)) || a.locals & b.locals != 0
}

// The region two reserved sets may share, said as a diagnostic names it.
@(private = "file")
shared_region_text :: proc(state: ^Prov_Solve, a, b: Region_Set) -> string {
	graph := state.graph
	c := state.k.c
	if name := prov_region_name(graph, Region_Set{locals = a.locals & b.locals}); name != "" {
		return fmt.tprintf("`%s`'s allocator", name)
	}
	if region_is_parameter_backed(a) && region_is_parameter_backed(b) && graph.literal != nil {
		if owner := symbol_of(c, graph.literal.symbol); owner != nil {
			params := a.params
			for index in next_region_param(&params) {
				if index < len(owner.param_symbols) {
					if sym := symbol_of(c, owner.param_symbols[index]); sym != nil {
						return fmt.tprintf("the allocator `%s` was given", identifier_text(c, sym.name))
					}
				}
			}
		}
	}
	return "an allocator region this procedure cannot tell apart from it"
}

// What a task reserves: what its call may use and what its thread's exit drops may
// (design.md "Globals while tasks run").
@(private = "file")
task_reservation :: proc(c: ^Compiler, site: Task_Site) -> Region_Set {
	reserve := site.reserve
	for drop in c.thread_exit_drops {
		region_merge(&reserve, drop.use)
	}
	reserve.default = false
	return reserve
}

// A task reserves the regions it may use until the join, so no other task
// that may be running uses them, nor another from the same spawn in a loop.
@(private = "file")
check_task_reservation :: proc(state: ^Prov_Solve, event: Prov_Event, window: []u8) {
	graph := state.graph
	c := state.k.c
	site := graph.task_sites[event.slot]
	reserve := task_reservation(c, site)
	cursor := 0
	for other in next_running_site(graph, window, &cursor) {
		reserved := graph.task_sites[other]
		running := task_reservation(c, reserved)
		if !reservations_conflict(reserve, running) {
			continue
		}
		region := shared_region_text(state, reserve, running)
		if other == event.slot {
			errorf(
				c, event.span, "L0732",
				"this task may use %s, which the task this `spawn` started on an earlier iteration reserves until the join",
				region,
			)
			add_notef(c, event.span, "an allocator that is not the default provider serves one task at a time; give each task its own")
		} else {
			errorf(c, event.span, "L0732", "this task may use %s, which a task started earlier reserves until the join", region)
			add_notef(c, reserved.span, "that task is started here")
		}
		return
	}
}

// The parent may not use a region a running task reserves, cleanup included.
@(private = "file")
check_parent_allocator_use :: proc(state: ^Prov_Solve, event: Prov_Event, window: []u8) {
	graph := state.graph
	c := state.k.c
	cursor := 0
	for other in next_running_site(graph, window, &cursor) {
		reserved := graph.task_sites[other]
		running := task_reservation(c, reserved)
		if !reservations_conflict(event.region, running) {
			continue
		}
		errorf(
			c, event.span, "L0732",
			"this uses %s, which a running task reserves until this `parallel` block joins",
			shared_region_text(state, event.region, running),
		)
		add_notef(c, reserved.span, "that task is started here")
		return
	}
}

@(private = "file")
first_report :: proc(shared: ^Shared_Reports, span: Span, global: Symbol_Id) -> bool {
	key := Shared_Report{span = span, global = global}
	if shared.seen[key] {
		return false
	}
	shared.seen[key] = true
	return true
}

@(private = "file")
report_parent_write :: proc(state: ^Prov_Solve, event: Prov_Event, window: []u8, shared: ^Shared_Reports) {
	c := state.k.c
	if !first_report(shared, event.span, event.symbol) {
		return
	}
	sym := symbol_of(c, event.symbol)
	how := event.name if event.name != "" else "written"
	errorf(
		c, event.span, "L0731",
		"`%s` is %s while this `parallel` block's tasks may be running, and every thread shares it",
		identifier_text(c, sym.name), how,
	)
	add_notef(c, window_block_span(state, window), "a task runs from its `spawn` until this block ends")
	add_notef(c, sym.span, "declared here; write it before the first `spawn` or after the block, or make it an `Atomic` or a `thread.Mutex`")
}

// A printed argument is reached where it is read and again by the call that
// holds it, and the argument's report already names that reach.
@(private = "file")
reach_reported_within :: proc(shared: ^Shared_Reports, span: Span, global: Symbol_Id) -> bool {
	for report in shared.seen {
		if report.global == global && report.span.file == span.file && span.lo <= report.span.lo && report.span.hi <= span.hi {
			return true
		}
	}
	return false
}

@(private = "file")
report_shared_reach :: proc(
	state: ^Prov_Solve, global: Symbol_Id, span: Span, window: []u8, shared: ^Shared_Reports, callee := "", precision: Precision_Loss = {},
) {
	c := state.k.c
	hazard := shared_carrier_hazard(c, global)
	if hazard.type == INVALID_TYPE || reach_reported_within(shared, span, global) || !first_report(shared, span, global) {
		return
	}
	who := "this" if callee == "" else callee
	errorf(
		c, span, "L0731",
		"%s %s `%s` while this `parallel` block's tasks may be running: %s",
		who, reach_verb(precision), identifier_text(c, symbol_of(c, global).name), shared_hazard_text(c, global, hazard),
	)
	add_notef(c, window_block_span(state, window), "a task runs from its `spawn` until this block ends")
	add_precision_notes(c, span, precision)
}

// design.md "Minimum provenance precision": with the dependency merged, the
// reach may only seem to be there.
@(private = "file")
reach_verb :: proc(precision: Precision_Loss) -> string {
	return precision != {} ? "may reach through" : "reaches through"
}

// design.md "Spawn statements", "Global write effects": a task that calls a
// procedure value or through a `dyn` view may run any body its values or
// union hold, and a callee runs what the task passes for each callback it
// calls, so each body that writes, or reaches through, the reported global is
// named, a callback with the parameter it was passed for.
@(private = "file")
note_value_targets :: proc(state: ^Prov_Solve, call: ^Expr_Call, global: Symbol_Id, writes: bool) {
	c := state.k.c
	if call == nil || state.graph.literal == nil {
		return
	}
	verb := "writes" if writes else "reaches through"
	global_name := identifier_text(c, symbol_of(c, global).name)
	for origin in call_effect_origins(c, state.graph.literal.symbol, call, global, writes) {
		sym := symbol_of(c, origin.target)
		if sym == nil {
			continue
		}
		target_name := fmt.tprintf("`%s`", identifier_text(c, sym.name))
		if sym.proc_literal != nil {
			target_name = "the procedure literal here"
		} else if type_is_capture_record(c, sym.owner_type) {
			target_name = "the capture literal here"
		} else if sym.owner_type != INVALID_TYPE {
			target_name = fmt.tprintf("`%s.%s`", type_name(c, sym.owner_type), identifier_text(c, sym.name))
		}
		callee := symbol_of(c, origin.callee)
		if callee == nil || origin.parameter >= len(callee.param_symbols) {
			add_notef(c, sym.span, "`%s` may be %s, which %s `%s`", spawn_callee_name(c, call), target_name, verb, global_name)
			continue
		}
		parameter := symbol_of(c, callee.param_symbols[origin.parameter])
		add_notef(
			c, sym.span, "`%s` may call %s for `%s`, which %s `%s`", identifier_text(c, callee.name), target_name,
			identifier_text(c, parameter.name), verb, global_name,
		)
	}
}

// A task does what its procedure's settled summaries say, and reaches through
// what it is given.
@(private = "file")
check_task_globals :: proc(state: ^Prov_Solve, event: Prov_Event, shared: ^Shared_Reports) {
	c := state.k.c
	call := state.graph.task_sites[event.slot].call
	for global in c.global_writes[event.symbol] {
		sym := symbol_of(c, global)
		if sym == nil || sym.duration == .Thread_Local || sym.synchronized || !first_report(shared, event.span, global) {
			continue
		}
		errorf(
			c, event.span, "L0731",
			"`%s` may write `%s`, which every task and the parent share",
			event.name, identifier_text(c, sym.name),
		)
		add_notef(c, sym.span, "declared here; return what the task computes, or make it an `Atomic` or a `thread.Mutex`")
		note_value_targets(state, call, global, true)
	}
	for reached in c.reach_effects[event.symbol] {
		hazard := shared_carrier_hazard(c, reached.global)
		if hazard.type == INVALID_TYPE || !first_report(shared, event.span, reached.global) {
			continue
		}
		errorf(
			c, event.span, "L0731",
			"`%s` %s `%s`, which every task and the parent share: %s",
			event.name, reach_verb(reached.source.precision), identifier_text(c, symbol_of(c, reached.global).name),
			shared_hazard_text(c, reached.global, hazard),
		)
		note_reach_chain(c, reached)
		note_value_targets(state, call, reached.global, false)
		add_precision_notes(c, event.span, reached.source.precision)
	}
	given := make([dynamic]Global_Effect, 0, 2, state.graph.alloc)
	for slot in event.sources {
		note_reached_globals(state, slot, event.span, &given)
	}
	for reached in given {
		hazard := shared_carrier_hazard(c, reached.global)
		if hazard.type == INVALID_TYPE || !first_report(shared, event.span, reached.global) {
			continue
		}
		errorf(
			c, event.span, "L0731",
			"this task %s what `%s` stores, which every task and the parent share: %s",
			reached.source.precision != {} ? "may be given" : "is given",
			identifier_text(c, symbol_of(c, reached.global).name), shared_hazard_text(c, reached.global, hazard),
		)
		add_precision_notes(c, event.span, reached.source.precision)
	}
}

// Every task runs each `thread_local` owner's drop when its thread exits, which
// is reported once per block.
@(private = "file")
check_thread_exit_drops :: proc(state: ^Prov_Solve, event: Prov_Event, shared: ^Shared_Reports) {
	c := state.k.c
	index := state.graph.task_sites[event.slot].block
	if shared.scopes[index] {
		return
	}
	shared.scopes[index] = true
	block := event.span
	if scope := symbol_of(c, state.graph.parallel_scopes[index]); scope != nil {
		block = scope.span
	}
	for drop in c.thread_exit_drops {
		owner := symbol_of(c, drop.variable)
		hook := symbol_of(c, drop.hook)
		for global in drop.writes {
			sym := symbol_of(c, global)
			if sym == nil || sym.duration == .Thread_Local || sym.synchronized {
				continue
			}
			errorf(
				c, block, "L0731",
				"each task of this block drops `%s` when its thread exits, and its hook `%s` writes `%s`, which every thread shares",
				identifier_text(c, owner.name), identifier_text(c, hook.name), identifier_text(c, sym.name),
			)
			add_notef(c, owner.span, "`%s` is declared here", identifier_text(c, owner.name))
			add_notef(c, hook.span, "`%s` is declared here", identifier_text(c, hook.name))
		}
		for reached in drop.reach {
			hazard := shared_carrier_hazard(c, reached.global)
			if hazard.type == INVALID_TYPE {
				continue
			}
			errorf(
				c, block, "L0731",
				"each task of this block drops `%s` when its thread exits, and its hook `%s` %s `%s`: %s",
				identifier_text(c, owner.name), identifier_text(c, hook.name), reach_verb(reached.source.precision),
				identifier_text(c, symbol_of(c, reached.global).name), shared_hazard_text(c, reached.global, hazard),
			)
			add_notef(c, owner.span, "`%s` is declared here", identifier_text(c, owner.name))
			add_precision_notes(c, block, reached.source.precision)
		}
	}
}

// How many calls of a reach chain the notes show. Recursive calls make the
// chain a cycle, which this bound also ends.
@(private = "file")
REACH_CHAIN_NOTES :: 8

// Where a task's summarized reach comes from: each call on the way, from the
// spawned procedure's, to the access itself. The run procedure's own call of
// the spawned one is the spawn, and is not repeated.
@(private = "file")
note_reach_chain :: proc(c: ^Compiler, reached: Global_Effect) {
	source := reached.source
	for step := 0; step < REACH_CHAIN_NOTES; step += 1 {
		via := symbol_of(c, source.via)
		if via == nil {
			if source.span != (Span{}) {
				add_notef(c, source.span, "reached here")
			}
			return
		}
		if step > 0 {
			add_notef(c, source.span, "through `%s`", identifier_text(c, via.name))
		}
		next, found := Effect_Source{}, false
		for entry in c.reach_effects[source.via] {
			if entry.global == reached.global {
				next, found = entry.source, true
				break
			}
		}
		if !found {
			return
		}
		source = next
	}
}

// design.md "Borrows crossing between tasks": each thread has its own
// `thread_local` storage, so no borrow of it crosses between a task and its
// parent, in either direction. A worker may use its own within itself.
@(private)
check_crossing :: proc(state: ^Prov_Solve, event: Prov_Event) {
	graph := state.graph
	it := slots_loans(state, event.sources)
	for _, index in next_live_loan(&it) {
		loan := graph.loans[index]
		root := graph.roots[int(loan.root)]
		if root.kind != .Thread_Local || loan.written_back {
			continue
		}
		// design.md "Minimum provenance precision": with the dependency merged,
		// the borrow may only seem to be there.
		merged := state.diagnostic_precision != {}
		if event.verb == "result" {
			errorf(
				state.k.c, event.span, "L0730",
				"this task's result %s a %s of %s, which is the worker's own `thread_local` storage, so it cannot cross to the parent",
				merged ? "may hold" : "holds", loan.what, root_phrase(root),
			)
		} else {
			errorf(
				state.k.c, event.span, "L0730",
				"this task %s a %s of %s, which is the parent's own `thread_local` storage, so it cannot cross to the task",
				merged ? "may be handed" : "is handed", loan.what, root_phrase(root),
			)
		}
		if root.span.file != NO_FILE {
			add_notef(state.k.c, root.span, "each thread has its own `thread_local` storage, which ends with that thread")
		}
		return
	}
}

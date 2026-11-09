// What a body's provenance leaves for the summaries its callers read, collected by
// `summarize_body` in `borrow.odin`: the carriers a call moves among what its arguments
// hold, the `thread_local` storage it writes, the regions it leaves in what it may
// write, and what its borrows and regions may escape into.
package lokec

import "core:mem"
import "core:slice"

// design.md "Values that contain borrows": what a body may store in the storage
// a writable parameter names out of what that argument held, as `links[0] =
// links[1]` or `pair^.a = pair^.b` (`prov_call_carrier_moves`).
Carrier_Move :: struct {
	// The carrier types stored there, or `any` for every one.
	types: []Type_Id,
	any:   bool,
	// A mutable carrier stored there may also stay where it was read, unlike
	// one read from below the place it lands, as `list^.head = list^.head^.next`
	// (design.md "Weakening and reborrows").
	copied: bool,
}

@(private)
graph_may_move_carriers :: proc(graph: ^Flow_Graph) -> bool {
	for block in graph.blocks {
		for event in block.prov {
			switch {
			case event.kind == .Publish && len(event.sources) > 0 && len(event.into) > 0, event.kind == .Rearrange:
				return true
			case event.kind == .Def && len(event.sources) > 0:
				if slot_stores_in_inout(graph, event.slot) {
					return true
				}
			}
		}
	}
	return false
}

// Whether `slot` is storage of an `inout` parameter: a store into it needs no
// carrier to name the caller's storage.
@(private = "file")
slot_stores_in_inout :: proc(graph: ^Flow_Graph, slot: int) -> bool {
	sym := symbol_of(graph.k.c, graph.prov_slots[slot].symbol)
	return sym != nil && sym.kind == .Parameter && sym.mode == .Inout
}

// A `Carrier_Move` a store makes into the storage parameter root `root` names.
@(private = "file")
Noted_Move :: struct {
	root: Root_Id,
	move: Carrier_Move,
}

// `Carrier_Move` of a body, read off each store that reaches its end of solving. A
// store that copies counts as one only if the copy outlasts the body, which a later
// store over the place it was read from ends, as `held := links[0]; links[0] =
// links[1]; links[1] = held;` does (`copies_outlast_body`).
@(private)
collect_carrier_moves :: proc(state: ^Prov_Solve, declaration: Symbol_Id) -> bool {
	graph := state.graph
	moves := make([dynamic]Noted_Move, graph.alloc)
	for block in graph.blocks {
		if !solve_enter_block(state, block) {
			continue
		}
		for event in block.prov {
			#partial switch event.kind {
			case .Publish:
				note_published_move(state, event, &moves)
			case .Def:
				note_inout_move(state, event, &moves)
			case .Rearrange:
				note_rearranged_move(state, event, &moves)
			}
			run_prov_event(state, event, state.reach, state.ended)
		}
	}
	copies := false
	for noted in moves {
		copies ||= noted.move.copied
	}
	if copies {
		link_landed_stores(state)
		resolve_content_reads(state)
		prov_settle_pending_reborrows(graph)
		solve_links_held(state)
	}
	changed := false
	outlast := make(map[Root_Id]bool, graph.alloc)
	for noted in moves {
		move := noted.move
		if move.copied {
			if noted.root not_in outlast {
				outlast[noted.root] = copies_outlast_body(state, noted.root)
			}
			move.copied = outlast[noted.root]
		}
		changed = merge_carrier_move(graph.k.c, declaration, graph.roots[int(noted.root)].param_index, move) || changed
	}
	return changed
}

// design.md "Weakening and reborrows": whether a carrier the body copied within the
// storage parameter root `root` names may still be in two places of it when the body
// ends. A carrier read out of that storage holds a link from the slot it was read from
// until the slot holds another (`end_links_of_value`), so a copy is left only where one
// of the storage's slots holds a link from another, at an end of the body. A reordering's
// link moves the carrier, leaving none behind. With no links solved, nothing says the
// copy ended.
@(private = "file")
copies_outlast_body :: proc(state: ^Prov_Solve, root: Root_Id) -> bool {
	graph := state.graph
	if state.link_row_bytes == 0 {
		return true
	}
	storage := make([]bool, state.slots, graph.alloc)
	for loan, slots in graph.caller_slots {
		if graph.loans[int(loan)].root == root {
			for slot in slots { storage[slot] = true }
		}
	}
	for slot in root_own_slots(graph, graph.roots[int(root)]) {
		storage[slot] = true
	}
	for block in graph.blocks {
		if len(block.succs) > 0 || block.unwind {
			continue
		}
		block_table_put(block.links_exit, state.links_held)
		for held, slot in state.links_held {
			if held == 0 || !storage[slot] {
				continue
			}
			row := state.link_rows.rows[held]
			for link, index in graph.reborrows {
				if bit_get(row, index) && storage[link.source] && !link.moved {
					return true
				}
			}
		}
	}
	return false
}

// A store through carriers moves what it stores to every loan they hold.
@(private = "file")
note_published_move :: proc(state: ^Prov_Solve, event: Prov_Event, moves: ^[dynamic]Noted_Move) {
	graph := state.graph
	mem.zero_slice(state.merged)
	for source in event.sources {
		bytes_or(state.merged, reach_row(state, state.reach, source))
	}
	if event.strips {
		for slot in event.into {
			for &byte, index in state.merged {
				byte &= ~reach_row(state, state.reach, slot)[index]
			}
		}
	}
	types, any := carried_types(graph.k.c, event.carried, graph.alloc)
	it := slots_loans(state, event.into)
	for _, index in next_live_loan(&it) {
		loan := graph.loans[index]
		// Reordering copies nothing: no place is deep enough to count.
		level := event.permutes ? -1 : loan.depth + 1
		note_carrier_move(state, moves, loan.root, level, types, any)
	}
}

// A definition of an `inout` parameter's storage moves what it stores there.
@(private = "file")
note_inout_move :: proc(state: ^Prov_Solve, event: Prov_Event, moves: ^[dynamic]Noted_Move) {
	graph := state.graph
	if len(event.sources) == 0 || !slot_stores_in_inout(graph, event.slot) {
		return
	}
	mem.zero_slice(state.merged)
	for source in event.sources {
		if source != event.slot {
			bytes_or(state.merged, reach_row(state, state.reach, source))
		}
	}
	types, any := carried_types(graph.k.c, slot_carrier_type(graph, event.slot), graph.alloc)
	symbol := graph.prov_slots[event.slot].symbol
	for root, at in graph.roots {
		if root.kind == .Param && root.symbol == symbol {
			note_carrier_move(state, moves, Root_Id(at), 0, types, any)
		}
	}
}

// A call's own moves apply to every parameter its argument's carriers name.
@(private = "file")
note_rearranged_move :: proc(state: ^Prov_Solve, event: Prov_Event, moves: ^[dynamic]Noted_Move) {
	graph := state.graph
	it := slots_loans(state, event.into)
	for _, index in next_live_loan(&it) {
		root := graph.loans[index].root
		if graph.roots[int(root)].kind == .Param {
			append(moves, Noted_Move{root, event.rearranged})
		}
	}
}

// A store of `types` into parameter storage at `root`, at `level` loads below
// the parameter, of what `state.merged` holds: a move when that holds what the
// same parameter held, and a copy when it came from no deeper than it lands.
@(private = "file")
note_carrier_move :: proc(
	state: ^Prov_Solve, moves: ^[dynamic]Noted_Move, root: Root_Id, level: int, types: []Type_Id, any: bool,
) {
	graph := state.graph
	c := graph.k.c
	descriptor := graph.roots[int(root)]
	if descriptor.kind != .Param {
		return
	}
	type := symbol_of(c, descriptor.symbol).type
	pointee := carrier_pointee_shape(c, type)
	held, copied := false, false
	for loan, index in graph.loans {
		if loan.root != root || !loan.content || !bit_get(state.merged, index) {
			continue
		}
		held = true
		// A mutable carrier stored as a read-only one is a reborrow all the same.
		// One pointee path's loan says whether that path holds one; otherwise
		// the path it is on is not known.
		mutable := loan.mutable
		if loan.pointee == 0 && len(pointee) > 0 {
			mutable = false
			for path in pointee { mutable ||= path.mutable }
		}
		copied ||= mutable && loan.depth <= level
	}
	if held {
		append(moves, Noted_Move{root, Carrier_Move{types, any, copied}})
	}
}

// The carriers in a value of `type`, or `any` when they are not all known. An
// allocator and a region provider are shared by design, so moving one says
// nothing (design.md "Weakening and reborrows").
carried_types :: proc(c: ^Compiler, type: Type_Id, allocator: mem.Allocator) -> (out: []Type_Id, any: bool) {
	if type == INVALID_TYPE {
		return nil, true
	}
	list := make([dynamic]Type_Id, 0, 2, allocator)
	add :: proc(c: ^Compiler, list: ^[dynamic]Type_Id, type: Type_Id) {
		if !type_is_region_provider(c, type) && !type_is_allocator(c, type) && !slice.contains(list[:], type) {
			append(list, type)
		}
	}
	if type_is_carrier(c, type) {
		add(c, &list, type)
		return list[:], false
	}
	for path in carrier_shape(c, type) {
		if path.truncated {
			return nil, true
		}
		add(c, &list, path.type)
	}
	return list[:], false
}

@(private = "file")
merge_carrier_move :: proc(c: ^Compiler, declaration: Symbol_Id, index: int, move: Carrier_Move) -> bool {
	if !move.any && len(move.types) == 0 {
		return false
	}
	rows, found := c.carrier_moves[declaration]
	if !found {
		rows = make([]Carrier_Move, len(symbol_of(c, declaration).param_symbols), c.semantic_allocator)
		c.carrier_moves[declaration] = rows
	}
	row := &rows[index]
	changed := move.any && !row.any || move.copied && !row.copied
	row.any ||= move.any
	row.copied ||= move.copied
	for type in move.types {
		changed = set_add(&row.types, type, c.semantic_allocator) || changed
	}
	return changed
}

// What a call may do to each of its `count` arguments' carriers, by argument,
// from the summary of every body it may run; `consulted` collects those. A
// foreign procedure may do anything with what it can reach.
call_carrier_moves :: proc(
	c: ^Compiler, call: ^Expr_Call, body: Symbol_Id, count: int, consulted: ^[dynamic]Symbol_Id, allocator: mem.Allocator,
) -> []Carrier_Move {
	if !c.global_writes_ready || !call_writes_caller(c, call) {
		return nil
	}
	targets, _ := call_summary_targets(c, call, body, forward = false)
	out := make([]Carrier_Move, count, allocator)
	for index := 0; index < len(targets); index += 1 {
		target := targets[index]
		if original, shifted := c.receiver_contract_of[target]; shifted {
			target = original
		}
		if is_contract_join(c, target) {
			append(&targets, ..symbol_of(c, target).members)
			continue
		}
		sym := symbol_of(c, target)
		if sym == nil {
			continue
		}
		append(consulted, target)
		if sym.is_foreign {
			for &move in out { move.any = true }
			continue
		}
		shift := count - len(sym.param_symbols)
		for row, position in c.carrier_moves[target] {
			if at := position + shift; at >= 0 && at < count {
				out[at].any ||= row.any
				out[at].copied ||= row.copied
				for type in row.types {
					set_add(&out[at].types, type, allocator)
				}
			}
		}
	}
	return out
}

// Whether a carrier of `source` may have been stored where one of `destination`
// is: it is the same carrier, perhaps weakened, or `destination` erases what it
// holds. An unshaped slot stands for every carrier below it.
@(private)
carrier_may_land_in :: proc(c: ^Compiler, destination, source: Type_Id) -> bool {
	if destination == source || destination == INVALID_TYPE || source == INVALID_TYPE {
		return true
	}
	into, from := underlying_info(c, destination), underlying_info(c, source)
	if into == nil || from == nil {
		return true
	}
	#partial switch into.kind {
	case .Pointer, .Slice, .String_View, .CString_View:
		return into.kind == from.kind && into.element == from.element
	}
	return true
}

// The carrier type a slot holds, or INVALID_TYPE for one standing for every
// carrier below its path.
@(private)
slot_carrier_type :: proc(graph: ^Flow_Graph, index: int) -> Type_Id {
	slot := graph.prov_slots[index]
	if slot.content_truncated || slot.content_type != INVALID_TYPE {
		return slot.content_type
	}
	if bare, exists := graph.slot_by_symbol[slot.symbol]; exists && bare == index {
		return symbol_of(graph.k.c, slot.symbol).type
	}
	return INVALID_TYPE
}

// design.md "Values that contain borrows": a call moves carriers among the
// storage its argument's mutable carriers lead to, so each there of a type the
// call moves may now hold what any there of a type it may have come from held.
@(private)
rearrange_carriers :: proc(state: ^Prov_Solve, event: Prov_Event, reach: []u8) {
	clear(&state.rearranged)
	load_writable_content(state, event, reach, &state.rearranged)
	reads := state.rearranged
	join :: proc(state: ^Prov_Solve, reach: []u8, reads: []int, type: Type_Id, every: bool) {
		graph := state.graph
		mem.zero_slice(state.merged)
		loss: Precision_Loss
		for index in reads {
			if every || carrier_may_land_in(graph.k.c, type, slot_carrier_type(graph, index)) {
				bytes_or(state.merged, reach_row(state, reach, index))
				loss |= state.precision[index]
			}
		}
		for index in reads {
			if every || slot_carrier_type(graph, index) == type || slot_carrier_type(graph, index) == INVALID_TYPE {
				bytes_or(reach_row_written(state, reach, index), state.merged)
				state.precision[index] |= loss
			}
		}
	}
	if event.rearranged.any {
		join(state, reach, reads[:], INVALID_TYPE, true)
		return
	}
	for type in event.rearranged.types {
		join(state, reach, reads[:], type, false)
	}
}

// The bodies whose summaries this one read. A callback's summary is read only
// once a callee is seen to call it, so the set may grow on a later round.
@(private)
record_summary_dependencies :: proc(c: ^Compiler, declaration: Symbol_Id, callees: []Symbol_Id) {
	known := c.result_summary_dependencies[declaration]
	added := 0
	for callee in callees {
		if !slice.contains(known, callee) {
			added += 1
		}
	}
	if added == 0 {
		return
	}
	grown := make([dynamic]Symbol_Id, 0, len(known) + added, c.semantic_allocator)
	append(&grown, ..known)
	for callee in callees {
		if !slice.contains(grown[:], callee) {
			append(&grown, callee)
		}
	}
	c.result_summary_dependencies[declaration] = grown[:]
}

@(private)
graph_borrows_thread_local :: proc(graph: ^Flow_Graph) -> bool {
	for root in graph.roots {
		if root.kind == .Thread_Local || root.forwarded {
			return true
		}
	}
	return false
}

// design.md "Borrows crossing between tasks": for each parameter, a
// `thread_local` global whose borrow the body may store in the caller storage
// it names, and what a callback it received may leave there, read off each
// store there. A call leaves the same borrow in its argument
// (`prov_call_thread_local_writes`), so a task's call that hands one back to
// its parent is seen at the spawn.
@(private)
collect_thread_local_writes :: proc(state: ^Prov_Solve, declaration: Symbol_Id) -> bool {
	graph := state.graph
	c := state.k.c
	written, found := c.thread_local_writes[declaration]
	if !found {
		written = make([]Symbol_Id, len(symbol_of(c, declaration).param_symbols), c.semantic_allocator)
		for &global in written {
			global = INVALID_SYMBOL
		}
		c.thread_local_writes[declaration] = written
	}
	changed := false
	for block in graph.blocks {
		if !solve_enter_block(state, block) {
			continue
		}
		for event in block.prov {
			if event.kind == .Retain {
				changed = note_thread_local_write(state, event, declaration, written) || changed
			}
			run_prov_event(state, event, state.reach, state.ended)
		}
	}
	return changed
}

// The first `thread_local` global a stored value borrows, and each callback's
// stand-in it holds, recorded for each parameter whose caller storage receives
// it: the stored place's root, or the roots of the carrier it was written
// through.
@(private = "file")
note_thread_local_write :: proc(state: ^Prov_Solve, event: Prov_Event, declaration: Symbol_Id, written: []Symbol_Id) -> bool {
	graph := state.graph
	global, forwarded := stored_thread_facts(state, event.sources)
	if global == INVALID_SYMBOL && len(forwarded) == 0 {
		return false
	}
	destinations := make([dynamic]Prov_Root, 0, 2, context.temp_allocator)
	if len(event.into) > 0 {
		it := slots_loans(state, event.into)
		for _, index in next_live_loan(&it) {
			append(&destinations, graph.roots[int(graph.loans[index].root)])
		}
	} else if event.root != NO_ROOT {
		append(&destinations, graph.roots[int(event.root)])
	}
	changed := false
	for root in destinations {
		if root.kind != .Param || root.param_index >= len(written) {
			continue
		}
		if global != INVALID_SYMBOL && written[root.param_index] == INVALID_SYMBOL {
			written[root.param_index] = global
			changed = true
		}
		for stand_in in forwarded {
			write := Callback_Write{callback = stand_in.param_index, argument = stand_in.argument, into = root.param_index}
			changed = add_unique(state.k.c, &state.k.c.callback_thread_local_writes, declaration, write) || changed
		}
	}
	return changed
}

// What a store's sources hold that a task's write-back cares about: the first
// `thread_local` global they borrow, and each callback's stand-in.
@(private = "file")
stored_thread_facts :: proc(state: ^Prov_Solve, sources: []int) -> (global: Symbol_Id, forwarded: []Prov_Root) {
	graph := state.graph
	global = INVALID_SYMBOL
	out := make([dynamic]Prov_Root, 0, 2, context.temp_allocator)
	it := slots_loans(state, sources)
	for _, index in next_live_loan(&it) {
		root := graph.roots[int(graph.loans[index].root)]
		switch {
		case root.forwarded:
			append(&out, root)
		case root.kind != .Thread_Local || global != INVALID_SYMBOL:
		case root.symbol != INVALID_SYMBOL:
			global = root.symbol
		case:
			global = root.origin
		}
	}
	return global, out[:]
}

param_writes_caller :: proc(c: ^Compiler, param: ^Symbol) -> bool {
	return param != nil && (param.mode == .Inout || carrier_is_mutable(c, param.type) || prov_type_reaches_mutable(c, param.type))
}

@(private)
proc_may_write_owners :: proc(c: ^Compiler, sym: ^Symbol) -> bool {
	for id in sym.param_symbols {
		if param_writes_caller(c, symbol_of(c, id)) {
			return true
		}
	}
	return false
}

// What a body leaves in each argument it may write: the regions, those backing
// owners rather than allocator handles, and the same by path, to which a call
// resolves what stays within one argument.
Written_Summary :: struct {
	regions: []Region_Set,
	owners:  []Region_Set,
	content: [][]Prov_Region_Content,
}

// design.md "Allocator regions and region provenance": the regions of owners a
// body leaves in each argument it may write, read off its flow-insensitive
// region facts. A region local to the body is its own error there.
@(private)
collect_written_regions :: proc(c: ^Compiler, graph: ^Flow_Graph, declaration: Symbol_Id, sym: ^Symbol) -> bool {
	summary, found := c.written_summaries[declaration]
	if !found {
		count := len(sym.param_symbols)
		summary = Written_Summary{
			regions = make([]Region_Set, count, c.semantic_allocator),
			owners  = make([]Region_Set, count, c.semantic_allocator),
			content = make([][]Prov_Region_Content, count, c.semantic_allocator),
		}
		c.written_summaries[declaration] = summary
	}
	changed := false
	for id, index in sym.param_symbols {
		if !param_writes_caller(c, symbol_of(c, id)) {
			continue
		}
		// The whole-argument unions join the path-indexed row; there a copy
		// within the argument stands for the whole argument, and only what is
		// not an allocator handle backs an owner.
		content := prov_written_parameter_content(graph, id, index)
		for entry in content {
			region := entry.region
			if from, copied := entry.from.?; copied {
				// Moving what any element holds to any element leaves the argument
				// nothing it did not hold, so only its row says so.
				if prov_same_path(from.path, entry.path) {
					continue
				}
				// A carrier copied within the argument leads below what it names.
				region = {}
				if type_carries_borrow(c, prov_parameter_type_at(c, symbol_of(c, id), from.path)).any {
					region_add_loaded_param(&region, index)
				} else {
					region_add_param(&region, index)
				}
			}
			changed = region_merge(&summary.regions[index], region) || changed
			if !entry.handle {
				changed = region_merge(&summary.owners[index], region) || changed
			}
		}
		changed = merge_written_content(c, &summary.content[index], content) || changed
	}
	return changed
}

// Merges a body's path-indexed content into a parameter's summary row. A
// region reaching a new path is growth even when the row's union is unchanged.
// Paths stop at the written-alias depth, as a recursive call can lengthen them
// on every round; a cut entry reaches every path below it.
@(private = "file")
merge_written_content :: proc(c: ^Compiler, row: ^[]Prov_Region_Content, from: []Prov_Region_Content) -> bool {
	changed := false
	next: for entry in from {
		entry := entry
		if len(entry.path) > WRITTEN_ALIAS_DEPTH {
			entry.path, entry.own = entry.path[:WRITTEN_ALIAS_DEPTH], false
		}
		if from, copied := entry.from.?; copied && len(from.path) > WRITTEN_ALIAS_DEPTH {
			entry.from = Prov_Region_Source{from.path[:WRITTEN_ALIAS_DEPTH], .All}
		}
		for &existing in row^ {
			if prov_same_region_content(existing, entry) {
				changed = region_merge(&existing.region, entry.region) || changed
				continue next
			}
		}
		grown := make([]Prov_Region_Content, len(row^) + 1, c.semantic_allocator)
		copy(grown, row^)
		grown[len(row^)] = prov_clone_region_content(entry, entry.region, c.semantic_allocator)
		row^ = grown
		changed = true
	}
	return changed
}

// The path-indexed written content of a call's declaration, or not found for a
// contract join, whose members a call takes together as whole regions.
written_content_summary :: proc(c: ^Compiler, declaration: Symbol_Id) -> ([][]Prov_Region_Content, bool) {
	if original, shifted := c.receiver_contract_of[declaration]; shifted {
		rows, found := written_content_summary(c, original)
		if !found {
			return nil, false
		}
		out := make([][]Prov_Region_Content, len(rows) + 1, context.temp_allocator)
		for row, index in rows {
			shifted_row := make([]Prov_Region_Content, len(row), context.temp_allocator)
			for entry, position in row {
				shifted_row[position] = entry
				shifted_row[position].region = receiver_region(entry.region)
			}
			out[index + 1] = shifted_row
		}
		return out, true
	}
	if is_contract_join(c, declaration) {
		return nil, false
	}
	summary, found := c.written_summaries[declaration]
	return summary.content, found
}

// The written regions of a call's declaration; a join's members are unioned.
// `owners` asks only for the regions backing owners left there, without an
// allocator handle's.
written_region_summary :: proc(c: ^Compiler, declaration: Symbol_Id, owners := false) -> ([]Region_Set, bool) {
	// A view's own row is empty: a plain receiver is not written.
	if original, shifted := c.receiver_contract_of[declaration]; shifted {
		written, found := written_region_summary(c, original, owners)
		if !found {
			return nil, false
		}
		out := make([]Region_Set, len(written) + 1, context.temp_allocator)
		for set, index in written {
			out[index + 1] = receiver_region(set)
		}
		return out, true
	}
	if !is_contract_join(c, declaration) {
		summary, found := c.written_summaries[declaration]
		return owners ? summary.owners : summary.regions, found
	}
	out: []Region_Set
	for member in symbol_of(c, declaration).members {
		summary, found := c.written_summaries[member]
		if !found {
			continue
		}
		written := owners ? summary.owners : summary.regions
		if out == nil {
			out = make([]Region_Set, len(written), context.temp_allocator)
		}
		for set, index in written {
			if index < len(out) {
				region_merge(&out[index], set)
			}
		}
	}
	return out, out != nil
}

// Every loan that can reach a `return` becomes a possibility in the summary.
@(private)
collect_escape_provenance :: proc(state: ^Prov_Solve, declaration: Symbol_Id, summary: ^Result_Provenance) -> bool {
	changed := false
	for block in state.graph.blocks {
		if !solve_enter_block(state, block) {
			continue
		}
		for event in block.prov {
			if event.kind == .Escape {
				changed = merge_escape_event(state, event, declaration, summary) || changed
			}
			run_prov_event(state, event, state.reach, state.ended)
		}
	}
	return changed
}

@(private = "file")
merge_escape_event :: proc(state: ^Prov_Solve, event: Prov_Event, declaration: Symbol_Id, into: ^Result_Provenance) -> bool {
	graph := state.graph
	changed := region_merge(&into.region, event.region)
	for escaped in event.region_content {
		for &content in into.region_content {
			if prov_same_path(content.path, escaped.path) {
				changed = region_merge(&content.region, escaped.region) || changed
			}
		}
	}
	for source in event.sources {
		slot := graph.prov_slots[source]
		changed = merge_precision(&into.precision, state.precision[source]) || changed
		row := reach_row(state, state.reach, source)
		for &content in into.content {
			if slot.content_shape == into.content_type && !paths_overlap(slot.path, content.path.steps) {
				continue
			}
			changed = merge_precision(&content.dependencies.precision, state.precision[source]) || changed
			for index in 0 ..< state.loans {
				if bit_get(row, index) && !graph.roots[int(graph.loans[index].root)].forwarded {
					changed = merge_loan_provenance(state, &content.dependencies, index) || changed
				}
			}
		}
		for index in 0 ..< state.loans {
			if !bit_get(row, index) {
				continue
			}
			// What a callback leaves is the caller's to name.
			if stand_in := graph.roots[int(graph.loans[index].root)]; stand_in.forwarded {
				read := Callback_Read{callback = stand_in.param_index, argument = stand_in.argument}
				changed = add_unique(state.k.c, &state.k.c.callback_result_reads, declaration, read) || changed
				continue
			}
			changed = merge_loan_provenance(state, &into.dependencies, index) || changed
		}
	}
	return changed
}

@(private = "file")
merge_loan_provenance :: proc(state: ^Prov_Solve, into: ^Result_Dependencies, index: int) -> bool {
	loan := state.graph.loans[index]
	root := state.graph.roots[int(loan.root)]
	one := Result_Dependencies{}
	switch root.kind {
	case .Param:
		if loan.depth > 0 && root.param_index < len(into.param_loads) {
			bit := u8(1) << u8(loan.depth - 1)
			changed := into.param_loads[root.param_index] & bit == 0
			changed = merge_param_load_paths(state, into, root, loan) || changed
			into.param_loads[root.param_index] |= bit
			return changed
		}
		if root.param_index >= 0 && root.param_index < len(into.params) {
			changed := merge_param_paths(state, into, root, loan)
			if !into.params[root.param_index] {
				into.params[root.param_index] = true
				changed = true
			}
			return changed
		}
		one.unknown = true
	case .Static, .Thread_Local:
		if root.symbol != INVALID_SYMBOL {
			one.globals = []Symbol_Id{root.symbol}
		} else if root.kind == .Static {
			one.static = true
		} else {
			one.thread = true
		}
	case .Materialized:
		one.static = true
	case .Local, .Slice_Literal, .Temporary, .Provider:
		one.local = true
	case .Unknown:
		one.unknown = true
	}
	return merge_provenance(into, one, state.k.c.semantic_allocator)
}

// Narrows a parameter dependency to the shape paths the loan overlaps, so a
// caller substitutes only those fields. Nil means the whole parameter.
@(private)
merge_param_paths :: proc(
	state: ^Prov_Solve,
	into: ^Result_Dependencies,
	root: Prov_Root,
	loan: Prov_Loan,
) -> bool {
	index := root.param_index
	if index >= len(into.param_paths) {
		return false
	}
	sym := symbol_of(state.k.c, root.symbol)
	shape: []Carrier_Path
	if sym != nil && !type_is_carrier(state.k.c, sym.type) {
		shape = carrier_shape(state.k.c, sym.type)
	}
	if len(shape) == 0 {
		changed := len(into.param_paths[index]) > 0
		into.param_paths[index] = nil
		return changed
	}
	if into.param_paths[index] == nil && into.params[index] {
		return false // already widened to the whole parameter
	}
	if into.param_paths[index] == nil {
		into.param_paths[index] = make([]bool, len(shape), state.k.c.semantic_allocator)
	}
	loan_path := slice.clone(loan.path, state.graph.alloc)
	widen_summary_map_path(state.k.c, sym.type, loan_path)
	changed := merge_precision(&into.precision, path_precision(loan_path))
	matched := false
	for path, position in shape {
		if !paths_overlap(path.steps, loan_path) {
			continue
		}
		matched = true
		if !into.param_paths[index][position] {
			into.param_paths[index][position] = true
			changed = true
		}
	}
	if !matched {
		// The parameter's own storage (`&self.count`), which no carrier path
		// describes: depend on all of it.
		into.param_paths[index] = nil
		return true
	}
	return changed
}

// Narrows a load dependency to the pointee path the loan's first load goes
// along, and below it to the path its last goes along where the loan says
// (`Prov_Loan.last`), so a caller loads only through those fields. Nil means every
// path. Runs before the load's bit is set, which is how a first narrowing tells
// itself apart from a dependency already widened to the whole pointee.
@(private = "file")
merge_param_load_paths :: proc(
	state: ^Prov_Solve,
	into: ^Result_Dependencies,
	root: Prov_Root,
	loan: Prov_Loan,
) -> bool {
	index := root.param_index
	if index >= len(into.param_load_paths) {
		return false
	}
	c := state.k.c
	fresh := into.param_loads[index] & (u8(1) << u8(loan.depth - 1)) == 0
	sym := symbol_of(c, root.symbol)
	pointee := sym == nil ? nil : carrier_pointee_shape(c, sym.type)
	paths := load_paths_at(into, index, loan.depth, c.semantic_allocator)
	// The pointee path the first load goes along: the loan's, or the one there is.
	along := -1
	switch {
	case loan.pointee > 0 && loan.pointee <= len(pointee):
		along = loan.pointee - 1
	case loan.pointee == 0 && len(pointee) == 1:
		along = 0
	}
	// Whether a loan went along it before, read before `first` takes this one in.
	seen := !fresh && along >= 0 && load_goes_along(paths.first, along)
	changed := narrow_path_row(&paths.first, loan.pointee, len(pointee), fresh, c.semantic_allocator)
	if along < 0 || (!fresh && paths.last == nil) {
		// Along any of several paths, or already below every path.
		if paths.last == nil {
			return changed
		}
		paths.last = nil
		return true
	}
	if paths.last == nil {
		paths.last = make([][]bool, len(pointee), c.semantic_allocator)
	}
	count := len(last_load_shape(c, pointee[along], loan.depth))
	return narrow_path_row(&paths.last[along], loan.last, count, !seen, c.semantic_allocator) || changed
}

// Marks path `position` (plus one) of `count` in `row`, or widens the row to
// every path when `position` names none. `fresh` says nothing has been marked yet,
// as a nil row is also one widened already.
@(private = "file")
narrow_path_row :: proc(row: ^[]bool, position, count: int, fresh: bool, allocator: mem.Allocator) -> bool {
	if position == 0 || position > count {
		if row^ == nil {
			return false
		}
		row^ = nil
		return true
	}
	if row^ == nil {
		if !fresh {
			return false // already widened to every path
		}
		row^ = make([]bool, count, allocator)
	}
	if row[position - 1] {
		return false
	}
	row[position - 1] = true
	return true
}

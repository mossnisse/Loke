// A mutable loan an argument takes is reserved until its call starts
// (design.md "Weakening and reborrows").
package lokec

// One reserved loan. Where the argument is evaluated it takes `hold`, read-only
// loans that keep its place valid and unwritten while the arguments after it are
// evaluated. The walk records the events of the mutable loan there too, since
// what they name is known there, but they are taken out of the block again
// (`prov_end_reserve`) and run where the call starts (`prov_start_reserved`).
//
// A place reached through carriers is found again through them when the call
// starts. `watched` are the places holding the named ones: an argument after it
// that wrote one, as `g(inout p)` in `p^.add(g(inout p))`, leaves the carrier
// naming other storage than the receiver that was computed. The loan then starts
// where the argument was evaluated, as it did before loans were reserved: its
// events go back where the walk recorded them, and the hold is never used.
Prov_Reserved :: struct {
	index:   int,
	hold:    []int,
	block:   Block_Id,
	first:   int,
	events:  []Prov_Event,
	// The first slot the recorded events made.
	slots:   int,
	// What the argument lends the call, and of that what stays live through it.
	actual:  []int,
	lent:    []int,
	watched: []Prov_Reserved_Place,
	// The first of `Prov_State.reserved_writes` made after the argument.
	writes:  int,
	// The recorded events stay where they are: there is no block to move them out
	// of, or one of them is a recorded operation's, which is replaced where it is
	// (`prov_materialize_events`).
	kept:    bool,
}

// A place in lexical storage.
Prov_Reserved_Place :: struct {
	root: Root_Id,
	path: []Proj_Step,
}

// Where the events of a loan being reserved start, with what recorded operations
// there are so far.
Prov_Reserve_Mark :: struct {
	block:      Block_Id,
	first:      int,
	slots:      int,
	operations: int,
	events:     int,
}

// Starts recording the events of the mutable loan a reserved argument takes.
@(private)
prov_begin_reserve :: proc(graph: ^Flow_Graph) -> Prov_Reserve_Mark {
	mark := Prov_Reserve_Mark{block = graph.current, first = prov_next_event(graph), slots = len(graph.prov_slots)}
	if program := graph.effect_program; program != nil {
		mark.operations, mark.events = len(program.operations), len(program.events)
	}
	graph.reserving += 1
	return mark
}

// Ends the recording `mark` started and takes its events out of the block, for
// `prov_start_reserved` to run where the call starts. `hold` is what the
// argument holds until then.
@(private)
prov_end_reserve :: proc(
	graph: ^Flow_Graph, reserved: ^[dynamic]Prov_Reserved, mark: Prov_Reserve_Mark, index: int, hold, actual, lent: []int,
	watched: []Prov_Reserved_Place = nil,
) {
	entry := Prov_Reserved {
		index = index, hold = hold, block = mark.block, first = mark.first, slots = mark.slots, actual = actual, lent = lent,
		watched = watched, writes = len(graph.reserved_writes),
	}
	recorded := false
	if program := graph.effect_program; program != nil {
		recorded = len(program.operations) != mark.operations || len(program.events) != mark.events
	}
	if mark.block == NO_BLOCK || graph.current != mark.block || recorded {
		entry.kept = true
	} else {
		events := graph.blocks[mark.block].prov[mark.first:]
		entry.events = make([]Prov_Event, len(events), graph.alloc)
		copy(entry.events, events)
		// A use of nothing, so the events after these keep their places: if a later
		// argument writes a watched carrier, these go back where they were, and the
		// borrows they made still name them there.
		for &event in events {
			event = Prov_Event{kind = .Live}
		}
	}
	append(reserved, entry)
}

// Whether an argument evaluated after `entry` wrote a place holding a carrier its
// place was reached through.
@(private = "file")
prov_reserved_carrier_written :: proc(graph: ^Flow_Graph, entry: Prov_Reserved) -> bool {
	// Not cleared before every reserving call has started (`prov_start_reserved`).
	for written in graph.reserved_writes[entry.writes:] {
		for place in entry.watched {
			if written.root == place.root && paths_overlap(written.path, place.path) {
				return true
			}
		}
	}
	return false
}

// design.md "Weakening and reborrows": the call starts. Every hold ends here,
// and then each reserved loan is taken, in the order the arguments were
// evaluated, so two of one place conflict as they do when neither is reserved.
@(private)
prov_start_reserved :: proc(graph: ^Flow_Graph, v: ^Expr_Call, reserved: []Prov_Reserved, actuals: [][]int, borrowed: ^[]int) {
	if len(reserved) == 0 {
		return
	}
	held: []int
	// Whether code ran after an entry's events: then they move past it, and a
	// diagnostic of theirs says so.
	moves := make([]bool, len(reserved), graph.alloc)
	for &entry, index in reserved {
		if entry.kept {
			continue
		}
		// Unreachable, the call starts nowhere and takes no loan.
		if graph.current == NO_BLOCK {
			entry.kept = true
			continue
		}
		if prov_reserved_carrier_written(graph, entry) {
			copy(graph.blocks[entry.block].prov[entry.first:], entry.events)
			entry.kept = true
			continue
		}
		moves[index] = graph.current != entry.block || prov_next_event(graph) != entry.first + len(entry.events)
		held = prov_join(graph, held, entry.hold)
	}
	if len(held) > 0 {
		prov_emit(graph, Prov_Event{kind = .Live, sources = held, span = v.span, reads_only = true})
	}
	for entry, index in reserved {
		if !entry.kept {
			prov_run_reserved(graph, entry, v.span if moves[index] else {})
		}
		// A pack's operand: the pack's actual names what it lends already.
		if entry.index >= 0 {
			actuals[entry.index] = entry.actual
		}
		borrowed^ = prov_join(graph, borrowed^, entry.lent)
	}
	graph.reserving -= len(reserved)
	if graph.reserving == 0 {
		clear(&graph.reserved_writes)
	}
}

// Runs the events of a reserved loan in the current block, where `call` starts,
// which is zero when they run where they were recorded. A borrow among the slots
// they made is revised through the events it names (`prov_reborrow`), so it is
// told where they are now.
@(private = "file")
prov_run_reserved :: proc(graph: ^Flow_Graph, entry: Prov_Reserved, call: Span) {
	block := graph.blocks[graph.current]
	base := len(block.prov)
	append(&block.prov, ..entry.events)
	for &event in block.prov[base:] {
		event.reserved_call = call
	}
	moved :: proc(graph: ^Flow_Graph, entry: Prov_Reserved, base: int, at: Prov_Event_At) -> Prov_Event_At {
		if at.block != entry.block || at.event < entry.first || at.event >= entry.first + len(entry.events) {
			return at
		}
		return Prov_Event_At{graph.current, base + at.event - entry.first}
	}
	for slot in entry.slots ..< len(graph.prov_slots) {
		switch &borrow in graph.prov_slots[slot].borrow {
		case Prov_Fresh_Borrow:
			borrow.access = moved(graph, entry, base, borrow.access)
		case Prov_Through_Borrow:
			writes := moved(graph, entry, base, borrow.writes)
			if writes != borrow.writes {
				borrow.writes_end += writes.event - borrow.writes.event
				borrow.writes = writes
			}
			for &read in borrow.walk_reads {
				read = moved(graph, entry, base, read)
			}
		}
	}
}

// What a root place holds while it is reserved: a read-only loan of it, taken as
// `&place` takes one. The read is reported as the access the call makes when it
// starts, `starts`, so a mutable borrow still in use is told what it was told
// before loans were reserved.
@(private)
prov_reserve_place :: proc(
	graph: ^Flow_Graph, root: Root_Id, path: []Proj_Step, starts: Access_Kind, span: Span, verb: string, at: Span, what: string,
) -> []int {
	prov_access(graph, root, path, .Read, span, verb, starts = starts)
	hold := prov_borrow(graph, root, path, false, at, what)
	if loan := prov_slot_fresh_loan(graph, hold[0]); loan != NO_LOAN {
		graph.loans[int(loan)].reserved = true
	}
	return hold
}

// The carriers a named place holds, read again where a call starts. Its
// subscripts were evaluated where the argument was (`prov_read_rooted`).
@(private)
prov_reread_carrier :: proc(graph: ^Flow_Graph, operand: Expr, reads_only := false) -> []int {
	if ident, is_ident := operand.(^Expr_Ident); is_ident {
		return prov_read_ident(graph, ident, reads_only = reads_only)
	}
	root, path, _ := prov_place_of(graph, operand)
	prov_access(graph, root, path, .Read, expr_span(operand), reads_only = reads_only)
	return prov_read_content(graph, root, path, prov_type(graph, operand), expr_span(operand), reads_only = reads_only)
}

// The value a place reached through carriers holds, read as `walk_flow_expr`
// reads it, where the place was already evaluated: no index is evaluated again.
// `reads_only` reads what it holds without using it, as a read-only borrow of the
// place does.
@(private)
prov_reread_through :: proc(graph: ^Flow_Graph, place: Expr, reads_only := false) -> []int {
	type := prov_type(graph, place)
	only := reads_only || prov_read_is_reads_only(graph.k.c, type)
	carriers, path, _ := prov_read_through_carrier(graph, place, only, again = true)
	return prov_load_content(graph, carriers, path, type, expr_span(place), only, place = place)
}

// The diagnostics of root and region provenance. Once `solve_provenance` in
// `borrow.odin` settles a body, `report_provenance` replays each block's events
// against the settled facts and reports conflicting accesses, borrows that outlive
// their storage, escapes, region resets, and retention.
package lokec

import "core:fmt"
import "core:mem"
import "core:slice"

@(private)
report_provenance :: proc(state: ^Prov_Solve) {
	graph := state.graph
	// One expression gets one borrow diagnostic: a receiver and the call it
	// starts, or two rules meeting the same mistake, report once.
	reported := make(map[[2]u32]bool, graph.alloc)
	window_entry := solve_window(state)
	window := make([]u8, (len(graph.task_sites) + 7) / 8, graph.alloc)
	shared := Shared_Reports{
		seen   = make(map[Shared_Report]bool, graph.alloc),
		scopes = make(map[int]bool, graph.alloc),
	}
	// What each event's replay changed, so going forward undoes it.
	changes := make([dynamic]Live_Change, 0, 64, graph.alloc)
	marks := make([dynamic]int, 0, 64, graph.alloc)
	for block, id in graph.blocks {
		if !block.prov_visited || len(block.prov) == 0 {
			continue
		}
		copy(window, window_entry[id])
		count := len(block.prov)
		// Replayed from the block's exit; event `index`'s changes are those from
		// `marks[index + 1]` up to `marks[index]`.
		clear(&changes)
		resize(&marks, count + 1)
		block_table_put(block.live_exit, state.live)
		block_table_put(block.use_exit, state.uses)
		marks[count] = 0
		for index := count - 1; index >= 0; index -= 1 {
			run_live_event(block.prov[index], state.live, state.uses, &changes)
			marks[index] = len(changes)
		}
		solve_enter_block(state, block)
		block_table_put(block.links_entry, state.links_held)
		block_table_put(block.below_entry, state.below.held)
		for event, index in block.prov {
			// Liveness after this event, which is what it consults.
			undo := changes[marks[index + 1]:marks[index]]
			#reverse for change in undo {
				state.live[change.slot], state.uses[change.slot] = change.live, change.use
			}
			// A temporary's end has no span of its own and is never merged.
			at := [2]u32{event.span.file, event.span.lo}
			placed := event.span != Span{}
			if !placed || !reported[at] {
				before := len(state.k.c.diagnostics)
				already := event.repeats_inner && reported_within(reported, event.span)
				if !already {
					check_prov_event(state, event, state.live, state.uses)
				}
				if placed && (already || len(state.k.c.diagnostics) > before) {
					reported[at] = true
				}
			}
			check_shared_event(state, event, window, &shared)
			window_step(graph, window, event)
			run_prov_event(state, event, state.reach, state.ended)
			run_links_held_event(state, event, state.links_held)
		}
	}
}

// Whether a diagnostic was reported inside `span`, as for an argument of the call
// `span` is.
@(private = "file")
reported_within :: proc(reported: map[[2]u32]bool, span: Span) -> bool {
	for at in reported {
		if at[0] == span.file && at[1] >= span.lo && at[1] < span.hi {
			return true
		}
	}
	return false
}

// Whether a reset ends storage rooted here: a control block the provider's
// destruction ends, in a region it may name or one never recorded. `free_all`
// leaves handles usable.
@(private)
reset_ends_root :: proc(root: Prov_Root, event: Prov_Event) -> bool {
	if root.kind != .Provider || !event.provider_end {
		return false
	}
	return region_is_empty(root.region) || regions_may_overlap(root.region, event.region)
}

@(private = "file")
access_conflicts :: proc(loan: Prov_Loan, event: Prov_Event) -> bool {
	if loan.root != event.root || !paths_overlap(loan.path, event.path) {
		return false
	}
	return event.access != .Read || loan.mutable
}

@(private = "file")
check_prov_event :: proc(state: ^Prov_Solve, event: Prov_Event, live: []Slot_Use, uses: []Span) {
	graph := state.graph
	before := len(state.k.c.diagnostics)
	state.diagnostic_precision = path_precision(event.path)
	for source in event.sources { state.diagnostic_precision |= state.precision[source] }
	defer {
		if len(state.k.c.diagnostics) > before {
			add_precision_notes(state.k.c, event.span, state.diagnostic_precision, event.region.crowded, event.region.crowded_params)
		}
	}
	#partial switch event.kind {
	case .Cross:
		check_crossing(state, event)
	case .Access:
		it := live_loans(state, live)
		for slot, index in next_live_loan(&it) {
			loan := graph.loans[index]
			if !access_conflicts(loan, event) || event.access == .Read && graph.prov_slots[slot].read_only_hold {
				continue
			}
			state.diagnostic_precision |= state.precision[slot]
			report_borrow_conflict(state, event, loan, uses[slot])
			return
		}
	case .Task_Join:
		check_join_retention(state, event, live)
	case .Through:
		check_place_loans(state, event, live, uses)
	case .Live, .Load:
		// A reborrow suspends its source until its own last use, and the last use
		// of whatever was reborrowed from it in turn.
		for source in event.sources {
			if reborrow, derived, found := live_reborrow_of(state, source, live, event); found {
				state.diagnostic_precision |= state.precision[derived]
				report_suspended_reborrow(state, event, reborrow, event.span if event.load == .At_Once else uses[derived])
				return
			}
		}
	case .Root_End:
		it := live_loans(state, live)
		for slot, index in next_live_loan(&it) {
			loan := graph.loans[index]
			// A result borrowing frame storage is the `Escape` event's error.
			if loan.root != event.root || graph.prov_slots[slot].returned {
				continue
			}
			state.diagnostic_precision |= state.precision[slot]
			report_root_outlived(state, event, loan, uses[slot])
			return
		}
	case .Escape:
		check_escape(state, event)
	case .Retain:
		check_retention(state, event)
	case .Reset:
		check_region_reset(state, event, live, uses)
	case .Region_Escape:
		check_region_escape(state, event)
	}
}

// A result backed by a region created here, as an owner or an allocation, or
// borrowing storage that ends with the frame.
@(private = "file")
check_escape :: proc(state: ^Prov_Solve, event: Prov_Event) {
	graph := state.graph
	c := state.k.c
	if region_has_local(event.region) {
		if event.name != "" {
			errorf(c, event.span, "L0592", "this result is backed by `%s`, an allocator region that ends when this procedure returns", event.name)
		} else {
			errorf(c, event.span, "L0592", "this result is backed by an allocator region created in this procedure, which ends when it returns")
		}
		return
	}
	it := slots_loans(state, prov_join(graph, event.sources, event.into))
	for _, index in next_live_loan(&it) {
		loan := graph.loans[index]
		root := graph.roots[int(loan.root)]
		if root_outlives_body(root.kind) || root_names_source(graph, root) {
			continue
		}
		// As in `report_borrow_conflict`.
		escaping := "this %s cannot be returned: %s ends when this procedure returns"
		if state.diagnostic_precision != {} {
			escaping = "this %s may depend on %s, which ends when this procedure returns"
		}
		errorf(c, event.span, "L0526", escaping, loan.what, root_phrase(root))
		add_root_notes(state, root, loan)
		add_plain_call_note(state, loan)
		return
	}
}

// An owner stored in longer-lived storage than its region.
@(private = "file")
check_region_escape :: proc(state: ^Prov_Solve, event: Prov_Event) {
	c := state.k.c
	if event.moved != "" {
		errorf(c, event.span, "L0536", "`%s` was received by `move`, and its `@(escape=...)` level does not let it be stored in %s", event.moved, event.name)
		return
	}
	errorf(
		c, event.span, "L0536", "%s is backed by an allocator region %s, so it cannot be stored in %s, which outlives that region",
		event.verb, region_has_local(event.region) ? "created in this procedure" : "this procedure received", event.name,
	)
}

// design.md "Weakening and reborrows": the first reborrow of `source` that a live slot still
// holds a value derived through (`solve_links_held`), and that live slot.
@(private)
live_reborrow_of :: proc(state: ^Prov_Solve, source: int, live: []Slot_Use, use: Prov_Event) -> (Prov_Reborrow, int, bool) {
	graph := state.graph
	links := reborrows_of(state, source)
	if len(links) == 0 {
		return {}, -1, false
	}
	at_once := use.load == .At_Once
	candidates := make([dynamic]int, 0, 8, context.temp_allocator)
	for row, slot in state.links_held {
		if row == 0 {
			continue
		}
		if at_once ? slice.contains(use.sources, slot) : slot != source && live[slot] == .Used {
			append(&candidates, slot)
		}
	}
	for index in links {
		reborrow := graph.reborrows[index]
		// Only a mutable reborrow excludes a read; what is derived from a
		// read-only one is read-only too.
		if reborrow.passes_on || reborrow.moved || (use.reads_only && !reborrow.mutable) {
			continue
		}
		// Only its own expression reads a temporary, so a later use of one is of a new
		// value; what it was copied from is what a store's link suspends.
		if reborrow.from_store > 0 && graph.prov_slots[source].kind == .Temporary {
			continue
		}
		for slot in candidates {
			if !bit_get(state.link_rows.rows[state.links_held[slot]], index) {
				continue
			}
			// A slot standing for many places holds the copy too, whichever it is.
			if slot == source {
				return reborrow, source, true
			}
			// A load through the reborrow itself is no competing use, as a slice argument
			// holding a reborrow of the elements a call reads through it, or `cur^.next`
			// once `cur = cur^.next` has stepped; nor is one only through what was loaded
			// below it, as `cur^.next^.next`.
			if use.kind == .Load && !at_once && (slice.contains(use.into, slot) || loads_below(state, use.into, slot)) {
				continue
			}
			// A load defines its slot afresh, as a loop's `list^.head` loads its temporary
			// again, so that slot's later uses are of the new value.
			if use.kind == .Load && slot == use.slot || use.reads_only && graph.prov_slots[slot].read_only_hold || !prov_slots_overlap(state, source, slot) {
				continue
			}
			if !at_once || at_once_reaches(state, use, source) {
				return reborrow, slot, true
			}
		}
	}
	return {}, -1, false
}

// Whether every carrier a load goes through was loaded below `cursor`'s current value
// (`Loaded_Below`). One slot stands for a field of every node, as a list's `next`, so what
// the cursor was copied out of and what is read below it share a slot. In a structure no
// mutable path reaches twice, a place below the cursor's value is not the one that value
// was copied from.
@(private = "file")
loads_below :: proc(state: ^Prov_Solve, carriers: []int, cursor: int) -> bool {
	for carrier in carriers {
		if !loaded_below(state, carrier, cursor) {
			return false
		}
	}
	return len(carriers) > 0
}

// Whether a call's `At_Once` load reaches `source` by other than what was reborrowed
// from it. A copy points where `source` does, so what it reaches is not `source` in
// any program that keeps one mutable path to each place: finding `source` that way
// only says the copy's loan names storage holding `source` too, as a value split out
// of a view borrows the view (design.md "Weakening and reborrows").
@(private = "file")
at_once_reaches :: proc(state: ^Prov_Solve, use: Prov_Event, source: int) -> bool {
	if slice.contains(use.into, source) {
		return true
	}
	derived := make([dynamic]int, 0, 8, context.temp_allocator)
	append(&derived, source)
	links := reborrows_of(state, source)
	for held, slot in state.links_held {
		if slot == source || held == 0 {
			continue
		}
		for index in links {
			if bit_get(state.link_rows.rows[held], index) {
				append(&derived, slot)
				break
			}
		}
	}
	saved := make([]u8, state.row_bytes * len(derived), context.temp_allocator)
	for slot, at in derived[1:] {
		row := reach_row(state, state.reach, slot)
		copy(saved[at * state.row_bytes:], row)
		mem.zero_slice(row)
	}
	reads := make([dynamic]int, 0, 8, context.temp_allocator)
	load_pointee_content(state, use, state.reach, &reads)
	for slot, at in derived[1:] {
		copy(reach_row(state, state.reach, slot), saved[at * state.row_bytes:][:state.row_bytes])
	}
	return slice.contains(reads[:], source)
}

// The index is rebuilt once materialization has added reborrows since, so a search
// through a long chain of reborrows reads only each slot's own.
@(private)
reborrows_of :: proc(state: ^Prov_Solve, slot: int) -> []int {
	graph := state.graph
	if state.reborrow_starts == nil || state.reborrows_indexed != len(graph.reborrows) {
		slots := len(graph.prov_slots)
		starts := make([]int, slots + 1, graph.alloc)
		for reborrow in graph.reborrows {
			starts[reborrow.source + 1] += 1
		}
		for index in 0 ..< slots {
			starts[index + 1] += starts[index]
		}
		indices := make([]int, len(graph.reborrows), graph.alloc)
		filled := make([]int, slots, context.temp_allocator)
		for reborrow, index in graph.reborrows {
			indices[starts[reborrow.source] + filled[reborrow.source]] = index
			filled[reborrow.source] += 1
		}
		state.reborrow_starts, state.reborrow_indices, state.reborrows_indexed = starts, indices, len(graph.reborrows)
	}
	return state.reborrow_indices[state.reborrow_starts[slot]:state.reborrow_starts[slot + 1]]
}

// An access through carriers that name storage a live place loan names, at
// an overlapping path, as a store replacing the payload a switch binding
// still views (design.md "Switch ownership"), or a read of a place a mutable
// borrow through another carrier still holds (design.md "Weakening and
// reborrows"). An access through the loan itself, a carrier holding its bit,
// is its own.
@(private = "file")
check_place_loans :: proc(state: ^Prov_Solve, event: Prov_Event, live: []Slot_Use, uses: []Span) {
	carrying: Live_Place_Bits
	gathered := false
	for loan, index in state.graph.place_loans {
		if (event.access == .Read && !loan.mutable) || !place_loan_overlaps(loan, event.path) {
			continue
		}
		if !gathered {
			carrying, gathered = live_place_bits(state, live, event.access == .Read), true
		}
		later, lent := place_loan_use(state, index, live, uses, carrying)
		if !lent {
			continue
		}
		bit := place_bit(state, index)
		for carrier in event.into {
			if !prov_slots_overlap(state, loan.slot, carrier) || bit_get(reach_row(state, state.reach, carrier), bit) ||
			   accessed_beside(state, index, carrier) || view_elements_apart(state, loan.element, loan.slot, event.element, carrier) {
				continue
			}
			state.diagnostic_precision |= state.precision[loan.slot] | state.precision[carrier] | event.precision
			if loan.borrows {
				report_place_borrowed(state, event, loan, carrier, later)
				return
			}
			// As in `report_borrow_conflict`.
			errorf(
				state.k.c, event.span, "L0511",
				"this %s %s the %s %s of `%s` that is still in use",
				event.verb, state.diagnostic_precision != {} ? "may not be compatible with" : "is not compatible with",
				loan.mutable ? "mutable" : "read-only", loan.what, loan.place,
			)
			add_notef(state.k.c, loan.span, "the switch borrows the %s here", loan.what)
			add_use_note(state, later)
			return
		}
	}
}

// Whether `carrier` was read out through another place loan of the storage
// place loan `index` names, at a place beside it, as `left` is for `right`
// in `.add(&mut left, &mut right)`: what it reaches is inside that place, so
// an access through it is beside this one too.
@(private = "file")
accessed_beside :: proc(state: ^Prov_Solve, index: int, carrier: int) -> bool {
	loans := state.graph.place_loans
	row := reach_row(state, state.reach, carrier)
	for other, at in loans {
		if at == index || !other.borrows || !bit_get(row, place_bit(state, at)) || !prov_slots_overlap(state, other.slot, loans[index].slot) {
			continue
		}
		if !place_loans_overlap(other, loans[index]) || view_elements_apart(state, other.element, other.slot, loans[index].element, loans[index].slot) {
			return true
		}
	}
	return false
}

@(private = "file")
place_loan_overlaps :: proc(loan: Prov_Place_Loan, path: []Proj_Step) -> bool {
	for at in loan.paths {
		if paths_overlap(at, path) {
			return true
		}
	}
	return false
}

@(private = "file")
place_loans_overlap :: proc(a, b: Prov_Place_Loan) -> bool {
	for at in a.paths {
		if place_loan_overlaps(b, at) {
			return true
		}
	}
	return false
}

// The source is suspended only while both slots' current values share a valid
// loan, so overwriting either one ends the reborrow.
@(private = "file")
prov_slots_overlap :: proc(state: ^Prov_Solve, source_slot, derived_slot: int) -> bool {
	source := reach_row(state, state.reach, source_slot)
	derived := reach_row(state, state.reach, derived_slot)
	for index in 0 ..< state.loans {
		if bit_get(source, index) && !state.ended[index] && bit_get(derived, index) {
			return true
		}
	}
	return false
}

// A reset is rejected when the body may not reset that region at all, or when an
// owner or borrow of the region is still live.
@(private = "file")
check_region_reset :: proc(state: ^Prov_Solve, event: Prov_Event, live: []Slot_Use, uses: []Span) {
	graph := state.graph
	if event.access == .Invalidate && !event.reset_covered {
		errorf(
			state.k.c, event.span, "L0538",
			"this resets a region that existed before the call, so the allocator must arrive through an `@(allocator_reset)` parameter",
		)
		return
	}
	if event.access == .Write && !event.reset_covered {
		// A reset-capable call given one of this body's own allocators.
		if event.name != "" {
			errorf(state.k.c, event.span, "L0538", "this call may reset `%s`, so `%s` must be marked `@(allocator_reset)`", event.name, event.name)
		} else {
			errorf(
				state.k.c, event.span, "L0538",
				"this call may reset a pre-existing or unknown allocator region, so the reset cannot be hidden in this procedure",
			)
		}
		return
	}
	// design.md "Minimum provenance precision": past the regions a body tells apart, the
	// dependency is only possible.
	would := event.region.crowded || event.region.crowded_params ? "may" : "would"
	if event.ends_result {
		errorf(
			state.k.c, event.span, "L0537",
			"%s %s end the region backing the returned value, which the caller already holds when deferred statements run",
			event.ends != "" ? event.ends : "this reset", would,
		)
		add_notef(state.k.c, event.owner_span, "the value is returned here")
		return
	}
	if event.verb != "" {
		errorf(
			state.k.c, event.span, "L0537", "%s %s end the region backing `%s`, which is still live here",
			event.ends != "" ? event.ends : "this reset", would, event.verb,
		)
		add_notef(state.k.c, event.owner_span, "`%s` is declared here and is cleaned up after this point", event.verb)
		if from, unwinding := event.unwind_from.?; unwinding {
			add_notef(state.k.c, from, "a panic in this statement unwinds through the cleanup, before `%s` is dropped", event.verb)
		}
		return
	}
	it := live_loans(state, live)
	for slot, index in next_live_loan(&it) {
		loan := graph.loans[index]
		root := graph.roots[int(loan.root)]
		if !reset_ends_root(root, event) {
			continue
		}
		// A result backed by this frame's region is the `Escape` event's error.
		if graph.prov_slots[slot].returned && region_is_local_only(root.region) {
			continue
		}
		errorf(state.k.c, event.span, "L0537", "%s %s end an allocator control block whose handle is still in use", event.ends != "" ? event.ends : "this cleanup", would)
		state.diagnostic_precision |= state.precision[slot]
		add_notef(state.k.c, loan.span, "the %s is created here", loan.what)
		add_use_note(state, uses[slot])
		return
	}
}

@(private = "file")
report_borrow_conflict :: proc(state: ^Prov_Solve, event: Prov_Event, loan: Prov_Loan, later: Span) {
	k := state.k
	root := state.graph.roots[int(loan.root)]
	// A merged dependency may be the only reason these two look like one place,
	// so the message claims no more than the analysis knows (design.md "Minimum
	// provenance precision"); the notes added after it say which budget merged
	// them and how to keep the two apart.
	merged := state.diagnostic_precision != {}
	invalidated := "%s cannot be %s here: a %s %s of it is still in use"
	conflicting := "this %s of %s is not compatible with the %s %s of it that is still in use"
	if merged {
		invalidated = "%s cannot be %s here: a %s %s of it may still be in use"
		conflicting = "this %s of %s may overlap the %s %s of it that is still in use"
	}
	if event.access == .Invalidate {
		errorf(
			k.c, event.span, "L0512", invalidated,
			root_label(root), event.verb == "" ? "invalidated" : event.verb, loan.mutable ? "mutable" : "read-only", loan.what,
		)
	} else if event.access == .Read && event.verb != "" {
		// design.md "Global write effects": a call's read of a global.
		errorf(k.c, event.span, "L0511", invalidated, root_label(root), event.verb, "mutable", loan.what)
	} else {
		// design.md "@(synchronized)": such an access counts as a write, and a
		// borrow of the field as a mutable one, whatever was written.
		access := event.access == .Write ? "write" : "read"
		if path_is_synchronized(event.path) {
			access = "access through a synchronized field"
		}
		errorf(
			k.c, event.span, "L0511", conflicting,
			access, root_label(root), path_is_synchronized(loan.path) ? "exclusive" : loan.mutable ? "mutable" : "read-only", loan.what,
		)
	}
	add_borrow_notes(state, root, loan, later)
	note_last_use_move(k.c, event.verb)
}

// A move the program did not write needs saying where it came from.
@(private = "file")
note_last_use_move :: proc(c: ^Compiler, verb: string) {
	if verb == LAST_USE_VERB {
		add_notef(c, NO_SPAN, "a copy of a local that nothing reads afterwards moves it; write `.clone()` to copy it instead")
	}
}

@(private = "file")
report_suspended_reborrow :: proc(
	state: ^Prov_Solve,
	event: Prov_Event,
	reborrow: Prov_Reborrow,
	later: Span,
) {
	k := state.k
	source := state.graph.prov_slots[reborrow.source]
	derived := state.graph.prov_slots[reborrow.derived]
	capability := reborrow.mutable ? "mutable" : "read-only"
	// A place, or a temporary, used through a binding that views it. A slice
	// literal's element has a description rather than a name.
	name := fmt.tprintf("`%s`", event.name if event.name != "" else source.name)
	if event.name == "" && source.kind == .Literal {
		name = source.name
	}
	covers := state.diagnostic_precision != {} ? " that may cover this place" : ""
	errorf(k.c, event.span, "L0641", "%s cannot be used here: a %s reborrow of it%s is still in use", name, capability, covers)
	if derived.name != "" {
		add_notef(k.c, reborrow.span, "`%s` reborrows it %s here", derived.name, reborrow.mutable ? "mutably" : "read-only")
	} else {
		add_notef(k.c, reborrow.span, "the %s reborrow is taken here", capability)
	}
	add_use_note(state, later)
}

// A carrier used for a place a borrow through another carrier still holds,
// as `h` for `h^.count += 1` while `count := &mut h^.count` is in use.
@(private = "file")
report_place_borrowed :: proc(state: ^Prov_Solve, event: Prov_Event, loan: Prov_Place_Loan, carrier: int, later: Span) {
	k := state.k
	name := event.name if event.name != "" else carrier_name(state.graph, carrier)
	capability := loan.mutable ? "mutable" : "read-only"
	// As in `report_borrow_conflict`.
	covers := state.diagnostic_precision != {} ? " that may cover this place" : ""
	errorf(k.c, event.span, "L0641", "`%s` cannot be used here: a %s reborrow of it%s is still in use", name, capability, covers)
	add_notef(k.c, loan.span, "the %s reborrow of `%s` is taken here", capability, loan.place)
	add_use_note(state, later)
}

// A carrier's name, or for a temporary reborrowed from one, as the read-only
// reborrow of `p^` that `p^^[1]` reads through, the name of what it reborrows.
@(private = "file")
carrier_name :: proc(graph: ^Flow_Graph, carrier: int) -> string {
	at := carrier
	for _ in 0 ..< len(graph.reborrows) + 1 {
		if graph.prov_slots[at].name != "" {
			return graph.prov_slots[at].name
		}
		source := -1
		for reborrow in graph.reborrows {
			if reborrow.derived == at {
				source = reborrow.source
				break
			}
		}
		if source < 0 {
			break
		}
		at = source
	}
	return ""
}

@(private = "file")
report_root_outlived :: proc(state: ^Prov_Solve, event: Prov_Event, loan: Prov_Loan, later: Span) {
	k := state.k
	root := state.graph.roots[int(loan.root)]
	label := root_label(root)
	// As in `report_borrow_conflict`.
	used := state.diagnostic_precision != {} ? "may be used" : "is used"
	// Points at the later use: the storage ends at no written operation.
	span := later.file == NO_FILE ? event.span : later
	if root.symbol == INVALID_SYMBOL {
		errorf(k.c, span, "L0513", "this %s %s after %s has ended", loan.what, used, label)
	} else {
		errorf(k.c, span, "L0513", "this %s %s after %s, the %s it borrows, has ended", loan.what, used, label, root_kind_text(root.kind))
	}
	if root.span.file != NO_FILE {
		if root.kind == .Temporary && root.extended {
			add_notef(k.c, root.span, "%s is kept until the end of the block that created it", label)
		} else if root.kind == .Temporary {
			add_notef(k.c, root.span, "%s ends with the statement that created it", label)
		} else {
			add_notef(k.c, root.span, "%s is declared here and ends with its scope", label)
		}
	}
	add_notef(k.c, loan.span, "the %s is created here", loan.what)
	// design.md "Task borrows and the join": the block's own
	// locals end before its join.
	if later_is_task_hold(state, later) {
		add_notef(
			k.c, later,
			"a task holds the %s until this `parallel` block joins, after its own locals end; declare the storage before the block, or spawn from a `parallel` block nested after it",
			loan.what,
		)
	}
}

// Whether a later use is a `parallel` block's join, which holds what its tasks hold.
@(private = "file")
later_is_task_hold :: proc(state: ^Prov_Solve, later: Span) -> bool {
	for scope in state.graph.task_slots {
		if sym := symbol_of(state.k.c, scope); sym != nil && sym.span == later {
			return true
		}
	}
	return false
}

@(private = "file")
add_root_notes :: proc(state: ^Prov_Solve, root: Prov_Root, loan: Prov_Loan) {
	if root.symbol != INVALID_SYMBOL && root.span.file != NO_FILE {
		add_notef(state.k.c, root.span, "%s is declared here", root_label(root))
	}
	add_notef(state.k.c, loan.span, "the %s is created here", loan.what)
}

// design.md "Procedure result contracts": a loan created in the arguments of a
// call through a type with no result contract reached the result only because
// that type states no bound. Names the innermost such call.
@(private = "file")
add_plain_call_note :: proc(state: ^Prov_Solve, loan: Prov_Loan) {
	found: ^Expr_Call
	for call in state.graph.plain_calls {
		if call.span.file == loan.span.file && call.span.lo <= loan.span.lo && loan.span.hi <= call.span.hi &&
		   (found == nil || call.span.hi - call.span.lo < found.span.hi - found.span.lo) {
			found = call
		}
	}
	if found != nil {
		add_notef(
			state.k.c, found.span,
			"a call through `%s` may return a borrow of any argument, because that type states no result bound; `@(escape=none)` on a parameter excludes it",
			type_name(state.k.c, call_proc_type(state.k.c, found)),
		)
	}
}

@(private = "file")
add_borrow_notes :: proc(state: ^Prov_Solve, root: Prov_Root, loan: Prov_Loan, later: Span) {
	k := state.k
	if root.symbol != INVALID_SYMBOL && root.span.file != NO_FILE {
		add_notef(
			k.c,
			root.span,
			"%s is the %s this %s borrows",
			root_label(root),
			root_kind_text(root.kind),
			loan.what,
		)
	}
	add_notef(k.c, loan.span, "the %s is created here", loan.what)
	add_use_note(state, later)
}

// The later use keeping a borrow live. One at a declaration is that local's
// `drop` hook, run when its scope ends.
@(private = "file")
add_use_note :: proc(state: ^Prov_Solve, later: Span) {
	if later.file == NO_FILE {
		return
	}
	if later_is_task_hold(state, later) {
		add_notef(state.k.c, later, "and a task holds it until this `parallel` block joins, which keeps it live")
		return
	}
	if state.graph.scope_drops[later] {
		add_notef(state.k.c, later, "and is still used when this is dropped at the end of its scope, which keeps it live")
	} else {
		add_notef(state.k.c, later, "and is still used here, which keeps it live")
	}
}

// A stored borrow must still be valid for as long as its destination lives.
@(private = "file")
check_retention :: proc(state: ^Prov_Solve, event: Prov_Event) {
	graph := state.graph
	// Written through a carrier (`p^.view`): the destinations are its loans' roots,
	// live or not.
	if len(event.into) > 0 {
		seen := make(map[Root_Id]bool, context.temp_allocator)
		it := slots_loans(state, event.into)
		for slot, index in next_live_loan(&it) {
			target := graph.loans[index].root
			if seen[target] {
				continue
			}
			seen[target] = true
			destination := graph.roots[int(target)]
			into := retain_kind_for_root(destination.kind)
			if into != .None && report_retention(state, event, into, target, destination, state.precision[slot]) {
				return
			}
		}
		return
	}
	destination := Prov_Root{symbol = INVALID_SYMBOL}
	if event.root != NO_ROOT {
		destination = graph.roots[int(event.root)]
	}
	report_retention(state, event, event.retain, event.root, destination)
}

// Reports the first loan of the stored value that does not reach the
// destination; returns whether it did. `destination_loss` is the precision of
// the carrier that names the destination.
//
// design.md "Minimum provenance precision": a merged dependency may be the
// only reason the value looks like a borrow of that storage, or the carrier
// like one naming that destination, so the message says each may be so.
@(private = "file")
report_retention :: proc(
	state: ^Prov_Solve,
	event: Prov_Event,
	into: Retain_Kind,
	target: Root_Id,
	destination: Prov_Root,
	destination_loss: Precision_Loss = {},
) -> bool {
	graph := state.graph
	borrows := state.diagnostic_precision != {} ? "may borrow" : "borrows"
	stored := destination_loss != {} ? ", where it may be stored" : ""
	it := slots_loans(state, event.sources)
	for _, index in next_live_loan(&it) {
		loan := graph.loans[index]
		root := graph.roots[int(loan.root)]
		// Storing into the same storage is not retention. A parameter has two
		// roots (entry loan and places), so compare the symbol too. A new
		// borrow of a parameter's own storage is, since the caller's root would
		// then borrow itself.
		same := loan.root == target || (root.symbol != INVALID_SYMBOL && root.symbol == destination.symbol)
		if same && (root.kind != .Param || loan.content) {
			continue
		}
		if root.kind == .Param {
			if parameter_allows_retention(state, root, into) {
				continue
			}
			errorf(
				state.k.c, event.span, "L0646",
				"this %s %s %s, which is not written `@(escape=%s)`, so it cannot reach %s%s",
				loan.what, borrows, root_phrase(root), escape_level_name(retain_kind_level(into)), retain_destination(event, destination), stored,
			)
		} else {
			if root_satisfies_retention(root.kind, into) || root_names_source(graph, root) {
				continue
			}
			errorf(
				state.k.c, event.span, "L0647",
				"this %s %s %s, which does not outlive %s%s: %s",
				loan.what, borrows, root_phrase(root), retain_destination(event, destination), stored, retain_kind_text(into),
			)
		}
		state.diagnostic_precision |= destination_loss
		add_root_notes(state, root, loan)
		// design.md "@(cross_thread)": this is why one cannot reach a thread.
		if root.kind == .Thread_Local && into == .Process {
			add_notef(state.k.c, root.span, "each thread has its own `thread_local` storage, which ends with that thread")
		}
		return true
	}
	return false
}

// The destination place, or the callee parameter that may keep the borrow.
@(private = "file")
retain_destination :: proc(event: Prov_Event, destination: Prov_Root) -> string {
	if destination.symbol == INVALID_SYMBOL || destination.name == "" {
		return event.verb
	}
	return fmt.tprintf("`%s`", destination.name)
}

@(private = "file")
parameter_allows_retention :: proc(state: ^Prov_Solve, root: Prov_Root, into: Retain_Kind) -> bool {
	sym := symbol_of(state.k.c, root.symbol)
	if sym == nil {
		return false
	}
	return sym.escape >= retain_kind_level(into)
}

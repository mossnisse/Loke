// What a stored carrier takes from the slots it was read from: a weakened fresh
// loan, or a reborrow of an existing mutable carrier that stays suspended while
// the destination is live (design.md "Weakening and reborrows").
package lokec

// design.md "Weakening and reborrows": a carrier stored into `into` from `slots`.
// A fresh mutable loan weakens to a read-only destination; an existing mutable
// carrier is reborrowed and suspended while `into` is live. `into` is -1 for a call
// argument, which `prov_call` gives derived slots of its own, and for storage
// written through a carrier. A `copies` destination that is named storage takes a
// copy (`prov_use_copied`); a temporary holding a read is no copy.
@(private)
prov_reborrow :: proc(graph: ^Flow_Graph, slots: []int, destination: Type_Id, into := -1, span := Span{}, copies := false) {
	if !type_is_carrier(graph.k.c, destination) {
		return
	}
	weakens := !carrier_is_mutable(graph.k.c, destination)
	if copies && (into < 0 || prov_slot_is_stored(graph.prov_slots[into])) {
		prov_use_copied(graph, slots, destination, span, !weakens, into)
	}
	for slot in slots {
		entry := graph.prov_slots[slot]
		// A borrow weakened to a read-only destination is taken read-only.
		if weakens {
			for &loan in graph.place_loans {
				if loan.borrows && loan.slot == slot {
					loan.mutable = false
				}
			}
		}
		switch borrow in entry.borrow {
		case Prov_Through_Borrow:
			if weakens {
				// It still reads what it borrows.
				if borrow.writes.event >= 0 {
					for index in borrow.writes.event ..< borrow.writes_end {
						graph.blocks[borrow.writes.block].prov[index].access = .Read
					}
				}
				for at in borrow.walk_reads {
					graph.blocks[at.block].prov[at.event].reads_only = true
				}
			}
			continue
		case Prov_Fresh_Borrow:
			if weakens && !path_is_synchronized(graph.loans[int(borrow.loan)].path) {
				graph.loans[int(borrow.loan)].mutable = false
				if borrow.access.event >= 0 {
					graph.blocks[borrow.access.block].prov[borrow.access.event].access = .Read
				}
			}
			continue
		}
		// Storing a carrier into itself, as `xs = xs[1:]`, suspends nothing. A
		// reborrow passes on to its copies and to what is taken from its elements.
		if into < 0 || into == slot {
			continue
		}
		// A copy of a lent element reborrows the stored carrier it names.
		if aliased, lent := graph.lent_aliases[slot]; lent {
			prov_reborrow(graph, aliased, destination, into, span, copies)
		}
		mutable_source := prov_slot_is_mutable_carrier(graph, slot) || prov_slot_is_loaded_mutable(graph, slot)
		reborrowed := prov_slot_is_reborrow(graph, slot)
		// A read-only copy may copy a reborrow only the solve can tell of
		// (`prov_settle_pending_reborrows`).
		pending := !mutable_source && !reborrowed && prov_slot_may_come_to_reborrow(graph, slot)
		reborrowed ||= pending
		if !mutable_source && !reborrowed {
			continue
		}
		// An unnamed value read out of a mutable carrier, as `held.items`, has
		// only this destination, so it takes the destination's capability as a
		// fresh loan does.
		if weakens && !prov_slot_is_stored(graph.prov_slots[slot]) {
			for &earlier in graph.reborrows {
				if earlier.derived == slot {
					earlier.mutable = false
				}
			}
		}
		// A named read-only reborrow is not itself suspended by its copies, nor
		// is a read-only carrier loaded out through a pointer.
		passes_on := !mutable_source && (prov_slot_is_stored(graph.prov_slots[slot]) || prov_slot_is_loaded_read_only(graph, slot))
		append(&graph.reborrows, Prov_Reborrow {
			source = slot, derived = into, span = span, mutable = !weakens, passes_on = passes_on, pending = pending,
		})
	}
}

// A value holding carriers stored through carriers, as `p^ = q^` for a record of
// pointers, copies each of them (design.md "Weakening and reborrows"). Where it is
// written, each copy uses what its carrier points to, and weakens what it copies.
// Which storage the target names is known only to the solve, which links each to
// where it lands (`prov_link_landed`).
@(private)
prov_use_stored :: proc(graph: ^Flow_Graph, sources: []int, stored: Type_Id, span: Span) {
	c := graph.k.c
	if type_is_carrier(c, stored) {
		prov_reborrow(graph, sources, stored, span = span, copies = true)
		return
	}
	for path in carrier_shape(c, stored) {
		if path.truncated || path.type == INVALID_TYPE {
			continue
		}
		if selected := prov_select_content(graph, sources, stored, path.steps); len(selected) > 0 {
			prov_reborrow(graph, selected, path.type, span = span, copies = true)
		}
	}
}

// design.md "Weakening and reborrows": each carrier a store through carriers copies
// reborrows the slots the solve found it landing in, from that store on
// (`Prov_Reborrow.from_store`). An untyped caller slot takes a carrier stored alone,
// as it stands for what the storage holds whatever that is.
@(private)
prov_link_landed :: proc(graph: ^Flow_Graph, event: Prov_Event, landed: []int) {
	c := graph.k.c
	stored := event.carried
	for into in landed {
		entry := graph.prov_slots[into]
		type := slot_carrier_type(graph, into)
		if type_is_carrier(c, stored) {
			if type == stored || entry.kind == .Caller && type == INVALID_TYPE {
				prov_reborrow(graph, event.sources, stored, into, event.span)
			}
			continue
		}
		for path in carrier_shape(c, stored) {
			if path.truncated || path.type == INVALID_TYPE || type != path.type || !prov_path_may_end_in(entry.path, path.steps) {
				continue
			}
			if selected := prov_select_content(graph, event.sources, stored, path.steps); len(selected) > 0 {
				prov_reborrow(graph, selected, path.type, into, event.span)
			}
		}
	}
}

// Whether `slot`, of a place a store of `stored` lands along, holds a carrier it
// stores: the carrier itself, or one on a path inside it whose place the slot may be.
@(private)
prov_slot_holds_stored :: proc(c: ^Compiler, slot: Prov_Slot, stored: Type_Id) -> bool {
	if type_is_carrier(c, stored) {
		return slot.content_type == stored
	}
	for inner in carrier_shape(c, stored) {
		if !inner.truncated && inner.type == slot.content_type && prov_path_may_end_in(slot.path, inner.steps) {
			return true
		}
	}
	return false
}

// `Prov_Event.linked` for a store of `stored` through carriers: whether the solve
// links each carrier it copies to where it lands (`prov_link_landed`).
@(private)
prov_store_linked :: proc(c: ^Compiler, stored: Type_Id) -> bool {
	if type_is_carrier(c, stored) {
		return true
	}
	paths := carrier_shape(c, stored)
	if len(paths) == 0 {
		return false
	}
	for path in paths {
		if path.truncated || path.type == INVALID_TYPE {
			return false
		}
	}
	return true
}

// `Prov_Through_Borrow`
@(private)
prov_slot_is_through :: proc(graph: ^Flow_Graph, slot: int) -> bool {
	_, through := graph.prov_slots[slot].borrow.(Prov_Through_Borrow)
	return through
}

// `Prov_Fresh_Borrow`, or NO_LOAN.
@(private)
prov_slot_fresh_loan :: proc(graph: ^Flow_Graph, slot: int) -> Loan_Id {
	if fresh, is_fresh := graph.prov_slots[slot].borrow.(Prov_Fresh_Borrow); is_fresh {
		return fresh.loan
	}
	return NO_LOAN
}

// design.md "Weakening and reborrows": a mutable carrier copied out through a
// pointer, as `pp^`, reborrows each carrier the `Load` read. A read-only copy only
// extends what the carrier it was read from belongs to, settled with every link
// made (`Prov_Reborrow.pending`).
@(private)
prov_reborrow_loaded :: proc(graph: ^Flow_Graph, event: Prov_Event) {
	if prov_slot_is_loaded_read_only(graph, event.slot) {
		for source in event.sources {
			append(&graph.reborrows, Prov_Reborrow {
				source = source, derived = event.slot, span = event.span, passes_on = true,
				pending = true,
			})
		}
		return
	}
	if !prov_slot_is_loaded_mutable(graph, event.slot) {
		return
	}
	// Its capability is the one the copy is stored with, or none for a read.
	mutable := !event.reads_only
	for reborrow in graph.reborrows {
		if reborrow.source == event.slot {
			mutable = reborrow.mutable && !event.reads_only
		}
	}
	passes_on := graph.prov_slots[event.slot].viewed
	for source in event.sources {
		if prov_slot_is_mutable_carrier(graph, source) || graph.prov_slots[source].caller_mutable {
			append(&graph.reborrows, Prov_Reborrow {
				source = source, derived = event.slot, span = event.span, mutable = mutable, passes_on = passes_on,
				moved = graph.prov_slots[event.slot].moved_out, names_element = graph.prov_slots[event.slot].names_element,
			})
		}
	}
}

// A read-only copy of a place that may hold a reborrow of a mutable carrier reborrows it
// too (design.md "Weakening and reborrows"): a store or a call may leave one there, or a
// definition met after the copy, over a loop's back edge. So this asks once every link is
// made: one taken from a slot that comes to reborrow a mutable carrier, directly or through
// the reborrows it derives from, extends that, and any other is gone. A copy made before
// the reborrow holds no loan of it, which the overlap check sees.
@(private)
prov_settle_pending_reborrows :: proc(graph: ^Flow_Graph) {
	reborrows_mutable := make([]bool, len(graph.prov_slots), graph.alloc)
	for changed := true; changed; {
		changed = false
		for &reborrow in graph.reborrows {
			if reborrow.pending {
				if reborrows_mutable[reborrow.source] {
					reborrow.pending = false
					reborrows_mutable[reborrow.derived] = true
					changed = true
				}
				continue
			}
			if reborrows_mutable[reborrow.derived] {
				continue
			}
			source := reborrow.source
			if reborrows_mutable[source] || prov_slot_is_mutable_carrier(graph, source) || prov_slot_is_loaded_mutable(graph, source) ||
			   graph.prov_slots[source].caller_mutable {
				reborrows_mutable[reborrow.derived] = true
				changed = true
			}
		}
	}
	kept := 0
	for reborrow in graph.reborrows {
		if !reborrow.pending {
			graph.reborrows[kept] = reborrow
			kept += 1
		}
	}
	resize(&graph.reborrows, kept)
}

// Whether a read-only carrier may come to hold a reborrow of a mutable one, whatever the
// links made so far say: read out through a pointer, copied from one that may, or in a
// place something may store to.
@(private)
prov_slot_may_come_to_reborrow :: proc(graph: ^Flow_Graph, slot: int) -> bool {
	return prov_slot_is_loaded_read_only(graph, slot) || prov_slot_is_pending(graph, slot) || prov_slot_may_take_store(graph, slot)
}

// Whether a read-only carrier sits in lasting storage a store through carriers or a
// call may write. A parameter's own binding is no such place: nothing can write it.
@(private = "file")
prov_slot_may_take_store :: proc(graph: ^Flow_Graph, slot: int) -> bool {
	entry := graph.prov_slots[slot]
	sym := symbol_of(graph.k.c, entry.symbol)
	if !prov_slot_is_stored(entry) || sym == nil || sym.kind == .Parameter && sym.immutable {
		return false
	}
	return prov_type_is_read_only_carrier(graph.k.c, slot_carrier_type(graph, slot))
}

// `Prov_Reborrow.pending`
@(private)
prov_slot_is_pending :: proc(graph: ^Flow_Graph, slot: int) -> bool {
	for reborrow in graph.reborrows {
		if reborrow.derived == slot && reborrow.pending {
			return true
		}
	}
	return false
}

@(private)
prov_slot_is_loaded_read_only :: proc(graph: ^Flow_Graph, slot: int) -> bool {
	entry := graph.prov_slots[slot]
	return entry.loaded && prov_type_is_read_only_carrier(graph.k.c, entry.content_type)
}

@(private = "file")
prov_type_is_read_only_carrier :: proc(c: ^Compiler, type: Type_Id) -> bool {
	return prov_type_is_view_carrier(c, type) && !carrier_is_mutable(c, type)
}

// A carrier that views storage, as a provider or an allocator handle does not.
@(private)
prov_type_is_view_carrier :: proc(c: ^Compiler, type: Type_Id) -> bool {
	return type_is_carrier(c, type) && !type_is_region_provider(c, type) && type_underlying(c, type) != TYPE_ALLOCATOR
}

// design.md "Allocator regions and region provenance": an owner moved in, a copy
// of one passed in, and what a carrier passed in views keep the argument's
// region, which the caller substitutes; so does an allocator handle, and what a
// view carrier inside a record passed in views. An allocator inside one, as an
// `Option(Allocator)`'s payload, is one the analysis cannot name instead
// (`prov_add_received_allocator`).
@(private)
prov_type_keeps_argument_region :: proc(c: ^Compiler, type: Type_Id) -> bool {
	if type_underlying(c, type) == TYPE_ALLOCATOR || type_is_managed(c, type) || prov_type_is_view_carrier(c, type) {
		return true
	}
	for path in carrier_shape(c, type) {
		if path.truncated || prov_type_is_view_carrier(c, path.type) {
			return true
		}
	}
	return false
}

@(private)
prov_slot_is_loaded_mutable :: proc(graph: ^Flow_Graph, slot: int) -> bool {
	entry := graph.prov_slots[slot]
	c := graph.k.c
	return entry.loaded && entry.content_type != INVALID_TYPE &&
		!type_is_region_provider(c, entry.content_type) && carrier_is_mutable(c, entry.content_type)
}

// A traversal of a mutable carrier reborrows it for as long as the traversal,
// or anything taken from an element, is used: the carrier is suspended, as a
// local source is by its loop loan.
@(private)
prov_reborrow_traversal :: proc(graph: ^Flow_Graph, sources: []int, span: Span, mutable: bool) -> []int {
	out := make([dynamic]int, 0, len(sources), graph.alloc)
	for slot in sources {
		if !prov_slot_is_mutable_carrier(graph, slot) {
			append(&out, slot)
			continue
		}
		derived := prov_temp_slot(graph)
		prov_def_copy(graph, derived, slot, span)
		append(&graph.reborrows, Prov_Reborrow{source = slot, derived = derived, span = span, mutable = mutable})
		append(&out, derived)
	}
	return out[:]
}

// A reborrow of a carrier, named or a traversal's, whose copies extend it.
@(private)
prov_slot_is_reborrow :: proc(graph: ^Flow_Graph, slot: int, mutable_only := false) -> bool {
	for reborrow in graph.reborrows {
		if reborrow.derived == slot && !reborrow.pending && (reborrow.mutable || !mutable_only) {
			return true
		}
	}
	return false
}

// A named slot, or a field of one, holding a mutable view (`^mut T`, `[]mut T`,
// `dyn mut I`); a temporary is left alone. A region provider is not one: copies
// of an allocator share it by design.
@(private)
prov_slot_is_mutable_carrier :: proc(graph: ^Flow_Graph, slot: int) -> bool {
	entry := graph.prov_slots[slot]
	type := entry.content_type
	if type == INVALID_TYPE {
		sym := symbol_of(graph.k.c, entry.symbol)
		if sym == nil {
			return false
		}
		type = sym.type
	}
	c := graph.k.c
	return prov_slot_is_stored(entry) && !type_is_region_provider(c, type) && carrier_is_mutable(c, type)
}

// Places reached through carriers: their loans, the accesses through them, the
// carrier hops a place is read through, and its subscripts.
package lokec

// A loan of `place`, reached through `carriers`, at `path` below their
// pointee (`Prov_Place_Loan`), as a switch over `h^.first` takes while a payload
// binding is in use (design.md "Switch ownership"). The slot returned is the
// snapshot, whose value carries the loan wherever it is copied.
@(private)
prov_place_loan :: proc(
	graph: ^Flow_Graph, carriers: []int, path: []Proj_Step, mutable: bool, what: string, place: Expr, borrows := false,
) -> []int {
	if len(carriers) == 0 || graph.current == NO_BLOCK {
		return nil
	}
	span := expr_span(place)
	offsets, _, merged := prov_value_offset(graph, carriers)
	places := make([]Prov_Offset, len(offsets), graph.alloc)
	for at, index in offsets {
		places[index] = Prov_Offset{prov_concat_path(graph, at.path, path), at.storage}
	}
	element := prov_view_at(graph, place, carriers)
	in_element: Prov_Element_Slots
	if borrows {
		in_element, _ = prov_view_element(graph, place)
	}
	slot := prov_temp_slot(graph)
	graph.place_loan_of[slot] = len(graph.place_loans)
	append(&graph.place_loans, Prov_Place_Loan {
		slot = slot, paths = prov_offset_paths(graph, places), mutable = mutable, borrows = borrows, what = what, span = span,
		place = span_text(graph.k.c, span), element = element, in_element = in_element,
	})
	graph.prov_slots[slot].element_defs = len(in_element.slots) > 0
	// design.md "Minimum provenance precision": a loan of places merged past
	// the limit, or of places of several storages, may cover a place the
	// carriers never point at, so a rejection it causes names the limit.
	graph.prov_slots[slot].precision |= prov_offset_precision(places, merged)
	prov_emit(graph, Prov_Event {
		kind = .Def, slot = slot, loan = NO_LOAN, sources = carriers, span = span, place_loan = len(graph.place_loans),
		element = element,
	})
	// A borrow points at the place it is of (`Prov_Slot.offsets`).
	if borrows {
		graph.prov_slots[slot].offsets = places
		graph.prov_slots[slot].offsets_merged = merged
	}
	return prov_one(graph, slot)
}

// A write through `carriers` at `path` below their pointee, which a place
// loan of the same storage forbids (`prov_place_loan`). A carrier that is a
// borrow of a place, as `count` for `count := &mut h^.count`, writes below
// that place (`prov_value_offset`). The event's index in the current block,
// -1 without carriers. `place`, when given, is the place accessed, which may be
// one element of a view (`prov_view_at`).
@(private)
prov_write_through :: proc(graph: ^Flow_Graph, carriers: []int, path: []Proj_Step, span: Span, verb: string, place: Expr = nil) -> int {
	return prov_access_through(graph, carriers, path, span, .Write, verb, prov_view_at(graph, place, carriers))
}

// A read through `carriers` at `path` below their pointee, which a mutable
// place loan of the same storage forbids.
@(private)
prov_read_through :: proc(graph: ^Flow_Graph, carriers: []int, path: []Proj_Step, span: Span, place: Expr = nil) {
	prov_access_through(graph, carriers, path, span, .Read, "read", prov_view_at(graph, place, carriers))
}

// Carriers pointing at different places, as a record holding `&mut h^.count`
// and `&mut h^.total` does, are each accessed at their own, and a carrier
// that may point at either, as one chosen between the two, at both. The
// events emitted are contiguous; the index of the first.
@(private = "file")
prov_access_through :: proc(
	graph: ^Flow_Graph, carriers: []int, path: []Proj_Step, span: Span, access: Access_Kind, verb: string, element: Prov_View_At,
) -> int {
	if len(carriers) == 0 || graph.current == NO_BLOCK {
		return -1
	}
	first := len(graph.blocks[graph.current].prov)
	offsets, _, merged := prov_value_offset(graph, carriers)
	if prov_offsets_agree(graph, carriers, offsets) {
		// As for a place loan (`prov_place_loan`): merged places name the limit.
		precision := prov_offset_precision(offsets, merged)
		for at in prov_offset_paths(graph, offsets) {
			prov_emit(graph, Prov_Event {
				kind = .Through, into = carriers, path = prov_concat_path(graph, at, path), span = span, verb = verb, access = access,
				precision = precision, element = element,
			})
		}
		return first
	}
	for carrier in carriers {
		if !prov_slot_is_through(graph, carrier) {
			prov_access_through(graph, prov_one(graph, carrier), path, span, access, verb, element)
		}
	}
	return first
}

// design.md "Places and overlap": the constant element of a named view that
// `place` is in, when `carriers` are that view's own slot, as for `s[1].count`
// (`Prov_View_At`). A view parameter's element is where its index says
// relative to the parameter's own loan; a local view's is worked out by the
// solve from where the view starts. None for any other place, or one reached
// through a copy of the view, whose start is not known.
@(private)
prov_view_at :: proc(graph: ^Flow_Graph, place: Expr, carriers: []int) -> Prov_View_At {
	if place == nil || len(carriers) != 1 {
		return {}
	}
	view, index, found := prov_constant_view_element(graph, place)
	if !found {
		return {}
	}
	slot, named := prov_slot_for_symbol(graph, view)
	if !named || carriers[0] != slot {
		return {}
	}
	if symbol_of(graph.k.c, view).kind != .Parameter {
		return Prov_View_At{slot = slot + 1, index = index}
	}
	if _, own := prov_view_parameter_loan(graph, view); own != NO_LOAN {
		return Prov_View_At{slot = slot + 1, loan = int(own) + 1, index = index}
	}
	return {}
}

// Whether every slot of `carriers` that names storage points at `offsets`.
@(private)
prov_offsets_agree :: proc(graph: ^Flow_Graph, carriers: []int, offsets: []Prov_Offset) -> bool {
	for carrier in carriers {
		if !prov_slot_is_through(graph, carrier) {
			own, _ := prov_carrier_offsets(graph, carrier)
			if !prov_offsets_cover(own, offsets, any_storage = true) || !prov_offsets_cover(offsets, own, any_storage = true) {
				return false
			}
		}
	}
	return true
}

// `prov_write_through` for a place its caller walked as a value, as a
// compound assignment or an `inout` receiver does. That walk only read the
// carriers, so they are read again as written through, which a reborrow of
// the place suspends (design.md "Weakening and reborrows"); the subscripts
// below the last carrier were walked already. Returns what
// `prov_read_through_carrier` does.
@(private)
prov_write_through_place :: proc(graph: ^Flow_Graph, place: Expr, span: Span) -> (carriers: []int, below: []Proj_Step, through: bool) {
	carriers, below, through = prov_read_through_carrier(graph, place, store = true)
	if through {
		prov_write_through(graph, carriers, below, span, "write", place)
	}
	return
}

// design.md "Weakening and reborrows": one carrier an access to a place goes
// through, read off the normalized place. `path` is where below the carrier's
// pointee the access goes on: to the place itself for the first hop, to the
// carrier of the hop before it for each later one.
Place_Hop :: struct {
	carrier: Value_Id,
	path:    []Proj_Step,
}

// The carriers a place is reached through, the one whose pointee holds it
// first and the outermost last; none for a place in lexical storage or one
// not reached through a carrier. Every access to a place, whether it loads,
// borrows, or stores, goes through these.
@(private)
prov_place_hops :: proc(graph: ^Flow_Graph, place: Expr) -> []Place_Hop {
	hops := make([dynamic]Place_Hop, 0, 2, graph.alloc)
	for at := prov_input_place(graph, place); true; {
		carrier, indirect := at.base.(Value_Id)
		if !indirect {
			break
		}
		// A view's loans already name the elements it views, so an element is
		// at no step below them.
		path := at.path
		if type_indexes_through_view(graph.k.c, prov_value(graph, carrier).type) {
			path = path[min(1, len(path)):]
		}
		append(&hops, Place_Hop{carrier, path})
		at = prov_value(graph, carrier).place
	}
	return hops[:]
}

// Reads the carriers `place` is reached through, outermost first, loading each
// inner one out of the pointee of the one before it, and returns the slots of
// the one whose pointee holds `place`, with the path below it. A `store`
// leaves the subscripts below the last carrier to itself. False when `place`
// is not reached through a carrier. `walk`, when given, collects the events
// reading the carriers (`Prov_Through_Borrow.walk_reads`).
@(private)
prov_read_through_carrier :: proc(
	graph: ^Flow_Graph, place: Expr, reads_only := false, store := false, walk: ^[dynamic]Prov_Event_At = nil, reads := true,
) -> ([]int, []Proj_Step, bool) {
	hops := prov_place_hops(graph, place)
	if len(hops) == 0 {
		return nil, nil, false
	}
	carriers := prov_reach_hop(graph, place, hops, 0, reads_only, store, walk)
	if !store && reads {
		prov_read_through(graph, carriers, hops[0].path, expr_span(place), place)
	}
	return carriers, hops[0].path, true
}

// Adds to `walk` the `.Live` and `.Load` events emitted in the current block
// from index `from` on.
@(private)
prov_note_walk_reads :: proc(graph: ^Flow_Graph, walk: ^[dynamic]Prov_Event_At, from: int) {
	if walk == nil || graph.current == NO_BLOCK {
		return
	}
	events := graph.blocks[graph.current].prov[:]
	for index in from ..< len(events) {
		if events[index].kind == .Live || events[index].kind == .Load {
			append(walk, Prov_Event_At{graph.current, index})
		}
	}
}

@(private)
prov_next_event :: proc(graph: ^Flow_Graph) -> int {
	return graph.current == NO_BLOCK ? 0 : len(graph.blocks[graph.current].prov)
}

// The slots holding `hops[at]`'s carrier, read through the hops outside it,
// and then the subscripts between it and what it leads to. Read only, a
// mutable carrier copied out of another, as `p^` in `p^^[0]`, reborrows the
// carrier it came from read-only, which another read-only reborrow of that one
// allows (design.md "Weakening and reborrows"): a loop over `p^^` may still
// read through `p`. Only the carriers' own reads go to `walk`: an index may
// write, as `idx(q)` in `p^.cells[idx(q)]` does, so a subscript, or a carrier
// whose own subscripts may, is walked without it.
@(private = "file")
prov_reach_hop :: proc(graph: ^Flow_Graph, place: Expr, hops: []Place_Hop, at: int, reads_only, store: bool, walk: ^[dynamic]Prov_Event_At) -> []int {
	carrier := prov_value(graph, hops[at].carrier).origin
	inner := at == 0 ? place : prov_value(graph, hops[at - 1].carrier).origin
	indices := make([dynamic]Expr, 0, 0, graph.alloc)
	prov_segment_indices(inner, carrier, &indices)
	// An index that may write the carrier, read after it, sees it as it was.
	captures := prov_indices_may_write(graph.k.c, indices[:]) && !(store && at == 0)
	only := reads_only && !captures
	slots: []int
	if at == len(hops) - 1 {
		if _, _, named := prov_place_of(graph, carrier); named {
			own := make([dynamic]Expr, 0, 0, graph.alloc)
			prov_segment_indices(carrier, nil, &own)
			from := prov_next_event(graph)
			slots = prov_read_carrier(graph, carrier, only)
			if !prov_indices_may_write(graph.k.c, own[:]) {
				prov_note_walk_reads(graph, walk, from)
			}
		} else {
			slots = walk_flow_expr(graph, carrier)
		}
	} else {
		loads := only || prov_read_is_reads_only(graph.k.c, prov_type(graph, carrier))
		outer := prov_reach_hop(graph, place, hops, at + 1, loads, false, walk)
		from := prov_next_event(graph)
		slots = prov_load_content(
			graph, outer, hops[at + 1].path, prov_type(graph, carrier), expr_span(carrier), reads_only = loads,
			place = carrier,
		)
		prov_note_walk_reads(graph, walk, from)
		if only {
			// Each loaded mutable carrier is replaced by a read-only reborrow of it.
			slots = prov_reborrow_each(graph, slots, expr_span(carrier), false, prov_slot_is_loaded_mutable)
		}
	}
	if captures {
		slots = prov_capture(graph, slots, expr_span(inner))
	}
	if !(store && at == 0) {
		for index in indices {
			walk_flow_expr(graph, index)
		}
	}
	return prov_reach(graph, slots, expr_span(inner))
}

// A carrier loaded through another, as `p^` for `p^^.count`, is named in
// diagnostics by the carrier it was loaded through, `p`.
@(private)
prov_name_loaded :: proc(graph: ^Flow_Graph, slots, outer: []int) {
	name := ""
	for slot in outer {
		if graph.prov_slots[slot].name != "" {
			name = graph.prov_slots[slot].name
			break
		}
	}
	for slot in slots {
		if entry := &graph.prov_slots[slot]; entry.name == "" && entry.loaded && entry.symbol == INVALID_SYMBOL {
			entry.name = name
		}
	}
}

// The index expressions from `from` down to the carrier `to`, or to the root
// when `to` is nil, in the order they are evaluated.
@(private = "file")
prov_segment_indices :: proc(from, to: Expr, out: ^[dynamic]Expr) {
	if from == nil || to != nil && expr_base(from) == expr_base(to) {
		return
	}
	#partial switch v in from {
	case ^Expr_Selector:
		prov_segment_indices(v.operand, to, out)
	case ^Expr_Postfix:
		prov_segment_indices(v.operand, to, out)
	case ^Expr_Index:
		prov_segment_indices(v.operand, to, out)
		append(out, ..v.indices)
	}
}

// An index that may run a program's code may write the carrier being indexed.
@(private)
prov_indices_may_write :: proc(c: ^Compiler, indices: []Expr) -> bool {
	for index in indices {
		if prov_expr_may_write(c, index) {
			return true
		}
	}
	return false
}

// The root and projection a place names, or none when it goes through a carrier;
// that is a use of the carrier, not a competing access to a root.
@(private)
prov_place_of :: proc(graph: ^Flow_Graph, e: Expr) -> (Root_Id, []Proj_Step, bool) {
	return prov_root_place(graph, prov_input_place(graph, e))
}

@(private)
prov_value_place_of :: proc(graph: ^Flow_Graph, id: Value_Id) -> (Root_Id, []Proj_Step, bool) {
	return prov_root_place(graph, prov_value(graph, id).place)
}

@(private)
prov_root_place :: proc(graph: ^Flow_Graph, place: Prov_Place) -> (Root_Id, []Proj_Step, bool) {
	if storage, direct := place.base.(Storage_Id); direct {
		root := prov_root_for_storage(graph, storage)
		return root, place.path, root != NO_ROOT
	}
	return NO_ROOT, nil, false
}

// Walks a place chain's index expressions; the place is one access, not one per
// link.
@(private)
prov_walk_subscripts :: proc(graph: ^Flow_Graph, e: Expr, publish_map_keys := false) {
	#partial switch v in e {
	case ^Expr_Selector:
		prov_walk_subscripts(graph, v.operand, publish_map_keys)
	case ^Expr_Postfix:
		if v.boxed {
			prov_walk_subscripts(graph, v.operand, publish_map_keys)
		}
	case ^Expr_Index:
		prov_walk_subscripts(graph, v.operand, publish_map_keys)
		key_sources: []int
		for index, position in v.indices {
			loans := walk_flow_expr(graph, index)
			if position == 0 {
				key_sources = loans
			}
		}
		if len(v.bound) == 0 && underlying_kind(graph.k.c, prov_type(graph, v.operand)) == .Map {
			// A map index hashes its key and compares it with the stored ones.
			prov_key_effects(graph, prov_type(graph, v.operand), v.span)
			if publish_map_keys && len(v.indices) == 1 {
				prov_publish_map_key(graph, v, key_sources)
			}
		}
	}
}

// Assigning through a map place may insert its key; an existing equal key stays,
// so the key dependency joins.
@(private = "file")
prov_publish_map_key :: proc(graph: ^Flow_Graph, v: ^Expr_Index, key_sources: []int) {
	map_type := prov_type(graph, v.operand)
	key_type := underlying_info(graph.k.c, map_type).key
	prov_copy_effects(graph, key_type, v.span)
	prov_retain_escape(graph, v.operand, key_sources, v.span)
	root, path, ok := prov_place_of(graph, v.operand)
	if !ok {
		prov_store_map_key_region(graph, prov_input_value(graph, v.operand), prov_input_value(graph, v.indices[0]))
		// Reached through a carrier: publish to what it may name.
		if through := prov_retain_through_carrier(graph, v.operand); len(through) > 0 {
			prov_reborrow(graph, key_sources, key_type)
			prov_emit(graph, Prov_Event {
				kind = .Publish, span = v.span, sources = key_sources, into = through,
			})
		}
		return
	}
	entry := prov_extend(graph, path, prov_map_entry_step(graph, map_type, v.indices[0]))
	written := prov_extend(graph, entry, proj_field(PROJ_MAP_KEY))
	prov_event(graph, Prov_Event_Key_Escape{prov_input_value(graph, v.indices[0]), expr_span(v.indices[0]), graph.roots[int(root)].symbol, prov_owner_name(graph, v.indices[0])})
	prov_define_value_regions(graph, root, written, prov_input_value(graph, v.indices[0]))
	if content := prov_content_at(graph, root, written); len(content) > 0 {
		prov_define_content(graph, content, key_sources, v.span, written, key_type, true)
	}
}

@(private)
prov_const_int :: proc(graph: ^Flow_Graph, e: Expr) -> (i64, bool) {
	base := expr_base(e)
	if base == nil || base.const_value.kind != .Integer {
		return 0, false
	}
	return bi_to_i64(graph.k.c, base.const_value.integer)
}

// A slice's optional constant bound, `default` when it is not written.
@(private)
prov_const_bound :: proc(graph: ^Flow_Graph, e: Expr, default: i64) -> (i64, bool) {
	if e == nil {
		return default, true
	}
	return prov_const_int(graph, e)
}

@(private)
prov_range_step :: proc(graph: ^Flow_Graph, v: ^Expr_Slice) -> Proj_Step {
	low, low_ok := prov_const_bound(graph, v.lo, 0)
	high, high_ok := i64(0), false
	if v.hi != nil {
		high, high_ok = prov_const_int(graph, v.hi)
	} else if info := underlying_info(graph.k.c, prov_type(graph, v.operand)); info != nil && info.kind == .Array {
		high, high_ok = i64(info.count), true
	}
	if !low_ok || !high_ok || high <= low {
		return proj_wild()
	}
	return proj_range(low, high)
}

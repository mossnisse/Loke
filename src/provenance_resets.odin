// The region reset check: a reset event, and what it may end that is still
// in use, held by the caller, or promised (design.md "@(allocator_reset)").
package lokec

// What a recorded reset ends, from the facts at hand.
@(private)
prov_materialize_reset :: proc(graph: ^Flow_Graph, op: Prov_Event_Reset) {
	set: Region_Set
	switch region in op.region {
	case Region_Set:
		set = region
	case Value_Id:
		set = prov_region_of(graph, region)
	case Prov_Reset_Indirect:
		// Only a provider something was lent can be reached through a pointer.
		set = Region_Set{}
		for id in region.owners {
			if graph.lent_locals[id] { region_merge(&set, prov_provider_region(graph, id)) }
		}
		if region_is_empty(set) { return }
	}
	// A region the analysis cannot name, such as an allocator in a received
	// record's field, is pre-existing: it stays uncovered.
	// A locally created region needs no promise (design.md "@(allocator_reset)").
	covered, unmarked := true, ""
	if !region_is_local_only(set) {
		covered, unmarked = prov_reset_promise(graph, set)
	}
	event := Prov_Event {
		kind          = .Reset,
		span          = op.span,
		access        = op.direct ? .Invalidate : .Write,
		name          = unmarked,
		region        = set,
		reset_covered = covered,
		ends          = op.ends,
		provider_end  = op.provider_end,
		unwind_from   = op.unwind_from,
	}
	if owner, merged := prov_reset_blocker(graph, op, set); owner != nil {
		event.verb = identifier_text(graph.k.c, owner.name)
		event.owner_span = owner.span
		event.precision |= merged
	}
	// Evaluated operands remain live while later operands run.
	if event.verb == "" {
		for held in op.held {
			region := op.provider_end ? prov_result_region(graph, held) : prov_reset_value_region(graph, held)
			if !region_is_empty(region) && regions_may_overlap(region, set) {
				event.verb = "this temporary"
				event.owner_span = expr_span(prov_value(graph, held).origin)
				break
			}
		}
	}
	if event.verb == "" {
		for root in op.temporaries {
			if prov_reset_temporary(graph, root, &event) { break }
		}
	}
	// design.md "Allocators": a result reaches the caller before the deferred
	// statements run, so it is live across a reset among them.
	if returning, held := op.returning.?; held && event.verb == "" && !op.provider_end {
		if regions_may_overlap(prov_returning_region(graph, returning), set) {
			event.ends_result = true
			event.owner_span = returning.span
		}
	}
	prov_emit(graph, event)
}

// design.md "Allocator regions and region provenance": a live owner in an
// overlapping region blocks the reset, since its cleanup still runs; a dropped
// owner no longer blocks. A live child provider depends on its parent's region.
// One whose overlap a store may have left only through a merged target blocks with
// that budget's `merged` loss, so an owner that certainly blocks is named first.
@(private = "file")
prov_reset_blocker :: proc(graph: ^Flow_Graph, op: Prov_Event_Reset, set: Region_Set) -> (blocker: ^Symbol, merged: Precision_Loss) {
	for id in op.live.owners {
		owner := symbol_of(graph.k.c, id)
		// The local being ended is what ends the region, not a dependant of it.
		if owner == nil || id == op.ending {
			continue
		}
		region: Region_Set
		switch {
		case type_is_region_provider(graph.k.c, owner.type):
			region = graph.provider_parents[id]
		case op.provider_end:
			region = prov_region_for_symbol(graph, id)
		case:
			region = prov_reset_symbol_region(graph, id, owner.type)
		}
		if region_is_empty(region) || !regions_may_overlap(region, set) {
			continue
		}
		stored: Prov_Merged_Region
		if root, found := graph.root_by_symbol[id]; found {
			stored = graph.merged_regions[prov_storage_for_root(graph, root)]
		}
		if stored.precision == {} || !regions_may_overlap(stored.region, set) {
			return owner, {}
		}
		if blocker == nil {
			blocker, merged = owner, stored.precision
		}
	}
	return
}

// What a result already handed to the caller holds while its return's
// deferred statements run.
@(private = "file")
prov_returning_region :: proc(graph: ^Flow_Graph, returning: Prov_Returning) -> Region_Set {
	if propagated, known := returning.propagated.?; known {
		return prov_reset_fields_region(graph, returning.result, prov_error_region_fields(graph, propagated, returning.result))
	}
	return prov_reset_value_region(graph, returning.value)
}

// design.md "Temporaries and procedure boundaries": a converted view still
// lends from its managed temporary until that root's actual cleanup boundary.
@(private = "file")
prov_reset_temporary :: proc(graph: ^Flow_Graph, root: Root_Id, event: ^Prov_Event) -> bool {
	temporary := graph.roots[int(root)]
	region := Region_Set{}
	// All of it for a provider's end, or the part a reset ends.
	join :: proc(graph: ^Flow_Graph, region: ^Region_Set, type: Type_Id, fields: []Prov_Region_Content, all: bool) {
		if !all {
			region_merge(region, prov_reset_fields_region(graph, type, fields))
			return
		}
		for field in fields { region_merge(region, field.region) }
	}
	if temporary.owner != nil {
		fields := prov_result_region_fields(graph, prov_input_value(graph, temporary.owner), temporary.dropped)
		join(graph, &region, temporary.dropped, fields, event.provider_end)
	}
	// Later writes into a temporary's backing storage are live until its
	// actual cleanup, just as its initial owners are (design.md
	// "Allocator regions and region provenance").
	if storage := prov_storage(graph, temporary.storage); storage.key.temporary != nil && type_is_managed(graph.k.c, storage.type) {
		join(graph, &region, storage.type, graph.region_content[temporary.storage][:], event.provider_end)
	}
	if region_is_empty(region) || !regions_may_overlap(region, event.region) { return false }
	event.verb, event.owner_span = temporary.name, temporary.span
	return true
}

// Whether every allocator parameter the set names carries the reset promise,
// or the name of one that does not.
@(private = "file")
prov_reset_promise :: proc(graph: ^Flow_Graph, set: Region_Set) -> (covered: bool, name: string) {
	params := set.params
	for index in next_region_param(&params) {
		sym := prov_parameter_symbol(graph, index)
		if sym == nil {
			continue
		}
		if !sym.allocator_reset {
			return false, identifier_text(graph.k.c, sym.name)
		}
		covered = true
	}
	// Every alternative that is not this body's own needs the promise; the
	// default or an unknown allocator never has it.
	if set.default || set.unknown {
		return false, ""
	}
	return covered, ""
}

@(private = "file")
prov_parameter_symbol :: proc(graph: ^Flow_Graph, index: int) -> ^Symbol {
	return index < len(graph.param_symbols) ? symbol_of(graph.k.c, graph.param_symbols[index]) : nil
}

// A reset may end every allocation in its region (design.md "@(allocator_reset)"): checked for its
// promise and for live owners it would strand.
@(private)
prov_reset :: proc(
	graph: ^Flow_Graph,
	region: Prov_Reset_Region,
	span: Span,
	direct: bool,
	at: ^Expr_Call,
	cleanup_live: Reset_Liveness = {},
	ends := "",
	ending := INVALID_SYMBOL,
	provider_end := false,
) {
	// Liveness is lifecycle's answer, recorded one pass earlier.
	live := cleanup_live
	if at != nil {
		found: bool
		live, found = graph.k.c.reset_dead[reset_key(graph, at)]
		assert(found, "the provenance walk reached a reset the lifecycle walk did not")
	}
	if graph.current == NO_BLOCK {
		return
	}
	held := make([]Value_Id, len(graph.held_owners), graph.alloc)
	for value, index in graph.held_owners { held[index] = prov_input_value(graph, value) }
	temporaries := make([dynamic]Root_Id, 0, len(graph.temp_roots), graph.alloc)
	append(&temporaries, ..graph.temp_roots[:])
	for cleanup in graph.in_scope {
		if cleanup.kind == .Prov_Root { append(&temporaries, cleanup.root) }
	}
	op := Prov_Event_Reset {
		region = region, span = span, direct = direct, live = live, ends = ends, ending = ending,
		provider_end = provider_end, held = held, temporaries = temporaries[:],
	}
	if graph.expansion.unwinding { op.unwind_from = graph.unwind_at }
	if graph.returning != nil { op.returning = graph.returning^ }
	prov_event(graph, op)
}

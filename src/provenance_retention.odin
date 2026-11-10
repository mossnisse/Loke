// What a call may leave behind: carriers it moves among its arguments, and what
// `@(escape=...)` lets it keep (design.md "Retaining a borrow").
package lokec

import "core:fmt"

// design.md "Values that contain borrows": what a call may do to the carriers its
// arguments lead to (`Carrier_Move`). What it may leave in two places is linked as a
// reborrow of the other, in each direction, as which place it was read from is not
// known; the links hold only while the two hold the same loan.
@(private)
prov_call_carrier_moves :: proc(graph: ^Flow_Graph, v: ^Expr_Call, container_op: Container_Op, actuals: [][]int) {
	c := graph.k.c
	consulted := make([dynamic]Symbol_Id, 0, 4, graph.alloc)
	moves := call_carrier_moves(c, v, graph.literal.symbol, len(actuals), &consulted, graph.alloc)
	prov_note_summary_dependencies(graph, consulted[:])
	if .Moves_Elements in CONTAINER_OP_EFFECTS[container_op] && len(actuals) > 0 {
		if moves == nil {
			moves = make([]Carrier_Move, len(actuals), graph.alloc)
		}
		receiver := underlying_info(c, prov_parameter_type(graph, v, 0))
		element := receiver == nil ? INVALID_TYPE : receiver.element
		if type_carries_borrow(c, element).any {
			moves[0].types, moves[0].any = carried_types(c, element, graph.alloc)
		}
	}
	for move, index in moves {
		if !move.any && len(move.types) == 0 {
			continue
		}
		if len(actuals[index]) == 0 && (index != 0 || .Removes_Element not_in CONTAINER_OP_EFFECTS[container_op]) {
			continue
		}
		into := actuals[index]
		if index == 0 && .Removes_Element in CONTAINER_OP_EFFECTS[container_op] {
			// Its actual is what the removal hands back, not the storage it shifts.
			if root, path, ok := prov_place_of(graph, v.bound[0]); ok {
				into = prov_borrow(graph, root, path, true, v.span, "borrow")
			} else {
				into = prov_carrier_slots(graph, v.bound[0])
			}
		}
		slot := prov_temp_slot(graph)
		prov_emit(graph, Prov_Event{kind = .Rearrange, slot = slot, into = into, span = v.span, rearranged = move})
		graph.has_linked_store ||= move.copied
	}
}

// Every slot of lasting storage, or slot standing for caller storage, that holds a
// carrier a call may have copied there, of those `rearranged` found it reaching, is
// linked to the others through the slot of the call's `Rearrange`, as there may be many.
// Each link holds from that event on (`Prov_Reborrow.from_store`).
@(private)
prov_link_copied_carriers :: proc(graph: ^Flow_Graph, event: Prov_Event, rearranged: []int) {
	c := graph.k.c
	hub := event.slot
	may_hold :: proc(c: ^Compiler, type: Type_Id, move: Carrier_Move) -> bool {
		if type == INVALID_TYPE || move.any {
			return true
		}
		for moved in move.types {
			if carrier_may_land_in(c, moved, type) {
				return true
			}
		}
		return false
	}
	// A body that leaves only read-only carriers there weakened what it copied, so what
	// came of it suspends no read of the carrier it came from.
	copies_mutable := event.rearranged.any
	for moved in event.rearranged.types {
		copies_mutable ||= carrier_is_mutable(c, moved)
	}
	for candidate in rearranged {
		entry := graph.prov_slots[candidate]
		sym := symbol_of(c, entry.symbol)
		if entry.kind == .Temporary || sym != nil && sym.kind == .Parameter && sym.immutable {
			continue
		}
		type := slot_carrier_type(graph, candidate)
		if type != INVALID_TYPE && (!type_is_carrier(c, type) || type_is_region_provider(c, type)) {
			continue
		}
		if may_hold(c, type, event.rearranged) {
			// Only a mutable one suspends a read of it.
			mutable := copies_mutable && (type == INVALID_TYPE || carrier_is_mutable(c, type))
			prov_add_reborrow(graph, Prov_Reborrow{source = candidate, derived = hub, span = event.span, mutable = mutable})
			prov_add_reborrow(graph, Prov_Reborrow{source = hub, derived = candidate, span = event.span, mutable = true})
		}
	}
}

// The caller's half of `@(escape=...)`. `static` must outlive the process;
// `stored` is modelled as an assignment into each writable argument, so the loan
// travels and ordinary scope rules handle the rest.
@(private)
prov_call_retention :: proc(graph: ^Flow_Graph, v: ^Expr_Call, actuals: [][]int) {
	proc_type := call_proc_type(graph.k.c, v)
	info := underlying_info(graph.k.c, proc_type)
	if info == nil {
		return
	}
	prov_call_written_regions(graph, prov_input_value(graph, v))
	prov_call_thread_local_writes(graph, v, actuals)
	destinations: []int
	for held, index in actuals {
		level := proc_param_escape(graph.k.c, proc_type, index)
		if level >= .Stored && param_mode_at(info, index) == .Move {
			prov_call_moved_owner(graph, v, index, level)
		}
		if len(held) == 0 || level < .Stored {
			continue
		}
		// The callee may keep what the argument reaches as well as the argument, or
		// of a `..^T` pack only what its lent values hold (design.md "Variadic
		// parameters"): below each operand's borrow, or for a forwarded `[]^T`, below
		// the pointers it holds. Values that hold no borrow leave nothing, where a
		// load into storage with no carriers would stand for the storage itself.
		slots: []int
		if lent, lends := proc_param_lent_type(graph.k.c, proc_type, index); lends {
			if !type_carries_borrow(graph.k.c, lent).any {
				continue
			}
			slots = prov_load_deep(graph, held, v.span, from = call_packs(v, index) ? 1 : 2)
		} else {
			slots = prov_with_content(graph, held, v.span)
		}
		if level == .Static {
			prov_emit(graph, Prov_Event {
				kind    = .Retain,
				span    = v.span,
				sources = slots,
				root    = NO_ROOT,
				retain  = .Process,
				verb    = prov_parameter_label(graph, v, index),
			})
		}
		if destinations == nil {
			destinations = prov_writable_arguments(graph, v, proc_type)
		}
		mutable := type_carries_borrow(graph.k.c, prov_parameter_type(graph, v, index)).mutable
		for target in destinations {
			if target == index {
				prov_retain_into_self(graph, v, index, slots, mutable)
			} else {
				prov_retain_into_argument(graph, v, target, actuals[target], slots, retained = true, retained_mutable = mutable)
			}
		}
	}
}

// design.md "Borrows crossing between tasks": what the task's call may write
// into an argument stays behind after the worker's thread ends, wherever the
// argument came from, a local or the parent's own caller.
@(private)
report_thread_local_writes :: proc(c: ^Compiler, call: ^Expr_Call, body: Symbol_Id) {
	consulted := make([dynamic]Symbol_Id, 0, 4, context.temp_allocator)
	reported := make([]bool, len(call.bound), context.temp_allocator)
	for left in call_thread_local_left(c, call, body, false, &consulted) {
		if left.global == INVALID_SYMBOL || left.at >= len(call.bound) || reported[left.at] {
			continue
		}
		span, written := prov_argument_span(call, left.at)
		sym := symbol_of(c, left.global)
		if sym == nil || !written {
			continue
		}
		reported[left.at] = true
		errorf(
			c, span, "L0730",
			"this task's call may leave a borrow of `%s` in this argument, but it is the worker's own `thread_local` storage, so it cannot cross to the parent",
			identifier_text(c, sym.name),
		)
		add_notef(c, sym.span, "each thread has its own `thread_local` storage, which ends with that thread")
	}
}

// Where bound argument `index` is written: its expression, or for a variadic
// pack its first operand. False for an empty pack, which nothing is left in.
@(private = "file")
prov_argument_span :: proc(call: ^Expr_Call, index: int) -> (Span, bool) {
	if !call_packs(call, index) {
		argument := call.bound[index]
		return argument == nil ? Span{} : expr_span(argument), argument != nil
	}
	cursor: Call_Pack_Cursor
	first, _, written := call_pack_next(call, &cursor)
	return written ? expr_span(first) : Span{}, written
}

// design.md "Borrows crossing between tasks": a callee that may leave a borrow
// of a `thread_local` global in an argument leaves it in the caller's storage,
// so a task's call that does is seen to hand it to the parent. While a body is
// summarized, a callback it received leaves its stand-in instead.
@(private)
prov_call_thread_local_writes :: proc(graph: ^Flow_Graph, v: ^Expr_Call, actuals: [][]int) {
	c := graph.k.c
	consulted := make([dynamic]Symbol_Id, 0, 4, graph.alloc)
	lefts := call_thread_local_left(c, v, graph.literal.symbol, graph.mode == .Prov_Summary, &consulted)
	prov_note_summary_dependencies(graph, consulted[:])
	spawned := v == graph.spawning
	for left in lefts {
		if left.at >= len(actuals) || (v.bound[left.at] == nil && !call_packs(v, left.at)) {
			continue
		}
		if left.callback != INVALID_SYMBOL {
			stand_in := prov_forwarded_root(graph, left.callback, left.argument, v.span)
			sources := prov_borrow(graph, stand_in, nil, false, v.span, "callback's write")
			prov_retain_into_argument(graph, v, left.at, actuals[left.at], sources)
		}
		if left.global != INVALID_SYMBOL {
			first := len(graph.loans)
			sources := prov_borrow(graph, prov_root_for_symbol(graph, left.global), nil, false, v.span, spawned ? "written-back borrow" : "borrow")
			// The spawn reports it from the summary, so the crossing check passes over it.
			for &loan in graph.loans[first:] { loan.written_back = spawned }
			prov_retain_into_argument(graph, v, left.at, actuals[left.at], sources)
		}
	}
}

// The carriers among `carriers`, a value of `type`, that a write may go
// through: each mutable one, and in what any carrier points at, each mutable
// one again. A read-only carrier is no destination, but a mutable one read
// through it is. Below a truncated path, or a pointee whose type is already
// being walked, the walk goes on in the analysis (`prov_load_writable`), since
// a recursive type reaches any depth; a read-only truncated path counts when a
// carrier in it leads to a destination.
@(private)
prov_mutable_reach :: proc(graph: ^Flow_Graph, carriers: []int, type: Type_Id, span: Span, walking: ^map[Type_Id]bool = nil) -> []int {
	c := graph.k.c
	chain := walking
	if chain == nil {
		chain = new(map[Type_Id]bool, graph.alloc)
		chain^ = make(map[Type_Id]bool, graph.alloc)
	}
	out: []int
	for path in carrier_shape(c, type) {
		if path.truncated && !path.mutable {
			visited := make(map[Type_Id]bool, graph.alloc)
			if !truncated_reaches_destination(c, path, &visited) {
				continue
			}
		}
		selected := prov_select_content(graph, carriers, type, path.steps)
		if len(selected) == 0 {
			continue
		}
		if path.mutable {
			out = prov_join(graph, out, selected)
		}
		info := underlying_info(c, path.type)
		if !path.truncated && (info == nil || !prov_type_reaches_destination(c, info.element)) {
			continue
		}
		if path.truncated || chain[info.element] {
			below := prov_load_writable(graph, selected, span)
			// design.md "Minimum provenance precision": what is below a cut is
			// merged, so a borrow written there may land in any of it. A
			// recursive type merges nothing the walk would have kept apart.
			if path.truncated {
				for slot in below { graph.prov_slots[slot].precision |= path.precision }
			}
			out = prov_join(graph, out, below)
			continue
		}
		// design.md "Variadic parameters": a pack also carries its operands'
		// loans, so what it holds may be an element as well as the storage it
		// views. That storage is searched by its own carriers' types, since an
		// element's loan names no element.
		if info.kind == .Slice {
			chain[info.element] = true
			out = prov_join(graph, out, prov_mutable_reach(graph, selected, info.element, span, chain))
			chain[info.element] = false
			out = prov_join(graph, out, prov_load_writable(graph, selected, span))
			continue
		}
		pointee := prov_temp_content(graph, info.element)
		for slot in pointee {
			prov_emit(graph, Prov_Event{kind = .Load, slot = slot, into = selected, path = graph.prov_slots[slot].path, span = span})
		}
		graph.has_content_load ||= len(pointee) > 0
		chain[info.element] = true
		out = prov_join(graph, out, prov_mutable_reach(graph, pointee, info.element, span, chain))
		chain[info.element] = false
	}
	return out
}

// The stand-in for what the callback in `callback`, this body's parameter,
// leaves in its argument `argument`.
@(private)
prov_forwarded_root :: proc(graph: ^Flow_Graph, callback: Symbol_Id, argument: int, span: Span) -> Root_Id {
	sym := symbol_of(graph.k.c, callback)
	root := prov_new_root(graph, .Static, span, identifier_text(graph.k.c, sym.name))
	graph.roots[int(root)].forwarded = true
	graph.roots[int(root)].param_index = int(sym.index)
	graph.roots[int(root)].argument = argument
	return root
}

// Where a `stored` argument may land: an `inout` parameter or receiver, or a
// mutable carrier, each only when it can hold a borrow.
@(private = "file")
prov_writable_arguments :: proc(graph: ^Flow_Graph, v: ^Expr_Call, proc_type: Type_Id) -> []int {
	c := graph.k.c
	out := make([dynamic]int, 0, len(v.bound), graph.alloc)
	sym := symbol_of(c, v.resolution.chosen_overload)
	start := 0
	if sym != nil && sym.has_receiver {
		start = 1
		if len(v.bound) > 0 && v.bound[0] != nil {
			type := prov_type(graph, v.bound[0])
			if sym.receiver == .Inout && type_carries_borrow(c, type).any || prov_type_reaches_destination(c, type) {
				append(&out, 0)
			}
		}
	}
	info := underlying_info(c, proc_type)
	if info == nil {
		return out[:]
	}
	for index in start ..< min(len(v.bound), len(info.parameters)) {
		type := info.parameters[index]
		if prov_argument_is_inout(graph, v, index) && type_carries_borrow(c, type).any || prov_type_reaches_destination(c, type) {
			append(&out, index)
		}
	}
	return out[:]
}

// One argument receiving what another may leave in it, joined since the callee
// may leave it alone. An `inout` argument is the place; a `^mut`/`[]mut` one
// goes through its `carrier` loans.
@(private = "file")
prov_retain_into_argument :: proc(
	graph: ^Flow_Graph,
	v: ^Expr_Call,
	index: int,
	carrier: []int,
	sources: []int,
	retained := false,
	retained_mutable := false,
) {
	argument := v.bound[index]
	// A variadic pack is a slice over its operands, which no place names.
	packed := call_packs(v, index)
	if argument == nil && !packed {
		return
	}
	if packed || !prov_argument_is_place(graph, v, index) {
		prov_retain_through(graph, carrier, prov_parameter_type(graph, v, index), sources, v.span, retained, retained_mutable)
		return
	}
	// `inout p` with `p: ^mut T`: through `p` as well as into it.
	if prov_type_reaches_destination(graph.k.c, prov_type(graph, argument)) {
		prov_retain_through(graph, prov_carrier_slots(graph, argument), prov_type(graph, argument), sources, v.span, retained, retained_mutable)
	}
	root, path, ok := prov_place_of(graph, argument)
	if !ok {
		return
	}
	prov_retain_escape(graph, argument, sources, v.span)
	slots := prov_content_at(graph, root, path)
	if len(slots) == 0 {
		ident, is_ident := argument.(^Expr_Ident)
		if !is_ident {
			return
		}
		slot, is_carrier := prov_slot_for_symbol(graph, ident.symbol)
		if !is_carrier {
			return
		}
		slots = prov_one(graph, slot)
	}
	// What a call leaves of a `stored` argument is linked to where it may land
	// from what the call lent it from (`prov_link_retained`), since the
	// call itself still uses the carrier it lends the argument through.
	for slot in slots {
		prov_define_one_content(graph, slot, prov_join(graph, prov_one(graph, slot), sources), v.span, reborrows = !retained)
	}
	if retained {
		prov_link_retained_places(graph, sources, slots, retained_mutable, v.span)
	}
}

// What a call leaves of a `stored` argument in slots the walk can name, for the solve
// to link (`prov_link_retained`).
@(private = "file")
prov_link_retained_places :: proc(graph: ^Flow_Graph, sources, places: []int, mutable: bool, span: Span) {
	if len(places) == 0 {
		return
	}
	graph.has_linked_store = true
	prov_emit(graph, Prov_Event{kind = .Publish, span = span, sources = sources, store = Prov_Store_Retained{mutable = mutable, places = places}})
}

// Through an argument's carriers, of `type`, and what they reach in turn.
// design.md "Borrows crossing between tasks": what a callee writes back rather
// than retains lands in the storage the mutable carriers name, and below that
// only where another mutable carrier leads (`prov_mutable_reach`), so neither
// what `slot: ^int` points at in `publish(&mut slot)` nor a read-only field
// beside a mutable one is a destination.
@(private = "file")
prov_retain_through :: proc(graph: ^Flow_Graph, held: []int, type: Type_Id, sources: []int, span: Span, retained, retained_mutable: bool) {
	carriers := retained ? prov_with_content(graph, held, span) : prov_mutable_reach(graph, held, type, span)
	if len(carriers) == 0 {
		return
	}
	prov_emit(graph, Prov_Event{kind = .Retain, span = span, sources = sources, root = NO_ROOT, into = carriers})
	lands: Prov_Store_Target
	if retained {
		lands = Prov_Store_Retained{mutable = retained_mutable}
		graph.has_linked_store = true
	}
	through_element := false
	for slot in carriers {
		through_element ||= retained && prov_may_point_at_element(graph, prov_one(graph, slot))
	}
	prov_emit(graph, Prov_Event{kind = .Publish, span = span, sources = sources, into = carriers, store = lands, through_element = through_element})
}

// design.md "Retaining a borrow", "Weakening and reborrows": each carrier among
// the store's `sources` is linked as a reborrow to the slots a destination may
// stand for. A parameter's own binding is no destination: no call can write it.
// The carrier a call lends its argument through (`prov_lend_carrier`) is used by
// the call itself, after what it leaves is published, so what it was lent from
// is linked instead.
@(private)
prov_link_retained :: proc(graph: ^Flow_Graph, event: Prov_Event, retained: Prov_Store_Retained, landed: []int) {
	c := graph.k.c
	linked := make(map[int]struct{}, graph.alloc)
	pending := make([dynamic]int, 0, len(event.sources), graph.alloc)
	append(&pending, ..event.sources)
	for len(pending) > 0 {
		source := pop(&pending)
		if source in linked {
			continue
		}
		linked[source] = {}
		entry := graph.prov_slots[source]
		if entry.borrow != nil {
			continue
		}
		if entry.kind == .Temporary && !entry.loaded {
			deriving := prov_reborrows_deriving(graph, source)
			for reborrow in prov_next_reborrow(graph, &deriving) {
				append(&pending, reborrow.source)
			}
			continue
		}
		mutable_caller := entry.kind == .Caller && entry.content_type != INVALID_TYPE && carrier_is_mutable(c, entry.content_type)
		mutable_source := prov_slot_is_mutable_carrier(graph, source) || prov_slot_is_loaded_mutable(graph, source) || mutable_caller
		// As for a copy (`prov_reborrow`), a named read-only reborrow, or a
		// read-only carrier loaded out through a pointer, is not itself
		// suspended by what the call leaves of it: that only extends it.
		passes_on := !mutable_source && (prov_slot_is_stored(entry) || prov_slot_is_loaded_read_only(graph, source))
		settles_later := !mutable_source && !prov_slot_is_reborrow(graph, source)
		link := proc(graph: ^Flow_Graph, source, into: int, mutable, passes_on, pending: bool, span: Span) {
			c := graph.k.c
			if into == source {
				return
			}
			candidate := graph.prov_slots[into]
			type := candidate.content_type
			if candidate.symbol != INVALID_SYMBOL {
				sym := symbol_of(c, candidate.symbol)
				if sym == nil || sym.kind == .Parameter && sym.immutable {
					return
				}
				if type == INVALID_TYPE && len(candidate.path) == 0 {
					type = sym.type
				}
				if !type_is_carrier(c, type) || type_is_region_provider(c, type) {
					return
				}
			} else if candidate.kind == .Temporary || type != INVALID_TYPE && type_is_region_provider(c, type) {
				return
			}
			held := type == INVALID_TYPE ? candidate.caller_mutable : carrier_is_mutable(c, type)
			prov_add_reborrow(graph, Prov_Reborrow {
				source = source, derived = into, span = span, mutable = mutable && held, passes_on = passes_on, pending = pending,
			})
		}
		for into in landed {
			link(graph, source, into, retained.mutable, passes_on, settles_later, event.span)
		}
		for into in retained.places {
			link(graph, source, into, retained.mutable, passes_on, settles_later, event.span)
		}
	}
}

// A `stored` argument that is also a destination may be left borrowing its own
// storage, as `h.view = h.items[:]` leaves it. Each content slot of the place
// gets a new borrow of it, weakened to that slot's capability; the argument's
// own loan keeps its. Any other carrier publishes its loans as they are.
@(private = "file")
prov_retain_into_self :: proc(graph: ^Flow_Graph, v: ^Expr_Call, index: int, carrier: []int, mutable: bool) {
	place := v.bound[index]
	if !prov_argument_is_place(graph, v, index) {
		unary, is_unary := place.(^Expr_Unary)
		if !is_unary || unary.op != .Amp {
			prov_retain_into_argument(graph, v, index, carrier, carrier, retained = true, retained_mutable = mutable)
			return
		}
		place = unary.operand
	}
	root, path, ok := prov_place_of(graph, place)
	if !ok {
		return
	}
	// design.md "Escape levels": the callee may store any of the argument's
	// content into any compatible part of it, so each part keeps its own
	// sources, gains every other part's, and borrows the argument's own root.
	slots := prov_content_at(graph, root, path)
	for slot in slots {
		own := prov_borrow(graph, root, path, true, v.span, "borrow")
		kept := prov_join(graph, prov_one(graph, slot), carrier)
		prov_define_one_content(graph, slot, prov_join(graph, kept, own), v.span)
	}
	prov_link_retained_places(graph, carrier, slots, mutable, v.span)
}

// Whether this argument names the destination itself rather than pointing at it.
@(private)
prov_argument_is_place :: proc(graph: ^Flow_Graph, v: ^Expr_Call, index: int) -> bool {
	input := prov_input_call(graph, v)
	return index < len(input.arguments) && input.arguments[index].place
}

@(private = "file")
prov_parameter_label :: proc(graph: ^Flow_Graph, v: ^Expr_Call, index: int) -> string {
	if sym := symbol_of(graph.k.c, v.resolution.chosen_overload); sym != nil && index < len(sym.param_symbols) {
		if bound := symbol_of(graph.k.c, sym.param_symbols[index]); bound != nil {
			return fmt.aprintf(
				"`%s`, which `%s` may keep",
				identifier_text(graph.k.c, bound.name),
				identifier_text(graph.k.c, sym.name),
				allocator = graph.alloc,
			)
		}
	}
	return "a parameter this call may keep"
}

// The content path a removal reads; a map removal reads only the value.
@(private)
prov_element_path :: proc(
	graph: ^Flow_Graph,
	v: ^Expr_Call,
	path: []Proj_Step,
	op: Container_Op,
) -> []Proj_Step {
	if op != .Map_Remove {
		return prov_extend(graph, path, proj_wild())
	}
	entry := prov_extend(graph, path, prov_map_call_step(graph, v))
	return prov_extend(graph, entry, proj_field(PROJ_MAP_VALUE))
}

// The entry step for a map operation that takes its key as an argument.
@(private)
prov_map_call_step :: proc(graph: ^Flow_Graph, v: ^Expr_Call) -> Proj_Step {
	if len(v.bound) < 2 || v.bound[0] == nil {
		return proj_wild()
	}
	return prov_map_entry_step(graph, prov_type(graph, v.bound[0]), v.bound[1])
}

// design.md "Allocator regions and region provenance": a call leaves in each
// argument it may write the owners its body leaves there, with the regions of
// the arguments they came from. With no body to summarize, every allocator or
// moved-owner argument may land in every such argument.
@(private)
prov_call_written_regions :: proc(graph: ^Flow_Graph, id: Value_Id) {
	form := prov_value(graph, id).form.(Prov_Form_Call)
	v, bound := form.call, prov_bound_values(form)
	prov_effect_scope(graph, prov_effect_active(graph) && prov_input_call(graph, v).writes_facts, Prov_Effect_Call{id, .Write})
	c := graph.k.c
	proc_type := call_proc_type(c, v)
	info := underlying_info(c, proc_type)
	if info == nil {
		return
	}
	callee := call_contract_declaration(c, v)
	direct := prov_has_direct_body(c, callee)
	prov_note_summary_dependency(graph, callee)
	written, found := written_region_summary(c, callee)
	if !found && direct {
		return // no parameter it writes can hold an owner
	}
	// What backs an owner left there, as opposed to an allocator handle.
	owners, _ := written_region_summary(c, callee, owners = true)
	everything := Region_Set{}
	if !found {
		for argument, index in bound {
			if argument == 0 || index >= len(info.parameters) {
				continue
			}
			moved := param_mode_at(info, index) == .Move
			if moved || type_is_allocator(c, info.parameters[index]) {
				region_merge(&everything, prov_region_of(graph, argument))
			}
		}
	}
	// Where the summary keeps paths, what it leaves lands at them, so a field
	// the callee never wrote keeps its own regions.
	rows, has_rows := written_content_summary(c, callee)
	for destination, index in bound {
		packed := call_packs(v, index)
		if (destination == 0 && !packed) || index >= len(info.parameters) {
			continue
		}
		region, owned := everything, everything
		contents: []Prov_Region_Content
		if found {
			if index >= len(written) {
				continue
			}
			region = prov_substitute_region(graph, form, written[index])
			owned = Region_Set{}
			if index < len(owners) {
				owned = prov_substitute_region(graph, form, owners[index])
			}
			if has_rows && !packed && index < len(rows) {
				contents = make([]Prov_Region_Content, len(rows[index]), graph.alloc)
				for entry, position in rows[index] {
					contents[position] = entry
					contents[position].region = prov_substitute_region(graph, form, entry.region)
				}
			}
		} else if packed || !prov_argument_is_place(graph, v, index) {
			type := info.parameters[index]
			if !carrier_is_mutable(c, type) && !prov_type_reaches_mutable(c, type) {
				continue
			}
		}
		if packed {
			for element in form.pack { prov_leave_region(graph, element, region, owned) }
		} else if prov_argument_is_place(graph, v, index) {
			prov_leave_in_place(graph, destination, region, owned, contents)
		} else if prov_parameter_is_record_by_value(c, param_mode_at(info, index), info.parameters[index]) {
			prov_store_region_through(graph, destination, region, owned, CALL_LEFT_OWNER, contents = contents, by_carrier = contents != nil)
		} else {
			prov_leave_region(graph, destination, region, owned, contents)
		}
	}
}

// The caller's half: a moved owner the call may keep takes its region into each
// argument it may be written to, or into static storage.
@(private)
prov_call_moved_owner :: proc(graph: ^Flow_Graph, v: ^Expr_Call, index: int, level: Escape_Level) {
	value := v.bound[index]
	info := underlying_info(graph.k.c, call_proc_type(graph.k.c, v))
	if value == nil || info == nil {
		return
	}
	if level == .Static {
		prov_event(graph, Prov_Event_Static_Escape{prov_input_value(graph, value), expr_span(value), prov_owner_name(graph, value)})
	}
	for destination, target in v.bound {
		if target == index || destination == nil || target >= len(info.parameters) {
			continue
		}
		place := destination
		if !prov_argument_is_place(graph, v, target) {
			if !carrier_is_mutable(graph.k.c, info.parameters[target]) {
				continue
			}
			if unary, is_unary := destination.(^Expr_Unary); is_unary && unary.op == .Amp {
				place = unary.operand
			}
		}
		prov_store_region(graph, prov_input_value(graph, place), prov_input_value(graph, value))
	}
}

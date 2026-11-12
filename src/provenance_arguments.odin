// What each argument of a call lends it, and what a callee may use through it
// (design.md "Weakening and reborrows").
package lokec

// An `inout` receiver invalidates borrows of it (design.md "Receiver forms"), and
// its held borrows stay live through the call, as `iterator.next()` reads its slice.
// It does so when the call starts: until then the receiver is reserved (design.md
// "Weakening and reborrows"), held as a `self: ^` receiver holds its place.
@(private = "file")
prov_inout_receiver :: proc(
	graph: ^Flow_Graph, v: ^Expr_Call, index: int, input: Prov_Call_Input, borrowed: ^[]int, reserved: ^[dynamic]Prov_Reserved,
) -> (actual: []int) {
	c := graph.k.c
	argument := v.bound[index]
	borrowed^ = prov_join(graph, borrowed^, prov_carrier_slots(graph, argument))
	root, path, named := prov_place_of(graph, argument)
	carriers: []int
	below: []Proj_Step
	through, reserving := false, false
	hold: []int
	watched: []Prov_Reserved_Place
	mark: Prov_Reserve_Mark
	switch {
	case named:
		prov_walk_subscripts(graph, argument)
		hold = prov_reserve_place(graph, root, path, .Invalidate, v.span, "modified", expr_span(argument), "borrow")
		mark, reserving = prov_begin_reserve(graph), true
		prov_access(graph, root, path, .Invalidate, v.span, "modified")
	case prov_place_reservable(graph, argument):
		// The receiver's value is read, as `prov_invalidate` walks it, which uses
		// the carriers it holds: only read while it is reserved.
		type := prov_type(graph, argument)
		held, at, _ := prov_read_through_carrier(graph, argument, reads_only = true)
		prov_load_content(graph, held, at, type, expr_span(argument), reads_only = true, place = argument)
		hold = prov_place_loan(graph, held, at, false, "borrow", argument, borrows = true, reserved = true)
		watched = prov_reserved_carriers(graph, argument)
		mark, reserving = prov_begin_reserve(graph), true
		prov_reread_through(graph, argument)
		carriers, below, through = prov_read_through_carrier(graph, argument, store = true, again = true)
		prov_write_through(graph, carriers, below, v.span, "write", argument)
	case:
		carriers, below, through = prov_invalidate(graph, argument, v.span, "modified")
	}
	// What stays live through the call, which joins `borrowed` when the loan starts.
	lent: []int
	// design.md "Borrowing iteration": a result derived from a view the
	// receiver holds names that view's source, not the receiver, so
	// advancing the receiver cannot invalidate an element already handed
	// back. The summary tells the two apart, or the callee's contract.
	lends := prov_result_reads_through_receiver(c, v, prov_type(graph, v), index) ||
	         prov_receiver_contract(c, symbol_of(c, v.resolution.chosen_overload)) == .Lends_Held
	removes := .Removes_Element in CONTAINER_OP_EFFECTS[input.container]
	switch {
	case lends:
		actual = prov_carrier_slots(graph, argument)
	case named && removes:
		// A removal returns what the element held, not a container borrow, and
		// leaves the container nothing of it (`Prov_Reborrow.moved`).
		element := underlying_info(c, prov_type(graph, argument)).element
		taken := len(graph.reborrows)
		actual = prov_read_content(graph, root, prov_element_path(graph, v, path, input.container), element, v.span)
		for &reborrow in graph.reborrows[taken:] {
			reborrow.moved = true
		}
		lent = actual
	case named:
		actual = prov_join(graph, prov_carrier_slots(graph, argument),
			prov_borrow(graph, root, path, true, expr_span(argument), "borrow"))
		lent = actual
	case through && removes:
		// The same as above, read through what it is behind.
		element := underlying_info(c, prov_type(graph, argument)).element
		actual = prov_load_content(graph, carriers, prov_element_path(graph, v, below, input.container), element, v.span)
		for slot in actual {
			graph.prov_slots[slot].moved_out = true
		}
		lent = actual
	case through:
		// design.md "Weakening and reborrows": a receiver behind a carrier is
		// borrowed as `&mut p^` is, for that place only.
		actual = prov_place_loan(graph, carriers, below, true, "borrow", argument, borrows = true)
		lent = actual
	}
	if reserving {
		prov_end_reserve(graph, reserved, mark, index, hold, actual, lent, watched)
		return nil
	}
	borrowed^ = prov_join(graph, borrowed^, lent)
	return actual
}

// design.md "Receiver forms": a read-only borrow of the caller's value, plus
// whatever borrows the receiver itself carries.
@(private = "file")
prov_borrowed_argument :: proc(graph: ^Flow_Graph, v: ^Expr_Call, index: int, input: Prov_Call_Input, borrowed: ^[]int) -> []int {
	c := graph.k.c
	argument := v.bound[index]
	is_receiver := index == 0 && input.has_receiver
	held := walk_flow_expr(graph, argument)
	loan: []int
	// Walking the argument above already read the place.
	if root, path, ok := prov_place_of(graph, argument); ok && !expression_converts_storage(argument) {
		loan = prov_borrow(graph, root, path, false, expr_span(argument), "borrow")
	} else if carriers, _, through := prov_read_through_carrier(graph, argument, reads_only = true); through {
		// `Type.method(&value)`, or a place behind a pointer. The borrow is
		// read-only, so a mutable carrier is reborrowed read-only for the
		// call, as one passed to a read-only parameter is, which another
		// read-only reborrow of it allows (design.md "Weakening and
		// reborrows").
		loan = prov_reborrow_traversal(graph, carriers, expr_span(argument), false)
	} else if index == 0 && prov_dispatches_on_view(c, v) {
		// design.md "Borrowed dynamic interface values": the slot is given the
		// viewed value, never the view itself, so a temporary view lends only
		// what it views, which walking it gave.
	} else {
		loan = prov_borrow(graph, prov_temp_root(graph, expr_span(argument)), nil, false, v.span, "borrow")
		// design.md "Spawn statements": a spawn's temporary belongs to the
		// task, so only a result borrowing it outlives the statement.
		if v == graph.spawning {
			graph.spawn_owned = prov_join(graph, graph.spawn_owned, loan)
		}
	}
	// A `value: T` callee shares the owner's allocations only for the call
	// (design.md "Parameter semantics and ABI lowering"): the argument stays
	// borrowed until it returns, but the result cannot derive from it.
	if !is_receiver && input.arguments[index].mode == .Value {
		borrowed^ = prov_join(graph, borrowed^, loan)
		return held
	}
	if is_receiver && type_underlying(c, prov_type(graph, argument)) == type_underlying(c, input.arguments[index].type) {
		graph.receiver_content[v] = held
	}
	return prov_join(graph, held, loan)
}

// One argument of `v`, in slot `index`: what it lends to the call. Loans that
// must stay live through the call are added to `borrowed`. A mutable loan the
// argument takes is added to `reserved` instead, and what the argument lends is
// then known where the call starts (`prov_start_reserved`).
@(private)
prov_call_argument :: proc(
	graph: ^Flow_Graph, v: ^Expr_Call, index: int, input: Prov_Call_Input, borrowed: ^[]int, reserved: ^[dynamic]Prov_Reserved,
) -> (actual: []int) {
	c := graph.k.c
	argument := v.bound[index]
	is_receiver := index == 0 && input.has_receiver
	param_type := input.arguments[index].type
	switch prov_argument_kind(graph, v, index, input) {
	case .Absent:
		return actual
	case .Pack:
		// design.md "Variadic parameters": the pack slot holds no written
		// expression unless a sole spread is forwarded.
		// Each operand lends as one argument of its type would: an element as the
		// pack's element, a spread as the slice it views. A mutable carrier passed
		// by name is reborrowed, so `fill(out, out)` uses `out` while it is lent.
		// A spread at the pack's type is copied in, so what a callee may keep of it
		// lies a load further down than of an element (`prov_argument_kept`).
		element := slice_element(c, param_type)
		operands: Prov_Pack_Operands
		cursor: Call_Pack_Cursor
		for operand, is_spread in call_pack_next(v, &cursor) {
			type := is_spread ? prov_pack_spread_type(c, prov_type(graph, operand), param_type) : element
			lent: []int
			if hold, watched, reserves := prov_reserve_argument(graph, operand, type, false); reserves {
				// The pack's actual names what the operand lends, which is defined
				// where the call starts.
				mark := prov_begin_reserve(graph)
				held := borrowed^
				lent = prov_lend_argument(graph, prov_take_reserved_argument(graph, operand), type, &held, expr_span(operand))
				prov_end_reserve(graph, reserved, mark, -1, hold, nil, lent, watched)
			} else {
				lent = prov_lend_argument(graph, walk_flow_expr(graph, operand), type, borrowed, expr_span(operand))
			}
			actual = prov_join(graph, actual, lent)
			if type == param_type {
				operands.spreads = prov_join(graph, operands.spreads, lent)
			} else {
				operands.elements = prov_join(graph, operands.elements, lent)
			}
		}
		if len(operands.spreads) > 0 {
			graph.pack_operands[v] = operands
		}
		return actual
	case .Moved_Receiver:
		actual = prov_consume(graph, argument, expr_span(argument), "moved")
		borrowed^ = prov_join(graph, borrowed^, actual)
		return actual
	case .Inout_Result:
		// design.md "`inout` results": an `inout` call result passed on `inout`
		// is the place its own `inout` arguments borrow.
		actual, _ = prov_inout_result_place(graph, argument)
		borrowed^ = prov_join(graph, borrowed^, actual)
		return actual
	case .Inout_Receiver:
		return prov_inout_receiver(graph, v, index, input, borrowed, reserved)
	case .View_Receiver:
		// design.md "Iteration adapters": a map view read-borrows the map, and
		// also carries what the stored elements borrow.
		held := walk_flow_expr(graph, argument)
		if root, path, ok := prov_place_of(graph, argument); ok {
			prov_access(graph, root, path, .Read, expr_span(argument))
			held = prov_join(
				graph, held, prov_borrow(graph, root, path, false, expr_span(argument), "view"),
			)
		} else if prov_expr_is_temporary(argument) {
			held = prov_join(
				graph, held,
				prov_borrow(graph, prov_temp_root(graph, expr_span(argument)), nil, false, v.span, "view"),
			)
		}
		actual = held
		borrowed^ = prov_join(graph, borrowed^, held)
		return actual
	case .Inout_Place:
		// design.md "Weakening and reborrows": reserved until the call starts.
		root, path, _ := prov_place_of(graph, argument)
		span := expr_span(argument)
		prov_walk_subscripts(graph, argument)
		hold := prov_reserve_place(graph, root, path, .Write, span, "", span, "borrow")
		mark := prov_begin_reserve(graph)
		prov_access(graph, root, path, .Write, span)
		actual = prov_join(graph, prov_carrier_slots(graph, argument), prov_borrow(graph, root, path, true, span, "borrow"))
		prov_end_reserve(graph, reserved, mark, index, hold, actual, actual)
		return nil
	case .Inout_Through:
		// design.md "Weakening and reborrows": `inout p^` lends what `p` names,
		// as `&mut p^` would, so `p` is suspended for the call, and only read
		// while the loan is reserved.
		span := expr_span(argument)
		if !prov_place_reservable(graph, argument) {
			carriers, below, _ := prov_read_through_carrier(graph, argument)
			prov_write_through(graph, carriers, below, span, "mutable argument", argument)
			actual = prov_lend_carrier(graph, carriers, borrowed^, span)
			borrowed^ = prov_join(graph, borrowed^, actual)
			return actual
		}
		held, _, _ := prov_read_through_carrier(graph, argument, reads_only = true)
		hold := prov_reserve_carriers(graph, held, span)
		mark := prov_begin_reserve(graph)
		carriers, below, _ := prov_read_through_carrier(graph, argument, again = true)
		prov_write_through(graph, carriers, below, span, "mutable argument", argument)
		actual = prov_lend_carrier(graph, carriers, borrowed^, span)
		prov_end_reserve(graph, reserved, mark, index, hold, actual, actual, prov_reserved_carriers(graph, argument))
		return nil
	case .Lookup_Receiver:
		// `lookup_value` copies the payload, carrying its stored dependencies.
		result_type := prov_type(graph, v)
		entry_step := prov_map_call_step(graph, v)
		if root, path, ok := prov_place_of(graph, argument); ok {
			prov_walk_subscripts(graph, argument)
			prov_access(graph, root, path, .Read, expr_span(argument))
			entry := prov_extend(graph, path, entry_step)
			value := prov_extend(graph, entry, proj_field(PROJ_MAP_VALUE))
			actual = prov_read_content(graph, root, value, result_type, v.span)
		} else {
			receiver := walk_flow_expr(graph, argument)
			entry := prov_extend(graph, nil, entry_step)
			value := prov_extend(graph, entry, proj_field(PROJ_MAP_VALUE))
			actual = prov_project_content(
				graph, receiver, prov_type(graph, argument), value, result_type, v.span,
			)
		}
	case .Only_Read_Slice:
		ident, _ := prov_plain_slice_local(graph, argument)
		prov_read_ident(graph, ident, reads_only = true)
		return actual
	case .Measured_Receiver:
		// A carrier holds its length, so that is a read of the carrier. An owner's is
		// beside what it holds, which it reads nothing of. It is still a call, so what
		// the receiver holds must last for it.
		kept: []int
		if type_is_carrier(c, prov_type(graph, argument)) {
			kept = prov_read_carrier(graph, argument, true)
		} else if root, path, named := prov_place_of(graph, argument); named {
			// What a container stores is the content of a loan of it.
			prov_walk_subscripts(graph, argument)
			prov_access(graph, root, path, .Read, expr_span(argument), reads_only = true)
			prov_emit(graph, Prov_Event{kind = .Live, sources = prov_borrow(graph, root, path, false, expr_span(argument), "borrow"), span = expr_span(argument), hands_on = true})
			return actual
		} else if carriers, below, through := prov_read_through_carrier(graph, argument, reads_only = true); through {
			prov_read_through(graph, carriers, below, expr_span(argument), argument)
			kept = carriers
		}
		prov_emit(graph, Prov_Event{kind = .Live, keeps_live = kept, span = expr_span(argument)})
		return actual
	case .Copied_Receiver:
		actual = walk_flow_expr(graph, argument)
		borrowed^ = prov_join(graph, borrowed^, actual)
		return actual
	case .Borrowed:
		actual = prov_borrowed_argument(graph, v, index, input, borrowed)
	case .Read_Only:
		// Weakened to a read-only parameter, the carrier is only read, all of
		// what it points to, while what is stored there keeps its capability.
		actual = prov_read_carrier(graph, argument, true)
		if prov_call_may_use_reach(graph, v) {
			if reached := prov_use_reached(graph, actual, param_type, expr_span(argument)); reached >= 0 {
				prov_write_through(graph, prov_one(graph, reached), nil, expr_span(argument), "mutable argument")
			}
		}
		prov_read_through(graph, actual, nil, expr_span(argument))
	case .Value:
		if hold, watched, reserves := prov_reserve_argument(graph, argument, param_type, is_receiver); reserves {
			mark := prov_begin_reserve(graph)
			actual = prov_take_reserved_argument(graph, argument)
			prov_use_mutable_argument(graph, actual, param_type, expr_span(argument))
			prov_use_reached_in_record(graph, v, index, argument, actual, param_type)
			held := borrowed^
			actual = prov_lend_argument(graph, actual, param_type, &held, expr_span(argument))
			prov_end_reserve(graph, reserved, mark, index, hold, actual, actual, watched)
			return nil
		}
		actual = walk_flow_expr(graph, argument)
		reached := -1
		if !is_receiver {
			reached = prov_use_reached(graph, actual, param_type, expr_span(argument))
		}
		// A callee given a mutable carrier may write what it names, below where
		// the argument points, as `[count]` for `&mut h^.count` or a record
		// holding it, and through what that holds; a read-only one reads it.
		if type_carries_borrow(c, param_type).mutable {
			prov_write_through(graph, actual, nil, expr_span(argument), "mutable argument")
			if reached >= 0 {
				prov_write_through(graph, prov_one(graph, reached), nil, expr_span(argument), "mutable argument")
			}
		} else if type_is_carrier(c, param_type) {
			prov_read_through(graph, actual, nil, expr_span(argument))
		}
	}
	prov_use_reached_in_record(graph, v, index, argument, actual, param_type)
	return prov_lend_argument(graph, actual, param_type, borrowed, expr_span(argument), is_receiver)
}

// What `actual`, passed as a parameter of `type`, lends the call, which joins
// `borrowed`. A mutable carrier passed on as one is reborrowed until the call and
// what it returns are done with it, so no other argument may use it meanwhile. A
// record holding one is lent as its carriers are (design.md "Values that contain
// borrows"). A receiver is the place the call borrows instead.
@(private = "file")
prov_lend_argument :: proc(graph: ^Flow_Graph, actual: []int, type: Type_Id, borrowed: ^[]int, span: Span, is_receiver := false) -> (lent: []int) {
	c := graph.k.c
	prov_reborrow(graph, actual, type)
	lent = actual
	if type_carries_borrow(c, type).mutable && !is_receiver {
		lent = prov_lend_carrier(graph, actual, borrowed^, span)
	} else if type_is_carrier(c, type) && !is_receiver {
		// design.md "Weakening and reborrows": an existing mutable carrier
		// weakened to a read-only parameter is reborrowed for the call, which
		// suspends it while later arguments are evaluated.
		lent = prov_reborrow_traversal(graph, actual, span, false)
	}
	borrowed^ = prov_join(graph, borrowed^, lent)
	return lent
}

// A callee given a mutable carrier may write what it names and what that holds
// (`prov_call_argument`).
@(private = "file")
prov_use_mutable_argument :: proc(graph: ^Flow_Graph, actual: []int, parameter: Type_Id, span: Span) {
	reached := prov_use_reached(graph, actual, parameter, span)
	prov_write_through(graph, actual, nil, span, "mutable argument")
	if reached >= 0 {
		prov_write_through(graph, prov_one(graph, reached), nil, span, "mutable argument")
	}
}

// design.md "Weakening and reborrows": what `carriers` hold while the loan of them
// is reserved: each named mutable one is reborrowed read-only, so it is not
// written through, nor reborrowed mutably, until the call starts.
@(private = "file")
prov_reserve_carriers :: proc(graph: ^Flow_Graph, carriers: []int, span: Span) -> []int {
	made := len(graph.reborrows)
	hold := prov_reborrow_traversal(graph, carriers, span, false)
	for &reborrow in graph.reborrows[made:] {
		reborrow.reserved = true
	}
	return hold
}

// How an argument takes a mutable loan its call reserves (`prov_reserve_argument`).
Prov_Reserved_Form :: enum u8 {
	None,
	// `&mut place` as written, which borrows the place.
	Borrow,
	// A place holding mutable carriers, read where it is: a carrier, a record
	// holding some, or the carrier a reslice `&mut xs[lo:hi]` is of.
	Carrier,
}

// The form of `argument`, given to a parameter of `parameter`, with the place a
// `Carrier` is read from and the reslice giving its bounds, if it is one.
@(private = "file")
prov_reserved_form :: proc(
	graph: ^Flow_Graph, argument: Expr, parameter: Type_Id,
) -> (form: Prov_Reserved_Form, place: Expr, bounds: ^Expr_Slice) {
	c := graph.k.c
	clean :: proc(graph: ^Flow_Graph, e: Expr) -> bool {
		base := expr_base(e)
		if base == nil || base.extended {
			return false
		}
		repr := prov_repr(graph, e)
		return repr.erased_from == INVALID_TYPE && repr.view_from == INVALID_TYPE
	}
	if !type_carries_borrow(c, parameter).mutable || type_is_region_provider(c, parameter) || !clean(graph, argument) {
		return
	}
	place = argument
	if prov_borrows_place(argument) {
		if borrowed, _, _, _ := prov_borrowed_place(graph, argument); borrowed != nil {
			return .Borrow, nil, nil
		}
		// A reslice of a carrier borrows nothing new: it lends the carrier.
		is_slice: bool
		if bounds, is_slice = argument.(^Expr_Slice); !is_slice || !clean(graph, bounds.operand) {
			return .None, nil, nil
		}
		place = bounds.operand
	}
	type := prov_type(graph, place)
	if !type_carries_borrow(c, type).mutable || type_is_region_provider(c, type) || !prov_reads_as_place(graph, place) ||
	   prov_place_indexes_map(graph, place) {
		return .None, nil, nil
	}
	if _, _, named := prov_place_of(graph, place); !named {
		if _, is_ident := place.(^Expr_Ident); !is_ident && !prov_place_reservable(graph, place) {
			return .None, nil, nil
		}
	}
	return .Carrier, place, bounds
}

// Whether `place` goes through a map's element, which reading clones out
// (`prov_read_index`), so it is no place to read a second time.
@(private = "file")
prov_place_indexes_map :: proc(graph: ^Flow_Graph, place: Expr) -> bool {
	#partial switch v in place {
	case ^Expr_Selector:
		return prov_place_indexes_map(graph, v.operand)
	case ^Expr_Postfix:
		return prov_place_indexes_map(graph, v.operand)
	case ^Expr_Index:
		return underlying_kind(graph.k.c, prov_type(graph, v.operand)) == .Map || prov_place_indexes_map(graph, v.operand)
	}
	return false
}

// design.md "Weakening and reborrows": whether `argument`, given to a parameter
// that takes a mutable carrier, takes a loan the call reserves: `&mut place`
// written as the argument, or mutable carriers read from a place. If so it is
// evaluated here, read-only, and `hold` is what it holds until the call starts;
// `watched` are the places holding the carriers it was reached through
// (`Prov_Reserved.watched`). A carrier the argument computes, as a call's result,
// is in use from where it is made.
@(private = "file")
prov_reserve_argument :: proc(
	graph: ^Flow_Graph, argument: Expr, parameter: Type_Id, is_receiver: bool,
) -> (hold: []int, watched: []Prov_Reserved_Place, reserves: bool) {
	if is_receiver {
		return
	}
	form, place, bounds := prov_reserved_form(graph, argument, parameter)
	switch form {
	case .None:
		return
	case .Borrow:
		return prov_reserve_borrow(graph, argument)
	case .Carrier:
	}
	span := expr_span(argument)
	if root, path, named := prov_place_of(graph, place); named {
		watched = make([]Prov_Reserved_Place, 1, graph.alloc)
		watched[0] = Prov_Reserved_Place{root, path}
	} else {
		watched = prov_reserved_carriers(graph, place)
	}
	held := prov_read_carrier(graph, place, true)
	if bounds != nil {
		prov_walk_slice_bounds(graph, bounds)
	}
	prov_reserve_through(graph, held, nil, span, "mutable argument")
	return prov_reserve_carriers(graph, held, span), watched, true
}

// The mutable loan of an argument `prov_reserve_argument` reserved, taken where
// the call starts without evaluating the argument again: what walking it would
// read.
@(private = "file")
prov_take_reserved_argument :: proc(graph: ^Flow_Graph, argument: Expr) -> (carried: []int) {
	if prov_borrows_place(argument) {
		if borrowed, _, _, _ := prov_borrowed_place(graph, argument); borrowed != nil {
			return prov_take_reserved_borrow(graph, argument)
		}
	}
	place := argument
	if slice, is_slice := argument.(^Expr_Slice); is_slice {
		place = slice.operand
	}
	if ident, is_ident := place.(^Expr_Ident); is_ident {
		carried = prov_read_ident(graph, ident)
	} else if _, _, named := prov_place_of(graph, place); named {
		carried = prov_reread_carrier(graph, place)
	} else {
		carried = prov_reread_through(graph, place)
	}
	// A copy that runs a hook hands it what the value holds (`walk_flow_expr`).
	if copied := expr_base(place).copied_as; copied != INVALID_TYPE {
		prov_copy_of_held_effects(graph, copied, carried, expr_base(place).span)
	}
	return carried
}

// design.md "Weakening and reborrows": a carrier handed to a call lets the
// callee use the carriers stored where it points, so passing `list` uses
// `list^.head`, which a mutable copy of it, as `node := list^.head`, suspends
// until its last use. A mutable carrier stored behind a read-only one keeps its capability
// (design.md "Values that contain borrows"), so a call given the read-only one may write
// through it too, and only a `copy` that runs nothing just reads them.
// The slot the load reads into, or -1 when there is none.
@(private = "file")
prov_use_reached :: proc(graph: ^Flow_Graph, slots: []int, parameter: Type_Id, span: Span, copy := false) -> int {
	c := graph.k.c
	info := underlying_info(c, parameter)
	if len(slots) == 0 || info == nil || !type_is_carrier(c, parameter) || type_is_region_provider(c, parameter) ||
	   !type_carries_borrow(c, info.element).mutable {
		return -1
	}
	graph.has_content_load = true
	slot := prov_temp_slot(graph)
	prov_emit(graph, Prov_Event {
		kind = .Load, slot = slot, into = slots, load = .Deep, span = span,
		reads_only = copy && !carrier_is_mutable(c, parameter),
	})
	return slot
}

// design.md "Weakening and reborrows": a record handed over by value lets the callee use
// what its carriers point to, as a carrier handed over itself does (`prov_use_reached`).
@(private = "file")
prov_use_reached_in_record :: proc(
	graph: ^Flow_Graph, v: ^Expr_Call, index: int, argument: Expr, actual: []int, parameter: Type_Id,
) {
	c := graph.k.c
	// A task holds what it is given until the join (`prov_spawn_reborrows`), which
	// reports a conflict with it once.
	if type_is_carrier(c, parameter) || !type_carries_borrow(c, parameter).any || !prov_call_may_use_reach(graph, v) ||
	   v == graph.spawning || prov_receiver_is_lent(graph, v, index) {
		return
	}
	span := expr_span(argument)
	// One load of them all, as what one holds is no conflict with using another.
	carriers := make([dynamic]int, 0, len(actual), graph.alloc)
	held := actual
	// Only a record named as a place hands over what that place holds: `p^.a` leaves
	// `p` and the rest of what it points to alone.
	if _, _, named := prov_place_of(graph, argument); named {
		held = prov_join(graph, held, prov_carrier_slots(graph, argument))
	}
	for slot in held {
		type := slot_carrier_type(graph, slot)
		info := underlying_info(c, type)
		if graph.prov_slots[slot].borrow != nil || !type_is_carrier(c, type) || info == nil ||
		   !type_carries_borrow(c, info.element).mutable {
			continue
		}
		append(&carriers, slot)
	}
	if len(carriers) > 0 {
		graph.has_content_load = true
		reached := prov_temp_slot(graph)
		prov_emit(graph, Prov_Event{kind = .Load, slot = reached, into = carriers[:], load = .Deep, span = span, repeats_inner = true})
		prov_write_through(graph, prov_one(graph, reached), nil, span, "mutable argument")
	}
}

// A receiver written `self: ^` is lent, not handed over.
@(private = "file")
prov_receiver_is_lent :: proc(graph: ^Flow_Graph, v: ^Expr_Call, index: int) -> bool {
	input := prov_input_call(graph, v)
	return index == 0 && input.has_receiver && input.receiver != .Value && input.receiver != .Move
}

// An operation of the compiler's own runs nothing that uses what its arguments reach,
// unless it compares elements with an operator a program wrote.
@(private = "file")
prov_call_may_use_reach :: proc(graph: ^Flow_Graph, v: ^Expr_Call) -> bool {
	if callee := symbol_of(graph.k.c, v.resolution.chosen_overload); callee != nil {
		#partial switch callee.synth {
		case .None, .Dyn_Forward, .Dyn_Proc_Adapter:
		case .Container_Op:
			return .Compares_Elements in CONTAINER_OP_EFFECTS[callee.container_op]
		case:
			return false
		}
	}
	return true
}

// design.md "Weakening and reborrows": a call uses every mutable carrier reachable
// through its arguments at once, so one of them and a live reborrow of it are never
// both left to it, however the arguments reach them (`Prov_Load_Kind.At_Once`).
@(private)
prov_use_reached_at_once :: proc(graph: ^Flow_Graph, v: ^Expr_Call, borrowed: []int) {
	c := graph.k.c
	if len(borrowed) == 0 || !prov_call_may_use_reach(graph, v) {
		return
	}
	reaches := false
	into := borrowed
	for argument, index in v.bound {
		parameter := prov_parameter_type(graph, v, index)
		info := underlying_info(c, parameter)
		held := parameter
		if info != nil && type_is_carrier(c, parameter) {
			held = info.element
		} else if argument != nil {
			// A record passed by value hands over the carriers its place holds.
			into = prov_join(graph, into, prov_carrier_slots(graph, argument))
		}
		reaches ||= type_carries_borrow(c, held).mutable
	}
	if !reaches {
		return
	}
	graph.has_content_load = true
	prov_emit(graph, Prov_Event{kind = .Load, slot = prov_temp_slot(graph), into = into, load = .At_Once, span = v.span, repeats_inner = true})
}

// design.md "Weakening and reborrows", "Switch ownership": copying carriers out of
// storage into `destination` uses all of what they point to (`prov_use_reached`),
// and a `mutable` copy may write it. Only carriers read out of storage are copied:
// a borrow taken here already accessed its place, as in `&mut other if flag else h`.
@(private)
prov_use_copied :: proc(graph: ^Flow_Graph, slots: []int, destination: Type_Id, span: Span, mutable: bool, into := -1) {
	copied := make([dynamic]int, 0, len(slots), graph.alloc)
	written := make([dynamic]int, 0, len(slots), graph.alloc)
	for slot in slots {
		entry := graph.prov_slots[slot]
		if slot == into || (!prov_slot_is_stored(entry) && !entry.loaded) {
			continue
		}
		append(&copied, slot)
		if prov_slot_is_mutable_carrier(graph, slot) || prov_slot_is_loaded_mutable(graph, slot) {
			append(&written, slot)
		}
	}
	reached := prov_use_reached(graph, copied[:], destination, span, copy = true)
	if mutable && len(written) > 0 {
		prov_write_through(graph, written[:], nil, span, "mutable copy")
		if reached >= 0 {
			prov_write_through(graph, prov_one(graph, reached), nil, span, "mutable copy")
		}
	} else if type_is_carrier(graph.k.c, destination) {
		prov_read_through(graph, copied[:], nil, span)
	}
}

// design.md "Global write effects": a temporary lent to a value parameter is
// dropped once the call is done with it, and its drop hooks write what they
// would anywhere. A container operation may keep its element, so it is left
// to the container's own effects.
@(private)
prov_argument_drop_effects :: proc(graph: ^Flow_Graph, v: ^Expr_Call) {
	c := graph.k.c
	if sym := symbol_of(c, v.resolution.chosen_overload); sym != nil && sym.synth == .Container_Op {
		return
	}
	info := underlying_info(c, call_proc_type(c, v))
	if info == nil {
		return
	}
	for argument, index in v.bound {
		if argument == nil || index >= len(info.param_modes) || info.param_modes[index] != .Value ||
		   expression_is_borrowed_place(argument) {
			continue
		}
		prov_drop_effects(graph, prov_type(graph, argument), expr_span(argument), region = prov_drop_region(graph, argument))
	}
}

// `into` now holds what `slot` does.
@(private)
prov_def_copy :: proc(graph: ^Flow_Graph, into, slot: int, span: Span) {
	prov_emit(graph, Prov_Event{kind = .Def, slot = into, loan = NO_LOAN, sources = prov_one(graph, slot), span = span})
}

// What `slots` hold now, in temporaries a later write cannot redefine.
@(private)
prov_snapshot :: proc(graph: ^Flow_Graph, slots: []int, span: Span) -> []int {
	out := make([]int, len(slots), graph.alloc)
	for slot, index in slots {
		out[index] = prov_temp_slot(graph)
		prov_def_copy(graph, out[index], slot, span)
	}
	return out
}

// standard-library.md "Splitting a mutable slice": the receiver is read before `mid` and
// lent after it, so `xs.split_at_mut(xs.len() / 2)` may still read `xs`. The
// value read is what is lent, so the halves stay tied to it even if `mid`
// reassigns `xs`; the reborrow suspends `xs` only while `xs` still views the
// same storage. A receiver read out of a place, as `halves.left` or `p^.rest`,
// is already a reborrow of the carrier stored there, which what is lent extends.
@(private)
prov_lend_split_receiver :: proc(graph: ^Flow_Graph, receiver, read: []int, span: Span) -> []int {
	out := prov_snapshot(graph, read, span)
	for slot, index in out {
		from := receiver[index]
		if prov_slot_is_mutable_carrier(graph, from) || prov_slot_is_loaded_mutable(graph, from) || prov_slot_is_reborrow(graph, from, mutable_only = true) {
			prov_add_reborrow(graph, Prov_Reborrow{source = receiver[index], derived = slot, span = span, mutable = true})
		}
	}
	return out
}

// design.md "Weakening and reborrows": a mutable carrier lent to a call is
// reborrowed for it. The arguments already evaluated are held through the call,
// so they are used again after the reborrow is taken, which catches one that
// reads through the same carrier.
@(private)
prov_lend_carrier :: proc(graph: ^Flow_Graph, carriers, held: []int, span: Span) -> []int {
	lent := prov_reborrow_traversal(graph, carriers, span, true)
	if len(held) > 0 {
		prov_emit(graph, Prov_Event{kind = .Live, sources = held, span = span})
	}
	return lent
}

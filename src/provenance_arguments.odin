// What each argument of a call lends it, and what a callee may use through it
// (design.md "Weakening and reborrows").
package lokec

// An `inout` receiver invalidates borrows of it (design.md "Receiver forms"), and
// its held borrows stay live through the call, as `iterator.next()` reads its slice.
@(private = "file")
prov_inout_receiver :: proc(graph: ^Flow_Graph, v: ^Expr_Call, index: int, input: Prov_Call_Input, borrowed: ^[]int) -> (actual: []int) {
	c := graph.k.c
	argument := v.bound[index]
	borrowed^ = prov_join(graph, borrowed^, prov_carrier_slots(graph, argument))
	carriers, below, through := prov_invalidate(graph, argument, v.span, "modified")
	// design.md "Borrowing iteration": a result derived from a view the
	// receiver holds names that view's source, not the receiver, so
	// advancing the receiver cannot invalidate an element already handed
	// back. The summary tells the two apart, or the callee's contract.
	lends := prov_result_reads_through_receiver(c, v, prov_type(graph, v), index) ||
	         prov_receiver_contract(c, symbol_of(c, v.resolution.chosen_overload)) == .Lends_Held
	if lends {
		return prov_carrier_slots(graph, argument)
	}
	removes := .Removes_Element in CONTAINER_OP_EFFECTS[input.container]
	if root, path, ok := prov_place_of(graph, argument); ok {
		if removes {
			// A removal returns what the element held, not a container borrow, and
			// leaves the container nothing of it (`Prov_Reborrow.moved`).
			element := underlying_info(c, prov_type(graph, argument)).element
			taken := len(graph.reborrows)
			actual = prov_read_content(graph, root, prov_element_path(graph, v, path, input.container), element, v.span)
			for &reborrow in graph.reborrows[taken:] {
				reborrow.moved = true
			}
		} else {
			actual = prov_join(graph, prov_carrier_slots(graph, argument),
				prov_borrow(graph, root, path, true, expr_span(argument), "borrow"))
		}
		borrowed^ = prov_join(graph, borrowed^, actual)
	} else if through {
		// design.md "Weakening and reborrows": a receiver behind a carrier is
		// borrowed as `&mut p^` is, for that place only.
		if removes {
			// The same as above, read through what it is behind.
			element := underlying_info(c, prov_type(graph, argument)).element
			actual = prov_load_content(graph, carriers, prov_element_path(graph, v, below, input.container), element, v.span)
			for slot in actual {
				graph.prov_slots[slot].moved_out = true
			}
		} else {
			actual = prov_place_loan(graph, carriers, below, true, "borrow", argument, borrows = true)
		}
		borrowed^ = prov_join(graph, borrowed^, actual)
	}
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
// must stay live through the call are added to `borrowed`.
@(private)
prov_call_argument :: proc(graph: ^Flow_Graph, v: ^Expr_Call, index: int, input: Prov_Call_Input, borrowed: ^[]int) -> (actual: []int) {
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
		element := slice_element(c, param_type)
		next_element, next_spread := 0, 0
		for is_spread in v.variadic_order {
			operand: Expr
			type := element
			if is_spread {
				operand, type = v.variadic_spreads[next_spread], param_type
				next_spread += 1
			} else {
				operand = v.variadic_elements[next_element]
				next_element += 1
			}
			lent := walk_flow_expr(graph, operand)
			prov_reborrow(graph, lent, type)
			if type_carries_borrow(c, type).mutable {
				lent = prov_lend_carrier(graph, lent, borrowed^, expr_span(operand))
			} else if type_is_carrier(c, type) {
				lent = prov_reborrow_traversal(graph, lent, expr_span(operand), false)
			}
			borrowed^ = prov_join(graph, borrowed^, lent)
			actual = prov_join(graph, actual, lent)
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
		return prov_inout_receiver(graph, v, index, input, borrowed)
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
		root, path, _ := prov_place_of(graph, argument)
		prov_walk_subscripts(graph, argument)
		prov_access(graph, root, path, .Write, expr_span(argument))
		actual = prov_join(graph, prov_carrier_slots(graph, argument),
			prov_borrow(graph, root, path, true, expr_span(argument), "borrow"))
		borrowed^ = prov_join(graph, borrowed^, actual)
		return actual
	case .Inout_Through:
		// design.md "Weakening and reborrows": `inout p^` lends what `p` names,
		// as `&mut p^` would, so `p` is suspended for the call.
		carriers, below, _ := prov_read_through_carrier(graph, argument)
		prov_write_through(graph, carriers, below, expr_span(argument), "mutable argument", argument)
		actual = prov_lend_carrier(graph, carriers, borrowed^, expr_span(argument))
		borrowed^ = prov_join(graph, borrowed^, actual)
		return actual
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
	prov_reborrow(graph, actual, param_type)
	// A mutable carrier passed on as one is reborrowed until the call and what
	// it returns are done with it, so no other argument may use it meanwhile.
	// A record holding one is lent as its carriers are (design.md "Values that
	// contain borrows").
	if type_carries_borrow(c, param_type).mutable && !is_receiver {
		actual = prov_lend_carrier(graph, actual, borrowed^, expr_span(argument))
	} else if type_is_carrier(c, param_type) && !is_receiver {
		// design.md "Weakening and reborrows": an existing mutable carrier
		// weakened to a read-only parameter is reborrowed for the call, which
		// suspends it while later arguments are evaluated.
		actual = prov_reborrow_traversal(graph, actual, expr_span(argument), false)
	}
	borrowed^ = prov_join(graph, borrowed^, actual)
	return actual
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
			return callee.container_op == .Sort || callee.container_op == .Reverse_Sort
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
// same storage.
@(private)
prov_lend_split_receiver :: proc(graph: ^Flow_Graph, receiver, read: []int, span: Span) -> []int {
	out := prov_snapshot(graph, read, span)
	for slot, index in out {
		if prov_slot_is_mutable_carrier(graph, receiver[index]) {
			append(&graph.reborrows, Prov_Reborrow{source = receiver[index], derived = slot, span = span, mutable = true})
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

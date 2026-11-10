// The calls with provenance rules of their own: shared constructors and the
// builtins (design.md "Built-in procedures").
package lokec

// What a handle or box to a `payload` holding `loans` holds: its paths, below the
// handle's one step and the `Result`'s if `fallible`, select from them.
@(private = "file")
prov_boxed_content :: proc(graph: ^Flow_Graph, v: ^Expr_Call, loans: []int, payload: Type_Id, fallible: bool) -> []int {
	depth := fallible ? 2 : 1
	content := prov_temp_content(graph, prov_type(graph, v))
	for slot in content {
		path := graph.prov_slots[slot].path
		suffix := path[min(depth, len(path)):]
		prov_define_one_content(graph, slot, prov_select_content(graph, loans, payload, suffix), v.span)
	}
	return content
}

// What storing `value` as `target` does to loans and regions alike.
@(private)
prov_store_value :: proc(graph: ^Flow_Graph, target, value: Expr, sources: []int, span: Span) {
	prov_store_region(graph, prov_input_value(graph, target), prov_input_value(graph, value))
	prov_store_loans(graph, target, sources, span)
}

// The value `place` holds, read out with what it borrows, leaving the place `verb`.
@(private = "file")
prov_read_out :: proc(graph: ^Flow_Graph, place: Expr, span: Span, verb: string) -> []int {
	type := prov_type(graph, place)
	out := prov_project_content(graph, walk_flow_expr(graph, place), type, nil, type, span)
	prov_invalidate(graph, place, span, verb)
	return out
}

// The calls with provenance rules of their own: a shared constructor and the
// builtins. `handled` is false for every other call.
@(private)
prov_builtin_call :: proc(graph: ^Flow_Graph, v: ^Expr_Call) -> (result: []int, handled: bool) {
	c := graph.k.c
	// design.md "Shared ownership": the payload's borrows land below the
	// handle's one step, as for a box; the library body hides them in a `rawptr`.
	if payload, fallible := shared_constructor_payload(c, v); payload != nil {
		loans := walk_flow_expr(graph, payload)
		prov_hold_owner(graph, payload)
		walk_flow_each(graph, v.bound[1:])
		return prov_boxed_content(graph, v, loans, prov_type(graph, payload), fallible), true
	}
	if sym := symbol_of(c, v.resolution.symbol); sym != nil && sym.kind == .Builtin {
		#partial switch sym.builtin {
		case .Assert, .Panic:
			// design.md "Built-in procedures": the report borrows what it prints
			// until it has printed the last argument, so a later argument cannot
			// change or destroy an earlier one.
			printed := min(sym.builtin == .Assert ? 2 : 1, len(v.bound))
			reports := v.bound[printed:]
			for argument in v.bound[:printed] {
				walk_flow_expr(graph, argument)
			}
			reported, reach: []int
			for argument in reports {
				held, holds := prov_printed_argument(graph, argument)
				reported = prov_join(graph, reported, held)
				reach = prov_join(graph, reach, holds)
				prov_hold_owner(graph, argument)
			}
			for argument in reports {
				prov_report_effects(graph, prov_type(graph, argument), expr_span(argument))
			}
			prov_read_printed_reach(graph, reach, v.span)
			if len(reported) > 0 {
				prov_emit(graph, Prov_Event{kind = .Live, sources = reported, span = v.span})
			}
			// What holds a value only for the report goes with the unwind.
			for argument in reports {
				prov_discarded_drop_effects(graph, argument)
			}
			return nil, true
		case .Box_New, .Try_Box:
			// design.md "Owned values": the payload's borrows land below the box's
			// one step, path by path, so a box keeps its fields apart as a record
			// does. The allocator is only read. A call that failed to check bound
			// nothing.
			if len(v.bound) == 0 {
				return nil, true
			}
			loans := walk_flow_expr(graph, v.bound[0])
			prov_hold_owner(graph, v.bound[0])
			if len(v.bound) > 1 {
				lent := prov_lend_copied_place(graph, v.bound[0])
				walk_flow_expr(graph, v.bound[1])
				if len(lent) > 0 {
					prov_emit(graph, Prov_Event{kind = .Live, sources = lent, span = v.span, hands_on = true})
				}
			}
			allocation := v.operation.(Call_Allocation)
			return prov_boxed_content(graph, v, loans, allocation.type, allocation.fallible), true
		case .Default_Allocator:
			return prov_synthetic_borrow(graph, v, .Static, TYPE_ALLOCATOR), true
		case .Unsafe_Free:
			// design.md "What is not checked": the operands are only read.
			walk_flow_each(graph, v.bound)
			return nil, true
		case .Free_All:
			if len(v.bound) >= 1 {
				allocator := prov_input_value(graph, v.bound[0])
				walk_flow_expr(graph, v.bound[0])
				prov_event(graph, Prov_Event_Allocator_Use{allocator, v.span, false})
				prov_reset(graph, allocator, v.span, true, v)
			}
			return nil, true
		case .Drop:
			if len(v.bound) == 1 {
				provider_drop_end(graph, v)
				prov_drop_effects(graph, prov_type(graph, v.bound[0]), v.span, region = prov_drop_region(graph, v.bound[0]))
				if ident, is_ident := v.bound[0].(^Expr_Ident); is_ident {
					prov_drop_use(graph, ident.symbol, v.span)
					prov_clear_content(graph, ident.symbol, v.span)
				}
				prov_invalidate(graph, v.bound[0], v.span, "dropped")
			}
			return nil, true
		case .Exchange:
			if len(v.bound) == 2 {
				provider_exchange_end(graph, v)
				// `old := x; x = value; return old`, for loans as for regions.
				old := prov_read_out(graph, v.bound[0], v.span, "exchanged")
				prov_store_value(graph, v.bound[0], v.bound[1], walk_flow_expr(graph, v.bound[1]), v.span)
				return old, true
			}
			return nil, true
		case .Atomic_Load, .Atomic_Store, .Atomic_Exchange, .Atomic_Compare_Exchange,
		     .Atomic_Add, .Atomic_Sub, .Atomic_And, .Atomic_Or, .Atomic_Xor, .Atomic_Fence:
			// An atomic returns the stored value, not a borrow of its address, or an
			// `Atomic(^T)` could never load.
			walk_flow_each(graph, v.bound)
			return nil, true
		case .Unsafe_Take:
			// design.md "The `unsafe` package": the value is read out, and keeps
			// what it borrows.
			if len(v.bound) == 1 {
				return prov_read_out(graph, v.bound[0], v.span, "taken"), true
			}
			return nil, true
		case .Unsafe_Write:
			// Stored the way an initialization takes it, loans and region alike.
			if len(v.bound) == 2 {
				prov_invalidate(graph, v.bound[0], v.span, "overwritten")
				prov_store_value(graph, v.bound[0], v.bound[1], walk_flow_expr(graph, v.bound[1]), v.span)
			}
			return nil, true
		case .Unsafe_Forget:
			if len(v.bound) == 1 {
				// A borrow of the forgotten value dies here, as at a `drop`.
				prov_consume(graph, v.bound[0], v.span, "forgotten")
			}
			return nil, true
		}
	}
	return nil, false
}

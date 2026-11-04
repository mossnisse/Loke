// What a call's result borrows and is in: resets, cross-thread checks, and result
// summaries substituted at the call (design.md "Temporaries and procedure boundaries").
package lokec

@(private)
prov_store_call_results :: proc(graph: ^Flow_Graph, v: ^Expr_Call, actuals: [][]int) -> []int {
	type := prov_type(graph, v)
	recorded := prov_effect_active(graph) && prov_type_has_region(graph.k.c, type)
	if recorded { prov_effect_begin(graph, Prov_Effect_Call{prov_input_value(graph, v), .Result}) }
	defer prov_effect_end(graph, recorded)
	// A diverging call's value is never produced (design.md "Diverging
	// procedures"), so it contributes no sources.
	if type == TYPE_VOID || type == INVALID_TYPE || call_diverges(graph.k.c, v) {
		return nil
	}
	id := prov_input_value(graph, v)
	result := Prov_Call_Result {
		loans          = prov_call_result(graph, v, actuals, type),
		region         = prov_call_region(graph, id, type),
		region_content = prov_call_region_content(graph, id),
	}
	if prov_result_is_inout(graph, v) {
		result.place = prov_inout_actuals(graph, v, actuals)
	}
	graph.call_results[v] = result
	return result.loans
}

// Resets propagate through wrappers and indirect calls (design.md "@(allocator_reset)").
@(private)
prov_call_resets :: proc(graph: ^Flow_Graph, v: ^Expr_Call) {
	proc_type := call_proc_type(graph.k.c, v)
	if proc_type == INVALID_TYPE {
		return
	}
	for argument, index in v.bound {
		if argument == nil || !proc_param_resets(graph.k.c, proc_type, index) {
			continue
		}
		prov_reset(graph, prov_input_value(graph, argument), v.span, false, v)
	}
}

// design.md "@(cross_thread)": @(escape=static) already rules out a thread_local
// borrow; this checks thread affinity, erasure, and the allocator region.
@(private)
prov_call_cross_thread :: proc(graph: ^Flow_Graph, v: ^Expr_Call) {
	c := graph.k.c
	if graph.mode != .Prov_Diagnose || !committing(c) {
		return
	}
	proc_type := call_proc_type(c, v)
	info := underlying_info(c, proc_type)
	if info == nil || len(info.param_cross_thread) == 0 {
		return
	}
	for argument, index in v.bound {
		if argument == nil || index >= len(info.parameters) || !proc_param_crosses_thread(c, proc_type, index) ||
		   underlying_kind(c, info.parameters[index]) == .Proc {
			continue
		}
		base := expr_base(argument)
		if base == nil || base.type == INVALID_TYPE {
			continue
		}
		facts := transfer_facts(c, prov_transferred_type(c, argument), through_views = true)
		span := expr_span(argument)
		report_transfer_facts(c, base.type, facts, span)
		prov_event(graph, Prov_Event_Received_Region{prov_input_value(graph, argument), span, prov_owner_name(graph, argument)})
	}
}

// design.md "Sharing with tasks", "Borrows crossing between tasks": the argument
// and result checks at a spawn; the solver checks thread_local borrows on crossing.
@(private)
prov_spawn_transfers :: proc(graph: ^Flow_Graph, s: ^Stmt_Spawn, call: ^Expr_Call, held, result: []int) {
	c := graph.k.c
	task := s.task
	if graph.mode != .Prov_Diagnose || !committing(c) {
		return
	}
	info := underlying_info(c, call_proc_type(c, call))
	for argument, index in call.bound {
		if info == nil || index >= len(info.parameters) || index >= len(task.kinds) {
			continue
		}
		// A pack element is the task's own when it is a temporary or moved in.
		// One copied from a place the parent keeps is shared, as a copy of
		// what that place reaches, and so is a spread, as the slice it views.
		if call_packs(call, index) {
			cursor: Call_Pack_Cursor
			for operand, is_spread in call_pack_next(call, &cursor) {
				if is_spread {
					prov_transfer_argument(c, operand, true)
					continue
				}
				_, moved := operand.(^Expr_Move)
				prov_transfer_argument(c, operand, !moved && expression_is_borrowed_place(operand))
			}
			continue
		}
		if argument == nil {
			continue
		}
		mode := index < len(info.param_modes) ? info.param_modes[index] : Param_Mode.Value
		// A moved argument is the task's alone, even one copied into the frame.
		_, moved := argument.(^Expr_Move)
		prov_transfer_argument(c, argument, task.kinds[index] != .Owned && mode != .Inout && !moved)
	}
	if s.result != nil {
		if sym := symbol_of(c, task.result); sym != nil {
			report_transfer_facts(c, sym.type, transfer_facts(c, sym.type, through_views = true), call.span)
		}
	}
	report_thread_local_writes(c, call, graph.literal.symbol)
	prov_emit(graph, Prov_Event {
		kind = .Cross, sources = prov_join(graph, held, prov_load_deep(graph, held, call.span)),
		span = call.span, verb = "argument",
	})
	if len(result) > 0 {
		prov_emit(graph, Prov_Event {
			kind = .Cross, sources = prov_join(graph, result, prov_load_deep(graph, result, call.span)),
			span = call.span, verb = "result",
		})
	}
}

// design.md "Temporaries and procedure boundaries": a direct call substitutes
// argument roots into the callee's result summary. An indirect call has none,
// so its result derives from every escaping argument.
@(private = "file")
prov_call_result :: proc(
	graph: ^Flow_Graph,
	v: ^Expr_Call,
	actuals: [][]int,
	result_type: Type_Id,
) -> []int {
	c := graph.k.c
	// design.md "`inout` results": the result aliases the `inout` arguments.
	if prov_result_is_inout(graph, v) {
		out := prov_inout_actuals(graph, v, actuals)
		return type_is_carrier(c, result_type) ? out : prov_value_content(graph, out, result_type, v.span)
	}
	// design.md "Shared ownership": a borrow from a handle derives from it. The
	// body can't show that through its `rawptr`, so it is asserted here.
	if len(actuals) > 0 && prov_receiver_is_shared_handle(graph, v) {
		return type_is_carrier(c, result_type) ? actuals[0] : prov_value_content(graph, actuals[0], result_type, v.span)
	}
	// A result that is not itself a borrow can still hold one.
	if !type_carries_borrow(c, result_type).any {
		return nil
	}
	// A conversion's result is its operand, carrier by carrier: a distinct
	// type and its underlying type share one carrier shape.
	if _, conversion := v.operation.(Call_Conversion); conversion && len(v.bound) == 1 && v.bound[0] != nil {
		if type_is_carrier(c, result_type) {
			return actuals[0]
		}
		return prov_project_content(graph, actuals[0], expr_base(v.bound[0]).type, nil, result_type, v.span)
	}
	callee := call_contract_declaration(c, v)
	direct := prov_has_direct_body(c, callee)
	prov_note_summary_dependency(graph, callee)
	out: []int
	if summary, found := result_summary(c, callee); found {
		// Sibling fields share one synthesized root per kind.
		synthetic := [3]Root_Id{NO_ROOT, NO_ROOT, NO_ROOT}
		read := prov_callback_result(graph, v, callee, result_type)
		if summary.content_type == result_type && len(summary.content) > 0 {
			content := prov_temp_content(graph, result_type)
			for slot in content {
				sources := read
				for path in summary.content {
					if paths_overlap(graph.prov_slots[slot].path, path.path.steps) {
						leaf_type := path.path.truncated ? result_type : path.path.type
						sources = prov_join(graph, sources, prov_substitute_result(graph, v, actuals, path.dependencies, leaf_type, &synthetic))
					}
				}
				prov_define_one_content(graph, slot, sources, v.span)
			}
			return content
		}
		out = prov_join(graph, read, prov_substitute_result(graph, v, actuals, summary.dependencies, result_type, &synthetic))
	} else if direct {
		// No summary yet is a forward fixed-point edge, not erased metadata.
		return nil
	} else {
		// Without a mapping every escaping argument can reach every result path.
		out = prov_escaping_actuals(graph, v, actuals)
		if _, is_call := v.operation.(Call_Procedure); is_call && symbol_of(c, callee) == nil {
			append(&graph.plain_calls, v)
		}
		// design.md "Temporaries and procedure boundaries": with no escaping
		// argument to derive from, the result's root is unknown. An argument
		// borrowed only for the call establishes nothing.
		if len(out) == 0 {
			out = prov_synthetic_borrow(graph, v, .Unknown, result_type)
		}
		out = prov_join(graph, out, prov_callback_returned(graph, v, result_type))
	}
	return type_is_carrier(c, result_type) ? out : prov_value_content(graph, out, result_type, v.span)
}

// design.md "Borrows crossing between tasks": what the result may hold that a
// callback the callee calls leaves in an argument, with the callback this call
// passes: its `thread_local` borrow, or while a body is summarized and the
// callback is that body's own, its stand-in.
@(private = "file")
prov_callback_result :: proc(graph: ^Flow_Graph, v: ^Expr_Call, callee: Symbol_Id, result_type: Type_Id) -> []int {
	consulted := make([dynamic]Symbol_Id, 0, 4, context.temp_allocator)
	reads := call_callback_reads(graph.k.c, v, callee, graph.literal.symbol, graph.mode == .Prov_Summary, &consulted)
	return prov_callback_loans(graph, v, reads, consulted[:], result_type)
}

// design.md "Borrows crossing between tasks": a call through a value may
// return a borrow of the `thread_local` storage of the thread that runs it,
// which an unknown root does not show: what each procedure the value may be
// returns, or while a body is summarized and the value is a callback that body
// received, the one its caller passes (`call_callback_returns`).
@(private = "file")
prov_callback_returned :: proc(graph: ^Flow_Graph, v: ^Expr_Call, result_type: Type_Id) -> []int {
	consulted := make([dynamic]Symbol_Id, 0, 4, context.temp_allocator)
	returned := call_callback_returns(graph.k.c, v, graph.literal.symbol, graph.mode == .Prov_Summary, &consulted)
	return prov_callback_loans(graph, v, returned, consulted[:], result_type)
}

@(private = "file")
prov_callback_loans :: proc(graph: ^Flow_Graph, v: ^Expr_Call, lefts: []Thread_Local_Left, consulted: []Symbol_Id, result_type: Type_Id) -> []int {
	prov_note_summary_dependencies(graph, consulted)
	out: []int
	for left in lefts {
		root := NO_ROOT
		if left.callback != INVALID_SYMBOL {
			root = prov_forwarded_root(graph, left.callback, left.argument, v.span)
		} else {
			root = prov_root_for_symbol(graph, left.global)
		}
		out = prov_join(graph, out, prov_root_borrow(graph, root, result_type, v.span))
	}
	return out
}

// A borrow of all of `root`, at `type`'s capability and noun.
@(private = "file")
prov_root_borrow :: proc(graph: ^Flow_Graph, root: Root_Id, type: Type_Id, span: Span) -> []int {
	return prov_borrow(graph, root, nil, type_carries_borrow(graph.k.c, type).mutable, span, carrier_noun(graph.k.c, type))
}

@(private = "file")
prov_inout_actuals :: proc(graph: ^Flow_Graph, v: ^Expr_Call, actuals: [][]int) -> []int {
	out: []int
	for slots, index in actuals {
		if prov_argument_is_inout(graph, v, index) {
			out = prov_join(graph, out, slots)
		}
	}
	return out
}

@(private)
prov_receiver_is_shared_handle :: proc(graph: ^Flow_Graph, v: ^Expr_Call) -> bool {
	sym := symbol_of(graph.k.c, v.resolution.chosen_overload)
	if sym == nil || !sym.has_receiver {
		return false
	}
	return type_is_shared_handle(graph.k.c, sym.owner_type)
}

// Substitutes one result path's dependencies, matching parameter paths by shape.
@(private = "file")
prov_substitute_result :: proc(
	graph: ^Flow_Graph,
	v: ^Expr_Call,
	actuals: [][]int,
	dependencies: Result_Dependencies,
	type: Type_Id,
	synthetic: ^[3]Root_Id,
) -> []int {
	out: []int
	for depths, index in dependencies.param_loads {
		if index >= len(actuals) {
			continue
		}
		// design.md "Procedure result contracts": a `self: ^` receiver's actual
		// also holds what its place holds, which is what one load through the
		// receiver reads, selected at the loaded path. Loading through those
		// carriers instead would reach what every field views, and loading
		// through the borrow of the place adds nothing but, for a temporary,
		// the temporary itself.
		through := actuals[index]
		held: []int
		if content, found := graph.receiver_content[v]; found && index == 0 {
			through, held = nil, content
		}
		load_through := proc(graph: ^Flow_Graph, v: ^Expr_Call, through, held: []int, depth: int, path: []Proj_Step) -> []int {
			if len(held) > 0 {
				return prov_load_held(graph, v, held, depth, path)
			}
			return prov_load_deep(graph, through, v.span, depth, path)
		}
		shape := prov_parameter_pointee_shape(graph, v, index)
		for depth in 1 ..= 8 {
			if depths & (u8(1) << u8(depth - 1)) == 0 {
				continue
			}
			// A load narrowed to some of the pointee's paths goes along only
			// those, and so do the loads below it.
			paths := result_load_paths(dependencies, index, depth)
			if len(paths) == 0 || len(paths) != len(shape) {
				out = prov_join(graph, out, load_through(graph, v, through, held, depth, nil))
				continue
			}
			for named, position in paths {
				if named {
					out = prov_join(graph, out, load_through(graph, v, through, held, depth, shape[position].steps))
				}
			}
		}
	}
	for wanted, index in dependencies.params {
		if !wanted || index >= len(actuals) {
			continue
		}
		paths := index < len(dependencies.param_paths) ? dependencies.param_paths[index] : nil
		param_type := prov_parameter_type(graph, v, index)
		shape := carrier_shape(graph.k.c, param_type)
		if len(paths) == 0 || len(paths) != len(shape) {
			out = prov_join(graph, out, actuals[index])
			continue
		}
		for named, position in paths {
			if named {
				out = prov_join(graph, out, prov_select_content(graph, actuals[index], param_type, shape[position].steps))
			}
		}
	}
	// design.md "Global write effects": a borrow of a named global is a loan on
	// that global's own root, as the same borrow written here would be.
	for global in dependencies.globals {
		out = prov_join(graph, out, prov_root_borrow(graph, prov_root_for_symbol(graph, global), type, v.span))
	}
	kinds := [3]Root_Kind{.Static, .Thread_Local, .Unknown}
	wanted := [3]bool{dependencies.static, dependencies.thread, dependencies.unknown || dependencies.local}
	for needed, index in wanted {
		if !needed {
			continue
		}
		if synthetic[index] == NO_ROOT {
			synthetic[index] = prov_synthetic_root(graph, v, kinds[index])
		}
		out = prov_join(graph, out, prov_root_borrow(graph, synthetic[index], type, v.span))
	}
	if dependencies.precision != {} && len(out) > 0 {
		slot := prov_temp_slot(graph)
		graph.prov_slots[slot].precision = dependencies.precision
		prov_define_one_content(graph, slot, out, v.span)
		return prov_one(graph, slot)
	}
	return out
}

// What `depth` loads through a `self: ^` receiver read of what its place holds,
// `held`, with the first load along `path`: the first load is `held` itself.
@(private = "file")
prov_load_held :: proc(graph: ^Flow_Graph, v: ^Expr_Call, held: []int, depth: int, path: []Proj_Step) -> []int {
	if len(held) == 0 {
		return nil
	}
	selected := prov_select_content(graph, held, prov_parameter_type(graph, v, 0), path)
	if depth == 1 {
		return selected
	}
	return prov_load_deep(graph, selected, v.span, depth - 1)
}

// The carrier paths of what one load through parameter `index` reads. A
// `self: ^` receiver's signature type is the pointee itself.
@(private = "file")
prov_parameter_pointee_shape :: proc(graph: ^Flow_Graph, v: ^Expr_Call, index: int) -> []Carrier_Path {
	type := prov_parameter_type(graph, v, index)
	if input := prov_input_call(graph, v); index == 0 && input.has_receiver && input.receiver == .Borrow {
		return carrier_shape(graph.k.c, type)
	}
	return carrier_pointee_shape(graph.k.c, type)
}

@(private)
prov_note_summary_dependencies :: proc(graph: ^Flow_Graph, targets: []Symbol_Id) {
	for target in targets {
		prov_note_summary_dependency(graph, target)
	}
}

@(private)
prov_note_summary_dependency :: proc(graph: ^Flow_Graph, callee: Symbol_Id) {
	if graph.mode != .Prov_Summary || !prov_has_direct_body(graph.k.c, callee) {
		return
	}
	if is_contract_join(graph.k.c, callee) {
		for member in symbol_of(graph.k.c, callee).members {
			prov_note_summary_dependency(graph, member)
		}
		return
	}
	for existing in graph.summary_callees {
		if existing == callee {
			return
		}
	}
	append(&graph.summary_callees, callee)
}

@(private = "file")
prov_synthetic_root :: proc(graph: ^Flow_Graph, v: ^Expr_Call, kind: Root_Kind) -> Root_Id {
	name: string
	#partial switch kind {
	case .Static:       name = "static storage"
	case .Thread_Local: name = "`thread_local` storage"
	case:               name = "unknown storage"
	}
	return prov_new_root(graph, kind, v.span, name)
}

@(private)
prov_synthetic_borrow :: proc(graph: ^Flow_Graph, v: ^Expr_Call, kind: Root_Kind, type: Type_Id) -> []int {
	root := prov_synthetic_root(graph, v, kind)
	return prov_borrow(
		graph,
		root,
		nil,
		carrier_is_mutable(graph.k.c, type),
		v.span,
		carrier_noun(graph.k.c, type),
	)
}

// Whether the result reaches this parameter only through a view it holds: a
// narrowed summary entry means exactly that, since `merge_param_paths` widens
// on any loan of the parameter's own storage.
@(private)
prov_result_reads_through_receiver :: proc(c: ^Compiler, v: ^Expr_Call, type: Type_Id, index: int) -> bool {
	// A mutable yield keeps naming the receiver (design.md "By-reference
	// iteration"); a mutable slice out of `operator([:])` reborrows the view
	// it reads through instead (design.md "Indexing and slicing").
	sym := symbol_of(c, v.resolution.chosen_overload)
	if type_carries_borrow(c, type).mutable && (sym == nil || sym.operator != "[:]") {
		return false
	}
	summary, found := result_summary(c, call_contract_declaration(c, v))
	if !found || index >= len(summary.param_paths) {
		return false
	}
	if summary.param_loads[index] != 0 && !summary.params[index] {
		return true
	}
	for named in summary.param_paths[index] {
		if named {
			return true
		}
	}
	return false
}

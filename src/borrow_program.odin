// The whole program's provenance: the result summaries settled over a worklist of
// direct callers, each body's declared escape checked against its own, and then each
// body's diagnostics, one graph at a time. The solver itself is in `borrow.odin`.
package lokec

// A body whose checking failed is skipped, so provenance adds no noise to it.
Checked_Body :: struct {
	literal: ^Expr_Proc,
	clean:   bool,
}

// The whole program's provenance, after every body is checked. Summaries settle
// first, over a worklist of direct callers, then each body's diagnostics run.
// One graph is built and released at a time.
analyze_program_provenance :: proc(k: ^Checker) {
	compute_global_writes(k)
	settle_result_summaries(k)
	check_proc_contracts(k)
	if k.c.thread_summaries_wanted {
		compute_thread_summaries(k)
	}
	// Summaries are settled, so a body's declared escape is checked with it;
	// `report` sorts diagnostics by position.
	for body in k.c.checked_bodies {
		if body.clean {
			analyze_provenance(k, body.literal)
			check_declared_escape(k, body.literal)
		}
	}
}

// A caller may precede its callee, so every body is queued again; one is revisited
// only if a summary it read grew since its last visit (`clock` stamps `grew_at`
// and `visited_at`).
@(private = "file")
settle_result_summaries :: proc(k: ^Checker) {
	clock := 0
	grew_at := make([]int, len(k.c.symbols), context.temp_allocator)
	visited_at := make([]int, len(k.c.symbols), context.temp_allocator)
	visit :: proc(k: ^Checker, clock: ^int, grew_at, visited_at: []int, literal: ^Expr_Proc) -> bool {
		visited_at[int(literal.symbol)] = clock^
		grew := summarize_body(k, literal)
		if grew {
			clock^ += 1
			grew_at[int(literal.symbol)] = clock^
		}
		return grew
	}
	stale :: proc(c: ^Compiler, grew_at, visited_at: []int, literal: ^Expr_Proc) -> bool {
		for callee in c.result_summary_dependencies[literal.symbol] {
			if grew_at[int(callee)] > visited_at[int(literal.symbol)] { return true }
		}
		return false
	}
	for body in k.c.checked_bodies {
		if body.clean {
			_ = visit(k, &clock, grew_at, visited_at, body.literal)
		}
	}
	// Bodies by their index in `checked_bodies`.
	queue := worklist_make(len(k.c.checked_bodies), context.temp_allocator)
	callers := make(map[Symbol_Id][dynamic]int, context.temp_allocator)
	// How many of each body's dependencies `callers` has: a resolved callback
	// adds more on a later round, appended after them.
	registered := make([]int, len(k.c.symbols), context.temp_allocator)
	register :: proc(c: ^Compiler, callers: ^map[Symbol_Id][dynamic]int, registered: []int, literal: ^Expr_Proc, body: int) {
		dependencies := c.result_summary_dependencies[literal.symbol]
		for callee in dependencies[registered[int(literal.symbol)]:] {
			if callee not_in callers^ {
				callers^[callee] = make([dynamic]int, 0, 4, context.temp_allocator)
			}
			append(&callers^[callee], body)
		}
		registered[int(literal.symbol)] = len(dependencies)
	}
	for body, index in k.c.checked_bodies {
		if body.clean {
			worklist_wake(&queue, index)
			register(k.c, &callers, registered, body.literal, index)
		}
	}
	for index in worklist_pop(&queue) {
		literal := k.c.checked_bodies[index].literal
		if !stale(k.c, grew_at, visited_at, literal) {
			continue
		}
		grew := visit(k, &clock, grew_at, visited_at, literal)
		register(k.c, &callers, registered, literal, index)
		if !grew {
			continue
		}
		// Bound to a local first: iterating the map index directly miscompiles.
		affected := callers[literal.symbol]
		for caller in affected {
			worklist_wake(&queue, caller)
		}
	}
}

// `@(escape=none)` contradicted by the body's own result summary.
@(private = "file")
check_declared_escape :: proc(k: ^Checker, literal: ^Expr_Proc) {
	sym := symbol_of(k.c, literal.symbol)
	if sym == nil {
		return
	}
	summary, found := k.c.result_summaries[literal.symbol]
	if !found {
		return
	}
	for id, index in sym.param_symbols {
		bound := symbol_of(k.c, id)
		// design.md "Variadic parameters": a pack, and a `..^T` pack's values, are
		// temporaries of the call, so the result may hold only what they hold.
		if lending, packs := param_symbol_pack_lending(k.c, bound); packs && result_borrows_lent(summary.dependencies, index, lending) {
			lends, _, borrowed := pack_lent_phrases(lending)
			errorf(
				k.c, bound.span, "L0644",
				"`%s` %s, but the result of `%s` may borrow %s",
				identifier_text(k.c, bound.name), lends, identifier_text(k.c, sym.name), borrowed,
			)
			add_precision_notes(k.c, bound.span, summary.precision)
			continue
		}
		if bound == nil || bound.escape != .None {
			continue
		}
		if result_uses_param(summary^, index) {
			errorf(
				k.c,
				bound.span,
				"L0644",
				"`%s` is written `@(escape=none)`, but the result of `%s` may borrow it",
				identifier_text(k.c, bound.name),
				identifier_text(k.c, sym.name),
			)
			add_precision_notes(k.c, bound.span, summary.precision)
		}
	}
}

// One round of one body's result equations; returns whether its summary grew.
@(private)
summarize_body :: proc(k: ^Checker, literal: ^Expr_Proc) -> bool {
	sym := symbol_of(k.c, literal.symbol)
	if sym == nil {
		return false
	}
	writes := proc_may_write_owners(k.c, sym)
	returns := sym.result != INVALID_TYPE
	if !returns && !writes {
		return false
	}
	defer free_all(k.c.analysis_allocator)
	graph := build_flow_graph(k, literal, .Prov_Summary)
	if graph == nil {
		return false
	}
	changed := writes && collect_written_regions(k.c, graph, literal.symbol, sym)
	record_summary_dependencies(k.c, literal.symbol, graph.summary_callees[:])
	// What a body stores in caller storage needs solving only when it borrows
	// `thread_local` storage at all, or may store what an argument held.
	stores_thread_local := writes && graph_borrows_thread_local(graph)
	moves_carriers := writes && graph_may_move_carriers(graph)
	summary: ^Result_Provenance
	if returns {
		found: bool
		if summary, found = k.c.result_summaries[literal.symbol]; !found {
			summary = new(Result_Provenance, k.c.semantic_allocator)
			summary^ = new_result_provenance(k.c, len(sym.param_symbols), sym.result, true, k.c.semantic_allocator)
			k.c.result_summaries[literal.symbol] = summary
		}
	}
	if !returns && !stores_thread_local && !moves_carriers {
		return changed
	}
	state := Prov_Solve{graph = graph, k = k}
	if !prepare_state(&state) {
		return changed
	}
	solve_reaching(&state)
	return collect_body_summaries(&state, literal.symbol, summary, stores_thread_local, moves_carriers) || changed
}

// One concrete body's root and region diagnostics.
analyze_provenance :: proc(k: ^Checker, literal: ^Expr_Proc) {
	defer free_all(k.c.analysis_allocator)
	first := len(k.c.diagnostics)
	defer note_instance_sites(k, literal, first)
	graph := build_flow_graph(k, literal, .Prov_Diagnose)
	if graph == nil {
		return
	}
	solve_provenance(k, graph)
}

// An error in a generic instance's body names the call that selected it, as
// the checker's do, which run before this pass: the body may be a library's,
// and the call the caller's.
@(private)
note_instance_sites :: proc(k: ^Checker, literal: ^Expr_Proc, first: int) {
	instance := k.c.procedure_instances[literal.symbol]
	if instance == nil || instance.selected_at.file == NO_FILE {
		return
	}
	append(&k.c.instantiation_stack, Instantiation_Frame {
		symbol   = instance.template,
		bindings = instance.bindings,
		span     = instance.selected_at,
	})
	defer pop(&k.c.instantiation_stack)
	note_instantiation_stack(k, first)
}

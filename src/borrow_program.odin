// The whole program's provenance: the result summaries settled over a worklist of
// direct callers, each body's declared escape checked against its own, and then each
// body's diagnostics, one graph at a time. The solver itself is in `borrow.odin`.
package lokec

import "core:fmt"
import "core:slice"

// Built with `-define:LOKE_RECHECK_PROVENANCE=true`, the compiler also builds
// the diagnosing graph of each body whose summary solve reported for it, and
// stops where the two disagree (compiler-architecture.md "Disposable
// control-flow graphs").
LOKE_RECHECK_PROVENANCE :: #config(LOKE_RECHECK_PROVENANCE, false)

// A body whose checking failed is skipped, so provenance adds no noise to it.
Checked_Body :: struct {
	literal: ^Expr_Proc,
	clean:   bool,
}

// What the solve of a body's last summary found to report, kept out of the
// compiler's list until every summary is settled.
@(private)
Body_Report :: struct {
	diagnostics: []Diagnostic,
	// Whether that solve stands for the body's diagnosing one.
	diagnosed:   bool,
}

// The whole program's provenance, after every body is checked. Summaries settle
// first, over a worklist of direct callers, then each body's diagnostics are
// reported: those its last summary solved for, or else those of a graph built
// for them. One graph is built and released at a time.
analyze_program_provenance :: proc(k: ^Checker) {
	compute_global_writes(k)
	reports := settle_result_summaries(k)
	check_proc_contracts(k)
	if k.c.thread_summaries_wanted {
		compute_thread_summaries(k)
	}
	// Summaries are settled, so a body's declared escape is checked with it;
	// `report` sorts diagnostics by position.
	for body, index in k.c.checked_bodies {
		if body.clean {
			first := len(k.c.diagnostics)
			if reports[index].diagnosed {
				when LOKE_RECHECK_PROVENANCE {
					recheck_body_report(k, body.literal, reports[index])
				}
				restore_diagnostics(k.c, reports[index].diagnostics)
			} else {
				analyze_provenance(k, body.literal)
			}
			check_declared_escape(k, body.literal)
			note_instance_sites(k, body.literal, first)
		}
	}
}

// A caller may precede its callee, so a body is queued again, and revisited, only
// if a summary it read grew since its last visit (`clock` stamps `grew_at` and
// `visited_at`). A body's last visit therefore read every summary as settled as
// its diagnostics would, so it solves for them too, and its report is by its
// index in `checked_bodies`. Two things leave a body to `analyze_provenance`
// instead:
//
// - A summary the visit read was still to be made (`made_at`). A caller reads
//   one that is there, even an empty one, otherwise than one that is not, and
//   making an empty one is no growth to visit the caller again for.
// - The program has a `parallel` statement. Its diagnostics also read the
//   thread summaries, which settle after these.
@(private = "file")
settle_result_summaries :: proc(k: ^Checker) -> []Body_Report {
	reports := make([]Body_Report, len(k.c.checked_bodies), context.temp_allocator)
	diagnose := !k.c.thread_summaries_wanted
	clock := 0
	grew_at := make([]int, len(k.c.symbols), context.temp_allocator)
	made_at := make([]int, len(k.c.symbols), context.temp_allocator)
	visited_at := make([]int, len(k.c.symbols), context.temp_allocator)
	summarized :: proc(c: ^Compiler, body: Symbol_Id) -> bool {
		return body in c.result_summaries || body in c.written_summaries
	}
	visit :: proc(k: ^Checker, clock: ^int, grew_at, made_at, visited_at: []int, literal: ^Expr_Proc, report: ^Body_Report) -> bool {
		body := literal.symbol
		visited_at[int(body)] = clock^
		had := summarized(k.c, body)
		grew := summarize_body(k, literal, report)
		made := !had && summarized(k.c, body)
		if grew || made {
			clock^ += 1
		}
		if grew {
			grew_at[int(body)] = clock^
		}
		if made {
			made_at[int(body)] = clock^
		}
		return grew
	}
	// Whether a summary the body read changed, by `changed_at`, since its last visit.
	stale :: proc(c: ^Compiler, changed_at, visited_at: []int, literal: ^Expr_Proc) -> bool {
		for callee in c.result_summary_dependencies[literal.symbol] {
			if changed_at[int(callee)] > visited_at[int(literal.symbol)] { return true }
		}
		return false
	}
	for body, index in k.c.checked_bodies {
		if body.clean {
			_ = visit(k, &clock, grew_at, made_at, visited_at, body.literal, diagnose ? &reports[index] : nil)
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
			register(k.c, &callers, registered, body.literal, index)
			if stale(k.c, grew_at, visited_at, body.literal) {
				worklist_wake(&queue, index)
			}
		}
	}
	for index in worklist_pop(&queue) {
		literal := k.c.checked_bodies[index].literal
		if !stale(k.c, grew_at, visited_at, literal) {
			continue
		}
		grew := visit(k, &clock, grew_at, made_at, visited_at, literal, diagnose ? &reports[index] : nil)
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
	for body, index in k.c.checked_bodies {
		if reports[index].diagnosed && stale(k.c, made_at, visited_at, body.literal) {
			drop_body_report(k.c, &reports[index])
		}
	}
	return reports
}

// `LOKE_RECHECK_PROVENANCE`: what `analyze_provenance` reports for the body is
// what `report` holds.
@(private = "file")
recheck_body_report :: proc(k: ^Checker, literal: ^Expr_Proc, report: Body_Report) {
	c := k.c
	first := len(c.diagnostics)
	analyze_provenance(k, literal)
	again := c.diagnostics[first:]
	same := len(again) == len(report.diagnostics)
	for index := 0; same && index < len(again); index += 1 {
		same = same_diagnostic(again[index], report.diagnostics[index]) &&
			slice.equal(again[index].notes[:], report.diagnostics[index].notes[:])
	}
	if !same {
		fmt.eprintfln("provenance recheck: `%s` differs", identifier_text(c, symbol_of(c, literal.symbol).name))
		for list, built in ([2][]Diagnostic{report.diagnostics, again}) {
			fmt.eprintfln("  from its %s:", built == 0 ? "last summary" : "diagnosing graph")
			for d in list {
				fmt.eprintfln("    %s %v %s (%d notes)", d.code, d.span, d.message, len(d.notes))
			}
		}
		panic("a body's summary solve and its diagnosing graph report differently")
	}
	truncate_diagnostics(c, first)
}

@(private = "file")
drop_body_report :: proc(c: ^Compiler, report: ^Body_Report) {
	for &diagnostic in report.diagnostics {
		destroy_diagnostic(c, &diagnostic)
	}
	report^ = {}
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
// With a `report`, the round also solves for the body's diagnostics and leaves
// there what it found, in place of an earlier round's, unless the body's
// diagnosing graph would be another (`Prov_State.summary_only`).
@(private)
summarize_body :: proc(k: ^Checker, literal: ^Expr_Proc, report: ^Body_Report = nil) -> bool {
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
	reported := len(k.c.diagnostics)
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
	summarizes := returns || stores_thread_local || moves_carriers
	diagnoses := report != nil && !graph.summary_only
	state := Prov_Solve{graph = graph, k = k}
	if (summarizes || diagnoses) && prepare_state(&state) {
		solve_reaching(&state)
		if summarizes {
			changed = collect_body_summaries(&state, literal.symbol, summary, stores_thread_local, moves_carriers) || changed
		}
		if diagnoses {
			report_solved(&state)
		}
	}
	if diagnoses {
		drop_body_report(k.c, report)
		report^ = {take_diagnostics(k.c, reported, context.temp_allocator), true}
	}
	return changed
}

// One concrete body's root and region diagnostics.
analyze_provenance :: proc(k: ^Checker, literal: ^Expr_Proc) {
	defer free_all(k.c.analysis_allocator)
	graph := build_flow_graph(k, literal, .Prov_Diagnose)
	if graph == nil {
		return
	}
	solve_provenance(k, graph)
}

// An error in a generic instance's body, or about its declared escape, names the
// call that selected it, as the checker's do, which run before this pass: the
// body may be a library's, and the call the caller's.
@(private = "file")
note_instance_sites :: proc(k: ^Checker, literal: ^Expr_Proc, first: int) {
	instance := k.c.procedure_instances[literal.symbol]
	if instance == nil || instance.selected_at.file == NO_FILE {
		return
	}
	depth := len(k.c.instantiation_stack)
	append(&k.c.instantiation_stack, ..instance.selected_under)
	append(&k.c.instantiation_stack, Instantiation_Frame {
		symbol   = instance.template,
		bindings = instance.bindings,
		span     = instance.selected_at,
	})
	defer resize(&k.c.instantiation_stack, depth)
	note_instantiation_stack(k, first)
}

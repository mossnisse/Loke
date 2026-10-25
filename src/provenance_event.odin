// Recorded events whose payload reads carried facts. The construction walk
// emits each with the facts it has; once the fact operations settle, the
// recorded inputs are materialized again and replace those events.
package lokec

import "core:slice"

// Where a reset's region comes from: fixed by the walk, the region of a value,
// or the providers of live owners that something may have been lent.
Prov_Reset_Indirect :: struct { owners: []Symbol_Id }
Prov_Reset_Region :: union { Region_Set, Value_Id, Prov_Reset_Indirect }

// `prov_reset`'s inputs, with the walk state it reads captured as values.
Prov_Event_Reset :: struct {
	region:       Prov_Reset_Region,
	span:         Span,
	direct:       bool,
	live:         Reset_Liveness,
	ends:         string,
	ending:       Symbol_Id,
	provider_end: bool,
	unwind_from:  Maybe(Span),
	held:         []Value_Id,
	temporaries:  []Root_Id,
	returning:    Maybe(Prov_Returning),
}

// A result handed back by `return` or a propagated error; `sources` and `into`
// are its settled carrier slots.
Prov_Event_Escape :: struct {
	sources, into: []int,
	span:          Span,
	value:         Value_Id,
	propagated:    Maybe(Prov_Form_Error),
	result:        Type_Id,
}

// An owner stored into `target`'s storage, which may outlive its region.
Prov_Event_Region_Escape :: struct {
	target, value: Value_Id,
	source:        []Proj_Step,
	copies:        bool,
	destination:   Symbol_Id,
}

// An owner a call may keep in storage that lasts for the process.
Prov_Event_Static_Escape :: struct {
	value: Value_Id,
	span:  Span,
	owner: string,
}

// A map key inserted by assigning through `symbol`'s map.
Prov_Event_Key_Escape :: struct {
	key:    Value_Id,
	span:   Span,
	symbol: Symbol_Id,
	owner:  string,
}

// A region read where it is used: fixed by the walk, a value's
// (`prov_region_of`), or a local's (`prov_region_for_symbol`).
Prov_Use_Region :: union { Region_Set, Value_Id, Symbol_Id }

@(private)
prov_use_region :: proc(graph: ^Flow_Graph, source: Prov_Use_Region) -> Region_Set {
	switch region in source {
	case Region_Set: return region
	case Value_Id:   return prov_region_of(graph, region)
	case Symbol_Id:  return prov_region_for_symbol(graph, region)
	}
	return prov_empty_region(graph)
}

// `prov_note_allocator_use` of a region read where it is used.
Prov_Event_Allocator_Use :: struct {
	region: Prov_Use_Region,
	span:   Span,
	owned:  bool,
}

// The allocator use of a call no summary follows (`prov_call_allocator_use`).
Prov_Event_Call_Allocator_Use :: struct { call: ^Expr_Call }

// The regions a call's or drop's effect is given: each argument's, or the
// dropped value's. `effect` indexes the call in `Flow_Graph.effect_calls`.
Prov_Event_Effect_Use :: struct {
	target: Effect_Call,
	call:   ^Expr_Call,
	drop:   Maybe(Prov_Use_Region),
	effect: int,
	span:   Span,
}

// An argument crossing to another thread backed by a received region.
Prov_Event_Received_Region :: struct {
	value: Value_Id,
	span:  Span,
	owner: string,
}

// A carrier written through a borrowed binding, published into the storage
// its region aliases name (design.md "Values that contain borrows").
Prov_Event_View_Publish :: struct {
	symbol:  Symbol_Id,
	path:    []Proj_Step,
	sources: []int,
	span:    Span,
	type:    Type_Id,
	through: []int,
}

Prov_Event_Operation :: union {
	Prov_Event_Reset, Prov_Event_Escape, Prov_Event_Region_Escape, Prov_Event_Static_Escape, Prov_Event_Key_Escape,
	Prov_Event_Allocator_Use, Prov_Event_Call_Allocator_Use, Prov_Event_Effect_Use, Prov_Event_Received_Region,
	Prov_Event_View_Publish,
}

// An allocator control block's root, whose region is its provider's.
Prov_Root_Region :: struct {
	root:     Root_Id,
	call:     ^Expr_Call,
	receiver: Value_Id,
}

// `first` and `count` are the construction events the operation produced in
// `block`, and `diagnostics` its construction diagnostics; `sequence` orders
// it among the fact operations. The walk state it reads is the site's.
Prov_Event_Site :: struct {
	operation:      Prov_Event_Operation,
	block:          Block_Id,
	expansion:      Defer_Expansion,
	first, count:   int,
	sequence:       int,
	parallel_depth: int,
	task:           int,
	diagnostics:    [2]int,
}

// The task site a spawned call's effects reserve for, or -1.
@(private)
prov_task_index :: proc(graph: ^Flow_Graph) -> int {
	return graph.task_effects ? len(graph.task_sites) : -1
}

// The kinds a replayed fact operation emits. They are checks whose position
// within their block the solver does not read.
PROV_FACT_EVENTS :: bit_set[Prov_Kind]{.Region_Escape, .Region_Use}

// Inside a recorded fact operation the event is that operation's to replay.
@(private)
prov_event :: proc(graph: ^Flow_Graph, operation: Prov_Event_Operation) {
	program := graph.effect_program
	if program == nil || graph.effect_depth > 0 {
		prov_materialize_event(graph, operation)
		return
	}
	first := graph.current == NO_BLOCK ? 0 : len(graph.blocks[graph.current].prov)
	reported := len(graph.k.c.diagnostics)
	prov_materialize_event(graph, operation)
	program.sequence += 1
	append(&program.events, Prov_Event_Site {
		operation = operation, block = graph.current, expansion = graph.expansion,
		first = first, count = graph.current == NO_BLOCK ? 0 : len(graph.blocks[graph.current].prov) - first,
		sequence = program.sequence, parallel_depth = graph.parallel_depth, task = prov_task_index(graph),
		diagnostics = {reported, len(graph.k.c.diagnostics)},
	})
}

// The construction diagnostics of recorded events, which their settled
// materialization reports again.
@(private)
prov_drop_event_diagnostics :: proc(c: ^Compiler, program: ^Prov_Effect_Program) {
	kept := -1
	next := 0
	for index := 0; index < len(c.diagnostics); index += 1 {
		for next < len(program.events) && program.events[next].diagnostics[1] <= index { next += 1 }
		dropped := false
		if next < len(program.events) {
			range := program.events[next].diagnostics
			dropped = range[0] <= index && index < range[1]
		}
		if dropped {
			if kept < 0 { kept = index }
			if c.diagnostics[index].severity == .Error { c.error_count -= 1 }
			destroy_diagnostic(c, &c.diagnostics[index])
			continue
		}
		if kept >= 0 {
			c.diagnostics[kept] = c.diagnostics[index]
			kept += 1
		}
	}
	if kept >= 0 { resize(&c.diagnostics, kept) }
}

@(private)
prov_materialize_event :: proc(graph: ^Flow_Graph, operation: Prov_Event_Operation) {
	switch op in operation {
	case Prov_Event_Reset:  prov_materialize_reset(graph, op)
	case Prov_Event_Escape: prov_materialize_escape(graph, op)
	case Prov_Event_Region_Escape:
		owned := prov_copied_owner_region(graph, op.value, op.source, op.copies, prov_destination_allocator(graph, op.destination))
		prov_region_escape_set(graph, op.target, owned, prov_owner_name(graph, prov_value(graph, op.value).origin))
	case Prov_Event_Key_Escape:
		prov_region_escape_into(graph, op.span, op.symbol, prov_result_region_at(graph, op.key, nil, .Owners), op.owner)
	case Prov_Event_Allocator_Use:
		prov_note_allocator_use(graph, prov_use_region(graph, op.region), op.span, op.owned)
	case Prov_Event_Call_Allocator_Use:
		prov_call_allocator_use(graph, op.call)
	case Prov_Event_Effect_Use:
		prov_materialize_effect_use(graph, op)
	case Prov_Event_View_Publish:
		prov_materialize_view_publish(graph, op)
	case Prov_Event_Received_Region:
		if prov_has_received_region(graph, prov_result_region(graph, op.value)) {
			errorf(
				graph.k.c, op.span, "L0726",
				"%s is backed by an allocator region this procedure received, which another thread may not be allowed to use",
				op.owner,
			)
			add_notef(graph.k.c, op.span, "build it with the default allocator, or in the thread that uses it")
		}
	case Prov_Event_Static_Escape:
		if region := prov_result_region(graph, op.value); region_has_local(region) {
			prov_emit(graph, Prov_Event {
				kind = .Region_Escape, span = op.span, verb = op.owner,
				name = "storage that lasts for the whole process", region = region,
			})
		}
	case: unreachable()
	}
}

@(private = "file")
prov_materialize_escape :: proc(graph: ^Flow_Graph, op: Prov_Event_Escape) {
	region: Region_Set
	fields: []Prov_Region_Content
	if propagated, known := op.propagated.?; known {
		region = prov_error_region_at(graph, propagated, nil, .All)
		fields = prov_error_region_fields(graph, propagated, op.result)
	} else {
		region = prov_escape_region(graph, op.value)
		fields = prov_result_region_fields(graph, op.value, op.result)
	}
	prov_emit(graph, Prov_Event {
		kind = .Escape, sources = op.sources, into = op.into, span = op.span,
		region = region, region_content = fields,
		// The frame's regions end here, so the diagnostic names them.
		name = prov_region_name(graph, region),
	})
}

// What a result already handed to the caller holds while its return's
// deferred statements run.
@(private)
prov_returning_region :: proc(graph: ^Flow_Graph, returning: Prov_Returning) -> Region_Set {
	if propagated, known := returning.propagated.?; known {
		return prov_reset_fields_region(graph, returning.result, prov_error_region_fields(graph, propagated, returning.result))
	}
	return prov_reset_value_region(graph, returning.value)
}

// Replaces the construction graph's fact-dependent events with ones built
// from the settled facts in `final`, a fact graph seeded with them.
@(private)
prov_materialize_events :: proc(graph, final: ^Flow_Graph, program: ^Prov_Effect_Program) {
	Replacement :: struct {
		first, count, sequence: int,
		fact:                   bool,
		events:                 []Prov_Event,
	}
	// Interleaved in recorded order, so each event sees the flow-sensitive
	// replay state, such as a borrowed binding's region aliases, of its site.
	// Summary outputs read from facts are rebuilt into `graph`.
	by_block := make([][dynamic]Replacement, len(graph.blocks), graph.alloc)
	for &replacements in by_block { replacements = make([dynamic]Replacement, graph.alloc) }
	final.materialized = graph
	defer final.materialized = nil
	graph.allocator_use = {}
	for &site in graph.task_sites { site.reserve = {} }
	facts, events := 0, 0
	for facts < len(program.operations) || events < len(program.events) {
		if events == len(program.events) || (facts < len(program.operations) && program.operations[facts].sequence < program.events[events].sequence) {
			site := program.operations[facts]
			facts += 1
			final.current, final.expansion = site.block, site.expansion
			final.parallel_depth, final.task_effects, final.task_index = site.parallel_depth, site.task >= 0, site.task
			// A replayed fact operation reports nothing: its construction did.
			diagnostics := len(graph.k.c.diagnostics)
			defer truncate_diagnostics(graph.k.c, diagnostics)
			first := site.block == NO_BLOCK ? 0 : len(final.blocks[site.block].prov)
			prov_replay_fact_operation(final, site.operation)
			if site.block == NO_BLOCK { continue }
			emitted := slice.clone(final.blocks[site.block].prov[first:], graph.alloc)
			for event in emitted { assert(event.kind in PROV_FACT_EVENTS, "fact replay emitted an event the walk owns") }
			append(&by_block[site.block], Replacement{site.first, site.count, site.sequence, true, emitted})
			continue
		}
		site := program.events[events]
		events += 1
		final.current, final.expansion = site.block, site.expansion
		final.parallel_depth, final.task_effects, final.task_index = site.parallel_depth, site.task >= 0, site.task
		first := site.block == NO_BLOCK ? 0 : len(final.blocks[site.block].prov)
		prov_materialize_event(final, site.operation)
		if site.block == NO_BLOCK { continue }
		append(&by_block[site.block], Replacement{site.first, site.count, site.sequence, false, slice.clone(final.blocks[site.block].prov[first:], graph.alloc)})
	}
	for entry in program.root_regions {
		graph.roots[int(entry.root)].region, _ = prov_handle_region(final, entry.call, entry.receiver)
	}
	graph.has_region_event = false
	window := graph.has_window_event
	for &replacements, index in by_block {
		block := graph.blocks[index]
		if len(replacements) > 0 {
			slice.sort_by(replacements[:], proc(a, b: Replacement) -> bool { return a.sequence < b.sequence })
			old := block.prov
			spliced := make([dynamic]Prov_Event, 0, len(old), graph.alloc)
			cursor := 0
			for replacement in replacements {
				assert(replacement.first >= cursor, "recorded event ranges overlap")
				append(&spliced, ..old[cursor:replacement.first])
				for event in old[replacement.first:][:replacement.count] {
					if replacement.fact && event.kind not_in PROV_FACT_EVENTS { append(&spliced, event) }
				}
				append(&spliced, ..replacement.events)
				cursor = replacement.first + replacement.count
			}
			append(&spliced, ..old[cursor:])
			block.prov = spliced
		}
		for event in block.prov {
			switch event.kind {
			case .Reset, .Region_Escape:
				graph.has_region_event = true
			case .Escape:
				graph.has_region_event ||= !region_is_empty(event.region)
				for content in event.region_content { graph.has_region_event ||= !region_is_empty(content.region) }
			case .Region_Use:
				window = true
			case .Def, .Live, .Access, .Root_End, .Rebind, .Retain, .Publish, .Load, .Reach, .Cross,
			     .Task_Start, .Task_Join, .Shared_Effect:
			}
		}
	}
	graph.has_window_event = window
}

@(private = "file")
prov_materialize_effect_use :: proc(graph: ^Flow_Graph, op: Prov_Event_Effect_Use) {
	target := op.target
	if op.call != nil {
		target.regions = prov_argument_regions(graph, op.call)
	} else if drop, known := op.drop.?; known {
		regions := make([]Region_Set, 1, graph.alloc)
		regions[0] = prov_caller_region(graph, prov_use_region(graph, drop))
		target.regions = regions
	}
	if op.effect >= 0 {
		prov_output(graph).effect_calls[op.effect].regions = target.regions
	}
	prov_window_effect_use(graph, target, op.span)
}

// The graph a materialization writes its summary outputs to.
@(private)
prov_output :: proc(graph: ^Flow_Graph) -> ^Flow_Graph {
	return graph.materialized != nil ? graph.materialized : graph
}

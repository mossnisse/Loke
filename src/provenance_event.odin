// Recorded events whose payload reads carried facts. The construction walk
// emits each with the facts it has; once the fact operations settle, the
// recorded inputs are materialized again and replace those events.
package lokec

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
	sources, into:   []int,
	using returning: Prov_Returning,
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
	return Region_Set{}
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

// The regions of an argument for a parameter with a `Thread_Check`, which the
// facts at hand decide.
Prov_Event_Thread_Regions :: struct {
	value: Value_Id,
	span:  Span,
	owner: string,
	check: Thread_Check,
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
	Prov_Event_Allocator_Use, Prov_Event_Call_Allocator_Use, Prov_Event_Effect_Use, Prov_Event_Thread_Regions,
	Prov_Event_View_Publish,
}

// An allocator control block's root, whose region is its provider's.
Prov_Root_Region :: struct {
	root:     Root_Id,
	call:     ^Expr_Call,
	receiver: Value_Id,
}

// Where a recorded operation ran. `first` and `count` are the construction events
// it produced in `block`; `sequence` orders it among all the recorded operations.
// The rest is the walk state materialization restores.
Prov_Site :: struct {
	block:          Block_Id,
	expansion:      Defer_Expansion,
	first, count:   int,
	sequence:       int,
	parallel_depth: int,
	task:           int,
}

// `diagnostics` are the operation's construction diagnostics.
Prov_Event_Site :: struct {
	operation:   Prov_Event_Operation,
	using at:    Prov_Site,
	diagnostics: [2]int,
}

// The site of an operation starting now, for the caller to number.
@(private)
prov_site_here :: proc(graph: ^Flow_Graph) -> Prov_Site {
	return Prov_Site {
		block = graph.current, expansion = graph.expansion, first = prov_next_event(graph),
		parallel_depth = graph.parallel_depth, task = prov_task_index(graph),
	}
}

// Puts `graph` where `site` ran, and answers where its events will start.
@(private = "file")
prov_enter_site :: proc(graph: ^Flow_Graph, site: Prov_Site) -> int {
	graph.current, graph.expansion = site.block, site.expansion
	graph.parallel_depth, graph.task_effects, graph.task_index = site.parallel_depth, site.task >= 0, site.task
	return prov_next_event(graph)
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
	at := prov_site_here(graph)
	reported := len(graph.k.c.diagnostics)
	prov_materialize_event(graph, operation)
	at.count = prov_next_event(graph) - at.first
	// After what the materialization itself recorded.
	program.sequence += 1
	at.sequence = program.sequence
	append(&program.events, Prov_Event_Site{operation = operation, at = at, diagnostics = {reported, len(graph.k.c.diagnostics)}})
}

// The construction diagnostics of recorded events, which their settled
// materialization reports again.
@(private)
prov_drop_event_diagnostics :: proc(c: ^Compiler, program: ^Prov_Effect_Program) {
	kept, next := 0, 0
	for index in 0 ..< len(c.diagnostics) {
		for next < len(program.events) && program.events[next].diagnostics[1] <= index { next += 1 }
		if next < len(program.events) && program.events[next].diagnostics[0] <= index {
			discard_diagnostic(c, &c.diagnostics[index])
			continue
		}
		c.diagnostics[kept] = c.diagnostics[index]
		kept += 1
	}
	shrink_diagnostics(c, kept)
}

// design.md "Allocator regions and region provenance": a string's `clone` or
// `try_clone` is a logical copy that keeps its source's allocation, so naming an
// allocator for it changes nothing; `copy()` is the copy with storage of its own.
@(private = "file")
prov_is_string_clone :: proc(c: ^Compiler, e: Expr) -> bool {
	call, is_call := e.(^Expr_Call)
	if !is_call { return false }
	contract := symbol_of(c, call_contract_declaration(c, call))
	if contract == nil || (contract.synth != .Clone && contract.synth != .Try_Clone) { return false }
	return type_underlying(c, contract.owner_type) == TYPE_STRING
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
	case Prov_Event_Thread_Regions:
		prov_check_thread_regions(graph, op)
	case Prov_Event_Static_Escape:
		if region := prov_result_region(graph, op.value); region_has_local(region) {
			prov_emit(graph, Prov_Event {
				kind = .Region_Escape, span = op.span, verb = op.owner,
				name = "storage that lasts for the whole process", region = region,
			})
		}
	}
}

// design.md "Concurrency and the memory model": an owner that crosses to another
// thread is in no region this body received unchecked, nor in one the checker
// cannot name, since the callee trusts its regions (design.md
// "@(concurrent_regions)"). An argument so promised is in none that serves one
// thread at a time either.
@(private = "file")
prov_check_thread_regions :: proc(graph: ^Flow_Graph, op: Prov_Event_Thread_Regions) {
	c := graph.k.c
	if op.check == .Crosses {
		// A local region is the escape check's (`Prov_Event_Static_Escape`).
		set := prov_unpromised_regions(graph, prov_result_region(graph, op.value))
		received := region_is_parameter_backed(set)
		if !received && !set.unknown {
			return
		}
		errorf(
			c, op.span, "L0726", "%s is backed by an allocator region %s, which another thread may not be allowed to use",
			op.owner, received ? "this procedure received" : "the checker cannot name",
		)
		if prov_is_string_clone(c, prov_value(graph, op.value).origin) {
			add_notef(c, op.span, "a string's `clone` shares its source's allocation; `copy()` makes one of its own")
		} else {
			add_notef(c, op.span, "build it with the default allocator, or in the thread that uses it")
		}
		return
	}
	set := prov_unpromised_regions(graph, prov_promised_regions(graph, op.value))
	if !region_has_local(set) && !region_is_parameter_backed(set) && !set.unknown {
		return
	}
	errorf(
		c, op.span, "L0758",
		"%s may be in or name an allocator region that serves one thread at a time, which a `@(concurrent_regions)` parameter rules out",
		op.owner,
	)
	switch local := prov_region_name(graph, Region_Set{locals = set.locals}); {
	case local != "":
		add_notef(c, op.span, "`%s`'s allocator is such a region", local)
	case region_has_local(set):
		add_notef(c, op.span, "an allocator made in this procedure is such a region")
	case region_is_parameter_backed(set):
		add_notef(c, op.span, "a region this procedure received may be one; mark the parameter it arrived through `@(concurrent_regions)` too")
	case:
		add_notef(c, op.span, "its allocator is one the checker cannot name, as one read from a global is")
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

// One recorded operation's events: `count` construction events from `first` give
// way to `length` from `start` in `final`'s block. A fact operation keeps the ones
// the walk owns.
@(private = "file")
Prov_Replacement :: struct {
	first, count:  int,
	fact:          bool,
	start, length: int,
}

// Replaces the construction graph's fact-dependent events with ones built
// from the settled facts in `final`, a fact graph seeded with them.
@(private)
prov_materialize_events :: proc(graph, final: ^Flow_Graph, program: ^Prov_Effect_Program) {
	// Interleaved in recorded order, so each event sees the flow-sensitive
	// replay state, such as a borrowed binding's region aliases, of its site.
	// Each block's replacements are therefore appended in recorded order too,
	// which is the order of their ranges. Summary outputs read from facts are
	// rebuilt into `graph`.
	by_block := make([][dynamic]Prov_Replacement, len(graph.blocks), graph.alloc)
	for &replacements in by_block { replacements = make([dynamic]Prov_Replacement, graph.alloc) }
	final.materialized = graph
	defer final.materialized = nil
	graph.allocator_use = {}
	for &site in graph.task_sites { site.reserve = {} }
	facts, events := 0, 0
	for facts < len(program.operations) || events < len(program.events) {
		fact := events == len(program.events) || (facts < len(program.operations) && program.operations[facts].sequence < program.events[events].sequence)
		at := fact ? program.operations[facts].at : program.events[events].at
		start := prov_enter_site(final, at)
		if fact {
			// A replayed fact operation reports nothing: its construction did.
			reported := len(graph.k.c.diagnostics)
			prov_replay_fact_operation(final, program.operations[facts].operation)
			assert(len(graph.k.c.diagnostics) == reported, "fact replay reported a diagnostic")
			facts += 1
		} else {
			prov_materialize_event(final, program.events[events].operation)
			events += 1
		}
		if at.block == NO_BLOCK { continue }
		emitted := final.blocks[at.block].prov[start:]
		if fact {
			for event in emitted { assert(event.kind in PROV_FACT_EVENTS, "fact replay emitted an event the walk owns") }
		}
		if at.count > 0 || len(emitted) > 0 {
			append(&by_block[at.block], Prov_Replacement{at.first, at.count, fact, start, len(emitted)})
		}
	}
	for entry in program.root_regions {
		graph.roots[int(entry.root)].region, _ = prov_handle_region(final, entry.call, entry.receiver)
	}
	for replacements, index in by_block {
		if len(replacements) > 0 { prov_splice_events(graph, graph.blocks[index], final.blocks[index].prov[:], replacements[:]) }
	}
	// Facts only grow, so `final` flags whatever its replacements need.
	graph.has_region_event ||= final.has_region_event
	graph.has_window_event ||= final.has_window_event
}

@(private = "file")
prov_splice_events :: proc(graph: ^Flow_Graph, block: ^Flow_Block, settled: []Prov_Event, replacements: []Prov_Replacement) {
	old := block.prov
	spliced := make([dynamic]Prov_Event, 0, len(old), graph.alloc)
	cursor := 0
	for replacement in replacements {
		assert(replacement.first >= cursor, "recorded event ranges overlap")
		append(&spliced, ..old[cursor:replacement.first])
		for event in old[replacement.first:][:replacement.count] {
			if replacement.fact && event.kind not_in PROV_FACT_EVENTS { append(&spliced, event) }
		}
		append(&spliced, ..settled[replacement.start:][:replacement.length])
		cursor = replacement.first + replacement.count
	}
	append(&spliced, ..old[cursor:])
	block.prov = spliced
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

// `set` without the parameters whose regions accept concurrent use: what arrived
// through a `@(cross_thread)` or `@(concurrent_regions)` parameter was checked
// at the call that passed it.
@(private)
prov_unpromised_regions :: proc(graph: ^Flow_Graph, set: Region_Set) -> Region_Set {
	out := set
	if graph.literal.signature == nil {
		return out
	}
	for id, index in graph.param_symbols {
		if sym := symbol_of(graph.k.c, id); sym != nil && sym.thread_check != .None {
			region_remove_param(&out, index)
		}
	}
	return out
}

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
	if owner := prov_reset_blocker(graph, op, set); owner != nil {
		event.verb = identifier_text(graph.k.c, owner.name)
		event.owner_span = owner.span
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
@(private = "file")
prov_reset_blocker :: proc(graph: ^Flow_Graph, op: Prov_Event_Reset, set: Region_Set) -> ^Symbol {
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
		if !region_is_empty(region) && regions_may_overlap(region, set) {
			return owner
		}
	}
	return nil
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
		join(graph, &region, storage.type, graph.region_content[temporary.storage], event.provider_end)
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

// Whether `set` names a region this body received and has not had checked: an
// owner that arrived through a `@(cross_thread)` `move` parameter was checked
// at the call that passed it.
@(private)
prov_has_received_region :: proc(graph: ^Flow_Graph, set: Region_Set) -> bool {
	if graph.literal.signature == nil {
		return region_is_parameter_backed(set)
	}
	for id, index in graph.param_symbols {
		if !region_has_param(set, index) {
			continue
		}
		if sym := symbol_of(graph.k.c, id); sym == nil || !sym.cross_thread || sym.mode != .Move {
			return true
		}
	}
	return false
}

// Each argument's region by callee parameter, which a followed callee's
// allocator use is substituted with; nil when no argument has one.
@(private)
prov_argument_regions :: proc(graph: ^Flow_Graph, v: ^Expr_Call) -> []Region_Set {
	c := graph.k.c
	form := prov_call_form(graph, v)
	count := len(form.arguments)
	out: []Region_Set
	for argument, index in form.arguments {
		if argument == 0 || !prov_type_has_region(c, prov_value(graph, argument).type) {
			continue
		}
		set := prov_visible_region(graph, prov_used_region(graph, argument))
		region_merge(&set, prov_visible_region(graph, prov_provider_viewed_by(graph, argument)))
		if region_is_empty(set) {
			continue
		}
		if out == nil {
			out = make([]Region_Set, count, graph.alloc)
		}
		out[index] = set
	}
	// A pack built from separate arguments has no bound value: it is in its
	// elements' regions, and known to be in none when they have none, so a
	// callee using it does not read as using an unknown region.
	if call_packs(v, v.variadic_slot) && v.variadic_slot < count {
		pack := Region_Set{}
		for element in form.pack {
			if element == 0 || !prov_type_has_region(c, prov_value(graph, element).type) {
				continue
			}
			region_merge(&pack, prov_visible_region(graph, prov_used_region(graph, element)))
		}
		if out == nil {
			out = make([]Region_Set, count, graph.alloc)
		}
		out[v.variadic_slot] = pack
	}
	return out
}

// The allocator use of a call the summaries do not follow into a body: a
// builtin, a compiler-supplied member, a foreign procedure, or a conversion.
// A followed call's, direct or through a value, comes from what its callees'
// summaries settle to. Either way an owner copied from a place may be cloned
// for the call.
@(private)
prov_call_allocator_use :: proc(graph: ^Flow_Graph, v: ^Expr_Call) {
	c := graph.k.c
	if !prov_tracks_allocator_use(graph) || v.dispatch != nil {
		return
	}
	builtin := Builtin_Kind.None
	if sym := symbol_of(c, v.resolution.symbol); sym != nil {
		builtin = sym.builtin
	}
	// `drop` and `free_all` note their operand where they are walked.
	if builtin == .Drop || builtin == .Free_All {
		return
	}
	// A supplied member changes storage only as a growing or shrinking
	// container operation does.
	member := symbol_of(c, v.resolution.chosen_overload)
	supplied := member != nil && member.synth != .None
	changes_storage := !supplied || (member.synth == .Container_Op && .Allocates in CONTAINER_OP_EFFECTS[member.container_op])
	followed := call_follows_bodies(c, v)
	info := underlying_info(c, call_proc_type(c, v))
	// A text operation borrows its operands rather than copying them.
	_, text := v.operation.(Call_Text)
	_, conversion := v.operation.(Call_Text_Conversion)
	text ||= conversion
	allocators := Region_Set{}
	for argument, index in prov_call_form(graph, v).arguments {
		if argument == 0 {
			continue
		}
		value := prov_value(graph, argument)
		type := value.type
		span := expr_span(value.origin)
		mode := param_mode_at(info, index)
		owns := type_owns_allocation(c, type)
		switch {
		case !text && mode == .Value && clone_may_allocate(c, type) && expression_is_borrowed_place(value.origin):
			prov_note_allocator_use(graph, Region_Set{}, span, owned = true)
		case followed:
		case type_underlying(c, type) == TYPE_ALLOCATOR:
			set := prov_used_region(graph, argument)
			region_merge(&allocators, set)
			prov_note_allocator_use(graph, set, span)
		case !changes_storage:
		case owns && (mode == .Inout || mode == .Move):
			prov_note_allocator_use(graph, prov_storage_region(graph, argument), span, owned = true)
		case !supplied && carrier_is_mutable(c, type) && !type_is_region_provider(c, type):
			if set := prov_viewed_region(graph, argument); !region_is_empty(set) {
				prov_note_allocator_use(graph, set, span)
			}
		}
	}
	if followed || type_is_region_provider(c, prov_type(graph, v)) {
		return
	}
	// An owner a builtin or a supplied member makes, such as `make`'s, `box`'s,
	// or a clone, comes from the allocator it is given or the default.
	allocates := builtin == .Unsafe_New || builtin == .Unsafe_Try_New || builtin == .Unsafe_Free
	if type_owns_allocation(c, prov_type(graph, v)) || allocates {
		prov_note_allocator_use(graph, allocators, v.span, owned = true)
	}
}

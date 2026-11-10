// What a body's thread summaries collect: what it reaches, and which allocator
// regions it uses (design.md "Allocators and tasks").
package lokec

import "core:math/bits"

// compiler-architecture.md "Ownership, lifecycle, and provenance": facts
// recorded while thread summaries collect, and inside a `parallel` block, so no
// other pass pays for them.

// What `carriers` hold is reached here; the reach effect resolves it to the
// globals whose stored carriers those are. Returns `carriers`.
@(private)
prov_reach :: proc(graph: ^Flow_Graph, carriers: []int, span: Span) -> []int {
	if (graph.k.c.thread_facts_pending || graph.parallel_depth > 0) && len(carriers) > 0 {
		prov_emit(graph, Prov_Event{kind = .Reach, sources = carriers, span = span})
	}
	return carriers
}

// A callee may read or write through anything it is given, and a call through
// a view dispatches through it.
@(private)
prov_reach_call :: proc(graph: ^Flow_Graph, callee: []int, actuals: [][]int, span: Span) {
	if !graph.k.c.thread_facts_pending && graph.parallel_depth == 0 {
		return
	}
	reached := callee
	for loans in actuals {
		reached = prov_join(graph, reached, loans)
	}
	prov_reach(graph, reached, span)
}

// The allocator-use effect: an operation here may allocate, resize, free,
// reset, or destroy in `set`. An `owned` set is an owner's, which with no
// region recorded is bound to the default provider (design.md "Allocators").
@(private)
prov_note_allocator_use :: proc(graph: ^Flow_Graph, set: Region_Set, span: Span, owned := false) {
	if !prov_tracks_allocator_use(graph) {
		return
	}
	if !graph.k.c.thread_facts_pending {
		prov_note_window_allocator_use(graph, prov_region_closure(graph, set), span)
		return
	}
	visible := prov_caller_region(graph, set)
	if owned && region_is_empty(set) {
		visible.default = true
	}
	merge_allocator_use(&prov_output(graph).allocator_use, visible)
}

// Whether allocator use is being recorded: while the thread summaries collect,
// and inside a `parallel` block once they have settled, for its reservations.
@(private)
prov_tracks_allocator_use :: proc(graph: ^Flow_Graph) -> bool {
	c := graph.k.c
	return c.thread_facts_pending || (graph.parallel_depth > 0 && c.global_writes_ready)
}

// design.md "Allocators and tasks": inside a `parallel` block, a spawned
// call's allocator use is what its task reserves, and any other is the
// parent's, checked against the reservations of the tasks that may be running.
// The default provider's region permits concurrent use, so it reserves
// nothing.
@(private)
prov_note_window_allocator_use :: proc(graph: ^Flow_Graph, set: Region_Set, span: Span) {
	if graph.task_effects {
		reserve := &graph.task_reserve
		if output := graph.materialized; output != nil { reserve = &output.task_sites[graph.task_index].reserve }
		region_merge(reserve, set)
		reserve.default = false
		return
	}
	used := set
	used.default = false
	if region_is_empty(used) {
		return
	}
	graph.has_window_event = true
	prov_emit(graph, Prov_Event{kind = .Region_Use, region = used, span = span})
}

// `set` with every local provider's parent added, as `prov_caller_region`
// finds them, but keeping the locals: two arenas over one unsynchronized
// parent share that parent's state.
@(private)
prov_region_closure :: proc(graph: ^Flow_Graph, set: Region_Set) -> Region_Set {
	out := set
	pending, seen := set.locals, u64(0)
	for pending & ~seen != 0 {
		position := bits.count_trailing_zeros(pending & ~seen)
		seen |= u64(1) << position
		if int(position) >= len(graph.provider_symbols) {
			out.unknown = true
			continue
		}
		if parent, found := graph.provider_parents[graph.provider_symbols[position]]; found {
			region_merge(&out, parent)
			pending |= parent.locals
		}
	}
	return out
}

// What a caller can name of `set`. A region this body created stands for the
// parent its provider draws blocks from: one with no parent recorded, as
// `mem.Arena.init()` has, for the default provider, and a temporary
// provider's, whose parent is not tracked, for an unknown region.
@(private)
prov_caller_region :: proc(graph: ^Flow_Graph, set: Region_Set) -> Region_Set {
	out := set
	out.unknown ||= set.crowded
	pending, seen := set.locals, u64(0)
	for pending & ~seen != 0 {
		position := bits.count_trailing_zeros(pending & ~seen)
		seen |= u64(1) << position
		provider := INVALID_SYMBOL
		if int(position) < len(graph.provider_symbols) {
			provider = graph.provider_symbols[position]
		}
		if provider == INVALID_SYMBOL {
			out.unknown = true
			continue
		}
		parent, found := graph.provider_parents[provider]
		if !found {
			out.default = true
			continue
		}
		region_merge(&out, parent)
		out.unknown ||= parent.crowded
		pending |= parent.locals
	}
	out.locals, out.crowded = 0, false
	return out
}

// `set` as this body's allocator use names it: what a caller can name while the
// thread summaries collect, and with its providers' parents once they settle.
@(private)
prov_visible_region :: proc(graph: ^Flow_Graph, set: Region_Set) -> Region_Set {
	return prov_caller_region(graph, set) if graph.k.c.thread_facts_pending else prov_region_closure(graph, set)
}

// The region an operation given `id` may use: an allocator the analysis cannot
// name, such as one read from a global, is an unknown one.
@(private)
prov_used_region :: proc(graph: ^Flow_Graph, id: Value_Id) -> Region_Set {
	set := prov_storage_region(graph, id)
	if region_is_empty(set) && type_is_allocator(graph.k.c, prov_value(graph, id).type) {
		return Region_Set{unknown = true}
	}
	return set
}

// The region a dropped value is in, for `prov_drop_effects`; nil unless
// `prov_tracks_allocator_use`.
@(private)
prov_drop_region :: proc(graph: ^Flow_Graph, e: Expr) -> Maybe(Prov_Use_Region) {
	if !prov_tracks_allocator_use(graph) || e == nil {
		return nil
	}
	return prov_input_value(graph, e)
}

@(private)
prov_symbol_drop_region :: proc(graph: ^Flow_Graph, id: Symbol_Id) -> Maybe(Prov_Use_Region) {
	if !prov_tracks_allocator_use(graph) {
		return nil
	}
	return id
}

// A non-empty container literal allocates from its destination's `via`
// allocator or the default, and a computed string, such as a concatenation,
// from the default.
@(private)
prov_note_fresh_owner :: proc(graph: ^Flow_Graph, e: Expr, via: Expr = nil) {
	if !prov_tracks_allocator_use(graph) || !type_owns_allocation(graph.k.c, prov_type(graph, e)) {
		return
	}
	set: Prov_Use_Region = Region_Set{}
	if via != nil {
		set = prov_input_value(graph, via)
	}
	prov_event(graph, Prov_Event_Allocator_Use{set, expr_span(e), true})
}

// Each argument's region by callee parameter, which a followed callee's
// allocator use is substituted with. An argument in no region, as a container
// still in its allocator-unbound zero state, is known to be in none
// (design.md "Allocators"); nil, which reads as unknown, when no argument can
// carry a region.
@(private)
prov_argument_regions :: proc(graph: ^Flow_Graph, v: ^Expr_Call) -> []Region_Set {
	form := prov_call_form(graph, v)
	count := len(form.arguments)
	out: []Region_Set
	for argument, index in form.arguments {
		if set, carries := prov_argument_region(graph, argument); carries {
			if out == nil {
				out = make([]Region_Set, count, graph.alloc)
			}
			out[index] = set
		}
	}
	// A pack built from separate arguments has no bound value: it is in its
	// elements' regions.
	if call_packs(v, v.variadic_slot) && v.variadic_slot < count {
		pack := Region_Set{}
		for element in form.pack {
			set, _ := prov_argument_region(graph, element)
			region_merge(&pack, set)
		}
		if out == nil {
			out = make([]Region_Set, count, graph.alloc)
		}
		out[v.variadic_slot] = pack
	}
	return out
}

// The region one argument value is in, with the providers it views; `carries`
// is false when its type can carry no region.
@(private = "file")
prov_argument_region :: proc(graph: ^Flow_Graph, value: Value_Id) -> (set: Region_Set, carries: bool) {
	if value == 0 || !prov_type_has_region(graph.k.c, prov_value(graph, value).type) {
		return {}, false
	}
	set = prov_visible_region(graph, prov_used_region(graph, value))
	region_merge(&set, prov_visible_region(graph, prov_provider_viewed_by(graph, value)))
	return set, true
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
	// container operation does, and a conversion, as `rawptr(p)`, never does.
	member := symbol_of(c, v.resolution.chosen_overload)
	supplied := member != nil && member.synth != .None
	_, converts := v.operation.(Call_Conversion)
	changes_storage := !converts && (!supplied || (member.synth == .Container_Op && .Allocates in CONTAINER_OP_EFFECTS[member.container_op]))
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
		case type_is_allocator(c, type):
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

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

// Interprets normalized transfer modes and paths against current facts.
package lokec

import "core:slice"

// Leaf calls and place reads still use the AST evaluation bridge until stage 4.
// Expose the checked representation captured by the normalizer, then restore it.
Prov_Value_Origin :: struct {
	base: ^Expr_Base,
	type, view, erased, widened: Type_Id,
}

@(private)
prov_open_value :: proc(graph: ^Flow_Graph, id: Value_Id) -> Prov_Value_Origin {
	value := graph.input.values[int(id)]
	base := expr_base(value.origin)
	saved := Prov_Value_Origin{base, base.type, base.view_from, base.erased_from, base.widened_from}
	base.type, base.view_from, base.erased_from, base.widened_from = value.type, value.view_from, value.erased_from, value.widened_from
	return saved
}

@(private)
prov_close_value :: proc(saved: Prov_Value_Origin) {
	saved.base.type, saved.base.view_from, saved.base.erased_from, saved.base.widened_from = saved.type, saved.view, saved.erased, saved.widened
}

@(private = "file")
prov_alias_projection :: proc(graph: ^Flow_Graph, type: Type_Id, path: []Proj_Step) -> []Proj_Step {
	out := slice.clone(path, graph.alloc)
	type := type
	for &step, index in out {
		original := path[index]
		if underlying_kind(graph.k.c, type) == .Union { step = proj_wild() }
		type = prov_type_at(graph.k.c, type, {original})
	}
	return out
}

prov_value_aliases :: proc(graph: ^Flow_Graph, id: Value_Id) -> []Written_Alias {
	value := graph.input.values[int(id)]
	transfer := graph.input.transfers[id]
	if transfer == nil {
		return prov_read_value_aliases(graph, id)
	}
	parts: []Prov_Component
	single: [1]Prov_Component
	switch operation in transfer {
	case Prov_Transfer_Forward:
		single[0] = operation.component
		parts = single[:]
	case Prov_Transfer_Join:
		parts = operation.alternatives
	case Prov_Transfer_Aggregate:
		parts = operation.components
	case Prov_Transfer_Borrow:
		prov_note_borrowed_owner(graph, id)
		return slice.clone([]Written_Alias{{target = operation.storage, at = operation.path}}, graph.alloc)
	case Prov_Transfer_Address:
		source := graph.input.values[int(operation.source)]
		if operation.storage {
			if storage, direct := source.place.base.(Storage_Id); direct {
				return slice.clone([]Written_Alias{{target = storage, at = source.place.path}}, graph.alloc)
			}
			saved := prov_open_value(graph, operation.source)
			defer prov_close_value(saved)
			out := make([dynamic]Written_Alias, graph.alloc)
			for alias in prov_written_targets(graph, source.origin, as_place = true) {
				append(&out, Written_Alias{target = alias.target, at = prov_concat_path(graph, alias.at, source.place.path)})
			}
			if len(out) == 0 { append(&out, Written_Alias{}) }
			return out[:]
		}
		out := slice.clone(prov_value_aliases(graph, operation.source), graph.alloc)
		for &alias in out { alias.path = nil }
		return out
	}
	out := make([dynamic]Written_Alias, graph.alloc)
	for part in parts {
		source := graph.input.values[int(part.source)]
		from := prov_alias_projection(graph, source.type, part.from)
		to := prov_alias_projection(graph, value.type, part.to)
		for alias in prov_value_aliases(graph, part.source) {
			if !paths_overlap(alias.path, from) { continue }
			rest := alias.path[min(len(from), len(alias.path)):]
			append(&out, Written_Alias{target = alias.target, at = alias.at, path = prov_concat_path(graph, to, rest)})
		}
		if part.uncertain_copy && prov_type_reaches_mutable(graph.k.c, part.type) {
			append(&out, Written_Alias{path = to})
		}
	}
	return out[:]
}

// design.md "Temporaries and procedure boundaries": a view of a materialized
// owner names the hidden storage holding that owner's carriers. Queries can
// discover the view first, so record that fact once for every replay round.
prov_note_borrowed_owner :: proc(graph: ^Flow_Graph, id: Value_Id) {
	borrow, ok := graph.input.transfers[id].(Prov_Transfer_Borrow)
	if !ok || !borrow.materialized { return }
	recorded := false
	if prov_effect_active(graph) && !graph.effect_program.borrowed_owners[id] {
		graph.effect_program.borrowed_owners[id] = true
		recorded = prov_effect_begin(graph, Prov_Effect_Borrow_Owner{id})
	}
	defer prov_effect_end(graph, recorded)
	for alias in prov_value_aliases(graph, borrow.owner) { prov_add_written_alias(graph, borrow.storage, alias) }
}

prov_value_region :: proc(graph: ^Flow_Graph, id: Value_Id, path: []Proj_Step, query: Region_Query) -> Region_Set {
	value := graph.input.values[int(id)]
	if transfer := graph.input.transfers[id]; transfer != nil { return prov_transfer_region(graph, transfer, path, query) }
	saved := prov_open_value(graph, id)
	defer prov_close_value(saved)
	return prov_result_region_at(graph, value.origin, path, query, value.type)
}

@(private = "file")
prov_component_region :: proc(graph: ^Flow_Graph, component: Prov_Component, path: []Proj_Step, query: Region_Query) -> Region_Set {
	source_path := prov_concat_path(graph, component.from, path)
	if component.mode != .Clone && component.mode != .Copy { return prov_value_region(graph, component.source, source_path, query) }
	allocator := Region_Set{default = true}
	if component.allocator != 0 { allocator = prov_value_region(graph, component.allocator, nil, .All) }
	return prov_copy_component_region(graph, component, path, query, allocator)
}

prov_copy_component_region :: proc(graph: ^Flow_Graph, component: Prov_Component, path: []Proj_Step,
                                   query: Region_Query, allocator: Region_Set) -> Region_Set {
	source := graph.input.values[int(component.source)]
	saved := prov_open_value(graph, component.source)
	defer prov_close_value(saved)
	selected := prov_concat_path(graph, component.from, path)
	return prov_copied_region_at(graph, Prov_Region_Copy{value = source.origin, prefix = component.copy_from,
	                             as_type = source.type, allocator = allocator}, component.copy.type,
	                             selected[len(component.copy_from):], query)
}

prov_transfer_region :: proc(graph: ^Flow_Graph, transfer: Prov_Transfer, path: []Proj_Step, query: Region_Query) -> Region_Set {
	out := prov_empty_region(graph)
	parts: []Prov_Component
	backing: []Prov_Backing
	single: [1]Prov_Component
	switch operation in transfer {
	case Prov_Transfer_Forward:
		single[0] = operation.component
		parts = single[:]
	case Prov_Transfer_Join:
		parts = operation.alternatives
	case Prov_Transfer_Aggregate:
		parts, backing = operation.components, operation.backing
	case Prov_Transfer_Borrow:
		if len(path) == 0 && query == .All { return prov_value_region(graph, operation.owner, nil, .All) }
		return prov_value_region(graph, operation.owner, prov_concat_path(graph, operation.path, path), query)
	case Prov_Transfer_Address:
		// The descriptor is a borrow, not an owner of the addressed allocation.
		// Reads through it query its backing storage via the ordinary place path.
		return out
	}
	for allocation in backing {
		if !paths_overlap(allocation.path, path) || len(path) > len(allocation.path) { continue }
		if query == .Own && !prov_same_path(path, allocation.path) { continue }
		if allocation.allocator == 0 { out.default = true
		} else { region_merge(&out, prov_value_region(graph, allocation.allocator, nil, .All)) }
	}
	for component in parts {
		if !paths_overlap(component.to, path) { continue }
		if len(path) < len(component.to) && query == .Own { continue }
		selected := path[min(len(path), len(component.to)):]
		region_merge(&out, prov_component_region(graph, component, selected, query))
	}
	return out
}

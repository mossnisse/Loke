// Interprets normalized transfers and their paths against current facts.
package lokec

import "core:slice"

@(private = "file")
prov_alias_projection :: proc(graph: ^Flow_Graph, type: Type_Id, path: []Proj_Step) -> []Proj_Step {
	out := slice.clone(path, graph.alloc)
	type := type
	for step, index in path {
		if underlying_kind(graph.k.c, type) == .Union { out[index] = proj_wild() }
		type = prov_type_at(graph.k.c, type, {step})
	}
	return out
}

prov_value_aliases :: proc(graph: ^Flow_Graph, id: Value_Id) -> []Written_Alias {
	transfer := prov_value_transfer(graph, id)
	if transfer == nil {
		return prov_place_aliases(graph, id, unresolved = true)
	}
	#partial switch operation in transfer {
	case Prov_Transfer_Borrow:
		prov_note_borrowed_owner(graph, id)
		return slice.clone([]Written_Alias{{target = operation.storage, at = operation.path}}, graph.alloc)
	case Prov_Transfer_Address:
		source := prov_value(graph, operation.source)
		if operation.storage {
			if storage, direct := source.place.base.(Storage_Id); direct {
				return slice.clone([]Written_Alias{{target = storage, at = source.place.path}}, graph.alloc)
			}
			out := make([dynamic]Written_Alias, graph.alloc)
			for alias in prov_written_targets(graph, operation.source, as_place = true) {
				append(&out, Written_Alias{target = alias.target, at = prov_concat_path(graph, alias.at, source.place.path), loaded = alias.loaded, precision = alias.precision})
			}
			if len(out) == 0 { append(&out, Written_Alias{}) }
			return out[:]
		}
		// Every path here builds a fresh slice, so this clears no stored fact.
		out := prov_value_aliases(graph, operation.source)
		for &alias in out { alias.path = nil }
		return out
	}
	value := prov_value(graph, id)
	out := make([dynamic]Written_Alias, graph.alloc)
	for part in transfer.(Prov_Transfer_Parts).components {
		aliases := prov_value_aliases(graph, part.source)
		// The bounded target analysis cannot prove a copied payload has only its
		// source's targets. This is a transfer policy, not an alias set.
		uncertain := part.copy_type != INVALID_TYPE && prov_type_reaches_mutable(graph.k.c, part.copy_type)
		if len(aliases) == 0 && !uncertain { continue }
		from := prov_alias_projection(graph, prov_value(graph, part.source).type, part.from)
		to := prov_alias_projection(graph, value.type, part.to)
		for alias in aliases {
			if !paths_overlap(alias.path, from) { continue }
			rest := alias.path[min(len(from), len(alias.path)):]
			append(&out, Written_Alias{target = alias.target, at = alias.at, path = prov_concat_path(graph, to, rest), loaded = alias.loaded, precision = alias.precision})
		}
		if uncertain {
			append(&out, Written_Alias{path = to})
		}
	}
	return out[:]
}

// design.md "Temporaries and procedure boundaries": a view of a materialized
// owner names the hidden storage holding that owner's carriers. Queries can
// discover the view first, so record that fact once for every replay round.
prov_note_borrowed_owner :: proc(graph: ^Flow_Graph, id: Value_Id) {
	borrow, ok := prov_value_transfer(graph, id).(Prov_Transfer_Borrow)
	if !ok || !borrow.materialized { return }
	recorded := prov_effect_active(graph) && !graph.effect_program.borrowed_owners[id]
	if recorded {
		graph.effect_program.borrowed_owners[id] = true
		prov_effect_begin(graph, Prov_Effect_Borrow_Owner{id})
	}
	defer prov_effect_end(graph, recorded)
	for alias in prov_value_aliases(graph, borrow.owner) { prov_add_written_alias(graph, borrow.storage, alias) }
}

// The region of an allocator operand; a zero one selects the default.
@(private = "file")
prov_allocator_region :: proc(graph: ^Flow_Graph, allocator: Value_Id) -> Region_Set {
	if allocator == 0 { return Region_Set{default = true} }
	return prov_result_region_at(graph, allocator, nil, .All)
}

@(private = "file")
prov_component_region :: proc(graph: ^Flow_Graph, component: Prov_Component, path: []Proj_Step, query: Region_Query) -> Region_Set {
	if component.copy_type == INVALID_TYPE {
		return prov_result_region_at(graph, component.source, prov_concat_path(graph, component.from, path), query)
	}
	return prov_copy_component_region(graph, component, path, query, prov_allocator_region(graph, component.allocator))
}

prov_copy_component_region :: proc(graph: ^Flow_Graph, component: Prov_Component, path: []Proj_Step,
                                   query: Region_Query, allocator: Region_Set) -> Region_Set {
	selected := prov_concat_path(graph, component.from, path)
	return prov_copied_region_at(graph, Prov_Region_Copy{value = component.source, prefix = component.copy_from,
	                             as_type = prov_value(graph, component.source).type, allocator = allocator}, component.copy_type,
	                             selected[len(component.copy_from):], query)
}

prov_transfer_region :: proc(graph: ^Flow_Graph, transfer: Prov_Transfer, path: []Proj_Step, query: Region_Query) -> Region_Set {
	out := Region_Set{}
	switch operation in transfer {
	case Prov_Transfer_Borrow:
		if len(path) == 0 && query == .All { return prov_result_region_at(graph, operation.owner, nil, .All) }
		// `operation.path` is the storage's. A named owner stands at that place,
		// so only a box's step lies below it; hidden storage holds the owner whole.
		below := operation.path
		if !operation.materialized { below = below[len(prov_value(graph, operation.owner).place.path):] }
		return prov_result_region_at(graph, operation.owner, prov_concat_path(graph, below, path), query)
	case Prov_Transfer_Address:
		// The descriptor is a borrow, not an owner of the addressed allocation.
		// Reads through it query its backing storage via the ordinary place path.
	case Prov_Transfer_Parts:
		for allocation in operation.backing {
			if !paths_overlap(allocation.path, path) || len(path) > len(allocation.path) { continue }
			if query == .Own && !prov_same_path(path, allocation.path) { continue }
			region_merge(&out, prov_allocator_region(graph, allocation.allocator))
		}
		for component in operation.components {
			if !paths_overlap(component.to, path) { continue }
			if len(path) < len(component.to) && query == .Own { continue }
			selected := path[min(len(path), len(component.to)):]
			region_merge(&out, prov_component_region(graph, component, selected, query))
		}
	}
	return out
}

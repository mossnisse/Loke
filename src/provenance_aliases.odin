// Written aliases: what a local's carriers may reach, so a store through one
// lands in that storage (design.md "Allocator regions and region provenance").
package lokec

import "core:slice"

// What a local's carriers may reach: a writable parameter's storage, or a
// variable's place, at `at` in it, that `&mut place` or `place[:]` lent. `path` is
// where in the local those carriers are held; nil when the whole local may
// hold them. A zero target is an unresolved alternative, not an empty set. A
// target is the storage it names, not the targets of carriers inside that
// storage.
Written_Alias :: struct {
	target: Storage_Id,
	at:     []Proj_Step,
	path:   []Proj_Step,
}

// Region field shapes also stop at eight projections. A recursive cursor can
// keep extending its target path across passes; retain a conservative prefix
// so that target facts converge (design.md "Minimum provenance precision").
WRITTEN_ALIAS_DEPTH :: 8

// The storage a write through `destination` may land in, as `p^`, `p.x`, or
// `p[i]` reach it: a parameter's, directly or through a local set from one,
// or a local place a local carrier was set to point at.
@(private)
prov_written_targets :: proc(graph: ^Flow_Graph, destination: Value_Id, as_place := false) -> []Written_Alias {
	carrier := destination
	value := prov_value(graph, destination)
	if as_place || !type_is_carrier(graph.k.c, value.type) {
		if through := prov_place_carrier(graph, destination); through != 0 {
			carrier = through
		} else if as_place && value.temporary && !type_is_carrier(graph.k.c, value.type) {
			storage := prov_storage_id(graph, Written_Storage{temporary = expr_base(value.origin), type = value.type})
			prov_note_alias_source(graph, storage, destination, nil)
			return slice.clone([]Written_Alias{{target = storage}}, graph.alloc)
		}
	}
	out := make([dynamic]Written_Alias, 0, 2, graph.alloc)
	for alias in prov_place_aliases(graph, carrier, unresolved = false) {
		known := false
		for seen in out {
			known ||= seen.target == alias.target && prov_same_path(seen.at, alias.at)
		}
		if !known {
			append(&out, Written_Alias{target = alias.target, at = alias.at})
		}
	}
	return out[:]
}

// What the carriers in the storage `id` names or reads through may reach, each
// with its path below that storage (design.md "Minimum provenance precision").
// A read through a carrier first selects its storage, then loads the carriers
// held there; it does not conflate successive levels of indirection. With
// `unresolved`, as for a read rather than a write's targets, a value that finds
// nothing at all is also unresolved when it may find storage no write named.
@(private)
prov_place_aliases :: proc(graph: ^Flow_Graph, id: Value_Id, unresolved: bool) -> []Written_Alias {
	if id == 0 { return nil }
	if prov_value_transfer(graph, id) != nil { return prov_value_aliases(graph, id) }
	value := prov_value(graph, id)
	aliases: []Written_Alias
	switch base in value.place.base {
	case Storage_Id:
		aliases = prov_written_aliases_of(graph, base, value.place.path)
	case Value_Id:
		aliases = prov_load_aliases(graph, prov_place_aliases(graph, base, unresolved), value.place.path, value.unknown_alias)
	case:
		aliases = prov_place_aliases(graph, prov_read_fallback(value.form), unresolved)
	}
	if unresolved && value.unknown_alias && len(aliases) == 0 {
		return make([]Written_Alias, 1, graph.alloc)
	}
	return aliases
}

// What a value that is no place reads from: the operand a projection of a
// temporary forwards, or the call a user operator is (design.md "Operator
// declarations").
@(private = "file")
prov_read_fallback :: proc(value_form: Prov_Form) -> Value_Id {
	#partial switch form in value_form {
	case Prov_Form_Selector: return form.operand
	case Prov_Form_Index:    return form.operator != 0 ? form.operator : form.operand
	case Prov_Form_Postfix:  return form.operand
	}
	return 0
}

// design.md "Minimum provenance precision": what a load through a carrier
// reaches, from each of the carrier's `targets`, at `path` below it. Each
// possible source contributes known targets or, when `unknown` says the read
// may find storage no write named, an unresolved alternative, even beside
// another source's known targets.
@(private = "file")
prov_load_aliases :: proc(graph: ^Flow_Graph, targets: []Written_Alias, path: []Proj_Step, unknown: bool) -> []Written_Alias {
	out := make([dynamic]Written_Alias, graph.alloc)
	for target in targets {
		if target.target == 0 {
			append(&out, target)
			continue
		}
		loaded := prov_written_aliases_of(graph, target.target, prov_concat_path(graph, target.at, path))
		if len(loaded) == 0 && unknown { append(&out, Written_Alias{})
		} else { append(&out, ..loaded) }
	}
	return out[:]
}

@(private)
prov_written_aliases_of :: proc(graph: ^Flow_Graph, id: Storage_Id, path: []Proj_Step) -> []Written_Alias {
	if sym := symbol_of(graph.k.c, prov_storage(graph, id).key.symbol); sym != nil && sym.kind == .Parameter && param_writes_caller(graph.k.c, sym) {
		return slice.clone([]Written_Alias{{target = id}}, graph.alloc)
	}
	out := make([dynamic]Written_Alias, 0, 2, graph.alloc)
	for alias in graph.region_aliases[prov_storage(graph, id).key.symbol] {
		if alias.root == NO_ROOT {
			append(&out, Written_Alias{})
		} else {
			append(&out, ..prov_written_aliases_of(graph, prov_storage_for_root(graph, alias.root), prov_concat_path(graph, alias.path, path)))
		}
	}
	for alias in graph.written_aliases[id] {
		if !paths_overlap(alias.path, path) {
			continue
		}
		// What lies below the asked-for storage keeps its place there.
		rest: []Proj_Step
		if len(alias.path) > len(path) {
			rest = alias.path[len(path):]
		}
		append(&out, Written_Alias{target = alias.target, at = alias.at, path = rest})
	}
	return out[:]
}

// design.md "Allocator regions and region provenance": a local set from a
// writable parameter's storage or from `&mut place` reaches it, through
// whichever operand supplies it. `path` is where in the local the value is
// stored, `type` the type stored there, and `source` the field of the value a
// destructuring binds.
@(private)
prov_note_written_alias :: proc(graph: ^Flow_Graph, local: Symbol_Id, value: Expr, path: []Proj_Step = nil, type := INVALID_TYPE, source: []Proj_Step = nil) {
	c := graph.k.c
	sym := symbol_of(c, local)
	if value == nil || sym == nil || sym.kind != .Var || sym.duration != .None {
		return
	}
	stored := type == INVALID_TYPE ? sym.type : type
	if !type_carries_borrow(c, stored).any {
		return
	}
	prov_note_alias_source(graph, prov_storage_id(graph, Written_Storage{symbol = local}), prov_input_value(graph, value), path, source)
}

// Records what `value` holds at `source` of writable parameters at `prefix` in
// `local`: a literal's fields at their own paths, so one field's carrier is not
// another's, and of a destructured record only the binding's field (design.md
// "Minimum provenance precision").
@(private)
prov_note_alias_source :: proc(graph: ^Flow_Graph, local: Storage_Id, value: Value_Id, prefix: []Proj_Step, source: []Proj_Step = nil) {
	type := prov_value(graph, value).type
	recorded := prov_effect_active(graph) && value != 0 && type_carries_borrow(graph.k.c, type).any
	if recorded { prov_effect_begin(graph, Prov_Effect_Targets{local, value, prov_effect_path(graph, prefix), prov_effect_path(graph, source)}) }
	defer prov_effect_end(graph, recorded)
	if value == 0 { return }
	for alias in prov_value_aliases(graph, value) {
		if !paths_overlap(alias.path, source) { continue }
		rest := alias.path[min(len(source), len(alias.path)):]
		prov_add_written_alias(graph, local, Written_Alias{target = alias.target, at = alias.at,
		                       path = prov_concat_path(graph, prefix, rest)})
	}
}

@(private)
prov_alias_source_is_unknown :: proc(c: ^Compiler, type: Type_Id, value: Expr) -> bool {
	if !type_carries_borrow(c, type).any { return false }
	// make's zero elements contain no incoming carriers.
	if call, ok := value.(^Expr_Call); ok {
		if sym := symbol_of(c, call.resolution.symbol); sym != nil && (sym.builtin == .Make || sym.builtin == .Try_Make) { return false }
	}
	return true
}

@(private)
prov_add_written_alias :: proc(graph: ^Flow_Graph, local: Storage_Id, alias: Written_Alias) {
	alias := alias
	if alias.target == 0 {
		alias.at = nil // uncertainty has no storage path to extend
	}
	paths := [2]^[]Proj_Step{&alias.at, &alias.path}
	for path in paths {
		if len(path^) >= WRITTEN_ALIAS_DEPTH {
			path^ = slice.clone(path^[:WRITTEN_ALIAS_DEPTH], graph.alloc)
			path^[WRITTEN_ALIAS_DEPTH - 1].precision += {.Depth}
		}
	}
	existing := graph.written_aliases[local]
	for known in existing {
		if known.target == alias.target && prov_same_path(known.at, alias.at) && prov_same_path(known.path, alias.path) {
			return
		}
	}
	grown := make([]Written_Alias, len(existing) + 1, graph.alloc)
	copy(grown, existing)
	grown[len(existing)] = Written_Alias {
		target = alias.target,
		at     = slice.clone(alias.at, graph.alloc),
		path   = slice.clone(alias.path, graph.alloc),
	}
	graph.written_aliases[local] = grown
}

// A call may replace writable carrier storage without a source expression in
// this body. Keep an unresolved alternative there, including through nested
// carriers (design.md "Allocator regions and region provenance").
@(private)
prov_call_written_aliases :: proc(graph: ^Flow_Graph, id: Value_Id) {
	form := prov_value(graph, id).form.(Prov_Form_Call)
	call := form.call
	recorded := prov_effect_active(graph) && prov_input_call(graph, call).writes_facts
	if recorded { prov_effect_begin(graph, Prov_Effect_Call{id, .Invalidate}) }
	defer prov_effect_end(graph, recorded)
	c := graph.k.c
	info := underlying_info(c, call_proc_type(c, call))
	if info == nil { return }
	seen := make([dynamic]Written_Alias_Visit, graph.alloc)
	for argument, index in prov_bound_values(form) {
		if index >= len(info.parameters) { continue }
		if call_packs(call, index) {
			// Separate elements at the element type, then spreads at the pack's.
			element := underlying_info(c, info.parameters[index]).element
			for value, position in form.pack { if !call.variadic_order[position] { prov_forget_argument_aliases(graph, value, element, false, &seen) } }
			for value, position in form.pack { if call.variadic_order[position] { prov_forget_argument_aliases(graph, value, info.parameters[index], false, &seen) } }
			continue
		}
		inout := index < len(info.param_modes) && info.param_modes[index] == .Inout
		prov_forget_argument_aliases(graph, argument, info.parameters[index], inout, &seen)
	}
}

// The effective parameter capability applies to the normalized value's paths.
@(private = "file")
prov_forget_argument_aliases :: proc(
	graph: ^Flow_Graph, id: Value_Id, parameter: Type_Id, inout: bool, seen: ^[dynamic]Written_Alias_Visit,
) {
	if id == 0 { return }
	c := graph.k.c
	if !inout && !carrier_is_mutable(c, parameter) && !prov_type_reaches_mutable(c, parameter) { return }
	if inout { prov_forget_place_aliases(graph, id, seen); return }
	aliases := prov_value_aliases(graph, id)
	for carrier in carrier_shape(c, parameter) {
		for alias in aliases {
			if paths_overlap(alias.path, carrier.steps) {
				prov_forget_storage_aliases(graph, alias.target, alias.at, carrier.mutable, seen)
			}
		}
	}
}

Written_Alias_Visit :: struct {
	target: Storage_Id,
	path: []Proj_Step,
	writable: bool,
}

// `path`, cut to the depth aliases keep, and whether this is the first visit to
// that place of `target` with this capability.
@(private)
prov_first_alias_visit :: proc(seen: ^[dynamic]Written_Alias_Visit, target: Storage_Id, path: []Proj_Step, writable: bool) -> (bounded: []Proj_Step, first: bool) {
	bounded = path[:min(len(path), WRITTEN_ALIAS_DEPTH)]
	for visit in seen^ {
		if visit.target == target && visit.writable == writable && prov_same_path(visit.path, bounded) { return bounded, false }
	}
	append(seen, Written_Alias_Visit{target, bounded, writable})
	return bounded, true
}

@(private = "file")
prov_forget_place_aliases :: proc(graph: ^Flow_Graph, place: Value_Id, seen: ^[dynamic]Written_Alias_Visit) {
	if root, path, ok := prov_value_place_of(graph, place); ok {
		prov_forget_storage_aliases(graph, prov_storage_for_root(graph, root), path, true, seen)
		return
	}
	if prov_place_carrier(graph, place) == 0 {
		// A temporary literal has no named storage, but the carriers it holds
		// still reach caller storage through their own capabilities.
		prov_forget_argument_aliases(graph, place, prov_value(graph, place).type, false, seen)
		return
	}
	below := prov_path_below_carrier(graph, place)
	for alias in prov_written_targets(graph, place, as_place = true) {
		prov_forget_storage_aliases(graph, alias.target, prov_concat_path(graph, alias.at, below), true, seen)
	}
}

@(private = "file")
prov_forget_storage_aliases :: proc(
	graph: ^Flow_Graph, target: Storage_Id, storage: []Proj_Step, writable: bool, seen: ^[dynamic]Written_Alias_Visit,
) {
	type := prov_storage(graph, target).type
	if type == INVALID_TYPE { return }
	path, first := prov_first_alias_visit(seen, target, storage, writable)
	if !first { return }
	for alias in graph.region_aliases[prov_storage(graph, target).key.symbol] {
		if alias.root != NO_ROOT {
			prov_forget_storage_aliases(graph, prov_storage_for_root(graph, alias.root),
			                           prov_concat_path(graph, alias.path, path), writable, seen)
		}
	}
	for carrier in carrier_shape(graph.k.c, prov_type_at(graph.k.c, type, path)) {
		at := prov_concat_path(graph, path, carrier.steps)
		previous := prov_written_aliases_of(graph, target, at)
		if writable && (carrier.truncated || prov_type_reaches_mutable(graph.k.c, carrier.type)) {
			prov_add_written_alias(graph, target, Written_Alias{path = at})
		}
		for alias in previous {
			prov_forget_storage_aliases(graph, alias.target, alias.at, carrier.mutable, seen)
		}
	}
}

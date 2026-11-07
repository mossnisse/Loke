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
	// `target` is a parameter standing for what its carriers lead to, reached by a load
	// through it, and not the storage it names itself: `at` says nothing of where.
	loaded: bool,
	// The analysis budget that merged this target in, as a result read past the loads
	// a summary keeps: a store landing here only through it may not land here at all
	// (design.md "Minimum provenance precision").
	precision: Precision_Loss,
}

// Region field shapes also stop here. A recursive cursor can keep extending its
// target path across passes; retain a conservative prefix so that target facts
// converge (design.md "Minimum provenance precision").
WRITTEN_ALIAS_DEPTH :: REGION_SHAPE_DEPTH

// The storage a write through `destination` may land in, as `p^`, `p.x`, or
// `p[i]` reach it: a parameter's, directly or through a local set from one,
// or a local place a local carrier was set to point at. With `held`, each keeps
// where in `destination` the carrier leading there is, which a record passed by
// value tells apart (`prov_contents_held_at`).
@(private)
prov_written_targets :: proc(graph: ^Flow_Graph, destination: Value_Id, as_place := false, held := false) -> []Written_Alias {
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
		path := held ? alias.path : nil
		known := false
		for &seen in out {
			if seen.target == alias.target && prov_same_path(seen.at, alias.at) && prov_same_path(seen.path, path) {
				// Found without a budget once, it is not merged in.
				seen.precision &= alias.precision
				known = true
			}
		}
		if !known {
			append(&out, Written_Alias{target = alias.target, at = alias.at, path = path, loaded = alias.loaded, precision = alias.precision})
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
		if _, is_call := value.form.(Prov_Form_Call); is_call {
			aliases = prov_call_result_aliases(graph, id)
		} else {
			aliases = prov_place_aliases(graph, prov_read_fallback(value.form), unresolved)
		}
	}
	if unresolved && value.unknown_alias && len(aliases) == 0 {
		return make([]Written_Alias, 1, graph.alloc)
	}
	return aliases
}

// design.md "Procedure result contracts": what a call's result may point at, by
// what the callee's summary says it takes of each argument, which the caller knows
// the targets of. A result the summary cannot tie to arguments alone, or one with
// no summary yet, keeps an unresolved alternative: a walk over what it finds would
// otherwise take the arguments' targets for all of them.
@(private = "file")
prov_call_result_aliases :: proc(graph: ^Flow_Graph, id: Value_Id) -> []Written_Alias {
	c := graph.k.c
	form := prov_value(graph, id).form.(Prov_Form_Call)
	arguments := prov_bound_values(form)
	// design.md "Shared ownership": `get()` lends what the handle holds, which the
	// body cannot show through its `rawptr`, so the provider is the handle's place.
	if prov_receiver_is_shared_handle(graph, form.call) && len(arguments) > 0 {
		handle := prov_value(graph, arguments[0])
		if root, path, ok := prov_root_place(graph, handle.place); ok {
			return slice.clone([]Written_Alias{{target = prov_storage_for_root(graph, root), at = path}}, graph.alloc)
		}
		return nil
	}
	summary, found := result_summary(c, call_contract_declaration(c, form.call))
	if !found || summary.unknown {
		return nil
	}
	// Each result path keeps what it takes, so that a field of the result reaches
	// what that field was given and not what its siblings were.
	if summary.content_type == prov_value(graph, id).type && len(summary.content) > 0 {
		out := make([dynamic]Written_Alias, graph.alloc)
		for content in summary.content {
			for alias in prov_dependency_aliases(graph, form, arguments, content.dependencies) {
				append(&out, Written_Alias{target = alias.target, at = alias.at, path = content.path.steps, precision = alias.precision})
			}
		}
		return out[:]
	}
	return prov_dependency_aliases(graph, form, arguments, summary.dependencies)
}

// What one result path may point at, by what `dependencies` take of each argument.
// Where the result holds it is the caller's to say.
@(private = "file")
prov_dependency_aliases :: proc(graph: ^Flow_Graph, form: Prov_Form_Call, arguments: []Value_Id, dependencies: Result_Dependencies) -> []Written_Alias {
	out := make([dynamic]Written_Alias, graph.alloc)
	if dependencies.static || dependencies.thread || dependencies.local || len(dependencies.globals) > 0 {
		append(&out, Written_Alias{})
	}
	for index in 0 ..< min(len(arguments), len(dependencies.params)) {
		held := prov_value_aliases(graph, arguments[index])
		if dependencies.params[index] {
			append(&out, ..prov_result_taken_aliases(graph, form, dependencies, index, held))
		}
		append(&out, ..prov_result_loaded_aliases(graph, form, dependencies, index, held))
	}
	for &alias in out { alias.path = nil }
	return out[:]
}

// What the result may hold of what is read through argument `index`, whose first
// load goes along the summary's paths of the pointee and the rest below them, as
// `prov_substitute_result` reads loans.
@(private = "file")
prov_result_loaded_aliases :: proc(graph: ^Flow_Graph, form: Prov_Form_Call, dependencies: Result_Dependencies, index: int, held: []Written_Alias) -> []Written_Alias {
	out := make([dynamic]Written_Alias, graph.alloc)
	shape := prov_parameter_pointee_shape(graph, form.call, index)
	follow := proc(graph: ^Flow_Graph, held: []Written_Alias, route: Load_Route, depth: int, out: ^[dynamic]Written_Alias) {
		loaded := prov_load_aliases(graph, held, route.first, unknown = true)
		for at in 2 ..= depth {
			loaded = prov_load_aliases(graph, loaded, at == depth ? route.last : nil, unknown = true)
		}
		append(out, ..loaded)
		// A summary keeps `CARRIER_DEPTH` loads; its last stands for every depth
		// from its own on, as the content loan it records does (`deeper_content_loan`),
		// so a result read through more loads may hold what any load below reaches.
		if depth >= CARRIER_DEPTH {
			append(out, ..prov_load_aliases_below(graph, loaded))
		}
	}
	for depth in 1 ..= 8 {
		if dependencies.param_loads[index] & (u8(1) << u8(depth - 1)) == 0 {
			continue
		}
		for route in result_load_routes(graph.k.c, dependencies, index, depth, shape, graph.alloc) {
			follow(graph, held, route, depth, &out)
		}
	}
	return out[:]
}

// What loads through `targets` reach at every depth below them, each place once.
// The summary names none of them, so each is merged in by its load budget.
@(private = "file")
prov_load_aliases_below :: proc(graph: ^Flow_Graph, targets: []Written_Alias) -> []Written_Alias {
	out := make([dynamic]Written_Alias, graph.alloc)
	seen := make(Written_Alias_Visits, graph.alloc)
	frontier := targets
	for len(frontier) > 0 {
		next := make([dynamic]Written_Alias, graph.alloc)
		for alias in prov_load_aliases(graph, frontier, nil, unknown = true) {
			alias := alias
			alias.precision += {.Depth}
			if alias.target != 0 {
				if _, first := prov_first_alias_visit(graph, &seen, alias.target, alias.at, false); !first { continue }
				append(&next, alias)
			}
			append(&out, alias)
		}
		frontier = next[:]
	}
	return out[:]
}

// Of what argument `index` holds, the carriers the result may take: those the
// summary's paths of the parameter's shape name, or all of them.
@(private = "file")
prov_result_taken_aliases :: proc(graph: ^Flow_Graph, form: Prov_Form_Call, dependencies: Result_Dependencies, index: int, held: []Written_Alias) -> []Written_Alias {
	c := graph.k.c
	paths := dependencies.param_paths[index]
	info := underlying_info(c, call_proc_type(c, form.call))
	if paths == nil || info == nil || index >= len(info.parameters) {
		return held
	}
	shape := carrier_shape(c, info.parameters[index])
	if len(shape) != len(paths) {
		return held
	}
	out := make([dynamic]Written_Alias, 0, len(held), graph.alloc)
	for alias in held {
		for carrier, position in shape {
			if paths[position] && paths_overlap(alias.path, carrier.steps) {
				append(&out, alias)
				break
			}
		}
	}
	return out[:]
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
		for &alias in loaded {
			alias.loaded ||= prov_target_stands_for_caller(graph, alias.target)
			alias.precision |= target.precision
		}
		if len(loaded) == 0 && unknown { append(&out, Written_Alias{})
		} else { append(&out, ..loaded) }
	}
	return out[:]
}

// A record a parameter takes by value: its own storage is nothing the caller can see.
@(private)
prov_parameter_is_record_by_value :: proc(c: ^Compiler, mode: Param_Mode, type: Type_Id) -> bool {
	return mode == .Value && !type_is_carrier(c, type)
}

// design.md "Minimum provenance precision": which of its carriers a read at `path`
// of what a parameter names goes through. A carrier keeps no region where it is held
// (`prov_store_keeps_region`), so what a body leaves at a carrier's path, or below it,
// went through that carrier, and a call lands it only where its argument's carrier at
// that path leads (`prov_contents_held_at`).
@(private = "file")
prov_parameter_carrier_path :: proc(c: ^Compiler, sym: ^Symbol, path: []Proj_Step) -> []Proj_Step {
	for length in 1 ..< len(path) {
		if type_is_carrier(c, prov_parameter_type_at(c, sym, path[:length])) {
			return path[:length]
		}
	}
	return path
}

// Whether `target` is a writable parameter, which holds no aliases of its own.
@(private = "file")
prov_target_stands_for_caller :: proc(graph: ^Flow_Graph, target: Storage_Id) -> bool {
	sym := symbol_of(graph.k.c, prov_storage(graph, target).key.symbol)
	return sym != nil && sym.kind == .Parameter && param_writes_caller(graph.k.c, sym)
}

@(private)
prov_written_aliases_of :: proc(graph: ^Flow_Graph, id: Storage_Id, path: []Proj_Step) -> []Written_Alias {
	if prov_target_stands_for_caller(graph, id) {
		sym := symbol_of(graph.k.c, prov_storage(graph, id).key.symbol)
		return slice.clone([]Written_Alias{{target = id, at = prov_parameter_carrier_path(graph.k.c, sym, path)}}, graph.alloc)
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
		// What lies below the asked-for storage keeps its place there. A path
		// asked below the carrier the local holds goes on in the storage that
		// carrier points at, as `p^[0].second` does (`prov_store_region_through`),
		// rather than standing for all of it.
		rest: []Proj_Step
		at := alias.at
		if len(alias.path) > len(path) {
			rest = alias.path[len(path):]
		} else if len(path) > len(alias.path) && prov_alias_at_carrier(graph, id, alias) {
			at = prov_concat_path(graph, alias.at, path[len(alias.path):])
		}
		append(&out, Written_Alias{target = alias.target, at = at, path = rest, loaded = alias.loaded, precision = alias.precision})
	}
	return out[:]
}

// Whether `alias.path` in the local `id` is the very carrier pointing at `alias.at`,
// so the steps below it name places in its target. A path cut at the alias depth
// stands for carriers further down, and a value's own position, as a call result
// whose summary does not say where in it each target is held, for those inside it.
@(private = "file")
prov_alias_at_carrier :: proc(graph: ^Flow_Graph, id: Storage_Id, alias: Written_Alias) -> bool {
	if alias.target == 0 || .Depth in path_precision(alias.path) {
		return false
	}
	type := prov_storage(graph, id).type
	if type == INVALID_TYPE {
		return false
	}
	held, named := prov_type_along(graph.k.c, type, alias.path)
	return named == len(alias.path) && type_is_carrier(graph.k.c, held)
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
		                       path = prov_concat_path(graph, prefix, rest), loaded = alias.loaded, precision = alias.precision})
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
	for &known in existing {
		if known.target == alias.target && prov_same_path(known.at, alias.at) && prov_same_path(known.path, alias.path) {
			known.loaded ||= alias.loaded
			// Set without a budget once, it was not merged in.
			known.precision &= alias.precision
			return
		}
	}
	grown := make([]Written_Alias, len(existing) + 1, graph.alloc)
	copy(grown, existing)
	grown[len(existing)] = Written_Alias {
		target    = alias.target,
		at        = slice.clone(alias.at, graph.alloc),
		path      = slice.clone(alias.path, graph.alloc),
		loaded    = alias.loaded,
		precision = alias.precision,
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
	seen := make(Written_Alias_Visits, graph.alloc)
	for argument, index in prov_bound_values(form) {
		if index >= len(info.parameters) { continue }
		if call_packs(call, index) {
			// Separate elements at the element type, then spreads at the pack's.
			element := underlying_info(c, info.parameters[index]).element
			for value, position in form.pack { if !call.variadic_order[position] { prov_forget_argument_aliases(graph, value, element, false, &seen) } }
			for value, position in form.pack {
				if call.variadic_order[position] {
					prov_forget_argument_aliases(graph, value, prov_pack_spread_type(c, prov_value(graph, value).type, info.parameters[index]), false, &seen)
				}
			}
			continue
		}
		inout := param_mode_at(info, index) == .Inout
		prov_forget_argument_aliases(graph, argument, info.parameters[index], inout, &seen)
	}
}

// The effective parameter capability applies to the normalized value's paths.
@(private = "file")
prov_forget_argument_aliases :: proc(
	graph: ^Flow_Graph, id: Value_Id, parameter: Type_Id, inout: bool, seen: ^Written_Alias_Visits,
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

// One place of a storage that an alias walk has visited with a capability. Its
// steps compare as `same_step` does, so that a visit is found by hashing.
Written_Alias_Visit :: struct {
	target:   Storage_Id,
	writable: bool,
	depth:    int,
	steps:    [WRITTEN_ALIAS_DEPTH]Written_Alias_Step,
}

Written_Alias_Step :: struct {
	kind: Proj_Kind,
	lo:   i64,
	hi:   i64,
}

Written_Alias_Visits :: map[Written_Alias_Visit]struct{}

// `path`, cut to the steps `target`'s type has and to the depth aliases keep, and
// whether this is the first visit to that place of `target` with this capability.
// A step the type has not, as an element step below a whole record a carrier was
// only known to point into, names all of the place before it. Kept, it would let
// a walk back into the same storage repeat that place at every depth.
@(private)
prov_first_alias_visit :: proc(graph: ^Flow_Graph, seen: ^Written_Alias_Visits, target: Storage_Id, path: []Proj_Step, writable: bool) -> (bounded: []Proj_Step, first: bool) {
	named := len(path)
	if type := prov_storage(graph, target).type; type != INVALID_TYPE {
		_, named = prov_type_along(graph.k.c, type, path)
	}
	bounded = path[:min(named, WRITTEN_ALIAS_DEPTH)]
	visit := Written_Alias_Visit{target = target, writable = writable, depth = len(bounded)}
	for step, index in bounded {
		visit.steps[index] = {step.kind, step.lo, step.hi}
	}
	if visit in seen^ {
		return bounded, false
	}
	seen^[visit] = {}
	return bounded, true
}

@(private = "file")
prov_forget_place_aliases :: proc(graph: ^Flow_Graph, place: Value_Id, seen: ^Written_Alias_Visits) {
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
	graph: ^Flow_Graph, target: Storage_Id, storage: []Proj_Step, writable: bool, seen: ^Written_Alias_Visits,
) {
	type := prov_storage(graph, target).type
	if type == INVALID_TYPE { return }
	path, first := prov_first_alias_visit(graph, seen, target, storage, writable)
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

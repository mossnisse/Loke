// Region providers: the token of each provider position a local's type fixes,
// and the providers moved into a local (design.md "Allocator regions and region
// provenance").
package lokec

import "core:slice"

// One provider position in a local: a field path its type fixes, or the path
// of a container, union, or array whose providers share one token.
Provider_Path :: struct {
	key: []Proj_Step,
	bit: u64,
}

// Every token of one local. Past `REGION_LOCAL_LIMIT` the set is `crowded`, meaning "may
// be any of them".
@(private)
prov_provider_region :: proc(graph: ^Flow_Graph, id: Symbol_Id) -> Region_Set {
	out := Region_Set{}
	if !prov_provider_tokens(graph, id) {
		out.crowded = true
		return out
	}
	out.locals = graph.provider_bits[id]
	return out
}

// The tokens of the providers at or under `path` in a local, or containing it,
// whether its type fixes them there or they were moved in there.
@(private)
prov_provider_region_at :: proc(graph: ^Flow_Graph, id: Symbol_Id, path: []Proj_Step) -> Region_Set {
	out := Region_Set{}
	if !prov_provider_tokens(graph, id) {
		out.crowded = true
		return out
	}
	key := provider_key(path)
	for position in graph.provider_paths[id] {
		if provider_keys_overlap(position.key, key) { out.locals |= position.bit }
	}
	for moved in graph.provider_moved[id] {
		if provider_keys_overlap(moved.key, key) { out.locals |= moved.bit }
	}
	return out
}

// Where in a local a provider at `path` sits: its field prefix. A container,
// union, or array shares one position among its elements.
@(private = "file")
provider_key :: proc(path: []Proj_Step) -> []Proj_Step {
	for step, index in path {
		if step.kind != .Field {
			return path[:index]
		}
	}
	return path
}

// Whether one provider position holds the other, or is held in it.
@(private = "file")
provider_keys_overlap :: proc(a, b: []Proj_Step) -> bool {
	return path_has_exact_prefix(a, b) || path_has_exact_prefix(b, a)
}

// The tokens of every provider moved into a local, wherever it sits.
@(private = "file")
prov_moved_tokens :: proc(graph: ^Flow_Graph, id: Symbol_Id) -> u64 {
	bits: u64
	for moved in graph.provider_moved[id] {
		bits |= moved.bit
	}
	return bits
}

// Gives a local one token per provider position on first use, so every token
// exists before any reset or handle reads it. False when the bits run out.
@(private = "file")
prov_provider_tokens :: proc(graph: ^Flow_Graph, id: Symbol_Id) -> bool {
	if _, found := graph.provider_bits[id]; found {
		return true
	}
	positions := make([dynamic]Provider_Path, 0, 1, graph.alloc)
	if sym := symbol_of(graph.k.c, id); sym != nil {
		prov_provider_positions(graph, sym.type, nil, 0, &positions)
	}
	if len(positions) == 0 {
		append(&positions, Provider_Path{})
	}
	if len(graph.provider_symbols) + len(positions) > REGION_LOCAL_LIMIT {
		return false
	}
	bits := prov_moved_tokens(graph, id)
	for &position in positions {
		position.bit = u64(1) << u64(len(graph.provider_symbols))
		append(&graph.provider_symbols, id)
		bits |= position.bit
	}
	graph.provider_paths[id] = positions[:]
	graph.provider_bits[id] = bits
	return true
}

@(private = "file")
prov_provider_positions :: proc(graph: ^Flow_Graph, type: Type_Id, prefix: []Proj_Step, depth: int, out: ^[dynamic]Provider_Path) {
	c := graph.k.c
	if !type_carries_provider(c, type) {
		return
	}
	info := underlying_info(c, type)
	if type_is_region_provider(c, type) || info == nil || info.kind != .Struct || type_is_shared_handle(c, type) || depth >= CARRIER_DEPTH {
		append(out, Provider_Path{key = prefix})
		return
	}
	for field in info.fields {
		if sym := symbol_of(c, field); sym != nil {
			prov_provider_positions(graph, sym.type, prov_extend(graph, prefix, proj_field(int(sym.index))), depth + 1, out)
		}
	}
}

// Ending a provider reads its control block, which a fixed arena keeps in the
// caller's buffer, so the buffer stays borrowed until then — and with it, until
// every owner the region backs is gone, since those must end first.
@(private)
prov_provider_use :: proc(graph: ^Flow_Graph, id: Symbol_Id, span: Span) {
	sources := make([dynamic]int, 0, 1, graph.alloc)
	if slot, is_carrier := prov_slot_for_symbol(graph, id); is_carrier {
		append(&sources, slot)
	}
	for slot in prov_content_slots(graph, id) {
		if type_is_region_provider(graph.k.c, graph.prov_slots[slot].content_type) {
			append(&sources, slot)
		}
	}
	if len(sources) > 0 {
		prov_emit(graph, Prov_Event{kind = .Live, sources = sources[:], span = span})
	}
}

// design.md "Allocators": the providers a value moved out of locals carries,
// through composite literals, `exchange`, `unsafe.take`, and `box`, each keyed by
// where in the value it sits, so that moving the value into a local puts each
// token at its own field there and a sibling field keeps none of it.
@(private)
prov_moved_providers :: proc(graph: ^Flow_Graph, id: Value_Id) -> []Provider_Path {
	source: Value_Id
	#partial switch form in prov_value(graph, id).form {
	case Prov_Form_Move:
		source = form.operand
	case Prov_Form_Call:
		v, bound := form.call, prov_bound_values(form)
		if builtin_moves_out_first(symbol_of(graph.k.c, v.resolution.symbol), len(bound)) {
			source = bound[0]
		} else if boxed_payload(graph.k.c, v) != nil {
			// A box is one position: its payload's fields are not the local's.
			return prov_rekey_providers(graph, prov_moved_providers(graph, bound[0]), prov_extend(graph, nil, proj_wild()))
		}
	case Prov_Form_Composite:
		out := make([dynamic]Provider_Path, graph.alloc)
		value := prov_value(graph, id)
		composite, _ := value.origin.(^Expr_Composite)
		for element, index in form.elements {
			if element == 0 { continue }
			// An element whose field is not known may be at any position.
			prefix := prov_extend(graph, nil, proj_wild())
			if composite != nil {
				prefix, _ = prov_element_prefix(graph, composite, value.type, index)
			}
			append(&out, ..prov_rekey_providers(graph, prov_moved_providers(graph, element), prefix))
		}
		return out[:]
	}
	// Only the providers at the place moved from go with it: a sibling field keeps
	// its own token.
	if source == 0 { return nil }
	root, path, ok := prov_value_place_of(graph, source)
	if !ok || graph.roots[int(root)].kind != .Local { return nil }
	symbol := graph.roots[int(root)].symbol
	// Moving a local's providers is a use of its tokens, which may not exist yet.
	// Past `REGION_LOCAL_LIMIT` they never will, and every region read of the local
	// is crowded, which overlaps any end of what it is moved into, so it carries none.
	if !prov_provider_tokens(graph, symbol) { return nil }
	key := provider_key(path)
	out := make([dynamic]Provider_Path, graph.alloc)
	take := proc(out: ^[dynamic]Provider_Path, held: Provider_Path, key: []Proj_Step) {
		if !provider_keys_overlap(held.key, key) { return }
		// What sat below the place moved keeps its place in the value; what held the
		// place, as a container of providers, is the whole value.
		below: []Proj_Step
		if len(held.key) > len(key) { below = held.key[len(key):] }
		append(out, Provider_Path{key = below, bit = held.bit})
	}
	for position in graph.provider_paths[symbol] { take(&out, position, key) }
	for moved in graph.provider_moved[symbol] { take(&out, moved, key) }
	return out[:]
}

// `moved`, read as held at `prefix`. A prefix past a field path, as a box's or an
// array element's, puts them all at the position holding it.
@(private = "file")
prov_rekey_providers :: proc(graph: ^Flow_Graph, moved: []Provider_Path, prefix: []Proj_Step) -> []Provider_Path {
	out := make([]Provider_Path, len(moved), graph.alloc)
	for held, index in moved {
		out[index] = Provider_Path{key = provider_key(prov_concat_path(graph, prefix, held.key)), bit = held.bit}
	}
	return out
}

// A provider moved into a local's existing storage, at `path` in it, joins that
// local's tokens there.
@(private)
prov_merge_moved_providers :: proc(graph: ^Flow_Graph, root: Symbol_Id, value: Value_Id, path: []Proj_Step = nil) {
	prov_effect_scope(graph, prov_effect_active(graph), Prov_Effect_Move_Provider{root, value, prov_effect_copy(graph, path)})
	moved := prov_moved_providers(graph, value)
	if len(moved) == 0 {
		return
	}
	existing := prov_provider_region(graph, root)
	if existing.crowded {
		return // already "may be any of them"
	}
	bits := prov_add_moved_providers(graph, root, prov_rekey_providers(graph, moved, path))
	graph.provider_bits[root] = existing.locals | bits
	if set, found := graph.region_of[root]; found && type_is_region_provider(graph.k.c, symbol_of(graph.k.c, root).type) {
		set.locals |= bits
		graph.region_of[root] = set
	}
}

// A local declared from a value carrying moved providers holds each at its own
// position, whether or not the local's own tokens exist yet.
@(private)
prov_declare_moved_providers :: proc(graph: ^Flow_Graph, id: Symbol_Id, value: Value_Id) {
	moved := prov_moved_providers(graph, value)
	if len(moved) == 0 {
		return
	}
	bits := prov_add_moved_providers(graph, id, moved)
	if existing, found := graph.provider_bits[id]; found {
		graph.provider_bits[id] = existing | bits
	}
}

// Records `moved` among a local's moved-in providers, and returns their tokens.
@(private)
prov_add_moved_providers :: proc(graph: ^Flow_Graph, root: Symbol_Id, moved: []Provider_Path) -> u64 {
	bits: u64
	held := make([dynamic]Provider_Path, 0, len(graph.provider_moved[root]) + len(moved), graph.alloc)
	append(&held, ..graph.provider_moved[root])
	outer: for added in moved {
		bits |= added.bit
		for &known in held {
			if prov_same_path(known.key, added.key) {
				known.bit |= added.bit
				continue outer
			}
		}
		append(&held, Provider_Path{key = slice.clone(added.key, graph.alloc), bit = added.bit})
	}
	graph.provider_moved[root] = held[:]
	return bits
}

// Where a provider's region ends: what both control-flow walks call at a cleanup,
// `drop`, `move`, `exchange`, or assignment. Lifecycle records who is dead at each
// such point, under the same `Reset_Key`, and provenance reads it to check what
// the region backs.
package lokec

import "core:fmt"
import "core:slice"

// A local holding a provider ends its region when it is cleaned up, dropped,
// moved anywhere but a new local or a result, or assigned over; every owner the
// region backs must be dead by then (design.md "Allocators"). `node` is the
// written end, or for a cleanup, the jump running it or nil; `ends` names a
// written end for the diagnostic.
@(private)
provider_region_end :: proc(graph: ^Flow_Graph, id: Symbol_Id, span: Span, node: rawptr, ends := "", path: []Proj_Step = nil) {
	if !provider_local(graph.k.c, id) {
		return
	}
	key := Reset_Key{graph.literal, node, id, graph.expansion}
	if graph.mode == .Lifecycle {
		graph.k.c.cleanup_reset_dead[key] = {}
		flow_emit(graph, Flow_Event{kind = .Reset_Point, reset = key, span = span})
		return
	}
	live, found := graph.k.c.cleanup_reset_dead[key]
	assert(found, "the provenance walk reached a provider end the lifecycle walk did not")
	// An unreachable exit ends nothing, and a consumed value has no region left.
	if !live.reached || slice.contains(live.dead, id) {
		return
	}
	prov_provider_use(graph, id, span)
	// A borrowed parameter's region is the caller's, and its owners are too.
	if root, rooted := graph.root_by_symbol[id]; !rooted || graph.roots[int(root)].kind != .Local {
		return
	}
	region := path == nil ? prov_provider_region(graph, id) : prov_provider_region_at(graph, id, path)
	prov_reset(graph, region, span, true, nil, live, ends, id, provider_end = true)
}

// A local or `move` parameter holding a provider by value, whose end can end a
// region. A view such as a `&mut` loop element owns nothing, so assigning through
// it replaces the provider in the storage it views (`place_is_direct`). Asked
// before an end is described, since most locals hold none.
@(private)
provider_local :: proc(c: ^Compiler, id: Symbol_Id) -> bool {
	sym := symbol_of(c, id)
	return sym != nil && sym.borrowed_binding == .None && provider_owner(c, sym)
}

// Whether this frame owns what a symbol holds, and it holds a provider: an
// ordinary parameter's providers are the caller's.
@(private = "file")
provider_owner :: proc(c: ^Compiler, sym: ^Symbol) -> bool {
	owned := sym.kind == .Var && sym.duration == .None || sym.kind == .Parameter && sym.mode == .Move
	return owned && type_carries_provider(c, sym.type)
}

// An end written on a place that is a whole `provider_local`, which it reports.
@(private = "file")
provider_ident_end :: proc(graph: ^Flow_Graph, place: Expr, node: rawptr, span: Span, verb: string) -> bool {
	ident, is_ident := place.(^Expr_Ident)
	if !is_ident || !provider_local(graph.k.c, ident.symbol) {
		return false
	}
	provider_region_end(graph, ident.symbol, span, node, provider_end_phrase(graph, verb, ident.name))
	return true
}

// A `move` out of a local ends what it holds, unless the move is into a new
// local or a result, which carries the region along.
@(private)
provider_move_end :: proc(graph: ^Flow_Graph, v: ^Expr_Move) {
	if graph.aliased_moves[v] {
		return
	}
	provider_ident_end(graph, v.value, v, v.span, "moving")
}

@(private)
provider_drop_end :: proc(graph: ^Flow_Graph, v: ^Expr_Call) {
	provider_ident_end(graph, v.bound[0], v, v.span, "dropping")
}

// `exchange` hands back the old value, which ends its region wherever it goes
// but a new local.
@(private)
provider_exchange_end :: proc(graph: ^Flow_Graph, v: ^Expr_Call) {
	if graph.aliased_moves[v] {
		return
	}
	provider_place_end(graph, v.bound[0], v, v.span, "exchanging")
}

// Assignment drops the destination's previous value (design.md "Assignment
// statements").
@(private)
provider_assign_end :: proc(graph: ^Flow_Graph, target: Expr) {
	if !provider_ident_end(graph, target, expr_base(target), expr_span(target), "assigning over") {
		provider_place_end(graph, target, expr_base(target), expr_span(target), "assigning", "into")
	}
}

// The local whose own storage a place is in, when that local holds providers by
// value; INVALID_SYMBOL for anything reached through a pointer or slice.
@(private)
provider_place_root :: proc(graph: ^Flow_Graph, place: Expr) -> Symbol_Id {
	if !place_is_direct(graph.k.c, place) {
		return INVALID_SYMBOL
	}
	root := place_root_symbol(place)
	sym := symbol_of(graph.k.c, root)
	if sym == nil || !provider_owner(graph.k.c, sym) {
		return INVALID_SYMBOL
	}
	return root
}

// Whether a place is in its root variable's own storage: a field or element
// path that never follows a pointer, a slice, or a binding viewing another
// owner's storage.
@(private = "file")
place_is_direct :: proc(c: ^Compiler, place: Expr) -> bool {
	#partial switch v in place {
	case ^Expr_Ident:
		sym := symbol_of(c, v.symbol)
		return sym == nil || sym.borrowed_binding == .None
	case ^Expr_Selector:
		return v.operand != nil && !type_is_pointer(c, expr_base(v.operand).type) && place_is_direct(c, v.operand)
	case ^Expr_Postfix:
		// A box's payload is part of the box (design.md "Owned values").
		return v.boxed && place_is_direct(c, v.operand)
	case ^Expr_Index:
		#partial switch underlying_kind(c, expr_base(v.operand).type) {
		case .Array, .Dynamic_Array, .Map:
			return len(v.bound) == 0 && place_is_direct(c, v.operand)
		}
	}
	return false
}

// Replacing or removing the providers at a place ends their regions: in a
// local's own storage, that local's; through a pointer or slice, any local's.
// Static storage is not followed.
@(private)
provider_place_end :: proc(graph: ^Flow_Graph, place: Expr, node: rawptr, span: Span, verb: string, preposition := "") {
	if !type_carries_provider(graph.k.c, prov_type(graph, place)) {
		return
	}
	if root := provider_place_root(graph, place); root != INVALID_SYMBOL {
		name := identifier_text(graph.k.c, symbol_of(graph.k.c, root).name)
		direct := preposition == "" ? verb : fmt.aprintf("%s %s", verb, preposition, allocator = graph.alloc)
		// Only the providers at or under this place end.
		path: []Proj_Step
		if graph.mode != .Lifecycle {
			if _, place_path, ok := prov_place_of(graph, place); ok {
				path = place_path
			}
		}
		provider_region_end(graph, root, span, node, provider_end_phrase(graph, direct, name), path)
		return
	}
	if !place_is_direct(graph.k.c, place) {
		provider_indirect_end(graph, node, span, verb)
	}
}

// A place behind a pointer or slice may be in any local holding providers that
// was ever lent mutably, so the regions of all of those in scope end here.
@(private = "file")
provider_indirect_end :: proc(graph: ^Flow_Graph, node: rawptr, span: Span, verb: string) {
	key := Reset_Key{graph.literal, node, INVALID_SYMBOL, graph.expansion}
	if graph.mode == .Lifecycle {
		graph.k.c.cleanup_reset_dead[key] = {}
		flow_emit(graph, Flow_Event{kind = .Reset_Point, reset = key, span = span})
		return
	}
	live, found := graph.k.c.cleanup_reset_dead[key]
	assert(found, "the provenance walk reached a provider end the lifecycle walk did not")
	if !live.reached {
		return
	}
	// Which of these was lent is a carried fact, read when the reset materializes.
	owners := make([dynamic]Symbol_Id, graph.alloc)
	for id in live.owners {
		sym := symbol_of(graph.k.c, id)
		if sym == nil || !type_carries_provider(graph.k.c, sym.type) {
			continue
		}
		if root, rooted := graph.root_by_symbol[id]; rooted && graph.roots[int(root)].kind == .Local {
			append(&owners, id)
		}
	}
	if len(owners) == 0 {
		return
	}
	ends := fmt.aprintf("%s through a pointer or slice", verb, allocator = graph.alloc)
	prov_reset(graph, Prov_Reset_Indirect{owners[:]}, span, true, nil, live, ends, provider_end = true)
}

// What a call does to the providers of the container it operates on, none when it
// is no container operation.
@(private = "file")
provider_container_op :: proc(graph: ^Flow_Graph, v: ^Expr_Call) -> bit_set[Container_Op_Effect] {
	sym := symbol_of(graph.k.c, v.resolution.chosen_overload)
	if sym == nil || sym.synth != .Container_Op || len(v.bound) == 0 {
		return {}
	}
	return CONTAINER_OP_EFFECTS[sym.container_op]
}

// A provider appended or inserted into a local container is stored there, so it
// carries its region along.
@(private)
provider_container_moves :: proc(graph: ^Flow_Graph, v: ^Expr_Call) {
	if .Stores_Provider not_in provider_container_op(graph, v) || provider_place_root(graph, v.bound[0]) == INVALID_SYMBOL {
		return
	}
	for argument in v.bound[1:] {
		if argument != nil {
			mark_aliased_moves(graph, argument)
		}
	}
	for argument in v.variadic_elements {
		mark_aliased_moves(graph, argument)
	}
}

@(private)
provider_container_end :: proc(graph: ^Flow_Graph, v: ^Expr_Call) {
	effects := provider_container_op(graph, v)
	stores := .Stores_Provider in effects
	if .Drops_Provider in effects {
		// `try_insert` replaces an entry where the key is present.
		provider_place_end(graph, v.bound[0], v, v.span, stores ? "replacing an entry" : "removing", stores ? "of" : "from")
	}
	if !stores || graph.mode == .Lifecycle {
		return
	}
	if root := provider_place_root(graph, v.bound[0]); root != INVALID_SYMBOL {
		for argument in v.bound[1:] {
			if argument != nil {
				prov_merge_moved_bits(graph, root, prov_input_value(graph, argument))
			}
		}
		for argument in v.variadic_elements {
			prov_merge_moved_bits(graph, root, prov_input_value(graph, argument))
		}
	}
}

@(private = "file")
provider_end_phrase :: proc(graph: ^Flow_Graph, verb, name: string) -> string {
	return graph.mode == .Lifecycle ? "" : fmt.aprintf("%s `%s`", verb, name, allocator = graph.alloc)
}

// The moves an initializer or a result takes whole, through composite literals
// and the payload of a box.
@(private)
mark_aliased_moves :: proc(graph: ^Flow_Graph, e: Expr) {
	#partial switch v in e {
	case ^Expr_Move:
		graph.aliased_moves[v] = true
	case ^Expr_Call:
		if sym := symbol_of(graph.k.c, v.resolution.symbol); sym != nil && sym.builtin == .Exchange {
			graph.aliased_moves[v] = true
		} else if payload := boxed_payload(graph.k.c, v); payload != nil {
			mark_aliased_moves(graph, payload)
		}
	case ^Expr_Composite:
		for element in v.elements {
			if element.value != nil {
				mark_aliased_moves(graph, element.value)
			}
		}
	}
}

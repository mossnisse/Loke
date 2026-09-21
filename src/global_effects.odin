package lokec

import "core:fmt"
import "core:mem"

// design.md "Global write effects": a call writes whatever static-duration
// storage its callee may write, directly or through its own callees. Each body's
// set is settled over the whole program before provenance runs, and a call then
// counts as a write to every global in its callee's set, so a borrow of one that
// is still in use across the call conflicts exactly as a local write would.

// What one call may reach: a direct procedure, a `dyn` slot, or any procedure of
// a compatible type called through a value.
Effect_Call :: struct {
	callee:        Symbol_Id,
	type:          Type_Id,
	dyn_interface: Symbol_Id,
	dyn_index:     int,
}

// One body's own writes and calls, before the fixed point.
@(private = "file")
Body_Effects :: struct {
	symbol: Symbol_Id,
	type:   Type_Id,
	writes:  [dynamic]Symbol_Id,
	calls:   []Effect_Call,
	targets: [dynamic]int, // the bodies those calls may run
}

// A write, invalidation, or mutable borrow of a global's storage.
prov_note_static_write :: proc(graph: ^Flow_Graph, root: Root_Id) {
	if root == NO_ROOT {
		return
	}
	entry := graph.roots[int(root)]
	if (entry.kind != .Static && entry.kind != .Thread_Local) || entry.symbol == INVALID_SYMBOL {
		return
	}
	for existing in graph.effect_writes {
		if existing == entry.symbol {
			return
		}
	}
	append(&graph.effect_writes, entry.symbol)
}

// A procedure named anywhere but as a direct callee may be called through a
// value, so an indirect call's targets are drawn from these.
prov_note_proc_value :: proc(graph: ^Flow_Graph, e: Expr) {
	c := graph.k.c
	if c.global_writes_ready || e == nil {
		return
	}
	id := INVALID_SYMBOL
	#partial switch v in e {
	case ^Expr_Ident:
		id = v.symbol
	case ^Expr_Selector:
		id = v.resolution.symbol
	case ^Expr_Proc:
		id = v.symbol
	case:
		return
	}
	sym := symbol_of(c, id)
	if sym == nil || sym.kind != .Proc {
		return
	}
	if callee := graph.callee_expr; callee != nil && expr_base(callee) == expr_base(e) {
		graph.callee_expr = nil
		return
	}
	append(&graph.effect_values, id)
}

// The callee a call's global writes come from.
@(private = "file")
call_effect :: proc(c: ^Compiler, v: ^Expr_Call) -> (Effect_Call, bool) {
	#partial switch op in v.operation {
	case Call_Sort_By:
		return Effect_Call{callee = op.comparator}, op.comparator != INVALID_SYMBOL
	case Call_Dyn_Slot:
		sel, is_selector := v.callee.(^Expr_Selector)
		if !is_selector || sel.operand == nil {
			return {}, false
		}
		info := underlying_info(c, expr_base(sel.operand).type)
		if info == nil || info.kind != .Dyn {
			return {}, false
		}
		return Effect_Call{dyn_interface = info.dyn_interface, dyn_index = op.index}, true
	case Call_Procedure:
	case:
		return {}, false
	}
	id := v.resolution.chosen_overload
	if id == INVALID_SYMBOL {
		id = v.resolution.symbol
	}
	if sym := symbol_of(c, id); sym != nil && sym.kind == .Proc {
		return Effect_Call{callee = id}, true
	}
	if base := expr_base(v.callee); base != nil && underlying_kind(c, base.type) == .Proc {
		return Effect_Call{type = base.type}, true
	}
	return {}, false
}

// Records the call while the effects settle; once they have, the callee's
// writes become accesses at the call, after its arguments' loans are taken.
prov_call_effects :: proc(graph: ^Flow_Graph, v: ^Expr_Call) {
	c := graph.k.c
	target, ok := call_effect(c, v)
	if !ok {
		return
	}
	if !c.global_writes_ready {
		append(&graph.effect_calls, target)
		return
	}
	name := ""
	if sym := symbol_of(c, target.callee); sym != nil {
		name = fmt.tprintf("modified by `%s`", identifier_text(c, sym.name))
	} else {
		name = "modified by a procedure this call may reach"
	}
	for global in effect_call_writes(c, target) {
		root := prov_root_for_symbol(graph, global)
		prov_access(graph, root, nil, .Invalidate, v.span, name)
	}
}

// The settled writes of one call target.
@(private = "file")
effect_call_writes :: proc(c: ^Compiler, target: Effect_Call) -> []Symbol_Id {
	if target.callee != INVALID_SYMBOL {
		return c.global_writes[target.callee]
	}
	return c.indirect_writes[effect_key(target, context.temp_allocator)]
}

// An indirect target's key: a `dyn` slot, or a procedure type.
@(private = "file")
effect_key :: proc(target: Effect_Call, allocator: mem.Allocator) -> string {
	if target.dyn_interface != INVALID_SYMBOL {
		return fmt.aprintf("d%d.%d", int(target.dyn_interface), target.dyn_index, allocator = allocator)
	}
	return fmt.aprintf("t%d", int(target.type), allocator = allocator)
}

// Every clean body's own writes and calls, then the fixed point: a body writes
// what it writes itself and what anything it may call writes. An indirect call
// may reach every body of a compatible type that is used as a value, and a
// `dyn` slot every witness target for it; both are keyed and settled with the
// rest.
compute_global_writes :: proc(k: ^Checker) {
	c := k.c
	c.global_writes = make(map[Symbol_Id][]Symbol_Id, c.semantic_allocator)
	c.indirect_writes = make(map[string][]Symbol_Id, c.semantic_allocator)
	used_as_value := make(map[Symbol_Id]bool, 16, context.temp_allocator)
	bodies := make([dynamic]Body_Effects, 0, len(c.checked_bodies), context.temp_allocator)
	for body in c.checked_bodies {
		if !body.clean {
			continue
		}
		graph := build_flow_graph(k, body.literal, c.analysis_allocator, .Prov_Summary)
		effects := Body_Effects{symbol = body.literal.symbol}
		if sym := symbol_of(c, body.literal.symbol); sym != nil {
			effects.type = sym.proc_type
		}
		effects.writes = make([dynamic]Symbol_Id, 0, len(graph.effect_writes), context.temp_allocator)
		append(&effects.writes, ..graph.effect_writes[:])
		effects.calls = make([]Effect_Call, len(graph.effect_calls), context.temp_allocator)
		copy(effects.calls, graph.effect_calls[:])
		for id in graph.effect_values {
			used_as_value[id] = true
		}
		append(&bodies, effects)
		free_all(c.analysis_allocator)
	}
	index_of := make(map[Symbol_Id]int, len(bodies), context.temp_allocator)
	for body, index in bodies {
		index_of[body.symbol] = index
	}
	for &body in bodies {
		body.targets = make([dynamic]int, 0, len(body.calls), context.temp_allocator)
		for call in body.calls {
			append(&body.targets, ..effect_targets(c, call, bodies[:], index_of, used_as_value))
		}
	}
	// ponytail: whole-program rounds until nothing grows; a worklist over
	// callers would do if large programs make this slow.
	for changed := true; changed; {
		changed = false
		for &body in bodies {
			for target in body.targets {
				for global in bodies[target].writes {
					changed |= add_global_write(&body.writes, global)
				}
			}
		}
	}
	for body in bodies {
		if len(body.writes) > 0 {
			c.global_writes[body.symbol] = clone_symbols(c, body.writes[:])
		}
	}
	// What an indirect call reaches is keyed once for the provenance pass.
	for body in bodies {
		for call in body.calls {
			if call.callee != INVALID_SYMBOL {
				continue
			}
			key := effect_key(call, c.semantic_allocator)
			if key in c.indirect_writes {
				continue
			}
			writes := make([dynamic]Symbol_Id, 0, 4, context.temp_allocator)
			for target in effect_targets(c, call, bodies[:], index_of, used_as_value) {
				for global in bodies[target].writes {
					add_global_write(&writes, global)
				}
			}
			c.indirect_writes[key] = clone_symbols(c, writes[:])
		}
	}
	c.global_writes_ready = true
}

// The bodies one call may run.
@(private = "file")
effect_targets :: proc(
	c: ^Compiler,
	call: Effect_Call,
	bodies: []Body_Effects,
	index_of: map[Symbol_Id]int,
	used_as_value: map[Symbol_Id]bool,
) -> []int {
	out := make([dynamic]int, 0, 4, context.temp_allocator)
	switch {
	case call.callee != INVALID_SYMBOL:
		if index, found := index_of[call.callee]; found {
			append(&out, index)
		}
	case call.dyn_interface != INVALID_SYMBOL:
		for witness in c.witness_order {
			if witness.interface_symbol != call.dyn_interface || call.dyn_index >= len(witness.slots) {
				continue
			}
			if index, found := index_of[witness.slots[call.dyn_index].target]; found {
				append(&out, index)
			}
		}
	case:
		for body, index in bodies {
			if used_as_value[body.symbol] && assignable(c, body.type, call.type) {
				append(&out, index)
			}
		}
	}
	return out[:]
}

@(private = "file")
add_global_write :: proc(writes: ^[dynamic]Symbol_Id, global: Symbol_Id) -> bool {
	for existing in writes {
		if existing == global {
			return false
		}
	}
	append(writes, global)
	return true
}

@(private = "file")
clone_symbols :: proc(c: ^Compiler, symbols: []Symbol_Id) -> []Symbol_Id {
	out := make([]Symbol_Id, len(symbols), c.semantic_allocator)
	copy(out, symbols)
	return out
}

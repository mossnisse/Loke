// Reach and allocator-use summaries, settled over the calls the write effects
// resolved, for a `parallel` block's window (design.md "Globals while tasks run").
package lokec

import "core:mem"
import "core:slice"

// compiler-architecture.md "Ownership, lifecycle, and provenance": where one
// part of a summary comes from. `via` is INVALID_SYMBOL for the body's own
// access at `span`; otherwise `span` is the call, hook run, or drop that
// reaches `via`, whose own summary says where it got it, so a diagnostic can
// follow the chain. `precision` is the provenance merge that may have widened
// the access.
Effect_Source :: struct {
	via:       Symbol_Id,
	span:      Span,
	precision: Precision_Loss,
}

// A global whose stored carriers a body may dereference, index, slice, call,
// or dispatch through, read or written: the reach effect. Handing such a
// carrier to a call, returning it, or storing it counts too, since what
// receives it may reach through it.
Global_Effect :: struct {
	global: Symbol_Id,
	source: Effect_Source,
}

// Reach effects in the order found, one per global, with where each is: a body
// near `main` may reach most of a program's globals.
Effect_List :: struct {
	list: [dynamic]Global_Effect,
	at:   map[Symbol_Id]int,
}

effect_list_make :: proc(allocator: mem.Allocator) -> Effect_List {
	return {make([dynamic]Global_Effect, allocator), make(map[Symbol_Id]int, allocator)}
}

// A `thread_local` owner every thread drops when it exits, and one of its hooks,
// with what that does. Every task carries all of them, in its reservation as well
// (design.md "Globals while tasks run"). The owner's own release is in the default
// provider's region, which nothing reserves.
Thread_Exit_Drop :: struct {
	variable: Symbol_Id,
	hook:     Symbol_Id,
	writes:   []Symbol_Id,
	reach:    []Global_Effect,
	use:      Region_Set,
}

// One body's thread facts: its own part, apart from the callbacks it calls,
// then all of it; per called parameter, the regions of what it passes there;
// and what each of its calls takes in.
@(private = "file")
Thread_Body :: struct {
	reach:       Effect_List,
	use:         Region_Set,
	whole_reach: Effect_List,
	whole_use:   Region_Set,
	regions:     []Region_Set,
	calls:       []Effect_Call,
	parts:       [][]Call_Part,
}

// design.md "Shared ownership": the runtime's handle operations reach their
// one control block through a raw pointer, so its allocator, and every handle
// they rebuild from it, has an unknown region, though the block is the
// handle's region (`prov_call_region`). In those bodies an unknown region is
// the receiver's: the body's own use of one, and an argument of one it passes.
// What a callee uses on its own, such as a payload's drop hook, is its own
// (design.md "Allocators and tasks").
@(private = "file")
runtime_handle_operation :: proc(c: ^Compiler, symbol: Symbol_Id) -> bool {
	sym := symbol_of(c, symbol)
	shared := symbol_of(c, c.shared_symbol)
	return sym != nil && shared != nil && sym.pkg == shared.pkg && sym.has_receiver &&
	       type_is_shared_handle(c, sym.owner_type)
}

@(private = "file")
unknown_as_receiver :: proc(set: ^Region_Set) {
	if set.unknown {
		set.unknown = false
		region_add_param(set, 0)
	}
}

// Each clean body's graph is built once more, with the result summaries
// settled, recording its own reach and allocator use and its calls; then both
// settle over the calls as the write effects do, each callback taken from
// where its caller passes it and given the regions its callee passes it.
compute_thread_summaries :: proc(k: ^Checker) {
	c := k.c
	program := &c.effect_program
	facts := collect_thread_facts(k)
	settle_thread_facts(c, facts)
	for body, index in facts {
		whole, own := &program.whole[index], &program.own[index]
		whole.reach = slice.clone(body.whole_reach.list[:], c.semantic_allocator)
		whole.use = body.whole_use
		own.reach, own.use = whole.reach, whole.use
		if summary := c.callback_summaries[program.bodies[index].symbol]; summary != nil {
			own.reach = slice.clone(body.reach.list[:], c.semantic_allocator)
			own.use = body.use
			summary.regions = clone_regions(body.regions, c.semantic_allocator)
		}
	}
	collect_thread_exit_drops(c)
}

@(private = "file")
collect_thread_facts :: proc(k: ^Checker) -> []Thread_Body {
	c := k.c
	program := &c.effect_program
	facts := make([]Thread_Body, len(program.bodies), context.temp_allocator)
	for &body in facts {
		body.reach = effect_list_make(context.temp_allocator)
		body.whole_reach = effect_list_make(context.temp_allocator)
	}
	c.thread_facts_pending = true
	for body in c.checked_bodies {
		index, found := program.index_of[body.literal.symbol]
		if !body.clean || !found {
			continue
		}
		graph := build_flow_graph(k, body.literal, .Prov_Summary)
		own := &facts[index]
		handle := runtime_handle_operation(c, body.literal.symbol)
		own.use = graph.allocator_use
		if handle {
			unknown_as_receiver(&own.use)
		}
		own.calls = make([]Effect_Call, len(graph.effect_calls), context.temp_allocator)
		own.parts = make([][]Call_Part, len(graph.effect_calls), context.temp_allocator)
		for call, position in graph.effect_calls {
			kept := call
			kept.args = nil
			kept.regions = clone_regions(call.regions, context.temp_allocator)
			if handle {
				handle_call_regions(c, &kept)
			}
			own.calls[position] = kept
			own.parts[position] = slice.clone(call_parts(c, body.literal.symbol, kept, open = false), context.temp_allocator)
		}
		// Solved last: the solve's storage is the graph's.
		body_global_reach(k, graph, &own.reach)
		free_all(c.analysis_allocator)
	}
	c.thread_facts_pending = false
	return facts
}

// A call in a runtime handle operation: where no argument can carry a region,
// which reads as unknown, what the callee reaches through one is in the block.
@(private = "file")
handle_call_regions :: proc(c: ^Compiler, call: ^Effect_Call) {
	if call.regions == nil {
		count := 1
		if callee := symbol_of(c, call.callee); callee != nil {
			count = max(len(callee.param_symbols), 1)
		}
		call.regions = make([]Region_Set, count, context.temp_allocator)
		for &set in call.regions {
			set = Region_Set{unknown = true}
		}
	}
	for &set in call.regions {
		unknown_as_receiver(&set)
	}
}

@(private = "file")
settle_thread_facts :: proc(c: ^Compiler, facts: []Thread_Body) {
	program := &c.effect_program
	parts := make([][]Call_Part, len(facts), context.temp_allocator)
	for &body, index in facts {
		list := make([dynamic]Call_Part, 0, len(body.calls), context.temp_allocator)
		for each in body.parts {
			append(&list, ..each)
		}
		parts[index] = list[:]
		if summary := c.callback_summaries[program.bodies[index].symbol]; summary != nil {
			body.regions = make([]Region_Set, len(summary.called), context.temp_allocator)
		}
	}
	settle := part_fixpoint_make(c, parts)
	for index in worklist_pop(&settle.queue) {
		body := &facts[index]
		grew := false
		for call, position in body.calls {
			for part in body.parts[position] {
				reached := &facts[part.body]
				via := program.bodies[part.body].symbol
				for effect in (reached.whole_reach.list if part.whole else reached.reach.list) {
					source := Effect_Source{via = via, span = call.span, precision = effect.source.precision}
					grew |= add_global_effect(&body.reach, effect.global, source)
				}
				use := reached.whole_use if part.whole else reached.use
				if part.callback >= 0 {
					use = callback_allocator_use(use, facts[part.via].regions[part.callback], call.regions)
				} else {
					use = substituted_region(use, call.regions, direct = !part.whole)
				}
				grew |= merge_allocator_use(&body.use, use)
			}
			grew |= note_callback_regions(c, facts, index, call)
		}
		for reached in body.reach.list {
			grew |= add_global_effect(&body.whole_reach, reached.global, reached.source)
		}
		grew |= merge_allocator_use(&body.whole_use, body.use)
		summary := c.callback_summaries[program.bodies[index].symbol]
		for part in settle.closing[index] {
			via := program.bodies[part.body].symbol
			span := summary.called[part.callback].span
			for reached in facts[part.body].whole_reach.list {
				source := Effect_Source{via = via, span = span, precision = reached.source.precision}
				grew |= add_global_effect(&body.whole_reach, reached.global, source)
			}
			given := []Region_Set{body.regions[part.callback]}
			grew |= merge_allocator_use(&body.whole_use, substituted_region(facts[part.body].whole_use, given, direct = false))
		}
		if grew {
			part_fixpoint_grew(&settle, index)
		}
	}
}

// What one call passes the callbacks the body received: a call through one
// gives it every argument's region, and a direct call passing one on gives
// it what the callee gives it there.
@(private = "file")
note_callback_regions :: proc(c: ^Compiler, facts: []Thread_Body, index: int, call: Effect_Call) -> bool {
	program := &c.effect_program
	body := &facts[index]
	summary := c.callback_summaries[program.bodies[index].symbol]
	if summary == nil {
		return false
	}
	grew := false
	args, values, followed := call_values(c, program.bodies[index].symbol, call)
	if target, found := program.index_of[call.callee]; found {
		passed := c.callback_summaries[call.callee]
		if passed == nil {
			return false
		}
		for callback, position in passed.called {
			for arg in args {
				own := called_position(summary, arg.parameter)
				if arg.binding != callback.parameter || arg.kind != .Parameter || own < 0 {
					continue
				}
				grew |= region_merge(&body.regions[own], substituted_region(facts[target].regions[position], call.regions))
			}
		}
	} else if followed {
		for value in values {
			own := called_position(summary, value.parameter) if value.kind == .Parameter else -1
			if own < 0 {
				continue
			}
			if call.regions == nil {
				grew |= region_merge(&body.regions[own], Region_Set{unknown = true})
			}
			for set in call.regions {
				grew |= region_merge(&body.regions[own], set)
			}
		}
	}
	return grew
}

@(private = "file")
called_position :: proc(summary: ^Callback_Summary, parameter: int) -> int {
	for called, position in summary.called {
		if called.parameter == parameter {
			return position
		}
	}
	return -1
}

// design.md "Owners and `drop`": a thread's exit drops each `thread_local` owner,
// as a task's completion does under thread-per-spawn. What each hook does comes
// from the settled summaries; its parameter is the owner, in the default provider's
// region, since `via` is forbidden on such storage.
@(private = "file")
collect_thread_exit_drops :: proc(c: ^Compiler) {
	drops := make([dynamic]Thread_Exit_Drop, 0, 4, c.semantic_allocator)
	owner := []Region_Set{{default = true}}
	for sym, index in c.symbols {
		if sym == nil || sym.kind != .Var || sym.duration != .Thread_Local {
			continue
		}
		for hook in type_drop_hooks(c, sym.type) {
			summary := body_summary(c, hook)
			reach := make([]Global_Effect, len(summary.reach), c.semantic_allocator)
			for reached, at in summary.reach {
				reach[at] = Global_Effect{global = reached.global, source = Effect_Source{via = hook, span = sym.span}}
			}
			append(&drops, Thread_Exit_Drop {
				variable = Symbol_Id(index),
				hook     = hook,
				writes   = summary.writes,
				reach    = reach,
				use      = substituted_region(summary.use, owner),
			})
		}
	}
	c.thread_exit_drops = drops[:]
}

@(private)
add_global_effect :: proc(effects: ^Effect_List, global: Symbol_Id, source: Effect_Source) -> bool {
	if at, found := effects.at[global]; found {
		return merge_effect_source(&effects.list[at].source, source)
	}
	effects.at[global] = len(effects.list)
	append(&effects.list, Global_Effect{global = global, source = source})
	return true
}

// One effect reached by two routes is reported from an exact one where either
// is, since then it certainly happens, and otherwise names both routes'
// precision limits, so whether it "reaches" or "may reach" does not depend on
// which came first. The route the notes follow (`via`, `span`) is still the
// first met of the kind kept.
@(private = "file")
merge_effect_source :: proc(into: ^Effect_Source, from: Effect_Source) -> bool {
	if into.precision == {} {
		return false
	}
	if from.precision == {} {
		into^ = from
		return true
	}
	return merge_precision(&into.precision, from.precision)
}
